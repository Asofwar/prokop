#!/usr/bin/env bash
set -euo pipefail

# C3: VLESS Encryption (ML-KEM) needs sing-box-extended 2.0.0: on an older
# extended core a subscription node with it is skipped and a manual link is
# refused, instead of one node failing the whole configuration. A value that
# sing-box-extended would not parse (a truncated key) is skipped or refused
# the same way. The opt-in rule option reality_mlkem adds the X25519MLKEM768
# key share to its REALITY servers with uTLS "chrome", on sing-box-extended
# 2.7.2 or newer only; on another core it changes nothing and says so.
# With $PROKOP_TEST_SING_BOX_EXTENDED (sing-box-extended 2.7.2 or newer) the
# value check agrees with the real parser and the configuration passes
# "sing-box check"; $PROKOP_TEST_SING_BOX_EXTENDED_OLD (2.7.1) shows the
# configuration without the key share passes there too.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
GENERATOR="$LIB/singbox/generator.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

K32="AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
K1184="$(head -c 1184 /dev/zero | base64 -w0 | tr '+/' '-_' | tr -d '=')"
K1183="$(head -c 1183 /dev/zero | base64 -w0 | tr '+/' '-_' | tr -d '=')"
P="mlkem768x25519plus"

# value|expected error ("" accepted); padding lengths are left to "sing-box check".
corpus() {
  cat <<EOF
$P.native.0rtt.$K32|
$P.xorpub.1rtt.$K1184|
$P.random.0rtt.$K32.$K1184|
$P.native.1rtt.100-111-11111.$K32|
$P.native.0rtt.AAAA|invalid key length
$P.native.0rtt.$K1183|invalid key length
$P.native.0rtt.100-111-1111.$K32|invalid key length
$P.native.0rtt.$K32.50-0-3333|invalid key
$P.native.0rtt.$K32..$K32|empty segment
$P.fast.0rtt.$K32|unknown mode
$P.native.2rtt.$K32|unsupported RTT value
$P.native.0rtt|missing components
x25519.native.0rtt.$K32|unsupported prefix
$P.native.0rtt.50-0-3333|no keys
EOF
}
while IFS='|' read -r value expected; do
  got="$(ucode -L "$LIB" "$GENERATOR" vless-encryption-error "$value")"
  [ "$got" = "$expected" ] || fail "encryption value ${value:0:48}...: expected '$expected', got '$got'"
done < <(corpus)

# generate NAME FIXTURE VERSION: an extended core of that version (empty: stable).
generate() {
  local name="$1" fixture="$2" version="$3" extended=1
  [ -n "$version" ] && [[ $version == *extended* ]] || extended=0
  mkdir -p "$WORK/subscriptions" "$WORK/persistent"
  TMP_SUBSCRIPTION_FOLDER="$WORK/subscriptions" PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/persistent" \
    ucode -L "$LIB" "$GENERATOR" generate-config-fixture \
    "$fixture" "$WORK/$name.json" 127.0.0.1 0 "$extended" '' "$version" 2>"$WORK/$name.stderr"
}

# --- VLESS Encryption by core version -----------------------------------------
cat >"$WORK/sub.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [ { ".name": "enc", ".type": "section", "enabled": "1", "action": "connection",
    "subscription_urls": [ "https://example.com/enc.json" ],
    "subscription_url_settings": "{\"https://example.com/enc.json\":{\"user_agent\":\"Happ\"}}",
    "domain_suffix": [ "enc.example" ] } ]
}
JSON
mkdir -p "$WORK/subscriptions"
cat >"$WORK/subscriptions/enc-subscription-1.json" <<JSON
{ "outbounds": [
  { "type": "vless", "tag": "enc-node", "remark": "Encrypted node", "server": "127.0.0.30", "server_port": 443,
    "uuid": "00000000-0000-4000-8000-000000000030", "encryption": "$P.native.0rtt.$K32" },
  { "type": "vless", "tag": "broken-node", "remark": "Broken node", "server": "127.0.0.32", "server_port": 443,
    "uuid": "00000000-0000-4000-8000-000000000032", "encryption": "$P.native.0rtt.AAAA" },
  { "type": "vless", "tag": "plain-node", "remark": "Plain node", "server": "127.0.0.31", "server_port": 443,
    "uuid": "00000000-0000-4000-8000-000000000031" } ] }
