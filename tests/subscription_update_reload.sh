#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATES_UC="$ROOT_DIR/prokop/files/usr/lib/components/updates.uc"
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
: >"$WORK_DIR/start.explicit"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

write_stub() {
  local path="$1"
  local body="$2"

  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" >"$path"
}

stub_header='#!/usr/bin/env ucode
let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'"'"'" + replace(as_string(value), /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'";
}

function record(line) {
    let path = getenv("FAKE_CALL_LOG") || "";
    if (path != "")
        system("printf '"'"'%s\\n'"'"' " + shell_quote(line) + " >> " + shell_quote(path));
}
'

FAKE_LIB="$WORK_DIR/lib"

write_stub "$FAKE_LIB/subscription/cache.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("subscription/cache:" + mode);
if (mode == "ensure-runtime-dirs")
    exit(0);
if (mode == "update-request") {
    print(getenv("FAKE_SUBSCRIPTION_UPDATE_SUMMARY") || "1 0 0 0", "\n");
    exit(0);
}
exit(64);
'

write_stub "$FAKE_LIB/service/state.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("service/state:" + mode);
if (mode == "start-managed-sing-box-runtime") {
    let count_path = getenv("FAKE_START_COUNT_FILE") || "";
    let count = count_path == "" ? 0 : int(trim(fs.readfile(count_path) || "0")) + 1;
    if (count_path != "")
        fs.writefile(count_path, as_string(count) + "\n");
    if (getenv("FAKE_FAIL_FIRST_START") == "1" && count == 1)
        exit(1);
}
if (mode == "wait-single-ready-sing-box-runtime") {
    record("service/state:wait-timeout:" + as_string(ARGV[1]));
    let count_path = getenv("FAKE_READY_COUNT_FILE") || "";
    let count = count_path == "" ? 0 : int(trim(fs.readfile(count_path) || "0")) + 1;
    if (count_path != "")
        fs.writefile(count_path, as_string(count) + "\n");
    exit(getenv("FAKE_FIRST_NOT_READY") == "1" && count == 1 ? 1 : 0);
}
if (mode == "acquire-runtime-dir-lock" ||
    mode == "acquire-runtime-dir-lock-wait" ||
    mode == "release-runtime-dir-lock" ||
    mode == "stop-managed-sing-box-runtime" ||
    mode == "start-managed-sing-box-runtime" ||
    mode == "write-current-reload-state-clean" ||
    mode == "run-pending-reload-if-requested" ||
    mode == "runtime-apply-allowed")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/config/validator.uc" "$stub_header"'
record("config/validator:" + as_string(ARGV[0]));
exit(ARGV[0] == "validate-runtime" ? 0 : 64);
'

write_stub "$FAKE_LIB/singbox/runtime.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
if (mode == "init-config")
    record("singbox/runtime:init-config:" + as_string(ARGV[1]) + ":" + as_string(ARGV[2]) + ":" + as_string(ARGV[3]));
else
    record("singbox/runtime:" + mode);
if (mode == "configure-service" ||
    mode == "prepare-config-stage" ||
    mode == "commit-config-stage") {
    if (mode == "commit-config-stage" && as_string(ARGV[2]) != "")
        fs.writefile(ARGV[2], "backup\n");
    exit(0);
}
if (mode == "discard-config-stage" || mode == "restore-config-stage")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/singbox/priority.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/priority:" + mode);
if (mode == "stop-runtime" || mode == "start-runtime")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/singbox/dns_failover.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/dns_failover:" + mode);
if (mode == "start-runtime" && getenv("FAKE_FAIL_AUXILIARY_START") == "1") {
    let count_path = getenv("FAKE_AUX_START_COUNT_FILE") || "";
    let count = count_path == "" ? 0 : int(trim(fs.readfile(count_path) || "0")) + 1;
    if (count_path != "")
        fs.writefile(count_path, as_string(count) + "\n");
    if (count == 1)
        exit(1);
}
if (mode == "stop-runtime" || mode == "start-runtime")
    exit(0);
exit(64);
'

