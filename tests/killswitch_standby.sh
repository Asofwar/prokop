#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
INIT_SCRIPT="$ROOT_DIR/prokop/files/etc/init.d/prokop-killswitch"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'nft log:\n' >&2
  cat "$WORK_DIR/nft.log" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/ks"
# The DNS chain's content lives in a file so the watcher can observe its own changes.
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK_DIR/nft.log"
if [ "$1 $2" = "list chain" ]; then
  [ -e "$WORK_DIR/ks-present" ] || exit 1
  printf 'table inet ProkopKillswitch {\n\tchain ks_dns {\n'
  cat "$WORK_DIR/ks_dns" 2>/dev/null
  printf '\t}\n}\n'
  exit 0
fi
if [ "$1" = "-f" ]; then
  : > "$WORK_DIR/ks_dns"
  grep -q 'redirect to :18054' "$2" && grep 'add rule' "$2" > "$WORK_DIR/ks_dns"
  exit 0
fi
exit 0
NFT
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK_DIR/dig.log"
[ -e "$WORK_DIR/sing-box-alive" ]
SH
cat >"$WORK_DIR/bin/conntrack" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK_DIR/conntrack.log"
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK_DIR/logger.log"
SH
chmod 0755 "$WORK_DIR/bin/"*

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export UCI_STATE="$WORK_DIR/uci.state"
export PROKOP_UCI_STATE_FILE="$UCI_STATE"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/90-prokop-killswitch.nft"
export PROKOP_KILLSWITCH_WATCH_INTERVAL_MS=1

ks() {
  ucode -L "$PROKOP_LIB" "$KS_UC" "$@"
}

cat >"$UCI_STATE" <<'EOF'
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan awg_server
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].prokop_server=1.1.1.1 9.9.9.9#53
dhcp.@dnsmasq[0].noresolv=1
dhcp.@dnsmasq[0].domain=home
EOF
printf 'server=/claude.ai/\nserver=/drive.example.com/#\n' > "$KILLSWITCH_STATE_DIR/dns-blocked.servers"

# armed follows the saved policy, never the first build's unguarded include.
printf '# policy\n' > "$KILLSWITCH_NFT_INCLUDE"
if ks armed; then fail "kill-switch must not be armed without its saved policy"; fi
rm -f "$KILLSWITCH_NFT_INCLUDE"
: > "$KILLSWITCH_STATE_DIR/policy.nft"
if ks armed; then fail "an empty saved policy protects nothing"; fi
printf '# policy\n' > "$KILLSWITCH_STATE_DIR/policy.nft"
ks armed || fail "kill-switch must be armed with its saved policy"

# Standby configuration: original upstream, local names via the main dnsmasq, the block list.
ks standby-config "$WORK_DIR/standby.conf" || fail "standby config failed"
conf="$WORK_DIR/standby.conf"
for line in "port=18054" "bind-dynamic" "max-ttl=30" "max-cache-ttl=30" "interface=br-lan" "interface=awg_server" "server=1.1.1.1" "server=9.9.9.9#53" \
  "server=/home/127.0.0.1" "server=/claude.ai/" "server=/drive.example.com/#"; do
  grep -Fqx "$line" "$conf" || fail "standby config must contain '$line'"
done
grep -Fqx "resolv-file=/tmp/resolv.conf.d/resolv.conf.auto" "$conf" ||
  fail "without a noresolv backup the original resolv file must be used"
if grep -Fq "127.0.0.42" "$conf"; then fail "standby must never forward to sing-box"; fi
printf 'dhcp.@dnsmasq[0].prokop_noresolv=1\n' >> "$UCI_STATE"
ks standby-config "$conf"
grep -Fqx "no-resolv" "$conf" || fail "an original noresolv must be kept"

# Watcher: sing-box answers, nothing changes.
touch "$WORK_DIR/ks-present" "$WORK_DIR/sing-box-alive"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=3 ks watch || fail "watch failed"
[ ! -s "$WORK_DIR/ks_dns" ] || fail "no redirect while sing-box answers"

# sing-box dies: two failed probes are not enough, the third switches.
rm -f "$WORK_DIR/sing-box-alive"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=2 ks watch
[ ! -s "$WORK_DIR/ks_dns" ] || fail "a short probe failure must not switch DNS"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=3 ks watch
grep -Fq 'iifname @ks_interfaces udp dport 53 counter redirect to :18054' "$WORK_DIR/ks_dns" ||
  fail "dead sing-box must redirect client UDP DNS to the standby"
grep -Fq 'tcp dport 53 counter redirect to :18054' "$WORK_DIR/ks_dns" || fail "TCP DNS must be redirected too"
grep -Fq -- '-D -p udp --dport 53' "$WORK_DIR/conntrack.log" || fail "stale DNS NAT bindings must be flushed"

