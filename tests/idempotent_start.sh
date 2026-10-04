#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Execute the actual start/retry functions with deterministic runtime doubles.
# No live process, nftables state or router service is touched.
python3 - "$ROOT_DIR" "$WORK_DIR/probe.uc" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]) / 'prokop/files/usr/lib/service'


def extract(filename, name):
    source = (root / filename).read_text()
    found = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if not found:
        raise SystemExit('missing service function: ' + name)
    return found.group()


# ucode compiles a reference to a not-yet-declared name as a global load, and a
# top-level `function name()` declares a local. The doubles are therefore split
# so that every part of the probe is emitted below everything it calls.
runtime_doubles = r'''
const STATE_UC = "state.uc";
const RT_TABLE_NAME = "prokop";
const NFT_TABLE_NAME = "prokop";
const NFT_FAKEIP_MARK = "0x123";
const RUNTIME_STABLE_MIN_AGE = 2;
const MANAGED_UPGRADE_SING_BOX_MARKER = "/test/upgrade.marker";
const MANAGED_UPGRADE_SING_BOX_WAIT_SECONDS = 20;
const MANAGED_UPGRADE_SING_BOX_MARKER_MAX_AGE_SECONDS = 120;
const SERVICE_INIT = "/etc/init.d/prokop";
const SERVICE_NAME = "prokop";
const START_RETRY_FILE = "/test/start.retry";
const START_IN_PROGRESS_FILE = "/test/start.in-progress";
const STOP_REQUESTED_FILE = "/test/stop.requested";
let marker_present = false;
let marker_resolved = true;
let conflict = false;
let transition_guard = false;
// ProkopTableDpiGuard of a failed DPI rollback, ProkopConfigRestoreDpiGuard of
// a restore that ended needs_attention (UC-019).
let dpi_guard = false;
let restore_guard = false;
let health = [true, true, true, true, true];
let calls = [];
let logs = [];
let released = 0;
let cold_starts = 0;
let cleanups = 0;
let retry_status = 0;
let retry_running = false;
let retry_enabled = true;
let retry_pending = true;
let retry_stop_requested = false;
let start_marker_present = false;
let stop_marker_present = false;
let explicit_start_recorded = false;
let legacy_active = false;
let legacy_checks = 0;
let dns_restores = 0;
function as_string(value) { return value == null ? "" : "" + value; }
function bool_text(value) { return value == "1"; }
function die(message) { warn("FAIL: " + message + "\n"); exit(1); }
function check(condition, message) { if (!condition) die(message); }
// Declared after check(): unlike sibling declarations, a closure that captures
// a name which is not declared yet never resolves it.
let fs = { stat: function(path) {
    check(path == MANAGED_UPGRADE_SING_BOX_MARKER, "unexpected stat");
    return marker_present ? {} : null;
} };
function sing_box_current_owned_service_runtime() { return health[0]; }
function sing_box_service_stable(age) {
    check(age == RUNTIME_STABLE_MIN_AGE, "stable age changed");
    return health[1];
}
function sing_box_runtime_ports_ready() { return health[2]; }
function sing_box_clash_api_ready() { return health[3]; }
function prokop_runtime_network_configured(rt, nft, mark) {
    check(rt == RT_TABLE_NAME && nft == NFT_TABLE_NAME && mark == NFT_FAKEIP_MARK,
        "network readiness parameters changed");
    return health[4];
}
'''

