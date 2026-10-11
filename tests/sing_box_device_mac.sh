#!/usr/bin/env bash
# Devices by MAC address (Device filter, Forced device routing, Exclude
# devices): sing-box 1.14 matches them with source_mac_address. sing-box ANDs
# source_ip_cidr and source_mac_address inside one rule, so a device filter
# with both kinds is emitted as two rule sets (addresses first); exclusions
# are inverted conditions of both kinds; forced routing gets a rule per kind.
# No MAC ever lands in source_ip_cidr. Older cores refuse such a rule with a
# clear message, and an unusable MAC (multicast) is refused too.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

write_fixture() {
  cat >"$WORK_DIR/fixture.json" <<JSON
{
  "settings": { ".name":"settings", ".type":"settings", "dns_server":"77.88.8.8" },
  "section": [
    {
      ".name":"vpn", ".type":"section", "enabled":"1", "action":"connection", "kill_switch":"1",
      "outbound_jsons":["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain":"example.com", "community_lists":["telegram"],
      "source_ip_cidr":["192.168.1.10","AA:BB:CC:DD:EE:01"],
      "excluded_source_ip_cidr":["192.168.1.11","aa-bb-cc-dd-ee-02"]
    },
    {
      ".name":"forced", ".type":"section", "enabled":"1", "action":"connection",
      "outbound_jsons":["{\"type\":\"http\",\"tag\":\"test2\",\"server\":\"proxy2.example\",\"server_port\":8080}"],
      "fully_routed_ips":["192.168.1.20","aa:bb:cc:dd:ee:03"]
    },
    {
      ".name":"byp", ".type":"section", "enabled":"1", "action":"bypass",
      "domain":"bank.example", "source_ip_cidr":["$1"]
    },
    {
      ".name":"dnsrule", ".type":"section", "enabled":"1", "action":"dns", "dns_server":"1.1.1.1",
      "domain":"corp.example", "source_ip_cidr":["aa:bb:cc:dd:ee:05"]
    }
  ]
}
JSON
}

generate() {
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 192.168.1.1 0 1 '' "$1"
}

write_fixture "aa:bb:cc:dd:ee:04"
generate 1.14.2
node - "$WORK_DIR/config.json" <<'NODE'
const assert = require('node:assert/strict');
const c = JSON.parse(require('node:fs').readFileSync(process.argv[2], 'utf8'));
const MAC = /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;
const all = [];
(function walk(v) {
  if (Array.isArray(v)) return v.forEach(walk);
  if (v && typeof v === 'object') { all.push(v); Object.values(v).forEach(walk); }
})({ r: c.route.rules, d: c.dns.rules });
for (const o of all) {
  for (const ip of [].concat(o.source_ip_cidr ?? []))
    assert.ok(!/[0-9a-f]{2}[:-][0-9a-f]{2}[:-][0-9a-f]{2}[:-]/i.test(ip) || ip.includes('::'), `MAC in source_ip_cidr: ${ip}`);
  for (const mac of [].concat(o.source_mac_address ?? []))
    assert.match(mac, MAC, `canonical MAC: ${mac}`);
  assert.ok(!(o.source_ip_cidr && o.source_mac_address), `one rule must not AND an address and a MAC: ${JSON.stringify(o)}`);
}
const text = (r) => JSON.stringify(r);
const vpnRoutes = c.route.rules.filter((r) => r.outbound === 'vpn-out' && r.domain !== 'ip.podkop.fyi');
const byIp = vpnRoutes.filter((r) => text(r).includes('"source_ip_cidr":["192.168.1.10"]'));
const byMac = vpnRoutes.filter((r) => text(r).includes('"source_mac_address":["aa:bb:cc:dd:ee:01"]'));
assert.ok(byIp.length >= 2 && byMac.length === byIp.length, 'each vpn route rule exists once per filter kind');
assert.ok(c.route.rules.indexOf(byIp[0]) < c.route.rules.indexOf(byMac[0]), 'addresses first');
for (const r of vpnRoutes) {
  assert.ok(text(r).includes('"source_ip_cidr":"192.168.1.11","invert":true'), 'address exclusion kept');
  assert.ok(text(r).includes('"source_mac_address":"aa:bb:cc:dd:ee:02","invert":true'), 'MAC exclusion added');
}
const forced = c.route.rules.filter((r) => r.outbound && r.outbound.startsWith('forced-'));
assert.deepEqual(forced.map((r) => r.source_ip_cidr ?? r.source_mac_address), ['192.168.1.20', 'aa:bb:cc:dd:ee:03']);
// MAC-only bypass: source-aware DNS from the source DNS inbound by MAC.
const bypassDns = c.dns.rules.filter((r) => text(r).includes('aa:bb:cc:dd:ee:04'));
assert.ok(bypassDns.length >= 2, 'bypass device DNS rules by MAC');
for (const r of bypassDns) assert.ok(text(r).includes('dns-source-in') || text(r).includes('"inbound"'), 'source DNS inbound');
// DNS rule by MAC.
assert.ok(c.dns.rules.some((r) => text(r).includes('aa:bb:cc:dd:ee:05') && r.server && r.server.startsWith('dnsrule')), 'DNS action by MAC');
// FakeIP DNS answers for the vpn devices exist for both kinds.
const fake = c.dns.rules.filter((r) => r.server === 'fakeip-server' && text(r).includes('example.com'));
assert.ok(fake.some((r) => text(r).includes('192.168.1.10')) && fake.some((r) => text(r).includes('aa:bb:cc:dd:ee:01')), 'FakeIP for both kinds');
// Fallback of the source DNS inbound for the MAC devices too.
assert.ok(c.dns.rules.some((r) => r.server === 'dnsmasq-server' && r.source_mac_address), 'MAC fallback to dnsmasq');
NODE

# Older cores: refused with a clear message, never a broken config.
if generate 1.13.0 2>"$WORK_DIR/err"; then fail "sing-box 1.13 accepted MAC devices"; fi
grep -q "selects devices by MAC address, which needs sing-box 1.14 or later" "$WORK_DIR/err" || fail "no clear message: $(cat "$WORK_DIR/err")"

# A multicast MAC is not a device.
write_fixture "01:00:5e:00:00:01"
if generate 1.14.2 2>"$WORK_DIR/err"; then fail "a multicast MAC was accepted"; fi
grep -q "invalid device MAC address '01:00:5e:00:00:01'" "$WORK_DIR/err" || fail "no clear message: $(cat "$WORK_DIR/err")"

SING_BOX="${PROKOP_TEST_SING_BOX:-$(command -v sing-box 2>/dev/null || true)}"
if [ -z "$SING_BOX" ] || [ ! -x "$SING_BOX" ]; then
  echo "sing_box_device_mac: OK (real sing-box not checked: set PROKOP_TEST_SING_BOX)"
  exit 0
fi
write_fixture "aa:bb:cc:dd:ee:04"
generate 1.14.2
"$SING_BOX" check -c "$WORK_DIR/config.json" >"$WORK_DIR/check.log" 2>&1 ||
  fail "real sing-box refused the configuration: $(cat "$WORK_DIR/check.log")"
echo "sing_box_device_mac: OK"
