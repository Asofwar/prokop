#!/usr/bin/env ucode

// Adapted from petrouspetr-pixel/trafira b3832a9 (GPL-2.0). See docs/design/FORK_EXPERIMENTS.md.

// Alice Mode device report for the dashboard: which LAN clients and WireGuard
// peers currently use Trafira, which go direct, and why.

let fs = require("fs");
let common = require("core.common");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let alice_config = require("config.alice");

const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || "prokop";
const DHCP_LEASES_FILE = getenv("PROKOP_DHCP_LEASES_FILE") || "/tmp/dhcp.leases";
const WIREGUARD_ONLINE_SECONDS = 180;
const ONLINE_NEIGH_STATES = { REACHABLE: true, DELAY: true, PROBE: true, PERMANENT: true };
const SEEN_NEIGH_STATES = { STALE: true, NOARP: true };

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function command_capture(args) {
    let command = join(" ", map(args, (arg) => "'" + replace(as_string(arg), "'", "'\\''") + "'")) + " 2>/dev/null";
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { ok: false, output: "" };
    let data = pipe.read("all");
    let status = normalize_status(pipe.close());
    return { ok: status == 0, output: as_string(data) };
}

function parse_neighbor_result(result) {
    if (!result.ok)
        return { ok: false };

    try {
        let value = json(as_string(result.output));
        return type(value) == "array"
            ? { ok: true, entries: value }
            : { ok: false };
    }
    catch (e) {
        return { ok: false };
    }
}

function source_interfaces(settings) {
    let result = common.list_option(settings, "source_network_interfaces");
    return length(result) > 0 ? result : [ "br-lan" ];
}

function link_local(ip) {
    return core_ip.ip_in_cidr(ip, "fe80::/10");
}

function parse_leases(text) {
    let by_mac = {};
    let by_ip = {};
    let malformed = 0;
    for (let line in split(as_string(text), "\n")) {
        if (trim(line) == "")
            continue;
        let fields = split(trim(line), /[ \t]+/);
        if (length(fields) < 4 || !core_ip.valid_ip(fields[2])) {
            malformed++;
            continue;
        }
        if (fields[3] != "*") {
            by_ip[fields[2]] = fields[3];
            if (core_ip.valid_mac(fields[1]))
                by_mac[lc(fields[1])] = fields[3];
        }
    }
    return { by_mac, by_ip, malformed };
}

// Only neighbours on interfaces Trafira captures or the Alice list names are
// shown; uplink neighbours such as the ISP gateway are not client devices.
function lan_devices(neigh, leases, relevant_interfaces) {
    let devices = {};
    let order = [];
    let malformed = 0;

    for (let entry in array_or_empty(neigh)) {
        if (type(entry) != "object" || !core_ip.valid_ip(entry.dst) || as_string(entry.dev) == "" || type(entry.state) != "array") {
            malformed++;
            continue;
        }
        entry = object_or_empty(entry);
        let ip = as_string(entry.dst);
        let mac = lc(as_string(entry.lladdr));
        if (mac != "" && !core_ip.valid_mac(mac)) {
            malformed++;
            continue;
        }
        let states = array_or_empty(entry.state);
        let online = false;
        let seen = false;
        for (let state in states) {
            online = online || ONLINE_NEIGH_STATES[state] == true;
            seen = seen || SEEN_NEIGH_STATES[state] == true;
        }
        if (mac == "" || !core_ip.valid_ip(ip) || (!online && !seen) ||
            !alice_config.interface_in_list(relevant_interfaces, entry.dev))
            continue;

        let key = as_string(entry.dev) + "|" + mac;
        if (devices[key] == null) {
            devices[key] = {
                kind: "lan",
                name: leases.by_mac[mac] || "",
                mac,
                interface: as_string(entry.dev),
                ips: [],
                online: false,
                last_handshake: null
            };
            push(order, key);
        }

        let device = devices[key];
        device.online = device.online || online;
        if (!link_local(ip) && index(device.ips, ip) < 0)
            push(device.ips, ip);
        if (device.name == "" && leases.by_ip[ip])
            device.name = leases.by_ip[ip];
    }

    return {
        devices: filter(map(order, (key) => devices[key]), (device) => length(device.ips) > 0),
        malformed
    };
}

