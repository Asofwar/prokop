#!/usr/bin/env bash
set -euo pipefail

# The autotune worker lock belongs to the manager run alone (UC-055).
#
# The manager holds an flock on worker.lock for the whole run and spawns the
# isolation and apply tools meanwhile. An apply reloads Prokop, and the reload
# restarts long-lived production daemons (zapret supervisors, nfqws) from
# inside that tool chain. When the lock's file descriptor is inherited, these
# daemons keep the lock after the manager dies (SIGKILL, OOM): every later
# run, apply and job is refused as busy, and status keeps showing the dead
# run as running until zapret is restarted or the router reboots.
#
# Here the isolation stand-in starts a detached long-lived daemon from inside
# the run, the manager is killed, and the tool chain finishes on its own.
# Stand-ins: tests/helpers/autotune_scheduler.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

lock_free() { flock -n "$PROKOP_AUTOTUNE_STATE_DIR/worker.lock" true; }
tool_gone() { ! pgrep -f "$LIB/autotune/isolation.uc" >/dev/null 2>&1; }

manager policy-set mode recommend >/dev/null

# The tool of the run starts a daemon in its own session, as a reload during
# an apply restarts the zapret supervisors, then keeps the run busy until the
# test releases it.
cat >"$WORK/tune/www.youtube.com.hook" <<SH
setsid sh -c 'echo \$\$ >"\$0"; exec sleep 300' "$WORK/daemon.pid" </dev/null >/dev/null 2>&1 &
while [ ! -e "$WORK/hook.release" ] && [ -d "$WORK" ]; do sleep 0.05; done
SH

ucode -L "$LIB" "$LIB/autotune/manager.uc" run youtube >/dev/null 2>&1 &
run_pid=$!
BG_PIDS+=("$run_pid")
wait_until 20 test -s "$WORK/daemon.pid" || fail "the run did not start its daemon"
daemon_pid="$(cat "$WORK/daemon.pid")"
BG_PIDS+=("$daemon_pid")
wait_until 10 process_running "$daemon_pid" || fail "fixture: the daemon is not running"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.state)" = '"running"' ] || fail "fixture: the run is not marked running"
lock_free && fail "fixture: the live run does not hold the worker lock"

# The manager dies; its tool chain finishes without it.
kill -9 "$run_pid"
wait "$run_pid" 2>/dev/null || true
: >"$WORK/hook.release"
wait_until 20 tool_gone || fail "fixture: the isolation tool did not finish after the manager died"
process_running "$daemon_pid" || fail "fixture: the daemon did not outlive the manager"

wait_until 5 lock_free || fail "a daemon started during the run keeps the worker lock after the manager died"
manager status >"$WORK/status.json"
[ "$(json_get "$WORK/status.json" worker.state)" = '"crashed"' ] ||
  fail "the dead run is not reported crashed: $(cat "$WORK/status.json")"
manager run youtube >"$WORK/after.json" || true
[ "$(json_get "$WORK/after.json" status)" = '"ok"' ] ||
  fail "the next run is refused after the manager died: $(cat "$WORK/after.json")"
[ "$(json_get "$WORK/after.json" recovered.phase)" = '"measuring"' ] ||
  fail "the next run does not find the dead run: $(cat "$WORK/after.json")"

# The daemon lived through the whole check: nothing above waited for it.
process_running "$daemon_pid" || fail "fixture: the daemon ended early"
lock_free || fail "a finished run left the worker lock held"

printf 'autotune worker lock inheritance checks passed\n'
