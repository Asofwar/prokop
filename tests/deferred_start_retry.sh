#!/usr/bin/env bash
set -euo pipefail

# A start that does not get reload.lock in time is retried, not dropped
# (UC-057, UC-010, UC-012, UC-013).
#
# A start holds reload.lock for its whole duration, and so do a forced
# subscription update or the automatic latency test: a start that arrives
# meanwhile waits for the lock only for START_RUNTIME_LOCK_WAIT_SECONDS. Once
# that wait runs out the start is deferred: the start-retry worker starts it
# after the holder has released the lock, unless an explicit stop came
# meanwhile (the stop wins, D-15). A caller that waits for the outcome
# (start-and-wait: the UI, component actions, the package postinst) is told
# "deferred", not "failed", and gets the result of the retried start.
#
# The init script is the real one behind an rc.common stand-in that holds the
# procd lock on fd 1000 like procd.sh (a nested init.d call reuses the lock
# it inherits), service/initd.uc, service/ui.uc and the lock helpers are
# real; `prokop` is a double. The waits are scaled down: the start waits 2 s
# for the lock, a deferred start is retried 1 s later.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
REAL_INITD="$ROOT_DIR/prokop/files/etc/init.d/prokop"
REAL_UCODE="$(command -v ucode)"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

actors=()
cleanup() {
  local pid
  for pid in "${actors[@]}"; do
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
  # Retry workers, detached start workers and UI waiters.
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -s "$EVENTS" ]; then
    sed 's/^/  event: /' "$EVENTS" >&2
  fi
  if [ -s "$WORK_DIR/syslog" ]; then
    sed 's/^/  syslog: /' "$WORK_DIR/syslog" >&2
  fi
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/prokop" "$WORK_DIR/tmp"
printf 'prokop.settings=settings\n' >"$WORK_DIR/uci.state"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" EVENTS REAL_INITD REAL_UCODE
export TEST_LIB="$LIB"
export RC_PROCD_LOCK="$WORK_DIR/procd_prokop.lock"
export RELOAD_LOCK="$WORK_DIR/run/prokop.reload.lock"
export STATE_DIR="$WORK_DIR/run/prokop"
export STOP_MARKER="$STATE_DIR/stop.requested"
export PROKOP_LIB="$LIB"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK"
export PROKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export PROKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export PROKOP_START_IN_PROGRESS_FILE="$STATE_DIR/start.in-progress"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_START_RUNTIME_LOCK_WAIT_SECONDS=2
export PROKOP_START_DEFERRED_RETRY_DELAY_SECONDS=1
# A failed start is not what these cases are about.
export PROKOP_START_RETRY_DELAY_SECONDS=300
export PROKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS=1
export PROKOP_START_WAIT_TIMEOUT_SECONDS=40
export PROKOP_START_SETTLE_SECONDS=3
export PROKOP_UI_ACTION_TRACKED=1
# A retried start opens a UI job of its own: the UI state of the cases before
# case 6 (which has a directory of its own) stays in the work directory too.
export PROKOP_UI_STATE_DIR="$WORK_DIR/ui-state-cases"
export PROKOP_UI_COMPONENT_ACTION_DIR="$PROKOP_UI_STATE_DIR/component-actions"
export PROKOP_UI_SUBSCRIPTION_ACTION_DIR="$PROKOP_UI_STATE_DIR/subscription-actions"

# Nothing here may reach the host's syslog, nftables or init scripts.
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_WORK/syslog"
# A case holds a start that has released reload.lock where it logs the
# recovery of a WAN-up retry (report_start_result).
case "$*" in
  *"recovered automatically"*)
    if [ -e "$TEST_WORK/logger.hold" ]; then
      : >"$TEST_WORK/logger.held"
      while [ -e "$TEST_WORK/logger.hold" ] && [ -d "$TEST_WORK" ]; do sleep 0.05; done
    fi
    ;;
esac
SH
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"

