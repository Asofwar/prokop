#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
NFT_RUNTIME="$PROKOP_LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
NFT_LOG="$WORK_DIR/nft.log"
OUT="$WORK_DIR/killswitch.nft"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'rendered policy:\n' >&2
  cat "$OUT" >&2 2>/dev/null || true
  exit 1
}

assert_contains() {
  grep -Fqx -- "$2" "$1" || fail "$3: expected line '$2'"
}

assert_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    fail "$3: unexpected '$2'"
  fi
}

line_of() {
  grep -Fnx -- "$2" "$1" | head -n 1 | cut -d: -f1
}

assert_before() {
  local first second
  first="$(line_of "$1" "$2")"
  second="$(line_of "$1" "$3")"
  [ -n "$first" ] || fail "$4: missing '$2'"
  [ -n "$second" ] || fail "$4: missing '$3'"
  [ "$first" -lt "$second" ] || fail "$4: expected order"
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
printf 'nft %s\n' "$*" >> "${NFT_LOG:?}"
# The live ProkopTable: every set of the fixture's sections, some filled.
if [ "$1" = "list" ] && [ "$2" = "table" ] && [ "$4" = "ProkopTable" ]; then
  printf 'table inet ProkopTable {\n'
  for section in zapret_first bypass_x vpn_main vpn_plain vpn_last; do
    for suffix in subnets subnets6 ip_ports ip6_ports port_subnets port_subnets6 subnet_ports udp_port_subnets udp_port_subnets6 udp_subnet_ports ports sources sources6 \
      fully_sources fully_sources6 excluded_sources excluded_sources6; do
      name="prokop_rule_${section}_$suffix"
      case " ${NFT_MISSING_SETS:-} " in *" $name "*) continue ;; esac
      printf '\tset %s {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\tauto-merge\n' "$name"
      case "$name" in
        prokop_rule_vpn_main_subnets)
          printf '\t\telements = { 3.3.3.0/24, 3.3.4.0/24,\n\t\t\t     3.3.5.1 }\n' ;;
        prokop_rule_zapret_first_subnets)
          printf '\t\telements = { 3.3.3.0/25 }\n' ;;
        prokop_rule_vpn_last_fully_sources)
          printf '\t\telements = { 192.168.1.50 }\n' ;;
      esac
      printf '\t}\n'
    done
  done
  printf '\tchain mangle {\n\t\ttype filter hook prerouting priority mangle + 1; policy accept;\n\t}\n}\n'
fi
NFT
chmod 0755 "$WORK_DIR/bin/nft"
export PATH="$WORK_DIR/bin:$PATH"
export NFT_LOG

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { "source_network_interfaces": "br-lan awg_server" },
  "section": [
    { ".name": "zapret_first", ".type": "section", "enabled": "1", "action": "zapret",
      "ip_cidr": [ "3.3.3.0/25" ] },
    { ".name": "bypass_x", ".type": "section", "enabled": "1", "action": "bypass",
      "ip_cidr": [ "2.2.2.0/24" ] },
    { ".name": "domains_only", ".type": "section", "enabled": "1", "action": "connection",
      "kill_switch": "1", "domain_suffix": [ "example.org" ] },
    { ".name": "vpn_main", ".type": "section", "enabled": "1", "action": "connection",
      "kill_switch": "1", "ip_cidr": [ "3.3.3.0/24" ] },
    { ".name": "vpn_plain", ".type": "section", "enabled": "1", "action": "connection",
      "ip_cidr": [ "4.4.4.0/24" ] },
    { ".name": "vpn_disabled", ".type": "section", "enabled": "0", "action": "connection",
      "kill_switch": "1", "ip_cidr": [ "6.6.6.0/24" ] },
    { ".name": "vpn_last", ".type": "section", "enabled": "1", "action": "proxy",
      "kill_switch": "1", "fully_routed_ips": [ "192.168.1.50" ] },
    { ".name": "zapret_after", ".type": "section", "enabled": "1", "action": "zapret",
      "kill_switch": "1", "ip_cidr": [ "5.5.5.0/24" ] }
  ]
}
JSON

summary="$(ucode -L "$PROKOP_LIB" "$NFT_RUNTIME" killswitch-render-fixture "$WORK_DIR/fixture.json" ProkopTable ProkopKillswitch "$OUT" 198.18.0.0/15 fc00::/18)" ||
  fail "render failed: $summary"
# One listing of the live table for all sets (audit optimization 23).
[ "$(grep -c '^nft list' "$NFT_LOG")" = 1 ] || fail "the render listed the live table $(grep -c '^nft list' "$NFT_LOG") times"

printf '%s' "$summary" | grep -Fq '"sections": [ "domains_only", "vpn_main", "vpn_last" ]' ||
  fail "summary must list exactly the enabled protected connection sections: $summary"
printf '%s' "$summary" | grep -Fq '"rule_sections": [ "vpn_main", "vpn_last" ]' ||
  fail "summary must list the protected sections with nft rules: $summary"

T="inet ProkopKillswitch"
assert_before "$OUT" "add table $T" "delete table $T" "atomic replace prologue"
assert_contains "$OUT" "add element $T ks_interfaces { \"br-lan\", \"awg_server\" }" "source interfaces"
assert_contains "$OUT" "add chain $T ks_forward { type filter hook forward priority -5; policy accept; }" "forward hook before fw4"
assert_contains "$OUT" "add rule $T ks_forward ip daddr 198.18.0.0/15 counter name ks_fakeip jump ks_reject" "FakeIP v4 reject"
assert_contains "$OUT" "add rule $T ks_forward ip6 daddr fc00::/18 counter name ks_fakeip jump ks_reject" "FakeIP v6 reject"
assert_before "$OUT" "add rule $T ks_forward ip daddr 198.18.0.0/15 counter name ks_fakeip jump ks_reject" \
  "add rule $T ks_forward ip daddr @localv4 return" "FakeIP rejected before local return"
