#!/usr/bin/env bash
set -euo pipefail

# Lock order between reload.lock and subscription-update.lock (UC-054).
# A start holds reload.lock (service/initd.uc) for the whole `prokop start`,
# and start_main takes subscription-update.lock inside it. A forced
# subscription update (components/updates.uc) must take the two locks in the
# same order: otherwise an update that arrives while a start holds reload.lock
# takes subscription-update.lock, waits for reload.lock, and the start waits
# for subscription-update.lock in turn, both for up to 300 s.
#
# The start is the real init.d start_service and service/initd.uc; its
# backend stands in for lifecycle.uc start_main and takes
# subscription-update.lock through the real service/state.uc, as start_main
# does. The update is the real subscription update with a stubbed cache
# request; its locks go through the real service/state.uc as well. Each actor
# runs in its own process group under a deadline, so a deadlock fails the
# test within seconds instead of hanging it. Both orders are checked: the
# update arriving while the start holds reload.lock, and the start arriving
# while the update holds its locks. Each order runs with a start that waits
# in its rc.common shell and with the detached start that rcS and procd get
# (fd 1000 open), whose worker holds reload.lock itself (UC-010).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
REAL_INITD="$ROOT_DIR/prokop/files/etc/init.d/prokop"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

actors=()
cleanup() {
  local pid
  for pid in "${actors[@]}"; do
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
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
  exit 1
}

# A deadlocked pair waits 300 s on each other; everything that completes
# finishes within a few lock polling rounds.
DEADLINE_SECONDS=25

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/prokop" "$WORK_DIR/tmp" "$WORK_DIR/fake-lib/service" "$WORK_DIR/fake-lib/subscription"
printf 'prokop.settings=settings\n' >"$WORK_DIR/uci.state"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS REAL_LIB REAL_INITD
export TEST_LIB="$REAL_LIB"
export RELOAD_LOCK="$WORK_DIR/run/prokop.reload.lock"
export SUB_LOCK="$WORK_DIR/run/prokop/subscription-update.lock"
export PROKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK"
export PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$SUB_LOCK"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/prokop"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/prokop/reload.pending"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export A_OWNER_FILE="$WORK_DIR/a.owner"

# Nothing here may reach the host's syslog or init scripts.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/no-init"

# The start's backend: `prokop start` under the reload.lock that initd.uc
# holds. Like lifecycle.uc start_main it waits for subscription-update.lock
# (300 s) with its own live pid as the owner.
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
ev() { printf '%s\n' "$1" >>"$EVENTS"; }
state() { ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" "$@"; }
case "$1" in
  start)
    state runtime-dir-lock-owner "$RELOAD_LOCK" >"$A_OWNER_FILE"
    ev "A start begin"
    if [ -n "${A_GATE:-}" ]; then
      n=0
      while [ ! -e "$A_GATE" ]; do
        n=$((n + 1))
        [ "$n" -lt 600 ] || { ev "A gate timeout"; exit 1; }
        sleep 0.05
      done
    fi
    state acquire-runtime-dir-lock-wait "$SUB_LOCK" "$$" 300 || { ev "A sub timeout"; exit 1; }
    ev "A sub acquired"
    sleep 0.3
    ev "A sub released"
    state release-runtime-dir-lock "$SUB_LOCK" "$$"
    ev "A start end"
    exit 0
    ;;
  get_status) printf '{"running":false}\n' ;;
esac
exit 0
SH

# rc.common stand-in: `rc <action> [args]` sources the real init script and
# runs its handler. Without RC_PROCD_LOCK the start runs synchronously and
# the waiting rc.common shell ($$) is a live reload.lock owner. With it, fd
# 1000 is open as under procd.sh and start_service detaches its worker; bash
# runs the stand-in then, since dash has no file descriptors above 9.
cat >"$WORK_DIR/rc" <<'SH'
#!/bin/sh
action="$1"
shift
if [ -n "${RC_PROCD_LOCK:-}" ]; then
  # procd.sh procd_lock: fd 1000 is open (and flocked) at source time.
  exec 1000>"$RC_PROCD_LOCK"
  flock 1000
fi
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
PROKOP_LIB="$TEST_LIB"
PROKOP_INITD_UC="$TEST_LIB/service/initd.uc"
case "$action" in
  start) start_service "$@" ;;
  reload) reload_service "$@" ;;
  *) exit 64 ;;
esac
SH

