#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let common = require("core.common");
let process_identity = require("core.process_identity");
let runtime_lock = require("core.runtime_lock");
let refresh_worker = require("core.refresh_worker");
let legacy = require("core.legacy_forkop");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function constant_value(name, fallback) {
    let value = constants[name];
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || constant_value("PROKOP_CONFIG_NAME", "prokop");
const CONFIG_FILE = getenv("PROKOP_CONFIG_FILE") || "/etc/config/" + CONFIG_NAME;
const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const BIN_PATH = getenv("PROKOP_BIN") || constant_value("PROKOP_BIN", "/usr/bin/prokop");
const SERVICE_INIT = getenv("PROKOP_SERVICE_INIT") || constant_value("PROKOP_SERVICE_INIT", "/etc/init.d/prokop");
const SERVICE_NAME = getenv("PROKOP_SERVICE_NAME") || constant_value("PROKOP_SERVICE_NAME", "prokop");
// The one-line installer that migrates a router from the product before the
// rename (core/legacy_forkop.uc).
const INSTALL_COMMAND = "wget -qO- " + constant_value("PROKOP_RELEASE_BASE_URL", "https://asofwar.github.io/prokop") + "/install.sh | sh";

const RUNTIME_STATE_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const SYSTEM_INFO_CACHE_FILE = getenv("PROKOP_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
const RELOAD_STATE_FILE = getenv("PROKOP_RELOAD_STATE_FILE") || RUNTIME_STATE_DIR + "/reload-state";
const RELOAD_STATE_SNAPSHOT_FILE = getenv("PROKOP_RELOAD_STATE_SNAPSHOT_FILE") || RUNTIME_STATE_DIR + "/reload-state.snapshot." + clock()[0] + "." + clock()[1];
const PENDING_RELOAD_FILE = getenv("PROKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const LIST_UPDATE_RELOAD_FILE = getenv("PROKOP_LIST_UPDATE_RELOAD_FILE") || RUNTIME_STATE_DIR + "/list-update.reload";
// Present while the live nft table lacks the list generation of the current
// configuration: a start without it, or a reload that left the rebuild to
// the list worker's list-content reload. Nothing may be rendered from that
// table meanwhile (killswitch/runtime.uc, UC-209).
const RUNTIME_LISTS_PENDING_FILE = getenv("PROKOP_RUNTIME_LISTS_PENDING_FILE") || RUNTIME_STATE_DIR + "/runtime-lists.pending";
const RULESET_REFRESH_AFTER_LIST_FILE = getenv("PROKOP_RULESET_REFRESH_AFTER_LIST_FILE") || RUNTIME_STATE_DIR + "/ruleset-refresh-after-list";
const START_IN_PROGRESS_FILE = getenv("PROKOP_START_IN_PROGRESS_FILE") || RUNTIME_STATE_DIR + "/start.in-progress";
const START_FAILURE_FILE = getenv("PROKOP_START_FAILURE_FILE") || RUNTIME_STATE_DIR + "/start.failure";
const START_RETRY_FILE = getenv("PROKOP_START_RETRY_FILE") || RUNTIME_STATE_DIR + "/start.retry";
// An explicit stop (service/state.uc runtime-apply-allowed; UC-012). It stays
// in effect until an explicit start or restart: no reload brings back the
// runtime it took down (reload_skipped_after_stop; D-15, UC-056).
const STOP_REQUESTED_FILE = getenv("PROKOP_STOP_REQUESTED_FILE") || RUNTIME_STATE_DIR + "/stop.requested";
// An explicit start since boot (service/initd.uc EXPLICIT_START_FILE),
// written by start and restart, removed by the user's stop. A reload does
// not start a runtime that is down without it (D-15(a), UC-056).
const EXPLICIT_START_FILE = getenv("PROKOP_EXPLICIT_START_FILE") || RUNTIME_STATE_DIR + "/start.explicit";
// Whether the last runtime of this boot was stopped cleanly, for dns/apply.uc:
// "0" once a start configured dnsmasq (also when it crashed after that), "1"
// after a stop or the cleanup of a failed start; none before the first start
// or stop of a boot. Runtime state, not configuration (UC-160).
const SHUTDOWN_STATE_FILE = RUNTIME_STATE_DIR + "/shutdown_correctly";
const MANAGED_UPGRADE_SING_BOX_MARKER = getenv("PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER") || "/tmp/prokop-managed-upgrade-sing-box";
const MANAGED_UPGRADE_SING_BOX_WAIT_SECONDS = int(getenv("PROKOP_MANAGED_UPGRADE_SING_BOX_WAIT_SECONDS") || "15");
const MANAGED_UPGRADE_SING_BOX_MARKER_MAX_AGE_SECONDS = int(getenv("PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER_MAX_AGE_SECONDS") || "120");
const SERVICE_TRIGGER_SYNC_FILE = getenv("PROKOP_SERVICE_TRIGGER_SYNC_FILE") || RUNTIME_STATE_DIR + "/service-triggers.sync";
const SUBSCRIPTION_UPDATE_STATE_DIR = getenv("PROKOP_SUBSCRIPTION_UPDATE_STATE_DIR") || RUNTIME_STATE_DIR + "/subscription-update";
const SUBSCRIPTION_LINKS_DIR = getenv("PROKOP_SUBSCRIPTION_LINKS_DIR") || RUNTIME_STATE_DIR + "/subscription-links";
const SUBSCRIPTION_METADATA_DIR = getenv("PROKOP_SUBSCRIPTION_METADATA_DIR") || RUNTIME_STATE_DIR + "/subscription-metadata";
const OUTBOUND_METADATA_DIR = getenv("PROKOP_OUTBOUND_METADATA_DIR") || RUNTIME_STATE_DIR + "/outbound-metadata";
const SECTION_CACHE_DIR = getenv("PROKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const RULE_CONDITION_CACHE_DIR = getenv("PROKOP_RULE_CONDITION_CACHE_DIR") || RUNTIME_STATE_DIR + "/rule-condition-cache";
const RUNTIME_CACHE_FORMAT_FILE = getenv("PROKOP_RUNTIME_CACHE_FORMAT_FILE") || RUNTIME_STATE_DIR + "/cache-format";
const PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/prokop/subscription-cache";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "10";
const LIFECYCLE_UC = LIB_DIR + "/service/lifecycle.uc";
const SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE = getenv("PROKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE") || RUNTIME_STATE_DIR + "/subscription-bootstrap-retry.pid";
const DNS_FAILOVER_STATE_FILE = getenv("PROKOP_DNS_FAILOVER_STATE_FILE") || RUNTIME_STATE_DIR + "/dns-failover.json";
const DNS_FAILOVER_PID_FILE = getenv("PROKOP_DNS_FAILOVER_PID_FILE") || RUNTIME_STATE_DIR + "/dns-failover.pid";
const SUBSCRIPTION_UPDATE_LOCK_DIR = getenv("PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR") || RUNTIME_STATE_DIR + "/subscription-update.lock";
const RELOAD_LOCK_DIR = getenv("PROKOP_RELOAD_LOCK_DIR") || "/var/run/prokop.reload.lock";
const INTERNAL_CONFIG_TRIGGER_GUARD = getenv("PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD") || "/var/run/prokop.internal-config-change";
// The uci CLI that core/uci.uc commit_option() commits one option with.
const UCI_CLI = getenv("PROKOP_UCI_CLI") || "uci";
const LIST_UPDATE_CRON_MARKER = getenv("PROKOP_LIST_UPDATE_CRON_MARKER") || "# prokop-list-update";
const SUBSCRIPTION_UPDATE_CRON_MARKER = getenv("PROKOP_SUBSCRIPTION_UPDATE_CRON_MARKER") || "# prokop-subscription-update";
const COMPONENT_UPDATE_CHECK_CRON_MARKER = getenv("PROKOP_COMPONENT_UPDATE_CHECK_CRON_MARKER") || "# prokop-component-update-check";
const RELOAD_STATE_FORMAT = int(getenv("PROKOP_RELOAD_STATE_FORMAT") || "1");
const RUNTIME_CACHE_FORMAT = int(getenv("PROKOP_RUNTIME_CACHE_FORMAT") || "11");
const RUNTIME_STABLE_MIN_AGE = int(getenv("PROKOP_RUNTIME_STABLE_MIN_AGE") || "2");
const SING_BOX_START_STABLE_MIN_AGE = int(getenv("PROKOP_SING_BOX_START_STABLE_MIN_AGE") || "8");
const SING_BOX_START_VERIFY_TIMEOUT = int(getenv("PROKOP_SING_BOX_START_VERIFY_TIMEOUT") || "10");
const NFT_POPULATE_ENABLED_DEFAULT = int(getenv("PROKOP_NFT_POPULATE_ENABLED") || "1");

const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || constant_value("TMP_SING_BOX_FOLDER", "/tmp/sing-box");
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || constant_value("TMP_RULESET_FOLDER", TMP_SING_BOX_FOLDER + "/rulesets");
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || constant_value("TMP_SUBSCRIPTION_FOLDER", TMP_SING_BOX_FOLDER + "/subscriptions");

const RT_TABLE_NAME = constant_value("RT_TABLE_NAME", "prokop");
const NFT_TABLE_NAME = constant_value("NFT_TABLE_NAME", "ProkopTable");
const NFT_LOCALV4_SET_NAME = constant_value("NFT_LOCALV4_SET_NAME", "localv4");
const NFT_LOCALV6_SET_NAME = constant_value("NFT_LOCALV6_SET_NAME", "localv6");
const NFT_COMMON_SET_NAME = constant_value("NFT_COMMON_SET_NAME", "prokop_subnets");
const NFT_COMMON6_SET_NAME = constant_value("NFT_COMMON6_SET_NAME", "prokop_subnets6");
const NFT_PORT_SET_NAME = constant_value("NFT_PORT_SET_NAME", "prokop_ports");
const NFT_IP_PORT_SET_NAME = constant_value("NFT_IP_PORT_SET_NAME", "prokop_ip_ports");
const NFT_IP_PORT6_SET_NAME = constant_value("NFT_IP_PORT6_SET_NAME", "prokop_ip6_ports");
const NFT_INTERFACE_SET_NAME = constant_value("NFT_INTERFACE_SET_NAME", "prokop_interfaces");
const NFT_FAKEIP_MARK = constant_value("NFT_FAKEIP_MARK", "0x04000000");
const NFT_OUTBOUND_MARK = constant_value("NFT_OUTBOUND_MARK", "0x08000000");

const SB_FAKEIP_INET4_RANGE = constant_value("SB_FAKEIP_INET4_RANGE", "198.18.0.0/15");
const SB_FAKEIP_INET6_RANGE = constant_value("SB_FAKEIP_INET6_RANGE", "fc00::/18");
const SB_TPROXY_INBOUND6_ADDRESS = constant_value("SB_TPROXY_INBOUND6_ADDRESS", "::1");
const SB_TPROXY_INBOUND_PORT = constant_value("SB_TPROXY_INBOUND_PORT", "1602");
const SB_SERVICE_MIXED_INBOUND_ADDRESS = constant_value("SB_SERVICE_MIXED_INBOUND_ADDRESS", "127.0.0.1");
const SB_SERVICE_MIXED_INBOUND_PORT = constant_value("SB_SERVICE_MIXED_INBOUND_PORT", "4534");
const SB_VARIANT_STATE_FILE = constant_value("SB_VARIANT_STATE_FILE", "/etc/prokop/sing-box-variant");
const SB_VERSION_STATE_FILE = constant_value("SB_VERSION_STATE_FILE", "/etc/prokop/sing-box-version");
const SRS_FALLBACK_MAIN_URL = constant_value("SRS_FALLBACK_MAIN_URL", "https://github.com/itdoginfo/allow-domains/releases/latest/download");
const SRS_FALLBACK_ADS_HAGEZI_PRO_URL = constant_value("SRS_FALLBACK_ADS_HAGEZI_PRO_URL", "https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.srs");
const SRS_FALLBACK_SUPERCELL_URL = constant_value("SRS_FALLBACK_SUPERCELL_URL", "https://raw.githubusercontent.com/ushan0v/sing-box-supercell-ruleset/main/supercell.srs");
const SRS_FALLBACK_GITHUB_URL = constant_value("SRS_FALLBACK_GITHUB_URL", "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/github.srs");

const ZAPRET_PROVIDER_NFQWS_BIN = constant_value("ZAPRET_PROVIDER_NFQWS_BIN", "/opt/zapret/nfq/nfqws");
const ZAPRET_ROUTE_MARK_BASE = constant_value("ZAPRET_ROUTE_MARK_BASE", "0x01000000");
const ZAPRET_QUEUE_BASE = constant_value("ZAPRET_QUEUE_BASE", "4000");
const ZAPRET_DESYNC_MARK = constant_value("ZAPRET_DESYNC_MARK", "0x40000000");
const ZAPRET_DESYNC_MARK_POSTNAT = constant_value("ZAPRET_DESYNC_MARK_POSTNAT", "0x20000000");
const ZAPRET2_PROVIDER_NFQWS2_BIN = constant_value("ZAPRET2_PROVIDER_NFQWS2_BIN", "/opt/zapret2/nfq2/nfqws2");
const ZAPRET2_ROUTE_MARK_BASE = constant_value("ZAPRET2_ROUTE_MARK_BASE", "0x02000000");
const ZAPRET2_QUEUE_BASE = constant_value("ZAPRET2_QUEUE_BASE", "4300");
const ZAPRET2_DESYNC_MARK = constant_value("ZAPRET2_DESYNC_MARK", "0x40000000");
const ZAPRET2_DESYNC_MARK_POSTNAT = constant_value("ZAPRET2_DESYNC_MARK_POSTNAT", "0x20000000");
const BYEDPI_BIN = constant_value("BYEDPI_BIN", "/usr/bin/ciadpi");

const DNS_APPLY_UC = LIB_DIR + "/dns/apply.uc";
const VALIDATOR_UC = LIB_DIR + "/config/validator.uc";
const NFT_UC = LIB_DIR + "/nft/apply.uc";
const SINGBOX_UC = LIB_DIR + "/singbox/runtime.uc";
const PRIORITY_UC = LIB_DIR + "/singbox/priority.uc";
const DNS_FAILOVER_UC = LIB_DIR + "/singbox/dns_failover.uc";
const SUBSCRIPTION_CACHE_UC = LIB_DIR + "/subscription/cache.uc";
const RULESET_CACHE_UC = LIB_DIR + "/singbox/ruleset_cache.uc";
const UPDATES_UC = LIB_DIR + "/components/updates.uc";
const AUTOTUNE_MANAGER_UC = LIB_DIR + "/autotune/manager.uc";
const STATE_UC = LIB_DIR + "/service/state.uc";
const RELOAD_UC = LIB_DIR + "/service/reload.uc";
const UI_UC = LIB_DIR + "/service/ui.uc";
const DIAGNOSTICS_UC = LIB_DIR + "/diagnostics/runtime.uc";
const ZAPRET_UC = LIB_DIR + "/providers/zapret/runtime.uc";
const ZAPRET2_UC = LIB_DIR + "/providers/zapret2/runtime.uc";
const BYEDPI_UC = LIB_DIR + "/providers/byedpi/runtime.uc";
const KILLSWITCH_UC = LIB_DIR + "/killswitch/runtime.uc";

let start_subscription_update_lock_held = false;
// Whether the last start_main applied the complete list generation; the
// kill-switch is only refreshed from a runtime that has it.
let start_lists_complete = true;
// Set once start_impl runs: an explicit start or restart has ended an earlier
// explicit stop before, so a stop request seen after that was made during
// this start (UC-012).
let start_watches_stop_request = false;
let subscription_caches_prepared = getenv("PROKOP_SUBSCRIPTION_CACHES_PREPARED") || "0";
let subscription_runtime_no_refresh = getenv("PROKOP_SUBSCRIPTION_RUNTIME_NO_REFRESH") || "0";
let subscription_deferred_sections = "";
let nft_populate_enabled = NFT_POPULATE_ENABLED_DEFAULT;
let nft_candidate_batch_file = "";
let rule_condition_cache_enabled = 0;
let startup_config_fingerprint = "";
let dpi_snapshot_dir = "";
let dpi_switch_started = false;
let dpi_restart_plan = null;
let dpi_nft_rollback_file = "";
let dpi_nft_committed = false;
let dpi_singbox_backup = "";
// How a failed reload takes its dnsmasq step back
// (snapshot_dnsmasq_reload_config); "" before that step.
let dns_reload_rollback = "";
let dpi_guard_active = false;
// Set once the reload in progress has given way to a stop request
// (reload_gives_way_to_stop).
let reload_stop_abandoned = false;
// The reload in progress stopped the Priority and DNS failover workers
// before its sing-box transition (LC-2), and whether it began to replace the
// live sing-box config. Until that commit the live config and section-cache
// are still the running generation, so a failed reload restarts the workers.
let reload_workers_stopped = false;
let reload_singbox_commit_started = false;

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function command_status(command) {
    return normalize_status(system(command));
}

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };

    let data = pipe.read("all");
    let status = normalize_status(pipe.close());
    return { status, output: data == null ? "" : as_string(data) };
}

function command_output(command) {
    let result = command_capture(command);
    return result.status == 0 ? result.output : "";
}

function read_json_file(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function command_status_from_args(args) {
    return command_status(command_from_args(args));
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function external_config_fingerprint() {
    let data = fs.readfile(CONFIG_FILE);
    if (data == null)
        return "";

    let lines = [];
    for (let line in split(as_string(data), "\n"))
        if (match(as_string(line), /^[ \t]*option[ \t]+shutdown_correctly([ \t]|$)/) == null)
            push(lines, line);

    return join("\n", lines);
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

// This ucode process. `sh -c 'echo $PPID'` names it only when /bin/sh execs
// its last command (busybox ash); dash reports a shell that has exited, and
// a runtime lock (core/runtime_lock.uc) is never held by an exited owner.
function owner_pid() {
    let pid = as_string(fs.readlink("/proc/self"));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function bool_text(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function string_array_contains(values, needle) {
    needle = as_string(needle);
    if (needle == "")
        return false;

    for (let item in array_or_empty(values))
        if (as_string(item) == needle)
            return true;

    return false;
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value));
}

function remove_file(path) {
    return fs.unlink(as_string(path)) || true;
}

function ensure_dir(path) {
    path = as_string(path);
    return path == "" || fs.mkdir(path, 0755) || fs.stat(path) != null;
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", SERVICE_NAME, "[" + level + "] " + as_string(message) ]);
}

function lifecycle_env() {
    let result = {
        PROKOP_CONFIG_NAME: CONFIG_NAME,
        PROKOP_LIB: LIB_DIR,
        PROKOP_BIN: BIN_PATH,
        PROKOP_SERVICE_INIT: SERVICE_INIT,
        PROKOP_RUNTIME_STATE_DIR: RUNTIME_STATE_DIR,
        PROKOP_SYSTEM_INFO_CACHE_FILE: SYSTEM_INFO_CACHE_FILE,
        PROKOP_SUBSCRIPTION_UPDATE_STATE_DIR: SUBSCRIPTION_UPDATE_STATE_DIR,
        PROKOP_SUBSCRIPTION_LINKS_DIR: SUBSCRIPTION_LINKS_DIR,
        PROKOP_SUBSCRIPTION_METADATA_DIR: SUBSCRIPTION_METADATA_DIR,
        PROKOP_OUTBOUND_METADATA_DIR: OUTBOUND_METADATA_DIR,
        PROKOP_SECTION_CACHE_DIR: SECTION_CACHE_DIR,
        PROKOP_RULE_CONDITION_CACHE_DIR: RULE_CONDITION_CACHE_DIR,
        PROKOP_RUNTIME_CACHE_FORMAT_FILE: RUNTIME_CACHE_FORMAT_FILE,
        PROKOP_RUNTIME_CACHE_FORMAT: as_string(RUNTIME_CACHE_FORMAT),
        PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR: PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT,
        PROKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE: SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE,
        PROKOP_DNS_FAILOVER_STATE_FILE: DNS_FAILOVER_STATE_FILE,
        PROKOP_DNS_FAILOVER_PID_FILE: DNS_FAILOVER_PID_FILE,
        PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR: SUBSCRIPTION_UPDATE_LOCK_DIR,
        PROKOP_PENDING_RELOAD_FILE: PENDING_RELOAD_FILE,
        PROKOP_RELOAD_LOCK_DIR: RELOAD_LOCK_DIR,
        PROKOP_NFT_BATCH_FILE: nft_candidate_batch_file,
        PROKOP_NFT_CANDIDATE_FAIL_PHASE: getenv("PROKOP_NFT_CANDIDATE_FAIL_PHASE") || "",
        PROKOP_SINGBOX_CONFIG_FAIL_PHASE: getenv("PROKOP_SINGBOX_CONFIG_FAIL_PHASE") || "",
        // Test-only bounded readiness fault injection is forwarded to the
        // state module. Empty in production, where its normal timeout stays
        // unchanged.
        PROKOP_SING_BOX_RELOAD_PID_TIMEOUT: getenv("PROKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "",
        TMP_SING_BOX_FOLDER: TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER: TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER: TMP_SUBSCRIPTION_FOLDER,
        SB_SERVICE_MIXED_INBOUND_ADDRESS: SB_SERVICE_MIXED_INBOUND_ADDRESS,
        SB_SERVICE_MIXED_INBOUND_PORT: SB_SERVICE_MIXED_INBOUND_PORT,
        SB_VARIANT_STATE_FILE: SB_VARIANT_STATE_FILE,
        SB_VERSION_STATE_FILE: SB_VERSION_STATE_FILE,
        ZAPRET_PROVIDER_NFQWS_BIN: ZAPRET_PROVIDER_NFQWS_BIN,
        ZAPRET2_PROVIDER_NFQWS2_BIN: ZAPRET2_PROVIDER_NFQWS2_BIN,
        BYEDPI_BIN: BYEDPI_BIN,
        PROKOP_RULE_CONDITION_CACHE_ENABLED: as_string(rule_condition_cache_enabled)
    };

    return result;
}

function command_env(assignments) {
    let parts = [];
    for (let name, value in assignments)
        push(parts, as_string(name) + "=" + shell_quote(value));
    return join(" ", parts);
}

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in (type(args) == "array" ? args : []))
        push(result, arg);
    return result;
}

function module_command(module_path, args) {
    return command_env(lifecycle_env()) + " " + command_from_args(module_args(module_path, args));
}

function module_capture(module_path, args) {
    return command_capture(module_command(module_path, args));
}

function module_status(module_path, args) {
    return command_status(module_command(module_path, args));
}

function module_success(module_path, args) {
    return module_status(module_path, args) == 0;
}

function validation_failure_message(result) {
    for (let line in split(as_string(result.output), "\n")) {
        line = trim(line);
        if (line != "")
            return line;
    }

    return "The configuration could not be validated. Aborted.";
}

function mark_pending_reload(reason) {
    return module_success(STATE_UC, [ "mark-pending-reload", PENDING_RELOAD_FILE, reason ]);
}

function pending_reload_log_context(reason) {
    reason = as_string(reason);
    if (reason == "config_changed_during_reload")
        return "current reload";
    return "startup";
}

function mark_pending_reload_if_config_changed(initial_fingerprint, reason) {
    initial_fingerprint = as_string(initial_fingerprint);
    if (initial_fingerprint == "")
        return false;

    let current_fingerprint = external_config_fingerprint();
    if (current_fingerprint == "" || current_fingerprint == initial_fingerprint)
        return false;

    let context = pending_reload_log_context(reason);
    if (mark_pending_reload(reason)) {
        log_message("Configuration changed during " + context + "; queued reload after " + context + " completes", "info");
        return true;
    }

    log_message("Configuration changed during " + context + ", but pending reload could not be queued", "warn");
    return false;
}

// A fail-closed guard that a failed lifecycle transition kept (UC-019): the
// DPI guard table of a reload whose DPI rollback failed (abort_reload), or
// the transition guard chain of a sing-box transition whose rollback failed
// (abort_guarded_transition). Both drop the traffic they guard until a stop
// removes them (stop_main), and both are installed create-only, so no reload
// can run its own transition over them. init.d runs every reload and start
// under reload.lock: a guard seen by one is not another one's in flight.
// The recovery is a restart: its stop removes the guard before the start.
function runtime_guard_kept() {
    return command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME + "DpiGuard" ]) ||
        command_success_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "prokop_transition_guard" ]);
}

