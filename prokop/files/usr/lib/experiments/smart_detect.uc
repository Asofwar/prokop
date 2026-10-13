// Compare two isolated SOCKS paths. Recommendations never mutate UCI.
let fs = require("fs");
let c = require("experiments.common");
let ip = require("core.ip");
let identity = require("core.process_identity");
let uci = require("core.uci");
let dns = require("singbox.dns");
let constants = require("singbox.constants");
const LIB = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const DIR = getenv("PROKOP_SMART_DETECT_DIR") || "/var/run/prokop/smart-detect";
const CONFIG = getenv("SB_CONFIG") || "/etc/sing-box/config.json";
const BIN = getenv("SB_BIN") || "/usr/bin/sing-box";
const PROC = getenv("PROKOP_SMART_DETECT_PROC") || "/proc";
const PORTS = { "11EE": 4590, "11EF": 4591 };
function domain(host) {
    if (length(host) > 253 || match(host, /^[a-z0-9.-]+$/) == null || ip.valid_ip(host)) return false;
    let labels = split(host, ".");
    if (length(labels) < 2) return false;
    for (let part in labels)
        if (length(part) < 1 || length(part) > 63 || match(part, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) == null) return false;
    return index([ "local", "lan", "localhost", "internal", "home", "arpa" ], labels[length(labels) - 1]) < 0;
}
function verdict(direct, proxy) {
    if (proxy != 0) return "proxy_failed";
    if (direct == 0) return "direct_works";
    if (index([ 7, 28, 35, 52, 56 ], direct) >= 0) return "candidate";
    return direct == 6 ? "dns_failed" : "inconclusive";
}
// The bootstrap DNS the running sing-box uses (after failover), else the
// active one of the configured list. `uci.get` joins a list into one string,
// so it never named a single server once two were configured.
function probe_resolver(source, settings) {
    let server = null;
    for (let entry in source?.dns?.servers || [])
        if (entry?.tag == constants.BOOTSTRAP_DNS_SERVER_TAG) server = entry;
    if (server?.type != "udp") server = dns.bootstrap_config(settings || {}, null);
    let port = server?.server_port == null ? 53 : server.server_port;
    if (!ip.valid_ip(c.value(server?.server)) || type(port) != "int" || port < 1 || port > 65535) return null;
    return { server: server.server, server_port: port };
}
function probe_config(source, target, resolver) {
    let index_by_tag = {}, selected = {}, outbounds = [];
    for (let out in source.outbounds || []) index_by_tag[out.tag] = out;
    function add(tag) {
        if (selected[tag]) return true;
        let out = index_by_tag[tag];
        if (out == null) return false;
        selected[tag] = true;
        if (out.detour != null && !add(out.detour)) return false;
        for (let member in out.outbounds || []) if (!add(member)) return false;
        // Cloned private config. Resolver and mark guarantee a separate path.
        out = json(sprintf("%J", out));
        if (out.server != null) out.domain_resolver = "probe-dns";
        push(outbounds, out);
        return true;
    }
    if (!add(target)) return null;
    if (!selected["direct-out"]) push(outbounds, { type: "direct", tag: "direct-out" });
    return {
        log: { disabled: true },
        dns: { servers: [ { type: "udp", tag: "probe-dns", server: resolver.server, server_port: resolver.server_port } ], final: "probe-dns", strategy: "ipv4_only" },
        inbounds: [ { type: "socks", tag: "probe-direct", listen: "127.0.0.1", listen_port: 4590 },
            { type: "socks", tag: "probe-proxy", listen: "127.0.0.1", listen_port: 4591 } ],
        outbounds,
        route: { default_mark: source.route?.default_mark || 0x08000000, default_domain_resolver: "probe-dns", final: "direct-out",
            rules: [ { inbound: "probe-direct", action: "route", outbound: "direct-out" },
                { inbound: "probe-proxy", action: "route", outbound: target } ] }
    };
}
// TCP listeners on the probe ports from /proc/net/tcp{,6}: `ss` is not part
// of a stock OpenWrt (iproute2 ships it separately), and a missing tool must
// not read as busy ports. null when the socket table cannot be read.
function probe_listeners() {
    let table = fs.readfile(PROC + "/net/tcp");
    if (table == null) return null;
    let found = [];
    for (let file in [ "tcp", "tcp6" ]) {
        let text = file == "tcp" ? table : fs.readfile(PROC + "/net/" + file);
        for (let line in split(c.value(text), "\n")) {
            let f = split(trim(line), /[ \t]+/);
            if (length(f) < 10 || f[3] != "0A") continue;
            let colon = rindex(f[1], ":");
            let port = colon < 0 ? null : PORTS[uc(substr(f[1], colon + 1))];
            if (port == null) continue;
            let address = uc(substr(f[1], 0, colon));
            // 127.0.0.1 in host byte order of either endianness.
            push(found, { port, inode: f[9], loopback: address == "0100007F" || address == "7F000001" });
        }
    }
    return found;
}
function ports_free(listeners) {
    return listeners != null && length(listeners) == 0;
}
// Both probe ports listen on 127.0.0.1 through sockets of this very process.
function ports_owned(listeners, pid) {
    let inodes = {};
    for (let link in fs.glob(PROC + "/" + pid + "/fd/*")) {
        let m = match(c.value(fs.readlink(link)), /^socket:\[([0-9]+)\]$/);
        if (m != null) inodes[m[1]] = true;
    }
    let owned = {};
    for (let l in listeners || []) {
        if (!l.loopback || !inodes[l.inode]) return false;
        owned[l.port] = true;
    }
    return owned[4590] === true && owned[4591] === true;
}
function probe(host, port) {
    return c.capture([ "curl", "--silent", "--output", "/dev/null", "--noproxy", "", "--proxy", "socks5h://127.0.0.1:" + port,
        "--proto", "=https", "--connect-timeout", "3", "--max-time", "5", "https://" + host + "/" ]).code;
}
function candidates() {
    let observed = {}, log = c.capture([ "logread", "-l", "150" ]).output;
    for (let line in split(log, "\n")) {
        if (match(line, /i\/o timeout|connection reset|connect:|TLS handshake|context deadline/) == null) continue;
        for (let word in split(line, /[ \t\"'()]+/)) {
            let found = match(word, /^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})(:[0-9]+)?$/);
            if (found != null && domain(lc(found[1]))) observed[lc(found[1])] = true;
        }
    }
    return slice(keys(observed), 0, 32);
}
function run(host, target) {
    host = lc(host);
    if (!domain(host) || match(target, /^[A-Za-z0-9_-]{1,100}$/) == null) return c.fail("invalid_input");
    if (!c.directory(DIR)) return c.fail("storage_unavailable");
    if (!c.locks.acquire(DIR + "/lock", c.self())) return c.fail("probe_busy");
    let args = [ BIN, "run", "-c", DIR + "/probe.json" ];
    let pidfile = DIR + "/probe.pid";
    function work() {
        let before = probe_listeners();
        if (before == null) return c.fail("probe_start_failed");
        if (!ports_free(before)) return c.fail("probe_ports_unavailable");
        let source = c.read(CONFIG, null);
        if (source == null) return c.fail("runtime_config_unavailable");
        let resolver = probe_resolver(source, uci.get_all("prokop", "settings"));
        if (resolver == null) return c.fail("invalid_bootstrap_resolver");
        let config = probe_config(source, target, resolver);
        if (config == null || !c.write(DIR + "/probe.json", config, false)) return c.fail("probe_config_failed");
        if (c.capture([ BIN, "check", "-c", DIR + "/probe.json" ]).code != 0) return c.fail("probe_config_unsupported");
        let child = fs.popen(c.command(args) + " >/dev/null 2>&1 & echo $!", "r");
        let pid = child ? trim(child.read("all")) : "";
        if (child) child.close();
        if (!identity.record(pidfile, pid)) return c.fail("probe_start_failed");
        // Wait for both ports; probes are never sent to an unrelated listener.
        let ready = false;
        for (let attempt = 0; attempt < 20; attempt++) {
            if (identity.matches(pidfile, BIN, args, true, true) == "") break;
            ready = ports_owned(probe_listeners(), pid);
            if (ready) break;
            system("sleep 0.1");
        }
        if (!ready) return c.fail("probe_not_ready");
        let direct = probe(host, 4590), proxy = probe(host, 4591), result = verdict(direct, proxy);
        let state = c.read(DIR + "/results.json", {}), previous = state[host], now = c.uptime();
        let count = result == "candidate" ? 1 : 0;
        if (result == "candidate" && previous?.target == target && previous?.verdict == "candidate" &&
            now - int(previous.checked_uptime) >= 120 && now - int(previous.checked_uptime) <= 1800) count = int(previous.count || 1) + 1;
        let record = { host, target, verdict: result, direct_exit: direct, proxy_exit: proxy, count, confirmed: count >= 2, checked_uptime: now };
        state[host] = record;
        // RAM-only bounded history.
        for (let key in keys(state)) if (now - int(state[key].checked_uptime) > 1800) delete state[key];
        while (length(keys(state)) > 64) delete state[keys(state)[0]];
        if (!c.write(DIR + "/results.json", state, false)) return c.fail("result_write_failed");
        return { success: true, recommendation: record };
    }
    let result;
    try { result = work(); } catch (e) { result = c.fail("probe_failed"); }
    {
        identity.signal(pidfile, BIN, args, true, "TERM", true);
        for (let attempt = 0; attempt < 10 && identity.matches(pidfile, BIN, args, true, true) != ""; attempt++) system("sleep 0.1");
        identity.signal(pidfile, BIN, args, true, "KILL", true);
        fs.unlink(pidfile); fs.unlink(DIR + "/probe.json");
        c.locks.release(DIR + "/lock", c.self());
    }
    return result;
}
let mode = c.value(ARGV[0]);
if (mode == "status") c.reply({ success: true, recommendations: values(c.read(DIR + "/results.json", {})), candidates: candidates() });
if (mode == "run") c.reply(run(c.value(ARGV[1]), c.value(ARGV[2])));
if (mode == "fixture") c.reply({ valid: domain(c.value(ARGV[1])), verdict: verdict(int(ARGV[2]), int(ARGV[3])) });
if (mode == "fixture-ports") {
    let listeners = probe_listeners();
    c.reply({ readable: listeners != null, free: ports_free(listeners), owned: ports_owned(listeners, c.value(ARGV[1])) });
}
if (mode == "fixture-config") c.reply(probe_config(c.read(ARGV[1], {}), c.value(ARGV[2]), { server: "77.88.8.8", server_port: 53 }) || c.fail("missing_target"));
if (mode == "fixture-resolver") c.reply({ resolver: probe_resolver(c.read(ARGV[1], {}), c.read(ARGV[2], {})) });
c.reply(c.fail("invalid_action"));
