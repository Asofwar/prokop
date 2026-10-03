#!/usr/bin/env bash
set -euo pipefail

# No dead SIGHUP path to sing-box (UC-157).
#
# service/state.uc kept a "hup-sing-box-runtime" operation from an earlier
# DNS-failover design: it sent SIGHUP to whatever PID procd reported for
# sing-box, checked by executable name only (no start ticks). Nothing calls
# it; DNS failover restarts sing-box through the controlled transition. A
# leftover signalling path that skips the process identity checks must not
# stay reachable, so the operation is gone and a sing-box procd reports is
# left alone.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

stand_in=""
cleanup() {
  if [ -n "$stand_in" ]; then
    owned_kill KILL "$stand_in" || true
    wait "$stand_in" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin"
# A running sing-box as procd reports it: an executable named sing-box that
# records any SIGHUP it receives.
cp "$(command -v bash)" "$WORK/bin/sing-box"
"$WORK/bin/sing-box" -c 'trap "echo hup >>\"$1\"" HUP; : >"$2"; while :; do sleep 0.1; done' \
  sing-box "$WORK/hup.log" "$WORK/ready" &
stand_in=$!
wait_until 10 test -e "$WORK/ready" || fail "fixture: the sing-box stand-in did not start"
[ "$(basename "$(readlink "/proc/$stand_in/exe")")" = sing-box ] || fail "fixture: the stand-in is not named sing-box"

cat >"$WORK/bin/ubus" <<SH
#!/bin/sh
printf '{"sing-box":{"instances":{"instance1":{"running":true,"pid":%s}}}}\n' "$stand_in"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod +x "$WORK/bin/ubus" "$WORK/bin/logger"

status=0
PATH="$WORK/bin:$PATH" ucode -L "$LIB" "$LIB/service/state.uc" hup-sing-box-runtime >"$WORK/out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "state.uc still accepts hup-sing-box-runtime"
grep -q '^Usage: service/state.uc' "$WORK/out" || fail "hup-sing-box-runtime is not an unknown operation: $(cat "$WORK/out")"
# A signal would have been handled by now: the trap runs between sleeps.
sleep 0.3
[ ! -s "$WORK/hup.log" ] || fail "state.uc sent SIGHUP to the sing-box procd reported"
process_running "$stand_in" || fail "the sing-box stand-in did not survive"

# rpcd is reloaded with killall -HUP; nothing signals a process by PID so.
source_refute "no production code may SIGHUP sing-box" -E '"kill", "-HUP"|SIGHUP reload|hup-sing-box' \
  "$LIB" "$ROOT_DIR/prokop/files/usr/bin/prokop" "$ROOT_DIR/prokop/files/etc/init.d/prokop"

printf 'sing-box SIGHUP path checks passed\n'
