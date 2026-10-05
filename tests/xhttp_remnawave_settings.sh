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
