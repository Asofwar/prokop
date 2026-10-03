#!/usr/bin/env bash
# Prokop's dataplane with the real nft and real packets: which connections
# the production ruleset hands to sing-box (the FakeIP/tproxy mark) and
# which it lets through.
#
# A private network namespace stands in for the router: a TUN interface is
# its LAN bridge (LAN clients' packets are written into it) and router-local
# sockets send their own packets. The ruleset is the start/reload candidate
# of nft/apply.uc for each configuration, applied by the real nft. A
# separate observer table after Prokop's hooks records every packet and
# every packet that carries the FakeIP mark.
#
# Skipped only when such a namespace, nft, python3 or a TUN device is not
# available.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
NFT_UC="$PROKOP_LIB/nft/apply.uc"
CHECK_JS="$ROOT_DIR/tests/helpers/nft_real_check.js"
PACKETS="$ROOT_DIR/tests/helpers/nft_packets.py"
NAMESPACE=(unshare --user --map-root-user --net --mount)

namespaces() { printf '%s %s' "$(readlink /proc/self/ns/net)" "$(readlink /proc/self/ns/mnt)"; }

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: nft_dataplane_real: %s\n' "$1"
    exit 0
  }
  command -v nft >/dev/null 2>&1 || skip 'nft is not installed'
  command -v unshare >/dev/null 2>&1 || skip 'unshare is not installed'
  command -v python3 >/dev/null 2>&1 || skip 'python3 is not installed'
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
trap 'rm -rf "${WORK_DIR:?}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'live ruleset:\n' >&2
  nft list ruleset >&2 2>/dev/null || true
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

if ! python3 "$PACKETS" setup br-lan 192.168.1.1/24 2>"$WORK_DIR/setup.err"; then
  printf 'SKIP: nft_dataplane_real: no TUN interface in the namespace: %s\n' "$(cat "$WORK_DIR/setup.err")"
  exit 0
fi

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/tmp"
export TMPDIR="$WORK_DIR/tmp"
# The policy routes are not under test here (tests/nft_apply.sh): ip only logs.
printf '#!/bin/sh\nprintf "ip %%s\\n" "$*" >>"%s/ip.log"\n' "$WORK_DIR" >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/logger.log"\n' "$WORK_DIR" >"$WORK_DIR/bin/logger"
chmod 0755 "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_RT_TABLES="$WORK_DIR/rt_tables" PROKOP_LIB
export PROKOP_NFT_SUBNET_CACHE_DIR="$WORK_DIR/nft-subnet-cache"

nft_uc() { ucode -L "$PROKOP_LIB" "$NFT_UC" "$@"; }
constant() { ucode -L "$PROKOP_LIB" "$PROKOP_LIB/core/constants.uc" get "$1"; }

RT_TABLE="$(constant RT_TABLE_NAME)"
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
OUTBOUND_MARK="$(constant NFT_OUTBOUND_MARK)"
FAKEIP_RANGE="$(constant SB_FAKEIP_INET4_RANGE)"
FAKEIP6_RANGE="$(constant SB_FAKEIP_INET6_RANGE)"
TPROXY_PORT="$(constant SB_TPROXY_INBOUND_PORT)"
TPROXY6_ADDRESS="$(constant SB_TPROXY_INBOUND6_ADDRESS)"
MISSING="$WORK_DIR/missing"

# No DPI provider binary: the configurations here need no NFQUEUE rules.
rebuild_args=(
  "$RT_TABLE" "$TABLE" "$LOCALV4" "$COMMON" "$PORTS" "$IP_PORTS" "$INTERFACES"
  "$FAKEIP_MARK" "$OUTBOUND_MARK" "$FAKEIP_RANGE" "$TPROXY_PORT"
  "$MISSING/nfqws" "$(constant ZAPRET_ROUTE_MARK_BASE)" "$(constant ZAPRET_QUEUE_BASE)"
  "$(constant ZAPRET_DESYNC_MARK)" "$(constant ZAPRET_DESYNC_MARK_POSTNAT)"
  "$MISSING/nfqws2" "$(constant ZAPRET2_ROUTE_MARK_BASE)" "$(constant ZAPRET2_QUEUE_BASE)"
  "$(constant ZAPRET2_DESYNC_MARK)" "$(constant ZAPRET2_DESYNC_MARK_POSTNAT)"
  "$LOCALV6" "$COMMON6" "$IP6_PORTS" "$FAKEIP6_RANGE" "$TPROXY6_ADDRESS"
)
populate_args=(
  1 "" "$TABLE" "$COMMON" "$PORTS" "$IP_PORTS" "$INTERFACES" "$LOCALV4" "$FAKEIP_MARK"
  "$COMMON6" "$IP6_PORTS" "$LOCALV6"
)

