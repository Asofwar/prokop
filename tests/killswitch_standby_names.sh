#!/usr/bin/env bash
# The standby resolver must not open unprotected VPN sections (UC-211).
#
# Without the kill-switch, a dead sing-box takes all client DNS down: dnsmasq
# still forwards to it, so the names of every VPN (connection) section fail
# and their traffic never leaves. With the kill-switch on one section, the
# watcher sends client DNS to a standby dnsmasq instead, which resolved every
# name it did not block through the ordinary upstream: the names of the other
# VPN sections got real addresses and their traffic left directly. The
# standby now answers the names of every VPN section locally; only the names
# of other sections (bypass, DPI, unmatched) use the ordinary upstream. The
# block list dnsmasq uses while Prokop is stopped keeps only the protected
# sections, as configured.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'standby config:\n' >&2
  cat "$WORK_DIR/standby.conf" >&2 2>/dev/null || true
  printf 'state.json:\n' >&2
  cat "$KILLSWITCH_STATE_DIR/state.json" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
case "$1 $2" in
  "list table")
    [ "$4" = "ProkopTable" ] && exit 0
    [ "$4" = "ProkopKillswitch" ] && { [ -e "$WORK_DIR/ks-present" ]; exit $?; }
    exit 1 ;;
  "list set") printf 'table inet ProkopTable {\n\tset %s {\n\t\ttype ipv4_addr\n\t}\n}\n' "$5"; exit 0 ;;
  "-c -f") exit 0 ;;
  "-f "*) touch "$WORK_DIR/ks-present"; exit 0 ;;
  "delete table") rm -f "$WORK_DIR/ks-present"; exit 0 ;;
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

printf '{"version":3,"rules":[{"domain_suffix":["other-list.example"]}]}\n' >"$WORK_DIR/other.json"
write_sing_box_config() {
  cat >"$WORK_DIR/sing-box.json" <<JSON
{ "outbounds": [ { "type": "direct", "tag": "main-out" }, { "type": "direct", "tag": "other-out" } ],
  "route": { "rules": [
    { "action": "route", "outbound": "bypass-out", "domain_suffix": [ "direct.example", "lan.other-vpn.example" ] },
    { "action": "route", "outbound": "main-out", "domain_suffix": [ "vpn.example" ] },
    { "action": "route", "outbound": "Zapret-out", "domain_suffix": [ "dpi.example" ] },
    { "action": "route", "outbound": "other-out", "domain_suffix": [ "other-vpn.example" ] },
    { "action": "route", "outbound": "other-out", "source_ip_cidr": [ "192.168.1.50/32" ], "domain_suffix": [ "device.other.example" ] },
    { "action": "route", "outbound": "other-out", "rule_set": [ "other-list" ] }
  ], "rule_set": [ { "tag": "other-list", "type": "local", "format": "source", "path": "$1" } ] } }
JSON
}
write_sing_box_config "$WORK_DIR/other.json"
cat >"$PROKOP_UCI_STATE_FILE" <<EOF
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan
prokop.settings.config_path=$WORK_DIR/sing-box.json
prokop.byp=section
prokop.byp.action=bypass
prokop.main=section
prokop.main.action=connection
prokop.main.kill_switch=1
prokop.zap=section
prokop.zap.action=zapret
prokop.other=section
prokop.other.action=connection
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].prokop_server=1.1.1.1
EOF
ks() { ucode -L "$PROKOP_LIB" "$KS_UC" "$@"; }

BLOCKED="$KILLSWITCH_STATE_DIR/dns-blocked.servers"

ks sync start || fail "the sync failed"
ks standby-config "$WORK_DIR/standby.conf" || fail "the standby configuration could not be written"
for name in vpn.example other-vpn.example other-list.example; do
  grep -Fqx "server=/$name/" "$WORK_DIR/standby.conf" ||
    fail "the standby resolver must answer $name of a VPN section locally while sing-box is dead"
done
grep -Fqx 'server=/lan.other-vpn.example/#' "$WORK_DIR/standby.conf" ||
  fail "an earlier bypass below a VPN section's name keeps the ordinary upstream"
for name in direct.example dpi.example; do
  if grep -Fq "$name" "$WORK_DIR/standby.conf"; then
    fail "the standby resolver must resolve $name of a non-VPN section through the ordinary upstream"
  fi
done
grep -Fqx 'server=1.1.1.1' "$WORK_DIR/standby.conf" || fail "the standby resolver must keep the ordinary upstream"
# dnsmasq answers every client alike: a device-limited rule is not blocked
# for all clients, and the warning says so.
if grep -Fq 'device.other.example' "$WORK_DIR/standby.conf"; then
  fail "the standby resolver must not block a device-limited rule for every client"
fi
grep -Fq '1 domains of device-limited rules of other VPN sections' "$KILLSWITCH_STATE_DIR/state.json" ||
  fail "the device-limited names the standby resolver does not block must be reported"
printf 'ok - the standby resolver blocks the names of every VPN section\n'

# The standby list can hold every name of large lists and changes with them;
# every refresh regenerates it, so it stays in RAM, never on flash (the
# state directory). Until the first refresh after a boot the standby blocks
# the protected names.
if grep -rlF 'other-vpn.example' "$KILLSWITCH_STATE_DIR"; then
  fail "the standby list must not be written to flash"
fi
mv "$KILLSWITCH_CACHE_DIR" "$WORK_DIR/cache.before-reboot"
ks standby-config "$WORK_DIR/standby.conf" || fail "the standby configuration could not be written after a reboot"
grep -Fqx 'server=/vpn.example/' "$WORK_DIR/standby.conf" || fail "after a reboot the standby resolver must block the protected names"
mv "$WORK_DIR/cache.before-reboot" "$KILLSWITCH_CACHE_DIR"
printf 'ok - the standby list is kept in RAM\n'

grep -Fqx 'server=/vpn.example/' "$BLOCKED" || fail "a stopped Prokop must block the protected names"
if grep -Fq 'other' "$BLOCKED"; then
  fail "a stopped Prokop must not block the names of an unprotected section"
fi
printf 'ok - a stopped Prokop blocks the protected names only\n'

# A list of an unprotected VPN section that is not downloaded yet cannot be
# listed: the standby still blocks every name it can read, and says so.
printf '{"version":1,"rules":[]}\n' >"$WORK_DIR/empty-0123456789ab.json"
write_sing_box_config "$WORK_DIR/empty-0123456789ab.json"
ks sync reload || fail "the sync with an unprotected list not downloaded yet failed"
ks standby-config "$WORK_DIR/standby.conf" || fail "the standby configuration could not be written"
for name in vpn.example other-vpn.example; do
  grep -Fqx "server=/$name/" "$WORK_DIR/standby.conf" ||
    fail "an unreadable list must not take $name out of the standby list"
done
grep -Fq 'not downloaded yet' "$KILLSWITCH_STATE_DIR/state.json" || fail "the incomplete standby list must be reported"
printf 'ok - an unreadable unprotected list keeps the other names in the standby\n'

# Lifting the protection removes the standby list with it.
sed -i '/kill_switch/d' "$PROKOP_UCI_STATE_FILE"
ks sync reload || fail "lifting the protection failed"
if ls "$KILLSWITCH_STATE_DIR"/*.servers "$KILLSWITCH_CACHE_DIR"/*.servers >/dev/null 2>&1; then
  fail "no block list may outlive the protection: $(ls "$KILLSWITCH_STATE_DIR" "$KILLSWITCH_CACHE_DIR")"
fi
printf 'ok - lifting the protection removes the standby list\n'

printf 'killswitch_standby_names: PASS\n'
