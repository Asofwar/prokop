#!/usr/bin/env bash
set -euo pipefail

# dnsmasq's conditional forwarders keep working while Prokop runs (NET-8).
# Forwarding to sing-box replaced dnsmasq's whole server list, so entries
# such as server=/corp.example/10.0.0.1 (a company domain over a VPN) or
# /onion/127.0.0.1#9053 stopped working until Prokop was stopped. They now
# stay next to sing-box, a restore puts the list back as it was, and a
# router configured by an earlier release gets them back at the next start.
#
# dns/apply.uc runs for real on the UCI fixture.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STATE="$WORK/uci.state"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  grep '^dhcp\.' "$STATE" | sed 's/^/  /' >&2 || true
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/killswitch"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/dnsmasq-init"
chmod 0755 "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" DNSMASQ_INIT="$WORK/bin/dnsmasq-init"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run" KILLSWITCH_STATE_DIR="$WORK/killswitch"
export PROKOP_CONFIG_NAME=prokop SB_DNS_INBOUND_ADDRESS=127.0.0.42
export PROKOP_UCI_STATE_FILE="$STATE" PROKOP_UCI_LOG_FILE="$WORK/uci.log"
export PROKOP_DNSMASQ_CONFIG_FILE="$WORK/no-dhcp"

dns_apply() { ucode -L "$LIB" "$LIB/dns/apply.uc" "$@" || fail "dns/apply.uc $* failed"; }
servers() { sed -n 's/^dhcp\.@dnsmasq\[0\]\.server=//p' "$STATE"; }
conditional='/corp.example/10.0.0.1 /onion/127.0.0.1#9053'

# 1. The configure keeps them next to sing-box; the restore puts the list back.
printf '%s\n' prokop.settings=settings "dhcp.@dnsmasq[0].server=1.1.1.1 $conditional" >"$STATE"
dns_apply configure force
[ "$(servers)" = "127.0.0.42 $conditional" ] ||
  fail "the conditional forwarders did not stay next to sing-box: $(servers)"
dns_apply restore force
[ "$(servers)" = "1.1.1.1 $conditional" ] || fail "the restore did not put the server list back: $(servers)"

# 2. A dnsmasq an earlier release configured (sing-box only, the forwarders in
#    the backup) gets them back at the next start.
printf '%s\n' prokop.settings=settings 'dhcp.@dnsmasq[0].server=127.0.0.42' \
  'dhcp.@dnsmasq[0].noresolv=1' 'dhcp.@dnsmasq[0].cachesize=0' \
  "dhcp.@dnsmasq[0].prokop_server=1.1.1.1 $conditional" >"$STATE"
dns_apply configure
[ "$(servers)" = "127.0.0.42 $conditional" ] ||
  fail "the conditional forwarders of an earlier configure did not come back: $(servers)"
: >"$WORK/uci.log"
dns_apply default-config-complete || fail "a dnsmasq forwarding to sing-box with its conditional forwarders is not taken as configured"
dns_apply configure
! grep -Fxq 'commit dhcp' "$WORK/uci.log" || fail "a configure that changes nothing wrote dhcp again"

printf 'dnsmasq conditional forwarder checks passed\n'
