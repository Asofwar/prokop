#!/usr/bin/env bash
set -euo pipefail

# Before the point of no return the switch from Forkop changes nothing of
# Forkop, and a failure rolls everything back: Prokop goes (unless it was
# installed before) without its prerm touching the dnsmasq Forkop still
# uses, its previous configuration comes back, the copied data goes, and
# Forkop is back in its recorded service state. Without an interactive
# terminal the switch needs --confirm-legacy-migration and refuses with a
# hint otherwise. A Prokop configuration that was edited is never replaced.

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

cat >"$WORK_DIR/validation-failure.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
pff_install_forkop
root="$PFF_ROOT"
before="$(pff_forkop_digest)"

FAKE_VALIDATION_FAILS=1
if pff_run_installer; then
    pff_fail "a migrated configuration that fails the Prokop checks must stop the switch"
fi
pff_assert_log 'Перенесенная конфигурация не прошла проверку Prokop: Section main has no usable outbound. Aborted.' \
    'the validation failure and its reason must be reported'
pff_assert_log 'Изменения отменены; Forkop оставлен как был' 'the rollback must be reported'

after="$(pff_forkop_digest)"
[ "$before" = "$after" ] || pff_fail "the rollback did not leave Forkop as it was:
$(printf '%s\n' "$before" >"$PFF_WORK/before"; printf '%s\n' "$after" >"$PFF_WORK/after"; diff "$PFF_WORK/before" "$PFF_WORK/after")"
pff_refute_event 'forkop stop' 'Forkop must not be stopped before the point of no return'
pff_refute_event 'remove forkop'
pff_assert_event 'remove prokop' 'the Prokop package installed by the switch must be removed'
pff_refute_event 'prokop prerm restored dnsmasq' 'the Prokop prerm must not restore the dnsmasq Forkop uses'
if pff_installed prokop; then pff_fail "prokop is still installed after the rollback"; fi
pff_installed forkop || pff_fail "forkop must stay installed"
pff_assert_exists "$FAKE_NFT_DIR/ForkopTable" "Forkop must keep running"
pff_assert_exists "$root/etc/rc.d/S99forkop" "Forkop must stay enabled"
for path in etc/config/prokop etc/config/prokop.migrating etc/prokop etc/prokop-backups \
    etc/prokop-forkop-migration; do
    pff_assert_absent "$root/$path" "the rollback must remove"
done
[ "$(pff_uci 'dnsmasq().server')" = 127.0.0.42 ] || pff_fail "dnsmasq must keep forwarding to the running Forkop"
SCENARIO

cat >"$WORK_DIR/migration-failure.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup apk
PFF_I18N=0 pff_install_forkop
root="$PFF_ROOT"
before="$(pff_forkop_digest)"

# Something other than the installer stopped and disabled Forkop on the way;
# the rollback brings it back to its recorded state.
install_backend_package() {
    pkg_install_prokop_file prokop "$PROKOP_BACKEND_FILE" || fail "prokop installation failed"
    pff_materialize_prokop_backend
    FAKE_FORKOP_STOP_DNS=keep "$PFF_ROOT/etc/init.d/forkop" stop
    "$PFF_ROOT/etc/init.d/forkop" disable
}
FAKE_MIGRATE_FAILS=1
if pff_run_installer; then
    pff_fail "a failed configuration migration must stop the switch"
fi
pff_assert_log 'The Forkop configuration could not be migrated' 'the migration failure must be reported'
pff_assert_event 'forkop enable source=' 'the rollback must enable Forkop again as recorded'
pff_assert_event 'forkop start source=' 'the rollback must start Forkop again as recorded'
after="$(pff_forkop_digest)"
[ "$before" = "$after" ] || pff_fail "the rollback did not bring Forkop back"
if pff_installed prokop; then pff_fail "prokop is still installed after the rollback with apk"; fi
pff_assert_absent "$root/etc/config/prokop"
pff_assert_absent "$root/etc/prokop-forkop-migration"
SCENARIO

