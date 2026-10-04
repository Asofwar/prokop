#!/usr/bin/env bash
set -euo pipefail

# full-uninstall.sh start hands its locks to the worker in order (UC-157
# follow-up).
#
# The starter takes the removal lock (/var/run/prokop/full-uninstall.lock) and
# the component action lock, starts the worker in the background, names the
# worker in both lock records and exits. A worker that failed at once (no
# original repositories to restore, no package manager) could reach its
# finish() before the starter's write: finish() removed the pid record, the
# starter wrote it again, and the rmdir that followed failed. The removal
# lock, which has no stale check, then named a dead process, and every later
# removal and every lifecycle command was refused until a reboot. The worker
# now waits until the starter has written the records ($JOB/started) or has
# exited, before it records itself or runs; nothing writes a record after
# the worker may have finished.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/prokop/files/usr/lib/full-uninstall.sh"
REAL_SLEEP="$(command -v sleep)"
WORK="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

pids=()
cleanup() {
  local pid
  owned_kill KILL "${pids[@]}" || true
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/worker.log" ] || sed 's/^/  worker: /' "$WORK/worker.log" >&2
  exit 1
}

# sleep: the status cleanup (sleep 300) lasts as long as this test; a pause
# of the worker's wait for the starter is marked and shortened.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/sleep" <<SH
#!/bin/sh
case "\$1" in
  300) while [ -d "$WORK" ]; do "$REAL_SLEEP" 0.1; done; exit 0 ;;
  1) : >"$WORK/worker.waiting"; exec "$REAL_SLEEP" 0.2 ;;
esac
exec "$REAL_SLEEP" "\$@"
SH
chmod +x "$WORK/bin/sleep"
export PATH="$WORK/bin:$PATH" PROKOP_MIRROR_BASE_URL="http://mirror.test"

# fixture NAME: a root whose only feed points at the mirror and has no
# original to restore, so the worker fails at once.
fixture() {
  UROOT="$WORK/root-$1"
  LOCK="$UROOT/var/run/prokop/full-uninstall.lock"
  ACTION_LOCK="$UROOT/var/run/prokop/component-action.lock"
  mkdir -p "$UROOT/etc/opkg" "$UROOT/tmp" "$UROOT/www" "$UROOT/var/run/prokop"
  printf 'src/gz openwrt http://mirror.test/openwrt/releases/test\n' >"$UROOT/etc/opkg/distfeeds.conf"
  export PROKOP_UNINSTALL_ROOT="$UROOT"
  rm -f "$WORK/worker.waiting"
}

# A starter that took both locks and started WORKER, as `start` does.
starter_took_locks() {
  "$REAL_SLEEP" 600 &
  starter=$!
  pids+=("$starter")
  mkdir "$LOCK" "$ACTION_LOCK"
  printf '%s\n' "$starter" >"$LOCK/pid"
  printf '%s\n' "$starter" >"$ACTION_LOCK/pid"
  JOB="$WORK/job-$1"
  mkdir "$JOB"
  sh "$SCRIPT" worker "$JOB" "$UROOT/www/status.json" "$starter" >"$WORK/worker.log" 2>&1 &
  worker=$!
  pids+=("$worker")
}

waiting_or_gone() { [ -e "$WORK/worker.waiting" ] || process_gone "$worker"; }

released() {
  wait_until 20 process_gone "$worker" || fail "$1: the worker did not finish"
  [ ! -e "$LOCK" ] || fail "$1: the removal lock was left behind ($(cat "$LOCK/pid" 2>/dev/null || true))"
  [ ! -e "$ACTION_LOCK" ] || fail "$1: the component action lock was left behind"
  grep -Fq '"state":"failed","phase":"preflight"' "$UROOT/www/status.json" || fail "$1: the removal did not fail its preflight"
}

# 1. The worker waits for the starter's hand-off before it records itself
#    or runs; the records name the live starter meanwhile.
fixture handoff
starter_took_locks handoff
wait_until 20 waiting_or_gone || fail "1: the worker neither ran nor waited"
process_running "$worker" || fail "1: the worker ran before the starter had written the lock records"
[ "$(cat "$LOCK/pid")" = "$starter" ] || fail "1: the worker recorded itself before the hand-off"
[ ! -e "$UROOT/www/status.json" ] || fail "1: the worker started the removal before the hand-off"
printf '%s\n' "$worker" >"$LOCK/pid"
printf '%s\n' "$worker" >"$ACTION_LOCK/pid"
: >"$JOB/started"
released 1

# 2. A starter that exited without the hand-off does not hold the worker.
fixture starter_gone
starter_took_locks starter_gone
wait_until 20 waiting_or_gone || fail "2: the worker neither ran nor waited"
kill -KILL "$starter"
wait "$starter" 2>/dev/null || true
released 2

# 3. The real start: the worker runs after the hand-off and releases both
#    locks.
fixture start
sh "$SCRIPT" start >"$WORK/start.out" </dev/null || fail "3: start failed: $(cat "$WORK/start.out")"
grep -Fq '"success":true' "$WORK/start.out" || fail "3: start did not report the removal: $(cat "$WORK/start.out")"
wait_until 20 test ! -e "$LOCK" || fail "3: the removal lock was left behind"
wait_until 20 test ! -e "$ACTION_LOCK" || fail "3: the component action lock was left behind"
for job in "$UROOT"/tmp/prokop-uninstall.*; do
  [ -e "$job/started" ] || fail "3: the starter did not mark the hand-off"
done
wait_until 20 grep -Fq '"state":"failed","phase":"preflight"' "$UROOT"/www/prokop-uninstall.*.json ||
  fail "3: the removal did not fail its preflight"

# 4. A removal lock whose removal was killed is taken over (CFG-3); one
#    whose removal runs is not.
fixture stale
"$REAL_SLEEP" 0 &
dead=$!
wait "$dead" || true
mkdir "$LOCK"
printf '%s\n' "$dead" >"$LOCK/pid"
sh "$SCRIPT" start >"$WORK/start.out" </dev/null || fail "4: a stale removal lock refused the removal: $(cat "$WORK/start.out")"
grep -Fq '"success":true' "$WORK/start.out" || fail "4: start did not report the removal: $(cat "$WORK/start.out")"
wait_until 20 test ! -e "$LOCK" || fail "4: the removal lock was left behind"
fixture running
sh -c 'while :; do "$1" 1; done' "$UROOT/full-uninstall.sh" "$REAL_SLEEP" &
running=$!
pids+=("$running")
wait_until 20 grep -q full-uninstall "/proc/$running/cmdline" || fail "5: the running removal did not start"
mkdir "$LOCK"
printf '%s\n' "$running" >"$LOCK/pid"
sh "$SCRIPT" start >"$WORK/start.out" </dev/null && fail "5: a second removal started next to a running one"
grep -Fq 'Removal is already running' "$WORK/start.out" || fail "5: the second removal does not say why: $(cat "$WORK/start.out")"
[ "$(cat "$LOCK/pid")" = "$running" ] || fail "5: the second removal took the lock of the running one"

printf 'full_uninstall_lock_handoff: ok\n'
