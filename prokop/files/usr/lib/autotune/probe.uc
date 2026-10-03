#!/usr/bin/env ucode

// One TCP/TLS/HTTPS probe for DPI autotune. The probe records transport facts
// only: timings, exit code, HTTP status and a classified failure. It never
// stores response bodies, headers, cookies or credentials. The HTTP status is
// informational; any status proves that TCP, TLS and HTTP transport worked.
let fs = require("fs");

const CURL = getenv("PROKOP_AUTOTUNE_CURL") || "curl";
const DIG = getenv("PROKOP_AUTOTUNE_DIG") || "dig";
const CONNECT_TIMEOUT = "5";
const MAX_TIME = "10";
const FIELDS = "%{exitcode}|%{local_port}|%{remote_ip}|%{http_code}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{errormsg}";

function as_string(value) { return value == null ? "" : "" + value; }
function quote(value) { return "'" + replace(as_string(value), /'/g, "'\\''") + "'"; }
function command(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}
function capture(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return { status: -1, output: "" };
    let data = pipe.read("all");
    let status = pipe.close();
    return { status: int(status), output: as_string(data) };
}

function valid_host(v) {
    v = as_string(v);
    if (length(v) > 253 || match(v, /^[A-Za-z0-9.-]+$/) == null)
        return false;
    let labels = split(v, ".");
    if (length(labels) < 2 || match(labels[length(labels) - 1], /^[A-Za-z]{2,63}$/) == null)
        return false;
    for (let label in labels)
        if (length(label) < 1 || length(label) > 63 ||
            match(label, /^[A-Za-z0-9]/) == null || match(label, /[A-Za-z0-9]$/) == null)
            return false;
    return true;
}

function ipv4_octets(v) {
    let m = match(as_string(v), /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
    if (m == null) return null;
    let octets = [ int(m[1]), int(m[2]), int(m[3]), int(m[4]) ];
    for (let o in octets) if (o > 255) return null;
    return octets;
}

function valid_ipv4(v) { return ipv4_octets(v) != null; }

// Answers that cannot be the real public address of a remote service: FakeIP,
// private, loopback, CGNAT, link-local, multicast and reserved space.
function public_ipv4(v) {
    let o = ipv4_octets(v);
    if (o == null) return false;
    return !(o[0] == 0 || o[0] == 10 || o[0] == 127 || o[0] >= 224 ||
        (o[0] == 100 && o[1] >= 64 && o[1] <= 127) ||
        (o[0] == 169 && o[1] == 254) ||
        (o[0] == 172 && o[1] >= 16 && o[1] <= 31) ||
        (o[0] == 192 && o[1] == 168) ||
        (o[0] == 198 && (o[1] == 18 || o[1] == 19)));
}

// The real address comes from an upstream resolver queried directly, never
// from the router's own resolver, which answers FakeIP for routed domains.
function resolve(host, resolver) {
    if (!valid_host(host)) return { status: "failed", reason: "invalid_host" };
    if (!valid_ipv4(resolver)) return { status: "failed", reason: "invalid_resolver" };
    let answer = capture([ DIG, "+short", "+time=2", "+tries=1", "@" + resolver, host, "A" ]);
    let addresses = [], rejected = [];
    for (let line in split(answer.output, "\n")) {
        line = trim(line);
        if (!valid_ipv4(line)) continue;
        if (public_ipv4(line)) push(addresses, line);
        else push(rejected, line);
    }
    let result = { status: "ok", reason: null, resolver, addresses, rejected };
    if (length(addresses) == 0) {
        result.status = "dns_failure";
        result.reason = length(rejected) > 0 ? "non_public_answer" : "no_address";
    }
    return result;
}

function seconds(v) {
    v = trim(as_string(v));
    return match(v, /^[0-9]+(\.[0-9]+)?$/) != null ? +v : 0;
}
function ms(v) { return int(seconds(v) * 1000 + 0.5); }

function tls_failure_code(code) {
    return index([ 35, 51, 53, 54, 58, 59, 60, 64, 66, 77, 80, 82, 83, 90, 91, 98 ], code) >= 0;
}
function transport_failure_code(code) {
    return index([ 8, 16, 18, 52, 55, 56, 92, 95 ], code) >= 0;
}

// classify({ exit_code, time_connect, time_appconnect, http_code, errormsg })
// -> { class, connect, tls, http }. Stages: ok | timeout | reset | failed |
// not_attempted. The HTTP status never turns a working transport into a
// failure.
function classify(r) {
    let code = int(r.exit_code);
    let connected = seconds(r.time_connect) > 0;
    let handshaken = seconds(r.time_appconnect) > 0;
    let err = lc(as_string(r.errormsg));
    let reset = match(err, /reset|broken pipe|connection aborted/) != null;
    let refused = match(err, /refused/) != null;
    let result = { class: "unknown_failure", connect: "not_attempted", tls: "not_attempted", http: "not_attempted" };

    if (code == 0) {
        result.connect = "ok"; result.tls = "ok";
        if (int(r.http_code) > 0) { result.http = "ok"; result.class = "success"; }
        else { result.http = "failed"; result.class = "http_transport_failure"; }
        return result;
    }
    if (code == 6) { result.class = "dns_failure"; return result; }
    if (code == 7) {
        if (reset || refused) { result.connect = "reset"; result.class = "tcp_reset"; }
        else if (match(err, /timed out|timeout/) != null) { result.connect = "timeout"; result.class = "connect_timeout"; }
        else { result.connect = "failed"; result.class = "connect_failure"; }
        return result;
    }
    if (code == 28) {
        if (!connected) { result.connect = "timeout"; result.class = "connect_timeout"; }
        else if (!handshaken) { result.connect = "ok"; result.tls = "timeout"; result.class = "tls_failure"; }
        else { result.connect = "ok"; result.tls = "ok"; result.http = "timeout"; result.class = "http_transport_failure"; }
        return result;
    }
    if (!connected) {
        // Transport failures without an established connection.
        if (reset) { result.connect = "reset"; result.class = "tcp_reset"; }
        else { result.connect = "failed"; result.class = "connect_failure"; }
        return result;
    }
    result.connect = "ok";
    if (!handshaken && (tls_failure_code(code) || transport_failure_code(code))) {
        if (reset) { result.tls = "reset"; result.class = "tcp_reset"; }
        else { result.tls = "failed"; result.class = "tls_failure"; }
        return result;
    }
    if (handshaken) {
        result.tls = "ok";
        result.http = reset ? "reset" : "failed";
        result.class = "http_transport_failure";
        return result;
    }
    return result;
}

function clean_message(v) {
    v = replace(as_string(v), /[^ -~]/g, " ");
    return length(v) > 160 ? substr(v, 0, 160) : v;
}

// probe({ host, ip, port_range, path }) -> sanitized probe record.
// options.production: a normal request through the production path (system
// resolver, no pinned address, no dedicated source ports) - used by stage 5
// to verify an applied strategy; the isolated probe pins ip and ports.
function probe(options) {
    let host = as_string(options.host), ip = options.production ? "" : as_string(options.ip);
    let path = as_string(options.path || "/");
    if (!valid_host(host) || (!options.production && !valid_ipv4(ip)) || match(path, /^\/[A-Za-z0-9._~\/-]*$/) == null)
        return { class: "invalid_input" };
    let args = [ CURL, "-s", "-o", "/dev/null", "--ipv4", "--noproxy", "*", "--proto", "=https",
        "--connect-timeout", CONNECT_TIMEOUT, "--max-time", MAX_TIME, "-w", FIELDS ];
    if (!options.production) push(args, "--resolve", host + ":443:" + ip);
    if (options.port_range && !options.production) push(args, "--local-port", as_string(options.port_range));
    push(args, "https://" + host + path);
    let run = capture(args);
    let line = "";
    for (let l in split(run.output, "\n")) if (trim(l) != "") line = l;
    let f = split(line, "|");
    let errormsg = length(f) > 8 ? join("|", slice(f, 8)) : "";
    let exit_code = match(as_string(f[0]), /^[0-9]+$/) != null ? int(f[0]) : run.status;
    let record = {
        host, resolved_ip: ip == "" ? null : ip, path, production: !!options.production,
        local_port: match(as_string(f[1]), /^[0-9]+$/) != null ? int(f[1]) : null,
        remote_ip: valid_ipv4(f[2]) ? f[2] : null,
        http_status: match(as_string(f[3]), /^[0-9]+$/) != null ? int(f[3]) : 0,
        time_connect_ms: ms(f[4]), time_appconnect_ms: ms(f[5]),
        time_starttransfer_ms: ms(f[6]), time_total_ms: ms(f[7]),
        curl_exit_code: exit_code, error: clean_message(errormsg)
    };
    let c = classify({ exit_code, time_connect: f[4], time_appconnect: f[5], http_code: f[3], errormsg });
    record.class = c.class;
    record.connect = c.connect;
    record.tls = c.tls;
    record.http = c.http;
    return record;
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return { resolve, probe, classify, valid_host, valid_ipv4, public_ipv4 };

let mode = ARGV[0] || "";
if (mode == "resolve")
    print(sprintf("%J\n", resolve(ARGV[1], ARGV[2])));
else if (mode == "probe")
    print(sprintf("%J\n", probe({ host: ARGV[1], ip: ARGV[2], port_range: ARGV[3], path: ARGV[4] })));
else if (mode == "classify")
    print(sprintf("%J\n", classify({ exit_code: ARGV[1], time_connect: ARGV[2], time_appconnect: ARGV[3],
        http_code: ARGV[4], errormsg: ARGV[5] })));
else {
    warn("Usage: autotune/probe.uc <resolve host resolver|probe host ip [port-range] [path]|classify ...>\n");
    exit(1);
}
