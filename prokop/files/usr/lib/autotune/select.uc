#!/usr/bin/env ucode

// DPI autotune stage 4: measurement aggregation and deterministic candidate
// selection. Pure functions only: the probes themselves are taken through the
// isolated path (autotune/isolation.uc tune); nothing here touches the system,
// and the result is a recommendation, never applied to Prokop.
//
// Policy, in priority order:
//   1. reliability: stability class from the transport success ratio
//      (stable >= STABLE_RATIO, unstable >= UNSTABLE_RATIO, else failed),
//      then the success ratio itself;
//   2. simplicity: lower complexity rank (direct = 0) wins unless a more
//      complex candidate is materially faster;
//   3. latency: median TLS handshake time of successful probes only;
//      "materially faster" means faster by more than
//      max(LATENCY_TOLERANCE_MS, LATENCY_TOLERANCE_RATIO * slower latency),
//      so network jitter never promotes a more complex strategy.
// Candidate id is the final tie breaker. Only stable candidates can be
// selected; otherwise the result is inconclusive.

const STABLE_RATIO = 0.8;          // 3/3, 4/5, 5/6, 6/7
const UNSTABLE_RATIO = 0.5;        // 2/3, 3/5, 3/6, 4/7
const MIN_PROBES = 3;
const MAX_PROBES = 7;
const MIN_STABLE_SUCCESSES = 3;    // latency medians need at least three samples
const LATENCY_TOLERANCE_MS = 25;
const LATENCY_TOLERANCE_RATIO = 0.20;
const STABILITY_ORDER = { stable: 0, unstable: 1, failed: 2 };

function as_string(v) { return v == null ? "" : "" + v; }

function median(values) {
    let sorted = sort([ ...values ], (a, b) => a - b);
    let n = length(sorted);
    if (n == 0) return null;
    // Even samples: the mean of the two middle values, rounded (not truncated).
    return n % 2 == 1 ? sorted[int(n / 2)] : int((sorted[n / 2 - 1] + sorted[n / 2]) / 2.0 + 0.5);
}

function stability(successes, attempted) {
    if (attempted <= 0) return "failed";
    let ratio = (successes * 1.0) / attempted;
    if (ratio >= STABLE_RATIO && successes >= MIN_STABLE_SUCCESSES) return "stable";
    if (ratio >= UNSTABLE_RATIO) return "unstable";
    return "failed";
}

// Per-candidate aggregate over its probe records (probe.uc records). Latency
// medians use successful probes only; failures are counted by class.
function aggregate(candidate, probes) {
    let ok = [], classes = {};
    for (let p in probes) {
        if (p.class == "success") push(ok, p);
        else classes[as_string(p.class)] = (classes[as_string(p.class)] || 0) + 1;
    }
    let failure_classes = [];
    for (let name in sort(keys(classes))) push(failure_classes, { class: name, count: classes[name] });
    let pick = (key) => { let v = []; for (let p in ok) push(v, int(p[key])); return median(v); };
    let attempted = length(probes), success = length(ok);
    return {
        id: candidate.id, supported: true, complexity: int(candidate.rank),
        attempted, success, failure_count: attempted - success,
        success_ratio: attempted > 0 ? (success * 1.0) / attempted : 0,
        stability: stability(success, attempted),
        median_connect_ms: pick("time_connect_ms"),
        median_tls_ms: pick("time_appconnect_ms"),
        median_total_ms: pick("time_total_ms"),
        failure_classes
    };
}

function tolerance(latency) {
    let relative = int(LATENCY_TOLERANCE_RATIO * latency + 0.5);
    return relative > LATENCY_TOLERANCE_MS ? relative : LATENCY_TOLERANCE_MS;
}
// Is a materially faster than b (beyond the jitter tolerance of b)?
function materially_faster(a, b) {
    if (a.median_tls_ms == null || b.median_tls_ms == null) return false;
    return a.median_tls_ms < b.median_tls_ms - tolerance(b.median_tls_ms);
}

