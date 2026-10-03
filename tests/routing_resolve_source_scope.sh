#!/usr/bin/env bash
set -euo pipefail

# routing/resolve.uc and rules limited to devices (source_ip_cidr). A target
# that names no source stays undecidable at such a rule, unless the caller
# asks "for the devices of that rule" (assume_rule_source): the route is then
# calculated for an address of the first source-scoped rule that takes the
# destination, and the answer names that address (source_scope).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cat >"$WORK/prokop" <<'EOF'
config settings 'settings'
config section 'youtube'
	option action 'zapret'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=multisplit'
config section 'main'
	option action 'connection'
EOF

cat >"$WORK/cases.uc" <<'EOF'
let fs = require("fs"), r = require("routing.resolve");
let sections = r.parse_config(fs.readfile(ARGV[0]));
let config = (rules) => ({ route: { final: "direct-out", rules },
    outbounds: [ { type: "direct", tag: "direct-out" }, { type: "vless", tag: "main-out" },
        { type: "direct", tag: "youtube-out", routing_mark: 16777217 } ] });
let rule = (outbound, more) => ({ action: "route", inbound: [ "tproxy-in" ], domain_suffix: [ "youtube.com" ], outbound, ...more });
let ask = (rules, opts) => {
    let g = r.resolve(config(rules), sections, r.target("www.youtube.com", "198.18.0.9", { fakeip: true, ...opts }));
    return { status: g.status, reason: g.reason, rule: g.route_rule, section: g.section, scope: g.source_scope };
};
let device = { source_ip_cidr: [ "192.168.1.50" ] }, assume = { assume_rule_source: true };
print(sprintf("%J\n", {
    no_source: ask([ rule("youtube-out", device) ], {}),
    assumed: ask([ rule("youtube-out", device) ], assume),
    assumed_subnet: ask([ rule("youtube-out", { source_ip_cidr: [ "fd00::/8", "10.20.0.0/16" ] }) ], assume),
    explicit_inside: ask([ rule("youtube-out", device) ], { source: "192.168.1.50" }),
    explicit_outside: ask([ rule("youtube-out", device), rule("main-out", {}) ], { source: "192.168.1.77" }),
    first_scoped_rule_wins: ask([ rule("main-out", { source_ip_cidr: [ "192.168.1.60" ] }), rule("youtube-out", device) ], assume),
    other_destination_above: ask([ { action: "route", inbound: [ "tproxy-in" ], domain_suffix: [ "example.org" ],
        source_ip_cidr: [ "192.168.1.60" ], outbound: "main-out" }, rule("youtube-out", {}) ], assume),
    unscoped: ask([ rule("youtube-out", {}) ], assume),
    ipv6_only: ask([ rule("youtube-out", { source_ip_cidr: [ "fd00::/8" ] }) ], assume)
}));
EOF
PROKOP_LIB="$LIB" ucode -L "$LIB" "$WORK/cases.uc" "$WORK/prokop" >"$WORK/out.json"

node - "$WORK/out.json" <<'NODE'
const assert = require('node:assert/strict');
const c = require(process.argv[2]);
const undecided = { status: 'undecidable', reason: 'source_scoped_rule', rule: 0, section: null, scope: null };

assert.deepEqual(c.no_source, undecided, 'without a source a device-limited rule is not guessed');
assert.deepEqual(c.assumed, { status: 'decided', reason: null, rule: 0, section: 'youtube',
  scope: { source: '192.168.1.50', assumed: true } }, 'asked for the devices of the rule');
assert.deepEqual(c.assumed_subnet.scope, { source: '10.20.0.0', assumed: true }, 'the first IPv4 entry gives the address');
assert.deepEqual(c.explicit_inside, { status: 'decided', reason: null, rule: 0, section: 'youtube',
  scope: { source: '192.168.1.50', assumed: false } }, 'a named source is not an assumption');
assert.deepEqual([c.explicit_outside.rule, c.explicit_outside.section, c.explicit_outside.scope], [1, 'main', null],
  'another device falls through to the next rule');
assert.deepEqual([c.first_scoped_rule_wins.rule, c.first_scoped_rule_wins.section, c.first_scoped_rule_wins.scope],
  [0, 'main', { source: '192.168.1.60', assumed: true }], 'the first device-limited rule that takes the destination decides the devices');
assert.deepEqual([c.other_destination_above.rule, c.other_destination_above.section, c.other_destination_above.scope],
  [1, 'youtube', null], 'a device-limited rule for another destination does not limit the answer');
assert.deepEqual([c.unscoped.section, c.unscoped.scope], ['youtube', null]);
assert.deepEqual(c.ipv6_only, undecided, 'no IPv4 address to ask for: still undecidable');
console.log('routing_resolve_source_scope: ok');
NODE
