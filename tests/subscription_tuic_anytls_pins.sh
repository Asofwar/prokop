#!/usr/bin/env bash
set -euo pipefail

# R4 (cergo666/netshift bc5de4f0): TUIC (tuic://) and AnyTLS (anytls://)
# links, in manual links and subscriptions (link lists, base64, Clash YAML),
# become sing-box outbounds; a link that cannot be built is refused, the rest
# of the configuration still runs.
# Adjacent 9: certificate pins (pinSHA256, pcs, Clash fingerprint, Xray
# pinnedPeerCertSha256) become tls.certificate_sha256 on sing-box 1.15.0+,
# where they replace insecure. On an older core the pin is left out, with a
# warning, and the node runs as before pins were read: with the usual
# certificate verification, or without it only when its link asks. The
# dashboard learns which nodes run without verification.
# With $PROKOP_TEST_SING_BOX (1.14.x) the generated configuration passes
# "sing-box check".

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
PARSER="$LIB/subscription/parser.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
link() { ucode -L "$LIB" "$PARSER" share-link-outbound "$1" t; }
expect() { # expect <link> <jq> <value>
  local out got
  out="$(link "$1")" || fail "refused: $1"
  got="$(jq -c "$2" <<<"$out")"
  [ "$got" = "$3" ] || fail "$1: $2 is $got, expected $3"
}
refused() {
  if out="$(link "$1" 2>/dev/null)" && [ -n "$out" ]; then fail "$1 must be refused, got $out"; fi
}

U=11111111-2222-3333-4444-555555555555
HEX="$(printf 'a%.0s' {1..32} | od -An -v -tx1 | tr -d ' \n' | sed 's/../&:/g;s/:$//' | tr a-f A-F)"
B64="YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE="

# --- TUIC ---------------------------------------------------------------------------
T="tuic://$U:p%40ss@tuic.example.com:8443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=tuic.example.com&allow_insecure=1&fp=chrome&reduce_rtt=1#node"
expect "$T" '[.type,.server,.server_port,.uuid,.password,.congestion_control,.udp_relay_mode,.zero_rtt_handshake]' \
  "[\"tuic\",\"tuic.example.com\",8443,\"$U\",\"p@ss\",\"bbr\",\"native\",true]"
expect "$T" '.tls' '{"enabled":true,"server_name":"tuic.example.com","insecure":true,"alpn":["h3"]}'
expect "tuic://$U@t.example.com:443?congestion_control=weird&udp_relay_mode=odd" '[has("password"),has("congestion_control"),has("udp_relay_mode")]' '[false,false,false]'
refused "tuic://t.example.com:443"
refused "tuic://:pw@t.example.com:443"
refused "tuic://$U:pw@t.example.com"

# --- AnyTLS -------------------------------------------------------------------------
A="anytls://se%23cret@any.example.com:8443/?sni=any.example.com&insecure=1&alpn=h2,http/1.1&fp=chrome#node"
expect "$A" '[.type,.server,.server_port,.password]' '["anytls","any.example.com",8443,"se#cret"]'
expect "$A" '.tls' '{"enabled":true,"server_name":"any.example.com","insecure":true,"alpn":["h2","http/1.1"],"utls":{"enabled":true,"fingerprint":"chrome"}}'
expect "anytls://pw@any.example.com:443" '.tls' '{"enabled":true}'
refused "anytls://any.example.com:443"
refused "anytls://pw@any.example.com:443?security=none"

# --- pins -----------------------------------------------------------------------------
expect "hy2://p@h.example.com:443?pinSHA256=$HEX" '.tls.certificate_sha256' "[\"$B64\"]"
expect "trojan://p@h.example.com:443?pcs=$B64" '.tls.certificate_sha256' "[\"$B64\"]"
expect "vless://$U@h.example.com:443?security=tls&pcs=${HEX//:/},$B64" '.tls.certificate_sha256' "[\"$B64\",\"$B64\"]"
expect "tuic://$U:p@t.example.com:443?pinSHA256=${HEX//:/}" '.tls.certificate_sha256' "[\"$B64\"]"
expect "anytls://p@a.example.com:443?pinSHA256=${HEX//:/}&insecure=1" '.tls | [.certificate_sha256, .insecure]' "[[\"$B64\"],true]"
refused "hy2://p@h.example.com:443?pinSHA256=deadbeef"
refused "trojan://p@h.example.com:443?pcs=zzzz"
refused "tuic://$U:p@t.example.com:443?pinSHA256=abc"

