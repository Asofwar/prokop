#!/usr/bin/env bash
set -euo pipefail

# Waits and deadlines run on the monotonic clock, and the boot-time NTP query
# is bounded (LC-6, A5). A router without an RTC boots in the past and NTP
# then steps the wall clock forward by months: a wait measured on the wall
# clock (the 300 s wait for the subscription update lock, the start and UI
# action waits) ended at once. `ntpd -q`, run under reload.lock when the year
# is before 2024, never returned without an answer (WAN down, NTP blocked).
#
# service/state.uc runs for real; `date` and ntpd are doubles. `date` steps
# the wall clock by a year at every call.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

holder=""
cleanup() {
  [ -z "$holder" ] || owned_kill KILL "$holder" || true
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR"
cat >"$WORK_DIR/bin/date" <<'SH'
#!/bin/sh
case "$1" in
  +%Y) echo 2000 ;;
  +%s)
    step="$(cat "$TEST_WORK/step" 2>/dev/null || echo 0)"
    echo $((step + 1))>"$TEST_WORK/step"
    echo $((946684800 + step * 31536000))
    ;;
  *) exec /bin/date "$@" ;;
esac
SH
cat >"$WORK_DIR/bin/ntpd" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >"$TEST_WORK/ntpd.args"
exec sleep 120
SH
chmod +x "$WORK_DIR/bin/"*

state() { ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }

# 1. The NTP query of a clock in the past ends after its bound.
started=$SECONDS
PROKOP_NTPD="$WORK_DIR/bin/ntpd" PROKOP_NTPD_QUERY_TIMEOUT_SECONDS=1 state sync-time-if-needed
[ -s "$WORK_DIR/ntpd.args" ] || fail "a clock in the past was not set by NTP"
grep -q -- '-q' "$WORK_DIR/ntpd.args" || fail "ntpd was not asked for one query"
[ $((SECONDS - started)) -lt 10 ] || fail "the NTP query without an answer ran for $((SECONDS - started)) s"

# 2. A lock wait lasts its timeout also while the wall clock steps.
lock="$WORK_DIR/reload.lock"
sleep 300 &
holder=$!
state acquire-runtime-dir-lock "$lock" "$holder" || fail "the holder did not get the lock"
started=$SECONDS
state acquire-runtime-dir-lock-wait "$lock" "$$" 3 && fail "the lock was taken from its running holder"
[ $((SECONDS - started)) -ge 3 ] ||
  fail "a 3 s lock wait ended after $((SECONDS - started)) s when the wall clock stepped"

printf 'time step wait checks passed\n'
