#!/bin/sh
set -eu

# The user's Stop during the in-app Prokop upgrade holds (D-15).
#
# The upgrade notes whether Prokop runs when the action begins, prepares the
# new set while Prokop still runs (the GitHub metadata of the installed
# release, three staged downloads, two dry runs: minutes on a slow link), and
# only then stops Prokop for the install. Meanwhile the UI and the CLI still
# offer Stop. Prokop's own stop keeps that stop the user's
# (service/initd.uc stop_request_source), but every start that follows the
# upgrade went by the state noted at the action's start: the restart after a
# failed upgrade, the start with which the rollback puts back the service and
# the final start of a completed upgrade each started Prokop again and
# removed the user's stop. Now none of them starts a Prokop that the user
# stopped during the action, on apk and on opkg.
#
# The upgrade runs end to end (tests/helpers/prokop_upgrade_harness.sh).

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/prokop_upgrade_harness.sh
. "$ROOT_DIR/tests/helpers/prokop_upgrade_harness.sh"

fail() {
    printf 'prokop_upgrade_user_stop: FAIL: %s\n' "$1" >&2
    upgrade_harness_dump
    exit 1
}

expect_message() {
    case "$(upgrade_harness_message)" in
        *"$2"*) ;;
        *) fail "$1: unexpected result: $(upgrade_harness_message)" ;;
    esac
}

set_installed() {
    [ "$(upgrade_harness_version prokop)" = "$1" ] &&
        [ "$(upgrade_harness_version luci-app-prokop)" = "$1" ] &&
        [ "$(upgrade_harness_version luci-i18n-prokop-ru)" = "$1" ]
}

# The user stopped Prokop while the upgrade prepared; it stays stopped, and
# the stop is still the user's.
expect_user_stop_kept() {
    grep -Fxq 'stop source=' "$UPGRADE_STATE/init.log" ||
        fail "$1: the user's stop did not happen during the upgrade"
    if grep -Eq '^(start|restart)' "$UPGRADE_STATE/init.log" ||
        grep -q '^start-and-wait' "$UPGRADE_STATE/initd.log"; then
        fail "$1: Prokop was started again after the user stopped it"
    fi
    ! upgrade_harness_running || fail "$1: Prokop runs after the user stopped it"
    grep -Fxq 'by=user' "$UPGRADE_STATE/run/stop.requested" 2>/dev/null ||
        fail "$1: the user's stop is no longer recorded"
    [ ! -e "$UPGRADE_MARKER" ] || fail "$1: the upgrade left its managed upgrade marker behind"
}

upgrade_harness_setup

for pm in apk opkg; do
    # --- the upgrade fails after its own stop ------------------------------
    upgrade_harness_reset "$pm"
    upgrade_harness_flag user_stop_on_github
    upgrade_harness_flag sing_box_ambiguous
    case="$pm failed upgrade"
    upgrade_harness_run && fail "$case: the failed upgrade was reported as installed"
    expect_message "$case" "Old sing-box processes"
    expect_user_stop_kept "$case"
    set_installed 1.0.0-r1 || fail "$case: the installed release changed"

    # --- the install fails and the rollback restores the previous release ---
    upgrade_harness_reset "$pm"
    upgrade_harness_flag user_stop_on_github
    if [ "$pm" = apk ]; then
        upgrade_harness_flag fail_new_prokop
    else
        upgrade_harness_flag fail_new_luci-app-prokop
    fi
    case="$pm rollback"
    upgrade_harness_run && fail "$case: the failed upgrade was reported as installed"
    expect_message "$case" "previous release restored"
    expect_user_stop_kept "$case"
    set_installed 1.0.0-r1 || fail "$case: the previous release is not installed again"
    [ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "$case: the completed rollback left its recovery state behind"

    # --- the upgrade completes ---------------------------------------------
    upgrade_harness_reset "$pm"
    upgrade_harness_flag user_stop_on_github
    case="$pm upgrade"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    expect_user_stop_kept "$case"
    set_installed 1.1.0-r1 || fail "$case: the new release is not installed"
    [ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "$case: the upgrade left its staging behind"
done

printf 'prokop_upgrade_user_stop: PASS\n'
