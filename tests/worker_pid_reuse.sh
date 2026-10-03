#!/usr/bin/env bash
set -euo pipefail

# Background workers are recognized and stopped by their recorded identity
# (core/process_identity.uc: pid + start ticks + executable + command line),
# never by a bare PID (UC-014): the list update worker, the deferred
# subscription bootstrap worker, the scheduled start retry, the workers of UI
# jobs and the lifecycle worker of a start.
#
# A worker that is OOM-killed or SIGKILLed leaves its pidfile behind, and the
# PID in it is soon reused. Such a pidfile, as a bare PID, as a record with
# another start time, or as the right start time of a process with another
# command line, must not get that process signalled and must not count as a
# running worker. A recorded worker still does. The process that reused the
# PID can run the worker's own executable (on OpenWrt /bin/sh, sleep and most
# daemons are one busybox binary, and ucode runs every Prokop module): then
# the command line alone tells it apart, also for a bare PID.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

actors=()
cleanup() {
  local pid
  for pid in "${actors[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -f "$WORK_DIR/dig.hold" "$WORK_DIR/lifecycle.hold" "$WORK_DIR/subscription.hold" "$WORK_DIR/foreign.hold"
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/tmp" "$WORK_DIR/ui"
printf 'prokop.settings=settings\n' >"$WORK_DIR/uci.state"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR"
export PROKOP_LIB="$LIB"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_LIST_UPDATE_PID_FILE="$WORK_DIR/run/list.pid"
export PROKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE="$WORK_DIR/run/subscription-bootstrap-retry.pid"
export PROKOP_START_IN_PROGRESS_FILE="$WORK_DIR/run/start.in-progress"
export PROKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/list-cache"
export PROKOP_RULESET_CACHE_DIR="$WORK_DIR/ruleset-cache"
export PROKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/list-generation"
export PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/subscription-cache"
export PROKOP_SUBSCRIPTION_UPDATE_JOB_DIR="$WORK_DIR/ui/subscription-actions"
export TMP_SING_BOX_FOLDER="$WORK_DIR/tmp/sing-box"
export SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant"
export SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version"
export PROKOP_UI_STATE_DIR="$WORK_DIR/ui"
export PROKOP_UI_SERVICE_ACTION_DIR="$WORK_DIR/ui/service-actions"
export PROKOP_UI_SERVICE_ACTION_LOCK_DIR="$WORK_DIR/ui/service-actions.lock"
export PROKOP_UI_LATENCY_ACTION_DIR="$WORK_DIR/ui/latency-actions"
export PROKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/ui/component-actions"
export PROKOP_UI_SUBSCRIPTION_ACTION_DIR="$WORK_DIR/ui/subscription-actions"
export PROKOP_UI_SING_BOX_VERSION_CACHE_FILE="$WORK_DIR/ui/sing-box-version"
export PROKOP_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/missing-variant"
export PROKOP_UI_SING_BOX_BIN_PATH="$WORK_DIR/missing-sing-box"
export ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws"
export ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2"
export BYEDPI_BIN="$WORK_DIR/missing-ciadpi"
unset PROKOP_UI_ACTION_TRACKED

# Nothing here may reach the host's syslog, nftables, resolver or services.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/init.log"\n' >"$WORK_DIR/bin/init"
# The resolver answers, or holds the list worker in its DNS check.
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
if [ -e "$TEST_WORK/dig.hold" ]; then
  : >"$TEST_WORK/dig.held"
  while [ -e "$TEST_WORK/dig.hold" ]; do sleep 0.05; done
fi
echo 192.0.2.1
SH
# `prokop subscription_update`, run by a subscription job worker.
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
while [ -e "$TEST_WORK/subscription.hold" ]; do sleep 0.05; done
exit 0
SH
chmod +x "$WORK_DIR/bin/"*

list() { ucode -L "$LIB" "$LIB/components/updates.uc" "$@"; }
subscription() { ucode -L "$LIB" "$LIB/subscription/cache.uc" "$@"; }
initd() { ucode -L "$LIB" "$LIB/service/initd.uc" "$@"; }
ui() { ucode -L "$LIB" "$LIB/service/ui.uc" "$@"; }
start_ticks() {
  ucode -L "$LIB" -e 'print(require("core.process_identity").start_ticks(ARGV[0]))' "$1"
}
json_field() {
  ucode -e 'let v = json(require("fs").readfile(ARGV[0])); print(v[ARGV[1]] == null ? "null" : v[ARGV[1]])' "$1" "$2"
}
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    printf '%s\n' "$child"
    descendants "$child"
  done
}
# Remembers what a worker spawned, so nothing it leaves behind outlives the
# test once the worker is stopped.
track_descendants() {
  local pid
  for pid in $(descendants "$1"); do actors+=("$pid"); done
}
first_line() { head -n 1 "$1" 2>/dev/null; }