function wireguard_peer_names(peer_sections) {
    let result = {};
    for (let section in array_or_empty(peer_sections)) {
        section = object_or_empty(section);
        let name = as_string(section.description);
        if (section.public_key && name != "")
            result[as_string(section.public_key)] = name;
    }
    return result;
}

function strip_host_prefix(value) {
    let slash = index(value, "/");
    if (slash < 0)
        return value;
    let prefix = substr(value, slash + 1);
    return prefix == "32" || prefix == "128" ? substr(value, 0, slash) : value;
}

// Peers of `wg show all dump`. Upstream peers (a default route in allowed-ips)
// are the router's own VPN clients, not devices, so they are skipped.
function wireguard_devices(dump, peer_sections, now) {
    let names = wireguard_peer_names(peer_sections);
    let devices = [];
    let malformed = 0;

    for (let line in split(as_string(dump), "\n")) {
        if (trim(line) == "")
            continue;
        let fields = split(trim(line), "\t");
        // Interface headers have five fields; peer rows have nine.
        if (length(fields) == 5 && match(fields[3], /^[0-9]+$/) != null)
            continue;
        if (length(fields) < 9 || match(fields[5], /^[0-9]+$/) == null) {
            malformed++;
            continue;
        }

        let allowed = [];
        let upstream = false;
        let invalid_allowed = false;
        for (let item in split(fields[4], ",")) {
            item = trim(item);
            if (item == "" || item == "(none)")
                continue;
            if (!core_ip.valid_ip_or_cidr(item)) {
                invalid_allowed = true;
                continue;
            }
            if (match(item, /\/0$/))
                upstream = true;
            push(allowed, strip_host_prefix(item));
        }
        if (invalid_allowed)
            malformed++;
        if (upstream || length(allowed) == 0)
            continue;

        let handshake = int(fields[5]);
        push(devices, {
            kind: "wireguard",
            name: names[fields[1]] || "",
            mac: "",
            interface: fields[0],
            ips: allowed,
            online: handshake > 0 && now - handshake <= WIREGUARD_ONLINE_SECONDS,
            last_handshake: handshake > 0 ? handshake : null
        });
    }

    return { devices, malformed };
}

function classify(device, alice, captured_interfaces) {
    let captured = alice_config.interface_in_list(captured_interfaces, device.interface);
    // Interface and MAC matches apply to every address. IP matches apply to
    // individual packets, so a dual-stack device or site subnet can be mixed.
    let matched_by = alice_config.match_device(alice, { ...device, ips: [] });
    let has_matched = matched_by != null;
    let has_unmatched = false;
    if (matched_by == null) {
        for (let ip in device.ips) {
            let coverage = core_ip.cidr_list_coverage(ip, alice.ips);
            has_matched = has_matched || coverage.any;
            has_unmatched = has_unmatched || !coverage.all;
            if (matched_by == null && coverage.matched != null)
                matched_by = "ip:" + coverage.matched;
        }
    }

    device.matched_by = matched_by;
    device.status = !captured ? "not_captured" :
        (has_matched && has_unmatched ? "mixed" :
            (alice_config.routes_through_prokop(alice, matched_by) ? "prokop" : "direct"));
    return device;
}

function warnings(alice, captured_interfaces) {
    let result = [];
    for (let name in alice.interfaces) {
        let captured = false;
        for (let source in captured_interfaces)
            if (alice_config.interface_matches(name, source) || alice_config.interface_matches(source, name))
                captured = true;
        if (!captured)
            push(result, { code: "interface_not_captured", value: name });
    }
    if (alice.list_mode == alice_config.LIST_MODE_ALLOW &&
        length(alice.ips) + length(alice.macs) + length(alice.interfaces) == 0)
        push(result, { code: "empty_allow_list", value: "" });
    return result;
}

