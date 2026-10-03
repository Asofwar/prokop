#!/usr/bin/env bash
set -euo pipefail

# After the point of no return a failure keeps the migrated Prokop
# configuration, the backups and the resume marker, leaves Prokop disabled
# and says how to finish; the next run completes the switch from the
# recorded stage without stopping or removing anything twice, with the
# backend of the release it installs the interface from. A run cut off
# (power loss) after that point is completed the same way; one cut off
# before it is rolled back and started again. A marker with an unknown
# stage stops the installer before any change.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v dash >/dev/null 2>&1 ||
  fail "dash is required: the installer runs under BusyBox ash on the router"

run_scenario() {
  mkdir -p "$WORK_DIR/$1"
  PFF_REPO="$ROOT_DIR" PFF_WORK="$WORK_DIR/$1" dash "$WORK_DIR/$1.sh" ||
    fail "scenario $1 failed"
}

cat >"$WORK_DIR/common.sh" <<'SCENARIO'
# The state of a completed switch.
assert_switched() {
    for package in prokop luci-app-prokop; do
        pff_installed "$package" || pff_fail "$package is not installed after the resumed switch"
    done
    for package in forkop luci-app-forkop luci-i18n-forkop-ru; do
        if pff_installed "$package"; then pff_fail "$package is still installed after the resumed switch"; fi
    done
    grep -Fq "vless://forkop-migration-test" "$PFF_ROOT/etc/config/prokop" ||
        pff_fail "the migrated configuration was lost"
    pff_assert_exists "$PFF_ROOT/etc/prokop/tailscale/node/node.key"
    pff_assert_absent "$PFF_ROOT/etc/config/forkop"
    pff_assert_absent "$PFF_ROOT/usr/lib/forkop"
    grep -Fq '# forkop-' "$PFF_ROOT/etc/crontabs/root" && pff_fail "Forkop cron jobs remain"
    pff_assert_exists "$PFF_ROOT/etc/rc.d/S99prokop" "Prokop must be enabled as Forkop was"
    pff_assert_exists "$FAKE_NFT_DIR/ProkopTable" "Prokop must be started as Forkop was"
    pff_assert_exists "$FAKE_NFT_DIR/ForkopKillswitch" "the old kill-switch stays until Prokop arms its own"
    pff_assert_absent "$PFF_ROOT/etc/prokop/.migrating-from-forkop"
    pff_assert_absent "$PFF_ROOT/etc/prokop-forkop-migration"
}

# A switch that failed after the point of no return is resumed after a newer
# release appeared: the backend comes from that release as the interface
# does, never an older backend under a newer interface.
newer_release_on_resume() {
    export FAKE_PKG_INSTALL_FAILS=luci-app-prokop
    if pff_run_installer; then
        pff_fail "a failed luci-app-prokop installation must stop the switch"
    fi
    [ "$(cat "$PFF_ROOT/etc/prokop/.migrating-from-forkop")" = finish ] || pff_fail "the marker must name the finish stage"
    [ "$(cat "$FAKE_PKG_DIR/installed/prokop")" = 2.0.0 ] || pff_fail "the first run installs the 2.0.0 backend"
    unset FAKE_PKG_INSTALL_FAILS

    PFF_RELEASE_VERSION=2.0.1
    pff_run_installer || pff_fail "the resumed switch must complete with the newer release"
    pff_assert_log 'Resuming the interrupted switch from Forkop at stage finish'
    pff_assert_event 'install prokop 2.0.1' 'the backend must come from the release of the interface'
    for package in prokop luci-app-prokop; do
        [ "$(cat "$FAKE_PKG_DIR/installed/$package")" = 2.0.1 ] ||
            pff_fail "$package must be at the resolved release 2.0.1, not $(cat "$FAKE_PKG_DIR/installed/$package")"
    done
    first() { grep -Fxn -- "$1" "$PFF_EVENTS" | head -n 1 | cut -d: -f1; }
    [ "$(first 'install prokop 2.0.1')" -lt "$(first 'install luci-app-prokop 2.0.1')" ] ||
        pff_fail "the backend must be installed before its interface"
    assert_switched
}
SCENARIO

for manager in opkg apk; do
    cat >"$WORK_DIR/newer-release-on-resume-$manager.sh" <<SCENARIO
. "\$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
. "\$PFF_WORK/../common.sh"
pff_setup $manager
PFF_I18N=0 pff_install_forkop
newer_release_on_resume
SCENARIO
done

cat >"$WORK_DIR/failure-after-removal.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
. "$PFF_WORK/../common.sh"
pff_setup opkg
PFF_I18N=0 pff_install_forkop
root="$PFF_ROOT"

export FAKE_PKG_INSTALL_FAILS=luci-app-prokop
if pff_run_installer; then
    pff_fail "a failed luci-app-prokop installation must stop the switch"
fi
pff_assert_log 'The switch from Forkop stopped at stage finish' 'the stage must be reported'
pff_assert_log "Prokop was left disabled; its configuration: $root/etc/config/prokop" \
    'the kept Prokop configuration must be named'
pff_assert_log "The Forkop state and backups (readable by root only) are in $root/etc/prokop-forkop-migration" \
    'the backups must be named'
pff_assert_log 'Run the installer again to complete the switch:' 'the next step must be given'
pff_assert_log 'wget -qO- https://asofwar.github.io/prokop/install.sh | sh' 'the command for the next step'
[ "$(cat "$root/etc/prokop/.migrating-from-forkop")" = finish ] || pff_fail "the resume marker must name the stage"
pff_assert_exists "$root/etc/prokop-forkop-migration/state" "the recorded state must stay"
pff_assert_exists "$root/etc/prokop-forkop-migration/legacy.config" "the backups must stay"
grep -Fq "vless://forkop-migration-test" "$root/etc/config/prokop" ||
    pff_fail "the migrated Prokop configuration must stay"
