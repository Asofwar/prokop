#!/usr/bin/env bash
# D-23: a protected section may let its excluded devices resolve its names
# while Prokop is stopped. The block list of the main dnsmasq is shared by
# every client, so it never changes: the excluded devices get resolvers of
# their own (groups by the rules that do not apply to them), the kill-switch
# watcher redirects exactly their DNS for the router there while Prokop is
# stopped, and only to a resolver that answers with the configuration of its
# group. Without the option every file, the state and the DNS chain stay as
# they were. The firewall policy never changes.
#
# Real nft and real packets: tests/killswitch_dns_exempt_nft_real.sh.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
DNS_UC="$PROKOP_LIB/dns/apply.uc"
VALIDATOR="$PROKOP_LIB/config/validator.uc"
INIT_SCRIPT="$ROOT_DIR/prokop/files/etc/init.d/prokop-killswitch"
KEEP_LIST="$ROOT_DIR/prokop/files/lib/upgrade/keep.d/prokop-killswitch"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'ks_dns:\n' >&2
  cat "$WORK_DIR/ks_dns" >&2 2>/dev/null || true
  printf 'state.json:\n' >&2
  cat "$KILLSWITCH_STATE_DIR/state.json" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/conf" "$WORK_DIR/gen"
# The live tables: ProkopTable while Prokop runs, the kill-switch table and
# its DNS chain (only the rules of a batch that flushes it).
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK_DIR/nft.log"
case "$1 $2" in
  "list table")
    [ "$4" = "ProkopTable" ] && { [ -e "$WORK_DIR/live-present" ]; exit $?; }
    [ "$4" = "ProkopKillswitch" ] && { [ -e "$WORK_DIR/ks-present" ]; exit $?; }
    exit 1 ;;
  "list set")
    printf 'table inet ProkopTable {\n\tset %s {\n\t\ttype ipv4_addr\n\t}\n}\n' "$5"
    exit 0 ;;
  "list chain")
    [ -e "$WORK_DIR/ks-present" ] || exit 1
    printf 'table inet ProkopKillswitch {\n\tchain ks_dns {\n'
    sed 's/^/\t\t/' "$WORK_DIR/ks_dns" 2>/dev/null
    printf '\t}\n}\n'
    exit 0 ;;
  "-c -f")
    grep -q 'add table inet ProkopKillswitch' "$3" || exit 1
    exit 0 ;;
  "-f "*)
    if grep -q '^flush chain inet ProkopKillswitch ks_dns$' "$2"; then
      sed -n 's/^add rule inet ProkopKillswitch ks_dns //p' "$2" > "$WORK_DIR/ks_dns"
    else
      cp "$2" "$WORK_DIR/live.nft"; touch "$WORK_DIR/ks-present"; : > "$WORK_DIR/ks_dns"
    fi
    exit 0 ;;
  "delete table")
    rm -f "$WORK_DIR/ks-present"; exit 0 ;;
  "-j list")
    printf '{"nftables":[]}\n'; exit 0 ;;
esac
exit 0
NFT
# A resolver answers on its port with what its configuration says: the probe
# name of its group, unless it is down.
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK_DIR/dig.log"
port=53 server="" name=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) port="$2"; shift ;;
    @*) server="${1#@}" ;;
    +*) ;;
    A) ;;
    *) name="$1" ;;
  esac
  shift
done
if [ "$server" = 127.0.0.42 ]; then [ -e "$WORK_DIR/sing-box-alive" ]; exit $?; fi
[ ! -e "$WORK_DIR/dead-$port" ] || exit 9
# fail-at-PORT: the numbers of the probes of that port that fail.
calls=$(( $(cat "$WORK_DIR/calls-$port" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$calls" >"$WORK_DIR/calls-$port"
if [ -e "$WORK_DIR/fail-at-$port" ] && grep -qx "$calls" "$WORK_DIR/fail-at-$port"; then exit 9; fi
for conf in "$WORK_DIR"/conf/exempt-*.conf; do
  [ -e "$conf" ] && grep -qx "port=$port" "$conf" || continue
  grep -qx "address=/$name/127.0.0.1" "$conf" && printf '127.0.0.1\n'
  exit 0
done
exit 9
SH
for name in logger dnsmasq-init killswitch-init conntrack ubus; do
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
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/ruleset-post/90-prokop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/conf"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"
export PROKOP_KILLSWITCH_WATCH_INTERVAL_MS=1

BLOCKED="$KILLSWITCH_STATE_DIR/dns-blocked.servers"
SERVERS="$KILLSWITCH_STATE_DIR/dnsmasq.servers"
EXEMPT="$KILLSWITCH_STATE_DIR/dns-exempt.json"
CONF_DIR="$WORK_DIR/conf"

ks() {
  ucode -L "$PROKOP_LIB" "$KS_UC" "$@"
}
json_value() {
  ucode -e 'let v = json(ARGV[0]); for (let k in split(ARGV[1], ".")) v = v == null ? null : v[k]; print(v ?? "null", "\n");' -- "$1" "$2"
}
state_value() {
  json_value "$(cat "$KILLSWITCH_STATE_DIR/state.json")" "$1"
}
# The state without the times of the last sync, which differ from run to run.
state_core() {
  ucode -e 'let s = json(require("fs").readfile(ARGV[0])); delete s.updated_at; delete s.last_error_at; print(sprintf("%.2J", s), "\n");' -- "$1"
}

# ---- a generated configuration ---------------------------------------------------
#
#   main   protected, excludes .50, does not exempt it
#   excl   protected, exempts its excluded .50, the /28 and fd00::50
#   excl2  protected, exempts its excluded .5 (inside the /28)
#   late   protected, no exclusions: shared.example stays blocked for all
#   free   an unprotected VPN section
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
      "excluded_source_ip_cidr": [ "192.168.1.50" ] },
    { ".name": "excl", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json b)" ], "domain_suffix": [ "excl-inline.example", "shared.example" ],
      "rule_set": [ "$WORK_DIR/gen/second.json" ],
      "excluded_source_ip_cidr": [ "192.168.1.50", "192.168.1.0/28", "fd00::50" ] },
    { ".name": "excl2", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json c)" ], "domain_suffix": [ "excl2-inline.example" ],
      "excluded_source_ip_cidr": [ "192.168.1.5" ] },
    { ".name": "late", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json d)" ], "domain_suffix": [ "shared.example", "late-only.example" ] },
    { ".name": "free", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": [ "$(outbound_json e)" ], "domain_suffix": [ "free.example" ],
      "excluded_source_ip_cidr": [ "192.168.1.50" ] }
  ]
}
JSON
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/gen/fixture.json" "$WORK_DIR/config.json" 192.168.1.1 0 1 '' 1.13.0 >/dev/null ||
  fail "the generator fixture could not be generated"
