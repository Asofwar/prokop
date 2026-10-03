#!/usr/bin/env bash
set -euo pipefail

# Which routers take the switch from Forkop, and that the others do not:
#  * a router that never had Forkop is not touched by any of its steps, as a
#    clean installation or as a Prokop update, also with the
#    *.pre-forkop-mirror files any mirror opt-in leaves;
#  * the podkop-plus migration keeps its own mode; Forkop goes first when
#    both are present (priority: interrupted switch, Forkop, podkop-plus,
#    update, clean);
#  * Forkop leftovers without its packages (configuration only) are switched
#    and cleaned up as well, its rc.d links by their exact names; next to an
#    installed Prokop a left configuration is only reported (a Prokop
#    update);
#  * the switch never uses the recursive name scan of the podkop-plus
#    cleanup.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v dash >/dev/null 2>&1 ||
  fail "dash is required: the installer runs under BusyBox ash on the router"

# shellcheck source=tests/helpers/source_checks.sh
source "$ROOT_DIR/tests/helpers/source_checks.sh"

run_scenario() {
  mkdir -p "$WORK_DIR/$1"
  PFF_REPO="$ROOT_DIR" PFF_WORK="$WORK_DIR/$1" dash "$WORK_DIR/$1.sh" ||
    fail "scenario $1 failed"
}

# The switch removes explicit paths only.
shell_switch="$(awk '
  /^legacy_forkop_[a-z_]*\(\) \{$/ { copy = 1 }
  copy { print }
  copy && /^}$/ { copy = 0 }
' "$INSTALLER")"
ucode_switch="$(awk '
  /^function (legacy_forkop_[a-z_]*|installer_hold_prokop)\(/ { copy = 1 }
  copy { print }
  copy && /^}$/ { copy = 0 }
' "$INSTALLER")"
[ "$(printf '%s\n' "$shell_switch" | grep -c '^legacy_forkop_[a-z_]*() {$')" -ge 20 ] ||
  fail "the shell functions of the switch were not found"
[ "$(printf '%s\n' "$ucode_switch" | grep -c '^function ')" -ge 8 ] ||
  fail "the ucode functions of the switch were not found"
for region in "$shell_switch" "$ucode_switch"; do
  source_refute_text "the switch must not use the recursive name scan of the podkop-plus cleanup" -E \
    'remove_legacy_named_children|installer[-_]finalize[-_]legacy|installer[-_]cleanup[-_]legacy|LEGACY_SCAN_ROOTS|lsdir' \
    "$region"
done

# Detection and the switch run before the podkop-plus detection and before
# the ordinary installation path.
awk '
  /^main\(\) \{$/ { in_main = 1 }
  in_main && /legacy_forkop_detect_installation/ && !forkop_detect { forkop_detect = NR }
  in_main && /detect_legacy_installation/ && !podkop_detect { podkop_detect = NR }
  in_main && /detect_install_mode/ && !mode { mode = NR }
  in_main && /if legacy_forkop_mode; then/ && !branch { branch = NR }
  in_main && /legacy_forkop_migrate/ && !migrate { migrate = NR }
  in_main && /resolve_prokop_release/ && !resolve { resolve = NR }
  in_main && /^}$/ { in_main = 0 }
  END {
    exit !(forkop_detect && podkop_detect > forkop_detect && mode > podkop_detect &&
      branch > mode && migrate > branch && resolve > migrate)
  }
' "$INSTALLER" || fail "main must detect and switch from Forkop before the podkop-plus and ordinary paths"
detect_mode="$(source_function "$INSTALLER" detect_install_mode)" || exit 1
printf '%s\n' "$detect_mode" | awk '
  /LEGACY_FORKOP_RESUME_STAGE/ && !resume { resume = NR }
  /LEGACY_FORKOP_DETECTED/ && !forkop { forkop = NR }
  /PROKOP_LEGACY_DETECTED/ && !podkop { podkop = NR }
  /pkg_is_installed "prokop"/ && !update { update = NR }
  END { exit !(resume && forkop > resume && podkop > forkop && update > podkop) }
' || fail "the installation modes must be chosen: interrupted switch, Forkop, podkop-plus, update, clean"

cat >"$WORK_DIR/common.sh" <<'SCENARIO'
root_digest() {
    (
        cd "$PFF_ROOT" || exit 1
        find . -print | LC_ALL=C sort | while IFS= read -r path; do
            if [ -f "$path" ]; then printf '%s %s\n' "$path" "$(cksum <"$path")"; else printf '%s\n' "$path"; fi
        done
        cat "$FAKE_UCI_STATE"
        ls "$FAKE_NFT_DIR" "$FAKE_PKG_DIR/installed"
    )
}

