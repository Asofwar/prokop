#!/bin/sh
set -eu

# The in-app Forkop upgrade refuses before it stops Forkop, and a failure
# after its stop brings the Forkop that was running back (UC-196, UC-027).
#
# Before: the upgrade stopped Forkop first and only then checked what 1.0.27
# added on both package managers: the metadata of the installed release on
# GitHub, the staging of its packages, the package manager's dry run and the
# free space (and that the installed set is consistent). Any of these
# refusals, and the stop of the old sing-box failing, left the router without
# Forkop: nothing started it again. Now every refusal comes before the stop,
# a refused stop (another sing-box makes the ownership of the runtime
# ambiguous) changes nothing, and a failure after the stop starts the Forkop
# that ran before with start-and-wait (UC-013).
#
# Each stop on the way is Forkop's own for the upgrade, never recorded as the
# user's (D-15): also the stop with which the rollback puts back a Forkop
# that was not running before the upgrade.
#
# The upgrade runs end to end (tests/helpers/forkop_upgrade_harness.sh).

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/forkop_upgrade_harness.sh
. "$ROOT_DIR/tests/helpers/forkop_upgrade_harness.sh"

fail() {
    printf 'forkop_upgrade_refusal_restart: FAIL: %s\n' "$1" >&2
    upgrade_harness_dump
    exit 1
}

set_installed() {
    [ "$(upgrade_harness_version forkop)" = "$1" ] &&
        [ "$(upgrade_harness_version luci-app-forkop)" = "$1" ] &&
        [ "$(upgrade_harness_version luci-i18n-forkop-ru)" = "$1" ]
}

expect_message() {
    case "$(upgrade_harness_message)" in
        *"$2"*) ;;
        *) fail "$1: unexpected result: $(upgrade_harness_message)" ;;
    esac
}

# No stop on the way is the user's: init.d records it with its source.
expect_no_user_stop() {
    ! grep -Eq '^stop source=(user)?$' "$UPGRADE_STATE/init.log" ||
        fail "$1: Forkop was stopped as if by the user"
}

packages_installed() {
    grep -Ev '^(apk add .*--simulate|opkg --noaction)' "$UPGRADE_STATE/pm.log" |
        grep -Eq '^(apk add|opkg install)'
}

# The packages of the installed release are in place, and nothing installed
# any.
untouched() {
    set_installed 1.0.0-r1 || fail "$1: the installed release changed"
    ! packages_installed || fail "$1: packages were installed"
}

upgrade_harness_setup

