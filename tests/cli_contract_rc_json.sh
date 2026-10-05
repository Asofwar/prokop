#!/usr/bin/env bash
set -euo pipefail

# S10 contract of /usr/bin/prokop: the exit code never contradicts what a
# command prints (UC-118, UC-119, UC-033), and refusals carry a stable reason.
#
# CONTRACT below is the command table of the CLI/RPC inventory (A13/A16 of
# docs/audit/ULTRACODE_INVENTORIES.md, commit 07872084) as of S10. Every
# command of command_spec in /usr/bin/prokop has exactly one row, and a row
# without a command fails the test, so a new command needs its contract here.
# Classes:
#   job-start    {success, job_id, message[, reason]}; rc 0 iff success; a
#                refusal has a reason (REASONS) and no job is started
#   job-status   rc 0: the job state {kind, running, success, message[, reason]},
#                a finished failure has a reason; rc 1: {success: false,
#                message, reason} (invalid_input, not_found)
#   json-success one JSON object; rc 0 iff success is not false; a failure
#                says why in reason or error (clash_api: error + message)
#   json-status  one JSON object {status, reason}; rc 0 iff status is one of
#                the listed statuses; a failure has a reason
#   json-error   rc 0: the JSON result; rc 1: {error: <code>}
#   json         rc 0: one JSON value
#   text         plain text for people (a failure says why on stderr)
#   rc           no stdout contract (syslog, init.d); rc 0 on success
# The commands marked "run" are executed below in a sandbox (every path under
# its own temporary directory, the network and the init system replaced);
# the others name the tests that cover them.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
CLI="$ROOT_DIR/prokop/files/usr/bin/prokop"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
WORK="$(mktemp -d)"
LIVE_PIDS=()
cleanup() {
  local pid
  if [ "${#LIVE_PIDS[@]}" -gt 0 ]; then
    owned_kill KILL "${LIVE_PIDS[@]}" || true
    for pid in "${LIVE_PIDS[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  fi
  [ -n "${KEEP_WORK:-}" ] || rm -rf "${WORK:?}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v ucode >/dev/null || fail "ucode is required"
command -v node >/dev/null || fail "node is required"

CONTRACT="$(cat <<'TABLE'
start                          | rc            | init.d start; covered: service_start_trap, initd_state, deferred_start_ui_job
stop                           | rc            | covered: stop_paths_owned, initd_state
reload                         | rc            | prints "queued"/"stopped" for UI-tracked reloads; covered: ui_reload_queued_job, stopped_reload_job
dns_failover_apply             | rc            | 0 applied, 1 failed, 2 reload.lock busy; covered: dns_failover_*
restart                        | rc            | covered: initd_state
enable                         | rc            | judged by the autostart read back (serviceControl.ts)
disable                        | rc            | judged by the autostart read back
uninstall                      | json-success  | alias of full_uninstall (UC-169); covered: cli_uninstall_alias
full_uninstall                 | json-success  | {success, status_url} / {success:false, message}; covered: full_uninstall_*
dnsmasq_restore                | rc            | covered: package_lifecycle
restore_dnsmasq                | rc            | alias of dnsmasq_restore
main                           | rc            | alias of start (UC-015); covered: cli_main_alias
list_update                    | rc            | busy is rc 0 (cron); covered: list_update_reload_policy
list_update_if_due             | rc            | busy is rc 0 (cron); covered: updates_due
list_update_async              | json-success  | covered: list_update_manual
get_list_update_status         | json          | covered: list_update_manual
subscription_update            | rc            | 0 updated, 1 failed, 2 busy (a reload or another update kept its locks); run (job); covered: subscription_update_busy_pending_reload
subscription_update_async      | job-start     | run: no worker started here; covered: subscriptionUpdate.test.ts
subscription_update_status     | job-status    | run
subscription_update_if_due     | rc            | busy is rc 0 (cron); covered: updates_due
check_proxy                    | text          | verdict on a terminal, failure reason on stderr (UC-117); covered: diagnostics_tty_verdict
check_nft                      | text          | covered: diagnostics_tty_verdict (nolog)
check_nft_rules                | json          | covered: nft tests
check_sing_box                 | json          | covered: diagnostics_status
check_logs                     | text          | run: rc 1 with the reason on stderr without logread
check_sing_box_logs            | text          | as check_logs
check_fakeip                   | json          | covered: fakeip tests
check_zapret_runtime           | json          | provider JSON, rc of the provider
check_zapret2_runtime          | json          | provider JSON, rc of the provider
check_byedpi_runtime           | json          | provider JSON, rc of the provider
neutralize_zapret_defaults     | rc            | no-op
clash_api                      | json-success  | run; one failure envelope {success:false, error, message} (UC-118); covered: clash_api_envelope
show_config                    | text          | run
show_version                   | text          | run
show_sing_box_config           | json          | run: masked JSON; rc 1 with the reason on stderr
show_sing_box_version          | text          | sing-box version
get_status                     | json          | covered: runtime_state_predicates
get_outbound_metadata          | json          | empty metadata for an unknown section
get_subscription_metadata      | json          | {} for an unknown section
get_sing_box_status            | json          | covered: runtime_state_predicates
get_zapret_status              | json          | provider JSON
get_zapret2_status             | json          | provider JSON
get_byedpi_status              | json          | provider JSON
get_system_info                | json          | covered: diagnostics_status
get_ui_capabilities            | json          | run
get_ui_state                   | json          | run
get_health_status              | json          | covered: acl_boundary, health tests
get_history                    | json          | run
route_trace                    | json-error    | run: {error: invalid_input} rc 1; covered: route_trace
device_traffic                 | json          | run; covered: device_traffic
config_snapshot_create         | json-status:created,existing | run
config_snapshot_list           | json          | run
config_snapshot_diff           | json          | run: no output and rc 1 for a missing snapshot
config_snapshot_restore        | json-status:success,recovered,restored_not_started | covered: config_snapshots, config_restore_guard
config_snapshot_delete         | json-status:deleted | run
connectivity_test              | json-error    | run: {error: invalid_input} rc 1
get_readonly_config_sections   | json          | run
get_dashboard_runtime_metadata | json          | run
service_action_async           | job-start     | run
service_action_status          | job-status    | run
latency_test_async             | job-start     | run
latency_test_status            | job-status    | run
ui_action_ack                  | job-start     | run
component_action               | json-success  | run: {success:false, reason} rc 1; covered: components_updater_job
component_action_async         | job-start     | run
prokop_releases                | json-success  | run: {success, releases}; rc 1 with a reason when none could be listed
component_action_status        | job-status    | run
component_updates_if_due       | rc            | busy is rc 0 (cron); covered: updates_due
component_update_check_cache   | json          | covered: cli_entrypoint
check_dns_available            | json          | network probe
global_check                   | text          | covered: readonly_secret_masking
support_report                 | text          | covered: acl_boundary
validate_nfqws_strategy_json   | json          | run: {valid, message} rc 0 (the verdict is data)
validate_nfqws2_strategy_json  | json          | run
validate_byedpi_strategy_json  | json          | run
package_prerm                  | rc            | covered: package_lifecycle
package_postinst               | rc            | covered: package_lifecycle
luci_postinst                  | rc            | covered: package_lifecycle
urltest_override_save          | rc            | reason on stderr; covered: urltest_override_validation
urltest_override_reset         | rc            | covered: urltest_override_validation
autotune_status                | json-status:ok | run
autotune_target                | json-status:ok | run
autotune_groups                | json-status:ok | covered: autotune_groups
autotune_policy_set            | json-status:ok | covered: autotune_contract
autotune_target_set            | json-status:ok | covered: autotune_contract
autotune_target_remove         | json-status:ok | covered: autotune_contract
autotune_list_domains          | json-status:ok | covered: autotune_contract
autotune_run                   | json-status:ok | covered: autotune_recovery
autotune_run_async             | json-status:ok | covered: autotune_manual_apply
autotune_run_status            | json-status:ok | covered: autotune_manual_apply
autotune_apply                 | json-status:ok | covered: autotune_manual_apply
autotune_apply_async           | json-status:ok | covered: autotune_manual_apply
autotune_rollback              | json-status:ok | covered: autotune_rollback
autotune_if_due                | json-status:ok | covered: autotune_scheduler
killswitch_status              | json          | covered: killswitch tests
killswitch_sync                | rc            | covered: killswitch tests
killswitch_disable             | rc            | covered: killswitch tests
notify_test                    | json-status:ok | covered: notifications
notify_status                  | json          | covered: notifications
notify_tick                    | rc            | covered: notifications
notify_flush                   | rc            | covered: notifications
TABLE
)"

