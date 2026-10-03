#!/usr/bin/env bash
set -euo pipefail

# The DNS card of Diagnostics (diagnostics/runtime.uc check-dns-available)
# decides whether the main DNS server needs the bootstrap server the way the
# generated sing-box config does (singbox/dns.uc server_from_options: a
# domain_resolver only for a server host that is not an IP literal), with the
# same URL parser (core/url.uc). The copy in core/helpers.uc took the text up
# to the first colon as the host: an IPv6 main DNS server was "2606", so the
# card wanted a bootstrap server and asked it for the name "2606" (UC-086).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

mkdir -p "$WORK/bin"
# Every dig asked fails; each query is recorded.
cat >"$WORK/bin/dig" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${DIG_LOG:?}"
exit 9
SH
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/ip"
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/ubus"
chmod 0755 "$WORK/bin/dig" "$WORK/bin/ip" "$WORK/bin/ubus"

# generator_needs_bootstrap <dns_type> <server>: 1 when the generated main DNS
# server resolves its host through the bootstrap server.
generator_needs_bootstrap() {
  ucode -L "$LIB" -e '
    let dns = require("singbox.dns");
    let server = dns.server_from_options("t", ARGV[0], ARGV[1], "");
    print(server.domain_resolver != null ? "1" : "0", "\n");
  ' -- "$1" "$2"
}

# diagnostics_check <name> <dns_type> <server>: runs the DNS card check;
# leaves the JSON in $WORK/<name>.json and the dig queries in <name>.dig.
diagnostics_check() {
  local name="$1" dns_type="$2" server="$3"
  printf 'prokop.settings=settings\nprokop.settings.dns_type=%s\nprokop.settings.dns_server=%s\nprokop.settings.bootstrap_dns_server=1.1.1.1\n' \
    "$dns_type" "$server" >"$WORK/$name.state"
  : >"$WORK/$name.dig"
  PATH="$WORK/bin:$PATH" DIG_LOG="$WORK/$name.dig" \
    PROKOP_UCI_STATE_FILE="$WORK/$name.state" \
    PROKOP_DNS_FAILOVER_STATE_FILE="$WORK/$name.none.json" \
    PROKOP_RUNTIME_STATE_DIR="$WORK/$name.run" PROKOP_LIB="$LIB" \
    ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" check-dns-available >"$WORK/$name.json" 2>"$WORK/$name.err"
}

json_field() {
  node -e 'const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(v[process.argv[2]]);' "$1" "$2"
}

# expect <name> <dns_type> <server> <bootstrap required 0|1> [bootstrap query name]
expect() {
  local name="$1" dns_type="$2" server="$3" required="$4" query="${5:-}" generator actual
  generator="$(generator_needs_bootstrap "$dns_type" "$server")"
  [ "$generator" = "$required" ] ||
    fail "$name: precondition: the generator should need the bootstrap server: $required, got $generator"
  diagnostics_check "$name" "$dns_type" "$server" || {
    fail "$name: check-dns-available failed ($(cat "$WORK/$name.err"))"
    return
  }
  actual="$(json_field "$WORK/$name.json" bootstrap_dns_required)"
  [ "$actual" = "$required" ] ||
    fail "$name: Diagnostics says bootstrap_dns_required=$actual for '$server', the generator $required"
  if [ "$required" = 0 ]; then
    if grep -q '^@1\.1\.1\.1 ' "$WORK/$name.dig"; then
      fail "$name: the bootstrap server was asked although '$server' is an IP literal: $(grep '^@1\.1\.1\.1 ' "$WORK/$name.dig")"
    fi
  else
    grep -Fqx "@1.1.1.1 $query A +short +timeout=2 +tries=1" "$WORK/$name.dig" ||
      fail "$name: the bootstrap server should resolve '$query': $(cat "$WORK/$name.dig")"
  fi
}

expect ipv6 udp '2606:4700:4700::1111' 0
expect ipv6_bracket_port udp '[2606:4700:4700::1111]:53' 0
expect ipv6_dot dot '[2606:4700:4700::1111]:853' 0
expect ipv6_doh doh 'https://[2606:4700:4700::1111]/dns-query' 0
expect ipv4 udp '1.1.1.1' 0
expect ipv4_port udp '1.1.1.1:5353' 0
expect hostname_doh doh 'dns.google/dns-query' 1 dns.google
expect hostname_doh_url doh 'https://dns.google:443/dns-query' 1 dns.google
expect hostname_dot dot 'dns.quad9.net' 1 dns.quad9.net

if [ "$failures" -ne 0 ]; then
  printf '%d DNS card verdict(s) differ from the generated config\n' "$failures" >&2
  exit 1
fi
printf 'Diagnostics DNS card needs the bootstrap server exactly when the generated config does\n'
