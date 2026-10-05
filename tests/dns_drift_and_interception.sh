#!/usr/bin/env bash
set -euo pipefail

# C8: dnsmasq changed behind Prokop, and plain DNS captured on the way.
#
# 1. Health warns when dnsmasq still forwards to sing-box but its upstream
#    resolvers (noresolv) or its cache (cachesize) were turned back on by
#    something else (dns.drift); devices then get answers past sing-box. A
#    UI state without dns_complete (an older backend) is no drift, and
#    dont_touch_dhcp silences it.
# 2. The DNS card of Diagnostics asks 192.0.2.1, where no DNS server runs:
#    an answer means something on the way captures port 53
#    (dns_interception=1); no answer is 0.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

health_dns() {
  printf '{"ui":{"service":{"prokop":{"running":1,%s},"sing_box":{"running":1}}},"guard":false,"package_pending":false,"events":[]}\n' "$1" \
    >"$WORK/fixture.json"
  PROKOP_RUNTIME_STATE_DIR="$WORK/run" ucode -L "$LIB" "$LIB/diagnostics/health.uc" fixture "$WORK/fixture.json" |
    ucode -e 'let v = json(trim(fs.readfile("/dev/stdin"))); print(v.dns.status, " ", v.dns.drift, "\n");' -l fs
}

[ "$(health_dns '"dns_configured":1,"dns_complete":1')" = "unknown false" ] || fail "complete dnsmasq settings read as a problem"
[ "$(health_dns '"dns_configured":1,"dns_complete":0')" = "warning true" ] || fail "dnsmasq changed behind Prokop is not reported"
[ "$(health_dns '"dns_configured":1')" = "unknown false" ] || fail "a UI state without dns_complete reads as drift"
[ "$(health_dns '"dns_configured":1,"dns_complete":0,"dhcp_user_managed":1')" = "unknown false" ] ||
  fail "drift is reported although the user manages dnsmasq"
[ "$(health_dns '"dns_configured":0')" = "warning false" ] || fail "dnsmasq not pointed to Prokop is no longer a warning"

# The canary: a dig stand-in that answers only when told to.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/dig" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${DIG_LOG:?}"
case "$1" in
  @192.0.2.1)
    [ "${CANARY_ANSWERS:-0}" = 1 ] || exit 9
    printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'
    exit 0 ;;
esac
exit 9
SH
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/ip"
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/ubus"
chmod 0755 "$WORK/bin/"*
printf 'prokop.settings=settings\nprokop.settings.dns_type=udp\nprokop.settings.dns_server=8.8.8.8\n' >"$WORK/dns.state"

canary() {
  : >"$WORK/dig.log"
  PATH="$WORK/bin:$PATH" DIG_LOG="$WORK/dig.log" CANARY_ANSWERS="$1" \
    PROKOP_UCI_STATE_FILE="$WORK/dns.state" \
    PROKOP_DNS_FAILOVER_STATE_FILE="$WORK/none.json" \
    PROKOP_RUNTIME_STATE_DIR="$WORK/run" PROKOP_LIB="$LIB" \
    ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" check-dns-available >"$WORK/dns.json" 2>"$WORK/dns.err" ||
    fail "check-dns-available failed: $(cat "$WORK/dns.err")"
  ucode -e 'print(json(trim(fs.readfile(ARGV[0]))).dns_interception, "\n");' -l fs -- "$WORK/dns.json"
}
[ "$(canary 1)" = 1 ] || fail "an answer from 192.0.2.1 is not reported as DNS interception"
grep -q '^@192.0.2.1 example.com A +timeout=2 +tries=1$' "$WORK/dig.log" || fail "the canary query was not sent: $(cat "$WORK/dig.log")"
[ "$(canary 0)" = 0 ] || fail "no answer from 192.0.2.1 is reported as DNS interception"

# The text report of global_check names the interception.
printf '{"dns_type":"udp","dns_server":"8.8.8.8","dns_status":1,"dns_on_router":1,"dhcp_config_status":1,"dns_interception":1}\n' |
  ucode -L "$LIB" "$LIB/diagnostics/status.uc" global-dns-check 0 >"$WORK/report.txt" || true
grep -q 'Plain DNS (port 53) is intercepted' "$WORK/report.txt" || fail "the text report does not name the interception: $(cat "$WORK/report.txt")"

printf 'OK: dnsmasq drift and DNS interception are reported\n'
