#!/usr/bin/env ucode

// Read-only checks of the router around Prokop (diagnostics «Окружение»):
// what can make Prokop's rules not apply although Prokop itself is healthy.
// Nothing here changes a setting, and the output names no address, server
// credential or other secret: flags, interface names and the clock state.
//
//  * flow_offloading: fw4 flow offloading (firewall defaults) moves an
//    established forwarded connection to the flowtable, past the nftables
//    hooks Prokop, its kill-switch and zapret use. Read from the firewall
//    configuration ("configured").
//  * ipv6: a global IPv6 address on a router interface while Prokop runs
//    IPv4 only (core/ipv6.uc: IPv6 disabled for the kernel or loopback):
//    IPv6 connections of the devices then pass Prokop entirely. Read from
//    the kernel's address list ("observed").
//  * clock: core/clock.uc status() when that module is installed ("observed");
//    without it the row is "unavailable".
//  * sing_box_files: open files of the running sing-box against its limit
//    (/proc/<pid>/fd, /proc/<pid>/limits; "observed"). A sing-box at its
//    limit fails every new connection. The package variants run with the
//    limit of their package init script, which sets none (often 4096);
//    Prokop's own script raises it.
//
// Row states: ok, warning, not_checked, unavailable.

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;

const IF_INET6_FILE = getenv("PROKOP_IF_INET6_FILE") || "/proc/net/if_inet6";
const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const PROC_DIR = getenv("PROKOP_PROC_DIR") || "/proc";
// Open files from this share of the limit on: a warning.
const FILES_WARNING_PERCENT = 80;

function flag(value) {
    value = lc(trim(as_string(value)));
    return value == "1" || value == "on" || value == "true" || value == "yes" || value == "enabled";
}

function flow_offloading_row() {
    if (!uci_core.available() || !uci_core.load("firewall"))
        return { state: "unavailable", provenance: "configured", reason: "firewall_config_unreadable" };
    let defaults = uci_core.section_objects("firewall", "defaults");
    if (length(defaults) == 0)
        return { state: "ok", provenance: "configured", software: false, hardware: false };
    let section = object_or_empty(defaults[0]);
    let software = flag(section.flow_offloading);
    // fw4 uses the hardware flowtable only together with the software one.
    let hardware = software && flag(section.flow_offloading_hw);
    return { state: software ? "warning" : "ok", provenance: "configured", software, hardware };
}

// Interface names with a global unicast (2000::/3) address, from the
// kernel's list: "<32 hex> <ifindex> <prefix> <scope> <flags> <name>".
function global_ipv6_interfaces(text) {
    let names = [];
    for (let line in split(as_string(text), "\n")) {
        let fields = split(trim(line), /[ \t]+/);
        if (length(fields) < 6 || match(fields[0], /^[0-9a-fA-F]{32}$/) == null)
            continue;
        let first = hex(substr(fields[0], 0, 1));
        let name = fields[5];
        // 0x2 and 0x3 as the first nibble: 2000::/3.
        if ((first != 2 && first != 3) || name == "lo" || index(names, name) >= 0)
            continue;
        push(names, name);
    }
    return sort(names);
}

function ipv6_row() {
    let ipv6 = require("core.ipv6");
    let handled = ipv6.available();
    let text = fs.readfile(IF_INET6_FILE);
    if (text == null)
        // No IPv6 in the kernel at all: nothing can pass Prokop over IPv6.
        return { state: handled ? "unavailable" : "ok", provenance: "observed", prokop_ipv6: handled,
            global_interfaces: [], reason: handled ? "address_list_unreadable" : null };
    let interfaces = global_ipv6_interfaces(text);
    return {
        state: length(interfaces) > 0 && !handled ? "warning" : "ok",
        provenance: "observed",
        prokop_ipv6: handled,
        global_interfaces: interfaces
    };
}