grep -Fq '"invert": true' "$WORK_DIR/config.json" || fail "the generator must wrap rules of sections with excluded devices"

# The UCI side of the same sections. $1/$2: the exemption of excl/excl2
# ("" for none); $3: the DNS server dnsmasq forwards to.
write_uci() {
  {
    printf 'prokop.settings=settings\n'
    printf 'prokop.settings.source_network_interfaces=%s\n' "${IFACES:-br-lan}"
    printf 'prokop.settings.config_path=%s\n' "$WORK_DIR/config.json"
    printf 'prokop.main=section\nprokop.main.action=connection\nprokop.main.kill_switch=1\n'
    printf 'prokop.main.excluded_source_ip_cidr=192.168.1.50\n'
    printf 'prokop.excl=section\nprokop.excl.action=connection\nprokop.excl.kill_switch=1\n'
    printf 'prokop.excl.excluded_source_ip_cidr=192.168.1.50 192.168.1.0/28 fd00::50\n'
    [ -z "$1" ] || printf 'prokop.excl.kill_switch_dns_exempt=%s\n' "$1"
    printf 'prokop.excl2=section\nprokop.excl2.action=connection\nprokop.excl2.kill_switch=1\n'
    printf 'prokop.excl2.excluded_source_ip_cidr=192.168.1.5\n'
    [ -z "$2" ] || printf 'prokop.excl2.kill_switch_dns_exempt=%s\n' "$2"
    printf 'prokop.late=section\nprokop.late.action=connection\nprokop.late.kill_switch=1\n'
    printf 'prokop.free=section\nprokop.free.action=connection\n'
    printf 'dhcp.@dnsmasq[0]=dnsmasq\n'
    printf 'dhcp.@dnsmasq[0].server=%s\n' "${3:-127.0.0.42}"
    printf 'dhcp.@dnsmasq[0].prokop_server=1.1.1.1\n'
    printf 'dhcp.@dnsmasq[0].noresolv=1\n'
    [ -z "$4" ] || printf 'dhcp.@dnsmasq[0].serversfile=%s\n' "$4"
  } >"$PROKOP_UCI_STATE_FILE"
}
# Prokop stops: dnsmasq answers with the block list itself.
stop_prokop() {
  write_uci "$1" "$2" 1.1.1.1 "$SERVERS"
  ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
  cmp -s "$BLOCKED" "$SERVERS" || fail "a stopped Prokop must answer with the block list"
}
start_prokop() {
  write_uci "$1" "$2" 127.0.0.42 "$SERVERS"
  ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
  [ ! -s "$SERVERS" ] || fail "a running Prokop must empty the block list dnsmasq reads"
}
fresh() {
  rm -rf "$KILLSWITCH_STATE_DIR" "$CONF_DIR" "$WORK_DIR/ks-present" "$WORK_DIR/ks_dns" "$WORK_DIR"/dead-* \
    "$WORK_DIR"/calls-* "$WORK_DIR"/fail-at-*
  mkdir -p "$CONF_DIR"
  touch "$WORK_DIR/live-present"
}
watch_passes() {
  PROKOP_KILLSWITCH_WATCH_ITERATIONS="$1" ks watch || fail "watch failed"
}

# ---- without the option: everything as before ----------------------------------