# --- Clash YAML ---------------------------------------------------------------------
cat >"$WORK/clash.yaml" <<YAML
proxies:
  - { name: T, type: tuic, server: t.example.com, port: 443, uuid: $U, password: pw, alpn: [h3], congestion-controller: bbr, udp-relay-mode: quic, sni: t.example.com, skip-cert-verify: true, reduce-rtt: true }
  - { name: A, type: anytls, server: a.example.com, port: 443, password: pw, sni: a.example.com, client-fingerprint: chrome, idle-session-check-interval: 30, min-idle-session: 2, fingerprint: "$HEX" }
  - { name: Legacy, type: trojan, server: l.example.com, port: 443, password: pw, fingerprint: chrome }
  - { name: H, type: hysteria2, server: h.example.com, port: 443, password: pw, fingerprint: "${HEX//:/}" }
YAML
ucode -L "$LIB" "$PARSER" normalize-content "$WORK/clash.yaml" "$WORK/clash.json" || fail "the Clash YAML was refused"
node - "$WORK/clash.json" "$U" "$B64" <<'NODE'
const assert = require('node:assert/strict');
const [file, uuid, pin] = process.argv.slice(2);
const o = Object.fromEntries(JSON.parse(require('fs').readFileSync(file, 'utf8')).outbounds.map((x) => [x.tag, x]));
assert.deepEqual(o.T, { type: 'tuic', tag: 'T', server: 't.example.com', server_port: 443, uuid, password: 'pw',
  congestion_control: 'bbr', udp_relay_mode: 'quic', zero_rtt_handshake: true,
  tls: { enabled: true, server_name: 't.example.com', insecure: true, alpn: ['h3'] } });
assert.deepEqual(o.A, { type: 'anytls', tag: 'A', server: 'a.example.com', server_port: 443, password: 'pw',
  idle_session_check_interval: '30s', min_idle_session: 2,
  tls: { enabled: true, server_name: 'a.example.com', certificate_sha256: [pin], utls: { enabled: true, fingerprint: 'chrome' } } });
assert.deepEqual(o.Legacy.tls.utls, { enabled: true, fingerprint: 'chrome' }, 'a uTLS name in fingerprint stays one');
assert.equal(o.Legacy.tls.certificate_sha256, undefined);
assert.deepEqual(o.H.tls.certificate_sha256, [pin], 'a Hysteria2 fingerprint is a pin');
NODE

