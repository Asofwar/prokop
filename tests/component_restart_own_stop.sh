#!/usr/bin/env bash
set -euo pipefail

# A component action restarts Prokop after the change; its own stop for that
# restart is no stop by the user (UC-235, D-15(a)).
#
# Whether the user stopped Prokop while the change ran is read from the stop
# request (stop.requested, by=<source>). The action restarted Prokop through
# `init.d restart`, whose stop carries no source and is therefore recorded as
# the user's. A restart that failed before its start removed that record
# read as a stop by the user: its stop failed (`prokop stop` exits 1, for
# example when the dnsmasq restore fails on a full overlay; init.d then exits
# before the start), or its start was deferred for reload.lock past the wait.
# The provider change then reported success with Prokop down and shown as
# "stopped by user", the failed sing-box change logged nothing, and Direct
# Proxy kept the new setting without its rollback. The restart is Prokop's
# own stop for the change (by=component) followed by an awaited start: such
# failures stay failures, and a stop by the user still holds.
#
# That stop and that start are two init.d calls, each under procd's lock. A
# user's Stop that waited for the lock behind Prokop's own stop ran between
# them, after the action had read the stop request, and the start took the
# user's request for the one before it: it removed it and started Prokop
# against the user's stop. The start now compares with Prokop's own stop
# request (PROKOP_START_AFTER_STOP), and any stop recorded after it wins.
# So does every other start after Prokop's own stop: the start after a failed
# sing-box change, after a failed upgrade and the start that puts back the
# service state of a package set (restore_prokop_opkg_service). Each checked
# for the user's stop and then started without that request: a user's Stop
# that got procd's lock right before the start was taken for the stop before
# it and undone.
#
# The init script is the real one behind an rc.common stand-in that holds fd
# 1000 like procd.sh; service/initd.uc is the real one; its backend `prokop`
# fails or succeeds on demand. The component action is components/action.uc
# with its dispatch replaced by the scenarios below; only its temporary
# directory, the sing-box service of the host and UCI are test doubles.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
REAL_INITD="$ROOT_DIR/prokop/files/etc/init.d/prokop"
REAL_UCODE="$(command -v ucode)"
ACTION_UC="${COMPONENT_RESTART_ACTION_UC:-$LIB/components/action.uc}"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

# A failed or deferred start schedules its retry: `/bin/sh -c '...; sleep
# "$1"; rm -f .../start-retry.pid; exec init retry_start_on_wan_up' sh N`.
kill_retry_workers() {
  local pid
  for pid in $(pgrep -f "${WORK_DIR:?}/run/prokop/start-retry.pid" 2>/dev/null); do
    owned_kill_children KILL "$pid"
    owned_kill KILL "$pid" || true
  done
  rm -f "${WORK_DIR:?}/run/prokop/start-retry.pid"
}

HOLDER=""
release_reload_lock() {
  [ -n "$HOLDER" ] || return 0
  : >"${WORK_DIR:?}/hold.gate"
  wait_until 10 process_gone "$HOLDER" || owned_kill KILL "$HOLDER" || true
  wait "$HOLDER" 2>/dev/null || true
  HOLDER=""
}