# The stable reasons of job refusals and job states (UC-119); a latency job
# also passes on the error code of clash_api.
REASONS="busy startup_in_progress invalid_input not_found forbidden failure timeout stale queued latency_failed clash_api_timeout clash_api_unreachable clash_api_unavailable clash_api_auth_unavailable clash_api_invalid_response clash_api_error"

# --- Every command has its contract ----------------------------------------------
dispatched="$(awk '/function command_spec/,/return commands/' "$CLI" |
  sed -n 's/^[[:space:]]*\([a-z0-9_]*\): \[.*/\1/p' | sort)"
[ "$(printf '%s\n' "$dispatched" | wc -l)" -ge 90 ] || fail "could not read command_spec of /usr/bin/prokop"
contracted="$(printf '%s\n' "$CONTRACT" | awk -F'|' 'NF { gsub(/[[:space:]]/, "", $1); print $1 }' | sort)"
[ -z "$(printf '%s\n' "$contracted" | uniq -d)" ] || fail "a command has two contract rows: $(printf '%s\n' "$contracted" | uniq -d)"
missing="$(comm -23 <(printf '%s\n' "$dispatched") <(printf '%s\n' "$contracted"))"
[ -z "$missing" ] || fail "commands without a contract row: $missing"
extra="$(comm -13 <(printf '%s\n' "$dispatched") <(printf '%s\n' "$contracted"))"
[ -z "$extra" ] || fail "contract rows without a command: $extra"

