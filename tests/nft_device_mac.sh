#!/usr/bin/env bash
# Devices by MAC address in a rule's device options, with an nft stub (the
# real nft checks the same batches in tests/nft_device_mac_real.sh): the
# live table's rules and the kill-switch rendered from it.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
NFT_RUNTIME="$PROKOP_LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
NFT_LOG="$WORK_DIR/nft.log"
KS_OUT="$WORK_DIR/killswitch.nft"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'nft log:\n' >&2
  cat "$NFT_LOG" >&2 2>/dev/null || true
  exit 1
}
has() { grep -Fqx -- "$2" "$1" || fail "$3: expected '$2'"; }
lacks() {
  if grep -Fq -- "$2" "$1"; then fail "$3: unexpected '$2'"; fi
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
printf 'nft %s\n' "$*" >> "${NFT_LOG:?}"
if [ "$1" = "list" ] && [ "$2" = "table" ] && [ "$4" = "ProkopTable" ]; then
  printf 'table inet ProkopTable {\n'
  for suffix in subnets subnets6 ip_ports ip6_ports port_subnets port_subnets6 subnet_ports udp_port_subnets udp_port_subnets6 udp_subnet_ports ports \
    sources sources6 fully_sources fully_sources6 excluded_sources excluded_sources6; do
    printf '\tset prokop_rule_tv_%s {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t}\n' "$suffix"
  done
  printf '\tset prokop_rule_tv_sources_mac {\n\t\ttype ether_addr\n\t\telements = { aa:bb:cc:00:00:01 }\n\t}\n'
  printf '\tset prokop_rule_tv_excluded_sources_mac {\n\t\ttype ether_addr\n\t\telements = { aa:bb:cc:00:00:02 }\n\t}\n'
  printf '}\n'
fi
NFT
chmod 0755 "$WORK_DIR/bin/nft"
export PATH="$WORK_DIR/bin:$PATH" NFT_LOG

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { "source_network_interfaces": "br-lan wg0" },
  "section": [
    { ".name": "tv", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "ip_cidr": [ "93.184.216.0/24" ],
      "source_ip_cidr": [ "AA:BB:CC:00:00:01" ],
      "excluded_source_ip_cidr": [ "aa-bb-cc-00-00-02" ] }
  ]
}
JSON

# -- live table ---------------------------------------------------------------
: >"$NFT_LOG"
ucode -L "$PROKOP_LIB" "$NFT_RUNTIME" nft-add-section-priority-rules-fixture "$WORK_DIR/fixture.json" ProkopTable prokop_interfaces localv4 localv6 0x00100000 ||
  fail "priority rules failed"
has "$NFT_LOG" "nft add set inet ProkopTable prokop_rule_tv_sources_mac { type ether_addr; }" "filter MAC set"
has "$NFT_LOG" "nft add set inet ProkopTable prokop_rule_tv_excluded_sources_mac { type ether_addr; }" "exclusion MAC set"
has "$NFT_LOG" "nft add chain inet ProkopTable prokop_rule_tv_mac_excl { }" "exclusion chain"
has "$NFT_LOG" "nft add rule inet ProkopTable prokop_rule_tv_mac_excl ether saddr @prokop_rule_tv_excluded_sources_mac return" "excluded MAC returns"
has "$NFT_LOG" "nft add rule inet ProkopTable prokop_rule_tv_mac_excl meta mark set 0x00100000 counter accept" "the rest is captured"
has "$NFT_LOG" "nft add rule inet ProkopTable priority_rules iifname @prokop_interfaces ether saddr @prokop_rule_tv_sources_mac ip daddr != @localv4 ip daddr @prokop_rule_tv_subnets meta l4proto { tcp, udp } jump prokop_rule_tv_mac_excl" "MAC filter rule"
# A MAC-only filter has no address rule, and nothing in output.
lacks "$NFT_LOG" "ip saddr @prokop_rule_tv_sources " "no address variant without addresses"
lacks "$NFT_LOG" "priority_output_rules" "router-originated traffic has no MAC"
lacks "$NFT_LOG" "ether saddr !=" "never a negated ether match"

# -- kill-switch ----------------------------------------------------------------
: >"$NFT_LOG"
ucode -L "$PROKOP_LIB" "$NFT_RUNTIME" killswitch-render-fixture "$WORK_DIR/fixture.json" ProkopTable ProkopKillswitch "$KS_OUT" 198.18.0.0/15 fc00::/18 >"$WORK_DIR/ks.json" ||
  fail "kill-switch render failed: $(cat "$WORK_DIR/ks.json")"
T="inet ProkopKillswitch"
has "$KS_OUT" "add set $T prokop_rule_tv_sources_mac { type ether_addr; }" "kill-switch filter MAC set"
has "$KS_OUT" "add element $T prokop_rule_tv_sources_mac { aa:bb:cc:00:00:01 }" "kill-switch copies the filter MACs"
has "$KS_OUT" "add element $T prokop_rule_tv_excluded_sources_mac { aa:bb:cc:00:00:02 }" "kill-switch copies the excluded MACs"
has "$KS_OUT" "add rule $T priority_rules iifname @ks_interfaces ether saddr @prokop_rule_tv_sources_mac ip daddr != @localv4 ip daddr @prokop_rule_tv_subnets jump prokop_rule_tv_mac_excl" "kill-switch MAC rule"
has "$KS_OUT" "add rule $T prokop_rule_tv_mac_excl ether saddr @prokop_rule_tv_excluded_sources_mac return" "kill-switch exclusion returns"
has "$KS_OUT" "add rule $T prokop_rule_tv_mac_excl counter name ks_tv jump ks_reject" "kill-switch rejects the rest"
lacks "$KS_OUT" "ether saddr !=" "kill-switch never negates an ether match"
lacks "$KS_OUT" "priority_output_rules" "kill-switch has no output rules"

# A live MAC set that is missing means the runtime does not match the config.
sed -i '/prokop_rule_tv_excluded_sources_mac/d' "$WORK_DIR/bin/nft"
if ucode -L "$PROKOP_LIB" "$NFT_RUNTIME" killswitch-render-fixture "$WORK_DIR/fixture.json" ProkopTable ProkopKillswitch "$WORK_DIR/partial.nft" >"$WORK_DIR/partial.json"; then
  fail "a missing live MAC set must fail the render"
fi
grep -Fq "prokop_rule_tv_excluded_sources_mac is missing" "$WORK_DIR/partial.json" || fail "the missing set must be reported: $(cat "$WORK_DIR/partial.json")"
[ ! -e "$WORK_DIR/partial.nft" ] || fail "a failed render must not write a policy"

printf 'PASS: nft_device_mac\n'
