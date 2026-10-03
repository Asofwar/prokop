#!/bin/sh
set -eu

# A component change never starts a Prokop that the user stopped while the
# change ran (D-15(a), UC-235).
#
# A component action notes whether Prokop runs when it begins and puts that
# state back once the change is done. Meanwhile the UI and the CLI still
# offer Stop. Before, every start after the change went by the noted state:
# the restart after a provider package was installed or removed, the restart
# and the wait after a sing-box variant change, the start (and its restart
# fallback) after a failed sing-box change and the restart with the previous
# Direct Proxy settings each started Prokop again and removed the user's
# stop. A restart that the user's stop overtook was also reported as a
# failed start, which rolled the change back; a start of the new release
# that it overtook failed the upgrade and kept its recovery set. Now the
# user's stop holds on every path: nothing starts Prokop again, the change
# stands, and the action does not fail for the start the user cancelled.
# Prokop's own stop for its restart is no stop by the user: a restart that
# fails before its start still fails the change.
#
# The actions run against the stand-ins of tests/helpers/prokop_upgrade_harness.sh:
# the provider removal and the Prokop upgrade end to end, the sing-box change
# and Direct Proxy through the production functions in a variant of the
# harness (the sing-box binaries and UCI of the host are not the router's).

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/prokop_upgrade_harness.sh
. "$ROOT_DIR/tests/helpers/prokop_upgrade_harness.sh"

fail() {
    printf 'component_change_user_stop: FAIL: %s\n' "$1" >&2
    upgrade_harness_dump
    exit 1
}

expect_message() {
    case "$(upgrade_harness_message)" in
        *"$2"*) ;;
        *) fail "$1: unexpected result: $(upgrade_harness_message)" ;;
    esac
}

# A start or restart of Prokop after the user's stop (a stop without a
# source, or the stop that overtook a start).
started_after_user_stop() {
    awk '/^stop source=$/ || /^start skipped: the user stopped Prokop$/ { stopped = 1; next }
        stopped && /^(start|restart) / { found = 1 }
        END { exit found ? 0 : 1 }' "$UPGRADE_STATE/init.log"
}

# Prokop's own restart after the change: COUNT stops of its own for the
# change (by=component; the sing-box change stops Prokop before it, too),
# then the awaited start.
restarted_after_change() {
    [ "$(grep -c '^stop source=component$' "$UPGRADE_STATE/init.log")" -eq "$1" ] &&
        grep -Fxq 'start-and-wait start' "$UPGRADE_STATE/initd.log" &&
        ! grep -q '^restart' "$UPGRADE_STATE/init.log"
}

# A failed restart is no stop by the user: Prokop's own stop for it is
# recorded as such (UC-235).
expect_own_stop_kept() {
    grep -Fxq 'by=component' "$UPGRADE_STATE/run/stop.requested" 2>/dev/null ||
        fail "$1: Prokop's own stop for the restart is not recorded as its own"
}

expect_user_stop_kept() {
    grep -Eq '^stop source=$|^start skipped: the user stopped Prokop$' "$UPGRADE_STATE/init.log" ||
        fail "$1: the user's stop did not happen during the change"
    ! started_after_user_stop || fail "$1: Prokop was started again after the user stopped it"
    ! upgrade_harness_running || fail "$1: Prokop runs after the user stopped it"
    grep -Fxq 'by=user' "$UPGRADE_STATE/run/stop.requested" 2>/dev/null ||
        fail "$1: the user's stop is no longer recorded"
}

upgrade_harness_setup

# The production functions with a scenario dispatch in place of the action's.
SCENARIO="$WORK_DIR/scenario.uc"
dispatch='component_action(ARGV[0], ARGV[1], ARGV[2]);'
grep -Fxq "$dispatch" "$UPGRADE_HARNESS" || fail "the harness dispatch line was not found"
grep -Fxv "$dispatch" "$UPGRADE_HARNESS" >"$SCENARIO"
cat >>"$SCENARIO" <<'UCODE'

// The user presses Stop (init.d stop without a stop source).
function user_stop_if_flagged() {
    if (file_exists(HARNESS_STATE + "/flags/user_stop_during_change"))
        system([ "env", "-u", "PROKOP_STOP_SOURCE", SERVICE_INIT, "stop" ]);
}

// UCI of the router, in memory: Direct Proxy is on at port 2080.
let harness_uci = { "prokop.settings.direct_proxy_enabled": "1", "prokop.settings.direct_proxy_port": "2080" };
uci_core = {
    available: function() { return true; },
    get: function(path) { return harness_uci[path]; },
    set: function(path, value) { harness_uci[path] = value; return true; },
    "delete": function(path) { delete harness_uci[path]; return true; },
    commit: function() { return true; }
};

