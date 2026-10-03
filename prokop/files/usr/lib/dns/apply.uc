#!/usr/bin/env ucode

let fs = require("fs");
let uci = require("core.uci");
let durable = require("core.durable");

const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || "prokop";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || "127.0.0.42";
const DNSMASQ_INIT = getenv("DNSMASQ_INIT") || "/etc/init.d/dnsmasq";
const KILLSWITCH_STATE_DIR = getenv("KILLSWITCH_STATE_DIR") || "/etc/prokop/killswitch";
const KILLSWITCH_DNS_BLOCKED_FILE = KILLSWITCH_STATE_DIR + "/dns-blocked.servers";
const KILLSWITCH_DNS_SERVERS_FILE = KILLSWITCH_STATE_DIR + "/dnsmasq.servers";
const DNSMASQ_SERVERSFILE_OPTION = "dhcp.@dnsmasq[0].serversfile";
// The options a configure set that were not set before: a restore removes
// them again (UC-236).
const DNSMASQ_UNSET_OPTION = "dhcp.@dnsmasq[0].prokop_unset";
const DNSMASQ_CONFIG_FILE = getenv("PROKOP_DNSMASQ_CONFIG_FILE") || "/etc/config/dhcp";
const UCI_CLI = getenv("PROKOP_UCI_CLI") || "uci";
// service/lifecycle.uc SHUTDOWN_STATE_FILE.
const SHUTDOWN_STATE_FILE = (getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop") + "/shutdown_correctly";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function run(command) {
    return system(command) == 0;
}

// The dnsmasq settings while configure, restore and the kill-switch refresh
// edit them (core/uci.uc session, edit_dhcp): /etc/config/dhcp as it is
// committed, saved only when something changes and without what someone
// staged with `uci set` (UC-236). Other reads go through core.uci.
let dhcp = null;
// How often an operation starts over when someone else commits dhcp while it
// edits the settings (the session's conflict()).
const DHCP_EDIT_ATTEMPTS = 5;

function uci_available() {
    return uci.available();
}

function store(path) {
    return dhcp != null && substr(as_string(path), 0, 5) == "dhcp." ? dhcp : uci;
}

function uci_get(path) {
    return store(path).get(path);
}

function uci_exists(path) {
    return store(path).exists(path);
}

function uci_delete(path) {
    return store(path).delete(path);
}

function uci_set(path, value) {
    return store(path).set(path, value);
}

function uci_add_list(path, value) {
    return store(path).add_list(path, value);
}