# Emitted below prokop_stably_running: module_success() dispatches into it.
service_doubles = r'''
function module_success(path, args) {
    check(path == STATE_UC, "unexpected start helper");
    push(calls, args[0]);
    if (args[0] == "wait-managed-upgrade-sing-box-exit") return marker_resolved;
    if (args[0] == "sing-box-process-conflict") return conflict;
    if (args[0] == "prokop-stably-running")
        return prokop_stably_running(args[1], args[2], args[3], args[4]);
    die("unexpected state helper");
}
function log_message(message, level) { push(logs, level + ":" + message); }
// The product before the rename is active: a start is refused before it
// records anything (tests/prokop_from_forkop_runtime_start_guard.sh).
function legacy_start_refused(action) {
    check(action == "start", "unexpected refusal check");
    legacy_checks++;
    return legacy_active;
}
function release_start_subscription_update_lock() { released++; }
// The not-retryable mark of a refused start: tests/runtime_guard_lifecycle.sh.
function clear_start_failure() { }
function mark_start_failure_not_retryable(reason) { }
function start_impl() { cold_starts++; return 23; }
function cleanup_failed_runtime() { cleanups++; }
// A refused start hands DNS back to dnsmasq unless Prokop runs (LC-1).
function restore_dns_after_refused_start() { dns_restores++; }
function runtime_is_running() { return retry_running; }
function service_is_enabled() { return retry_enabled; }
function start_retry_pending(path) { return retry_pending; }
function stop_requested() { return retry_stop_requested; }
// No start deferred for reload.lock is pending in these cases
// (tests/deferred_start_retry.sh).
function deferred_start_stop_request() { return null; }
function start_retry_stop_requested() { return retry_stop_requested; }
function resolve_deferred_start_results(status) { return true; }
function clear_start_retry(path) { push(calls, "clear-retry"); }
function command_status_from_args(args) {
    check(join(" ", args) == SERVICE_INIT + " start triggered", "retry used destructive restart");
    push(calls, "retry-start");
    return retry_status;
}
function command_success_from_args(args) {
    if (args[0] == "nft") {
        let command = join(" ", args);
        if (command == "nft list table inet " + NFT_TABLE_NAME + "DpiGuard")
            return dpi_guard;
        if (command == "nft list table inet ProkopConfigRestoreDpiGuard")
            return restore_guard;
        check(command == "nft list chain inet " + NFT_TABLE_NAME + " prokop_transition_guard",
            "unexpected nft command during duplicate start");
        return transition_guard;
    }
    push(logs, join(" ", args));
    return true;
}
function owner_pid() { return 4321; }
// start() records its lifecycle worker (pid + start ticks) through
// mark_start_in_progress(); this stands in for that record.
function mark_start_in_progress() {
    check(owner_pid() == 4321, "start marker did not name the lifecycle worker");
    start_marker_present = true;
    return true;
}
// start() records the explicit start (EXPLICIT_START_FILE, D-15(a)): a
// runtime that is down after it is repaired by a reload.
function mark_explicit_start() {
    explicit_start_recorded = true;
    return true;
}
function remove_file(path) {
    if (path == STOP_REQUESTED_FILE) {
        stop_marker_present = false;
        return true;
    }
    check(path == START_IN_PROGRESS_FILE, "unexpected file removal during start");
    start_marker_present = false;
    return true;
}
function reset_probe() {
    marker_present = false; marker_resolved = true; conflict = false; transition_guard = false;
    dpi_guard = false; restore_guard = false;
    health = [true, true, true, true, true];
    calls = []; logs = []; released = 0; cold_starts = 0; cleanups = 0;
    retry_status = 0; retry_running = false; retry_enabled = true; retry_pending = true;
    retry_stop_requested = false;
    start_marker_present = false;
    stop_marker_present = true;
    explicit_start_recorded = false;
    legacy_active = false;
    legacy_checks = 0;
    dns_restores = 0;
}
'''
cases = r'''
// While the product before the rename is active, a start is refused before
// any runtime check, and it neither ends an explicit stop nor counts as an
// explicit start.
reset_probe();
legacy_active = true;
check(start() == 1, "a start next to the active product before the rename was accepted");
check(legacy_checks == 1 && length(calls) == 0, "a refused start reached the runtime checks");
check(!start_marker_present && stop_marker_present && !explicit_start_recorded,
    "a refused start changed the start or stop records");
check(released == 0 && cold_starts == 0 && cleanups == 0, "a refused start touched the runtime");

reset_probe();
check(start() == 0, "duplicate stable start was not successful");
check(dns_restores == 0, "a duplicate start of a running Prokop touched dnsmasq");
check(join(",", calls) == "sing-box-process-conflict,prokop-stably-running" && legacy_checks == 1,
    "stable check bypassed ownership guard");
check(released == 1 && cold_starts == 0 && cleanups == 0,
    "duplicate stable start changed existing runtime or leaked subscription lock");
// The UI reads this marker to keep the start button blocked. It must not
// survive a start that has already returned, on any outcome.
check(!start_marker_present, "start left its in-progress marker behind");
// An explicit start ends an explicit stop even when it finds the runtime
// already running (UC-012), and is recorded as one (D-15(a)).
check(!stop_marker_present, "duplicate start kept the explicit stop");
check(explicit_start_recorded, "duplicate start was not recorded as an explicit start");

reset_probe();
transition_guard = true;
check(start() == 1, "retained fail-closed guard was reported as successful recovery");
check(!start_marker_present, "failed start left its in-progress marker behind");
check(!stop_marker_present, "failed start kept the explicit stop");
check(explicit_start_recorded, "failed start was not recorded as an explicit start");
check(released == 1 && cold_starts == 0 && cleanups == 0,
    "duplicate start altered the retained fail-closed runtime");

// The DPI guard of a failed DPI rollback is a table of its own that no start
// removes: neither a duplicate nor a cold start runs over it (UC-019).
for (let stable in [ true, false ]) {
    reset_probe();
    dpi_guard = true;
    if (!stable) health[0] = false;
    check(start() == 1, "a start over the kept DPI guard was reported as successful");
    check(released == 1 && cold_starts == 0 && cleanups == 0,
        "a start over the kept DPI guard changed the retained fail-closed runtime");
    check(index(join("\n", logs), "runtime_guard_active") >= 0, "the kept DPI guard refusal gave no reason");
    check(dns_restores == 1, "a start refused for the kept DPI guard left DNS pointed at sing-box");
}

// The guard of an unfinished restore: a duplicate start starts nothing and
// does not report the guarded runtime as started; a cold start builds the
// runtime under it.
reset_probe();
restore_guard = true;
check(start() == 1, "a duplicate start under the restore guard was reported as successful");
check(released == 1 && cold_starts == 0 && cleanups == 0,
    "a duplicate start under the restore guard changed the runtime");
reset_probe();
restore_guard = true;
health[0] = false;
check(start() == 23 && cold_starts == 1, "a cold start under the restore guard did not take the guarded cold-start path");

reset_probe();
marker_present = true;
check(start() == 0, "resolved managed upgrade prevented duplicate start");
check(join(",", calls) == "wait-managed-upgrade-sing-box-exit,sing-box-process-conflict,prokop-stably-running",
    "managed upgrade provenance was checked after runtime adoption");

reset_probe();
marker_present = true; marker_resolved = false;
check(start() == 1, "unresolved managed upgrade was accepted");
check(join(",", calls) == "wait-managed-upgrade-sing-box-exit" &&
    released == 1 && cold_starts == 0 && cleanups == 0,
    "unresolved managed upgrade changed existing runtime");
check(dns_restores == 1, "a start refused for the managed upgrade left DNS pointed at sing-box");

reset_probe();
conflict = true;
check(start() == 1, "ambiguous runtime was adopted");
check(join(",", calls) == "sing-box-process-conflict" &&
    released == 1 && cold_starts == 0 && cleanups == 0,
    "ambiguous runtime reached stable adoption or cleanup");
check(dns_restores == 1, "a start refused for an ambiguous sing-box left DNS pointed at sing-box");

// Every part of the full stable-runtime predicate remains mandatory. A partial
// runtime follows the original guarded cold-start path, never the success path.
for (let failed_check = 0; failed_check < 5; failed_check++) {
    reset_probe();
    health[failed_check] = false;
    check(start() == 23, "partial runtime was incorrectly accepted as stable");
    check(cold_starts == 1 && released == 1 && cleanups == 1,
        "partial runtime bypassed original cold-start error handling");
}

// init.d accepts the detached retry start with 0 before it has run; only the
// start worker knows whether Prokop recovered (UC-013, tests/start_result_wait.sh).
reset_probe();
check(retry_start_on_wan_up("123") == 0, "accepted retry lost its status");
check(index(join("\n", logs), "recovered automatically") < 0,
    "an accepted retry was announced as a recovery before the start ran");

reset_probe();
retry_status = 19;
check(retry_start_on_wan_up("123") == 19, "failed retry lost its status");
check(index(join("\n", logs), "[error] Prokop automatic recovery request failed with status 19") >= 0,
    "failed retry request is not logged");

for (let skipped in ["running", "disabled", "no-retry"]) {
    reset_probe();
    retry_running = skipped == "running";
    retry_enabled = skipped != "disabled";
    retry_pending = skipped != "no-retry";
    check(retry_start_on_wan_up("123") == 0, "skipped retry failed");
    check(index(join(",", calls), "retry-start") < 0 && length(logs) == 0,
        "skipped retry started a service or falsely announced recovery");
}
// A retry of a start that an explicit stop interrupted does not start Prokop
// again; it is dropped (UC-012).
reset_probe();
retry_stop_requested = true;
check(retry_start_on_wan_up("123") == 0, "a retry skipped for an explicit stop failed");
check(index(join(",", calls), "retry-start") < 0, "a retry started Prokop after an explicit stop");
check(index(join(",", calls), "clear-retry") >= 0, "a retry skipped for an explicit stop was kept pending");
print("idempotent start and retry outcome checks passed\n");
'''
pathlib.Path(sys.argv[2]).write_text('\n'.join([
    runtime_doubles,
    extract('state.uc', 'prokop_stably_running'),
    service_doubles,
    extract('lifecycle.uc', 'start_inner'),
    extract('lifecycle.uc', 'start'),
    extract('initd.uc', 'retry_start_on_wan_up_action'),
    extract('initd.uc', 'retry_start_on_wan_up'),
    cases,
]))
PY

ucode "$WORK_DIR/probe.uc"