# `prokop` behind initd.uc: start brings the modelled runtime up (under its
# own reload.lock), stop takes it down.
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
ev() { printf '%s\n' "$1" >>"$EVENTS"; }
case "$1" in
  start)
    owner="$(ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" runtime-dir-lock-owner "$RELOAD_LOCK" || true)"
    cmd=""
    [ -z "$owner" ] || cmd="$(tr '\0' ' ' <"/proc/$owner/cmdline" 2>/dev/null || true)"
    case "$cmd" in
      *"service/initd.uc start-service"*) ev "prokop start" ;;
      *) ev "prokop start (without reload.lock)" ;;
    esac
    # A case holds the start while it owns reload.lock.
    while [ -e "$TEST_WORK/start.hold" ] && [ -d "$TEST_WORK" ]; do sleep 0.05; done
    : >"$TEST_WORK/runtime.up"
    ;;
  stop)
    ev "prokop stop"
    rm -f "$TEST_WORK/runtime.up"
    # A case leaves a process in the background with this output open.
    if [ -e "$TEST_WORK/stop.background" ]; then
      (while [ -e "$TEST_WORK/stop.background" ] && [ -d "$TEST_WORK" ]; do sleep 0.1; done) &
    fi
    ;;
  get_status)
    if [ -e "$TEST_WORK/runtime.up" ]; then printf '{"running":1}\n'; else printf '{"running":0}\n'; fi
    ;;
esac
exit 0
SH

# /etc/init.d/prokop as procd runs it: rc.common with the procd lock on fd
# 1000 (procd.sh procd_lock: a nested call that inherits the locked fd keeps
# using it). bash stands in for busybox ash (dash has no fd above 9).
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
exec bash "$TEST_WORK/rc" "$@"
SH
cat >"$WORK_DIR/rc" <<'SH'
#!/usr/bin/env bash
action="$1"
shift
printf '%s\n' "$action${*:+ $*}" >>"$TEST_WORK/rc.calls"
if ! flock -n 1000 2>/dev/null; then
  exec 1000>"$RC_PROCD_LOCK"
  flock 1000
fi
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
PROKOP_LIB="$TEST_LIB"
PROKOP_INITD_UC="$TEST_LIB/service/initd.uc"
case "$action" in
  start) start_service "$@"; service_started ;;
  stop) stop_service "$@" ;;
  retry_start_on_wan_up) retry_start_on_wan_up ;;
  handle_wan_up) handle_wan_up ;;
  *) exit 64 ;;
esac
SH

# service/ui.uc asks service/state.uc whether the runtime is stably running.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "${3:-}" in
  */service/state.uc)
    if [ "${4:-}" = prokop-stably-running ]; then
      [ -e "$TEST_WORK/runtime.up" ]
      exit $?
    fi
    ;;
  */dns/apply.uc | */diagnostics/health.uc) exit 0 ;;
esac
exec "$REAL_UCODE" "$@"
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

initd() { "$REAL_UCODE" -L "$LIB" "$LIB/service/initd.uc" "$@"; }

has_event() { grep -qx "$1" "$EVENTS" 2>/dev/null; }
no_event() { ! grep -q "$1" "$EVENTS" 2>/dev/null; }
logged() { grep -q "$1" "$WORK_DIR/syslog" 2>/dev/null; }
starts() { grep -c '^prokop start' "$EVENTS" 2>/dev/null || true; }

# Actors run in their own process group under a hard deadline. The detached
# start worker and the retry worker it schedules stay in that group.
start_actor() {
  setsid timeout -s KILL 120 "$@" &
  LAST_ACTOR=$!
  actors+=("$LAST_ACTOR")
}

group_done() { ! pgrep -g "$1" >/dev/null 2>&1; }