function uci_del_list(path, value) {
    return store(path).del_list(path, value);
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function truthy(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function list_has(values, needle) {
    for (let value in words(values))
        if (value == needle)
            return true;
    return false;
}

function log(message, level) {
    level = as_string(level || "info");
    run("logger -t " + shell_quote("prokop") + " " + shell_quote("[" + level + "] " + as_string(message)));
}

function restart_dnsmasq() {
    return run("[ -x " + shell_quote(DNSMASQ_INIT) + " ] && " + shell_quote(DNSMASQ_INIT) + " restart");
}

// Neither UCI nor dnsmasq settings: nothing to configure or restore.
function no_dnsmasq_settings() {
    return !uci_available() && fs.stat(DNSMASQ_CONFIG_FILE) == null;
}

// Opens the edit of the dnsmasq settings (dhcp) unless it is open.
function edit_dhcp() {
    if (dhcp == null)
        dhcp = uci.session("dhcp", DNSMASQ_CONFIG_FILE, UCI_CLI);
    return dhcp != null;
}

function dhcp_unreadable() {
    log("Could not read the dnsmasq settings in " + DNSMASQ_CONFIG_FILE, "error");
    return false;
}

// dnsmasq reads its settings from /etc/config/dhcp at its restart, and only
// there (UCI staged in /tmp/.uci would also reach any later commit, an
// override file in /var/run/uci only newer libuci): forwarding to sing-box
// needs a write, written only when something changes (UC-236). A commit that
// fails (a full or read-only overlay) leaves the file as it was: dnsmasq is
// not restarted, and the start, stop or failsafe that asked for the change
// fails with it, so that its own error handling runs (UC-024).
// The file someone else committed meanwhile is not overwritten: the
// operation starts over from it (see the end of this file).
function commit_dhcp() {
    if (dhcp != null && dhcp.commit())
        return true;
    if (dhcp != null && dhcp.conflict())
        log("The dnsmasq settings in " + DNSMASQ_CONFIG_FILE + " changed while Prokop edited them", "info");
    else
        log("Could not save the dnsmasq settings in " + DNSMASQ_CONFIG_FILE, "error");
    return false;
}

function dnsmasq_legacy_instance_exists() {
    return uci_exists("dhcp.prokop");
}

// dnsmasq runs an instance per dnsmasq section: without one there is nothing
// to forward to sing-box and nothing to attach the kill-switch servers file
// to. Nothing is written then, and that fails no start or stop.
function dnsmasq_section_missing() {
    return !uci_exists("dhcp.@dnsmasq[0]");
}

function dnsmasq_default_servers() {
    return uci_get("dhcp.@dnsmasq[0].server");
}

function dnsmasq_default_has_prokop_dns() {
    return list_has(dnsmasq_default_servers(), SB_DNS_INBOUND_ADDRESS);
}

function dnsmasq_has_prokop_dns() {
    return dnsmasq_default_has_prokop_dns() || dnsmasq_legacy_instance_exists();
}

function dnsmasq_has_prokop_managed_state() {
    return uci_get("dhcp.@dnsmasq[0].prokop_server") != "" ||
        uci_get("dhcp.@dnsmasq[0].prokop_noresolv") != "" ||
        uci_get("dhcp.@dnsmasq[0].prokop_cachesize") != "" ||
        uci_get(DNSMASQ_UNSET_OPTION) != "" ||
        uci_get("dhcp.@dnsmasq[0].prokop_notinterface") != "" ||
        dnsmasq_legacy_instance_exists();
}

function dnsmasq_management_disabled() {
    return truthy(uci_get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

// "0" while Prokop runs (or after a start that crashed), "1" after it was
// stopped, "" before the first start or stop of this boot: dnsmasq then
// still runs with the configuration it read at boot. A runtime record
// (service/lifecycle.uc record_shutdown_state); the shutdown_correctly
// option older releases kept in UCI is not read (UC-160).
function shutdown_state() {
    return trim(as_string(fs.readfile(SHUTDOWN_STATE_FILE)));
}

// The VPN kill-switch must keep protected domains from resolving through the
// ordinary upstream whenever dnsmasq does not forward to sing-box: after a
// stop, a failed start, or a reboot with Prokop disabled. dnsmasq reads its
// servers file at start, so the file is empty while sing-box answers DNS and
// holds the local-only "server=/domain/" entries prepared by the kill-switch
// otherwise. Returns true when dnsmasq must be restarted to pick up a change.
function killswitch_dns_apply(blocking) {
    let armed = fs.stat(KILLSWITCH_DNS_BLOCKED_FILE) != null && !dnsmasq_management_disabled();
    let present = fs.stat(KILLSWITCH_DNS_SERVERS_FILE) != null;
    if (!armed && !present)
        return false;

    let current = uci_get(DNSMASQ_SERVERSFILE_OPTION);
    if (!armed) {
        let changed = false;
        if (current == KILLSWITCH_DNS_SERVERS_FILE) {
            uci_delete(DNSMASQ_SERVERSFILE_OPTION);
            changed = true;
        }
        fs.unlink(KILLSWITCH_DNS_SERVERS_FILE);
        return changed;
    }

    if (dnsmasq_section_missing()) {
        log("Kill-switch DNS protection is unavailable: there is no dnsmasq section in " + DNSMASQ_CONFIG_FILE, "warn");
        return false;
    }
    if (current != "" && current != KILLSWITCH_DNS_SERVERS_FILE) {
        log("Kill-switch DNS protection is unavailable: dnsmasq already uses servers file " + current, "warn");
        return false;
    }

    let content = blocking ? as_string(fs.readfile(KILLSWITCH_DNS_BLOCKED_FILE)) : "";
    let changed = false;
    if (!present || as_string(fs.readfile(KILLSWITCH_DNS_SERVERS_FILE)) != content) {
        // Unique per writer (UC-210). On flash and read at boot, before
        // Prokop runs: read back, and flushed before and after the rename
        // (core/durable.uc), so neither a full overlay nor a power cut
        // leaves an empty file in place of the block list (UC-212, UC-241).
        let tmp = KILLSWITCH_DNS_SERVERS_FILE + ".tmp." + as_string(fs.readlink("/proc/self"));
        if (!durable.durable_replace(tmp, KILLSWITCH_DNS_SERVERS_FILE, content)) {
            log("Could not write the kill-switch dnsmasq servers file", "error");
            return false;
        }
        changed = true;
    }
    if (current != KILLSWITCH_DNS_SERVERS_FILE) {
        uci_set(DNSMASQ_SERVERSFILE_OPTION, KILLSWITCH_DNS_SERVERS_FILE);
        changed = true;
    }
    return changed;
}

function killswitch_dns_refresh() {
    if (no_dnsmasq_settings())
        return true;
    // Without a dhcp configuration there are no Prokop settings in it.
    if (!edit_dhcp())
        return fs.stat(DNSMASQ_CONFIG_FILE) == null || dhcp_unreadable();
    if (!killswitch_dns_apply(!dnsmasq_has_prokop_dns()))
        return true;
    if (!commit_dhcp())
        return false;
    return restart_dnsmasq();
}

function killswitch_dns_status() {
    let current = uci_available() ? uci_get(DNSMASQ_SERVERSFILE_OPTION) : "";
    let active = as_string(fs.readfile(KILLSWITCH_DNS_SERVERS_FILE));
    print(sprintf("%J", {
        armed: fs.stat(KILLSWITCH_DNS_BLOCKED_FILE) != null,
        managed: !dnsmasq_management_disabled(),
        serversfile: current,
        attached: current == KILLSWITCH_DNS_SERVERS_FILE,
        conflict: current != "" && current != KILLSWITCH_DNS_SERVERS_FILE,
        prokop_dns: dnsmasq_has_prokop_dns(),
        blocking: current == KILLSWITCH_DNS_SERVERS_FILE && length(active) > 0
    }), "\n");
    return true;
}

function dnsmasq_default_config_is_complete() {
    return dnsmasq_default_has_prokop_dns() &&
        uci_get("dhcp.@dnsmasq[0].noresolv") == "1" &&
        uci_get("dhcp.@dnsmasq[0].cachesize") == "0" &&
        !dnsmasq_legacy_instance_exists();
}

function dnsmasq_legacy_interfaces() {
    let legacy_dnsmasq_section = "prokop";
    let legacy_interfaces = uci_get("dhcp." + legacy_dnsmasq_section + ".interface");
    if (legacy_interfaces == "")
        legacy_interfaces = uci_get(CONFIG_NAME + ".settings.source_network_interfaces");
    if (legacy_interfaces == "")
        legacy_interfaces = "br-lan";

    return legacy_interfaces;
}

// The value the option had, in prokop_<key>; one that was not set is listed
// in prokop_unset instead.
function backup_dnsmasq_config_option(key) {
    if (uci_get("dhcp.@dnsmasq[0].prokop_" + key) != "" || list_has(uci_get(DNSMASQ_UNSET_OPTION), key))
        return;

    let value = uci_get("dhcp.@dnsmasq[0]." + key);
    if (value != "")
        uci_set("dhcp.@dnsmasq[0].prokop_" + key, value);
    else
        uci_add_list(DNSMASQ_UNSET_OPTION, key);
}

function backup_dnsmasq_server_list() {
    if (uci_get("dhcp.@dnsmasq[0].prokop_server") != "")
        return;

    let servers = [];
    for (let server in words(dnsmasq_default_servers())) {
        if (server != SB_DNS_INBOUND_ADDRESS)
            push(servers, server);
    }
    uci_set("dhcp.@dnsmasq[0].prokop_server", servers);
}

// The option as it was before the configure. Releases before UC-236 kept no
// record of an option that was not set: then the dnsmasq default
// (fallback) undoes the Prokop value.
function restore_dnsmasq_config_option(key, managed_global_dns, fallback) {
    let value = uci_get("dhcp.@dnsmasq[0].prokop_" + key);
    if (value != "")
        uci_set("dhcp.@dnsmasq[0]." + key, value);
    else if (list_has(uci_get(DNSMASQ_UNSET_OPTION), key))
        uci_delete("dhcp.@dnsmasq[0]." + key);
    else if (managed_global_dns)
        uci_set("dhcp.@dnsmasq[0]." + key, fallback);
    uci_delete("dhcp.@dnsmasq[0].prokop_" + key);
}

function dnsmasq_cleanup_legacy_instance() {
    let legacy_instance_present = dnsmasq_legacy_instance_exists();
    let legacy_interfaces = legacy_instance_present ? dnsmasq_legacy_interfaces() : "";

    uci_delete("dhcp.prokop");

    let backup_notinterfaces = uci_get("dhcp.@dnsmasq[0].prokop_notinterface");
    if (backup_notinterfaces != "") {
        uci_delete("dhcp.@dnsmasq[0].notinterface");
        for (let value in words(backup_notinterfaces))
            uci_add_list("dhcp.@dnsmasq[0].notinterface", value);
        uci_delete("dhcp.@dnsmasq[0].prokop_notinterface");
        return;
    }

    if (legacy_instance_present) {
        for (let value in words(legacy_interfaces))
            uci_del_list("dhcp.@dnsmasq[0].notinterface", value);
    }

    uci_delete("dhcp.@dnsmasq[0].prokop_notinterface");
}

function dnsmasq_configure_default_instance() {
    let default_has_prokop_dns = dnsmasq_default_has_prokop_dns();

    backup_dnsmasq_server_list();
    if (!default_has_prokop_dns) {
        backup_dnsmasq_config_option("noresolv");
        backup_dnsmasq_config_option("cachesize");
    }

    uci_set("dhcp.@dnsmasq[0].server", [ SB_DNS_INBOUND_ADDRESS ]);
    uci_set("dhcp.@dnsmasq[0].noresolv", "1");
    uci_set("dhcp.@dnsmasq[0].cachesize", "0");
}

function dnsmasq_restore_default_instance() {
    let server_list = dnsmasq_default_servers();
    let backup_servers = uci_get("dhcp.@dnsmasq[0].prokop_server");
    let managed_global_dns = list_has(server_list, SB_DNS_INBOUND_ADDRESS);

    let servers = [];
    for (let value in words(backup_servers != "" ? backup_servers : server_list)) {
        if (backup_servers != "" || value != SB_DNS_INBOUND_ADDRESS)
            push(servers, value);
    }
    uci_set("dhcp.@dnsmasq[0].server", servers);
    uci_delete("dhcp.@dnsmasq[0].prokop_server");

    restore_dnsmasq_config_option("noresolv", managed_global_dns, "0");
    restore_dnsmasq_config_option("cachesize", managed_global_dns, "150");
    uci_delete(DNSMASQ_UNSET_OPTION);
}

function dnsmasq_configure(force) {
    if (no_dnsmasq_settings())
        return true;
    if (!edit_dhcp())
        return dhcp_unreadable();
    if (dnsmasq_section_missing()) {
        log("There is no dnsmasq section in " + DNSMASQ_CONFIG_FILE + ": DNS is not forwarded to sing-box", "warn");
        return true;
    }

    if (as_string(force) != "force" && shutdown_state() != "1") {
        if (dnsmasq_default_config_is_complete()) {
            log("dnsmasq already points to sing-box", "info");
            if (killswitch_dns_apply(false)) {
                if (!commit_dhcp())
                    return false;
                return restart_dnsmasq();
            }
            return true;
        }
    }

    log("Configuring dnsmasq to forward DNS to sing-box", "info");
    dnsmasq_cleanup_legacy_instance();
    dnsmasq_configure_default_instance();
    killswitch_dns_apply(false);
    if (!commit_dhcp())
        return false;

    return restart_dnsmasq();
}

function dnsmasq_restore(force, quiet) {
    if (no_dnsmasq_settings())
        return true;
    if (!edit_dhcp())
        return fs.stat(DNSMASQ_CONFIG_FILE) == null || dhcp_unreadable();

    if (!quiet)
        log("Restoring DNS settings in dnsmasq", "info");
    if (as_string(force) != "force" && shutdown_state() != "0") {
        if (!dnsmasq_has_prokop_dns()) {
            log("dnsmasq already uses non-Prokop DNS settings; restore is not required", "info");
            if (killswitch_dns_apply(true)) {
                if (!commit_dhcp())
                    return false;
                return restart_dnsmasq();
            }
            return true;
        }
        log("Prokop DNS settings are still present; restoring DNS settings in dnsmasq", "info");
    }

    dnsmasq_cleanup_legacy_instance();
    dnsmasq_restore_default_instance();
    killswitch_dns_apply(true);
    if (!commit_dhcp())
        return false;

    return restart_dnsmasq();
}

function failsafe_restore() {
    if (no_dnsmasq_settings())
        return true;
    if (!edit_dhcp())
        return fs.stat(DNSMASQ_CONFIG_FILE) == null || dhcp_unreadable();

    if (dnsmasq_management_disabled()) {
        if (!dnsmasq_has_prokop_managed_state()) {
            log("DNS rollback skipped: dont_touch_dhcp is enabled and no Prokop dnsmasq changes were found", "info");
            return true;
        }

        log("Rolling back previous Prokop dnsmasq changes because dont_touch_dhcp is enabled", "warn");
    }
    else {
        log("Rolling back Prokop DNS changes in dnsmasq", "warn");
    }

    return dnsmasq_restore("force", true);
}

function run_mode(mode) {
    if (mode == "configure")
        return dnsmasq_configure(ARGV[1]);
    if (mode == "restore")
        return dnsmasq_restore(ARGV[1]);
    if (mode == "failsafe-restore")
        return failsafe_restore();
    if (mode == "has-prokop-dns")
        return dnsmasq_has_prokop_dns();
    if (mode == "has-managed-state")
        return dnsmasq_has_prokop_managed_state();
    if (mode == "default-config-complete")
        return dnsmasq_default_config_is_complete();
    if (mode == "killswitch-refresh")
        return killswitch_dns_refresh();
    if (mode == "killswitch-status")
        return killswitch_dns_status();
    return null;
}

let mode = ARGV[0] || "";
let result = null;

// Each attempt decides from the file as it is then; the edit holds no lock
// on it (core/uci.uc session).
for (let attempt = 1; ; attempt++) {
    result = run_mode(mode);
    let conflict = dhcp != null && dhcp.conflict();
    // An edit that ended without a commit (nothing to change) changes nothing.
    if (dhcp != null)
        dhcp.close();
    dhcp = null;
    if (!conflict)
        break;
    if (attempt >= DHCP_EDIT_ATTEMPTS) {
        log("Could not save the dnsmasq settings in " + DNSMASQ_CONFIG_FILE + ": the file kept changing while Prokop edited it", "error");
        break;
    }
}
if (result != null)
    exit(result ? 0 : 1);

warn("Usage: dns/apply.uc <configure|restore|failsafe-restore|has-prokop-dns|has-managed-state|default-config-complete|killswitch-refresh|killswitch-status>\n");
exit(1);
