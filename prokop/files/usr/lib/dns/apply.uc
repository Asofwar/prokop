#!/usr/bin/env ucode

let fs = require("fs");
let uci = require("core.uci");

const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || "prokop";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || "127.0.0.42";
const DNSMASQ_INIT = getenv("DNSMASQ_INIT") || "/etc/init.d/dnsmasq";
const KILLSWITCH_STATE_DIR = getenv("KILLSWITCH_STATE_DIR") || "/etc/prokop/killswitch";
const KILLSWITCH_DNS_BLOCKED_FILE = KILLSWITCH_STATE_DIR + "/dns-blocked.servers";
const KILLSWITCH_DNS_SERVERS_FILE = KILLSWITCH_STATE_DIR + "/dnsmasq.servers";
const DNSMASQ_SERVERSFILE_OPTION = "dhcp.@dnsmasq[0].serversfile";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function run(command) {
    return system(command) == 0;
}

function uci_available() {
    return uci.available();
}

function uci_get(path) {
    return uci.get(path);
}

function uci_exists(path) {
    return uci.exists(path);
}

function uci_delete(path) {
    uci.delete(path);
}

function uci_set(path, value) {
    uci.set(path, value);
}

function uci_add_list(path, value) {
    uci.add_list(path, value);
}

function uci_del_list(path, value) {
    return uci.del_list(path, value);
}

