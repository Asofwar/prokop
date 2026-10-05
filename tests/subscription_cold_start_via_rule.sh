#!/usr/bin/env bash
set -euo pipefail

# A cold start does not download directly a subscription configured to
# download through another rule (LC-11). prepare-caches before sing-box runs
# used to fetch it directly ("downloading it directly during startup"): the
# provider saw the subscription host the user routed through a proxy. Now
# such a rule is deferred and downloads through the service proxy once
# sing-box runs (or through the temporary list sing-box). Directly only when
# the rule it downloads through cannot carry it at this start, or the rule
# has sources that do not wait, so the start does not lose them.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; [ ! -s "$W/logger.log" ] || sed 's/^/  log: /' "$W/logger.log" >&2; exit 1; }

mkdir -p "$W/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/logger.log"\n' "$W" >"$W/bin/logger"
printf '#!/bin/sh\necho "{}"\n' >"$W/bin/ubus"
cat >"$W/bin/curl" <<SH
#!/bin/sh
url=""; proxy=direct; prev=""
for arg in "\$@"; do
  case "\$prev" in -x|--proxy) proxy="\$arg" ;; -K) url="\$(sed -n 's/^url = "\\(.*\\)"\$/\\1/p' "\$arg")" ;; esac
  case "\$arg" in http://* | https://*) url="\$arg" ;; esac
  prev="\$arg"
done
printf '%s proxy=%s\n' "\$url" "\$proxy" >>"$W/curl.log"
exit 7
SH
chmod +x "$W/bin/"*

# $1: rule main's options, $2: extra options of rule vpn.
prepare() {
  rm -rf "$W/run" "$W/tmp" "$W/subcache" "$W/curl.log" "$W/logger.log"
  mkdir -p "$W/run" "$W/tmp"
  {
    printf '%s\n' prokop.settings=settings prokop.settings.dns_server=77.88.8.8 prokop.settings.bootstrap_dns_server=77.88.8.8
    printf '%s\n' prokop.main=section prokop.main.enabled=1 prokop.main.action=connection "$1"
    printf '%s\n' prokop.vpn=section prokop.vpn.enabled=1 prokop.vpn.action=connection \
      prokop.vpn.subscription_urls=https://sub.example.net/secret-token \
      'prokop.vpn.subscription_url_settings={"https://sub.example.net/secret-token":{"download_via_proxy_enabled":"1","download_via_proxy_section":"main"}}'
    [ -z "$2" ] || printf '%s\n' "$2"
  } >"$W/uci.state"
  env PATH="$W/bin:$PATH" PROKOP_LIB="$LIB" PROKOP_UCI_STATE_FILE="$W/uci.state" PROKOP_RUNTIME_STATE_DIR="$W/run" \
    TMP_SING_BOX_FOLDER="$W/tmp" TMP_SUBSCRIPTION_FOLDER="$W/tmp/subscriptions" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$W/subcache" TMPDIR="$W/tmp" \
    ucode -L "$LIB" "$LIB/subscription/cache.uc" prepare-caches startup 0 0 >"$W/out" 2>"$W/err"
}

# 1. Rule main has its own node: vpn waits for it.
prepare 'prokop.main.outbound_jsons={"type":"direct","tag":"test"}' '' || fail "the start did not defer rule vpn: $(cat "$W/err")"
! grep -q 'sub.example.net.*proxy=direct' "$W/curl.log" 2>/dev/null ||
  fail "the subscription was downloaded directly at the cold start: $(cat "$W/curl.log")"
[ "$(tr -d '[:space:]' <"$W/out")" = vpn ] || fail "rule vpn was not deferred to the service proxy: '$(cat "$W/out")'"
grep -q "downloads via rule 'main' once sing-box runs" "$W/logger.log" || fail "the log does not say the subscription waits"
! grep -q 'directly during startup' "$W/logger.log" || fail "the log still says it downloads directly"

# 2. Rule main cannot carry it at this start: directly, as before.
prepare 'prokop.main.subscription_urls=https://other.example.net/sub' '' || true
grep -q 'sub.example.net/secret-token proxy=direct' "$W/curl.log" ||
  fail "a subscription whose download rule has no nodes was not downloaded at all: $(cat "$W/curl.log" 2>/dev/null)"

# 3. Rule vpn also has a manual node: it starts with it, the subscription
#    downloads directly, as before.
prepare 'prokop.main.outbound_jsons={"type":"direct","tag":"test"}' 'prokop.vpn.outbound_jsons={"type":"direct","tag":"own"}' ||
  fail "the start failed for a rule with a manual node: $(cat "$W/err")"
grep -q 'sub.example.net/secret-token proxy=direct' "$W/curl.log" ||
  fail "the subscription of a rule with a manual node was not downloaded: $(cat "$W/curl.log" 2>/dev/null)"
[ -z "$(tr -d '[:space:]' <"$W/out")" ] || fail "a rule with a manual node was deferred: '$(cat "$W/out")'"

printf 'subscription_cold_start_via_rule: OK\n'
