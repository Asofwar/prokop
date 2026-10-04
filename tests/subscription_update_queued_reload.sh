#!/usr/bin/env bash
set -eo pipefail

# A subscription update does not record the reload state as applied while a
# reload is queued (UC-057 follow-up).
#
# A subscription update with changes applies the sing-box configuration only
# and then records the current configuration as the applied reload state. A
# reload queued meanwhile has not been applied: init.d queues every reload
# while the list worker runs its downloads without reload.lock, and a
# subscription update now runs next to them. When the recorded state already
# held that reload's changes, the queued reload found nothing to do ("Reload
# skipped: runtime-relevant configuration is unchanged") and, for a list
# source changed during a list update, the new source was never downloaded.
# The recorded state is left to the queued reload, whether it was queued
# before the update or while it ran; without one the update records it.

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
  [ ! -s "$WORK_DIR/calls.log" ] || sed 's/^/  call: /' "$WORK_DIR/calls.log" >&2
  exit 1
}

write_stub() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
}

stub_header='#!/usr/bin/env ucode
let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function record(line) {
    let path = getenv("FAKE_CALL_LOG") || "";
    let old = path == "" ? null : fs.readfile(path);
    if (path != "")
        fs.writefile(path, (old == null ? "" : old) + line + "\n");
}
'

FAKE_LIB="$WORK_DIR/lib"

# One subscription changed.
write_stub "$FAKE_LIB/subscription/cache.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("subscription/cache:" + mode);
if (mode == "ensure-runtime-dirs")
    exit(0);
if (mode == "update-request") {
    print("1 0 0 0\n");
    exit(0);
}
exit(64);
'

# The reload state this update records as applied: $FAKE_RELOAD_STATE.
write_stub "$FAKE_LIB/service/state.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("service/state:" + mode);
if (mode == "write-current-reload-state-clean") {
    fs.writefile(getenv("FAKE_RELOAD_STATE"), "current\n");
    exit(0);
}
if (mode == "acquire-runtime-dir-lock" ||
    mode == "acquire-runtime-dir-lock-wait" ||
    mode == "release-runtime-dir-lock" ||
    mode == "stop-managed-sing-box-runtime" ||
    mode == "start-managed-sing-box-runtime" ||
    mode == "run-pending-reload-if-requested" ||
    mode == "runtime-apply-allowed")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/config/validator.uc" "$stub_header"'
record("config/validator:" + as_string(ARGV[0]));
exit(ARGV[0] == "validate-runtime" ? 0 : 64);
'

# With $FAKE_QUEUE_DURING_UPDATE set, a reload is queued while the update
# publishes the new sing-box configuration (init.d, for a configuration
# change that arrives meanwhile).
write_stub "$FAKE_LIB/singbox/runtime.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/runtime:" + mode);
if (mode == "commit-config-stage") {
    if (as_string(ARGV[2]) != "")
        fs.writefile(ARGV[2], "backup\n");
    if (getenv("FAKE_QUEUE_DURING_UPDATE") == "1")
        fs.writefile(getenv("PROKOP_PENDING_RELOAD_FILE"), "reason=on_config_change\nupdated_at=1\nrequest=2\n");
    exit(0);
}
if (mode == "configure-service" || mode == "prepare-config-stage" ||
    mode == "discard-config-stage" || mode == "restore-config-stage")
    exit(0);
exit(64);
'

for module in priority dns_failover; do
  write_stub "$FAKE_LIB/singbox/$module.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/'"$module"':" + mode);
exit(mode == "stop-runtime" || mode == "start-runtime" ? 0 : 64);
'
done

RUN="$WORK_DIR/run"
PENDING="$RUN/reload.pending"
RELOAD_STATE="$WORK_DIR/reload-state"

run_update() {
  : >"$WORK_DIR/calls.log"
  mkdir -p "$WORK_DIR/tmp" "$RUN"
  env \
    TMPDIR="$WORK_DIR/tmp" \
    PROKOP_LIB="$FAKE_LIB" \
    PROKOP_RUNTIME_STATE_DIR="$RUN" \
    PROKOP_EXPLICIT_START_FILE="$WORK_DIR/start.explicit" \
    PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$RUN/subscription-update.lock" \
    PROKOP_RELOAD_LOCK_DIR="$RUN/reload.lock" \
    PROKOP_SUBSCRIPTION_UPDATE_STATE_DIR="$RUN/subscription-update" \
    PROKOP_SUBSCRIPTION_UPDATE_JOB_DIR="$RUN/subscription-update-jobs" \
    PROKOP_SUBSCRIPTION_LINKS_DIR="$RUN/subscription-links" \
    PROKOP_SUBSCRIPTION_METADATA_DIR="$RUN/subscription-metadata" \
    PROKOP_OUTBOUND_METADATA_DIR="$RUN/outbound-metadata" \
    PROKOP_SECTION_CACHE_DIR="$RUN/section-cache" \
    PROKOP_RUNTIME_CACHE_FORMAT_FILE="$RUN/cache-format" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent/subscription-cache" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE="$WORK_DIR/persistent/subscription-cache/cache-format" \
    PROKOP_PENDING_RELOAD_FILE="$PENDING" \
    PROKOP_RELOAD_STATE_FILE="$RUN/reload-state" \
    PROKOP_RULE_CONDITION_CACHE_DIR="$RUN/rule-condition-cache" \
    FAKE_RELOAD_STATE="$RELOAD_STATE" \
    FAKE_CALL_LOG="$WORK_DIR/calls.log" \
    ucode -L "$REAL_LIB" "$UPDATES_UC" subscription-update-if-due
}

applied() { grep -qx 'service/state:start-managed-sing-box-runtime' "$WORK_DIR/calls.log"; }
recorded() { [ "$(cat "$RELOAD_STATE" 2>/dev/null)" = current ]; }
drained() { grep -qx 'service/state:run-pending-reload-if-requested' "$WORK_DIR/calls.log"; }

# 1. A reload was queued before the update (a list source changed while the
#    list worker downloads).
rm -f "$RELOAD_STATE"
mkdir -p "$RUN"
printf 'reason=on_config_change\nupdated_at=1\nrequest=1\n' >"$PENDING"
run_update || fail "1: the subscription update failed"
applied || fail "1: the subscription update did not apply sing-box"
! recorded || fail "1: the subscription update recorded the reload state over a queued reload"
drained || fail "1: the subscription update did not hand the queued reload on"

# 2. A reload is queued while the update runs.
rm -f "$RELOAD_STATE" "$PENDING"
FAKE_QUEUE_DURING_UPDATE=1 run_update || fail "2: the subscription update failed"
applied || fail "2: the subscription update did not apply sing-box"
[ -e "$PENDING" ] || fail "2: fixture: no reload was queued during the update"
! recorded || fail "2: the subscription update recorded the reload state over a reload queued meanwhile"
drained || fail "2: the subscription update did not hand the queued reload on"

# 3. Nothing is queued: the update records the state it applied, as before.
rm -f "$RELOAD_STATE" "$PENDING"
run_update || fail "3: the subscription update failed"
recorded || fail "3: the subscription update did not record the reload state"

printf 'subscription_update_queued_reload: ok\n'
