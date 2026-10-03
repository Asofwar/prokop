#!/usr/bin/env ucode

let fs = require("fs");
let uci = require("core.uci");
let legacy = require("core.legacy_forkop");

const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || "prokop";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || "127.0.0.42";
const DNSMASQ_INIT = getenv("DNSMASQ_INIT") || "/etc/init.d/dnsmasq";
const KILLSWITCH_STATE_DIR = getenv("KILLSWITCH_STATE_DIR") || "/etc/prokop/killswitch";
const KILLSWITCH_DNS_BLOCKED_FILE = KILLSWITCH_STATE_DIR + "/dns-blocked.servers";
const KILLSWITCH_DNS_SERVERS_FILE = KILLSWITCH_STATE_DIR + "/dnsmasq.servers";
const DNSMASQ_SERVERSFILE_OPTION = "dhcp.@dnsmasq[0].serversfile";
// What the product before the rename (core/legacy_forkop.uc) leaves in
// dhcp: the servers file of its kill-switch, its backups of the original
// dnsmasq options and its old separate dnsmasq instance.
const LEGACY_KILLSWITCH_SERVERS_FILE = legacy.path(legacy.KILLSWITCH_SERVERSFILE);
const LEGACY_DNSMASQ_SECTION = "dhcp." + legacy.DHCP_SECTION;
const BACKUP_KEYS = [ "server", "noresolv", "cachesize", "notinterface" ];
const BACKUP_LIST_KEYS = { server: true, notinterface: true };

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

// sing-box's DNS inbound, also when written with a port. It is never an
// original upstream: no backup or restore keeps it.
function is_sing_box_dns(value) {
    value = as_string(value);
    return value == SB_DNS_INBOUND_ADDRESS || index(value, SB_DNS_INBOUND_ADDRESS + "#") == 0;
}