# Some long work (a forced subscription update, the automatic latency test)
# holds reload.lock until the gate opens.
hold_reload_lock() {
  rm -f "$WORK_DIR/hold.gate" "$WORK_DIR/hold.acquired"
  start_actor sh -c '
    ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" acquire-runtime-dir-lock "$RELOAD_LOCK" "$$" || exit 1
    : >"$TEST_WORK/hold.acquired"
    while [ ! -e "$TEST_WORK/hold.gate" ]; do sleep 0.05; done
    ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" release-runtime-dir-lock "$RELOAD_LOCK" "$$"
  '
  HOLDER="$LAST_ACTOR"
  wait_until 10 test -e "$WORK_DIR/hold.acquired" || fail "the lock holder did not get reload.lock"
}

release_reload_lock() {
  : >"$WORK_DIR/hold.gate"
  wait_until 10 process_gone "$HOLDER" || fail "the lock holder did not finish"
  wait "$HOLDER" 2>/dev/null || true
}

launch_start() {
  start_actor "$PROKOP_SERVICE_INIT" start
  START_ACTOR="$LAST_ACTOR"
}

# The start gave up waiting for reload.lock ...
start_deferred() { logged 'start deferred'; }
# ... and its retry has run at least once while the lock was still held.
deferred_start_retried() { deferred_retries_at_least 1; }
# How many times the retry worker has started the deferred start again.
deferred_retries_at_least() {
  local count
  count="$(grep -cx 'start deferred' "$WORK_DIR/rc.calls" 2>/dev/null || true)"
  [ "${count:-0}" -ge "$1" ]
}

retry_worker_running() {
  local pid
  pid="$(head -n 1 "$STATE_DIR/start-retry.pid" 2>/dev/null)" || return 1
  [ -n "$pid" ] && process_running "$pid"
}

# Some part of a start of this test is still at work: an init.d call, a
# scheduled retry, a detached start worker or a WAN-up handler. Other tests
# run the same initd.uc: its processes are told apart by their state
# directory.
start_work_running() {
  local pid
  pgrep -f "$WORK_DIR/(rc|bin/init)|$STATE_DIR/start-retry.pid" >/dev/null 2>&1 && return 0
  for pid in $(pgrep -f 'service/initd.uc (start-service|retry-start-on-wan-up|handle-wan-up)' 2>/dev/null); do
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qx "PROKOP_RUNTIME_STATE_DIR=$STATE_DIR" && return 0
  done
  return 1
}
start_work_done() { ! start_work_running; }

reset_case() {
  local pid
  pid="$(head -n 1 "$STATE_DIR/start-retry.pid" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$WORK_DIR"/runtime.up "$WORK_DIR"/hold.gate "$WORK_DIR"/hold.acquired \
    "$WORK_DIR"/start.hold "$WORK_DIR"/logger.hold "$WORK_DIR"/logger.held "$WORK_DIR"/rc.calls \
    "$WORK_DIR"/stop.background \
    "$STATE_DIR"/start.retry "$STATE_DIR"/start-retry.pid "$STOP_MARKER" "$STATE_DIR"/start-result.*
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  [ ! -e "$RELOAD_LOCK" ] || fail "reload.lock leaked from the previous case"
}

# The start happened once, under its own reload.lock, and left nothing to
# retry.
started_once() {
  local label="$1"
  wait_until 20 test -e "$WORK_DIR/runtime.up" || fail "$label: Prokop was not started after the lock was released"
  wait_until 20 start_work_done || fail "$label: the start or its retry did not finish"
  [ "$(starts)" = 1 ] || fail "$label: Prokop was not started exactly once"
  has_event "prokop start" || fail "$label: the start ran without reload.lock"
  [ ! -e "$STATE_DIR/start.retry" ] || fail "$label: a start retry is still pending after the start"
  retry_worker_running && fail "$label: a start retry is still scheduled after the start"
  [ ! -e "$RELOAD_LOCK" ] || fail "$label: the start left reload.lock behind"
  if logged 'recovery attempt failed' || logged 'start failed'; then
    fail "$label: the deferred start was reported as a failure"
  fi
}