// Last-known-working names only a configuration that this start or reload
// proved (UC-019, UC-020): the file is still the one it began with (an edit
// made meanwhile waits for the reload queued for it), and no DPI transition
// guard, neither of a restore or autotune apply nor of a failed lifecycle
// transition, protects a runtime that no reload has proved yet.
// config/snapshots.uc also refuses while an autotune apply is unfinished or
// has not settled on the candidate that is now the configuration.
// Every restore and autotune apply reloads under its own guard and moves
// last-known-working itself: that refusal is routine and not logged.
function confirm_working_config(initial_fingerprint) {
    if (external_config_fingerprint() != as_string(initial_fingerprint))
        return false;
    if (command_success_from_args([ "nft", "list", "table", "inet", "ProkopConfigRestoreDpiGuard" ]))
        return false;
    if (runtime_guard_kept()) {
        log_message("Working configuration not confirmed as last known working: a failed transition kept its fail-closed guard", "info");
        return false;
    }
    let result = module_capture(LIB_DIR + "/config/snapshots.uc", [ "confirm-working" ]);
    let answer = null;
    try { answer = json(result.output); } catch (e) { answer = null; }
    if (type(answer) == "object" && answer.status == "not_confirmed")
        log_message("Working configuration not confirmed as last known working: " + as_string(answer.reason), "info");
    return result.status == 0;
}

function finish_reload_status(status, initial_fingerprint) {
    status = int(status || 0);
    if (status == 0)
        confirm_working_config(initial_fingerprint);
    if (status == 0)
        mark_pending_reload_if_config_changed(initial_fingerprint, "config_changed_during_reload");
    return status;
}

function module_output(module_path, args) {
    let result = module_capture(module_path, args);
    return result.status == 0 ? result.output : "";
}

function selector_state_from_proxies_payload(payload) {
    let result = {};
    let proxies = object_or_empty(object_or_empty(payload).proxies);

    for (let tag, proxy in proxies) {
        proxy = object_or_empty(proxy);
        let proxy_type = lc(as_string(proxy.type || ""));
        let selected = as_string(proxy.now || "");

        if (proxy_type == "selector" && string_array_contains(proxy.all, selected))
            result[as_string(tag)] = selected;
    }

    return result;
}

function selector_restore_pairs(snapshot, payload) {
    let result = [];
    snapshot = object_or_empty(snapshot);
    let proxies = object_or_empty(object_or_empty(payload).proxies);

    for (let group, selected in snapshot) {
        group = as_string(group);
        selected = as_string(selected);

        if (group == "" || selected == "")
            continue;

        let proxy = object_or_empty(proxies[group]);
        if (lc(as_string(proxy.type || "")) != "selector")
            continue;
        if (!string_array_contains(proxy.all, selected))
            continue;
        if (as_string(proxy.now || "") == selected)
            continue;

        push(result, { group, proxy: selected });
    }

    return result;
}

function clash_api_json(action, arg1, arg2, arg3) {
    let result = module_capture(DIAGNOSTICS_UC, [
        "clash-api",
        action,
        as_string(arg1 || ""),
        as_string(arg2 || ""),
        as_string(arg3 || "")
    ]);
    if (result.status != 0)
        return null;

    try {
        return json(result.output);
    }
    catch (e) {
        return null;
    }
}

function capture_selector_state() {
    return selector_state_from_proxies_payload(clash_api_json("get_proxies"));
}

function restore_selector_state(snapshot) {
    let pairs = selector_restore_pairs(snapshot, clash_api_json("get_proxies"));

    for (let pair in pairs)
        module_success(DIAGNOSTICS_UC, [ "clash-api", "set_group_proxy", pair.group, pair.proxy, "" ]);
}

function module_background(module_path, args) {
    return command_status(module_command(module_path, args) + " >/dev/null 2>&1 1000>&- &") == 0;
}

function config_get(path, fallback) {
    path = as_string(path);
    if (!uci_core.exists(path))
        return as_string(fallback);
    return trim(uci_core.get(path));
}

function file_md5(path) {
    path = as_string(path);
    if (path == "" || fs.stat(path) == null)
        return "";

    let output = command_output("md5sum " + shell_quote(path) + " 2>/dev/null");
    let fields = split(trim(output), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function current_config_hash() {
    return file_md5(CONFIG_FILE);
}

function mark_internal_config_guard() {
    let hash = current_config_hash();
    if (hash == "") {
        fs.unlink(INTERNAL_CONFIG_TRIGGER_GUARD);
        return;
    }

    let stamp = clock();
    let tmp_path = INTERNAL_CONFIG_TRIGGER_GUARD + "." + stamp[0] + "." + stamp[1];
    fs.writefile(tmp_path, as_string(stamp[0]) + "\n" + hash + "\n");
    if (!fs.rename(tmp_path, INTERNAL_CONFIG_TRIGGER_GUARD))
        fs.unlink(tmp_path);
}

// SHUTDOWN_STATE_FILE, on tmpfs and only when it changes. Releases before
// UC-160 kept it as option shutdown_correctly in /etc/config/prokop, which
// put a flash write and a commit of the whole package (with whatever someone
// staged with `uci set`) into every start and stop, and a full or read-only
// overlay failed the start. A record that cannot be written costs at most
// one dnsmasq restart more (dns/apply.uc): it fails neither start nor stop.
function record_shutdown_state(value) {
    value = as_string(value) + "\n";
    if (fs.readfile(SHUTDOWN_STATE_FILE) == value)
        return true;
    if (ensure_dir(RUNTIME_STATE_DIR) && write_file(SHUTDOWN_STATE_FILE, value) != null)
        return true;
    log_message("Could not record the Prokop runtime state in " + SHUTDOWN_STATE_FILE, "warn");
    return false;
}

function mark_runtime_stopped_clean() {
    record_shutdown_state("1");
    module_success(STATE_UC, [ "clear-reload-state", RELOAD_STATE_FILE, RELOAD_STATE_SNAPSHOT_FILE ]);
}

function setting_bool(name, fallback) {
    let value = config_get(CONFIG_NAME + ".settings." + as_string(name), fallback ? "1" : "0");
    return bool_text(value);
}

function clear_start_failure() {
    remove_file(START_FAILURE_FILE);
}

// A start refused for a guard that only a restart removes: init.d does not
// schedule a retry of it (initd.uc start_service), since none could succeed
// before that restart and each would record another failed start (UC-019).
// The next start clears the mark (start_inner, start_main).
function mark_start_failure_not_retryable(reason) {
    write_file(START_FAILURE_FILE, "reason=" + as_string(reason) + "\n");
}

// Prokop never runs next to the product before the rename while that one is
// active: both drive the same sing-box service, dnsmasq and policy routing
// table. Only the installer's migration hands the router over; until then a
// start, restart or reload-restart is refused, and not retried.
function legacy_start_refused(action) {
    let reason = legacy.active_reason();
    if (reason == null)
        return false;
    log_message("Refusing Prokop " + as_string(action) + ": " + legacy.PRODUCT + " is still active (" + reason +
        "). Run the Prokop installer to migrate: " + INSTALL_COMMAND, "fatal");
    mark_start_failure_not_retryable("legacy_runtime_active");
    return true;
}

// The product before the rename runs here (a migration in progress or rolled
// back) and Prokop has no runtime of its own: a stop then touches nothing the
// two share (the sing-box service, dnsmasq, policy routing table 105). A
// stopped or removed old product never takes this path.
function legacy_runtime_owns_router() {
    return legacy.installed() && legacy.active() &&
        !command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ]);
}

