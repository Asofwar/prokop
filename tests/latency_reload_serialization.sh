#!/bin/sh
set -eo pipefail

# Automatic latency tests query the running sing-box through the Clash API
# and must never race a Prokop reload. Who schedules and resumes the test is
# checked in the sources. The serialization itself is checked by running the
# production worker (diagnostics/runtime.uc automatic-latency-test) against a
# runtime-state stub that records every lock and handoff call next to the
# Clash requests: every latency request is made while the worker holds the
# reload lock, a reload in progress or a sing-box that is not ready defers the
# test, the worker hands the reload lock over between bounded batches and
# yields to a pending reload, and a duplicate request is dropped at once
# instead of queued. The pending marker's retry bookkeeping is covered by
# automatic_latency_pending.sh.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
LIFECYCLE_UC="$PROKOP_LIB/service/lifecycle.uc"
DIAGNOSTICS_UC="$PROKOP_LIB/diagnostics/runtime.uc"
UPDATES_UC="$PROKOP_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# --- Wiring -----------------------------------------------------------------
grep -Fq 'refresh-rulesets-after-start' "$LIFECYCLE_UC" ||
  fail "cold-start rule-set refresh must remain enabled without a latency test"
grep -Fq 'module_background(DIAGNOSTICS_UC, [ "automatic-latency-test", "resume" ])' "$LIFECYCLE_UC" ||
  fail "successful startup must resume a persistent pending latency test"
[ "$(grep -Fc 'module_background(DIAGNOSTICS_UC, [ "automatic-latency-test", "resume" ])' "$LIFECYCLE_UC")" -eq 1 ] ||
  fail "startup must contain only one pending-test resume hook"
[ "$(grep -Fc 'module_background([ DIAGNOSTICS_UC, "automatic-latency-test", "new" ])' "$UPDATES_UC")" -eq 1 ] ||
  fail "subscription changes must launch one new automatic latency worker"
grep -Fq 'AUTOMATIC_LATENCY_PENDING_FILE' "$UPDATES_UC" ||
  fail "subscription changes must use a persistent pending marker"
grep -Fq 'write_state_file(AUTOMATIC_LATENCY_PENDING_FILE' "$UPDATES_UC" ||
  fail "pending marker must be written atomically"
grep -Fq 'final_proxy_set_changed = proxy_signature_after != "" && proxy_signature_after != proxy_signature_before' "$UPDATES_UC" ||
  fail "latency scheduling must compare the final usable proxy set"
grep -Fq 'function single_ready_sing_box_runtime()' "$PROKOP_LIB/service/state.uc" ||
  fail "service state must expose the single ready sing-box predicate"

# The LuCI/manual bulk action stays available and is intentionally independent
# from the removed lifecycle scheduling.
grep -Fq 'if (action == "get_proxy_latencies")' "$DIAGNOSTICS_UC" ||
  fail "manual LuCI bulk latency test must remain available"
grep -Fq 'let owner_pid = current_pid();' "$PROKOP_LIB/service/ui.uc" ||
  fail "manual LuCI latency lock must be owned by the live worker process"

# --- Serialization, observed -------------------------------------------------
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/config.json" <<'EOF_CONFIG'
{"outbounds":[{"type":"direct","tag":"direct"},{"type":"vless","tag":"proxy-a","server":"one.test","server_port":443},{"type":"trojan","tag":"proxy-b","server":"two.test","server_port":443},{"type":"vmess","tag":"proxy-c","server":"three.test","server_port":443}]}
EOF_CONFIG
cat >"$WORK_DIR/uci.state" <<EOF_UCI
prokop.settings=settings
prokop.settings.config_path=$WORK_DIR/config.json
EOF_UCI