fresh
write_uci "" ""
ks sync start || fail "sync without the option failed"
[ ! -e "$EXEMPT" ] || fail "without the option no exemption may be saved"
cp "$BLOCKED" "$WORK_DIR/blocked.off"
cp "$KILLSWITCH_STATE_DIR/policy.nft" "$WORK_DIR/policy.off"
state_core "$KILLSWITCH_STATE_DIR/state.json" >"$WORK_DIR/state.off"
ks standby-config "$WORK_DIR/standby.off" || fail "standby config failed"
for name in main-inline.example excl-inline.example shared.example second-list.example excl2-inline.example late-only.example; do
  grep -Fqx "server=/$name/" "$BLOCKED" || fail "the shared block list must block $name"
done
if grep -Fq 'free.example' "$BLOCKED"; then fail "an unprotected section is not in the shared block list"; fi
[ "$(state_value dns.sections.excl.excluded_devices)" = 3 ] ||
  fail "without the option the names of excl are blocked for its excluded devices as well"
if grep -Eq 'exempt' "$KILLSWITCH_STATE_DIR/state.json"; then
  fail "without the option the state must not change: $(cat "$KILLSWITCH_STATE_DIR/state.json")"
fi
[ -z "$(ks exempt-configs "$CONF_DIR")" ] || fail "without the option no resolver of excluded devices may run"
stop_prokop "" ""
watch_passes 3
[ ! -s "$WORK_DIR/ks_dns" ] || fail "without the option a stopped Prokop redirects no DNS"
grep -Fq '"dns_exempt": false' <<<"$(ks status)" || fail "status must report no exemption"

# "0" is the same as no option.
fresh
write_uci 0 0
ks sync start || fail "sync with the option off failed"
[ ! -e "$EXEMPT" ] || fail "an option set to 0 saves no exemption"
cmp -s "$BLOCKED" "$WORK_DIR/blocked.off" || fail "an option set to 0 must not change the block list"
cmp -s <(state_core "$KILLSWITCH_STATE_DIR/state.json") "$WORK_DIR/state.off" || fail "an option set to 0 must not change the state"
cmp -s "$KILLSWITCH_STATE_DIR/policy.nft" "$WORK_DIR/policy.off" || fail "an option set to 0 must not change the firewall policy"
printf 'ok - without the option nothing changes\n'

# ---- with the option -------------------------------------------------------------

fresh
write_uci 1 1
ks sync start || fail "sync with the option failed"
cmp -s "$BLOCKED" "$WORK_DIR/blocked.off" || fail "the shared block list must stay the same for every other client"
# The firewall policy only gains the guard of the resolvers of excluded
# devices: clients reach them only through the redirect.
cmp -s <(grep -v ' ks_exempt_guard' "$KILLSWITCH_STATE_DIR/policy.nft") "$WORK_DIR/policy.off" ||
  fail "the firewall policy must not change apart from the guard of the resolvers"
grep -Fqx 'add chain inet ProkopKillswitch ks_exempt_guard { type filter hook input priority -1; policy accept; }' "$KILLSWITCH_STATE_DIR/policy.nft" ||
  fail "the guard of the resolvers must be an input chain"
grep -Fqx 'add rule inet ProkopKillswitch ks_exempt_guard iifname != "lo" meta l4proto { tcp, udp } th dport 18055-18058 ct direction original ct status & dnat == 0 drop' \
  "$KILLSWITCH_STATE_DIR/policy.nft" || fail "only redirected DNS may reach the resolvers of excluded devices"
if grep -Fq ' ks_exempt_guard' "$WORK_DIR/policy.off"; then fail "without the option there is no guard"; fi
ks standby-config "$WORK_DIR/standby.on" || fail "standby config failed"
cmp -s "$WORK_DIR/standby.on" "$WORK_DIR/standby.off" || fail "the standby resolver must not change"
[ -s "$EXEMPT" ] || fail "the groups of excluded devices must be saved for a stopped Prokop"
grep -Fqx '/etc/prokop/killswitch/dns-exempt.json' "$KEEP_LIST" || fail "sysupgrade must keep the groups with the block list"
# Only names the saved groups really resolve count: shared.example stays
# blocked for the excluded devices of excl through late.
[ "$(state_value dns.sections.excl.excluded_exempt)" = 2 ] || fail "the exempted names of excl must be reported"
[ "$(state_value dns.sections.excl.excluded_devices)" = 1 ] || fail "shared.example stays blocked for the excluded devices of excl"
[ "$(state_value dns.excluded_exempt)" = 3 ] || fail "three names are resolved by excluded devices in all"
[ "$(state_value dns.sections.excl2.excluded_exempt)" = 1 ] || fail "the exempted name of excl2 must be reported"
[ "$(state_value dns.sections.main.excluded_devices)" = 1 ] || fail "main does not exempt its excluded device"
[ "$(state_value dns.exempt_groups)" = 2 ] || fail "two groups of excluded devices: .5 and the rest of excl"

