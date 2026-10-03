#!/usr/bin/env bash
set -euo pipefail

# A subscription update downloads before it takes reload.lock (UC-057).
#
# The update took reload.lock (then subscription-update.lock, the global
# lock order of UC-054) before its downloads: every retry and compatibility
# profile of every source ran under the lock that DNS failover gives up on
# within two seconds. The responses are now fetched first, into a private
# directory, without any lock; the update then takes both locks in the same
# order and commits the cache from these responses without going to the
# network again. A failed fetch is not retried under the lock. A request the
# fetch did not make (the source changed meanwhile) is downloaded as before,
# so a stale response is never committed.
#
# The update is the real components/updates.uc with the real
# subscription/cache.uc and service/state.uc; curl is a stand-in that
# records who holds reload.lock when it runs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
# shellcheck source=tests/helpers/case_groups.sh
. "$ROOT_DIR/tests/helpers/case_groups.sh"

pids=()
cleanup() {
  local pid
  owned_kill KILL "${pids[@]}" || true
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
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

# The fixture of a group of cases: stand-ins and state under its own
# $WORK_DIR.
update_fixture() {
RUN="$WORK_DIR/run"
SUBS="$WORK_DIR/sing-box/subscriptions"
PERSISTENT="$WORK_DIR/persistent/subscription-cache"
export RELOAD_LOCK="$RUN/reload.lock" EVENTS TEST_LIB="$LIB"
export CURL_FAIL="$WORK_DIR/curl.fail"
mkdir -p "$WORK_DIR/bin" "$RUN" "$WORK_DIR/tmp"
: >"$EVENTS"

# curl records the URL and who holds reload.lock: nobody, the other holder
# of this test, or anyone else (the update itself).
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
owner="$(ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" runtime-dir-lock-owner "$RELOAD_LOCK" 2>/dev/null || true)"
if [ -z "$owner" ]; then held=free; elif [ "$owner" = "$HOLDER_PID" ]; then held=holder; else held=update; fi
output=""
headers=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -D) headers="$2"; shift 2 ;;
    -H|-x|--connect-timeout|--speed-time|--speed-limit|--resolve) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf 'curl %s lock=%s\n' "$url" "$held" >>"$EVENTS"
[ ! -e "$CURL_FAIL" ] || exit 7
name="${url##*/}"
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
printf 'vless://00000000-0000-4000-8000-000000000001@%s.example.com:443?type=tcp&encryption=none&security=tls&sni=example.com#%s\n' \
  "$name" "$name" >"$output"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/ubus"
chmod +x "$WORK_DIR/bin/"*
}

state() { ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }
events_with() { grep -c -- "$1" "$EVENTS" 2>/dev/null || true; }
cached_host() { grep -o '@[a-z0-9]*\.example\.com' "$SUBS/alpha-subscription-1.json" 2>/dev/null | head -n 1 || true; }

