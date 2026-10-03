"use strict";

// Properties of autotune hysteresis, autonomous-apply gating and candidate
// selection over generated inputs (UC-156, safety invariant 11: Prokop never
// applies an unconfirmed or different recommendation).
// Hysteresis (autotune/hysteresis.uc) over random observation streams:
//   - the count equals the confident recommendations of the pending candidate
//     since it was (re)started, capped at the requirement; ready means the
//     count reached the requirement;
//   - a changed rule fingerprint restarts the count (at most 1 after it);
//   - two inconclusive runs in a row, a conflict, "direct works" or "already
//     active" leave nothing pending;
//   - autoapply.decide() applies only a ready, high-confidence
//     recommendation of the pending candidate, never "direct".
// Selection (autotune/select.uc evaluate) over random measurement sets:
//   - the result does not depend on the order of candidates or probes;
//   - adding a candidate that failed every probe never changes the choice;
//   - one more successful probe never makes a candidate rank below one it
//     ranked above, and a selected candidate stays selected.
// Usage: autotune.js <prokop lib>

const assert = require("node:assert/strict");
const { Rng, seedFrom, casesFrom, ucodeBatch, forAll, exercised } = require("./scaffold");

const [lib] = process.argv.slice(2);
const seed = seedFrom(1560002);
const rng = new Rng(seed);
const CASES = casesFrom(300);
const CANDIDATES = ["multisplit", "fake", "hostfakesplit", "direct"];

// --- Hysteresis and apply gating ---------------------------------------------
function observation() {
  const status = rng.pickWeighted([[6, "recommendation"], [3, "inconclusive"], [1, "conflict"], [1, "direct_stable"], [1, "no_change"]]);
  const obs = { status, fingerprint: rng.pickWeighted([[8, "a"], [1, "b"], [1, null]]) };
  if (status === "recommendation") {
    obs.candidate = rng.pickWeighted([[4, "multisplit"], [2, "fake"], [1, "hostfakesplit"], [1, "direct"]]);
    obs.confidence = rng.pickWeighted([[5, "high"], [2, "medium"], [1, "low"]]);
  }
  return obs;
}
const streams = Array.from({ length: CASES }, () => ({
  policy: {
    confirmations: rng.int(1, 5), min_confidence: rng.pick(["high", "medium"]), mode: "auto",
    apply_min_confidence: "high", max_applies_per_day: 5, cooldown_seconds: 3600,
  },
  observations: rng.array(1, 14, observation),
}));

const HYSTERESIS = `
let h = require("autotune.hysteresis");
let autoapply = require("autotune.autoapply");
function evaluate(input) {
    let group = null, steps = [];
    for (let i = 0; i < length(input.observations); i++) {
        let obs = input.observations[i], now = 1000 + i;
        let observed = h.observe(group, obs, input.policy, now, "schedule");
        group = observed.group;
        let decision = autoapply.decide({ policy: input.policy, trigger: "schedule",
            group: { ...observed.group, ready: observed.ready, ready_auto: observed.ready_auto }, result: obs, custom: false,
            applies: [], now, cooldown_until: null, recovered_at: null });
        push(steps, { pending: group.pending, ready: observed.ready, required: observed.required,
            events: map(observed.events, (e) => e.event), apply: decision.apply });
    }
    return steps;
}
`;
const RANK = { low: 0, medium: 1, high: 2 };
const confident = (obs, policy) => (RANK[obs.confidence] ?? -1) >= RANK[policy.min_confidence];
const hysteresis = ucodeBatch(lib, HYSTERESIS, streams);

let readySteps = 0, applySteps = 0, fingerprintResets = 0, inconclusiveResets = 0;
forAll("hysteresis counts confident repeats of one candidate", seed, streams, (stream, n) => {
  const steps = hysteresis[n];
  const { policy, observations } = stream;
  const required = policy.confirmations;
  let lastFingerprint = null;
  steps.forEach((step, i) => {
    const obs = observations[i];
    const before = i > 0 ? steps[i - 1].pending : null;
    const p = step.pending;
    assert.equal(step.required, required, `step ${i}: required`);
    assert.equal(step.ready, p !== null && p.count >= required, `step ${i}: ready iff the count reached the requirement`);
    if (p !== null) {
      assert(p.count >= 1 && p.count <= required, `step ${i}: 1 <= count <= required`);
      const start = p.first_seen - 1000;
      assert(start >= 0 && start <= i, `step ${i}: the count started in this stream`);
      const repeats = observations.slice(start, i + 1)
        .filter((o) => o.status === "recommendation" && o.candidate === p.candidate && confident(o, policy)).length;
      assert.equal(p.count, Math.min(required, repeats), `step ${i}: count = confident repeats since step ${start}`);
    }
    if (before !== null && lastFingerprint !== null && obs.fingerprint !== null && obs.fingerprint !== lastFingerprint) {
      fingerprintResets++;
      assert(p === null || p.count <= 1, `step ${i}: a changed rule fingerprint restarts the count`);
    }
    if (obs.fingerprint !== null) lastFingerprint = obs.fingerprint;
    if (i > 0 && obs.status === "inconclusive" && observations[i - 1].status === "inconclusive") {
      inconclusiveResets++;
      assert.equal(p, null, `step ${i}: two inconclusive runs in a row reset the count`);
    }
    if (["conflict", "direct_stable", "no_change"].includes(obs.status))
      assert.equal(p, null, `step ${i}: ${obs.status} leaves nothing pending`);
    if (step.ready) readySteps++;
    if (step.apply) {
      applySteps++;
      assert(step.ready, `step ${i}: only a confirmed recommendation is applied`);
      assert.equal(obs.status, "recommendation");
      assert.equal(obs.candidate, p.candidate, `step ${i}: the applied candidate is the confirmed one`);
      assert.equal(obs.confidence, "high", `step ${i}: only high confidence is applied`);
      assert.notEqual(obs.candidate, "direct", `step ${i}: Prokop never turns DPI off by itself`);
    }
  });
});
exercised("ready steps", readySteps, CASES / 3);
exercised("applied steps", applySteps, CASES / 6);
exercised("rule fingerprint changes", fingerprintResets, CASES / 10);
exercised("inconclusive pairs", inconclusiveResets, CASES / 10);

