#!/usr/bin/env bash
set -euo pipefail

# The scheduled start retry does not keep procd's service lock (R5).
#
# OpenWrt runs every init.d action with procd's lock on fd 1000. Every
# background process Prokop leaves behind closes it (the Priority and DNS
# failover workers, the start worker, the list worker); the start retry
# (service/initd.uc schedule_start_retry) did not: a retry scheduled from a
# caller that holds the lock slept up to its delay with fd 1000 open, and
# every init.d call of Prokop waited for it until procd's timeout. Without
# fd 1000 (dash takes "1000>&-" for an argument) nothing changes.
#
# The lock is closed by /bin/sh. busybox ash (OpenWrt) and bash close fd
# 1000; dash cannot address it at all, so on a host whose /bin/sh is dash
# only the scheduling with fd 1000 open is checked (NOT TESTED there: the
# close itself).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
W="$(mktemp -d)"
cleanup() {
  local pid
  pid="$(head -n1 "$W/run/start-retry.pid" 2>/dev/null || true)"
  [ -z "$pid" ] || pkill -KILL -P "$pid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  rm -rf "$W"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$W/run" "$W/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/init.log"\n' "$W" >"$W/bin/init"
chmod +x "$W/bin/init"
export PROKOP_RUNTIME_STATE_DIR="$W/run" PROKOP_SERVICE_INIT="$W/bin/init"
initd() { ucode -L "$LIB" "$LIB/service/initd.uc" "$@"; }

# Under procd's lock (fd 1000 held, as rc.common holds it).
(
  exec 1000>"$W/procd.lock"
  flock 1000
  initd schedule-start-retry "$W/run/start-retry.pid" 300
) || fail "the start retry was not scheduled"
pid="$(head -n1 "$W/run/start-retry.pid")"
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || fail "the scheduled start retry is not running"
if [ "$(/bin/sh -c 'exec 1000>&- 2>/dev/null; echo ok' 2>/dev/null)" = ok ]; then
  [ ! -e "/proc/$pid/fd/1000" ] || fail "the scheduled start retry keeps procd's lock (fd 1000)"
  flock -n "$W/procd.lock" true || fail "procd's lock is still held after the scheduling call returned"
else
  printf 'start_retry_procd_lock: /bin/sh cannot close fd 1000 (dash); the close itself is not checked here\n'
fi
initd cancel-scheduled-start-retry "$W/run/start-retry.pid"
for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
! kill -0 "$pid" 2>/dev/null || fail "the start retry was not cancelled"

# Without fd 1000 the retry is scheduled as before and still runs.
initd schedule-start-retry "$W/run/start-retry.pid" 1 || fail "the start retry was not scheduled without fd 1000"
for _ in $(seq 100); do [ -s "$W/init.log" ] && break; sleep 0.1; done
grep -Fxq retry_start_on_wan_up "$W/init.log" || fail "the start retry did not run: $(cat "$W/init.log" 2>/dev/null)"

printf 'start_retry_procd_lock: OK\n'
