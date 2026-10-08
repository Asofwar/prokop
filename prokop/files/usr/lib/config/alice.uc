#!/usr/bin/env ucode

// Adapted from petrouspetr-pixel/trafira b3832a9 (GPL-2.0). See docs/design/FORK_EXPERIMENTS.md.

// Alice Mode settings shared by nftables, the validator, signatures and diagnostics.

let common = require("core.common");
let core_ip = require("core.ip");

const LIST_MODE_ALLOW = "allow";
const LIST_MODE_DENY = "deny";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function string_list(section, key) {
    let result = [];
    for (let item in common.list_option(object_or_empty(section), key)) {
        item = trim(as_string(item));
        if (item != "")
            push(result, item);
    }
    return result;
}

function list_mode(settings) {
    let value = as_string(object_or_empty(settings).alice_list_mode);
    return value == LIST_MODE_DENY ? LIST_MODE_DENY : LIST_MODE_ALLOW;
}

function config(settings) {
    settings = object_or_empty(settings);
    return {
        enabled: common.bool_option(settings, "alice_mode_enabled", false),
        list_mode: list_mode(settings),
        ips: string_list(settings, "alice_ips"),
        macs: map(string_list(settings, "alice_macs"), (mac) => lc(mac)),
        interfaces: string_list(settings, "alice_interfaces")
    };
}

function valid_interface_name(value) {
    return match(as_string(value), /^[A-Za-z0-9_.@-]+\*?$/) != null;
}

// nftables ifname sets treat a trailing "*" as a prefix wildcard.
function interface_matches(pattern, name) {
    pattern = as_string(pattern);
    name = as_string(name);
    if (substr(pattern, length(pattern) - 1) == "*")
        return substr(name, 0, length(pattern) - 1) == substr(pattern, 0, length(pattern) - 1);
    return pattern == name;
}

function interface_in_list(patterns, name) {
    for (let pattern in patterns)
        if (interface_matches(pattern, name))
            return true;
    return false;
}

// nft rejects overlapping ifname intervals, so names covered by another wildcard are dropped.
function nft_interface_elements(patterns) {
    let result = [];
    for (let name in patterns) {
        let covered = false;
        for (let other in patterns)
            if (other != name && substr(other, length(other) - 1) == "*" && interface_matches(other, name))
                covered = true;
        if (!covered && index(result, name) < 0)
            push(result, name);
    }
    return result;
}

// Mirrors the nftables alice_gate chain: interface, then MAC, then source IP.
function match_device(alice, device) {
    device = object_or_empty(device);
    for (let pattern in alice.interfaces)
        if (interface_matches(pattern, device.interface))
            return "interface:" + pattern;

    let mac = lc(as_string(device.mac));
    if (mac != "")
        for (let item in alice.macs)
            if (item == mac)
                return "mac:" + item;

    for (let ip in (type(device.ips) == "array" ? device.ips : []))
        for (let item in alice.ips)
            if (core_ip.ip_in_cidr(ip, item))
                return "ip:" + item;

    return null;
}

function routes_through_prokop(alice, matched_by) {
    return (alice.list_mode == LIST_MODE_ALLOW) == (matched_by != null);
}

function signature_body(settings, add_value, body) {
    let alice = config(settings);
    // Disabled mode adds nothing so existing signatures stay stable.
    if (!alice.enabled)
        return body;

    body = add_value(body, "settings.alice_mode_enabled", "1");
    body = add_value(body, "settings.alice_list_mode", alice.list_mode);
    body = add_value(body, "settings.alice_ips", join(" ", alice.ips));
    body = add_value(body, "settings.alice_macs", join(" ", alice.macs));
    body = add_value(body, "settings.alice_interfaces", join(" ", alice.interfaces));
    return body;
}

return {
    LIST_MODE_ALLOW,
    LIST_MODE_DENY,
    config,
    valid_interface_name,
    interface_matches,
    interface_in_list,
    nft_interface_elements,
    match_device,
    routes_through_prokop,
    signature_body
};