function list_has_sing_box_dns(values) {
    for (let value in words(values))
        if (is_sing_box_dns(value))
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

// The old separate dnsmasq instance: Prokop's name, or the one the product
// before the rename cleaned up in its turn.
function dnsmasq_legacy_instance_exists() {
    return uci_exists("dhcp.prokop") || uci_exists(LEGACY_DNSMASQ_SECTION);
}

function dnsmasq_default_servers() {
    return uci_get("dhcp.@dnsmasq[0].server");
}

function dnsmasq_default_has_prokop_dns() {
    return list_has_sing_box_dns(dnsmasq_default_servers());
}

function dnsmasq_has_prokop_dns() {
    return dnsmasq_default_has_prokop_dns() || dnsmasq_legacy_instance_exists();
}

// The product before the rename is running, starting or crashed with its
// package still installed: dnsmasq is its own, also while Prokop's package is
// installed next to it during a migration (or removed again by its rollback).
// Prokop then neither configures nor restores dnsmasq.
function legacy_runtime_owns_dnsmasq() {
    return legacy.installed() && legacy.active();
}

// Backups of the original dnsmasq options that the product before the rename
// left behind once its package is gone (a migration that did not convert
// them). Prokop takes them over as its own.
function legacy_backup_key(key) {
    return "dhcp.@dnsmasq[0]." + legacy.DHCP_OPTION_PREFIX + key;
}

function legacy_backups_present() {
    if (legacy.installed())
        return false;
    for (let key in BACKUP_KEYS)
        if (uci_get(legacy_backup_key(key)) != "")
            return true;
    return false;
}

// An existing prokop_* backup wins; sing-box itself is never adopted as an
// original upstream. Returns whether dhcp changed.
function adopt_legacy_backups() {
    if (!legacy_backups_present())
        return false;
    let changed = false;
    for (let key in BACKUP_KEYS) {
        let value = uci_get(legacy_backup_key(key));
        if (value == "")
            continue;
        let own = "dhcp.@dnsmasq[0].prokop_" + key;
        if (uci_get(own) == "") {
            if (BACKUP_LIST_KEYS[key]) {
                for (let item in words(value))
                    if (key != "server" || !is_sing_box_dns(item))
                        uci_add_list(own, item);
            }
            else
                uci_set(own, value);
        }
        uci_delete(legacy_backup_key(key));
        changed = true;
    }
    return changed;
}

function dnsmasq_has_prokop_managed_state() {
    return uci_get("dhcp.@dnsmasq[0].prokop_server") != "" ||
        uci_get("dhcp.@dnsmasq[0].prokop_noresolv") != "" ||
        uci_get("dhcp.@dnsmasq[0].prokop_cachesize") != "" ||
        uci_get("dhcp.@dnsmasq[0].prokop_notinterface") != "" ||
        dnsmasq_legacy_instance_exists() || legacy_backups_present();
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
//
// The servers file of the old kill-switch (the product before the rename) is
// left alone unless release_legacy is set (killswitch/runtime.uc hand-over and
// disable): then this kill-switch replaces it when armed, or dnsmasq leaves it,
// in the same commit.
function killswitch_dns_apply(blocking, release_legacy) {
    let armed = fs.stat(KILLSWITCH_DNS_BLOCKED_FILE) != null && !dnsmasq_management_disabled();
    let present = fs.stat(KILLSWITCH_DNS_SERVERS_FILE) != null;
    let current = uci_get(DNSMASQ_SERVERSFILE_OPTION);
    let legacy_attached = release_legacy === true && current == LEGACY_KILLSWITCH_SERVERS_FILE;
    if (!armed && !present && !legacy_attached)
        return false;

    if (!armed) {
        let changed = false;
        if (current == KILLSWITCH_DNS_SERVERS_FILE || legacy_attached) {
            uci_delete(DNSMASQ_SERVERSFILE_OPTION);
            changed = true;
        }
        fs.unlink(KILLSWITCH_DNS_SERVERS_FILE);
        return changed;
    }

    if (current != "" && current != KILLSWITCH_DNS_SERVERS_FILE && !legacy_attached) {
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

function killswitch_dns_refresh(release_legacy) {
    if (!uci_available())
        return true;
    if (legacy_runtime_owns_dnsmasq()) {
        log("Kill-switch DNS refresh skipped: dnsmasq belongs to the running " + legacy.PRODUCT, "warn");
        return true;
    }
    if (!killswitch_dns_apply(!dnsmasq_has_prokop_dns(), release_legacy))
        return true;
    uci_commit("dhcp");
    return restart_dnsmasq();
}

function killswitch_dns_status() {
    let current = uci_available() ? uci_get(DNSMASQ_SERVERSFILE_OPTION) : "";
    let active = as_string(fs.readfile(KILLSWITCH_DNS_SERVERS_FILE));
    let legacy_attached = current != "" && current == LEGACY_KILLSWITCH_SERVERS_FILE;
    print(sprintf("%J", {
        armed: fs.stat(KILLSWITCH_DNS_BLOCKED_FILE) != null,
        managed: !dnsmasq_management_disabled(),
        serversfile: current,
        attached: current == KILLSWITCH_DNS_SERVERS_FILE,
        conflict: current != "" && current != KILLSWITCH_DNS_SERVERS_FILE && !legacy_attached,
        // The old kill-switch's servers file, still attached.
        legacy_attached,
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
        legacy_interfaces = uci_get(LEGACY_DNSMASQ_SECTION + ".interface");
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

// A backup that names nothing but sing-box is no backup of the original.
function backup_servers_of(value) {
    return filter(words(value), (server) => !is_sing_box_dns(server));
}

function backup_dnsmasq_server_list() {
    let existing = uci_get("dhcp.@dnsmasq[0].prokop_server");
    if (length(backup_servers_of(existing)) > 0)
        return;
    if (existing != "")
        uci_delete("dhcp.@dnsmasq[0].prokop_server");

    for (let server in words(dnsmasq_default_servers())) {
        if (!is_sing_box_dns(server))
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
    uci_delete(LEGACY_DNSMASQ_SECTION);

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
    let backup_servers = backup_servers_of(uci_get("dhcp.@dnsmasq[0].prokop_server"));
    let managed_global_dns = list_has_sing_box_dns(server_list);

    uci_delete("dhcp.@dnsmasq[0].server");
    if (length(backup_servers) > 0) {
        for (let value in backup_servers)
            uci_add_list("dhcp.@dnsmasq[0].server", value);
        uci_delete("dhcp.@dnsmasq[0].prokop_server");
    }
    else {
        for (let value in words(server_list)) {
            if (!is_sing_box_dns(value))
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
    if (legacy_runtime_owns_dnsmasq()) {
        log("dnsmasq is not configured: it belongs to the running " + legacy.PRODUCT, "error");
        return false;
    }

    // Before any backup: the originals the old product saved are the ones.
    let adopted = adopt_legacy_backups();
    if (as_string(force) != "force" && uci_get(CONFIG_NAME + ".settings.shutdown_correctly") == "0") {
        if (dnsmasq_default_config_is_complete()) {
            log("Previous Prokop shutdown was unclean; dnsmasq already points to sing-box", "info");
            if (killswitch_dns_apply(false)) {
                uci_commit("dhcp");
                return restart_dnsmasq();
            }
            // Backup options only: dnsmasq does not read them.
            if (adopted)
                uci_commit("dhcp");
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
    if (legacy_runtime_owns_dnsmasq()) {
        log("dnsmasq is not restored: it belongs to the running " + legacy.PRODUCT, "warn");
        return true;
    }

    if (!quiet)
        log("Restoring DNS settings in dnsmasq", "info");
    let adopted = adopt_legacy_backups();
    if (as_string(force) != "force" && uci_get(CONFIG_NAME + ".settings.shutdown_correctly") == "1") {
        if (!dnsmasq_has_prokop_dns()) {
            log("dnsmasq already uses non-Prokop DNS settings; restore is not required", "info");
            if (killswitch_dns_apply(true)) {
                uci_commit("dhcp");
                return restart_dnsmasq();
            }
            if (adopted)
                uci_commit("dhcp");
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
    if (legacy_runtime_owns_dnsmasq()) {
        log("DNS rollback skipped: dnsmasq belongs to the running " + legacy.PRODUCT, "warn");
        return true;
    }

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
    exit(killswitch_dns_refresh(ARGV[1] == "release-legacy") ? 0 : 1);
else if (mode == "killswitch-status")
    exit(killswitch_dns_status() ? 0 : 1);

warn("Usage: dns/apply.uc <configure|restore|failsafe-restore|has-prokop-dns|has-managed-state|default-config-complete|killswitch-refresh [release-legacy]|killswitch-status>\n");
exit(1);
