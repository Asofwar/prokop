#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let legacy = require("core.legacy_forkop");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = env("PROKOP_CONFIG_NAME", "prokop");
const CONFIG_PATH = env("PROKOP_CONFIG_PATH", "/etc/config/prokop");
const DEFAULT_CONFIG_PATH = env("PROKOP_DEFAULT_CONFIG_PATH", "/usr/share/prokop/defaults/prokop");
const RT_TABLES_PATH = env("PROKOP_RT_TABLES", "/etc/iproute2/rt_tables");
const BIN_PATH = env("PROKOP_BIN", "/usr/bin/prokop");
const INIT_PATH = env("PROKOP_INIT", "/etc/init.d/prokop");
const LIB_DIR = env("PROKOP_LIB", "/usr/lib/prokop");
const DNS_APPLY_UC = env("PROKOP_DNS_APPLY_UC", "/usr/lib/prokop/dns/apply.uc");
const KILLSWITCH_UC = env("PROKOP_KILLSWITCH_UC", "/usr/lib/prokop/killswitch/runtime.uc");
const SING_BOX_INIT = env("PROKOP_SING_BOX_INIT", "/etc/init.d/sing-box");
const SING_BOX_BIN = env("PROKOP_SING_BOX_BIN", "/usr/bin/sing-box");
const SING_BOX_CRONET = env("PROKOP_SING_BOX_CRONET", "/usr/lib/libcronet.so");
const SING_BOX_MANAGED_MARKER = env("SB_MANAGED_SERVICE_MARKER", "Prokop managed sing-box service for binary variants");
const PACKAGE_UPGRADE_STATE = env("PROKOP_PACKAGE_UPGRADE_STATE", "/tmp/prokop-package-was-running");
const UPGRADE_SING_BOX_WAIT_SECONDS = int(env("PROKOP_UPGRADE_SING_BOX_WAIT_SECONDS", "15"));
// The start after an upgrade runs while the package manager holds its lock;
// a slow cold start must not hold the package operation up for the start's
// full timeout. The start carries on after this bound, logs its outcome and
// schedules its own retry.
const POSTINST_START_WAIT_SECONDS = env("PROKOP_POSTINST_START_WAIT_SECONDS", "60");
const PROC_DIR = env("PROKOP_PROC_DIR", "/proc");
const COMPONENT_UPDATE_CHECK_CACHE_DIR = env("PROKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR", "/var/run/prokop/component-update-checks");
const COMPONENT_UPDATE_CHECK_STATE_FILE = env("PROKOP_COMPONENT_UPDATE_CHECK_STATE_FILE", "/var/run/prokop/component-update-check.timestamp");
const PACKAGE_TEST_MODE = env("PROKOP_PACKAGE_TEST_MODE", "") != "";
// Root prefix for the retired VPN fail-closed guard's paths (tests only).
const LEGACY_GUARD_ROOT = env("PROKOP_LEGACY_GUARD_ROOT", "");
const LEGACY_GUARD_TABLE = "ForkopVpnGuard";
const LEGACY_GUARD_SERVICE = "forkop-guard";
const LEGACY_GUARD_FIREWALL_INCLUDE = "firewall.forkop_vpn_guard";
const LEGACY_GUARD_OFFLOAD_KEYS = [ "flow_offloading", "flow_offloading_hw" ];

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

function command_success_from_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

// Status and standard output (stderr discarded).
function command_capture_from_args(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return { status: 1, output: "" };
    let output = as_string(pipe.read("all"));
    return { status: normalize_status(pipe.close()), output };
}

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function path_basename(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, slash + 1) : path;
}

// A package replacement renames the executable link of an already running
// sing-box to "sing-box (deleted)". That process still holds the runtime, so
// the upgrade must keep counting it instead of concluding it has exited.
function sing_box_exe_path(path) {
    let basename = path_basename(path);
    return basename == "sing-box" || basename == "sing-box (deleted)";
}

