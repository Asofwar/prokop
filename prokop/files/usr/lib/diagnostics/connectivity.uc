#!/usr/bin/env ucode

// Router-originated reachability probes. Every probe is bounded by the tool's
// own timeout options (dig +timeout/+tries, curl --connect-timeout/--max-time):
// OpenWrt busybox ships neither `timeout` nor an `nc` with -z/-w.

let ip = require("core.ip");
let fs = require("fs");
function value(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(value(v), /'/g, "'\\''") + "'"; }
function command(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}
function capture(args) {
    // stderr is dropped: tool messages may echo arguments and never reach the UI.
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return { status: 127, output: "" };
    let output = pipe.read("all");
    let status = int(pipe.close());
    return { status: status > 255 ? int(status / 256) : status, output: value(output) };
}
function valid_domain(host) {
    if (match(host, /^[A-Za-z0-9.-]+$/) == null) return false;
    let labels = split(host, ".");
    if (length(labels) < 2) return false;
    for (let part in labels)
        if (length(part) < 1 || length(part) > 63 ||
            match(part, /^[A-Za-z0-9]/) == null || match(part, /[A-Za-z0-9]$/) == null)
            return false;
    return true;
}
function valid_host(host) {
    return length(host) <= 253 && host != "" && (ip.valid_ip(host) || valid_domain(host));
}
function url_host(host) { return ip.valid_ipv6(host) ? "[" + host + "]" : host; }
const DEFAULT_PORTS = { HTTP: "80", HTTPS: "443" };
function normalize(host, test_type, port) {
    host = value(host); test_type = value(test_type); port = value(port);
    // TLS was the previous name of the HTTPS request probe.
    if (test_type == "TLS") test_type = "HTTPS";
    if (!valid_host(host) || index([ "DNS", "TCP", "HTTP", "HTTPS" ], test_type) < 0)
        return null;
    if (test_type == "DNS")
        return ip.valid_ip(host) ? null : { host, type: test_type, port: null };
    if (port == "" && DEFAULT_PORTS[test_type] != null) port = DEFAULT_PORTS[test_type];
    if (match(port, /^[0-9]{1,5}$/) == null || int(port) < 1 || int(port) > 65535)
        return null;
    return { host, type: test_type, port: int(port) };
}
function probe_args(request) {
    if (request.type == "DNS")
        return [ "dig", "+timeout=3", "+tries=1", "+noall", "+comments", "+answer", request.host, "A" ];
    // TCP uses a plain HTTP request only to open the connection; time_connect
    // proves the handshake regardless of what the service answers.
    let scheme = request.type == "HTTPS" ? "https://" : "http://";
    return [ "curl", "-sS", "-o", "/dev/null",
        "--connect-timeout", "4", "--max-time", request.type == "TCP" ? "5" : "8",
        "-w", "%{time_connect} %{time_total} %{http_code}",
        scheme + url_host(request.host) + ":" + request.port + "/" ];
}
const TLS_FAILURES = [ 35, 51, 53, 54, 58, 59, 60, 64, 66, 77, 80, 83, 90, 91 ];
function curl_verdict(request, result) {
    let fields = split(trim(result.output), " ");
    let connect = +(fields[0] || 0), total = +(fields[1] || 0);
    let code = int(fields[2] || 0);
    if (request.type == "TCP" && connect > 0)
        return { status: "ok", error: null, latency_ms: int(connect * 1000) };
    if (request.type != "TCP" && result.status == 0 && code > 0)
        return { status: "ok", error: null, latency_ms: int(total * 1000), http_code: code };
    let error = result.status == 28 ? "timeout" : result.status == 6 ? "dns_failed" :
        result.status == 7 ? "connect_failed" : index(TLS_FAILURES, result.status) >= 0 ? "tls_failed" :
        result.status == 52 || result.status == 56 ? "no_response" :
        result.status == 127 ? "tool_missing" : "failed";
    return { status: error == "timeout" ? "timeout" : "error", error, latency_ms: int(total * 1000) };
}
function dns_verdict(result, elapsed_ms) {
    let text = result.output;
    if (result.status == 127) return { status: "error", error: "tool_missing", latency_ms: elapsed_ms };
    if (result.status == 9 || match(text, /timed out|no servers could be reached/) != null)
        return { status: "timeout", error: "timeout", latency_ms: elapsed_ms };
    let header = match(text, /status: ([A-Z]+)/);
    let rcode = header ? header[1] : "";
    let address = "";
    for (let line in split(text, "\n")) {
        let answer = match(line, /[ \t]IN[ \t]+A[ \t]+([0-9.]+)[ \t]*$/);
        if (answer && ip.valid_ip(answer[1])) { address = answer[1]; break; }
    }
    if (rcode == "NOERROR" && address != "")
        return { status: "ok", error: null, latency_ms: elapsed_ms, address };
    let error = rcode == "NXDOMAIN" ? "nxdomain" : rcode == "NOERROR" ? "no_answer" : "dns_failed";
    return { status: "error", error, latency_ms: elapsed_ms };
}
function run(host, test_type, port, runner) {
    let request = normalize(host, test_type, port);
    if (request == null) return { error: "invalid_input" };
    let started = clock(true);
    let result = runner(probe_args(request));
    let finished = clock(true);
    let elapsed_ms = int((finished[0] - started[0]) * 1000 + (finished[1] - started[1]) / 1000000);
    let verdict = request.type == "DNS" ? dns_verdict(result, elapsed_ms) : curl_verdict(request, result);
    return { host: request.host, type: request.type, port: request.port, origin: "router", ...verdict };
}
let mode = value(ARGV[0]);
if (index([ "test", "fixture", "fixture-args" ], mode) < 0) exit(1);
let fixture_args = [];
let response = run(ARGV[1], ARGV[2], ARGV[3], function(args) {
    if (mode == "test") return capture(args);
    fixture_args = args;
    return { status: int(ARGV[4] || 0), output: value(ARGV[5]) };
});
print(sprintf("%J\n", mode == "fixture-args" ? fixture_args : response));
exit(response.status == null ? 1 : 0);
