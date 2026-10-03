#!/usr/bin/env bash
set -euo pipefail

# The list worker downloads its sources into a private staging directory in
# /tmp before it takes reload.lock (UC-057). A stop terminates a worker that
# is still downloading, and a worker can be killed: it never removes that
# directory, and the downloaded lists stayed in RAM until the reboot. The
# directory carries its worker's identity (pid and start ticks,
# core/process_identity.uc): the stop that terminated the worker removes it,
# and so does every later list update once its worker is gone. The directory
# of a running worker is never removed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

actors=()
cleanup() {
  rm -f "$WORK_DIR/curl.hold"
  owned_kill KILL "${actors[@]}" || true
  wait 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/tmp" "$WORK_DIR/rulesets"
cat >"$WORK_DIR/uci.state" <<'UCI'
prokop.settings=settings
prokop.settings.update_interval=1d
prokop.alpha=section
prokop.alpha.enabled=1
prokop.alpha.action=connection
prokop.alpha.remote_domain_lists=https://lists.test/domains.txt
UCI

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR"
export PROKOP_LIB="$LIB"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_LIST_UPDATE_PID_FILE="$WORK_DIR/run/list.pid"
export PROKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/list-cache"
export PROKOP_RULESET_CACHE_DIR="$WORK_DIR/ruleset-cache"
export PROKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/list-generation"
export PROKOP_LIST_DOWNLOAD_MIN_FREE_BYTES=0
export TMP_SING_BOX_FOLDER="$WORK_DIR/tmp/sing-box"
export TMP_RULESET_FOLDER="$WORK_DIR/rulesets"

printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/init"
printf '#!/bin/sh\necho 192.0.2.1\n' >"$WORK_DIR/bin/dig"
# The download records where it writes and holds the worker in its
# downloads while curl.hold exists.
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$output" >>"$TEST_WORK/curl.outputs"
while [ -e "$TEST_WORK/curl.hold" ]; do sleep 0.05; done
printf 'listed.example\n' >"$output"
SH
chmod +x "$WORK_DIR/bin/"*

list() { ucode -L "$LIB" "$LIB/components/updates.uc" "$@"; }
start_ticks() {
  ucode -L "$LIB" -e 'print(require("core.process_identity").start_ticks(ARGV[0]))' "$1"
}
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    printf '%s\n' "$child"
    descendants "$child"
  done
}
track_descendants() {
  local pid
  for pid in $(descendants "$1"); do actors+=("$pid"); done
}
downloading() { [ -s "$WORK_DIR/curl.outputs" ]; }
# The staging directory of the download the worker is in.
staging_dir() { dirname "$(tail -n 1 "$WORK_DIR/curl.outputs")"; }
# start_worker: a list update held in its first download.
start_worker() {
  : >"$WORK_DIR/curl.hold"
  : >"$WORK_DIR/curl.outputs"
  list list-update >/dev/null 2>&1 &
  WORKER=$!
  actors+=("$WORKER")
  wait_until 20 downloading || fail "the list worker did not reach its download"
  track_descendants "$WORKER"
  STAGING="$(staging_dir)"
  [ -d "$STAGING" ] || fail "the list worker has no staging directory"
}

# --- a stop during the downloads ---------------------------------------------
start_worker
list stop-list-update
wait_until 10 process_gone "$WORKER" || fail "stop-list-update left the list worker running"
[ ! -e "$STAGING" ] || fail "a stop during the downloads left the staging directory: $(ls -a "$STAGING")"
rm -f "$WORK_DIR/curl.hold"

# --- leftovers of workers that are gone --------------------------------------
# A killed worker's directory, a directory whose PID now belongs to another
# process, and the directory of the worker that is running.
sleep 0 &
dead=$!
wait "$dead" || true
sleep 300 &
other=$!
actors+=("$other")
wait_until 10 process_exec_is "$other" sleep || fail "the other process did not start"
mkdir -p "$TMPDIR/prokop-list-staging.$dead.12345" "$TMPDIR/prokop-list-staging.$other.$(start_ticks "$other")"
printf 'x\n' >"$TMPDIR/prokop-list-staging.$dead.12345/source-1"
mkdir -p "$TMPDIR/prokop-list-staging.junk" "$TMPDIR/unrelated"
start_worker
[ ! -e "$TMPDIR/prokop-list-staging.$dead.12345" ] || fail "a list update kept the staging directory of a killed worker"
[ ! -e "$TMPDIR/prokop-list-staging.$other.$(start_ticks "$other")" ] ||
  fail "a list update kept a staging directory whose PID another process reused"
for kept in prokop-list-staging.junk unrelated; do
  [ -d "$TMPDIR/$kept" ] || fail "a list update removed $kept, which is no staging directory"
done
# Another list update while this one runs: it skips, and the running
# worker's directory stays.
list list-update >/dev/null 2>&1 || fail "a list update next to a running one failed instead of skipping"
[ -d "$STAGING" ] || fail "the staging directory of a running worker was removed"
process_running "$WORKER" || fail "the running list worker was disturbed"

# A worker that ends normally removes its own directory.
rm -f "$WORK_DIR/curl.hold"
wait "$WORKER" || true
[ ! -e "$STAGING" ] || fail "a finished list update left its staging directory"

printf 'list_staging_cleanup: PASS\n'