# The update's lock calls go to the real service/state.uc; each call is
# recorded around it so the test can see who held which lock when.
cat >"$WORK_DIR/fake-lib/service/state.uc" <<'UC'
let fs = require("fs");
function q(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
function ev(line) { system("printf '%s\\n' " + q(line) + " >> " + q(getenv("EVENTS"))); }
let mode = "" + (ARGV[0] ?? "");
let lock = "" + (ARGV[1] ?? "");
let name = lock == getenv("RELOAD_LOCK") ? "reload" : lock == getenv("SUB_LOCK") ? "sub" : lock;
let tracked = index(mode, "runtime-dir-lock") >= 0;
let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/service/state.uc");
for (let arg in ARGV)
    command += " " + q(arg);
if (tracked)
    ev("B call " + mode + " " + name);
let status = system(command);
if (tracked && index(mode, "acquire") == 0)
    ev("B " + mode + " " + name + " rc=" + status);
exit(status);
UC

# The cache request holds the update inside its locked region until B_GATE
# exists, then reports an unchanged cache so no runtime transition follows.
cat >"$WORK_DIR/fake-lib/subscription/cache.uc" <<'UC'
let fs = require("fs");
function q(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
function ev(line) { system("printf '%s\\n' " + q(line) + " >> " + q(getenv("EVENTS"))); }
let mode = "" + (ARGV[0] ?? "");
if (mode == "ensure-runtime-dirs")
    exit(0);
if (mode == "update-request") {
    ev("B update begin");
    let gate = getenv("B_GATE") || "";
    for (let n = 0; gate != "" && fs.stat(gate) == null && n < 600; n++)
        system("sleep 0.05");
    ev("B update end");
    print("0 0 1 0\n");
    exit(0);
}
exit(64);
UC
chmod +x "$WORK_DIR/bin/prokop" "$WORK_DIR/bin/logger" "$WORK_DIR/bin/no-init" "$WORK_DIR/rc"

A_PID=""
B_PID=""

# Actors run in their own process group (setsid execs in place, so the pid
# is the group id) under a hard kill deadline as a second safety net.
start_actor() {
  setsid timeout -s KILL 90 "$@" &
  LAST_ACTOR=$!
  actors+=("$LAST_ACTOR")
}

RC_MODE=sync
launch_start() {
  local shell=sh procd_lock=""
  if [ "$RC_MODE" = detached ]; then
    shell=bash
    procd_lock="$WORK_DIR/procd_prokop.lock"
  fi
  start_actor env PROKOP_UI_ACTION_TRACKED=1 PROKOP_BIN="$WORK_DIR/bin/prokop" \
    PROKOP_START_RUNTIME_LOCK_WAIT_SECONDS=20 PROKOP_START_RETRY_DELAY_SECONDS=300 \
    RC_PROCD_LOCK="$procd_lock" A_GATE="${A_GATE:-}" "$shell" "$WORK_DIR/rc" start manual >"$WORK_DIR/a.out" 2>&1
  A_PID="$LAST_ACTOR"
}

# The synchronous start is over when its rc.common shell returns. The detached
# one returns at once; its worker, the reload.lock owner the backend saw, runs
# until it has released the lock.
start_done() {
  process_gone "$A_PID" || return 1
  [ "$RC_MODE" = detached ] || return 0
  has_event '^A start end$' && [ -s "$A_OWNER_FILE" ] && process_gone "$(cat "$A_OWNER_FILE")"
}

launch_update() {
  start_actor env PROKOP_LIB="$WORK_DIR/fake-lib" B_GATE="${B_GATE:-}" \
    ucode -L "$REAL_LIB" "$REAL_LIB/components/updates.uc" subscription-update >"$WORK_DIR/b.out" 2>&1
  B_PID="$LAST_ACTOR"
}

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }

reset_case() {
  : >"$EVENTS"
  rm -f "$WORK_DIR/a.gate" "$WORK_DIR/b.gate" "$PROKOP_PENDING_RELOAD_FILE" "$A_OWNER_FILE"
  [ ! -e "$RELOAD_LOCK" ] || fail "reload.lock leaked from the previous case"
  [ ! -e "$SUB_LOCK" ] || fail "subscription-update.lock leaked from the previous case"
}

# Both actors must finish before the deadline; a pair still waiting on each
# other is the deadlock.
finish_case() {
  local label="$1" status
  if ! wait_until "$DEADLINE_SECONDS" start_done ||
    ! wait_until "$DEADLINE_SECONDS" process_gone "$B_PID"; then
    fail "$label: start and subscription update deadlocked on reload.lock/subscription-update.lock"
  fi
  status=0
  wait "$A_PID" || status=$?
  [ "$status" = 0 ] || fail "$label: start failed with status $status: $(cat "$WORK_DIR/a.out")"
  status=0
  wait "$B_PID" || status=$?
  [ "$status" = 0 ] || fail "$label: subscription update failed with status $status: $(cat "$WORK_DIR/b.out")"
  has_event '^A start end$' || fail "$label: the start backend did not finish"
  has_event '^B update end$' || fail "$label: the subscription update did not run"
  [ ! -e "$RELOAD_LOCK" ] || fail "$label: reload.lock was left behind"
  [ ! -e "$SUB_LOCK" ] || fail "$label: subscription-update.lock was left behind"
  [ ! -e "$PROKOP_PENDING_RELOAD_FILE" ] || fail "$label: a lock wait gave up and queued a reload"
  exclusive "$label"
}

# The start (inside reload.lock) and the update's cache request (inside both
# locks) never overlap, and nobody takes reload.lock or
# subscription-update.lock while the other one holds it.
exclusive() {
  awk -v label="$1" '
    /^B update begin$/ { if (a_in) bad = "the update ran inside the start"; b_in = 1 }
    /^B update end$/ { b_in = 0 }
    /^A start begin$/ {
      if (b_in) bad = "the start ran inside the update"
      if (b_reload) bad = "the start took reload.lock from the update"
      a_in = 1
    }
    /^A start end$/ { a_in = 0 }
    /^B acquire-runtime-dir-lock(-wait)? reload rc=0$/ {
      if (a_in) bad = "the update took reload.lock from the start"
      b_reload = 1
    }
    /^B call release-runtime-dir-lock reload$/ { b_reload = 0 }
    /^B acquire-runtime-dir-lock(-wait)? sub rc=0$/ {
      if (holder == "A") bad = "the update took subscription-update.lock from the start"
      holder = "B"
    }
    /^B call release-runtime-dir-lock sub$/ { if (holder == "B") holder = "" }
    /^A sub acquired$/ {
      if (holder == "B") bad = "the start took subscription-update.lock from the update"
      holder = "A"
    }
    /^A sub released$/ { if (holder == "A") holder = "" }
    END { if (bad != "") { print label ": " bad; exit 1 } }
  ' "$EVENTS" >"$WORK_DIR/exclusive.out" || fail "$(cat "$WORK_DIR/exclusive.out")"
}

before() {
  awk -v first="$1" -v second="$2" '
    $0 == first && !seen_second { seen_first = 1 }
    $0 == second { seen_second = 1 }
    END { exit seen_first && seen_second ? 0 : 1 }
  ' "$EVENTS"
}

for RC_MODE in sync detached; do
  # 1. The start holds reload.lock and has not reached subscription-update.lock
  #    yet when a forced update arrives. The update must wait for reload.lock
  #    without holding subscription-update.lock; the start then completes and
  #    the update runs after it.
  reset_case
  A_GATE="$WORK_DIR/a.gate" launch_start
  wait_until 10 has_event '^A start begin$' || fail "$RC_MODE start did not reach its backend: $(cat "$WORK_DIR/a.out")"
  [ -d "$RELOAD_LOCK" ] || fail "$RC_MODE start backend runs without reload.lock"
  B_GATE="" launch_update
  wait_until 10 has_event '^B call acquire-runtime-dir-lock-wait reload$' ||
    fail "update did not reach its reload.lock wait: $(cat "$WORK_DIR/b.out")"
  touch "$WORK_DIR/a.gate"
  finish_case "update during $RC_MODE start"
  before "A start end" "B update begin" || fail "update during $RC_MODE start: the update did not wait for the start"

  # 2. The update holds its locks when the start arrives. The start waits for
  #    reload.lock (START_RUNTIME_LOCK_WAIT_SECONDS) and runs after the update.
  reset_case
  B_GATE="$WORK_DIR/b.gate" launch_update
  wait_until 10 has_event '^B update begin$' || fail "update did not reach its cache request: $(cat "$WORK_DIR/b.out")"
  A_GATE="" launch_start
  # Let the start make its first reload.lock attempts while the update holds it.
  sleep 1
  has_event '^A start begin$' && fail "$RC_MODE start ran its backend while the update held reload.lock"
  touch "$WORK_DIR/b.gate"
  finish_case "$RC_MODE start during update"
  before "B update end" "A start begin" || fail "$RC_MODE start during update: the start did not wait for the update"
done

printf 'subscription/start lock order checks passed\n'