JSON
printf '%s' 'https://example.com/enc.json' >"$WORK/subscriptions/enc-subscription-1.url"
printf '%s' 'Happ' >"$WORK/subscriptions/enc-subscription-1.user_agent"

generate sub-old "$WORK/sub.json" 1.12.12-extended-1.5.0 || fail "an old extended core did not build the remaining nodes"
grep -Fq 'Encrypted node (VLESS encryption requires sing-box-extended 2.0.0 or newer)' "$WORK/sub-old.stderr" ||
  fail "the old extended core did not say why the node was skipped: $(cat "$WORK/sub-old.stderr")"
grep -Fq '"enc-node"' "$WORK/sub-old.json" && fail "the old extended core kept the VLESS encryption node"
grep -Fq '"plain-node"' "$WORK/sub-old.json" || fail "the old extended core dropped the plain node"

for version in 1.14.1-extended-2.7.2 1.13.0-extended-2.0.0 ""; do
  name="sub-new${version:+-$version}"
  # An empty version is an extended core of unknown version: as before.
  if [ -z "$version" ]; then
    mkdir -p "$WORK/subscriptions" "$WORK/persistent"
    TMP_SUBSCRIPTION_FOLDER="$WORK/subscriptions" PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/persistent" \
      ucode -L "$LIB" "$GENERATOR" generate-config-fixture "$WORK/sub.json" "$WORK/$name.json" 127.0.0.1 0 1 2>"$WORK/$name.stderr" ||
      fail "an extended core of unknown version did not build"
  else
    generate "$name" "$WORK/sub.json" "$version" || fail "extended $version did not build"
  fi
  grep -Fq '"enc-node"' "$WORK/$name.json" || fail "extended '$version' dropped the VLESS encryption node"
  grep -Fq '"broken-node"' "$WORK/$name.json" && fail "extended '$version' kept a node with a truncated key"
  grep -Fq 'Broken node (invalid VLESS encryption value (invalid key length))' "$WORK/$name.stderr" ||
    fail "extended '$version' did not say why the broken node was skipped: $(cat "$WORK/$name.stderr")"
done

cat >"$WORK/manual.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [ { ".name": "manual_enc", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": [ "vless://00000000-0000-4000-8000-000000000032@enc.example:443?encryption=$P.native.0rtt.$K32&security=tls&sni=enc.example&type=tcp#Manual Enc" ] } ]
}
JSON
if generate manual-old "$WORK/manual.json" 1.12.12-extended-1.5.0; then
  fail "an old extended core accepted a manual VLESS encryption link"
fi
grep -Fq 'VLESS encryption requires sing-box-extended 2.0.0 or newer' "$WORK/manual-old.stderr" ||
  fail "the refused manual link does not say why: $(cat "$WORK/manual-old.stderr")"
generate manual-new "$WORK/manual.json" 1.14.1-extended-2.7.2 || fail "extended 2.7.2 refused the manual link"

# --- reality_mlkem ------------------------------------------------------------------
reality_fixture() {
  cat >"$WORK/reality-$1.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [ { ".name": "pq", ".type": "section", "enabled": "1", "action": "connection"${2:+, \"reality_mlkem\": \"$2\"},
    "selector_proxy_links": [
      "vless://00000000-0000-4000-8000-000000000040@r1.example:443?security=reality&pbk=$K32&sid=ab&sni=www.example.com&fp=chrome&type=tcp#Chrome",
      "vless://00000000-0000-4000-8000-000000000041@r2.example:443?security=reality&pbk=$K32&sid=ab&sni=www.example.com&fp=firefox&type=tcp#Firefox",
      "vless://00000000-0000-4000-8000-000000000042@t.example:443?security=tls&sni=t.example&fp=chrome&type=tcp#TLS" ] } ]
}
JSON
}
reality_fixture on 1
reality_fixture off ""
generate pq-new "$WORK/reality-on.json" 1.14.1-extended-2.7.2 || fail "reality_mlkem on 2.7.2 did not build"
generate pq-old "$WORK/reality-on.json" 1.14.0-extended-2.7.1 || fail "reality_mlkem on 2.7.1 did not build"
generate pq-stable "$WORK/reality-on.json" 1.12.9 || fail "reality_mlkem on stable did not build"
generate pq-off "$WORK/reality-off.json" 1.14.1-extended-2.7.2 || fail "reality_mlkem off did not build"

