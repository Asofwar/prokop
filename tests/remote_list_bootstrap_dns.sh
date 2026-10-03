#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/cache"
cat >"$WORK_DIR/bin/nslookup" <<'SH'
#!/bin/sh
[ "$1" = -timeout=5 ] || exit 2
shift
printf '%s %s\n' "$1" "$2" >>"$DNS_LOG"
[ "$2" != 1.1.1.1 ] || exit 1
printf 'Server: dns\nAddress: 8.8.8.8\nName: %s\n' "$1"
case "$1" in
  ipv6.example) printf 'Address 1: 2001:db8::7 ipv6.example\n' ;;
  *) printf 'Address 1: 2001:db8::8 alias\nAddress 2: 203.0.113.8 alias\n' ;;
esac
if [ "${DNS_MIXED_FAILURE:-0}" = 1 ]; then
  printf '** server can\047t find %s: SERVFAIL\n' "$1"
  exit 1
fi
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CURL_LOG"
output=''
resolved=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) output="$2"; shift 2 ;;
    --resolve) resolved="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "${CURL_FAILURE:-6}" = 6 ] || exit "$CURL_FAILURE"
[ -n "$resolved" ] || exit 6
if [ "${PAYLOAD_KIND:-list}" = json ]; then
  printf '{"version":1,"rules":[{"domain_suffix":["resolved.example","%s.example"]}]}\n' \
    "${PAYLOAD_TAG:-base}" >"$output"
else
  printf 'resolved.example\n' >"$output"
fi
SH
cat >"$WORK_DIR/bin/df" <<'SH'
#!/bin/sh
if [ "${NO_SPACE:-0}" = 1 ]; then
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 1000 1000 0 100%% /\n'
else
  /bin/df "$@"
fi
SH
cat >"$WORK_DIR/bin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
server=''
for arg in "$@"; do
  case "$arg" in
    @*) server="${arg#@}" ;;
  esac
done
printf '%s\n' "${server:-system}" >>"$DIG_LOG"
if [ -n "$server" ]; then
  [ "${BOOTSTRAP_UP:-0}" = 1 ] || exit 9
else
  [ "${SYSTEM_DNS_UP:-0}" = 1 ] || exit 9
fi
printf '203.0.113.10\n'
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH" PROKOP_LIB
export DNS_LOG="$WORK_DIR/dns.log" CURL_LOG="$WORK_DIR/curl.log" DIG_LOG="$WORK_DIR/dig.log"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
printf 'prokop.settings=settings\nprokop.settings.bootstrap_dns_server=1.1.1.1 8.8.8.8\n' >"$PROKOP_UCI_STATE_FILE"
reset_logs() { : >"$DNS_LOG"; : >"$CURL_LOG"; }
download_list() {
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/components/updates.uc" download-list-file "$1" "$WORK_DIR/list" "${2:-}"
}
reset_logs
download_list 'https://cdn.jsdelivr.net:8443/gh/project/list@HEAD/domains.txt' || fail 'list Bootstrap download failed'
grep -Fxq 'cdn.jsdelivr.net 1.1.1.1' "$DNS_LOG" || fail 'first DNS not tried'
grep -Fxq 'cdn.jsdelivr.net 8.8.8.8' "$DNS_LOG" || fail 'second DNS not tried'
grep -Fq -- '--resolve cdn.jsdelivr.net:8443:203.0.113.8' "$CURL_LOG" || fail 'wrong @ path hostname or IPv4 preference'
grep -Fq -- '--location --max-time 120' "$CURL_LOG" || fail 'redirect/total timeout missing'
grep -Fq 'resolved.example' "$WORK_DIR/list" || fail 'payload missing'

reset_logs
DNS_MIXED_FAILURE=1 download_list 'https://lists.example/mixed-dns.txt' || fail 'valid A answer lost after failed AAAA query'
grep -Fq -- '--resolve lists.example:443:203.0.113.8' "$CURL_LOG" || fail 'mixed DNS list response not used'

reset_logs
download_list 'https://ipv6.example:9443/rules.txt' || fail 'IPv6 Bootstrap failed'
grep -Fq -- '--resolve ipv6.example:9443:[2001:db8::7]' "$CURL_LOG" || fail 'IPv6 must be bracketed'

reset_logs
if download_list 'https://lists.example/rules.txt' '127.0.0.1:18080'; then fail 'proxy DNS failure accepted'; fi
[ ! -s "$DNS_LOG" ] || fail 'proxy path must not resolve destination directly'
grep -Fq -- '-x http://127.0.0.1:18080' "$CURL_LOG" || fail 'proxy lost'
grep -Fq -- '--resolve' "$CURL_LOG" && fail 'proxy path used direct resolve'

reset_logs
if CURL_FAILURE=60 download_list 'https://lists.example/rules.txt'; then fail 'TLS failure accepted'; fi
[ ! -s "$DNS_LOG" ] || fail 'TLS failure must not trigger DNS retry'
grep -Eq -- '(^| )(-k|--insecure)( |$)' "$CURL_LOG" && fail 'TLS validation disabled'