assert_untouched() {
    [ "$1" = "$(root_digest)" ] || pff_fail "a router without Forkop was changed"
    [ "$(grep -cv '^--- run ' "$PFF_EVENTS")" -eq 0 ] || pff_fail "a router without Forkop ran Forkop steps"
    [ ! -s "$PFF_NFT_LOG" ] || pff_fail "a router without Forkop had nftables touched"
    [ ! -s "$FAKE_UCI_LOG" ] || pff_fail "a router without Forkop had UCI committed"
}
SCENARIO

cat >"$WORK_DIR/no-forkop.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
. "$PFF_WORK/../common.sh"
pff_setup opkg
before="$(root_digest)"
pff_run_installer || pff_fail "detection failed on a clean router"
pff_assert_log 'NOT MIGRATED: mode clean' 'a router without Forkop is a clean installation'
assert_untouched "$before"

# A Prokop update, with an interface package, is not a switch either.
mkdir -p "$PFF_ROOT/etc/prokop"
printf '%s\n' "config settings 'settings'" >"$PFF_ROOT/etc/config/prokop"
printf '%s\n' 1.0.26 >"$FAKE_PKG_DIR/installed/prokop"
printf '%s\n' 1.0.26 >"$FAKE_PKG_DIR/installed/luci-app-prokop"
before="$(root_digest)"
pff_run_installer || pff_fail "detection failed on a Prokop router"
pff_assert_log 'NOT MIGRATED: mode update' 'an installed Prokop is an update'
assert_untouched "$before"
SCENARIO

cat >"$WORK_DIR/podkop-plus.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
. "$PFF_WORK/../common.sh"
pff_setup apk
plus_package="$(printf '\160\157\144\153\157\160')-plus"
printf '%s\n' 0.7.0 >"$FAKE_PKG_DIR/installed/$plus_package"
before="$(root_digest)"
pff_run_installer || pff_fail "detection failed on a podkop-plus router"
pff_assert_log 'NOT MIGRATED: mode legacy' 'podkop-plus keeps its own migration'
assert_untouched "$before"

# Both installed: Forkop goes first, podkop-plus is left to a later run.
PFF_I18N=0 pff_install_forkop
modes="$(
    legacy_forkop_detect_installation >/dev/null
    detect_legacy_installation >/dev/null
    detect_install_mode >/dev/null
    printf '%s %s %s\n' "$INSTALL_MODE" "$LEGACY_FORKOP_DETECTED" "$PROKOP_LEGACY_DETECTED"
)"
[ "$modes" = 'legacy_forkop 1 0' ] || pff_fail "Forkop must go first when podkop-plus is installed too: $modes"
pff_run_installer || pff_fail "the switch from Forkop next to podkop-plus failed"
pff_installed "$plus_package" || pff_fail "the switch from Forkop must leave podkop-plus to its own migration"
if pff_installed forkop; then pff_fail "forkop must be removed"; fi
pff_run_installer || pff_fail "the run after the switch failed"
pff_assert_log 'NOT MIGRATED: mode legacy' 'podkop-plus is migrated by the next run'
SCENARIO

cat >"$WORK_DIR/config-only.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
PFF_I18N=0 PFF_KILLSWITCH=0 pff_install_forkop
root="$PFF_ROOT"
# The packages are gone; their configuration, state and runtime are left.
rm -f "$FAKE_PKG_DIR/installed/forkop" "$FAKE_PKG_DIR/installed/luci-app-forkop"
rm -rf "$root/etc/init.d/forkop" "$root/etc/init.d/forkop-killswitch" "$root/etc/init.d/forkop-torrserver-direct" \
    "$root/usr/bin/forkop" "$root/usr/lib/forkop"
# rc.d links of its three services (START/STOP 99/-, 20/90, 100/9) and two
# that are not its own.
for link in S99forkop S20forkop-killswitch K90forkop-killswitch S100forkop-torrserver-direct \
    K9forkop-torrserver-direct; do
    [ -L "$root/etc/rc.d/$link" ] || ln -s ../init.d/removed "$root/etc/rc.d/$link"
done
ln -s ../init.d/forkopx "$root/etc/rc.d/S99forkopx"
ln -s ../init.d/prokop "$root/etc/rc.d/S50prokop"

