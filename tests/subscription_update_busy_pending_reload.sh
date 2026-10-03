#!/usr/bin/env bash
set -euo pipefail

# A subscription update that took reload.lock but finds
# subscription-update.lock busy applies the reloads queued behind its
# reload.lock before it gives up (UC-054 lock order, review follow-up).
#
# The update takes reload.lock first and subscription-update.lock second
# (global lock order, service/state.uc). While it holds reload.lock, an
# init.d reload only queues itself in reload.pending; when the second lock
# is busy (the deferred subscription bootstrap retry downloads under it), the
# update releases reload.lock and returns. Nobody else is left to apply the
# queued reload then, so the update must do it after the release, as its
# success path does. A forced update still leaves its own
# subscription_update_busy request for the subscription-update.lock holder.
#
# The update is the real components/updates.uc; its lock and queue calls go
# through the real service/state.uc behind a recording wrapper that holds the
# update on a gate right after it took reload.lock. The queued reload is the
# real init.d reload_service and service/initd.uc.

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
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export B_GATE="$WORK_DIR/b.gate"
unset PROKOP_UI_ACTION_TRACKED
# The init.d reload reads and tidies the UI jobs (service/ui.uc).
export PROKOP_UI_STATE_DIR="$WORK_DIR/run/ui-state"
export PROKOP_UI_COMPONENT_ACTION_DIR="$PROKOP_UI_STATE_DIR/component-actions"
export PROKOP_UI_SUBSCRIPTION_ACTION_DIR="$PROKOP_UI_STATE_DIR/subscription-actions"

# Nothing here may reach the host's syslog or init scripts.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
# /etc/init.d/prokop as the queue drain calls it: record the call and
# whether reload.lock was still held at that moment.
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
if [ -e "$RELOAD_LOCK" ]; then held=held; else held=free; fi
printf 'init %s reload.lock=%s\n' "$*" "$held" >>"$EVENTS"
exit 0
SH
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
case "$1" in
  reload) printf 'prokop reload %s\n' "$2" >>"$EVENTS" ;;
  get_status) printf '{"running":true}\n' ;;
esac
exit 0
SH

# rc.common stand-in for `/etc/init.d/prokop reload <reason>` (no procd lock
# on fd 1000: a hotplug or CLI reload).
cat >"$WORK_DIR/rc" <<'SH'
#!/bin/sh
action="$1"
shift
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
PROKOP_LIB="$TEST_LIB"
PROKOP_INITD_UC="$TEST_LIB/service/initd.uc"
case "$action" in
  reload) reload_service "$@" ;;
  *) exit 64 ;;
esac
SH

