#!/usr/bin/env bash
set -eo pipefail

# C11: custom HTTP headers of a subscription source.
#   - the headers of a subscription_url item go to curl in its 0600 config
#     file, never on its command line; an invalid one (no colon, a control
#     character, a header Prokop sets itself or one that changes the request
#     framing) is not sent;
#   - the cache keeps only a hash of the headers, never their values;
#   - a cache downloaded with other headers is not current: changing the
#     headers makes the next update download again, as a changed URL does.
#
# subscription/cache.uc and config/connections.uc run for real; curl is a
# stub that answers with one VLESS link.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
CACHE_UC="$PROKOP_LIB/subscription/cache.uc"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CURL_LOG:?}"
out="" config=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -K) config="$2"; shift ;;
  esac
  shift
done
if [ -n "$config" ]; then
  stat -c '%a' "$config" >"$CURL_CONFIG_MODE"
  cat "$config" >"$CURL_CONFIG_COPY"
fi
printf 'vless://11111111-1111-1111-1111-111111111111@192.0.2.10:443?security=none&type=tcp#node-a\n' >"$out"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/"*

export PATH="$WORK_DIR/bin:$PATH"
export CURL_LOG="$WORK_DIR/curl.args"
export CURL_CONFIG_MODE="$WORK_DIR/curl.mode"
export CURL_CONFIG_COPY="$WORK_DIR/curl.config"
export TMP_SING_BOX_FOLDER="$WORK_DIR/sing-box"
export TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/sing-box/subscriptions"
export PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_SUBSCRIPTION_METADATA_DIR="$WORK_DIR/run/subscription-metadata"
export PROKOP_OUTBOUND_METADATA_DIR="$WORK_DIR/run/outbound-metadata"
export PROKOP_SECTION_CACHE_DIR="$WORK_DIR/run/section-cache"
export PROKOP_SUBSCRIPTION_LINKS_DIR="$WORK_DIR/run/subscription-links"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_LIB

URL='https://sub.example/api/sub'
write_config() {
  {
    printf 'prokop.settings=settings\n'
    printf 'prokop.vpn=section\nprokop.vpn.enabled=1\nprokop.vpn.action=connection\nprokop.vpn.proxy_config_type=subscription\n'
    printf 'prokop.s1=subscription_url\nprokop.s1.section=vpn\nprokop.s1.url=%s\n' "$URL"
    if [ -n "$1" ]; then
      printf 'prokop.s1.headers=%s\n' "$1"
    fi
  } >"$WORK_DIR/uci.state"
}

cache() { ucode -L "$PROKOP_LIB" "$CACHE_UC" "$@"; }

# Header validation and order (config/connections.uc).
valid="$(ucode -L "$PROKOP_LIB" -e '
  let c = require("config.connections");
  for (let entry in [ "X-Token: abc", "Authorization:Bearer t", "NoColon", "Bad Name: v", "User-Agent: x",
      "x-hwid: y", "Host: h", "Empty:", "Line: a\rb" ])
    print(entry, " => ", c.subscription_header_error(entry) || "ok", "\n");
')"
expected='X-Token: abc => ok
Authorization:Bearer t => ok
NoColon => not Name: value
Bad Name: v => invalid name
User-Agent: x => reserved name
x-hwid: y => reserved name
Host: h => reserved name
Empty: => empty value
Line: a'$'\r''b => control characters'
[ "$valid" = "$expected" ] || fail "header validation differs:
$valid"

# The rule modal refuses what the backend leaves out (section.js mirror).
SECTION_JS="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js"
ui_verdicts="$(node - "$SECTION_JS" <<'NODE'
const fs = require('node:fs');
const source = fs.readFileSync(process.argv[2], 'utf8');
const start = source.indexOf('const SUBSCRIPTION_RESERVED_HEADERS');
const end = source.indexOf('function subscriptionUrlChildDefaults');
const check = new Function('_', `${source.slice(start, end)}; return subscriptionHeaderError;`)((text) => text);
for (const entry of ['X-Token: abc', 'Authorization:Bearer t', 'NoColon', 'Bad Name: v', 'User-Agent: x',
  'x-hwid: y', 'Host: h', 'Empty:', 'Line: a\rb'])
  console.log(check(entry) === true ? 'ok' : 'refused');