class_of() {
  printf '%s\n' "$CONTRACT" | awk -F'|' -v c="$1" '{ name = $1; gsub(/[[:space:]]/, "", name); if (name == c) { cls = $2; gsub(/[[:space:]]/, "", cls); print cls } }'
}

# --- The sandbox -------------------------------------------------------------------
mkdir -p "${WORK:?}/bin" "${WORK:?}/run" "${WORK:?}/ui-state" "${WORK:?}/snapshots"
for tool in logger opkg apk wget uclient-fetch; do
  printf '#!/bin/sh\nexit 1\n' >"${WORK:?}/bin/$tool"
done
printf '#!/bin/sh\nexit 0\n' >"${WORK:?}/bin/logger"
# The Clash API controller: the error a stopped sing-box answers with.
printf '#!/bin/sh\nexit 7\n' >"${WORK:?}/bin/curl"
printf '#!/bin/sh\nexit 0\n' >"${WORK:?}/init.d-prokop"
cat >"${WORK:?}/prokop" <<SH
#!/bin/sh
exec ucode "$CLI" "\$@"
SH
chmod +x "${WORK:?}/bin/"* "${WORK:?}/init.d-prokop" "${WORK:?}/prokop"

cat >"${WORK:?}/prokop.conf" <<'UCI'
config settings 'settings'
	option dns_type 'doh'
	option latency_test_url 'https://latency.example/generate_204'
UCI
printf '%s\n' 'prokop.settings=settings' 'prokop.settings.dns_type=doh' >"${WORK:?}/uci-state"