reset_logs
if NO_SPACE=1 download_list 'https://lists.example/rules.txt'; then fail 'no-space result was treated as success'; fi
[ ! -s "$CURL_LOG" ] || fail 'download started without space'
[ ! -s "$DNS_LOG" ] || fail 'storage failure triggered Bootstrap'

# Exercise the actual ruleset refresh path, not extracted helper functions.
export PROKOP_RULESET_CACHE_DIR="$WORK_DIR/cache"
export PROKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json"
export PROKOP_RULESET_RUNTIME_CACHE_DIR="$WORK_DIR/runtime"
export PROKOP_RULESET_RUNTIME_MANIFEST="$WORK_DIR/runtime-manifest.json"
export PROKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/list-cache"
cat >"$WORK_DIR/config.json" <<'JSON'
{"route":{"rule_set":[{"type":"remote","tag":"source","format":"source","url":"https://lists.example/rules@HEAD.json","update_interval":"1d"}]}}
JSON
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/ruleset_cache.uc" materialize-config "$WORK_DIR/config.json" cache-only
reset_logs
PAYLOAD_KIND=json ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/ruleset_cache.uc" refresh || fail 'ruleset Bootstrap refresh failed'
grep -Fq -- '--resolve lists.example:443:203.0.113.8' "$CURL_LOG" || fail 'ruleset DNS fallback absent'
reset_logs
# A distinct payload keeps this a real refresh: an identical one is committed by
# the previous case, and refresh_manifest reports "nothing changed" as exit 1.
DNS_MIXED_FAILURE=1 PAYLOAD_KIND=json PAYLOAD_TAG=mixed \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/ruleset_cache.uc" refresh ||
  fail 'ruleset valid A answer lost after failed AAAA query'
grep -Fq -- '--resolve lists.example:443:203.0.113.8' "$CURL_LOG" || fail 'mixed DNS ruleset response not used'
grep -Rq 'mixed.example' "$WORK_DIR/cache" "$WORK_DIR/runtime" || fail 'mixed DNS ruleset payload was not committed'
reset_logs
if PAYLOAD_KIND=json ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/ruleset_cache.uc" refresh '127.0.0.1:18080'; then
  fail 'failed proxy refresh must fail'
fi
[ ! -s "$DNS_LOG" ] || fail 'ruleset proxy path bypassed proxy DNS'
grep -Fq -- '--proxy http://127.0.0.1:18080' "$CURL_LOG" || fail 'ruleset proxy lost'
grep -Rq 'resolved.example' "$WORK_DIR/cache" "$WORK_DIR/runtime" || fail 'working cache lost after failure'

# A configured Bootstrap server is not a reachable one: the pre-download DNS
# probe may only shorten the cold-boot grace period when it actually answers.
dns_probe() {
  : >"$DIG_LOG"
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/components/updates.uc" list-dns-probe "${1:-}"
}

SYSTEM_DNS_UP=1 dns_probe || fail 'working system DNS must pass the probe'
grep -Fxq 'system' "$DIG_LOG" || fail 'system resolver was not probed'
grep -Fxq '1.1.1.1' "$DIG_LOG" && fail 'Bootstrap probed while system DNS worked'

SYSTEM_DNS_UP=0 BOOTSTRAP_UP=1 dns_probe || fail 'reachable Bootstrap DNS must let the list update continue'
[ "$(grep -Fxc 'system' "$DIG_LOG")" = 1 ] || fail 'reachable Bootstrap must not extend the grace period'
grep -Fxq '1.1.1.1' "$DIG_LOG" || fail 'Bootstrap resolver was not probed'

if SYSTEM_DNS_UP=0 BOOTSTRAP_UP=0 dns_probe; then
  fail 'unreachable Bootstrap DNS must not report a passing probe'
fi
[ "$(grep -Fxc 'system' "$DIG_LOG")" = 10 ] || fail 'the cold-boot DNS grace period was abandoned'
[ "$(grep -Fxc '1.1.1.1' "$DIG_LOG")" = 2 ] || fail 'Bootstrap must be probed on the first and last attempt only'
[ "$(grep -Fxc '8.8.8.8' "$DIG_LOG")" = 2 ] || fail 'every configured Bootstrap server must be probed'

dns_probe 127.0.0.1:18080 || fail 'proxied list downloads must skip the DNS probe'
[ ! -s "$DIG_LOG" ] || fail 'proxied probe must not query a resolver directly'

ucode -L "$PROKOP_LIB" -e '
let url = require("core.url");
for (let value in ["https://user:pass@example.org:8443/list@HEAD?q=x@y#z@a", "https://example.org:8443/?q=x@y"]) {
    if (url.host(value) != "example.org" || url.port(value) != "8443") exit(1);
}
if (url.host("https://user:pass@[2001:db8::1]:8443/list@HEAD") != "2001:db8::1") exit(1);
' || fail 'URL authority regression'
printf 'remote list Bootstrap DNS checks passed\n'
