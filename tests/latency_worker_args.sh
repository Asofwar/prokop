#!/usr/bin/env bash
set -euo pipefail

# UC-033: the dashboard latency job passes the job state path to clash_api
# only for a proxy list, where it is the progress file. For a single proxy the
# third argument of get_proxy_latency is the test URL (priority.uc health
# checks rely on it), so the path must not reach it: sing-box would test
# "/var/run/.../<job>.json" and fail. A group delay takes no third argument.
#
# The real ui.uc latency-worker runs against a PROKOP_BIN double that records
# its argv and answers with a canned rc, so the job outcome follows clash_api.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
UI_UC="$PROKOP_LIB/service/ui.uc"
WORK="$(mktemp -d)"
cleanup() {
  [ -n "${KEEP_WORK:-}" ] || rm -rf "${WORK:?}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v ucode >/dev/null || fail "ucode is required"
command -v node >/dev/null || fail "node is required"

cat >"${WORK:?}/prokop-bin" <<'SH'
#!/bin/sh
# Records one argument per line, then answers like clash_api would.
: >"$FAKE_ARGV_LOG"
for arg in "$@"; do
  printf '%s\n' "$arg" >>"$FAKE_ARGV_LOG"
done
printf '%s\n' "$FAKE_ANSWER"
exit "$FAKE_RC"
SH
chmod +x "${WORK:?}/prokop-bin"

export PROKOP_LIB
export PROKOP_BIN="${WORK:?}/prokop-bin"
export PROKOP_UI_STATE_DIR="${WORK:?}/ui-state"
export PROKOP_UI_LATENCY_ACTION_DIR="${WORK:?}/ui-state/latency-actions"
export PROKOP_LATENCY_TEST_LOCK_DIR="${WORK:?}/latency.lock"
export PROKOP_RUNTIME_STATE_DIR="${WORK:?}/run"
mkdir -p "$PROKOP_UI_LATENCY_ACTION_DIR" "$PROKOP_RUNTIME_STATE_DIR"

# run_worker TYPE TAG TIMEOUT RC ANSWER: runs one job and leaves its state
# path in STATE and the recorded argv in ARGV_LOG.
run_worker() {
  local type="$1" tag="$2" timeout="$3" rc="$4" answer="$5"
  STATE="$PROKOP_UI_LATENCY_ACTION_DIR/job-$type.json"
  ARGV_LOG="${WORK:?}/argv-$type"
  printf '{"success":true,"running":true,"kind":"latency","latency_type":"%s","section":"main","tag":"x","started_at":100}\n' \
    "$type" >"$STATE"
  FAKE_ARGV_LOG="$ARGV_LOG" FAKE_RC="$rc" FAKE_ANSWER="$answer" \
    ucode -L "$PROKOP_LIB" "$UI_UC" latency-worker "$STATE" "$type" "$tag" "$timeout" ||
    fail "latency-worker $type exited non-zero"
}

expect_argv() {
  local expected
  expected="$(printf '%s\n' "$@")"
  [ "$(cat "$ARGV_LOG")" = "$expected" ] || {
    printf 'expected argv:\n%s\ngot:\n%s\n' "$expected" "$(cat "$ARGV_LOG")" >&2
    fail "$1 $2 called with the wrong arguments"
  }
}

expect_state() {
  STATE_FILE="$STATE" node - "$1" "$2" <<'NODE'
const fs = require("fs");
const [success, label] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
if (value.running !== false || value.success !== (success === "true")) {
  console.error(`${label}: expected a finished job with success=${success}, got ${JSON.stringify(value)}`);
  process.exit(1);
}
NODE
}

# A single proxy: the test URL comes from settings, never from the job path.
run_worker proxy proxy-out 5000 0 '{"delay":42}'
expect_argv clash_api get_proxy_latency proxy-out 5000
grep -Fq "$STATE" "$ARGV_LOG" && fail "the job state path reached get_proxy_latency as its test URL"
expect_state true "proxy measured"

run_worker group main-urltest 10000 0 '{"proxy-a":42}'
expect_argv clash_api get_group_latency main-urltest 10000
expect_state true "group measured"

# A proxy list keeps the progress path as its third argument.
run_worker proxy_list '["proxy-a","proxy-b"]' 5000 0 '{"success":true,"count":2,"failed":false}'
expect_argv clash_api get_proxy_latencies '["proxy-a","proxy-b"]' 5000 "$STATE"
expect_state true "proxy list measured"

# A clash_api failure ends the job as failed, whatever the type.
for type in proxy group proxy_list; do
  run_worker "$type" tag 5000 1 '{"success":false,"error":"latency_failed","message":"An error occurred in the delay test"}'
  expect_state false "$type failure"
done

printf 'latency worker argument checks passed\n'