function sing_box_process_count() {
    let count = 0;
    for (let exe_path in fs.glob(PROC_DIR + "/[0-9]*/exe"))
        if (sing_box_exe_path(as_string(fs.readlink(exe_path))))
            count++;
    return count;
}

function wait_for_upgrade_sing_box_exit() {
    let timeout = UPGRADE_SING_BOX_WAIT_SECONDS;

    // prerm stops the old service, but its sing-box child exits asynchronously.
    // postinst would otherwise reach the guarded start while that process is
    // still present, and the start refuses an ambiguous runtime by design -
    // leaving Prokop stopped after an ordinary package upgrade. Wait for the
    // process to leave on its own; never kill anything by name.
    while (sing_box_process_count() > 0) {
        if (timeout <= 0)
            return false;
        command_success_from_args([ "sleep", "1" ]);
        timeout--;
    }

    return true;
}

function unlink_if_exists(path) {
    if (path_exists(path))
        fs.unlink(as_string(path));
}

function clear_component_update_check_cache() {
    for (let path in fs.glob(COMPONENT_UPDATE_CHECK_CACHE_DIR + "/*"))
        unlink_if_exists(path);
    unlink_if_exists(COMPONENT_UPDATE_CHECK_STATE_FILE);
}

// The entry of the product before the rename (core/legacy_forkop.uc), which
// a migration or its old package removal may have left. It names the same
// table id, so `ip rule` would show Prokop's rule under the old name. It is
// the old product's own while that package is installed.
function legacy_rt_tables_line(line) {
    let fields = split(trim(as_string(line)), /[ \t]+/);
    return length(fields) >= 2 && fields[0] == legacy.RT_TABLE_ID && fields[1] == legacy.RT_TABLE_NAME;
}