function uci_commit(package_name) {
    uci.commit(package_name);
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

function dnsmasq_legacy_instance_exists() {
    return uci_exists("dhcp.prokop");
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
        uci_get("dhcp.@dnsmasq[0].prokop_notinterface") != "" ||
        dnsmasq_legacy_instance_exists();
}

function dnsmasq_management_disabled() {
    return truthy(uci_get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
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

    if (current != "" && current != KILLSWITCH_DNS_SERVERS_FILE) {
        log("Kill-switch DNS protection is unavailable: dnsmasq already uses servers file " + current, "warn");
        return false;
    }

    let content = blocking ? as_string(fs.readfile(KILLSWITCH_DNS_BLOCKED_FILE)) : "";
    let changed = false;
    if (!present || as_string(fs.readfile(KILLSWITCH_DNS_SERVERS_FILE)) != content) {
        let tmp = KILLSWITCH_DNS_SERVERS_FILE + ".tmp";
        if (fs.writefile(tmp, content) == null || !fs.rename(tmp, KILLSWITCH_DNS_SERVERS_FILE)) {
            fs.unlink(tmp);
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
    if (!uci_available())
        return true;
    if (!killswitch_dns_apply(!dnsmasq_has_prokop_dns()))
        return true;
    uci_commit("dhcp");
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

function backup_dnsmasq_config_option(key, backup_key) {
    if (uci_get("dhcp.@dnsmasq[0]." + backup_key) != "")
        return;

    let value = uci_get("dhcp.@dnsmasq[0]." + key);
    if (value != "")
        uci_set("dhcp.@dnsmasq[0]." + backup_key, value);
}

function backup_dnsmasq_server_list() {
    if (uci_get("dhcp.@dnsmasq[0].prokop_server") != "")
        return;

    for (let server in words(dnsmasq_default_servers())) {
        if (server != SB_DNS_INBOUND_ADDRESS)
            uci_add_list("dhcp.@dnsmasq[0].prokop_server", server);
    }
}

function restore_dnsmasq_config_option(key, backup_key, default_value) {
    let value = uci_get("dhcp.@dnsmasq[0]." + backup_key);
    if (value != "") {
        uci_set("dhcp.@dnsmasq[0]." + key, value);
        uci_delete("dhcp.@dnsmasq[0]." + backup_key);
    }
    else if (as_string(default_value) != "") {
        uci_set("dhcp.@dnsmasq[0]." + key, default_value);
    }
    else {
        uci_delete("dhcp.@dnsmasq[0]." + key);
    }
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
        backup_dnsmasq_config_option("noresolv", "prokop_noresolv");
        backup_dnsmasq_config_option("cachesize", "prokop_cachesize");
    }

    uci_delete("dhcp.@dnsmasq[0].server");
    uci_add_list("dhcp.@dnsmasq[0].server", SB_DNS_INBOUND_ADDRESS);
    uci_set("dhcp.@dnsmasq[0].noresolv", "1");
    uci_set("dhcp.@dnsmasq[0].cachesize", "0");
}

function dnsmasq_restore_default_instance() {
    let server_list = dnsmasq_default_servers();
    let backup_servers = uci_get("dhcp.@dnsmasq[0].prokop_server");
    let managed_global_dns = list_has(server_list, SB_DNS_INBOUND_ADDRESS);

    uci_delete("dhcp.@dnsmasq[0].server");
    if (backup_servers != "") {
        for (let value in words(backup_servers))
            uci_add_list("dhcp.@dnsmasq[0].server", value);
        uci_delete("dhcp.@dnsmasq[0].prokop_server");
    }
    else {
        for (let value in words(server_list)) {
            if (value != SB_DNS_INBOUND_ADDRESS)
                uci_add_list("dhcp.@dnsmasq[0].server", value);
        }
    }
    uci_delete("dhcp.@dnsmasq[0].prokop_server");

    let noresolv = uci_get("dhcp.@dnsmasq[0].prokop_noresolv");
    if (noresolv != "")
        restore_dnsmasq_config_option("noresolv", "prokop_noresolv", "");
    else if (managed_global_dns)
        uci_set("dhcp.@dnsmasq[0].noresolv", "0");

    let cachesize = uci_get("dhcp.@dnsmasq[0].prokop_cachesize");
    if (cachesize != "")
        restore_dnsmasq_config_option("cachesize", "prokop_cachesize", "");
    else if (managed_global_dns)
        uci_set("dhcp.@dnsmasq[0].cachesize", "150");
}

function dnsmasq_configure(force) {
    if (!uci_available())
        return true;

    if (as_string(force) != "force" && uci_get(CONFIG_NAME + ".settings.shutdown_correctly") == "0") {
        if (dnsmasq_default_config_is_complete()) {
            log("Previous Prokop shutdown was unclean; dnsmasq already points to sing-box", "info");
            if (killswitch_dns_apply(false)) {
                uci_commit("dhcp");
                return restart_dnsmasq();
            }
            return true;
        }
        log("Previous Prokop shutdown was unclean and dnsmasq is not ready; applying Prokop DNS settings", "info");
    }

    log("Configuring dnsmasq to forward DNS to sing-box", "info");
    dnsmasq_cleanup_legacy_instance();
    dnsmasq_configure_default_instance();
    killswitch_dns_apply(false);
    uci_commit("dhcp");

    return restart_dnsmasq();
}

function dnsmasq_restore(force, quiet) {
    if (!uci_available())
        return true;

    if (!quiet)
        log("Restoring DNS settings in dnsmasq", "info");
    if (as_string(force) != "force" && uci_get(CONFIG_NAME + ".settings.shutdown_correctly") == "1") {
        if (!dnsmasq_has_prokop_dns()) {
            log("dnsmasq already uses non-Prokop DNS settings; restore is not required", "info");
            if (killswitch_dns_apply(true)) {
                uci_commit("dhcp");
                return restart_dnsmasq();
            }
            return true;
        }
        log("Prokop DNS settings are still present after a clean shutdown; restoring DNS settings in dnsmasq", "info");
    }

    dnsmasq_cleanup_legacy_instance();
    dnsmasq_restore_default_instance();
    killswitch_dns_apply(true);
    uci_commit("dhcp");

    return restart_dnsmasq();
}

function failsafe_restore() {
    if (!uci_available())
        return true;

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

    dnsmasq_restore("force", true);
    return true;
}

let mode = ARGV[0] || "";

if (mode == "configure")
    exit(dnsmasq_configure(ARGV[1]) ? 0 : 1);
else if (mode == "restore")
    exit(dnsmasq_restore(ARGV[1]) ? 0 : 1);
else if (mode == "failsafe-restore")
    exit(failsafe_restore() ? 0 : 1);
else if (mode == "has-prokop-dns")
    exit(dnsmasq_has_prokop_dns() ? 0 : 1);
else if (mode == "has-managed-state")
    exit(dnsmasq_has_prokop_managed_state() ? 0 : 1);
else if (mode == "default-config-complete")
    exit(dnsmasq_default_config_is_complete() ? 0 : 1);
else if (mode == "killswitch-refresh")
    exit(killswitch_dns_refresh() ? 0 : 1);
else if (mode == "killswitch-status")
    exit(killswitch_dns_status() ? 0 : 1);

warn("Usage: dns/apply.uc <configure|restore|failsafe-restore|has-prokop-dns|has-managed-state|default-config-complete|killswitch-refresh|killswitch-status>\n");
exit(1);