# One resolver per group: .5 is excluded from excl and excl2; .50, the /28
# and fd00::50 from excl only (main does not exempt .50).
configs="$(ks exempt-configs "$CONF_DIR")" || fail "exempt-configs failed"
[ "$(printf '%s\n' "$configs" | wc -l)" = 2 ] || fail "two resolvers expected: $configs"
both="" single=""
for conf in $configs; do
  grep -Fqx 'server=/excl2-inline.example/' "$conf" && single="$conf" || both="$conf"
done
if [ -z "$both" ] || [ -z "$single" ]; then fail "one group exempt from excl and excl2, one from excl only"; fi
for conf in "$both" "$single"; do
  # dnsmasq listens on loopback by itself whenever an interface is named.
  if grep -Fqx 'interface=lo' "$conf"; then fail "$conf must listen where the standby resolver does"; fi
  for line in "bind-dynamic" "interface=br-lan" "server=1.1.1.1" "max-ttl=30" \
    "server=/main-inline.example/" "server=/shared.example/" "server=/late-only.example/"; do
    grep -Fqx "$line" "$conf" || fail "$conf must contain '$line'"
  done
  for name in excl-inline.example second-list.example free.example; do
    if grep -Fq "/$name/" "$conf"; then fail "$conf must resolve $name"; fi
  done
  grep -Eq '^address=/g[0-9]+-[0-9a-f]{32}\.exempt\.prokop\.invalid/127\.0\.0\.1$' "$conf" || fail "$conf must answer its probe name"
done
if grep -Fq '/excl2-inline.example/' "$both"; then fail ".5 is excluded from excl2 as well"; fi
port_both="$(sed -n 's/^port=//p' "$both")"
port_single="$(sed -n 's/^port=//p' "$single")"
if [ "$port_both" = "$port_single" ] || [ "$port_both" -lt 18055 ] || [ "$port_single" -lt 18055 ]; then
  fail "each group needs a port of its own: $port_both $port_single"
fi
printf 'ok - excluded devices are grouped by the rules that do not apply to them\n'

# Interfaces dnsmasq cannot be given by name (a wildcard): the resolvers
# listen everywhere, like the standby resolver, so that the redirect to the
# router's LAN address reaches them.
IFACES='br-*' write_uci 1 1
ks sync reload || fail "sync with a wildcard interface failed"
wild="$(ks exempt-configs "$CONF_DIR")" || fail "exempt-configs failed"
[ "$(printf '%s\n' "$wild" | wc -l)" = 2 ] || fail "two resolvers expected with a wildcard interface: $wild"
ks standby-config "$WORK_DIR/standby.wild" || fail "standby config failed"
for conf in $wild "$WORK_DIR/standby.wild"; do
  if grep -q '^interface=' "$conf"; then fail "$conf must listen on every interface: $(grep '^interface=' "$conf")"; fi
done
write_uci 1 1
ks sync reload || fail "sync failed"
ks exempt-configs "$CONF_DIR" >/dev/null || fail "exempt-configs failed"
grep -Fqx 'interface=br-lan' "$both" || fail "a named interface is named again"
printf 'ok - the resolvers of excluded devices listen where the standby resolver does\n'

# ---- the watcher -----------------------------------------------------------------

# Running Prokop: client DNS goes through sing-box; nothing is redirected.
touch "$WORK_DIR/sing-box-alive"
start_prokop 1 1
watch_passes 3
[ ! -s "$WORK_DIR/ks_dns" ] || fail "a running Prokop must not redirect the excluded devices"

# Stopped: exactly the excluded addresses go to their resolvers, the
# narrowest source first; DNS for the router only.
stop_prokop 1 1
watch_passes 2
rules="$(cat "$WORK_DIR/ks_dns")"
expect_rule() {
  grep -Fq "iifname @ks_interfaces $1 saddr $2 fib daddr type local udp dport 53 counter redirect to :$3 comment \"prokop-exempt-" <<<"$rules" ||
    fail "expected the UDP redirect of $2 to :$3"
  grep -Fq "iifname @ks_interfaces $1 saddr $2 fib daddr type local tcp dport 53 counter redirect to :$3 comment \"prokop-exempt-" <<<"$rules" ||
    fail "expected the TCP redirect of $2 to :$3"
}
expect_rule ip 192.168.1.5/32 "$port_both"
expect_rule ip 192.168.1.50/32 "$port_single"
expect_rule ip 192.168.1.0/28 "$port_single"
expect_rule ip6 fd00:0:0:0:0:0:0:50/128 "$port_single"
[ "$(wc -l <"$WORK_DIR/ks_dns")" = 8 ] || fail "only the excluded addresses may be redirected: $rules"
if grep -Fq ':18054' <<<"$rules"; then fail "a stopped Prokop needs no standby redirect"; fi
line_of() { grep -nF "saddr $1 " "$WORK_DIR/ks_dns" | head -n1 | cut -d: -f1; }
if [ "$(line_of 192.168.1.5/32)" -gt "$(line_of 192.168.1.0/28)" ] || [ "$(line_of 192.168.1.50/32)" -gt "$(line_of 192.168.1.0/28)" ]; then
  fail "an address inside the /28 must match its own group first: $rules"
fi
grep -Fq '"dns_exempt": true' <<<"$(ks status)" || fail "status must report the exemption in use"
grep -Fq 'resolve their names through their own resolvers' "$WORK_DIR/logger.log" || fail "the exemption must be logged"