function remove_rt_tables_entry() {
    let data = fs.readfile(RT_TABLES_PATH);
    if (data == null)
        return true;

    let strip_legacy = !legacy.installed();
    let changed = false;
    let lines = [];
    for (let line in split(data, "\n")) {
        if (index(line, "105 prokop") >= 0 || (strip_legacy && legacy_rt_tables_line(line))) {
            changed = true;
            continue;
        }
        push(lines, line);
    }

    return !changed || fs.writefile(RT_TABLES_PATH, join("\n", lines)) != null;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function truthy(value) {
    value = ascii_lower(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function dont_touch_dhcp_enabled() {
    return truthy(uci_core.get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

function restore_dnsmasq_if_needed() {
    if (dont_touch_dhcp_enabled())
        return;

    command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);
    if (path_exists(DNS_APPLY_UC))
        command_success_from_args([ "ucode", DNS_APPLY_UC, "failsafe-restore" ]);
}

// A managed service script the product before the rename wrote is Prokop's
// once that package is gone (a migration that did not rewrite its marker).
function managed_sing_box_script(data) {
    if (data == null)
        return false;
    if (index(data, SING_BOX_MANAGED_MARKER) >= 0)
        return true;
    return !legacy.installed() && index(data, legacy.SING_BOX_MANAGED_MARKER) >= 0;
}

function remove_managed_sing_box() {
    let data = fs.readfile(SING_BOX_INIT);
    if (!managed_sing_box_script(data))
        return;

    command_success_from_args([ SING_BOX_INIT, "stop" ]);
    command_success_from_args([ SING_BOX_INIT, "disable" ]);
    unlink_if_exists(SING_BOX_INIT);
    unlink_if_exists(SING_BOX_BIN);
    unlink_if_exists(SING_BOX_CRONET);
}

function remember_upgrade_state(action) {
    // An explicit removal is unambiguous: nothing should be restored later.
    if (as_string(action) == "remove") {
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
        return;
    }

    // opkg invokes prerm without an action argument on some OpenWrt 24 builds,
    // including an ordinary version upgrade. Treating an empty action as "not
    // an upgrade" erased the only hand-off telling postinst to restart a
    // service that prerm had just stopped, so the router came back with Prokop
    // down. Service state is authoritative here: record a restart only when
    // Prokop was actually running immediately before prerm, or a start
    // deferred for reload.lock was still to run: the stop below cancels it.
    if (command_success_from_args([ INIT_PATH, "status" ]) ||
        command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/initd.uc", "deferred-start-pending" ]))
        fs.writefile(PACKAGE_UPGRADE_STATE, "1\n");
    else
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
}

function prerm_cleanup(action) {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    remember_upgrade_state(action);
    if (!PACKAGE_TEST_MODE) {
        // Prokop's own stop for the package change, not the user's
        // (service/initd.uc stop_request_source).
        command_success_from_args([ "env", "PROKOP_STOP_SOURCE=package", INIT_PATH, "stop" ]);
        // No start follows a removal: the explicit start ends with it, and
        // a reinstall that does not start Prokop shows it not started, not
        // as a start that failed (service/initd.uc EXPLICIT_START_FILE;
        // D-15(a)).
        if (as_string(action) == "remove")
            command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/initd.uc", "clear-explicit-start" ]);
        // An upgrade keeps the kill-switch: protected traffic must stay
        // blocked while the old runtime is down. Only a removal lifts it,
        // since nothing would be left to manage the persistent policy.
        if (as_string(action) == "remove" && path_exists(KILLSWITCH_UC))
            command_success_from_args([ "ucode", "-L", LIB_DIR, KILLSWITCH_UC, "disable", "package removal" ]);
        restore_dnsmasq_if_needed();
        remove_managed_sing_box();
    }
    return remove_rt_tables_entry();
}

function read_json_or_null(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

// The per-section kill-switch replaced the global VPN fail-closed guard
// (ForkopVpnGuard, /etc/init.d/forkop-guard). An upgrade removes the guard's
// files, but not what it left running or changed: its procd service with the
// standby dnsmasq instances and watcher, the DNS redirect in its nft table
// (after the old prerm's stop all client DNS goes to those instances), the
// firewall include and the disabled flow offload. Undo all of it here, before
// Prokop is started again. config/migration.uc carries its protection over to
// the sections.
function legacy_vpn_guard_cleanup() {
    let root = LEGACY_GUARD_ROOT;
    let state_dir = root + "/etc/forkop/vpn-guard";
    let runtime_dir = root + "/tmp/forkop-vpn-guard";
    let init_script = root + "/etc/init.d/" + LEGACY_GUARD_SERVICE;
    let has_table = command_success_from_args([ "sh", "-c", "nft list table inet " + LEGACY_GUARD_TABLE + " >/dev/null 2>&1" ]);
    let has_include = uci_core.exists(LEGACY_GUARD_FIREWALL_INCLUDE);
    if (!has_table && !has_include && !path_exists(state_dir) && !path_exists(runtime_dir) && !path_exists(init_script))
        return true;

    // Saved offload values live only in the guard's policy snapshot; old
    // versions kept them in the firewall include section.
    let saved = {};
    let policy = read_json_or_null(state_dir + "/policy.json");
    if (type(policy) == "object" && type(policy.saved_offload) == "object")
        saved = policy.saved_offload;
    for (let key in LEGACY_GUARD_OFFLOAD_KEYS)
        if (saved[key] == null && has_include)
            saved[key] = uci_core.get(LEGACY_GUARD_FIREWALL_INCLUDE + ".saved_" + key);

    command_success_from_args([ "ubus", "call", "service", "delete", sprintf("%J", { name: LEGACY_GUARD_SERVICE }) ]);
    let rc_dir = root + "/etc/rc.d";
    for (let name in (fs.lsdir(rc_dir) || []))
        if (match(name, /^[SK][0-9]+forkop-guard$/) != null)
            fs.unlink(rc_dir + "/" + name);

    // The guard's forward rejects stay until the first successful kill-switch
    // sync replaces them (killswitch/runtime.uc), so an upgrade never leaves
    // a window without protection. Only its client DNS redirect goes now:
    // the standby resolvers it pointed to were just stopped.
    if (has_table)
        command_success_from_args([ "sh", "-c", "nft flush chain inet " + LEGACY_GUARD_TABLE + " dns >/dev/null 2>&1; true" ]);
    // DNS flows already redirected to the stopped standby keep their NAT.
    command_success_from_args([ "sh", "-c", "conntrack -D -p udp --dport 53 >/dev/null 2>&1; conntrack -D -p tcp --dport 53 >/dev/null 2>&1; true" ]);

    let firewall_changed = false;
    for (let key in LEGACY_GUARD_OFFLOAD_KEYS) {
        if (as_string(saved[key]) == "1" && as_string(uci_core.get("firewall.@defaults[0]." + key)) != "1") {
            uci_core.set("firewall.@defaults[0]." + key, "1");
            firewall_changed = true;
        }
    }
    if (has_include) {
        uci_core.delete(LEGACY_GUARD_FIREWALL_INCLUDE);
        firewall_changed = true;
    }
    if (firewall_changed) {
        uci_core.commit("firewall");
        command_success_from_args([ "sh", "-c", "[ ! -x /etc/init.d/firewall ] || /etc/init.d/firewall reload >/dev/null 2>&1" ]);
    }

    command_success_from_args([ "rm", "-rf", state_dir, runtime_dir ]);
    for (let path in [ init_script, root + "/etc/hotplug.d/iface/95-forkop-guard",
        root + "/lib/upgrade/keep.d/forkop-guard", root + "/usr/share/forkop/vpn-guard-firewall.sh" ])
        unlink_if_exists(path);
    return true;
}

// Zapret-Manager launchers that Prokop wrote for another mirror, a former
// upstream one among them, would keep running the script from that host:
// they follow the current mirror setting again (components/action.uc).
function reconcile_zapret_manager_launchers() {
    let module = LIB_DIR + "/components/action.uc";
    if (path_exists(module) &&
        !command_success_from_args([ "ucode", "-L", LIB_DIR, module, "reconcile-zapret-manager-launchers" ]))
        warn("Unable to update the Zapret-Manager launchers for the current mirror setting.\n");
}

// What the product before the rename left once its package is gone: the
// retired VPN guard and the policy routing table entry. Nothing while that
// package is installed: Prokop's package is installed next to it during a
// migration, which must be able to roll back to it untouched. The installer
// runs this again after it has removed the old package.
function legacy_cleanup() {
    if (legacy.installed())
        return true;
    let ok = legacy_vpn_guard_cleanup();
    let data = fs.readfile(RT_TABLES_PATH);
    if (data != null) {
        let lines = filter(split(data, "\n"), (line) => !legacy_rt_tables_line(line));
        if (length(lines) != length(split(data, "\n")) && fs.writefile(RT_TABLES_PATH, join("\n", lines)) == null)
            ok = false;
    }
    return ok;
}

function postinst_restore() {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    clear_component_update_check_cache();
    legacy_cleanup();
    reconcile_zapret_manager_launchers();

    let config = fs.readfile(CONFIG_PATH);
    if (config == null || trim(as_string(config)) == "") {
        let defaults = fs.readfile(DEFAULT_CONFIG_PATH);
        if (defaults == null || trim(as_string(defaults)) == "") {
            warn("Unable to restore missing Prokop configuration: packaged defaults are unavailable.\n");
            return false;
        }
        if (fs.writefile(CONFIG_PATH, defaults) == null ||
            !command_success_from_args([ "chmod", "0644", CONFIG_PATH ])) {
            warn("Unable to restore missing Prokop configuration.\n");
            return false;
        }
    }

    if (!uci_core.load(CONFIG_NAME) || !uci_core.exists(CONFIG_NAME + ".settings")) {
        warn("Prokop configuration is invalid or unavailable to UCI.\n");
        return false;
    }

    // Only an explicit start since boot lets a reload start a runtime that
    // is down (service/initd.uc EXPLICIT_START_FILE; D-15(a)), and a previous
    // version kept no record of its start. A runtime that runs across the
    // upgrade (no prerm stopped it) was started explicitly; so was Prokop
    // that ran before the upgrade, whose restart below is an explicit start
    // also when it does not come or fails.
    let initd_module = LIB_DIR + "/service/initd.uc";
    if (!path_exists(PACKAGE_UPGRADE_STATE)) {
        command_success_from_args([ "ucode", "-L", LIB_DIR, initd_module, "mark-explicit-start", "if-running" ]);
        return true;
    }
    command_success_from_args([ "ucode", "-L", LIB_DIR, initd_module, "mark-explicit-start" ]);

    if (!wait_for_upgrade_sing_box_exit()) {
        warn("Timed out waiting for the previous Prokop sing-box runtime to exit; startup was not attempted.
");
        return false;
    }

    // The hand-off is consumed before the start, whatever its outcome: opkg
    // configures a package whose postinst failed again on every later
    // install, and such a re-run must neither wait for the runtime that came
    // up meanwhile nor start a Prokop that was stopped since.
    unlink_if_exists(PACKAGE_UPGRADE_STATE);

    // init.d exits 0 under procd before the detached start has run: wait for
    // the start's own result (service/initd.uc start-and-wait, UC-013) to
    // report a failure. It does not fail the package operation, as with
    // OpenWrt's default postinst: a failed start schedules its own retry,
    // and the in-app upgrade checks the runtime itself.
    let started = command_capture_from_args([ "env", "PROKOP_SERVICE_INIT=" + INIT_PATH,
        "ucode", "-L", LIB_DIR, LIB_DIR + "/service/initd.uc", "start-and-wait", "start", "",
        POSTINST_START_WAIT_SECONDS ]);
    if (started.status != 0 && match(started.output, /(^|\n)pending\n/) != null)
        warn("Prokop is still starting after the package upgrade; see the Prokop log for its outcome.\n");
    else if (started.status != 0)
        warn("Prokop did not start after the package upgrade; see the Prokop log.\n");
    return true;
}

function luci_cache_globs() {
    let configured = env("PROKOP_LUCI_CACHE_GLOBS", "");
    if (configured != "")
        return split(configured, /[ \t\r\n]+/);

    return [ "/var/luci-indexcache*", "/tmp/luci-indexcache*" ];
}

function remove_luci_index_cache() {
    for (let pattern in luci_cache_globs()) {
        pattern = as_string(pattern);
        if (pattern == "")
            continue;

        for (let path in fs.glob(pattern))
            unlink_if_exists(path);
    }
}

function luci_postinst() {
    remove_luci_index_cache();
    if (!PACKAGE_TEST_MODE) {
        if (path_exists("/etc/init.d/rpcd"))
            command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);
        command_success_from_args([ "logger", "-t", "prokop", "[info] Package defaults applied" ]);
    }
    return true;
}

let mode = ARGV[0] || "";

if (mode == "prerm")
    exit(prerm_cleanup(ARGV[1]) ? 0 : 1);
else if (mode == "postinst")
    exit(postinst_restore() ? 0 : 1);
else if (mode == "remove-rt-tables-entry")
    exit(remove_rt_tables_entry() ? 0 : 1);
else if (mode == "luci-postinst")
    exit(luci_postinst() ? 0 : 1);
else if (mode == "legacy-vpn-guard-cleanup")
    exit(legacy_vpn_guard_cleanup() ? 0 : 1);
else if (mode == "legacy-cleanup")
    exit(legacy_cleanup() ? 0 : 1);
else if (mode == "sing-box-exe-path-fixture")
    exit(sing_box_exe_path(ARGV[1]) ? 0 : 1);
else {
    warn("Usage: service/package.uc <prerm|postinst|remove-rt-tables-entry|luci-postinst|legacy-cleanup>\n");
    exit(1);
}