# start_case URL [SOURCE_INDEX]: a forced update of rule alpha (or of one of
# its sources) while another lifecycle holds reload.lock; starts the update in
# the background.
start_case() {
  : >"$EVENTS"
  rm -rf "$WORK_DIR/sing-box" "$WORK_DIR/persistent" "${RUN:?}"/*
  cat >"$WORK_DIR/uci.state" <<UCI
prokop.settings=settings
prokop.alpha=section
prokop.alpha.enabled=1
prokop.alpha.action=connection
prokop.alpha.subscription_urls=$1
UCI
  sleep 600 &
  HOLDER=$!
  pids+=("$HOLDER")
  export HOLDER_PID="$HOLDER"
  state acquire-runtime-dir-lock "$RELOAD_LOCK" "$HOLDER" || fail "the holder could not take reload.lock"

  env PATH="$WORK_DIR/bin:$PATH" TMPDIR="$WORK_DIR/tmp" \
    PROKOP_LIB="$LIB" \
    PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    TMP_SING_BOX_FOLDER="$WORK_DIR/sing-box" \
    TMP_RULESET_FOLDER="$WORK_DIR/sing-box/rulesets" \
    TMP_SUBSCRIPTION_FOLDER="$SUBS" \
    PROKOP_RUNTIME_STATE_DIR="$RUN" \
    PROKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK" \
    PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$RUN/subscription-update.lock" \
    PROKOP_PENDING_RELOAD_FILE="$RUN/reload.pending" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$PERSISTENT" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE="$PERSISTENT/cache-format" \
    PROKOP_SERVICE_INIT="$WORK_DIR/bin/logger" \
    PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" \
    SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" \
    SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version" \
    ucode -L "$LIB" "$LIB/components/updates.uc" subscription-update alpha "${2:-}" >"$WORK_DIR/update.log" 2>&1 &
  UPDATE=$!
  pids+=("$UPDATE")
}

# The update fetched while the holder had the lock, and waits for it.
fetched_while_held() {
  wait_until 30 grep -q '^curl ' "$EVENTS" ||
    fail "the subscription update did not download while another process held reload.lock"
  process_running "$UPDATE" || fail "the subscription update finished while another process held reload.lock"
  [ "$(events_with 'lock=holder')" -ge 1 ] || fail "the subscription update did not download before taking reload.lock"
  [ ! -e "$SUBS/alpha-subscription-1.json" ] || fail "the subscription update changed the cache while another process held reload.lock"
  [ "$(state runtime-dir-lock-owner "$RELOAD_LOCK")" = "$HOLDER" ] ||
    fail "the subscription update took reload.lock from its holder"
}

finish_case() {
  local status=0
  state release-runtime-dir-lock "$RELOAD_LOCK" "$HOLDER"
  wait_until 60 process_gone "$UPDATE" || fail "the subscription update did not finish after reload.lock was released"
  wait "$UPDATE" || status=$?
  owned_kill KILL "$HOLDER" || true
  wait "$HOLDER" 2>/dev/null || true
  [ ! -e "$RELOAD_LOCK" ] || fail "the subscription update left reload.lock behind"
  [ ! -e "$RUN/subscription-update.lock" ] || fail "the subscription update left subscription-update.lock behind"
  if find "$WORK_DIR/tmp" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    fail "the subscription update left its fetched responses behind"
  fi
  UPDATE_STATUS="$status"
}

cases_1() {
# 1. The response fetched before the lock is committed without another
#    download under the lock.
start_case "https://sub.test/alpha"
fetched_while_held
finish_case
[ "$UPDATE_STATUS" = 0 ] || fail "the subscription update failed with status $UPDATE_STATUS: $(cat "$WORK_DIR/update.log")"
[ "$(cached_host)" = "@alpha.example.com" ] || fail "the subscription update did not commit the fetched response"
[ "$(events_with 'lock=update')" = 0 ] || fail "the subscription update downloaded again under reload.lock"
}

cases_2() {
# 2. A failed fetch is not retried under the lock.
: >"$CURL_FAIL"
start_case "https://sub.test/alpha"
fetched_while_held
finish_case
rm -f "$CURL_FAIL"
[ "$UPDATE_STATUS" != 0 ] || fail "a subscription update whose download failed reported success"
[ ! -e "$SUBS/alpha-subscription-1.json" ] || fail "a failed subscription download produced a cache"
[ "$(events_with 'lock=update')" = 0 ] || fail "a failed subscription download was retried under reload.lock"
}

cases_3() {
# 3. A source changed after the fetch is downloaded under the lock, and only
#    the response for the current source is committed.
start_case "https://sub.test/alpha"
fetched_while_held
sed -i 's#^prokop.alpha.subscription_urls=.*#prokop.alpha.subscription_urls=https://sub.test/bravo#' "$WORK_DIR/uci.state"
finish_case
[ "$UPDATE_STATUS" = 0 ] || fail "the subscription update of a changed source failed: $(cat "$WORK_DIR/update.log")"
[ "$(cached_host)" = "@bravo.example.com" ] || fail "a response fetched for a replaced source was committed"
grep -qx 'curl https://sub.test/bravo lock=update' "$EVENTS" || fail "the changed source was not downloaded"
}

cases_4() {
# 4. An update of an invalid source index, which the update refuses, fetches
#    nothing beforehand.
start_case "https://sub.test/alpha" x
wait_until 30 pgrep -f "acquire-runtime-dir-lock-wait $RELOAD_LOCK" >/dev/null ||
  fail "the update of an invalid source did not reach reload.lock"
finish_case
[ "$UPDATE_STATUS" != 0 ] || fail "the update of an invalid source index reported success"
if grep -q '^curl ' "$EVENTS"; then
  fail "the update of an invalid source index downloaded"
fi
}

# The cases run at once, each in a work directory of its own: a waiting
# update polls reload.lock every 2 s, so one after another they took most
# of 20 s. The update of a case is told apart by its own lock path.
case_group() {
  WORK_DIR="$(mktemp -d)"
  EVENTS="$WORK_DIR/events"
  pids=()
  # The group's cleanup signals only the group's processes.
  owned_processes_init
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  update_fixture
  "cases_$1"
}
run_case_groups "$WORK_DIR/case-groups" case_group 1 2 3 4

printf 'subscription update lock scope checks passed\n'
