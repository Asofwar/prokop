#!/usr/bin/env bash
set -euo pipefail

# C14: settings.exclude_bittorrent (off by default) sends the BitTorrent that
# sing-box sniffs directly, in front of every section rule: a route rule on
# both tproxy inbounds, right after sniffing and the DNS hijack. Off, there is
# no such rule. The Diagnostics site check (routing/resolve.uc) still decides
# a site's route with the rule in place: a site speaks TLS or HTTP, never
# BitTorrent. The setting warns that the traffic passes the kill-switch.
# With $PROKOP_TEST_SING_BOX (or sing-box on PATH) the generated
# configuration passes "sing-box check".

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

generate() {
  local name="$1" value="$2"
  cat >"$WORK/$name.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"],
    "yacd_secret_key": "test-clash-secret"${value:+, \"exclude_bittorrent\": \"$value\"} },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": ["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain_suffix": ["example.com"] }
  ]
}
JSON
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/$name.json" "$WORK/$name.config.json" 192.0.2.1 0 1 '' 1.12.0 >/dev/null 2>&1 ||
    fail "generator failed for $name"
}
generate default ""
generate off 0
generate on 1

node - "$WORK/default.config.json" "$WORK/off.config.json" "$WORK/on.config.json" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [def, off, on] = process.argv.slice(2).map((f) => JSON.parse(fs.readFileSync(f, 'utf8')));
const list = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
const torrent = (c) => c.route.rules.findIndex((r) => list(r.protocol).includes('bittorrent'));
assert.equal(torrent(def), -1, 'no BitTorrent rule by default');
assert.equal(torrent(off), -1, 'no BitTorrent rule when off');
const rules = on.route.rules;
const i = torrent(on);
assert.ok(i >= 0, 'the BitTorrent rule is generated');
const rule = rules[i];
assert.equal(rule.action, 'route');
assert.equal(rule.outbound, 'direct-out', 'BitTorrent goes directly');
assert.deepEqual(list(rule.inbound).sort(), ['tproxy-in', 'tproxy6-in'], 'both tproxy inbounds');
const sniff = rules.findIndex((r) => r.action === 'sniff');
const firstSection = rules.findIndex((r) => r.outbound && r.outbound !== 'direct-out' && !list(r.protocol).length);
assert.ok(sniff >= 0 && sniff < i, 'the rule follows sniffing');
assert.ok(firstSection < 0 || i < firstSection, `the rule precedes every section rule (${i} < ${firstSection})`);
NODE

# The site check keeps deciding a site's route with the rule in place.
cat >"$WORK/trace.uc" <<'UC'
let r = require("routing.resolve");
const T = [ "tproxy-in", "tproxy6-in" ];
const SECTIONS = r.parse_config("config section 'v'\n\toption action 'connection'\n");
let config = { route: { final: "direct-out", rules: [
    { action: "sniff", inbound: [ "tproxy-in", "tproxy6-in", "dns-in" ] },
    { action: "hijack-dns", port: 53 },
    { action: "hijack-dns", protocol: "dns" },
    { action: "route", inbound: T, protocol: "bittorrent", outbound: "direct-out" },
    { action: "route", inbound: T, domain_suffix: [ "example.com" ], outbound: "v-out" }
] }, outbounds: [ { type: "direct", tag: "direct-out" }, { type: "vless", tag: "v-out" } ] };
let x = r.resolve(config, SECTIONS, r.target("www.example.com", "198.18.0.9", { port: 443 }));
print(x.status, " ", x.outbound, "\n");
UC
trace="$(ucode -L "$LIB" "$WORK/trace.uc")"
case "$trace" in
  *" v-out") ;;
  *) fail "the site check did not decide the site's route with the BitTorrent rule: $trace" ;;
esac

grep -q 'kill-switch of a rule' "$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/settings.js" ||
  fail "the setting does not warn that BitTorrent passes the kill-switch"

SING_BOX="${PROKOP_TEST_SING_BOX:-$(command -v sing-box 2>/dev/null || true)}"
if [ -z "$SING_BOX" ] || [ ! -x "$SING_BOX" ]; then
  printf 'exclude_bittorrent: OK (real sing-box not checked: set PROKOP_TEST_SING_BOX)\n'
  exit 0
fi
"$SING_BOX" check -c "$WORK/on.config.json" >"$WORK/check.log" 2>&1 || fail "real sing-box refused the configuration: $(cat "$WORK/check.log")"
echo "exclude_bittorrent: OK"