NODE
)"
backend_verdicts="$(printf '%s\n' "$valid" | sed 's/.* => ok$/ok/; t; s/.* => .*/refused/')"
[ "$ui_verdicts" = "$backend_verdicts" ] || fail "the rule modal and the backend disagree on headers:
$ui_verdicts
--
$backend_verdicts"

# The headers of an item, in order, without the invalid ones.
cat >"$WORK_DIR/prokop.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [ { ".name": "vpn", ".type": "section", "enabled": "1", "action": "connection" } ],
  "subscription_url": [
    { ".name": "s1", ".type": "subscription_url", "section": "vpn", "url": "https://sub.example/api/sub",
      "headers": [ "X-Panel-Token: secret-tok-55", "Authorization:Bearer secret-bearer-66", "User-Agent: Evil",
        "NoColon", "  X-Spaced  :  value  " ] }
  ]
}
JSON
listed="$(ucode -L "$PROKOP_LIB" -e '
  let fs = require("fs");
  let c = require("config.connections");
  let data = json(fs.readfile(ARGV[0]));
  c.set_item_sections_from_data(data);
  print(join("|", c.subscription_headers(data.section[0], "https://sub.example/api/sub")), "\n");
' -- "$WORK_DIR/prokop.json")"
[ "$listed" = 'X-Panel-Token: secret-tok-55|Authorization: Bearer secret-bearer-66|X-Spaced: value' ] ||
  fail "the headers of a source differ: $listed"

# 1. The configured headers reach curl through its 0600 config only.
# The UCI state fixture keeps a list as one line split at blanks, so the
# update gets one header; the list handling is checked through
# connections.uc below.
write_config "X-Panel-Token:secret-tok-55"
cache update-source vpn 1 "$URL" >"$WORK_DIR/update.log" 2>&1 || fail "the update with custom headers failed: $(cat "$WORK_DIR/update.log")"
[ "$(cat "$CURL_CONFIG_MODE")" = 600 ] || fail "the curl config must be 0600"
grep -Fxq 'header = "X-Panel-Token: secret-tok-55"' "$CURL_CONFIG_COPY" || fail "the custom header was not sent: $(cat "$CURL_CONFIG_COPY")"
grep -q 'secret-' "$CURL_LOG" && fail "a header value reached curl's command line"

# 2. The cache keeps only a hash.
hash_file="$TMP_SUBSCRIPTION_FOLDER/vpn-subscription-1.headers"
[ -s "$hash_file" ] || hash_file="$(find "$TMP_SUBSCRIPTION_FOLDER" -name '*.headers' | head -n 1)"
[ -s "$hash_file" ] || fail "no headers hash was stored with the cache"
grep -Eq '^sha256:[0-9a-f]{64}$' "$hash_file" || fail "the stored headers hash is not a hash: $(cat "$hash_file")"
if grep -rq 'secret-' "$TMP_SUBSCRIPTION_FOLDER" "$PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR"; then
  fail "a header value was stored in the cache: $(grep -rl 'secret-' "$TMP_SUBSCRIPTION_FOLDER" "$PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR")"
fi
ls "$PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR"/*.headers >/dev/null 2>&1 || fail "the persistent cache has no headers hash"

# 3. The cache is current with the same headers, not with other ones.
cache section-current-usable-cache vpn "$TMP_SUBSCRIPTION_FOLDER" "$PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR" "" ||
  fail "the cache is not current with the headers it was downloaded with"
write_config "X-Panel-Token:secret-tok-99"
if cache section-current-usable-cache vpn "$TMP_SUBSCRIPTION_FOLDER" "$PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR" ""; then
  fail "a cache downloaded with other headers is still current"
fi
write_config ""
if cache section-current-usable-cache vpn "$TMP_SUBSCRIPTION_FOLDER" "$PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR" ""; then
  fail "a cache downloaded with headers is current after they were removed"
fi

# 4. Without headers nothing changes: no extra header lines, an empty hash.
rm -rf "$TMP_SUBSCRIPTION_FOLDER" "$PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR"
cache update-source vpn 1 "$URL" >"$WORK_DIR/update.log" 2>&1 || fail "the update without custom headers failed"
[ "$(grep -c '^header = ' "$CURL_CONFIG_COPY")" = 7 ] || fail "headers were added without any configured: $(cat "$CURL_CONFIG_COPY")"
cache section-current-usable-cache vpn "$TMP_SUBSCRIPTION_FOLDER" "$PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR" "" ||
  fail "a cache without headers is not current"

printf 'OK: subscription custom headers\n'
