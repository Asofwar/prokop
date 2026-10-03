#!/usr/bin/env bash
set -euo pipefail

# Legacy domain conditions (list domain, domain_keyword, domain_regex and
# their *_text options) reach the generator through routing/rule_conditions.uc,
# which drops a value the normalizer refuses: a comma or whitespace in a
# keyword or regular expression (^a{1,3}\.example$), a name that is no
# domain. The validator never looked at them, so the value stopped matching
# without a word (UC-094). The validator now names every value the
# generator ignores. A configuration with such a value started before with
# the value ignored, so it is reported in the system log, not refused
# (invariant 17); the rule editor shows the value in the domain text, where
# it has to be fixed before the rule is saved again.

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
    { ".name": "lists", ".type": "section", "enabled": "1", "action": "block",
      "domain_regex": [ "^a{1,3}\\.example$", "^kept\\.example$" ],
      "domain_keyword": [ "two words", "video" ],
      "domain": [ "bad domain.example", "exact.example" ] },
    { ".name": "texts", ".type": "section", "enabled": "1", "action": "bypass",
      "domain_text": "text.example, bad$name.example" },
    { ".name": "off", ".type": "section", "enabled": "0", "action": "block",
      "domain_regex": [ "^b{1,2}\\.example$" ] }
  ]
}
JSON

: >"$WORK/logger.log"
if ! PATH="$WORK/bin:$PATH" LOGGER_LOG="$WORK/logger.log" PROKOP_LIB="$LIB" \
  ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/fixture.json" '{}' >"$WORK/validator.out" 2>&1; then
  fail "a configuration whose legacy values were ignored started before and must still be accepted ($(cat "$WORK/validator.out"))"
fi

mkdir -p "$WORK/generated.section-cache"
TMP_SUBSCRIPTION_FOLDER="$WORK/subs" ucode -L "$LIB" "$LIB/singbox/generator.uc" \
  generate-config-fixture "$WORK/fixture.json" "$WORK/generated" 127.0.0.1 0 >/dev/null 2>"$WORK/generator.err" ||
  fail "precondition: the generator accepts the fixture ($(cat "$WORK/generator.err"))"

# Every value the generator leaves out is reported with its rule and option,
# and nothing else is.
node - "$WORK/generated" "$WORK/logger.log" <<'NODE' || failures=$((failures + 1))
const assert = require('node:assert/strict');
const fs = require('node:fs');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const log = fs.readFileSync(process.argv[3], 'utf8').split('\n').filter(Boolean);
const generated = (key) => config.route.rules.flatMap((rule) => rule[key] || []);

const ignored = [
  ['lists', 'domain_regex', '^a{1,3}\\.example$'],
  ['lists', 'domain_keyword', 'two words'],
  ['lists', 'domain', 'bad domain.example'],
  ['texts', 'domain', 'bad$name.example'],
];
const kept = [['domain_regex', '^kept\\.example$'], ['domain_keyword', 'video'], ['domain', 'exact.example'],
  ['domain', 'text.example']];

for (const [, key, value] of ignored)
  assert.equal(generated(key).includes(value), false, `precondition: the generator ignores ${key} '${value}'`);
for (const [key, value] of kept)
  assert.equal(generated(key).includes(value), true, `precondition: the generator uses ${key} '${value}'`);

const warnings = log.filter((line) => line.includes('[warn]'));
for (const [rule, key, value] of ignored) {
  const line = warnings.find((l) => l.includes(`'${rule}'`) && l.includes(` ${key} `) && l.includes(`'${value}'`));
  assert.ok(line, `the validator must report the ignored ${key} value '${value}' of rule '${rule}': ${JSON.stringify(log)}`);
  assert.match(line, /ignore/);
}
assert.equal(warnings.length, ignored.length, `only the ignored values are reported: ${JSON.stringify(warnings)}`);
assert.equal(log.some((line) => line.includes("'off'")), false, 'a disabled rule is not reported');
NODE

if [ "$failures" -ne 0 ]; then
  printf '%d legacy domain value check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'validator reports the legacy domain values the generator ignores\n'