# A respawned watcher keeps the redirect while sing-box is still dead.
PROKOP_KILLSWITCH_WATCH_ITERATIONS=1 ks watch
grep -Fq 'redirect to :18054' "$WORK_DIR/ks_dns" || fail "a restarted watcher must keep the redirect while sing-box is dead"

# A firewall reload empties the chain; the watcher restores the redirect.
: > "$WORK_DIR/ks_dns"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=3 ks watch
grep -Fq 'redirect to :18054' "$WORK_DIR/ks_dns" || fail "the watcher must restore a redirect lost to a firewall reload"

# sing-box is back: one good probe is not enough, the second hands DNS back.
touch "$WORK_DIR/sing-box-alive"
printf 'add rule inet ProkopKillswitch ks_dns redirect to :18054\n' > "$WORK_DIR/ks_dns"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=1 ks watch
PROKOP_KILLSWITCH_WATCH_ITERATIONS=2 ks watch
[ ! -s "$WORK_DIR/ks_dns" ] || fail "a recovered sing-box must get client DNS back"

# A planned sing-box restart under Prokop's reload lock (a live owner,
# core/runtime_lock) is not an outage.
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/reload.lock"
mkdir "$PROKOP_RELOAD_LOCK_DIR"
ticks="$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$$/stat")"
printf '%s\n%s\n' "$$" "$ticks" >"$PROKOP_RELOAD_LOCK_DIR/owner.$$.$ticks"
rm -f "$WORK_DIR/sing-box-alive"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=5 ks watch
[ ! -s "$WORK_DIR/ks_dns" ] || fail "no failover while Prokop itself restarts sing-box"
rm -rf "$PROKOP_RELOAD_LOCK_DIR"

# Prokop stopped (dnsmasq answers with its own block list): never redirect.
sed -i 's/^dhcp.@dnsmasq\[0\].server=.*/dhcp.@dnsmasq[0].server=1.1.1.1/' "$UCI_STATE"
rm -f "$WORK_DIR/sing-box-alive"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=4 ks watch
[ ! -s "$WORK_DIR/ks_dns" ] || fail "no redirect while dnsmasq does not forward to sing-box"

# No block list (dont_touch_dhcp): a standby could not enforce anything.
sed -i 's/^dhcp.@dnsmasq\[0\].server=.*/dhcp.@dnsmasq[0].server=127.0.0.42/' "$UCI_STATE"
mv "$KILLSWITCH_STATE_DIR/dns-blocked.servers" "$WORK_DIR/blocked.saved"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=4 ks watch
[ ! -s "$WORK_DIR/ks_dns" ] || fail "no redirect without a block list"
mv "$WORK_DIR/blocked.saved" "$KILLSWITCH_STATE_DIR/dns-blocked.servers"

# Manual switch, as used by the service's stop.
ks dns-redirect on || fail "dns-redirect on failed"
grep -Fq 'redirect to :18054' "$WORK_DIR/ks_dns" || fail "dns-redirect on"
ks dns-redirect off || fail "dns-redirect off failed"
[ ! -s "$WORK_DIR/ks_dns" ] || fail "dns-redirect off"
rm -f "$WORK_DIR/ks-present"
ks dns-redirect off || fail "dns-redirect without a table must be a no-op"

# The init script runs the standby and the watcher only while armed.
sh -n "$INIT_SCRIPT" || fail "init script syntax"
grep -Fq 'killswitch armed' "$INIT_SCRIPT" || fail "service must start only while armed"
grep -Fq -- '--conf-file="$STANDBY_CONF"' "$INIT_SCRIPT" || fail "standby dnsmasq must use the generated config"
# sysupgrade keeps the saved policy and block list, which only Prokop loads
# (tests/killswitch_owner_nft_real.sh), never what fw4 or dnsmasq read alone.
keep_list="$ROOT_DIR/prokop/files/lib/upgrade/keep.d/prokop-killswitch"
grep -Fqx '/etc/prokop/killswitch/policy.nft' "$keep_list" || fail "sysupgrade must keep the saved policy"
grep -Fqx '/etc/prokop/killswitch/dns-blocked.servers' "$keep_list" || fail "sysupgrade must keep the saved block list"
if grep -Eq 'nftables\.d|dnsmasq\.servers|^/etc/prokop/killswitch/?$' "$keep_list"; then
  fail "sysupgrade must not keep a file that fw4 or dnsmasq read without Prokop"
fi
grep -Fq 'killswitch-refresh' "$INIT_SCRIPT" || fail "the boot must attach the kept block list again"
grep -Fq 'procd_set_param file "$STANDBY_CONF"' "$INIT_SCRIPT" || fail "a changed standby config must restart the standby"
grep -Fq 'killswitch dns-redirect off' "$INIT_SCRIPT" || fail "stopping the service must hand DNS back"

printf 'killswitch_standby: PASS\n'
