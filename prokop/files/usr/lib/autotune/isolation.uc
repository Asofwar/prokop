#!/usr/bin/env ucode

// Isolated candidate probing for DPI autotune.
//
// A candidate strategy is tested without touching the production runtime:
// a temporary nft table (ProkopAutotuneProbe) queues only the probe's own
// connection, selected by destination and by a source-port range outside the
// kernel ephemeral range, to a temporary nfqws on a dedicated queue.
//
// Every packet of the probe tuple leaves the temporary chains with exactly the
// canonical probe mark (the Prokop outbound mark) and is routed with it:
//  - chain "premark" (route, -152) gives the probe connection the probe mark and
//    accepts, so the kernel re-routes it with that mark before anything else;
//  - chain "output" (route, -151) queues it to the candidate, and normalizes
//    packets injected by the temporary nfqws (desync | probe mark) back to the
//    probe mark (return: re-routed with it as well); anything else of the
//    tuple is dropped.
// Production is therefore only ever asked to honour one thing - its bypass
// for that mark - and autotune/contract.uc proves that bypass, the policy
// routing and the reply path from the live system before anything is created.
// Configuration, ProkopTable, the production nfqws and sing-box are never
// modified; every run ends with a verified teardown.
//
// Modes: "run" probes one candidate; "tune" (stage 4) measures several
// candidates interleaved through the same isolated path - one temporary
// nfqws per DPI candidate on its own queue, each candidate with a fixed slice
// of the source ports and a probe rule of its own for that slice (direct:
// accept with the probe mark) - and returns a selection from
// autotune/select.uc. Neither mode applies anything.
//
// Must be invoked as: ucode -L <lib> <lib>/autotune/isolation.uc <mode> ...
// (the autotune lock identifies its owner by that command line).
let fs = require("fs");
let constants = require("core.constants");
let identity = require("core.process_identity");
let catalog = require("autotune.catalog");
let probe_module = require("autotune.probe");
let contract = require("autotune.contract");
let select_module = require("autotune.select");
let autotune_lock = require("autotune.lock");

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const STATE_DIR = getenv("PROKOP_AUTOTUNE_STATE_DIR") || "/var/run/prokop/autotune";
const ACTIVE = STATE_DIR + "/active.json";
const WORKDIR = STATE_DIR + "/work";
const TABLE = "ProkopAutotuneProbe";
const MARK_CHAIN = "premark";
const MARK_PRIORITY = -152;
const CHAIN = "output";
const PRIORITY = -151;
const REPLY_CHAIN = "replies";
const REPLY_PRIORITY = -300;
const QUEUE = int(getenv("PROKOP_AUTOTUNE_QUEUE") || "4600");
// Queues of one run: one per DPI candidate, QUEUE .. QUEUE_LAST.
const MAX_QUEUES = 8;
const QUEUE_LAST = QUEUE + MAX_QUEUES - 1;
const PORT_FIRST = 61000;
// 64 source ports (D-4a): the largest catalog (8 TCP candidates) at the
// policy's highest probe count (7) fits without lowering the probes.
const PORT_LAST = 61063;
const PORT_RANGE = PORT_FIRST + "-" + PORT_LAST;
const PROD_TABLE = constants.NFT_TABLE_NAME;
const PROBE_MARK = constants.NFT_OUTBOUND_MARK;
const DESYNC_MARK = getenv("ZAPRET_DESYNC_MARK") || constants.ZAPRET_DESYNC_MARK;
const NFQWS = getenv("ZAPRET_NFQWS_BIN") || constants.ZAPRET_NFQWS_BIN;
// nfqws drops privileges to this uid; its injected packets may carry it.
const NFQWS_UID = 2147483647;
const PROC_QUEUE = getenv("PROKOP_AUTOTUNE_PROC_QUEUE") || "/proc/net/netfilter/nfnetlink_queue";
const PORT_RANGE_FILE = getenv("PROKOP_AUTOTUNE_PORT_RANGE_FILE") || "/proc/sys/net/ipv4/ip_local_port_range";
const PROC_NET = getenv("PROKOP_AUTOTUNE_PROC_NET") || "/proc/net";
const CHILD_PID_DIR = getenv("ZAPRET_CHILD_PID_DIR") || constants.ZAPRET_CHILD_PID_DIR;
const SNAPSHOT_LOCK = getenv("PROKOP_SNAPSHOT_LOCK_DIR") || "/var/run/prokop/config-snapshot.lock";
const GUARD_TABLES = [ "ProkopConfigRestoreDpiGuard", PROD_TABLE + "DpiGuard" ];
const VERIFY_TABLE = "ProkopAutotuneVerify";
const LISTENER_WAIT = int(getenv("PROKOP_AUTOTUNE_LISTENER_WAIT") || "5");
const TRACE = getenv("PROKOP_AUTOTUNE_TRACE") == "1";
const NFQWS_DEBUG = getenv("PROKOP_AUTOTUNE_NFQWS_DEBUG") == "1";
const MAX_PROBES = 5;
// A tuning run never uses more probe connections than source ports.
const MAX_TUNE_PROBES_TOTAL = PORT_LAST - PORT_FIRST + 1;
// Seconds the teardown waits, with the isolation intact, for the probe
// connections to finish closing and for queued packets to get a verdict.
const DRAIN_TIMEOUT = int(getenv("PROKOP_AUTOTUNE_DRAIN_TIMEOUT") || "3");
// Seconds the table is kept after nfqws stopped, until no socket of the probe
// tuple is left. The wait ends as soon as they are gone. TIME_WAIT lasts 60 s,
// but a probe the DPI blocked leaves an orphan with unacknowledged data that
// the kernel keeps retransmitting until tcp_orphan_retries run out: about
// 150 s on GL-MT6000 for a blocked target, where a 65 s hold discarded every
// measurement. The bound covers the retransmission with a margin.
const HOLD_TIMEOUT = int(getenv("PROKOP_AUTOTUNE_HOLD_TIMEOUT") || "300");
// Seconds to wait for production queues to be momentarily empty before the
// temporary hooks are registered or unregistered.
const QUIET_TIMEOUT = int(getenv("PROKOP_AUTOTUNE_QUIET_TIMEOUT") || "2");
// Where a tune reports its phase while it runs, for the page (the manager
// passes it; none: no reports). { phase, done, total, waited_s, timeout_s }.
const PROGRESS_FILE = getenv("PROKOP_AUTOTUNE_PROGRESS") || "";
const PROBE_MARK_VALUE = contract.mark_number(PROBE_MARK);
const DESYNC_MARK_VALUE = contract.mark_number(DESYNC_MARK);
const REQUIRED_COUNTERS = [ "probe_mark", "reinjected", "reinjected_bare", "unexpected" ];
// A probe rule carries one of these comments; the probe rule of a tuning
// slice adds ":<candidate>".
const PROBE_RULE_COMMENTS = [ "probe", "direct", "released" ];
// Production queue ranges the dedicated queue must stay out of.
const RESERVED_QUEUES = [
    [ int(constants.ZAPRET_QUEUE_BASE), int(constants.ZAPRET_QUEUE_BASE) + int(constants.ZAPRET_QUEUE_RANGE_SIZE) - 1 ],
    [ int(constants.ZAPRET2_QUEUE_BASE), int(constants.ZAPRET2_QUEUE_BASE) + int(constants.ZAPRET2_QUEUE_RANGE_SIZE) - 1 ]
];

let interrupted = false;
let timeline = [];

