#!/usr/bin/env bash
set -euo pipefail

# A start that keeps failing is retried with a backoff (LC-4). It was retried
# every 30 s for as long as it failed (WAN down at the first boot without a
# cache, unreachable subscriptions, a sing-box runtime error): each failure
# restarted dnsmasq, and with it DHCP, and wrote a start failure to the
# history on flash. Now the delay doubles from 30 s up to 30 min; WAN coming
# up starts the series over and a start that succeeds ends it. Only the
# first failure of a series goes to the history, and the DNS failsafe after
# a failed start restarts dnsmasq only when it changed something.
#
# service/initd.uc runs for real; `prokop start` and init.d are doubles.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
REAL_INITD="$ROOT_DIR/prokop/files/etc/init.d/prokop"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

cleanup() {
  local pid
  kill_retry_worker
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

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/prokop" "$WORK_DIR/tmp" "$WORK_DIR/rc.d"
printf 'prokop.settings=settings\n' >"$WORK_DIR/uci.state"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" EVENTS REAL_INITD
export TEST_LIB="$LIB"
export STATE_DIR="$WORK_DIR/run/prokop"
export PROKOP_LIB="$LIB"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/prokop.reload.lock"
export PROKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export PROKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export PROKOP_STOP_REQUESTED_FILE="$STATE_DIR/stop.requested"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RC_D_DIR="$WORK_DIR/rc.d"
export PROKOP_UI_ACTION_TRACKED=1

printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
case "$1" in
  start)
    status="$(cat "$TEST_WORK/start.status" 2>/dev/null || echo 1)"
    printf 'prokop start exit %s\n' "$status" >>"$EVENTS"
    [ "$status" != 0 ] || : >"$TEST_WORK/runtime.up"
    exit "$status"
    ;;
  get_status)
    if [ -e "$TEST_WORK/runtime.up" ]; then printf '{"running":1}\n'; else printf '{"running":0}\n'; fi
    ;;
esac
exit 0
SH
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
exec bash "$TEST_WORK/rc" "$@"
SH
cat >"$WORK_DIR/rc" <<'SH'
action="$1"
shift
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
PROKOP_LIB="$TEST_LIB"
PROKOP_INITD_UC="$TEST_LIB/service/initd.uc"
case "$action" in
  start) start_service "$@" ;;
  retry_start_on_wan_up) retry_start_on_wan_up ;;
  *) exit 64 ;;
esac
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

initd() { ucode -L "$LIB" "$LIB/service/initd.uc" "$@"; }

# The scheduled retry worker: `sh -c <script> sh <delay>`.
retry_worker() { head -n 1 "$STATE_DIR/start-retry.pid" 2>/dev/null || true; }
scheduled_delay() {
  local pid
  pid="$(retry_worker)"
  [ -n "$pid" ] && process_running "$pid" || return 1
  tr '\0' '\n' <"/proc/$pid/cmdline" | tail -n 1
}
# The worker goes first: with only its sleep killed it would run the retry.
kill_retry_worker() {
  local pid children child
  pid="$(retry_worker)"
  [ -n "$pid" ] || return 0
  children="$(pgrep -P "$pid" || true)"
  owned_kill KILL "$pid" || true
  for child in $children; do owned_kill KILL "$child" || true; done
  wait_until 5 process_gone "$pid" || true
  rm -f "$STATE_DIR/start-retry.pid"
}
reset_case() {
  kill_retry_worker
  rm -f "$STATE_DIR/start.retry" "$WORK_DIR/runtime.up" "$WORK_DIR/start.status"
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
}
attempts() { sed -n 's/^attempts=//p' "$STATE_DIR/start.retry"; }

# failed_start <reason> <attempts> <delay>: one more failed start, as the
# retry worker runs it once its delay is over.
failed_start() {
  local reason="$1" count="$2" delay="$3"
  kill_retry_worker
  initd start-service "$reason" >/dev/null 2>&1 && fail "a failing start reported success"
  [ "$(attempts)" = "$count" ] || fail "failed start $count recorded $(attempts) failed starts"
  [ "$(scheduled_delay)" = "$delay" ] || fail "the retry after failed start $count waits $(scheduled_delay || echo none) s, not $delay s"
  grep -q "scheduled an automatic retry in $delay s (failed starts in a row: $count)" "$WORK_DIR/syslog" ||
    fail "failed start $count does not log its retry delay"
}

# 1. The delay doubles from START_RETRY_DELAY_SECONDS up to the limit.
for pair in 1:30 2:60 3:120 4:240 5:480 6:960 7:1800 12:1800 0:30; do
  [ "$(initd start-retry-delay "${pair%%:*}")" = "${pair#*:}" ] ||
    fail "failed start ${pair%%:*} is retried after $(initd start-retry-delay "${pair%%:*}") s, not ${pair#*:} s"
