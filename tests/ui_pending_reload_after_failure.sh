#!/usr/bin/env bash
set -euo pipefail

# A reload queued behind a UI service action (a Save & Apply while the
# action ran) is applied when the action ends, also when the action failed
# or timed out (LC-5). It used to be applied only after a successful action:
# after a failed reload the queued configuration stayed unapplied, and
# nothing said so. A failed start or restart still leaves the queue to its
# retry or the next start, and nothing is applied after an explicit stop or
# for a Prokop not started since boot (D-15).
#
# service/ui.uc runs for real; init.d is a double that records its calls.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

cleanup() {
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in "$EVENTS" "$WORK_DIR/syslog"; do
    [ ! -s "$log" ] || sed "s|^|  $(basename "$log"): |" "$log" >&2
  done
  exit 1
}

RUN="$WORK_DIR/run/prokop"
mkdir -p "$WORK_DIR/bin" "$RUN" "$WORK_DIR/tmp"
printf 'prokop.settings=settings\n' >"$WORK_DIR/uci.state"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" EVENTS
export PROKOP_LIB="$LIB"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_UI_STATE_DIR="$RUN/ui-state"
export PROKOP_PENDING_RELOAD_FILE="$RUN/reload.pending"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/prokop.reload.lock"
export PROKOP_START_IN_PROGRESS_FILE="$RUN/start.in-progress"
export PROKOP_STOP_REQUESTED_FILE="$RUN/stop.requested"
export PROKOP_EXPLICIT_START_FILE="$RUN/start.explicit"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$RUN"

printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
printf 'init %s\n' "$*" >>"$EVENTS"
exit 0
SH
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
[ "$1" != get_status ] || printf '{"running":1}\n'
exit 0
SH
chmod +x "$WORK_DIR/bin/"*

ui() { ucode -L "$LIB" "$LIB/service/ui.uc" "$@"; }

reset_case() {
  wait_until 30 workers_gone || fail "a service action worker of the previous case is still running"
  rm -rf "$PROKOP_UI_STATE_DIR"
  rm -f "$PROKOP_PENDING_RELOAD_FILE" "$PROKOP_STOP_REQUESTED_FILE"
  : >"$PROKOP_EXPLICIT_START_FILE"
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
}
workers_gone() { ! pgrep -f "service-action-worker $PROKOP_UI_STATE_DIR" >/dev/null 2>&1; }

# finish <action> <status>: a UI job for the action, with a reload queued
# behind it, ends with that status.
finish() {
  local action="$1" status="$2" job
  job="$(ui service-action-begin-if-idle "$action" ui)" || fail "no $action job could be opened"
  printf 'reason=on_config_change\nupdated_at=1\nrequest=1\n' >"$PROKOP_PENDING_RELOAD_FILE"
  ui service-action-finish-after-command "$action" "$job" "$status" >/dev/null 2>&1 || true
}
applied() {
  wait_until 20 grep -qx 'init reload pending' "$EVENTS" || return 1
  [ ! -e "$PROKOP_PENDING_RELOAD_FILE" ]
}
kept() {
  sleep 0.5
  ! grep -q '^init reload' "$EVENTS" && [ -e "$PROKOP_PENDING_RELOAD_FILE" ]
}

# 1. A reload that failed: the reload queued behind it runs.
reset_case
finish reload 1
applied || fail "the reload queued behind a failed reload was not applied"
grep -q 'Applying pending Prokop reload' "$WORK_DIR/syslog" || fail "the queued reload is not logged"

# 2. Control: after a reload that succeeded as well.
reset_case
finish reload 0
applied || fail "the reload queued behind a successful reload was not applied"

# 3. Not after an explicit stop, nor for a Prokop not started since boot.
reset_case
printf '1\n' >"$PROKOP_STOP_REQUESTED_FILE"
finish reload 1
kept || fail "a reload queued behind a failed reload ran after an explicit stop"
reset_case
rm -f "$PROKOP_EXPLICIT_START_FILE"
finish reload 1
kept || fail "a reload queued behind a failed reload ran for a Prokop not started since boot"

# 4. A failed start or restart leaves the queue to the start that follows.
for action in start restart; do
  reset_case
  finish "$action" 1
  kept || fail "a reload queued behind a failed $action ran on its own"
done

reset_case
printf 'ui pending reload after failure checks passed\n'