# Runtime state stub: locks are directories (a held lock fails at once, as a
# reload that does not finish in time), every call is recorded.
cat >"$WORK_DIR/state-stub.uc" <<'EOF_STATE'
#!/usr/bin/env ucode
let fs = require("fs");
let mode = ARGV[0] || "", path = ARGV[1] || "";
function event(text) {
    let fh = fs.open(getenv("TEST_EVENTS"), "a");
    fh.write(text + "\n");
    fh.close();
}
function lock_name(p) {
    return p == getenv("PROKOP_RELOAD_LOCK_DIR") ? "reload"
        : p == getenv("PROKOP_AUTOMATIC_LATENCY_TEST_LOCK_DIR") ? "latency" : p;
}
if (mode == "acquire-runtime-dir-lock" || mode == "acquire-runtime-dir-lock-wait") {
    let ok = fs.stat(path) == null && fs.mkdir(path) == true;
    event((mode == "acquire-runtime-dir-lock" ? "try " : "wait ") + lock_name(path) + (ok ? " ok" : " busy"));
    exit(ok ? 0 : 1);
}
if (mode == "release-runtime-dir-lock") {
    fs.rmdir(path);
    event("release " + lock_name(path));
    exit(0);
}
if (mode == "single-ready-sing-box-runtime") {
    let ready = fs.stat(getenv("TEST_NOT_READY_FLAG")) == null;
    event("ready " + (ready ? "yes" : "no"));
    exit(ready ? 0 : 1);
}
if (mode == "run-pending-reload-if-requested") {
    event("handoff");
    if (fs.stat(getenv("TEST_KEEP_PENDING_FLAG")) != null)
        fs.writefile(getenv("PROKOP_PENDING_RELOAD_FILE"), "1\n");
    exit(0);
}
if (mode == "sing-box-service-runtime-pid") {
    print("123\n");
    exit(0);
}
exit(0);
EOF_STATE
cat >"$WORK_DIR/bin/logger" <<'EOF_LOGGER'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_LOG"
EOF_LOGGER
cat >"$WORK_DIR/bin/curl" <<'EOF_CURL'
#!/bin/sh
case "$*" in
  */proxies)
    printf '%s\n' '{"proxies":{"proxy-a":{"type":"VLESS"},"proxy-b":{"type":"Trojan"},"proxy-c":{"type":"VMess"},"DIRECT":{"type":"Direct"}}}'
    ;;
  */delay*)
    printf 'request\n' >>"$TEST_EVENTS"
    # A reload that arrives now finds reload.lock held: init.d queues it.
    [ ! -e "$TEST_QUEUE_RELOAD_FLAG" ] || printf 'reason=on_config_change\n' >"$PROKOP_PENDING_RELOAD_FILE"
    printf '%s\n' '{"delay":25}'
    ;;
  *) printf '%s\n' '{}' ;;
esac
EOF_CURL
chmod +x "$WORK_DIR/bin/logger" "$WORK_DIR/bin/curl" "$WORK_DIR/state-stub.uc"

export PATH="$WORK_DIR/bin:$PATH"
export TEST_LOG="$WORK_DIR/test.log"
export TEST_EVENTS="$WORK_DIR/events"
export TEST_NOT_READY_FLAG="$WORK_DIR/not-ready"
export TEST_KEEP_PENDING_FLAG="$WORK_DIR/keep-pending"
export TEST_QUEUE_RELOAD_FLAG="$WORK_DIR/queue-reload"
export PROKOP_LIB PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_SERVICE_STATE_UC="$WORK_DIR/state-stub.uc"
export PROKOP_AUTOMATIC_LATENCY_PENDING_FILE="$WORK_DIR/automatic-latency.pending"
export PROKOP_AUTOMATIC_LATENCY_TEST_LOCK_DIR="$WORK_DIR/latency.lock"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/reload.pending"
export PROKOP_AUTOMATIC_LATENCY_BATCH_PAUSE=0
export PROKOP_AUTOMATIC_LATENCY_CLASH_READY_ATTEMPTS=1

signature="$(ucode -L "$PROKOP_LIB" "$DIAGNOSTICS_UC" proxy-outbounds-signature "$WORK_DIR/config.json")"
[ -n "$signature" ] || fail "proxy signature was not produced"

# run_worker BATCH_SIZE: schedules a test for the current proxy set and runs
# one new worker; the recorded calls land in $TEST_EVENTS.
run_worker() {
  : >"$TEST_EVENTS"
  : >"$TEST_LOG"
  ucode -L "$PROKOP_LIB" "$UPDATES_UC" schedule-automatic-latency-test "$signature" ||
    fail "the latency test was not scheduled"
  PROKOP_AUTOMATIC_LATENCY_BATCH_SIZE="$1" ucode -L "$PROKOP_LIB" "$DIAGNOSTICS_UC" automatic-latency-test new \
    >"$WORK_DIR/worker.out" 2>&1 || {
    cat "$WORK_DIR/worker.out" >&2
    return 1
  }
}

# check_events DESCRIPTION REQUESTS HANDOFFS: every request is made while the
# worker holds the latency and the reload lock, each handoff to a pending
# reload happens with the reload lock released, and both locks are released
# at the end.
check_events() {
  awk -v label="$1" -v want_requests="$2" -v want_handoffs="$3" '
    function bad(message) { printf "FAIL: %s: %s (event %d: %s)\n", label, message, NR, $0 > "/dev/stderr"; failed = 1; exit 1 }
    $0 == "try latency ok" || $0 == "wait latency ok" { latency = 1 }
    $0 == "wait reload ok" || $0 == "try reload ok" { reload = 1 }
    $0 == "release latency" { latency = 0 }
    $0 == "release reload" { reload = 0 }
    $0 == "request" { requests++; if (!latency) bad("latency request without the latency test lock"); if (!reload) bad("latency request without the reload lock") }
    $0 == "handoff" { handoffs++; if (reload) bad("pending reload handoff while the worker holds the reload lock") }
    END {
      if (failed) exit 1
      if (latency || reload) { printf "FAIL: %s: a lock was left held\n", label > "/dev/stderr"; exit 1 }
      if (requests != want_requests) { printf "FAIL: %s: %d latency requests, want %d\n", label, requests, want_requests > "/dev/stderr"; exit 1 }
      if (handoffs != want_handoffs) { printf "FAIL: %s: %d reload handoffs, want %d\n", label, handoffs, want_handoffs > "/dev/stderr"; exit 1 }
    }
  ' "$TEST_EVENTS" || {
    sed 's/^/  event: /' "$TEST_EVENTS" >&2
    sed 's/^/  log: /' "$TEST_LOG" >&2
    exit 1
  }
}

