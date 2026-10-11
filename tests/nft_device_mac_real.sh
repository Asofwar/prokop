#!/usr/bin/env bash
# Devices chosen by MAC address in a rule's device filter, exclusion and
# forced-device list: the live table and the kill-switch built from them,
# checked and applied by the real nft in a private user+net namespace.
#
#  * a MAC is matched with `ether saddr` only where a packet has a link layer
#    (prerouting, the kill-switch's forward chain), never in output;
#  * an exclusion by MAC is a return in the rule's own chain, never a "!="
#    condition (nft adds `meta iiftype ether` to an ether match, so a negated
#    one would take every WireGuard or PPP client out of the rule, the
#    kill-switch's included);
#  * a configuration without MAC addresses has no ether match and no MAC set.
#
# Skipped only when such a namespace cannot be created here.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
NFT_UC="$PROKOP_LIB/nft/apply.uc"
NAMESPACE=(unshare --user --map-root-user --net)

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: nft_device_mac_real: %s\n' "$1"
    exit 0
  }
  command -v nft >/dev/null 2>&1 || skip 'nft is not installed'
  command -v unshare >/dev/null 2>&1 || skip 'unshare is not installed'
  if ! probe="$("${NAMESPACE[@]}" nft list ruleset 2>&1)"; then
    skip "nftables is unavailable in an unprivileged network namespace: $probe"
  fi
  PROKOP_NFT_MAC_HOST_NET="$(readlink /proc/self/ns/net)" exec "${NAMESPACE[@]}" bash "$0" --in-namespace
fi

# ---- inside the namespace ---------------------------------------------------

# Never touch the caller's ruleset: only a new network namespace in a user
# namespace mapping nothing but root, as this script creates it.
mapfile -t uid_map </proc/self/uid_map
read -r map_inside _ map_count <<<"${uid_map[0]:-}"
if [ "${#uid_map[@]}" != 1 ] || [ "$map_inside" != 0 ] || [ "$map_count" != 1 ] ||
  [ -z "${PROKOP_NFT_MAC_HOST_NET:-}" ] || [ "$(readlink /proc/self/ns/net)" = "$PROKOP_NFT_MAC_HOST_NET" ]; then
  printf 'FAIL: --in-namespace is only for the private namespace this test creates\n' >&2
  exit 1