# A firewall reload empties the chain: the watcher restores the redirect.
: >"$WORK_DIR/ks_dns"
watch_passes 1
cmp -s <(printf '%s\n' "$rules") "$WORK_DIR/ks_dns" || fail "the watcher must restore the redirect of excluded devices"

# A resolver that does not answer, or answers for another configuration,
# gets no client: its devices keep the shared block list.
touch "$WORK_DIR/dead-$port_both"
watch_passes 1
if grep -Fq 'saddr 192.168.1.5/32' "$WORK_DIR/ks_dns"; then fail "a dead resolver must get no client"; fi
grep -Fq 'saddr 192.168.1.0/28' "$WORK_DIR/ks_dns" || fail "the other group keeps its resolver"
rm -f "$WORK_DIR/dead-$port_both"
sed -i 's/^address=\/g\([0-9]*\)-[0-9a-f]*\./address=\/g\1-00000000000000000000000000000000./' "$single"
watch_passes 1
if grep -Fq "redirect to :$port_single" "$WORK_DIR/ks_dns"; then fail "a resolver with another configuration must get no client"; fi
grep -Fq 'saddr 192.168.1.5/32' "$WORK_DIR/ks_dns" || fail "the answering resolver keeps its clients"
ks exempt-configs "$CONF_DIR" >/dev/null || fail "exempt-configs failed"
watch_passes 1
cmp -s <(printf '%s\n' "$rules") "$WORK_DIR/ks_dns" || fail "a resolver with its configuration again gets its clients back"

# A resolver that answers is probed again only every fifth pass.
: >"$WORK_DIR/dig.log"
watch_passes 10
probes="$(grep -c -- "-p $port_both " "$WORK_DIR/dig.log" || true)"
[ "$probes" = 2 ] || fail "a resolver that answers is probed every fifth pass, not $probes times in 10"
cmp -s <(printf '%s\n' "$rules") "$WORK_DIR/ks_dns" || fail "the redirect stays while the resolvers answer"

# One failed probe in a row does not move its clients (it would flush the
# chain and the DNS conntrack entries of every client twice); two do.
rm -f "$WORK_DIR"/calls-*
: >"$WORK_DIR/nft.log"
printf '2\n' >"$WORK_DIR/fail-at-$port_both"
PROKOP_KILLSWITCH_EXEMPT_PROBE_PASSES=1 PROKOP_KILLSWITCH_WATCH_ITERATIONS=3 ks watch || fail "watch failed"
[ "$(cat "$WORK_DIR/calls-$port_both")" = 3 ] || fail "every pass must probe with PROKOP_KILLSWITCH_EXEMPT_PROBE_PASSES=1"
if grep -q '^-f ' "$WORK_DIR/nft.log"; then fail "a single failed probe must not change the DNS chain"; fi
cmp -s <(printf '%s\n' "$rules") "$WORK_DIR/ks_dns" || fail "a single failed probe keeps the redirect"
rm -f "$WORK_DIR"/calls-*
printf '2\n3\n' >"$WORK_DIR/fail-at-$port_both"
PROKOP_KILLSWITCH_EXEMPT_PROBE_PASSES=1 PROKOP_KILLSWITCH_WATCH_ITERATIONS=3 ks watch || fail "watch failed"
if grep -Fq 'saddr 192.168.1.5/32' "$WORK_DIR/ks_dns"; then fail "two failed probes in a row hand the devices back to the shared list"; fi
grep -Fq 'saddr 192.168.1.0/28' "$WORK_DIR/ks_dns" || fail "the other group keeps its resolver"
rm -f "$WORK_DIR"/calls-* "$WORK_DIR"/fail-at-*
watch_passes 1
cmp -s <(printf '%s\n' "$rules") "$WORK_DIR/ks_dns" || fail "an answering resolver gets its clients back"

# Prokop starts again: the excluded devices use sing-box like everybody else.
start_prokop 1 1
watch_passes 1
[ ! -s "$WORK_DIR/ks_dns" ] || fail "a running Prokop must take the redirect of excluded devices away"

# sing-box dies while Prokop runs: the standby resolver for everybody.
rm -f "$WORK_DIR/sing-box-alive"
watch_passes 3
grep -Fq 'redirect to :18054' "$WORK_DIR/ks_dns" || fail "a dead sing-box must switch every client to the standby"
if grep -Fq 'prokop-exempt' "$WORK_DIR/ks_dns"; then fail "the standby redirect replaces the exemption"; fi
touch "$WORK_DIR/sing-box-alive"
watch_passes 2
[ ! -s "$WORK_DIR/ks_dns" ] || fail "a recovered sing-box takes every client back"
printf 'ok - the watcher redirects exactly the excluded devices while Prokop is stopped\n'

# ---- what the groups were saved for --------------------------------------------

