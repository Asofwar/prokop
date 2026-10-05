#!/usr/bin/env bash
set -euo pipefail

# C1: nft captures the shared Cloudflare ranges of the Discord list for
# Discord's media ports over UDP (443 included), whatever ports the rule
# filters. sing-box takes that traffic to the rule's target by the same
# ranges and ports, from the same constants; before, a rule with its own
# port filter let it go out directly. A block rule rejects it. A rule
# without the Discord list gets no such matcher. With $PROKOP_TEST_SING_BOX
# (or sing-box on PATH) the configuration passes "sing-box check".

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# generate NAME ACTION COMMUNITY: one rule with that list and a TCP 443 filter.
generate() {
  local name="$1" action="$2" community="$3" outbound=""
  [ "$action" = connection ] &&
    outbound='"outbound_jsons": ["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],'
  cat >"$WORK/$name.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"],
    "yacd_secret_key": "test-clash-secret" },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "$action", $outbound
      "community_lists": ["$community"], "ports": ["443"], "source_ip_cidr": ["192.168.1.10"] }
  ]
}
JSON
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/$name.json" "$WORK/$name.config.json" 192.0.2.1 0 1 '' 1.12.0 >"$WORK/$name.log" 2>&1 ||
    fail "generator failed for $name: $(cat "$WORK/$name.log")"
}
generate proxy connection discord
generate block block discord
generate other connection telegram

ucode -L "$LIB" -e 'let ip = require("core.ip"); print(sprintf("%J", { cidrs: ip.CLOUDFLARE_SHARED_CIDRS, ports: ip.DISCORD_VOICE_PORTS_NFT }));' >"$WORK/constants.json"

node - "$WORK/constants.json" "$WORK/proxy.config.json" "$WORK/block.config.json" "$WORK/other.config.json" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [constants, proxy, block, other] = process.argv.slice(2).map((f) => JSON.parse(fs.readFileSync(f, 'utf8')));
const list = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
// The rule may be wrapped in a logical rule that excludes sources.
const flat = (r) => (r.type === 'logical' ? [r, ...r.rules.flatMap(flat)] : [r]);
const discordRule = (c) => c.route.rules.find((r) => flat(r).some((x) => list(x.network).includes('udp') &&
  list(x.ip_cidr).includes('162.159.0.0/16')));

assert.ok(constants.ports.split(',').includes('443'), 'UDP 443 is a Discord media port');
const rule = discordRule(proxy);
assert.ok(rule, 'the shared Cloudflare UDP rule is generated');
const m = flat(rule).find((x) => list(x.ip_cidr).length);
assert.deepEqual(list(m.ip_cidr), constants.cidrs, 'the same ranges as nft');
const nftPorts = constants.ports.split(',');
const ports = [...list(m.port).map(String), ...list(m.port_range).map((p) => p.replace(':', '-'))];
assert.deepEqual(ports.sort(), [...nftPorts].sort(), 'the same ports as nft');
assert.equal(rule.action, 'route');
assert.equal(rule.outbound, 'main-out', 'to the rule\'s connection');
assert.deepEqual(list(m.inbound).sort(), ['tproxy-in', 'tproxy6-in']);
assert.deepEqual(list(m.source_ip_cidr), ['192.168.1.10'], 'the rule\'s devices only');
const finalIndex = proxy.route.rules.indexOf(rule);
const sectionIndex = proxy.route.rules.findIndex((r) => r.outbound === 'main-out');
assert.ok(sectionIndex >= 0 && finalIndex >= sectionIndex, 'among the rule\'s own route rules');

const blocked = discordRule(block);
assert.ok(blocked, 'a block rule has the matcher too');
assert.equal(blocked.action, 'reject', 'a block rule rejects the traffic');
assert.equal(discordRule(other), undefined, 'no matcher without the Discord list');
NODE

SING_BOX="${PROKOP_TEST_SING_BOX:-$(command -v sing-box 2>/dev/null || true)}"
if [ -z "$SING_BOX" ] || [ ! -x "$SING_BOX" ]; then
  printf 'discord_route_alignment: OK (real sing-box not checked: set PROKOP_TEST_SING_BOX)\n'
  exit 0
fi
for name in proxy block; do
  "$SING_BOX" check -c "$WORK/$name.config.json" >"$WORK/check.log" 2>&1 ||
    fail "real sing-box refused the $name configuration: $(cat "$WORK/check.log")"
done
echo "discord_route_alignment: OK"