export PATH="${WORK:?}/bin:$PATH"
export PROKOP_LIB="$LIB"
export PROKOP_BIN="${WORK:?}/prokop"
export PROKOP_SERVICE_INIT="${WORK:?}/init.d-prokop"
export PROKOP_RELOAD_COMMAND="${WORK:?}/init.d-prokop"
export PROKOP_RUNTIME_STATE_DIR="${WORK:?}/run"
export PROKOP_UI_STATE_DIR="${WORK:?}/ui-state"
export PROKOP_UI_SERVICE_ACTION_DIR="${WORK:?}/ui-state/service-actions"
export PROKOP_UI_SERVICE_ACTION_LOCK_DIR="${WORK:?}/ui-state/service-actions.lock"
export PROKOP_UI_LATENCY_ACTION_DIR="${WORK:?}/ui-state/latency-actions"
export PROKOP_UI_COMPONENT_ACTION_DIR="${WORK:?}/component-actions"
export PROKOP_UI_SUBSCRIPTION_ACTION_DIR="${WORK:?}/subscription-jobs"
export PROKOP_SUBSCRIPTION_UPDATE_JOB_DIR="${WORK:?}/subscription-jobs"
export UPDATES_JOB_DIR="${WORK:?}/component-actions"
export UPDATES_LOCK_DIR="${WORK:?}/run/component-action.lock"
export PROKOP_LATENCY_TEST_LOCK_DIR="${WORK:?}/run/latency.lock"
export PROKOP_START_IN_PROGRESS_FILE="${WORK:?}/run/start.in-progress"
export PROKOP_PENDING_RELOAD_FILE="${WORK:?}/run/reload.pending"
export PROKOP_RELOAD_LOCK_DIR="${WORK:?}/run/reload.lock"
export PROKOP_UI_SING_BOX_BIN_PATH="${WORK:?}/no-sing-box"
export PROKOP_UI_SING_BOX_VARIANT_STATE_FILE="${WORK:?}/sing-box-variant"
export PROKOP_SYSTEM_INFO_CACHE_FILE="${WORK:?}/run/system-info.json"
export PROKOP_CONFIG="${WORK:?}/prokop.conf"
export PROKOP_CONFIG_FILE="${WORK:?}/prokop.conf"
export PROKOP_UCI_STATE_FILE="${WORK:?}/uci-state"
export PROKOP_UCI_SAVEDIR="${WORK:?}/uci-save"
export PROKOP_SNAPSHOT_DIR="${WORK:?}/snapshots"
export PROKOP_SNAPSHOT_HASH_DIR="${WORK:?}/run/snapshot-hash"
export PROKOP_SNAPSHOT_LOCK_DIR="${WORK:?}/run/config-snapshot.lock"
export PROKOP_HISTORY_FILE="${WORK:?}/history.jsonl"
export PROKOP_OPKG_RECOVERY_DIR="${WORK:?}/opkg-recovery"
export PROKOP_AUTOTUNE_APPLY_STATE="${WORK:?}/autotune-apply.json"
export PROKOP_AUTOTUNE_STATE_DIR="${WORK:?}/run/autotune"
export PROKOP_AUTOTUNE_UCI_SAVEDIR="${WORK:?}/uci-save"
export PROKOP_CRONTAB_FILE="${WORK:?}/crontab"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="${WORK:?}/managed-upgrade"

