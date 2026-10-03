#!/usr/bin/env bash
set -euo pipefail

# Edges of routing/resolve.uc the Diagnostics site check reaches, each
# against what sing-box and nft really do:
#   - an IPv6 target, an IPv6 source and a FakeIP literal without its domain
#     are outside the model: undecidable, never a decided owner (UC-096);
#   - a connection to port 53 is hijacked as DNS by sing-box before any
#     section rule: undecidable (UC-096);
#   - a rule's own resolve rule (ByeDPI, resolve_real_ip_for_routing) placed
#     directly before its route rule with the same matchers does not make the
#     owner undecidable; a resolve rule of another rule still does (UC-103);
#   - a real-address connection reaches sing-box only when nft intercepts the
#     address: a domain decision holds only when the first rule that takes
#     the address itself captures it; a bypass address is never intercepted;
#     otherwise undecidable (UC-100);
#   - nft returns a local or reserved IPv4 destination (localv4) before any
#     rule chain: it never reaches sing-box, whatever rule names it (UC-100);
#   - a list (rule_set) that may hold the address counts both ways for nft:
#     only an outcome shared with and without it is proven (UC-100);
#   - sing-box compares a domain value as written with the lower-cased host:
#     an upper-case keyword never matches (UC-099).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

cat >"$WORK/cases.uc" <<'UC'
let r = require("routing.resolve");
const T = [ "tproxy-in", "tproxy6-in" ];
const BASE = [
    { action: "sniff", inbound: [ "tproxy-in", "tproxy6-in", "dns-in" ] },
    { action: "hijack-dns", port: 53 },
    { action: "hijack-dns", protocol: "dns" },
    { action: "reject", inbound: T, protocol: "quic" }
];
const SECTIONS = r.parse_config(
    "config section 'v'\n\toption action 'connection'\n" +
    "config section 'w'\n\toption action 'connection'\n" +
    "config section 'b'\n\toption action 'byedpi'\n" +
    "config section 'y'\n\toption action 'zapret'\n");
function config(rules) {
    return { route: { final: "direct-out", rules: [ ...BASE, ...rules ] }, outbounds: [
        { type: "direct", tag: "direct-out" }, { type: "direct", tag: "bypass-out" },
        { type: "vless", tag: "v-out" }, { type: "vless", tag: "w-out" }, { type: "direct", tag: "b-out" },
        { type: "direct", tag: "y-out", routing_mark: 16777217 } ] };
}
function ask(rules, host, ip, opts) {
    let x = r.resolve(config(rules), SECTIONS, r.target(host, ip, opts));
    return { status: x.status, reason: x.reason, rule: x.route_rule == null ? null : x.route_rule - length(BASE),
        outbound: x.outbound, section: x.section };
}
const V6 = { action: "route", inbound: T, ip_cidr: [ "2a00:1450::/32" ], outbound: "v-out" };
const YT = { action: "route", inbound: T, domain_suffix: [ "youtube.com" ], outbound: "y-out" };
const B_RES = { inbound: T, domain_suffix: [ "example.com" ], action: "resolve", server: "dns-server" };
const B_ROUTE = { action: "route", inbound: T, outbound: "b-out", domain_suffix: [ "example.com" ] };
const OTHER_RES = { inbound: T, domain_suffix: [ "example.com", "example.net" ], action: "resolve", server: "dns-server" };
const V_DOMAIN = { action: "route", inbound: T, domain_suffix: [ "example.com" ], outbound: "v-out" };
const W_IP = { action: "route", inbound: T, ip_cidr: [ "93.184.216.0/24" ], outbound: "w-out" };
const BYPASS_IP = { action: "route", inbound: T, ip_cidr: [ "93.184.216.0/24" ], outbound: "bypass-out" };
const LOCAL_IP = { action: "route", inbound: T, ip_cidr: [ "10.0.0.0/8" ], outbound: "w-out" };
const BYPASS_SET = { action: "route", inbound: T, rule_set: [ "bypass-list" ], outbound: "bypass-out" };
const W_SET = { action: "route", inbound: T, rule_set: [ "w-list" ], outbound: "w-out" };
const PORTS = { action: "route", inbound: T, port: [ 443 ], outbound: "w-out" };