cleanup() {
  local owner
  release_reload_lock
  owner="$("$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" runtime-dir-lock-owner "$PROKOP_RELOAD_LOCK_DIR" 2>/dev/null || true)"
  [ -z "$owner" ] || owned_kill KILL "$owner" || true
  kill_retry_workers
  pkill -KILL -f "${WORK_DIR:?}" 2>/dev/null || true
  rm -rf "${WORK_DIR:?}"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'component_restart_own_stop: FAIL: %s\n' "$1" >&2
  for log in out syslog; do
    [ ! -s "$WORK_DIR/$log" ] || sed "s|^|  $log: |" "$WORK_DIR/$log" >&2
  done
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/prokop" "$WORK_DIR/tmp"
printf 'prokop.settings=settings\n' >"$WORK_DIR/uci.state"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" REAL_INITD REAL_UCODE
export TEST_LIB="$LIB"
export RC_PROCD_LOCK="$WORK_DIR/procd_prokop.lock"
export PROKOP_LIB="$LIB"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/prokop.reload.lock"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/prokop"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/prokop/reload.pending"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export PROKOP_SYSTEM_INFO_CACHE_FILE="$WORK_DIR/run/system-info.json"
export PROKOP_OPKG_RECOVERY_DIR="$WORK_DIR/recovery"
export UPDATES_LOCK_DIR="$WORK_DIR/run/component-action.lock"
export PROKOP_START_RETRY_DELAY_SECONDS=300
export PROKOP_START_DEFERRED_RETRY_DELAY_SECONDS=300
export PROKOP_START_RUNTIME_LOCK_WAIT_SECONDS=1
export PROKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS=1
export PROKOP_START_WAIT_TIMEOUT_SECONDS=4
export PROKOP_START_SETTLE_SECONDS=2
export PROKOP_UI_ACTION_TRACKED=1

# Nothing here may reach the host's syslog, nftables or init scripts.
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_WORK/syslog"
SH
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"

# `prokop` behind initd.uc. start exits with start.status and brings the
# runtime up; with start.user-stop the user's Stop comes in while it runs.
# stop takes the runtime down and exits with stop.status. With stray, a
# sing-box that runs Prokop's configuration outside procd makes the
# ownership of the runtime ambiguous: service/lifecycle.uc refuses
# Prokop's own stop (exit 2, nothing changed) unless it is the cleanup stop
# of a Prokop already down for the change (PROKOP_STOP_CLEANUP=1), which
# stops the stray as the user's Stop does; the start fails while it runs.
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
case "$1" in
  start)
    printf 'start\n' >>"$TEST_WORK/starts"
    if [ -e "$TEST_WORK/start.user-stop" ]; then
      rm -f "$TEST_WORK/start.user-stop"
      env -u PROKOP_STOP_SOURCE "$PROKOP_SERVICE_INIT" stop >/dev/null 2>&1
      exit 0
    fi
    [ ! -e "$TEST_WORK/stray" ] || exit 1
    status="$(cat "$TEST_WORK/start.status" 2>/dev/null || echo 0)"
    [ "$status" != 0 ] || : >"$TEST_WORK/runtime.up"
    exit "$status"
    ;;
  stop)
    if [ -e "$TEST_WORK/stray" ] && [ "${PROKOP_STOP_SOURCE:-}" = component ] &&
      [ "${PROKOP_STOP_CLEANUP:-}" != 1 ]; then
      exit 2
    fi
    rm -f "$TEST_WORK/stray" "$TEST_WORK/runtime.up"
    exit "$(cat "$TEST_WORK/stop.status" 2>/dev/null || echo 0)"
    ;;
  get_status)
    if [ -e "$TEST_WORK/runtime.up" ]; then printf '{"running":1}\n'; else printf '{"running":0}\n'; fi
    ;;
esac
exit 0
SH

# /etc/init.d/prokop as procd runs it: rc.common with fd 1000 open and
# flocked; restart is the init script's own (rc.common's stop, then start).
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
exec bash "$TEST_WORK/rc" "$@"
SH
#
# The user's Stop alongside Prokop's own stop for the restart
# (PROKOP_STOP_SOURCE=component): with user-stop.queued it is requested while
# that stop runs and waits for procd's lock behind it (LuCI's System >
# Startup, `service prokop stop`); once it has the lock it takes
# PROKOP_TEST_USER_STOP_DELAY before it records its request, as a slow router
# does. With user-stop.after it runs right after that stop, before the
# action goes on. With user-stop.before-start it gets procd's lock right
# before the next start, after the action has checked for the user's stop.
cat >"$WORK_DIR/rc" <<'SH'
#!/usr/bin/env bash
action="$1"
shift
if [ "$action" = start ] && [ -e "$TEST_WORK/user-stop.before-start" ]; then
  rm -f "$TEST_WORK/user-stop.before-start"
  env -u PROKOP_STOP_SOURCE -u PROKOP_STOP_CLEANUP -u PROKOP_START_REQUEST -u PROKOP_START_AFTER_STOP \
    "$PROKOP_SERVICE_INIT" stop </dev/null >/dev/null 2>&1
  printf '%s\n' "$?" >"$TEST_WORK/user-stop.done"