# Applies the start/reload candidate for the UCI state in $1 and a fresh
# observer table after it.
apply_config() {
  local state="$1" batch="$WORK_DIR/candidate.nft"
  nft delete table inet "$TABLE" 2>/dev/null || true
  nft delete table inet ProkopTestObserve 2>/dev/null || true
  printf '# Prokop nft candidate\n' >"$batch"
  PROKOP_UCI_STATE_FILE="$state" PROKOP_NFT_BATCH_FILE="$batch" \
    nft_uc nft-rebuild-runtime-from-uci "${rebuild_args[@]}" || fail "$state: nft-rebuild-runtime-from-uci failed"
  PROKOP_UCI_STATE_FILE="$state" PROKOP_NFT_BATCH_FILE="$batch" \
    nft_uc nft-populate-runtime-sets-from-uci "${populate_args[@]}" || fail "$state: nft-populate-runtime-sets-from-uci failed"
  nft_uc nft-validate-candidate-batch "$batch" 2>"$batch.err" || fail "$state: nft -c rejected the batch: $(cat "$batch.err")"
  nft_uc nft-commit-candidate-batch "$batch" 2>"$batch.err" || fail "$state: nft -f rejected the batch: $(cat "$batch.err")"
  nft -f - <<EOF || fail "the observer table was not applied"
table inet ProkopTestObserve {
  set seen { type ipv4_addr . inet_proto . inet_service; flags dynamic; }
  set marked { type ipv4_addr . inet_proto . inet_service; flags dynamic; }
  chain pre {
    type filter hook prerouting priority -50; policy accept;
    meta l4proto { tcp, udp } add @seen { ip daddr . meta l4proto . th dport }
    meta l4proto { tcp, udp } meta mark & $FAKEIP_MARK == $FAKEIP_MARK add @marked { ip daddr . meta l4proto . th dport }
  }
  chain out {
    type filter hook output priority 0; policy accept;
    meta l4proto { tcp, udp } add @seen { ip daddr . meta l4proto . th dport }
    meta l4proto { tcp, udp } meta mark & $FAKEIP_MARK == $FAKEIP_MARK add @marked { ip daddr . meta l4proto . th dport }
  }
}
EOF
}

set_elements() {
  nft -j list set inet ProkopTestObserve "$1" >"$WORK_DIR/set.json"
  node "$CHECK_JS" elements "$WORK_DIR/set.json" ProkopTestObserve "$1"
}

# expect captured|direct lan SRC DST PROTO PORT  /  expect ... local DST PROTO PORT [MARK]
expect() {
  local want="$1" origin="$2" dst proto port key
  shift 2
  if [ "$origin" = lan ]; then
    dst="$2" proto="$3" port="$4"
    python3 "$PACKETS" lan br-lan "$@" || fail "could not send $* from the LAN"
  else
    dst="$1" proto="$2" port="$3"
    python3 "$PACKETS" local "$@" || fail "could not send $* from the router"
  fi
  key="\"$dst . $proto . $port\""
  set_elements seen | grep -Fq "$key" || fail "the $origin packet $* did not reach the hooks"
  if set_elements marked | grep -Fq "$key"; then
    [ "$want" = captured ] || fail "the $origin packet $* was captured for sing-box; it must go direct"
  else
    [ "$want" = direct ] || fail "the $origin packet $* was not captured; it must reach sing-box"
  fi
  # One packet per destination: the next check starts from empty sets.
  nft flush set inet ProkopTestObserve seen
  nft flush set inet ProkopTestObserve marked
}

# ---- UC-030: ByeDPI rules with IPs, subnets or ports ----------------------------

# ciadpi's own upstream connections are router-local sockets without a mark.
# Captured, they would come back to sing-box and the same ByeDPI rule (a
# loop). Since D-8(a) no ByeDPI section captures router-local traffic; LAN
# clients are still captured.
cat >"$WORK_DIR/byedpi.uci" <<'EOF'
prokop.settings=settings
prokop.bye=section
prokop.bye.action=byedpi
prokop.bye.ip_cidr=93.184.220.0/24
prokop.byeports=section
prokop.byeports.action=byedpi
prokop.byeports.ports=8443
prokop.byeipports=section
prokop.byeipports.action=byedpi
prokop.byeipports.ip_cidr=93.184.221.0/24
prokop.byeipports.ports=443
EOF
apply_config "$WORK_DIR/byedpi.uci"
expect captured lan 192.168.1.60 93.184.220.5 tcp 443
expect captured lan 192.168.1.60 93.184.220.5 udp 443
expect captured lan 192.168.1.60 203.0.114.9 tcp 8443
expect captured lan 192.168.1.60 93.184.221.7 tcp 443
expect direct local 93.184.220.5 tcp 443
expect direct local 93.184.220.5 udp 443
expect direct local 203.0.114.9 tcp 8443
expect direct local 203.0.114.9 udp 8443
expect direct local 93.184.221.7 tcp 443
ok "ByeDPI with ip_cidr, port-only and ip+port matchers: LAN captured, ciadpi's own unmarked sockets go direct (UC-030)"

