#!/usr/bin/env bash
set -euo pipefail

# The generated route rules sing-box gets for both transparent proxy
# inbounds and for port conditions the rule editor accepts:
#   - sniffing and the QUIC reject of disable_quic cover tproxy6-in as well as
#     tproxy-in: every section rule takes both, so an IPv6 connection (a
#     FakeIP6 answer, a real IPv6 address) is sniffed and its QUIC rejected
#     like an IPv4 one (UC-097);
#   - a single-port range 'N-N', which the editor and the validator accept,
#     is the port N, never a port_range item without ':' that sing-box
#     refuses ("bad port range"), aborting the reload (UC-098);
#   - a keyword is generated in lower case: sing-box compares a keyword with
#     the lower-cased domain as written, so 'YouTube' never matched (UC-099).
# With a sing-box binary ($FORKOP_TEST_SING_BOX, else sing-box on PATH, else
# the versions in $FORKOP_TEST_SING_BOX_DIRS) the generated config must also
# pass "sing-box check".

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

generate() { # fixture output
  mkdir -p "$2.section-cache"
  TMP_SUBSCRIPTION_FOLDER="$WORK/subs" ucode -L "$LIB" "$LIB/singbox/generator.uc" \
    generate-config-fixture "$1" "$2" 127.0.0.1 0 >/dev/null 2>"$2.err" ||
    fail "the generator refused $(basename "$1"): $(cat "$2.err")"
}

fixture() { # name disable_quic
  cat >"$WORK/$1.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn", "disable_quic": "$2",
    "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret" },
  "section": [
    { ".name": "single", ".type": "section", "enabled": "1", "action": "bypass",
      "domain_keyword": [ "YouTube" ], "ports": [ "443-443", "8000-8080", "80", "80-80" ] },
    { ".name": "text", ".type": "section", "enabled": "1", "action": "block",
      "domain_suffix": [ "example.org" ], "ports_text": "8443-8443, 9000-9001" }
  ]
}
JSON
}

fixture quic 1
fixture noquic 0
generate "$WORK/quic.json" "$WORK/quic.config"
generate "$WORK/noquic.json" "$WORK/noquic.config"

node - "$WORK/quic.config" "$WORK/noquic.config" <<'NODE' || failures=$((failures + 1))
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [quic, noquic] = process.argv.slice(2).map((f) => JSON.parse(fs.readFileSync(f, 'utf8')));
const list = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
const both = (rule) => list(rule.inbound).includes('tproxy-in') && list(rule.inbound).includes('tproxy6-in');

for (const [name, config] of [['disable_quic=1', quic], ['disable_quic=0', noquic]]) {
  const rules = config.route.rules;
  const sniff = rules.find((r) => r.action === 'sniff');
  assert.ok(sniff && both(sniff), `${name}: sniffing covers tproxy-in and tproxy6-in: ${JSON.stringify(sniff)}`);
  assert.ok(list(sniff.inbound).includes('dns-in'), `${name}: the DNS inbound is still sniffed`);
  const sections = rules.filter((r) => r.outbound === 'bypass-out' || (r.action === 'reject' && r.domain_suffix));
  assert.equal(sections.length, 2, `${name}: both section rules generated`);
  for (const r of sections) assert.ok(both(r), `${name}: section rule takes both inbounds`);

  // UC-098: no port_range item without ':'; 'N-N' is the port N.
  for (const r of rules)
    for (const range of list(r.port_range))
      assert.match(range, /^[0-9]*:[0-9]*$/, `${name}: port_range item '${range}' is a sing-box range`);
  const single = rules.find((r) => r.outbound === 'bypass-out');
  assert.deepEqual([...list(single.port)].sort((a, b) => a - b), [80, 443], `${name}: 443-443 and 80-80 are ports`);
  assert.deepEqual(list(single.port_range), ['8000:8080'], `${name}: the real range stays a range`);
  const text = rules.find((r) => r.action === 'reject' && r.domain_suffix);
  assert.deepEqual(list(text.port), [8443], `${name}: 8443-8443 from the text is the port 8443`);
  assert.deepEqual(list(text.port_range), ['9000:9001'], `${name}: 9000-9001 from the text is a range`);

  // UC-099: the keyword is lower case in route and DNS rules.
  assert.deepEqual(list(single.domain_keyword), ['youtube'], `${name}: keyword lower-cased in the route rule`);
  for (const r of config.dns.rules)
    for (const k of list(r.domain_keyword)) assert.equal(k, k.toLowerCase(), `${name}: DNS keyword '${k}' is lower case`);
}

const rejects = (config) => config.route.rules.filter((r) => r.action === 'reject' && list(r.protocol).includes('quic'));
assert.equal(rejects(quic).length, 1, 'disable_quic=1: one QUIC reject rule');
assert.ok(both(rejects(quic)[0]), `QUIC is rejected on tproxy-in and tproxy6-in: ${JSON.stringify(rejects(quic)[0])}`);
assert.equal(rejects(noquic).length, 0, 'disable_quic=0: no QUIC reject rule');
// The QUIC reject comes before every section rule.
const firstSection = quic.route.rules.findIndex((r) => r.outbound === 'bypass-out' || (r.action === 'reject' && r.domain_suffix));
assert.ok(quic.route.rules.indexOf(rejects(quic)[0]) < firstSection, 'QUIC reject before the section rules');
NODE

# ---- sing-box itself accepts the generated config -------------------------

binaries=()
if [ -n "${FORKOP_TEST_SING_BOX:-}" ]; then
  binaries+=("$FORKOP_TEST_SING_BOX")
elif command -v sing-box >/dev/null 2>&1; then
  binaries+=("$(command -v sing-box)")
fi
for dir in ${FORKOP_TEST_SING_BOX_DIRS:-}; do
  [ -x "$dir/sing-box" ] && binaries+=("$dir/sing-box")
done
if [ "${#binaries[@]}" -eq 0 ]; then
  printf 'SKIP: singbox_route_base_rules: no sing-box binary for "sing-box check" (set FORKOP_TEST_SING_BOX or FORKOP_TEST_SING_BOX_DIRS)\n'
fi
for bin in "${binaries[@]}"; do
  version="$("$bin" version 2>/dev/null | sed -n '1s/.* version //p')"
  case "$version" in
    1.11.*|1.10.*|1.9.*|1.8.*) printf 'SKIP: sing-box %s predates the generated DNS server format\n' "$version"; continue ;;
  esac
  for config in quic noquic; do
    "$bin" check -c "$WORK/$config.config" >"$WORK/check.out" 2>&1 ||
      fail "sing-box $version refuses the $config config: $(cat "$WORK/check.out")"
  done
done

if [ "$failures" -ne 0 ]; then
  printf 'singbox_route_base_rules: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'singbox_route_base_rules: PASS\n'