fi
exec 1000>"$RC_PROCD_LOCK"
[ -z "${PROKOP_TEST_USER_STOP_DELAY:-}" ] || printf '%s\n' "$$" >"$TEST_WORK/user-stop.waiting"
flock 1000
[ -z "${PROKOP_TEST_USER_STOP_DELAY:-}" ] || sleep "$PROKOP_TEST_USER_STOP_DELAY"
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
PROKOP_LIB="$TEST_LIB"
PROKOP_INITD_UC="$TEST_LIB/service/initd.uc"
stop() { stop_service "$@"; }
start() { start_service "$@"; service_started; }
printf '%s source=%s cleanup=%s\n' "$action" "${PROKOP_STOP_SOURCE:-}" "${PROKOP_STOP_CLEANUP:-}" >>"$TEST_WORK/init.log"
own_stop=""
[ "$action" != stop ] || [ "${PROKOP_STOP_SOURCE:-}" != component ] || own_stop=1
if [ -n "$own_stop" ] && [ -e "$TEST_WORK/user-stop.queued" ]; then
  rm -f "$TEST_WORK/user-stop.queued"
  (
    exec 1000>&-
    status=0
    env -u PROKOP_STOP_SOURCE PROKOP_TEST_USER_STOP_DELAY=0.5 "$PROKOP_SERVICE_INIT" stop || status=$?
    printf '%s\n' "$status" >"$TEST_WORK/user-stop.done"
  ) </dev/null >/dev/null 2>&1 &
  # Until the user's stop waits in flock for procd's lock.
  for _ in $(seq 200); do
    waiting="$(cat "$TEST_WORK/user-stop.waiting" 2>/dev/null || true)"
    [ -z "$waiting" ] || ! pgrep -P "$waiting" -x flock >/dev/null || break
    sleep 0.05
  done
fi
case "$action" in
  start) start "$@" ;;
  stop) stop "$@" ;;
  restart) restart "$@" ;;
  *) exit 64 ;;
esac
status=$?
if [ -n "$own_stop" ] && [ -e "$TEST_WORK/user-stop.after" ]; then
  rm -f "$TEST_WORK/user-stop.after"
  exec 1000>&-
  env -u PROKOP_STOP_SOURCE "$PROKOP_SERVICE_INIT" stop </dev/null >/dev/null 2>&1
  printf '%s\n' "$?" >"$TEST_WORK/user-stop.done"
fi
exit "$status"
SH

# No sing-box of another program runs; the runtime is "stably running"
# while it is up; DNS and health stay the router's.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "${3:-}" in
  */service/state.uc)
    case "${4:-}" in
      prokop-stably-running) [ -e "$TEST_WORK/runtime.up" ]; exit $? ;;
      foreign-sing-box-present) exit 1 ;;
    esac
    ;;
  */dns/apply.uc | */diagnostics/health.uc | */killswitch/runtime.uc) exit 0 ;;
esac
exec "$REAL_UCODE" "$@"
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

# components/action.uc up to its dispatch, then the scenarios.
PROBE="$WORK_DIR/action-probe.uc"
awk '
  $0 == "let mode = ARGV[0] || \"\";" { found = 1; exit }
  { print }
  END { if (!found) exit 1 }
' "$ACTION_UC" >"$PROBE" || fail "the dispatch of components/action.uc was not found"
cat >>"$PROBE" <<'UCODE'

// The action's temporary files stay in the test's directory; the host's
// sing-box service and UCI are not the router's.
const TEST_WORK = getenv("TEST_WORK");
function cleanup_stale_tmp_files() {}
function init_tmp_dir() {
    if (tmp_dir != "")
        return true;
    tmp_dir = trim(command_output_from_args([ "mktemp", "-d", TEST_WORK + "/tmp/updates.XXXXXX" ]));
    return tmp_dir != "";
}
function prepare_sing_box_service_disabled() {}
// Direct Proxy is on at port 2080; a commit is what the router keeps.
let test_uci = { "prokop.settings.direct_proxy_enabled": "1", "prokop.settings.direct_proxy_port": "2080" };
uci_core = {
    available: function() { return true; },
    get: function(path) { return test_uci[path]; },
    set: function(path, value) { test_uci[path] = value; return true; },
    "delete": function(path) { delete test_uci[path]; return true; },
    commit: function() { return fs.writefile(TEST_WORK + "/uci.committed", sprintf("%J\n", test_uci)) != null; }
};

