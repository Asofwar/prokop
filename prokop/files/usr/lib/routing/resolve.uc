#!/usr/bin/env ucode

// The one answer to "which Prokop rule handles this connection", calculated
// from the generated sing-box config and the Prokop UCI config. Autotune
// apply, Diagnostics (route_trace) and every later explanation use it.
//
// Pure and read-only: no traffic, no nft, no UCI writes. The answer is the
// first sing-box route rule the connection takes (first-match). When the
// config cannot prove it — lists sing-box cannot be asked about (remote,
// not downloaded), regexes, logical rules, source-scoped rules without a
// source, unknown fields, a resolve action above the owner of a FakeIP
// connection — the result says so with a reason instead of guessing.
// The only command it runs is "sing-box rule-set match" on a local list
// file, bounded in time.
let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let dpi_strategy = require("core.dpi_strategy");
let rulesets = require("singbox.rulesets");

const TPROXY_INBOUND = constants.SB_TPROXY_INBOUND_TAG || "tproxy-in";
const DIRECT_OUTBOUND = constants.SB_DIRECT_OUTBOUND_TAG || "direct-out";
const BYPASS_OUTBOUND = constants.SB_BYPASS_OUTBOUND_TAG || "bypass-out";
const DEFAULT_SINGBOX_CONFIG = "/etc/sing-box/config.json";
const FAKEIP_PREFIX = [ "198.18.0.0", 15 ];
// The local and reserved IPv4 ranges nft returns early for, before any rule
// chain (nft/apply.uc LOCALV4_RANGES, 240.0.0.0-255.255.255.255 written as
// its prefix): such a destination never reaches sing-box.
const LOCALV4_RANGES = [ "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4" ];
const LEGACY_CONNECTION_ACTIONS = [ "proxy", "outbound", "vpn" ];
const RULESET_MATCH_BIN = getenv("PROKOP_RULESET_MATCH_BIN") || "/usr/bin/sing-box";
function seconds_setting(value, fallback) {
    let n = int(value);
    return n > 0 ? n : fallback;
}
// Each sing-box question parses the whole list. One run is killed after
// RULESET_MATCH_TIMEOUT seconds, or sooner when less is left of the budget:
// one pass over the rules for a target (route_owner) spends at most
// RULESET_MATCH_BUDGET seconds asking about lists, so a route_trace answers
// within the 15s the page waits for it, DNS included. A caller resolving many
// targets for a waiting page limits the whole process (limit_ruleset_time).
// Past any of them, the list is undecidable (UC-220).
const RULESET_MATCH_TIMEOUT = seconds_setting(getenv("PROKOP_RULESET_MATCH_TIMEOUT"), 5);
const RULESET_MATCH_BUDGET = seconds_setting(getenv("PROKOP_RULESET_MATCH_BUDGET"), 6);

function as_string(v) { return v == null ? "" : "" + v; }
function list_of(v) { return v == null ? [] : type(v) == "array" ? v : [ v ]; }
function words(value) {
    value = trim(replace(as_string(value), /[ \t\r\n]+/g, " "));
    return value == "" ? [] : split(value, " ");
}
function number(value) {
    let text = lc(trim(as_string(value)));
    if (match(text, /^[0-9]+$/) != null) return int(text);
    if (substr(text, 0, 2) != "0x") return null;
    let result = 0;
    for (let i = 2; i < length(text); i++) {
        let d = index("0123456789abcdef", substr(text, i, 1));
        if (d < 0) return null;
        result = result * 16 + d;
    }
    return result;
}

// ---- Prokop UCI config ----------------------------------------------------

// A UCI value made of quoted/unquoted segments (same rules as snapshots.uc).
function uci_value(text) {
    let result = "", q = null;
    for (let i = 0; i < length(text); i++) {
        let c = substr(text, i, 1);
        if (q == "'") { if (c == "'") q = null; else result += c; }
        else if (q == "\"") {
            if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
            else if (c == "\"") q = null;
            else result += c;
        }
        else if (c == "'" || c == "\"") q = c;
        else if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
        else if (c == " " || c == "\t") break;
        else result += c;
    }
    return q == null ? result : null;
}

