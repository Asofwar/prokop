#!/usr/bin/env bash
set -euo pipefail

# C2: the xHTTP settings Remnawave and Xray-core send beyond the base set
# (uplink method, session, seq and uplink data placement and keys, chunk
# size, padding obfuscation, buffered posts, SSE header, session ID table
# and length) reach sing-box-extended from a share link's "extra" and from
# an Xray JSON subscription. A value sing-box-extended would refuse in that
# mode is left out, so one node never fails the whole configuration. With
# $PROKOP_TEST_SING_BOX_EXTENDED every result passes "sing-box check".

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
PARSER="$LIB/subscription/parser.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# link NAME MODE EXTRA_JSON: the outbound of a VLESS xHTTP share link.
link() {
  local extra
  extra="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$3")"
  ucode -L "$LIB" "$PARSER" share-link-outbound \
    "vless://00000000-0000-4000-8000-000000000001@x.example:443?security=tls&sni=x.example&type=xhttp&mode=$2&path=%2Fp&extra=$extra#N" \
    "$1" >"$WORK/$1.json" || fail "the $1 link was not parsed"
}
link full packet-up '{"xPaddingObfsMode":true,"xPaddingKey":"pad","xPaddingHeader":"X-Pad","xPaddingPlacement":"header",
  "xPaddingMethod":"tokenish","uplinkHTTPMethod":"get","sessionPlacement":"header","sessionKey":"X-S","seqPlacement":"query",
  "seqKey":"q","uplinkDataPlacement":"cookie","uplinkDataKey":"d","uplinkChunkSize":"1000-2000","scMaxBufferedPosts":30,
  "noSSEHeader":true,"sessionIDTable":"abcdef","sessionIDLength":"8-16"}'
# Nested the way Remnawave sends it, with values refused in stream-up mode.
link refused stream-up '{"xhttpSettings":{"extra":{"uplinkHTTPMethod":"GET","uplinkDataPlacement":"header",
  "sessionPlacement":"body","xPaddingPlacement":"path","xPaddingMethod":"zeros","sessionKey":"bad key",
  "uplinkChunkSize":"0-10","scMaxBufferedPosts":-1,"seqPlacement":"cookie"}}}'

cat >"$WORK/xray.json" <<'JSON'
[{"remarks":"Remna","outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"r.example","port":443,
 "users":[{"id":"00000000-0000-4000-8000-000000000002","encryption":"none"}]}]},
 "streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{"serverName":"r.example"},
 "xhttpSettings":{"mode":"stream-up","path":"/x","uplinkHTTPMethod":"PUT","sessionPlacement":"cookie","seqPlacement":"bogus",
  "scMaxBufferedPosts":"20","extra":{"noSSEHeader":true,"xPaddingMethod":"tokenish"}}}}]}]
JSON
ucode -L "$LIB" "$PARSER" normalize-content "$WORK/xray.json" "$WORK/xray.out" || fail "the Xray JSON was not parsed"

node - "$WORK" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const dir = process.argv[2];
const transport = (name) => JSON.parse(fs.readFileSync(`${dir}/${name}.json`, 'utf8')).transport;
const pick = (t, keys) => Object.fromEntries(keys.filter((k) => k in t).map((k) => [k, t[k]]));
const EXTENDED = ['uplink_http_method', 'session_placement', 'session_key', 'seq_placement', 'seq_key',
  'uplink_data_placement', 'uplink_data_key', 'uplink_chunk_size', 'x_padding_obfs_mode', 'x_padding_key',
  'x_padding_header', 'x_padding_placement', 'x_padding_method', 'sc_max_buffered_posts', 'no_sse_header',
  'session_id_table', 'session_id_length'];
assert.deepEqual(pick(transport('full'), EXTENDED), {
  uplink_http_method: 'GET', session_placement: 'header', session_key: 'X-S', seq_placement: 'query', seq_key: 'q',
  uplink_data_placement: 'cookie', uplink_data_key: 'd', uplink_chunk_size: '1000-2000', x_padding_obfs_mode: true,
  x_padding_key: 'pad', x_padding_header: 'X-Pad', x_padding_placement: 'header', x_padding_method: 'tokenish',
  sc_max_buffered_posts: 30, no_sse_header: true, session_id_table: 'abcdef', session_id_length: '8-16',
}, 'every setting of a packet-up link');
assert.deepEqual(pick(transport('refused'), EXTENDED), { seq_placement: 'cookie' },
  'refused values are left out, valid ones kept');
const xray = JSON.parse(fs.readFileSync(`${dir}/xray.out`, 'utf8'));
const out = (xray.outbounds || xray).find((o) => o.transport);
assert.deepEqual(pick(out.transport, EXTENDED), {
  uplink_http_method: 'PUT', session_placement: 'cookie', sc_max_buffered_posts: 20, no_sse_header: true,
  x_padding_method: 'tokenish',
}, 'the Xray JSON settings and their extra');
for (const [name, o] of [['full', JSON.parse(fs.readFileSync(`${dir}/full.json`, 'utf8'))],
  ['refused', JSON.parse(fs.readFileSync(`${dir}/refused.json`, 'utf8'))], ['xray', out]]) {
  // remark is Prokop's own field, which the generator strips.
  const { remark, ...outbound } = o;
  fs.writeFileSync(`${dir}/check-${name}.json`, JSON.stringify({ outbounds: [{ ...outbound, tag: 'x' }] }));
}
NODE