capture_prokop_running_state();
let scenario = ARGV[0];
if (scenario == "restart")
    print("restarted=", restart_prokop_after_successful_change() ? "yes" : "no", "\n");
else if (scenario == "direct-proxy")
    set_direct_proxy("disable");
else if (scenario == "failed-sing-box") {
    // Prokop's own stop for the change; the new variant does not start,
    // and neither does the stop of the restart that follows.
    if (!stop_prokop_before_sing_box_change())
        die("the stop for the sing-box change was refused");
    fs.writefile(TEST_WORK + "/start.status", "1\n");
    fs.writefile(TEST_WORK + "/stop.status", "1\n");
    restart_prokop_after_failed_sing_box_change();
    print("done\n");
}
else if (scenario == "failed-sing-box-start") {
    // Prokop's own stop for the change; the change fails, and the start
    // after it would bring Prokop back.
    if (!stop_prokop_before_sing_box_change())
        die("the stop for the sing-box change was refused");
    restart_prokop_after_failed_sing_box_change();
    print("done\n");
}
else if (scenario == "failed-upgrade") {
    // Prokop's own stop for an in-app upgrade; the upgrade fails.
    if (!command_success_from_args(prokop_stop_for_component_change_args()))
        die("the stop for the upgrade failed");
    prokop_stopped_for_upgrade = true;
    restart_prokop_after_failed_upgrade();
    print("done\n");
}
else if (scenario == "restore-service") {
    // Prokop's own stop for a package set that is put back; Prokop ran
    // before it.
    if (!command_success_from_args(prokop_stop_for_component_change_args()))
        die("the stop for the package set failed");
    print("restored=", restore_prokop_opkg_service(true) ? "yes" : "no", "\n");
}
else if (scenario == "sing-box-stray") {
    // Prokop's own stop for the change; then a sing-box that runs Prokop's
    // configuration is left behind (with failed: the new variant does not
    // start cleanly).
    if (!stop_prokop_before_sing_box_change())
        die("the stop for the sing-box change was refused");
    fs.writefile(TEST_WORK + "/stray", "");
    if (ARGV[1] == "failed")
        restart_prokop_after_failed_sing_box_change();
    else
        print("restarted=", restart_prokop_after_successful_change() ? "yes" : "no", "\n");
    print("done\n");
}
UCODE

# The live reload.lock of other work (a forced subscription update, the
# automatic latency test) until release_reload_lock.
hold_reload_lock() {
  rm -f "$WORK_DIR/hold.gate" "$WORK_DIR/hold.acquired"
  sh -c '
    "$REAL_UCODE" -L "$TEST_LIB" "$TEST_LIB/service/state.uc" acquire-runtime-dir-lock "$PROKOP_RELOAD_LOCK_DIR" "$$" || exit 1
    : >"$TEST_WORK/hold.acquired"
    while [ ! -e "$TEST_WORK/hold.gate" ]; do sleep 0.05; done
    "$REAL_UCODE" -L "$TEST_LIB" "$TEST_LIB/service/state.uc" release-runtime-dir-lock "$PROKOP_RELOAD_LOCK_DIR" "$$"
  ' &
  HOLDER=$!
  wait_until 10 test -e "$WORK_DIR/hold.acquired" || fail "the lock holder did not get reload.lock"
}

# Prokop 1.0 runs, started explicitly; nobody asked for a stop.
reset_case() {
  release_reload_lock
  kill_retry_workers
  rm -f "$WORK_DIR"/start.status "$WORK_DIR"/stop.status "$WORK_DIR"/start.user-stop "$WORK_DIR"/starts \
    "$WORK_DIR"/user-stop.queued "$WORK_DIR"/user-stop.after "$WORK_DIR"/user-stop.waiting "$WORK_DIR"/user-stop.done \
    "$WORK_DIR"/user-stop.before-start \
    "$WORK_DIR"/stray \
    "$WORK_DIR"/uci.committed "$WORK_DIR"/out "$PROKOP_RUNTIME_STATE_DIR"/stop.requested \
    "$PROKOP_RUNTIME_STATE_DIR"/start.retry "$PROKOP_RUNTIME_STATE_DIR"/start-result.*
  : >"$WORK_DIR/syslog"
  : >"$WORK_DIR/init.log"
  : >"$WORK_DIR/runtime.up"
  printf 'explicit\n' >"$PROKOP_RUNTIME_STATE_DIR/start.explicit"
}