function dns_apply_status(args) {
    return module_status(DNS_APPLY_UC, args);
}

function dns_apply_success(args) {
    return dns_apply_status(args) == 0;
}

function dnsmasq_configure(force) {
    let args = [ "configure" ];
    if (force)
        push(args, "force");
    return dns_apply_status(args);
}

function dnsmasq_restore(force) {
    let args = [ "restore" ];
    if (force)
        push(args, "force");
    return dns_apply_status(args);
}

function dnsmasq_restore_fail_safe() {
    return dns_apply_status([ "failsafe-restore" ]);
}

function dnsmasq_has_prokop_managed_state() {
    return dns_apply_success([ "has-managed-state" ]);
}

// Before the reload's dnsmasq step: whether dnsmasq forwards to sing-box.
// A reload that fails after that step sets this forwarding again or takes
// it back (dns/apply.uc configure or restore, which restart dnsmasq), never
// by copying /etc/config/dhcp back: that copy was not atomic, went around
// the UCI commit lock and discarded what anyone committed to dhcp during the
// reload (UC-071). dns/apply.uc edits only Prokop's dnsmasq options, a
// restore puts back what the configure found, and an edit starts over from
// a file someone else changed meanwhile.
function snapshot_dnsmasq_reload_config() {
    if (dns_reload_rollback == "")
        dns_reload_rollback = dns_apply_success([ "has-prokop-dns" ]) ? "configure" : "restore";
    return true;
}

function restore_dnsmasq_reload_config() {
    if (dns_reload_rollback == "")
        return true;
    if (dns_apply_status([ dns_reload_rollback, "force" ]) != 0)
        return false;
    dns_reload_rollback = "";
    return true;
}

function discard_dnsmasq_reload_config() {
    dns_reload_rollback = "";
}

// D-1 (b), UC-007: the Clash API secret is mandatory. The package postinst
// migration generates it, but a configuration that never went through the
// postinst (Prokop built into a firmware image, a keep-settings sysupgrade, a
// restored backup of an older config) would otherwise be refused by the
// validator. Only an absent or blank secret is filled in; an existing one is
// never replaced, and the value is never logged. Only the secret is
// committed: changes someone staged with uci stay staged.
function ensure_clash_api_secret() {
    if (config_get(CONFIG_NAME + ".settings.yacd_secret_key", "") != "")
        return true;
    let secret = common.random_hex_secret();
    let written = secret == null ? "" :
        uci_core.commit_option(CONFIG_FILE, CONFIG_NAME + ".settings.yacd_secret_key", secret, true, UCI_CLI);
    if (written == "") {
        log_message("Could not generate the mandatory Clash API secret", "warn");
        return false;
    }
    if (written == "written") {
        mark_internal_config_guard();
        log_message("Generated the mandatory Clash API secret", "info");
    }
    return true;
}

function validate_start_config() {
    let status = module_status(VALIDATOR_UC, [ "check-requirements" ]);
    if (status != 0)
        return status;

    let validation = module_capture(VALIDATOR_UC, [ "validate-runtime" ]);
    if (validation.status != 0) {
        log_message("Prokop configuration is invalid: " + validation_failure_message(validation), "fatal");
        return validation.status;
    }

    return 0;
}

// Taken inside reload.lock, which service/initd.uc holds around `prokop start`
// and `prokop reload`, or this process for a command-line call
// (acquire_cli_reload_lock; global lock order: service/state.uc). The one process
// that downloads under subscription-update.lock without reload.lock is the
// deferred subscription bootstrap retry, which holds the lock for as long as
// its requests take (a forced subscription update waiting for the lock takes
// it only for a moment, holding nothing else). Waiting for the retry here
// would hold reload.lock, and a DNS failover switch and every reload with it,
// for that long (UC-057). This start supersedes the retry: it prepares the
// subscription caches itself and retries the rules it defers once sing-box
// runs, with a new retry for those that stay unavailable
// (run-deferred-bootstrap). So it stops the retry by its identity first, as a
// stop and a restarting reload do in stop_main; the lock of the stopped retry
// is stale and taken at once. The bounded wait is left for a holder that is
// not the retry.
//
// The start's own downloads still run inside reload.lock, which it holds for
// its whole run (S3). The stopped retry's unfinished download is lost:
// prepare-caches defers again the rules it had not recovered, and
// run-deferred-bootstrap downloads them through the service proxy before
// this start releases subscription-update.lock. A start that meets the retry
// mid-download so holds reload.lock for one full download of those rules,
// where it used to wait for the rest of the retry's download and then skip
// the rules the retry recovered. That is a known remainder of UC-057; moving
// the start's deferred bootstrap out of reload.lock (to the background retry)
// is a change of its own.
function acquire_start_subscription_update_lock() {
    module_success(SUBSCRIPTION_CACHE_UC, [ "stop-deferred-bootstrap-worker" ]);
    if (module_success(STATE_UC, [ "acquire-runtime-dir-lock-wait", SUBSCRIPTION_UPDATE_LOCK_DIR, owner_pid(), "300" ])) {
        start_subscription_update_lock_held = true;
        return true;
    }

    log_message("Subscription update is already running during startup. Aborted.", "fatal");
    return false;
}

function release_start_subscription_update_lock() {
    if (!start_subscription_update_lock_held)
        return;

    module_success(STATE_UC, [ "release-runtime-dir-lock", SUBSCRIPTION_UPDATE_LOCK_DIR, owner_pid() ]);
    start_subscription_update_lock_held = false;
}

function nft_rebuild_runtime() {
    return module_status(NFT_UC, [
        "nft-rebuild-runtime-from-uci",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_LOCALV4_SET_NAME,
        NFT_COMMON_SET_NAME,
        NFT_PORT_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        NFT_INTERFACE_SET_NAME,
        NFT_FAKEIP_MARK,
        NFT_OUTBOUND_MARK,
        SB_FAKEIP_INET4_RANGE,
        SB_TPROXY_INBOUND_PORT,
        ZAPRET_PROVIDER_NFQWS_BIN,
        ZAPRET_ROUTE_MARK_BASE,
        ZAPRET_QUEUE_BASE,
        ZAPRET_DESYNC_MARK,
        ZAPRET_DESYNC_MARK_POSTNAT,
        ZAPRET2_PROVIDER_NFQWS2_BIN,
        ZAPRET2_ROUTE_MARK_BASE,
        ZAPRET2_QUEUE_BASE,
        ZAPRET2_DESYNC_MARK,
        ZAPRET2_DESYNC_MARK_POSTNAT,
        NFT_LOCALV6_SET_NAME,
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME,
        SB_FAKEIP_INET6_RANGE,
        SB_TPROXY_INBOUND6_ADDRESS
    ]);
}

function nft_candidate_begin() {
    nft_candidate_batch_file = trim(command_output_from_args([ "mktemp" ]));
    if (nft_candidate_batch_file == "") {
        log_message("Failed to create nft candidate batch: mktemp returned no path", "fatal");
        return false;
    }
    remove_file(nft_candidate_batch_file);
    // fs.writefile() returns the byte count on OpenWrt. An empty seed is a
    // successful zero-byte write but is falsey, so keep a harmless nft comment
    // as the first line of every candidate transaction.
    let created = write_file(nft_candidate_batch_file, "# Prokop nft candidate\n");
    if (!created)
        log_message("Failed to create nft candidate batch: ucode write_file returned false", "fatal");
    return created;
}

function nft_candidate_validate() {
    return nft_candidate_batch_file != "" && module_success(NFT_UC, [
        "nft-validate-candidate-batch",
        nft_candidate_batch_file
    ]);
}

function nft_candidate_finish(commit, validated) {
    let path = nft_candidate_batch_file;
    nft_candidate_batch_file = "";
    if (path == "")
        return !commit;
    let status = !commit || module_success(NFT_UC, [
        validated ? "nft-commit-candidate-batch" : "nft-apply-candidate-batch",
        path
    ]);
    remove_file(path);
    return status;
}

function nft_populate_runtime_sets() {
    return module_status(NFT_UC, [
        "nft-populate-runtime-sets-from-uci",
        as_string(nft_populate_enabled),
        subscription_deferred_sections,
        NFT_TABLE_NAME,
        NFT_COMMON_SET_NAME,
        NFT_PORT_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        NFT_INTERFACE_SET_NAME,
        NFT_LOCALV4_SET_NAME,
        NFT_FAKEIP_MARK,
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME,
        NFT_LOCALV6_SET_NAME
    ]);
}

// The nft sets are filled inside the start candidate, which is committed
// atomically before this runs: init-config must not fill them again live
// (UC-162), as reload's prepare-config-stage does not.
function singbox_init_config() {
    let result = module_capture(SINGBOX_UC, [
        "init-config",
        "0",
        subscription_caches_prepared,
        subscription_runtime_no_refresh,
        subscription_deferred_sections
    ]);
    if (result.status == 0) {
        subscription_deferred_sections = trim(result.output);
        subscription_caches_prepared = "1";
    }
    return result.status;
}

function singbox_prepare_config_stage(stage_path) {
    let result = module_capture(SINGBOX_UC, [
        "prepare-config-stage",
        "0",
        subscription_caches_prepared,
        subscription_runtime_no_refresh,
        subscription_deferred_sections,
        stage_path
    ]);
    if (result.status == 0) {
        subscription_deferred_sections = trim(result.output);
        subscription_caches_prepared = "1";
    }
    return result.status;
}

function discard_singbox_config_stage(stage_path) {
    if (as_string(stage_path) != "")
        module_success(SINGBOX_UC, [ "discard-config-stage", stage_path ]);
}

// A stop that stopped waiting for reload.lock (service/initd.uc) tears the
// runtime down while the reload in progress still holds the lock, and one
// that still waits does so as soon as the lock is released. From the moment
// its request is recorded the reload starts, commits and restores nothing
// more: no sing-box, no auxiliary or DPI runtime, no nft table, no dnsmasq
// change (D-15, UC-056). reload_skipped_after_stop decides the same when a
// reload begins.
function reload_gives_way_to_stop(step) {
    if (fs.stat(STOP_REQUESTED_FILE) == null)
        return false;
    if (!reload_stop_abandoned)
        log_message("Prokop reload abandoned before " + step + ": a stop was requested meanwhile; the runtime stays stopped", "info");
    reload_stop_abandoned = true;
    return true;
}

