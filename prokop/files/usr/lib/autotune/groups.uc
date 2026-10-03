#!/usr/bin/env ucode

// Autotune groups: a group is one DPI rule (a zapret config section), its
// targets are the autotune targets that rule owns. Membership is calculated
// from the routing (routing/resolve.uc) on every run and never stored, so it
// follows rule edits. Pure: no DNS, no files.
//
// A strategy is set per rule, so a group gets one recommendation only when
// every target with a conclusive result agrees on it; otherwise the result
// is a conflict and nothing is changed.

function as_string(v) { return v == null ? "" : "" + v; }

// Where one target stands, from its DNS answer and the routing:
// { in_group: <section> | null, reason, detail, source_scoped }.
// source_scoped: the rule handles the target for its own devices only
// (source_ip_cidr); the routing was asked for those devices.
// dns: { answers, fakeip }, r: routing/resolve.uc resolve() result.
function classify(dns, r) {
    if (dns == null || dns.answers == 0) return { in_group: null, reason: "target_unresolved" };
    // Autotune apply can only verify (and so only change) the sing-box path
    // of a FakeIP-routed target.
    if (!dns.fakeip) return { in_group: null, reason: "target_not_fakeip_routed" };
    if (r.status != "decided") return { in_group: null, reason: "rule_owner_undecidable", detail: r.reason };
    if (r.kind == "rule") {
        if (r.action == "zapret")
            return r.zapret != null
                ? { in_group: r.section, reason: null, label: r.label, source_scoped: r.source_scope != null }
                : { in_group: null, reason: "dpi_identity_unproven", detail: r.section };
        if (r.action == "zapret2" || r.action == "byedpi")
            return { in_group: null, reason: "provider_not_supported", detail: r.section };
        if (r.action == "connection") return { in_group: null, reason: "routed_through_connection", detail: r.section };
        return { in_group: null, reason: "not_a_dpi_rule", detail: r.section };
    }
    if (r.kind == "direct") return { in_group: null, reason: "no_dpi_rule" };
    if (r.kind == "bypass") return { in_group: null, reason: "bypassed" };
    if (r.kind == "block") return { in_group: null, reason: "blocked" };
    return { in_group: null, reason: "outbound_without_rule", detail: r.outbound };
}

function confidence_rank(c) {
    let rank = { low: 0, medium: 1, high: 2 }[as_string(c)];
    return rank == null ? -1 : rank;
}

function stable_for(summary, candidate) {
    for (let c in summary.candidates || [])
        if (c.id == candidate) return c.stability == "stable";
    return false;
}

// Group result from the latest target summaries (autotune/state.uc):
// { status: recommendation | no_change | direct_stable | conflict | inconclusive,
//   candidate, confidence, representative, reason, conflict: [...] }.
// current: strategy identity of the rule (catalog id, "default" or "").
function aggregate(members, current) {
    let result = { status: "inconclusive", candidate: null, confidence: null, representative: null,
        reason: null, conflict: [] };
    let conclusive = filter(members, (m) => m.summary != null && m.summary.status == "selected" && m.summary.selected);
    if (length(members) == 0) { result.reason = "no_targets"; return result; }
    if (length(conclusive) == 0) {
        let reasons = [];
        for (let m in members) if (m.summary != null && m.summary.reason && index(reasons, m.summary.reason) < 0) push(reasons, m.summary.reason);
        result.reason = length(reasons) == 1 ? reasons[0] : length(reasons) == 0 ? "not_measured" : "no_conclusive_result";
        return result;
    }
    let wanted = [];
    for (let m in conclusive) if (m.summary.selected != "direct" && index(wanted, m.summary.selected) < 0) push(wanted, m.summary.selected);
    // Direct works for every target: bypass is not needed, but Prokop never
    // turns DPI off by itself.
    if (length(wanted) == 0) { result.status = "direct_stable"; result.reason = "direct_not_applicable"; return result; }
    if (length(wanted) > 1) {
        result.status = "conflict";
        result.reason = "targets_need_different_strategies";
        result.conflict = map(conclusive, (m) => ({ target: m.id, selected: m.summary.selected }));
        return result;
    }
    let candidate = wanted[0];
    let unstable = filter(conclusive, (m) => !stable_for(m.summary, candidate));
    if (length(unstable) > 0) {
        result.status = "conflict";
        result.reason = "candidate_not_stable_for_all";
        result.candidate = candidate;
        result.conflict = map(unstable, (m) => ({ target: m.id, selected: m.summary.selected }));
        return result;
    }
    let choosing = sort(filter(conclusive, (m) => m.summary.selected == candidate), (a, b) => {
        let d = confidence_rank(b.summary.confidence) - confidence_rank(a.summary.confidence);
        return d != 0 ? d : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
    });
    let lowest = choosing[length(choosing) - 1].summary.confidence;
    result.candidate = candidate;
    result.confidence = lowest;
    result.representative = choosing[0].id;
    if (candidate == as_string(current)) { result.status = "no_change"; result.reason = "candidate_already_active"; return result; }
    result.status = "recommendation";
    result.reason = choosing[0].summary.reason;
    return result;
}

// Change detection for a rule's configuration (not a security hash):
// FNV-1a over the canonical JSON of its options.
function fingerprint(section) {
    let options = section == null ? {} : section.options, canonical = {};
    for (let key in sort(keys(options))) canonical[key] = options[key];
    let text = sprintf("%J", canonical), h = 2166136261;
    for (let i = 0; i < length(text); i++) {
        h = h ^ ord(text, i);
        h = (h * 16777619) & 0xffffffff;
    }
    return sprintf("%08x", h);
}

return { classify, aggregate, fingerprint };