// --- Selection -----------------------------------------------------------------
const IDS = ["direct", "fake", "multisplit", "hostfakesplit", "disorder", "split2", "syndata"];
function candidateMeasurement(id) {
  const attempted = rng.int(3, 7);
  const successRate = rng.pickWeighted([[2, 1], [3, 0.85], [2, 0.6], [1, 0.3], [1, 0]]);
  const base = rng.int(20, 400);
  const probes = Array.from({ length: attempted }, () => (rng.bool(successRate)
    ? { class: "success", time_connect_ms: rng.int(5, 60), time_appconnect_ms: base + rng.int(0, 120), time_total_ms: base + rng.int(100, 400) }
    : { class: rng.pick(["timeout", "reset", "tls_error"]) }));
  return { candidate: { id, rank: id === "direct" ? 0 : rng.int(1, 6) }, probes };
}
const failedMeasurement = (id) => ({ candidate: { id, rank: rng.int(0, 6) },
  probes: Array.from({ length: rng.int(3, 7) }, () => ({ class: rng.pick(["timeout", "reset"]) })) });

const sets = Array.from({ length: CASES }, () => {
  const ids = rng.shuffle(IDS);
  return rng.array(1, 6, (i) => candidateMeasurement(ids[i]));
});
const selectionInputs = [];
const selectionCases = sets.map((measured) => {
  const used = new Set(measured.map((m) => m.candidate.id));
  const spare = IDS.find((id) => !used.has(id));
  const c = {
    measured,
    shuffled: rng.shuffle(measured).map((m) => ({ ...m, probes: rng.shuffle(m.probes) })),
    withFailed: spare ? rng.shuffle([...measured, failedMeasurement(spare)]) : null,
  };
  selectionInputs.push(c.measured, c.shuffled);
  if (c.withFailed) selectionInputs.push(c.withFailed);
  return c;
});
const SELECT = `
let select = require("autotune.select");
function evaluate(measured) { return select.evaluate(measured); }
`;
const selected = ucodeBatch(lib, SELECT, selectionInputs);
let k = 0;
for (const c of selectionCases) {
  c.result = selected[k++];
  c.shuffledResult = selected[k++];
  if (c.withFailed) c.withFailedResult = selected[k++];
}

// Improving a candidate: one of its failed probes succeeds (any latency).
const improved = [];
for (const c of selectionCases) {
  const withFailures = c.measured.filter((m) => m.probes.some((p) => p.class !== "success"));
  if (!withFailures.length) continue;
  const winner = withFailures.find((m) => m.candidate.id === c.result.selected);
  const id = (winner && rng.bool(0.6) ? winner : rng.pick(withFailures)).candidate.id;
  improved.push({ ...c, id, input: c.measured.map((m) => {
    if (m.candidate.id !== id) return m;
    const probes = [...m.probes];
    probes[probes.findIndex((p) => p.class !== "success")] =
      { class: "success", time_connect_ms: 10, time_appconnect_ms: rng.int(20, 900), time_total_ms: 1000 };
    return { ...m, probes };
  }) });
}
const improvedResults = ucodeBatch(lib, SELECT, improved.map((c) => c.input));

forAll("selection does not depend on input order", seed, selectionCases, (c) => {
  assert.deepEqual(c.shuffledResult, c.result);
});
forAll("a candidate that failed every probe never changes the choice", seed, selectionCases, (c) => {
  if (!c.withFailed) return;
  assert.equal(c.withFailedResult.status, c.result.status);
  assert.equal(c.withFailedResult.selected, c.result.selected);
  assert.equal(c.withFailedResult.leading, c.result.leading);
});
forAll("one more successful probe never makes a candidate lose to one it beat", seed, improved, (c, i) => {
  const before = c.result.ranking, after = improvedResults[i].ranking;
  for (const other of before.slice(before.indexOf(c.id) + 1))
    assert(after.indexOf(c.id) < after.indexOf(other), `${c.id} still ranks above ${other}`);
  if (c.result.selected === c.id) {
    assert.equal(improvedResults[i].status, "selected");
    assert.equal(improvedResults[i].selected, c.id, "the selected candidate stays selected");
  }
});
exercised("selected sets", selectionCases.filter((c) => c.result.status === "selected").length, CASES / 4);
exercised("inconclusive sets", selectionCases.filter((c) => c.result.status !== "selected").length, CASES / 20);
exercised("improved candidates", improved.length, CASES / 2);
exercised("improved selected candidates", improved.filter((c) => c.result.selected === c.id).length, CASES / 60);

console.log(`autotune properties passed (seed ${seed}: ${streams.length} observation streams, ${readySteps} ready steps, ` +
  `${applySteps} applies, ${selectionCases.length} measurement sets, ${improved.length} improved)`);