function restore_guarded_singbox_runtime(backup_path, guard_active) {
    // The stock sing-box init script may watch config.json too. Ensure that no
    // managed runtime can observe the restored file before we publish it.
    if (as_string(backup_path) == "" || module_status(STATE_UC, [
        "stop-managed-sing-box-runtime",
        as_string(getenv("PROKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15")
    ]) != 0 || !module_success(SINGBOX_UC, [ "restore-config-stage", backup_path ]))
        return false;

    // The previous configuration is back; a stop keeps sing-box down.
    if (reload_gives_way_to_stop("the sing-box rollback"))
        return false;

    if (module_status(STATE_UC, [
        "start-managed-sing-box-runtime",
        as_string(getenv("PROKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15")
    ]) != 0)
        return false;

    if (module_status(STATE_UC, [
        "wait-prokop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(SING_BOX_START_STABLE_MIN_AGE),
        as_string(SING_BOX_START_VERIFY_TIMEOUT)
    ]) != 0)
        return false;

    return !guard_active || module_success(NFT_UC, [
        "remove-transition-guard",
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK
    ]);
}

// Autotune keeps its own cron line; it never blocks the service. It reports by
// printing a JSON result, which must not reach the output of an init.d action:
// an operator who runs restart would read autotune's "enabled": false as a
// verdict on the service. Capture discards it; module_success would not.
function sync_autotune_cron(mode) {
    module_capture(AUTOTUNE_MANAGER_UC, [ mode ]);
}

function refresh_cron() {
    let status = module_status(UPDATES_UC, [
        "refresh-cron-from-uci",
        BIN_PATH,
        LIST_UPDATE_CRON_MARKER,
        SUBSCRIPTION_UPDATE_CRON_MARKER,
        COMPONENT_UPDATE_CHECK_CRON_MARKER
    ]);
    sync_autotune_cron("cron-sync");
    return status;
}

// components/updates.uc refresh-cron-from-uci exits with this status for an
// invalid interval in the settings: a configuration error, which fails the
// start or reload as it always did. Any other failure is a crontab that
// could not be read or written.
const CRON_REFRESH_INVALID_INTERVAL = 2;

let cron_refresh_failed = false;

// The scheduled jobs are not the proxy: a crontab that cannot be read or
// written (a nearly full overlay, or another writer's change at the same
// moment: components/updates.uc write_crontab_text) must not keep Prokop
// down or roll a reload back. The failure is logged (updates.uc logs what
// it left in the crontab) and recorded in the history, not masked, and the
// reload state this start or reload records keeps the cron settings
// unapplied (keep_cron_refresh_pending): the next reload refreshes the jobs
// again. Returns the status that fails the start or reload: 0 or an invalid
// interval.
function refresh_cron_reported(action) {
    let status = refresh_cron();
    if (status == 0 || status == CRON_REFRESH_INVALID_INTERVAL)
        return status;
    cron_refresh_failed = true;
    log_message("Could not update Prokop's scheduled jobs in the crontab (exit status " + as_string(status) +
        "); the " + action + " goes on, and the next reload or start updates them again", "error");
    module_success(LIB_DIR + "/diagnostics/health.uc", [ "record", "cron_refresh", "failure" ]);
    return 0;
}

// After the reload state is written: a failed cron refresh leaves the cron
// settings unapplied in it (service/state.uc mark-reload-state-cron-unapplied).
function keep_cron_refresh_pending(path) {
    if (cron_refresh_failed && !module_success(STATE_UC, [ "mark-reload-state-cron-unapplied", path ]))
        log_message("Could not record in " + path + " that the scheduled jobs were not updated; " +
            "only the next start or a change of their settings updates them", "warn");
}

function remove_cron_jobs() {
    let status = module_status(UPDATES_UC, [
        "remove-cron-jobs",
        LIST_UPDATE_CRON_MARKER,
        SUBSCRIPTION_UPDATE_CRON_MARKER,
        COMPONENT_UPDATE_CHECK_CRON_MARKER
    ]);
    sync_autotune_cron("cron-remove");
    return status;
}

function prepare_subscription_caches(mode) {
    let result = module_capture(SUBSCRIPTION_CACHE_UC, [
        "prepare-caches",
        mode,
        subscription_caches_prepared,
        subscription_runtime_no_refresh
    ]);
    if (result.status == 0) {
        subscription_deferred_sections = trim(result.output);
        subscription_caches_prepared = "1";
    }
    return result.status;
}

function start_sing_box_and_wait() {
    if (module_status(STATE_UC, [
        "start-managed-sing-box-runtime",
        getenv("PROKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15"
    ]) != 0)
        return 1;

    return module_status(STATE_UC, [
        "wait-prokop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(SING_BOX_START_STABLE_MIN_AGE),
        as_string(SING_BOX_START_VERIFY_TIMEOUT)
    ]);
}

// Only a fully applied runtime may refresh the persistent VPN kill-switch;
// every failure path keeps the previously applied protection untouched.
// Start and reload call it holding reload.lock, which a manual sync takes
// first (killswitch/runtime.uc, UC-210).
function killswitch_sync(reason) {
    if (module_status(KILLSWITCH_UC, [ "sync", reason, "reload-lock-held" ]) != 0)
        log_message("Kill-switch policy was not refreshed; the previously applied protection stays in place", "warn");
}

// A runtime without the list generation of its configuration refreshes
// nothing from its table (UC-209). Lifting renders nothing from it, so a
// kill-switch that no section has any more is lifted all the same; a
// protected section keeps the previously applied protection.
function killswitch_sync_deferred(reason) {
    log_message("Kill-switch refresh deferred until the list generation is applied", "info");
    module_success(KILLSWITCH_UC, [ "follow-stopped-config", reason, "reload-lock-held" ]);
}

function start_phase_failed(phase, status) {
    if (status != 0)
        log_message("Startup phase '" + phase + "' failed with exit status " + as_string(status), "fatal");
    return status;
}

// A stop waits for the start's reload.lock only for a bounded time: a start
// that is still at work then must not bring the runtime up after the stop.
function start_abandoned_for_stop(phase) {
    if (!start_watches_stop_request || fs.stat(STOP_REQUESTED_FILE) == null)
        return false;
    log_message("Prokop start abandoned before " + phase + ": a stop was requested meanwhile", "info");
    return true;
}

function start_main() {
    let status;

    log_message("Starting Prokop", "info");
    clear_start_failure();

    ensure_clash_api_secret();
    status = validate_start_config();
    if (status != 0)
        return status;

    startup_config_fingerprint = external_config_fingerprint();

    status = module_status(NFT_UC, [ "ensure-bridge-netfilter-disabled" ]);
    if (status != 0)
        return start_phase_failed("bridge-netfilter", status);

    module_success(STATE_UC, [ "sync-time-if-needed" ]);

    status = module_status(SUBSCRIPTION_CACHE_UC, [ "ensure-runtime-dirs" ]);
    if (status != 0)
        return start_phase_failed("runtime-dirs", status);

    if (!acquire_start_subscription_update_lock())
        return 1;

    status = prepare_subscription_caches("startup");
    if (status != 0) {
        log_message("Subscription caches are not ready. Aborted.", "fatal");
        return start_phase_failed("subscription-caches", status);
    }

    // Materialized list data is an explicit generation.  A source-backed
    // policy may not start from missing or invalid list data: that would
    // silently turn protected IP traffic into final/direct traffic.
    let has_list_sources = module_success(STATE_UC, [ "has-list-update-sources" ]);
    if (has_list_sources && !module_success(UPDATES_UC, [ "restore-list-cache" ])) {
        log_message("Preparing the initial list generation before starting routing", "info");
        if (!module_success(UPDATES_UC, [ "prepare-list-cache" ]) ||
            !module_success(UPDATES_UC, [ "restore-list-cache" ])) {
            log_message("No valid active list generation is available. Aborted rather than starting a partial routing policy.", "fatal");
            return 1;
        }
    }

    if (start_abandoned_for_stop("the nftables policy"))
        return 1;

    if (!nft_candidate_begin())
        return start_phase_failed("nft-candidate-begin", 1);
    status = nft_rebuild_runtime();
    if (status != 0) {
        nft_candidate_finish(false);
        return start_phase_failed("nft-rebuild", status);
    }

    status = module_status(SINGBOX_UC, [ "configure-service" ]);
    if (status != 0) {
        nft_candidate_finish(false);
        return start_phase_failed("sing-box-service-configure", status);
    }

    // The generator rebuilds local file references. Re-apply the complete
    // cached generation to both rule-set files and the freshly-created nft
    // table before sing-box validates/starts. A corrupt cache is fatal here;
    // silently starting with a partial routing policy is less safe.
    start_lists_complete = !has_list_sources;
    if (has_list_sources && (module_success(UPDATES_UC, [ "runtime-list-cache-active" ]) ||
        module_success(UPDATES_UC, [ "list-cache-valid" ]))) {
        status = module_status(UPDATES_UC, [ "apply-list-cache" ]);
        if (status != 0) {
            nft_candidate_finish(false);
            log_message("Persistent list cache could not be applied. Aborted.", "fatal");
            return start_phase_failed("active-list-generation", status);
        }
        start_lists_complete = true;
    }
    status = nft_populate_runtime_sets();
    if (status != 0) {
        nft_candidate_finish(false);
        return start_phase_failed("nft-runtime-sets", status);
    }
    if (!nft_candidate_finish(true)) {
        log_message("Candidate nftables policy could not be applied; the active policy was left unchanged", "fatal");
        return start_phase_failed("nft-candidate-apply", 1);
    }
    if (start_lists_complete)
        remove_file(RUNTIME_LISTS_PENDING_FILE);
    else
        write_file(RUNTIME_LISTS_PENDING_FILE, "start\n");

    status = singbox_init_config();
    if (status != 0)
        return start_phase_failed("sing-box-config", status);

    status = refresh_cron_reported("start");
    if (status != 0)
        return start_phase_failed("cron-refresh", status);

    if (start_abandoned_for_stop("sing-box"))
        return 1;

    module_success(BYEDPI_UC, [ "start-runtime" ]);

    status = start_sing_box_and_wait();
    if (status != 0) {
        log_message("sing-box did not reach a stable running state after start. Aborted.", "fatal");
        return status;
    }

    status = module_status(PRIORITY_UC, [ "start-runtime" ]);
    if (status != 0) {
        log_message("Failed to start Priority runtime. Aborted.", "fatal");
        return status;
    }

    status = module_status(SUBSCRIPTION_CACHE_UC, [ "run-deferred-bootstrap", subscription_deferred_sections ]);
    if (status != 0)
        return status;

    // The deferred bootstrap can download through sing-box for a while.
    if (start_abandoned_for_stop("the DPI providers"))
        return 1;

    release_start_subscription_update_lock();
    module_success(ZAPRET_UC, [ "start-runtime" ]);
    module_success(ZAPRET2_UC, [ "start-runtime" ]);

    return 0;
}

// A worker of its own (start_impl); an explicit stop terminates it
// (core/refresh_worker.uc).
function refresh_rulesets_after_start() {
    refresh_worker.register();
    let proxy_address = setting_bool("download_lists_via_proxy", false)
        ? SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + as_string(SB_SERVICE_MIXED_INBOUND_PORT)
        : "";
    let status = module_status(RULESET_CACHE_UC, [ "refresh-if-due", proxy_address ]);

    if (status == 0) {
        log_message("Rule-set cache changed; reloading Prokop", "info");
        command_status_from_args([ SERVICE_INIT, "reload", "ruleset-cache" ]);
    }
    else if (status != 1)
        log_message("Rule-set cache refresh failed", "warn");
    refresh_worker.unregister();
}

// An explicit start or restart has ended an earlier explicit stop before
// this runs (start(), restart()). A reload that restarts the runtime
// (restart_runtime_for_reload) ends none (D-15, UC-056): a stop request seen
// from here on keeps the runtime down, also one that waited for reload.lock
// while the reload held it.
function start_impl() {
    start_watches_stop_request = true;
    let status = start_main();
    if (status != 0)
        return status;

    if (start_abandoned_for_stop("dnsmasq"))
        return 1;

    if (!setting_bool("dont_touch_dhcp", false)) {
        status = dnsmasq_configure(false);
        if (status != 0)
            return status;
    }
    else if (dnsmasq_has_prokop_managed_state()) {
        status = dnsmasq_restore(true);
        if (status != 0)
            return status;
    }

    record_shutdown_state("0");

    status = module_status(STATE_UC, [
        "write-current-reload-state-clean",
        RELOAD_STATE_FILE,
        as_string(RELOAD_STATE_FORMAT),
        RULE_CONDITION_CACHE_DIR
    ]);
    if (status != 0)
        return status;
    keep_cron_refresh_pending(RELOAD_STATE_FILE);

    if (start_abandoned_for_stop("the DNS-failover and background workers"))
        return 1;

    status = module_status(DNS_FAILOVER_UC, [ "start-runtime" ]);
    if (status != 0) {
        log_message("Failed to start DNS failover runtime", "fatal");
        return status;
    }

    // A start without its list generation runs with empty list sets until
    // the list update's own "list-content" reload; refreshing the
    // kill-switch from it would replace a complete saved policy.
    if (start_lists_complete)
        killswitch_sync("start");
    else
        killswitch_sync_deferred("start");

    if (module_success(STATE_UC, [ "has-list-update-sources" ])) {
        // Serialize the two network workers. The rule-set refresh may reload
        // sing-box and must not tear down the service proxy during list I/O.
        write_file(RULESET_REFRESH_AFTER_LIST_FILE, "due\n");
        module_background(UPDATES_UC, [ "list-update-after-start" ]);
    }
    else {
        module_background(LIFECYCLE_UC, [ "refresh-rulesets-after-start" ]);
    }
    module_background(DIAGNOSTICS_UC, [ "get-system-info" ]);
    // The worker exits immediately when no persistent pending marker exists.
    // Scheduling it here guarantees that a reboot-interrupted test resumes
    // only after sing-box, Clash API, and the rest of Prokop are ready.
    module_background(DIAGNOSTICS_UC, [ "automatic-latency-test", "resume" ]);
    return 0;
}

function stop_main(explicit_stop) {
    let status = 0;

    // A reload or package transition must never tear down Prokop's DNS,
    // nftables and routing state before it has proved that the live sing-box
    // belongs to the managed procd service: this function removes the policy
    // before the controlled sing-box stop would reject ambiguous ownership,
    // so without this gate it could discard the fail-closed policy while an
    // unknown process stays alive. procd can also briefly report an old PID
    // while replacing its child; treat that unsettled observation exactly
    // like a foreign process and let the serialized caller retry.
    //
    // An explicit Stop is different: the user asked for interception to end.
    // Prokop's own nft table, ip rules and DNS need no proof of ownership and
    // go; of the sing-box processes only those proven to be Prokop's are
    // stopped, a sing-box of another program is left running (UC-213).
    let process_conflict = module_success(STATE_UC, [ "sing-box-process-conflict" ]);
    if (process_conflict && !explicit_stop) {
        log_message("Refusing Prokop stop: sing-box process ownership is ambiguous; preserving the existing runtime", "fatal");
        return 2;
    }
    if (process_conflict)
        log_message("Additional sing-box process detected; explicit Stop removes Prokop's interception and stops only the sing-box processes that Prokop owns", "warn");

    log_message("Stopping Prokop", "info");
    module_success(DNS_FAILOVER_UC, [ "stop-runtime" ]);
    module_success(PRIORITY_UC, [ "stop-runtime" ]);
    module_success(SUBSCRIPTION_CACHE_UC, [ "stop-deferred-bootstrap-worker" ]);
    module_success(UPDATES_UC, [ "stop-list-update" ]);
    remove_cron_jobs();
    // A newer list generation may intentionally live only in /tmp because
    // flash space was below the persistent-cache reserve. Keep it across an
    // in-boot service reload; a real reboot clears both /tmp and its marker.
    if (!module_success(UPDATES_UC, [ "runtime-list-cache-active" ]))
        command_success_from_args([ "find", TMP_RULESET_FOLDER, "-mindepth", "1", "-maxdepth", "1", "-type", "f", "-delete" ]);

    module_success(ZAPRET_UC, [ "stop-runtime" ]);
    module_success(ZAPRET2_UC, [ "stop-runtime" ]);
    module_success(BYEDPI_UC, [ "stop-runtime" ]);
    module_success(NFT_UC, [ "remove-dpi-transition-guard", NFT_TABLE_NAME ]);

    if (command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ]))
        command_success_from_args([ "nft", "delete", "table", "inet", NFT_TABLE_NAME ]);

    module_success(NFT_UC, [ "remove-tproxy-route-rule", RT_TABLE_NAME, NFT_FAKEIP_MARK ]);

    let sing_box_status = module_status(STATE_UC, [
        explicit_stop ? "stop-owned-sing-box-runtime" : "stop-managed-sing-box-runtime",
        getenv("PROKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15"
    ]);
    if (sing_box_status != 0)
        status = sing_box_status;

    return status;
}

function cleanup_failed_runtime() {
    let status = 0;

    log_message("Cleaning up Prokop runtime after failed start/reload", "info");

    let stop_status = stop_main(false);
    if (stop_status != 0)
        status = stop_status;

    let dns_status = dnsmasq_restore_fail_safe();
    if (dns_status != 0 && status == 0)
        status = dns_status;

    mark_runtime_stopped_clean();

    if (status != 0)
        log_message("Failed to fully clean up Prokop runtime after start/reload failure", "warn");

    return status;
}

function discard_dpi_snapshot() {
    if (dpi_snapshot_dir != "")
        command_success_from_args([ "rm", "-rf", dpi_snapshot_dir ]);
    dpi_snapshot_dir = "";
    dpi_switch_started = false;
    dpi_restart_plan = null;
    dpi_nft_rollback_file = "";
    dpi_nft_committed = false;
    dpi_singbox_backup = "";
}

function snapshot_dpi_runtime(plan) {
    if (plan.needs_zapret_restart != 1 && plan.needs_zapret2_restart != 1 && plan.needs_byedpi_restart != 1)
        return true;
    dpi_snapshot_dir = trim(command_output_from_args([ "mktemp", "-d" ]));
    if (dpi_snapshot_dir == "")
        return false;
    dpi_restart_plan = plan;
    let providers = [
        [ plan.needs_zapret_restart, ZAPRET_UC, "zapret" ],
        [ plan.needs_zapret2_restart, ZAPRET2_UC, "zapret2" ],
        [ plan.needs_byedpi_restart, BYEDPI_UC, "byedpi" ]
    ];
    for (let provider in providers) {
        if (provider[0] == 1 && module_status(provider[1], [ "snapshot-runtime", dpi_snapshot_dir + "/" + provider[2] + ".json" ]) != 0) {
            log_message("Could not snapshot the previous " + provider[2] + " runtime; preserving the live DPI processes", "fatal");
            discard_dpi_snapshot();
            return false;
        }
    }
    if (plan.needs_nft_rebuild == 1 && !(plan.changed_list == 1 && plan.needs_list_update == 1)) {
        let table_file = dpi_snapshot_dir + "/nft.table";
        dpi_nft_rollback_file = dpi_snapshot_dir + "/nft.rollback";
        if (system(command_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ]) + " >" + shell_quote(table_file)) != 0 ||
            !write_file(dpi_nft_rollback_file, "delete table inet " + NFT_TABLE_NAME + "\n") ||
            system("cat " + shell_quote(table_file) + " >>" + shell_quote(dpi_nft_rollback_file)) != 0 ||
            !module_success(NFT_UC, [ "nft-validate-candidate-batch", dpi_nft_rollback_file ])) {
            log_message("Could not prepare an atomic rollback of the previous nft table; preserving the live DPI processes", "fatal");
            discard_dpi_snapshot();
            return false;
        }
        remove_file(table_file);
    }
    return true;
}