function as_string(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(as_string(v), /'/g, "'\\''") + "'"; }
function command(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}
function capture(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return { status: -1, output: "" };
    let data = pipe.read("all");
    return { status: int(pipe.close()), output: as_string(data) };
}
function success(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function pause() { system("sleep 1"); }

function now() {
    let c = type(clock) == "function" ? clock() : null;
    let sec = c ? c[0] : time(), msec = c ? int(c[1] / 1000000) : 0;
    let t = localtime(sec);
    return sprintf("%02d:%02d:%02d.%03d", t.hour, t.min, t.sec, msec);
}
// The phase of a running tune: preparing, measuring (done/total probes),
// holding (waiting for probe connections to close), cleaning. Best effort.
function progress(phase, extra) {
    if (PROGRESS_FILE == "") return;
    let tmp = PROGRESS_FILE + ".tmp";
    if (fs.writefile(tmp, sprintf("%J\n", { phase, at: time(), ...(extra || {}) })) != null) fs.rename(tmp, PROGRESS_FILE);
}

function mark(step, event, extra) {
    let entry = { step, event, at: now() };
    if (extra != null) entry.detail = extra;
    push(timeline, entry);
}

function hex_value(text) {
    let result = 0;
    text = lc(as_string(text));
    if (text == "") return null;
    for (let i = 0; i < length(text); i++) {
        let digit = index("0123456789abcdef", substr(text, i, 1));
        if (digit < 0) return null;
        result = result * 16 + digit;
    }
    return result;
}

function queue_reserved() {
    for (let range in RESERVED_QUEUES)
        if (QUEUE <= range[1] && QUEUE_LAST >= range[0]) return true;
    return false;
}
function in_run_range(queue) { return queue >= QUEUE && queue <= QUEUE_LAST; }
function pidfile_for(queue) { return STATE_DIR + "/nfqws-" + queue + ".pid"; }

// ---- lock --------------------------------------------------------------

// The shared autotune lock (autotune/lock.uc): one probe, tune or apply at a time.
function owner_pid() { return autotune_lock.owner_pid(); }

// ---- observation -------------------------------------------------------

// "present", "absent" or "unknown" (nft failed): only a successful listing
// that lacks the table counts as absent.
function table_state(name) {
    let out = capture([ "nft", "list", "tables" ]);
    if (out.status != 0) return "unknown";
    for (let line in split(out.output, "\n"))
        if (trim(line) == "table inet " + name) return "present";
    return "absent";
}
function table_exists(name) { return table_state(name) != "absent"; }

function nft_listing(args) {
    let listing = capture(args);
    if (listing.status != 0 || trim(listing.output) == "") return null;
    try {
        let parsed = json(listing.output);
        return type(parsed) == "object" && type(parsed.nftables) == "array" ? parsed.nftables : null;
    }
    catch (e) { return null; }
}
function nft_json(name) { return nft_listing([ "nft", "-j", "list", "table", "inet", name ]); }

// Counters move with live traffic; the structure of the table must not.
function without_counters(value) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value) push(result, without_counters(item));
        return result;
    }
    if (type(value) != "object") return value;
    let result = {};
    for (let key in keys(value)) {
        if (key == "counter" && type(value[key]) == "object")
            result[key] = { packets: 0, bytes: 0 };
        else
            result[key] = without_counters(value[key]);
    }
    return result;
}

function sha(text) {
    // mktemp creates the file exclusively; status must not create runtime state.
    let path = trim(capture([ "mktemp", "/tmp/prokop-autotune-hash.XXXXXX" ]).output);
    if (path == "" || fs.writefile(path, text) == null) { if (path != "") fs.unlink(path); return ""; }
    let out = capture([ "sha256sum", path ]);
    fs.unlink(path);
    let m = match(out.output, /^([0-9a-f]{64})/);
    return m ? m[1] : "";
}

function queues() {
    let result = [];
    for (let line in split(as_string(fs.readfile(PROC_QUEUE)), "\n")) {
        let f = split(trim(line), /[ \t]+/);
        if (length(f) < 8 || match(f[0], /^[0-9]+$/) == null) continue;
        push(result, { queue: int(f[0]), portid: f[1], total: int(f[2]), dropped: int(f[5]),
            user_dropped: int(f[6]), id_sequence: int(f[7]) });
    }
    return result;
}
function queue_entry(number) {
    for (let q in queues()) if (q.queue == number) return q;
    return null;
}
function run_queues() { return filter(queues(), (q) => in_run_range(q.queue)); }

// Registering or unregistering a base chain affects packets that sit in an
// NFQUEUE at that instant. Wait (bounded) for production queues to be empty.
function production_queues_quiet() {
    let result = { quiet: false, waited_s: 0, pending: 0 };
    for (let i = 0; ; i++) {
        let pending = 0;
        for (let q in queues()) if (!in_run_range(q.queue)) pending += q.total;
        result.pending = pending;
        if (pending == 0) { result.quiet = true; break; }
        if (i >= QUIET_TIMEOUT) break;
        pause();
        result.waited_s++;
    }
    return result;
}

function child_records() {
    let result = [];
    for (let name in sort(fs.lsdir(CHILD_PID_DIR) || [])) {
        if (match(name, /\.pid$/) == null) continue;
        let saved = identity.read_record(CHILD_PID_DIR + "/" + name);
        push(result, name + "=" + (saved ? saved.pid + ":" + saved.ticks : "invalid"));
    }
    return result;
}

function guards_present() {
    let result = [];
    for (let name in GUARD_TABLES) if (table_exists(name)) push(result, name);
    // The transition guard chain that a sing-box transition whose rollback
    // failed keeps in the production table (service/lifecycle.uc, UC-019).
    if (capture([ "nft", "list", "chain", "inet", PROD_TABLE, "prokop_transition_guard" ]).status == 0)
        push(result, PROD_TABLE + ":prokop_transition_guard");
    return result;
}

function ip_json(args) {
    let out = capture(args);
    if (out.status != 0) return null;
    try { return json(out.output); } catch (e) { return null; }
}

// The route of the probe tuple as the kernel resolves it. All probe packets
// are routed with the probe mark; the unmarked lookup (the socket's own route,
// which picked the source address) must be the same route.
function route_lookup(ip, mark_value) {
    let routes = ip_json([ "ip", "-j", "route", "get", ip, "mark", mark_value, "ipproto", "tcp",
        "sport", "" + PORT_FIRST, "dport", "443", "uid", "0" ]);
    let route = type(routes) == "array" ? routes[0] : null;
    if (type(route) != "object") return null;
    return { dev: route.dev || null, gateway: route.gateway || null, prefsrc: route.prefsrc || null,
        type: route.type || "unicast" };
}
function probe_route(ip) {
    let marked = route_lookup(ip, PROBE_MARK), unmarked = route_lookup(ip, "0");
    if (marked == null || unmarked == null) return { ok: false, reason: "route_unavailable" };
    let result = { ok: true, ...marked, unmarked };
    if (marked.dev == "lo" || marked.type != "unicast") { result.ok = false; result.reason = "probe_route_local"; }
    else if (marked.dev != unmarked.dev || marked.gateway != unmarked.gateway || marked.prefsrc != unmarked.prefsrc) {
        result.ok = false; result.reason = "probe_route_differs_from_socket_route";
    }
    return result;
}

// The production state the run compares before and after, together with the
// table listing it was hashed from (so the contract can be checked on it).
function production_snapshot(ip) {
    let table = nft_json(PROD_TABLE);
    let other = [];
    for (let q in queues()) if (!in_run_range(q.queue)) push(other, q.queue + ":" + q.portid);
    return { table, state: {
        prokop_table_hash: table == null ? "absent" : sha(sprintf("%J", without_counters(table))),
        queues: other,
        zapret_children: child_records(),
        guards: guards_present(),
        ip_rules_hash: sha(capture([ "ip", "-j", "rule" ]).output),
        route: ip ? probe_route(ip) : null
    } };
}
function production_state(ip) { return production_snapshot(ip).state; }
function same_state(a, b) { return sprintf("%J", a) == sprintf("%J", b); }

function legacy_tables() {
    let result = [];
    for (let file in [ "ip_tables_names", "ip6_tables_names" ])
        for (let line in split(as_string(fs.readfile(PROC_NET + "/" + file)), "\n"))
            if (trim(line) != "") push(result, trim(line));
    return result;
}

// The contract on the live ruleset (terse: no set elements), plus the
// elements of the interface sets production inbound rules gate on.
function bypass_contract(route, ip) {
    let listing = nft_listing([ "nft", "-j", "-t", "list", "ruleset" ]);
    let sets = {};
    for (let name in contract.reply_sets(listing, PROD_TABLE)) {
        let set = null;
        for (let item in nft_listing([ "nft", "-j", "list", "set", "inet", PROD_TABLE, name ]) || [])
            if (type(item.set) == "object") set = item.set;
        if (set != null) {
            let elements = [];
            for (let e in set.elem || []) push(elements, e);
            sets[name] = elements;
        }
    }
    let result = contract.evaluate(listing, ip_json([ "ip", "-j", "rule" ]) || "unavailable", {
        probe_mark: PROBE_MARK, own_table: TABLE, own_priority: PRIORITY, prod_table: PROD_TABLE,
        target: ip, probe_saddr: route.prefsrc, reply_dev: route.dev, sets,
        sport_range: [ PORT_FIRST, PORT_LAST ], dport: 443, uids: [ 0, NFQWS_UID ],
        legacy_tables: legacy_tables()
    });
    result.sets = sets;
    return result;
}

// Counters of every rule of the temporary table by comment; null when the
// listing is unavailable or incomplete.
// "probe", "direct" or "released" for a probe rule (of a slice as well),
// null for any other comment.
function probe_rule_kind(comment) {
    comment = as_string(comment);
    let colon = index(comment, ":");
    let kind = colon < 0 ? comment : substr(comment, 0, colon);
    return index(PROBE_RULE_COMMENTS, kind) >= 0 && (colon < 0 || colon < length(comment) - 1) ? kind : null;
}