# Known risk (UC-185, D-8(b) not implemented): another section's router-local
# capture still takes ciadpi's upstream connection. A domain-only ByeDPI rule
# plus a port-only VPN rule: ciadpi's connection to the site's real address
# on 443 is captured by the VPN rule and sent back to sing-box, where the
# earlier ByeDPI domain rule may take it again. This assertion pins the
# remaining loop; change it when ciadpi's sockets are exempted by cgroup/uid.
cat >"$WORK_DIR/byedpi-vpn.uci" <<'EOF'
prokop.settings=settings
prokop.bd=section
prokop.bd.action=byedpi
prokop.bd.domain=rutracker.org
prokop.vpn=section
prokop.vpn.action=vpn
prokop.vpn.ports=443
EOF
apply_config "$WORK_DIR/byedpi-vpn.uci"
expect captured local 104.21.32.1 tcp 443
expect direct local 104.21.32.1 tcp 444
expect direct local 104.21.32.1 tcp 443 "$OUTBOUND_MARK"
ok "byedpi domain + port-only VPN rule: ciadpi's unmarked upstream is still captured by the VPN rule (known risk UC-185)"

# ---- UC-029: bypass priority rules and FakeIP addresses ------------------------

# A FakeIP address (here for youtube.com of the 'yt' rule) only means
# something to sing-box. A bypass rule by ports, by device and ports, or by a
# subnet covering the FakeIP range must still hand it to sing-box, which then
# applies the bypass rule in UCI order to the real address; accepted without
# the mark, the connection would be lost. Real addresses keep the bypass
# fast path.
cat >"$WORK_DIR/bypass.uci" <<'EOF'
prokop.settings=settings
prokop.yt=section
prokop.yt.action=connection
prokop.yt.domain_suffix=youtube.com
prokop.tv=section
prokop.tv.action=bypass
prokop.tv.source_ip_cidr=192.168.1.50/32
prokop.tv.ports=443
prokop.pb=section
prokop.pb.action=bypass
prokop.pb.ports=8443
prokop.all=section
prokop.all.action=bypass
prokop.all.source_ip_cidr=192.168.1.70/32
prokop.all.ip_cidr=0.0.0.0/0
prokop.allports=section
prokop.allports.action=bypass
prokop.allports.source_ip_cidr=192.168.1.80/32
prokop.allports.ip_cidr=0.0.0.0/0
prokop.allports.ports=443
EOF
apply_config "$WORK_DIR/bypass.uci"
FAKE_ADDRESS="${FAKEIP_RANGE%/*}"
FAKE_ADDRESS="${FAKE_ADDRESS%.*}.5"
expect captured lan 192.168.1.50 "$FAKE_ADDRESS" tcp 443
expect captured lan 192.168.1.50 "$FAKE_ADDRESS" udp 443
expect captured lan 192.168.1.60 "$FAKE_ADDRESS" tcp 8443
expect captured lan 192.168.1.70 "$FAKE_ADDRESS" tcp 443
expect captured lan 192.168.1.80 "$FAKE_ADDRESS" tcp 443
expect captured local "$FAKE_ADDRESS" tcp 8443
expect captured local "$FAKE_ADDRESS" udp 8443
expect direct lan 192.168.1.50 93.184.216.34 tcp 443
expect direct lan 192.168.1.60 93.184.216.34 tcp 8443
expect direct lan 192.168.1.70 93.184.216.34 tcp 443
expect direct lan 192.168.1.80 93.184.216.34 tcp 443
expect direct local 93.184.216.34 tcp 8443
ok "bypass rules by ports, device and ports, and subnets: FakeIP addresses still reach sing-box, real addresses bypass (UC-029)"

# ---- UC-104: other output hooks of the same priority ---------------------------

# Another output hook at -150 (fw4's mangle_output, pbr, mwan3) registered
# after Prokop's runs before it and may OR its own bits into the mark. sing-box
# sockets (the outbound mark) must still leave mangle_output at once: here
# to a FakeIP address, which the generic output rules would otherwise
# capture back into sing-box.
apply_config "$WORK_DIR/bypass.uci"
expect direct local "$FAKE_ADDRESS" udp 444 "$OUTBOUND_MARK"
nft -f - <<'EOF' || fail "the foreign output hook was not applied"
table inet ProkopTestForeign {
  chain mangle_output {
    type route hook output priority -150; policy accept;
    meta mark set meta mark | 0x00010000
  }
}
EOF
expect direct local "$FAKE_ADDRESS" udp 443 "$OUTBOUND_MARK"
expect direct local "$FAKE_ADDRESS" tcp 443 "$OUTBOUND_MARK"
expect captured local "$FAKE_ADDRESS" udp 443
nft delete table inet ProkopTestForeign
ok "a foreign output hook ORing its bits into sing-box's mark does not send sing-box's own traffic back to it (UC-104)"

printf 'real nft dataplane checks passed\n'
