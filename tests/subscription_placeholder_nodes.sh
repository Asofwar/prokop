#!/usr/bin/env bash
set -euo pipefail

# R1 (rock12/FlowGate 448eb451, c0d78b83): pseudo nodes a panel sends for an
# expired subscription ("Subscription expired", address 0.0.0.0 or ::, any
# all-zero spelling) are dropped in every format and counted as placeholders
# in the parse losses, so the import summary says why. Loopback stays: it may
# be a real local server. subscription/parser.uc runs for real.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
PARSER="$LIB/subscription/parser.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
parse() { ucode -L "$LIB" "$PARSER" "$@"; }
uuid=00000000-0000-4000-8000-000000000060
b64() { printf '%s' "$1" | base64 -w0; }

vmess0="vmess://$(b64 "{\"v\":\"2\",\"ps\":\"vm0\",\"add\":\"0.0.0.0\",\"port\":\"443\",\"id\":\"$uuid\"}")"
ss0="ss://$(b64 'aes-128-gcm:pw')@[::]:8388#ss0"
cat >"$WORK/links.txt" <<EOF2
vless://$uuid@0.0.0.0:443?security=tls#Subscription%20expired
trojan://p@[::]:443#Traffic%20is%20over
trojan://p@[0:0:0:0:0:0:0:0]:443#zero6
hy2://p@000.0.0.0:443#zero4
socks5://[::ffff:0.0.0.0]:1080#mapped
$vmess0
$ss0
vless://$uuid@example.com:443?security=tls#Real
socks5://127.0.0.1:1080#Loopback
trojan://p@[::1]:443#Loopback6
vless://broken
EOF2
parse normalize-uri-list "$WORK/links.txt" "$WORK/links.json" || fail "the link list was refused"
[ "$(jq -c '[.skipped, .placeholders, [.outbounds[].tag]]' "$WORK/links.json")" = '[1,7,["Real","Loopback","Loopback6"]]' ] ||
  fail "links: $(jq -c '[.skipped, .placeholders, [.outbounds[].tag]]' "$WORK/links.json")"
msg="$(parse normalized-skipped-warning "$WORK/links.json")"
grep -Fq 'Skipped 1 invalid or unsupported subscription links' <<<"$msg" || fail "skipped message: $msg"
grep -Fq 'Skipped 7 placeholder entries with address 0.0.0.0 or ::' <<<"$msg" || fail "placeholder message: $msg"

# Base64 lists go the same way.
b64 "$(cat "$WORK/links.txt")" >"$WORK/links.b64"
parse normalize-content "$WORK/links.b64" "$WORK/b64.json" || fail "the base64 list was refused"
[ "$(jq -c '.placeholders' "$WORK/b64.json")" = 7 ] || fail "base64 list placeholders: $(cat "$WORK/b64.json")"

cat >"$WORK/clash.yaml" <<YAML
proxies:
  - { name: Expired, type: trojan, server: 0.0.0.0, port: 443, password: p }
  - { name: Over, type: vless, server: "::", port: 443, uuid: $uuid }
  - { name: Real, type: trojan, server: example.com, port: 443, password: p }
YAML
parse normalize-content "$WORK/clash.yaml" "$WORK/clash.json" || fail "the Clash YAML was refused"
[ "$(jq -c '[.skipped, .placeholders, [.outbounds[].tag]]' "$WORK/clash.json")" = '[0,2,["Real"]]' ] ||
  fail "clash: $(cat "$WORK/clash.json")"

# sing-box JSON: a node chained through a placeholder and a group left
# empty go too; a group keeps its real members.
cat >"$WORK/sb.json" <<JSON
{"outbounds":[
 {"type":"trojan","tag":"Expired","server":"0.0.0.0","server_port":443,"password":"p"},
 {"type":"trojan","tag":"Real","server":"example.com","server_port":443,"password":"p"},
 {"type":"trojan","tag":"Chained","server":"example.net","server_port":443,"password":"p","detour":"Expired"},
 {"type":"urltest","tag":"Auto","outbounds":["Expired","Real"]},
 {"type":"urltest","tag":"Dead","outbounds":["Expired"]}
]}
JSON
parse normalize-content "$WORK/sb.json" "$WORK/sb-out.json" || fail "the sing-box JSON was refused"
[ "$(jq -c '[.skipped, .placeholders, [.outbounds[] | .tag], ([.outbounds[] | select(.tag=="Auto")][0].outbounds)]' "$WORK/sb-out.json")" = \
  '[2,1,["Real","Auto"],["Real"]]' ] || fail "sing-box JSON: $(cat "$WORK/sb-out.json")"

# Xray JSON.
cat >"$WORK/xray.json" <<JSON
[{"remarks":"Expired","outbounds":[{"protocol":"vless","tag":"proxy",
  "settings":{"vnext":[{"address":"0.0.0.0","port":443,"users":[{"id":"$uuid"}]}]}}]},
 {"remarks":"Real","outbounds":[{"protocol":"vless","tag":"proxy",
  "settings":{"vnext":[{"address":"example.com","port":443,"users":[{"id":"$uuid"}]}]}}]}]
JSON
parse normalize-content "$WORK/xray.json" "$WORK/xray-out.json" || fail "the Xray JSON was refused"
[ "$(jq -c '[.placeholders, [.outbounds[] | select(.type=="vless") | .server]]' "$WORK/xray-out.json")" = '[1,["example.com"]]' ] ||
  fail "xray: $(cat "$WORK/xray-out.json")"

# A subscription of placeholders only is refused (the last working cache
# stays) and the module tells the cache why.
printf 'vless://%s@0.0.0.0:443?security=tls#Expired\n' "$uuid" >"$WORK/only.txt"
cat >"$WORK/only.uc" <<'UC'
let p = require("subscription.parser");
if (p.normalize_content_validated(ARGV[0], ARGV[1])) exit(1);
print(p.normalized_placeholders_only(), "\n");
UC
ucode -L "$LIB" "$WORK/only.uc" "$WORK/only.txt" "$WORK/only.json" >"$WORK/only.out" ||
  fail "a subscription of placeholders only was accepted"
[ "$(cat "$WORK/only.out")" = 1 ] || fail "placeholders-only count: $(cat "$WORK/only.out")"
grep -Fq 'returned only' "$LIB/subscription/cache.uc" || fail "the cache does not log a placeholders-only subscription"

# A manual link to a placeholder is skipped with that reason.
cat >"$WORK/manual.json" <<JSON
{ "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [ { ".name": "m", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": [ "trojan://p@0.0.0.0:443#Expired", "trojan://p@example.com:443#Real" ] } ] }
JSON
mkdir -p "$WORK/subs"
TMP_SUBSCRIPTION_FOLDER="$WORK/subs" PROKOP_SECTION_CACHE_DIR="$WORK/sc" \
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/manual.json" "$WORK/gen.json" 127.0.0.1 0 \
  2>"$WORK/gen.err" || fail "the manual configuration was not generated: $(cat "$WORK/gen.err")"
grep -Fq "its server address is 0.0.0.0 or ::" "$WORK/gen.err" || fail "manual placeholder reason: $(cat "$WORK/gen.err")"
jq -e '[.outbounds[] | select(.type=="trojan")] | length == 1 and .[0].server == "example.com"' "$WORK/gen.json" >/dev/null ||
  fail "manual outbounds: $(jq -c '[.outbounds[] | select(.type=="trojan")]' "$WORK/gen.json")"

printf 'subscription placeholder node checks passed\n'
