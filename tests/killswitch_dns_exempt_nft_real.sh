#!/usr/bin/env bash
# D-23 with the real nft and real packets: only the excluded devices of
# sections that exempt them bypass the kill-switch's DNS block while Prokop
# is stopped; every other client stays blocked, and so do the names of every
# section that does not exempt the device.
#
# A private network namespace stands in for the router: a TUN interface is
# its LAN bridge, clients' DNS queries are written into it and their answers
# read back. tests/helpers/dns_tun.py answers like the router's resolvers
# (the main dnsmasq with the shared block list, one per group of excluded
# devices with the configuration the kill-switch generated for it). The
# kill-switch itself is the production code: its sync applies the policy
# from a real live ProkopTable, its watcher puts the redirect into the real
# table, and the kernel routes the packets.
#
# Skipped only when such a namespace, nft, python3 or a TUN device is not
# available.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
NFT_UC="$PROKOP_LIB/nft/apply.uc"
DNS_UC="$PROKOP_LIB/dns/apply.uc"
HELPER="$ROOT_DIR/tests/helpers/dns_tun.py"
NAMESPACE=(unshare --user --map-root-user --net --mount)

namespaces() { printf '%s %s' "$(readlink /proc/self/ns/net)" "$(readlink /proc/self/ns/mnt)"; }

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: killswitch_dns_exempt_nft_real: %s\n' "$1"
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
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
RESOLVERS=""
cleanup() {
  [ -z "$RESOLVERS" ] || owned_kill TERM "$RESOLVERS" || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'live ruleset:\n' >&2
  nft list ruleset >&2 2>/dev/null || true
  printf 'resolver log:\n' >&2
  cat "$WORK_DIR/resolvers.log" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

if ! setup="$(python3 "$HELPER" setup br-lan 192.168.1.1/24 fd00::1/64 2>"$WORK_DIR/setup.err")"; then
  printf 'SKIP: killswitch_dns_exempt_nft_real: no TUN interface in the namespace: %s\n' "$(cat "$WORK_DIR/setup.err")"
  exit 0
fi
# The rules for IPv6 clients are checked in the kernel's ruleset either way;
# their packets only where the kernel has IPv6.
IPV6=1
if [ "$setup" != "ipv6 available" ]; then
  IPV6=0
  printf 'NOTE: this kernel has no IPv6; IPv6 clients are not queried\n'
fi
if ! printf 'add table inet ks_probe\nadd chain inet ks_probe c { type nat hook prerouting priority -102; policy accept; }\nadd rule inet ks_probe c fib daddr type local udp dport 53 redirect to :1\n' |
  nft -c -f - >/dev/null 2>&1; then
  printf 'SKIP: killswitch_dns_exempt_nft_real: this kernel has no nft redirect or fib expression\n'
  exit 0
fi

STATE_DIR="$WORK_DIR/ks"
CONF_DIR="$WORK_DIR/conf"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/stub" "$WORK_DIR/run" "$WORK_DIR/gen" "$STATE_DIR" "$CONF_DIR"
for name in logger dnsmasq-init killswitch-init; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
# The watcher's dig: a real query.
printf '#!/bin/sh\nexec python3 "%s" dig "$@"\n' "$HELPER" >"$WORK_DIR/bin/dig"
# Only to learn which live sets the render reads; never on PATH otherwise.
cat >"$WORK_DIR/stub/nft" <<'EOF'
#!/bin/sh
# The live table with every set a rule section of the UCI state can have.
if [ "$1 $2" = "list table" ]; then
  printf 'table inet %s {\n' "$4"
  for section in $(sed -n 's/^prokop\.\([A-Za-z0-9_]*\)=section$/\1/p' "$PROKOP_UCI_STATE_FILE"); do
    for suffix in subnets subnets6 ip_ports ip6_ports port_subnets port_subnets6 subnet_ports udp_port_subnets udp_port_subnets6 udp_subnet_ports ports sources sources6 \
      fully_sources fully_sources6 excluded_sources excluded_sources6; do
      printf '\tset prokop_rule_%s_%s {\n\t\ttype ipv4_addr\n\t}\n' "$section" "$suffix"
    done
  done
  printf '}\n'
fi
exit 0
EOF
chmod 0755 "$WORK_DIR/bin/"* "$WORK_DIR/stub/nft"

export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export KILLSWITCH_STATE_DIR="$STATE_DIR"
export KILLSWITCH_CACHE_DIR="$CONF_DIR"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/90-prokop-killswitch.nft"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"
export PROKOP_KILLSWITCH_WATCH_INTERVAL_MS=1
export DNS_TUN_LOG="$WORK_DIR/resolvers.log"
SERVERS="$STATE_DIR/dnsmasq.servers"
EXEMPT="$STATE_DIR/dns-exempt.json"

ks() { ucode -L "$PROKOP_LIB" "$KS_UC" "$@"; }

# ---- a running Prokop with four protected sections ----------------------------

printf '{"version":3,"rules":[{"domain_suffix":["second-list.example"]}]}\n' >"$WORK_DIR/gen/second.json"
outbound_json() {
  printf '{\\"type\\":\\"http\\",\\"tag\\":\\"%s\\",\\"server\\":\\"proxy.example\\",\\"server_port\\":8080}' "$1"
}
cat >"$WORK_DIR/gen/fixture.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8" },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json a)" ], "domain_suffix": [ "main-inline.example" ],
      "ip_cidr": [ "3.3.3.0/24" ], "excluded_source_ip_cidr": [ "192.168.1.50" ] },
    { ".name": "excl", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json b)" ], "domain_suffix": [ "excl-inline.example", "shared.example" ],
      "rule_set": [ "$WORK_DIR/gen/second.json" ],
      "excluded_source_ip_cidr": [ "192.168.1.50", "192.168.1.0/28", "fd00::50" ] },
    { ".name": "excl2", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json c)" ], "domain_suffix": [ "excl2-inline.example" ],
      "excluded_source_ip_cidr": [ "192.168.1.5" ] },
    { ".name": "free", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": [ "$(outbound_json e)" ], "domain_suffix": [ "sub.shared.example" ] },
    { ".name": "late", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json d)" ], "domain_suffix": [ "shared.example" ] }
  ]
}
JSON
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/gen/fixture.json" "$WORK_DIR/config.json" 192.168.1.1 0 1 '' 1.13.0 >/dev/null ||
  fail "the generator fixture could not be generated"

