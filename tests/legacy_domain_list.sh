#!/usr/bin/env bash
set -euo pipefail

# Legacy `list domain` (exact domains, before the combined domain text) must
# keep working without a destructive migration:
# - the backend reads it through the shared rule-condition layer
#   (routing/rule_conditions.uc): exact domains, rule order kept;
# - the validator accepts it with the same checks;
# - the LuCI rule editor loads it as full:<domain> lines, so saving the rule
#   keeps the same exact matches instead of dropping them.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cat >"$WORK/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn",
    "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret" },
  "section": [
    { ".name": "text", ".type": "section", "enabled": "1", "action": "block", "domain": "text.example\nfull:exact-text.example" },
    { ".name": "one", ".type": "section", "enabled": "1", "action": "block", "domain": [ "one.example" ] },
    { ".name": "many", ".type": "section", "enabled": "1", "action": "block", "domain": [ "b.example", "a.example", "b.example" ] },
    { ".name": "mixed", ".type": "section", "enabled": "1", "action": "block", "domain": [ "legacy.example" ],
      "domain_suffix": [ "sfx.example" ], "domain_suffix_text": "text-sfx.example" }
  ]
}
JSON

generate() {
  mkdir -p "$2.section-cache"
  TMP_SUBSCRIPTION_FOLDER="$WORK/subs" ucode -L "$LIB" "$LIB/singbox/generator.uc" \
    generate-config-fixture "$1" "$2" 127.0.0.1 0 >/dev/null
}
generate "$WORK/fixture.json" "$WORK/legacy.json"
PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/fixture.json" '{}' ||
  { echo "FAIL: validator rejected legacy list domain" >&2; exit 1; }

node - "$ROOT_DIR" "$WORK" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const [root, work] = process.argv.slice(2);
const lib = path.join(root, 'prokop/files/usr/lib');

// Backend: generated sing-box rules, in rule order.
const rules = (file) => JSON.parse(fs.readFileSync(file, 'utf8')).route.rules
  .filter((r) => r.action === 'reject' && (r.domain || r.domain_suffix))
  .map((r) => ({ domain: r.domain || [], domain_suffix: r.domain_suffix || [] }));
const legacy = rules(path.join(work, 'legacy.json'));
assert.deepEqual(legacy, [
  { domain: ['exact-text.example'], domain_suffix: ['text.example'] },
  { domain: ['one.example'], domain_suffix: [] },
  { domain: ['b.example', 'a.example', 'b.example'], domain_suffix: [] },
  { domain: ['legacy.example'], domain_suffix: ['text-sfx.example', 'sfx.example'] },
], 'list domain is exact, option domain is combined text, rule order kept');

// Backend read layer used by the generator (and autotune from 6.8.2 on).
const fixture = JSON.parse(fs.readFileSync(path.join(work, 'fixture.json'), 'utf8'));
fs.writeFileSync(path.join(work, 'conditions.uc'), `let c = require("routing.rule_conditions");
let sections = json(require("fs").readfile(ARGV[0])).section;
let out = {};
for (let s in sections) out[s[".name"]] = c.domain_conditions(s);
print(sprintf("%J\\n", out));
`);
const canonical = JSON.parse(execFileSync('ucode', ['-L', lib, path.join(work, 'conditions.uc'), path.join(work, 'fixture.json')]).toString());
assert.deepEqual(canonical.one, { domain: ['one.example'], domain_suffix: [], domain_keyword: [], domain_regex: [] });
assert.deepEqual(canonical.mixed.domain, ['legacy.example']);
assert.deepEqual(canonical.mixed.domain_suffix, ['text-sfx.example', 'sfx.example']);

// LuCI editor: load the rule's domain text with the real section.js code.
const source = fs.readFileSync(path.join(root, 'luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js'), 'utf8');
function fn(name) {
  const start = source.indexOf(`function ${name}(`);
  assert(start >= 0, `${name} not found`);
  let depth = 0;
  for (let i = source.indexOf('{', start); i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`${name} not closed`);
}
const names = ['normalizeOptionValues', 'getConfigListValues', 'domainValuesWithPrefix', 'domainTextValuesWithPrefix',
  'uniqueDomainTextValues', 'appendUniqueDomainTextValues', 'legacyExactDomainValues', 'loadCombinedDomainText',
  'backendOptionText', 'backendFlag', 'backendTextListValues', 'conditionTextMode', 'backendConditionValues',
  'legacyDomainConditionValues'];
const parseValueList = (value) => value.split(/\n/).map((l) => l.split('//')[0].split('#')[0]).join(' ')
  .split(/[,\s]+/).map((s) => s.trim()).filter(Boolean);
function loadText(section) {
  const store = { rule: section };
  const context = {
    UCI_PACKAGE: 'prokop',
    main: { parseValueList },
    uci: { get: (_c, sid, key) => store[sid]?.[key] },
    L: { toArray: (v) => (v == null ? [] : Array.isArray(v) ? v : [v]) },
  };
  vm.runInNewContext(names.filter((n) => source.includes(`function ${n}(`)).map(fn).join('\n') +
    '\nresult = loadCombinedDomainText("rule");', context);
  return context.result;
}
const byName = Object.fromEntries(fixture.section.map((s) => [s['.name'], s]));
assert.equal(loadText(byName.text), 'text.example\nfull:exact-text.example', 'combined text loads unchanged');
assert.equal(loadText(byName.one), 'full:one.example', 'a legacy list domain loads as an exact match');
assert.equal(loadText(byName.many), 'full:b.example\nfull:a.example', 'several legacy domains keep their order, once each');
assert.equal(loadText(byName.mixed), 'text-sfx.example\nfull:legacy.example\nsfx.example',
  'legacy exact and suffix domains load together');

// Saving the rule writes the loaded text as the combined option and drops
// the legacy keys (section.js addTextConditionField write + afterWrite).
const saved = JSON.parse(JSON.stringify(fixture));
for (const s of saved.section) {
  const text = loadText(s);
  for (const key of ['domain_suffix', 'domain_suffix_text', 'domain_keyword', 'domain_regex', 'domain_text']) delete s[key];
  s.domain = text;
}
fs.writeFileSync(path.join(work, 'saved.json'), JSON.stringify(saved));
fs.writeFileSync(path.join(work, 'saved-rules.txt'), '');
NODE

generate "$WORK/saved.json" "$WORK/saved-config.json"
node - "$WORK" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const work = process.argv[2];
const matchers = (file) => JSON.parse(fs.readFileSync(`${work}/${file}`, 'utf8')).route.rules
  .filter((r) => r.action === 'reject' && (r.domain || r.domain_suffix))
  .map((r) => ({ domain: [...new Set(r.domain || [])].sort(), domain_suffix: [...new Set(r.domain_suffix || [])].sort() }));
assert.deepEqual(matchers('saved-config.json'), matchers('legacy.json'),
  'saving a legacy rule in the editor keeps the same exact and suffix matches');
NODE

echo "legacy list domain checks passed"
