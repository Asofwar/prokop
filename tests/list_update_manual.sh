#!/usr/bin/env bash
set -euo pipefail

# Manual lists update from the UI and the outcome of the last update (C6).
#
# get_list_update_status reports whether a lists update runs now, when the
# lists last updated successfully, and how the last update ended with the
# sources that failed to download. Those sources are named without their
# credentials, query or fragment. list_update_async starts the same
# "list-update" worker the CLI runs, in the background; a second request
# while it runs starts nothing.
#
# The worker is the real components/updates.uc in a sandbox: curl, dig, nft,
# logger and the init script are stand-ins.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

cleanup() {
  local pids="" worker=""
  rm -f "$WORK_DIR/slow"
  read -r worker _ 2>/dev/null <"$WORK_DIR/run/list.pid" || true
  pids="$(pgrep -f "$WORK_DIR/bin/" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  owned_kill KILL $worker $pids 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -s "$WORK_DIR/worker.log" ]; then
    sed 's/^/  worker: /' "$WORK_DIR/worker.log" >&2
  fi
  exit 1
}

RUN="$WORK_DIR/run"
mkdir -p "$WORK_DIR/bin" "$RUN" "$WORK_DIR/rulesets" "$WORK_DIR/cache"

printf '#!/bin/sh\nprintf "192.0.2.1\\n"\n' >"$WORK_DIR/bin/dig"
# A download of bad.test fails; the others succeed, after a pause while
# the "slow" marker exists.
cat >"$WORK_DIR/bin/curl" <<SH
#!/bin/sh
while [ -e "$WORK_DIR/slow" ]; do sleep 0.1; done
url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) output="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in
  *bad.test*) exit 22 ;;
esac
printf 'new.example\n' >"\$output"
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$*" = '-j list table inet prokop' ] && printf '{"nftables":[]}\n'
exit 0
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/init-prokop"
chmod +x "$WORK_DIR/bin/"*

cat >"$WORK_DIR/uci.state" <<'UCI'
prokop.settings=settings
prokop.settings.update_interval=1d
prokop.alpha=section
prokop.alpha.enabled=1
prokop.alpha.action=connection
prokop.alpha.remote_domain_lists=https://lists.test/domains.txt
prokop.beta=section
prokop.beta.enabled=1
prokop.beta.action=connection
prokop.beta.remote_domain_lists=https://user:pa55word@bad.test/private/list.txt?token=s3cret#frag
UCI

updates() {
  env PATH="$WORK_DIR/bin:$PATH" \
    PROKOP_LIB="$REAL_LIB" \
    PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    PROKOP_RUNTIME_LIST_GENERATION_DIR="$WORK_DIR/generation" \
    PROKOP_RULESET_CACHE_DIR="$WORK_DIR/ruleset-cache" \
    TMP_RULESET_FOLDER="$WORK_DIR/rulesets" \
    PROKOP_RUNTIME_STATE_DIR="$RUN" \
    PROKOP_RELOAD_LOCK_DIR="$RUN/reload.lock" \
    PROKOP_LIST_UPDATE_PID_FILE="$RUN/list.pid" \
    PROKOP_PENDING_RELOAD_FILE="$RUN/reload.pending" \
    PROKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/cache" \
    PROKOP_LIST_UPDATE_STATE_FILE="$WORK_DIR/cache/list-update.timestamp" \
    PROKOP_SERVICE_INIT="$WORK_DIR/bin/init-prokop" \
    NFT_TABLE_NAME=prokop \
    ucode -L "$REAL_LIB" "$REAL_LIB/components/updates.uc" "$@"
}

field() {
  ucode -e 'let v = json(getenv("JSON")); for (let k in split(ARGV[0], ".")) v = v == null ? null : v[k]; print(type(v) == "array" ? join("\n", v) : v, "\n");' -- "$1"
}

# 1. Before any update: nothing runs and there is no last result.
status_json="$(updates list-update-status)" || fail "list-update-status failed"
[ "$(JSON="$status_json" field running)" = false ] || fail "a lists update runs before any was started: $status_json"
[ "$(JSON="$status_json" field last_result)" = "" ] || fail "a last result exists before any update: $status_json"

# 2. A synchronous update with one failing source records the outcome.
updates list-update >"$WORK_DIR/worker.log" 2>&1 || true
cp "$RUN/list-update-result.json" "$WORK_DIR/result.json" 2>/dev/null || true
[ -s "$RUN/list-update-result.json" ] || fail "the lists update did not record its result"
status_json="$(updates list-update-status)" || fail "list-update-status failed"
[ "$(JSON="$status_json" field running)" = false ] || fail "a finished lists update still reads as running: $status_json"
[ "$(JSON="$status_json" field last_result.success)" = false ] || fail "a lists update with a failed source reads as successful: $status_json"
failed="$(JSON="$status_json" field last_result.failed_sources)"
[ "$failed" = "list source bad.test/private/list.txt" ] ||
  fail "the failed source is not named as expected: $failed"
case "$status_json" in
  *pa55word* | *s3cret* | *frag* | *user:* | *lists.test*) fail "the status leaks credentials or names a source that worked: $status_json" ;;
esac
[ "$(JSON="$status_json" field last_result.finished_at)" -ge "$(JSON="$status_json" field last_result.started_at)" ] ||
  fail "the last result has no consistent times: $status_json"

# 3. Without the failing source the update succeeds and the failure is gone.
sed -i '/^prokop.beta/d' "$WORK_DIR/uci.state"
updates list-update >"$WORK_DIR/worker.log" 2>&1 || fail "the lists update without a failing source failed"
status_json="$(updates list-update-status)"
[ "$(JSON="$status_json" field last_result.success)" = true ] || fail "a successful lists update reads as failed: $status_json"
[ "$(JSON="$status_json" field last_result.failed_sources)" = "" ] || fail "a successful lists update kept old failed sources: $status_json"
[ "$(JSON="$status_json" field last_success_at)" -gt 0 ] || fail "the last successful update time is missing: $status_json"

# 4. The background start runs the list-update worker; a second start while
#    it runs starts nothing.
: >"$WORK_DIR/slow"
rm -f "$RUN/list-update-result.json"
start_json="$(updates list-update-async)" || fail "list-update-async failed: $start_json"
[ "$(JSON="$start_json" field started)" = true ] || fail "list-update-async did not start the worker: $start_json"
wait_until 30 pgrep -f "$WORK_DIR/bin/curl" >/dev/null ||
  fail "the background lists update did not start downloading"
status_json="$(updates list-update-status)"
[ "$(JSON="$status_json" field running)" = true ] || fail "a running background lists update is not reported: $status_json"
second_json="$(updates list-update-async)" || fail "a second list-update-async failed: $second_json"
{ [ "$(JSON="$second_json" field started)" = false ] && [ "$(JSON="$second_json" field running)" = true ]; } ||
  fail "a second start while the worker runs did not answer running: $second_json"
rm -f "$WORK_DIR/slow"
wait_until 60 sh -c "[ -s '$RUN/list-update-result.json' ]" || fail "the background lists update did not finish"
wait_until 30 sh -c "[ ! -e '$RUN/list.pid' ]" || fail "the background lists update did not release its pidfile"
status_json="$(updates list-update-status)"
{ [ "$(JSON="$status_json" field running)" = false ] && [ "$(JSON="$status_json" field last_result.success)" = true ]; } ||
  fail "the background lists update did not end successfully: $status_json"

printf 'OK: manual lists update and its last result\n'