node - "$WORK" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const dir = process.argv[2];
const load = (n) => JSON.parse(fs.readFileSync(`${dir}/${n}.json`, 'utf8'));
const pq = (c) => Object.fromEntries(c.outbounds.filter((o) => o.tls && o.server)
  .map((o) => [o.server, o.tls.reality ? o.tls.reality.support_x25519mlkem768 === true : null]));
assert.deepEqual(pq(load('pq-new')), { 'r1.example': true, 'r2.example': false, 't.example': null },
  'on 2.7.2 only the chrome REALITY server gets the key share');
for (const n of ['pq-old', 'pq-stable', 'pq-off'])
  assert.deepEqual(pq(load(n)), { 'r1.example': false, 'r2.example': false, 't.example': null }, `${n}: no key share`);
NODE
grep -Fq "post-quantum REALITY key share needs sing-box-extended 2.7.2 or newer; not applied" "$WORK/pq-old.stderr" ||
  fail "2.7.1 did not say the option is not applied: $(cat "$WORK/pq-old.stderr")"
grep -Fq "post-quantum" "$WORK/pq-off.stderr" && fail "the option off still warned"

SECTION_JS="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js"
grep -q '"reality_mlkem"' "$SECTION_JS" || fail "the rule has no reality_mlkem setting"
grep -q 'REALITY_MLKEM_MIN_EXTENDED' "$SECTION_JS" || fail "the setting is not disabled on an unsuitable core"

# --- the real core -------------------------------------------------------------------
SBX="${PROKOP_TEST_SING_BOX_EXTENDED:-}"
if [ -z "$SBX" ] || [ ! -x "$SBX" ]; then
  printf 'vless_encryption_reality_mlkem: OK (real sing-box-extended not checked: set PROKOP_TEST_SING_BOX_EXTENDED)\n'
  exit 0
fi
while IFS='|' read -r value expected; do
  printf '{"outbounds":[{"type":"vless","tag":"x","server":"127.0.0.1","server_port":443,"uuid":"00000000-0000-4000-8000-000000000030","encryption":"%s"}]}\n' \
    "$value" >"$WORK/enc-check.json"
  if "$SBX" check -c "$WORK/enc-check.json" >/dev/null 2>&1; then real=""; else real=refused; fi
  [ -z "$expected" ] && [ -z "$real" ] || { [ -n "$expected" ] && [ -n "$real" ]; } ||
    fail "the real parser disagrees on ${value:0:48}...: Prokop '$expected', sing-box-extended '${real:-accepted}'"
done < <(corpus)
for name in pq-new sub-new-1.14.1-extended-2.7.2 manual-new; do
  "$SBX" check -c "$WORK/$name.json" >"$WORK/check.log" 2>&1 || fail "sing-box-extended refused $name: $(cat "$WORK/check.log")"
done
OLD="${PROKOP_TEST_SING_BOX_EXTENDED_OLD:-}"
if [ -n "$OLD" ] && [ -x "$OLD" ]; then
  "$OLD" check -c "$WORK/pq-old.json" >"$WORK/check.log" 2>&1 || fail "sing-box-extended 2.7.1 refused pq-old: $(cat "$WORK/check.log")"
  "$OLD" check -c "$WORK/pq-new.json" >/dev/null 2>&1 && fail "2.7.1 accepted the key share, so the version gate is wrong"
fi
echo "vless_encryption_reality_mlkem: OK"