// The SYN-ACK counter of a probe rule: "synack" for the run's rule,
// "synack:<id>" for a tuning slice.
function syn_ack_comment(comment) {
    comment = as_string(comment);
    let colon = index(comment, ":");
    return "synack" + (colon < 0 ? "" : substr(comment, colon));
}

// Counters by rule comment. One probe rule for the whole port range (run),
// or one per tuning slice, each comment once.
function probe_counters() {
    let table = nft_json(TABLE);
    if (table == null) return null;
    let result = {}, rules = 0, sliced = 0, plain = 0;
    for (let item in table) {
        let rule = item.rule;
        if (type(rule) != "object" || rule.table != TABLE) continue;
        let comment = as_string(rule.comment);
        for (let expr in rule.expr || [])
            if (type(expr) == "object" && type(expr.counter) == "object") {
                if (result[comment] != null) return null;
                result[comment] = { packets: int(expr.counter.packets), bytes: int(expr.counter.bytes) };
                if (probe_rule_kind(comment) != null) {
                    rules++;
                    if (index(comment, ":") >= 0) sliced++; else plain++;
                }
            }
    }
    for (let name in REQUIRED_COUNTERS)
        if (result[name] == null) return null;
    return (plain == 1 && sliced == 0) || (plain == 0 && sliced > 0) ? result : null;
}

// ---- runtime preconditions ---------------------------------------------

function queue_referenced(ruleset) {
    for (let m in match(ruleset, /queue( flags [a-z,]+)? (to|num) ([0-9]+)(-([0-9]+))?/g) || []) {
        let first = int(m[3]), last = m[5] ? int(m[5]) : first;
        if (first <= QUEUE_LAST && last >= QUEUE) return true;
    }
    return false;
}

function queue_check() {
    if (queue_reserved()) return "queue_overlaps_prokop_range";
    if (length(run_queues()) > 0) return "queue_in_use";
    let ruleset = capture([ "nft", "list", "ruleset" ]);
    if (ruleset.status != 0) return "ruleset_unavailable";
    if (queue_referenced(ruleset.output)) return "queue_referenced";
    return null;
}

function port_check() {
    let range = split(trim(as_string(fs.readfile(PORT_RANGE_FILE))), /[ \t]+/);
    if (length(range) != 2) return "port_range_unknown";
    if (!(PORT_LAST < int(range[0]) || PORT_FIRST > int(range[1]))) return "port_range_overlaps_ephemeral";
    for (let file in [ "tcp", "tcp6" ]) {
        for (let line in split(as_string(fs.readfile(PROC_NET + "/" + file)), "\n")) {
            let f = split(trim(line), /[ \t]+/);
            if (length(f) < 4 || index(f[1], ":") < 0) continue;
            let port = hex_value(substr(f[1], index(f[1], ":") + 1));
            // TIME_WAIT (06) leftovers of an earlier probe send no new data.
            if (port != null && port >= PORT_FIRST && port <= PORT_LAST && f[3] != "06")
                return "port_range_in_use";
        }
    }
    return null;
}

