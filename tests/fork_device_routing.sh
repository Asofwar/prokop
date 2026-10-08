#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export PROKOP_LIB="$LIB" PROKOP_UCI_STATE_FILE="$WORK/uci" NFT_LOG="$WORK/nft.log"
export PROKOP_NFT_SUBNET_CACHE_DIR="$WORK/cache"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/nft" <<'NFT'
#!/bin/sh
printf '%s\n' "$*" >>"$NFT_LOG"
exit 0
NFT
chmod +x "$WORK/bin/nft"
export PATH="$WORK/bin:$PATH"
base() { ucode -L "$LIB" "$LIB/nft/apply.uc" nft-create-runtime-base-from-uci ProkopTable localv4 prokop_subnets prokop_ports prokop_ip_ports prokop_interfaces 0x04000000 0x08000000 198.18.0.0/15 1602; }
cat >"$WORK/uci" <<'UCI'
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan
prokop.settings.alice_mode_enabled=1
prokop.settings.alice_list_mode=deny
prokop.settings.alice_ips=192.168.1.5
prokop.settings.alice_macs=aa:bb:cc:dd:ee:ff
prokop.settings.alice_interfaces=wg*
prokop.settings.intercept_client_dns_exclude=9.9.9.9 2001:4860:4860::8888
UCI
base
node - "$WORK/nft.log" <<'NODE'
const assert = require('node:assert/strict'); const log = require('fs').readFileSync(process.argv[2],'utf8');
assert.match(log, /mangle iifname @prokop_interfaces jump alice_gate/);
assert.match(log, /alice_gate ip daddr 198\.18\.0\.0\/15 return/);
assert.match(log, /alice_gate ip6 daddr fc00::\/18 return/);
assert.ok(log.indexOf('alice_gate ip daddr 198.18.0.0/15 return') < log.indexOf('alice_gate ip saddr @prokop_alice_sources counter accept'));
assert.match(log, /alice_gate ip saddr @prokop_alice_sources counter accept/);
assert.match(log, /alice_dns_gate fib daddr type local return/);
assert.match(log, /alice_dns_gate ip daddr @localv4 return/);
assert.match(log, /alice_dns_gate ip6 daddr @localv6 return/);
assert.match(log, /alice_dns_gate ip saddr \{ 9\.9\.9\.9 \} return/);
assert.match(log, /alice_dns_gate ip daddr \{ 9\.9\.9\.9 \} return/);
assert.match(log, /alice_dns_gate ip6 saddr \{ 2001:4860:4860::8888 \} return/);
assert.match(log, /alice_dns_gate ip6 daddr \{ 2001:4860:4860::8888 \} return/);
assert.ok(log.indexOf('alice_dns_gate fib daddr type local return') < log.indexOf('alice_dns_gate iifname @prokop_alice_interfaces'));
assert.match(log, /alice_dns_gate.*redirect to :1604/);
assert.match(log, /prokop_alice_sources.*192\.168\.1\.5/);
assert.ok(log.indexOf('jump alice_gate') < log.indexOf('ct direction reply return'));
NODE
cat >"$WORK/uci" <<'UCI'
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan
prokop.settings.gaming_enabled=1
prokop.settings.gaming_ips=192.168.1.15
prokop.settings.gaming_section=main
UCI
: >"$WORK/nft.log"
base
node - "$WORK/nft.log" <<'NODE'
const assert = require('node:assert/strict'); const log = require('fs').readFileSync(process.argv[2],'utf8');
assert.match(log,/insert rule inet ProkopTable mangle iifname @prokop_interfaces ip saddr @prokop_game_sources ip daddr != 198\.18\.0\.0\/15 meta l4proto udp return/);
assert.match(log,/insert rule inet ProkopTable mangle iifname @prokop_interfaces ip6 saddr @prokop_game_sources6 ip6 daddr != fc00::\/18 meta l4proto udp return/);
assert.match(log,/game_rules ip saddr @prokop_game_sources meta l4proto tcp meta mark set 0x04000000 return/);
assert.match(log,/dns_redirect iifname @prokop_interfaces ip saddr @prokop_game_sources udp dport 53 jump game_dns_gate/);
assert.match(log,/game_dns_gate fib daddr type local return/);
assert.match(log,/game_dns_gate ip daddr @localv4 return/);
assert.match(log,/game_dns_gate ip6 daddr @localv6 return/);
assert.match(log,/game_dns_gate meta l4proto \{ tcp, udp \} redirect to :1604/);
NODE
cat >"$WORK/gaming.json" <<'JSON'
{"settings":{".name":"settings",".type":"settings","gaming_enabled":"1","gaming_ips":["192.168.1.15"],"gaming_section":"main","dns_server":["77.88.8.8"],"bootstrap_dns_server":["77.88.8.8"],"yacd_secret_key":"test-secret"},"sections":[{".name":"main",".type":"section","enabled":"1","action":"connection","selector_proxy_links":["socks5://192.0.2.10:1080"],"domain_suffix":["example.com"]}]}
JSON
ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/gaming.json" '{}'
mkdir -p "$WORK/config.json.section-cache"
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/gaming.json" "$WORK/config.json" 127.0.0.1
node - "$WORK/config.json" "$WORK/gaming.json" "$WORK/protected.json" <<'NODE'
const assert = require('node:assert/strict'); const fs = require('fs'); const config = JSON.parse(fs.readFileSync(process.argv[2]));
const consoleRoute = config.route.rules.find(x => x.network === 'tcp' && x.source_ip_cidr?.includes('192.168.1.15'));
assert.equal(consoleRoute.outbound, 'main-out');
assert.ok(config.route.rules.indexOf(consoleRoute) < config.route.rules.findIndex(x => x.protocol === 'quic'));
assert.equal(config.dns.rules.find(x => x.inbound === 'devices-dns-in').server, 'dns-server');
const input = JSON.parse(fs.readFileSync(process.argv[3])); input.sections[0].kill_switch='1'; fs.writeFileSync(process.argv[4],JSON.stringify(input));
NODE
if ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/protected.json" '{}' >"$WORK/out" 2>&1; then
  printf 'Gaming must refuse a protected configuration\n' >&2; exit 1
fi
grep -q 'Gaming UDP bypass cannot be combined' "$WORK/out"
printf 'device bypass, game routing and kill-switch refusal passed\n'
