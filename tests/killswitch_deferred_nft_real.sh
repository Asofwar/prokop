#!/usr/bin/env bash
# A deferred protected section in the real nft dataplane (UC-192).
#
# While a protected section's subscription is deferred, sing-box rejects its
# traffic (singbox/generator.uc), so its destinations must keep reaching
# sing-box: the start/reload candidate (nft/apply.uc, as
# service/lifecycle.uc builds it) holds them in the live ProkopTable, and a
# kill-switch policy rendered from that table rejects them as well. An
# unprotected deferred section stays out of both. nft checks (-c) and
# applies (-f) every batch in a private user+net(+mount) namespace.
#
# The namespace part is skipped only when such a namespace cannot be created.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
NFT_UC="$PROKOP_LIB/nft/apply.uc"
NAMESPACE=(unshare --user --map-root-user --net --mount)

namespaces() { printf '%s %s' "$(readlink /proc/self/ns/net)" "$(readlink /proc/self/ns/mnt)"; }

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: killswitch_deferred_nft_real: %s\n' "$1"
    exit 0
  }
  command -v nft >/dev/null 2>&1 || skip 'nft is not installed'
  command -v unshare >/dev/null 2>&1 || skip 'unshare is not installed'
  if ! probe="$("${NAMESPACE[@]}" nft list ruleset 2>&1)"; then
    skip "nftables is unavailable in an unprivileged network namespace: $probe"
  fi
  PROKOP_NFT_REAL_HOST_NAMESPACES="$(namespaces)" exec "${NAMESPACE[@]}" bash "$0" --in-namespace
fi

# ---- inside the namespace (same guard as tests/nft_real.sh) -----------------

refuse() {
  printf 'FAIL: --in-namespace is only for the private namespace this test creates (%s)\n' "$1" >&2
  exit 1
}
mapfile -t uid_map </proc/self/uid_map
read -r map_inside _ map_count <<<"${uid_map[0]:-}"
if [ "${#uid_map[@]}" != 1 ] || [ "$map_inside" != 0 ] || [ "$map_count" != 1 ]; then
  refuse "not a user namespace mapping only root: ${uid_map[*]:-}"
fi
read -r host_net host_mnt <<<"${PROKOP_NFT_REAL_HOST_NAMESPACES:-}"
read -r own_net own_mnt <<<"$(namespaces)"
if [ -z "${host_net:-}" ] || [ "$own_net" = "$host_net" ] || [ "$own_mnt" = "${host_mnt:-}" ]; then
  refuse "the network or mount namespace is not new"
fi
[ -z "$(nft list ruleset)" ] || refuse "the namespace does not start with an empty ruleset"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'live ruleset:\n' >&2
  nft list ruleset >&2 2>/dev/null || true
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/tmp"
export TMPDIR="$WORK_DIR/tmp"
# The route helpers are not under test here (tests/nft_apply.sh).
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/nfqws"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/nfqws2"
chmod 0755 "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_RT_TABLES="$WORK_DIR/rt_tables" PROKOP_LIB

nft_uc() { ucode -L "$PROKOP_LIB" "$NFT_UC" "$@"; }
constant() { ucode -L "$PROKOP_LIB" "$PROKOP_LIB/core/constants.uc" get "$1"; }

TABLE="$(constant NFT_TABLE_NAME)"
LOCALV4="$(constant NFT_LOCALV4_SET_NAME)"
LOCALV6="$(constant NFT_LOCALV6_SET_NAME)"
COMMON="$(constant NFT_COMMON_SET_NAME)"
COMMON6="$(constant NFT_COMMON6_SET_NAME)"
PORTS="$(constant NFT_PORT_SET_NAME)"
IP_PORTS="$(constant NFT_IP_PORT_SET_NAME)"
IP6_PORTS="$(constant NFT_IP_PORT6_SET_NAME)"
INTERFACES="$(constant NFT_INTERFACE_SET_NAME)"
FAKEIP_MARK="$(constant NFT_FAKEIP_MARK)"
FAKEIP_RANGE="$(constant SB_FAKEIP_INET4_RANGE)"
FAKEIP6_RANGE="$(constant SB_FAKEIP_INET6_RANGE)"

# A kernel may lack the tproxy or queue expression (some VM kernels without
# modules). The kernel stage then takes the batch without that statement;
# tests/nft_real.sh checks the full batch.
MISSING=()
probe_feature() {
  if ! printf 'add table inet prokop_probe\nadd chain inet prokop_probe c { %s }\nadd rule inet prokop_probe c %s\n' \
    "$2" "$3" | nft -c -f - >/dev/null 2>&1; then
    MISSING+=("$1")
    printf 'NOTE: this kernel has no nft %s expression; the live table is applied without it\n' "$1"
  fi
}
probe_feature queue 'type filter hook output priority 0; policy accept;' 'queue num 1 bypass'
probe_feature tproxy 'type filter hook prerouting priority 0; policy accept;' 'meta l4proto tcp tproxy ip to :1'
kernel_batch() {
  local sed_args=(-e 's/^//') name
  for name in "${MISSING[@]}"; do
    case "$name" in
      queue) sed_args+=(-e 's/ queue num [0-9]+( bypass)?//') ;;
      tproxy) sed_args+=(-e 's/ tproxy ip6? to [^ ]+//') ;;
    esac
  done
  sed -E "${sed_args[@]}" "$1"
}