function by_simplicity(a, b) {
    if (a.complexity != b.complexity) return a.complexity - b.complexity;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

// Canonical ranking for display: stability, ratio, complexity, latency, id.
function ranking(candidates) {
    return sort([ ...candidates ], (a, b) => {
        let s = STABILITY_ORDER[a.stability] - STABILITY_ORDER[b.stability];
        if (s != 0) return s;
        if (a.success_ratio != b.success_ratio) return a.success_ratio > b.success_ratio ? -1 : 1;
        let c = by_simplicity(a, b);
        if (a.complexity != b.complexity) return c;
        let la = a.median_tls_ms == null ? 1e9 : a.median_tls_ms, lb = b.median_tls_ms == null ? 1e9 : b.median_tls_ms;
        if (la != lb) return la - lb;
        return c;
    });
}

// Selection over aggregated candidates (unsupported ones must already be
// excluded). Deterministic: independent of input order.
function select(candidates) {
    let result = { status: "inconclusive", selected: null, reason: null, confidence: "low",
        ranking: map(ranking(candidates), (c) => c.id) };
    let direct = null;
    for (let c in candidates) if (c.id == "direct") direct = c;
    let stable = filter(candidates, (c) => c.stability == "stable");
    if (length(candidates) == 0) { result.reason = "no_candidates"; return result; }
    if (length(stable) == 0) {
        let unstable = filter(candidates, (c) => c.stability == "unstable");
        result.reason = length(unstable) > 0 ? "no_stable_candidate" : "all_failed";
        if (length(unstable) > 0) result.leading = ranking(unstable)[0].id;
        return result;
    }
    // Reliability: the best success ratio among stable candidates.
    let best_ratio = 0;
    for (let c in stable) if (c.success_ratio > best_ratio) best_ratio = c.success_ratio;
    let pool = sort(filter(stable, (c) => c.success_ratio == best_ratio), by_simplicity);
    // Simplicity with latency tolerance: start from the simplest candidate and
    // move to a more complex one only when it is materially faster.
    let choice = pool[0], reason = "simplest_stable";
    for (let i = 1; i < length(pool); i++)
        if (materially_faster(pool[i], choice)) { choice = pool[i]; reason = "materially_faster"; }

    result.status = "selected";
    result.selected = choice.id;
    if (choice.id == "direct") result.reason = "direct_stable";
    else if (direct == null) result.reason = reason;
    else if (direct.stability == "failed") result.reason = "direct_failed_candidate_stable";
    else if (direct.stability == "unstable") result.reason = "direct_unstable_candidate_stable";
    else if (direct.success_ratio < choice.success_ratio) result.reason = "candidate_more_reliable_than_direct";
    else result.reason = "materially_faster_than_direct";

    // Confidence: high when the choice is fully reliable and clearly separated
    // (it is direct, or direct failed outright); medium when the choice rests
    // on a partial ratio, a latency difference or an unstable control.
    let full = choice.success_ratio == 1.0 && choice.attempted >= MIN_PROBES;
    let separated = choice.id == "direct" || (direct != null && direct.stability == "failed") ||
        (direct == null && reason == "simplest_stable");
    result.confidence = full && separated && reason != "materially_faster" ? "high" : "medium";
    return result;
}

// Deterministic interleaving: round r probes the base order rotated by r, so
// every candidate takes different positions across rounds (no warm-up bias)
// while the schedule stays reproducible.
function schedule(ids, rounds) {
    let result = [];
    let n = length(ids);
    for (let r = 0; r < rounds; r++) {
        let order = [];
        for (let i = 0; i < n; i++) push(order, ids[(i + r) % n]);
        push(result, order);
    }
    return result;
}

// Base order of a run: direct first, then by complexity and id; independent
// of the order the candidates were requested in.
function base_order(candidates) {
    return map(sort([ ...candidates ], (a, b) => {
        let ra = a.id == "direct" ? -1 : int(a.rank), rb = b.id == "direct" ? -1 : int(b.rank);
        if (ra != rb) return ra - rb;
        return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
    }), (c) => c.id);
}

function policy() {
    return { stable_ratio: STABLE_RATIO, unstable_ratio: UNSTABLE_RATIO, min_probes: MIN_PROBES,
        max_probes: MAX_PROBES, min_stable_successes: MIN_STABLE_SUCCESSES,
        latency_metric: "median_tls_ms", latency_tolerance_ms: LATENCY_TOLERANCE_MS,
        latency_tolerance_ratio: LATENCY_TOLERANCE_RATIO };
}

// Selection from raw probe records: [{ candidate: {id, rank}, probes: [...] }].
function evaluate(measured) {
    let candidates = [];
    for (let m in measured) push(candidates, aggregate(m.candidate, m.probes));
    let chosen = select(candidates);
    chosen.candidates = sort(candidates, by_simplicity);
    chosen.policy = policy();
    return chosen;
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return { aggregate, select, evaluate, schedule, base_order, stability, median, policy,
        MIN_PROBES, MAX_PROBES };

let fs = require("fs");
let mode = ARGV[0] || "";
if (mode == "evaluate") {
    // evaluate <measured.json>: [{ candidate: {id, rank}, probes: [probe records] }]
    let data = fs.readfile(as_string(ARGV[1]));
    let measured = null;
    try { measured = json(data); } catch (e) { measured = null; }
    if (type(measured) != "array") { warn("invalid measurement input\n"); exit(1); }
    print(sprintf("%J\n", evaluate(measured)));
    exit(0);
}
if (mode == "schedule") {
    print(sprintf("%J\n", schedule(split(as_string(ARGV[1]), ","), int(ARGV[2] || "3"))));
    exit(0);
}
warn("Usage: autotune/select.uc <evaluate measured.json|schedule ids rounds>\n");
exit(1);