capture_prokop_running_state();
let scenario = ARGV[0];
if (scenario == "sing-box-change") {
    // Prokop's own stop for the change, the new variant is in place, then
    // Prokop is put back and awaited (install_package_sing_box and the
    // extended variants).
    if (!stop_prokop_before_sing_box_change())
        action_fail("sing_box", "install", SING_BOX_CHANGE_STOP_REFUSED);
    user_stop_if_flagged();
    if (!restart_prokop_after_successful_change() || !wait_prokop_running_after_sing_box_change())
        action_fail("sing_box", "install", "sing-box was installed, but Prokop did not start cleanly");
    action_success("sing_box", "install", "sing-box has been installed");
}
else if (scenario == "sing-box-failure") {
    if (!stop_prokop_before_sing_box_change())
        action_fail("sing_box", "install", SING_BOX_CHANGE_STOP_REFUSED);
    user_stop_if_flagged();
    action_fail("sing_box", "install", "sing-box package installation failed; previous sing-box variant was restored");
}
else if (scenario == "direct-proxy") {
    set_direct_proxy("disable");
}
UCODE

# The waits of the sing-box change poll every 4 and 8 seconds; the scenarios
# do not wait for them. Every other sleep (the status probe's watchdog) is
# the real one.
mkdir -p "$WORK_DIR/fast-sleep"
real_sleep="$(command -v sleep)"
cat >"$WORK_DIR/fast-sleep/sleep" <<SH
#!/bin/sh
case "\$*" in
    4|8) exit 0 ;;
esac
exec "$real_sleep" "\$@"
SH
chmod +x "$WORK_DIR/fast-sleep/sleep"
UPGRADE_PATH="$WORK_DIR/fast-sleep:$UPGRADE_PATH"

scenario() {
    upgrade_harness_exec "$SCENARIO" "$@"
}