# The unrelated process that now holds the PID a crashed worker left behind.
sleep 300 &
FOREIGN=$!
actors+=("$FOREIGN")
wait_until 10 process_exec_is "$FOREIGN" sleep || fail "the foreign process did not start"
FOREIGN_TICKS="$(start_ticks "$FOREIGN")"
[ -n "$FOREIGN_TICKS" ] || fail "cannot read the start ticks of the foreign process"
FORMS="bare other-start same-start"
# Processes that hold the PID and run the worker's executable with another
# command line: another ucode program with the same library path, and
# another /bin/sh script.
: >"$WORK_DIR/foreign.hold"
FOREIGN_LOOP="while [ -e '$WORK_DIR/foreign.hold' ]; do sleep 0.05; done"
ucode -L "$LIB" -e 'system(ARGV[0])' "$FOREIGN_LOOP" &
FOREIGN_UCODE=$!
actors+=("$FOREIGN_UCODE")
wait_until 10 process_exec_is "$FOREIGN_UCODE" ucode || fail "the foreign ucode process did not start"
/bin/sh -c "$FOREIGN_LOOP" &
FOREIGN_SH=$!
actors+=("$FOREIGN_SH")
wait_until 10 process_exec_is "$FOREIGN_SH" "$(basename "$(readlink -f /bin/sh)")" ||
  fail "the foreign /bin/sh process did not start"

stale_record() {
  local pid="${3:-$FOREIGN}" ticks
  ticks="$(start_ticks "$pid")"
  [ -n "$ticks" ] || fail "cannot read the start ticks of $pid"
  case "$2" in
    bare) printf '%s\n' "$pid" ;;
    other-start) printf '%s\n%s\n' "$pid" "$((ticks + 1))" ;;
    same-start) printf '%s\n%s\n' "$pid" "$ticks" ;;
  esac >"$1"
}

foreign_alive() {
  process_running "$FOREIGN" || fail "$1 signalled the process that reused the worker's PID"
  process_running "$FOREIGN_UCODE" || fail "$1 signalled a ucode process that reused the worker's PID"
  process_running "$FOREIGN_SH" || fail "$1 signalled a /bin/sh process that reused the worker's PID"
}

# --- list update worker ------------------------------------------------------
LIST_PID="$PROKOP_LIST_UPDATE_PID_FILE"
for foreign in "$FOREIGN" "$FOREIGN_UCODE"; do
  for form in $FORMS; do
    stale_record "$LIST_PID" "$form" "$foreign"
    list stop-list-update
    foreign_alive "stop-list-update ($form $foreign)"
    [ ! -e "$LIST_PID" ] || fail "stop-list-update kept a stale pidfile ($form $foreign)"

    stale_record "$LIST_PID" "$form" "$foreign"
    : >"$WORK_DIR/syslog"
    list prepare-list-cache >/dev/null 2>&1 || true
    if grep -q 'Another lists update is already running' "$WORK_DIR/syslog"; then
      fail "a list pidfile left behind ($form $foreign) kept the lists from being updated"
    fi
    grep -q 'Downloading and processing lists' "$WORK_DIR/syslog" ||
      fail "the list update did not run past a stale pidfile ($form $foreign)"
    [ "$(first_line "$LIST_PID")" != "$foreign" ] || fail "the list update left the stale pidfile ($form $foreign)"
    foreign_alive "the list update ($form $foreign)"
  done
