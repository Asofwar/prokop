#!/usr/bin/env bash
set -euo pipefail

# Stage 6.8.3: a group recommendation becomes "ready" only after the same
# candidate N runs in a row with enough confidence; other results, two
# inconclusive runs, rule changes and conflicts reset the count; a rolled
# back candidate waits out its cooldown.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cat >"$WORK/h.uc" <<'UC'
let h = require("autotune.hysteresis");
let policy = { confirmations: 3, min_confidence: "high" };
let rec = (candidate, confidence, fp) => ({ status: "recommendation", candidate, confidence: confidence || "high", fingerprint: fp || "fp1" });
function run(steps, p) {
  let g = null, out = [];
  for (let i = 0; i < length(steps); i++) {
    let r = h.observe(g, steps[i], p || policy, 1000 + i, steps[i].manual ? "manual" : "schedule");
    g = r.group;
    push(out, { events: map(r.events, (e) => e.event), count: g.pending ? g.pending.count : 0,
      candidate: g.pending ? g.pending.candidate : null, ready: r.ready, ready_auto: r.ready_auto,
      scheduled: g.pending ? g.pending.scheduled : 0 });
  }
  return { steps: out, group: g };
}
let out = {
  confirm: run([ rec("multisplit"), rec("multisplit"), rec("multisplit"), rec("multisplit") ]),
  change: run([ rec("multisplit"), rec("multisplit"), rec("fake") ]),
  inconclusive_once: run([ rec("multisplit"), { status: "inconclusive" }, rec("multisplit") ]),
  inconclusive_twice: run([ rec("multisplit"), { status: "inconclusive" }, { status: "inconclusive" } ]),
  low_confidence: run([ rec("multisplit"), rec("multisplit", "medium"), rec("fake", "medium") ]),
  rule_changed: run([ rec("multisplit", "high", "a"), rec("multisplit", "high", "a"), rec("multisplit", "high", "b") ]),
  resets: run([ rec("multisplit"), { status: "conflict", fingerprint: "fp1" }, rec("multisplit"),
    { status: "direct_stable" }, rec("multisplit"), { status: "no_change" } ]),
  medium_policy: run([ rec("fake", "medium"), rec("fake", "medium") ], { confirmations: 2, min_confidence: "medium" }),
  // AT-2: with min_confidence medium, medium runs confirm the Apply button
  // but only high runs count for automatic apply.
  medium_auto: run([ rec("fake", "medium"), rec("fake", "medium"), rec("fake", "high"), rec("fake", "high"), rec("fake", "high") ],
    { confirmations: 3, min_confidence: "medium", apply_min_confidence: "high" }),
  // D-11a: "Check now" three times in a row is ready for a manual apply,
  // never for an automatic one; scheduled runs add their own count.
  manual: run([ { ...rec("multisplit"), manual: true }, { ...rec("multisplit"), manual: true },
    { ...rec("multisplit"), manual: true }, rec("multisplit"), rec("multisplit"), rec("multisplit") ])
};
// AT-4: a cooldown set before the clock jumped back ends a cooldown from now.
let jumped = h.start_cooldown(h.empty_group(), "fake", 3600, 1000000);
let seen = h.observe(jumped, rec("fake"), { confirmations: 3, min_confidence: "high", cooldown_seconds: 3600 }, 500, "schedule").group;
out.clock_back = { until: h.cooldown_until(seen, "fake"), original: jumped.cooldowns.fake };
let g = h.start_cooldown(h.empty_group(), "multisplit", 3600, 100);
g = h.start_cooldown(g, "fake", 60, 100);
out.cooldown = { active: h.in_cooldown(g, "multisplit", 200), other: h.in_cooldown(g, "direct", 200),
  expired: h.in_cooldown(g, "multisplit", 3700), until: h.cooldown_until(g, "multisplit") };
g = h.start_cooldown(g, "hostfakesplit", 60, 5000);
out.cooldown.kept = sort(keys(g.cooldowns));
print(sprintf("%J\n", out));
UC
ucode -L "$LIB" "$WORK/h.uc" >"$WORK/h.json"

node - "$WORK/h.json" <<'NODE'
const assert = require('node:assert/strict');
const r = JSON.parse(require('node:fs').readFileSync(process.argv[2], 'utf8'));
const brief = (run) => run.steps.map((s) => [s.events.join('+'), s.count, s.ready]);
assert.deepEqual(r.clock_back, { until: 4100, original: 1003600 }, 'a cooldown after the clock jumped back is cut to one cooldown (AT-4)');
assert.deepEqual(r.medium_auto.steps.map((s) => [s.count, s.ready, s.scheduled, s.ready_auto]),
  [[1, false, 0, false], [2, false, 0, false], [3, true, 1, false], [3, true, 2, false], [3, true, 3, true]],
  'medium runs never count toward automatic apply (AT-2)');

assert.deepEqual(brief(r.confirm), [['started', 1, false], ['confirmed', 2, false], ['ready', 3, true], ['ready', 3, true]],
  'the same candidate three times in a row becomes ready; the count stops at the requirement');
assert.deepEqual(brief(r.change), [['started', 1, false], ['confirmed', 2, false], ['result_changed+started', 1, false]]);
assert.equal(r.change.steps[2].candidate, 'fake', 'another candidate restarts the count for itself');
assert.deepEqual(brief(r.inconclusive_once), [['started', 1, false], ['inconclusive_kept', 1, false], ['confirmed', 2, false]],
  'one run without data keeps the progress');
assert.deepEqual(brief(r.inconclusive_twice), [['started', 1, false], ['inconclusive_kept', 1, false], ['reset_inconclusive', 0, false]],
  'two runs without data reset it');
assert.deepEqual(brief(r.low_confidence), [['started', 1, false], ['confidence_too_low', 1, false],
  ['result_changed+confidence_too_low', 0, false]], 'low confidence never grows or starts a count');
assert.deepEqual(brief(r.rule_changed), [['started', 1, false], ['confirmed', 2, false], ['reset_rule_changed+started', 1, false]],
  'a changed rule configuration restarts the count');
assert.equal(r.rule_changed.group.fingerprint, 'b');
assert.deepEqual(brief(r.resets).map((s) => s[0]),
  ['started', 'reset_conflict', 'started', 'reset_direct_stable', 'started', 'reset_already_active']);
assert.deepEqual(r.resets.group.last, { status: 'no_change', candidate: null, confidence: null, reason: null, at: 1005,
  trigger: 'schedule' });
assert.deepEqual(r.confirm.steps.map((s) => [s.scheduled, s.ready_auto]), [[1, false], [2, false], [3, true], [3, true]],
  'scheduled runs make a group ready for an automatic apply');
assert.deepEqual(r.manual.steps.map((s) => [s.count, s.ready, s.scheduled, s.ready_auto]),
  [[1, false, 0, false], [2, false, 0, false], [3, true, 0, false], [3, true, 1, false], [3, true, 2, false], [3, true, 3, true]],
  'manual checks never count toward an automatic apply');
assert.equal(r.manual.steps.length, 6);
assert.deepEqual(brief(r.medium_policy), [['started', 1, false], ['ready', 2, true]]);

assert.deepEqual([r.cooldown.active, r.cooldown.other, r.cooldown.expired, r.cooldown.until], [true, false, false, 3700]);
assert.deepEqual(r.cooldown.kept, ['hostfakesplit'], 'expired cooldowns are dropped');
console.log('autotune hysteresis checks passed');
NODE
