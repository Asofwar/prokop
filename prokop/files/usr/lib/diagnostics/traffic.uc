#!/usr/bin/ucode

// Per-device traffic accounting (Monitoring > Devices).
//
// A table of its own, ProkopTraffic, counts what each LAN address sends and
// receives: packets that arrive on a source interface (settings
// source_network_interfaces) update a dynamic set keyed by the source
// address, packets that leave through one update a set keyed by the
// destination address. Every set element carries an nft counter. The table
// has no verdicts and no marks: it only counts, its chains accept, and a full
// set only stops counting new addresses, it never drops a packet.
//
// The ingress chain runs before everything else of the router (raw - 10)
// and the egress chain after NAT, so a connection that sing-box takes over
// with TPROXY is counted like any other: its packets cross prerouting from
// the device and postrouting back to it. Only a source the router would
// route back through the interface the packet came in on is counted
// (TRF-1): a client that forges source addresses from elsewhere neither
// fills the sets nor books its traffic on another network's address.
// What is counted, and what is not, the Devices page says (TRF-6). What fw4 flow offloading
// accelerates no longer crosses these hooks; the reader says so instead of
// reporting a partial count as the total.
//
// The table lives while Prokop runs: start and every successful reload
// (service/lifecycle.uc) keep it when it is already the one this
// configuration asks for, and build it afresh (counters from zero) when it is
// missing or different; stop and the removals delete it.

let fs = require("fs");
let uci = require("core.uci");
let connections = require("config.connections");

function env(name, fallback) {
    let value = getenv(name);
    return value == null || value == "" ? fallback : value;
}

const CONFIG_NAME = env("PROKOP_CONFIG_NAME", "prokop");
const TABLE = "ProkopTraffic";
const PROD_TABLE = env("NFT_TABLE_NAME", "ProkopTable");
const RUNTIME_STATE_DIR = env("PROKOP_RUNTIME_STATE_DIR", "/var/run/prokop");
const STATE_FILE = RUNTIME_STATE_DIR + "/traffic.json";
const IPV4_SET_SIZE = 1024;
const IPV6_SET_SIZE = 4096;
// An address that sent and received nothing for this long leaves the set.
const ELEMENT_TIMEOUT = "7d";
// The reader reports the addresses with the most traffic, at most this
// many (TRF-2): rpcd and ubus refuse a large answer, and the page polls
// every few seconds.
const DEVICES_MAX = 200;
const PROC_UPTIME = env("PROKOP_PROC_UPTIME", "/proc/uptime");