# expect COMMAND RC [REASON] -- ARG...: runs the command, checks its class
# rule, the exit code and, when given, the reason (or clash_api's error).
expect() {
  local command="$1" want_rc="$2" want_reason="$3" class
  shift 4
  class="$(class_of "$command")"
  [ -n "$class" ] || fail "no contract for $command"
  set +e
  ucode "$CLI" "$command" "$@" >"${WORK:?}/out" 2>"${WORK:?}/err" </dev/null
  RC=$?
  set -e
  [ "$RC" = "$want_rc" ] || fail "$command $*: expected rc $want_rc, got $RC: $(cat "${WORK:?}/out" "${WORK:?}/err")"
  OUT_FILE="${WORK:?}/out" node - "$command $*" "$class" "$RC" "$want_reason" "$REASONS" <<'NODE'
const fs = require("fs");
const [label, cls, rcText, wantReason, reasonList] = process.argv.slice(2);
const rc = Number(rcText);
const reasons = reasonList.split(" ");
const text = fs.readFileSync(process.env.OUT_FILE, "utf8");
const die = (why) => { console.error(`${label} [${cls}]: ${why}\n${text}`); process.exit(1); };
const parse = () => { try { return JSON.parse(text); } catch (e) { die("stdout is not one JSON value"); } };
const object = () => { const v = parse(); if (!v || typeof v !== "object" || Array.isArray(v)) die("not a JSON object"); return v; };
let why = "";
if (cls === "job-start") {
  const v = object();
  if (typeof v.success !== "boolean" || typeof v.message !== "string") die("no {success, message}");
  if ((rc === 0) !== v.success) die("rc contradicts success");
  if (v.success && !v.job_id) die("a started job has no job_id");
  if (!v.success) { if (!reasons.includes(v.reason)) die(`refusal reason ${v.reason} is not one of the stable reasons`); why = v.reason; }
} else if (cls === "job-status") {
  const v = object();
  if (rc === 0) {
    if (typeof v.running !== "boolean" || typeof v.kind !== "string") die("no job state");
    if (v.running === false && v.success === false) {
      if (!reasons.includes(v.reason)) die(`failed job reason ${v.reason} is not one of the stable reasons`);
      why = v.reason;
    }
  } else {
    if (v.success !== false || !reasons.includes(v.reason)) die("a refused status has no {success:false, reason}");
    why = v.reason;
  }
} else if (cls === "json-success") {
  const v = object();
  if ((rc === 0) !== (v.success !== false)) die("rc contradicts success");
  if (v.success === false) {
    why = v.reason || v.error;
    if (typeof why !== "string" || why === "") die("a failure says no reason or error code");
    if (v.error !== undefined && (typeof v.message !== "string" || v.message === "")) die("an error code without a message");
  }
} else if (cls.startsWith("json-status:")) {
  const ok = cls.slice("json-status:".length).split(",");
  const v = object();
  if ((rc === 0) !== ok.includes(v.status)) die(`rc contradicts status ${v.status}`);
  if (!ok.includes(v.status)) { why = v.reason; if (typeof why !== "string" || why === "") die("a refusal has no reason"); }
} else if (cls === "json-error") {
  const v = parse();
  if (rc !== 0) { if (!v || typeof v.error !== "string") die("a failure has no {error}"); why = v.error; }
} else if (cls === "json") {
  if (rc === 0) parse(); else if (text.trim() !== "") parse();
} else if (cls === "text" || cls === "rc") {
  // No stdout contract.
} else die("unknown class");
if (wantReason !== "" && why !== wantReason) die(`expected reason ${wantReason}, got ${why}`);
NODE
}

json_field() {
  node -e 'const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(v[process.argv[2]] ?? ""));' \
    "${WORK:?}/out" "$1"
}

live_process() {
  sleep 600 &
  LIVE=$!
  LIVE_PIDS+=("$LIVE")
}

state() { ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }

# --- UI service actions ---------------------------------------------------------------
expect service_action_async 1 invalid_input -- bogus
mkdir -p "$PROKOP_UI_SERVICE_ACTION_DIR"
live_process
printf '{"success":true,"running":true,"kind":"service","action":"restart","source":"ui","message":"Service action is running","pid":"%s","started_at":%s}\n' \
  "$LIVE" "$(date +%s)" >"$PROKOP_UI_SERVICE_ACTION_DIR/job-busy.json"
expect service_action_async 1 busy -- reload
expect service_action_status 0 "" -- job-busy
expect service_action_status 1 invalid_input -- ../job-busy
expect service_action_status 1 not_found -- 1700000000_123
expect ui_action_ack 1 busy -- service job-busy
expect ui_action_ack 1 invalid_input -- nothing job-busy
owned_kill TERM "$LIVE" || true
printf '{"success":false,"running":false,"kind":"service","action":"restart","message":"Service restart did not finish within 120 s and is still pending; see the Prokop log for its outcome","reason":"timeout","exit_code":1,"started_at":1,"updated_at":2}\n' \
  >"$PROKOP_UI_SERVICE_ACTION_DIR/job-busy.json"
expect service_action_status 0 timeout -- job-busy
expect ui_action_ack 0 "" -- service job-busy
# A command that returned 0 while the runtime then stayed in the wrong state
# for the whole wait failed: that is no unconfirmed action (timeout), which
# the page shows as a warning that it may still finish.
printf '{"success":true,"running":true,"kind":"service","action":"start","source":"ui","message":"Service action is running","started_at":%s}\n' \
  "$(date +%s)" >"$PROKOP_UI_SERVICE_ACTION_DIR/job-state.json"
mkdir -p "${WORK:?}/no-runtime"
for tool in nft ubus ip pidof; do
  printf '#!/bin/sh\nexit 1\n' >"${WORK:?}/no-runtime/$tool"
