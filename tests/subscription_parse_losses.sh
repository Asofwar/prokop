#!/usr/bin/env bash
set -euo pipefail

# Nodes that were built wrong instead of refused (SB-9): socks5h:// became
# version "5h", which sing-box rejects; kcp, quic and other transports
# sing-box has no equivalent of were silently sent over plain TCP; the
# splithttp name of XHTTP was lost; the uTLS fingerprints random and qq were
# rewritten to chrome.
#
# subscription/parser.uc runs for real.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

outbound() {
  ucode -L "$LIB" "$LIB/subscription/parser.uc" share-link-outbound "$1" t
}
expect() { # expect <link> <jq filter> <value>
  local out got
  out="$(outbound "$1")" || fail "the link $1 was refused"
  got="$(jq -r "$2" <<<"$out")"
  [ "$got" = "$3" ] || fail "$1: $2 is '$got', expected '$3'"
}
refused() {
  local out=""
  if out="$(outbound "$1" 2>/dev/null)" && [ -n "$out" ] && [ "$out" != null ]; then
    fail "$1 must be refused, got $out"
  fi
}

uuid=00000000-0000-4000-8000-000000000050
expect 'socks5h://user:pass@example.com:1080' .version 5
expect 'socks5h://user:pass@example.com:1080' .username user
expect 'socks4a://example.com:1080' .version 4a

expect "vless://$uuid@example.com:443?type=splithttp&path=%2Fx&security=tls" .transport.type xhttp
expect "vless://$uuid@example.com:443?type=splithttp&path=%2Fx&security=tls" .transport.path /x
expect "vless://$uuid@example.com:443?type=raw&security=tls" '.transport // "none"' none
expect "vless://$uuid@example.com:443?type=ws&path=%2Fws&security=tls" .transport.type ws
refused "vless://$uuid@example.com:443?type=kcp&security=tls"
refused "trojan://secret@example.com:443?type=quic"
vmess_kcp="vmess://$(printf '{"v":"2","ps":"k","add":"example.com","port":"443","id":"%s","net":"kcp"}' "$uuid" | base64 -w0)"
refused "$vmess_kcp"
vmess_ws="vmess://$(printf '{"v":"2","ps":"w","add":"example.com","port":"443","id":"%s","net":"ws","path":"/w"}' "$uuid" | base64 -w0)"
expect "$vmess_ws" .transport.type ws

expect "vless://$uuid@example.com:443?security=tls&fp=random" .tls.utls.fingerprint random
expect "vless://$uuid@example.com:443?security=tls&fp=qq" .tls.utls.fingerprint qq
expect "vless://$uuid@example.com:443?security=tls&fp=nonsense" .tls.utls.fingerprint chrome

# Clash: a network with no builder drops the node (http, V2Ray's HTTP
# header obfuscation of TCP; h2 is built since SB-13), ws still works.
cat >"$WORK_DIR/clash.yaml" <<YAML
proxies:
  - { name: HTTP node, type: vless, server: example.com, port: 443, uuid: $uuid, network: http, tls: true }
  - { name: WS node, type: vless, server: example.com, port: 443, uuid: $uuid, network: ws, tls: true, ws-opts: { path: /ws } }
  - { name: TCP node, type: trojan, server: example.com, port: 443, password: secret }
YAML
ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-clash-yaml "$WORK_DIR/clash.yaml" "$WORK_DIR/clash.json" ||
  fail "the Clash YAML must be normalized"
tags="$(jq -r '[.outbounds[].tag] | join(",")' "$WORK_DIR/clash.json")"
[ "$tags" = "WS node,TCP node" ] || fail "Clash http node must be skipped, got tags '$tags'"

# Xray JSON: a kcp stream drops the node, splithttp keeps it as XHTTP.
cat >"$WORK_DIR/xray.json" <<JSON
[
  { "remarks": "KCP", "outbounds": [ { "protocol": "vless", "tag": "proxy",
    "settings": { "vnext": [ { "address": "example.com", "port": 443, "users": [ { "id": "$uuid" } ] } ] },
    "streamSettings": { "network": "kcp" } } ] },
  { "remarks": "Split", "outbounds": [ { "protocol": "vless", "tag": "proxy",
    "settings": { "vnext": [ { "address": "example.com", "port": 443, "users": [ { "id": "$uuid" } ] } ] },
    "streamSettings": { "network": "splithttp", "splithttpSettings": { "path": "/sp" } } } ] }
]
JSON
ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-content "$WORK_DIR/xray.json" "$WORK_DIR/xray-out.json" ||
  fail "the Xray JSON must be normalized"
jq -e '[.outbounds[] | select(.type == "vless")] | length == 1' "$WORK_DIR/xray-out.json" >/dev/null ||
  fail "the Xray kcp node must be skipped: $(cat "$WORK_DIR/xray-out.json")"
jq -e '[.outbounds[] | select(.type == "vless")][0].transport | .type == "xhttp" and .path == "/sp"' \
  "$WORK_DIR/xray-out.json" >/dev/null ||
  fail "the Xray splithttp node must become XHTTP: $(cat "$WORK_DIR/xray-out.json")"

printf 'subscription parse loss checks passed\n'
