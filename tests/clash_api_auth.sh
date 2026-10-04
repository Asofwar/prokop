#!/usr/bin/env bash
set -euo pipefail

# UC-035, UC-007 (D-1 b): one Clash API authentication predicate. The
# controller carries a secret whenever one is configured (not only with YACD
# or WAN access), and every backend request to the controller, the readiness
# probe included, sends it. The secret never appears on a command line, so
# the process list of a support report cannot capture it.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
GENERATOR="$PROKOP_LIB/singbox/generator.uc"
RUNTIME_UC="$PROKOP_LIB/diagnostics/runtime.uc"
STATE_UC="$PROKOP_LIB/service/state.uc"
WORK_DIR="$(mktemp -d)"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

UCODE_BIN="$(command -v ucode)" || fail "ucode is required"
SECRET='S3cr3t-Clash-Marker'

# --- Generator ---------------------------------------------------------------

generate() {
  local name="$1" settings="$2"
  cat >"$WORK_DIR/$name.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8"$settings },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": ["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain_suffix": ["example.com"] }
  ]
}
JSON
  "$UCODE_BIN" -L "$PROKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/$name.json" "$WORK_DIR/$name.config.json" 192.0.2.1 0 1 '' 1.12.0 ||
    fail "generator failed for $name"
}

clash_field() {
  "$UCODE_BIN" -e 'let c = json(require("fs").readfile(ARGV[0])); let v = c.experimental.clash_api[ARGV[1]]; print(v == null ? "<none>" : v);' \
    "$WORK_DIR/$1.config.json" "$2"
}

generate lan-secret ", \"enable_yacd\": \"0\", \"yacd_secret_key\": \"$SECRET\""
[ "$(clash_field lan-secret secret)" = "$SECRET" ] ||
  fail "a configured secret must protect the LAN controller even without YACD"
[ "$(clash_field lan-secret external_controller)" = "192.0.2.1:9090" ] ||
  fail "without WAN access the controller stays on the LAN address"
[ "$(clash_field lan-secret external_ui)" = "<none>" ] ||
  fail "the YACD UI is only served with YACD enabled"

generate yacd-lan ", \"enable_yacd\": \"1\", \"enable_yacd_wan_access\": \"0\", \"yacd_secret_key\": \"$SECRET\""
[ "$(clash_field yacd-lan secret)" = "$SECRET" ] || fail "YACD on the LAN must keep the secret"
[ "$(clash_field yacd-lan external_ui)" = "ui" ] || fail "YACD must serve the UI"

generate yacd-wan ", \"enable_yacd\": \"1\", \"enable_yacd_wan_access\": \"1\", \"yacd_secret_key\": \"$SECRET\""
[ "$(clash_field yacd-wan secret)" = "$SECRET" ] || fail "WAN access must keep the secret"
[ "$(clash_field yacd-wan external_controller)" = "0.0.0.0:9090" ] || fail "WAN access listens on all addresses"

generate padded ", \"yacd_secret_key\": \"  $SECRET  \""
[ "$(clash_field padded secret)" = "$SECRET" ] || fail "the generator and the backend must use the same trimmed secret"

# --- Backend requests ----------------------------------------------------------

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/etc"
# curl stub: answers like the sing-box controller, which rejects a request
# without the right bearer token. Its command line and header files are
# recorded.
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
log="${CLASH_TEST_CURL_LOG:?}"
printf 'ARGV:' >>"$log"
auth=""
mode=""
prev=""
for arg in "$@"; do
  printf ' %s' "$arg" >>"$log"
  if [ "$prev" = "-H" ] || [ "$prev" = "--header" ]; then
    case "$arg" in
      @*) file="${arg#@}"
          [ -r "$file" ] || { printf '\nHEADER-FILE-UNREADABLE\n' >>"$log"; exit 7; }
          mode="HEADER-FILE-MODE: $(stat -c %a "$file")"
          auth="$(cat "$file")" ;;
      *) auth="$arg" ;;
    esac
  fi
  prev="$arg"