for pm in apk opkg; do
    # --- a provider package is removed --------------------------------------
    upgrade_harness_reset "$pm"
    printf '1.0-r1\n' >"$UPGRADE_STATE/pkg/zapret"
    case="$pm zapret removal"
    upgrade_harness_run zapret remove || fail "$case: the removal failed: $(upgrade_harness_message)"
    [ -z "$(upgrade_harness_version zapret)" ] || fail "$case: zapret was not removed"
    restarted_after_change 1 || fail "$case: Prokop was not restarted after the change"
    upgrade_harness_running || fail "$case: Prokop does not run after the change"

    # The restart's own stop fails (init.d exits before its start), or its
    # start is deferred past the wait: Prokop did not come back, and nobody
    # stopped it. The removal reports that.
    for flag in stop_status start_deferred; do
        upgrade_harness_reset "$pm"
        printf '1.0-r1\n' >"$UPGRADE_STATE/pkg/zapret"
        upgrade_harness_flag "$flag"
        case="$pm zapret removal, $flag"
        upgrade_harness_run zapret remove && fail "$case: the removal was reported as done"
        expect_message "$case" "zapret package has been removed, but Prokop did not start again"
        expect_own_stop_kept "$case"
    done

    # The user stops Prokop while the package is removed.
    upgrade_harness_reset "$pm"
    printf '1.0-r1\n' >"$UPGRADE_STATE/pkg/zapret"
    upgrade_harness_flag user_stop_on_remove
    case="$pm zapret removal, user stop"
    upgrade_harness_run zapret remove || fail "$case: the removal failed: $(upgrade_harness_message)"
    expect_message "$case" "zapret package has been removed"
    [ -z "$(upgrade_harness_version zapret)" ] || fail "$case: zapret was not removed"
    expect_user_stop_kept "$case"
    ! grep -q '^start-and-wait' "$UPGRADE_STATE/initd.log" ||
        fail "$case: a start was attempted after the user's stop"

    # The user's stop overtakes the restart after the removal: the stop wins,
    # and the removal is no failure.
    upgrade_harness_reset "$pm"
    printf '1.0-r1\n' >"$UPGRADE_STATE/pkg/byedpi"
    upgrade_harness_flag user_stop_on_start
    case="$pm ByeDPI removal, user stop overtakes the restart"
    upgrade_harness_run byedpi remove || fail "$case: the removal failed: $(upgrade_harness_message)"
    expect_message "$case" "ByeDPI package has been removed"
    expect_user_stop_kept "$case"
    [ "$(grep -c '^start-and-wait' "$UPGRADE_STATE/initd.log")" -eq 1 ] ||
        fail "$case: Prokop was started more than once"

    # --- the Prokop upgrade: the user stops Prokop during the install --------
    upgrade_harness_reset "$pm"
    upgrade_harness_flag user_stop_on_install
    case="$pm Prokop upgrade, user stop"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    [ "$(upgrade_harness_version prokop)" = 1.1.0-r1 ] || fail "$case: the new release is not installed"
    expect_user_stop_kept "$case"

    # The user's stop overtakes the start of the new release: the upgrade is
    # done, and its recovery set is no longer needed.
    upgrade_harness_reset "$pm"
    upgrade_harness_flag user_stop_on_start
    case="$pm Prokop upgrade, user stop overtakes the start"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    expect_message "$case" "Prokop has been installed"
    [ "$(upgrade_harness_version prokop)" = 1.1.0-r1 ] || fail "$case: the new release is not installed"
    expect_user_stop_kept "$case"
    [ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "$case: the recovery set of a completed upgrade was kept"
    [ "$(grep -c '^start-and-wait' "$UPGRADE_STATE/initd.log")" -eq 1 ] || fail "$case: Prokop was started more than once"
done

# --- a sing-box variant change ----------------------------------------------
upgrade_harness_reset opkg
case="sing-box change"
scenario sing-box-change || fail "$case: the change failed: $(upgrade_harness_message)"
restarted_after_change 2 || fail "$case: Prokop was not stopped for the change and restarted as its own"
upgrade_harness_running || fail "$case: Prokop does not run after the change"

# The restart's start is deferred past the wait: the new variant did not
# start cleanly, which is a failure (the action rolls the variant back).
upgrade_harness_reset opkg
upgrade_harness_flag start_deferred
case="sing-box change, the restart's start deferred"
scenario sing-box-change && fail "$case: the change was reported as done"
expect_message "$case" "Prokop did not start cleanly"
expect_own_stop_kept "$case"

# The user stops Prokop while the variant is replaced: the change completes,
# Prokop stays stopped, and the standalone sing-box service stays disabled.
upgrade_harness_reset opkg
upgrade_harness_flag user_stop_during_change
case="sing-box change, user stop"
scenario sing-box-change || fail "$case: the change failed: $(upgrade_harness_message)"
expect_user_stop_kept "$case"
! grep -q '^start-and-wait' "$UPGRADE_STATE/initd.log" || fail "$case: a start was attempted after the user's stop"
[ "$(grep -c '^disable$' "$UPGRADE_STATE/sing-box-service.log")" -ge 2 ] ||
    fail "$case: the standalone sing-box service was not kept disabled"

# The user's stop overtakes the restart: no failure, so no rollback of the
# new variant, and no further start.
upgrade_harness_reset opkg
upgrade_harness_flag user_stop_on_start
case="sing-box change, user stop overtakes the restart"
scenario sing-box-change || fail "$case: the change failed: $(upgrade_harness_message)"
expect_user_stop_kept "$case"
[ "$(grep -c '^start-and-wait' "$UPGRADE_STATE/initd.log")" -eq 1 ] || fail "$case: Prokop was started more than once"

# --- a failed sing-box change ------------------------------------------------
upgrade_harness_reset opkg
case="failed sing-box change"
scenario sing-box-failure && fail "$case: the failed change was reported as done"
grep -Fxq 'start-and-wait start' "$UPGRADE_STATE/initd.log" ||
    fail "$case: Prokop was not started again after the failed change"
upgrade_harness_running || fail "$case: Prokop does not run after the failed change"

upgrade_harness_reset opkg
upgrade_harness_flag user_stop_during_change
case="failed sing-box change, user stop"
scenario sing-box-failure && fail "$case: the failed change was reported as done"
expect_user_stop_kept "$case"
! grep -q '^start-and-wait' "$UPGRADE_STATE/initd.log" || fail "$case: a start was attempted after the user's stop"

# The user's stop overtakes the start after the failure: no restart follows.
upgrade_harness_reset opkg
upgrade_harness_flag user_stop_on_start
case="failed sing-box change, user stop overtakes the start"
scenario sing-box-failure && fail "$case: the failed change was reported as done"
expect_user_stop_kept "$case"
[ "$(grep -c '^start-and-wait' "$UPGRADE_STATE/initd.log")" -eq 1 ] || fail "$case: Prokop was started more than once"

# --- Direct Proxy: the user's stop overtakes the restart ---------------------
# The setting is saved and applies at the next start; the restart with the
# previous settings would have started Prokop again.
upgrade_harness_reset opkg
case="Direct Proxy"
scenario direct-proxy || fail "$case: the change failed: $(upgrade_harness_message)"
restarted_after_change 1 || fail "$case: Prokop was not restarted"
upgrade_harness_running || fail "$case: Prokop does not run after the change"

# The restart's own stop fails: the setting is not applied, and the action
# fails (the previous setting is restored).
upgrade_harness_reset opkg
upgrade_harness_flag stop_status 1
case="Direct Proxy, the restart's stop fails"
scenario direct-proxy && fail "$case: the change was reported as done"
expect_message "$case" "Failed to apply Direct Proxy settings"
expect_own_stop_kept "$case"

upgrade_harness_reset opkg
upgrade_harness_flag user_stop_on_start
case="Direct Proxy, user stop overtakes the restart"
scenario direct-proxy || fail "$case: the change failed: $(upgrade_harness_message)"
expect_message "$case" "Direct Proxy has been disabled"
expect_user_stop_kept "$case"
[ "$(grep -c '^start-and-wait' "$UPGRADE_STATE/initd.log")" -eq 1 ] || fail "$case: Prokop was started more than once"

printf 'component_change_user_stop: PASS\n'
