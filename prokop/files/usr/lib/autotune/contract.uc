#!/usr/bin/env ucode

// Production bypass contract for isolated autotune probes.
//
// The probe path relies on one property of the live system: every packet of
// the probe tuple leaves the temporary chains with exactly the canonical probe
// mark (the Prokop outbound mark, 0x08000000) and is then neither classified,
// queued, re-marked, redirected nor policy-routed by production; its replies
// are not classified either. This module proves that property from the
// structure and semantics of the ruleset, the policy routing rules and the
// legacy iptables state. It never relies on nft handle numbers or on the
// relative order of production rules other than "the bypass comes first".
//
// Contract (all must hold, otherwise the probe path is unavailable):
//  1. The production table (family inet) has at least one base chain on the
//     output path (hook output or postrouting); every one has policy accept,
//     an integer priority, and output-hook chains run after the probe chains.
//  2. In every production output-path base chain the first rule that can
//     matter for the probe is a bypass: it matches only on the packet mark,
//     accepts the probe mark and returns/accepts. Rules before it may only
//     match, count and return/accept.
//  3. No other table has a chain reachable from an output-path hook that
//     re-marks packets (other than to the probe mark itself), queues,
//     redirects, rewrites addresses/ports or uses unknown statements.
//  4. No inbound chain (prerouting/input/ingress, production or foreign) can
//     mark, queue or redirect the probe's replies: every such statement sits
//     behind a match (interface, mark, protocol, ports, source) that the
//     replies (TCP from TARGET:443 on the WAN device, mark 0) provably fail.
//  5. No policy routing rule that can select a lookup made with the probe
//     mark looks up anything but the standard local/main/default tables, and
//     no rule blocks the first lookups (socket mark 0, nfqws desync marks).
//  6. No legacy iptables tables are loaded (their hooks are invisible to nft).
//  7. The probe mark shares no bits with the FakeIP and desync marks and lies
//     outside the zapret/zapret2 route mark ranges.

let constants = require("core.constants");

const OUTPUT_PATH_HOOKS = [ "output", "postrouting", "egress" ];
const INBOUND_HOOKS = [ "prerouting", "input", "ingress" ];
const SAFE_STATEMENTS = [ "match", "counter", "accept", "drop", "reject", "return", "continue",
    "limit", "log", "quota", "masquerade", "snat", "notrack" ];
const STANDARD_TABLES = [ "local", "main", "default", "255", "254", "253" ];
// Rule selectors understood below; anything else makes a rule undecidable.
const RULE_KEYS = [ "priority", "src", "srclen", "dst", "dstlen", "table", "fwmark", "fwmask", "not",
    "iif", "oif", "ipproto", "sport", "dport", "sport_start", "sport_end", "dport_start", "dport_end",
    "uidrange", "uid_start", "uid_end", "suppress_prefixlen", "suppress_ifgroup", "protocol",
    "action", "goto", "flags", "l3mdev", "nop", "tos", "dscp" ];
// Rule actions that end a lookup without a route.
const BLOCKING_ACTIONS = [ "blackhole", "unreachable", "prohibit" ];

function as_string(v) { return v == null ? "" : "" + v; }

function mark_number(value) {
    if (type(value) == "int") return value;
    let text = lc(trim(as_string(value)));
    if (match(text, /^[0-9]+$/) != null) return int(text);
    if (substr(text, 0, 2) != "0x" || length(text) < 3) return null;
    let result = 0;
    for (let i = 2; i < length(text); i++) {
        let digit = index("0123456789abcdef", substr(text, i, 1));
        if (digit < 0) return null;
        result = result * 16 + digit;
    }
    return result;
}
function hex(value) { return sprintf("0x%08x", value); }