function restore_dpi_runtime() {
    if (!dpi_switch_started || dpi_restart_plan == null)
        return true;
    let providers = [
        [ dpi_restart_plan.needs_zapret_restart, ZAPRET_UC, "zapret" ],
        [ dpi_restart_plan.needs_zapret2_restart, ZAPRET2_UC, "zapret2" ],
        [ dpi_restart_plan.needs_byedpi_restart, BYEDPI_UC, "byedpi" ]
    ];
    for (let provider in providers) {
        if (provider[0] == 1 && module_status(provider[1], [ "preflight-runtime", dpi_snapshot_dir + "/" + provider[2] + ".json" ]) != 0) {
            log_message("Previous " + provider[2] + " runtime cannot be restored; preserving the current runtime under the DPI guard", "fatal");
            return false;
        }
    }
    if (reload_gives_way_to_stop("the DPI rollback"))
        return false;
    if (dpi_nft_committed && dpi_nft_rollback_file != "") {
        if (system(command_from_args([ "nft", "-f", dpi_nft_rollback_file ])) != 0) {
            log_message("Failed to restore the previous nft table during DPI rollback", "fatal");
            return false;
        }
    }
    for (let provider in providers) {
        if (provider[0] == 1 && module_status(provider[1], [ "stop-owned-runtime" ]) != 0) {
            log_message("Could not safely stop the current " + provider[2] + " runtime; old runtime was not started", "fatal");
            return false;
        }
    }
    let restored = [];
    for (let provider in providers) {
        if (provider[0] != 1)
            continue;
        if (module_status(provider[1], [ "restore-runtime", dpi_snapshot_dir + "/" + provider[2] + ".json" ]) != 0) {
            log_message("Failed to restore the previous " + provider[2] + " runtime", "fatal");
            for (let previous in restored)
                if (module_status(previous[1], [ "stop-owned-runtime" ]) != 0)
                    log_message("Could not clean up partially restored " + previous[2] + " runtime", "fatal");
            return false;
        }
        push(restored, provider);
    }
    return true;
}

function switch_dpi_runtime(plan) {
    if (dpi_snapshot_dir == "")
        return 0;
    if (!module_success(NFT_UC, [ "install-dpi-transition-guard", NFT_TABLE_NAME ])) {
        log_message("Could not install the fail-closed DPI transition guard; preserving the previous runtime", "fatal");
        return 1;
    }
    dpi_guard_active = true;
    dpi_switch_started = true;
    let providers = [
        [ plan.needs_zapret_restart, ZAPRET_UC, "Zapret" ],
        [ plan.needs_zapret2_restart, ZAPRET2_UC, "Zapret2" ],
        [ plan.needs_byedpi_restart, BYEDPI_UC, "ByeDPI" ]
    ];
    for (let provider in providers) {
        if (provider[0] != 1)
            continue;
        let status = module_status(provider[1], [ "stop-runtime" ]);
        if (status != 0)
            return status;
        status = module_status(provider[1], [ "start-runtime" ]);
        if (status != 0) {
            log_message("Failed to start " + provider[2] + " runtime during reload", "fatal");
            return status;
        }
    }
    return 0;
}

// The reload gives way to a stop (reload_gives_way_to_stop): sing-box stays
// stopped, the fail-closed guards and the rest of the teardown are left to
// the stop, and nothing this reload prepared is kept. Not a failure: the next
// explicit start applies the whole configuration.
function abandon_reload_for_stop(stage_path, backup_path) {
    nft_candidate_finish(false);
    discard_singbox_config_stage(stage_path);
    if (as_string(backup_path) != "")
        remove_file(backup_path);
    if (dpi_singbox_backup != "")
        remove_file(dpi_singbox_backup);
    discard_dpi_snapshot();
    discard_dnsmasq_reload_config();
    remove_file(RELOAD_STATE_SNAPSHOT_FILE);
    dpi_guard_active = false;
    module_status(STATE_UC, [
        "stop-managed-sing-box-runtime",
        as_string(getenv("PROKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15")
    ]);
    return 0;
}

// A reload that failed before replacing the live sing-box config leaves the
// old sing-box running with its own config and section-cache: the workers it
// stopped go back to watching that runtime (LC-2).
function resume_reload_workers() {
    if (!reload_workers_stopped)
        return;
    reload_workers_stopped = false;
    if (reload_singbox_commit_started) {
        log_message("Priority and DNS failover stay stopped: the failed reload had already replaced the sing-box config; the next successful reload or restart starts them", "warn");
        return;
    }
    // sing_box_runtime_pid() is defined further down.
    let pid = module_capture(STATE_UC, [ "sing-box-service-runtime-pid" ]);
    if (pid.status != 0 || trim(pid.output) == "") {
        log_message("Priority and DNS failover stay stopped: sing-box is not running after the failed reload", "warn");
        return;
    }
    if (module_status(PRIORITY_UC, [ "start-runtime" ]) != 0)
        log_message("Could not restart the Priority runtime after a failed reload", "warn");
    if (module_status(DNS_FAILOVER_UC, [ "start-runtime" ]) != 0)
        log_message("Could not restart the DNS failover runtime after a failed reload", "warn");
}

function abort_reload(status, runtime_changed) {
    if (reload_gives_way_to_stop("its rollback"))
        return abandon_reload_for_stop("", "");
    status = int(status || 0);
    if (status == 0)
        status = 1;

    if (dpi_switch_started && !dpi_guard_active) {
        if (!module_success(NFT_UC, [ "install-dpi-transition-guard", NFT_TABLE_NAME ])) {
            log_message("Could not re-install the DPI guard for post-commit rollback; keeping the current runtime", "fatal");
            remove_file(RELOAD_STATE_SNAPSHOT_FILE);
            return status;
        }
        dpi_guard_active = true;
    }

    if (!restore_dnsmasq_reload_config()) {
        if (dpi_switch_started) {
            log_message("Could not restore the previous dnsmasq configuration; preserving the DPI guard and rollback snapshot " + dpi_snapshot_dir, "fatal");
            remove_file(RELOAD_STATE_SNAPSHOT_FILE);
            return status;
        }
        log_message("Could not restore the previous dnsmasq configuration; stopping the partial runtime", "fatal");
        if (dpi_singbox_backup != "")
            remove_file(dpi_singbox_backup);
        discard_dpi_snapshot();
        cleanup_failed_runtime();
        remove_file(RELOAD_STATE_SNAPSHOT_FILE);
        return status;
    }

    if (dpi_singbox_backup != "") {
        if (!module_success(NFT_UC, [ "install-transition-guard", NFT_TABLE_NAME, NFT_FAKEIP_MARK ]) ||
            !restore_guarded_singbox_runtime(dpi_singbox_backup, false)) {
            if (reload_stop_abandoned)
                return abandon_reload_for_stop("", "");
            log_message("Post-commit sing-box rollback failed; retaining the fail-closed transition guard", "fatal");
            remove_file(RELOAD_STATE_SNAPSHOT_FILE);
            return status;
        }
    }

    let dpi_rollback_attempted = dpi_switch_started;
    let dpi_restored = restore_dpi_runtime();
    if (!dpi_restored) {
        if (reload_stop_abandoned)
            return abandon_reload_for_stop("", "");
        log_message("DPI reload rollback failed; preserving the fail-closed guards and rollback snapshot " + dpi_snapshot_dir, "fatal");
        remove_file(RELOAD_STATE_SNAPSHOT_FILE);
        return status;
    }
    if (dpi_singbox_backup != "" && dpi_nft_rollback_file == "" &&
        !module_success(NFT_UC, [ "remove-transition-guard", NFT_TABLE_NAME, NFT_FAKEIP_MARK ])) {
        log_message("Could not remove the sing-box transition guard after rollback", "fatal");
        remove_file(RELOAD_STATE_SNAPSHOT_FILE);
        return status;
    }
    if (dpi_guard_active && !module_success(NFT_UC, [ "remove-dpi-transition-guard", NFT_TABLE_NAME ])) {
        log_message("Could not remove the DPI transition guard after rollback", "fatal");
        remove_file(RELOAD_STATE_SNAPSHOT_FILE);
        return status;
    }
    dpi_guard_active = false;
    discard_dpi_snapshot();

    if (runtime_changed && !(dpi_rollback_attempted && dpi_restored))
        cleanup_failed_runtime();
    else {
        remove_file(RELOAD_STATE_SNAPSHOT_FILE);
        resume_reload_workers();
    }

    return status;
}

function abort_reload_after_dns_failure(status) {
    return abort_reload(status, false);
}

// A transition that failed before commit-config-stage made its backup left
// the live config untouched; sing-box may still be stopped for the commit.
function restart_uncommitted_singbox() {
    let pid = module_capture(STATE_UC, [ "sing-box-service-runtime-pid" ]);
    if (pid.status == 0 && trim(pid.output) != "")
        return true;
    if (reload_gives_way_to_stop("the sing-box restart"))
        return false;
    log_message("Starting the previous sing-box again: the failed transition never replaced its config", "warn");
    return module_status(STATE_UC, [
        "start-managed-sing-box-runtime",
        as_string(getenv("PROKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15")
    ]) == 0 && module_status(STATE_UC, [
        "wait-prokop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(SING_BOX_START_STABLE_MIN_AGE),
        as_string(SING_BOX_START_VERIFY_TIMEOUT)
    ]) == 0;
}

function abort_guarded_transition(status, stage_path, backup_path, guard_active) {
    nft_candidate_finish(false);
    discard_singbox_config_stage(stage_path);
    // commit-config-stage copies the live config to the backup before it
    // writes anything, so without a backup the live config and section-cache
    // are still the old generation.
    reload_singbox_commit_started = fs.stat(backup_path) != null;

    if (reload_gives_way_to_stop("its rollback"))
        return abandon_reload_for_stop("", backup_path);

    if (!guard_active)
        return abort_reload(status, false);

    // If the live config was never committed, the old runtime is still
    // coherent and the temporary packet guard can be removed directly. A
    // backup exists only after commit-config-stage has copied the old config.
    if (fs.stat(backup_path) == null) {
        // The old sing-box may already have been stopped for the commit; it
        // comes back on its unchanged config before the guard is lifted.
        if (!restart_uncommitted_singbox()) {
            if (reload_stop_abandoned)
                return abandon_reload_for_stop("", backup_path);
            log_message("The previous sing-box did not come back after a failed transition; retaining the fail-closed nft guard", "fatal");
            remove_file(RELOAD_STATE_SNAPSHOT_FILE);
            return status == 0 ? 1 : status;
        }
        if (module_success(NFT_UC, [
            "remove-transition-guard",
            NFT_TABLE_NAME,
            NFT_FAKEIP_MARK
        ]))
            return abort_reload(status, false);
    }

    if (fs.stat(backup_path) != null && restore_guarded_singbox_runtime(backup_path, true))
        return abort_reload(status, false);
    if (reload_stop_abandoned)
        return abandon_reload_for_stop("", backup_path);

    // Do not call cleanup_failed_runtime here. The guard intentionally stays
    // in the old table and drops classified traffic until an operator/retry can
    // restore a coherent pair; tearing down the table would create a direct
    // leak window.
    log_message("Cross-component transition rollback failed; retaining the fail-closed nft guard", "fatal");
    remove_file(RELOAD_STATE_SNAPSHOT_FILE);
    return status == 0 ? 1 : status;
}

// A start refused before it built anything leaves dnsmasq as it was. After a
// boot that is still the forwarding to sing-box the last run committed, and
// without a running sing-box the LAN has no DNS (LC-1): hand DNS back to
// dnsmasq unless a Prokop runtime is in fact up.
function restore_dns_after_refused_start() {
    if (module_success(STATE_UC, [ "prokop-running", RT_TABLE_NAME, NFT_TABLE_NAME, NFT_FAKEIP_MARK ]))
        return;
    if (dnsmasq_restore(false) != 0)
        log_message("Could not hand DNS back to dnsmasq after the refused start", "warn");
}

function start_inner() {
    clear_start_failure();
    // A current installer/updater may have recorded one exact, procd-owned
    // pre-upgrade process. Wait only for that process to exit; a legacy direct
    // opkg/apk upgrade has no marker and remains fail-closed below.
    if (fs.stat(MANAGED_UPGRADE_SING_BOX_MARKER) != null &&
        !module_success(STATE_UC, [
            "wait-managed-upgrade-sing-box-exit",
            MANAGED_UPGRADE_SING_BOX_MARKER,
            as_string(MANAGED_UPGRADE_SING_BOX_WAIT_SECONDS),
            as_string(MANAGED_UPGRADE_SING_BOX_MARKER_MAX_AGE_SECONDS)
        ])) {
        log_message("Refusing Prokop start: managed upgrade sing-box provenance did not resolve safely", "fatal");
        release_start_subscription_update_lock();
        restore_dns_after_refused_start();
        return 1;
    }

    // A second sing-box is not safely attributable from its executable name.
    // Do not turn this detection into a stop/restart cycle: that could remove
    // the old working nft policy while an orphan remains alive.
    if (module_success(STATE_UC, [ "sing-box-process-conflict" ])) {
        log_message("Refusing Prokop start: sing-box process ownership is ambiguous; preserving the existing runtime", "fatal");
        release_start_subscription_update_lock();
        restore_dns_after_refused_start();
        return 1;
    }

    // The DPI guard of a failed DPI rollback is a table of its own: a start
    // leaves it in place, and it would go on dropping DPI traffic under a
    // runtime reported as started (UC-019). Only a restart removes it.
    if (command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME + "DpiGuard" ])) {
        log_message("Refusing Prokop start: a failed transition kept the fail-closed DPI guard (runtime_guard_active); restart Prokop to recover", "fatal");
        mark_start_failure_not_retryable("runtime_guard_active");
        release_start_subscription_update_lock();
        restore_dns_after_refused_start();
        return 1;
    }

    // A package install can queue a second start while the first one is
    // building its runtime. initd serializes both with reload.lock; once the
    // second call acquires it, accept only the complete, sole procd-owned
    // runtime. Never adopt a partial runtime or bypass the ownership guards.
    if (module_success(STATE_UC, [
        "prokop-stably-running",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE)
    ])) {
        // This fork retains a drop guard when a coordinated rollback fails.
        // Table/route readiness alone must not report that state as recovered.
        // A cold start rebuilds the production table and the chain with it.
        if (command_success_from_args([
            "nft", "list", "chain", "inet", NFT_TABLE_NAME, "prokop_transition_guard"
        ])) {
            log_message("Refusing duplicate Prokop start: the failed-transition guard is still active (runtime_guard_active); preserving the fail-closed runtime; restart Prokop to recover", "fatal");
            release_start_subscription_update_lock();
            return 1;
        }
        // Nor while the guard of a restore or an autotune apply that ended
        // needs_attention drops DPI traffic: this start starts nothing, and
        // only a restore of a snapshot releases that guard
        // (config/snapshots.uc). A cold start builds the runtime under it.
        if (command_success_from_args([ "nft", "list", "table", "inet", "ProkopConfigRestoreDpiGuard" ])) {
            log_message("Refusing duplicate Prokop start: the DPI guard of an unfinished configuration restore is still active (runtime_guard_active); restore the last known working snapshot to recover", "fatal");
            release_start_subscription_update_lock();
            return 1;
        }
        log_message("Prokop is already stably running; treating duplicate start as successful", "info");
        release_start_subscription_update_lock();
        return 0;
    }

    let status = start_impl();
    release_start_subscription_update_lock();

    if (status != 0) {
        cleanup_failed_runtime();
        return status;
    }

    mark_pending_reload_if_config_changed(startup_config_fingerprint, "config_changed_during_start");

    status = module_status(STATE_UC, [
        "wait-prokop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE),
        "8"
    ]);
    if (status != 0) {
        log_message("Startup verification failed after Prokop was started; rolling back DNS changes", "warn");
        cleanup_failed_runtime();
        return status;
    }

    // Latency values live in sing-box's runtime and are lost on a real reboot.
    // Queue a fresh pass only after the complete Prokop runtime has passed its
    // startup verification.  schedule-automatic-latency-test coalesces an
    // existing marker, so this also safely continues a test interrupted by a
    // reboot instead of starting a competing worker.
    let config_path = config_get(CONFIG_NAME + ".settings.config_path", "");
    let proxy_signature = trim(module_output(DIAGNOSTICS_UC, [
        "proxy-outbounds-signature", config_path
    ]));
    if (proxy_signature == "") {
        log_message("Automatic latency test was not scheduled at startup because no testable proxy outbounds were found", "info");
    }
    else if (!module_success(UPDATES_UC, [ "schedule-automatic-latency-test", proxy_signature ])) {
        log_message("Automatic latency test could not be scheduled at startup", "warn");
    }
    else {
        module_background(DIAGNOSTICS_UC, [ "automatic-latency-test", "new" ]);
    }

    return 0;
}

