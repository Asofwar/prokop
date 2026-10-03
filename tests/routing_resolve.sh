#!/usr/bin/env bash
set -euo pipefail

# routing/resolve.uc is the one route/owner resolver. Run on the recorded
# Stage 5 cases it must give autotune apply's answers (first-match, FakeIP,
# undecidable matchers, zapret identity) and a structured result: status,
# kind, section, action, outbound, DPI strategy identity, scope, provenance.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS="$ROOT_DIR/tests/helpers/route_owner"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

node "$HELPERS/run_resolver.js" "$ROOT_DIR/prokop/files/usr/lib" "$WORK" "$HELPERS/cases.js" > "$WORK/resolved.json"
node - "$WORK/resolved.json" "$HELPERS/apply_owner.golden.json" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const resolved = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const golden = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));

for (const [name, want] of Object.entries(golden)) {
  const got = resolved[name];
  assert(got, `${name}: resolved`);
  assert.equal(got.route_rule, want.rule, `${name}: first-match rule index`);
  if (!want.decided) {
    assert.equal(got.reason, want.reason, `${name}: reason`);
    assert.notEqual(got.status, 'decided', `${name}: never guessed`);
    assert.equal(got.provenance, 'unknown', `${name}: no provenance without an answer`);
    for (const key of ['kind', 'section', 'action', 'outbound', 'dpi', 'zapret'])
      assert.equal(got[key], null, `${name}: ${key} stays empty when undecided`);
    continue;
  }
  assert.equal(got.status, 'decided', `${name}: decided`);
  assert.equal(got.provenance, 'simulated', `${name}: calculated, not observed`);
  assert.equal(got.outbound, want.outbound, `${name}: outbound`);
  if (want.kind === 'zapret') {
    const { section, index, mark, mark_value, queue } = want;
    assert.deepEqual(got.zapret, { section, index, mark, mark_value, queue }, `${name}: zapret identity`);
    assert.equal(got.route, 'outbound');
  } else {
    assert.equal(got.zapret, null, `${name}: no zapret identity`);
    assert.equal(got.route, want.kind, `${name}: route kind`);
  }
}

// Status classes: undecidable (the config does not say), unsupported (a rule
// shape the resolver does not evaluate), unavailable (nothing to read).
const status = (name) => resolved[name].status;
for (const name of ['rule_set_before_owner', 'domain_regex', 'source_scoped', 'resolve_above_owner_fakeip'])
  assert.equal(status(name), 'undecidable', name);
for (const name of ['logical', 'unknown_field', 'tls_protocol']) assert.equal(status(name), 'unsupported', name);
assert.equal(status('singbox_config_missing'), 'unavailable');

// Canonical kinds and identity of the owning rule.
const yt = resolved.zapret_owner;
assert.deepEqual([yt.kind, yt.section, yt.label, yt.action], ['rule', 'youtube', 'youtube', 'zapret']);
assert.deepEqual(yt.dpi, { provider: 'zapret', strategy: '', custom: true });
assert.deepEqual(yt.scope, { rule: 'youtube', matchers: {} });
assert.deepEqual([resolved.first_match_connection.kind, resolved.first_match_connection.section,
  resolved.first_match_connection.action], ['rule', 'main', 'connection']);
assert.deepEqual([resolved.reject.kind, resolved.reject.action], ['block', 'block']);
assert.deepEqual([resolved.final.kind, resolved.final.action], ['direct', 'direct']);
assert.deepEqual([resolved.mark_mismatch.kind, resolved.mark_mismatch.section, resolved.mark_mismatch.zapret],
  ['rule', 'youtube', null], 'a zapret rule without a matching route mark has no proven DPI identity');
assert.equal(resolved.second_zapret_rule.zapret.queue, 4001, 'disabled zapret rules do not shift the queue');
console.log(`routing_resolve: PASS (${Object.keys(golden).length} cases)`);
NODE