# One proxy per batch: the reload lock is handed over between every batch.
run_worker 1 || fail "a serialized latency test failed"
check_events "batches of one" 3 2
[ ! -e "$PROKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "a completed test kept its pending marker"
[ "$(grep -c '^wait reload ok$' "$TEST_EVENTS")" -eq 3 ] ||
  fail "the worker must re-acquire the reload lock after every handoff"

# Bounded batches: two proxies, then one handoff, then the last proxy.
run_worker 2 || fail "a batched latency test failed"
check_events "batches of two" 3 1
[ "$(sed -n '/^handoff$/=' "$TEST_EVENTS")" -gt "$(sed -n '/^request$/=' "$TEST_EVENTS" | sed -n '2p')" ] ||
  fail "the reload handoff must follow a full batch"

# A pending reload after the handoff wins: the worker stops and keeps the marker.
: >"$TEST_KEEP_PENDING_FLAG"
run_worker 1 || fail "yielding to a pending reload is not a failure"
rm -f "$TEST_KEEP_PENDING_FLAG" "$PROKOP_PENDING_RELOAD_FILE"
check_events "pending reload" 1 1
[ -s "$PROKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "yielding to a reload dropped the pending marker"
grep -Fq 'yielded to a pending Prokop reload handoff' "$TEST_LOG" || fail "the yield was not logged"

# A reload in progress: no request is made and the marker waits.
mkdir "$PROKOP_RELOAD_LOCK_DIR"
run_worker 4 || fail "a deferred latency test is not a failure"
rm -rf "$PROKOP_RELOAD_LOCK_DIR"
check_events "reload in progress" 0 0
grep -Fxq 'wait reload busy' "$TEST_EVENTS" || fail "the worker did not wait for the reload lock"
[ -s "$PROKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "a deferred test dropped its pending marker"
grep -Fq 'did not finish reloading' "$TEST_LOG" || fail "the deferral was not logged"

# sing-box not ready (or several sing-box processes): no request either.
: >"$TEST_NOT_READY_FLAG"
run_worker 4 || fail "a deferred latency test is not a failure"
rm -f "$TEST_NOT_READY_FLAG"
check_events "sing-box not ready" 0 0
grep -Fxq 'ready no' "$TEST_EVENTS" || fail "the worker did not check for one ready sing-box process"
[ -s "$PROKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "a deferred test dropped its pending marker"

# A reload queued behind the test while it held reload.lock is applied when
# the test lets the lock go for good, after its last batch or when it gives
# up early: no other holder is left to apply it, and a UI reload job that
# init.d queued behind the test has ended by then (UC-061). One batch, so
# there is no handoff between batches.
: >"$TEST_QUEUE_RELOAD_FLAG"
run_worker 4 || fail "a latency test with a queued reload failed"
rm -f "$TEST_QUEUE_RELOAD_FLAG"
check_events "reload queued during the last batch" 3 1
[ "$(tail -n 1 "$TEST_EVENTS")" = handoff ] || {
  sed 's/^/  event: /' "$TEST_EVENTS" >&2
  fail "the reload queued during the last batch was not applied after the test"
}
rm -f "$PROKOP_PENDING_RELOAD_FILE"
printf 'reason=on_config_change\n' >"$PROKOP_PENDING_RELOAD_FILE"
: >"$TEST_NOT_READY_FLAG"
run_worker 4 || fail "a deferred latency test is not a failure"
rm -f "$TEST_NOT_READY_FLAG" "$PROKOP_PENDING_RELOAD_FILE"
check_events "reload queued, sing-box not ready" 0 1

# A duplicate request while a test runs is coalesced at once, not queued: one
# attempt on the latency lock and nothing else.
mkdir "$PROKOP_AUTOMATIC_LATENCY_TEST_LOCK_DIR"
run_worker 4 || fail "a coalesced request is not a failure"
rm -rf "$PROKOP_AUTOMATIC_LATENCY_TEST_LOCK_DIR"
[ "$(cat "$TEST_EVENTS")" = "try latency busy" ] || {
  sed 's/^/  event: /' "$TEST_EVENTS" >&2
  fail "a duplicate automatic latency request must be dropped after one lock attempt"
}
grep -Fq 'coalescing the duplicate request' "$TEST_LOG" || fail "the coalesced request was not logged"
[ -s "$PROKOP_AUTOMATIC_LATENCY_PENDING_FILE" ] || fail "a coalesced request dropped the running test's marker"

printf 'latency/reload serialization checks passed\n'
