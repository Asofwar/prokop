#!/bin/sh
set -eu
# OBS-5: with the main DNS server given as an address no bootstrap resolver
# is needed and none is checked (diagnostics/runtime.uc
# bootstrap_dns_required 0). The global check and the support report say it
# is not used instead of a false "❌ Bootstrap DNS"; a needed one that failed
# stays an error.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
check() {
  printf '{"dns_type":"udp","dns_server":"%s","bootstrap_dns_server":"77.88.8.8","bootstrap_dns_status":0,"bootstrap_dns_required":%s,"dns_status":1,"dns_on_router":1,"dhcp_config_status":1}' "$1" "$2" |
    ucode -L "$LIB" "$LIB/diagnostics/status.uc" global-dns-check 0
}
out="$(check 1.1.1.1 0)"
printf '%s\n' "$out" | grep -q 'Bootstrap DNS: 77.88.8.8 (not used' || fail "an unused bootstrap resolver is not said to be unused: $out"
! printf '%s\n' "$out" | grep -q '❌ Bootstrap' || fail "an unused bootstrap resolver is shown as failed"
check dns.google 1 | grep -q '❌ Bootstrap DNS: 77.88.8.8' || fail "a needed bootstrap resolver that failed is not an error"
echo "global_dns_check_bootstrap: OK"