# $1: whether excl and excl2 exempt their excluded devices; $2: the server
# dnsmasq forwards to (127.0.0.42 while Prokop runs); IFACES: the LAN
# interfaces (br-lan).
write_uci() {
  {
    printf 'prokop.settings=settings\nprokop.settings.source_network_interfaces=%s\n' "${IFACES:-br-lan}"
    printf 'prokop.settings.config_path=%s\n' "$WORK_DIR/config.json"
    printf 'prokop.main=section\nprokop.main.action=connection\nprokop.main.kill_switch=1\n'
    printf 'prokop.main.ip_cidr=3.3.3.0/24\nprokop.main.excluded_source_ip_cidr=192.168.1.50\n'
    printf 'prokop.excl=section\nprokop.excl.action=connection\nprokop.excl.kill_switch=1\n'
    printf 'prokop.excl.excluded_source_ip_cidr=192.168.1.50 192.168.1.0/28 fd00::50\n'
    printf 'prokop.excl2=section\nprokop.excl2.action=connection\nprokop.excl2.kill_switch=1\n'
    printf 'prokop.excl2.excluded_source_ip_cidr=192.168.1.5\n'
    if [ "$1" = 1 ]; then
      printf 'prokop.excl.kill_switch_dns_exempt=1\nprokop.excl2.kill_switch_dns_exempt=1\n'
    fi
    printf 'prokop.free=section\nprokop.free.action=connection\n'
    printf 'prokop.late=section\nprokop.late.action=connection\nprokop.late.kill_switch=1\n'
    printf 'dhcp.@dnsmasq[0]=dnsmasq\ndhcp.@dnsmasq[0].server=%s\ndhcp.@dnsmasq[0].prokop_server=1.1.1.1\n' "$2"
    printf 'dhcp.@dnsmasq[0].serversfile=%s\n' "$SERVERS"
  } >"$PROKOP_UCI_STATE_FILE"
}

write_uci 1 127.0.0.42
PATH="$WORK_DIR/stub:$PATH" ucode -L "$PROKOP_LIB" "$NFT_UC" killswitch-render ProkopTable ProkopKillswitch \
  "$WORK_DIR/sets.nft" 198.18.0.0/15 fc00::/18 >/dev/null || fail "could not render the set layout"
{
  printf 'add table inet ProkopTable\n'
  grep '^add set inet ProkopKillswitch prokop_rule_' "$WORK_DIR/sets.nft" | sed 's/ ProkopKillswitch / ProkopTable /'
  printf 'add element inet ProkopTable prokop_rule_main_subnets { 3.3.3.0/24 }\n'
} >"$WORK_DIR/live.nft"
nft -f "$WORK_DIR/live.nft" || fail "could not create the live ProkopTable"