fi
[ -z "$(nft list ruleset)" ] || {
  printf 'FAIL: the namespace does not start with an empty ruleset\n' >&2
  exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/tmp"
export TMPDIR="$WORK_DIR/tmp"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'live ruleset:\n' >&2
  nft list ruleset >&2 2>/dev/null || true
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod 0755 "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_RT_TABLES="$WORK_DIR/rt_tables"
export PROKOP_NFT_SUBNET_CACHE_DIR="$WORK_DIR/nft-subnet-cache"

nft_uc() { ucode -L "$PROKOP_LIB" "$NFT_UC" "$@"; }
constant() { ucode -L "$PROKOP_LIB" "$PROKOP_LIB/core/constants.uc" get "$1"; }

TABLE="$(constant NFT_TABLE_NAME)"
INTERFACES="$(constant NFT_INTERFACE_SET_NAME)"
FAKEIP_MARK="$(constant NFT_FAKEIP_MARK)"
FAKEIP_RANGE="$(constant SB_FAKEIP_INET4_RANGE)"
FAKEIP6_RANGE="$(constant SB_FAKEIP_INET6_RANGE)"
SOURCE_DNS_PORT="$(ucode -L "$PROKOP_LIB" -e 'print(require("singbox.constants").SOURCE_DNS_INBOUND_PORT)')"
rebuild_args=(
  "$(constant RT_TABLE_NAME)" "$TABLE" "$(constant NFT_LOCALV4_SET_NAME)" "$(constant NFT_COMMON_SET_NAME)"
  "$(constant NFT_PORT_SET_NAME)" "$(constant NFT_IP_PORT_SET_NAME)" "$INTERFACES"
  "$FAKEIP_MARK" "$(constant NFT_OUTBOUND_MARK)" "$FAKEIP_RANGE" "$(constant SB_TPROXY_INBOUND_PORT)"
  "" "$(constant ZAPRET_ROUTE_MARK_BASE)" "$(constant ZAPRET_QUEUE_BASE)" "$(constant ZAPRET_DESYNC_MARK)" "$(constant ZAPRET_DESYNC_MARK_POSTNAT)"
  "" "$(constant ZAPRET2_ROUTE_MARK_BASE)" "$(constant ZAPRET2_QUEUE_BASE)" "$(constant ZAPRET2_DESYNC_MARK)" "$(constant ZAPRET2_DESYNC_MARK_POSTNAT)"
  "$(constant NFT_LOCALV6_SET_NAME)" "$(constant NFT_COMMON6_SET_NAME)" "$(constant NFT_IP_PORT6_SET_NAME)" "$FAKEIP6_RANGE" "$(constant SB_TPROXY_INBOUND6_ADDRESS)"
)
populate_args=(
  1 "" "$TABLE" "$(constant NFT_COMMON_SET_NAME)" "$(constant NFT_PORT_SET_NAME)" "$(constant NFT_IP_PORT_SET_NAME)"
  "$INTERFACES" "$(constant NFT_LOCALV4_SET_NAME)" "$FAKEIP_MARK"
  "$(constant NFT_COMMON6_SET_NAME)" "$(constant NFT_IP_PORT6_SET_NAME)" "$(constant NFT_LOCALV6_SET_NAME)"
)

# Builds, checks (nft -c) and applies the start/reload candidate of a UCI
# state, then lists the live table.
apply_state() {
  local state="$1" batch="$2"
  printf '# Prokop nft candidate\n' >"$batch"
  PROKOP_UCI_STATE_FILE="$state" PROKOP_NFT_BATCH_FILE="$batch" nft_uc nft-rebuild-runtime-from-uci "${rebuild_args[@]}" ||
    fail "$batch: nft-rebuild-runtime-from-uci failed"
  PROKOP_UCI_STATE_FILE="$state" PROKOP_NFT_BATCH_FILE="$batch" nft_uc nft-populate-runtime-sets-from-uci "${populate_args[@]}" ||
    fail "$batch: nft-populate-runtime-sets-from-uci failed"
  nft -c -f "$batch" 2>"$batch.err" || fail "$batch: nft -c rejected the batch: $(cat "$batch.err")"
  nft -f "$batch" 2>"$batch.err" || fail "$batch: nft -f rejected the batch: $(cat "$batch.err")"
  nft list table inet "$TABLE" >"$batch.live"
}

# Lines of the live listing, whitespace-normalised.
live_has() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g; s/ packets 0 bytes 0//g' "$1" | grep -Fx -- "$2" >/dev/null ||
    fail "$3: expected '$2' in $(basename "$1")"
}
live_lacks() {
  if grep -Fq -- "$2" "$1"; then
    fail "$3: unexpected '$2' in $(basename "$1")"
  fi
}

# Elements of a set in the live listing, one line.
set_elements() {
  awk -v name="$2" '
    $1 == "set" && $2 == name { inside = 1; next }
    inside && /elements = \{/ { collecting = 1 }
    inside && collecting { line = line " " $0 }
    inside && /\}/ && collecting { inside = 0; collecting = 0 }
    inside && $0 ~ /^[[:space:]]*\}/ { inside = 0 }
    END { print line }
  ' "$1" | sed -E 's/.*elements = \{//; s/\}.*//; s/[[:space:],]+/ /g; s/^ //; s/ $//'
}

# -- devices by MAC -----------------------------------------------------------
cat >"$WORK_DIR/mac.uci" <<'EOF'
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan wg0
prokop.tv=section
prokop.tv.enabled=1
prokop.tv.action=connection
prokop.tv.kill_switch=1
prokop.tv.ip_cidr=93.184.216.0/24
prokop.tv.source_ip_cidr=192.168.1.30 AA:BB:CC:00:00:01
prokop.tv.excluded_source_ip_cidr=aa-bb-cc-00-00-02 192.168.1.31
prokop.forced=section
prokop.forced.enabled=1
prokop.forced.action=connection
prokop.forced.kill_switch=1
prokop.forced.fully_routed_ips=aa:bb:cc:00:00:03
prokop.allowed=section
prokop.allowed.enabled=1
prokop.allowed.action=connection
prokop.allowed.ip_cidr=93.184.217.0/24
prokop.allowed.excluded_source_ip_cidr=aa:bb:cc:00:00:04
prokop.later=section
prokop.later.enabled=1
prokop.later.action=connection
prokop.later.kill_switch=1
prokop.later.ip_cidr=93.184.217.0/24
prokop.resolver=section
prokop.resolver.action=dns
prokop.resolver.domain=router.example
prokop.resolver.source_ip_cidr=aa:bb:cc:00:00:05
EOF
apply_state "$WORK_DIR/mac.uci" "$WORK_DIR/mac.nft"
LIVE="$WORK_DIR/mac.nft.live"