probe() {
  local status=0
  "$REAL_UCODE" -L "$LIB" "$PROBE" "$@" >"$WORK_DIR/out" 2>&1 || status=$?
  return "$status"
}

stop_request_by() {
  sed -n 's/^by=//p' "$PROKOP_RUNTIME_STATE_DIR/stop.requested" 2>/dev/null || true
}

expect_not_user_stop() {
  [ "$(stop_request_by)" != user ] || fail "$1: Prokop's own stop for the restart was recorded as the user's"
  if grep -q 'stopped by the user' "$WORK_DIR/syslog"; then
    fail "$1: a failed restart was reported as the user's stop"
  fi
}

# 1. A working restart after a provider change.
reset_case
case="restart"
probe restart || fail "$case: the probe failed"
grep -qx 'restarted=yes' "$WORK_DIR/out" || fail "$case: a working restart was reported as failed"
[ -e "$WORK_DIR/runtime.up" ] || fail "$case: Prokop does not run after its restart"
[ ! -e "$PROKOP_RUNTIME_STATE_DIR/stop.requested" ] || fail "$case: the restart left a stop request"
[ -e "$PROKOP_RUNTIME_STATE_DIR/start.explicit" ] || fail "$case: the restart ended the explicit start"

# 2. The restart's own stop fails (exit 1): init.d does not start Prokop.
#    The change did not bring Prokop back, which is a failure.
reset_case
printf '1\n' >"$WORK_DIR/stop.status"
case="restart, its stop fails"
probe restart || fail "$case: the probe failed"
grep -qx 'restarted=no' "$WORK_DIR/out" || fail "$case: a restart whose stop failed was reported as done"
expect_not_user_stop "$case"
grep -q '\[error\] Updates: Prokop did not start again after the component change' "$WORK_DIR/syslog" ||
  fail "$case: the failed restart was not logged as an error"

# 3. The restart's start is deferred for reload.lock past the wait: the
#    change did not bring Prokop back within the wait.
reset_case
hold_reload_lock
case="restart, its start deferred"
probe restart || fail "$case: the probe failed"
grep -qx 'restarted=no' "$WORK_DIR/out" || fail "$case: a deferred restart was reported as done"
expect_not_user_stop "$case"
grep -q '\[error\] Updates: Prokop did not start again after the component change' "$WORK_DIR/syslog" ||
  fail "$case: the deferred restart was not logged as an error"

# 4. The user's Stop overtakes the restart's start: the stop holds and the
#    change is no failure (D-15(a)).
reset_case
: >"$WORK_DIR/start.user-stop"
case="restart, the user's stop overtakes the start"
probe restart || fail "$case: the probe failed"
grep -qx 'restarted=yes' "$WORK_DIR/out" || fail "$case: the user's stop was reported as a failed restart"
[ "$(stop_request_by)" = user ] || fail "$case: the user's stop is no longer recorded"
[ ! -e "$WORK_DIR/runtime.up" ] || fail "$case: Prokop runs after the user stopped it"
[ "$(grep -c '^start$' "$WORK_DIR/starts")" -eq 1 ] || fail "$case: Prokop was started again after the user's stop"

# 5. Direct Proxy: the restart's stop fails. The new setting is rolled back
#    and the action fails.
reset_case
printf '1\n' >"$WORK_DIR/stop.status"
case="Direct Proxy, the restart's stop fails"
probe direct-proxy && fail "$case: the action succeeded"
grep -q '"success": *false' "$WORK_DIR/out" || fail "$case: the failed restart was reported as success"
grep -q 'Failed to apply Direct Proxy settings' "$WORK_DIR/out" || fail "$case: unexpected result"
grep -q '"prokop.settings.direct_proxy_enabled": *"1"' "$WORK_DIR/uci.committed" ||
  fail "$case: the new Direct Proxy setting was kept: $(cat "$WORK_DIR/uci.committed")"
expect_not_user_stop "$case"