let cases = {
    ipv6_cidr: ask([ V6, YT ], "", "2a00:1450:4001::1", { fakeip: false }),
    ipv6_real_domain: ask([ V6, YT ], "www.youtube.com", "2a00:1450:4001::1", { fakeip: false }),
    ipv6_fakeip: ask([ YT ], "www.youtube.com", "fc00::5", { fakeip: true }),
    ipv6_source: ask([ YT ], "www.youtube.com", "198.18.0.5", { source: "fd00::5" }),
    fakeip_no_domain: ask([ YT ], "", "198.18.0.5"),
    dns_port_fakeip: ask([ YT ], "www.youtube.com", "198.18.0.5", { port: 53 }),
    dns_port_udp: ask([ YT ], "www.youtube.com", "198.18.0.5", { port: 53, network: "udp" }),
    https_port_fakeip: ask([ YT ], "www.youtube.com", "198.18.0.5", { port: 443 }),
    own_resolve: ask([ B_RES, B_ROUTE ], "www.example.com", "198.18.0.9"),
    own_resolve_other_domain: ask([ B_RES, B_ROUTE, YT ], "www.youtube.com", "198.18.0.9"),
    own_resolve_with_ip: ask([ B_RES, { ...B_ROUTE, ip_cidr: [ "10.0.0.0/8" ] } ], "www.example.com", "198.18.0.9"),
    foreign_resolve: ask([ OTHER_RES, V_DOMAIN ], "www.example.com", "198.18.0.9"),
    resolve_route_udp_only: ask([ B_RES, { ...B_ROUTE, network: "udp" } ], "www.example.com", "198.18.0.9"),
    real_domain_unknown: ask([ V_DOMAIN ], "www.example.com", "93.184.216.34", { fakeip: false }),
    real_domain_captured: ask([ V_DOMAIN, W_IP ], "www.example.com", "93.184.216.34", { fakeip: false }),
    real_domain_bypassed: ask([ V_DOMAIN, BYPASS_IP ], "www.example.com", "93.184.216.34", { fakeip: false }),
    real_domain_port_capture: ask([ V_DOMAIN, PORTS ], "www.example.com", "93.184.216.34", { fakeip: false }),
    real_ip_rule: ask([ W_IP, V_DOMAIN ], "www.example.com", "93.184.216.34", { fakeip: false }),
    local_domain: ask([ { ...V_DOMAIN, domain_suffix: [ "corp.example" ] }, LOCAL_IP ], "app.corp.example", "10.1.2.3", { fakeip: false }),
    local_ip_rule: ask([ LOCAL_IP ], "", "10.1.2.3", { fakeip: false }),
    local_reserved: ask([ { action: "route", inbound: T, ip_cidr: [ "240.0.0.0/4" ], outbound: "w-out" } ], "", "250.1.1.1", { fakeip: false }),
    local_dns_port: ask([ LOCAL_IP ], "", "10.1.2.3", { fakeip: false, port: 53 }),
    real_set_bypass_then_capture: ask([ V_DOMAIN, BYPASS_SET, W_IP ], "www.example.com", "93.184.216.34", { fakeip: false }),
    real_set_capture_then_capture: ask([ V_DOMAIN, W_SET, W_IP ], "www.example.com", "93.184.216.34", { fakeip: false }),
    real_set_bypass_then_bypass: ask([ V_DOMAIN, BYPASS_SET, BYPASS_IP ], "www.example.com", "93.184.216.34", { fakeip: false }),
    real_set_capture_then_bypass: ask([ V_DOMAIN, W_SET, BYPASS_IP ], "www.example.com", "93.184.216.34", { fakeip: false }),
    real_no_rule: ask([ V_DOMAIN ], "other.org", "1.1.1.1", { fakeip: false }),
    keyword_upper: ask([ { action: "route", inbound: T, domain_keyword: [ "YouTube" ], outbound: "v-out" }, YT ], "www.youtube.com", "198.18.0.5"),
    keyword_lower: ask([ { action: "route", inbound: T, domain_keyword: [ "youtube" ], outbound: "v-out" }, YT ], "www.youtube.com", "198.18.0.5")
};
print(sprintf("%J\n", cases));
UC