assert_contains "$OUT" "add rule $T ks_reject meta l4proto tcp reject with tcp reset" "tcp reset"
assert_contains "$OUT" "add counter $T ks_vpn_main" "per-section counter"
assert_contains "$OUT" "add counter $T ks_domains_only" "domain-only protected section counter"

# First-match order: an earlier Zapret subnet keeps its own verdict.
zapret_rule="add rule $T priority_rules iifname @ks_interfaces ip daddr != @localv4 ip daddr @prokop_rule_zapret_first_subnets return"
vpn_rule="add rule $T priority_rules iifname @ks_interfaces ip daddr != @localv4 ip daddr @prokop_rule_vpn_main_subnets counter name ks_vpn_main jump ks_reject"
assert_contains "$OUT" "$zapret_rule" "earlier zapret returns"
# A bypass rule never matches FakeIP addresses (UC-029); ks_forward rejects
# them before the policy chain anyway.
assert_contains "$OUT" "add rule $T priority_rules iifname @ks_interfaces ip daddr != @localv4 ip daddr != 198.18.0.0/15 ip daddr @prokop_rule_bypass_x_subnets return" "earlier bypass returns"
assert_contains "$OUT" "$vpn_rule" "protected section rejects"
assert_before "$OUT" "$zapret_rule" "$vpn_rule" "zapret before protected section"
assert_contains "$OUT" "add rule $T priority_rules iifname @ks_interfaces ip daddr != @localv4 ip daddr @prokop_rule_vpn_plain_subnets return" "unprotected connection between protected ones returns"

# Fully-routed client of a protected section.
assert_contains "$OUT" "add rule $T priority_rules iifname @ks_interfaces ip saddr @prokop_rule_vpn_last_fully_sources ip daddr != @localv4 meta l4proto tcp counter name ks_vpn_last jump ks_reject" "fully routed client rejected"

# Copied live elements, normalised to one line.
assert_contains "$OUT" "add element $T prokop_rule_vpn_main_subnets { 3.3.3.0/24, 3.3.4.0/24, 3.3.5.1 }" "live elements copied"
assert_contains "$OUT" "add element $T prokop_rule_zapret_first_subnets { 3.3.3.0/25 }" "earlier zapret elements copied"

# Nothing after the last protected section, nothing disabled, no router-originated rules.
assert_not_contains "$OUT" "zapret_after" "sections after the last protected one are irrelevant"
assert_not_contains "$OUT" "vpn_disabled" "disabled section ignored"
assert_not_contains "$OUT" "priority_output_rules" "router-originated rules not rendered"
assert_not_contains "$OUT" "meta mark set" "no Prokop marks in the kill-switch"

# A live set that does not exist means the runtime does not match the config.
if NFT_MISSING_SETS="prokop_rule_vpn_main_subnets6" ucode -L "$PROKOP_LIB" "$NFT_RUNTIME" killswitch-render-fixture "$WORK_DIR/fixture.json" ProkopTable ProkopKillswitch "$WORK_DIR/partial.nft" >"$WORK_DIR/partial.json"; then
  fail "missing live set must fail the render"
fi
grep -Fq 'prokop_rule_vpn_main_subnets6 is missing' "$WORK_DIR/partial.json" || fail "missing set must be reported"
[ ! -e "$WORK_DIR/partial.nft" ] || fail "failed render must not write a policy"

sed 's/"source_network_interfaces": "br-lan awg_server"/"source_network_interfaces": "br-lan awg_server", "exclude_ntp": "1"/' \
  "$WORK_DIR/fixture.json" > "$WORK_DIR/ntp.json"
ucode -L "$PROKOP_LIB" "$NFT_RUNTIME" killswitch-render-fixture "$WORK_DIR/ntp.json" ProkopTable ProkopKillswitch "$WORK_DIR/ntp.nft" >/dev/null ||
  fail "render with exclude_ntp failed"
grep -Fqx "add rule $T ks_forward udp dport 123 return" "$WORK_DIR/ntp.nft" || fail "excluded NTP must never be rejected"
assert_before "$WORK_DIR/ntp.nft" "add rule $T ks_forward udp dport 123 return" "add rule $T ks_forward jump priority_rules" "NTP exclusion before the policy"
assert_not_contains "$OUT" "dport 123" "NTP is only excluded when configured"

cat >"$WORK_DIR/none.json" <<'JSON'
{ "section": [ { ".name": "z", "action": "zapret", "kill_switch": "1", "ip_cidr": [ "1.1.1.1" ] } ] }
JSON
if ucode -L "$PROKOP_LIB" "$NFT_RUNTIME" killswitch-render-fixture "$WORK_DIR/none.json" ProkopTable ProkopKillswitch "$WORK_DIR/none.nft" >"$WORK_DIR/none.out"; then
  fail "kill_switch on a non-connection action must not render a policy"
fi
grep -Fq 'no protected sections' "$WORK_DIR/none.out" || fail "non-connection section must not count as protected"

printf 'killswitch_nft_render: PASS\n'