# 6. A failed sing-box change: the start after it fails, and so does the
#    stop of the restart that follows. That is logged as an error.
reset_case
case="failed sing-box change, the restart's stop fails"
probe failed-sing-box || fail "$case: the probe failed"
grep -q '\[error\] Updates: Prokop did not start again after the failed sing-box component change' "$WORK_DIR/syslog" ||
  fail "$case: the failed restart was not logged as an error"
expect_not_user_stop "$case"

# The user's Stop with Prokop's own stop for the restart: it holds, and the
# change is no failure (D-15(a)). No start runs, and the explicit start stays
# ended: no reload brings the runtime back.
expect_user_stop_holds() {
  wait_until 20 test -e "$WORK_DIR/user-stop.done" || fail "$1: the user's stop did not finish"
  [ "$(cat "$WORK_DIR/user-stop.done")" = 0 ] || fail "$1: the user's stop failed"
  grep -qx 'restarted=yes' "$WORK_DIR/out" || fail "$1: the user's stop was reported as a failed restart"
  [ "$(stop_request_by)" = user ] || fail "$1: the user's stop is no longer recorded ($(stop_request_by))"
  [ ! -e "$WORK_DIR/runtime.up" ] || fail "$1: Prokop runs after the user stopped it"
  [ ! -s "$WORK_DIR/starts" ] || fail "$1: Prokop was started after the user's stop"
  [ ! -e "$PROKOP_RUNTIME_STATE_DIR/start.explicit" ] || fail "$1: the start after the user's stop recorded an explicit start"
}

# 7. The user's Stop waits for procd's lock behind Prokop's own stop, and
#    records its request only after the action has read the stop request.
reset_case
: >"$WORK_DIR/user-stop.queued"
case="restart, the user's stop waits behind its own stop"
probe restart || fail "$case: the probe failed"
expect_user_stop_holds "$case"

# 8. The user's Stop runs between the restart's own stop and its start.
reset_case
: >"$WORK_DIR/user-stop.after"
case="restart, the user's stop between its stop and its start"
probe restart || fail "$case: the probe failed"
expect_user_stop_holds "$case"

# A refused restart stop changed nothing: Prokop runs on as it was, with no
# stop request, and no start was tried. That is no failed start.
expect_refused_restart() {
  [ -e "$WORK_DIR/runtime.up" ] || fail "$1: Prokop does not run after its own stop was refused"
  [ ! -e "$PROKOP_RUNTIME_STATE_DIR/stop.requested" ] || fail "$1: the refused stop left a stop request"
  [ -e "$PROKOP_RUNTIME_STATE_DIR/start.explicit" ] || fail "$1: the refused stop ended the explicit start"
  [ ! -s "$WORK_DIR/starts" ] || fail "$1: a start followed the refused stop"
  [ "$(grep -c '^stop ' "$WORK_DIR/init.log")" -eq 1 ] || fail "$1: Prokop was stopped again after the refusal"
  grep -q 'Prokop was not restarted: another sing-box process makes the ownership of its runtime ambiguous' "$WORK_DIR/syslog" ||
    fail "$1: the refusal is not reported"
  if grep -q 'did not start again' "$WORK_DIR/syslog"; then
    fail "$1: the refused restart was reported as a failed start"
  fi
}

# 9. Prokop's own stop for the restart is refused: another sing-box makes the
#    ownership of the runtime ambiguous. The change is not applied, which the
#    action reports as such.
reset_case
: >"$WORK_DIR/stray"
case="restart, its own stop refused"
probe restart || fail "$case: the probe failed"
grep -qx 'restarted=no' "$WORK_DIR/out" || fail "$case: a refused restart was reported as done"
expect_refused_restart "$case"

# 10. Direct Proxy: the restart's own stop is refused. Prokop runs on with the
#     previous settings, which are kept; nothing restarts it again.
reset_case
: >"$WORK_DIR/stray"
case="Direct Proxy, the restart's own stop refused"
probe direct-proxy && fail "$case: the action succeeded"
grep -q '"success": *false' "$WORK_DIR/out" || fail "$case: the refused restart was reported as success"
grep -q 'Prokop was not restarted: another sing-box process' "$WORK_DIR/out" ||
  fail "$case: the action does not report the refusal"