done

# A running list worker is recorded, keeps a second one out and is stopped.
rm -f "$LIST_PID" "$WORK_DIR/dig.held"
: >"$WORK_DIR/dig.hold"
ucode -L "$LIB" "$LIB/components/updates.uc" prepare-list-cache >/dev/null 2>&1 &
LIST_WORKER=$!
actors+=("$LIST_WORKER")
wait_until 20 test -e "$WORK_DIR/dig.held" || fail "the list worker did not reach its DNS check"
[ "$(first_line "$LIST_PID")" = "$LIST_WORKER" ] || fail "the list worker did not record itself"
[ "$(sed -n 2p "$LIST_PID")" = "$(start_ticks "$LIST_WORKER")" ] ||
  fail "the list worker record has no start ticks"
: >"$WORK_DIR/syslog"
list prepare-list-cache >/dev/null 2>&1 || fail "a second list update failed instead of skipping"
grep -q 'Another lists update is already running' "$WORK_DIR/syslog" ||
  fail "a second list update ran next to the recorded worker"
track_descendants "$LIST_WORKER"
list stop-list-update
wait_until 10 process_gone "$LIST_WORKER" || fail "stop-list-update left the recorded list worker running"
rm -f "$WORK_DIR/dig.hold"

# --- deferred subscription bootstrap worker ----------------------------------
SUB_PID="$PROKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE"
for foreign in "$FOREIGN" "$FOREIGN_UCODE"; do
  for form in $FORMS; do
    stale_record "$SUB_PID" "$form" "$foreign"
    subscription stop-deferred-bootstrap-worker
    foreign_alive "stop-deferred-bootstrap-worker ($form $foreign)"
    [ ! -e "$SUB_PID" ] || fail "stop-deferred-bootstrap-worker kept a stale pidfile ($form $foreign)"

    stale_record "$SUB_PID" "$form" "$foreign"
    subscription start-deferred-bootstrap-worker alpha
    worker="$(first_line "$SUB_PID")"
    if [ -z "$worker" ] || [ "$worker" = "$foreign" ]; then
      fail "a stale pidfile ($form $foreign) kept the deferred subscription worker from starting"
    fi
    actors+=("$worker")
    process_running "$worker" || fail "the deferred subscription worker did not start ($form $foreign)"
    foreign_alive "start-deferred-bootstrap-worker ($form $foreign)"

    : >"$WORK_DIR/syslog"
    subscription start-deferred-bootstrap-worker alpha
    [ "$(first_line "$SUB_PID")" = "$worker" ] || fail "a second deferred subscription worker replaced the recorded one"
    wait_until 10 test -n "$(descendants "$worker")" || fail "the deferred subscription worker did not start waiting"
    track_descendants "$worker"
    subscription stop-deferred-bootstrap-worker
    wait_until 10 process_gone "$worker" || fail "the recorded deferred subscription worker was not stopped"
    foreign_alive "stop-deferred-bootstrap-worker"
  done
done