done
printf '\n' >>"$log"
[ -z "$mode" ] || printf '%s\n' "$mode" >>"$log"
if [ -n "${CLASH_TEST_SECRET:-}" ] && [ "$auth" != "Authorization: Bearer $CLASH_TEST_SECRET" ]; then
  printf '{"message":"Unauthorized"}\n'
  exit 0
fi
case "$*" in
  */version) printf '{"version":"sing-box 1.12.0"}\n' ;;
  *) printf '{"proxies":{"direct":{"type":"Direct"},"main-out":{"type":"VLESS"}}}\n' ;;
esac
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
exit 0
SH
chmod 0755 "$WORK_DIR/bin/curl" "$WORK_DIR/bin/logger"

write_state() {
  local secret_line="$1"
  cat >"$WORK_DIR/etc/prokop" <<EOF
config settings 'settings'
	option service_listen_address '127.0.0.1'
	option enable_yacd '0'
EOF
  {
    printf '%s\n' 'prokop.settings=settings' \
      'prokop.settings.service_listen_address=127.0.0.1' \
      'prokop.settings.enable_yacd=0'
    [ -z "$secret_line" ] || printf '%s\n' "$secret_line"
  } >"$WORK_DIR/uci-state"
}

backend() {
  : >"$WORK_DIR/curl.log"
  env PATH="$WORK_DIR/bin:$PATH" \
    PROKOP_LIB="$PROKOP_LIB" \
    PROKOP_CONFIG="$WORK_DIR/etc/prokop" \
    PROKOP_CONFIG_FILE="$WORK_DIR/etc/prokop" \
    PROKOP_UCI_STATE_FILE="$WORK_DIR/uci-state" \
    PROKOP_UCI_LOG_FILE="$WORK_DIR/uci-log" \
    PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    CLASH_TEST_CURL_LOG="$WORK_DIR/curl.log" \
    CLASH_TEST_SECRET="${CLASH_TEST_SECRET:-}" \
    TMPDIR="$WORK_DIR/tmp" \
    "$UCODE_BIN" -L "$PROKOP_LIB" "$RUNTIME_UC" "$@"
}
mkdir -p "$WORK_DIR/tmp"

# The secret is configured, YACD and WAN access are off: the controller
# requires the token, so readiness must send it.
write_state "prokop.settings.yacd_secret_key=$SECRET"
CLASH_TEST_SECRET="$SECRET" backend clash-api-ready >/dev/null 2>&1 ||
  fail "readiness must authenticate whenever a secret is configured (got 401)"
grep -q '^ARGV:.*/version' "$WORK_DIR/curl.log" || fail "readiness did not query the controller"
# Optimization 3: readiness reads the version, not the whole proxy list.
! grep -q '^ARGV:.*/proxies' "$WORK_DIR/curl.log" || fail "readiness fetched the whole proxy list"
grep '^ARGV:' "$WORK_DIR/curl.log" | grep -q "$SECRET" &&
  fail "the Clash secret must not appear on the curl command line"
grep -q '^HEADER-FILE-MODE: 600$' "$WORK_DIR/curl.log" ||
  fail "the Authorization header must come from a private (0600) file"
[ -z "$(find "$WORK_DIR/tmp" "$WORK_DIR/run" -type f -path '*auth*' 2>/dev/null; find "$WORK_DIR/tmp" -type f)" ] ||
  fail "the header file must be removed after the request"
# Optimization 4: the header file is made in-process, in a private directory.
! grep -q '^ARGV:.*mktemp' "$WORK_DIR/curl.log" || fail "mktemp ran"
[ "$(stat -c %a "$WORK_DIR/run/clash-auth")" = 700 ] || fail "the header directory is not private"

out="$(CLASH_TEST_SECRET="$SECRET" backend clash-api get_proxies 2>/dev/null)" ||
  fail "get_proxies failed"
printf '%s' "$out" | grep -q '"main-out"' || fail "get_proxies must authenticate with the configured secret: $out"
grep '^ARGV:' "$WORK_DIR/curl.log" | grep -q "$SECRET" && fail "get_proxies put the secret on the command line"
printf '%s' "$out" | grep -q "$SECRET" && fail "get_proxies output must not echo the secret"

