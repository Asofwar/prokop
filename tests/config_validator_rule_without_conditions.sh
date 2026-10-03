#!/usr/bin/env bash
set -euo pipefail

# An enabled routing rule whose only condition is the device filter
# (source_ip_cidr) matches nothing: the device filter only narrows the other
# conditions, so the generator emits no route rule and nft no capture, and
# the rule silently does nothing (UC-102). The validator warns about every
# enabled routing rule the generator leaves without a route rule, and names
# 'Forced device routing'; it does not refuse the configuration, which
# started before (invariant 17).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

mkdir -p "$WORK/bin"
cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
SH
chmod 0755 "$WORK/bin/logger"

cat >"$WORK/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn",
    "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret" },
  "section": [
    { ".name": "srconly", ".type": "section", "enabled": "1", "action": "bypass",
      "source_ip_cidr": [ "192.168.1.5/32" ] },
    { ".name": "vpnsrc", ".type": "section", "enabled": "1", "action": "connection",
      "interfaces": [ "wg0" ], "source_ip_cidr_text": "192.168.1.6" },
    { ".name": "empty", ".type": "section", "enabled": "1", "action": "block" },
    { ".name": "domain", ".type": "section", "enabled": "1", "action": "block",
      "source_ip_cidr": [ "192.168.1.7/32" ], "domain_suffix": [ "example.org" ] },
    { ".name": "fully", ".type": "section", "enabled": "1", "action": "connection",
      "interfaces": [ "wg1" ], "fully_routed_ips": [ "192.168.1.8" ] },
    { ".name": "ports", ".type": "section", "enabled": "1", "action": "bypass", "ports": [ "8443" ] },
    { ".name": "subnets", ".type": "section", "enabled": "1", "action": "bypass", "ip_cidr": [ "10.0.0.0/8" ] },
    { ".name": "keyword", ".type": "section", "enabled": "1", "action": "bypass", "domain_keyword": [ "video" ] },
    { ".name": "off", ".type": "section", "enabled": "0", "action": "block",
      "source_ip_cidr": [ "192.168.1.9/32" ] }
  ]
}
JSON

: >"$WORK/logger.log"
if ! PATH="$WORK/bin:$PATH" LOGGER_LOG="$WORK/logger.log" PROKOP_LIB="$LIB" \
  ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/fixture.json" '{}' >"$WORK/validator.out" 2>&1; then
  fail "a rule without conditions started before and must still be accepted ($(cat "$WORK/validator.out"))"
fi

mkdir -p "$WORK/generated.section-cache"
TMP_SUBSCRIPTION_FOLDER="$WORK/subs" ucode -L "$LIB" "$LIB/singbox/generator.uc" \
  generate-config-fixture "$WORK/fixture.json" "$WORK/generated" 127.0.0.1 0 >/dev/null 2>"$WORK/generator.err" ||
  fail "precondition: the generator accepts the fixture ($(cat "$WORK/generator.err"))"

node - "$WORK/generated" "$WORK/logger.log" <<'NODE' || failures=$((failures + 1))
const assert = require('node:assert/strict');
const fs = require('node:fs');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const log = fs.readFileSync(process.argv[3], 'utf8').split('\n').filter(Boolean);
const rules = config.route.rules;
// The first Connection rule also carries Prokop's own check domain
// (ip.podkop.fyi), which is no condition of the rule.
const owns = (name) => rules.some((r) => (r.outbound === `${name}-out` || r.outbound?.startsWith(`${name}-`)) &&
  !JSON.stringify(r.domain || []).includes('podkop.fyi'));
const fixture = ['srconly', 'vpnsrc', 'empty', 'domain', 'fully', 'ports', 'subnets', 'keyword'];
// Rules that route to their own outbound or to bypass/reject: count by
// matchers the generator emitted for the section.
const emitted = {
  srconly: rules.some((r) => r.outbound === 'bypass-out' && JSON.stringify(r).includes('192.168.1.5')),
  vpnsrc: owns('vpnsrc'),
  empty: rules.some((r) => r.action === 'reject' && !r.protocol && !r.domain_suffix),
  domain: rules.some((r) => r.action === 'reject' && JSON.stringify(r.domain_suffix || []).includes('example.org')),
  fully: owns('fully'),
  ports: rules.some((r) => r.outbound === 'bypass-out' && JSON.stringify(r.port || []).includes('8443')),
  subnets: rules.some((r) => r.outbound === 'bypass-out' && JSON.stringify(r.ip_cidr || []).includes('10.0.0.0/8')),
  keyword: rules.some((r) => r.outbound === 'bypass-out' && JSON.stringify(r.domain_keyword || []).includes('video')),
};
assert.deepEqual(fixture.filter((n) => !emitted[n]), ['srconly', 'vpnsrc', 'empty'],
  'precondition: the generator emits no route rule for exactly these rules');

const warnings = log.filter((line) => line.includes('[warn]') && line.includes('no condition'));
for (const name of fixture) {
  const warned = warnings.some((l) => l.includes(`'${name}'`));
  assert.equal(warned, !emitted[name], `rule '${name}' ${emitted[name] ? 'is not' : 'is'} reported: ${JSON.stringify(warnings)}`);
}
assert.ok(warnings.every((l) => l.includes('Forced device routing')), 'the warning names the working option');
assert.equal(log.some((line) => line.includes("'off'")), false, 'a disabled rule is not reported');
NODE

if [ "$failures" -ne 0 ]; then
  printf 'config_validator_rule_without_conditions: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'config_validator_rule_without_conditions: PASS\n'
