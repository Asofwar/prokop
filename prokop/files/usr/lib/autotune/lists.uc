#!/usr/bin/env ucode

// Rule-list targets: a local sing-box rule set of the routing, measured
// through a few of its domains.
//
//   config autotune_target '<id>'
//       option rule_set 'Zapret-youtube-community-ruleset'
//       option sample '3'                 # domains measured, 1..8
//       list pin 'youtube.com'            # optional: exactly these domains
//
// At every expansion the list is read from its local file (a binary list is
// decompiled by sing-box itself), its domain and domain_suffix entries are
// taken (keywords and regexes name no host and are skipped), and a
// deterministic sample of them becomes the members of the target: evenly
// spaced over the sorted list, each slot taking the first domain from its
// position on that has an IPv4 address at the resolver of the target.
// Pinned domains replace the sample. The sample is kept in tmpfs while the
// list file, the options and the resolver stay the same: a day, or ten
// minutes for a sample DNS left short or a list that gave none.
// Members are ordinary targets "<id>__<n>" in groups, runs and the state.
let fs = require("fs");
let probe_module = require("autotune.probe");

const SINGBOX = getenv("PROKOP_AUTOTUNE_SINGBOX_BIN") || "/usr/bin/sing-box";
const DIG = getenv("PROKOP_AUTOTUNE_DIG") || "dig";
const DEFAULT_SAMPLE = 3;
const MAX_SAMPLE = 8;
// Domains tried from each slot position before the slot stays empty.
const TRIES_PER_SLOT = 4;
const CACHE_SECONDS = 86400;
// A sample DNS left short, or a list that gave none, is taken again sooner;
// the page asks for the status every few seconds and must not wait on DNS.
const RETRY_SECONDS = 600;

