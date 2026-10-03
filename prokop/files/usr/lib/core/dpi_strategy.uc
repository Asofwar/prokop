#!/usr/bin/env ucode

// Derived, read-only view of a DPI rule's strategy: the provider, the name of
// a known strategy (an autotune catalog template or the provider default) and
// whether it is custom. The raw option text never leaves the admin role.
let constants = require("core.constants");

const STRATEGY_OPTIONS = { zapret: "nfqws_opt", zapret2: "nfqws2_opt", byedpi: "byedpi_cmd_opts" };

let catalog = null;

function as_string(value) { return value == null ? "" : "" + value; }
function normalize(value) { return trim(replace(as_string(value), /[ \t\r\n]+/g, " ")); }

function words(value) { let v = normalize(value); return v == "" ? [] : split(v, " "); }

// nfqws profiles of a strategy: the word lists between "--new".
function profiles(opt) {
    let result = [ [] ];
    for (let w in words(opt)) {
        if (w == "--new") push(result, []);
        else push(result[length(result) - 1], w);
    }
    return result;
}

function covers_443(ports) {
    for (let part in split(ports, ",")) {
        let m = match(part, /^([0-9]+)(-([0-9]+))?$/);
        if (m != null && int(m[1]) <= 443 && (m[3] == null ? int(m[1]) : int(m[3])) >= 443) return true;
    }
    return false;
}

// How a profile takes TCP connections to port 443 (nfqws applies the first
// profile whose filters match): "exact" (--filter-tcp=443 and nothing else
// narrows or widens it), "shared" (it takes TCP/443 with other traffic, or
// may take it), "no", or "unparsed" (a filter written as two words).
function tcp443_scope(profile) {
    let tcp = null, udp = false, other = false;
    for (let w in profile) {
        if (index([ "--filter-tcp", "--filter-udp", "--filter-l3", "--filter-l7" ], w) >= 0) return "unparsed";
        if (substr(w, 0, 13) == "--filter-tcp=") tcp = substr(w, 13);
        else if (substr(w, 0, 13) == "--filter-udp=") udp = true;
        else if (substr(w, 0, 12) == "--filter-l3=" || substr(w, 0, 12) == "--filter-l7=") other = true;
    }
    if (tcp == null) return udp && !other ? "no" : "shared";
    if (!covers_443(tcp)) return "no";
    return tcp == "443" && !other ? "exact" : "shared";
}

// Words that select the traffic of a profile; everything else is its strategy.
function is_selection(w) {
    return substr(w, 0, 9) == "--filter-" || substr(w, 0, 10) == "--hostlist" || substr(w, 0, 7) == "--ipset";
}

// The strategy "current" with its TCP/443 profile replaced by the strategy of
// a one-profile TCP/443 candidate: the profile keeps its own selection
// (filters, host lists) and takes the candidate's options; every other
// profile (HTTP, QUIC, ...) stays word for word. current: the effective
// strategy (never empty). { opt, profile, before, after } or { error }.
function tcp443_splice(current, candidate) {
    let cand = profiles(candidate);
    if (length(cand) != 1 || tcp443_scope(cand[0]) != "exact") return { error: "candidate_not_tcp443" };
    let ps = profiles(current), at = -1;
    if (length(words(current)) == 0) return { error: "strategy_empty" };
    for (let i = 0; i < length(ps) && at < 0; i++) {
        let scope = tcp443_scope(ps[i]);
        if (scope == "unparsed") return { error: "strategy_unparsed" };
        if (scope == "shared") return { error: "tcp443_profile_shared" };
        if (scope == "exact") at = i;
    }
    if (at < 0) return { error: "no_tcp443_profile" };
    let replaced = [ ...filter(ps[at], is_selection), ...filter(cand[0], (w) => !is_selection(w)) ];
    let out = [];
    for (let i = 0; i < length(ps); i++) push(out, join(" ", i == at ? replaced : ps[i]));
    return { opt: join(" --new ", out), profile: at, before: join(" ", ps[at]), after: join(" ", replaced) };
}

function is_dpi_action(action) {
    return STRATEGY_OPTIONS[as_string(action)] != null;
}

function load_catalog() {
    if (catalog == null) {
        try { catalog = require("autotune.catalog"); }
        catch (e) { catalog = false; }
    }
    return catalog;
}

// section: an object with action and the provider's strategy option.
function view(section) {
    let provider = as_string(section.action);
    let raw = normalize(section[STRATEGY_OPTIONS[provider]]);
    let defaults = {
        zapret: [ constants.ZAPRET_DEFAULT_NFQWS_OPT, constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT ],
        zapret2: [ constants.ZAPRET2_DEFAULT_NFQWS2_OPT ],
        byedpi: [ constants.BYEDPI_DEFAULT_CMD_OPTS ]
    };
    let strategy = "";
    if (raw == "")
        strategy = "default";
    else {
        for (let value in defaults[provider])
            if (value != null && raw == normalize(value))
                strategy = "default";
        let known = provider == "zapret" && strategy == "" ? load_catalog() : null;
        for (let entry in (known ? known.entries() : [])) {
            if (entry.nfqws_opt == "" || strategy != "") continue;
            // The template itself, or the provider default whose TCP/443
            // profile autotune replaced by it (autotune/apply.uc).
            let spliced = tcp443_splice(constants.ZAPRET_DEFAULT_NFQWS_OPT, entry.nfqws_opt);
            if (raw == normalize(entry.nfqws_opt) || (spliced.opt != null && raw == spliced.opt))
                strategy = entry.id;
        }
    }
    return { dpi_provider: provider, dpi_strategy: strategy, dpi_strategy_custom: strategy == "" };
}

return { is_dpi_action, view, profiles, tcp443_scope, tcp443_splice };
