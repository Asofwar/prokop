#!/usr/bin/env ucode

// The address that sing-box serves its LAN inbounds and the Clash API on.
// singbox/runtime.uc generates the configuration with it, and
// diagnostics/runtime.uc reaches the Clash API on it in-process: a Clash API
// request (the Priority worker, the dashboard, every UI state poll) does not
// start an interpreter just to ask for it (UC-148).

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let option = common.option;

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_output_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));

    let pipe = fs.popen(join(" ", parts), "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function whitespace_items(value) {
    let result = [];
    if (type(value) == "array") {
        for (let item in value) {
            item = as_string(item);
            if (item != "")
                push(result, item);
        }
        return result;
    }

    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function ip_addr_first_inet4(data) {
    for (let line in split(as_string(data), "\n")) {
        let matched = match(line, /inet[ \t]+([0-9.]+)\//);
        if (matched)
            return as_string(matched[1]);
    }
    return "";
}

function network_interface_ipv4(name) {
    let data = command_output_from_args([ "ubus", "call", "network.interface." + as_string(name), "status" ]);
    try {
        let value = json(data);
        let addresses = array_or_empty(object_or_empty(value)["ipv4-address"]);
        if (length(addresses) > 0)
            return as_string(object_or_empty(addresses[0]).address);
    }
    catch (e) {
    }
    return "";
}

function device_ipv4_address(device) {
    return ip_addr_first_inet4(command_output_from_args([ "ip", "-4", "addr", "show", "dev", as_string(device) ]));
}

// log(message, level), when given, tells about a manual address and about
// one that could not be found. Read-only queries pass none: they run with
// every UI state poll and Clash API request and leave syslog alone; the
// configuration generation tells (UC-149).
function service_listen_address(settings, log) {
    let configured = option(settings, "service_listen_address", "");
    if (configured != "") {
        if (log)
            log("service_listen_address is set manually; automatic listen-address detection is skipped", "warn");
        return configured;
    }

    let address = network_interface_ipv4("lan");
    if (address != "")
        return address;

    for (let iface in whitespace_items(option(settings, "source_network_interfaces", "br-lan"))) {
        address = network_interface_ipv4(iface);
        if (address != "")
            return address;
        address = device_ipv4_address(iface);
        if (address != "")
            return address;
    }

    if (log)
        log("Failed to determine the listening IP address. Please open an issue to report this problem: https://github.com/Asofwar/prokop/issues", "error");
    return "";
}

return {
    device_ipv4_address,
    ip_addr_first_inet4,
    service_listen_address
};