# The init script runs one dnsmasq per group, beside the standby.
cat >"$WORK_DIR/init-start.sh" <<SH
. "$INIT_SCRIPT"
PROKOP_LIB="$PROKOP_LIB"
KILLSWITCH_UC="$KS_UC"
STANDBY_DIR="$CONF_DIR"
STANDBY_CONF="$CONF_DIR/standby.conf"
procd_open_instance() { printf 'instance %s\n' "\$1"; }
procd_set_param() { printf 'param %s\n' "\$*"; }
procd_close_instance() { :; }
start_service
SH
sh "$WORK_DIR/init-start.sh" >"$WORK_DIR/instances.log" || fail "start_service failed"
for instance in standby exempt-0 exempt-1 watch; do
  grep -Fqx "instance $instance" "$WORK_DIR/instances.log" || fail "the service must run the instance $instance: $(cat "$WORK_DIR/instances.log")"
done
grep -Fqx "param command /usr/sbin/dnsmasq --keep-in-foreground --conf-file=$CONF_DIR/exempt-0.conf --pid-file=" "$WORK_DIR/instances.log" ||
  fail "a resolver of excluded devices is a dnsmasq with its generated configuration"
grep -Fqx "param file $CONF_DIR/exempt-1.conf" "$WORK_DIR/instances.log" || fail "a changed configuration must restart its resolver"

# A block list that changed since (a release without the exemption) or a
# changed exemption leaves every excluded device with the shared list.
cp "$BLOCKED" "$WORK_DIR/blocked.saved"
printf 'server=/added-by-another-release.example/\n' >>"$BLOCKED"
[ -z "$(ks exempt-configs "$CONF_DIR")" ] || fail "groups saved for another block list must not get a resolver"
ls "$CONF_DIR"/exempt-*.conf >/dev/null 2>&1 && fail "their configurations must be removed"
cp "$WORK_DIR/blocked.saved" "$BLOCKED"
stop_prokop 1 ""
[ -z "$(ks exempt-configs "$CONF_DIR")" ] || fail "groups saved for another exemption must not get a resolver"
stop_prokop 1 1
[ -n "$(ks exempt-configs "$CONF_DIR")" ] || fail "the saved groups are used again with the configuration they were saved for"
printf 'ok - groups are used only with the block list and configuration they were saved for\n'

# Groups belong to the sync that saved them. A later sync that did not (a
# release without the exemption after a downgrade rewrites the state and
# leaves a file it does not know; its block list can come out the same)
# leaves them unused: no resolver runs them and the watcher redirects no
# device to one still running them.
fresh
write_uci 1 1
ks sync start || fail "sync failed"
cp "$EXEMPT" "$WORK_DIR/exempt.saved"
stop_prokop 1 1
ks exempt-configs "$CONF_DIR" >"$WORK_DIR/confs.saved" || fail "exempt-configs failed"
watch_passes 1
grep -Fq 'prokop-exempt' "$WORK_DIR/ks_dns" || fail "the exemption is in use before the other sync"
start_prokop "" ""
ks sync reload || fail "sync without the option failed"
cp "$WORK_DIR/exempt.saved" "$EXEMPT"
cmp -s "$BLOCKED" "$WORK_DIR/blocked.off" || fail "the other sync saved the same shared block list"
stop_prokop 1 1
watch_passes 1
if grep -Fq 'prokop-exempt' "$WORK_DIR/ks_dns"; then fail "groups of another sync must not be redirected to"; fi
[ -z "$(ks exempt-configs "$CONF_DIR")" ] || fail "groups of another sync must not get a resolver"
ks follow-stopped-config "reload while Prokop is stopped" || fail "follow-stopped-config failed"
[ ! -e "$EXEMPT" ] || fail "a reload while Prokop is stopped removes groups of another sync"
printf 'ok - groups are used only after the sync that saved them\n'
fresh
write_uci 1 1
ks sync start || fail "sync failed"
stop_prokop 1 1
ks exempt-configs "$CONF_DIR" >/dev/null || fail "exempt-configs failed"

# A reload while Prokop is stopped (D-15) does not render anything; a
# changed exemption ends at once, to the blocking side.
watch_passes 1
grep -Fq 'prokop-exempt' "$WORK_DIR/ks_dns" || fail "the exemption is in use before the change"
stop_prokop 1 ""
ks follow-stopped-config "reload while Prokop is stopped" || fail "follow-stopped-config failed"
[ ! -e "$EXEMPT" ] || fail "an exemption changed while Prokop is stopped must end"
if grep -Fq 'prokop-exempt' "$WORK_DIR/ks_dns"; then fail "its redirect must end at once"; fi
cmp -s "$BLOCKED" "$SERVERS" || fail "the shared block list stays"
[ -s "$KILLSWITCH_STATE_DIR/policy.nft" ] || fail "the protection stays"
watch_passes 1
[ ! -s "$WORK_DIR/ks_dns" ] || fail "nothing may bring the redirect back until the next start"
printf 'ok - a changed exemption ends while Prokop is stopped\n'

