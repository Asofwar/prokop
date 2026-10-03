#!/usr/bin/env bash
set -euo pipefail

# The service/ui.uc directory locks (service-actions.lock and the sing-box
# version cache lock) follow the runtime lock protocol of core/runtime_lock
# (UC-011): the lock is published together with an owner.<pid>.<start ticks>
# record, a dead owner or a reused pid leaves a stale lock that the next
# caller reclaims, a lock still being set up is not taken, and a holder
# releases only its own record. service/ui.uc is the real code.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
UI_UC="$LIB/service/ui.uc"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

actors=()
cleanup() {
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

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/tmp"
export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB="$LIB"
export PROKOP_CONFIG_NAME=prokop-ui-lock-test
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export PROKOP_START_IN_PROGRESS_FILE="$WORK_DIR/run/start.in-progress"
export PROKOP_UI_STATE_DIR="$WORK_DIR/state"
export PROKOP_UI_SERVICE_ACTION_DIR="$PROKOP_UI_STATE_DIR/service-actions"
export PROKOP_UI_SERVICE_ACTION_LOCK_DIR="$PROKOP_UI_STATE_DIR/service-actions.lock"
export PROKOP_UI_LATENCY_ACTION_DIR="$PROKOP_UI_STATE_DIR/latency-actions"
export PROKOP_UI_COMPONENT_ACTION_DIR="$PROKOP_UI_STATE_DIR/component-actions"
export PROKOP_UI_SUBSCRIPTION_ACTION_DIR="$PROKOP_UI_STATE_DIR/subscription-actions"
export PROKOP_UI_SING_BOX_VERSION_CACHE_FILE="$PROKOP_UI_STATE_DIR/sing-box-version"
export PROKOP_UI_SING_BOX_VERSION_CACHE_LOCK_DIR="$PROKOP_UI_SING_BOX_VERSION_CACHE_FILE.lock"
export PROKOP_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/missing-variant"
export PROKOP_UI_SING_BOX_BIN_PATH="$WORK_DIR/sing-box"
export PROKOP_UI_SING_BOX_VERSION_PROBE_TIMEOUT_SECONDS=10
export PROKOP_LATENCY_TEST_LOCK_DIR="$WORK_DIR/run/automatic-latency-test.lock"
export ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws"
export ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2"
export BYEDPI_BIN="$WORK_DIR/missing-ciadpi"
export PROBE_LOG="$WORK_DIR/probe.log"
unset PROKOP_UI_ACTION_TRACKED
SERVICE_LOCK="$PROKOP_UI_SERVICE_ACTION_LOCK_DIR"
VERSION_LOCK="$PROKOP_UI_SING_BOX_VERSION_CACHE_LOCK_DIR"

# Nothing here may reach the host's syslog, nftables or package manager.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/apk"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/opkg"
# `sing-box version`, run by service/ui.uc while it holds the version cache
# lock: records the lock as it sees it and the record its caller (the first
# ucode ancestor) should own, or, with PROBE_MODE=takeover, stands for
# another caller that took the lock over meanwhile.
cat >"$WORK_DIR/sing-box" <<'SH'
#!/bin/sh
start_ticks() {
  stat="$(cat "/proc/$1/stat")"
  stat="${stat##*) }"
  # shellcheck disable=SC2086
  set -- $stat
  shift 19
  printf '%s\n' "$1"
}
caller=$PPID
while [ "$caller" -gt 1 ]; do
  case "$(readlink "/proc/$caller/exe")" in */ucode) break ;; esac
  caller="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$caller/status")"
done
lock="$PROKOP_UI_SING_BOX_VERSION_CACHE_LOCK_DIR"
printf 'expected owner.%s.%s\n' "$caller" "$(start_ticks "$caller")" >>"$PROBE_LOG"
printf 'held %s\n' "$(ls -A "$lock" | tr '\n' ' ')" >>"$PROBE_LOG"
if [ "${PROBE_MODE:-}" = takeover ]; then
  rm -rf "$lock"
  mkdir "$lock"
  printf '%s\n' "$PROBE_SUCCESSOR" >"$lock/pid"
fi
printf 'sing-box version 1.13.14\n\nTags: with_quic\n'
SH
chmod +x "$WORK_DIR/bin/logger" "$WORK_DIR/bin/nft" "$WORK_DIR/bin/apk" "$WORK_DIR/bin/opkg" \
  "$WORK_DIR/sing-box"

start_ticks() {
  local stat
  IFS= read -r stat <"/proc/$1/stat" || return 1
  stat="${stat##*) }"
  # shellcheck disable=SC2086
  set -- $stat
  shift 19
  printf '%s\n' "$1"
}

# B is a live owner; DEAD is a reaped process, so no process runs under its pid.
sleep 300 >/dev/null 2>&1 &
B=$!
actors+=("$B")
sleep 0 &
DEAD=$!
wait "$DEAD" || true
wait_until 10 process_exec_is "$B" sleep || fail "owner process $B did not start"
process_gone "$DEAD" || fail "the dead owner still runs"
b_ticks="$(start_ticks "$B")"