function text(value) { return value == null ? "" : "" + value; }
function quote(value) { return "'" + replace(text(value), /'/g, "'\\''") + "'"; }
function command(args) {
    let values = [];
    for (let arg in args) push(values, quote(arg));
    return join(" ", values);
}
function success(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function command_output(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return null;
    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? text(data) : null;
}
function log_message(message, level) {
    success([ "logger", "-t", "prokop", "[" + (level || "info") + "] " + message ]);
}

function settings_value(name, fallback) {
    uci.refresh(CONFIG_NAME);
    let value = uci.get(CONFIG_NAME + ".settings." + name);
    return value == null || value == "" ? fallback : value;
}

function enabled() {
    return trim(text(settings_value("device_traffic", "1"))) != "0";
}

// Interface names as the validator and the kill-switch read them
// (config/connections.uc valid_source_interface_name, NET-14); a name nft
// could read as anything else is left out.
function interfaces() {
    let value = settings_value("source_network_interfaces", "br-lan");
    let names = type(value) == "array" ? value : split(trim(text(value)), /[ \t\r\n]+/);
    let result = [];
    for (let name in names) {
        name = trim(text(name));
        if (name != "" && connections.valid_source_interface_name(name) && index(result, name) < 0)
            push(result, name);
    }
    return result;
}

// Seconds since boot: unlike the clock, right before NTP has set it.
function uptime() {
    let m = match(text(fs.readfile(PROC_UPTIME)), /^([0-9]+)/);
    return m == null ? null : int(m[1]);
}

function table_present(name) {
    return success([ "nft", "list", "table", "inet", name ]);
}

// One transaction: the add makes the delete valid when there is no table
// yet, and the new table replaces the old one whole.
function batch(names) {
    let set_options = "flags dynamic,timeout; timeout " + ELEMENT_TIMEOUT + "; counter;";
    let text_value =
        "add table inet " + TABLE + "\n" +
        "delete table inet " + TABLE + "\n" +
        "add table inet " + TABLE + "\n" +
        "add set inet " + TABLE + " tx4 { type ipv4_addr; size " + IPV4_SET_SIZE + "; " + set_options + " }\n" +
        "add set inet " + TABLE + " rx4 { type ipv4_addr; size " + IPV4_SET_SIZE + "; " + set_options + " }\n" +
        "add set inet " + TABLE + " tx6 { type ipv6_addr; size " + IPV6_SET_SIZE + "; " + set_options + " }\n" +
        "add set inet " + TABLE + " rx6 { type ipv6_addr; size " + IPV6_SET_SIZE + "; " + set_options + " }\n" +
        "add chain inet " + TABLE + " ingress { type filter hook prerouting priority -310; policy accept; }\n" +
        "add chain inet " + TABLE + " egress { type filter hook postrouting priority 110; policy accept; }\n";
    if (!length(names))
        return text_value;
    // One set of the interfaces: two rules per hook whatever their number.
    let quoted = [];
    for (let name in names)
        push(quoted, sprintf("%J", name));
    text_value +=
        "add set inet " + TABLE + " ifaces { type ifname; flags interval; auto-merge; }\n" +
        "add element inet " + TABLE + " ifaces { " + join(", ", quoted) + " }\n" +
        "add rule inet " + TABLE + " ingress iifname @ifaces fib saddr . iif oif exists update @tx4 { ip saddr }\n" +
        "add rule inet " + TABLE + " ingress iifname @ifaces fib saddr . iif oif exists update @tx6 { ip6 saddr }\n" +
        "add rule inet " + TABLE + " egress oifname @ifaces update @rx4 { ip daddr }\n" +
        "add rule inet " + TABLE + " egress oifname @ifaces update @rx6 { ip6 daddr }\n";
    return text_value;
}

function read_state() {
    let data = fs.readfile(STATE_FILE);
    if (data == null) return null;
    try {
        let value = json(data);
        return type(value) == "object" ? value : null;
    }
    catch (e) {
        return null;
    }
}

function write_state(value) {
    if (fs.stat(RUNTIME_STATE_DIR) == null)
        fs.mkdir(RUNTIME_STATE_DIR, 0755);
    let tmp = STATE_FILE + ".tmp";
    if (fs.writefile(tmp, sprintf("%J\n", value)) == null)
        return false;
    return fs.rename(tmp, STATE_FILE) == true;
}

function remove() {
    if (table_present(TABLE))
        success([ "nft", "delete", "table", "inet", TABLE ]);
    fs.unlink(STATE_FILE);
    return 0;
}

function apply(rules) {
    // A fresh file of mktemp (TMPDIR or /tmp), never a fixed path that a
    // symlink could point elsewhere.
    let path = trim(text(command_output([ "mktemp" ])));
    if (path == "") return false;
    let applied = fs.writefile(path, rules) != null && success([ "nft", "-f", path ]);
    fs.unlink(path);
    return applied;
}

// Counts only while Prokop's own table is there: a start or reload calls it
// after the runtime is up, and nothing is counted for a stopped Prokop.
function sync() {
    if (!enabled() || !table_present(PROD_TABLE))
        return remove();
    let names = interfaces();
    if (!length(names))
        return remove();

    let rules = batch(names);
    let state = read_state();
    if (state != null && state.spec == rules && table_present(TABLE))
        return 0;

    if (!apply(rules)) {
        remove();
        log_message("Device traffic accounting could not be set up; Monitoring shows no per-device counters", "warn");
        return 1;
    }
    // The clock may still be the build date before NTP (no RTC, TRF-5):
    // the reader dates the start from the uptime.
    if (!write_state({ since: time(), since_uptime: uptime(), spec: rules }))
        log_message("Device traffic accounting runs, but the time it started could not be saved", "warn");
    return 0;
}

function json_listing(args) {
    let output = command_output(args);
    if (output == null) return null;
    try {
        let value = json(output);
        return type(value) == "object" && type(value.nftables) == "array" ? value.nftables : null;
    }
    catch (e) {
        return null;
    }
}

// Unicast host addresses only: what a device answers to. Broadcast
// (also the directed broadcast of the router's networks, `broadcasts`),
// multicast, loopback and the unspecified address are not a device.
function host_address(address, family, broadcasts) {
    address = lc(text(address));
    if (family == 4) {
        let m = match(address, /^([0-9]+)\.[0-9]+\.[0-9]+\.[0-9]+$/);
        if (m == null) return false;
        let first = int(m[1]);
        return address != "0.0.0.0" && address != "255.255.255.255" && first != 127 && (first < 224 || first > 239) &&
            !broadcasts[address];
    }
    return index(address, ":") >= 0 && address != "::" && address != "::1" && substr(address, 0, 2) != "ff";
}

function link_local6(address) {
    return match(lc(address), /^fe[89ab][0-9a-f]:/) != null;
}

function ip_json(args) {
    let output = command_output([ "ip", "-j", ...args ]);
    if (output == null) return [];
    try {
        let value = json(output);
        return type(value) == "array" ? value : [];
    }
    catch (e) {
        return [];
    }
}

// The broadcast addresses of the router's IPv4 networks (observed).
function broadcast_addresses() {
    let result = {};
    for (let link in ip_json([ "-4", "addr", "show" ]))
        for (let info in (type(link?.addr_info) == "array" ? link.addr_info : []))
            if (type(info?.broadcast) == "string" && info.broadcast != "")
                result[info.broadcast] = true;
    return result;
}

// Address -> MAC from the router's neighbour table now (observed): the
// page puts the IPv4 and IPv6 addresses of one device together by it
// (TRF-3), also an IPv6 address the DHCP leases and host hints do not know.
function neighbour_macs() {
    let result = {};
    for (let entry in ip_json([ "neigh", "show" ])) {
        let mac = lc(text(entry?.lladdr));
        let state = type(entry?.state) == "array" ? entry.state : [];
        if (match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) == null || index(state, "FAILED") >= 0 ||
            index(state, "INCOMPLETE") >= 0 || mac == "00:00:00:00:00:00")
            continue;
        result[lc(text(entry.dst))] = mac;
    }
    return result;
}

// fw4 flow offloading: flows it accelerates bypass prerouting and
// postrouting, so the counters miss them. Observed from the flowtables that
// exist, not from the firewall configuration.
function offload_state() {
    let items = json_listing([ "nft", "-j", "list", "flowtables" ]);
    if (items == null) return "unknown";
    let found = "none";
    for (let item in items) {
        let flowtable = item?.flowtable;
        if (type(flowtable) != "object") continue;
        let flags = flowtable.flags;
        if (flags == "offload" || (type(flags) == "array" && index(flags, "offload") >= 0))
            return "hardware";
        found = "software";
    }
    return found;
}

const SET_SIZES = { tx4: IPV4_SET_SIZE, rx4: IPV4_SET_SIZE, tx6: IPV6_SET_SIZE, rx6: IPV6_SET_SIZE };

// The devices by address, the most traffic first, and the sets that are
// full: those count no new address until one of theirs times out (TRF-1).
function counters(items, broadcasts, macs) {
    let devices = {};
    let order = [];
    let full = [];
    let sets = { tx4: [ "tx", 4 ], rx4: [ "rx", 4 ], tx6: [ "tx", 6 ], rx6: [ "rx", 6 ] };
    for (let item in items) {
        let set = item?.set;
        if (type(set) != "object" || set.table != TABLE || !exists(sets, set.name)) continue;
        let direction = sets[set.name][0];
        let family = sets[set.name][1];
        let elements = type(set.elem) == "array" ? set.elem : [];
        if (length(elements) >= SET_SIZES[set.name] && index(full, set.name) < 0)
            push(full, set.name);
        for (let element in elements) {
            let entry = type(element) == "object" ? element.elem : null;
            if (type(entry) != "object" || type(entry.counter) != "object") continue;
            let address = text(entry.val);
            if (!host_address(address, family, broadcasts)) continue;
            if (!exists(devices, address)) {
                devices[address] = { address, family, tx_bytes: 0, tx_packets: 0, rx_bytes: 0, rx_packets: 0 };
                let mac = macs[lc(address)];
                if (mac != null) devices[address].mac = mac;
                push(order, address);
            }
            devices[address][direction + "_bytes"] += int(entry.counter.bytes || 0);
            devices[address][direction + "_packets"] += int(entry.counter.packets || 0);
        }
    }
    let result = [];
    for (let address in order) {
        let device = devices[address];
        // A link-local address alone is no device: its neighbour discovery
        // and mDNS belong to one the router knows by MAC, or to none.
        if (device.family == 6 && link_local6(address) && device.mac == null) continue;
        push(result, device);
    }
    sort(result, (a, b) => (b.tx_bytes + b.rx_bytes) - (a.tx_bytes + a.rx_bytes) || (a.address < b.address ? -1 : (a.address > b.address ? 1 : 0)));
    return { devices: result, full };
}

// Read-only: what the counters hold now. "state" tells why there are none:
// disabled in the settings, Prokop not running, or set up but unreadable.
// devices: at most DEVICES_MAX, the most traffic first; total_devices
// counts them all. full: the sets that count no new address.
function get() {
    let result = {
        state: "ok", since: null, now: time(), offload: "unknown",
        interfaces: interfaces(), devices: [], total_devices: 0, truncated: false, full: []
    };
    if (!table_present(TABLE)) {
        if (!enabled()) result.state = "disabled";
        else if (!table_present(PROD_TABLE)) result.state = "stopped";
        else result.state = "unavailable";
        return result;
    }
    let items = json_listing([ "nft", "-j", "list", "table", "inet", TABLE ]);
    if (items == null) {
        result.state = "unavailable";
        return result;
    }
    let state = read_state();
    if (state != null && type(state.since) == "int" && state.since > 0) {
        result.since = state.since;
        // Dated from the uptime when the start recorded it and the clock
        // has moved since (NTP set it after a boot without RTC, TRF-5).
        // Within a couple of minutes the recorded time stands: the two
        // clocks tick apart by a second, and the page reads a new start
        // as rebuilt counters.
        let now_uptime = uptime();
        if (type(state.since_uptime) == "int" && now_uptime != null && now_uptime >= state.since_uptime) {
            let dated = result.now - (now_uptime - state.since_uptime);
            if (dated - state.since > 120 || state.since - dated > 120)
                result.since = dated;
        }
    }
    result.offload = offload_state();
    let counted = counters(items, broadcast_addresses(), neighbour_macs());
    result.total_devices = length(counted.devices);
    result.truncated = result.total_devices > DEVICES_MAX;
    result.devices = result.truncated ? slice(counted.devices, 0, DEVICES_MAX) : counted.devices;
    result.full = counted.full;
    return result;
}

let mode = ARGV[0] || "get";
if (mode == "get") print(sprintf("%J\n", get()));
else if (mode == "sync") exit(sync());
else if (mode == "remove") exit(remove());
else if (mode == "batch") {
    // Prints the batch sync() would submit; changes nothing (tests).
    print(batch(length(ARGV) > 1 ? slice(ARGV, 1) : interfaces()));
}
else exit(1);