# A configuration that cannot be read keeps the protection, but not the
# exemption: who is exempt cannot be known.
fresh
write_uci 1 1
ks sync start || fail "sync failed"
stop_prokop 1 1
ks exempt-configs "$CONF_DIR" >/dev/null || fail "exempt-configs failed"
watch_passes 1
grep -Fq 'prokop-exempt' "$WORK_DIR/ks_dns" || fail "the exemption is in use before the configuration breaks"
sed -i '/^prokop\./d' "$PROKOP_UCI_STATE_FILE"
if ks follow-stopped-config "reload while Prokop is stopped"; then fail "an unreadable configuration is an error"; fi
[ ! -e "$EXEMPT" ] || fail "an unreadable configuration ends the exemption"
if grep -Fq 'prokop-exempt' "$WORK_DIR/ks_dns"; then fail "an unreadable configuration ends the redirect at once"; fi
[ -s "$KILLSWITCH_STATE_DIR/policy.nft" ] || fail "an unreadable configuration keeps the protection"
cmp -s "$BLOCKED" "$SERVERS" || fail "an unreadable configuration keeps the shared block list"
grep -Fq 'could not be read' "$KILLSWITCH_STATE_DIR/state.json" || fail "the unreadable configuration must be reported"
printf 'ok - an unreadable configuration ends the exemption\n'

# An unchanged one stays.
fresh
write_uci 1 1
ks sync start || fail "sync failed"
cp "$EXEMPT" "$WORK_DIR/exempt.saved"
stop_prokop 1 1
ks follow-stopped-config "reload while Prokop is stopped" || fail "follow-stopped-config failed"
cmp -s "$EXEMPT" "$WORK_DIR/exempt.saved" || fail "an unchanged exemption must stay"

# ---- removal -----------------------------------------------------------------------

ks exempt-configs "$CONF_DIR" >/dev/null
watch_passes 1
grep -Fq 'prokop-exempt' "$WORK_DIR/ks_dns" || fail "the exemption is in use before the removal"
ks disable "test" || fail "disable failed"
[ ! -e "$EXEMPT" ] || fail "removing the kill-switch removes the groups"
ls "$CONF_DIR"/exempt-*.conf >/dev/null 2>&1 && fail "removing the kill-switch removes the resolver configurations"
[ ! -e "$WORK_DIR/ks-present" ] || fail "removing the kill-switch removes its table with the redirect"

# Not managing dnsmasq: no block list, no exemption.
fresh
write_uci 1 1
ks sync start || fail "sync failed"
[ -s "$EXEMPT" ] || fail "the exemption is saved"
printf 'prokop.settings.dont_touch_dhcp=1\n' >>"$PROKOP_UCI_STATE_FILE"
ks sync reload || fail "sync with dont_touch_dhcp failed"
[ ! -e "$EXEMPT" ] || fail "without a block list there is nothing to exempt from"

# The option removed: the next refresh removes the groups.
fresh
write_uci 1 1
ks sync start || fail "sync failed"
write_uci "" ""
ks sync reload || fail "sync failed"
[ ! -e "$EXEMPT" ] || fail "a refresh without the option removes the groups"
cmp -s "$BLOCKED" "$WORK_DIR/blocked.off" || fail "the block list is the one without the option"
printf 'ok - the groups go with the kill-switch, the managed DNS and the option\n'

# ---- names a group resolves -----------------------------------------------------
#
#   exa   protected, exempts its excluded .50: example.com, exa-only.example
#   free  unprotected: sub.example.com
#   prot  protected: example.com
#
# For .50 example.com stays blocked through prot, which comes after free:
# its list gets the exception for sub.example.com that only it has. Only
# exa-only.example counts as resolved by the excluded devices of exa.
cat >"$WORK_DIR/added.json" <<'JSON'
{ "route": { "rules": [
  { "action": "route", "outbound": "exa-out", "type": "logical", "mode": "and", "rules": [
    { "domain_suffix": [ "example.com", "exa-only.example" ] }, { "source_ip_cidr": [ "192.168.1.50" ], "invert": true } ] },
  { "action": "route", "outbound": "free-out", "domain_suffix": [ "sub.example.com" ] },
  { "action": "route", "outbound": "prot-out", "domain_suffix": [ "example.com" ] }
], "rule_set": [] } }
JSON
fresh
{
  printf 'prokop.settings=settings\nprokop.settings.source_network_interfaces=br-lan\n'
  printf 'prokop.settings.config_path=%s\n' "$WORK_DIR/added.json"
  printf 'prokop.exa=section\nprokop.exa.action=connection\nprokop.exa.kill_switch=1\nprokop.exa.kill_switch_dns_exempt=1\n'
  printf 'prokop.exa.excluded_source_ip_cidr=192.168.1.50\n'
  printf 'prokop.free=section\nprokop.free.action=connection\n'
  printf 'prokop.prot=section\nprokop.prot.action=connection\nprokop.prot.kill_switch=1\n'
  printf 'dhcp.@dnsmasq[0]=dnsmasq\ndhcp.@dnsmasq[0].server=127.0.0.42\n'
} >"$PROKOP_UCI_STATE_FILE"
ks sync start || fail "sync failed"
grep -Fqx 'server=/example.com/' "$BLOCKED" || fail "example.com is blocked for every client"
if grep -Fq 'sub.example.com' "$BLOCKED"; then fail "every other client gets no exception for sub.example.com"; fi
conf="$(ks exempt-configs "$CONF_DIR")" || fail "exempt-configs failed"
[ "$(printf '%s\n' "$conf" | wc -l)" = 1 ] || fail "one group expected: $conf"
grep -Fqx 'server=/sub.example.com/#' "$conf" || fail "the group's list must resolve sub.example.com"
grep -Fqx 'server=/example.com/' "$conf" || fail "example.com stays blocked for .50 through prot"
if grep -Fq 'exa-only.example' "$conf"; then fail "the group's list must resolve exa-only.example"; fi
[ "$(state_value dns.sections.exa.excluded_exempt)" = 1 ] || fail "only exa-only.example is resolved by the excluded devices of exa"
[ "$(state_value dns.sections.exa.excluded_devices)" = 1 ] || fail "example.com stays blocked for the excluded devices of exa"
printf 'ok - a group gets the exceptions only it has, and only what it resolves is reported\n'

