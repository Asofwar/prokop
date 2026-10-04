#!/usr/bin/env bash
set -euo pipefail

# DPI provider supervisors keep their logs in RAM (/var/run). The log is
# trimmed, a binary that keeps failing is restarted less and less often, its
# restarts reach the status, and strategies cannot turn on per-packet debug
# output (OBS-3).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
supervisor_pid=""
cleanup() {
  if [ -n "$supervisor_pid" ]; then
    owned_kill KILL "$supervisor_pid" || :
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

# Module: trimming, backoff, counters.
cat >"$WORK_DIR/module.uc" <<'UC'
let fs = require("fs");
let respawn = require("providers.respawn");
const WORK = getenv("WORK_DIR");
function check(ok, message) {
    if (!ok) {
        warn("FAIL: " + message + "\n");
        exit(1);
    }
}
let log = WORK + "/rule.log";
let lines = "";
for (let i = 0; i < 400; i++)
    lines += sprintf("line %04d of the provider output\n", i);
fs.writefile(log, lines);
check(!respawn.trim_log(log, 64 * 1024), "a log under the limit was trimmed");
check(respawn.trim_log(log, 4096), "a log over the limit was not trimmed");
let kept = fs.readfile(log);
check(length(kept) <= 4096, "the trimmed log is " + length(kept) + " bytes");
check(index(kept, "line 0399 of the provider output\n") >= 0, "the newest output was lost");
check(index(kept, "line 0000") < 0, "the oldest output was kept");
check(match(split(kept, "\n")[1], /^line [0-9]{4} of the provider output$/) != null, "the trimmed log does not start at a line boundary");

check(respawn.next_delay(0, "5", 0) == 5, "the first respawn waits the base delay");
check(respawn.next_delay(5, "5", 1) == 10, "a quick failure doubles the delay");
check(respawn.next_delay(160, "5", 1) == 300, "the delay is capped at 300 s");
check(respawn.next_delay(300, "5", 1) == 300, "the delay stays at the cap");
check(respawn.next_delay(300, "5", 300) == 5, "a run of 5 minutes starts the count over");

check(respawn.restart_count(WORK + "/none") == 0, "a missing log dir has no restarts");
check(respawn.record_restart(log) == 1 && respawn.record_restart(log) == 2, "restarts are counted");
fs.writefile(WORK + "/other.restarts", "3\n");
check(respawn.restart_count(WORK) == 5, "restarts of all rules are summed");
UC
export WORK_DIR
ucode -L "$LIB" "$WORK_DIR/module.uc" || fail "respawn module checks failed"

# Validators: debug output only to syslog (nfqws) or off.
nfqueue_valid() {
  POSIXLY_CORRECT=1 ucode -L "$LIB" "$LIB/providers/nfqueue/validator.uc" validate-json "$1" "$2" |
    jq -e '.valid' >/dev/null
}
byedpi_valid() {
  POSIXLY_CORRECT=1 ucode -L "$LIB" "$LIB/providers/byedpi/validator.uc" validate-json "$1" |
    jq -e '.valid' >/dev/null
}
for kind in nfqws nfqws2; do
  for strategy in '--filter-tcp=443 --debug' '--filter-tcp=443 --debug=1' '--filter-tcp=443 --debug=@/etc/passwd'; do
    if nfqueue_valid "$kind" "$strategy"; then
      fail "$kind strategy '$strategy' must be refused"
    fi
  done
  for strategy in '--filter-tcp=443 --debug=syslog' '--filter-tcp=443 --debug=0'; do
    nfqueue_valid "$kind" "$strategy" || fail "$kind strategy '$strategy' must be accepted"
  done
done
for strategy in '-o 2 --debug 2' '-o 2 --debug=1' '-o 2 -x 1' '-o 2 -x2' '-o 2 -x'; do
  if byedpi_valid "$strategy"; then
    fail "ByeDPI strategy '$strategy' must be refused"
  fi
done
for strategy in '-o 2 --debug 0' '-o 2 -x0' '-o 2'; do
  byedpi_valid "$strategy" || fail "ByeDPI strategy '$strategy' must be accepted"
done

# A real supervisor around a binary that prints and dies at once.
mkdir -p "$WORK_DIR/byedpi/log" "$WORK_DIR/byedpi/child-pid"
cat >"$WORK_DIR/ciadpi" <<'SH'
#!/bin/sh
i=0
while [ "$i" -lt 40 ]; do
  echo "ciadpi noise line $i ............................................................"
  i=$((i + 1))
done
# Long enough for the supervisor to record its pid.
sleep 0.5
exit 3
SH
chmod +x "$WORK_DIR/ciadpi"
log="$WORK_DIR/byedpi/log/rule1.log"
BYEDPI_BIN="$WORK_DIR/ciadpi" BYEDPI_STATE_DIR="$WORK_DIR/byedpi" BYEDPI_RESPAWN_DELAY=1 \
  PROKOP_PROVIDER_LOG_MAX_BYTES=2048 PROKOP_LIB="$LIB" POSIXLY_CORRECT=1 \
  setsid ucode -L "$LIB" "$LIB/providers/byedpi/runtime.uc" supervisor rule1 1080 "-o 2" \
  "$WORK_DIR/byedpi/child-pid/rule1.pid" >>"$log" 2>&1 &
supervisor_pid=$!

backed_off() {
  grep -q 'respawning in 4 seconds' "$log"
}
wait_until 30 backed_off || {
  cat "$log" >&2
  fail "a binary that keeps failing was not backed off"
}
owned_kill KILL "$supervisor_pid" || :
wait "$supervisor_pid" 2>/dev/null || :
supervisor_pid=""

grep -q 'respawning in 1 seconds' "$log" || grep -q 'log trimmed by Prokop' "$log" ||
  fail "the first respawn did not wait the base delay"
size="$(wc -c <"$log")"
[ "$size" -le 6144 ] || fail "the supervisor log grew to $size bytes past its 2048-byte limit"

[ "$(cat "$WORK_DIR/byedpi/log/rule1.restarts")" -ge 3 ] || fail "the supervisor did not count its restarts"

grep -Fq 'return respawn.restart_count(BYEDPI_LOG_DIR);' "$LIB/providers/byedpi/runtime.uc" ||
  fail "ByeDPI status must count restarts from the supervisor counters"
grep -Fq 'restart_count: restarts,' "$LIB/providers/nfqueue/runtime.uc" ||
  fail "zapret and zapret2 status must report restarts"

printf 'DPI supervisor bound checks passed\n'
