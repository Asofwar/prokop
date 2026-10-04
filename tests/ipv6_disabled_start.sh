#!/usr/bin/env bash
set -euo pipefail

# Prokop starts on a router with IPv6 disabled (A1). With
# net.ipv6.conf.all.disable_ipv6=1 the IPv6 TPROXY route and rule cannot be
# added and sing-box cannot listen on ::1: the start failed at the route, or
# waited for a ::1 listener that never came, and was retried forever with
# no proxy at all. Prokop now runs IPv4 only there. With IPv6 enabled, or a
# kernel without the sysctl, nothing changes.
#
# nft/apply.uc, the generator and the diagnostics run for real on a fake
# /proc/sys/net/ipv6; `ip` is a double that has no IPv6.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export IP_LOG="$WORK/ip.log" LOGGER_LOG="$WORK/logger.log"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in "$IP_LOG" "$LOGGER_LOG"; do
    [ ! -s "$log" ] || sed "s|^|  $(basename "$log"): |" "$log" >&2
  done
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/run"
export PATH="$WORK/bin:$PATH"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run" PROKOP_PROC_SYS_DIR="$WORK/proc-sys"
export PROKOP_NFT_SUBNET_CACHE_DIR="$WORK/nft-subnet-cache"
export PROKOP_IPV6_SYSCTL_DIR="$WORK/ipv6"

cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$LOGGER_LOG"
SH
# A kernel with IPv6 disabled: every `ip -6` call fails as on the router.
cat >"$WORK/bin/ip" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$IP_LOG"
case "$*" in
  -6\ *) echo 'RTNETLINK answers: Permission denied' >&2; exit 2 ;;
  'route list table '*) [ -e "$IP_LOG.route" ] && echo 'local default dev lo scope host' ;;
  '-4 rule list') [ -e "$IP_LOG.rule" ] && echo '105: from all fwmark 0x100000/0x100000 lookup prokop' ;;
  'route add '*) : >"$IP_LOG.route" ;;
  '-4 rule add '*) : >"$IP_LOG.rule" ;;
esac
exit 0
SH
chmod 0755 "$WORK/bin/"*

sysctl() { # sysctl <all> <lo>: disable_ipv6 values; "-" leaves the file out
  rm -rf "$PROKOP_IPV6_SYSCTL_DIR"
  local name value
  for name in all lo; do
    value="$1"
    shift
    [ "$value" = - ] && continue
    mkdir -p "$PROKOP_IPV6_SYSCTL_DIR/conf/$name"
    printf '%s\n' "$value" >"$PROKOP_IPV6_SYSCTL_DIR/conf/$name/disable_ipv6"
  done
}
available() { ucode -L "$LIB" -e 'exit(require("core.ipv6").available() ? 0 : 1)'; }
nft() { ucode -L "$LIB" "$LIB/nft/apply.uc" "$@"; }

# 1. IPv6 is off when all or lo has disable_ipv6=1.
sysctl 1 0
! available || fail "IPv6 is available with all.disable_ipv6=1"
sysctl 0 1
! available || fail "IPv6 is available with lo.disable_ipv6=1"
sysctl 0 0
available || fail "IPv6 is unavailable with both sysctls at 0"
sysctl - -
available || fail "a kernel without the IPv6 sysctls is taken for IPv6 disabled"

# 2. The TPROXY route and rule are added for IPv4 only, with no `ip -6`.
sysctl 1 1
nft ensure-tproxy-route-rule prokop 0x00100000 "$WORK/rt_tables" ||
  fail "the TPROXY route and rule failed with IPv6 disabled"
! grep -q '^-6 ' "$IP_LOG" || fail "an IPv6 route or rule was set up with IPv6 disabled"
grep -q '^route add local 0.0.0.0/0 dev lo table prokop' "$IP_LOG" || fail "no IPv4 TPROXY route was added"
grep -q '^-4 rule add fwmark' "$IP_LOG" || fail "no IPv4 TPROXY rule was added"
nft tproxy-route-rule-present prokop 0x00100000 ||
  fail "the IPv4 TPROXY route and rule are not taken as complete with IPv6 disabled"
# Control: with IPv6 enabled the missing IPv6 route still fails.
sysctl 0 0
! nft tproxy-route-rule-present prokop 0x00100000 2>/dev/null ||
  fail "a missing IPv6 TPROXY route was accepted with IPv6 enabled"
! nft ensure-tproxy-route-rule prokop 0x00100000 "$WORK/rt_tables" >/dev/null 2>&1 ||
  fail "an IPv6 route that could not be added was accepted with IPv6 enabled"

# 3. sing-box gets no tproxy6-in inbound with IPv6 disabled.
cat >"$WORK/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8" },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": ["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain_suffix": ["example.com"] }
  ]
}
JSON
inbounds() {
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/fixture.json" "$WORK/config.json" 192.0.2.1 0 1 '' 1.12.0 || fail "the generator failed"
  ucode -e 'for (let i in json(require("fs").readfile(ARGV[0])).inbounds) print(i.tag, "\n");' "$WORK/config.json"
}
sysctl 1 0
inbounds >"$WORK/inbounds"
! grep -qx tproxy6-in "$WORK/inbounds" || fail "sing-box listens on ::1 with IPv6 disabled"
grep -qx tproxy-in "$WORK/inbounds" || fail "the IPv4 TPROXY inbound is missing with IPv6 disabled"
sysctl 0 0
inbounds | grep -qx tproxy6-in || fail "the IPv6 TPROXY inbound is missing with IPv6 enabled"

# 4. sing-box is ready without a ::1 listener when IPv6 is disabled.
netstat_v4='tcp 0 0 127.0.0.42:53 0.0.0.0:* LISTEN 1/sing-box
tcp 0 0 0.0.0.0:1602 0.0.0.0:* LISTEN 1/sing-box'
listening() { printf '%s\n' "$netstat_v4" | ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" sing-box-standard-ports-listening-fixture >/dev/null 2>&1; }
sysctl 1 1
listening || fail "sing-box without a ::1 listener is not ready with IPv6 disabled"
sysctl 0 0
! listening || fail "sing-box without a ::1 listener is ready with IPv6 enabled"

printf 'ipv6 disabled start checks passed\n'
