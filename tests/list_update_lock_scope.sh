#!/usr/bin/env bash
set -euo pipefail

# A list update holds reload.lock only for its transaction, not for its
# network I/O (UC-057).
#
# reload.lock serializes every runtime mutation, and DNS failover gives up
# on it within two seconds. The list worker used to take it before its DNS
# probe (up to ten attempts with dig timeouts and sleeps) and keep it through
# every download and the final rule-set refresh: with a dead resolver, DNS
# failover could not switch servers and recovery waited for minutes.
#
# The DNS probe and the source downloads go to a private staging directory
# before the lock is taken; the snapshot, import and commit of the generation
# run under it; the rule-set refresh through the service proxy and the final
# list-content reload run after it is released. Another process holds
# reload.lock here while the worker starts: the worker downloads meanwhile
# but changes nothing until the holder releases the lock.
#
# The worker is the real components/updates.uc; its locks go through the
# real service/state.uc. The rule-set cache module is a stand-in that
# records whether reload.lock is held when it runs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

pids=()
cleanup() {
  local pid
  for pid in "${pids[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
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
  if [ -s "$WORK_DIR/worker.log" ]; then
    sed 's/^/  worker: /' "$WORK_DIR/worker.log" >&2
  fi
  exit 1
}

RUN="$WORK_DIR/run"
export RELOAD_LOCK="$RUN/reload.lock" EVENTS
mkdir -p "$WORK_DIR/bin" "$RUN" "$WORK_DIR/rulesets" "$WORK_DIR/cache"
: >"$EVENTS"

# A library with the real modules and a stand-in rule-set cache.
LIB="$WORK_DIR/lib"
mkdir -p "$LIB/singbox"
for entry in "$REAL_LIB"/*; do [ "${entry##*/}" = singbox ] || ln -s "$entry" "$LIB/${entry##*/}"; done
for entry in "$REAL_LIB"/singbox/*; do ln -s "$entry" "$LIB/singbox/${entry##*/}"; done
rm "$LIB/singbox/ruleset_cache.uc"
cat >"$LIB/singbox/ruleset_cache.uc" <<'UC'
let held = require("fs").stat(getenv("RELOAD_LOCK")) != null ? "held" : "free";
system("printf '%s\\n' 'ruleset " + ARGV[0] + " lock=" + held + "' >>" + getenv("EVENTS"));
exit(1);
UC

lock_state() {
  cat >>"$WORK_DIR/bin/$1" <<'SH'
if [ -e "$RELOAD_LOCK" ]; then held=held; else held=free; fi
SH
}
printf '#!/bin/sh\n' >"$WORK_DIR/bin/dig"
lock_state dig
cat >>"$WORK_DIR/bin/dig" <<'SH'
printf 'dig lock=%s\n' "$held" >>"$EVENTS"
printf '192.0.2.1\n'
SH
printf '#!/bin/sh\n' >"$WORK_DIR/bin/curl"
lock_state curl
cat >>"$WORK_DIR/bin/curl" <<'SH'
printf 'download lock=%s\n' "$held" >>"$EVENTS"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'new.example\n' >"$output"
SH
printf '#!/bin/sh\n' >"$WORK_DIR/bin/init-prokop"
lock_state init-prokop
cat >>"$WORK_DIR/bin/init-prokop" <<'SH'
printf 'init %s lock=%s\n' "$*" "$held" >>"$EVENTS"
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf 'nft %s\n' "$*" >>"$EVENTS"
[ "$*" = '-j list table inet prokop' ] && printf '{"nftables":[]}\n'
exit 0
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/"*

state() { ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" "$@"; }

# run_case PROXY: a list update while another lifecycle holds reload.lock.
# With PROXY=1 the lists are downloaded through the sing-box service proxy.
run_case() {
  local proxy="$1" holder worker status=0
  : >"$EVENTS"
  rm -rf "$WORK_DIR/generation" "$WORK_DIR/cache" "$WORK_DIR/ruleset-cache" "${RUN:?}"/*
  mkdir -p "$WORK_DIR/cache"
  printf '{"version":3,"rules":[{"domain_suffix":["old.example"]}]}\n' >"$WORK_DIR/rulesets/alpha-remote-domains-ruleset.json"
  cp "$WORK_DIR/rulesets/alpha-remote-domains-ruleset.json" "$WORK_DIR/before.json"
  printf 'force\n' >"$RUN/ruleset-refresh-after-list"
  cat >"$WORK_DIR/uci.state" <<'UCI'
prokop.settings=settings
prokop.settings.update_interval=1d
prokop.alpha=section
prokop.alpha.enabled=1
prokop.alpha.action=connection
prokop.alpha.remote_domain_lists=https://lists.test/domains.txt
UCI
  if [ "$proxy" = 1 ]; then
    printf 'prokop.settings.download_lists_via_proxy=1\nprokop.settings.download_lists_via_proxy_section=alpha\n' \
      >>"$WORK_DIR/uci.state"
  fi

  sleep 600 &
  holder=$!
  pids+=("$holder")
  state acquire-runtime-dir-lock "$RELOAD_LOCK" "$holder" || fail "the holder could not take reload.lock"

  env PATH="$WORK_DIR/bin:$PATH" \
    PROKOP_LIB="$LIB" \
    PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    PROKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/generation" \
    PROKOP_RULESET_CACHE_DIR="$WORK_DIR/ruleset-cache" \
    TMP_RULESET_FOLDER="$WORK_DIR/rulesets" \
    PROKOP_RUNTIME_STATE_DIR="$RUN" \
    PROKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK" \
    PROKOP_LIST_UPDATE_PID_FILE="$RUN/list.pid" \
    PROKOP_PENDING_RELOAD_FILE="$RUN/reload.pending" \
    PROKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/cache" \
    PROKOP_SERVICE_INIT="$WORK_DIR/bin/init-prokop" \
    NFT_TABLE_NAME=prokop \
    ucode -L "$LIB" "$LIB/components/updates.uc" list-update >"$WORK_DIR/worker.log" 2>&1 &
  worker=$!
  pids+=("$worker")

  if [ "$proxy" = 1 ]; then
    # 1p. Downloads through the service proxy wait for a start or reload in
    #     progress to settle, as they did under the lock, and then run
    #     without it.
    wait_until 30 pgrep -f "acquire-runtime-dir-lock-wait $RELOAD_LOCK" >/dev/null ||
      fail "the proxied list update did not wait for the start or reload in progress"
    if grep -q '^download ' "$EVENTS"; then
      fail "the proxied list update downloaded while a start or reload was in progress"
    fi
    state release-runtime-dir-lock "$RELOAD_LOCK" "$holder"
    wait_until 30 grep -q '^download ' "$EVENTS" || fail "the proxied list update did not download"
    if grep -q '^download lock=held' "$EVENTS"; then
      fail "a proxied download ran under reload.lock"
    fi
    if grep -q '^dig ' "$EVENTS"; then
      fail "the proxied list update probed the system resolver"
    fi
  else
    # 1. The probe and the downloads do not wait for the lock.
    wait_until 30 grep -q '^download ' "$EVENTS" ||
      fail "the list update did not download while another process held reload.lock"
    grep -qx 'dig lock=held' "$EVENTS" || fail "the DNS probe did not run while another process held reload.lock"
    if grep -q '^download lock=free' "$EVENTS"; then
      fail "a download waited for reload.lock"
    fi

    # 2. Nothing of the generation is applied while the holder has the lock.
    process_running "$worker" || fail "the list update finished while another process held reload.lock"
    cmp -s "$WORK_DIR/before.json" "$WORK_DIR/rulesets/alpha-remote-domains-ruleset.json" ||
      fail "the list update changed the active rule set while another process held reload.lock"
    [ "$(state runtime-dir-lock-owner "$RELOAD_LOCK")" = "$holder" ] || fail "the list update took reload.lock from its holder"
    if grep -q '^ruleset \|^init ' "$EVENTS"; then
      fail "the list update refreshed rule sets or reloaded while another process held reload.lock"
    fi
    state release-runtime-dir-lock "$RELOAD_LOCK" "$holder"
  fi

  # 3. Once the lock is free the transaction runs; the rule-set refresh and
  #    the final reload run after the worker released it again.
  wait_until 60 process_gone "$worker" || fail "the list update did not finish after reload.lock was released"
  wait "$worker" || status=$?
  [ "$status" = 0 ] || fail "the list update failed with status $status"
  grep -q 'new.example' "$WORK_DIR/rulesets/alpha-remote-domains-ruleset.json" ||
    fail "the list update did not apply the new generation"
  grep -qx 'ruleset refresh lock=free' "$EVENTS" || fail "the rule-set refresh ran under reload.lock"
  grep -qx 'init reload list-content lock=free' "$EVENTS" || fail "the final list-content reload did not run after the release"
  [ ! -e "$RELOAD_LOCK" ] || fail "the list update left reload.lock behind"
  [ ! -e "$RUN/list.pid" ] || fail "the list update left its PID file behind"
  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

run_case 0
run_case 1

printf 'list update lock scope checks passed\n'