ks sync start || fail "sync from the real live table failed"
nft list table inet ProkopKillswitch >/dev/null 2>&1 || fail "the synced policy is not live"
[ -s "$EXEMPT" ] || fail "the groups of excluded devices must be saved"
cp "$STATE_DIR/policy.nft" "$WORK_DIR/policy.exempt"
# Only the client DNS intercept (NET-6) is static; the redirects of excluded
# devices are the watcher's.
if grep redirect "$WORK_DIR/policy.exempt" | grep -vq ' ks_dns_intercept '; then fail "the saved firewall policy redirects nothing"; fi
grep -q ' ks_exempt_guard ' "$WORK_DIR/policy.exempt" || fail "the saved firewall policy guards the resolvers of excluded devices"

# Prokop stops: dnsmasq answers with the shared block list.
write_uci 1 1.1.1.1
ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
grep -Fqx 'server=/excl-inline.example/' "$SERVERS" || fail "a stopped Prokop blocks the names of excl for every client"

ks exempt-configs "$CONF_DIR" >"$WORK_DIR/confs" || fail "exempt-configs failed"
[ "$(wc -l <"$WORK_DIR/confs")" = 2 ] || fail "two groups of excluded devices expected: $(cat "$WORK_DIR/confs")"
# The router's resolvers for the configurations in $WORK_DIR/confs.
serve() {
  [ -z "$RESOLVERS" ] || owned_kill TERM "$RESOLVERS" || true
  : >"$WORK_DIR/serve.out"
  # shellcheck disable=SC2046
  python3 "$HELPER" serve "$SERVERS" $(cat "$WORK_DIR/confs") >"$WORK_DIR/serve.out" 2>&1 &
  RESOLVERS=$!
  wait_until 10 resolvers_ready || fail "the resolvers did not start: $(cat "$WORK_DIR/serve.out")"
}
resolvers_ready() { grep -qxs ready "$WORK_DIR/serve.out"; }
serve

PROKOP_KILLSWITCH_WATCH_ITERATIONS=2 ks watch || fail "watch failed"
chain="$(nft list chain inet ProkopKillswitch ks_dns)"
grep -Fq 'ip saddr 192.168.1.5 fib daddr type local udp dport 53 counter' <<<"$chain" ||
  fail "the kernel must hold the redirect of the excluded devices: $chain"
grep -Fq 'ip6 saddr fd00::50 fib daddr type local' <<<"$chain" || fail "the IPv6 excluded device must be redirected: $chain"

# ---- what the clients get --------------------------------------------------------

ask() { DNS_TUN_DEADLINE="${DEADLINE:-2}" python3 "$HELPER" query br-lan "$1" "$2" "$3" "${4:-53}"; }
expect() {
  local src="$1" name="$2" want="$3" dst="${4:-192.168.1.1}" port="${5:-53}" got
  if [[ "$src" == *:* ]]; then
    [ "$IPV6" = 1 ] || return 0
    [ "$dst" != 192.168.1.1 ] || dst=fd00::1
  fi
  local deadline=8
  [ "$want" != noreply ] || deadline=2
  got="$(DEADLINE="$deadline" ask "$src" "$dst" "$name" "$port")"
  case "$want" in
    blocked) [[ "$got" == "rcode=3 "* ]] || fail "$src must get NXDOMAIN for $name, got: $got" ;;
    exempt) [[ "$got" =~ ^rcode=0\ answer=203\.0\.113\.5[5-8]\ sport=53$ ]] ||
      fail "$src must resolve $name through its own resolver, got: $got" ;;
    shared) [[ "$got" == "rcode=0 answer=203.0.113.53 sport=53" ]] ||
      fail "$src must resolve $name through the main dnsmasq, got: $got" ;;
    noreply) [ "$got" = noreply ] || fail "$src must get no answer for $name from $dst, got: $got" ;;
  esac
}
# Excluded from excl only (and from main, which does not exempt it).
expect 192.168.1.50 excl-inline.example exempt
expect 192.168.1.50 second-list.example exempt
expect 192.168.1.50 unrelated.example exempt
expect 192.168.1.50 main-inline.example blocked
expect 192.168.1.50 excl2-inline.example blocked
expect 192.168.1.50 shared.example blocked
# For .50 shared.example is blocked by late, after the unprotected free.
expect 192.168.1.50 sub.shared.example exempt
expect 192.168.1.10 excl-inline.example exempt
expect 192.168.1.10 excl2-inline.example blocked
# Excluded from excl and excl2.
expect 192.168.1.5 excl2-inline.example exempt
expect 192.168.1.5 excl-inline.example exempt
expect 192.168.1.5 main-inline.example blocked
expect fd00::50 excl-inline.example exempt
ok "the excluded devices of exempting sections resolve those sections' names"