# --- scheduled start retry ---------------------------------------------------
RETRY_PID="$WORK_DIR/run/start-retry.pid"
for foreign in "$FOREIGN" "$FOREIGN_SH"; do
  for form in $FORMS; do
    stale_record "$RETRY_PID" "$form" "$foreign"
    initd cancel-scheduled-start-retry "$RETRY_PID"
    foreign_alive "cancel-scheduled-start-retry ($form $foreign)"
    [ ! -e "$RETRY_PID" ] || fail "cancel-scheduled-start-retry kept a stale pidfile ($form $foreign)"

    stale_record "$RETRY_PID" "$form" "$foreign"
    initd schedule-start-retry "$RETRY_PID" 300 || fail "the start retry was not scheduled ($form $foreign)"
    worker="$(first_line "$RETRY_PID")"
    if [ -z "$worker" ] || [ "$worker" = "$foreign" ]; then
      fail "a stale pidfile ($form $foreign) kept the start retry from being scheduled"
    fi
    actors+=("$worker")
    process_running "$worker" || fail "the scheduled start retry is not running ($form $foreign)"

    initd schedule-start-retry "$RETRY_PID" 300 || fail "a second schedule of the start retry failed"
    [ "$(first_line "$RETRY_PID")" = "$worker" ] || fail "a second start retry replaced the scheduled one"
    wait_until 10 test -n "$(descendants "$worker")" || fail "the scheduled start retry did not start waiting"
    track_descendants "$worker"
    initd cancel-scheduled-start-retry "$RETRY_PID"
    wait_until 10 process_gone "$worker" || fail "the scheduled start retry was not cancelled"
    foreign_alive "cancel-scheduled-start-retry"
  done
done
# The retry still runs its marker-gated action after its delay.
: >"$WORK_DIR/init.log"
initd schedule-start-retry "$RETRY_PID" 1 || fail "a short start retry was not scheduled"
worker="$(first_line "$RETRY_PID")"
actors+=("$worker")
wait_until 20 file_nonempty "$WORK_DIR/init.log" || fail "the scheduled start retry did not run"
grep -Fxq 'retry_start_on_wan_up' "$WORK_DIR/init.log" || fail "the start retry called $(cat "$WORK_DIR/init.log")"
[ ! -e "$RETRY_PID" ] || fail "the start retry did not remove its pidfile before retrying"

# --- UI jobs -----------------------------------------------------------------
mkdir -p "$PROKOP_UI_SERVICE_ACTION_DIR" "$PROKOP_UI_LATENCY_ACTION_DIR" \
  "$PROKOP_UI_COMPONENT_ACTION_DIR" "$PROKOP_UI_SUBSCRIPTION_ACTION_DIR"
job_record() {
  printf '{"success":true,"running":true,"kind":"%s","action":"%s","component":"prokop","section":"alpha","message":"running","pid":"%s","pid_ticks":"%s","started_at":1,"updated_at":null,"exit_code":null}\n' \
    "$2" "$3" "$FOREIGN" "$4" >"$1"
}
job_running() { [ "$(json_field "$1" running)" = "true" ]; }

check_job() {
  local label="$1" path="$2" kind="$3" action="$4"
  shift 4
  # A worker that died left its PID to another process.
  job_record "$path" "$kind" "$action" "$((FOREIGN_TICKS + 1))"
  "$@" >/dev/null
  job_running "$path" && fail "a $label job whose worker PID was reused stays running"
  # The recorded worker still runs.
  job_record "$path" "$kind" "$action" "$FOREIGN_TICKS"
  "$@" >/dev/null
  job_running "$path" || fail "a $label job whose recorded worker runs was marked stale"
  rm -f "$path"
  foreign_alive "the $label job status"
}
check_job service "$PROKOP_UI_SERVICE_ACTION_DIR/1-1.json" service reload ui service-action-status 1-1
check_job latency "$PROKOP_UI_LATENCY_ACTION_DIR/1-2.json" latency latency ui latency-test-status 1-2
check_job subscription "$PROKOP_UI_SUBSCRIPTION_ACTION_DIR/1-3.json" subscription subscription_update \
  list subscription-update-status 1-3
check_job component "$PROKOP_UI_COMPONENT_ACTION_DIR/1-4.json" component update list component-action-status 1-4

# A job records the start ticks of the worker it names.
job="$(ui service-action-begin-if-idle reload ui)"
[ -n "$job" ] || fail "no service action job was opened"
ui service-action-update-pid "$job" "$FOREIGN" || fail "the service action worker was not recorded"
[ "$(json_field "$PROKOP_UI_SERVICE_ACTION_DIR/$job.json" pid_ticks)" = "$FOREIGN_TICKS" ] ||
  fail "the service action job does not record its worker's start ticks"
