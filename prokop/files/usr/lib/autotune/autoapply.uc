#!/usr/bin/env ucode

// Autonomous application policy: when a confirmed group recommendation may
// be applied by itself, and what an apply outcome means for the budget, the
// cooldowns and the history. Pure: no files, no processes. The apply itself
// is always autotune/apply.uc plan + apply (Stage 5), never bypassed.
//
// A recommendation is applied only when every one of these holds:
//   - the mode is "auto" and the run is a scheduled one;
//   - hysteresis confirmed it (policy.confirmations scheduled runs in a row;
//     manual checks do not count, D-11a);
//   - the group result is a recommendation with at least
//     policy.apply_min_confidence (always "high");
//   - the rule does not carry a custom strategy of the user;
//   - the candidate is not in its cooldown after a rollback or failure;
//   - fewer than policy.max_applies_per_day applies in the last 24 hours;
//   - the state was not recovered from a corrupt file within policy.cooldown.
// "direct" is never applied: Prokop never turns DPI off by itself.
let policy_module = require("autotune.policy");

const DAY = 86400;

function as_string(v) { return v == null ? "" : "" + v; }

function applies_today(applies, now) {
    let count = 0;
    for (let a in type(applies) == "array" ? applies : [])
        if (type(a) == "object" && a.counted === true && type(a.at) == "int" && a.at > now - DAY) count++;
    return count;
}

// ctx: { policy, trigger, group (hysteresis state), result (aggregate),
//        custom, applies, now, cooldown_until, recovered_at }
// → { apply: bool, reason } — reason is null only when it may be applied.
function decide(ctx) {
    let p = ctx.policy, r = ctx.result || {};
    if (p.mode != "auto") return { apply: false, reason: "mode_not_auto" };
    if (ctx.trigger != "schedule") return { apply: false, reason: "manual_run" };
    if (r.status == "not_applicable") return { apply: false, reason: "plan_not_applicable:" + as_string(r.reason) };
    if (r.status != "recommendation" || !r.candidate) return { apply: false, reason: "no_recommendation" };
    if (r.candidate == "direct") return { apply: false, reason: "direct_not_applicable" };
    // A custom strategy is kept whatever the confirmations say.
    if (ctx.custom === true) return { apply: false, reason: "custom_strategy_kept" };
    if (!policy_module.confidence_at_least(r.confidence, p.apply_min_confidence || "high"))
        return { apply: false, reason: "confidence_too_low" };
    if (ctx.group == null || ctx.group.ready_auto !== true) return { apply: false, reason: "not_confirmed" };
    if (ctx.cooldown_until != null && ctx.now < ctx.cooldown_until) return { apply: false, reason: "candidate_in_cooldown" };
    if (type(ctx.recovered_at) == "int" && ctx.now < ctx.recovered_at + int(p.cooldown_seconds))
        return { apply: false, reason: "state_recovered" };
    let limit = int(p.max_applies_per_day);
    if (limit <= 0) return { apply: false, reason: "applies_disabled" };
    if (applies_today(ctx.applies, ctx.now) >= limit) return { apply: false, reason: "daily_limit_reached" };
    return { apply: true, reason: null };
}

// What an apply.uc apply result means:
//   counted   counts against the daily limit (a production change was tried)
//   cooldown  the candidate is not tried again before policy.cooldown
//   reset     the confirmations start over
//   history   the health.uc event status, or null for none
function outcome(result) {
    let status = type(result) == "object" ? as_string(result.status) : "";
    if (status == "applied") return { status, counted: true, cooldown: false, reset: true, history: "success" };
    // The WAN dropped during the verification: rolled back, but the
    // candidate is not to blame and the daily budget is not spent (AT-3).
    if (status == "rolled_back" && as_string(result.reason) == "verification_network_unavailable")
        return { status, counted: false, cooldown: false, reset: true, history: "recovered" };
    if (status == "rolled_back") return { status, counted: true, cooldown: true, reset: true, history: "recovered" };
    if (status == "no_change_required") return { status, counted: false, cooldown: false, reset: true, history: null };
    // Nothing was changed: the plan went stale or another autotune ran.
    if (status == "stale" || status == "busy") return { status, counted: false, cooldown: false, reset: false, history: null };
    // failed, needs_attention or an unreadable result: what happened is not
    // known for sure, so it counts, cools down and is recorded as a failure.
    return { status: status || "unknown", counted: true, cooldown: true, reset: true, history: "failure" };
}

return { DAY, applies_today, decide, outcome };