// pid + start ticks (core/process_identity.uc): a marker that a killed start
// left behind does not make the UI report a start that is not running
// (UC-014).
function mark_start_in_progress() {
    return process_identity.record(START_IN_PROGRESS_FILE, owner_pid());
}

// Also when the start then fails: a runtime that is down after an explicit
// start is repaired by a reload.
function mark_explicit_start() {
    ensure_dir(RUNTIME_STATE_DIR);
    let now = clock();
    return write_file(EXPLICIT_START_FILE, sprintf("%d.%09d.%s\n", now[0], now[1], owner_pid()));
}

function start() {
    // Neither recorded as an explicit start nor ending an explicit stop.
    if (legacy_start_refused("start"))
        return 1;
    // The init.d UI action can fail to register when a stop has only just
    // completed. Track the actual lifecycle worker independently of UI jobs.
    mark_start_in_progress();
    // An explicit start ends an explicit stop, also when it finds the
    // runtime already running and does not start it again.
    mark_explicit_start();
    remove_file(STOP_REQUESTED_FILE);
    let status = start_inner();
    remove_file(START_IN_PROGRESS_FILE);
    return status;
}

// Set by a stop that found the router run by the product before the rename:
// nothing of Prokop was torn down, so nothing shared is put back either.
let stop_left_to_legacy = false;

function stop_impl(explicit_stop) {
    let status = 0;

    stop_left_to_legacy = false;
    if (legacy_runtime_owns_router()) {
        log_message("Prokop has no runtime to stop; the running " + legacy.PRODUCT + " and its DNS settings are left alone", "info");
        stop_left_to_legacy = true;
        return 0;
    }

    // A refused stop changes nothing, and DNS stays with the runtime that
    // still serves traffic: refuse before DNS is restored (UC-215).
    if (!explicit_stop && module_success(STATE_UC, [ "sing-box-process-conflict" ])) {
        log_message("Refusing Prokop stop: sing-box process ownership is ambiguous; preserving the existing runtime", "fatal");
        return 2;
    }

    if (!setting_bool("dont_touch_dhcp", false)) {
        let dns_status = dnsmasq_restore(false);
        if (dns_status != 0)
            status = dns_status;
    }
    else if (dnsmasq_has_prokop_managed_state()) {
        let dns_status = dnsmasq_restore(true);
        if (dns_status != 0)
            status = dns_status;
    }

    let runtime_status = stop_main(explicit_stop);
    // Ownership changed after the check above: the dataplane is untouched,
    // but DNS was restored already. That is a failed stop, not a refusal
    // that left everything as it was.
    if (runtime_status == 2) {
        dnsmasq_restore_fail_safe();
        return 1;
    }
    if (runtime_status != 0)
        status = runtime_status;

    mark_runtime_stopped_clean();

    if (status != 0)
        dnsmasq_restore_fail_safe();

    return status;
}

// Who asked for the stop (PROKOP_STOP_SOURCE): Prokop itself for a package
// or component change, or the user; as service/initd.uc stop_request_source.
// Prokop's own stop comes through init.d, which has recorded it before and
// cancelled a start deferred after the user's stop: what it recorded tells
// that case.
function stop_request_source() {
    let source = as_string(getenv("PROKOP_STOP_SOURCE"));
    if (source != "package" && source != "component")
        return "user";
    let previous = fs.readfile(STOP_REQUESTED_FILE);
    if (previous == null)
        return source;
    let by = match(previous, /(^|\n)by=([a-z]*)/);
    return by == null || by[2] == "user" ? "user" : source;
}

// The stop is part of a managed upgrade in progress: its marker is fresh.
// A failed or refused in-app upgrade can leave the marker behind. A stale
// one names no transition, and start_inner would refuse the next start over
// it, so it is removed (UC-217).
function managed_upgrade_in_progress() {
    if (fs.stat(MANAGED_UPGRADE_SING_BOX_MARKER) == null)
        return false;
    if (module_success(STATE_UC, [ "managed-upgrade-marker-fresh", MANAGED_UPGRADE_SING_BOX_MARKER,
        as_string(MANAGED_UPGRADE_SING_BOX_MARKER_MAX_AGE_SECONDS) ]))
        return true;
    log_message("Removing a stale managed upgrade marker: no upgrade is in progress", "info");
    remove_file(MANAGED_UPGRADE_SING_BOX_MARKER);
    return false;
}

// Puts back what a refused stop recorded over (null: there was no file).
function restore_file(path, content) {
    if (content == null)
        remove_file(path);
    else
        write_file(path, content);
}

// Also recorded by service/initd.uc before it waits for reload.lock; here for
// a `prokop stop` that does not come through init.d. The stop also revokes
// what would otherwise bring the runtime back or change it later: the
// rule-set refresh workers, whose final reload is such a trigger, and the
// reloads queued for the runtime it takes down (the next start applies the
// whole configuration). Reloads requested from now on are skipped
// (reload_skipped_after_stop; D-15, UC-056). The user's stop also ends the
// explicit start; Prokop's own stop for a package or component change keeps
// it for the start that follows.
function stop() {
    // The UI button and a plain init.d stop are explicit shutdowns: they end
    // Prokop's interception and stop the sing-box that Prokop owns.
    // Prokop's own stop for a package or component change
    // (PROKOP_STOP_SOURCE, an upgrade in progress) keeps the ownership
    // guard, because it brings the same runtime back up afterwards. Its
    // refusal changes nothing: no stop request, no ended explicit start, no
    // stopped refresh workers, no DNS change (UC-215, UC-217). A component
    // change whose own stop already took the runtime down has nothing left
    // to keep (PROKOP_STOP_CLEANUP, components/action.uc): its next stop ends
    // what that runtime left as an explicit one does, still as Prokop's own
    // stop. A managed upgrade in progress keeps the guard.
    let requested_by = as_string(getenv("PROKOP_STOP_SOURCE"));
    let cleanup_stop = requested_by == "component" && getenv("PROKOP_STOP_CLEANUP") == "1";
    let internal_stop = requested_by == "package" || (requested_by == "component" && !cleanup_stop) ||
        getenv("PROKOP_INTERNAL_SERVICE_STOP") == "1" || managed_upgrade_in_progress();
    if (internal_stop && module_success(STATE_UC, [ "sing-box-process-conflict" ])) {
        log_message("Refusing Prokop stop: sing-box process ownership is ambiguous; preserving the existing runtime", "fatal");
        return 2;
    }

    ensure_dir(RUNTIME_STATE_DIR);
    let previous_request = fs.readfile(STOP_REQUESTED_FILE);
    let previous_start = fs.readfile(EXPLICIT_START_FILE);
    let now = clock();
    let source = stop_request_source();
    write_file(STOP_REQUESTED_FILE, sprintf("%d.%09d.%s\nby=%s\n", now[0], now[1], owner_pid(), source));
    if (source == "user")
        remove_file(EXPLICIT_START_FILE);
    if (refresh_worker.stop_all(LIB_DIR) > 0)
        log_message("Stopped the rule-set refresh", "info");
    let status = stop_impl(!internal_stop);
    // Refused by a later check (ownership changed meanwhile): the runtime
    // was not torn down and runs on without a stop request.
    if (status == 2) {
        restore_file(STOP_REQUESTED_FILE, previous_request);
        restore_file(EXPLICIT_START_FILE, previous_start);
        return 2;
    }
    remove_file(PENDING_RELOAD_FILE);
    // The runtime is down: br_netfilter's iptables hooks go back to what
    // they were before Prokop's start, where nothing else has set them
    // since (D-19, UC-109). Lifecycle's own restart and a reload keep them
    // off; /etc/init.d/prokop restart is a stop and a start, so it puts
    // them back while TPROXY is down and its start turns them off again.
    if (status == 0 && !stop_left_to_legacy && !module_success(NFT_UC, [ "restore-bridge-netfilter" ]))
        log_message("Could not restore the br_netfilter settings", "warn");
    return status;
}

function restart_runtime_for_reload() {
    let status;
    if (legacy_start_refused("reload restart"))
        return 1;
    let selector_state = capture_selector_state();

    log_message("Reload requires a full Prokop runtime restart", "info");

    status = stop_main(false);
    if (status != 0)
        return status;

    status = start_impl();
    if (status != 0) {
        cleanup_failed_runtime();
        return status;
    }

    status = module_status(STATE_UC, [
        "wait-prokop-stable-start",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE),
        "8"
    ]);
    if (status != 0) {
        log_message("Reload runtime restart verification failed after Prokop was started; rolling back DNS changes", "fatal");
        cleanup_failed_runtime();
        return status;
    }

    restore_selector_state(selector_state);
    remove_file(RELOAD_STATE_SNAPSHOT_FILE);
    return 0;
}

function write_service_trigger_sync_state(changed) {
    ensure_dir(RUNTIME_STATE_DIR);
    write_file(SERVICE_TRIGGER_SYNC_FILE, as_string(changed) + "\n");
}

function parse_reload_plan(output) {
    let result = {
        changed_service_triggers: 0,
        changed_dnsmasq: 0,
        changed_sing_box: 0,
        changed_nft: 0,
        changed_zapret_queue: 0,
        changed_zapret_runtime: 0,
        changed_zapret2_queue: 0,
        changed_zapret2_runtime: 0,
        changed_byedpi_runtime: 0,
        changed_cron: 0,
        changed_list: 0,
        needs_sing_box_reload: 0,
        needs_nft_rebuild: 0,
        needs_zapret_restart: 0,
        needs_zapret2_restart: 0,
        needs_byedpi_restart: 0,
        needs_dnsmasq_configure: 0,
        needs_dnsmasq_restore: 0,
        needs_cron_refresh: 0,
        needs_list_update: 0,
        has_work: 0
    };

    for (let line in split(as_string(output), "\n")) {
        line = as_string(line);
        if (line == "")
            continue;
        let fields = split(line, "\t");
        if (length(fields) < 2)
            continue;
        let key = fields[0];
        if (result[key] != null)
            result[key] = int(fields[1] || 0);
    }

    return result;
}

function append_reload_action(actions, enabled, label) {
    if (!(enabled === true || int(enabled || 0) == 1))
        return actions;
    return actions + (actions != "" ? ", " : "") + label;
}

function reload_actions_summary(plan) {
    let actions = "";
    actions = append_reload_action(actions, plan.needs_sing_box_reload, "sing-box");
    actions = append_reload_action(actions, plan.needs_nft_rebuild, "nftables");
    actions = append_reload_action(actions, plan.needs_zapret_restart, "Zapret");
    actions = append_reload_action(actions, plan.needs_zapret2_restart, "Zapret2");
    actions = append_reload_action(actions, plan.needs_byedpi_restart, "ByeDPI");
    actions = append_reload_action(actions, plan.needs_dnsmasq_configure || plan.needs_dnsmasq_restore, "dnsmasq");
    actions = append_reload_action(actions, plan.needs_cron_refresh, "scheduled jobs");
    actions = append_reload_action(actions, plan.needs_list_update, "remote lists");
    return actions;
}

// init.d queues every reload that finds reload.lock held (service/initd.uc):
// the DNS-failover apply, the last holder those reloads saw, applies them
// once it lets the lock go, as the list worker does (components/updates.uc).
// Otherwise a reload queued behind the apply, a UI reload job's among them,
// waits for an unrelated later reload or start (UC-061).
function release_reload_lock() {
    module_success(STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR, owner_pid() ]);
    if (fs.stat(PENDING_RELOAD_FILE) != null)
        module_success(STATE_UC, [ "run-pending-reload-if-requested", PENDING_RELOAD_FILE, SERVICE_INIT ]);
}

function sing_box_runtime_pid() {
    let result = module_capture(STATE_UC, [ "sing-box-service-runtime-pid" ]);
    return result.status == 0 ? trim(result.output) : "";
}

function wait_dns_failover_state(candidate_state_path, attempts) {
    attempts = int(attempts || 1);
    for (let i = 0; i < attempts; i++) {
        let status = module_status(DNS_FAILOVER_UC, [ "verify-state", candidate_state_path ]);
        if (status == 0)
            return 0;
        if (i + 1 < attempts)
            command_success_from_args([ "sleep", "1" ]);
    }
    return 1;
}

// Checked under reload.lock before the apply takes sing-box down (UC-012).
function runtime_apply_allowed() {
    return module_success(STATE_UC, [ "runtime-apply-allowed", NFT_TABLE_NAME ]);
}

// Once the apply holds sing-box stopped under reload.lock, only a stop
// request keeps it down; a transient nft error must not.
function stop_requested() {
    return fs.stat(STOP_REQUESTED_FILE) != null;
}