# ---- limits ------------------------------------------------------------------------

# Five exempting sections, five groups: four get a resolver, the rest stays
# blocked and is reported.
{
  printf '{ "route": { "rules": [\n'
  for i in 1 2 3 4 5; do
    [ "$i" = 1 ] || printf ',\n'
    printf '{ "action": "route", "outbound": "s%s-out", "type": "logical", "mode": "and", "rules": [ { "domain_suffix": [ "s%s.example" ] }, { "source_ip_cidr": [ "10.0.0.%s" ], "invert": true } ] }' "$i" "$i" "$i"
  done
  printf ',\n{ "action": "route", "outbound": "s6-out", "type": "logical", "mode": "and", "rules": [ { "domain_suffix": [ "s6.example" ] }, { "source_ip_cidr": [ "bogus", "10.0.0.66/33", "10.0.0.6" ], "invert": true } ] }'
  printf ',\n{ "action": "route", "outbound": "s7-out", "type": "logical", "mode": "and", "rules": [ { "domain_suffix": [ "s7.example" ] }, { "source_ip_cidr": [ "10.0.0.7" ], "source_port": [ 53 ], "invert": true } ] }'
  printf '\n], "rule_set": [] } }\n'
} >"$WORK_DIR/many.json"
fresh
{
  printf 'prokop.settings=settings\nprokop.settings.source_network_interfaces=br-lan\n'
  printf 'prokop.settings.config_path=%s\n' "$WORK_DIR/many.json"
  for i in 1 2 3 4 5 6 7; do
    printf 'prokop.s%s=section\nprokop.s%s.action=connection\nprokop.s%s.kill_switch=1\nprokop.s%s.kill_switch_dns_exempt=1\n' "$i" "$i" "$i" "$i"
  done
  printf 'dhcp.@dnsmasq[0]=dnsmasq\ndhcp.@dnsmasq[0].server=127.0.0.42\n'
} >"$PROKOP_UCI_STATE_FILE"
ks sync start || fail "sync with many groups failed"
[ "$(state_value dns.exempt_groups)" = 4 ] || fail "at most four groups get a resolver"
grep -Fq 'more than 4 groups with different blocked names, only 4 get their own resolver; 2 device addresses stay blocked' "$KILLSWITCH_STATE_DIR/state.json" ||
  fail "the groups beyond the limit must be reported"
grep -Fq '2 excluded device addresses of sections that exempt their excluded devices cannot be read' "$KILLSWITCH_STATE_DIR/state.json" ||
  fail "unreadable excluded addresses must be reported"
[ "$(state_value dns.sections.s7.excluded_devices)" = 1 ] ||
  fail "a rule that excludes devices in another form keeps its names blocked for them"
[ "$(ks exempt-configs "$CONF_DIR" | wc -l)" = 4 ] || fail "four resolvers expected"
if grep -Fq '10.0.0.7' "$EXEMPT"; then fail "a source excluded together with a port is not exempt"; fi
printf 'ok - limits: four groups, unreadable addresses and other forms stay blocked\n'

# ---- validator ---------------------------------------------------------------------

validate() {
  cat >"$WORK_DIR/validate.json" <<JSON
{ "settings": { ".name": "settings", ".type": "settings", "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ], "yacd_secret_key": "test-clash-secret" },
  "section": [ { ".name": "vpn", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_json": "{\"type\":\"direct\"}", "domain_suffix": [ "example.com" ], "kill_switch": "1",
    "excluded_source_ip_cidr": [ "192.168.1.50" ], "kill_switch_dns_exempt": "$1" } ] }
JSON
  ucode -L "$PROKOP_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/validate.json" '{}' 2>&1
}
for value in 1 0; do
  output="$(validate "$value")" || fail "kill_switch_dns_exempt=$value must be valid: $output"
done
if output="$(validate maybe)"; then fail "kill_switch_dns_exempt=maybe must be rejected"; fi
grep -Fq "kill_switch_dns_exempt" <<<"$output" || fail "the validator must name the option: $output"
printf 'ok - the validator checks the option\n'

printf 'killswitch_dns_exempt: PASS\n'
