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
# ip+port: the subnet only on the section's port (optimization 22 keeps
# subnets and ports in two sets).
expect direct lan 192.168.1.60 93.184.221.7 tcp 80
expect direct lan 192.168.1.60 203.0.114.9 tcp 443
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

# ---- NET-1: answers are never captured -------------------------------------

# Capture goes by destination address. The answers of a connection that a
# host in a captured list opened to the router (SSH, LuCI, a WireGuard
# server, ACME) or to a LAN server through it went to sing-box as well,
# and the connection never came up. Packets in conntrack reply direction
# are no longer marked, in prerouting and in the router's output.
expect_answer() { # expect_answer KIND CLIENT SERVER PORT
  local kind="$1" client="$2" server="$3" port="$4" key
  python3 "$PACKETS" "$kind" br-lan "$client" "$server" "$port" || fail "could not send the $kind connection $client -> $server:$port"
  key="\"$client . tcp . $((40000 + port % 20000))\""
  set_elements seen | grep -Fq "$key" || fail "the answer of the $kind connection $client -> $server:$port did not reach the hooks"
  ! set_elements marked | grep -Fq "$key" || fail "the answer of the $kind connection $client -> $server:$port was captured for sing-box"
  nft flush set inet ProkopTestObserve seen
  nft flush set inet ProkopTestObserve marked
}
printf '1\n' >/proc/sys/net/ipv4/ip_forward || fail "forwarding could not be enabled in the namespace"
cat >"$WORK_DIR/answers.uci" <<'EOF'
prokop.settings=settings
prokop.cf=section
prokop.cf.action=vpn
prokop.cf.ip_cidr=93.184.220.0/24
EOF
apply_config "$WORK_DIR/answers.uci"
# Control: new connections to the list are still captured.
expect captured lan 192.168.1.60 93.184.220.5 tcp 22
expect captured local 93.184.220.5 tcp 22
expect_answer inbound 93.184.220.5 192.168.1.1 2222
expect_answer forwarded-reply 93.184.220.6 192.168.1.60 8443
ok "answers of connections from captured addresses to the router and to LAN servers go direct (NET-1)"

# ---- NET-2: the router's own addresses are never captured -------------------

# Only private ranges were exempt from capture. A LAN client (or a router
# process) reaching the router by its WAN address (hairpin, router.lan's
# global IPv6 address) on a captured port was sent to sing-box, as was
# Tailscale and carrier-grade NAT space (100.64.0.0/10).
python3 "$PACKETS" address br-lan:1 81.2.3.4/32 || fail "the router's WAN address could not be added"
cat >"$WORK_DIR/own.uci" <<'EOF'
prokop.settings=settings
prokop.web=section
prokop.web.action=vpn
prokop.web.ports=443 22
EOF
apply_config "$WORK_DIR/own.uci"
# Control: the ports are captured for any other address.
expect captured lan 192.168.1.60 93.184.216.34 tcp 443
expect captured local 93.184.216.34 tcp 443
expect direct lan 192.168.1.60 81.2.3.4 tcp 443
expect direct lan 192.168.1.60 81.2.3.4 tcp 22
expect direct local 81.2.3.4 tcp 443
expect direct lan 192.168.1.60 100.100.1.1 tcp 443
expect direct lan 192.168.1.60 100.64.10.2 tcp 22
expect direct local 100.100.1.1 tcp 443
ok "the router's own addresses and 100.64.0.0/10 go direct (NET-2)"

# ---- NET-9: interface names nft would read as something else ------------------

# The source interfaces went into the nft set unquoted: 'lan@1' (a VLAN
# device) or '10g' are a syntax error there, and the whole start failed.
cat >"$WORK_DIR/ifnames.uci" <<'EOF'
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan lan@1 10g wg*
prokop.web=section
prokop.web.action=vpn
prokop.web.ports=443
EOF
apply_config "$WORK_DIR/ifnames.uci"
# Read in full before matching: a grep -q ending nft early is a SIGPIPE.
grep -q '"lan@1"' <<<"$(nft list set inet "$TABLE" "$INTERFACES")" || fail "the interface lan@1 is not in the capture set"
expect captured lan 192.168.1.60 93.184.216.34 tcp 443
ok "interface names such as lan@1 and 10g are quoted for nft (NET-9)"