function build_report(data) {
    data = object_or_empty(data);
    let settings = object_or_empty(data.settings);
    let alice = alice_config.config(settings);
    if (!alice.enabled)
        return { enabled: false };

    let captured_interfaces = source_interfaces(settings);
    let now = int(data.now || time());
    let neighbor_result;
    if (type(data.neighbor_result) == "object")
        neighbor_result = data.neighbor_result.output != null
            ? parse_neighbor_result(data.neighbor_result)
            : data.neighbor_result;
    else
        neighbor_result = type(data.neigh) == "array" ? { ok: true, entries: data.neigh } : { ok: false };
    let wireguard_result = type(data.wireguard_result) == "object"
        ? data.wireguard_result
        : (data.wg_dump != null ? { ok: true, output: data.wg_dump } : { ok: false });
    let lease_result = type(data.lease_result) == "object"
        ? data.lease_result
        : (data.leases != null ? { ok: true, output: data.leases } : { ok: false });
    let report_warnings = warnings(alice, captured_interfaces);
    let devices = [];
    let lease_data = lease_result.ok
        ? parse_leases(lease_result.output)
        : { by_mac: {}, by_ip: {}, malformed: 0 };

    if (!lease_result.ok)
        push(report_warnings, { code: "dhcp_source_unavailable", value: "" });
    else if (lease_data.malformed > 0)
        push(report_warnings, { code: "dhcp_source_partial", value: "" });

    if (neighbor_result.ok) {
        let entries = neighbor_result.entries;
        if (type(entries) != "array")
            neighbor_result = { ok: false };
        else {
            let lan = lan_devices(entries, lease_data, [ ...captured_interfaces, ...alice.interfaces ]);
            push(devices, ...lan.devices);
            if (lan.malformed > 0)
                push(report_warnings, { code: "neighbor_source_partial", value: "" });
        }
    }
    if (!neighbor_result.ok)
        push(report_warnings, { code: "neighbor_source_unavailable", value: "" });

    if (wireguard_result.ok) {
        let wireguard = wireguard_devices(wireguard_result.output, data.wireguard_peers, now);
        push(devices, ...wireguard.devices);
        if (wireguard.malformed > 0)
            push(report_warnings, { code: "wireguard_source_partial", value: "" });
    }
    else
        push(report_warnings, { code: "wireguard_source_unavailable", value: "" });

    return {
        enabled: true,
        dashboard_visible: common.bool_option(settings, "alice_dashboard_enabled", true),
        list_mode: alice.list_mode,
        source_interfaces: captured_interfaces,
        devices: map(devices, (device) => classify(device, alice, captured_interfaces)),
        warnings: report_warnings,
        generated_at: now
    };
}

function wireguard_peer_sections(dump) {
    let result = [];
    let seen = {};
    for (let line in split(as_string(dump), "\n")) {
        let iface = split(line, "\t")[0];
        if (!iface || seen[iface])
            continue;
        seen[iface] = true;
        push(result, ...array_or_empty(uci_core.section_objects("network", "wireguard_" + iface)));
    }
    return result;
}

function runtime_data() {
    let settings = object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
    if (!common.bool_option(settings, "alice_mode_enabled", false))
        return { settings };

    let neighbor_command = command_capture([ "ip", "-j", "neigh", "show" ]);
    let neighbor_result = parse_neighbor_result(neighbor_command);
    let wireguard_result = command_capture([ "wg", "show", "all", "dump" ]);
    let leases = fs.readfile(DHCP_LEASES_FILE);
    return {
        settings,
        neighbor_result,
        wireguard_result,
        lease_result: { ok: leases != null, output: as_string(leases) },
        wireguard_peers: wireguard_peer_sections(wireguard_result.output)
    };
}

let mode = ARGV[0] || "";

if (mode == "get-alice-devices")
    common.write_json(build_report(runtime_data()));
else if (mode == "get-alice-devices-fixture")
    common.write_json(build_report(common.read_json_file(ARGV[1])));
else {
    warn("Usage: alice.uc get-alice-devices | get-alice-devices-fixture <json>\n");
    exit(1);
}