// /proc/net/tcp prints an address as the raw 32-bit value in host byte
// order: accept both renderings so little- and big-endian targets work.
function address_hex_forms(ip) {
    let m = match(as_string(ip), /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
    if (m == null) return [];
    let be = sprintf("%02X%02X%02X%02X", int(m[1]), int(m[2]), int(m[3]), int(m[4]));
    let le = sprintf("%02X%02X%02X%02X", int(m[4]), int(m[3]), int(m[2]), int(m[1]));
    return [ be, le,
        "0000000000000000FFFF0000" + le,      // ::ffff:a.b.c.d, little-endian words
        "00000000000000000000FFFF" + be ];    // ::ffff:a.b.c.d, big-endian words
}
// Sockets of the probe tuple (local port in the probe range, remote target:443).
function probe_sockets(ip) {
    let forms = address_hex_forms(ip);
    let result = { total: 0, closing: 0 };
    for (let file in [ "tcp", "tcp6" ]) {
        for (let line in split(as_string(fs.readfile(PROC_NET + "/" + file)), "\n")) {
            let f = split(trim(line), /[ \t]+/);
            if (length(f) < 4 || index(f[1], ":") < 0 || index(f[2], ":") < 0) continue;
            let port = hex_value(substr(f[1], index(f[1], ":") + 1));
            if (port == null || port < PORT_FIRST || port > PORT_LAST) continue;
            let remote = uc(substr(f[2], 0, index(f[2], ":")));
            if (index(forms, remote) < 0 || hex_value(substr(f[2], index(f[2], ":") + 1)) != 443) continue;
            result.total++;
            if (f[3] != "06") result.closing++;
        }
    }
    return result;
}

// ---- process ownership -------------------------------------------------

function nfqws_argv(opt, debug_file, queue) {
    let argv = [ NFQWS, "--qnum=" + (queue != null ? queue : QUEUE), "--dpi-desync-fwmark=" + DESYNC_MARK ];
    for (let word in catalog.words(opt)) push(argv, word);
    if (debug_file) push(argv, "--debug=@" + debug_file);
    return argv;
}
function signature_prefix(queue) {
    return [ NFQWS, "--qnum=" + queue, "--dpi-desync-fwmark=" + DESYNC_MARK ];
}

// Terminates a process only while its start time, executable and command line
// still match the recorded identity.
function stop_identified(saved, argv, exact) {
    if (identity.matches_record(saved, NFQWS, argv, exact, true) == "") return "not_ours";
    identity.signal_record(saved, NFQWS, argv, exact, "TERM");
    for (let i = 0; i < 3 && identity.matches_record(saved, NFQWS, argv, exact, true) != ""; i++) pause();
    if (identity.matches_record(saved, NFQWS, argv, exact, true) == "") return "stopped";
    identity.signal_record(saved, NFQWS, argv, exact, "KILL");
    for (let i = 0; i < 2 && identity.matches_record(saved, NFQWS, argv, exact, true) != ""; i++) pause();
    return identity.matches_record(saved, NFQWS, argv, exact, true) == "" ? "killed" : "failed";
}

// nfqws processes with the signature of a run: the very binary path, a
// queue of the run range and the desync mark. A run stops only the processes
// it recorded when it started them (pidfile: pid + start ticks); any other
// match - an admin's own nfqws on a run queue, say - is never signalled, and
// a run refuses while one exists (queue_in_use, UC-053).
function orphans() {
    let result = [];
    for (let name in fs.lsdir("/proc") || []) {
        if (match(name, /^[1-9][0-9]*$/) == null || name == owner_pid()) continue;
        let exe = replace(as_string(fs.readlink("/proc/" + name + "/exe")), / \(deleted\)$/, "");
        if (exe != NFQWS) continue;
        let argv = split(as_string(fs.readfile("/proc/" + name + "/cmdline")), "\0");
        let m = match(as_string(argv[1]), /^--qnum=([0-9]+)$/);
        if (m == null || !in_run_range(int(m[1]))) continue;
        let saved = { pid: name, queue: int(m[1]), ticks: identity.start_ticks(name), prefix: signature_prefix(int(m[1])) };
        if (saved.ticks != "" && identity.matches_record(saved, NFQWS, saved.prefix, false, true) != "")
            push(result, saved);
    }
    return result;
}

// What keeps a run or a cleanup from ending clean, for the operator to stop.
function blocking_nfqws(found) {
    return map(found, (o) => ({ pid: int(o.pid), queue: o.queue }));
}

// nfqws processes a run started: [{ queue, pidfile, argv }] from active.json,
// plus pidfiles without a recorded command line (active.json lost), which
// are identified by the run signature instead.
function nfqws_entries(active) {
    let result = [], known = {};
    for (let e in (type(active) == "object" && type(active.nfqws) == "array") ? active.nfqws : []) {
        if (type(e) != "object" || type(e.argv) != "array" || !in_run_range(int(e.queue))) continue;
        let entry = { queue: int(e.queue), pidfile: pidfile_for(int(e.queue)), argv: e.argv };
        known[entry.pidfile] = true;
        push(result, entry);
    }
    for (let name in sort(fs.lsdir(STATE_DIR) || [])) {
        let m = match(name, /^nfqws-([0-9]+)\.pid$/);
        if (m != null && !known[STATE_DIR + "/" + name])
            push(result, { queue: int(m[1]), pidfile: STATE_DIR + "/" + name, argv: null });
    }
    return result;
}
function pidfiles_present() {
    for (let name in fs.lsdir(STATE_DIR) || []) if (match(name, /^nfqws-[0-9]+\.pid$/) != null) return true;
    return false;
}

function read_active() {
    let data = fs.readfile(ACTIVE);
    if (data == null) return null;
    try { let parsed = json(data); return type(parsed) == "object" ? parsed : {}; }
    catch (e) { return {}; }
}

// The probe target as recorded in the temporary table itself (recovery when
// active.json is missing or malformed).
function table_target() {
    for (let item in nft_json(TABLE) || []) {
        let rule = item.rule;
        if (type(rule) != "object") continue;
        for (let expr in rule.expr || []) {
            let m = type(expr) == "object" ? expr.match : null;
            if (type(m) == "object" && type(m.left) == "object" && type(m.left.payload) == "object" &&
                m.left.payload.protocol == "ip" && m.left.payload.field == "daddr" && probe_module.valid_ipv4(m.right))
                return m.right;
        }
    }
    return null;
}

// The temporary chains as data: the nft batch is rendered from them and the
// regression tests evaluate exactly this model against production rulesets.
// Every rule is confined to the probe tuple; nothing outside it is touched.
// A probe rule: a candidate queue, direct (accept with the probe mark) or
// released (accept, after the candidates stopped).
// sport: the source ports of the rule ([first, last]), all of them when null.
function probe_rule_spec(queue, comment, sport) {
    return queue != null ? { comment: comment || "probe", verdict: "queue", queue, sport }
        : { comment: comment || "probe", verdict: "accept", queue: null, sport };
}

// The fixed source-port slices of a tuning run: the ports split evenly in
// the order given, a slice per candidate. A probe of a candidate leaves from
// its slice, so its packets, and the late ones of its earlier probes, can
// only take its own rule: no rule is switched between candidates.
function port_slices(ids) {
    let size = int((PORT_LAST - PORT_FIRST + 1) / length(ids));
    let result = {};
    for (let i = 0; i < length(ids); i++)
        result[ids[i]] = [ PORT_FIRST + i * size, PORT_FIRST + (i + 1) * size - 1 ];
    return result;
}

// spec: one probe rule spec, or the list of the slice rules of a tuning run.
function probe_chains(ip, spec) {
    let tuple = { daddr: ip, dport: 443, sport: [ PORT_FIRST, PORT_LAST ] };
    let injected = DESYNC_MARK_VALUE | PROBE_MARK_VALUE;
    let probe_rules = [];
    for (let rule in type(spec) == "array" ? spec : [ spec ])
        push(probe_rules, { comment: rule.comment, tuple: rule.sport ? { ...tuple, sport: rule.sport } : tuple,
            mark: PROBE_MARK_VALUE, set_mark: null, verdict: rule.verdict, queue: rule.queue });
    let chains = [
        { name: MARK_CHAIN, type: "route", hook: "output", priority: MARK_PRIORITY, rules: [
            // The probe connection: canonical probe mark, accepted so the
            // kernel re-routes it with that mark.
            { comment: "probe_mark", tuple, mark: 0, set_mark: PROBE_MARK_VALUE, verdict: "accept" }
        ] },
        { name: CHAIN, type: "route", hook: "output", priority: PRIORITY, rules: [
            // Injected by the temporary nfqws for the probe connection
            // (desync | probe mark): normalized to the canonical probe mark.
            { comment: "reinjected", tuple, mark: injected, set_mark: PROBE_MARK_VALUE, verdict: "return" },
            // Injected with the bare desync mark: normalized the same way.
            { comment: "reinjected_bare", tuple, mark: DESYNC_MARK_VALUE, set_mark: PROBE_MARK_VALUE, verdict: "return" },
            // The marked probe connection goes to the candidate (of its slice).
            ...probe_rules,
            // Anything else of the probe tuple: never handed to production.
            { comment: "unexpected", tuple, mark: null, set_mark: null, verdict: "drop" }
        ] }
    ];
    // Counts only, no verdict: the SYN-ACKs the target sends to each probe
    // rule's source ports. curl reports a TLS handshake the DPI blackholes as
    // "Connection timed out" with time_connect 0, so only a SYN-ACK proves
    // the TCP connection was up (probe.uc handshake).
    let replies = [];
    for (let rule in type(spec) == "array" ? spec : [ spec ]) {
        let colon = index(rule.comment || "", ":");
        push(replies, { comment: "synack" + (colon < 0 ? "" : substr(rule.comment, colon)),
            reply: { saddr: ip, sport: 443, dport: rule.sport || [ PORT_FIRST, PORT_LAST ] }, syn_ack: true,
            mark: null, set_mark: null, verdict: null });
    }
    if (TRACE)
        // Evidence only: marks the replies for nft trace and counts them.
        push(replies, { comment: "reply", reply: { saddr: ip, sport: 443, dport: [ PORT_FIRST, PORT_LAST ] },
            mark: null, set_mark: null, verdict: null });
    push(chains, { name: REPLY_CHAIN, type: "filter", hook: "prerouting", priority: REPLY_PRIORITY, rules: replies });
    return chains;
}

function render_rule(rule) {
    let text = rule.reply
        ? "ip saddr " + rule.reply.saddr + " tcp sport " + rule.reply.sport + " tcp dport " + rule.reply.dport[0] + "-" + rule.reply.dport[1]
        : "ip daddr " + rule.tuple.daddr + " tcp dport " + rule.tuple.dport + " tcp sport " + rule.tuple.sport[0] + "-" + rule.tuple.sport[1];
    if (rule.syn_ack) text += " tcp flags & (syn | ack) == syn | ack";
    if (rule.mark != null) text += sprintf(" meta mark 0x%08x", rule.mark);
    if (TRACE) text += " meta nftrace set 1";
    if (rule.set_mark != null) text += sprintf(" meta mark set 0x%08x", rule.set_mark);
    text += " counter";
    if (rule.verdict == "queue") text += " queue num " + rule.queue;
    else if (rule.verdict != null) text += " " + rule.verdict;
    return text + " comment \"" + rule.comment + "\"";
}

function batch(ip, spec) {
    let text = "create table inet " + TABLE + "\n";
    for (let chain in probe_chains(ip, spec)) {
        text += "add chain inet " + TABLE + " " + chain.name + " { type " + chain.type + " hook " + chain.hook +
            " priority " + chain.priority + "; policy accept; }\n";
        for (let rule in chain.rules)
            text += "add rule inet " + TABLE + " " + chain.name + " " + render_rule(rule) + "\n";
    }
    return text;
}

function probe_rule_handles() {
    let result = [];
    for (let item in nft_json(TABLE) || [])
        if (type(item.rule) == "object")
            push(result, { chain: item.rule.chain, handle: item.rule.handle, comment: item.rule.comment });
    return result;
}

// Quiesce while the candidate still runs: the probe connections finish their
// closing handshake and queued packets get their verdict. Skipped on signal.
function drain(ip, queue_candidate) {
    let result = { settled: false, waited_s: 0, closing_sockets: 0, queue_pending: 0 };
    for (let i = 0; ; i++) {
        let sockets = probe_sockets(ip), pending = 0;
        if (queue_candidate) for (let q in run_queues()) pending += q.total;
        result.closing_sockets = sockets.closing;
        result.queue_pending = pending;
        if (sockets.closing == 0 && result.queue_pending == 0) { result.settled = true; break; }
        if (interrupted || i >= DRAIN_TIMEOUT) break;
        pause();
        result.waited_s++;
    }
    return result;
}

// The source ports a probe rule of the listing matches: [first, last], or
// null when the listing does not show one range.
function listed_sport(rule) {
    for (let expr in rule.expr || []) {
        let m = type(expr) == "object" ? expr.match : null;
        if (type(m) != "object" || type(m.left) != "object" || type(m.left.payload) != "object" ||
            m.left.payload.protocol != "tcp" || m.left.payload.field != "sport") continue;
        if (type(m.right) == "object" && type(m.right.range) == "array" && length(m.right.range) == 2)
            return [ int(m.right.range[0]), int(m.right.range[1]) ];
        if (type(m.right) == "int") return [ m.right, m.right ];
        return null;
    }
    return null;
}

// Release the probe connections from the candidates before they stop: every
// probe rule becomes an accept of the canonical probe mark for its own
// source ports, in one atomic batch of replaces (no hook is registered or
// removed), so late packets (FIN/ACK, TIME_WAIT ACKs) leave through the
// production bypass instead of being dropped (which would make the peer
// retransmit and keep the sockets alive) or queued without a listener.
function release_probe_rule(ip) {
    let listing = nft_json(TABLE);
    if (listing == null) return "failed";
    let lines = [], plain = 0, slices = 0;
    for (let item in listing) {
        if (type(item.rule) != "object" || item.rule.chain != CHAIN) continue;
        let comment = as_string(item.rule.comment), kind = probe_rule_kind(comment);
        if (kind == null) continue;
        let sliced = index(comment, ":") >= 0;
        if (sliced) slices++; else plain++;
        if (kind == "released") continue;
        let sport = sliced ? listed_sport(item.rule) : [ PORT_FIRST, PORT_LAST ];
        if (sport == null) return "failed";
        let rule = { comment: sliced ? "released" + substr(comment, index(comment, ":")) : "released",
            tuple: { daddr: ip, dport: 443, sport }, mark: PROBE_MARK_VALUE, set_mark: null, verdict: "accept", queue: null };
        push(lines, "replace rule inet " + TABLE + " " + CHAIN + " handle " + item.rule.handle + " " + render_rule(rule));
    }
    if (!((plain == 1 && slices == 0) || (plain == 0 && slices > 0))) return "failed";
    if (length(lines) == 0) return "already_released";
    let file = WORKDIR + "/release.nft";
    if (fs.stat(WORKDIR) == null) fs.mkdir(WORKDIR, 0755);
    if (fs.writefile(file, join("\n", lines) + "\n") == null) return "failed";
    let ok = success([ "nft", "-f", file ]);
    fs.unlink(file);
    return ok ? "released" : "failed";
}

// Keep the table until no socket of the probe tuple is left, so no late packet
// can reach production classification after the table is gone. Not cut short
// by a signal: it is bounded and only waits.
function hold(ip) {
    let result = { settled: false, waited_s: 0, sockets: 0 };
    for (let i = 0; ; i++) {
        result.sockets = probe_sockets(ip).total;
        if (result.sockets == 0) { result.settled = true; break; }
        if (i >= HOLD_TIMEOUT) break;
        if (i % 5 == 0) progress("holding", { waited_s: result.waited_s, timeout_s: HOLD_TIMEOUT, sockets: result.sockets });
        pause();
        result.waited_s++;
    }
    return result;
}

// Idempotent teardown of everything a probe run can leave behind. Safe for:
// table+process, table only, process only, nothing, stale pidfile, PID reuse.
// report (optional) receives the drain/hold evidence of a live run.
function teardown(active, actions, report) {
    let ok = true, stopped = false;
    let state = table_state(TABLE);
    let table_present = state != "absent";
    let ip = type(active) == "object" && probe_module.valid_ipv4(active.ip) ? active.ip : null;
    if (ip == null && state == "present") ip = table_target();
    let entries = nfqws_entries(active);
    if (report != null && ip != null && state == "present")
        report.drain = drain(ip, length(entries) > 0);
    if (report != null && state == "present") report.counters_at_stop = probe_counters();
    if (table_present && ip != null) {
        let released = release_probe_rule(ip);
        push(actions, "probe_rule:" + released);
        if (released == "failed") ok = false;
    }
    for (let entry in entries) {
        if (fs.stat(entry.pidfile) == null) continue;      // never started
        let saved = identity.read_record(entry.pidfile);
        if (saved == null) { push(actions, "pidfile:stale"); continue; }
        let outcome = entry.argv ? stop_identified(saved, entry.argv, true)
            : stop_identified(saved, signature_prefix(entry.queue), false);
        if (outcome == "failed") ok = false;
        else if (outcome != "not_ours") stopped = true;
        push(actions, "pidfile:" + (outcome == "not_ours" ? "stale" : outcome));
    }
    if (stopped) {
        // The kernel releases the queue binding as the process exits.
        for (let i = 0; i < 3 && length(run_queues()) > 0; i++) pause();
        mark("T6", "temporary nfqws stopped", report ? report.drain : null);
    }
    let held = null;
    if (table_present) {
        if (ip != null) {
            held = hold(ip);
            if (report != null) report.hold = held;
            push(actions, "hold:" + (held.settled ? "settled" : "timeout"));
        }
        else push(actions, "hold:target_unknown");
        if (ip == null || !held.settled) {
            // Removing the table now could hand late packets of live probe
            // sockets to production: keep it (released + drop) and the
            // recovery data; a later cleanup repeats the hold.
            push(actions, "table:kept");
            ok = false;
        }
        else {
            let quiet = production_queues_quiet();
            if (report != null) {
                report.quiet_before_removal = quiet;
                report.counters_at_removal = probe_counters();
            }
            if (success([ "nft", "delete", "table", "inet", TABLE ]) && table_state(TABLE) == "absent")
                push(actions, "table:removed");
            else { push(actions, "table:remove_failed"); ok = false; }
            mark("T7", "temporary table removed", held);
        }
    }
    // Recovery data is kept until the table and the recorded processes are
    // verifiably gone.
    if (ok && table_state(TABLE) == "absent") {
        for (let entry in nfqws_entries(active)) fs.unlink(entry.pidfile);
        for (let name in fs.lsdir(WORKDIR) || []) fs.unlink(WORKDIR + "/" + name);
        fs.rmdir(WORKDIR);
        fs.unlink(ACTIVE);
    }
    return ok;
}

function verify_clean() {
    let found = orphans();
    let result = {
        table_absent: table_state(TABLE) == "absent",
        queue_absent: length(run_queues()) == 0,
        process_absent: length(found) == 0,
        state_removed: fs.stat(ACTIVE) == null && !pidfiles_present() && fs.stat(WORKDIR) == null
    };
    result.clean = result.table_absent && result.queue_absent && result.process_absent && result.state_removed;
    if (length(found) > 0) result.blocking_nfqws = blocking_nfqws(found);
    return result;
}

function cleanup() {
    let actions = [];
    let ok = teardown(read_active(), actions);
    let verified = verify_clean();
    return { status: ok && verified.clean ? "clean" : "failed", actions, verified };
}

// ---- probe run ---------------------------------------------------------

function start_nfqws(argv, log) {
    let pipe = fs.popen(command(argv) + " >" + quote(log) + " 2>&1 </dev/null & echo $!", "r");
    if (!pipe) return "";
    let pid = trim(as_string(pipe.read("all")));
    pipe.close();
    return match(pid, /^[1-9][0-9]*$/) != null ? pid : "";
}

function summary(probes) {
    let ok = 0, tls = [];
    for (let p in probes) if (p.class == "success") { ok++; push(tls, p.time_appconnect_ms); }
    tls = sort(tls, (a, b) => a - b);
    return { attempts: length(probes), successes: ok,
        success_rate: length(probes) > 0 ? (ok * 1.0) / length(probes) : 0,
        median_tls_ms: length(tls) > 0 ? tls[int(length(tls) / 2)] : null };
}

// Start one candidate nfqws on its queue and wait for its listener.
function start_candidate(entry) {
    let pid = start_nfqws(entry.argv, WORKDIR + "/nfqws-" + entry.queue + ".log");
    if (pid == "") return { failure: "nfqws_start_failed" };
    if (!identity.record(entry.pidfile, pid)) {
        // Unrecorded, it would never be stopped later: stop the process this
        // run has just started, once it runs nfqws.
        let saved = { pid, ticks: identity.start_ticks(pid) };
        for (let i = 0; saved.ticks != "" && i <= LISTENER_WAIT &&
            stop_identified(saved, entry.argv, true) == "not_ours" && identity.start_ticks(pid) == saved.ticks; i++)
            pause();
        return { failure: "nfqws_start_failed" };
    }
    // The pid is the shell's fork until it execs nfqws: on a loaded router
    // the first look can still find the shell. Only a process that is gone
    // (or a reused pid) fails the start at once.
    let recorded = identity.read_record(entry.pidfile);
    let ticks = type(recorded) == "object" ? recorded.ticks : null;
    let listener = null, running = false;
    for (let i = 0; i <= LISTENER_WAIT && listener == null; i++) {
        running = identity.matches(entry.pidfile, NFQWS, entry.argv, true, true) != "";
        if (!running && identity.start_ticks(pid) != ticks) return { failure: "nfqws_start_failed" };
        if (running) listener = queue_entry(entry.queue);
        if (listener == null) pause();
    }
    if (listener == null) return { failure: running ? "nfqws_listener_missing" : "nfqws_start_failed" };
    return { pid, listener };
}

function unavailable(result, detail) {
    result.status = "unsupported";
    result.reason = "isolation_unavailable";
    result.isolation.unavailable = detail;
    return result;
}

// Everything before anything is created: recovery of leftovers, refusals,
// one resolution of the target (pinned for the whole run), the probe route,
// the bypass contract and the production pre-state. Returns null when the
// run must not go on (result already describes why).
function preflight(result, host, resolver, ip, on_dns_failure) {
    // Leftovers of an interrupted run are ours by name and signature.
    let recovered = [];
    if (!teardown(read_active(), recovered)) {
        result.status = "refused"; result.reason = "stale_probe_state";
        result.cleanup = { actions: recovered, verified: verify_clean() };
        return null;
    }
    if (length(recovered) > 0) result.recovered = recovered;
    timeline = []; result.timeline = timeline;

    let refusal = null, found = [];
    if (length(guards_present()) > 0) refusal = "guard_active";
    // The marking rule of an apply verification (autotune/apply.uc) matches
    // the same probe tuple at the same priority. One a killed verification
    // left behind is removed (this run holds the autotune lock, so no
    // verification is running); never measure next to one.
    else if (table_exists(VERIFY_TABLE) && (!success([ "nft", "delete", "table", "inet", VERIFY_TABLE ]) || table_exists(VERIFY_TABLE)))
        refusal = "verify_path_present";
    else if (fs.stat(SNAPSHOT_LOCK) != null) refusal = "snapshot_operation_in_progress";
    // An nfqws of the run signature that no run recorded is not ours to stop.
    else if (length(found = orphans()) > 0) refusal = "queue_in_use";
    else refusal = queue_check() || port_check();
    if (length(found) > 0) result.blocking_nfqws = blocking_nfqws(found);
    if (refusal) { result.status = "refused"; result.reason = refusal; return null; }

    let target = { host, port: 443, resolver: resolver || null, addresses: null, ip: null, route: null };
    result.target = target;
    if (ip) {
        if (!probe_module.valid_host(host) || !probe_module.public_ipv4(ip)) {
            result.status = "refused"; result.reason = "invalid_target"; return null;
        }
        target.addresses = [ ip ];
    }
    else {
        let resolved = probe_module.resolve(host, resolver);
        target.addresses = resolved.addresses;
        if (resolved.status != "ok") { on_dns_failure(resolved); return null; }
    }
    target.ip = target.addresses[0];
    target.route = probe_route(target.ip);
    if (!target.route.ok) { unavailable(result, target.route.reason); return null; }

    // The production bypass for the probe mark, the policy routing and the
    // reply path must be proven from the live system; there is no fallback to
    // the current rule order.
    result.contract = bypass_contract(target.route, target.ip);
    if (!result.contract.ok) { unavailable(result, "bypass_contract"); return null; }

    // The table the run is compared against must itself satisfy the contract.
    let snapshot = production_snapshot(target.ip);
    let snapshot_contract = contract.evaluate(snapshot.table, null,
        { probe_mark: PROBE_MARK, own_table: TABLE, own_priority: PRIORITY, prod_table: PROD_TABLE,
          reply_dev: target.route.dev, sets: result.contract.sets || null });
    if (!snapshot_contract.ok) {
        result.contract = snapshot_contract;
        unavailable(result, "bypass_contract_changed");
        return null;
    }
    return { target, before: snapshot.state };
}

// Candidates of a tuning run: the requested catalog ids (all by default),
// always including the direct control. Unsupported or non-TCP candidates are
// excluded with their reason; they are never counted as failed connectivity.
function tune_candidates(list) {
    let ids = [];
    let requested = list ? split(as_string(list), ",") : map(catalog.entries(), (e) => e.id);
    for (let id in [ "direct", ...requested ]) {
        id = trim(as_string(id));
        if (id != "" && index(ids, id) < 0) push(ids, id);
    }
    let candidates = [], excluded = [];
    for (let id in ids) {
        let entry = catalog.find(id);
        if (entry == null) { push(excluded, { id, supported: false, reason: "unknown_candidate" }); continue; }
        let checked = catalog.validate_entry(entry);
        if (checked.state != "supported") { push(excluded, { id, supported: false, reason: checked.reason }); continue; }
        if (checked.protocol != "tcp") { push(excluded, { id, supported: false, reason: "protocol_unsupported" }); continue; }
        push(candidates, checked);
    }
    return { candidates, excluded };
}

// Stage 4: measure several candidates for one target through the isolated
// path and select one deterministically (autotune/select.uc). The target is
// resolved once and pinned for every probe; candidates are probed in
// interleaved, rotated rounds. The result is a recommendation only.
// probes: probes per candidate, 3..7. "max:<n>" asks for at most n: the
// count is lowered until every candidate fits the source ports of one run
// (the manager's policy does not know how many candidates are supported).
function tune(host, probes, resolver, list, ip) {
    let result = { status: "failed", reason: null, target: null, selected: null, confidence: null,
        isolation: { table: TABLE, chains: [ MARK_CHAIN + "@" + MARK_PRIORITY, CHAIN + "@" + PRIORITY, REPLY_CHAIN + "@" + REPLY_PRIORITY ],
            queues: null, port_range: PORT_RANGE, probe_mark: PROBE_MARK, desync_mark: DESYNC_MARK },
        contract: null, timeline, schedule: null, candidates: [], excluded: [], pruned: [], probes: [],
        teardown: null, production: null, cleanup: null, applied: false };
    let at_most = substr(as_string(probes), 0, 4) == "max:";
    probes = int((at_most ? substr(as_string(probes), 4) : probes) || select_module.MIN_PROBES);
    result.probes_requested = probes;
    if (probes < select_module.MIN_PROBES || probes > select_module.MAX_PROBES) {
        result.status = "refused"; result.reason = "invalid_probe_count"; return result;
    }
    let chosen = tune_candidates(list);
    result.excluded = chosen.excluded;
    let supported = chosen.candidates;
    let dpi = filter(supported, (c) => c.nfqws_opt != "");
    if (length(dpi) == 0) { result.status = "refused"; result.reason = "no_supported_dpi_candidate"; return result; }
    if (length(dpi) > MAX_QUEUES) { result.status = "refused"; result.reason = "too_many_candidates"; return result; }
    // Every probe of a candidate needs a source port of its slice: a used
    // port stays in TIME_WAIT for the rest of the run.
    let slice_size = int(MAX_TUNE_PROBES_TOTAL / length(supported));
    if (at_most && probes > slice_size) probes = slice_size;
    if (probes < select_module.MIN_PROBES || probes > slice_size) {
        result.status = "refused"; result.reason = "too_many_probes"; return result;
    }
    result.probes_per_candidate = probes;

    // One queue per DPI candidate and one port slice per candidate, assigned
    // in the deterministic base order.
    let order = select_module.base_order(supported);
    let slices = port_slices(order);
    let by_id = {}, entries = [], rules = [], next_queue = QUEUE;
    for (let id in order) {
        let c = null;
        for (let s in supported) if (s.id == id) c = s;
        let slot = { id, rank: c.rank, queue: null, pidfile: null, argv: null, sport: slices[id],
            ports: slices[id][0] + "-" + slices[id][1] };
        if (c.nfqws_opt != "") {
            slot.queue = next_queue++;
            slot.pidfile = pidfile_for(slot.queue);
            slot.argv = nfqws_argv(c.nfqws_opt, null, slot.queue);
            push(entries, { queue: slot.queue, pidfile: slot.pidfile, argv: slot.argv });
        }
        slot.comment = (slot.queue == null ? "direct:" : "probe:") + id;
        push(rules, probe_rule_spec(slot.queue, slot.comment, slot.sport));
        by_id[id] = slot;
    }
    result.isolation.queues = map(entries, (e) => e.queue);
    result.isolation.port_slices = {};
    for (let id in order) result.isolation.port_slices[id] = by_id[id].ports;
    result.schedule = select_module.schedule(order, probes);
    let total_probes = 0;
    for (let r in result.schedule) total_probes += length(r);
    progress("preparing", { done: 0, total: total_probes, candidates: length(order) });

    let pre = preflight(result, host, resolver, ip, (resolved) => {
        result.status = "inconclusive"; result.reason = "target_unresolved";
        result.target.dns = resolved.reason;
    });
    if (pre == null) return result;
    let target = pre.target, before = pre.before;
    mark("T0", "pre-state recorded");

    let records = {};
    for (let id in order) records[id] = [];
    let body = function() {
        // Announced before anything is created so an interrupted run can
        // always be torn down.
        if (!fs.mkdir(WORKDIR, 0755) ||
            fs.writefile(ACTIVE, sprintf("%J\n", { table: TABLE, nfqws: entries, ip: target.ip })) == null)
            return "state_write_failed";
        let batch_file = WORKDIR + "/probe.nft";
        if (fs.writefile(batch_file, batch(target.ip, rules)) == null) return "state_write_failed";
        result.teardown = { quiet_before_creation: production_queues_quiet() };
        if (!result.teardown.quiet_before_creation.quiet) return "production_queue_busy";
        if (!success([ "nft", "-f", batch_file ])) return "nft_setup_failed";
        result.isolation.rules = probe_rule_handles();
        mark("T1", "temporary nft table created");
        let pids = {};
        for (let entry in entries) {
            if (interrupted) return "interrupted";
            let started = start_candidate(entry);
            if (started.failure) return started.failure;
            pids["" + entry.queue] = int(started.pid);
        }
        mark("T2", "temporary nfqws started", pids);
        mark("T3", "measurement begins", { rounds: length(result.schedule), candidates: order });
        progress("measuring", { done: 0, total: total_probes, candidates: length(order) });
        // Queue positions of every candidate before its first probe: the run
        // is checked as a whole as well (below).
        let run_queue_before = {};
        for (let entry in entries) run_queue_before["" + entry.queue] = queue_entry(entry.queue);
        let run_counters_before = probe_counters();
        if (run_counters_before == null) return "counters_unavailable";
        for (let r = 0; r < length(result.schedule); r++) {
            let round = [];
            for (let id in result.schedule[r]) {
                if (interrupted) return "interrupted";
                // A candidate already failed whatever its remaining probes
                // give is not probed further (select.uc settled_failed). The
                // control (direct) is always measured in full: the selection
                // relies on its failures.
                let remaining = length(result.schedule) - r;
                if (id != "direct" && index(result.pruned, id) < 0 &&
                    select_module.settled_failed(records[id], remaining)) {
                    push(result.pruned, id);
                    total_probes -= remaining;
                }
                if (index(result.pruned, id) >= 0) continue;
                let slot = by_id[id];
                let comment = slot.comment, synack = syn_ack_comment(comment);
                // The queue is read before the rule counter here and after it
                // below, so the queue window contains the rule window: a late
                // packet of an earlier probe of this candidate (a blocked
                // probe leaves an orphan that keeps retransmitting) between
                // two readings can only add to "queued", never look like a
                // packet that bypassed the candidate. Late packets of other
                // candidates leave from their own slices, through their own
                // rules and queues.
                let queue_before = slot.queue != null ? queue_entry(slot.queue) : null;
                let counters_before = probe_counters();
                if (counters_before == null || counters_before[comment] == null || counters_before[synack] == null)
                    return "counters_unavailable";
                let record = probe_module.probe({ host, ip: target.ip, port_range: slot.ports });
                let counters_after = probe_counters();
                if (counters_after == null || counters_after[comment] == null || counters_after[synack] == null)
                    return "counters_unavailable";
                record = probe_module.handshake(record, counters_after[synack].packets - counters_before[synack].packets);
                record.round = r + 1;
                record.candidate = id;
                record.port_range = slot.ports;
                record.rule_packets = counters_after[comment].packets - counters_before[comment].packets;
                if (slot.queue != null) {
                    let queue_after = queue_entry(slot.queue);
                    if (identity.matches(slot.pidfile, NFQWS, slot.argv, true, true) == "") return "nfqws_died";
                    record.queued = queue_before && queue_after ? queue_after.id_sequence - queue_before.id_sequence : null;
                    // Fail-open queues accept packets untransformed without a
                    // drop counter: every packet the rule matched must have
                    // entered this candidate's queue.
                    if (record.queued == null || record.queued < record.rule_packets) return "candidate_bypassed";
                }
                push(records[id], record);
                push(result.probes, record);
                push(round, record);
                progress("measuring", { done: length(result.probes), total: total_probes, candidates: length(order) });
            }
            // No candidate can repair a TCP connect failure: when every
            // candidate of a round fails before the connection is established,
            // the pinned target is unusable; it is never re-resolved mid-run.
            if (length(filter(round, (p) => p.connect == "ok")) == 0) {
                result.unreachable_round = r + 1;
                return "target_unreachable";
            }
        }
        // Over the whole run, every packet a candidate's rule matched must
        // have entered its queue, the late ones of its last probes included
        // (rule counters first, queues after them: see above).
        let run_counters_after = probe_counters();
        if (run_counters_after == null) return "counters_unavailable";
        for (let id in order) {
            let slot = by_id[id];
            if (slot.queue == null || run_counters_after[slot.comment] == null || run_counters_before[slot.comment] == null)
                continue;
            let before_q = run_queue_before["" + slot.queue], after_q = queue_entry(slot.queue);
            let matched = run_counters_after[slot.comment].packets - run_counters_before[slot.comment].packets;
            if (before_q == null || after_q == null || after_q.id_sequence - before_q.id_sequence < matched)
                return "candidate_bypassed";
        }
        mark("T5", "measurement done", { probes: length(result.probes) });
        return null;
    };
    let failure = null;
    try { failure = body(); }
    catch (e) { failure = "exception: " + as_string(e.message); }

    let actions = [], report = result.teardown || {};
    progress("cleaning", { done: length(result.probes), total: total_probes });
    let torn_down = teardown(read_active() || { nfqws: entries, ip: target.ip }, actions, report);
    result.teardown = report;
    let verified = verify_clean();
    let after = production_state(target.ip);
    let unchanged = same_state(before, after);
    result.cleanup = { status: torn_down && verified.clean ? "clean" : "failed", actions, verified };
    result.production = { before, after, unchanged };
    if (verified.clean) mark("T8", "cleanliness verified", { production_unchanged: unchanged });

    let final_counters = report.counters_at_removal;
    let hold_settled = report.hold == null || report.hold.settled;
    let pinned = true;
    for (let p in result.probes)
        if (p.resolved_ip != target.ip || (p.remote_ip != null && p.remote_ip != target.ip)) pinned = false;
    if (failure == null && interrupted) failure = "interrupted";
    if (failure == null && !hold_settled) failure = "isolation_hold_timeout";
    let isolation_ok = torn_down && verified.clean && unchanged && final_counters != null &&
        final_counters.unexpected.packets == 0;
    if (failure == "target_unreachable" && isolation_ok) {
        result.status = "inconclusive"; result.reason = "target_unreachable";
    }
    else if (failure != null) { result.status = failure == "interrupted" ? "interrupted" : "failed"; result.reason = failure; }
    else if (!torn_down || !verified.clean) { result.status = "failed"; result.reason = "cleanup_unverified"; }
    else if (!unchanged) { result.status = "failed"; result.reason = "production_changed"; }
    else if (final_counters == null) { result.status = "failed"; result.reason = "counters_unavailable"; }
    else if (final_counters.unexpected.packets > 0) { result.status = "failed"; result.reason = "unexpected_probe_packets"; }
    else if (!pinned) { result.status = "inconclusive"; result.reason = "target_ip_mismatch"; }
    else {
        let measured = map(order, (id) => ({ candidate: { id, rank: by_id[id].rank }, probes: records[id] }));
        let evaluation = select_module.evaluate(measured);
        result.status = evaluation.status;
        result.selected = evaluation.selected;
        result.reason = evaluation.reason;
        result.confidence = evaluation.confidence;
        result.candidates = evaluation.candidates;
        result.ranking = evaluation.ranking;
        result.policy = evaluation.policy;
        if (evaluation.leading) result.leading = evaluation.leading;
        if (report.quiet_before_removal != null && !report.quiet_before_removal.quiet) result.warning = "production_queue_busy_at_removal";
    }
    return result;
}

// handshake: "handshake" for TCP handshakes only (probe.uc), the control
// runs of autotune/apply.uc; direct only.
function run(candidate_id, host, count, resolver, ip, handshake) {
    let result = { status: "failed", reason: null, candidate: null, target: null,
        isolation: { table: TABLE, chains: [ MARK_CHAIN + "@" + MARK_PRIORITY, CHAIN + "@" + PRIORITY, REPLY_CHAIN + "@" + REPLY_PRIORITY ], queue: QUEUE,
            port_range: PORT_RANGE, probe_mark: PROBE_MARK, desync_mark: DESYNC_MARK },
        contract: null, timeline, probes: [], summary: null, counters: null, teardown: null,
        production: null, cleanup: null };
    count = int(count || 3);
    if (count < 1 || count > MAX_PROBES) { result.status = "refused"; result.reason = "invalid_count"; return result; }

    let entry = catalog.find(candidate_id);
    if (entry == null) { result.status = "refused"; result.reason = "unknown_candidate"; return result; }
    let checked = catalog.validate_entry(entry);
    result.candidate = { id: checked.id, rank: checked.rank, nfqws_opt: checked.nfqws_opt,
        state: checked.state, reason: checked.reason };
    if (checked.state != "supported") { result.status = "unsupported"; result.reason = checked.reason; return result; }
    let handshake_only = handshake == "handshake";
    if ((handshake != null && !handshake_only) || (handshake_only && checked.nfqws_opt != "")) {
        result.status = "refused"; result.reason = "invalid_mode"; return result;
    }
    if (handshake_only) result.handshake = true;

    let pre = preflight(result, host, resolver, ip, (resolved) => {
        result.status = "completed"; result.reason = "dns_failure";
        push(result.probes, { host, class: "dns_failure", detail: resolved.reason });
        result.summary = summary(result.probes);
    });
    if (pre == null) return result;
    let target = pre.target, before = pre.before;
    mark("T0", "pre-state recorded");
    let queue_candidate = checked.nfqws_opt != "";
    let debug_file = NFQWS_DEBUG && queue_candidate ? WORKDIR + "/nfqws.debug" : null;
    let argv = queue_candidate ? nfqws_argv(checked.nfqws_opt, debug_file, QUEUE) : null;
    let pidfile = pidfile_for(QUEUE);
    let nfqws = queue_candidate ? [ { queue: QUEUE, pidfile, argv } ] : [];
    let body = function() {
        // The run is announced before anything is created so an interrupted
        // run can always be torn down.
        if (!fs.mkdir(WORKDIR, 0755) ||
            fs.writefile(ACTIVE, sprintf("%J\n", { table: TABLE, nfqws, ip: target.ip })) == null)
            return "state_write_failed";
        if (debug_file) { fs.writefile(debug_file, ""); fs.chmod(debug_file, 0666); }
        let batch_file = WORKDIR + "/probe.nft";
        if (fs.writefile(batch_file, batch(target.ip, probe_rule_spec(queue_candidate ? QUEUE : null))) == null) return "state_write_failed";
        result.teardown = { quiet_before_creation: production_queues_quiet() };
        // Registering hooks while production packets sit in an NFQUEUE could
        // make them resume at a shifted hook index.
        if (!result.teardown.quiet_before_creation.quiet) return "production_queue_busy";
        if (!success([ "nft", "-f", batch_file ])) return "nft_setup_failed";
        result.isolation.rules = probe_rule_handles();
        mark("T1", "temporary nft table created");
        if (interrupted) return "interrupted";
        if (queue_candidate) {
            let started = start_candidate(nfqws[0]);
            if (started.failure) return started.failure;
            mark("T2", "temporary nfqws started", { pid: int(started.pid), queue_portid: started.listener.portid });
        }
        if (interrupted) return "interrupted";
        let queue_before = queue_entry(QUEUE);
        mark("T3", "probe begins");
        for (let i = 0; i < count; i++) {
            if (interrupted) return "interrupted";
            let before_c = probe_counters();
            if (before_c == null || before_c.synack == null) return "counters_unavailable";
            let record = probe_module.probe({ host, ip: target.ip, port_range: PORT_RANGE, handshake: handshake_only });
            let after_c = probe_counters();
            if (after_c == null || after_c.synack == null) return "counters_unavailable";
            push(result.probes, probe_module.handshake(record, after_c.synack.packets - before_c.synack.packets));
        }
        // The rule counter first, the queue after it: see tune().
        result.counters = probe_counters();
        let queue_after = queue_entry(QUEUE);
        if (result.counters == null) return "counters_unavailable";
        if (queue_candidate) {
            result.counters.queue = {
                id_sequence_before: queue_before ? queue_before.id_sequence : null,
                id_sequence_after: queue_after ? queue_after.id_sequence : null,
                packets_queued: queue_before && queue_after ? queue_after.id_sequence - queue_before.id_sequence : null,
                dropped: queue_after ? queue_after.dropped : null,
                user_dropped: queue_after ? queue_after.user_dropped : null
            };
            mark("T4", "queue " + QUEUE + " received probe", { packets_queued: result.counters.queue.packets_queued });
            if (identity.matches(pidfile, NFQWS, argv, true, true) == "") return "nfqws_died";
            // nfqws queues are fail-open: a packet the queue could not take is
            // accepted untransformed without a drop counter. Every packet the
            // probe rule matched must have entered the queue.
            let queued = result.counters.queue.packets_queued;
            if (queued == null || result.counters.probe == null || queued < result.counters.probe.packets) return "candidate_bypassed";
        }
        mark("T5", "probe result", summary(result.probes));
        if (debug_file) {
            let lines = split(trim(as_string(fs.readfile(debug_file))), "\n");
            result.nfqws_debug = slice(lines, length(lines) > 80 ? length(lines) - 80 : 0);
        }
        return null;
    };
    let failure = null;
    try { failure = body(); }
    catch (e) { failure = "exception: " + as_string(e.message); }

    let actions = [], report = result.teardown || {};
    let torn_down = teardown(read_active() || { nfqws, ip: target.ip }, actions, report);
    result.teardown = report;
    let verified = verify_clean();
    let after = production_state(target.ip);
    let unchanged = same_state(before, after);
    result.cleanup = { status: torn_down && verified.clean ? "clean" : "failed", actions, verified };
    result.production = { before, after, unchanged };
    result.summary = summary(result.probes);
    if (verified.clean) mark("T8", "cleanliness verified", { production_unchanged: unchanged });

    // Every packet of the probe tuple must have taken a modelled path.
    let final_counters = report.counters_at_removal;
    let hold_settled = report.hold == null || report.hold.settled;
    if (failure == null && interrupted) failure = "interrupted";
    if (failure == null && !hold_settled) failure = "isolation_hold_timeout";
    if (failure != null) { result.status = failure == "interrupted" ? "interrupted" : "failed"; result.reason = failure; }
    else if (!torn_down || !verified.clean) { result.status = "failed"; result.reason = "cleanup_unverified"; }
    else if (!unchanged) { result.status = "failed"; result.reason = "production_changed"; }
    else if (final_counters == null) { result.status = "failed"; result.reason = "counters_unavailable"; }
    else if (final_counters.unexpected.packets > 0) { result.status = "failed"; result.reason = "unexpected_probe_packets"; }
    else {
        result.status = "completed";
        if (report.quiet_before_removal != null && !report.quiet_before_removal.quiet) result.warning = "production_queue_busy_at_removal";
    }
    return result;
}

// ---- entry -------------------------------------------------------------

if (type(signal) == "function")
    for (let name in [ "SIGINT", "SIGTERM", "SIGHUP" ])
        signal(name, function() { interrupted = true; });

let mode = ARGV[0] || "";
let output = null, code = 1;
if (mode == "model") {
    // The temporary chains for a target, as evaluated by the regression tests.
    // "tune": the slices of a tuning run of the control and one DPI candidate.
    let tune_slices = port_slices([ "direct", "candidate" ]);
    let spec = ARGV[2] == "direct" ? probe_rule_spec(null) : ARGV[2] == "tune"
        ? [ probe_rule_spec(null, "direct:direct", tune_slices.direct), probe_rule_spec(QUEUE, "probe:candidate", tune_slices.candidate) ]
        : probe_rule_spec(QUEUE);
    print(sprintf("%J\n", { probe_mark: PROBE_MARK_VALUE, desync_mark: DESYNC_MARK_VALUE, queue: QUEUE,
        chains: probe_chains(ARGV[1], spec), batch: batch(ARGV[1], spec) }));
    exit(0);
}
if (queue_reserved()) {
    // Never scan for, signal or queue to a production queue number.
    print(sprintf("%J\n", { status: "refused", reason: "queue_overlaps_prokop_range", queue: QUEUE, queue_last: QUEUE_LAST }));
    exit(1);
}
if (mode == "run" || mode == "cleanup" || mode == "tune") {
    if (!autotune_lock.acquire())
        output = autotune_lock.busy() ? { status: "busy", reason: "autotune_in_progress" } : { status: "failed", reason: "lock_unavailable" };
    else {
        if (mode == "run") output = run(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
        else if (mode == "tune") output = tune(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
        else output = cleanup();
        autotune_lock.release();
        code = index([ "completed", "clean", "selected", "inconclusive" ], output.status) >= 0 ? 0 : 1;
    }
}
else if (mode == "status") {
    output = { active: fs.stat(ACTIVE) != null, table: table_state(TABLE), queues: run_queues(),
        orphans: length(orphans()), production: production_state() };
    code = 0;
}
else {
    warn("Usage: autotune/isolation.uc <run <candidate> <host> [count] [resolver] [ip] [handshake]|tune <host> [probes] [resolver] [candidates] [ip]|cleanup|status|model <ip> [direct|tune]>\n");
    exit(1);
}
print(sprintf("%J\n", output));
exit(code);