# ---- NET-6: client DNS to foreign servers goes to the router -----------------

# seen holds the destination after NAT: a redirected query arrives at the
# router's own address on port 53.
expect_dns() { # expect_dns redirected|direct SRC DST PROTO
  local want="$1" src="$2" dst="$3" proto="$4" elements
  python3 "$PACKETS" lan br-lan "$src" "$dst" "$proto" 53 || fail "could not send DNS to $dst from the LAN"
  elements="$(set_elements seen)"
  if grep -Fq "\"192.168.1.1 . $proto . 53\"" <<<"$elements" && ! grep -Fq "\"$dst . $proto . 53\"" <<<"$elements"; then
    [ "$want" = redirected ] || fail "DNS to $dst over $proto was redirected to the router; it must go direct"
  else
    [ "$want" = direct ] || fail "DNS to $dst over $proto was not redirected to the router: $elements"
  fi
  nft flush set inet ProkopTestObserve seen
  nft flush set inet ProkopTestObserve marked
}
printf '%s\n' prokop.settings=settings prokop.settings.intercept_client_dns=1 prokop.web=section prokop.web.action=vpn \
  prokop.web.domain=example.com prokop.web.kill_switch=1 >"$WORK_DIR/dns-intercept.uci"
apply_config "$WORK_DIR/dns-intercept.uci"
expect_dns redirected 192.168.1.60 8.8.8.8 udp
expect_dns redirected 192.168.1.60 8.8.8.8 tcp
# A resolver in the LAN (a Pi-hole) stays as it is.
expect_dns direct 192.168.1.60 192.168.1.53 udp
printf 'prokop.settings.intercept_client_dns=0\n' >>"$WORK_DIR/dns-intercept.uci"
apply_config "$WORK_DIR/dns-intercept.uci"
# A new client each time: a NAT binding stays with its connection.
expect_dns direct 192.168.1.61 8.8.8.8 udp
# NET-12: without the option the intercept is off, a kill-switch or not.
printf '%s\n' prokop.settings=settings prokop.web=section prokop.web.action=vpn \
  prokop.web.domain=example.com prokop.web.kill_switch=1 >"$WORK_DIR/dns-intercept-off.uci"
apply_config "$WORK_DIR/dns-intercept-off.uci"
expect_dns direct 192.168.1.62 8.8.8.8 udp
printf 'prokop.settings.intercept_client_dns=auto\n' >>"$WORK_DIR/dns-intercept-off.uci"
apply_config "$WORK_DIR/dns-intercept-off.uci"
expect_dns redirected 192.168.1.63 8.8.8.8 udp
ok "client DNS to foreign servers goes to the router only when asked, with auto only while a rule has the kill-switch; LAN resolvers stay (NET-6, NET-12)"

# ---- NET-12: what the intercept leaves alone -----------------------------------

# A VPN server on port 53 and a resolver in the LAN that asks the root
# servers itself are excluded by address, as destination or as source.
printf '%s\n' prokop.settings=settings prokop.settings.intercept_client_dns=1 \
  'prokop.settings.intercept_client_dns_exclude=185.10.20.30 192.168.1.70 2001:db8:53::/48' \
  prokop.web=section prokop.web.action=vpn prokop.web.domain=example.com >"$WORK_DIR/dns-exclude.uci"
apply_config "$WORK_DIR/dns-exclude.uci"
expect_dns direct 192.168.1.64 185.10.20.30 udp
expect_dns direct 192.168.1.64 185.10.20.30 tcp
expect_dns direct 192.168.1.70 8.8.8.8 udp
expect_dns redirected 192.168.1.65 8.8.8.8 udp
grep -q '2001:db8:53::/48' <<<"$(nft list set inet "$TABLE" dns_intercept_skip6)" ||
  fail "the excluded IPv6 subnet is not in the intercept's exclusions"