done
chmod +x "${WORK:?}/no-runtime/"*
PATH="${WORK:?}/no-runtime:$PATH" PROKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS=1 PROKOP_UI_SERVICE_ACTION_SETTLE_SECONDS=1 \
  ucode -L "$LIB" "$LIB/service/ui.uc" service-action-wait-worker \
  "$PROKOP_UI_SERVICE_ACTION_DIR/job-state.json" start job-state >/dev/null 2>&1 ||
  fail "service-action-wait-worker exited non-zero"
expect service_action_status 0 failure -- job-state
grep -Fq 'did not reach expected state' "${WORK:?}/out" || fail "fixture: the start was expected to miss its state: $(cat "${WORK:?}/out")"

# --- Jobs whose worker is gone ------------------------------------------------------
# A job left running by a worker that exited without writing its outcome is
# stale: what it did is unknown, which is no failure the action reported.
stale_job() {
  printf '{"success":true,"running":true,"kind":"%s","message":"running","started_at":1%s}\n' "$2" "$3" >"$1"
}
mkdir -p "$PROKOP_UI_LATENCY_ACTION_DIR" "$UPDATES_JOB_DIR" "$PROKOP_SUBSCRIPTION_UPDATE_JOB_DIR"
stale_job "$PROKOP_UI_SERVICE_ACTION_DIR/job-stale.json" service ',"action":"restart","source":"ui"'
expect service_action_status 0 stale -- job-stale
stale_job "$PROKOP_UI_LATENCY_ACTION_DIR/job-stale.json" latency ',"latency_type":"proxy","section":"main","tag":"proxy-a"'
expect latency_test_status 0 stale -- job-stale
stale_job "$UPDATES_JOB_DIR/job-stale.json" component ',"component":"sing_box","action":"check_update"'
expect component_action_status 0 stale -- job-stale
stale_job "$PROKOP_SUBSCRIPTION_UPDATE_JOB_DIR/job-stale.json" subscription ',"section":"main","source_index":"0"'
expect subscription_update_status 0 stale -- job-stale
rm -f "$PROKOP_UI_SERVICE_ACTION_DIR/job-stale.json" "$PROKOP_UI_LATENCY_ACTION_DIR/job-stale.json" \
  "$UPDATES_JOB_DIR/job-stale.json" "$PROKOP_SUBSCRIPTION_UPDATE_JOB_DIR/job-stale.json"

# --- Latency tests --------------------------------------------------------------------
expect latency_test_async 1 invalid_input -- bogus main tag 5000
expect latency_test_async 1 invalid_input -- proxy main "" 5000
live_process
state acquire-runtime-dir-lock "$PROKOP_LATENCY_TEST_LOCK_DIR" "$LIVE" || fail "fixture: could not take the latency lock"
expect latency_test_async 1 busy -- proxy main proxy-a 5000
state release-runtime-dir-lock "$PROKOP_LATENCY_TEST_LOCK_DIR" "$LIVE"
expect latency_test_status 1 invalid_input -- ../x
expect latency_test_status 1 not_found -- 1700000000_123
# A latency job against a controller that does not answer fails with the
# error code of clash_api.
expect latency_test_async 0 "" -- proxy main proxy-a 1000
job="$(json_field job_id)"
for _ in $(seq 1 100); do
  expect latency_test_status 0 "" -- "$job"
  [ "$(json_field running)" = false ] && break
  sleep 0.1
done
expect latency_test_status 0 clash_api_unreachable -- "$job"

# --- clash_api ----------------------------------------------------------------------
expect clash_api 1 clash_api_unreachable -- get_proxies
expect clash_api 1 invalid_input -- get_proxy_latency ""
expect clash_api 1 invalid_input -- no_such_action