// Runs as a child of the DNS-failover worker; a stop TERMs only the worker, so
// this apply can still be at work when the stop proceeds. It never starts
// sing-box once a stop was requested or Prokop is down.
function dns_failover_apply(candidate_state_path) {
    candidate_state_path = as_string(candidate_state_path);
    if (candidate_state_path == "" || fs.stat(candidate_state_path) == null)
        return 1;

    if (!module_success(STATE_UC, [ "acquire-runtime-dir-lock-wait", RELOAD_LOCK_DIR, owner_pid(), "2" ]))
        return 2;

    if (!runtime_apply_allowed()) {
        log_message("DNS failover switch skipped: Prokop is stopped or stopping", "info");
        release_reload_lock();
        return 1;
    }

    // Do not publish config.json while a vendor-provided init script can be
    // watching it. Its watcher is outside Prokop's ownership and can otherwise
    // race our controlled replacement with a second procd start.
    let transition_timeout = as_string(getenv("PROKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15");
    if (module_status(STATE_UC, [ "stop-managed-sing-box-runtime", transition_timeout ]) != 0) {
        release_reload_lock();
        return 1;
    }

    let patch_result = module_capture(SINGBOX_UC, [ "patch-dns-config", candidate_state_path ]);
    if (patch_result.status != 0) {
        if (!stop_requested())
            module_success(STATE_UC, [ "start-managed-sing-box-runtime", transition_timeout ]);
        release_reload_lock();
        return patch_result.status;
    }

    let fields = split(trim(patch_result.output), "\t");
    let changed = as_string(fields[0]) == "1";
    let backup_path = length(fields) > 1 ? as_string(fields[1]) : "";
    let status = 0;
    let stopping = stop_requested();

    if (stopping) {
        log_message("Prokop is stopping; the DNS failover switch was abandoned and sing-box stays stopped", "info");
        status = 1;
    }
    else if (changed) {
        status = module_status(STATE_UC, [ "start-managed-sing-box-runtime", transition_timeout ]);
        if (status == 0)
            status = wait_dns_failover_state(candidate_state_path, 8);
    }
    else {
        status = module_status(STATE_UC, [ "start-managed-sing-box-runtime", transition_timeout ]);
    }

    if (status == 0 && !module_success(DNS_FAILOVER_UC, [ "commit-state", candidate_state_path ]))
        status = 1;

    if (status != 0 && backup_path != "") {
        if (!stopping)
            log_message("DNS failover apply failed; restoring the previous sing-box configuration", "error");
        if (module_success(STATE_UC, [ "stop-managed-sing-box-runtime", transition_timeout ]) &&
            module_success(SINGBOX_UC, [ "restore-dns-config", backup_path ]) &&
            !stop_requested())
            module_success(STATE_UC, [ "start-managed-sing-box-runtime", transition_timeout ]);
    }

    if (backup_path != "")
        remove_file(backup_path);
    release_reload_lock();
    return status;
}

// A reload never starts a runtime that an explicit stop took down, whoever
// requests it: background work that began before the stop (UC-012), a manual
// reload, a snapshot restore, an autotune apply. Only an explicit start
// brings it back (D-15, UC-056). Nor does it start a runtime that nobody
// started since boot (no EXPLICIT_START_FILE; D-15(a)). A runtime that went
// down after an explicit start (it crashed, its start failed) is still
// repaired by the reload. A stop requested while the reload is in progress
// stops it before its next start step (reload_gives_way_to_stop).
// service/initd.uc decides the same before it opens a UI job; this is the
// check under reload.lock.
function reload_skipped_after_stop(reason) {
    reason = as_string(reason || "");
    let stopped = fs.stat(STOP_REQUESTED_FILE) != null;
    if ((!stopped && fs.stat(EXPLICIT_START_FILE) != null) ||
        module_success(STATE_UC, [ "prokop-running", RT_TABLE_NAME, NFT_TABLE_NAME, NFT_FAKEIP_MARK ]))
        return false;
    log_message("Reload '" + reason + (stopped ? "' skipped: Prokop was stopped; only a start brings its runtime back" :
        "' skipped: Prokop was not started since boot; only a start starts it"), "info");
    return true;
}

function reload(reason) {
    reason = as_string(reason || "");
    // A completed list generation whose final runtime apply failed is safe to
    // retry locally. Never let a later generic/pending reload skip that
    // generation or trigger a second network update.
    if (reason != "list-content" && fs.stat(LIST_UPDATE_RELOAD_FILE) != null) {
        log_message("A committed list generation is pending runtime apply; performing a local list-content reload", "info");
        reason = "list-content";
    }
    // The plan below compares configurations only. Over a kept guard a DPI
    // restart would fail at the create-only install every time, and any
    // other plan would report success while the guard still drops traffic
    // (UC-019). A reload of an incomplete runtime plans nothing: it restarts
    // the runtime (restart_runtime_for_reload), whose stop removes the guard
    // as the restart named for recovery does, so it goes on.
    let restart_under_guard = false;
    if (runtime_guard_kept()) {
        if (module_success(STATE_UC, [ "prokop-running", RT_TABLE_NAME, NFT_TABLE_NAME, NFT_FAKEIP_MARK ])) {
            log_message("Reload '" + reason + "' refused: a failed transition kept the fail-closed guard (runtime_guard_active); restart Prokop to recover", "fatal");
            return 1;
        }
        log_message("Reload '" + reason + "': the runtime is incomplete and a failed transition kept its fail-closed guard; the runtime restart removes the guard", "info");
        restart_under_guard = true;
    }
    let status;
    // This remains false until a complete nft transaction was accepted or a
    // sing-box process reload was requested. Candidate preparation and its
    // check/apply failures have not changed the live policy.
    let runtime_changed = false;
    let force_runtime_reload = reason == "on_config_change" ? 0 : 1;
    ensure_clash_api_secret();
    let reload_config_fingerprint = external_config_fingerprint();
    rule_condition_cache_enabled = force_runtime_reload;

    log_message("Reloading Prokop", "info");
    module_success(LIB_DIR + "/config/snapshots.uc", [ "create", "automatic" ]);

    status = validate_start_config();
    if (status != 0)
        return status;

    status = module_status(SUBSCRIPTION_CACHE_UC, [ "ensure-runtime-dirs" ]);
    if (status != 0)
        return status;

    // This gate must precede every reload-state capture and candidate nft
    // operation. A reload can otherwise rebuild the live dataplane before a
    // later sing-box transition notices that procd ownership is unsettled.
    // Preserve the coherent runtime until ownership has converged instead.
    if (module_success(STATE_UC, [ "sing-box-process-conflict" ])) {
        log_message("Reload refused: multiple or non-procd sing-box processes were detected; preserving the existing runtime", "fatal");
        return finish_reload_status(1, reload_config_fingerprint);
    }

    if (!module_success(STATE_UC, [ "prokop-running", RT_TABLE_NAME, NFT_TABLE_NAME, NFT_FAKEIP_MARK ]) || restart_under_guard) {
        log_message("Runtime state is incomplete; restarting Prokop runtime", "info");
        return finish_reload_status(restart_runtime_for_reload(), reload_config_fingerprint);
    }

    remove_file(RELOAD_STATE_SNAPSHOT_FILE);
    status = module_status(STATE_UC, [
        "capture-reload-state",
        RELOAD_STATE_SNAPSHOT_FILE,
        as_string(RELOAD_STATE_FORMAT)
    ]);
    if (status != 0)
        return status;

    let current_reload_state_file = trim(command_output_from_args([ "mktemp" ]));
    if (current_reload_state_file == "")
        return abort_reload(1, false);

    status = module_status(STATE_UC, [
        "write-captured-reload-state",
        current_reload_state_file,
        RELOAD_STATE_SNAPSHOT_FILE,
        as_string(RELOAD_STATE_FORMAT),
        "",
        "0",
        "0"
    ]);
    if (status != 0) {
        remove_file(current_reload_state_file);
        return abort_reload(status, false);
    }

    let dnsmasq_managed_state = dnsmasq_has_prokop_managed_state() ? 1 : 0;
    let list_update_sources = module_success(STATE_UC, [ "has-list-update-sources" ]) ? 1 : 0;
    let nft_list_update_sources = module_success(STATE_UC, [ "has-nft-list-update-sources" ]) ? 1 : 0;
    let runtime_cache_needs_rebuild = 0;
    if (as_string(getenv("PROKOP_RUNTIME_CACHE_INVALIDATED") || "0") == "1" ||
        module_success(SUBSCRIPTION_CACHE_UC, [ "runtime-cache-needs-rebuild", SECTION_CACHE_DIR ]))
        runtime_cache_needs_rebuild = 1;

    let plan_result = module_capture(RELOAD_UC, [
        "plan-state-files",
        RELOAD_STATE_FILE,
        current_reload_state_file,
        as_string(force_runtime_reload),
        as_string(dnsmasq_managed_state),
        as_string(list_update_sources),
        as_string(nft_list_update_sources),
        as_string(runtime_cache_needs_rebuild)
    ]);
    remove_file(current_reload_state_file);

    if (plan_result.status != 0) {
        if (plan_result.status == 2) {
            log_message("Reload state is unavailable; restarting Prokop runtime", "info");
            return finish_reload_status(restart_runtime_for_reload(), reload_config_fingerprint);
        }
        return abort_reload(plan_result.status, false);
    }

    let plan = parse_reload_plan(plan_result.output);
    // A changed source must first become a complete active generation. Do not
    // publish a freshly rebuilt table without its replacement list data.
    if (reason == "list-content") {
        plan.has_work = 1;
        plan.needs_nft_rebuild = 1;
        plan.needs_list_update = 0;
        plan.changed_list = 0;
    }
    write_service_trigger_sync_state(plan.changed_service_triggers);

    if (plan.has_work == 0) {
        status = module_status(STATE_UC, [
            "write-captured-reload-state",
            RELOAD_STATE_FILE,
            RELOAD_STATE_SNAPSHOT_FILE,
            as_string(RELOAD_STATE_FORMAT),
            RULE_CONDITION_CACHE_DIR,
            "1",
            "1"
        ]);
        if (status == 0) {
            log_message("Reload skipped: runtime-relevant configuration is unchanged", "info");
            // Only a subscription section's kill-switch is in the plan.
            killswitch_sync("reload");
            // Nor is the autotune schedule (UC-115): a change of only
            // autotune.mode plans nothing else.
            sync_autotune_cron("cron-sync");
        }
        return finish_reload_status(status, reload_config_fingerprint);
    }

    let actions = reload_actions_summary(plan);
    if (actions != "")
        log_message("Applying reload changes: " + actions, "info");

    if (!snapshot_dpi_runtime(plan))
        return abort_reload(1, false);

    // A staged config and a checked nft batch must both exist before the
    // first live transition. The old sing-box process keeps its in-memory
    // config while this preparation runs.
    let staged_singbox_config = "";
    let staged_singbox_backup = "";
    let transition_guard_active = false;
    let needs_singbox_transition = plan.needs_sing_box_reload == 1 &&
        !(plan.needs_list_update == 1 && plan.changed_list == 1);
    let sing_box_config_path = "";
    let sing_box_config_hash_before = "";
    let sing_box_pid_before = "";
    reload_workers_stopped = false;
    reload_singbox_commit_started = false;
    if (needs_singbox_transition) {
        module_success(DNS_FAILOVER_UC, [ "stop-runtime" ]);
        module_success(PRIORITY_UC, [ "stop-runtime" ]);
        reload_workers_stopped = true;
        status = module_status(SINGBOX_UC, [ "configure-service" ]);
        if (status != 0)
            return abort_reload(status, false);
        sing_box_config_path = config_get(CONFIG_NAME + ".settings.config_path", "");
        sing_box_config_hash_before = file_md5(sing_box_config_path);
        sing_box_pid_before = sing_box_runtime_pid();
        staged_singbox_config = trim(command_output_from_args([ "mktemp" ]));
        staged_singbox_backup = trim(command_output_from_args([ "mktemp" ]));
        if (staged_singbox_config == "" || staged_singbox_backup == "") {
            discard_singbox_config_stage(staged_singbox_config);
            remove_file(staged_singbox_backup);
            return abort_reload(1, false);
        }
        // mktemp creates the backup path, while commit-config-stage requires
        // copying the live config itself before it is changed.
        remove_file(staged_singbox_backup);
        status = singbox_prepare_config_stage(staged_singbox_config);
        if (status != 0) {
            discard_singbox_config_stage(staged_singbox_config);
            return abort_reload(status, false);
        }
    }

    if (plan.needs_nft_rebuild == 1 && !(plan.changed_list == 1 && plan.needs_list_update == 1)) {
        log_message("Rebuilding nftables rules", "info");
        if (!nft_candidate_begin())
            return abort_reload(1, false);
        status = nft_rebuild_runtime();
        if (status != 0) {
            nft_candidate_finish(false);
            return abort_reload(status, runtime_changed);
        }
        // A local policy change must reconstruct downloaded subnet data from
        // the already active generation.  It is deliberately synchronous and
        // offline: list_update is reserved for a changed source signature.
        if ((plan.needs_list_update == 1 && plan.changed_list == 0) || reason == "list-content") {
            status = module_status(UPDATES_UC, [ "apply-list-cache" ]);
            if (status != 0) {
                nft_candidate_finish(false);
                log_message("Active list generation could not be restored after nft rebuild. Aborted to preserve fail-safe policy.", "fatal");
                return abort_reload(status, runtime_changed);
            }
        }
        // Inline/source-aware sets are part of the same candidate, not a
        // post-commit append. List-derived elements above use the active
        // generation and are recorded in this very batch as well.
        status = nft_populate_runtime_sets();
        if (status != 0) {
            nft_candidate_finish(false);
            discard_singbox_config_stage(staged_singbox_config);
            if (status == 0)
                log_message("Candidate nftables policy failed validation or apply; active policy was left unchanged", "fatal");
            return abort_reload(status == 0 ? 1 : status, runtime_changed);
        }
        // When sing-box also changes, retain this checked candidate until the
        // new process is ready behind the temporary fail-closed guard.
        if ((needs_singbox_transition || dpi_snapshot_dir != "") && !nft_candidate_validate()) {
            nft_candidate_finish(false);
            discard_singbox_config_stage(staged_singbox_config);
            log_message("Candidate nftables policy failed validation; active policy was left unchanged", "fatal");
            return abort_reload(1, runtime_changed);
        }
    }

    if (!needs_singbox_transition) {
        if (reload_gives_way_to_stop("the DPI providers and the nft table"))
            return abandon_reload_for_stop("", "");
        status = switch_dpi_runtime(plan);
        if (status != 0) {
            nft_candidate_finish(false);
            return abort_reload(status, false);
        }
        if (nft_candidate_batch_file != "" && !nft_candidate_finish(true, false)) {
            log_message("Candidate nftables policy failed validation or apply; restoring the previous DPI runtime", "fatal");
            return abort_reload(1, false);
        }
        if (dpi_nft_rollback_file != "")
            dpi_nft_committed = true;
        if (dpi_guard_active && !module_success(NFT_UC, [ "remove-dpi-transition-guard", NFT_TABLE_NAME ]))
            return abort_reload(1, runtime_changed);
        dpi_guard_active = false;
        if (plan.needs_nft_rebuild == 1 && !(plan.changed_list == 1 && plan.needs_list_update == 1))
            runtime_changed = true;
    }

    if (plan.needs_sing_box_reload == 1 && plan.needs_list_update == 1 && plan.changed_list == 1) {
        // The list worker owns one final reload after every source has been
        // processed. Avoid applying an intermediate config with stale files.
        write_file(LIST_UPDATE_RELOAD_FILE, "1\n");
    }
    else if (needs_singbox_transition) {
        // The guard is installed atomically in the existing table after
        // mangle marking and before TPROXY. It is the only unavoidable
        // cross-component window: protected packets are dropped, never sent
        // to a process with a different routing generation.
        if (!module_success(NFT_UC, [ "install-transition-guard", NFT_TABLE_NAME, NFT_FAKEIP_MARK ]))
            return abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, false);
        transition_guard_active = true;
        if (module_status(STATE_UC, [
            "stop-managed-sing-box-runtime",
            as_string(getenv("PROKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15")
        ]) != 0)
            return abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        if (!module_success(SINGBOX_UC, [ "commit-config-stage", staged_singbox_config, staged_singbox_backup ]))
            return abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        if (reload_gives_way_to_stop("sing-box"))
            return abandon_reload_for_stop(staged_singbox_config, staged_singbox_backup);
        status = module_status(STATE_UC, [
            "start-managed-sing-box-runtime",
            as_string(getenv("PROKOP_SING_BOX_RELOAD_PID_TIMEOUT") || "15")
        ]);
        if (status != 0)
            return abort_guarded_transition(status, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        status = module_status(STATE_UC, [
            "wait-prokop-stable-start",
            RT_TABLE_NAME,
            NFT_TABLE_NAME,
            NFT_FAKEIP_MARK,
            as_string(SING_BOX_START_STABLE_MIN_AGE),
            as_string(SING_BOX_START_VERIFY_TIMEOUT)
        ]);
        if (status != 0) {
            log_message("Reload verification failed after sing-box was reloaded; restoring the previous coherent runtime", "fatal");
            return abort_guarded_transition(status, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        }
        if (reload_gives_way_to_stop("Priority"))
            return abandon_reload_for_stop(staged_singbox_config, staged_singbox_backup);
        status = module_status(PRIORITY_UC, [ "start-runtime" ]);
        if (status != 0) {
            log_message("Failed to start Priority runtime after sing-box reload", "fatal");
            return abort_guarded_transition(status, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        }
        if (reload_gives_way_to_stop("DNS failover"))
            return abandon_reload_for_stop(staged_singbox_config, staged_singbox_backup);
        status = module_status(DNS_FAILOVER_UC, [ "start-runtime" ]);
        if (status != 0) {
            log_message("Failed to restart DNS failover runtime after sing-box reload", "fatal");
            return abort_guarded_transition(status, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        }
        reload_workers_stopped = false;
        if (reload_gives_way_to_stop("the DPI providers and the nft table"))
            return abandon_reload_for_stop(staged_singbox_config, staged_singbox_backup);
        status = switch_dpi_runtime(plan);
        if (status != 0)
            return abort_guarded_transition(status, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        if (nft_candidate_batch_file != "" && !nft_candidate_finish(true, true))
            return abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        if (dpi_nft_rollback_file != "")
            dpi_nft_committed = true;
        if (nft_candidate_batch_file == "" && !module_success(NFT_UC, [ "remove-transition-guard", NFT_TABLE_NAME, NFT_FAKEIP_MARK ]))
            return abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        if (dpi_guard_active && !module_success(NFT_UC, [ "remove-dpi-transition-guard", NFT_TABLE_NAME ]))
            return abort_guarded_transition(1, staged_singbox_config, staged_singbox_backup, transition_guard_active);
        dpi_guard_active = false;
        transition_guard_active = false;
        if (dpi_snapshot_dir != "")
            dpi_singbox_backup = staged_singbox_backup;
        else
            remove_file(staged_singbox_backup);
        runtime_changed = true;
    }

    if (reload_gives_way_to_stop("dnsmasq and the scheduled jobs"))
        return abandon_reload_for_stop("", "");

    if ((plan.needs_dnsmasq_configure == 1 || plan.needs_dnsmasq_restore == 1) &&
        !snapshot_dnsmasq_reload_config())
        return abort_reload(1, false);

    if (plan.needs_dnsmasq_configure == 1) {
        status = dnsmasq_configure(true);
        if (status != 0)
            return abort_reload_after_dns_failure(status);
        module_success(STATE_UC, [ "capture-reload-state", RELOAD_STATE_SNAPSHOT_FILE, as_string(RELOAD_STATE_FORMAT) ]);
    }
    else if (plan.needs_dnsmasq_restore == 1) {
        status = dnsmasq_restore(true);
        if (status != 0)
            return abort_reload_after_dns_failure(status);
        module_success(STATE_UC, [ "capture-reload-state", RELOAD_STATE_SNAPSHOT_FILE, as_string(RELOAD_STATE_FORMAT) ]);
    }

    if (plan.needs_cron_refresh == 1) {
        status = refresh_cron_reported("reload");
        if (status != 0)
            return abort_reload(status, false);
    }
    // The autotune schedule is outside the cron signature: a restored
    // snapshot or `uci set ...autotune.mode` with a reload changes it too
    // (UC-115). cron-sync writes the crontab only when its line changes;
    // refresh_cron above runs it as well.
    else
        sync_autotune_cron("cron-sync");

    status = finish_reload_status(module_status(STATE_UC, [
        "write-captured-reload-state",
        RELOAD_STATE_FILE,
        RELOAD_STATE_SNAPSHOT_FILE,
        as_string(RELOAD_STATE_FORMAT),
        RULE_CONDITION_CACHE_DIR,
        "1",
        "1"
    ]), reload_config_fingerprint);
    if (status != 0)
        return abort_reload(status, runtime_changed);
    keep_cron_refresh_pending(RELOAD_STATE_FILE);
    if (dpi_singbox_backup != "")
        remove_file(dpi_singbox_backup);
    discard_dpi_snapshot();
    discard_dnsmasq_reload_config();
    // A changed list source left the nft rebuild to the list worker's
    // list-content reload: until then the live table is the previous one
    // under the new rule order, and that reload refreshes the kill-switch
    // (UC-209).
    if (plan.changed_list == 1 && plan.needs_list_update == 1) {
        write_file(RUNTIME_LISTS_PENDING_FILE, "reload\n");
        killswitch_sync_deferred(reason == "" ? "reload" : "reload " + reason);
    }
    else {
        if (plan.needs_nft_rebuild == 1)
            remove_file(RUNTIME_LISTS_PENDING_FILE);
        killswitch_sync(reason == "" ? "reload" : "reload " + reason);
    }

    // Clear the durable retry request only after the complete local apply
    // committed its reload state. A failed candidate/guarded transition
    // returns above and deliberately leaves the marker intact.
    if (reason == "list-content")
        remove_file(LIST_UPDATE_RELOAD_FILE);

    // A stop requested meanwhile has terminated the workers it found; no new
    // one comes after it (D-15, UC-056): the next start runs them.
    if (fs.stat(STOP_REQUESTED_FILE) != null)
        return 0;

    // Background workers may update UCI selector state or materialized list
    // files immediately. Start them only after the reload snapshot and config
    // fingerprint have been committed, otherwise Prokop mistakes its own
    // runtime updates for a concurrent user edit and queues another reload.
    if (plan.changed_list == 1 && plan.needs_list_update == 1)
        write_file(RULESET_REFRESH_AFTER_LIST_FILE, "force\n");
    if (plan.needs_list_update == 1 && plan.changed_list == 1)
        module_background(UPDATES_UC, [ "list-update" ]);

    // Refresh persistent remote rule sets only when their source signature
    // changed. Local routing edits must stay entirely offline. The refresh
    // worker compares content and requests one reload only when cache bytes
    // actually changed.
    if (plan.changed_list == 1) {
        if (plan.needs_list_update != 1) {
            module_success(UPDATES_UC, [ "invalidate-list-cache" ]);
            module_background(RULESET_CACHE_UC, [
                "refresh-and-reload",
                setting_bool("download_lists_via_proxy", false) ? SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + as_string(SB_SERVICE_MIXED_INBOUND_PORT) : ""
            ]);
        }
    }

    return 0;
}

function reload_tracked(reason) {
    // Nothing was reloaded: no UI job of its own and no health record. A job
    // that init.d opened completes without waiting for the stopped runtime
    // (service/ui.uc). A kill-switch that no section has any more is lifted
    // all the same (UC-208); init.d holds reload.lock for this reload.
    if (reload_skipped_after_stop(reason)) {
        module_success(KILLSWITCH_UC, [ "follow-stopped-config", reason, "reload-lock-held" ]);
        return 0;
    }

    // A reload that gave way to a stop is recorded as neither.
    if (as_string(getenv("PROKOP_UI_ACTION_TRACKED") || "0") == "1") {
        let status = reload(reason);
        if (!reload_stop_abandoned)
            module_success(LIB_DIR + "/diagnostics/health.uc", [ "record", "reload", status == 0 ? "success" : "failure" ]);
        return status;
    }

    let job_id = trim(module_output(UI_UC, [ "service-action-begin-if-idle", "reload", "runtime_reload" ]));
    if (job_id != "")
        module_success(UI_UC, [ "service-action-update-pid", job_id, owner_pid() ]);

    let status = reload(reason);
    if (!reload_stop_abandoned)
        module_success(LIB_DIR + "/diagnostics/health.uc", [ "record", "reload", status == 0 ? "success" : "failure" ]);
    if (job_id != "")
        module_success(UI_UC, [ "service-action-finish-after-command", "reload", job_id, as_string(status) ]);

    return status;
}

function reload_reason_fixture(reason) {
    reason = as_string(reason || "");
    if (reason != "list-content" && fs.stat(LIST_UPDATE_RELOAD_FILE) != null)
        reason = "list-content";
    print(reason, "\n");
}

function restart() {
    if (legacy_start_refused("restart"))
        return 1;
    log_message("Restarting Prokop", "info");

    // Do not let any restart caller bypass the same ownership check as cold
    // start. In particular, delayed startup recovery must never stop an
    // unknown runtime merely to make room for Prokop.
    if (module_success(STATE_UC, [ "sing-box-process-conflict" ])) {
        log_message("Refusing Prokop restart: sing-box process ownership is ambiguous; preserving the existing runtime", "fatal");
        return 1;
    }

    let selector_state = capture_selector_state();
    let status = stop_impl(false);
    if (status != 0)
        return status;

    // An explicit restart is an explicit start: it ends an earlier explicit
    // stop.
    mark_explicit_start();
    remove_file(STOP_REQUESTED_FILE);
    status = start_impl();
    if (status != 0) {
        cleanup_failed_runtime();
        return status;
    }

    if (module_success(STATE_UC, [
        "prokop-stably-running",
        RT_TABLE_NAME,
        NFT_TABLE_NAME,
        NFT_FAKEIP_MARK,
        as_string(RUNTIME_STABLE_MIN_AGE)
    ])) {
        restore_selector_state(selector_state);
        return 0;
    }

    log_message("Restart verification failed after Prokop was started; stopping Prokop runtime", "fatal");
    cleanup_failed_runtime();
    return 1;
}

function enable_service() {
    return command_status_from_args([ SERVICE_INIT, "enable" ]);
}

function disable_service() {
    return command_status_from_args([ SERVICE_INIT, "disable" ]);
}

// `prokop start|stop|reload|restart` (main as well) run under reload.lock
// (LC-3). service/initd.uc takes it around them for init.d, the UI, procd
// triggers and every internal caller, so this process runs under the lock of
// an ancestor. Run from the command line it takes the lock itself: a start or
// reload that never gets it changes nothing and fails, and a stop goes on
// without it after the same wait as service/initd.uc stop_service (the work
// that holds the lock gives way to the stop request the stop writes). A stop
// that service/initd.uc already let go without the lock does not wait again
// (PROKOP_RELOAD_LOCK_WAIVED).
const CLI_RELOAD_LOCK_WAIT_SECONDS = getenv("PROKOP_CLI_RELOAD_LOCK_WAIT_SECONDS") || "30";
let cli_reload_lock_held = false;

function reload_lock_held_by_caller() {
    let owner = runtime_lock.owner(RELOAD_LOCK_DIR);
    if (owner == "")
        return false;
    let pid = owner_pid();
    for (let depth = 0; depth < 16 && pid != "" && pid != "0"; depth++) {
        if (pid == owner)
            return true;
        pid = process_identity.parent_pid(pid);
    }
    return false;
}

function acquire_cli_reload_lock(mode) {
    if (reload_lock_held_by_caller())
        return true;
    if (mode == "stop" && getenv("PROKOP_RELOAD_LOCK_WAIVED") == "1")
        return true;
    if (module_success(STATE_UC, [ "acquire-runtime-dir-lock-wait", RELOAD_LOCK_DIR, owner_pid(), CLI_RELOAD_LOCK_WAIT_SECONDS ])) {
        cli_reload_lock_held = true;
        return true;
    }
    if (mode == "stop") {
        log_message("Prokop stop did not get the runtime lock within " + CLI_RELOAD_LOCK_WAIT_SECONDS +
            " s; stopping without it, the work that holds it will not start the runtime again", "warn");
        return true;
    }
    let message = "Prokop " + mode + " refused: another start, stop, reload or update held the runtime lock for " +
        CLI_RELOAD_LOCK_WAIT_SECONDS + " s; nothing was changed. Try again, or run " + SERVICE_INIT + " " +
        (mode == "main" ? "start" : mode) + ", which waits or queues it";
    log_message(message, "error");
    warn(message + "\n");
    return false;
}

// A reload that init.d queued while this process held the lock runs once it
// is released, as service/initd.uc reload_finish does.
function release_cli_reload_lock(mode, status) {
    if (!cli_reload_lock_held)
        return;
    cli_reload_lock_held = false;
    module_success(STATE_UC, [ "release-runtime-dir-lock", RELOAD_LOCK_DIR, owner_pid() ]);
    if (status == 0 && mode != "stop" && fs.stat(PENDING_RELOAD_FILE) != null)
        module_success(STATE_UC, [ "run-pending-reload-if-requested", PENDING_RELOAD_FILE, SERVICE_INIT ]);
}

let mode = ARGV[0] || "";
let status = 1;
let cli_lock_mode = mode == "start" || mode == "main" || mode == "stop" || mode == "reload" || mode == "restart";

if (cli_lock_mode && !acquire_cli_reload_lock(mode)) {
    release_start_subscription_update_lock();
    exit(1);
}

// "main" is kept as a compatibility alias of start. It must take the same
// gated path: start_main() alone rebuilds the live nftables policy without
// the ownership and failed-transition checks of start_inner() (UC-015).
if (mode == "start" || mode == "main") {
    status = start();
    // start() ends an earlier explicit stop: a stop request now was made
    // during this start, and a start it abandoned or cut short did not fail
    // (UC-012). The stop records nothing either.
    // A start that keeps failing is retried with a backoff
    // (service/initd.uc start_retry_delay): its history on flash records the
    // first failure of the series, not each retry (LC-4).
    let failed_retry = status != 0 &&
        match(as_string(fs.readfile(START_RETRY_FILE)), /(^|\n)reason=(start_failed|wan_retry_failed)(\n|$)/) != null;
    if ((status == 0 || fs.stat(STOP_REQUESTED_FILE) == null) && !failed_retry)
        module_success(LIB_DIR + "/diagnostics/health.uc", [ "record", "start", status == 0 ? "success" : "failure" ]);
    if (status == 0)
        confirm_working_config(startup_config_fingerprint);
}
else if (mode == "stop")
    status = stop();
else if (mode == "reload")
    status = reload_tracked(ARGV[1] || "");
else if (mode == "reload-reason-fixture") {
    reload_reason_fixture(ARGV[1] || "");
    status = 0;
}
else if (mode == "dns-failover-apply")
    status = dns_failover_apply(ARGV[1] || "");
else if (mode == "restart")
    status = restart();
else if (mode == "refresh-rulesets-after-start") {
    refresh_rulesets_after_start();
    status = 0;
}
else if (mode == "enable")
    status = enable_service();
else if (mode == "disable")
    status = disable_service();
else if (mode == "selector-state-from-proxies-fixture") {
    write_json(selector_state_from_proxies_payload(read_json_file(ARGV[1])));
    status = 0;
}
else if (mode == "selector-restore-pairs-fixture") {
    write_json(selector_restore_pairs(read_json_file(ARGV[1]), read_json_file(ARGV[2])));
    status = 0;
}
else if (mode == "dnsmasq-restore" || mode == "restore-dnsmasq")
    status = dnsmasq_restore_fail_safe();
else {
    warn("Usage: service/lifecycle.uc <start|stop|reload|restart|main|enable|disable|dnsmasq-restore|uninstall> ...\n");
    status = 1;
}

release_start_subscription_update_lock();
if (cli_lock_mode)
    release_cli_reload_lock(mode, status);
exit(status);
