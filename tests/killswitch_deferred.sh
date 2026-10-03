#!/usr/bin/env bash
# A protected section whose subscription is deferred (UC-192).
#
# A start that cannot load a subscription defers its section until the
# subscription can be downloaded through another section
# (subscription/cache.uc). The running sing-box then has no outbound for it.
# Its traffic must not leave directly meanwhile, and a kill-switch refresh
# from that runtime must not replace the saved protection with one that has
# none of the section's destinations and names.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
GENERATOR_UC="$PROKOP_LIB/singbox/generator.uc"
NFT_UC="$PROKOP_LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'state.json:\n' >&2
  cat "$KILLSWITCH_STATE_DIR/state.json" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

# ---- the running sing-box rejects a deferred protected section ----------------

outbound_json='{\"type\":\"http\",\"tag\":\"a\",\"server\":\"proxy.example\",\"server_port\":8080}'
cat >"$WORK_DIR/fixture.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8" },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": [ "$outbound_json" ], "domain_suffix": [ "main.example" ] },
    { ".name": "vpn", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "subscription_urls": [ "https://sub.example/vpn" ], "mixed_proxy_enabled": "1", "mixed_proxy_port": "2081",
      "domain_suffix": [ "vpn.example" ], "ip_cidr": [ "93.184.216.0/24" ] },
    { ".name": "other", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": [ "https://sub.example/other" ], "domain_suffix": [ "other.example" ] }
  ]
}
JSON
ucode -L "$PROKOP_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 192.168.1.1 0 1 'vpn other' 1.13.0 ||
  fail "the generator must accept deferred sections"
ucode -e '
  let c = json(require("fs").readfile(ARGV[0]));
  function check(value, message) { if (!value) die(message + "\n"); }
  function has(value, item) { return index(type(value) == "array" ? value : [ value ], item) >= 0; }
  let rejected = { domain: false, ip: false }, fakeip = false;
  for (let rule in c.route.rules) {
    let text = sprintf("%J", rule);
    check(index(text, "other.example") < 0, "an unprotected deferred section must stay out of the config");
    check(index(text, "vpn-out") < 0, "a deferred section has no outbound to route to");
    if (rule.action == "reject" && has(rule.domain_suffix, "vpn.example")) rejected.domain = true;
    if (rule.action == "reject" && has(rule.ip_cidr, "93.184.216.0/24")) rejected.ip = true;
  }
  for (let rule in c.dns.rules)
    if (has(rule.domain_suffix, "vpn.example") && rule.server == "fakeip-server") fakeip = true;
  for (let outbound in c.outbounds)
    check(outbound.tag != "vpn-out" && outbound.tag != "other-out", "deferred sections have no outbound");
  for (let inbound in c.inbounds)
    check(inbound.listen_port != 2081, "a deferred section has no mixed proxy inbound");
  check(rejected.domain, "the domains of a deferred protected section must be rejected, not sent directly");
  check(rejected.ip, "the IP destinations of a deferred protected section must be rejected, not sent directly");
  check(fakeip, "the names of a deferred protected section must resolve to FakeIP so that sing-box rejects them");
' "$WORK_DIR/config.json" 2>"$WORK_DIR/generator.err" || fail "$(cat "$WORK_DIR/generator.err")"
printf 'ok - the running sing-box rejects a deferred protected section\n'

# ---- its destinations still reach sing-box ------------------------------------

cat >"$WORK_DIR/populate.uci" <<'EOF'
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan
prokop.vpn=section
prokop.vpn.action=connection
prokop.vpn.kill_switch=1
prokop.vpn.subscription_urls=https://sub.example/vpn
prokop.vpn.ip_cidr=93.184.216.0/24
prokop.vpn.source_ip_cidr=192.168.1.0/28
prokop.vpn.domain_suffix=vpn.example
prokop.other=section
prokop.other.action=connection
prokop.other.subscription_urls=https://sub.example/other
prokop.other.ip_cidr=203.0.113.0/24
prokop.other.source_ip_cidr=192.168.1.32/28
prokop.other.domain_suffix=other.example
EOF
printf '# candidate\n' >"$WORK_DIR/populate.nft"
PROKOP_UCI_STATE_FILE="$WORK_DIR/populate.uci" PROKOP_NFT_BATCH_FILE="$WORK_DIR/populate.nft" \
  ucode -L "$PROKOP_LIB" "$NFT_UC" nft-populate-runtime-sets-from-uci 1 'vpn other' ProkopTable \
  prokop_subnets prokop_ports prokop_ip_ports prokop_interfaces localv4 0x00100000 \
  prokop_subnets6 prokop_ip_ports6 localv6 || fail "populating the runtime sets failed"
