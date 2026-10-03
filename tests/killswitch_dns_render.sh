#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
WORK_DIR="$(mktemp -d)"
OUT="$WORK_DIR/blocked.servers"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  cat "$OUT" >&2 2>/dev/null || true
  exit 1
}

has_line() {
  grep -Fqx -- "$1" "$OUT" || fail "$2: expected line '$1'"
}

lacks() {
  if grep -Fq -- "$1" "$OUT"; then
    fail "$2: unexpected '$1'"
  fi
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/cache"
cat >"$WORK_DIR/bin/sing-box" <<'SB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SB_LOG:?}"
[ "$1" = "rule-set" ] && [ "$2" = "decompile" ] || exit 2
[ "${SB_DECOMPILE_FAIL:-0}" = "1" ] && exit 1
cat > "$5" <<'JSON'
{"version":3,"rules":[
 {"domain_suffix":["Russia.Example","ru-site.example"],"domain":["exact.example"]},
 {"type":"logical","mode":"or","rules":[{"domain_suffix":["logical.example"]},{"domain_keyword":["kw"]}]},
 {"domain_suffix":["inverted.example"],"invert":true},
 {"domain_regex":["^a.*"],"ip_cidr":["9.9.9.0/24"]}
]}
JSON
SB
chmod 0755 "$WORK_DIR/bin/sing-box"
printf 'binary-list' > "$WORK_DIR/list.srs"
cat >"$WORK_DIR/source.json" <<'JSON'
{"version":3,"rules":[{"domain_suffix":["source-list.example"]}]}
JSON

cat >"$WORK_DIR/config.json" <<JSON
{
  "route": {
    "rules": [
      { "action": "sniff", "inbound": [ "tproxy-in" ] },
      { "action": "hijack-dns", "protocol": "dns" },
      { "action": "route", "inbound": [ "tproxy-in" ], "outbound": "Zapret-out", "domain": [ "ip.podkop.fyi" ] },
      { "action": "route-options", "domain": [ "fakeip.podkop.fyi" ], "override_port": 80 },
      { "action": "route", "inbound": [ "tproxy-in" ], "outbound": "Zapret-out", "domain_suffix": [ "youtube.com" ], "source_ip_cidr": [ "192.168.1.222" ] },
      { "action": "route", "inbound": [ "tproxy-in" ], "outbound": "bypass-out", "domain_suffix": [ "drive.google.com", "bypassed.example" ] },
      { "action": "route", "inbound": [ "tproxy-in" ], "outbound": "Zapret2-out", "domain_suffix": [ "port-limited.google.com" ], "port": [ 443 ] },
      { "action": "route", "inbound": [ "tproxy-in" ], "outbound": "main-out", "domain_suffix": [ "google.com", "youtube.com", "bypassed.example", "sub.bypassed.example", "bad/domain" ] },
      { "action": "route", "inbound": [ "tproxy-in" ], "outbound": "main-out", "rule_set": [ "main-list", "main-source", "inline-set" ] },
      { "action": "route", "inbound": [ "tproxy-in" ], "outbound": "other-out", "domain_suffix": [ "mail.google.com" ] },
      { "action": "reject", "inbound": [ "tproxy-in" ], "rule_set": "ads" },
      { "action": "route", "inbound": [ "tproxy-in" ], "outbound": "late-out", "domain_suffix": [ "late.example" ], "domain_keyword": [ "late" ] },
      { "action": "route", "inbound": [ "tproxy-in" ], "outbound": "late-out", "domain_suffix": [ "kids.example" ], "source_ip_cidr": [ "192.168.1.30" ] }
    ],
    "rule_set": [
      { "tag": "main-list", "type": "local", "format": "binary", "path": "$WORK_DIR/list.srs" },
      { "tag": "main-source", "type": "local", "format": "source", "path": "$WORK_DIR/source.json" },
      { "tag": "inline-set", "type": "inline", "rules": [ { "domain_suffix": [ ".inline.example." ] } ] },
      { "tag": "ads", "type": "remote", "url": "https://example.invalid/ads.srs" }
    ]
  }
}
JSON

export PATH="$WORK_DIR/bin:$PATH"
export SB_LOG="$WORK_DIR/sb.log"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"

ks() {
  ucode -L "$PROKOP_LIB" "$KS_UC" "$@"
}

summary="$(ks render-dns-fixture "$WORK_DIR/config.json" "main,late" "$OUT")" || fail "render failed: $summary"

# Protected domains, including every list kind, normalised.
has_line "server=/google.com/" "inline suffix"
has_line "server=/russia.example/" "decompiled binary list, lower-cased"
has_line "server=/exact.example/" "exact names are blocked with their subdomains"
has_line "server=/logical.example/" "logical rule children"
has_line "server=/source-list.example/" "source rule-set"
has_line "server=/inline.example/" "inline rule-set, dots trimmed"
has_line "server=/late.example/" "second protected section"
lacks "inverted.example" "inverted matchers are not blocked"
lacks "bad/domain" "invalid names never reach dnsmasq"
lacks "ip.podkop.fyi" "unprotected rules are not blocked"

# First-match order.
lacks "server=/bypassed.example/" "a name shadowed by an earlier unrestricted bypass suffix is not blocked"
lacks "server=/sub.bypassed.example/" "a subdomain of an earlier bypass suffix is not blocked"
has_line "server=/drive.google.com/#" "earlier unrestricted bypass below a protected suffix becomes an exception"
has_line "server=/youtube.com/" "an earlier client-restricted Zapret rule does not weaken the block"
lacks "port-limited.google.com" "an earlier port-restricted rule does not create an exception"
lacks "mail.google.com" "a later unprotected rule cannot carve out an exception"

printf '%s' "$summary" | grep -Fq '"uncovered_keyword": 2' || fail "keywords must be reported as uncovered: $summary"
printf '%s' "$summary" | grep -Fq '"uncovered_regex": 1' || fail "regex must be reported as uncovered: $summary"
printf '%s' "$summary" | grep -Fq '"uncovered_inverted": 1' || fail "inverted matchers must be reported: $summary"
printf '%s' "$summary" | grep -Fq '"invalid": 1' || fail "invalid names must be counted: $summary"
lacks "kids.example" "a client-limited protected rule must not block its names for every client"
printf '%s' "$summary" | grep -Fq '"client_limited": 1' || fail "client-limited names must be reported: $summary"

# The decompiled list is cached by content and reused.
[ "$(wc -l < "$SB_LOG")" -eq 1 ] || fail "binary rule-set must be decompiled once"
ks render-dns-fixture "$WORK_DIR/config.json" "main" "$WORK_DIR/second.servers" >/dev/null || fail "second render failed"
[ "$(wc -l < "$SB_LOG")" -eq 1 ] || fail "cached rule-set must not be decompiled again"
ls "$WORK_DIR/cache"/*.json >/dev/null 2>&1 || fail "decompile cache must exist"

# A protected list that cannot be read fails the render instead of shrinking the block list.
rm -f "$WORK_DIR/cache"/*.json
if SB_DECOMPILE_FAIL=1 ks render-dns-fixture "$WORK_DIR/config.json" "main" "$WORK_DIR/fail.servers" >"$WORK_DIR/fail.json"; then
  fail "an unreadable protected rule-set must fail the DNS render"
fi
grep -Fq 'could not decompile' "$WORK_DIR/fail.json" || fail "decompile failure must be reported"
[ ! -e "$WORK_DIR/fail.servers" ] || fail "failed render must not write a block list"

# A list that was never downloaded is unknown, not empty.
printf '{"version":1,"rules":[]}\n' > "$WORK_DIR/empty-0123456789ab.json"
sed "s#$WORK_DIR/source.json#$WORK_DIR/empty-0123456789ab.json#" "$WORK_DIR/config.json" > "$WORK_DIR/placeholder.json"
if ks render-dns-fixture "$WORK_DIR/placeholder.json" "main" "$WORK_DIR/placeholder.servers" >"$WORK_DIR/placeholder.out"; then
  fail "a protected rule-set placeholder must not shrink the block list"
fi
grep -Fq 'not downloaded yet' "$WORK_DIR/placeholder.out" || fail "placeholder must be reported"

# Device scoping in a real generated config (UC-193). The generator wraps
# every route rule of a section with excluded devices as a logical "and" of
# its conditions and the inverted excluded sources.
GEN_DIR="$WORK_DIR/generated"
mkdir -p "$GEN_DIR"
printf '{"version":3,"rules":[{"domain_suffix":["first-list.example"]}]}\n' > "$GEN_DIR/first.json"
printf '{"version":3,"rules":[{"domain_suffix":["second-list.example"]}]}\n' > "$GEN_DIR/second.json"
printf '{"version":3,"rules":[{"domain_suffix":["device-list.example"]}]}\n' > "$GEN_DIR/device.json"
outbound_json() {
  printf '{\\"type\\":\\"http\\",\\"tag\\":\\"%s\\",\\"server\\":\\"proxy.example\\",\\"server_port\\":8080}' "$1"
}
cat >"$GEN_DIR/fixture.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8" },
  "section": [
    { ".name": "byp", ".type": "section", "enabled": "1", "action": "bypass",
      "domain_suffix": [ "sub.excl-inline.example" ], "excluded_source_ip_cidr": [ "192.168.1.60/32" ] },
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json a)" ],
      "domain_suffix": [ "main-inline.example" ], "rule_set": [ "$GEN_DIR/first.json" ] },
    { ".name": "excl", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json b)" ],
      "domain_suffix": [ "excl-inline.example" ], "rule_set": [ "$GEN_DIR/second.json" ],
      "excluded_source_ip_cidr": [ "192.168.1.50/32" ] },
    { ".name": "devlim", ".type": "section", "enabled": "1", "action": "connection", "kill_switch": "1",
      "outbound_jsons": [ "$(outbound_json c)" ],
      "domain_suffix": [ "device-only.example" ], "rule_set": [ "$GEN_DIR/device.json" ],
      "source_ip_cidr": [ "192.168.1.0/28" ], "excluded_source_ip_cidr": [ "192.168.1.5/32" ] }
  ]
}
JSON
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$GEN_DIR/fixture.json" "$GEN_DIR/config.json" 192.168.1.1 0 1 '' 1.13.0 ||
  fail "the generator fixture could not be generated"
grep -Fq '"invert": true' "$GEN_DIR/config.json" || fail "the generator must wrap rules of sections with excluded devices"

OUT="$GEN_DIR/blocked.servers"
summary="$(ks render-dns-fixture "$GEN_DIR/config.json" "main,excl,devlim" "$OUT")" || fail "generated render failed: $summary"
section_value() {
  ucode -e 'let s = json(ARGV[0]); print(s.sections[ARGV[1]][ARGV[2]] ?? "null", "\n");' -- "$summary" "$1" "$2"
}
has_line "server=/main-inline.example/" "plain protected section"
has_line "server=/first-list.example/" "rule-set of a plain protected section"
has_line "server=/excl-inline.example/" "inline names of a section with excluded devices"
has_line "server=/second-list.example/" "rule-set of a section with excluded devices"
lacks "device-only.example" "a device-scoped section with excluded devices must not block its names for every client"
lacks "device-list.example" "a device-scoped section's rule-set must not be blocked for every client"
lacks "server=/sub.excl-inline.example/#" "a bypass rule with excluded devices is restricted and never an exception"
[ "$(section_value excl domains)" = 2 ] || fail "the section with excluded devices must count both names: $summary"
[ "$(section_value excl excluded_devices)" = 2 ] ||
  fail "names also blocked for the excluded devices must be reported: $summary"
[ "$(section_value main excluded_devices)" = 0 ] || fail "a section without exclusions has no excluded devices: $summary"
[ "$(section_value devlim domains)" = 0 ] || fail "a device-scoped section blocks no names through DNS: $summary"
[ "$(section_value devlim client_limited)" = 2 ] ||
  fail "both names of the device-scoped section must be reported as client-limited: $summary"

printf 'killswitch_dns_render: PASS\n'