ucode -L "$LIB" "$WORK/cases.uc" >"$WORK/out.json"
node - "$WORK/out.json" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const undecided = (name, reason) => {
  assert.notEqual(c[name].status, 'decided', `${name}: never a decided owner (${JSON.stringify(c[name])})`);
  assert.equal(c[name].outbound, null, `${name}: no outbound`);
  if (reason) assert.equal(c[name].reason, reason, `${name}: reason`);
};
const decided = (name, rule, outbound) => {
  assert.equal(c[name].status, 'decided', `${name}: decided (${JSON.stringify(c[name])})`);
  assert.equal(c[name].rule, rule, `${name}: rule`);
  assert.equal(c[name].outbound, outbound, `${name}: outbound`);
};

undecided('ipv6_cidr', 'ipv6_not_modelled');
undecided('ipv6_real_domain', 'ipv6_not_modelled');
undecided('ipv6_fakeip', 'ipv6_not_modelled');
undecided('ipv6_source', 'ipv6_not_modelled');
undecided('fakeip_no_domain', 'fakeip_domain_unknown');
undecided('dns_port_fakeip', 'dns_hijack');
undecided('dns_port_udp', 'dns_hijack');
decided('https_port_fakeip', 0, 'y-out');

decided('own_resolve', 1, 'b-out');
assert.equal(c.own_resolve.section, 'b', 'own_resolve: the ByeDPI rule owns it');
decided('own_resolve_other_domain', 2, 'y-out');
decided('own_resolve_with_ip', 1, 'b-out');
undecided('foreign_resolve', 'resolve_rule');
undecided('resolve_route_udp_only', 'resolve_rule');

undecided('real_domain_unknown', 'real_address_interception_unknown');
decided('real_domain_captured', 0, 'v-out');
decided('real_domain_bypassed', 1, 'bypass-out');
decided('real_domain_port_capture', 0, 'v-out');
decided('real_ip_rule', 0, 'w-out');
undecided('local_domain', 'local_address_not_intercepted');
undecided('local_ip_rule', 'local_address_not_intercepted');
undecided('local_reserved', 'local_address_not_intercepted');
undecided('local_dns_port', 'dns_hijack');
undecided('real_set_bypass_then_capture', 'real_address_interception_unknown');
decided('real_set_capture_then_capture', 0, 'v-out');
assert.equal(c.real_set_bypass_then_bypass.status, 'decided', 'real_set_bypass_then_bypass: bypassed either way');
assert.equal(c.real_set_bypass_then_bypass.outbound, 'bypass-out', 'real_set_bypass_then_bypass: outbound');
undecided('real_set_capture_then_bypass', 'real_address_interception_unknown');
decided('real_no_rule', null, 'direct-out');

decided('keyword_upper', 1, 'y-out');
decided('keyword_lower', 0, 'v-out');
console.log('routing_resolve_edges: PASS');
NODE

# The resolver's local ranges are the ones nft returns early for.
node - "$LIB/nft/apply.uc" "$LIB/routing/resolve.uc" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ranges = (file, name) => {
  const m = fs.readFileSync(file, 'utf8').match(new RegExp(`${name} = \\[([^\\]]*)\\]`));
  assert.ok(m, `${name} in ${file}`);
  return [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1] === '240.0.0.0-255.255.255.255' ? '240.0.0.0/4' : x[1]);
};
assert.deepEqual(ranges(process.argv[3], 'LOCALV4_RANGES'), ranges(process.argv[2], 'LOCALV4_RANGES'));
console.log('routing_resolve_edges: local ranges PASS');
NODE
