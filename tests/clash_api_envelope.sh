#!/usr/bin/env bash
set -euo pipefail

# UC-118, UC-033: `prokop clash_api` exits non-zero exactly when it prints a
# failure, and every failure has one envelope:
#   {"success": false, "error": "<code>", "message": "<text>", ...}
# A transport failure (no answer, timeout), a sing-box error body
# ({"message": ...} with an HTTP error status, on which curl -s still exits 0),
# a delay test that measured nothing and bad arguments all fail that way. A
# delay test succeeds only with a numeric delay: {"delay": N} for a proxy, a
# member map {"tag": N, ...} with at least one delay for a group, and per tag
# for a proxy list, whose failed tags are counted; like a group, a list fails
# only when no tag measured a delay.
#
# The automatic latency test after a start is unchanged: a proxy that sing-box
# tested and found unreachable is a result, not a failed run (its pending
# marker is removed); only a run the controller did not answer is retried.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
RUNTIME_UC="$PROKOP_LIB/diagnostics/runtime.uc"
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

FAKE_DIR="${WORK:?}/answers"
mkdir -p "${WORK:?}/bin" "$FAKE_DIR"
# The controller double: the answer to <path> is $FAKE_DIR/<path with / as _>
# (.body is printed, .rc is curl's exit code; no file: no output, rc 0).
cat >"${WORK:?}/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
url=""
for arg in "$@"; do
  case "$arg" in
    *127.0.0.1:9090/*) url="$arg" ;;
  esac
done
key="$(printf '%s' "${url#*127.0.0.1:9090/}" | tr '/' '_')"
[ -f "$FAKE_DIR/$key.body" ] && cat "$FAKE_DIR/$key.body"
if [ -f "$FAKE_DIR/$key.rc" ]; then
  exit "$(cat "$FAKE_DIR/$key.rc")"
fi
exit 0
SH
chmod +x "${WORK:?}/bin/curl"

uci_state="${WORK:?}/uci-state"
cat >"$uci_state" <<'EOF'
prokop.settings=settings
prokop.settings.latency_test_url=https://latency.example/generate_204
EOF

export PROKOP_LIB FAKE_DIR
export PROKOP_UCI_STATE_FILE="$uci_state"
export FAKE_CURL_LOG="${WORK:?}/curl.log"
export PATH="${WORK:?}/bin:$PATH"

answer() {
  local key="$1" body="$2" rc="${3:-0}"
  printf '%s\n' "$body" >"$FAKE_DIR/$key.body"
  printf '%s\n' "$rc" >"$FAKE_DIR/$key.rc"
}

no_answer() {
  rm -f "$FAKE_DIR/$1.body"
  printf '%s\n' "$2" >"$FAKE_DIR/$1.rc"
}

# clash ACTION ARG...: runs the action, leaves stdout in OUT and rc in RC.
clash() {
  set +e
  OUT="$(ucode -L "$PROKOP_LIB" "$RUNTIME_UC" clash-api "$@" 2>/dev/null)"
  RC=$?
  set -e
}

# expect_ok LABEL [JS]: rc 0, a JSON answer that is no failure envelope, and
# an optional check of `value`.
expect_ok() {
  [ "$RC" -eq 0 ] || fail "$1: expected rc 0, got $RC with: $OUT"
  OUT="$OUT" node - "$1" "${2:-true}" <<'NODE'
const [label, check] = process.argv.slice(2);
let value;
try { value = JSON.parse(process.env.OUT); } catch (e) {
  console.error(`${label}: output is not JSON: ${process.env.OUT}`); process.exit(1);
}
if (value && value.success === false) {
  console.error(`${label}: rc 0 with a failure: ${process.env.OUT}`); process.exit(1);
}
if (!eval(check)) { console.error(`${label}: unexpected answer ${process.env.OUT}`); process.exit(1); }
NODE
}

# expect_failure LABEL CODE [JS]: rc 1 and the one failure envelope.
expect_failure() {
  [ "$RC" -eq 1 ] || fail "$1: expected rc 1, got $RC with: $OUT"
  OUT="$OUT" node - "$1" "$2" "${3:-true}" <<'NODE'
const [label, code, check] = process.argv.slice(2);
let value;
try { value = JSON.parse(process.env.OUT); } catch (e) {
  console.error(`${label}: failure output is not JSON: ${process.env.OUT}`); process.exit(1);
}
if (!value || value.success !== false || value.error !== code ||
    typeof value.message !== "string" || value.message === "") {
  console.error(`${label}: expected {success:false, error:${code}, message}, got ${process.env.OUT}`);
  process.exit(1);
}
if (!eval(check)) { console.error(`${label}: unexpected envelope ${process.env.OUT}`); process.exit(1); }
NODE
}

proxies='{"proxies":{"proxy-a":{"type":"VLESS"},"proxy-b":{"type":"Trojan"},"auto":{"type":"URLTest","all":["proxy-a","proxy-b"]},"main":{"type":"Selector","all":["auto","proxy-a"]}}}'

# --- get_proxies / get_connections -----------------------------------------
answer proxies "$proxies"
clash get_proxies
expect_ok "get_proxies" 'value.proxies["proxy-a"].type === "VLESS"'

answer proxies '{"message":"Unauthorized"}'
clash get_proxies
expect_failure "get_proxies with a sing-box error body" clash_api_error 'value.message === "Unauthorized"'

no_answer proxies 7
clash get_proxies
expect_failure "get_proxies without a controller" clash_api_unreachable

no_answer proxies 28
clash get_proxies
expect_failure "get_proxies past its bound" clash_api_timeout

no_answer proxies 0
clash get_proxies
expect_failure "get_proxies with an empty answer" clash_api_invalid_response

answer proxies '<html>gateway</html>'
clash get_proxies
expect_failure "get_proxies with a non-JSON answer" clash_api_invalid_response

answer connections '{"downloadTotal":1,"uploadTotal":2,"connections":[]}'
clash get_connections
expect_ok "get_connections" 'Array.isArray(value.connections)'

answer connections '{"message":"Unauthorized"}'
clash get_connections
expect_failure "get_connections with a sing-box error body" clash_api_error

# --- get_proxy_latency ---------------------------------------------------------
answer proxies_proxy-a_delay '{"delay":42}'
clash get_proxy_latency proxy-a 5000
expect_ok "get_proxy_latency" 'value.delay === 42'
grep -F 'proxies/proxy-a/delay' "$FAKE_CURL_LOG" | tail -n1 | grep -Fq 'url=https://latency.example/generate_204' ||
  fail "get_proxy_latency without a URL must test the configured latency_test_url"

# priority.uc passes its own health URL as the third argument.
clash get_proxy_latency proxy-a 2000 https://health.example/check
expect_ok "get_proxy_latency with a URL"
grep -F 'proxies/proxy-a/delay' "$FAKE_CURL_LOG" | tail -n1 | grep -Fq 'url=https://health.example/check' ||
  fail "get_proxy_latency must keep its URL argument (singbox/priority.uc)"

answer proxies_proxy-a_delay '{"message":"An error occurred in the delay test"}'
clash get_proxy_latency proxy-a 5000
expect_failure "get_proxy_latency with a failed test" latency_failed \
  'value.message === "An error occurred in the delay test"'

answer proxies_proxy-a_delay '{"message":"Timeout"}'
clash get_proxy_latency proxy-a 5000
expect_failure "get_proxy_latency past the test timeout" latency_failed

answer proxies_proxy-a_delay '{"delay":"fast"}'
clash get_proxy_latency proxy-a 5000
expect_failure "get_proxy_latency without a numeric delay" latency_failed

no_answer proxies_proxy-a_delay 7
clash get_proxy_latency proxy-a 5000
expect_failure "get_proxy_latency without a controller" clash_api_unreachable

clash get_proxy_latency "" 5000
expect_failure "get_proxy_latency without a tag" invalid_input

# --- get_group_latency ---------------------------------------------------------
answer proxies "$proxies"
answer group_auto_delay '{"proxy-a":42,"proxy-b":120}'
clash get_group_latency auto 5000
expect_ok "get_group_latency" 'value["proxy-a"] === 42'

answer group_auto_delay '{}'
clash get_group_latency auto 5000
expect_failure "get_group_latency with no member measured" latency_failed

answer group_auto_delay '{"message":"context deadline exceeded"}'
clash get_group_latency auto 5000
expect_failure "get_group_latency with a sing-box error" latency_failed \
  'value.message === "context deadline exceeded"'

no_answer proxies 7
clash get_group_latency auto 5000
expect_failure "get_group_latency without a controller" clash_api_unavailable
answer proxies "$proxies"

clash get_group_latency "" 5000
expect_failure "get_group_latency without a tag" invalid_input

# --- get_proxy_latencies ---------------------------------------------------------
progress_dir="${WORK:?}/ui-state/latency-actions"
mkdir -p "$progress_dir"
progress="$progress_dir/job.json"
reset_progress() {
  printf '%s\n' '{"success":true,"running":true,"kind":"latency","latency_type":"proxy_list","section":"main","tag":"[]","started_at":100}' >"$progress"
}
expect_progress() {
  PROGRESS="$progress" node - "$1" "$2" "$3" <<'NODE'
const fs = require("fs");
const [completed, failed, label] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(process.env.PROGRESS, "utf8"));
const p = value.progress || {};
if (p.completed !== Number(completed) || p.failed !== Number(failed)) {
  console.error(`${label}: expected progress ${completed} done / ${failed} failed, got ${JSON.stringify(p)}`);
  process.exit(1);
}
NODE
}
export PROKOP_UI_LATENCY_ACTION_DIR="$progress_dir"

answer proxies_proxy-a_delay '{"delay":42}'
answer proxies_proxy-b_delay '{"delay":51}'
answer group_auto_delay '{"proxy-a":42}'
reset_progress
clash get_proxy_latencies '["proxy-a","proxy-b","auto"]' 5000 "$progress"
expect_ok "get_proxy_latencies" 'value.success === true && value.count === 3 && value.failed === false'
expect_progress 3 0 "get_proxy_latencies all measured"

# A list of a selector section often holds a dead node: the run succeeds
# while some tag measured a delay, like a group, and counts the others.
answer proxies_proxy-b_delay '{"message":"An error occurred in the delay test"}'
answer group_auto_delay '{}'
reset_progress
clash get_proxy_latencies '["proxy-a","proxy-b","auto"]' 5000 "$progress"
expect_ok "get_proxy_latencies with some failed tests" \
  'value.success === true && value.count === 3 && value.failed === true && value.failed_count === 2'
expect_progress 3 2 "get_proxy_latencies counts error bodies as failed"

answer proxies_proxy-a_delay '{"message":"An error occurred in the delay test"}'
reset_progress
clash get_proxy_latencies '["proxy-a","proxy-b","auto"]' 5000 "$progress"
expect_failure "get_proxy_latencies with no tag measured" latency_failed \
  'value.count === 3 && value.failed === true && value.failed_count === 3'
expect_progress 3 3 "get_proxy_latencies with no tag measured"
answer proxies_proxy-a_delay '{"delay":42}'

clash get_proxy_latencies 'not-json' 5000
expect_failure "get_proxy_latencies with bad tags" invalid_input

no_answer proxies 7
clash get_proxy_latencies '["proxy-a"]' 5000
expect_failure "get_proxy_latencies without a controller" clash_api_unavailable
answer proxies "$proxies"

# --- writes and unknown actions ---------------------------------------------------
printf '%s\n%s' '{"message":"Internal error"}' 500 >"$FAKE_DIR/proxies_main.body"
printf '0\n' >"$FAKE_DIR/proxies_main.rc"
clash set_group_proxy main proxy-a
expect_failure "set_group_proxy with an HTTP error" clash_api_error 'value.http_code === 500'

printf '\n%s' 404 >"$FAKE_DIR/proxies_main.body"
clash set_group_proxy main proxy-a
expect_failure "set_group_proxy of a missing group" group_not_found

printf '\n%s' 204 >"$FAKE_DIR/proxies_main.body"
clash set_group_proxy main proxy-a
expect_ok "set_group_proxy" 'value.success === true'

clash set_group_proxy main ""
expect_failure "set_group_proxy without a proxy" invalid_input

clash no_such_action
expect_failure "an unknown action" invalid_input 'Array.isArray(value.available)'

# --- the dashboard latency job end to end (UC-033) -----------------------------
# service/ui.uc latency-worker -> /usr/bin/prokop clash_api -> runtime.uc.
cat >"${WORK:?}/prokop" <<SH
#!/bin/sh
exec ucode "$ROOT_DIR/prokop/files/usr/bin/prokop" "\$@"
SH
chmod +x "${WORK:?}/prokop"
job_dir="${WORK:?}/ui-state/latency-actions"
run_latency_job() {
  job="$job_dir/job-$1.json"
  printf '{"success":true,"running":true,"kind":"latency","latency_type":"%s","section":"main","tag":"%s","started_at":100}\n' \
    "$1" "$2" >"$job"
  PROKOP_BIN="${WORK:?}/prokop" PROKOP_LATENCY_TEST_LOCK_DIR="${WORK:?}/latency.lock" \
  PROKOP_RUNTIME_STATE_DIR="${WORK:?}/run" \
    ucode -L "$PROKOP_LIB" "$PROKOP_LIB/service/ui.uc" latency-worker "$job" "$1" "$2" 5000 ||
    fail "latency-worker $1 exited non-zero"
  JOB="$job" node -e 'const v = JSON.parse(require("fs").readFileSync(process.env.JOB, "utf8"));
    if (v.running !== false) process.exit(1); process.stdout.write(String(v.success));'
}
mkdir -p "${WORK:?}/run"
answer proxies_proxy-a_delay '{"message":"An error occurred in the delay test"}'
[ "$(run_latency_job proxy proxy-a)" = false ] ||
  fail "a dashboard latency test that measured nothing must end as failed"
grep -F 'proxies/proxy-a/delay' "$FAKE_CURL_LOG" | tail -n1 | grep -Fq 'url=https://latency.example/generate_204' ||
  fail "the dashboard latency test of one proxy must test the configured URL, not its job file"
answer proxies_proxy-a_delay '{"delay":42}'
[ "$(run_latency_job proxy proxy-a)" = true ] ||
  fail "a dashboard latency test with a delay must end as completed"
answer group_auto_delay '{}'
[ "$(run_latency_job group auto)" = false ] ||
  fail "a group latency test with no member measured must end as failed"
answer proxies_proxy-b_delay '{"message":"An error occurred in the delay test"}'
[ "$(run_latency_job proxy_list '["proxy-a","proxy-b"]')" = true ] ||
  fail "a section latency test where one proxy measured a delay must end as completed"
answer proxies_proxy-a_delay '{"message":"An error occurred in the delay test"}'
[ "$(run_latency_job proxy_list '["proxy-a","proxy-b"]')" = false ] ||
  fail "a section latency test where no proxy measured a delay must end as failed"

# --- the automatic latency test --------------------------------------------------
# Only the lock and readiness answers of service/state.uc are modelled here.
mkdir -p "${WORK:?}/latency-lib/service"
ln -s "$PROKOP_LIB/core" "${WORK:?}/latency-lib/core"
ln -s "$PROKOP_LIB/diagnostics" "${WORK:?}/latency-lib/diagnostics"
ln -s "$PROKOP_LIB/singbox" "${WORK:?}/latency-lib/singbox"
cat >"${WORK:?}/latency-lib/service/state.uc" <<'UC'
if (ARGV[0] == "sing-box-service-runtime-pid") {
    print("4242\n");
    exit(0);
}
if (ARGV[0] == "single-ready-sing-box-runtime" ||
    ARGV[0] == "acquire-runtime-dir-lock" ||
    ARGV[0] == "acquire-runtime-dir-lock-wait" ||
    ARGV[0] == "release-runtime-dir-lock")
    exit(0);
exit(64);
UC
printf '%s\n' '{"outbounds":[{"type":"vless","tag":"proxy-a","server":"one.test"},{"type":"trojan","tag":"proxy-b","server":"two.test"}]}' >"${WORK:?}/config.json"
printf 'prokop.settings.config_path=%s\n' "${WORK:?}/config.json" >>"$uci_state"
signature="$(ucode -L "$PROKOP_LIB" "$RUNTIME_UC" proxy-outbounds-signature "${WORK:?}/config.json")"
marker="${WORK:?}/automatic.pending"

run_automatic() {
  printf '{"format":"1","signature":"%s"}\n' "$signature" >"$marker"
  set +e
  PROKOP_LIB="${WORK:?}/latency-lib" \
  PROKOP_AUTOMATIC_LATENCY_PENDING_FILE="$marker" \
  PROKOP_AUTOMATIC_LATENCY_TEST_LOCK_DIR="${WORK:?}/automatic.lock" \
  PROKOP_PENDING_RELOAD_FILE="${WORK:?}/reload.pending" \
  PROKOP_AUTOMATIC_LATENCY_BATCH_PAUSE=0 \
    ucode -L "$ROOT_DIR/prokop/files/usr/lib" "$RUNTIME_UC" automatic-latency-test >/dev/null 2>&1
  RC=$?
  set -e
}

answer proxies_proxy-b_delay '{"message":"An error occurred in the delay test"}'
run_automatic
[ "$RC" -eq 0 ] || fail "an unreachable proxy must not fail the automatic latency test (rc $RC)"
[ ! -e "$marker" ] || fail "the automatic latency test must remove its marker once every proxy was tested"

no_answer proxies_proxy-b_delay 28
run_automatic
[ "$RC" -ne 0 ] || fail "a delay request the controller did not answer must fail the automatic latency test"
[ -e "$marker" ] || fail "the automatic latency test must keep its marker when the controller did not answer"

printf 'clash_api envelope checks passed\n'
