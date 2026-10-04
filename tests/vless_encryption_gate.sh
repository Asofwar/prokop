#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
SINGBOX_GENERATOR_UC="$PROKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# $1 fixture, $2 output, $3 supports_xhttp (sing-box-extended)
generate() {
  mkdir -p "$2.section-cache" "$2.rulesets"
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent" \
    ucode -L "$PROKOP_LIB" "$SINGBOX_GENERATOR_UC" generate-config-fixture \
      "$1" "$2" "127.0.0.1" "0" "$3"
}

mkdir -p "$WORK_DIR/subscriptions" "$WORK_DIR/persistent"

cat >"$WORK_DIR/sub-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [
    {
      ".name": "enc",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "subscription_urls": [ "https://example.com/enc.json" ],
      "subscription_url_settings": "{\"https://example.com/enc.json\":{\"user_agent\":\"Happ\"}}",
      "domain_suffix": [ "enc.example" ]
    }
  ]
}
JSON
cat >"$WORK_DIR/subscriptions/enc-subscription-1.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "vless", "tag": "enc-node", "remark": "Encrypted node",
      "server": "127.0.0.30", "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000030",
      "encryption": "mlkem768x25519plus.native.0rtt.AAAA"
    },
    {
      "type": "vless", "tag": "plain-node", "remark": "Plain node",
      "server": "127.0.0.31", "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000031",
      "encryption": "none"
    }
  ]
}
JSON
printf '%s' 'https://example.com/enc.json' >"$WORK_DIR/subscriptions/enc-subscription-1.url"
printf '%s' 'Happ' >"$WORK_DIR/subscriptions/enc-subscription-1.user_agent"

generate "$WORK_DIR/sub-fixture.json" "$WORK_DIR/sub-stable.json" 0 2>"$WORK_DIR/sub-stable.stderr" ||
  fail "stable sing-box must still build a config from the remaining subscription nodes"
grep -Fq "Encrypted node (VLESS encryption requires sing-box-extended)" "$WORK_DIR/sub-stable.stderr" ||
  fail "stable sing-box must warn about the skipped VLESS encryption node"
grep -Fq '"enc-node"' "$WORK_DIR/sub-stable.json" &&
  fail "stable sing-box must drop the VLESS encryption node"
grep -Fq '"plain-node"' "$WORK_DIR/sub-stable.json" ||
  fail "stable sing-box must keep a node with encryption=none"

generate "$WORK_DIR/sub-fixture.json" "$WORK_DIR/sub-extended.json" 1 2>"$WORK_DIR/sub-extended.stderr" ||
  fail "sing-box-extended must build the subscription config"
grep -Fq '"enc-node"' "$WORK_DIR/sub-extended.json" ||
  fail "sing-box-extended must keep the VLESS encryption node"
grep -Fq "VLESS encryption requires" "$WORK_DIR/sub-extended.stderr" &&
  fail "sing-box-extended must not warn about VLESS encryption"

cat >"$WORK_DIR/manual-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [
    {
      ".name": "manual_enc",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000032@enc.example:443?encryption=mlkem768x25519plus.native.0rtt.AAAA&security=tls&sni=enc.example&type=tcp#Manual Enc"
      ]
    }
  ]
}
JSON
if generate "$WORK_DIR/manual-fixture.json" "$WORK_DIR/manual-stable.json" 0 \
  >"$WORK_DIR/manual-stable.stdout" 2>"$WORK_DIR/manual-stable.stderr"; then
  fail "stable sing-box must reject a manual VLESS encryption link"
fi
grep -Fq "uses VLESS encryption, but sing-box-extended is not installed" "$WORK_DIR/manual-stable.stderr" ||
  fail "the manual VLESS encryption failure must explain the extended requirement"
generate "$WORK_DIR/manual-fixture.json" "$WORK_DIR/manual-extended.json" 1 ||
  fail "sing-box-extended must accept a manual VLESS encryption link"

printf 'vless encryption gate checks passed\n'