pff_run_installer || pff_fail "Forkop leftovers must be switched as well"
pff_assert_log 'Installation mode: legacy_forkop'
pff_refute_event 'forkop stop' 'there is no old init script to stop'
for service in forkop forkop-killswitch forkop-torrserver-direct; do
    pff_assert_event "ubus call service delete {\"name\":\"$service\"}"
done
grep -Fxq 'nft delete table inet ForkopTable' "$PFF_NFT_LOG" || pff_fail "the left runtime table must go"
[ "$(pff_uci 'dnsmasq().server')" = 8.8.8.8 ] || pff_fail "dnsmasq must be restored without the old code"
grep -Fq "vless://forkop-migration-test" "$root/etc/config/prokop" || pff_fail "the left configuration must be migrated"
for path in etc/config/forkop etc/forkop etc/rc.d/S99forkop etc/rc.d/S20forkop-killswitch \
    etc/rc.d/K90forkop-killswitch etc/rc.d/S100forkop-torrserver-direct etc/rc.d/K9forkop-torrserver-direct \
    www/luci-static/resources/view/forkop; do
    pff_assert_absent "$root/$path" "the leftovers must be cleaned up"
done
pff_assert_exists "$root/etc/rc.d/S99forkopx" "an rc.d link of another service must stay"
pff_assert_exists "$root/etc/rc.d/S50prokop" "an rc.d link of another service must stay"
grep -Fq '# forkop-' "$root/etc/crontabs/root" && pff_fail "the left cron jobs must go"
pff_refute_event 'prokop start' 'without a Forkop service Prokop is not started'
SCENARIO

# Only the configuration is left and Prokop is not installed: it is imported.
cat >"$WORK_DIR/config-file-only.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup apk
root="$PFF_ROOT"
printf '%s\n' "config section 'main'" "	list selector_proxy_links 'vless://forkop-leftover'" \
    >"$root/etc/config/forkop"

pff_run_installer || pff_fail "a left Forkop configuration must be switched without Prokop"
pff_assert_log 'Installation mode: legacy_forkop'
grep -Fq "vless://forkop-leftover" "$root/etc/config/prokop" || pff_fail "the left configuration must be imported"
pff_assert_absent "$root/etc/config/forkop" "the imported configuration must be cleaned up"
pff_installed prokop || pff_fail "Prokop must be installed"
SCENARIO

# Prokop was installed and started outside the installer; Forkop is gone and
# left only its configuration (and dnsmasq backups). That is a Prokop update:
# the 127.0.0.42 dnsmasq forwards to and the running service are Prokop's.
cat >"$WORK_DIR/config-left-next-to-prokop.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
. "$PFF_WORK/../common.sh"
pff_setup opkg
root="$PFF_ROOT"
pff_materialize_prokop_backend
printf '%s\n' 2.0.0 >"$FAKE_PKG_DIR/installed/prokop"
printf '%s\n' 2.0.0 >"$FAKE_PKG_DIR/installed/luci-app-prokop"
ln -s ../init.d/prokop "$root/etc/rc.d/S99prokop"
: >"$FAKE_NFT_DIR/ProkopTable"
printf '%s\n' "config section 'main'" "	list selector_proxy_links 'vless://forkop-leftover'" \
    >"$root/etc/config/forkop"
"$PFF_REAL_UCODE" -e '
    let fs = require("fs");
    let s = json(fs.readfile(getenv("FAKE_UCI_STATE")));
    let d = s.dhcp.cfg01411c;
    d.prokop_server = d.server;
    d.forkop_server = [ "1.1.1.1" ];
    d.server = [ "127.0.0.42" ];
    d.noresolv = "1";
    fs.writefile(getenv("FAKE_UCI_STATE"), sprintf("%.2J\n", s));
' || pff_fail "failed to write the dnsmasq fixture"
before="$(root_digest)"

pff_run_installer || pff_fail "detection failed next to an installed Prokop"
pff_assert_log 'NOT MIGRATED: mode update' 'a left Forkop configuration next to Prokop is a Prokop update'
pff_assert_log "$root/etc/config/forkop is left over from Forkop, which is not installed" \
    'the left configuration must be reported'
assert_untouched "$before"
pff_assert_exists "$root/etc/config/forkop" "the left configuration must stay"
SCENARIO

run_scenario no-forkop
run_scenario podkop-plus
run_scenario config-only
run_scenario config-file-only
run_scenario config-left-next-to-prokop

printf 'Prokop from Forkop installer detection tests passed\n'