[ "$(set_elements "$LIVE" prokop_rule_tv_sources_mac)" = "aa:bb:cc:00:00:01" ] ||
  fail "device filter MAC set: '$(set_elements "$LIVE" prokop_rule_tv_sources_mac)'"
[ "$(set_elements "$LIVE" prokop_rule_tv_excluded_sources_mac)" = "aa:bb:cc:00:00:02" ] ||
  fail "exclusion MAC set (dash form normalised): '$(set_elements "$LIVE" prokop_rule_tv_excluded_sources_mac)'"
[ "$(set_elements "$LIVE" prokop_rule_tv_sources)" = "192.168.1.30" ] ||
  fail "the address set keeps only the addresses: '$(set_elements "$LIVE" prokop_rule_tv_sources)'"
[ "$(set_elements "$LIVE" prokop_rule_forced_fully_sources_mac)" = "aa:bb:cc:00:00:03" ] ||
  fail "forced device MAC set"
# Only rules with DNS matchers send a device's DNS to the source-aware
# inbound, as for addresses.
[ "$(set_elements "$LIVE" prokop_dns_sources_mac)" = "aa:bb:cc:00:00:05" ] ||
  fail "source-aware DNS MAC set: '$(set_elements "$LIVE" prokop_dns_sources_mac)'"
ok "MAC sets created and filled"

live_has "$LIVE" "iifname @$INTERFACES ip saddr @prokop_rule_tv_sources ip saddr != @prokop_rule_tv_excluded_sources ip daddr != @localv4 ip daddr @prokop_rule_tv_subnets jump prokop_rule_tv_mac_excl" "address variant of the filter"
live_has "$LIVE" "iifname @$INTERFACES ether saddr @prokop_rule_tv_sources_mac ip saddr != @prokop_rule_tv_excluded_sources ip daddr != @localv4 ip daddr @prokop_rule_tv_subnets jump prokop_rule_tv_mac_excl" "MAC variant of the filter"
live_has "$LIVE" "ether saddr @prokop_rule_tv_excluded_sources_mac return" "exclusion chain returns for excluded MACs"
live_has "$LIVE" "iifname @$INTERFACES ether saddr @prokop_rule_forced_fully_sources_mac ip daddr != @localv4 meta l4proto tcp meta mark set $FAKEIP_MARK counter accept" "forced device by MAC"
live_has "$LIVE" "iifname @$INTERFACES ether saddr @prokop_dns_sources_mac udp dport 53 counter redirect to :$SOURCE_DNS_PORT" "DNS of MAC devices to the source-aware inbound"
live_has "$LIVE" "iifname @$INTERFACES ip daddr != @localv4 ip daddr @prokop_rule_allowed_subnets jump prokop_rule_allowed_mac_excl" "MAC-only exclusion without filter"
# Router-originated traffic has no link layer: no ether match in output, and
# the address variant there gives the plain verdict.
awk '/chain priority_output_rules/,/^\t}/' "$LIVE" >"$WORK_DIR/output.rules"
live_lacks "$WORK_DIR/output.rules" "ether" "no MAC match in the output chain"
live_lacks "$WORK_DIR/output.rules" "_mac_excl" "no exclusion chain in the output chain"
if grep -E 'ether saddr != |ether saddr !=' "$LIVE"; then
  fail "an exclusion by MAC must never be a negated ether match"
fi
ok "live table: MAC variants, exclusion chain, DNS redirect, nothing in output"

# -- kill-switch rendered from the live table ---------------------------------
KS_OUT="$WORK_DIR/ks.nft"
PROKOP_UCI_STATE_FILE="$WORK_DIR/mac.uci" nft_uc killswitch-render "$TABLE" ProkopKillswitch "$KS_OUT" "$FAKEIP_RANGE" "$FAKEIP6_RANGE" >"$WORK_DIR/ks.json" ||
  fail "kill-switch render failed: $(cat "$WORK_DIR/ks.json")"
