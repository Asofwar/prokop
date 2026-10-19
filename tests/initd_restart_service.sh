#!/usr/bin/env bash
set -euo pipefail

# init.d restart of a running Prokop is one runtime transition (`prokop
# restart`), not a stop and a start: rc.common's stop and start would hand
# dnsmasq back to the upstream resolvers in between, and clients would cache
# real addresses that bypass FakeIP after the start. A start-and-wait caller
# (the UI, a component action) gets the restart's result. A restart refused
# before its stop keeps the running Prokop and schedules no retry; one that
# took Prokop down is retried as a failed start is. A stopped Prokop, or one
# whose reload.lock stays busy, is stopped and started as before.
#
# The init script is the real one behind an rc.common stand-in that holds the
# procd lock on fd 1000 like procd.sh; service/initd.uc and the lock helpers
# are real; `prokop` is a double.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
REAL_INITD="$ROOT_DIR/prokop/files/etc/init.d/prokop"
REAL_UCODE="$(command -v ucode)"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

actors=()
cleanup() {
  owned_kill KILL "${actors[@]}" || true
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
# A scheduled retry must not run within a case.
export PROKOP_START_RETRY_DELAY_SECONDS=300
export PROKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS=1
export PROKOP_START_WAIT_TIMEOUT_SECONDS=30
export PROKOP_START_SETTLE_SECONDS=3
export PROKOP_UI_ACTION_TRACKED=1
export PROKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export PROKOP_UI_COMPONENT_ACTION_DIR="$PROKOP_UI_STATE_DIR/component-actions"
export PROKOP_UI_SUBSCRIPTION_ACTION_DIR="$PROKOP_UI_STATE_DIR/subscription-actions"

# Nothing here may reach the host's syslog, nftables or init scripts.
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"

# `prokop`: start brings the modelled runtime up, stop takes it down. restart
# succeeds, is refused before its stop (restart.refuse) or takes the runtime
# down and fails (restart.fail).
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
ev() { printf '%s\n' "$1" >>"$EVENTS"; }
case "$1" in
  start) ev "prokop start"; : >"$TEST_WORK/runtime.up" ;;
  stop) ev "prokop stop"; rm -f "$TEST_WORK/runtime.up" ;;
  restart)
    owner="$(ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" runtime-dir-lock-owner "$RELOAD_LOCK" || true)"
    cmd=""
    [ -z "$owner" ] || cmd="$(tr '\0' ' ' <"/proc/$owner/cmdline" 2>/dev/null || true)"
    case "$cmd" in
      *"service/initd.uc restart-service"*) ev "prokop restart" ;;
      *) ev "prokop restart (without reload.lock)" ;;
    esac
    [ ! -e "$TEST_WORK/restart.refuse" ] || exit 1
    if [ -e "$TEST_WORK/restart.fail" ]; then
      rm -f "$TEST_WORK/runtime.up"
      exit 1
    fi
    : >"$TEST_WORK/runtime.up"
    ;;
  get_status)
    if [ -e "$TEST_WORK/runtime.up" ]; then printf '{"running":1}\n'; else printf '{"running":0}\n'; fi
    ;;
esac
exit 0
SH

# /etc/init.d/prokop as procd runs it: rc.common with the procd lock on fd
# 1000 and its stop, start and restart. bash stands in for busybox ash.
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
start() { start_service "$@"; service_started; }
stop() { stop_service "$@"; }
rc_procd() { printf '%s\n' "procd register" >>"$EVENTS"; "$@"; }
# shellcheck disable=SC1090
. "$REAL_INITD"
PROKOP_LIB="$TEST_LIB"
PROKOP_INITD_UC="$TEST_LIB/service/initd.uc"
case "$action" in
  start) start "$@" ;;
  stop) stop "$@" ;;
  restart) restart "$@" ;;
  *) exit 64 ;;
esac
SH

# The restart-blocked check asks service/state.uc about foreign sing-box
# processes; service/ui.uc whether the runtime runs stably.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "${3:-}" in
  */service/state.uc)
    case "${4:-}" in
      foreign-sing-box-present) exit 1 ;;
      prokop-stably-running) [ -e "$TEST_WORK/runtime.up" ]; exit $? ;;
    esac
    ;;
  */dns/apply.uc | */diagnostics/health.uc) exit 0 ;;
esac
exec "$REAL_UCODE" "$@"
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

initd() { "$REAL_UCODE" -L "$LIB" "$LIB/service/initd.uc" "$@"; }
has_event() { grep -qx "$1" "$EVENTS" 2>/dev/null; }
no_event() { ! grep -qx "$1" "$EVENTS" 2>/dev/null; }

reset_case() {
  : >"$EVENTS"
  rm -f "$WORK_DIR/restart.refuse" "$WORK_DIR/restart.fail" "$STATE_DIR/start.retry" \
    "$STATE_DIR/stop.requested"
  initd cancel-scheduled-start-retry >/dev/null 2>&1 || true
}

restart_and_wait() {
  local status=0
  setsid timeout -s KILL 60 "$REAL_UCODE" -L "$LIB" "$LIB/service/initd.uc" start-and-wait restart "" 30 \
    >"$WORK_DIR/wait.out" 2>&1 &
  local pid=$!
  actors+=("$pid")
  wait "$pid" || status=$?
  return "$status"
}

# 1. Running: one `prokop restart` under reload.lock, no stop and no start,
# the service stays registered, the caller gets the result.
reset_case
: >"$WORK_DIR/runtime.up"
restart_and_wait || fail "the restart of a running Prokop failed"
has_event "prokop restart" || fail "a running Prokop was not restarted in one transition"
no_event "prokop stop" || fail "the restart of a running Prokop ran init.d's stop"
no_event "prokop start" || fail "the restart of a running Prokop ran init.d's start"
has_event "procd register" || fail "the restart did not keep the service registered"
[ ! -e "$STATE_DIR/stop.requested" ] || fail "the restart left a stop request"
[ ! -e "$RELOAD_LOCK" ] || fail "the restart kept reload.lock"

# 2. Refused before its stop: Prokop runs on, the caller learns the failure,
# no retry.
reset_case
: >"$WORK_DIR/runtime.up"; : >"$WORK_DIR/restart.refuse"
if restart_and_wait; then
  fail "a refused restart was reported as done"
fi
[ -e "$WORK_DIR/runtime.up" ] || fail "a refused restart took Prokop down"
[ ! -e "$STATE_DIR/start.retry" ] || fail "a refused restart scheduled a start retry"

# 3. Failed after its stop: Prokop is down, a retry is scheduled as after a
# failed start.
reset_case
: >"$WORK_DIR/runtime.up"; : >"$WORK_DIR/restart.fail"
if restart_and_wait; then
  fail "a failed restart was reported as done"
fi
[ ! -e "$WORK_DIR/runtime.up" ] || fail "the modelled restart failure kept Prokop up"
[ -e "$STATE_DIR/start.retry" ] || fail "a restart that took Prokop down scheduled no start retry"

# 4. Stopped: init.d's stop and start, as before.
reset_case
rm -f "$WORK_DIR/runtime.up"
restart_and_wait || fail "the restart of a stopped Prokop failed"
has_event "prokop start" || fail "the restart of a stopped Prokop did not start it"
no_event "prokop restart" || fail "a stopped Prokop was restarted as a running one"

echo "initd_restart_service: OK"