# Xray JSON pinnedPeerCertSha256; an unreadable one drops the node.
cat >"$WORK/xray.json" <<JSON
[{"remarks":"Pinned","outbounds":[{"protocol":"vless","tag":"proxy","settings":{"vnext":[{"address":"x.example.com","port":443,"users":[{"id":"$U"}]}]},
  "streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"x.example.com","pinnedPeerCertSha256":"${HEX//:/}"}}}]},
 {"remarks":"Bad","outbounds":[{"protocol":"vless","tag":"proxy","settings":{"vnext":[{"address":"y.example.com","port":443,"users":[{"id":"$U"}]}]},
  "streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"pinnedPeerCertSha256":"nope"}}}]}]
JSON
ucode -L "$LIB" "$PARSER" normalize-content "$WORK/xray.json" "$WORK/xray-out.json" || fail "the Xray JSON was refused"
[ "$(jq -c '[.outbounds[] | select(.type=="vless") | [.server, .tls.certificate_sha256]]' "$WORK/xray-out.json")" = "[[\"x.example.com\",[\"$B64\"]]]" ] ||
  fail "xray pins: $(cat "$WORK/xray-out.json")"

# A link list with TUIC and AnyTLS, plain and base64.
printf '%s\n%s\n' "$T" "$A" >"$WORK/list.txt"
base64 -w0 "$WORK/list.txt" >"$WORK/list.b64"
ucode -L "$LIB" "$PARSER" normalize-content "$WORK/list.b64" "$WORK/list.json" || fail "the base64 list was refused"
[ "$(jq -c '[.outbounds[].type]' "$WORK/list.json")" = '["tuic","anytls"]' ] || fail "list: $(cat "$WORK/list.json")"

# Share links of TUIC and AnyTLS read back the same; pins survive.
cat >"$WORK/roundtrip.uc" <<'UC'
let sl = require("subscription.share_link");
let p = require("subscription.parser");
for (let o in json(ARGV[0]).outbounds) {
    delete o.share_link;
    let link = sl.serialize_outbound_link(o);
    let back = p.parse_share_link(link);
    delete back.share_link;
    if (sprintf("%J", back) != sprintf("%J", o)) {
        warn("round trip differs: ", sprintf("%J", o), " -> ", sprintf("%J", back), "\n");
        exit(1);
    }
}
UC
cat >"$WORK/rt.json" <<JSON
{"outbounds":[
 {"type":"tuic","tag":"t1","server":"t.example.com","server_port":443,"uuid":"$U","password":"p:w","congestion_control":"bbr","udp_relay_mode":"native","zero_rtt_handshake":true,"tls":{"enabled":true,"server_name":"t.example.com","insecure":true,"disable_sni":true,"alpn":["h3"],"certificate_sha256":["$B64"]}},
 {"type":"anytls","tag":"a1","server":"a.example.com","server_port":443,"password":"p#w","tls":{"enabled":true,"server_name":"a.example.com","certificate_sha256":["$B64"],"alpn":["h2"],"utls":{"enabled":true,"fingerprint":"chrome"}}}
]}
JSON
ucode -L "$LIB" "$WORK/roundtrip.uc" "$(cat "$WORK/rt.json")" || fail "the TUIC/AnyTLS share link round trip changed the node"
ucode -L "$LIB" -e 'let sl = require("subscription.share_link"); exit(sl.is_copyable_link("anytls://x@y:1") ? 0 : 1);' ||
  fail "anytls links are not copyable"

# --- generator ------------------------------------------------------------------------
mkdir -p "$WORK/subs"
cat >"$WORK/subs/proxy-subscription-1.json" <<JSON
{"version":1,"format":"sing-box-json","outbounds":[
 {"type":"tuic","tag":"SubTuic","server":"t.example.com","server_port":443,"uuid":"$U","password":"pw","tls":{"enabled":true,"server_name":"t.example.com","alpn":["h3"],"utls":{"enabled":true,"fingerprint":"chrome"}}},
 {"type":"anytls","tag":"SubAny","server":"a.example.com","server_port":443,"password":"pw","tls":{"enabled":true,"server_name":"a.example.com","insecure":true}},
 {"type":"trojan","tag":"SubPinned","server":"p.example.com","server_port":443,"password":"pw","tls":{"enabled":true,"server_name":"p.example.com","certificate_sha256":["$B64"]}},
 {"type":"trojan","tag":"SubPinnedInsecure","server":"q.example.com","server_port":443,"password":"pw","tls":{"enabled":true,"insecure":true,"certificate_sha256":["$B64"]}}
]}
JSON
printf '%s' 'https://example.com/sub' >"$WORK/subs/proxy-subscription-1.url"
printf '%s' 'Happ' >"$WORK/subs/proxy-subscription-1.user_agent"
cat >"$WORK/fixture.json" <<JSON
{ "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [ { ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection",
    "subscription_urls": [ "https://example.com/sub" ],
    "selector_proxy_links": [
      "$T",
      "$A",
      "hy2://p@h.example.com:443?pinSHA256=$HEX#ManualPinned",
      "trojan://p@m.example.com:443?pcs=$B64&allowInsecure=1#ManualPinnedInsecure"
    ] } ] }
JSON
generate() { # generate VERSION
  TMP_SUBSCRIPTION_FOLDER="$WORK/subs" PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/persistent" \
    ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/gen-$1.json" 127.0.0.1 0 1 '' "$1" \
    2>"$WORK/gen-$1.err" || fail "core $1: not generated: $(cat "$WORK/gen-$1.err")"
}
summary() { # name:has-pin:insecure for each server outbound
  jq -r '[.outbounds[] | select(.server != null) | "\(.server):\(.tls.certificate_sha256 != null):\(.tls.insecure == true)"] | join(" ")' "$WORK/gen-$1.json"
}
generate 1.14.2
# 1.14: no pin anywhere; pinned nodes without insecure stay, verified as usual.
[ "$(summary 1.14.2)" = "tuic.example.com:false:true any.example.com:false:true h.example.com:false:false m.example.com:false:true t.example.com:false:false a.example.com:false:true p.example.com:false:false q.example.com:false:true" ] ||
  fail "1.14.2: $(summary 1.14.2)"
grep -Fq "certificate pin of 'ManualPinned' left out: it needs sing-box 1.15.0 or newer; the node connects with the usual certificate verification" \
  "$WORK/gen-1.14.2.err" || fail "the unenforced manual pin was not reported: $(cat "$WORK/gen-1.14.2.err")"
grep -Fq "certificate pin of 'SubPinned' left out: it needs sing-box 1.15.0 or newer; the node connects with the usual certificate verification" \
  "$WORK/gen-1.14.2.err" || fail "the unenforced subscription pin was not reported"
grep -Fq "certificate pin of 'SubPinnedInsecure' left out: it needs sing-box 1.15.0 or newer; the node skips certificate verification" \
  "$WORK/gen-1.14.2.err" || fail "the dropped pin was not reported"
if grep -Fq "skipped" "$WORK/gen-1.14.2.err"; then fail "a pinned node was skipped: $(cat "$WORK/gen-1.14.2.err")"; fi
# The dashboard says one subscription pin is not enforced (SubPinned; the
# insecure one is marked as unverified instead).
jq -e '[.subscriptionNotices[] | select(.kind == "certificate_pin") | .count] == [1]' \
  "$WORK/gen-1.14.2.json.section-cache/proxy.json" >/dev/null ||
  fail "no unenforced-pin notice: $(jq -c .subscriptionNotices "$WORK/gen-1.14.2.json.section-cache/proxy.json")"
jq -e '[.outbounds[] | select(.type=="tuic") | .tls.utls] | all(. == null)' "$WORK/gen-1.14.2.json" >/dev/null || fail "TUIC kept uTLS"
node -e '
  const fs = require("fs");
  const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const s = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const tags = c.outbounds.filter((o) => o.tls && o.tls.insecure).map((o) => o.tag).sort();
  const marked = Object.keys(s.outboundMetadata.insecure || {}).sort();
  if (JSON.stringify(tags) !== JSON.stringify(marked)) { console.error("insecure marks", tags, marked); process.exit(1); }
  if (!Object.values(s.outboundMetadata.protocols).includes("tuic")) { console.error("no tuic protocol"); process.exit(1); }
' "$WORK/gen-1.14.2.json" "$WORK/gen-1.14.2.json.section-cache/proxy.json" || fail "the section cache does not mark the insecure nodes"

generate 1.15.0
[ "$(summary 1.15.0)" = "tuic.example.com:false:true any.example.com:false:true h.example.com:true:false m.example.com:true:false t.example.com:false:false a.example.com:false:true p.example.com:true:false q.example.com:true:false" ] ||
  fail "1.15.0: $(summary 1.15.0)"
jq -e '[.subscriptionNotices[]? | select(.kind == "certificate_pin")] == []' \
  "$WORK/gen-1.15.0.json.section-cache/proxy.json" >/dev/null || fail "1.15.0 must not report unenforced pins"
generate 1.15.0-alpha.3
[ "$(summary 1.15.0-alpha.3)" = "$(summary 1.14.2)" ] || fail "a 1.15.0 pre-release must not take pins: $(summary 1.15.0-alpha.3)"
generate ''
[ "$(summary '')" = "$(summary 1.14.2)" ] || fail "an unknown core must not take pins: $(summary '')"

SB="${PROKOP_TEST_SING_BOX:-}"
if [ -z "$SB" ] || [ ! -x "$SB" ]; then
  printf 'subscription TUIC/AnyTLS/pin checks passed (sing-box check skipped: set PROKOP_TEST_SING_BOX)\n'
  exit 0
fi
"$SB" check -c "$WORK/gen-1.14.2.json" >"$WORK/check.log" 2>&1 || fail "sing-box refused the configuration: $(cat "$WORK/check.log")"
# The Clash and link outbounds alone, too.
jq '{outbounds: ([.outbounds[] | del(.share_link) | .tag = ("o" + (.server_port|tostring) + .type + (.server))] )}' "$WORK/clash.json" \
  | jq '.outbounds |= map(if .tls.certificate_sha256 then del(.tls.certificate_sha256) else . end)' >"$WORK/clash-check.json"
"$SB" check -c "$WORK/clash-check.json" >"$WORK/check.log" 2>&1 || fail "sing-box refused the Clash outbounds: $(cat "$WORK/check.log")"
printf 'subscription TUIC/AnyTLS/pin checks passed (with sing-box check)\n'