# 1. An automatic start (boot, postinst, component restart: init.d start
#    under procd) that loses the race for reload.lock is retried once the
#    holder has released it. Autostart is off on this host: the deferred
#    start is an explicit request and does not depend on it.
reset_case
hold_reload_lock
launch_start
wait_until 15 start_deferred || fail "the start did not give up waiting for reload.lock"
no_event '^prokop start' || fail "the start ran while another process held reload.lock"
grep -qx 'reason=start_deferred' "$STATE_DIR/start.retry" 2>/dev/null ||
  fail "the deferred start left no retry: $(cat "$STATE_DIR/start.retry" 2>/dev/null || printf 'no start.retry')"
# The holder keeps the lock beyond the retry's own wait: the retry defers
# again instead of giving up. The log says once that the start is deferred,
# not on every retry: a holder may keep the lock for long.
wait_until 20 deferred_retries_at_least 2 || fail "the retried start did not wait for the lock again"
no_event '^prokop start' || fail "the retried start ran while another process held reload.lock"
[ "$(grep -c . "$WORK_DIR/syslog")" = 1 ] || fail "the deferred start logged more than its deferral while it waited"
release_reload_lock
started_once "automatic start"
logged 'Running the deferred Prokop start' || fail "the deferred start did not log that it runs"
# The retried start opens a UI job of its own (it drops
# PROKOP_UI_ACTION_TRACKED): the job is the test's, not the host's.
ls "$WORK_DIR"/ui-state-cases/service-actions/*.json >/dev/null 2>&1 ||
  fail "the retried start opened no UI job in the test's own UI state directory"

# 1b. Switching autostart off (init.d disable cancels the scheduled retry of a
#     failed start) during the deferral is no stop: the explicit start still
#     runs once the lock is released, and leaves no deferred start behind for
#     a later WAN-up to run with autostart off. The retry is scheduled later
#     here, so that disable surely finds it waiting.
reset_case
hold_reload_lock
PROKOP_START_DEFERRED_RETRY_DELAY_SECONDS=4 launch_start
wait_until 15 start_deferred || fail "the start did not give up waiting for reload.lock"
retry_worker_running || fail "the deferred start scheduled no retry"
# What init.d disable runs besides removing the host's rc.d links.
initd cancel-scheduled-start-retry >/dev/null 2>&1 || fail "cancelling a scheduled start retry failed"
release_reload_lock
started_once "start deferred across init.d disable"

# 2. An explicit stop during the deferral wins: the deferred start does not
#    run after the holder has released the lock.
reset_case
hold_reload_lock
launch_start
wait_until 15 start_deferred || fail "the start did not give up waiting for reload.lock"
start_actor "$PROKOP_SERVICE_INIT" stop
STOP_ACTOR="$LAST_ACTOR"
wait_until 20 group_done "$STOP_ACTOR" || fail "the stop did not finish"
[ -e "$STOP_MARKER" ] || fail "the stop was not recorded"
release_reload_lock
wait_until 20 group_done "$START_ACTOR" || fail "the deferred start or its retry is still at work after the stop"
no_event '^prokop start' || fail "a deferred start ran after an explicit stop"
[ ! -e "$WORK_DIR/runtime.up" ] || fail "Prokop runs after an explicit stop"
[ ! -e "$STATE_DIR/start.retry" ] || fail "the stop left the deferred start pending"
[ -e "$STOP_MARKER" ] || fail "the explicit stop is no longer recorded"

# 2b. The same when the stop comes while the retried start waits for the
#     lock again.
reset_case
hold_reload_lock
launch_start
wait_until 15 deferred_start_retried || fail "the deferred start was not retried"
start_actor "$PROKOP_SERVICE_INIT" stop
STOP_ACTOR="$LAST_ACTOR"
wait_until 20 group_done "$STOP_ACTOR" || fail "the stop did not finish"
release_reload_lock
wait_until 20 group_done "$START_ACTOR" || fail "the retried start is still at work after the stop"
no_event '^prokop start' || fail "a retried start ran after an explicit stop"
[ ! -e "$WORK_DIR/runtime.up" ] || fail "Prokop runs after an explicit stop"
[ ! -e "$STATE_DIR/start.retry" ] || fail "the stop left the deferred start pending"

# 2c. WAN-up during the deferral after a stop does not start Prokop either.
reset_case
hold_reload_lock
launch_start
wait_until 15 start_deferred || fail "the start did not give up waiting for reload.lock"
printf 'later-stop\nby=user\n' >"$STOP_MARKER"
initd handle-wan-up >/dev/null 2>&1 || fail "WAN-up during a deferred start failed"
release_reload_lock
wait_until 20 group_done "$START_ACTOR" || fail "the deferred start or its retry is still at work after the stop"
no_event '^prokop start' || fail "a deferred start ran after a stop requested during its deferral"

# 3. Control: a start requested after an earlier stop is not undone by that
#    stop while it is deferred; it runs and ends the stop. Neither WAN-up
#    during the deferral cancels it.
reset_case
printf 'earlier-stop\nby=user\n' >"$STOP_MARKER"
hold_reload_lock
launch_start
wait_until 15 start_deferred || fail "the start after an earlier stop did not give up waiting for reload.lock"
initd handle-wan-up >/dev/null 2>&1 || fail "WAN-up during a deferred start failed"
grep -qx 'reason=start_deferred' "$STATE_DIR/start.retry" 2>/dev/null ||
  fail "WAN-up dropped a start deferred after an earlier stop"
wait_until 15 deferred_start_retried || fail "the deferred start after an earlier stop was not retried"
release_reload_lock
started_once "start after an earlier stop"
[ ! -e "$STOP_MARKER" ] || fail "a start after an earlier stop kept the explicit stop"

# 4. The WAN-up retry of a failed start ("triggered") that is deferred is not
#    a failed recovery: it is retried as well.
reset_case
hold_reload_lock
start_actor "$REAL_UCODE" -L "$LIB" "$LIB/service/initd.uc" start-service triggered >/dev/null 2>&1
START_ACTOR="$LAST_ACTOR"
wait_until 15 start_deferred || fail "the WAN-up retry did not give up waiting for reload.lock"
logged 'recovery attempt failed' && fail "a deferred WAN-up retry was logged as a failed recovery"
release_reload_lock
started_once "WAN-up retry"

# 4b. A start that runs while another start is deferred serves it: the
#     deferred start's retry ends before that start releases reload.lock.
#     Otherwise the retry, waiting for the lock, may take it next, find its
#     record and start Prokop once more. The running start is held just after
#     it has released the lock; the deferred start's retry is scheduled late
#     enough to be still waiting then.
reset_case
: >"$WORK_DIR/start.hold"
: >"$WORK_DIR/logger.hold"
start_actor "$REAL_UCODE" -L "$LIB" "$LIB/service/initd.uc" start-service triggered >/dev/null 2>&1
HOLDING_START="$LAST_ACTOR"
wait_until 15 has_event "prokop start" || fail "the first start did not run"
PROKOP_START_DEFERRED_RETRY_DELAY_SECONDS=30 launch_start
wait_until 15 start_deferred || fail "the second start did not give up waiting for reload.lock"
grep -qx 'reason=start_deferred' "$STATE_DIR/start.retry" 2>/dev/null || fail "the second start left no retry"
rm -f "$WORK_DIR/start.hold"
wait_until 15 test -e "$WORK_DIR/logger.held" || fail "the first start did not finish"
[ ! -e "$RELOAD_LOCK" ] || fail "the first start still holds reload.lock after it finished"
[ ! -e "$STATE_DIR/start.retry" ] ||
  fail "the deferred start was still pending after the start that served it released reload.lock"
rm -f "$WORK_DIR/logger.hold"
wait_until 20 group_done "$HOLDING_START" || fail "the first start did not exit"
started_once "start deferred behind another start"

# 5. start-and-wait (component actions, the package postinst) is told that
#    the start was deferred and waits for the retried start's own result.
reset_case
hold_reload_lock
rm -f "$WORK_DIR/wait.status"
start_actor sh -c 'status=0; "$0" -L "$1" "$1/service/initd.uc" start-and-wait start "" 40 >"$2/wait.out" 2>&1 || status=$?; echo "$status" >"$2/wait.status"' \
  "$REAL_UCODE" "$LIB" "$WORK_DIR"
START_ACTOR="$LAST_ACTOR"
deferred_result() { grep -qx 'status=deferred' "$STATE_DIR"/start-result.* 2>/dev/null; }
wait_until 15 deferred_result || fail "the waiting caller was not told that the start was deferred"
[ ! -e "$WORK_DIR/wait.status" ] || fail "start-and-wait returned for a deferred start: $(cat "$WORK_DIR/wait.status")"
release_reload_lock
wait_until 30 test -e "$WORK_DIR/wait.status" || fail "start-and-wait did not return after the retried start"
[ "$(cat "$WORK_DIR/wait.status")" = 0 ] || fail "a deferred start that ran was reported as failed: $(cat "$WORK_DIR/wait.out")"
started_once "start-and-wait"

# 5b. A stop during the deferral ends the wait with a failure at once, not
#     at the wait's timeout.
reset_case
hold_reload_lock
rm -f "$WORK_DIR/wait.status"
start_actor sh -c 'status=0; "$0" -L "$1" "$1/service/initd.uc" start-and-wait start "" 40 >"$2/wait.out" 2>&1 || status=$?; echo "$status" >"$2/wait.status"' \
  "$REAL_UCODE" "$LIB" "$WORK_DIR"
START_ACTOR="$LAST_ACTOR"
wait_until 15 deferred_result || fail "the waiting caller was not told that the start was deferred"
start_actor "$PROKOP_SERVICE_INIT" stop
STOP_ACTOR="$LAST_ACTOR"
wait_until 20 group_done "$STOP_ACTOR" || fail "the stop did not finish"
wait_until 10 test -e "$WORK_DIR/wait.status" || fail "start-and-wait kept waiting for a start that a stop cancelled"
[ "$(cat "$WORK_DIR/wait.status")" != 0 ] || fail "a deferred start cancelled by a stop was reported as successful"
release_reload_lock
wait_until 20 group_done "$START_ACTOR" || fail "the deferred start is still at work after the stop"
no_event '^prokop start' || fail "a deferred start ran after an explicit stop"

# 6. A UI start: its job stays running and says that the start is deferred,
#    then finishes as success once the retried start has run.
export PROKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export PROKOP_UI_SERVICE_ACTION_DIR="$PROKOP_UI_STATE_DIR/service-actions"
export PROKOP_UI_SERVICE_ACTION_LOCK_DIR="$PROKOP_UI_STATE_DIR/service-actions.lock"
export PROKOP_UI_LATENCY_ACTION_DIR="$PROKOP_UI_STATE_DIR/latency-actions"
export PROKOP_UI_COMPONENT_ACTION_DIR="$PROKOP_UI_STATE_DIR/component-actions"
export PROKOP_UI_SUBSCRIPTION_ACTION_DIR="$PROKOP_UI_STATE_DIR/subscription-actions"
export PROKOP_UI_SERVICE_ACTION_SETTLE_SECONDS=1
export PROKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS=40
ui() { "$REAL_UCODE" -L "$LIB" "$LIB/service/ui.uc" "$@"; }
reset_case
hold_reload_lock
# The Start button: service_action_async launches the job worker.
started_json="$(ui service-action-async start)" || fail "the UI start was refused: $started_json"
job="$(printf '%s\n' "$started_json" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
[ -n "$job" ] || fail "the UI start named no job: $started_json"
UI_JOB="$PROKOP_UI_SERVICE_ACTION_DIR/$job.json"
job_deferred() { grep -q '"deferred": *true' "$UI_JOB" 2>/dev/null; }
job_finished() { grep -q '"running": *false' "$UI_JOB" 2>/dev/null; }
wait_until 15 job_deferred || fail "the UI start job does not say that the start is deferred: $(cat "$UI_JOB")"
# What the page polls: the job is still running, not failed.
status_json="$(ui service-action-status "$job")" || fail "the UI start job status could not be read"
printf '%s\n' "$status_json" | grep -q '"running": *true' ||
  fail "the UI start job of a deferred start is no longer running: $status_json"
printf '%s\n' "$status_json" | grep -q '"deferred": *true' || fail "the UI job status does not show the deferral: $status_json"
release_reload_lock
wait_until 30 job_finished || fail "the UI start job did not finish after the retried start: $(cat "$UI_JOB")"
grep -q '"success": *true' "$UI_JOB" || fail "the deferred UI start did not finish as success: $(cat "$UI_JOB")"
started_once "UI start"

# 7. A deferral that outlasts the UI job's bound: the job ends saying that the
#    start is still pending, not that it failed. The retried start that runs
#    after the job has ended opens a job of its own, as any start outside the
#    UI does, so the page shows it and refuses a second service action. Here
#    nothing but the UI worker marks the start as tracked by the UI.
reset_case
hold_reload_lock
started_json="$(PROKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS=4 env -u PROKOP_UI_ACTION_TRACKED \
  "$REAL_UCODE" -L "$LIB" "$LIB/service/ui.uc" service-action-async start)" ||
  fail "the UI start was refused: $started_json"
job="$(printf '%s\n' "$started_json" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
[ -n "$job" ] || fail "the UI start named no job: $started_json"
UI_JOB="$PROKOP_UI_SERVICE_ACTION_DIR/$job.json"
wait_until 20 job_finished || fail "the UI start job did not end at its bound: $(cat "$UI_JOB")"
no_event '^prokop start' || fail "the start ran while another process held reload.lock"
grep -q '"message": *"[^"]*still pending' "$UI_JOB" ||
  fail "the UI job of a start still deferred at its bound does not say that it is pending: $(cat "$UI_JOB")"
release_reload_lock
# The job that the retried start opened.
retried_start_job() {
  local path
  for path in "$PROKOP_UI_SERVICE_ACTION_DIR"/*.json; do
    [ "$path" != "$UI_JOB" ] || continue
    grep -q '"action": *"start"' "$path" 2>/dev/null && grep -q '"source": *"initd"' "$path" 2>/dev/null &&
      RETRIED_JOB="$path" && return 0
  done
  return 1
}
RETRIED_JOB=""
wait_until 20 test -e "$WORK_DIR/runtime.up" || fail "Prokop was not started after the lock was released"
wait_until 20 retried_start_job || fail "the retried start after the UI job had ended opened no job of its own"
wait_until 20 grep -q '"running": *false' "$RETRIED_JOB" || fail "the retried start's job did not finish: $(cat "$RETRIED_JOB")"
grep -q '"success": *true' "$RETRIED_JOB" || fail "the retried start's job did not finish as success: $(cat "$RETRIED_JOB")"
started_once "UI start beyond its bound"

# 8. Only a start's outcome is read from what its command prints. A UI stop
#    waits for init.d, not for a process that the stop leaves in the
#    background with that output open.
reset_case
: >"$WORK_DIR/runtime.up"
: >"$WORK_DIR/stop.background"
started_json="$(ui service-action-async stop)" || fail "the UI stop was refused: $started_json"
job="$(printf '%s\n' "$started_json" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
[ -n "$job" ] || fail "the UI stop named no job: $started_json"
UI_JOB="$PROKOP_UI_SERVICE_ACTION_DIR/$job.json"
wait_until 10 job_finished || fail "the UI stop job waited for a process that the stop left in the background: $(cat "$UI_JOB")"
rm -f "$WORK_DIR/stop.background"
grep -q '"success": *true' "$UI_JOB" || fail "the UI stop did not finish as success: $(cat "$UI_JOB")"

printf 'deferred start retry checks passed\n'