# The update's service/state.uc calls go to the real module. Right after the
# update took reload.lock it waits for B_GATE, so the test can queue a reload
# behind it; its wait for subscription-update.lock is shortened to
# SUB_WAIT_SECONDS (300 s in production).
cat >"$WORK_DIR/fake-lib/service/state.uc" <<'UC'
let fs = require("fs");
function q(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
function ev(line) { system("printf '%s\\n' " + q(line) + " >> " + q(getenv("EVENTS"))); }
let mode = "" + (ARGV[0] ?? "");
let lock = "" + (ARGV[1] ?? "");
let name = lock == getenv("RELOAD_LOCK") ? "reload" : lock == getenv("SUB_LOCK") ? "sub" : lock;
let args = [];
for (let arg in ARGV)
    push(args, arg);
if (mode == "acquire-runtime-dir-lock-wait" && name == "sub" && getenv("SUB_WAIT_SECONDS"))
    args[3] = getenv("SUB_WAIT_SECONDS");
let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/service/state.uc");
for (let arg in args)
    command += " " + q(arg);
let status = system(command);
if (index(mode, "runtime-dir-lock") >= 0 || index(mode, "pending-reload") >= 0)
    ev("B " + mode + " " + name + " rc=" + status);
if (index(mode, "acquire") == 0 && name == "reload" && status == 0) {
    let gate = getenv("B_GATE");
    for (let n = 0; fs.stat(gate) == null && n < 600; n++)
        system("sleep 0.05");
}
exit(status);
UC

cat >"$WORK_DIR/fake-lib/subscription/cache.uc" <<'UC'
function q(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
let mode = "" + (ARGV[0] ?? "");
if (mode == "ensure-runtime-dirs")
    exit(0);
if (mode == "update-request") {
    system("printf 'B update ran\\n' >> " + q(getenv("EVENTS")));
    print("0 0 1 0\n");
    exit(0);
}
exit(64);
UC
chmod +x "$WORK_DIR/bin/init" "$WORK_DIR/bin/prokop" "$WORK_DIR/bin/logger" "$WORK_DIR/rc"

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }
pending_reason() { sed -n 's/^reason=//p' "$PROKOP_PENDING_RELOAD_FILE" 2>/dev/null; }

# The deferred bootstrap retry worker stands in as a live holder of
# subscription-update.lock for the whole test.
sleep 300 >/dev/null 2>&1 &
holder=$!
disown "$holder"
actors+=("$holder")
ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" acquire-runtime-dir-lock "$SUB_LOCK" "$holder" ||
  fail "could not take subscription-update.lock for the holder"

run_case() {
  local label="$1" mode="$2" expected_status="$3" update status
  : >"$EVENTS"
  rm -f "$B_GATE" "$PROKOP_PENDING_RELOAD_FILE"
  [ ! -e "$RELOAD_LOCK" ] || fail "$label: reload.lock leaked from the previous case"

  setsid timeout -s KILL 60 env PROKOP_LIB="$WORK_DIR/fake-lib" SUB_WAIT_SECONDS=2 \
    ucode -L "$REAL_LIB" "$REAL_LIB/components/updates.uc" "$mode" >"$WORK_DIR/update.out" 2>&1 &
  update=$!
  actors+=("$update")
  wait_until 20 has_event '^B acquire-runtime-dir-lock\(-wait\)\? reload rc=0$' ||
    fail "$label: the update did not take reload.lock: $(cat "$WORK_DIR/update.out")"

  # A reload (WAN up, a config change) arrives while the update holds
  # reload.lock: init.d queues it and returns.
  status=0
  timeout -s KILL 30 sh "$WORK_DIR/rc" reload badwan_interface_up >"$WORK_DIR/reload.out" 2>&1 || status=$?
  [ "$status" = 0 ] || fail "$label: init.d reload returned $status: $(cat "$WORK_DIR/reload.out")"
  [ "$(pending_reason)" = badwan_interface_up ] || fail "$label: the reload was not queued behind the update"
  has_event '^prokop reload' && fail "$label: a reload ran next to the update's reload.lock"

  touch "$B_GATE"
  wait_until 30 process_gone "$update" || fail "$label: the update did not give up on the busy subscription-update.lock"
  status=0
  wait "$update" || status=$?
  [ "$status" = "$expected_status" ] || fail "$label: the update exited $status, expected $expected_status: $(cat "$WORK_DIR/update.out")"

  has_event '^B update ran$' && fail "$label: the update ran without subscription-update.lock"
  [ ! -e "$RELOAD_LOCK" ] || fail "$label: the update left reload.lock behind"
  [ "$(ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" runtime-dir-lock-owner "$SUB_LOCK")" = "$holder" ] ||
    fail "$label: the update changed the subscription-update.lock owner"
  [ "$(grep -c '^init ' "$EVENTS" || true)" = 1 ] || fail "$label: the queued reload was not applied exactly once"
  # The drain closes procd's fd 1000 with `1000>&-`; dash, which has no
  # descriptors above 9, passes that 1000 on as an argument.
  has_event '^init reload pending\( 1000\)\? reload.lock=free$' ||
    fail "$label: the queued reload was not applied after the update released reload.lock"
}

# The init.d reload reads the UI jobs through service/ui.uc, which also marks
# the job of a dead worker as ended: the jobs of the test's own UI state, not
# the host's. One such job, past its start grace, stands in the test's UI
# state.
stale_job="$WORK_DIR/run/ui-state/service-actions/1-1.json"
mkdir -p "${stale_job%/*}"
dead_pid="$(sh -c 'echo $$')"
printf '{ "success": true, "running": true, "kind": "service", "action": "start", "source": "initd", "message": "Service action is running", "pid": "%s", "started_at": %s, "updated_at": null, "exit_code": null, "pid_ticks": "1" }\n' \
  "$dead_pid" "$(($(date +%s) - 600))" >"$stale_job"

# 1. The due (unforced) update tries each lock once.
run_case "due update" subscription-update-if-due 0
[ ! -e "$PROKOP_PENDING_RELOAD_FILE" ] || fail "due update: the queued reload is still pending ($(pending_reason))"
grep -q '"running": *false' "$stale_job" ||
  fail "the init.d reload did not read the test's own UI state: $(cat "$stale_job")"

# 2. A forced update waits for subscription-update.lock and then gives up. It
#    applies the queued reload and still leaves its own request for the
#    subscription-update.lock holder, as before.
run_case "forced update" subscription-update 1
[ "$(pending_reason)" = subscription_update_busy ] ||
  fail "forced update: its subscription_update_busy request is missing (pending reason '$(pending_reason)')"

printf 'subscription update busy pending reload checks passed\n'