cat >"$WORK_DIR/uci.state" <<'EOF'
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan
prokop.byp=section
prokop.byp.action=bypass
prokop.byp.ip_cidr=198.51.100.0/24
prokop.vpn=section
prokop.vpn.action=connection
prokop.vpn.kill_switch=1
prokop.vpn.subscription_urls=https://sub.example/vpn
prokop.vpn.ip_cidr=93.184.216.0/24
prokop.other=section
prokop.other.action=connection
prokop.other.subscription_urls=https://sub.example/other
prokop.other.ip_cidr=203.0.113.0/24
EOF

# The start candidate (service/lifecycle.uc nft_rebuild_runtime and
# nft_populate_runtime_sets) with both subscription sections deferred.
batch="$WORK_DIR/live.nft"
printf '# Prokop nft candidate\n' >"$batch"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" PROKOP_NFT_BATCH_FILE="$batch"
nft_uc nft-rebuild-runtime-from-uci "$(constant RT_TABLE_NAME)" "$TABLE" "$LOCALV4" "$COMMON" "$PORTS" "$IP_PORTS" \
  "$INTERFACES" "$FAKEIP_MARK" "$(constant NFT_OUTBOUND_MARK)" "$FAKEIP_RANGE" "$(constant SB_TPROXY_INBOUND_PORT)" \
  "$WORK_DIR/bin/nfqws" "$(constant ZAPRET_ROUTE_MARK_BASE)" "$(constant ZAPRET_QUEUE_BASE)" \
  "$(constant ZAPRET_DESYNC_MARK)" "$(constant ZAPRET_DESYNC_MARK_POSTNAT)" \
  "$WORK_DIR/bin/nfqws2" "$(constant ZAPRET2_ROUTE_MARK_BASE)" "$(constant ZAPRET2_QUEUE_BASE)" \
  "$(constant ZAPRET2_DESYNC_MARK)" "$(constant ZAPRET2_DESYNC_MARK_POSTNAT)" \
  "$LOCALV6" "$COMMON6" "$IP6_PORTS" "$FAKEIP6_RANGE" "$(constant SB_TPROXY_INBOUND6_ADDRESS)" ||
  fail "nft-rebuild-runtime-from-uci failed"
nft_uc nft-populate-runtime-sets-from-uci 1 "vpn other" "$TABLE" "$COMMON" "$PORTS" "$IP_PORTS" "$INTERFACES" \
  "$LOCALV4" "$FAKEIP_MARK" "$COMMON6" "$IP6_PORTS" "$LOCALV6" || fail "nft-populate-runtime-sets-from-uci failed"
unset PROKOP_NFT_BATCH_FILE

kernel_batch "$batch" >"$batch.kernel"
nft -c -f "$batch.kernel" 2>"$WORK_DIR/live.err" || fail "nft -c rejected the start candidate: $(cat "$WORK_DIR/live.err")"
nft -f "$batch.kernel" 2>"$WORK_DIR/live.err" || fail "nft -f rejected the start candidate: $(cat "$WORK_DIR/live.err")"
# nft writes a listing in many small writes; read it in full before matching.
vpn_set="$(nft list set inet "$TABLE" prokop_rule_vpn_subnets)"
grep -Fq '93.184.216.0/24' <<<"$vpn_set" ||
  fail "a deferred protected section's destinations must stay in the live table for sing-box to reject them"
other_set="$(nft list set inet "$TABLE" prokop_rule_other_subnets)"
if grep -Fq '203.0.113.0/24' <<<"$other_set"; then
  fail "an unprotected deferred section must not be captured"
fi
ok "the live table keeps capturing the deferred protected section"

nft_uc killswitch-render "$TABLE" ProkopKillswitch "$WORK_DIR/ks.nft" "$FAKEIP_RANGE" "$FAKEIP6_RANGE" >"$WORK_DIR/render.json" ||
  fail "kill-switch render failed: $(cat "$WORK_DIR/render.json")"
grep -Fq 'add element inet ProkopKillswitch prokop_rule_vpn_subnets { 93.184.216.0/24 }' "$WORK_DIR/ks.nft" ||
  fail "the kill-switch policy must hold the deferred protected section's destinations"
nft -c -f "$WORK_DIR/ks.nft" 2>"$WORK_DIR/ks.err" || fail "nft -c rejected the kill-switch policy: $(cat "$WORK_DIR/ks.err")"
nft -f "$WORK_DIR/ks.nft" 2>"$WORK_DIR/ks.err" || fail "nft -f rejected the kill-switch policy: $(cat "$WORK_DIR/ks.err")"
priority="$(nft list chain inet ProkopKillswitch priority_rules)"
grep -Fq '@prokop_rule_byp_subnets return' <<<"$priority" || fail "the earlier bypass section must keep its verdict"
grep -Fq 'ip daddr @prokop_rule_vpn_subnets counter name "ks_vpn" jump ks_reject' <<<"$priority" ||
  fail "the deferred protected section must be rejected"
ks_set="$(nft list set inet ProkopKillswitch prokop_rule_vpn_subnets)"
grep -Fq '93.184.216.0/24' <<<"$ks_set" || fail "the live kill-switch set must hold the destinations"
ok "the kill-switch policy from that table passes nft -c and -f and rejects the deferred section"

printf 'killswitch_deferred_nft_real: PASS\n'