rm -f "$PROKOP_UI_SERVICE_ACTION_DIR/$job.json"
: >"$WORK_DIR/subscription.hold"
list subscription-update-async alpha 1 >"$WORK_DIR/job.json" || fail "the subscription update job did not start"
job="$(json_field "$WORK_DIR/job.json" job_id)"
path="$PROKOP_SUBSCRIPTION_UPDATE_JOB_DIR/$job.json"
worker="$(json_field "$path" pid)"
actors+=("$worker")
[ "$(json_field "$path" pid_ticks)" = "$(start_ticks "$worker")" ] ||
  fail "the subscription update job does not record its worker's start ticks"
rm -f "$WORK_DIR/subscription.hold"
wait_until 20 process_gone "$worker" || fail "the subscription update worker did not finish"

# --- lifecycle worker of a start ---------------------------------------------
ui_status() {
  ui get-ui-state | ucode -e 'print(json(require("fs").stdin.read("all")).service.prokop.status)'
}
for foreign in "$FOREIGN" "$FOREIGN_UCODE"; do
  for form in $FORMS; do
    stale_record "$PROKOP_START_IN_PROGRESS_FILE" "$form" "$foreign"
    [ "$(ui_status)" != starting ] || fail "a start marker left behind ($form $foreign) keeps Prokop starting"
  done
done
# The real lifecycle start, run as the CLI runs it (`ucode -L <lib>
# <lib>/service/lifecycle.uc start`), records itself in the start marker, and
# ui.uc reports a start in progress while it runs and no longer once it has
# ended. Every module the start calls is a double; the first one it calls
# (the sing-box conflict check) holds it, then reports a conflict, so the
# start refuses and ends.
FAKE_LIB="$WORK_DIR/fake-lib"
mkdir -p "$FAKE_LIB/service" "$FAKE_LIB/diagnostics"
cat >"$FAKE_LIB/service/state.uc" <<'UC'
let fs = require("fs");
fs.writefile(getenv("TEST_WORK") + "/lifecycle.held", "");
while (fs.stat(getenv("TEST_WORK") + "/lifecycle.hold") != null)
    system("sleep 0.05");
exit(0);
UC
printf 'exit(0);\n' >"$FAKE_LIB/diagnostics/health.uc"
rm -f "$PROKOP_START_IN_PROGRESS_FILE" "$WORK_DIR/lifecycle.held"
: >"$WORK_DIR/lifecycle.hold"
PROKOP_LIB="$FAKE_LIB" PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/missing-upgrade-marker" \
  ucode -L "$LIB" "$LIB/service/lifecycle.uc" start >/dev/null 2>&1 &
LIFECYCLE=$!
actors+=("$LIFECYCLE")
wait_until 20 test -e "$WORK_DIR/lifecycle.held" || fail "the lifecycle start did not reach its first module"
[ "$(first_line "$PROKOP_START_IN_PROGRESS_FILE")" = "$LIFECYCLE" ] ||
  fail "the lifecycle start did not record itself in the start marker"
[ "$(sed -n 2p "$PROKOP_START_IN_PROGRESS_FILE")" = "$(start_ticks "$LIFECYCLE")" ] ||
  fail "the start marker has no start ticks of the lifecycle start"
[ "$(ui_status)" = starting ] || fail "a running lifecycle start is not reported as starting"
rm -f "$WORK_DIR/lifecycle.hold"
wait_until 20 process_gone "$LIFECYCLE" || fail "the lifecycle start did not finish"
grep -q 'sing-box process ownership is ambiguous' "$WORK_DIR/syslog" ||
  fail "the lifecycle start did not end where the test expects it to"
[ ! -e "$PROKOP_START_IN_PROGRESS_FILE" ] || fail "the finished lifecycle start left its start marker"
[ "$(ui_status)" != starting ] || fail "a finished lifecycle start is still reported as starting"

foreign_alive "the test"
printf 'worker_pid_reuse: PASS\n'
