#!/usr/bin/env bash
set -euo pipefail

# Clash YAML block entries read as their flow-style form (SB-4). An inline
# map in a block entry ('reality-opts: {public-key: ...}', as mihomo and
# subconverter write it) was kept as one opaque value: a REALITY node
# became plain TLS. A comment after a value ('password: abc # old') became
# part of it. Both nodes were written without an error and never connected.
#
# subscription/parser.uc runs for real.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/out.json" ] || sed 's/^/  parsed: /' "$WORK/out.json" >&2
  exit 1
}

cat >"$WORK/in.yaml" <<'YAML'
proxies:
  - name: reality-block
    type: vless
    server: example.com
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    network: tcp
    tls: true
    servername: www.example.org
    client-fingerprint: chrome
    reality-opts: {public-key: AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg, short-id: 0123abcd}
  - name: commented # the old one
    type: trojan
    server: example.net # main server
    port: 443
    password: abc # rotated monthly
    sni: "x#y.example.net"
  - name: hash-in-password
    type: trojan
    server: example.org
    port: 443
    password: a#b
YAML
ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-clash-yaml "$WORK/in.yaml" "$WORK/out.json" ||
  fail "the Clash YAML was refused"
node() { jq -c --arg tag "$1" '.outbounds[] | select(.tag == $tag)' "$WORK/out.json"; }

[ "$(node reality-block | jq -r '.tls.reality.public_key')" = AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg ] ||
  fail "the inline reality-opts of a block entry were lost"
[ "$(node reality-block | jq -r '.tls.reality.short_id')" = 0123abcd ] || fail "the REALITY short id was lost"
[ "$(node commented | jq -r '.password')" = abc ] || fail "a comment became part of the password"
[ "$(node commented | jq -r '.server')" = example.net ] || fail "a comment became part of the server"
[ "$(node commented | jq -r '.tls.server_name')" = 'x#y.example.net' ] || fail "a '#' inside quotes was taken for a comment"
[ "$(node hash-in-password | jq -r '.password')" = 'a#b' ] || fail "a '#' inside a value was taken for a comment"

# SB-13: quotes as YAML reads them. In single quotes '' is one quote (and
# '#' inside them no comment); in double quotes a backslash escapes; an
# apostrophe inside a plain value opens no quote. Clash network h2 and
# vmess httpupgrade build the sing-box transports they are.
cat >"$WORK/in.yaml" <<'YAML'
proxies:
  - name: 'it''s single'
    type: trojan
    server: example.com
    port: 443
    password: 'it''s #x' # comment
  - {name: "dq \"x\" \u263a", type: trojan, server: example.com, port: 443, password: "q\"x\\y", sni: 'a''b'}
  - {name: Bob's plain, type: trojan, server: example.com, port: 443, password: p'q}
  - name: h2-node
    type: vless
    server: example.com
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    tls: true
    network: h2
    h2-opts: {host: [h2.example.com, 'b.example.com'], path: /h2}
YAML
ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-clash-yaml "$WORK/in.yaml" "$WORK/out.json" ||
  fail "the Clash YAML with quotes was refused"
[ "$(node "it's single" | jq -r '.password')" = "it's #x" ] || fail "a single-quoted value with '' was cut"
[ "$(node 'dq "x" ☺' | jq -r '.password')" = 'q"x\y' ] || fail "the escapes of a double-quoted value were not read"
[ "$(node 'dq "x" ☺' | jq -r '.tls.server_name')" = "a'b" ] || fail "a single-quoted value in a flow map was not unquoted"
[ "$(node "Bob's plain" | jq -r '.password')" = "p'q" ] || fail "an apostrophe in a plain value opened a quote"
[ "$(node h2-node | jq -c '.transport')" = '{"type":"http","path":"/h2","host":["h2.example.com","b.example.com"]}' ] ||
  fail "the Clash h2 network was not built"
vmess="vmess://$(printf '%s' '{"v":"2","ps":"hu","add":"example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","net":"httpupgrade","path":"/u","host":"u.example.com","tls":"tls"}' | base64 -w0)"
ucode -L "$LIB" "$LIB/subscription/parser.uc" share-link-outbound "$vmess" hu >"$WORK/hu.json" ||
  fail "a vmess httpupgrade link was refused"
[ "$(jq -c '.transport' "$WORK/hu.json")" = '{"type":"httpupgrade","path":"/u","host":"u.example.com"}' ] ||
  fail "the vmess httpupgrade transport was not built: $(cat "$WORK/hu.json")"

printf 'clash yaml block entry checks passed\n'