pff_assert_absent "$root/etc/rc.d/S99prokop" "Prokop must stay disabled"
pff_assert_absent "$FAKE_NFT_DIR/ProkopTable" "Prokop must not be started"
pff_refute_event 'prokop start'
if pff_installed forkop; then pff_fail "forkop was removed before the failure"; fi
stops="$(pff_event_count 'forkop stop source=package')"

# A Prokop that got enabled before a failure is disabled again.
ln -s ../init.d/prokop "$root/etc/rc.d/S99prokop"
if pff_run_installer; then
    pff_fail "the resumed switch must fail again while luci-app-prokop cannot be installed"
fi
pff_assert_log 'Resuming the interrupted switch from Forkop at stage finish' 'the resume must be reported'
pff_assert_event 'prokop disable' 'an enabled Prokop must be disabled after a failure'
pff_assert_absent "$root/etc/rc.d/S99prokop"

unset FAKE_PKG_INSTALL_FAILS
pff_run_installer || pff_fail "the resumed switch must complete"
pff_assert_log 'The switch from Forkop to Prokop is complete'
[ "$(pff_event_count 'forkop stop source=package')" -eq "$stops" ] ||
    pff_fail "the resumed switch must not stop Forkop again"
[ "$(pff_event_count 'remove forkop')" -eq 1 ] || pff_fail "Forkop must be removed once"
[ "$(pff_event_count 'install prokop 2.0.0')" -eq 1 ] || pff_fail "an installed Prokop backend is not reinstalled"
assert_switched
SCENARIO

cat >"$WORK_DIR/interrupted-cleanup.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
. "$PFF_WORK/../common.sh"
pff_setup apk
PFF_I18N=0 pff_install_forkop
root="$PFF_ROOT"

# Power loss in the middle of the cleanup: no failure handler runs.
PFF_INTERRUPT=legacy_forkop_remove_cron_jobs
if pff_run_installer; then
    pff_fail "the interrupted run must not complete"
fi
PFF_INTERRUPT=""
[ "$(cat "$root/etc/prokop/.migrating-from-forkop")" = cleanup ] || pff_fail "the marker must name the cleanup stage"
grep -Fq '# forkop-' "$root/etc/crontabs/root" || pff_fail "the interruption must hit before the cron cleanup"
if pff_installed forkop; then pff_fail "forkop was removed before the interruption"; fi

pff_run_installer || pff_fail "the run after the interruption must complete the switch"
pff_assert_log 'Resuming the interrupted switch from Forkop at stage cleanup'
[ "$(pff_event_count 'remove forkop')" -eq 1 ] || pff_fail "Forkop must be removed once"
[ "$(pff_event_count 'install prokop 2.0.0')" -eq 1 ] ||
    pff_fail "a backend of the resolved release is not reinstalled with apk"
[ "$(pff_event_count 'forkop stop source=package')" -eq 2 ] ||
    pff_fail "Forkop must be stopped once by the installer and once by its own prerm"
assert_switched
SCENARIO

cat >"$WORK_DIR/interrupted-install.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
. "$PFF_WORK/../common.sh"
pff_setup opkg
PFF_I18N=0 pff_install_forkop
root="$PFF_ROOT"

# Power loss after Prokop was installed next to Forkop, before the point of
# no return.
PFF_INTERRUPT=legacy_forkop_copy_state
if pff_run_installer; then
    pff_fail "the interrupted run must not complete"
fi
PFF_INTERRUPT=""
[ "$(cat "$root/etc/prokop/.migrating-from-forkop")" = install ] || pff_fail "the marker must name the install stage"
pff_installed prokop || pff_fail "Prokop was installed before the interruption"
pff_assert_exists "$FAKE_NFT_DIR/ForkopTable" "Forkop must still run"
pff_refute_event 'forkop stop'

pff_run_installer || pff_fail "the run after the interruption must roll back and switch"
pff_assert_log 'The previous switch from Forkop stopped before its removal; rolling it back and starting again. Stage: install'
pff_assert_log 'The changes were rolled back; Forkop was left as it was'
pff_refute_event 'prokop prerm restored dnsmasq' 'the rollback must not let the Prokop prerm restore dnsmasq'
first() { grep -Fxn -- "$1" "$PFF_EVENTS" | head -n 1 | cut -d: -f1; }
second_install="$(grep -Fxn 'install prokop 2.0.0' "$PFF_EVENTS" | sed -n '2p' | cut -d: -f1)"
[ -n "$second_install" ] && [ "$(first 'remove prokop')" -lt "$second_install" ] ||
    pff_fail "the interrupted installation must be rolled back before Prokop is installed again"
assert_switched
SCENARIO

cat >"$WORK_DIR/unknown-stage.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
pff_install_forkop
root="$PFF_ROOT"
mkdir -p "$root/etc/prokop"
printf '%s\n' 'half-written' >"$root/etc/prokop/.migrating-from-forkop"
before="$(pff_forkop_digest)"
if pff_run_installer; then
    pff_fail "an unknown stage must stop the installer"
fi
pff_assert_log "names an unknown stage 'half-written'" 'the unknown stage must be reported'
[ "$before" = "$(pff_forkop_digest)" ] || pff_fail "an unknown stage must change nothing"
pff_refute_event 'install prokop'
pff_assert_exists "$root/etc/prokop/.migrating-from-forkop" "the marker must stay for inspection"
SCENARIO

run_scenario failure-after-removal
run_scenario newer-release-on-resume-opkg
run_scenario newer-release-on-resume-apk
run_scenario interrupted-cleanup
run_scenario interrupted-install
run_scenario unknown-stage

printf 'Prokop from Forkop installer resume tests passed\n'