# 1. service-actions.lock: `service-action-begin-if-idle` registers a service
#    action only when it gets the lock, and drops the lock afterwards.
begin() {
  local status=0
  rm -rf "$PROKOP_UI_SERVICE_ACTION_DIR"
  ucode -L "$LIB" "$UI_UC" service-action-begin-if-idle restart ui >/dev/null 2>&1 || status=$?
  printf '%s\n' "$status"
}
set_lock() {
  local label="$1"
  shift
  rm -rf "$SERVICE_LOCK" "$SERVICE_LOCK".new.*
  mkdir -p "$(dirname "$SERVICE_LOCK")"
  mkdir "$SERVICE_LOCK"
  "$@"
  touch -d '1 minute ago' "$SERVICE_LOCK"
  CASE="$label"
}
reclaimed() {
  [ "$(begin)" = 0 ] || fail "$CASE: the stale service-actions.lock was not reclaimed"
  [ ! -e "$SERVICE_LOCK" ] || fail "$CASE: the reclaimed lock was left behind: $(ls -A "$SERVICE_LOCK" | tr '\n' ' ')"
}
held() {
  local expected="$1"
  [ "$(begin)" = 2 ] || fail "$CASE: a service action began next to a live service-actions.lock owner"
  [ "$(ls -A "$SERVICE_LOCK")" = "$expected" ] || fail "$CASE: the live owner's lock was changed: $(ls -A "$SERVICE_LOCK")"
}

rm -rf "$SERVICE_LOCK"
[ "$(begin)" = 0 ] || fail "a free service-actions.lock was refused"
[ ! -e "$SERVICE_LOCK" ] || fail "service-actions.lock was not released"
set_lock "dead owner" eval ': >"$SERVICE_LOCK/owner.$DEAD.$b_ticks"'
reclaimed
set_lock "reused pid" eval ': >"$SERVICE_LOCK/owner.$B.$((b_ticks + 1))"'
reclaimed
set_lock "live owner" eval ': >"$SERVICE_LOCK/owner.$B.$b_ticks"'
held "owner.$B.$b_ticks"
set_lock "previous-version live owner" eval 'printf "%s\n" "$B" >"$SERVICE_LOCK/pid"'
held pid
set_lock "previous-version dead owner" eval 'printf "%s\n" "$DEAD" >"$SERVICE_LOCK/pid"'
reclaimed
set_lock "abandoned lock without an owner record" true
reclaimed
# A lock whose creator has not written its owner yet is not taken.
rm -rf "$SERVICE_LOCK"
mkdir "$SERVICE_LOCK"
[ "$(begin)" = 2 ] || fail "a service-actions.lock being set up was taken"
if [ ! -d "$SERVICE_LOCK" ] || [ -n "$(ls -A "$SERVICE_LOCK")" ]; then
  fail "a refused caller changed a service-actions.lock being set up"
fi
rm -rf "$SERVICE_LOCK"

# 2. The version cache lock, seen while service/ui.uc holds it, names its
#    holder by pid and start ticks; the holder's release leaves a lock that
#    another caller took over meanwhile alone.
capabilities() {
  rm -f "$PROKOP_UI_SING_BOX_VERSION_CACHE_FILE" "$PROBE_LOG"
  ucode -L "$LIB" "$UI_UC" get-ui-capabilities >/dev/null
}
capabilities
[ -s "$PROBE_LOG" ] || fail "service/ui.uc did not probe sing-box under the version cache lock"
expected="$(sed -n 's/^expected //p' "$PROBE_LOG")"
[ "$(sed -n 's/^held //p' "$PROBE_LOG")" = "$expected " ] ||
  fail "the held version cache lock is not published with its owner: $(cat "$PROBE_LOG")"
[ ! -e "$VERSION_LOCK" ] || fail "the version cache lock was not released"
! compgen -G "$VERSION_LOCK.new.*" >/dev/null || fail "a pending version cache lock was left behind"

PROBE_MODE=takeover PROBE_SUCCESSOR="$B" capabilities
[ "$(cat "$VERSION_LOCK/pid" 2>/dev/null)" = "$B" ] ||
  fail "a holder released the version cache lock another caller had taken over"
rm -rf "$VERSION_LOCK"

# A live holder keeps the lock: nobody probes next to it.
mkdir "$VERSION_LOCK"
: >"$VERSION_LOCK/owner.$B.$b_ticks"
touch -d '1 minute ago' "$VERSION_LOCK"
capabilities
[ ! -e "$PROBE_LOG" ] || fail "service/ui.uc probed sing-box next to a live version cache lock owner"
[ "$(ls -A "$VERSION_LOCK")" = "owner.$B.$b_ticks" ] || fail "the live version cache lock owner lost its lock"
rm -rf "$VERSION_LOCK"

printf 'ui dir lock owner checks passed\n'