# --- Component actions -----------------------------------------------------------------
mkdir -p "$UPDATES_JOB_DIR"
expect component_action_async 1 invalid_input -- bogus nothing
expect component_action_async 1 invalid_input -- sing_box install 1.2.3
live_process
state acquire-runtime-dir-lock "$UPDATES_LOCK_DIR" "$LIVE" || fail "fixture: could not take the component lock"
expect component_action_async 1 busy -- sing_box check_update
expect component_action 1 busy -- sing_box check_update
# An action outside components/catalog.uc, the one list the UI start and the
# action itself check, is refused by the UI start before any lock: no refusal
# as busy that a retry could not help.
expect component_action_async 1 invalid_input -- prokop remove
state release-runtime-dir-lock "$UPDATES_LOCK_DIR" "$LIVE"
[ -z "$(ls -A "$UPDATES_JOB_DIR")" ] || fail "a refused component action started a job"
expect component_action 1 invalid_input -- bogus nothing
expect component_action 1 invalid_input -- prokop remove
# The release catalog cannot be fetched (curl, wget and uclient-fetch fail).
expect prokop_releases 1 failure --
expect component_action_status 1 invalid_input -- ../x
expect component_action_status 1 not_found -- 1700000000_123

# --- Subscription updates -----------------------------------------------------------------
expect subscription_update_status 1 invalid_input -- ../x
expect subscription_update_status 1 not_found -- 1700000000_123
# A UI update that another reload or subscription update kept from its locks
# (prokop subscription_update exits 2) was refused as busy, not failed.
cat >"${WORK:?}/busy-prokop" <<'SH'
#!/bin/sh
echo "Prokop reload is already running; the subscription update did not run"
exit 2
SH
chmod +x "${WORK:?}/busy-prokop"
printf '{"success":true,"running":true,"kind":"subscription","message":"running","section":"main","source_index":"0","started_at":%s}\n' \
  "$(date +%s)" >"$PROKOP_SUBSCRIPTION_UPDATE_JOB_DIR/job-busy.json"
PROKOP_BIN="${WORK:?}/busy-prokop" ucode -L "$LIB" "$LIB/components/updates.uc" subscription-update-worker \
  "$PROKOP_SUBSCRIPTION_UPDATE_JOB_DIR/job-busy.json" "${WORK:?}/busy-update.out" main 0 ||
  fail "subscription-update-worker exited non-zero"
expect subscription_update_status 0 busy -- job-busy
grep -Fq 'did not run' "${WORK:?}/out" || fail "the busy subscription job must say why: $(cat "${WORK:?}/out")"

# --- Snapshots -------------------------------------------------------------------------------
expect config_snapshot_create 1 invalid_input -- bogus-kind
expect config_snapshot_create 0 "" -- manual
snapshot="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).snapshot.id)' "${WORK:?}/out")"
expect config_snapshot_list 0 "" --
expect config_snapshot_diff 0 "" -- "$snapshot"
expect config_snapshot_diff 1 "" -- missing-snapshot
expect config_snapshot_delete 1 invalid_input -- ../x
expect config_snapshot_delete 1 invalid_snapshot -- missing-snapshot
printf '%s\n' "$snapshot" >"$PROKOP_SNAPSHOT_DIR/last-known-working"
expect config_snapshot_delete 1 lkg_protected -- "$snapshot"
rm -f "$PROKOP_SNAPSHOT_DIR/last-known-working"
expect config_snapshot_delete 0 "" -- "$snapshot"

# --- Read views, validators and inputs ----------------------------------------------------------
expect show_version 0 "" --
expect show_config 0 "" -- masked
expect get_ui_capabilities 0 "" --
expect get_ui_state 0 "" --
expect get_history 0 "" --
expect device_traffic 0 "" --
expect get_readonly_config_sections 0 "" --
expect get_dashboard_runtime_metadata 0 "" --
expect validate_nfqws_strategy_json 0 "" -- "--dpi-desync=fake"
expect validate_nfqws2_strategy_json 0 "" -- ""
expect validate_byedpi_strategy_json 0 "" -- ""
expect route_trace 1 invalid_input -- "bad host!" "" "" ""
expect connectivity_test 1 invalid_input -- "bad host!" tcp 443
expect autotune_status 0 "" --
expect autotune_target 1 invalid_target -- "../x"
PROKOP_UCI_STATE_FILE="${WORK:?}/missing-state" expect show_sing_box_config 1 "" -- masked
grep -Fxq 'Configuration file not found' "${WORK:?}/err" || fail "show_sing_box_config must say why it failed"

printf 'CLI rc <-> JSON contract checks passed\n'