grep -Fq 'prokop_rule_vpn_subnets { 93.184.216.0/24 }' "$WORK_DIR/populate.nft" ||
  fail "a deferred protected section's IP destinations must be captured for sing-box to reject: $(cat "$WORK_DIR/populate.nft")"
grep -Eq 'prokop_dns_sources \{[^}]*192\.168\.1\.0/28' "$WORK_DIR/populate.nft" ||
  fail "a deferred protected section's clients must use the source-aware DNS the generator expects"
if grep -Fq '203.0.113.0/24' "$WORK_DIR/populate.nft" || grep -Eq 'prokop_dns_sources \{[^}]*192\.168\.1\.32/28' "$WORK_DIR/populate.nft"; then
  fail "an unprotected deferred section must not be captured"
fi
printf 'ok - the destinations of a deferred protected section reach sing-box\n'

# The option decides what a deferred subscription section gets from sing-box
# and nft, so turning it on or off there must reach the runtime: the reload
# plan sees it in the sing-box and nft signatures. Elsewhere it changes
# neither (killswitch/runtime.uc follows it without a runtime reload).
signatures() {
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/service/state.uc" reload-state-text-fixture "$1" 1 |
    grep -E '^(sing_box|nft)_signature='
}
signature_fixture() {
  cat >"$WORK_DIR/signature.json" <<JSON
{ "settings": { ".name": "settings", ".type": "settings" },
  "section": [ { ".name": "vpn", ".type": "section", "action": "connection", $1 "kill_switch": "$2",
    "ip_cidr": [ "93.184.216.0/24" ] } ] }
JSON
  signatures "$WORK_DIR/signature.json"
}
subscription='"subscription_urls": [ "https://sub.example/vpn" ],'
[ "$(signature_fixture "$subscription" 0)" != "$(signature_fixture "$subscription" 1)" ] ||
  fail "turning the kill-switch on for a subscription section must reload the runtime that defers it"
links='"connection_urls": [ "vless://00000000-0000-4000-8000-000000000001@a.example:443?security=tls#A" ],'
[ "$(signature_fixture "$links" 0)" = "$(signature_fixture "$links" 1)" ] ||
  fail "the kill-switch of a section that is never deferred must not reload the runtime"
printf 'ok - the kill-switch of a subscription section reaches the runtime\n'

# ---- the kill-switch follows the live table, not the unknown names -------------
#
# The live table holds the deferred protected section's destinations, so the
# nft policy is refreshed as usual: every other change of the configuration
# (a section's kill-switch turned off, another section sent direct, new list
# addresses) reaches it while the subscription stays unreachable. Only the
# section's names are unknown to the running sing-box; the DNS block list
# keeps the previous one meanwhile.

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
case "$1 $2" in
  "list table")
    [ "$4" = "ProkopTable" ] && exit 0
    [ "$4" = "ProkopKillswitch" ] && { [ -e "$WORK_DIR/ks-present" ]; exit $?; }
    exit 1 ;;
  "list set")
    printf 'table inet ProkopTable {\n\tset %s {\n\t\ttype ipv4_addr\n' "$5"
    [ "$5" = "prokop_rule_vpn_subnets" ] && [ -e "$WORK_DIR/vpn-elements" ] && printf '\t\telements = { 93.184.216.0/24 }\n'
    [ "$5" = "prokop_rule_main_subnets" ] && printf '\t\telements = { 198.51.100.0/24 }\n'
    printf '\t}\n}\n'
    exit 0 ;;
  "-c -f") exit 0 ;;
  "-f "*) cp "$2" "$WORK_DIR/live.nft"; touch "$WORK_DIR/ks-present"; exit 0 ;;
esac
exit 0
NFT
for name in logger dnsmasq-init killswitch-init; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
chmod 0755 "$WORK_DIR/bin/"*

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/nftables.d/90-prokop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"