for pm in apk opkg; do
    # --- refusals: Forkop is never stopped ---------------------------------
    for refusal in github_down download_fail_1.0.0 preflight_fail df_avail inconsistent; do
        upgrade_harness_reset "$pm"
        case "$refusal" in
            # The channel cannot name the installed release (components/action.uc
            # unpublished_forkop_release_error); the upgrade is refused all the same.
            github_down) expected="cannot be staged for rollback; automatic upgrade refused" ;;
            download_fail_1.0.0) expected="Failed to stage previous Forkop release packages" ;;
            preflight_fail) expected="preflight failed" ;;
            df_avail) expected="Not enough free space" ;;
            inconsistent) expected="Installed Forkop package versions are inconsistent" ;;
        esac
        case "$refusal" in
            df_avail) upgrade_harness_flag df_avail 100 ;;
            inconsistent) printf '0.9.0-r1\n' >"$UPGRADE_STATE/pkg/luci-app-forkop" ;;
            *) upgrade_harness_flag "$refusal" ;;
        esac
        case="$pm $refusal"
        upgrade_harness_run && fail "$case: the refused upgrade was reported as installed"
        expect_message "$case" "$expected"
        ! grep -q '^stop' "$UPGRADE_STATE/init.log" || fail "$case: Forkop was stopped before the upgrade refused"
        upgrade_harness_running || fail "$case: Forkop does not run after the refused upgrade"
        ! packages_installed || fail "$case: the refused upgrade installed packages"
        [ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "$case: the refused upgrade left its staging behind"
        [ ! -e "$UPGRADE_MARKER" ] || fail "$case: the refused upgrade left its managed upgrade marker behind"
    done

    # --- Forkop goes down while the upgrade prepares, which then refuses ---
    # The upgrade never stopped it: its refusal does not start it either.
    upgrade_harness_reset "$pm"
    upgrade_harness_flag crash_on_github
    upgrade_harness_flag github_down
    case="$pm down before refusal"
    upgrade_harness_run && fail "$case: the refused upgrade was reported as installed"
    expect_message "$case" "cannot be staged for rollback; automatic upgrade refused"
    if grep -Eq '^(start|restart)' "$UPGRADE_STATE/init.log" ||
        grep -q '^start-and-wait' "$UPGRADE_STATE/initd.log"; then
        fail "$case: the refused upgrade started the Forkop it never stopped"
    fi
    untouched "$case"

    # --- the stop of the old sing-box fails after Forkop was stopped -------
    upgrade_harness_reset "$pm"
    upgrade_harness_flag sing_box_ambiguous
    case="$pm old sing-box"
    upgrade_harness_run && fail "$case: the failed upgrade was reported as installed"
    expect_message "$case" "Old sing-box processes have ambiguous ownership or did not stop"
    grep -Fxq 'stop source=component' "$UPGRADE_STATE/init.log" ||
        fail "$case: Forkop was not stopped for the upgrade as its own change"
    grep -Fxq 'start-and-wait start' "$UPGRADE_STATE/initd.log" ||
        fail "$case: Forkop was not started again with start-and-wait"
    upgrade_harness_running || fail "$case: Forkop does not run after the failed upgrade"
    expect_no_user_stop "$case"
    untouched "$case"
    [ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "$case: the failed upgrade left its staging behind"
    [ ! -e "$UPGRADE_MARKER" ] || fail "$case: the failed upgrade left its managed upgrade marker behind"

    # --- Forkop's stop for the upgrade is refused --------------------------
    # Another sing-box makes the ownership of the runtime ambiguous: Forkop
    # runs on untouched, so the upgrade must not go on, and its failure must
    # not start the Forkop it never stopped.
    upgrade_harness_reset "$pm"
    upgrade_harness_flag stop_status 2
    case="$pm refused stop"
    upgrade_harness_run && fail "$case: the upgrade went on after Forkop's stop was refused"
    expect_message "$case" "Forkop was not stopped: another sing-box process makes the ownership of its runtime ambiguous"
    upgrade_harness_running || fail "$case: Forkop does not run after its refused stop"
    if grep -Eq '^(start|restart)' "$UPGRADE_STATE/init.log" ||
        grep -q '^start-and-wait' "$UPGRADE_STATE/initd.log"; then
        fail "$case: the Forkop that was never stopped was started again"
    fi
    untouched "$case"
    [ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "$case: the failed upgrade left its staging behind"
    [ ! -e "$UPGRADE_MARKER" ] || fail "$case: the failed upgrade left its managed upgrade marker behind"

    # --- the install and its rollback fail ---------------------------------
    # The half-installed set keeps its archives for the next attempt; the
    # Forkop that ran before the upgrade is started again meanwhile. The
    # package manager ran longer than the upgrade marker's age: the marker
    # names no transition any more and must not refuse that start (UC-217).
    upgrade_harness_reset "$pm"
    if [ "$pm" = apk ]; then
        upgrade_harness_flag fail_new_forkop
    else
        upgrade_harness_flag fail_new_luci-app-forkop
    fi
    upgrade_harness_flag fail_old_luci-app-forkop
    upgrade_harness_flag fail_old_forkop
    upgrade_harness_flag marker_stale
    case="$pm failed rollback"
    upgrade_harness_run && fail "$case: the failed upgrade was reported as installed"
    expect_message "$case" "recovery archives retained"
    grep -Fxq 'start-and-wait start' "$UPGRADE_STATE/initd.log" ||
        fail "$case: Forkop was not started again with start-and-wait"
    ! grep -q '^start refused' "$UPGRADE_STATE/init.log" ||
        fail "$case: the stale upgrade marker refused the start"
    upgrade_harness_running || fail "$case: Forkop does not run after the failed upgrade"
    expect_no_user_stop "$case"
    [ -s "$UPGRADE_RECOVERY_DIR/pending" ] || fail "$case: the pending rollback was dropped"

    # The next Update click runs the pending rollback first. Restoring the
    # backend runs its prerm, which stops Forkop for the package; when the
    # rollback fails again, the Forkop that was running when this action
    # began is started again as well.
    : >"$UPGRADE_STATE/init.log"
    : >"$UPGRADE_STATE/initd.log"
    case="$pm failed pending rollback"
    upgrade_harness_run && fail "$case: the failed rollback was reported as completed"
    expect_message "$case" "recovery archives retained"
    grep -Fxq 'stop source=package' "$UPGRADE_STATE/init.log" ||
        fail "$case: the rollback did not stop Forkop for the package"
    grep -Fxq 'start-and-wait start' "$UPGRADE_STATE/initd.log" ||
        fail "$case: Forkop was not started again with start-and-wait"
    upgrade_harness_running || fail "$case: Forkop does not run after the failed pending rollback"
    expect_no_user_stop "$case"
    [ -s "$UPGRADE_RECOVERY_DIR/pending" ] || fail "$case: the pending rollback was dropped"

    # Once the rollback can complete, it does, and Forkop runs on.
    upgrade_harness_unflag fail_old_luci-app-forkop
    upgrade_harness_unflag fail_old_forkop
    case="$pm completed pending rollback"
    upgrade_harness_run || fail "$case: the pending rollback failed: $(upgrade_harness_message)"
    expect_message "$case" "recovery completed"
    set_installed 1.0.0-r1 || fail "$case: the previous release is not installed again"
    upgrade_harness_running || fail "$case: Forkop does not run after the completed rollback"
    expect_no_user_stop "$case"
    [ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "$case: the completed rollback left its recovery state behind"

    # --- a successful upgrade ----------------------------------------------
    upgrade_harness_reset "$pm"
    case="$pm upgrade"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    set_installed 1.1.0-r1 || fail "$case: the new release is not installed"
    upgrade_harness_running || fail "$case: Forkop does not run after the upgrade"
    expect_no_user_stop "$case"
    [ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "$case: the upgrade left its staging behind"
    [ ! -e "$UPGRADE_MARKER" ] || fail "$case: the upgrade left its managed upgrade marker behind"

    # The package manager ran longer than the upgrade marker's age (a slow
    # router, the mirror migration's downloads). The old sing-box was proven
    # gone before the package step: the marker names no transition any more
    # and must not refuse the start of the new release, which would report
    # the installed upgrade as failed (UC-217, UC-027).
    upgrade_harness_reset "$pm"
    upgrade_harness_flag marker_stale
    case="$pm slow upgrade"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    expect_message "$case" "Forkop has been installed"
    set_installed 1.1.0-r1 || fail "$case: the new release is not installed"
    ! grep -q '^start refused' "$UPGRADE_STATE/init.log" ||
        fail "$case: the stale upgrade marker refused the start of the new release"
    [ "$(grep -c '^start' "$UPGRADE_STATE/init.log")" -eq 1 ] || fail "$case: the new release was started more than once"
    upgrade_harness_running || fail "$case: Forkop does not run after the upgrade"
    expect_no_user_stop "$case"
    [ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "$case: the upgrade left its staging behind"
    [ ! -e "$UPGRADE_MARKER" ] || fail "$case: the upgrade left its managed upgrade marker behind"
done

# --- the rollback stops a Forkop that was not running before ----------------
# The package scripts start Forkop during the upgrade and its rollback; the
# rollback then puts back the stopped state, with Forkop's own stop.
upgrade_harness_reset opkg
rm -f "$UPGRADE_STATE/running"
upgrade_harness_flag postinst_starts
upgrade_harness_flag fail_new_luci-app-forkop
case="opkg rollback of a stopped Forkop"
upgrade_harness_run && fail "$case: the failed upgrade was reported as installed"
expect_message "$case" "previous release restored"
set_installed 1.0.0-r1 || fail "$case: the previous release is not installed again"
! upgrade_harness_running || fail "$case: the rollback left running a Forkop that was stopped before the upgrade"
expect_no_user_stop "$case"

printf 'forkop_upgrade_refusal_restart: PASS\n'