CLASH_TEST_SECRET="$SECRET" backend clash-api set_group_proxy main-group main-out >/dev/null 2>&1 || true
grep -q '^HEADER-FILE-MODE: 600$' "$WORK_DIR/curl.log" || fail "set_group_proxy must authenticate"
grep '^ARGV:' "$WORK_DIR/curl.log" | grep -q "$SECRET" && fail "set_group_proxy put the secret on the command line"

# A whitespace-only secret is no secret: nothing is sent.
write_state "prokop.settings.yacd_secret_key=   "
backend clash-api-ready >/dev/null 2>&1 || fail "readiness without a secret must not require one"
grep -q 'HEADER-FILE\|Authorization' "$WORK_DIR/curl.log" && fail "no Authorization header without a secret"

# --- Support report ------------------------------------------------------------

# The otherwise unmasked support report keeps the Clash secret out: support
# never needs it (D-1). The config file, the raw global check and the raw
# sing-box config all carry it.
write_state "prokop.settings.yacd_secret_key=$SECRET"
printf "\toption yacd_secret_key '%s'\n\toption config_path '%s'\n" "$SECRET" "$WORK_DIR/sing-box.json" >>"$WORK_DIR/etc/prokop"
printf 'prokop.settings.config_path=%s\n' "$WORK_DIR/sing-box.json" >>"$WORK_DIR/uci-state"
printf '{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090","secret":"%s"}}}\n' "$SECRET" >"$WORK_DIR/sing-box.json"
backend support-report >"$WORK_DIR/report.txt" 2>&1 </dev/null || true
grep -Fq 'CONFIDENTIAL SUPPORT REPORT' "$WORK_DIR/report.txt" || fail "the support report was not produced"
grep -Fq "yacd_secret_key" "$WORK_DIR/report.txt" || fail "the support report must keep the option shape"
grep -Fq "$SECRET" "$WORK_DIR/report.txt" && fail "the support report must not contain the Clash secret"

# A user secret with a quote or a backslash appears JSON-escaped in the raw
# sing-box config; that form must be masked too.
ESCAPED_SECRET='Qu0teMark"Back\slash'
write_state "prokop.settings.yacd_secret_key=$ESCAPED_SECRET"
printf "\toption yacd_secret_key '%s'\n\toption config_path '%s'\n" "$ESCAPED_SECRET" "$WORK_DIR/sing-box.json" >>"$WORK_DIR/etc/prokop"
printf 'prokop.settings.config_path=%s\n' "$WORK_DIR/sing-box.json" >>"$WORK_DIR/uci-state"
"$UCODE_BIN" -e 'require("fs").writefile(ARGV[0], sprintf("{\"experimental\":{\"clash_api\":{\"secret\":%J}}}\n", ARGV[1]));' \
  "$WORK_DIR/sing-box.json" "$ESCAPED_SECRET"
grep -Fq 'Back\\slash' "$WORK_DIR/sing-box.json" || fail "the fixture must hold the JSON-escaped secret"
backend support-report >"$WORK_DIR/report-escaped.txt" 2>&1 </dev/null || true
grep -Fq 'CONFIDENTIAL SUPPORT REPORT' "$WORK_DIR/report-escaped.txt" || fail "the support report was not produced"
grep -Fq 'Qu0teMark' "$WORK_DIR/report-escaped.txt" &&
  fail "the support report must mask the JSON-escaped form of the Clash secret"

# --- Reload signature ------------------------------------------------------------

# A changed secret changes the controller, so it must reload sing-box even
# with YACD off; otherwise the backend would send a secret sing-box does not
# know yet.
signature() {
  cat >"$WORK_DIR/sig.json" <<JSON
{ "settings": { "enable_yacd": "0", "yacd_secret_key": "$1" }, "runtime": { "mwan3_active": "0" }, "section": [] }
JSON
  "$UCODE_BIN" -L "$PROKOP_LIB" "$STATE_UC" sing-box-signature-fixture "$WORK_DIR/sig.json"
}
[ "$(signature one)" != "$(signature two)" ] ||
  fail "the sing-box reload signature must follow the Clash secret regardless of YACD"

printf 'Clash API authentication predicate is shared and secret-safe\n'