# dnsmasq without DNS (port 0): redirecting to it would only break DNS.
printf '%s\n' prokop.settings=settings prokop.settings.intercept_client_dns=1 \
  prokop.web=section prokop.web.action=vpn prokop.web.domain=example.com \
  dhcp.cfg01=dnsmasq dhcp.cfg01.port=0 >"$WORK_DIR/dns-port0.uci"
apply_config "$WORK_DIR/dns-port0.uci"
expect_dns direct 192.168.1.66 8.8.8.8 udp
grep -q 'dnsmasq answers no DNS' "$WORK_DIR/logger.log" || fail "the skipped intercept was not logged"
# dnsmasq does not answer on the LAN (notinterface), and the delegated IPv6
# prefixes of the network daemon are the LAN.
cat >"$WORK_DIR/bin/ubus" <<'UBUS'
#!/bin/sh
cat <<'JSON'
{ "interface": [
  { "interface": "lan", "l3_device": "br-lan", "device": "br-lan",
    "ipv6-prefix-assignment": [ { "address": "2001:db8:bb:10::", "mask": 64 } ] },
  { "interface": "wan6", "l3_device": "eth1", "ipv6-prefix": [ { "address": "2001:db8:aa::", "mask": 56 } ] },
  { "interface": "guest", "l3_device": "br-guest", "device": "br-guest" }
] }
JSON
UBUS
chmod 0755 "$WORK_DIR/bin/ubus"
printf '%s\n' prokop.settings=settings prokop.settings.intercept_client_dns=1 \
  prokop.web=section prokop.web.action=vpn prokop.web.domain=example.com \
  dhcp.cfg01=dnsmasq dhcp.cfg01.notinterface=lan >"$WORK_DIR/dns-unserved.uci"
apply_config "$WORK_DIR/dns-unserved.uci"
expect_dns direct 192.168.1.67 8.8.8.8 udp
printf '%s\n' prokop.settings=settings prokop.settings.intercept_client_dns=1 \
  'prokop.settings.source_network_interfaces=br-lan br-guest' \
  prokop.web=section prokop.web.action=vpn prokop.web.domain=example.com \
  dhcp.cfg01=dnsmasq dhcp.cfg01.interface=guest >"$WORK_DIR/dns-served.uci"
apply_config "$WORK_DIR/dns-served.uci"
expect_dns direct 192.168.1.68 8.8.8.8 udp
rules="$(nft list chain inet "$TABLE" dns_redirect)"
grep -q 'iifname != "br-lan"' <<<"$rules" || fail "the intercept does not leave out br-lan, where dnsmasq does not answer: $rules"
prefixes="$(nft list set inet "$TABLE" dns_intercept_lan6)"
grep -q '2001:db8:aa::/56' <<<"$prefixes" && grep -q "2001:db8:bb:10::/64" <<<"$prefixes" ||
  fail "the delegated IPv6 prefixes are not left alone: $prefixes"
rm -f "$WORK_DIR/bin/ubus"
ok "the intercept leaves excluded addresses, interfaces dnsmasq does not answer on and delegated IPv6 prefixes alone, and is off while dnsmasq answers no DNS (NET-12)"

# ---- NET-10: the table vanishes between building and committing a reload -----

# A reload built its batch with a bare 'delete table' when the table was
# there. When it was gone by the commit (fw4 flush, a stop meanwhile), the
# whole batch failed with "No such file or directory" and the reload with it.
batch="$WORK_DIR/reload.nft"
printf '# Prokop nft candidate\n' >"$batch"
nft list table inet "$TABLE" >/dev/null || fail "the table of the previous case is gone"
PROKOP_UCI_STATE_FILE="$WORK_DIR/ifnames.uci" PROKOP_NFT_BATCH_FILE="$batch" \
  nft_uc nft-rebuild-runtime-from-uci "${rebuild_args[@]}" || fail "the reload candidate was not built"
nft delete table inet "$TABLE"
nft_uc nft-commit-candidate-batch "$batch" 2>"$batch.err" ||
  fail "the reload failed once the table was gone before its commit: $(cat "$batch.err")"
nft list table inet "$TABLE" >/dev/null || fail "the reload did not create the table"
ok "a reload commits when its table vanished after the batch was built (NET-10)"

printf 'real nft dataplane checks passed\n'