run_update() {
  local summary="$1"
  local log="$2"

  : >"$log"
  # The stubbed discard-config-stage keeps the staged file; keep it in WORK_DIR.
  mkdir -p "$WORK_DIR/tmp"
  env \
    TMPDIR="$WORK_DIR/tmp" \
    PROKOP_LIB="$FAKE_LIB" \
    PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    PROKOP_EXPLICIT_START_FILE="$WORK_DIR/start.explicit" \
    PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK_DIR/run/subscription-update.lock" \
    PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock" \
    PROKOP_SUBSCRIPTION_UPDATE_STATE_DIR="$WORK_DIR/run/subscription-update" \
    PROKOP_SUBSCRIPTION_UPDATE_JOB_DIR="$WORK_DIR/run/subscription-update-jobs" \
    PROKOP_SUBSCRIPTION_LINKS_DIR="$WORK_DIR/run/subscription-links" \
    PROKOP_SUBSCRIPTION_METADATA_DIR="$WORK_DIR/run/subscription-metadata" \
    PROKOP_OUTBOUND_METADATA_DIR="$WORK_DIR/run/outbound-metadata" \
    PROKOP_SECTION_CACHE_DIR="$WORK_DIR/run/section-cache" \
    PROKOP_RUNTIME_CACHE_FORMAT_FILE="$WORK_DIR/run/cache-format" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent/subscription-cache" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE="$WORK_DIR/persistent/subscription-cache/cache-format" \
    PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending" \
    FAKE_START_COUNT_FILE="$WORK_DIR/start-count" \
    FAKE_AUX_START_COUNT_FILE="$WORK_DIR/aux-start-count" \
    FAKE_READY_COUNT_FILE="$WORK_DIR/ready-count" \
    PROKOP_RELOAD_STATE_FILE="$WORK_DIR/run/reload-state" \
    PROKOP_RULE_CONDITION_CACHE_DIR="$WORK_DIR/run/rule-condition-cache" \
    FAKE_CALL_LOG="$log" \
    FAKE_SUBSCRIPTION_UPDATE_SUMMARY="$summary" \
    ucode -L "$REAL_LIB" "$UPDATES_UC" subscription-update-if-due
}

updated_log="$WORK_DIR/updated.log"
run_update "1 0 0 0" "$updated_log"

node - "$updated_log" <<'JS'
const fs = require("fs");
const calls = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n+/);
const expected = [
  "subscription/cache:update-request",
  "config/validator:validate-runtime",
  "singbox/runtime:configure-service",
  "singbox/runtime:prepare-config-stage",
  "singbox/dns_failover:stop-runtime",
  "singbox/priority:stop-runtime",
  "service/state:stop-managed-sing-box-runtime",
  "singbox/runtime:commit-config-stage",
  "service/state:start-managed-sing-box-runtime",
  "service/state:wait-single-ready-sing-box-runtime",
  "service/state:wait-timeout:15",
  "singbox/priority:start-runtime",
  "singbox/dns_failover:start-runtime",
  "service/state:write-current-reload-state-clean",
  "service/state:run-pending-reload-if-requested"
];

let position = -1;
for (const item of expected) {
  const next = calls.indexOf(item, position + 1);
  if (next === -1) {
    console.error(`missing or out-of-order call: ${item}`);
    console.error(calls.join("\n"));
    process.exit(1);
  }
  position = next;
}
JS

unchanged_log="$WORK_DIR/unchanged.log"
run_update "0 0 1 0" "$unchanged_log"

if grep -Eq 'config/validator|singbox/runtime|singbox/priority|singbox/dns_failover|reload-sing-box-runtime|write-current-reload-state-clean' "$unchanged_log"; then
  fail "unchanged subscription update must not rebuild or reload sing-box"
fi

: >"$WORK_DIR/start-count"
rollback_log="$WORK_DIR/rollback.log"
if FAKE_FAIL_FIRST_START=1 run_update "1 0 0 0" "$rollback_log"; then
  fail "subscription update must fail when the replacement runtime cannot start"
fi

node - "$rollback_log" <<'JS'
const fs = require("fs");
const calls = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n+/);
const expected = [
  "singbox/runtime:prepare-config-stage",
  "service/state:stop-managed-sing-box-runtime",
  "singbox/runtime:commit-config-stage",
  "service/state:start-managed-sing-box-runtime",
  "service/state:stop-managed-sing-box-runtime",
  "singbox/runtime:restore-config-stage",
  "service/state:start-managed-sing-box-runtime",
  "singbox/runtime:discard-config-stage",
  "singbox/priority:start-runtime",
  "singbox/dns_failover:start-runtime"
];

let position = -1;
for (const item of expected) {
  const next = calls.indexOf(item, position + 1);
  if (next === -1) {
    console.error(`missing or out-of-order rollback call: ${item}`);
    console.error(calls.join("\n"));
    process.exit(1);
  }
  position = next;
}
JS

: >"$WORK_DIR/start-count"
auxiliary_log="$WORK_DIR/auxiliary.log"
if FAKE_FAIL_AUXILIARY_START=1 run_update "1 0 0 0" "$auxiliary_log"; then
  fail "subscription update must fail when an auxiliary runtime cannot start"
