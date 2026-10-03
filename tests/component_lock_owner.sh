#!/usr/bin/env bash
set -euo pipefail

# The component action lock goes through core/runtime_lock (UC-157).
#
# components/action.uc kept its own lock helper: mkdir, then <lock>/pid,
# kill -0 as the only liveness check, and a lock directory without a pid
# taken over at once. full-uninstall.sh creates the same lock with mkdir and
# writes its pid right after, so a component action that came in between
# broke the lock of a running removal. The lock now uses the protocol of the
# other runtime locks: an owner record published with the directory, a
# directory still being set up counts as held for a grace period, a dead
# owner's lock is taken over and only the owner releases it. The previous
# format (full-uninstall.sh, which runs while the packages are removed and
# cannot load Prokop modules) holds the lock while its pid runs.
#
# The action is the real components/action.uc with an unknown component: it
# takes the lock, then fails with "Unknown component action" and releases it.
#
# full-uninstall.sh start records its own pid, starts its worker in the
# background and exits; the worker records its pid once it runs. Until then
# the record must name the worker, not the starter that has exited, or a
# component action takes the lock and runs alongside the removal.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

pids=()
cleanup() {
  local pid
  for pid in "${pids[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

LOCK="$WORK/run/component-action.lock"
mkdir -p "$WORK/bin" "$WORK/run"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
# The first thing an action does with its lock is to create its temporary
# directory: mktemp holds it there while action.hold exists.
REAL_MKTEMP="$(command -v mktemp)"
cat >"$WORK/bin/mktemp" <<SH
#!/bin/sh
if [ -e "$WORK/action.hold" ]; then
  : >"$WORK/action.inside"
  while [ -e "$WORK/action.hold" ]; do sleep 0.05; done
fi
exec "$REAL_MKTEMP" "\$@"
SH
chmod +x "$WORK/bin/"*

action() {
  PATH="$WORK/bin:$PATH" PROKOP_RUNTIME_STATE_DIR="$WORK/run" UPDATES_LOCK_DIR="${ACTION_LOCK:-$LOCK}" \
    PROKOP_BIN="$WORK/no-prokop" PROKOP_SERVICE_INIT="$WORK/no-init" PROKOP_OPKG_RECOVERY_DIR="$WORK/recovery" \
    PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK/managed-upgrade" \
    ucode -L "$LIB" "$LIB/components/action.uc" component-action bogus nothing 2>/dev/null || true
}
state() { ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }
live_process() {
  sleep 600 &
  LIVE=$!
  pids+=("$LIVE")
}
passed_lock() { action | grep -q '"message": *"Unknown component action"'; }
refused() { action | grep -q 'Another component action is already running'; }

# 1. A free lock is taken and released.
passed_lock || fail "a component action did not take a free lock"
[ ! -e "$LOCK" ] || fail "a component action left its lock behind"

# 2. A running full removal holds the lock in the previous format.
live_process
mkdir "$LOCK"
printf '%s\n' "$LIVE" >"$LOCK/pid"
refused || fail "a component action ran during a full removal"
[ "$(cat "$LOCK/pid")" = "$LIVE" ] || fail "a refused component action changed the removal's lock"
# ... and its lock is taken over once the removal is gone.
kill -KILL "$LIVE"
wait "$LIVE" 2>/dev/null || true
passed_lock || fail "the lock of a dead removal was not taken over"
[ ! -e "$LOCK" ] || fail "a component action left its lock behind after a takeover"

# 3. A full removal that has created the lock but not yet written its pid.
mkdir "$LOCK"
refused || fail "a component action broke the lock of a removal that was still writing its pid"
[ -d "$LOCK" ] || fail "a refused component action removed a lock being set up"
rmdir "$LOCK"

# 4. Another component action holds the lock.
live_process
state acquire-runtime-dir-lock "$LOCK" "$LIVE" || fail "fixture: could not take the lock for a live owner"
refused || fail "a component action ran while another one held the lock"
[ "$(state runtime-dir-lock-owner "$LOCK")" = "$LIVE" ] || fail "a refused component action changed the lock owner"
state release-runtime-dir-lock "$LOCK" "$LIVE"

# 5. While an action holds the lock, full-uninstall.sh's mkdir fails and a
#    second action is refused; the owner is the action itself.
: >"$WORK/action.hold"
action >"$WORK/first.out" &
first=$!
pids+=("$first")
wait_until 20 test -e "$WORK/action.inside" || fail "the component action did not start"
owner="$(state runtime-dir-lock-owner "$LOCK" || true)"
[ -n "$owner" ] || fail "the lock of a running component action has no live owner"
tr '\0' ' ' <"/proc/$owner/cmdline" | grep -q 'components/action.uc component-action' ||
  fail "the lock owner is not the component action"
if mkdir "$LOCK" 2>/dev/null; then fail "full-uninstall.sh could take the lock of a running component action"; fi
refused || fail "a second component action ran concurrently"
rm -f "$WORK/action.hold"
wait_until 20 process_gone "$first" || fail "the component action did not finish"
wait "$first" 2>/dev/null || true
grep -q 'Unknown component action' "$WORK/first.out" || fail "the held component action did not complete"
[ ! -e "$LOCK" ] || fail "the component action left its lock behind"

# 6. full-uninstall.sh start hands the lock to its worker before it exits.
UROOT="$WORK/root"
ACTION_LOCK="$UROOT/var/run/prokop/component-action.lock"
mkdir -p "$UROOT"
: >"$WORK/worker.hold"
# The worker is started as `sh <job>/worker.sh worker ...`; it waits here,
# before it runs a line of the script, until worker.hold is removed.
cat >"$WORK/bin/sh" <<SH
#!/bin/sh
case "\${1:-}" in
  */worker.sh)
    : >"$WORK/worker.started"
    while [ -e "$WORK/worker.hold" ] && [ -d "$WORK" ]; do sleep 0.05; done
    exit 0 ;;
esac
exec /bin/sh "\$@"
SH
chmod +x "$WORK/bin/sh"
PATH="$WORK/bin:$PATH" PROKOP_UNINSTALL_ROOT="$UROOT" PROKOP_MIRROR_BASE_URL="http://mirror.test" \
  /bin/sh "$LIB/full-uninstall.sh" start >"$WORK/uninstall.out" </dev/null ||
  fail "full-uninstall.sh start failed: $(cat "$WORK/uninstall.out")"
wait_until 20 test -e "$WORK/worker.started" || fail "full-uninstall.sh did not start its worker"
record="$(cat "$ACTION_LOCK/pid")"
process_running "$record" || fail "the removal's lock names a process that has exited ($record)"
refused || fail "a component action ran while a full removal was handing its lock to its worker"
[ "$(cat "$ACTION_LOCK/pid")" = "$record" ] || fail "a refused component action changed the removal's lock"
rm -f "$WORK/worker.hold"
wait_until 20 process_gone "$record" || fail "the held removal worker did not exit"
unset ACTION_LOCK

printf 'component lock owner checks passed\n'