nft -c -f "$KS_OUT" 2>"$KS_OUT.err" || fail "nft -c rejected the kill-switch: $(cat "$KS_OUT.err")"
nft -f "$KS_OUT" 2>"$KS_OUT.err" || fail "nft -f rejected the kill-switch: $(cat "$KS_OUT.err")"
KS_LIVE="$WORK_DIR/ks.live"
nft list table inet ProkopKillswitch >"$KS_LIVE"
[ "$(set_elements "$KS_LIVE" prokop_rule_tv_sources_mac)" = "aa:bb:cc:00:00:01" ] || fail "kill-switch copies the filter MAC set"
[ "$(set_elements "$KS_LIVE" prokop_rule_tv_excluded_sources_mac)" = "aa:bb:cc:00:00:02" ] || fail "kill-switch copies the exclusion MAC set"
[ "$(set_elements "$KS_LIVE" prokop_rule_forced_fully_sources_mac)" = "aa:bb:cc:00:00:03" ] || fail "kill-switch copies the forced MAC set"
live_has "$KS_LIVE" "iifname @ks_interfaces ether saddr @prokop_rule_tv_sources_mac ip saddr != @prokop_rule_tv_excluded_sources ip daddr != @localv4 ip daddr @prokop_rule_tv_subnets jump prokop_rule_tv_mac_excl" "kill-switch MAC variant"
# Protected rule: the excluded device returns to the next sections (which
# may still reject it), every other device is rejected.
awk '/chain prokop_rule_tv_mac_excl/,/^\t}/' "$KS_LIVE" >"$WORK_DIR/ks_tv_excl"
live_has "$WORK_DIR/ks_tv_excl" "ether saddr @prokop_rule_tv_excluded_sources_mac return" "kill-switch exclusion returns"
live_has "$WORK_DIR/ks_tv_excl" "counter name \"ks_tv\" jump ks_reject" "kill-switch exclusion chain rejects the rest"
# Unprotected rule with a MAC exclusion: its traffic is allowed (accept ends
# the forward chain, whose last rule is the policy jump), the excluded
# device falls through to the protected rule after it.
awk '/chain prokop_rule_allowed_mac_excl/,/^\t}/' "$KS_LIVE" >"$WORK_DIR/ks_allowed_excl"
live_has "$WORK_DIR/ks_allowed_excl" "ether saddr @prokop_rule_allowed_excluded_sources_mac return" "unprotected exclusion returns"
live_has "$WORK_DIR/ks_allowed_excl" "accept" "unprotected rule allows the rest"
live_has "$KS_LIVE" "iifname @ks_interfaces ip daddr != @localv4 ip daddr @prokop_rule_later_subnets counter name \"ks_later\" jump ks_reject" "later protected rule still rejects"
live_has "$KS_LIVE" "iifname @ks_interfaces ether saddr @prokop_rule_forced_fully_sources_mac ip daddr != @localv4 meta l4proto tcp counter name \"ks_forced\" jump ks_reject" "forced MAC device rejected"
last_rule="$(awk '/chain ks_forward/,/^\t}/' "$KS_LIVE" | grep -v '^\s*}' | tail -n 1 | sed -E 's/^[[:space:]]+//')"
[ "$last_rule" = "jump priority_rules" ] || fail "the policy jump must stay the forward chain's last rule (accept in an exclusion chain relies on it): '$last_rule'"
if grep -E 'ether saddr !=' "$KS_LIVE"; then
  fail "the kill-switch must never negate an ether match"
fi
ok "kill-switch: MAC sets copied, exclusion chain fail-closed, policy jump last"

# -- addresses only: nothing of the above -------------------------------------
nft flush ruleset
cat >"$WORK_DIR/ip.uci" <<'EOF'
prokop.settings=settings
prokop.tv=section
prokop.tv.enabled=1
prokop.tv.action=connection
prokop.tv.kill_switch=1
prokop.tv.ip_cidr=93.184.216.0/24
prokop.tv.source_ip_cidr=192.168.1.30
prokop.tv.excluded_source_ip_cidr=192.168.1.31
prokop.tv.fully_routed_ips=192.168.1.32
EOF
apply_state "$WORK_DIR/ip.uci" "$WORK_DIR/ip.nft"
live_lacks "$WORK_DIR/ip.nft" "ether" "address-only batch"
live_lacks "$WORK_DIR/ip.nft" "_mac" "address-only batch"
live_has "$WORK_DIR/ip.nft.live" "iifname @$INTERFACES ip saddr @prokop_rule_tv_sources ip saddr != @prokop_rule_tv_excluded_sources ip daddr != @localv4 ip daddr @prokop_rule_tv_subnets meta mark set $FAKEIP_MARK counter accept" "address rule as before"
PROKOP_UCI_STATE_FILE="$WORK_DIR/ip.uci" nft_uc killswitch-render "$TABLE" ProkopKillswitch "$WORK_DIR/ip-ks.nft" "$FAKEIP_RANGE" "$FAKEIP6_RANGE" >/dev/null ||
  fail "address-only kill-switch render failed"
live_lacks "$WORK_DIR/ip-ks.nft" "ether" "address-only kill-switch"
nft -c -f "$WORK_DIR/ip-ks.nft" || fail "address-only kill-switch rejected"
ok "addresses only: no MAC set, no ether match"

printf 'PASS: nft_device_mac_real\n'