// Sections in file order: [{ type, name, options: { key: value | [values] } }].
function parse_config(text) {
    let sections = [], current = null;
    let lines = split(as_string(text), "\n");
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        let start = match(line, /^[ \t]*config[ \t]+([A-Za-z0-9_-]+)([ \t]+['"]?([A-Za-z0-9_-]+)['"]?)?/);
        if (start != null) {
            current = { type: start[1], name: start[3] || null, options: {} };
            push(sections, current);
            continue;
        }
        let opt = match(line, /^[ \t]*(option|list)[ \t]+([A-Za-z0-9_-]+)[ \t]+(.+)$/);
        if (current == null || opt == null) continue;
        let text_value = trim(opt[3]), raw = uci_value(text_value);
        while (raw == null && i + 1 < length(lines)) { text_value += "\n" + lines[++i]; raw = uci_value(text_value); }
        if (raw == null) raw = text_value;
        if (opt[1] == "list") {
            if (type(current.options[opt[2]]) != "array") current.options[opt[2]] = [];
            push(current.options[opt[2]], raw);
        }
        else current.options[opt[2]] = raw;
    }
    return sections;
}

// The shared reading of the flag (core/common, UC-105): the generator and nft
// count the same enabled rules.
function enabled(section) {
    return common.section_enabled(section.options);
}
function find_section(sections, name) {
    for (let s in sections) if (s.type == "section" && s.name == name) return s;
    return null;
}
function zapret_sections(sections) {
    return filter(sections, (s) => s.type == "section" && enabled(s) && s.options.action == "zapret");
}
function settings_of(sections) {
    for (let s in sections) if (s.type == "settings") return s.options;
    return {};
}
function singbox_config_path(sections) {
    return as_string(settings_of(sections).config_path) || DEFAULT_SINGBOX_CONFIG;
}
function load_json(path) {
    let data = path == "" ? null : fs.readfile(path);
    try { return data == null ? null : json(data); } catch (e) { return null; }
}

// What the rule's strategy applies to: matcher names and sizes, no values of
// secrets (matchers are never secrets, but only counts and list names are kept).
// The counts are informational (the autotune plan JSON). A string value is
// counted by whitespace, unlike the generator and nft, which split the
// *_text options at commas too (config/rule.uc text_list_values
// "comma-space"): "a.com,b.com" counts as one here. Not unified (UC-172):
// it would change the plan JSON.
function rule_scope(section) {
    let scope = {};
    for (let key in [ "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr", "community_lists",
                      "rule_set", "rule_set_with_subnets", "domain_ip_lists", "ports", "source_ip_cidr", "fully_routed_ips" ]) {
        let v = section.options[key];
        if (v == null || v == "") continue;
        scope[key] = key == "community_lists" ? (type(v) == "array" ? v : words(v)) : (type(v) == "array" ? length(v) : length(words(v)));
    }
    return scope;
}

// ---- which rule handles the target ---------------------------------------

function in_prefix(ip, prefix, len) {
    let parse = (t) => {
        let m = match(as_string(t), /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
        if (m == null) return null;
        return ((int(m[1]) * 256 + int(m[2])) * 256 + int(m[3])) * 256 + int(m[4]);
    };
    let a = parse(ip), b = parse(prefix);
    if (a == null || b == null) return false;
    let size = 1;
    for (let i = 0; i < 32 - len; i++) size *= 2;
    return int(a / size) == int(b / size);
}
function cidr_contains(cidr, ip) {
    let m = match(as_string(cidr), /^([0-9.]+)(\/([0-9]+))?$/);
    return m != null && in_prefix(ip, m[1], m[3] ? int(m[3]) : 32);
}
function is_fakeip(ip) {
    return in_prefix(ip, FAKEIP_PREFIX[0], FAKEIP_PREFIX[1]);
}
function is_localv4(ip) {
    for (let c in LOCALV4_RANGES) if (cidr_contains(c, ip)) return true;
    return false;
}

// The connection being asked about. fakeip: the target reaches sing-box as
// a FakeIP address (replaced by the domain name); defaults to whether ip is
// in the FakeIP range. Without a source, source-scoped rules are undecidable,
// unless assume_rule_source asks "for the devices of the first source-scoped
// rule that takes the destination" (resolve() then names the address it used).
function target(host, ip, opts) {
    opts = type(opts) == "object" ? opts : {};
    return {
        host: lc(as_string(host)),
        ip: as_string(ip),
        fakeip: opts.fakeip != null ? !!opts.fakeip : is_fakeip(ip),
        network: lc(as_string(opts.network || "tcp")),
        port: opts.port != null && as_string(opts.port) != "" ? int(opts.port) : 443,
        source: as_string(opts.source),
        assume_rule_source: opts.assume_rule_source === true
    };
}

function port_matches(rule, port) {
    if (rule.port == null && rule.port_range == null) return true;
    for (let p in list_of(rule.port)) if (int(p) == port) return true;
    for (let r in list_of(rule.port_range)) {
        let m = match(as_string(r), /^([0-9]*):([0-9]*)$/);
        if (m && (m[1] == "" || port >= int(m[1])) && (m[2] == "" || port <= int(m[2]))) return true;
    }
    return false;
}
const RULE_KEYS = [ "action", "outbound", "inbound", "domain", "domain_suffix", "domain_keyword", "domain_regex",
    "ip_cidr", "rule_set", "source_ip_cidr", "port", "port_range", "network", "protocol" ];
// Sniffed protocols a TCP connection to a site can never have (disable_quic
// adds a protocol=quic reject rule in front of every section rule,
// exclude_bittorrent a protocol=bittorrent route): a site speaks TLS or HTTP.
const NON_SITE_PROTOCOLS = [ "quic", "dtls", "stun", "bittorrent" ];
const RESOLVE_KEYS = [ "action", "server", "strategy", "disable_cache", "rewrite_ttl", "client_subnet" ];

// A copy of a rule without the given (action-specific) option keys.
function filter_keys(r, drop) {
    let copy = {};
    for (let k, v in r) if (index(drop, k) < 0) copy[k] = v;
    return copy;
}

// The local list files of the generated config: { tag: { format, path } }.
function local_rule_sets(config) {
    let result = {};
    let list = type(config) == "object" && type(config.route) == "object" ? config.route.rule_set : null;
    for (let e in list_of(list)) {
        if (type(e) != "object" || e.type != "local" || as_string(e.tag) == "" || as_string(e.path) == "") continue;
        let format = e.format == null ? "source" : as_string(e.format);
        if (format != "binary" && format != "source") continue;
        result[e.tag] = { format, path: as_string(e.path) };
    }
    return result;
}

// The answer of "sing-box rule-set match": one line "match rules.[<i>]: ..."
// per matching rule, printed with Go's builtin println, i.e. on stderr; no
// line at all when nothing matches (the exit status is 0 either way). Any
// other output is not an answer: "unknown".
function rule_set_answer(output) {
    let answer = "no";
    for (let line in split(as_string(output), "\n")) {
        if (line == "") continue;
        if (substr(line, 0, 13) != "match rules.[") return "unknown";
        answer = "match";
    }
    return answer;
}

// Seconds spent asking about lists (sing-box runs, reading source lists):
// by the current pass over the rules, and by this process against the limit
// a caller set (null: none).
let ruleset_pass_spent = 0, ruleset_process_spent = 0, ruleset_process_limit = null;
function monotonic() {
    let now = clock(true);
    return now[0] + now[1] / 1e9;
}
// Whole seconds left now; below 1, nothing more is asked.
function ruleset_seconds_left() {
    let left = RULESET_MATCH_BUDGET - ruleset_pass_spent;
    if (ruleset_process_limit != null && ruleset_process_limit - ruleset_process_spent < left)
        left = ruleset_process_limit - ruleset_process_spent;
    return left < 1 ? 0 : int(left);
}
function ruleset_spend(started) {
    let seconds = monotonic() - started;
    ruleset_pass_spent += seconds;
    ruleset_process_spent += seconds;
}
// From now on this process spends at most `seconds` more asking about lists.
function limit_ruleset_time(seconds) {
    ruleset_process_limit = ruleset_process_spent + seconds_setting(seconds, 0);
}

// One bounded sing-box run: everything it printed (stdout and stderr), or
// null when it failed, was killed at RULESET_MATCH_TIMEOUT or at what is
// left of the budget, or nothing is left. The watchdog counts the seconds
// with one-second sleeps: killed when sing-box ends, it leaves at most one
// of them behind for less than a second (a trap cannot reliably take a
// longer sleep down: the kill can land before the sleep is recorded).
function run_singbox(args) {
    let left = ruleset_seconds_left();
    if (left < 1) return null;
    let timeout = left < RULESET_MATCH_TIMEOUT ? left : RULESET_MATCH_TIMEOUT;
    let script = common.shell_command(args) + " 2>&1 & child=$!; " +
        "( i=0; while [ \"$i\" -lt " + timeout + " ]; do sleep 1; i=$((i + 1)); done; " +
        "kill -KILL \"$child\" 2>/dev/null ) >/dev/null 2>&1 & watchdog=$!; " +
        "wait \"$child\"; rc=$?; kill \"$watchdog\" 2>/dev/null; exit \"$rc\"";
    let started = monotonic();
    let pipe = fs.popen(common.shell_command([ "sh", "-c", script ]) + " 2>/dev/null", "r");
    if (pipe == null) return null;
    let output = as_string(pipe.read("all"));
    let status = pipe.close();
    ruleset_spend(started);
    return status == 0 ? output : null;
}

// Answers and list shapes already known in this process, by list file
// (path, format, inode, size, mtime, ctime) and value: each is asked once,
// however many rules name the list and however many targets are resolved.
let ruleset_answers = {}, ruleset_shapes = {};

// Whether sing-box can answer for a list file: its rules are plain
// destination-address matchers (singbox/rulesets.uc list_shape, UC-218). A
// source list is read here. A binary one is never decompiled here: for a
// large list that costs seconds and far more memory than the questions it
// guards, in every process. Its shape is the one singbox/ruleset_cache.uc
// recorded when it stored and checked the file; a binary list without a
// record of the file as it is now (a local .srs of the user) is undecidable.
// Reading a source list counts against the budget like a sing-box run.
function list_is_plain(entry, file) {
    if (ruleset_shapes[file] == null) {
        let shape = null;
        if (entry.format == "binary")
            shape = rulesets.recorded_binary_shape(entry.path);
        else {
            if (ruleset_seconds_left() < 1) return false;
            let started = monotonic(), value = null;
            try { value = json(fs.readfile(entry.path)); } catch (e) { value = null; }
            ruleset_spend(started);
            shape = rulesets.list_shape(value);
        }
        ruleset_shapes[file] = shape == "plain";
    }
    return ruleset_shapes[file];
}

// Whether a list holds the value, asked of sing-box itself: "match", "no",
// or "unknown" when it cannot be asked (no local file, a list that is not
// plain, a failing, hung or over-budget command, output that is not an
// answer).
function rule_set_holds(entry, value) {
    let st = entry == null ? null : fs.stat(entry.path);
    if (st == null) return "unknown";
    let file = join("\n", [ entry.format, entry.path, join(":", [ st.inode, st.size, st.mtime, st.ctime ]) ]);
    if (!list_is_plain(entry, file)) return "unknown";
    let key = file + "\n" + value;
    if (ruleset_answers[key] == null) {
        let output = run_singbox([ RULESET_MATCH_BIN, "rule-set", "match", "-f", entry.format, entry.path, value ]);
        ruleset_answers[key] = output == null ? "unknown" : rule_set_answer(output);
    }
    return ruleset_answers[key];
}

// The values a list is asked about: the name a FakeIP connection reaches
// sing-box with; a real-address connection also by its address. null: the
// target is not a plain host/address and is never handed to a command.
function rule_set_values(t) {
    let values = [];
    if (t.host != "") {
        if (match(t.host, /^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$/) == null) return null;
        push(values, t.host);
    }
    if (!t.fakeip && t.ip != "") {
        if (match(t.ip, /^[0-9a-fA-F:.]+$/) == null) return null;
        push(values, t.ip);
    }
    return values;
}

// Whether a rule's matchers take the connection: "match", "no", or
// { reason } when that cannot be decided statically.
// A FakeIP connection reaches sing-box as the domain name (the FakeIP
// address is replaced by the FQDN), so ip_cidr matches nothing unless a
// resolve action filled real addresses in (route_owner refuses to decide
// past one); a real-address connection is matched by ip_cidr and by the
// sniffed domain. lists: local_rule_sets() of the config; without it a
// rule_set matcher is undecidable.
function rule_matches(r, t, lists) {
    if (r.type == "logical" || r.invert) return { reason: "logical_rule" };
    for (let key in keys(r)) if (index(RULE_KEYS, key) < 0) return { reason: "unknown_rule_field:" + key };
    if (r.network != null && index(list_of(r.network), t.network) < 0) return "no";
    if (!port_matches(r, t.port)) return "no";
    if (r.protocol != null) {
        if (t.network != "tcp") return { reason: "protocol_matcher" };
        let tcp_possible = filter(list_of(r.protocol), (p) => index(NON_SITE_PROTOCOLS, p) < 0);
        if (length(tcp_possible) == 0) return "no";
        return { reason: "protocol_matcher" };
    }
    let host = t.host, dest_fields = 0, dest = "no";
    let hit = () => { dest = "match"; };
    let unknown = () => { if (dest != "match") dest = "unknown"; };
    // sing-box lower-cases the host and compares each value as written: an
    // upper-case value never matches (the generator writes lower case,
    // UC-099).
    for (let d in list_of(r.domain)) { dest_fields++; if (host != "" && d == host) hit(); }
    for (let d in list_of(r.domain_suffix)) {
        dest_fields++;
        if (host == "") continue;
        // sing-box: ".example.com" matches subdomains only, "example.com"
        // the domain itself and its subdomains.
        let s = as_string(d), sub_only = substr(s, 0, 1) == ".";
        if (sub_only) s = substr(s, 1);
        if ((!sub_only && host == s) || (length(host) > length(s) + 1 && substr(host, length(host) - length(s) - 1) == "." + s)) hit();
    }
    for (let d in list_of(r.domain_keyword)) { dest_fields++; if (host != "" && index(host, as_string(d)) >= 0) hit(); }
    for (let d in list_of(r.domain_regex)) { dest_fields++; unknown(); }
    for (let c in list_of(r.ip_cidr)) { dest_fields++; if (!t.fakeip && cidr_contains(c, t.ip)) hit(); }
    for (let n in list_of(r.rule_set)) {
        dest_fields++;
        if (dest == "match") continue;
        let values = type(lists) == "object" ? rule_set_values(t) : null, held = "no";
        if (values == null) { unknown(); continue; }
        for (let v in values) {
            let answer = rule_set_holds(lists[n], v);
            if (answer == "match") { held = "match"; break; }
            if (answer == "unknown") held = "unknown";
        }
        if (held == "match") hit(); else if (held == "unknown") unknown();
    }
    if (dest_fields > 0 && dest == "no") return "no";
    if (dest == "unknown") return { reason: "undecidable_matcher" };
    if (r.source_ip_cidr != null) {
        if (t.source == "") return { reason: "source_scoped_rule" };
        let inside = false;
        for (let c in list_of(r.source_ip_cidr)) if (cidr_contains(c, t.source)) inside = true;
        if (!inside) return "no";
    }
    return "match";
}

function is_ipv4(ip) {
    return match(as_string(ip), /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) != null;
}
function takes_tproxy(r) {
    return type(r) == "object" && (r.inbound == null || index(list_of(r.inbound), TPROXY_INBOUND) >= 0);
}
function same_value(a, b) {
    return sprintf("%J", a) == sprintf("%J", b);
}

// A rule's own resolve rule (ByeDPI, resolve_real_ip_for_routing): the
// generator puts it directly before the rule's route rule, with the same
// matchers (singbox/route.uc resolve_rule_for_section). The route rule may
// add ip_cidr and network; nothing else differs.
const PAIRED_ROUTE_EXTRA_KEYS = [ "action", "outbound", "ip_cidr", "network" ];
function paired_route_rule(resolve_rule, next) {
    if (!takes_tproxy(next) || (next.action != null && next.action != "route" && next.action != "reject")) return false;
    let own = filter_keys(resolve_rule, RESOLVE_KEYS), route = filter_keys(next, PAIRED_ROUTE_EXTRA_KEYS);
    if (length(keys(own)) != length(keys(route))) return false;
    for (let k, v in own) if (!same_value(v, route[k])) return false;
    return true;
}

const DOMAIN_KEYS = [ "domain", "domain_suffix", "domain_keyword", "domain_regex", "rule_set" ];
// Whether a rule takes the address itself, the way nft does from the rule's
// sets: by ip_cidr, or by ports/devices when it has no destination matcher.
// A list (rule_set) is no proof: nft holds its addresses only when subnet
// extraction is on, which the sing-box config does not show.
function address_match(r, t, lists) {
    let has_dest = false;
    for (let k in [ ...DOMAIN_KEYS, "ip_cidr" ]) if (r[k] != null) has_dest = true;
    if (has_dest && r.ip_cidr == null) return "no";
    let m = rule_matches(filter_keys(r, DOMAIN_KEYS), { ...t, host: "" }, lists);
    return m == "match" || m == "no" ? m : "unknown";
}
// A real-address connection enters sing-box only when nft intercepts its
// address: the per-rule sets nft builds from the same rules (ip_cidr, ports,
// devices), first match in rule order; a bypass verdict leaves it on the
// direct path (nft/apply.uc priority_rules). "capture", { bypass: i }, or
// "unknown" when the rules do not prove it. A list that may hold the
// address counts both ways (in nft or not): only an outcome both share is
// proven.
function interception(rules, t, lists, from) {
    for (let i = from || 0; i < length(rules); i++) {
        let r = rules[i];
        if (!takes_tproxy(r)) continue;
        let action = r.action || "route";
        if (action != "route" && action != "reject") continue;
        let verdict = action == "route" && r.outbound == BYPASS_OUTBOUND ? { bypass: i } : "capture";
        if (r.rule_set != null) {
            let held = rule_matches(filter_keys(r, [ "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr" ]), { ...t, host: "" }, lists);
            if (held != "no") {
                let rest = interception(rules, t, lists, i + 1);
                if (verdict == "capture" && rest == "capture") return "capture";
                if (type(verdict) == "object" && type(rest) == "object") return verdict;
                return "unknown";
            }
        }
        let m = address_match(r, t, lists);
        if (m == "no") continue;
        return m == "match" ? verdict : "unknown";
    }
    return "unknown";
}

// First sing-box route rule the connection takes from the transparent proxy
// inbound: { decided, kind: outbound|reject|final, outbound, rule, reason }.
function route_owner(config, t) {
    let rules = type(config) == "object" && type(config.route) == "object" && type(config.route.rules) == "array" ? config.route.rules : null;
    if (rules == null) return { decided: false, reason: "singbox_config_unavailable" };
    // Outside the model (UC-096): IPv6 (tproxy6-in, FakeIP6, IPv6 matchers)
    // and a FakeIP address whose domain is not known (sing-box routes it by
    // the domain).
    if ((t.ip != "" && !is_ipv4(t.ip)) || (t.source != "" && !is_ipv4(t.source)))
        return { decided: false, reason: "ipv6_not_modelled" };
    if (t.fakeip && t.host == "") return { decided: false, reason: "fakeip_domain_unknown" };
    let lists = local_rule_sets(config);
    // Each pass asks about lists within a budget of its own.
    ruleset_pass_spent = 0;
    for (let i = 0; i < length(rules); i++) {
        let r = rules[i];
        if (!takes_tproxy(r)) continue;
        let action = r.action || "route";
        if (action == "hijack-dns") {
            // The asked connection carries the target's own traffic, not DNS:
            // a rule on the sniffed DNS protocol does not take it, one on the
            // port (53) does (UC-096).
            let dns = filter_keys(r, [ "action" ]);
            if (dns.protocol != null && length(filter(list_of(dns.protocol), (p) => p != "dns")) == 0) delete dns.protocol;
            if (length(keys(dns)) == 0 || (length(keys(dns)) == 1 && dns.inbound != null)) continue;
            if (rule_matches(dns, t, lists) != "no") return { decided: false, reason: "dns_hijack", rule: i };
            continue;
        }
        if (action == "resolve") {
            if (!t.fakeip) continue;
            if (rule_matches(filter_keys(r, RESOLVE_KEYS), t, lists) == "no") continue;
            // The rule's own resolve rule: its route rule takes the
            // connection by the same domain after the resolve, so that rule
            // decides; when it would not, the route depends on the answer
            // (UC-103).
            if (i + 1 < length(rules) && paired_route_rule(r, rules[i + 1]) && rule_matches(rules[i + 1], t, lists) != "no") continue;
            return { decided: false, reason: "resolve_rule", rule: i };
        }
        if (action != "route" && action != "reject") continue;
        let m = rule_matches(r, t, lists);
        if (m == "no") continue;
        if (type(m) == "object")
            return { decided: false, reason: m.reason, rule: i, sources: m.reason == "source_scoped_rule" ? list_of(r.source_ip_cidr) : null };
        // A local or reserved real address: nft returns it before any rule
        // chain, whatever rule names it; the connection goes directly
        // (nft/apply.uc mangle, mangle_output).
        if (!t.fakeip && is_localv4(t.ip)) return { decided: false, reason: "local_address_not_intercepted", rule: i };
        // A real address taken by its domain: sing-box sees it only when nft
        // intercepts the address (UC-100).
        if (!t.fakeip && address_match(r, t, lists) != "match") {
            let seen = interception(rules, t, lists);
            if (type(seen) == "object")
                return { decided: true, kind: "outbound", outbound: rules[seen.bypass].outbound, rule: seen.bypass,
                    source_scoped: rules[seen.bypass].source_ip_cidr != null };
            if (seen != "capture") return { decided: false, reason: "real_address_interception_unknown", rule: i };
        }
        if (action == "reject") return { decided: true, kind: "reject", rule: i };
        return { decided: true, kind: "outbound", outbound: r.outbound, rule: i, source_scoped: r.source_ip_cidr != null };
    }
    return { decided: true, kind: "final", outbound: config.route.final || null, rule: null };
}

// The zapret rule behind a sing-box outbound: a direct outbound whose
// routing mark is the rule's route mark (base + position among enabled
// zapret rules), cross-checked against the outbound tag convention.
function zapret_owner(config, sections, outbound) {
    let base = number(constants.ZAPRET_ROUTE_MARK_BASE), queue_base = int(constants.ZAPRET_QUEUE_BASE);
    for (let o in list_of(config.outbounds)) {
        if (type(o) != "object" || o.tag != outbound || o.type != "direct" || o.routing_mark == null) continue;
        let index_value = int(o.routing_mark) - base;
        let zs = zapret_sections(sections);
        if (index_value < 1 || index_value > length(zs)) return null;
        let s = zs[index_value - 1];
        if (o.tag != s.name + "-out" && o.tag != s.name + "-out-1") return null;
        return { section: s.name, index: index_value, mark: sprintf("0x%08x", int(o.routing_mark)),
            mark_value: int(o.routing_mark), queue: queue_base + index_value - 1 };
    }
    return null;
}

// The enabled Prokop rule (config section) behind an outbound tag:
// <name>-out, <name>-out-<n>, <name>-urltest[-<id>]-out, <name>-<n>-out, ...
function section_for_outbound(sections, tag) {
    tag = as_string(tag);
    let best = null;
    for (let s in sections) {
        let name = as_string(s.name);
        if (s.type != "section" || !enabled(s) || name == "" || substr(tag, 0, length(name) + 1) != name + "-") continue;
        if (match(tag, /-out(-[0-9]+)?$/) == null) continue;
        if (best == null || length(name) > length(best.name)) best = s;
    }
    return best;
}

// An address the rule's source_ip_cidr covers: the base address of its first
// IPv4 entry (the resolver compares IPv4 sources only).
function source_of(cidrs) {
    for (let c in list_of(cidrs)) {
        let m = match(as_string(c), /^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(\/[0-9]+)?$/);
        if (m != null) return m[1];
    }
    return null;
}

// Undecidable: the config does not say. Unsupported: a rule shape the
// static resolver does not evaluate. Unavailable: no config to read.
function status_for(reason) {
    reason = as_string(reason);
    if (reason == "singbox_config_unavailable") return "unavailable";
    if (reason == "logical_rule" || reason == "protocol_matcher" || substr(reason, 0, 19) == "unknown_rule_field:") return "unsupported";
    return "undecidable";
}

// Structured answer for (config, sections, target):
// { status: decided|undecidable|unsupported|unavailable, reason,
//   route: outbound|reject|final, route_rule, kind: rule|bypass|block|direct|outbound,
//   section, label, action, outbound, dpi: { provider, strategy, custom },
//   zapret: { section, index, mark, mark_value, queue }, scope, provenance,
//   source_scope: null | { source, assumed } — the owner is a source-scoped
//   rule; assumed: the answer holds for the rule's own devices only (the
//   target asked with assume_rule_source and named no source) }
function resolve(config, sections, t) {
    let route = route_owner(config, t), assumed = null;
    if (!route.decided && route.reason == "source_scoped_rule" && t.assume_rule_source) {
        assumed = source_of(route.sources);
        if (assumed != null) route = route_owner(config, { ...t, source: assumed });
    }
    let result = { status: "decided", reason: null, route: null, route_rule: route.rule, kind: null,
        section: null, label: null, action: null, outbound: null, dpi: null, zapret: null, scope: null,
        provenance: "simulated", source_scope: null };
    if (!route.decided) {
        result.status = status_for(route.reason);
        result.reason = route.reason;
        result.provenance = "unknown";
        return result;
    }
    result.route = route.kind;
    result.outbound = route.outbound || null;
    if (route.source_scoped === true) result.source_scope = { source: assumed != null ? assumed : t.source, assumed: assumed != null };
    // Zapret identity (route mark and queue) is proven from the outbound
    // itself, exactly as autotune apply checks it.
    if (route.kind == "outbound") result.zapret = zapret_owner(config, sections, route.outbound);
    if (route.kind == "reject") { result.kind = "block"; result.action = "block"; return result; }
    if (result.outbound == BYPASS_OUTBOUND) { result.kind = "bypass"; result.action = "bypass"; return result; }
    if (route.kind == "final" && (result.outbound == null || result.outbound == DIRECT_OUTBOUND)) {
        result.kind = "direct"; result.action = "direct"; return result;
    }
    let section = section_for_outbound(sections, result.outbound);
    if (section == null) {
        result.kind = result.outbound == DIRECT_OUTBOUND ? "direct" : "outbound";
        result.action = result.kind == "direct" ? "direct" : null;
        return result;
    }
    let action = as_string(section.options.action);
    if (index(LEGACY_CONNECTION_ACTIONS, action) >= 0) action = "connection";
    result.kind = "rule";
    result.section = section.name;
    result.label = as_string(section.options.label) || section.name;
    result.action = action;
    result.scope = { rule: section.name, matchers: rule_scope(section) };
    if (dpi_strategy.is_dpi_action(action)) {
        let view = dpi_strategy.view(section.options);
        result.dpi = { provider: view.dpi_provider, strategy: view.dpi_strategy, custom: view.dpi_strategy_custom };
    }
    return result;
}

return {
    parse_config, enabled, find_section, zapret_sections, settings_of, singbox_config_path, load_json,
    rule_scope, is_fakeip, target, rule_matches, route_owner, zapret_owner, section_for_outbound, resolve,
    limit_ruleset_time
};