fi

node - "$auxiliary_log" <<'JS'
const fs = require("fs");
const calls = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n+/);
const expected = [
  "service/state:start-managed-sing-box-runtime",
  "singbox/priority:start-runtime",
  "singbox/dns_failover:start-runtime",
  "singbox/dns_failover:stop-runtime",
  "singbox/priority:stop-runtime",
  "service/state:stop-managed-sing-box-runtime",
  "singbox/runtime:restore-config-stage",
  "service/state:start-managed-sing-box-runtime",
  "singbox/priority:start-runtime",
  "singbox/dns_failover:start-runtime"
];

let position = -1;
for (const item of expected) {
  const next = calls.indexOf(item, position + 1);
  if (next === -1) {
    console.error(`missing or out-of-order auxiliary rollback call: ${item}`);
    console.error(calls.join("\n"));
    process.exit(1);
  }
  position = next;
}
JS

# F5: the workers (Priority, DNS failover) start only once the new sing-box
# is ready (its DNS and TPROXY listeners and the Clash API answer), not as
# soon as procd has a process. A sing-box that does not become ready in the
# transition timeout is rolled back like one that does not start, and the
# workers start with the restored runtime.
: >"$WORK_DIR/start-count"
: >"$WORK_DIR/ready-count"
: >"$WORK_DIR/aux-start-count"
not_ready_log="$WORK_DIR/not-ready.log"
if FAKE_FIRST_NOT_READY=1 run_update "1 0 0 0" "$not_ready_log"; then
  fail "subscription update must fail when the replacement runtime does not become ready"
fi

node - "$not_ready_log" <<'JS'
const fs = require("fs");
const calls = fs.readFileSync(process.argv[2], "utf8").trim().split(/\n+/);
const expected = [
  "singbox/runtime:commit-config-stage",
  "service/state:start-managed-sing-box-runtime",
  "service/state:wait-single-ready-sing-box-runtime",
  "service/state:stop-managed-sing-box-runtime",
  "singbox/runtime:restore-config-stage",
  "service/state:start-managed-sing-box-runtime",
  "service/state:wait-single-ready-sing-box-runtime",
  "singbox/runtime:discard-config-stage",
  "singbox/priority:start-runtime",
  "singbox/dns_failover:start-runtime"
];

let position = -1;
for (const item of expected) {
  const next = calls.indexOf(item, position + 1);
  if (next === -1) {
    console.error(`missing or out-of-order not-ready rollback call: ${item}`);
    console.error(calls.join("\n"));
    process.exit(1);
  }
  position = next;
}
const firstStart = calls.indexOf("service/state:start-managed-sing-box-runtime");
const firstWait = calls.indexOf("service/state:wait-single-ready-sing-box-runtime");
const firstWorker = calls.indexOf("singbox/priority:start-runtime", firstStart);
const restore = calls.indexOf("singbox/runtime:restore-config-stage");
if (firstWorker < restore) {
  console.error("a worker started on the runtime that never became ready");
  console.error(calls.join("\n"));
  process.exit(1);
}
if (!(firstStart < firstWait)) process.exit(1);
JS

# The real wait: no ready sing-box gives up after the timeout, and a stop
# request ends it at once rather than holding reload.lock for the timeout.
STATE_UC="$REAL_LIB/service/state.uc"
mkdir -p "$WORK_DIR/wait-bin" "$WORK_DIR/wait-run"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/wait-bin/ubus"
chmod 0755 "$WORK_DIR/wait-bin/ubus"
wait_ready() {
  PATH="$WORK_DIR/wait-bin:$PATH" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/wait-run" \
    PROKOP_STOP_REQUESTED_FILE="$WORK_DIR/wait-run/stop.requested" \
    ucode -L "$REAL_LIB" "$STATE_UC" wait-single-ready-sing-box-runtime "$1" >/dev/null 2>&1
}
started="$(date +%s)"
if wait_ready 1; then
  fail "the readiness wait accepted a runtime without sing-box"
fi
[ "$(( $(date +%s) - started ))" -le 5 ] || fail "the readiness wait overran its timeout"
: >"$WORK_DIR/wait-run/stop.requested"
started="$(date +%s)"
if wait_ready 15; then
  fail "the readiness wait succeeded although a stop was requested"
fi
[ "$(( $(date +%s) - started ))" -le 3 ] || fail "a stop request did not end the readiness wait"

printf 'subscription update reload checks passed\n'