function ipv4_number(text) {
    let m = match(as_string(text), /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
    if (m == null) return null;
    let n = 0;
    for (let i = 1; i <= 4; i++) {
        if (int(m[i]) > 255) return null;
        n = n * 256 + int(m[i]);
    }
    return n;
}
function in_prefix(ip, prefix, len) {
    let a = ipv4_number(ip), b = ipv4_number(prefix);
    if (a == null || b == null || len < 0 || len > 32) return null;
    let size = 1;
    for (let i = 0; i < 32 - len; i++) size *= 2;
    return int(a / size) == int(b / size);
}

function objects(listing, kind) {
    let result = [];
    for (let item in (type(listing) == "array" ? listing : []))
        if (type(item) == "object" && type(item[kind]) == "object")
            push(result, item[kind]);
    return result;
}
function chain_key(family, table, name) { return family + "|" + table + "|" + name; }
function expr_key(expr) { return type(expr) == "object" ? keys(expr)[0] : null; }

// The value a mark match compares against the packet mark, or null when the
// expression is not a pure mark match.
function mark_match(expr) {
    let m = type(expr) == "object" ? expr.match : null;
    if (type(m) != "object") return null;
    let left = m.left, mask = null;
    if (type(left) == "object" && type(left["&"]) == "array" && length(left["&"]) == 2) {
        mask = mark_number(left["&"][1]);
        left = left["&"][0];
        if (mask == null) return null;
    }
    if (type(left) != "object" || type(left.meta) != "object" || left.meta.key != "mark") return null;
    let op = m.op || "==";
    let values = [];
    if (type(m.right) == "object" && type(m.right.set) == "array") {
        for (let v in m.right.set) {
            let n = mark_number(v);
            if (n == null) return null;
            push(values, n);
        }
    }
    else {
        let n = mark_number(m.right);
        if (n == null) return null;
        push(values, n);
    }
    if (op != "==" && op != "!=" && op != "in") return null;
    return { mask, values, negate: op == "!=" };
}
function mark_matches(spec, mark) {
    let value = spec.mask == null ? mark : (mark & spec.mask);
    let hit = false;
    for (let v in spec.values) if (value == v) hit = true;
    return spec.negate ? !hit : hit;
}

function verdict_of(expr) {
    for (let key in [ "return", "accept" ])
        if (type(expr) == "object" && exists(expr, key)) return key;
    return null;
}

// A rule that can only observe the packet and end or continue evaluation.
function harmless_prefix_rule(rule) {
    let verdicts = 0;
    for (let expr in rule.expr || []) {
        let key = expr_key(expr);
        if (key == "match" || key == "counter") continue;
        if (key == "return" || key == "accept") { verdicts++; continue; }
        return key || "invalid";
    }
    return verdicts <= 1 ? null : "multiple_verdicts";
}

// A rule that returns every packet carrying the probe mark, whatever else.
function bypass_rule(rule, probe_mark) {
    let marks = 0, verdict = null;
    for (let expr in rule.expr || []) {
        let key = expr_key(expr);
        if (key == "counter") continue;
        if (key == "match") {
            let spec = mark_match(expr);
            if (spec == null || !mark_matches(spec, probe_mark)) return false;
            marks++;
            continue;
        }
        let v = verdict_of(expr);
        if (v == null || verdict != null) return false;
        verdict = v;
    }
    return marks > 0 && verdict != null;
}

// Header rewrites that cannot redirect or reclassify a packet. Setting the
// probe mark itself is only harmless when the rule is confined to another
// application's sockets (TorrServer Direct: socket cgroupv2); unconditionally
// it would strip the desync bit from the candidate's injected packets.
function cgroup_confined(rule) {
    for (let expr in (type(rule) == "object" ? rule.expr : null) || []) {
        let m = type(expr) == "object" ? expr.match : null;
        if (type(m) == "object" && type(m.left) == "object" && type(m.left.socket) == "object" &&
            m.left.socket.key == "cgroupv2" && (m.op || "==") == "==")
            return true;
    }
    return false;
}
function safe_mangle(target, value, probe_mark, rule) {
    if (type(target) != "object") return false;
    if (type(target.meta) == "object")
        return target.meta.key == "priority" || target.meta.key == "nftrace" ||
            (target.meta.key == "mark" && mark_number(value) == probe_mark && cgroup_confined(rule));
    if (type(target["tcp option"]) == "object") return target["tcp option"].name == "maxseg";
    if (type(target.payload) == "object")
        return (target.payload.protocol == "ip" || target.payload.protocol == "ip6") && target.payload.field == "dscp";
    return false;
}

function statement_risk(expr, probe_mark, rule) {
    let key = expr_key(expr);
    if (key == null) return "invalid_statement";
    if (index(SAFE_STATEMENTS, key) >= 0) return null;
    if (key == "mangle") {
        let m = expr.mangle;
        if (type(m) == "object" && safe_mangle(m.key, m.value, probe_mark, rule)) return null;
        return "mangle " + sprintf("%J", type(m) == "object" ? m.key : null);
    }
    return key;
}

// Branching statements: null when expr does not branch, otherwise the chains
// it can continue in (opaque: a verdict map whose entries are not listed).
function branch_targets(expr) {
    let key = expr_key(expr);
    if (key == "jump" || key == "goto")
        return { opaque: false, targets: [ as_string(expr[key].target) ] };
    if (key != "vmap") return null;
    let data = type(expr.vmap) == "object" ? expr.vmap.data : null;
    if (type(data) != "object" || type(data.set) != "array") return { opaque: true, targets: [] };
    let targets = [];
    for (let entry in data.set) {
        let verdict = type(entry) == "array" ? entry[1] : null;
        if (type(verdict) != "object") return { opaque: true, targets: [] };
        let verdict_key = keys(verdict)[0];
        if (verdict_key == "jump" || verdict_key == "goto") push(targets, as_string(verdict[verdict_key].target));
        else if (index([ "accept", "drop", "return", "continue" ], verdict_key) < 0) return { opaque: true, targets: [] };
    }
    return { opaque: false, targets };
}

// Literal values of a match right-hand side: an array of plain values or
// [lo, hi] intervals, or null when not decidable (named set, wildcard, ...).
function literal_values(right, sets) {
    let items = null;
    if (type(right) == "string" && substr(right, 0, 1) == "@") {
        let elements = sets ? sets[substr(right, 1)] : null;
        if (type(elements) != "array") return null;
        items = elements;
    }
    else if (type(right) == "object" && type(right.set) == "array") items = right.set;
    else items = [ right ];
    let result = [];
    for (let v in items) {
        if (type(v) == "int") push(result, [ v, v ]);
        else if (type(v) == "string" && index(v, "*") < 0) push(result, v);
        else if (type(v) == "object" && type(v.range) == "array" && type(v.range[0]) == "int" && type(v.range[1]) == "int")
            push(result, [ v.range[0], v.range[1] ]);
        else if (type(v) == "object" && type(v.prefix) == "object") push(result, v);
        else return null;
    }
    return result;
}
function value_member(value, values) {
    for (let v in values) {
        if (type(v) == "array" && type(value) == "int" && value >= v[0] && value <= v[1]) return true;
        if (type(v) == "string" && v == value) return true;
        if (type(v) == "object" && type(v.prefix) == "object" && type(value) == "string" &&
            in_prefix(value, v.prefix.addr, int(v.prefix.len)) == true) return true;
    }
    return false;
}

// Does this match provably fail for every reply packet of the probe (from the
// WAN device, mark 0, TCP from TARGET:443 to the probe port range)?
function reply_match_fails(m, reply) {
    let spec = mark_match({ match: m });
    if (spec != null) return !mark_matches(spec, 0);
    let left = m.left, op = m.op || "==";
    if (op != "==" && op != "!=" && op != "in") return false;
    let candidates = null, key = null;
    if (type(left) == "object" && type(left.meta) == "object") {
        key = left.meta.key;
        if ((key == "iifname" || key == "iif") && reply.dev != null) candidates = [ reply.dev ];
        else if (key == "l4proto") candidates = [ "tcp", 6 ];
        else if (key == "nfproto") candidates = [ "ipv4" ];
    }
    else if (type(left) == "object" && type(left.payload) == "object") {
        let p = left.payload;
        if ((p.protocol == "tcp" || p.protocol == "th") && p.field == "dport") {
            candidates = [];
            for (let port = reply.dport[0]; port <= reply.dport[1]; port++) push(candidates, port);
        }
        else if ((p.protocol == "tcp" || p.protocol == "th") && p.field == "sport") candidates = [ reply.sport ];
        else if (p.protocol == "udp" || p.protocol == "icmp" || p.protocol == "ip6" || p.protocol == "icmpv6") return op != "!=";
        else if (p.protocol == "ip" && p.field == "saddr" && reply.saddr != null) candidates = [ reply.saddr ];
    }
    if (candidates == null) return false;
    let values = literal_values(m.right, reply.sets);
    if (values == null) return false;
    let hits = 0;
    for (let c in candidates) if (value_member(c, values)) hits++;
    // l4proto/nfproto: any spelling of the reply value counts as that value.
    if (key == "l4proto" || key == "nfproto") return op == "!=" ? hits > 0 : hits == 0;
    return op == "!=" ? hits == length(candidates) : hits == 0;
}

// Walk one rule left to right for a reply packet: statements before the
// first provably failing match execute; everything after it does not.
function reply_rule(rule, reply, risks, targets) {
    for (let expr in rule.expr || []) {
        let m = type(expr) == "object" ? expr.match : null;
        if (type(m) == "object") {
            if (reply_match_fails(m, reply)) return;
            continue;
        }
        let branch = branch_targets(expr);
        if (branch != null) {
            if (branch.opaque) push(risks, "opaque verdict map");
            for (let target in branch.targets) push(targets, target);
            continue;
        }
        let risk = statement_risk(expr, -1, rule);
        if (risk != null) push(risks, risk);
    }
}

// Set names inbound rules gate on (their elements are not part of a terse
// listing and must be supplied as options.sets).
function reply_sets(listing, prod_table) {
    let result = [];
    for (let rule in objects(listing, "rule")) {
        for (let expr in rule.expr || []) {
            let m = type(expr) == "object" ? expr.match : null;
            if (type(m) == "object" && type(m.left) == "object" && type(m.left.meta) == "object" &&
                (m.left.meta.key == "iifname" || m.left.meta.key == "iif") &&
                type(m.right) == "string" && substr(m.right, 0, 1) == "@" &&
                rule.family == "inet" && rule.table == prod_table && index(result, substr(m.right, 1)) < 0)
                push(result, substr(m.right, 1));
        }
    }
    return result;
}

function range_of(rule, key) {
    if (rule[key + "_start"] != null)
        return [ int(rule[key + "_start"]), int(rule[key + "_end"] != null ? rule[key + "_end"] : rule[key + "_start"]) ];
    let v = rule[key];
    if (v == null) return null;
    if (type(v) == "int") return [ v, v ];
    let m = match(as_string(v), /^([0-9]+)(-([0-9]+))?$/);
    return m ? [ int(m[1]), int(m[3] || m[1]) ] : "invalid";
}
// How a selector relates to a set of probe values: "all" of them match it,
// "none" does, or only "some".
function coverage(hits, total) { return hits == total ? "all" : hits == 0 ? "none" : "some"; }
function range_coverage(range, values) {
    let hits = 0;
    for (let v in values) if (v >= range[0] && v <= range[1]) hits++;
    return coverage(hits, length(values));
}

// Can this policy rule select a lookup of a probe packet? true, false, or
// null (undecidable). probe.marks lists the marks the lookup may carry.
function rule_selects_probe(rule, probe) {
    for (let key in keys(rule))
        if (index(RULE_KEYS, key) < 0) return null;
    if (exists(rule, "nop") || exists(rule, "l3mdev")) return false;
    let states = [];
    if (rule.fwmark != null) {
        let value = mark_number(rule.fwmark), mask = rule.fwmask == null ? 0xffffffff : mark_number(rule.fwmask);
        if (value == null || mask == null) return null;
        // Kernel semantics: ((mark ^ value) & mask) == 0.
        let hits = 0;
        for (let mark in probe.marks) if (((mark ^ value) & mask) == 0) hits++;
        push(states, coverage(hits, length(probe.marks)));
    }
    if (rule.iif != null) push(states, rule.iif == "lo" ? "all" : "none");
    if (rule.oif != null) push(states, "none");      // locally generated lookups carry no oif
    if (rule.ipproto != null) push(states, rule.ipproto == "tcp" || rule.ipproto == "6" ? "all" : "none");
    for (let key in [ "tos", "dscp" ])
        if (rule[key] != null) push(states, mark_number(rule[key]) == 0 ? "all" : "none");
    let sport = range_of(rule, "sport"), dport = range_of(rule, "dport");
    if (sport == "invalid" || dport == "invalid") return null;
    if (sport != null) {
        let ports = [];
        for (let p = probe.sport[0]; p <= probe.sport[1]; p++) push(ports, p);
        push(states, range_coverage(sport, ports));
    }
    if (dport != null) push(states, range_coverage(dport, [ probe.dport ]));
    let uids = range_of(rule, "uid");
    if (uids == null && rule.uidrange != null) uids = range_of({ uid: rule.uidrange }, "uid");
    if (uids == "invalid") return null;
    if (uids != null) push(states, range_coverage(uids, probe.uids));
    if (rule.dst != null && rule.dst != "all") {
        let hit = probe.target ? in_prefix(probe.target, rule.dst, int(rule.dstlen != null ? rule.dstlen : 32)) : null;
        push(states, hit == null ? "unknown" : hit ? "all" : "none");
    }
    if (rule.src != null && rule.src != "all") {
        let hit = probe.saddr ? in_prefix(probe.saddr, rule.src, int(rule.srclen != null ? rule.srclen : 32)) : null;
        push(states, hit == null ? "unknown" : hit ? "all" : "none");
    }
    let none = index(states, "none") >= 0, unknown = index(states, "unknown") >= 0;
    let all = true;
    for (let s in states) if (s != "all") all = false;
    if (exists(rule, "not")) {
        // FIB_RULE_INVERT selects every lookup the conjunction does not match:
        // it never selects a probe lookup only if every selector covers all.
        if (all) return false;
        return unknown && !none ? null : true;
    }
    if (none) return false;
    return unknown ? null : true;
}

function evaluate(listing, ip_rules, options) {
    options = options || {};
    let probe_mark = mark_number(options.probe_mark || constants.NFT_OUTBOUND_MARK);
    let own_table = options.own_table || "ProkopAutotuneProbe";
    let own_priority = int(options.own_priority != null ? options.own_priority : -151);
    let prod_table = options.prod_table || constants.NFT_TABLE_NAME;
    let reply = { dev: options.reply_dev || null, sets: type(options.sets) == "object" ? options.sets : {},
        saddr: options.target || null, sport: options.dport || 443, dport: options.sport_range || [ 61000, 61031 ] };
    let violations = [], bypass = [], foreign = [], caveats = [];
    let result = { ok: false, reason: null, probe_mark: hex(probe_mark), violations, bypass, foreign_chains: foreign, caveats };
    let violation = (code, detail) => push(violations, { code, detail: detail || null });

    // 7. Mark layout.
    let fakeip = mark_number(constants.NFT_FAKEIP_MARK);
    let desync = mark_number(constants.ZAPRET_DESYNC_MARK) | mark_number(constants.ZAPRET_DESYNC_MARK_POSTNAT) |
        mark_number(constants.ZAPRET2_DESYNC_MARK) | mark_number(constants.ZAPRET2_DESYNC_MARK_POSTNAT);
    if (probe_mark == null || probe_mark == 0 || (probe_mark & fakeip) != 0 || (probe_mark & desync) != 0)
        violation("probe_mark_overlap", hex(probe_mark));
    for (let range in [ [ constants.ZAPRET_ROUTE_MARK_BASE, constants.ZAPRET_QUEUE_RANGE_SIZE ],
                        [ constants.ZAPRET2_ROUTE_MARK_BASE, constants.ZAPRET2_QUEUE_RANGE_SIZE ] ]) {
        let base = mark_number(range[0]);
        if (probe_mark > base && probe_mark <= base + int(range[1]))
            violation("probe_mark_overlap", "route mark range " + hex(base));
    }

    // 6. Legacy iptables hooks are invisible to nft.
    if (options.legacy_tables != null) {
        if (type(options.legacy_tables) != "array") violation("legacy_iptables_unknown");
        else if (length(options.legacy_tables) > 0) violation("legacy_iptables_present", join(",", options.legacy_tables));
    }

    let chains = {}, rules = {};
    for (let chain in objects(listing, "chain")) {
        let key = chain_key(chain.family, chain.table, chain.name);
        chains[key] = chain;
        rules[key] = [];
    }
    for (let rule in objects(listing, "rule")) {
        let key = chain_key(rule.family, rule.table, rule.chain);
        if (rules[key] == null) rules[key] = [];
        push(rules[key], rule);
    }
    let is_prod = (c) => c.family == "inet" && c.table == prod_table;
    let is_own = (c) => c.family == "inet" && c.table == own_table;

    // 1./2. Production output path.
    let prod_seen = false, prod_output = 0;
    for (let key in keys(chains)) {
        let chain = chains[key];
        if (!is_prod(chain)) continue;
        prod_seen = true;
        if (chain.hook == null || index(OUTPUT_PATH_HOOKS, chain.hook) < 0) continue;
        prod_output++;
        let where = chain.table + "/" + chain.name;
        if (type(chain.prio) != "int") { violation("production_chain_priority_unknown", where); continue; }
        if (chain.hook == "output" && chain.prio <= own_priority)
            violation("production_chain_not_after_probe", where + " priority " + chain.prio);
        if (chain.policy != "accept") violation("production_chain_policy", where + " policy " + as_string(chain.policy));
        let chain_rules = rules[key], found = -1;
        for (let i = 0; i < length(chain_rules) && found < 0; i++)
            if (bypass_rule(chain_rules[i], probe_mark)) found = i;
        if (found < 0) {
            violation("bypass_rule_missing", where);
            continue;
        }
        let safe = true;
        for (let i = 0; i < found && safe; i++) {
            let risk = harmless_prefix_rule(chain_rules[i]);
            if (risk != null) {
                violation("unsafe_rule_before_bypass", where + " rule #" + (i + 1) + ": " + risk);
                safe = false;
            }
        }
        // The handle is reported for evidence only; nothing depends on it.
        if (safe)
            push(bypass, { chain: where, hook: chain.hook, priority: chain.prio, position: found + 1,
                handle: chain_rules[found].handle });
    }
    if (!prod_seen) violation("production_table_absent", prod_table);
    else if (prod_output == 0) violation("production_output_chain_absent", prod_table);

    // 4. Inbound path: replies of the probe must not be classified, queued,
    // marked or redirected by production or by any other table.
    for (let key in keys(chains)) {
        let chain = chains[key];
        if (is_own(chain) || chain.hook == null || index(INBOUND_HOOKS, chain.hook) < 0) continue;
        let code = is_prod(chain) ? "reply_path_unsafe" : "foreign_reply_unsafe";
        let where = chain.family + " " + chain.table + "/" + chain.name;
        if (chain.policy == "drop") push(caveats, where + ": policy drop on the reply path");
        let seen = {}, stack = [ key ];
        while (length(stack) > 0) {
            let current = pop(stack);
            if (seen[current]) continue;
            seen[current] = true;
            if (chains[current] == null) { violation(is_prod(chain) ? "production_chain_unresolved" : "foreign_chain_unresolved", current); continue; }
            let position = 0;
            for (let rule in rules[current]) {
                position++;
                let risks = [], targets = [];
                reply_rule(rule, reply, risks, targets);
                for (let target in targets) push(stack, chain_key(chain.family, chain.table, target));
                for (let risk in risks) {
                    if (risk == "drop" || risk == "reject") continue;
                    violation(code, where + " via " + current + " rule #" + position + ": " + risk);
                }
            }
        }
    }

    // 3. Every other output-path chain, with everything it can jump to.
    for (let key in keys(chains)) {
        let chain = chains[key];
        if (is_prod(chain) || is_own(chain)) continue;
        if (chain.hook == null || index(OUTPUT_PATH_HOOKS, chain.hook) < 0) continue;
        let where = chain.family + " " + chain.table + "/" + chain.name;
        push(foreign, { chain: where, hook: chain.hook, priority: chain.prio,
            before_probe: chain.hook == "output" && type(chain.prio) == "int" && chain.prio <= own_priority });
        if (chain.policy == "drop") push(caveats, where + ": policy drop on the output path");
        let seen = {}, stack = [ key ];
        while (length(stack) > 0) {
            let current = pop(stack);
            if (seen[current]) continue;
            seen[current] = true;
            if (chains[current] == null) { violation("foreign_chain_unresolved", current); continue; }
            let position = 0;
            for (let rule in rules[current]) {
                position++;
                for (let expr in rule.expr || []) {
                    let branch = branch_targets(expr);
                    if (branch != null) {
                        if (branch.opaque)
                            violation("foreign_chain_unsafe", where + " via " + current + " rule #" + position + ": opaque verdict map");
                        for (let target in branch.targets) push(stack, chain_key(chain.family, chain.table, target));
                        continue;
                    }
                    let key_name = expr_key(expr);
                    if (key_name == "drop" || key_name == "reject") {
                        push(caveats, where + " via " + current + " rule #" + position + ": " + key_name + " on the output path");
                        continue;
                    }
                    let risk = statement_risk(expr, probe_mark, rule);
                    if (risk != null)
                        violation("foreign_chain_unsafe", where + " via " + current + " rule #" + position + ": " + risk);
                }
            }
        }
    }

    // 5. Policy routing. Every probe packet is finally routed with the probe
    // mark (curl uid 0 or nfqws uid): only standard tables may be selected.
    // The first lookups (socket mark 0, nfqws desync marks) are re-routed by
    // the probe chains, but must not be blocked before they get there.
    if (ip_rules != null) {
        let desync_marks = [ mark_number(constants.ZAPRET_DESYNC_MARK), mark_number(constants.ZAPRET_DESYNC_MARK) | probe_mark ];
        let probe = { marks: [ probe_mark ], sport: options.sport_range || [ 61000, 61031 ], dport: options.dport || 443,
            uids: options.uids || [ 0 ], target: options.target || null, saddr: options.probe_saddr || null };
        let first = { ...probe, marks: [ 0, ...desync_marks ] };
        if (type(ip_rules) != "array") violation("ip_rules_unavailable");
        else for (let rule in ip_rules) {
            if (type(rule) != "object") { violation("ip_rule_unparsable"); continue; }
            let target = as_string(rule.table);
            let where = "priority " + as_string(rule.priority) + " -> " + (target || as_string(rule.action || rule.goto));
            let blocking = rule.action != null && index(BLOCKING_ACTIONS, as_string(rule.action)) >= 0;
            if (rule.action != null || rule.goto != null || index(STANDARD_TABLES, target) < 0) {
                let selects = rule_selects_probe(rule, probe);
                if (selects != false)
                    violation(selects == null ? "policy_route_undecidable" : "policy_route_matches_probe_mark", where);
            }
            if (blocking) {
                let selects = rule_selects_probe(rule, first);
                if (selects != false) violation("policy_route_blocks_probe", where);
            }
        }
    }

    result.ok = length(violations) == 0;
    if (!result.ok) result.reason = "isolation_unavailable";
    return result;
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return { evaluate, mark_number, reply_sets };

let fs = require("fs");
function read_json(path) {
    let data = fs.readfile(as_string(path));
    if (data == null) return null;
    try { return json(data); } catch (e) { return null; }
}
let mode = ARGV[0] || "";
if (mode == "evaluate") {
    // evaluate <nft-json> [context-json]; context: { ip_rules, options }.
    let listing = read_json(ARGV[1]);
    let context = ARGV[2] ? read_json(ARGV[2]) : null;
    let ip_rules = null, options = {};
    if (ARGV[2]) {
        ip_rules = type(context) == "object" ? context.ip_rules : "unavailable";
        options = type(context) == "object" && type(context.options) == "object" ? context.options : {};
    }
    let result = evaluate(type(listing) == "object" ? listing.nftables : null, ip_rules, options);
    print(sprintf("%J\n", result));
    exit(result.ok ? 0 : 1);
}
warn("Usage: autotune/contract.uc evaluate <nft-json> [context-json]\n");
exit(1);
