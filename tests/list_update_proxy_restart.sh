#!/usr/bin/env bash
set -euo pipefail

# A list download through the service proxy that failed while the proxy was
# being restarted is downloaded once more after the restart, still without
# reload.lock (UC-057 follow-up).
#
# The list worker downloads its sources before it takes reload.lock. A DNS
# failover switch or a subscription update may take the free lock meanwhile
# and stop and start sing-box, the service proxy the downloads go through.
# The worker used to give up on a source after three attempts two seconds
# apart and fail the whole update ("Failed to preflight list source"); when
# a list-source change had started that update, every later reload turned
# into a failing list-content reload until the next successful update. Now
# the first source that fails through the proxy waits until reload.lock is
# free, without holding it, and is downloaded once more. No download runs
# under reload.lock: holding it for network I/O blocks the DNS failover and
# runtime recovery a broken proxy needs (UC-057). A direct download does not
# depend on the proxy and is not retried. A second proxied failure, of the
# same source or a later one, fails the update at once, so a proxy that is
# really down costs two source budgets and not one per source.
#
# The worker is the real components/updates.uc; its locks go through the
# real service/state.uc.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
REAL_SLEEP="$(command -v sleep)"
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
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  [ ! -s "$WORK_DIR/worker.log" ] || sed 's/^/  worker: /' "$WORK_DIR/worker.log" >&2
  exit 1
}

RUN="$WORK_DIR/run"
export RELOAD_LOCK="$RUN/reload.lock" EVENTS WORK_DIR REAL_LIB REAL_SLEEP
mkdir -p "$WORK_DIR/bin" "$RUN" "$WORK_DIR/rulesets"
: >"$EVENTS"

# A library with the real modules and a rule-set cache that changes nothing.
LIB="$WORK_DIR/lib"
mkdir -p "$LIB/singbox"
for entry in "$REAL_LIB"/*; do [ "${entry##*/}" = singbox ] || ln -s "$entry" "$LIB/${entry##*/}"; done
for entry in "$REAL_LIB"/singbox/*; do ln -s "$entry" "$LIB/singbox/${entry##*/}"; done
rm "$LIB/singbox/ruleset_cache.uc"
printf 'exit(1);\n' >"$LIB/singbox/ruleset_cache.uc"

cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
printf '192.0.2.1\n'
SH
# curl: with $WORK_DIR/restart present, the first request starts a restart of
# the service proxy: the restarting process (the DNS failover apply) takes
# reload.lock and the proxy refuses connections until $WORK_DIR/proxy.down is
# gone. With $WORK_DIR/unreachable present, no source answers; a source whose
# URL contains "dead" never answers.
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
if [ -e "$WORK_DIR/restart" ]; then
  rm -f "$WORK_DIR/restart"
  ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" acquire-runtime-dir-lock "$RELOAD_LOCK" "$(cat "$WORK_DIR/holder.pid")" || exit 99
  : >"$WORK_DIR/proxy.down"
fi
# lock=: free, restart (held by the restart) or held (by anyone else: the
# worker).
held=free
if [ -e "$RELOAD_LOCK" ]; then
  held=held
  for record in "$RELOAD_LOCK"/owner."$(cat "$WORK_DIR/holder.pid")".*; do
    [ ! -e "$record" ] || held=restart
  done
fi
proxy=direct
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -x) proxy=proxied; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >>"$WORK_DIR/urls"
case "$url" in *dead*) dead=1 ;; *) dead=0 ;; esac
if { [ "$proxy" = proxied ] && [ -e "$WORK_DIR/proxy.down" ]; } || [ -e "$WORK_DIR/unreachable" ] || [ "$dead" = 1 ]; then
  printf 'download %s lock=%s fail\n' "$proxy" "$held" >>"$EVENTS"
  exit 7
fi
printf 'download %s lock=%s ok\n' "$proxy" "$held" >>"$EVENTS"
printf 'new.example\n' >"$output"
SH
# The pause between download attempts, shortened.
cat >"$WORK_DIR/bin/sleep" <<'SH'
#!/bin/sh
[ "$*" != 2 ] || exec "$REAL_SLEEP" 0.1
exec "$REAL_SLEEP" "$@"
SH
cat >"$WORK_DIR/bin/init-prokop" <<'SH'
#!/bin/sh
printf 'init %s\n' "$*" >>"$EVENTS"
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$*" = '-j list table inet prokop' ] && printf '{"nftables":[]}\n'
exit 0
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/"*

state() { ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" "$@"; }
failures() { grep -c ' fail$' "$EVENTS" || true; }
three_failures() { [ "$(failures)" -ge 3 ]; }
attempts() { grep -cx "$1" "$WORK_DIR/urls" || true; }
no_locked_download() {
  if grep -q '^download .* lock=held' "$EVENTS"; then
    fail "$1: a list source was downloaded while reload.lock was held"
  fi
}

# start_worker PROXY MARKER [URL...]: a list update of URL (by default one
# source), through the service proxy with PROXY=1, with $WORK_DIR/MARKER in
# place (see curl above).
start_worker() {
  local proxy="$1" marker="$2"
  shift 2
  [ "$#" -gt 0 ] || set -- https://lists.test/domains.txt
  : >"$EVENTS"
  : >"$WORK_DIR/urls"
  rm -rf "$WORK_DIR/generation" "$WORK_DIR/cache" "$WORK_DIR/ruleset-cache" "${RUN:?}"/*
  rm -f "$WORK_DIR/restart" "$WORK_DIR/proxy.down" "$WORK_DIR/unreachable"
  [ "$marker" = none ] || : >"$WORK_DIR/$marker"
  mkdir -p "$WORK_DIR/cache"
  printf '{"version":3,"rules":[{"domain_suffix":["old.example"]}]}\n' >"$WORK_DIR/rulesets/alpha-remote-domains-ruleset.json"
  cat >"$WORK_DIR/uci.state" <<'UCI'
prokop.settings=settings
prokop.settings.update_interval=1d
prokop.alpha=section
prokop.alpha.enabled=1
prokop.alpha.action=connection
UCI
  printf 'prokop.alpha.remote_domain_lists=%s\n' "$*" >>"$WORK_DIR/uci.state"
  if [ "$proxy" = 1 ]; then
    printf 'prokop.settings.download_lists_via_proxy=1\nprokop.settings.download_lists_via_proxy_section=alpha\n' \
      >>"$WORK_DIR/uci.state"
  fi
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
}

# finish_worker: the worker's exit status in $status.
finish_worker() {
  wait_until 60 process_gone "$worker" || fail "$1: the list update did not finish"
  status=0
  wait "$worker" || status=$?
  [ ! -e "$RELOAD_LOCK" ] || fail "$1: reload.lock was left behind"
  [ ! -e "$RUN/list.pid" ] || fail "$1: the list update left its PID file behind"
}

# end_restart CASE: the restart that took reload.lock keeps it a while after
# the three attempts failed; the worker must not download meanwhile. Then the
# proxy comes up and the restart releases the lock, as lifecycle does.
end_restart() {
  wait_until 30 three_failures || fail "$1: the downloads did not fail while the service proxy restarted"
  "$REAL_SLEEP" 1
  [ "$(failures)" = 3 ] || fail "$1: the worker downloaded again while the restart held reload.lock"
  if grep -q ' ok$' "$EVENTS"; then
    fail "$1: a download succeeded through a proxy that was down"
  fi
  rm -f "$WORK_DIR/proxy.down"
  state release-runtime-dir-lock "$RELOAD_LOCK" "$holder" || fail "$1: the restart could not release reload.lock"
}

applied() { grep -q 'new.example' "$WORK_DIR/rulesets/alpha-remote-domains-ruleset.json"; }

"$REAL_SLEEP" 600 &
holder=$!
pids+=("$holder")
printf '%s\n' "$holder" >"$WORK_DIR/holder.pid"

# 1. The service proxy restarts while the worker downloads through it; the
#    restart ends after all three attempts failed. The source is downloaded
#    again once the restart released reload.lock, without holding it.
start_worker 1 restart
end_restart 1
finish_worker 1
[ "$status" = 0 ] || fail "1: the list update failed after the service proxy restarted (status $status)"
grep -qx 'download proxied lock=free ok' "$EVENTS" || fail "1: the failed source was not downloaded again after the restart"
no_locked_download 1
[ "$(failures)" = 3 ] || fail "1: $(failures) downloads failed, expected the three during the restart"
applied || fail "1: the list update did not apply the source"
grep -qx 'init reload list-content' "$EVENTS" || fail "1: the list update did not apply its generation"

# 2. A direct download is not retried.
start_worker 0 unreachable
finish_worker 2
[ "$status" != 0 ] || fail "2: the list update with an unreachable source succeeded"
[ "$(failures)" = 3 ] || fail "2: a direct download was attempted $(failures) times"
no_locked_download 2
applied && fail "2: the failed list update changed the active rule set"

# 3. With the service proxy really down, the first proxied source is retried
#    once, without reload.lock, and its second failure fails the update: the
#    remaining sources are not downloaded at all.
start_worker 1 unreachable https://lists.test/a.txt https://lists.test/b.txt https://lists.test/c.txt
finish_worker 3
[ "$status" != 0 ] || fail "3: the list update with an unreachable proxied source succeeded"
no_locked_download 3
[ "$(attempts https://lists.test/a.txt)" = 6 ] ||
  fail "3: the first proxied source was attempted $(attempts https://lists.test/a.txt) times, expected 3 and 3 on the retry"
[ "$(failures)" = 6 ] || fail "3: $(failures) downloads failed, expected 6: the update went on past the first source"
applied && fail "3: the failed list update changed the active rule set"
if grep -q '^init ' "$EVENTS"; then
  fail "3: the failed list update reloaded"
fi

# 4. The retry is spent once per update: after a source recovered from a
#    proxy restart, a later proxied source that fails fails the update at
#    once, without a retry and without reload.lock.
start_worker 1 restart https://lists.test/domains.txt https://lists.test/dead.txt
end_restart 4
finish_worker 4
[ "$status" != 0 ] || fail "4: the list update with a dead proxied source succeeded"
no_locked_download 4
[ "$(attempts https://lists.test/domains.txt)" = 4 ] ||
  fail "4: the restarted source was attempted $(attempts https://lists.test/domains.txt) times, expected 3 and 1 on the retry"
[ "$(attempts https://lists.test/dead.txt)" = 3 ] ||
  fail "4: the dead source was attempted $(attempts https://lists.test/dead.txt) times, expected 3 without a retry"
applied && fail "4: the failed list update changed the active rule set"
if grep -q '^init ' "$EVENTS"; then
  fail "4: the failed list update reloaded"
fi

printf 'list_update_proxy_restart: ok\n'