# Every other client keeps the shared block list.
for client in 192.168.1.70 192.168.1.16 fd00::70; do
  expect "$client" excl-inline.example blocked
  expect "$client" excl2-inline.example blocked
  expect "$client" second-list.example blocked
  expect "$client" sub.shared.example blocked
  expect "$client" unrelated.example shared
done
ok "every other client stays blocked"

# The resolvers of excluded devices answer only DNS the kill-switch
# redirected to them, not clients that ask them directly.
for port in 18055 18056; do
  for client in 192.168.1.70 192.168.1.50 fd00::70; do
    expect "$client" excl-inline.example noreply 192.168.1.1 "$port"
  done
done
expect 192.168.1.50 excl-inline.example exempt
ok "clients cannot ask the resolvers of excluded devices directly"

# Only DNS for the router itself goes to their resolvers.
: >"$WORK_DIR/resolvers.log"
expect 192.168.1.50 excl-inline.example noreply 192.168.1.99
[ ! -s "$WORK_DIR/resolvers.log" ] || fail "DNS for another server must not reach the router's resolvers: $(cat "$WORK_DIR/resolvers.log")"
ok "DNS for other servers is not redirected"

# A firewall reload loads the saved policy without the redirect; the
# watcher puts it back.
nft delete table inet ProkopKillswitch
nft -f "$STATE_DIR/policy.nft" || fail "the saved policy does not load"
expect 192.168.1.50 excl-inline.example blocked
PROKOP_KILLSWITCH_WATCH_ITERATIONS=1 ks watch || fail "watch failed"
expect 192.168.1.50 excl-inline.example exempt
ok "the watcher restores the redirect after a firewall reload"

# ---- without the option: as before ------------------------------------------------

write_uci 0 127.0.0.42
ks sync start || fail "sync without the option failed"
[ ! -e "$EXEMPT" ] || fail "without the option no groups may be saved"
cmp -s "$STATE_DIR/policy.nft" <(grep -v ' ks_exempt_guard ' "$WORK_DIR/policy.exempt") ||
  fail "the option must not change the firewall policy apart from the guard of its resolvers"
write_uci 0 1.1.1.1
ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
[ -z "$(ks exempt-configs "$CONF_DIR")" ] || fail "without the option no resolver of excluded devices may run"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=1 ks watch || fail "watch failed"
if grep -q redirect <<<"$(nft list chain inet ProkopKillswitch ks_dns)"; then
  fail "without the option nothing may be redirected"
fi
for client in 192.168.1.50 192.168.1.5 fd00::50 192.168.1.70; do
  expect "$client" excl-inline.example blocked
done
expect 192.168.1.50 unrelated.example shared
ok "without the option every client keeps the shared block list"

# ---- LAN interfaces dnsmasq cannot be given by name --------------------------------
#
# A wildcard matches br-lan in the kill-switch's interface set; the
# resolvers of excluded devices must then listen on br-lan as well.
IFACES='br-*' write_uci 1 127.0.0.42
ks sync start || fail "sync with a wildcard interface failed"
IFACES='br-*' write_uci 1 1.1.1.1
ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
ks exempt-configs "$CONF_DIR" >"$WORK_DIR/confs" || fail "exempt-configs failed"
serve
PROKOP_KILLSWITCH_WATCH_ITERATIONS=1 ks watch || fail "watch failed"
expect 192.168.1.50 excl-inline.example exempt
expect 192.168.1.5 excl2-inline.example exempt
expect 192.168.1.70 excl-inline.example blocked
ok "with a wildcard interface the excluded devices reach their resolvers"

# ---- the owner goes: nothing stays --------------------------------------------------

write_uci 1 127.0.0.42
ks sync start || fail "sync failed"
write_uci 1 1.1.1.1
ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
ks exempt-configs "$CONF_DIR" >/dev/null || fail "exempt-configs failed"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=1 ks watch || fail "watch failed"
expect 192.168.1.50 excl-inline.example exempt
ks release "package removal" || fail "release failed"
if nft list table inet ProkopKillswitch >/dev/null 2>&1; then fail "the package removal must remove the table"; fi
[ ! -e "$EXEMPT" ] || fail "the package removal must remove the groups"
ls "$CONF_DIR"/exempt-*.conf >/dev/null 2>&1 && fail "the package removal must remove the resolver configurations"
expect 192.168.1.50 excl-inline.example shared
expect 192.168.1.70 excl-inline.example shared
ok "the package removal lifts the exemption with the rest of the kill-switch"

printf 'killswitch_dns_exempt_nft_real: PASS\n'
