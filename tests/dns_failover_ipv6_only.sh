#!/usr/bin/env bash
set -euo pipefail

# DNS failover works with dns_strategy=ipv6_only (NET-7). Its health query
# asked for an A record and wanted an IPv4 address; with ipv6_only sing-box
# answers A queries with no address, so every server looked down and the
# failover kept switching. The query is AAAA then.
#
# singbox/dns_failover.uc runs for real; `dig` answers as sing-box does
# under the configured strategy.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK/bin"
export PATH="$WORK/bin:$PATH" PROKOP_UCI_STATE_FILE="$WORK/uci.state" WORK
cat >"$WORK/bin/dig" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$WORK/dig.log"
strategy="$(sed -n 's/^prokop.settings.dns_strategy=//p' "$PROKOP_UCI_STATE_FILE")"
case "$*" in
  *' AAAA '*) [ "$strategy" = ipv4_only ] || echo 2606:2800:21f:cb07:6820:80da:af6b:8b2c ;;
  *' A '*) [ "$strategy" = ipv6_only ] || echo 93.184.215.14 ;;
esac
SH
chmod 0755 "$WORK/bin/dig"

probe() { ucode -L "$LIB" "$LIB/singbox/dns_failover.uc" probe main 0; }
strategy() {
  printf '%s\n' 'prokop.settings=settings' 'prokop.settings.dns_server=1.1.1.1 8.8.8.8' \
    "prokop.settings.dns_strategy=$1" >"$PROKOP_UCI_STATE_FILE"
}

strategy ipv6_only
probe || fail "a server answering under ipv6_only was taken for down"
grep -q ' AAAA ' "$WORK/dig.log" || fail "the ipv6_only health query did not ask for AAAA"
for value in prefer_ipv4 ipv4_only prefer_ipv6; do
  strategy "$value"
  probe || fail "a server answering under $value was taken for down"
done

printf 'dns failover ipv6_only checks passed\n'