uci_state() {
  cat >"$PROKOP_UCI_STATE_FILE" <<EOF
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan
prokop.settings.config_path=$WORK_DIR/sing-box.json
prokop.main=section
prokop.main.action=connection
prokop.main.kill_switch=$1
prokop.main.ip_cidr=198.51.100.0/24
prokop.vpn=section
prokop.vpn.action=connection
prokop.vpn.kill_switch=1
prokop.vpn.ip_cidr=93.184.216.0/24
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=127.0.0.42
EOF
}
ks() { ucode -L "$PROKOP_LIB" "$KS_UC" "$@"; }
routed_config() {
  cat >"$WORK_DIR/sing-box.json" <<'JSON'
{ "outbounds": [ { "type": "direct", "tag": "main-out" }, { "type": "direct", "tag": "vpn-out" } ],
  "route": { "rules": [ { "action": "route", "outbound": "main-out", "domain_suffix": [ "main.example" ] },
    { "action": "route", "outbound": "vpn-out", "domain_suffix": [ "vpn.example" ] } ], "rule_set": [] } }
JSON
}
# What the generator writes while the section is deferred: no outbound, its
# matchers rejected.
deferred_config() {
  cat >"$WORK_DIR/sing-box.json" <<'JSON'
{ "outbounds": [ { "type": "direct", "tag": "main-out" }, { "type": "direct", "tag": "direct-out" } ],
  "route": { "rules": [ { "action": "route", "outbound": "main-out", "domain_suffix": [ "main.example" ] },
    { "action": "reject", "domain_suffix": [ "vpn.example" ] } ], "rule_set": [] } }
JSON
}

POLICY="$KILLSWITCH_STATE_DIR/policy.nft"
BLOCKED="$KILLSWITCH_STATE_DIR/dns-blocked.servers"

touch "$WORK_DIR/vpn-elements"
uci_state 1
routed_config
ks sync start || fail "the sync of routed sections failed"
grep -Fq 'prokop_rule_vpn_subnets { 93.184.216.0/24 }' "$POLICY" || fail "the complete policy must hold the section's destinations"
grep -Fqx 'server=/vpn.example/' "$BLOCKED" || fail "the complete block list must hold the section's names"
grep -Fqx 'server=/main.example/' "$BLOCKED" || fail "the complete block list must hold the other section's names"
cp "$BLOCKED" "$WORK_DIR/blocked.before"

# The subscription of vpn is deferred, and the kill-switch of main is turned
# off meanwhile.
deferred_config
uci_state 0
ks sync reload || fail "a sync while a protected section is not routed must still refresh the nft policy"
grep -Fq 'prokop_rule_vpn_subnets { 93.184.216.0/24 }' "$POLICY" ||
  fail "the refreshed policy must keep the deferred section's destinations from the live table: $(cat "$POLICY")"
! grep -Fq 'ks_main' "$POLICY" || fail "a section whose kill-switch was turned off must not stay protected while another is deferred"
cmp -s "$BLOCKED" "$WORK_DIR/blocked.before" || fail "the names of a deferred section are unknown; the block list must stay as it was"
grep -Fq 'not routed' "$KILLSWITCH_STATE_DIR/state.json" || fail "the kept block list must be explained"
grep -Fq '"last_error": ""' "$KILLSWITCH_STATE_DIR/state.json" || fail "the refreshed nft policy is not an error"
status="$(ks status)" || fail "status failed"
ucode -e 'let s = json(ARGV[0]); exit(sprintf("%J", s.unrouted) == "[ \"vpn\" ]" ? 0 : 1);' -- "$status" ||
  fail "status must name the protected section the running Prokop does not route: $status"
printf 'ok - a deferred section keeps the previous block list, and the nft policy follows the configuration\n'

routed_config
ks sync reload || fail "the sync after the subscription was loaded failed"
grep -Fqx 'server=/vpn.example/' "$BLOCKED" || fail "the refreshed block list must hold the section's names"
! grep -Fq 'main.example' "$BLOCKED" || fail "the refreshed block list must drop the names of an unprotected section"
grep -Fq '"last_error": ""' "$KILLSWITCH_STATE_DIR/state.json" || fail "a successful sync must clear the error"
! grep -Fq 'not routed' "$KILLSWITCH_STATE_DIR/state.json" || fail "a routed section must not be reported any more"
status="$(ks status)" || fail "status failed"
ucode -e 'let s = json(ARGV[0]); exit(length(s.unrouted) == 0 ? 0 : 1);' -- "$status" ||
  fail "a routed section is not reported as unrouted: $status"
printf 'ok - the protection is refreshed once the section is routed\n'

printf 'killswitch_deferred: PASS\n'