function as_string(v) { return v == null ? "" : "" + v; }
function list_of(v) { return v == null ? [] : type(v) == "array" ? v : [ v ]; }
function quote(v) { return "'" + replace(as_string(v), /'/g, "'\\''") + "'"; }
function command(args) { return join(" ", map(args, quote)); }
function capture(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return { status: -1, output: "" };
    let data = pipe.read("all");
    return { status: int(pipe.close()), output: as_string(data) };
}

function valid_tag(tag) { return match(as_string(tag), /^[A-Za-z0-9_.-]{1,96}$/) != null; }
function valid_sample(n) { return match(as_string(n), /^[0-9]+$/) != null && int(n) >= 1 && int(n) <= MAX_SAMPLE; }

// The local list files of a generated sing-box config: { tag: { format, path } }.
function local_rule_sets(config) {
    let result = {};
    let list = type(config) == "object" && type(config.route) == "object" ? config.route.rule_set : null;
    for (let e in list_of(list)) {
        if (type(e) != "object" || e.type != "local" || !valid_tag(e.tag) || as_string(e.path) == "") continue;
        let format = e.format == null ? "source" : as_string(e.format);
        if (format != "binary" && format != "source") continue;
        result[e.tag] = { format, path: as_string(e.path) };
    }
    return result;
}

// The source form of a list: read as it is, or decompiled into tmp_dir.
function source_of(entry, tmp_dir) {
    if (entry.format == "source") return fs.readfile(entry.path);
    let dir = trim(capture([ "mktemp", "-d", tmp_dir + "/prokop-autotune-list.XXXXXX" ]).output);
    if (dir == "") return null;
    let out = dir + "/list.json";
    let text = capture([ SINGBOX, "rule-set", "decompile", "-o", out, entry.path ]).status == 0 ? fs.readfile(out) : null;
    system(command([ "rm", "-rf", dir ]));
    return text;
}

// The hosts of one list rule into seen; a logical rule by its parts.
function take_rule(rule, seen, count) {
    if (type(rule) != "object") return;
    if (rule.type == "logical") { for (let r in list_of(rule.rules)) take_rule(r, seen, count); return; }
    for (let d in [ ...list_of(rule.domain), ...list_of(rule.domain_suffix) ]) {
        let host = lc(as_string(d));
        if (substr(host, 0, 1) == ".") host = substr(host, 1);
        if (probe_module.valid_host(host)) seen[host] = true; else count.skipped++;
    }
    count.skipped += length(list_of(rule.domain_keyword)) + length(list_of(rule.domain_regex));
}

// The domains of a list, sorted and unique: { domains, skipped } or { error }.
// skipped counts entries that name no host (keyword, regex, bad names).
function domains(entry, tmp_dir) {
    if (entry == null) return { error: "list_not_local" };
    if (fs.stat(entry.path) == null) return { error: "list_file_missing" };
    let text = source_of(entry, tmp_dir), parsed = null;
    try { parsed = json(text); } catch (e) { parsed = null; }
    if (type(parsed) != "object" || type(parsed.rules) != "array") return { error: "list_unreadable" };
    let seen = {}, count = { skipped: 0 };
    for (let rule in parsed.rules) take_rule(rule, seen, count);
    return { domains: sort(keys(seen)), skipped: count.skipped };
}

// Whether the resolver of the target gives the domain an IPv4 address; any
// answer counts, the measurement itself checks the address.
function resolves(host, dns) {
    let answer = capture([ DIG, "+short", "+time=2", "+tries=1", "@" + dns, host, "A" ]);
    for (let line in split(answer.output, "\n")) if (probe_module.valid_ipv4(trim(line))) return true;
    return false;
}

// Evenly spaced slots over the sorted list; each takes the first domain from
// its position on that resolves. Deterministic for the same list and DNS.
function sample(all, n, dns) {
    let picked = [], count = length(all);
    for (let slot = 0; slot < n && slot < count; slot++) {
        let start = int(slot * count / n);
        for (let k = 0; k < TRIES_PER_SLOT && k < count; k++) {
            let host = all[(start + k) % count];
            if (index(picked, host) >= 0) continue;
            if (dns == null || resolves(host, dns)) { push(picked, host); break; }
        }
    }
    return picked;
}

// The members of one list target: { tag, total, skipped, pinned, members,
// missing, error }. missing: pinned domains the list does not hold (they
// are not measured: the rule may not route them).
function expand(t, entry, dns, cache_dir, tmp_dir, now) {
    let base = { tag: t.rule_set, total: 0, skipped: 0, pinned: length(t.pins) > 0, members: [], missing: [], error: null };
    let st = entry != null ? fs.stat(entry.path) : null;
    let key = st == null ? null : join("|", [ t.rule_set, entry.path, st.mtime, st.size, t.sample, join(",", t.pins), as_string(dns) ]);
    let cache = cache_dir + "/" + t.id + ".json";
    if (key != null) {
        let cached = null;
        try { cached = json(fs.readfile(cache)); } catch (e) { cached = null; }
        if (type(cached) == "object" && cached.key == key && now - int(cached.at) < int(cached.ttl) && type(cached.view) == "object")
            return cached.view;
    }
    let d = domains(entry, tmp_dir), view = { ...base, error: d.error || null };
    if (d.error == null) {
        view.total = length(d.domains);
        view.skipped = d.skipped;
        if (view.pinned) {
            view.members = filter(t.pins, (p) => index(d.domains, p) >= 0);
            view.missing = filter(t.pins, (p) => index(d.domains, p) < 0);
        } else view.members = sample(d.domains, t.sample, dns);
        if (length(view.members) == 0) view.error = view.total == 0 ? "list_has_no_domains" : "list_domains_unresolved";
    }
    let full = view.error == null && (view.pinned || length(view.members) == (t.sample < view.total ? t.sample : view.total));
    if (key != null) {
        system(command([ "mkdir", "-p", cache_dir ]));
        fs.writefile(cache + ".tmp", sprintf("%J\n", { key, at: now, ttl: full ? CACHE_SECONDS : RETRY_SECONDS, view })) && fs.rename(cache + ".tmp", cache);
    }
    return view;
}

function member_id(id, n) { return id + "__" + n; }

return { DEFAULT_SAMPLE, MAX_SAMPLE, valid_tag, valid_sample, local_rule_sets, domains, sample, expand, member_id };
