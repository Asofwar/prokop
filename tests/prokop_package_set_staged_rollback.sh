#!/bin/sh
set -eu

# The in-app upgrade stages the previous release before it installs the new
# one, so that a half-installed package set can be rolled back (1.0.27). The
# rollback has to find those archives on both package managers (UC-195).
#
# Before: the previous release was always staged as backend.ipk, app.ipk and
# i18n.ipk, while the recovery looked for backend.apk, app.apk and i18n.apk
# on apk systems (OpenWrt 25.12). It answered "recovery archive is missing;
# manual recovery required" with the archives on disk, Prokop stayed
# half-installed and stopped, and every later upgrade repeated the error.
# Now the staged names come from the same place as the names the recovery
# looks for, and the recovery also takes the *.ipk names that a release
# before the fix staged on apk.
#
# The upgrade runs end to end (tests/helpers/prokop_upgrade_harness.sh).

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/prokop_upgrade_harness.sh
. "$ROOT_DIR/tests/helpers/prokop_upgrade_harness.sh"

fail() {
    printf 'prokop_package_set_staged_rollback: FAIL: %s\n' "$1" >&2
    upgrade_harness_dump
    exit 1
}

# The rollback puts back the Prokop that ran before the upgrade and awaits
# its start (start-and-wait, UC-013): one start, and no other start after it.
rollback_started_prokop() {
    grep -Fxq 'start-and-wait start' "$UPGRADE_STATE/initd.log" &&
        [ "$(grep -c '^start' "$UPGRADE_STATE/init.log")" -eq 1 ]
}

previous_set_installed() {
    [ "$(upgrade_harness_version prokop)" = 1.0.0-r1 ] &&
        [ "$(upgrade_harness_version luci-app-prokop)" = 1.0.0-r1 ] &&
        [ "$(upgrade_harness_version luci-i18n-prokop-ru)" = 1.0.0-r1 ]
}

# The router's package manager is the stand-in, also when the host has one:
# a host apk on PATH must neither turn an opkg run into an apk run nor be
# called at all.
mkdir -p "$WORK_DIR/host-bin"
cat >"$WORK_DIR/host-bin/apk" <<'SH'
#!/bin/sh
printf 'apk %s\n' "$*" >>"${0%/*}/called"
exit 1
SH
chmod +x "$WORK_DIR/host-bin/apk"
PATH="$WORK_DIR/host-bin:$PATH"

upgrade_harness_setup

# --- apk: the new set fails half-way and the previous release is restored --

# apk installs the LuCI packages of the transaction, then fails on the
# backend: the set is mixed.
upgrade_harness_reset apk
upgrade_harness_flag fail_new_prokop
upgrade_harness_run && fail "apk: a failed package set was reported as installed"
case "$(upgrade_harness_message)" in
    *"previous release restored"*) ;;
    *) fail "apk: the half-installed set was not rolled back: $(upgrade_harness_message)" ;;
esac
previous_set_installed || fail "apk: the previous release is not installed again after the rollback"
upgrade_harness_running || fail "apk: Prokop does not run again after the rollback"
rollback_started_prokop || fail "apk: the rollback did not start Prokop with start-and-wait"
[ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "apk: the completed rollback left its recovery state behind"
grep -Eq '^apk add .*--force-reinstall .*/backend\.apk' "$UPGRADE_STATE/pm.log" ||
    fail "apk: the previous release was not staged and restored as .apk archives"

# --- opkg: the same rollback --------------------------------------------------

# opkg installs the backend first, then fails on the LuCI app.
upgrade_harness_reset opkg
upgrade_harness_flag fail_new_luci-app-prokop
upgrade_harness_run && fail "opkg: a failed package set was reported as installed"
case "$(upgrade_harness_message)" in
    *"previous release restored"*) ;;
    *) fail "opkg: the half-installed set was not rolled back: $(upgrade_harness_message)" ;;
esac
previous_set_installed || fail "opkg: the previous release is not installed again after the rollback"
upgrade_harness_running || fail "opkg: Prokop does not run again after the rollback"
rollback_started_prokop || fail "opkg: the rollback did not start Prokop with start-and-wait"
[ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "opkg: the completed rollback left its recovery state behind"
grep -Eq '^opkg install .*--force-reinstall .*/backend\.ipk' "$UPGRADE_STATE/pm.log" ||
    fail "opkg: the previous release was not staged and restored as .ipk archives"

# --- apk: a rollback left pending by a release that staged *.ipk ------------

# An earlier upgrade on apk failed half-way and its rollback did not finish.
# Its archives carry the .ipk names; the next upgrade recovers from them.
upgrade_harness_reset apk
mkdir -p "$UPGRADE_RECOVERY_DIR"
for archive in backend:prokop app:luci-app-prokop i18n:luci-i18n-prokop-ru; do
    printf 'name=%s\nversion=1.0.0-r1\n' "${archive#*:}" >"$UPGRADE_RECOVERY_DIR/${archive%%:*}.ipk"
done
printf '1.0.0\t1.1.0\t1\t1\n' >"$UPGRADE_RECOVERY_DIR/pending"
printf '1.1.0-r1\n' >"$UPGRADE_STATE/pkg/luci-app-prokop"
printf '1.1.0-r1\n' >"$UPGRADE_STATE/pkg/luci-i18n-prokop-ru"
rm -f "$UPGRADE_STATE/running"
upgrade_harness_run || fail "apk: the pending rollback from .ipk archives failed: $(upgrade_harness_message)"
case "$(upgrade_harness_message)" in
    *"recovery completed"*) ;;
    *) fail "apk: the pending rollback was not completed: $(upgrade_harness_message)" ;;
esac
previous_set_installed || fail "apk: the pending rollback did not restore the previous release"
upgrade_harness_running || fail "apk: the pending rollback did not start the Prokop that ran before the upgrade"
[ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "apk: the completed rollback left its recovery state behind"

# --- the upgrade completes ----------------------------------------------------

# The LuCI caches and rpcd are the router's: the harness records their
# refresh instead of touching the host's.
for pm in apk opkg; do
    upgrade_harness_reset "$pm"
    upgrade_harness_run || fail "$pm: the upgrade failed: $(upgrade_harness_message)"
    [ "$(upgrade_harness_version prokop)" = 1.1.0-r1 ] || fail "$pm: the new release is not installed"
    [ -s "$UPGRADE_STATE/luci-refresh.log" ] || fail "$pm: the LuCI refresh after the upgrade was not the harness's"
done

[ ! -e "$WORK_DIR/host-bin/called" ] || {
    sed 's/^/  host: /' "$WORK_DIR/host-bin/called" >&2
    fail "the host's package manager was called"
}

printf 'prokop_package_set_staged_rollback: PASS\n'