# The setting was rolled back: it does not apply at the next start.
if grep -q 'applies at its next start' "$WORK_DIR/out" "$WORK_DIR/syslog"; then
  fail "$case: the refusal claims that the rolled-back setting applies at the next start"
fi
grep -q 'Prokop runs on with the previous Direct Proxy settings' "$WORK_DIR/out" ||
  fail "$case: the refusal does not say that Prokop runs on with the previous settings"
grep -q '"prokop.settings.direct_proxy_enabled": *"1"' "$WORK_DIR/uci.committed" ||
  fail "$case: the new Direct Proxy setting was kept: $(cat "$WORK_DIR/uci.committed")"
expect_refused_restart "$case"

# 11. A sing-box change: Prokop is down already, stopped for the change, and
#     a sing-box that runs Prokop's configuration is left behind. Nothing
#     runs that the ownership guard would keep: the stop of the restart
#     clears it as the user's Stop does, still as Prokop's own stop, and
#     Prokop starts again. So does the restart fallback after a failed change.
for mode in successful failed; do
  reset_case
  case="sing-box change ($mode), a stray sing-box left behind"
  probe sing-box-stray "$mode" || fail "$case: the probe failed"
  [ "$mode" = failed ] || grep -qx 'restarted=yes' "$WORK_DIR/out" || fail "$case: the restart was reported as failed"
  [ ! -e "$WORK_DIR/stray" ] || fail "$case: the stray sing-box was left running"
  [ -e "$WORK_DIR/runtime.up" ] || fail "$case: Prokop does not run again"
  grep -q '^stop source=component cleanup=1$' "$WORK_DIR/init.log" || fail "$case: the stop of the restart was no cleanup stop"
  [ "$(grep -c '^stop source=component cleanup=$' "$WORK_DIR/init.log")" -eq 1 ] ||
    fail "$case: the stop for the change was not the guarded one"
  expect_not_user_stop "$case"
  if grep -q 'did not start again\|was not restarted' "$WORK_DIR/syslog"; then
    fail "$case: the restart was reported as failed"
  fi
done

# 12. The start after Prokop's own stop for a failed sing-box change, after a
#     failed upgrade and the start that puts back a package set's service
#     state: without the user's stop each brings Prokop back; the user's
#     Stop that gets procd's lock right before the start holds (D-15(a)).
for scenario in failed-sing-box-start failed-upgrade restore-service; do
  reset_case
  case="$scenario, no stop by the user"
  probe "$scenario" || fail "$case: the probe failed"
  [ -e "$WORK_DIR/runtime.up" ] || fail "$case: Prokop was not started again"
  [ "$(grep -c '^start$' "$WORK_DIR/starts" 2>/dev/null || true)" -eq 1 ] || fail "$case: Prokop was not started once"
  [ "$scenario" != restore-service ] || grep -qx 'restored=yes' "$WORK_DIR/out" ||
    fail "$case: the service state was not reported as restored"

  reset_case
  : >"$WORK_DIR/user-stop.before-start"
  case="$scenario, the user's stop right before the start"
  probe "$scenario" || fail "$case: the probe failed"
  wait_until 20 test -e "$WORK_DIR/user-stop.done" || fail "$case: the user's stop did not run"
  [ "$(cat "$WORK_DIR/user-stop.done")" = 0 ] || fail "$case: the user's stop failed"
  [ "$(stop_request_by)" = user ] || fail "$case: the user's stop is no longer recorded ($(stop_request_by))"
  [ ! -e "$WORK_DIR/runtime.up" ] || fail "$case: Prokop runs after the user stopped it"
  [ ! -s "$WORK_DIR/starts" ] || fail "$case: Prokop was started after the user's stop"
  [ ! -e "$PROKOP_RUNTIME_STATE_DIR/start.explicit" ] || fail "$case: the start after the user's stop recorded an explicit start"
  [ "$scenario" != restore-service ] || grep -qx 'restored=yes' "$WORK_DIR/out" ||
    fail "$case: the user's stop was reported as a service state not restored"
  if grep -q 'did not start again' "$WORK_DIR/syslog"; then
    fail "$case: the user's stop was reported as a failed start"
  fi
done

printf 'component_restart_own_stop: PASS\n'