// core/clock.uc is optional: { state: synced|unsynced|unknown, source,
// stratum, observed_at, reason }. Only these fields go out.
function clock_row() {
    let clock = null;
    try {
        clock = require("core.clock");
    }
    catch (e) {
        clock = null;
    }
    if (clock == null || type(clock.status) != "function")
        return { state: "unavailable", provenance: "observed", reason: "clock_module_missing" };
    let status = null;
    try {
        status = clock.status();
    }
    catch (e) {
        return { state: "unavailable", provenance: "observed", reason: "clock_status_failed" };
    }
    status = object_or_empty(status);
    let observed = as_string(status.state);
    let state = observed == "synced" ? "ok" : (observed == "unsynced" ? "warning" : "not_checked");
    let row = { state, provenance: "observed", clock_state: observed == "" ? "unknown" : observed };
    if (status.source != null)
        row.source = as_string(status.source);
    if (status.stratum != null)
        row.stratum = int(status.stratum);
    if (status.observed_at != null)
        row.observed_at = int(status.observed_at);
    if (status.reason != null)
        row.reason = as_string(status.reason);
    return row;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), "'", "'\\''") + "'";
}

// The PID of the sing-box that procd runs (its ujail child), as
// service/state.uc finds it; 0 when none runs.
function sing_box_pid() {
    let override = getenv("PROKOP_ENV_SING_BOX_PID");
    if (override != null)
        return int(override);
    let pipe = fs.popen("ubus call service list '{\"name\":\"sing-box\"}' 2>/dev/null | ucode -L " +
        shell_quote(LIB_DIR) + " " + shell_quote(LIB_DIR + "/service/state.uc") + " sing-box-service-pid 2>/dev/null", "r");
    if (pipe == null)
        return 0;
    let output = pipe.read("all");
    pipe.close();
    return int(trim(as_string(output)) || 0);
}

// "Max open files  <soft>  <hard>  files" of /proc/<pid>/limits; a limit
// "unlimited" is -1.
function open_files_limits(text) {
    for (let line in split(as_string(text), "\n")) {
        let found = match(line, /^Max open files[ \t]+([0-9]+|unlimited)[ \t]+([0-9]+|unlimited)/);
        if (found != null)
            return { soft: found[1] == "unlimited" ? -1 : int(found[1]), hard: found[2] == "unlimited" ? -1 : int(found[2]) };
    }
    return null;
}

function open_files_state(open, soft) {
    return soft > 0 && open * 100 >= soft * FILES_WARNING_PERCENT ? "warning" : "ok";
}

function sing_box_files_row() {
    let pid = sing_box_pid();
    if (pid <= 0)
        return { state: "not_checked", provenance: "observed", reason: "sing_box_not_running" };
    let limits = open_files_limits(fs.readfile(PROC_DIR + "/" + pid + "/limits"));
    let fds = fs.lsdir(PROC_DIR + "/" + pid + "/fd");
    if (limits == null || fds == null)
        return { state: "unavailable", provenance: "observed", reason: "process_unreadable" };
    let open = length(fds);
    return { state: open_files_state(open, limits.soft), provenance: "observed", open,
        soft_limit: limits.soft, hard_limit: limits.hard };
}

function check() {
    let rows = {};
    for (let item in [ [ "flow_offloading", flow_offloading_row ], [ "ipv6", ipv6_row ], [ "clock", clock_row ],
        [ "sing_box_files", sing_box_files_row ] ]) {
        try {
            rows[item[0]] = item[1]();
        }
        catch (e) {
            rows[item[0]] = { state: "unavailable", reason: "check_failed" };
        }
    }
    return rows;
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return { check, global_ipv6_interfaces, open_files_limits, open_files_state };

let mode = ARGV[0] || "";
if (mode == "check") {
    print(sprintf("%J", check()), "\n");
    exit(0);
}
warn("Usage: diagnostics/environment.uc check\n");
exit(1);
