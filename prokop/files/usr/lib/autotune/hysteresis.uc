#!/usr/bin/env ucode

// Hysteresis of autotune group recommendations: a strategy is applied only
// after the same result N runs in a row. Pure: state in, state out.
//
// Group state (autotune/state.uc groups[<section>]):
//   { pending: { candidate, count, confidence, first_seen, last_seen,
//                inconclusive_streak } | null,
//     fingerprint,                 # of the rule config the count belongs to
//     last: { status, candidate, confidence, reason, at },
//     cooldowns: { <candidate>: <until> },
//     last_apply: { ... } }
//
// Rules:
//  - the count grows only when the same candidate is recommended again with
//    at least policy.min_confidence;
//  - another candidate restarts the count at 1 for it;
//  - an inconclusive run keeps the count; two in a row reset it;
//  - a changed rule configuration (fingerprint) resets it;
//  - a conflict, "direct works" or "already active" result resets it.
// Every step returns an event code the UI and the history explain.
let policy_module = require("autotune.policy");

function as_string(v) { return v == null ? "" : "" + v; }

function empty_group() {
    return { pending: null, fingerprint: null, last: null, cooldowns: {}, last_apply: null };
}

// observation: aggregate() of autotune/groups.uc plus the rule fingerprint:
// { status, candidate, confidence, reason, fingerprint }.
function observe(group, observation, policy, now) {
    group = type(group) == "object" ? { ...empty_group(), ...group } : empty_group();
    let obs = type(observation) == "object" ? observation : { status: "inconclusive" };
    let pending = group.pending, events = [];
    let required = int(policy.confirmations);

    if (group.fingerprint != null && obs.fingerprint != null && group.fingerprint != obs.fingerprint && pending != null) {
        push(events, { event: "reset_rule_changed", candidate: pending.candidate });
        pending = null;
    }
    if (obs.fingerprint != null) group.fingerprint = obs.fingerprint;

    let start = (candidate) => ({ candidate, count: 1, confidence: obs.confidence, first_seen: now, last_seen: now,
        inconclusive_streak: 0 });

    if (obs.status == "recommendation" && obs.candidate) {
        let confident = policy_module.confidence_at_least(obs.confidence, policy.min_confidence);
        if (pending != null && pending.candidate == obs.candidate) {
            if (confident) {
                pending = { ...pending, count: pending.count >= required ? required : pending.count + 1,
                    confidence: obs.confidence, last_seen: now, inconclusive_streak: 0 };
                push(events, { event: pending.count >= required ? "ready" : "confirmed", candidate: obs.candidate, count: pending.count });
            }
            else push(events, { event: "confidence_too_low", candidate: obs.candidate, count: pending.count });
        }
        else {
            if (pending != null) push(events, { event: "result_changed", previous: pending.candidate, candidate: obs.candidate });
            pending = confident ? start(obs.candidate) : null;
            push(events, confident ? { event: required <= 1 ? "ready" : "started", candidate: obs.candidate, count: 1 }
                : { event: "confidence_too_low", candidate: obs.candidate, count: 0 });
        }
    }
    else if (obs.status == "inconclusive") {
        if (pending != null) {
            let streak = int(pending.inconclusive_streak) + 1;
            if (streak >= 2) { push(events, { event: "reset_inconclusive", candidate: pending.candidate }); pending = null; }
            else { pending = { ...pending, inconclusive_streak: streak }; push(events, { event: "inconclusive_kept", candidate: pending.candidate, count: pending.count }); }
        }
        else push(events, { event: "inconclusive" });
    }
    else {
        // conflict, direct_stable, no_change: nothing to confirm.
        let code = obs.status == "conflict" ? "reset_conflict" : obs.status == "direct_stable" ? "reset_direct_stable"
            : obs.status == "no_change" ? "reset_already_active" : "reset_" + as_string(obs.status);
        if (pending != null) push(events, { event: code, candidate: pending.candidate });
        else push(events, { event: code == "reset_already_active" ? "already_active" : obs.status == "conflict" ? "conflict" : as_string(obs.status) });
        pending = null;
    }

    group.pending = pending;
    group.last = { status: obs.status, candidate: obs.candidate || null, confidence: obs.confidence || null,
        reason: obs.reason || null, at: now };
    return { group, events, ready: pending != null && pending.count >= required, required };
}

// A candidate rolled back recently is not applied again before the cooldown
// ends.
function cooldown_until(group, candidate) {
    let until = type(group) == "object" && type(group.cooldowns) == "object" ? group.cooldowns[as_string(candidate)] : null;
    return type(until) == "int" ? until : null;
}
function in_cooldown(group, candidate, now) {
    let until = cooldown_until(group, candidate);
    return until != null && now < until;
}
function start_cooldown(group, candidate, seconds, now) {
    group = type(group) == "object" ? group : empty_group();
    if (type(group.cooldowns) != "object") group.cooldowns = {};
    // Expired cooldowns are dropped so the state does not grow.
    for (let id in keys(group.cooldowns)) if (group.cooldowns[id] <= now) delete group.cooldowns[id];
    group.cooldowns[as_string(candidate)] = now + int(seconds);
    return group;
}

return { empty_group, observe, cooldown_until, in_cooldown, start_cooldown };