cat >"$WORK_DIR/needs-confirmation.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
PFF_CONFIRM=0
pff_setup opkg
pff_install_forkop
root="$PFF_ROOT"
before="$(pff_forkop_digest)"

if pff_run_installer; then
    pff_fail "a non-interactive switch without --confirm-legacy-migration must refuse"
fi
pff_assert_log '--confirm-legacy-migration' 'the refusal must name the confirmation option'
pff_assert_log 'wget -qO- https://asofwar.github.io/prokop/install.sh | sh -s -- --confirm-legacy-migration' \
    'the refusal must give the command that confirms the switch'
if grep -Fq 'Изменения отменены' "$PFF_LOG"; then
    pff_fail "a refusal before any change must not report a rollback"
fi
pff_refute_event 'download prokop' 'nothing may be downloaded before the confirmation'
pff_refute_event 'install prokop'
[ "$before" = "$(pff_forkop_digest)" ] || pff_fail "the refusal changed Forkop"
for path in etc/prokop etc/prokop-forkop-migration etc/config/prokop; do
    pff_assert_absent "$root/$path" "the refusal must leave nothing behind"
done
SCENARIO

cat >"$WORK_DIR/edited-prokop-config.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
pff_install_forkop
root="$PFF_ROOT"
pff_materialize_prokop_backend
printf '%s\n' 2.0.0 >"$FAKE_PKG_DIR/installed/prokop"
printf '%s\n' "config settings 'settings'" "	option edited_by_user '1'" >"$root/etc/config/prokop"
cp "$root/etc/config/prokop" "$PFF_WORK/edited-config"
mkdir -p "$root/etc/prokop"
printf '%s\n' 'prokop variant' >"$root/etc/prokop/sing-box-variant"

FAKE_VALIDATION_FAILS=1
if pff_run_installer; then
    pff_fail "the validation failure must stop the switch"
fi
pff_installed prokop || pff_fail "a Prokop installed before the switch must stay installed"
cmp -s "$root/etc/config/prokop" "$PFF_WORK/edited-config" ||
    pff_fail "the rollback must bring the edited Prokop configuration back"
[ "$(cat "$root/etc/prokop/sing-box-variant")" = 'prokop variant' ] ||
    pff_fail "existing Prokop state must never be replaced by the copy"
pff_assert_absent "$root/etc/prokop/tailscale" "copied data must go with the rollback"
pff_assert_exists "$root/etc/prokop/sing-box-variant" "Prokop state that existed must stay"
pff_assert_absent "$root/etc/prokop/.migrating-from-forkop"

FAKE_VALIDATION_FAILS=0
pff_run_installer || pff_fail "the switch must complete next to an edited Prokop configuration"
cmp -s "$root/etc/config/prokop" "$PFF_WORK/edited-config" ||
    pff_fail "an edited Prokop configuration must never be replaced"
pff_refute_event 'migrate vless://forkop-migration-test' 'the kept configuration is not migrated again'
pff_assert_log 'Измененная конфигурация Prokop сохранена как есть' 'the kept configuration must be reported'
pff_assert_exists "$root/etc/prokop-forkop-migration/legacy.config" \
    "the Forkop configuration must stay in the backup when it was not migrated"
[ "$(stat -c %a "$root/etc/prokop-forkop-migration/legacy.config")" = 600 ] ||
    pff_fail "the backups must be readable by root only"
[ "$(stat -c %a "$root/etc/prokop-forkop-migration")" = 700 ] ||
    pff_fail "the backup directory must be private"
pff_assert_exists "$root/etc/prokop/tailscale/node/node.key" "missing Prokop state must still be copied"
if pff_installed forkop; then pff_fail "forkop must be removed"; fi
SCENARIO

run_scenario validation-failure
run_scenario migration-failure
run_scenario needs-confirmation
run_scenario edited-prokop-config

printf 'Prokop from Forkop installer rollback tests passed\n'