# SB-10: the generator leaves out the settings the running core does not
# read (sing-box-extended 1.6.0 brought most of them, 2.5.0 the session ID
# ones; sing-box refuses unknown fields, so one of them failed the whole
# configuration). An extended core of unknown version keeps only those of
# every xHTTP-capable core (1.1.0). Checked against the released 1.5.3,
# 2.4.1 and 2.7.2 binaries with "sing-box check".
extra='{"xPaddingObfsMode":true,"xPaddingKey":"pad","uplinkHTTPMethod":"get","sessionPlacement":"header","sessionKey":"X-S",
  "scMaxBufferedPosts":30,"noSSEHeader":true,"sessionIDTable":"abcdef","sessionIDLength":"8-16"}'
extra="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$extra")"
cat >"$WORK/manual.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [ { ".name": "xh", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": [ "vless://00000000-0000-4000-8000-000000000003@x.example:443?security=tls&sni=x.example&type=xhttp&mode=packet-up&path=%2Fp&extra=$extra#XH" ] } ]
}
JSON
generate() { # generate VERSION: the transport keys of the generated xHTTP outbound
  mkdir -p "$WORK/subscriptions" "$WORK/persistent"
  TMP_SUBSCRIPTION_FOLDER="$WORK/subscriptions" PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/persistent" \
    ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/manual.json" "$WORK/gen.json" 127.0.0.1 0 1 '' "$1" 2>"$WORK/gen.stderr" ||
    fail "the configuration for core '$1' was not generated: $(cat "$WORK/gen.stderr")"
  node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const t = c.outbounds.find((o) => o.transport && o.transport.type === "xhttp").transport;
    const keys = ["uplink_http_method", "session_placement", "session_key", "x_padding_obfs_mode", "x_padding_key",
      "sc_max_buffered_posts", "no_sse_header", "session_id_table", "session_id_length"];
    process.stdout.write(keys.filter((k) => k in t).join(" "));' "$WORK/gen.json"
}
all="uplink_http_method session_placement session_key x_padding_obfs_mode x_padding_key sc_max_buffered_posts no_sse_header session_id_table session_id_length"
[ "$(generate 1.14.1-extended-2.7.2)" = "$all" ] || fail "extended 2.7.2 lost xHTTP settings: $(generate 1.14.1-extended-2.7.2)"
[ "$(generate 1.13.14-extended-2.5.0)" = "$all" ] || fail "extended 2.5.0 lost xHTTP settings"
[ "$(generate 1.13.12-extended-2.4.1)" = "${all% session_id_table session_id_length}" ] ||
  fail "extended 2.4.1 got the session ID settings: $(generate 1.13.12-extended-2.4.1)"
grep -Fq "xHTTP settings of outbound 'xh-1-out' need a newer sing-box-extended and were left out: session_id_table, session_id_length" "$WORK/gen.stderr" ||
  fail "the left-out settings were not reported: $(cat "$WORK/gen.stderr")"
[ "$(generate 1.12.22-extended-1.6.0)" = "${all% session_id_table session_id_length}" ] ||
  fail "extended 1.6.0 lost settings it reads"
[ "$(generate 1.12.17-extended-1.5.3)" = "sc_max_buffered_posts no_sse_header" ] ||
  fail "extended 1.5.3 got settings it does not read: $(generate 1.12.17-extended-1.5.3)"
# Before 1.6.0 a range is "from-to" only: a plain number failed the check.
ranges() {
  node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const t = c.outbounds.find((o) => o.transport && o.transport.type === "xhttp").transport;
    process.stdout.write(JSON.stringify([t.x_padding_bytes, t.sc_max_each_post_bytes, t.sc_min_posts_interval_ms]));' "$WORK/gen.json"
}
[ "$(ranges)" = '["100-1000","1000000-1000000","30-30"]' ] || fail "extended 1.5.3 got ranges it cannot read: $(ranges)"
generate 1.12.22-extended-1.6.0 >/dev/null
[ "$(ranges)" = '["100-1000",1000000,30]' ] || fail "the ranges changed for extended 1.6.0: $(ranges)"
[ "$(generate '')" = "sc_max_buffered_posts no_sse_header" ] ||
  fail "an extended core of unknown version got settings it may not read: $(generate '')"

SBX="${PROKOP_TEST_SING_BOX_EXTENDED:-}"
if [ -z "$SBX" ] || [ ! -x "$SBX" ]; then
  printf 'xhttp_remnawave_settings: OK (real sing-box-extended not checked: set PROKOP_TEST_SING_BOX_EXTENDED)\n'
  exit 0
fi
for name in full refused xray; do
  "$SBX" check -c "$WORK/check-$name.json" >"$WORK/check.log" 2>&1 ||
    fail "sing-box-extended refused the $name outbound: $(cat "$WORK/check.log")"
done
echo "xhttp_remnawave_settings: OK"
