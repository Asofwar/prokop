// Compare two isolated SOCKS paths. Recommendations never mutate UCI.
let fs = require("fs");
let c = require("experiments.common");
let ip = require("core.ip");
let identity = require("core.process_identity");
let uci = require("core.uci");
const LIB = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const DIR = getenv("PROKOP_SMART_DETECT_DIR") || "/var/run/prokop/smart-detect";
const CONFIG = getenv("SB_CONFIG") || "/etc/sing-box/config.json";
const BIN = getenv("SB_BIN") || "/usr/bin/sing-box";
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
        dns: { servers: [ { type: "udp", tag: "probe-dns", server: resolver } ], final: "probe-dns", strategy: "ipv4_only" },
        inbounds: [ { type: "socks", tag: "probe-direct", listen: "127.0.0.1", listen_port: 4590 },
            { type: "socks", tag: "probe-proxy", listen: "127.0.0.1", listen_port: 4591 } ],
        outbounds,
        route: { default_mark: source.route?.default_mark || 0x08000000, default_domain_resolver: "probe-dns", final: "direct-out",
            rules: [ { inbound: "probe-direct", action: "route", outbound: "direct-out" },
                { inbound: "probe-proxy", action: "route", outbound: target } ] }
    };
}
function ports_free() {
    let text = c.capture([ "ss", "-H", "-lnt" ]);
    return text.code == 0 && match(text.output, /:459[01][ \t]/) == null;
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
        if (!ports_free()) return c.fail("probe_ports_unavailable");
        let source = c.read(CONFIG, null);
        if (source == null) return c.fail("runtime_config_unavailable");
        let resolver = uci.get("prokop.settings.bootstrap_dns_server") || "77.88.8.8";
        if (type(resolver) == "array") resolver = resolver[0];
        if (!ip.valid_ip(resolver)) return c.fail("invalid_bootstrap_resolver");
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
            let listeners = c.capture([ "ss", "-H", "-lntp" ]);
            let owned = filter(split(listeners.output, "\n"), (line) => index(line, "pid=" + pid + ",") >= 0);
            ready = length(filter(owned, (line) => match(line, /127\.0\.0\.1:459[01][ \t]/) != null)) == 2;
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
if (mode == "fixture-config") c.reply(probe_config(c.read(ARGV[1], {}), c.value(ARGV[2]), "77.88.8.8") || c.fail("missing_target"));
c.reply(c.fail("invalid_action"));