done
[ "$(PROKOP_START_RETRY_DELAY_SECONDS=300 initd start-retry-delay 3)" = 1200 ] ||
  fail "the backoff ignores PROKOP_START_RETRY_DELAY_SECONDS"
[ "$(PROKOP_START_RETRY_MAX_DELAY_SECONDS=100 initd start-retry-delay 9)" = 100 ] ||
  fail "the backoff ignores PROKOP_START_RETRY_MAX_DELAY_SECONDS"

# 2. Failed starts in a row back off; a record of the previous version (no
#    count) is one failed start.
reset_case
failed_start "" 1 30
failed_start triggered 2 60
grep -q '^reason=wan_retry_failed$' "$STATE_DIR/start.retry" || fail "the failed retry is not recorded as one"
failed_start triggered 3 120
printf 'reason=start_failed\nupdated_at=1\n' >"$STATE_DIR/start.retry"
failed_start triggered 2 60
printf 'reason=start_deferred\nupdated_at=1\nstop_request=\n' >"$STATE_DIR/start.retry"
[ "$(initd start-retry-attempts "$STATE_DIR/start.retry")" = 0 ] ||
  fail "the retry of a deferred start counts as a failed start"

# 3. A start that succeeds ends the series.
reset_case
failed_start "" 1 30
failed_start triggered 2 60
printf '0\n' >"$WORK_DIR/start.status"
kill_retry_worker
initd start-service triggered >/dev/null 2>&1 || fail "the start that succeeds failed"
[ ! -e "$STATE_DIR/start.retry" ] || fail "a successful start left its retry series behind"
rm -f "$WORK_DIR/runtime.up" "$WORK_DIR/start.status"
failed_start "" 1 30

# 4. WAN coming up starts the series over: the retry waiting out a long delay
#    is cancelled, the start runs at once and a failure is retried after the
#    shortest delay again.
reset_case
: >"$PROKOP_RC_D_DIR/S99prokop"
printf 'reason=wan_retry_failed\nupdated_at=1\nattempts=6\n' >"$STATE_DIR/start.retry"
initd schedule-start-retry "$STATE_DIR/start-retry.pid" 1800 || fail "the long retry was not scheduled"
long_worker="$(retry_worker)"
initd handle-wan-up >/dev/null 2>&1 || true
wait_until 5 process_gone "$long_worker" || fail "WAN-up kept the retry waiting out its long delay"
grep -q '^prokop start exit 1$' "$EVENTS" || fail "WAN-up did not run the pending start"
[ "$(attempts)" = 1 ] || fail "WAN-up did not start the retry series over (failed starts: $(attempts))"
[ "$(scheduled_delay)" = 30 ] || fail "the start after WAN-up is retried after $(scheduled_delay || echo none) s, not 30 s"
rm -f "$PROKOP_RC_D_DIR/S99prokop"

# 5. The history on flash gets the first failed start of a series, not each
#    retry. The lifecycle start is the real one; it refuses at its first
#    check (a sing-box it does not own).
FAKE_LIB="$WORK_DIR/fake-lib"
mkdir -p "$FAKE_LIB/service" "$FAKE_LIB/diagnostics" "$FAKE_LIB/dns"
cat >"$FAKE_LIB/service/state.uc" <<'UC'
exit((ARGV[0] ?? "") == "prokop-running" ? 1 : 0);
UC
cat >"$FAKE_LIB/diagnostics/health.uc" <<'UC'
system("printf '%s\\n' 'health " + join(" ", ARGV) + "' >>" + getenv("EVENTS"));
UC
printf 'exit(0);\n' >"$FAKE_LIB/dns/apply.uc"
lifecycle_start() {
  env PROKOP_LIB="$FAKE_LIB" ucode -L "$LIB" "$LIB/service/lifecycle.uc" start >/dev/null 2>&1 &&
    fail "the lifecycle start next to a foreign sing-box succeeded"
  return 0
}
reset_case
lifecycle_start
grep -qx 'health record start failure' "$EVENTS" || fail "the first failed start is not in the history"
printf 'reason=start_failed\nupdated_at=1\nattempts=1\n' >"$STATE_DIR/start.retry"
: >"$EVENTS"
lifecycle_start
! grep -q '^health record start' "$EVENTS" || fail "a retry of a failed start is written to the history again"
printf 'reason=start_deferred\nupdated_at=1\nstop_request=\n' >"$STATE_DIR/start.retry"
lifecycle_start
grep -qx 'health record start failure' "$EVENTS" || fail "a failed deferred start is not in the history"

printf 'start retry backoff checks passed\n'
