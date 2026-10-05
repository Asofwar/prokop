#!/usr/bin/env ucode

// DPI autotune stage 5: controlled, explicit, one-shot application of a
// strategy selected by stage 4 (isolation.uc tune), with production
// verification and automatic rollback. No daemon, no periodic retuning.
//
// Production model (derived from the generator, not assumed): a DPI strategy
// is the nfqws_opt of an enabled rule (config section) with action=zapret;
// targets reach a rule through its matchers, and sing-box applies its route
// rules in configuration order, first match wins. There is no per-domain
// strategy. The only unambiguous mapping of "candidate X for target T" is:
//   the first route rule the target matches (decided statically from the
//   generated sing-box config) belongs to an enabled zapret rule, the match
//   is by matchers the resolver can decide (static domain/IP matchers and
//   local lists sing-box is asked about; no undownloaded lists above it),
//   and that rule's strategy is one TCP/443 profile
//   -> set that rule's nfqws_opt to the candidate template.
// The change applies to the rule's whole target group, which the plan names.
// A rule limited to devices (source_ip_cidr) owns the target for those
// devices only, and sing-box sends nothing of the router into it. Its DPI
// queue, however, is chosen by the route mark of the rule, not by the
// source: the verification sends the router's own requests to the pinned
// address of the target with that mark (a rule in a temporary table,
// confined to the probe tuple), so they pass the production queue and the
// production nfqws of the rule. What is not exercised is the sing-box
// decision "this device -> this rule", which the resolver proves statically.
// Everything else is "not_applicable" with the reason. "direct" never
// changes production: it is "no_change_required" when no DPI rule handles
// the target and "direct_not_applicable" when one does.
//
// Modes:
//   plan <selection.json> [resolver]   read-only; prints the plan
//   apply <plan.json> [resolver]       stale checks, revalidation, transaction
//   verify <plan.json> [proposed|current] [traffic]  read-only verification
//   rollback                           restore the recorded pre-apply snapshot
//   observe <started_at>               read-only: one observation check of
//                                      the recorded applied candidate
//   rollback observation <started_at>  the rollback of that apply after its
//                                      observation found it failing
//   status                             durable state and current diagnosis
//   path <host>                        read-only: production DNS mode and the
//                                      outbound a connection to host takes
//
// Must be invoked as: ucode -L <lib> <lib>/autotune/apply.uc <mode> ...
// (the autotune lock identifies its owner by that command line).
let fs = require("fs");
let constants = require("core.constants");
let identity = require("core.process_identity");
let catalog = require("autotune.catalog");
let probe_module = require("autotune.probe");
let select_module = require("autotune.select");
let autotune_lock = require("autotune.lock");
let runtime_lock = require("core.runtime_lock");
let list_worker = require("core.list_worker");
let resolver = require("routing.resolve");
let dpi_strategy = require("core.dpi_strategy");
let durable = require("core.durable");

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const CONFIG_FILE = getenv("PROKOP_CONFIG_FILE") || "/etc/config/prokop";
const STATE_FILE = getenv("PROKOP_AUTOTUNE_APPLY_STATE") || "/etc/prokop/autotune-apply.json";
const UCI = getenv("PROKOP_AUTOTUNE_UCI") || "uci";
const ZAPRET_RUNTIME = getenv("PROKOP_AUTOTUNE_ZAPRET_RUNTIME") || LIB_DIR + "/providers/zapret/runtime.uc";
const SNAPSHOTS = LIB_DIR + "/config/snapshots.uc";
const SNAPSHOT_LOCK = getenv("PROKOP_SNAPSHOT_LOCK_DIR") || "/var/run/prokop/config-snapshot.lock";
const SNAPSHOT_DIR = getenv("PROKOP_SNAPSHOT_DIR") || "/etc/prokop/config-snapshots";
const SINGBOX_CONFIG = getenv("PROKOP_AUTOTUNE_SINGBOX_CONFIG") || "";
const PROC_QUEUE = getenv("PROKOP_AUTOTUNE_PROC_QUEUE") || "/proc/net/netfilter/nfnetlink_queue";
const CHILD_PID_DIR = getenv("ZAPRET_CHILD_PID_DIR") || constants.ZAPRET_CHILD_PID_DIR;
const DESYNC_MARK = getenv("ZAPRET_DESYNC_MARK") || constants.ZAPRET_DESYNC_MARK;
const RELOAD_LOCK = getenv("PROKOP_RELOAD_LOCK_DIR") || "/var/run/prokop.reload.lock";
// An explicit stop (service/initd.uc, service/lifecycle.uc): until an
// explicit start no reload brings the runtime back (D-15, UC-056).
const STOP_REQUESTED = getenv("PROKOP_STOP_REQUESTED_FILE") ||
    (getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop") + "/stop.requested";
// An explicit start since boot (service/initd.uc): a runtime that is down
// without it was not started since boot, and no reload starts it (D-15(a)).
const EXPLICIT_START = getenv("PROKOP_EXPLICIT_START_FILE") ||
    (getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop") + "/start.explicit";
const UCI_SAVEDIR = getenv("PROKOP_AUTOTUNE_UCI_SAVEDIR") || "/tmp/.uci";
const TMP_DIR = getenv("PROKOP_AUTOTUNE_TMPDIR") || "/tmp";
const HOLD_SECONDS = 5;
const CURL = getenv("PROKOP_AUTOTUNE_CURL") || "curl";
const PROD_TABLE = constants.NFT_TABLE_NAME;
// What an empty nfqws_opt runs (providers/zapret/common.uc).
const DEFAULT_STRATEGY = getenv("ZAPRET_DEFAULT_NFQWS_OPT") || constants.ZAPRET_DEFAULT_NFQWS_OPT;
const PROBE_TABLE = "ProkopAutotuneProbe";
const GUARD_TABLES = [ "ProkopConfigRestoreDpiGuard", PROD_TABLE + "DpiGuard" ];
const VERIFY_PROBES = 3;
// The marked verification of a device-limited rule: a table of its own with
// one rule for the probe tuple (the pinned target, the dedicated source
// ports of autotune probes), removed as soon as the probes are done.
const VERIFY_TABLE = "ProkopAutotuneVerify";
const VERIFY_PORT_FIRST = 61000, VERIFY_PORT_LAST = 61063;
const VERIFY_SETTLE = int(getenv("PROKOP_AUTOTUNE_VERIFY_SETTLE") || "10");
const PORT_RANGE_FILE = getenv("PROKOP_AUTOTUNE_PORT_RANGE_FILE") || "/proc/sys/net/ipv4/ip_local_port_range";
const PROC_NET = getenv("PROKOP_AUTOTUNE_PROC_NET") || "/proc/net";
const ROLLBACK_WAIT_SECONDS = int(getenv("PROKOP_AUTOTUNE_ROLLBACK_WAIT_SECONDS") || "300");
const TERMINAL_PHASES = [ "applied", "rolled_back", "failed", "stale", "no_change_required", "needs_attention" ];

let interrupted = false;

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
// A configuration transaction runs in its own session: Ctrl-C or an SSH
// hangup reaches this process (which records the interruption) but never the
// half-done restore/apply/reload. Signal dispositions are left untouched, so
// services started by the reload keep the default handlers.
function capture_detached(args) {
    let pipe = fs.popen("setsid " + command(args) + " 2>/dev/null", "r");
    if (!pipe) return { status: -1, output: "" };
    let data = pipe.read("all");
    return { status: int(pipe.close()), output: as_string(data) };
}
function success(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function parse_json(text) { try { return json(as_string(text)); } catch (e) { return null; } }
function read_json(path) { let data = fs.readfile(as_string(path)); return data == null ? null : parse_json(data); }
function now() { return time(); }
function sha_file(path) {
    let m = match(capture([ "sha256sum", path ]).output, /^([0-9a-f]{64})/);
    return m ? m[1] : "";
}
// Not prokop-autotune-apply.*: a manager run removes those as the
// directories of a dead run (autotune/manager.uc, UC-157).
function sha_text(text) {
    let path = trim(capture([ "mktemp", TMP_DIR + "/prokop-autotune-hash.XXXXXX" ]).output);
    if (path == "" || fs.writefile(path, text) == null) { if (path != "") fs.unlink(path); return ""; }
    let hash = sha_file(path);
    fs.unlink(path);
    return hash;
}
// Strategy text compared and split the one way core/dpi_strategy.uc does.
function words(value) { return dpi_strategy.words(value); }
function normalize(opt) { return dpi_strategy.normalize(opt); }
function valid_hash(v) { return match(as_string(v), /^[0-9a-f]{64}$/) != null; }
// Releases before UC-160 rewrote option shutdown_correctly on every stop and
// start; the user configuration is the file without it
// (lifecycle.external_config_fingerprint).
function fingerprint(text) {
    if (text == null) return "";
    let lines = [];
    for (let line in split(as_string(text), "\n"))
        if (match(line, /^[ \t]*option[ \t]+shutdown_correctly([ \t]|$)/) == null) push(lines, line);
    return sha_text(join("\n", lines));
}

// ---- configuration (read-only view of the file snapshots hash) ----------

// ---- which rule handles the target ---------------------------------------
// routing/resolve.uc is the one implementation (also used by Diagnostics).
// These wrappers keep the owner shape this file has always worked with:
// { decided, kind: zapret|outbound|reject|final, rule, outbound, reason,
//   section, index, mark, mark_value, queue }.

function parse_config(text) { return resolver.parse_config(text); }
function find_section(sections, name) { return resolver.find_section(sections, name); }
function rule_scope(section) { return resolver.rule_scope(section); }
function is_fakeip(ip) { return resolver.is_fakeip(ip); }

// Autotune only tunes TCP/443 and never knows the client: a source-scoped
// rule is asked about for its own devices (owner.source_scoped).
function tcp443_target(host, ip, fakeip) {
    return resolver.target(host, ip, { fakeip, network: "tcp", port: 443, assume_rule_source: true });
}

// Exported for callers that ask for the first route rule only.
function route_owner(config, host, ip, fakeip) {
    return resolver.route_owner(config, tcp443_target(host, ip, fakeip));
}

function singbox_config(sections) {
    return resolver.load_json(SINGBOX_CONFIG != "" ? SINGBOX_CONFIG : resolver.singbox_config_path(sections));
}

function owner_of(sections, host, ip, fakeip) {
    let r = resolver.resolve(singbox_config(sections), sections, tcp443_target(host, ip, fakeip));
    if (r.status != "decided") return { decided: false, reason: r.reason, rule: r.route_rule };
    // source_scoped is present only for a rule limited to devices.
    let scoped = r.source_scope != null ? { source_scoped: true } : {};
    if (r.zapret != null)
        return { decided: true, kind: "zapret", rule: r.route_rule, outbound: r.outbound, ...r.zapret, ...scoped };
    return { decided: true, kind: r.route, rule: r.route_rule, outbound: r.outbound, ...scoped };
}

// The strategy nfqws runs for an option value: empty means the default.
function effective(opt) { let n = normalize(opt); return n != "" ? n : normalize(DEFAULT_STRATEGY); }

// ---- candidate configuration ----------------------------------------------

// The candidate configuration: the current file with exactly one change
// (rule.nfqws_opt), produced by uci itself on a private copy, then proven by
// the semantic snapshot diff to differ in that option only. The copy uses its
// own package name, config and delta directories, so neither /etc/config nor
// pending LuCI changes in /tmp/.uci/prokop can take part. uci rewrites the
// file in its canonical form (comments are not kept); values, lists and
// unrelated options are preserved.
const CANDIDATE_PACKAGE = "prokop_autotune";
function build_candidate(text, section, opt) {
    let dir = trim(capture([ "mktemp", "-d", TMP_DIR + "/prokop-autotune-uci.XXXXXX" ]).output);
    if (dir == "") return { error: "tempdir_unavailable" };
    let cleanup = () => { system(command([ "rm", "-rf", dir ])); };
    let file = dir + "/" + CANDIDATE_PACKAGE, path = CANDIDATE_PACKAGE + "." + section + ".nfqws_opt";
    fs.mkdir(dir + "/save", 0700);
    if (fs.writefile(file, text) == null) { cleanup(); return { error: "tempfile_unavailable" }; }
    let base = [ UCI, "-c", dir, "-t", dir + "/save" ];
    if (!success([ ...base, "set", path + "=" + opt ]) || !success([ ...base, "commit", CANDIDATE_PACKAGE ])) {
        cleanup(); return { error: "uci_failed" };
    }
    let got = trim(capture([ ...base, "get", path ]).output);
    let candidate = fs.readfile(file);
    fs.writefile(dir + "/before", text);
    let changes = parse_json(capture([ "ucode", "-L", LIB_DIR, SNAPSHOTS, "fixture-diff", dir + "/before", file ]).output);
    cleanup();
    if (candidate == null || normalize(got) != normalize(opt)) return { error: "uci_value_mismatch" };
    if (type(changes) != "array" || length(changes) != 1 || changes[0].section != section || changes[0].option != "nfqws_opt")
        return { error: "mutation_not_exact", changes };
    let hash = sha_text(candidate);
    if (!valid_hash(hash)) return { error: "hash_unavailable" };
    return { text: candidate, hash, fingerprint: fingerprint(candidate) };
}

// ---- state (durable, atomic) -----------------------------------------------

// A record file that exists but holds no record (empty after a power cut,
// truncated, garbage) may hide an unresolved apply: it is needs_attention,
// never "no recorded apply" (UC-069). Only the operator's rollback settles it.
function state_read() {
    if (fs.stat(STATE_FILE) == null) return null;
    let s = read_json(STATE_FILE);
    return type(s) == "object" && type(s.phase) == "string" ? s :
        { phase: "needs_attention", status: "needs_attention", reason: "apply_state_unreadable", unreadable: true };
}
// Flushed to flash before and after the rename (UC-025): a power cut leaves
// the previous record or this one, never an empty one.
function state_write(state) {
    let dir = fs.dirname(STATE_FILE);
    if (fs.stat(dir) == null) fs.mkdir(dir, 0700);
    return durable.durable_replace(STATE_FILE + ".tmp." + autotune_lock.owner_pid(), STATE_FILE, sprintf("%J\n", state));
}

// ---- production observation --------------------------------------------------

function table_present(name) {
    let out = capture([ "nft", "list", "tables" ]);
    if (out.status != 0) return null;
    for (let line in split(out.output, "\n")) if (trim(line) == "table inet " + name) return true;
    return false;
}
// A snapshot operation is running while its lock holds an owner record of a
// live snapshots.uc process (a crashed operation leaves a stale directory).
function snapshot_operation_active() {
    for (let name in fs.lsdir(SNAPSHOT_LOCK) || []) {
        let m = match(name, /^owner\.([1-9][0-9]*)\.([0-9]+)$/);
        if (m != null && identity.matches_record({ pid: m[1], ticks: m[2] }, "ucode",
            [ "ucode", "-L", LIB_DIR, SNAPSHOTS ], false, true) != "")
            return true;
    }
    return false;
}
// The transition guard chain that a sing-box transition whose rollback
// failed keeps in the production table (service/lifecycle.uc).
const TRANSITION_GUARD_CHAIN = "prokop_transition_guard";
function transition_chain_present() {
    return capture([ "nft", "list", "chain", "inet", PROD_TABLE, TRANSITION_GUARD_CHAIN ]).status == 0;
}
function guards_present() {
    let result = [];
    for (let name in GUARD_TABLES) if (table_present(name) != false) push(result, name);
    if (transition_chain_present()) push(result, PROD_TABLE + ":" + TRANSITION_GUARD_CHAIN);
    return result;
}
// A fail-closed guard that a failed lifecycle transition kept: its DPI guard
// table or the transition guard chain (service/lifecycle.uc
// runtime_guard_kept). Only a restart removes it; until then the lifecycle
// refuses every reload and the snapshot restore refuses to start (UC-019).
function runtime_guard_kept() {
    return table_present(PROD_TABLE + "DpiGuard") != false || transition_chain_present();
}
// A lifecycle action (reload/start, and a stop once its bounded wait got the
// lock) holds the reload lock, and a running list update gets every reload
// queued for it with or without the lock: either would run outside this
// transaction. A queued reload (reload.pending) without such a live owner is
// no action: the transaction's own reload takes the free lock, and init.d
// drains the queue at its end, still under the guard; a start or reload
// never confirms an unsettled candidate as last-known-working
// (config/snapshots.uc confirm-working). Refusing it instead would stall
// autotune, and its rollback, until some other reload came by.
// The lock and its owner record: core/runtime_lock.uc; the list worker:
// core/list_worker.uc.
function service_action() {
    if (runtime_lock.busy(RELOAD_LOCK) || list_worker.running(LIB_DIR)) return "service_action_in_progress";
    return null;
}
// An apply or rollback never changes a runtime that an explicit stop holds
// down, nor one that was not started since boot and is down (its production
// table is missing): its reload would be skipped and nothing could verify
// the result.
function service_stopped() {
    return fs.stat(STOP_REQUESTED) != null || (fs.stat(EXPLICIT_START) == null && table_present(PROD_TABLE) === false);
}
// The last-known-working snapshot, compared by user configuration.
function lkg_fingerprint() {
    let id = trim(as_string(fs.readfile(SNAPSHOT_DIR + "/last-known-working")));
    let item = match(id, /^[0-9]+_[0-9]+$/) != null ? read_json(SNAPSHOT_DIR + "/" + id + ".json") : null;
    return type(item) == "object" && type(item.content) == "string" ? fingerprint(item.content) : "";
}
function queue_entry(number_value) {
    for (let line in split(as_string(fs.readfile(PROC_QUEUE)), "\n")) {
        let f = split(trim(line), /[ \t]+/);
        if (length(f) >= 8 && int(f[0]) == number_value) return { queue: int(f[0]), portid: f[1], total: int(f[2]), id_sequence: int(f[7]) };
    }
    return null;
}
// The production queue rule of a zapret rule (TCP): found by meaning.
function queue_rule_counter(owner) {
    let out = capture([ "nft", "-j", "list", "chain", "inet", PROD_TABLE, "mangle_output" ]);
    let listing = parse_json(out.output);
    if (type(listing) != "object" || type(listing.nftables) != "array") return null;
    for (let item in listing.nftables) {
        let r = item.rule;
        if (type(r) != "object") continue;
        let mark_ok = false, tcp = false, queue_ok = false, packets = null;
        for (let e in r.expr || []) {
            // The route mark on Prokop's own mark bits (`meta mark & M == V`,
            // nft/apply.uc, UC-104) or, from an older release, exact.
            let left = type(e.match) == "object" ? e.match.left : null;
            if (type(left) == "object" && type(left["&"]) == "array" && length(left["&"]) == 2 &&
                type(left["&"][0]) == "object" && type(left["&"][0].meta) == "object" && left["&"][0].meta.key == "mark" &&
                (int(left["&"][1]) & owner.mark_value) == owner.mark_value && int(e.match.right) == owner.mark_value)
                mark_ok = true;
            if (type(left) == "object" && type(left.meta) == "object") {
                if (left.meta.key == "mark" && int(e.match.right) == owner.mark_value) mark_ok = true;
                if (left.meta.key == "l4proto" && e.match.right == "tcp") tcp = true;
            }
            if (type(e.queue) == "object" && int(e.queue.num) == owner.queue) queue_ok = true;
            if (type(e.counter) == "object") packets = int(e.counter.packets);
        }
        if (mark_ok && tcp && queue_ok) return packets;
    }
    return null;
}
function uncommitted_changes() {
    let st = fs.stat(UCI_SAVEDIR + "/prokop");
    return st != null && st.size > 0;
}
// sing-box connection tracker (clash API) of the generated configuration.
function clash_controller(config) {
    let c = type(config) == "object" && type(config.experimental) == "object" ? config.experimental.clash_api : null;
    if (type(c) != "object" || type(c.external_controller) != "string") return null;
    let m = match(c.external_controller, /^(.*):([0-9]+)$/);
    if (m == null) return null;
    let host = m[1];
    if (index([ "", "0.0.0.0", "::", "[::]" ], host) >= 0) host = "127.0.0.1";
    return { url: "http://" + host + ":" + m[2], secret: type(c.secret) == "string" ? c.secret : "" };
}
function clash_connections(ctl) {
    // Bounded like every controller request (UC-016).
    let args = [ CURL, "-s", "--noproxy", "*", "--connect-timeout", "2", "--max-time", "3" ], header = null;
    if (ctl.secret != "") {
        // The secret goes through a private file, never the command line.
        header = trim(capture([ "mktemp", TMP_DIR + "/prokop-autotune-hdr.XXXXXX" ]).output);
        if (header == "" || fs.writefile(header, "Authorization: Bearer " + ctl.secret + "\n") == null) { if (header != "") fs.unlink(header); return null; }
        push(args, "-H", "@" + header);
    }
    push(args, ctl.url + "/connections");
    let out = capture(args);
    if (header != null) fs.unlink(header);
    let parsed = parse_json(out.output);
    return type(parsed) == "object" && type(parsed.connections) == "array" ? parsed.connections : null;
}
// Which outbound a production connection to the target really takes: a
// connection that sends nothing (curl ftp:// on port 443 waits for a greeting
// that never comes) is held open from a known local port through the normal
// path (system resolver, no isolation mark), and the tracker entry with that
// source port and host names the chain. Only the TCP handshake reaches the
// remote; the hold ends by itself after HOLD_SECONDS.
function path_probe(host, config) {
    let ctl = clash_controller(config);
    if (ctl == null) return { ok: false, reason: "clash_api_unavailable", chains: null };
    let base = 45000 + autotune_lock.owner_pid() % 900;
    for (let attempt = 0; attempt < 3; attempt++) {
        let port = base + attempt * 1000;
        system(command([ CURL, "-s", "-o", "/dev/null", "--noproxy", "*", "--ipv4", "--local-port", "" + port,
            "--connect-timeout", "4", "--max-time", "" + HOLD_SECONDS, "ftp://" + host + ":443/" ]) + " >/dev/null 2>&1 &");
        let polled = false;
        for (let i = 0; i < HOLD_SECONDS - 1; i++) {
            if (interrupted) return { ok: false, reason: "interrupted", chains: null, interrupted: true };
            system("sleep 1");
            let list = clash_connections(ctl);
            if (list == null) continue;
            polled = true;
            for (let c in list) {
                let md = type(c) == "object" && type(c.metadata) == "object" ? c.metadata : {};
                if (int(md.sourcePort) == port && lc(as_string(md.host)) == lc(host))
                    return { ok: true, reason: null, port, chains: type(c.chains) == "array" ? c.chains : [], network: md.network || null,
                        rule: substr(as_string(c.rule), 0, 160) };
            }
        }
        if (!polled) return { ok: false, reason: "clash_api_unreachable", chains: null };
    }
    return { ok: false, reason: "connection_not_seen", chains: null };
}
function check(checks, name, ok, detail) { push(checks, { name, ok: !!ok, detail: detail == null ? null : detail }); return !!ok; }

// Every failed probe died before the TCP connection was up: the WAN, not
// the candidate, failed the verification (AT-3).
// A curl timeout (exit 28) without time_connect is not such proof: curl
// reports a TLS handshake the DPI blackholes the same way, and these probes
// have no SYN-ACK count (probe.uc handshake). It blames the candidate.
function network_unavailable(probes, successes) {
    let proven = (p) => select_module.network_failure(p) && !(p.curl_exit_code == 28 && p.syn_acks == null);
    return successes < length(probes) &&
        length(filter(probes, (p) => p.class != "success" && !proven(p))) == 0;
}

// ---- marked verification of a device-limited rule ---------------------------

function remove_verify_table() {
    if (table_present(VERIFY_TABLE) === false) return true;
    success([ "nft", "delete", "table", "inet", VERIFY_TABLE ]);
    return table_present(VERIFY_TABLE) === false;
}
function fields(line) { return filter(split(trim(replace(as_string(line), "\t", " ")), " "), (f) => f != ""); }
// The dedicated source ports must be outside the ephemeral range, or another
// connection of the router to the target could pick one.
function verify_ports_free() {
    let range = fields(fs.readfile(PORT_RANGE_FILE));
    return length(range) == 2 && (VERIFY_PORT_LAST < int(range[0]) || VERIFY_PORT_FIRST > int(range[1]));
}
function create_verify_table(ip, mark_value) {
    let pipe = fs.popen("nft -f - >/dev/null 2>&1", "w");
    if (pipe == null) return false;
    pipe.write("create table inet " + VERIFY_TABLE + "\n" +
        "add chain inet " + VERIFY_TABLE + " premark { type route hook output priority mangle - 2; policy accept; }\n" +
        "add rule inet " + VERIFY_TABLE + " premark ip daddr " + ip + " tcp dport 443 tcp sport " + VERIFY_PORT_FIRST + "-" + VERIFY_PORT_LAST +
        " meta mark 0x00000000 meta mark set " + sprintf("0x%08x", mark_value) + " counter accept comment \"rule_mark\"\n");
    return pipe.close() == 0 && table_present(VERIFY_TABLE) === true;
}
function verify_rule_packets() {
    let listing = parse_json(capture([ "nft", "-j", "list", "table", "inet", VERIFY_TABLE ]).output);
    if (type(listing) != "object" || type(listing.nftables) != "array") return null;
    for (let item in listing.nftables) {
        let r = item.rule;
        if (type(r) != "object" || r.comment != "rule_mark") continue;
        for (let e in r.expr || []) if (type(e.counter) == "object") return int(e.counter.packets);
    }
    return null;
}
// Sockets of the probe tuple that may still send (TIME_WAIT sends nothing new).
function verify_sockets(ip) {
    let o = split(ip, "."), count = 0;
    let be = sprintf("%02X%02X%02X%02X", int(o[0]), int(o[1]), int(o[2]), int(o[3]));
    let le = sprintf("%02X%02X%02X%02X", int(o[3]), int(o[2]), int(o[1]), int(o[0]));
    for (let line in split(as_string(fs.readfile(PROC_NET + "/tcp")), "\n")) {
        let f = fields(line);
        if (length(f) < 4 || index(f[1], ":") < 0 || index(f[2], ":") < 0) continue;
        let port = hex(substr(f[1], index(f[1], ":") + 1));
        let remote = uc(substr(f[2], 0, index(f[2], ":")));
        if (port < VERIFY_PORT_FIRST || port > VERIFY_PORT_LAST || (remote != be && remote != le)) continue;
        if (f[3] != "06") count++;
    }
    return count;
}
// Requests of the router through the production queue of the rule. The
// table is removed before the verdict in every outcome.
function marked_traffic(plan, owner, checks, result) {
    let ip = plan.target.ip;
    if (!check(checks, "verify_path_available", probe_module.valid_ipv4(ip) && owner.mark_value != null &&
        verify_ports_free() && remove_verify_table(), "pinned address, rule mark, free probe ports, no leftover table")) {
        result.ok = false; return result;
    }
    let before_q = queue_entry(plan.owner.queue), before_c = queue_rule_counter(plan.owner);
    let created = create_verify_table(ip, owner.mark_value), probes = [];
    for (let i = 0; created && i < VERIFY_PROBES && !interrupted; i++)
        push(probes, probe_module.probe({ host: plan.target.host, ip, port_range: VERIFY_PORT_FIRST + "-" + VERIFY_PORT_LAST }));
    // The rule counter first, the queue after it: the queue window contains
    // the window of the marked packets.
    let marked = created ? verify_rule_packets() : null;
    let after_q = queue_entry(plan.owner.queue), after_c = queue_rule_counter(plan.owner);
    for (let i = 0; created && i < VERIFY_SETTLE && verify_sockets(ip) > 0; i++) system("sleep 1");
    let removed = remove_verify_table();
    if (interrupted) return { ok: false, checks, traffic: null, interrupted: true };
    let successes = length(filter(probes, (p) => p.class == "success"));
    let t = {
        mode: "rule_mark",
        probes: map(probes, (p) => ({ class: p.class, connect: p.connect, http_status: p.http_status, remote_ip: p.remote_ip,
            time_appconnect_ms: p.time_appconnect_ms, curl_exit_code: p.curl_exit_code })),
        stability: select_module.stability(successes, length(probes)),
        network_unavailable: network_unavailable(probes, successes),
        marked_packets: marked,
        queue_packets: before_q && after_q ? after_q.id_sequence - before_q.id_sequence : null,
        queue_rule_packets: before_c != null && after_c != null ? after_c - before_c : null
    };
    result.traffic = t;
    check(checks, "verify_path_created", created);
    check(checks, "traffic_transport", t.stability == "stable", sprintf("%d/%d", successes, length(probes)));
    // Every probe connection sends at least one packet with the rule mark,
    // and every marked packet enters the rule's production queue.
    check(checks, "traffic_rule_mark", marked != null && marked >= VERIFY_PROBES, as_string(marked) + " marked packets");
    check(checks, "traffic_dpi_queue", marked != null && t.queue_packets != null && t.queue_packets >= marked &&
        t.queue_rule_packets != null && t.queue_rule_packets >= marked,
        sprintf("queue %s, rule %s packets", as_string(t.queue_packets), as_string(t.queue_rule_packets)));
    check(checks, "verify_path_removed", removed);
    for (let c in checks) if (!c.ok) result.ok = false;
    return result;
}

// Runtime coherence of the rule with an expected strategy, plus (optionally)
// a small sample of normal production requests proving they took this rule's
// zapret path (FakeIP answer, the rule's queue and queue rule counting them).
function verify_production(plan, expected_opt, traffic) {
    let checks = [];
    let text = fs.readfile(CONFIG_FILE);
    let sections = parse_config(text);
    let section = find_section(sections, plan.owner.section);
    check(checks, "rule_strategy", section != null && normalize(section.options.nfqws_opt) == normalize(expected_opt),
        section == null ? "rule missing" : null);
    let owner = owner_of(sections, plan.target.host, plan.target.ip, true);
    check(checks, "rule_owns_target", owner.decided && owner.kind == "zapret" && owner.section == plan.owner.section &&
        owner.queue == plan.owner.queue, owner.decided ? owner.kind + ":" + as_string(owner.section || owner.outbound) : owner.reason);
    let status = parse_json(capture([ "ucode", "-L", LIB_DIR, ZAPRET_RUNTIME, "status" ]).output);
    check(checks, "zapret_runtime_ready", type(status) == "object" && status.ready && !status.conflict &&
        status.running_process_count == status.expected_process_count &&
        status.supervisor_process_count == status.expected_process_count,
        type(status) == "object" ? sprintf("%d/%d running, %d supervisors", status.running_process_count, status.expected_process_count, status.supervisor_process_count) : "status unavailable");
    let saved = identity.read_record(CHILD_PID_DIR + "/" + plan.owner.section + ".pid");
    let expected_args = [ "--qnum=" + plan.owner.queue, "--dpi-desync-fwmark=" + DESYNC_MARK, ...words(effective(expected_opt)) ];
    let argv = null;
    if (saved != null && identity.start_ticks(saved.pid) == saved.ticks) {
        argv = split(as_string(fs.readfile("/proc/" + saved.pid + "/cmdline")), "\0");
        if (length(argv) > 0 && argv[length(argv) - 1] == "") pop(argv);
    }
    let exe = saved != null ? replace(as_string(fs.readlink("/proc/" + saved.pid + "/exe")), /^.*\//, "") : "";
    check(checks, "nfqws_arguments", argv != null && replace(exe, / \(deleted\)$/, "") == "nfqws" &&
        sprintf("%J", identity.argv_tokens(argv)) == sprintf("%J", identity.argv_tokens([ argv[0], ...expected_args ])),
        argv == null ? "process missing" : null);
    let q = queue_entry(plan.owner.queue);
    check(checks, "queue_owner", q != null && saved != null && q.portid == saved.pid, q == null ? "queue unbound" : null);
    check(checks, "no_guard", length(guards_present()) == 0, join(",", guards_present()));
    check(checks, "no_snapshot_operation", !snapshot_operation_active());
    let action = service_action();
    check(checks, "no_service_action", action == null, action);
    check(checks, "no_probe_table", table_present(PROBE_TABLE) == false);
    let result = { ok: true, checks, traffic: null };
    for (let c in checks) if (!c.ok) result.ok = false;
    if (!traffic || !result.ok) return result;
    // sing-box sends nothing of the router into a rule limited to other
    // devices: its queue is proven with marked requests instead. Decided
    // from the routing as it is now, never from the plan file.
    if (owner.source_scoped === true) return marked_traffic(plan, owner, checks, result);

    // Normal production requests: system resolver, no pinned address, no
    // isolation mark or source ports.
    let before_q = queue_entry(plan.owner.queue), before_c = queue_rule_counter(plan.owner);
    let probes = [];
    for (let i = 0; i < VERIFY_PROBES; i++) {
        if (interrupted) return { ok: false, checks, traffic: null, interrupted: true };
        push(probes, probe_module.probe({ host: plan.target.host, production: true }));
    }
    let after_q = queue_entry(plan.owner.queue), after_c = queue_rule_counter(plan.owner);
    let successes = length(filter(probes, (p) => p.class == "success"));
    let t = {
        probes: map(probes, (p) => ({ class: p.class, connect: p.connect, http_status: p.http_status, remote_ip: p.remote_ip,
            time_appconnect_ms: p.time_appconnect_ms, curl_exit_code: p.curl_exit_code })),
        stability: select_module.stability(successes, length(probes)),
        network_unavailable: network_unavailable(probes, successes),
        queue_packets: before_q && after_q ? after_q.id_sequence - before_q.id_sequence : null,
        queue_rule_packets: before_c != null && after_c != null ? after_c - before_c : null
    };
    result.traffic = t;
    check(checks, "traffic_transport", t.stability == "stable", sprintf("%d/%d", successes, length(probes)));
    check(checks, "traffic_sing_box_path", length(filter(probes, (p) => p.remote_ip != null && is_fakeip(p.remote_ip))) == length(probes),
        "FakeIP answers");
    // Every probe connection sends at least one packet through the rule's
    // queue; other traffic of the rule can only add to the count.
    check(checks, "traffic_dpi_queue", t.queue_packets != null && t.queue_packets >= VERIFY_PROBES &&
        t.queue_rule_packets != null && t.queue_rule_packets >= VERIFY_PROBES,
        sprintf("queue %s, rule %s packets", as_string(t.queue_packets), as_string(t.queue_rule_packets)));
    // The counters alone could be other traffic of the rule: the tracker must
    // show a production connection to the target on this rule's outbound.
    let path = path_probe(plan.target.host, singbox_config(sections));
    if (path.interrupted) return { ok: false, checks, traffic: t, interrupted: true };
    t.path = path;
    check(checks, "traffic_rule_path", path.ok && path.network == "tcp" && index(path.chains, plan.owner.outbound) >= 0,
        path.ok ? join(",", path.chains) : path.reason);
    for (let c in checks) if (!c.ok) result.ok = false;
    return result;
}

// ---- plan ---------------------------------------------------------------------

function selection_fingerprint(sel, entry) {
    return sha_text(sprintf("%J", { host: sel.target.host, ip: sel.target.ip, selected: sel.selected,
        reason: sel.reason, confidence: sel.confidence, nfqws_opt: entry ? entry.nfqws_opt : null,
        probes: length(sel.probes || []) }));
}

function plan(selection_file, resolver) {
    let sel = read_json(selection_file);
    let result = { status: "failed", reason: null, target: null, selected: null, applied: false };
    if (type(sel) != "object" || sel.status != "selected" || type(sel.target) != "object" ||
        !probe_module.valid_host(sel.target.host) || !probe_module.valid_ipv4(sel.target.ip) || !sel.selected) {
        result.reason = "invalid_selection"; return result;
    }
    result.target = { host: sel.target.host, ip: sel.target.ip, resolver: resolver || sel.target.resolver || null };
    if (!probe_module.valid_ipv4(result.target.resolver)) { result.reason = "resolver_missing"; return result; }
    result.selected = sel.selected;
    result.selection = { reason: sel.reason, confidence: sel.confidence };
    if (index([ "high", "medium" ], sel.confidence) < 0) { result.reason = "selection_confidence_too_low"; return result; }
    let text = fs.readfile(CONFIG_FILE);
    if (text == null) { result.reason = "config_unavailable"; return result; }
    result.config_hash = sha_text(text);
    if (!valid_hash(result.config_hash)) { result.reason = "hash_unavailable"; return result; }
    let sections = parse_config(text);
    // Clients reach the target as production DNS answers it; verification
    // can only prove the sing-box path of a FakeIP-routed target.
    let dns = probe_module.production_dns(sel.target.host);
    result.production_dns = dns.fakeip ? "fakeip" : dns.answers > 0 ? "real_address" : "no_answer";
    let owner = owner_of(sections, sel.target.host, sel.target.ip, dns.fakeip);
    result.owner = owner;
    let entry = catalog.find(sel.selected);
    result.selection.fingerprint = selection_fingerprint(sel, entry);

    if (sel.selected == "direct") {
        // The control candidate never mutates production. Whether a
        // real-address connection enters sing-box at all depends on the nft
        // interception sets, so only FakeIP-routed targets are judged.
        if (!dns.fakeip) { result.status = "not_applicable"; result.reason = "target_not_fakeip_routed"; }
        else if (!owner.decided) { result.status = "not_applicable"; result.reason = "rule_owner_undecidable:" + owner.reason; }
        else if (owner.kind == "zapret") { result.status = "direct_not_applicable"; result.reason = "direct_would_disable_dpi_for_rule"; }
        else { result.status = "no_change_required"; result.reason = "target_not_handled_by_dpi_rule"; }
        return result;
    }
    if (entry == null) { result.status = "failed"; result.reason = "unknown_candidate"; return result; }
    let checked = catalog.validate_entry(entry);
    if (checked.state != "supported" || checked.protocol != "tcp") {
        result.status = "failed"; result.reason = "candidate_unsupported"; result.candidate_reason = checked.reason; return result;
    }
    if (!dns.fakeip) { result.status = "not_applicable"; result.reason = "target_not_fakeip_routed"; return result; }
    if (!owner.decided) { result.status = "not_applicable"; result.reason = "rule_owner_undecidable:" + owner.reason; return result; }
    if (owner.kind != "zapret") { result.status = "not_applicable"; result.reason = "target_not_handled_by_dpi_rule"; return result; }
    let section = find_section(sections, owner.section);
    let current = section.options.nfqws_opt;
    result.current_strategy = normalize(current);
    result.scope = { rule: owner.section, matchers: rule_scope(section) };
    // Only the TCP/443 profile is replaced; the other profiles of the rule
    // (HTTP, QUIC) stay word for word. An empty option is the default
    // strategy, made explicit here.
    let splice = dpi_strategy.tcp443_splice(effective(current), checked.nfqws_opt);
    if (splice.error) { result.status = "not_applicable"; result.reason = splice.error; return result; }
    result.proposed_strategy = splice.opt;
    result.profile = { index: splice.profile, before: splice.before, after: splice.after };
    if (splice.opt == effective(current)) { result.status = "no_change_required"; result.reason = "candidate_already_active"; return result; }
    let candidate = build_candidate(text, owner.section, splice.opt);
    if (candidate.error) { result.status = "failed"; result.reason = candidate.error; return result; }
    result.candidate_hash = candidate.hash;
    result.changes = [ { section: owner.section, option: "nfqws_opt", from: normalize(current), to: splice.opt } ];
    result.status = "ready";
    result.reason = null;
    result.created_at = now();
    return result;
}

// ---- apply ----------------------------------------------------------------------

// Every snapshots.uc call here is a transaction (apply, restore, confirm).
function snapshots(args) {
    let out = capture_detached([ "ucode", "-L", LIB_DIR, SNAPSHOTS, ...args ]);
    let parsed = parse_json(out.output);
    return type(parsed) == "object" ? parsed : { status: "failed", reason: "snapshot_tool_failed" };
}

// The before-autotune snapshot of a recorded apply, also when the process
// died before it could record the id (matched by config hash and time).
function find_pre_snapshot(s) {
    if (s.pre_snapshot != null) return s.pre_snapshot;
    let found = null;
    for (let file in fs.lsdir(SNAPSHOT_DIR) || []) {
        let item = read_json(SNAPSHOT_DIR + "/" + file);
        if (type(item) == "object" && item.reason == "before-autotune" && item.config_hash == s.plan_config_hash &&
            int(item.created_at) >= int(s.started_at) - 1 && (found == null || item.created_at > found.created_at))
            found = item;
    }
    return found ? found.id : null;
}

// What an apply left behind, from facts only. The user configuration is
// compared without the shutdown_correctly bookkeeping of older releases.
//   not_applied        config is the pre-apply file and no guard is active
//   candidate_active   config is the candidate, no guard: reload completed or
//                      never started; verification verdict missing
//   in_transaction     a restore guard or snapshot operation is active
//   superseded         no transaction active and the config is neither: it was
//                      changed outside this apply, which no longer owns it
//   state_unreadable   the record itself cannot be read
function diagnose(s) {
    let text = fs.readfile(CONFIG_FILE);
    let hash = text != null ? sha_text(text) : "";
    let fp = fingerprint(text);
    let is_pre = valid_hash(hash) && (hash == s.plan_config_hash || (valid_hash(s.plan_config_fingerprint) && fp == s.plan_config_fingerprint));
    let is_candidate = valid_hash(hash) && (hash == s.candidate_hash || (valid_hash(s.candidate_fingerprint) && fp == s.candidate_fingerprint));
    let config_is = !valid_hash(hash) ? "unreadable" : is_pre ? "pre_apply" : is_candidate ? "candidate" : "other";
    let guards = guards_present();
    let diagnosis = s.unreadable ? "state_unreadable" : length(guards) > 0 || snapshot_operation_active() ? "in_transaction" :
        config_is == "pre_apply" ? "not_applied" : config_is == "candidate" ? "candidate_active" :
        config_is == "other" ? "superseded" : "in_transaction";
    return { diagnosis, config_is, config_hash: hash, guards, pre_snapshot: find_pre_snapshot(s) };
}

// Whether the rule the record changed still runs the candidate's strategy
// in `text`: an enabled zapret rule whose nfqws_opt is the candidate's. The
// same definition as config/snapshots.uc runs_strategy.
function runs_candidate_strategy(s, text) {
    let m = s.mutation;
    if (type(m) != "object" || type(m.section) != "string" || type(m.to) != "string") return false;
    let section = find_section(parse_config(text), m.section);
    return section != null && resolver.enabled(section) && section.options.action == "zapret" &&
        type(section.options.nfqws_opt) == "string" && normalize(section.options.nfqws_opt) == normalize(m.to);
}

// A record still waiting for a decision on its candidate, whatever the
// configuration is now: unfinished, needs_attention, or failed with a
// rollback left to do (as config/snapshots.uc autotune_objection reads it).
function undecided(s) {
    return index(TERMINAL_PHASES, s.phase) < 0 || s.phase == "needs_attention" || (s.phase == "failed" && s.rollback_available === true);
}

// A recorded apply that still needs a decision: an unfinished one that may
// have changed production, a verification interrupted after the reload while
// the candidate is still active, or needs_attention while production is not
// provably back on the pre-apply configuration.
function unresolved(s, d) {
    if (type(s) == "object" && s.unreadable) return true;
    if (type(s) != "object" || s.mutation == null || d.diagnosis == "superseded") return false;
    if (index(TERMINAL_PHASES, s.phase) < 0) return d.diagnosis != "not_applied";
    if (s.phase == "failed" && s.rollback_available) return d.diagnosis != "not_applied";
    if (s.phase == "needs_attention") return d.diagnosis != "not_applied";
    return false;
}

// Everything that must still hold for the plan: nothing is changed on failure.
function stale_reason(p, resolver) {
    if (service_stopped()) return "service_stopped";
    if (runtime_guard_kept()) return "runtime_guard_active";
    if (length(guards_present()) > 0) return "restore_guard_active";
    if (snapshot_operation_active()) return "snapshot_operation_in_progress";
    let action = service_action();
    if (action != null) return action;
    if (table_present(PROBE_TABLE) != false) return "probe_path_present";
    // Left by a verification that was killed; nothing else creates it and
    // this process holds the autotune lock.
    if (!remove_verify_table()) return "verify_path_present";
    // Pending LuCI/uci changes would ride along: reload reads through them.
    if (uncommitted_changes()) return "uncommitted_uci_changes";
    let text = fs.readfile(CONFIG_FILE);
    if (text == null || sha_text(text) != p.config_hash) return "config_changed";
    // Production must run the configuration the candidate is built from: the
    // file is the last confirmed working one (no committed but unreloaded
    // edits would ride along) and the rule's runtime is on the planned strategy.
    let fp = fingerprint(text);
    if (!valid_hash(fp) || lkg_fingerprint() != fp) return "config_not_last_known_good";
    let sections = parse_config(text);
    let section = find_section(sections, p.owner.section);
    if (section == null || normalize(section.options.nfqws_opt) != p.changes[0].from) return "strategy_changed";
    if (!probe_module.production_dns(p.target.host).fakeip) return "target_not_fakeip_routed";
    let owner = owner_of(sections, p.target.host, p.target.ip, true);
    if (!owner.decided || owner.kind != "zapret" || owner.section != p.owner.section || owner.queue != p.owner.queue) return "rule_owner_changed";
    if (!verify_production(p, p.changes[0].from, false).ok) return "runtime_not_on_planned_strategy";
    let resolved = probe_module.resolve(p.target.host, resolver || p.target.resolver || "");
    if (resolved.status != "ok" || index(resolved.addresses, p.target.ip) < 0) return "target_resolution_changed";
    // The plan file is input, not trusted: the candidate is re-derived and
    // must still be a supported TCP/443 profile replacing a TCP/443 profile.
    let entry = catalog.find(p.selected);
    let checked = entry ? catalog.validate_entry(entry) : null;
    let splice = checked != null ? dpi_strategy.tcp443_splice(effective(p.changes[0].from), checked.nfqws_opt) : null;
    if (checked == null || checked.state != "supported" || checked.protocol != "tcp" || splice.error || splice.opt != p.changes[0].to)
        return "candidate_invalid";
    return null;
}

// The history event of a rollback that started its restore: an autotune
// rollback, never a restore, with who started it (the operator, or the apply
// whose candidate failed its verification) and its outcome once known: a
// success only when the old configuration and strategy are proven back
// (UC-060, design H.6). The restore itself records nothing ("autotune").
function rollback_event(restored, phase, trigger, candidate) {
    if (!restored.started) return;
    let status = phase == "rolled_back" ? "success" : restored.status == "restored_not_started" ? "not_started" : "failure";
    success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "autotune_rollback", status,
        trigger, as_string(candidate) ]);
}

// Restore the pre-apply snapshot through the standard restore transaction
// and prove the old configuration and runtime are back.
// A rollback replaces only the candidate this apply wrote: the restore is
// given the candidate's fingerprint (the shutdown_correctly flag of older
// releases aside) and refuses before any change when the configuration was
// edited since, during the verification or right before an operator's
// rollback. The edit stays and is saved as a snapshot; LKG is not moved
// (UC-017).
function rollback_to(audit, p, why) {
    let recorded = { phase: audit.phase, status: audit.status, reason: audit.reason };
    audit.phase = "rolling_back";
    state_write(audit);
    let expected = valid_hash(audit.candidate_fingerprint) ? audit.candidate_fingerprint : as_string(audit.candidate_hash);
    let trigger = why == "operator_rollback" ? "manual" : "automatic";
    let restored = snapshots([ "restore", audit.pre_snapshot, expected, "autotune" ]);
    // A lifecycle action that owns the reload lock, or a running list update
    // (which also fails verification's no_service_action), refuses the
    // restore unchanged. An automatic rollback waits for it, bounded, instead of
    // leaving the unverified candidate in place without a guard.
    for (let waited = 0; why != "operator_rollback" && restored.status == "busy" &&
        restored.reason == "service_action_in_progress" && waited < ROLLBACK_WAIT_SECONDS && !interrupted; waited++) {
        system("sleep 1");
        if (service_action() != "service_action_in_progress") restored = snapshots([ "restore", audit.pre_snapshot, expected, "autotune" ]);
    }
    audit.rollback = { status: restored.status, reason: restored.reason || null, guard: restored.guard || null };
    let edited = restored.reason == "config_changed_during_transaction";
    if (edited) audit.rollback.saved_snapshot = restored.saved_snapshot || null;
    if (restored.status != "success" && (why == "operator_rollback" || why == "observation_failed") && length(guards_present()) == 0 &&
        ((edited && !restored.started) || diagnose(audit).diagnosis == "candidate_active")) {
        // The restore changed nothing: the verified record stays as it was.
        audit.phase = recorded.phase; audit.status = recorded.status; audit.reason = recorded.reason;
        audit.last_attempt = { status: "failed", reason: "rollback_" + as_string(restored.reason || restored.status), finished_at: now() };
        state_write(audit);
        // A restore that ran and put the candidate back is still a failed
        // rollback in the history.
        rollback_event(restored, "failed", trigger, audit.selected);
        return { status: "failed", reason: "rollback_not_started:" + as_string(restored.reason || restored.status), phase: audit.phase };
    }
    // Not rolled back. After an edit made while the candidate verified, the
    // candidate may still be part of the edited configuration, which no
    // longer belongs to this apply. An edit that landed while the restore
    // itself ran (it wrote the pre-apply configuration and reloaded): the
    // runtime may run either, and the reason says the rollback started.
    if (restored.status != "success") {
        audit.phase = "needs_attention"; audit.status = "needs_attention";
        audit.reason = why + (!edited ? ":rollback_" + as_string(restored.status) :
            restored.started ? ":config_changed_during_rollback" : ":config_changed_during_transaction");
        audit.finished_at = now();
        state_write(audit);
        rollback_event(restored, audit.phase, trigger, audit.selected);
        return audit;
    }
    let text = fs.readfile(CONFIG_FILE);
    let lkg = trim(as_string(fs.readfile(SNAPSHOT_DIR + "/last-known-working")));
    let old = verify_production(p, p.changes[0].from, false);
    let hash = text != null ? sha_text(text) : "";
    audit.rollback.config_exact = valid_hash(hash) && hash == p.config_hash;
    audit.rollback.config_hash_restored = audit.rollback.config_exact ||
        (valid_hash(audit.plan_config_fingerprint) && fingerprint(text) == audit.plan_config_fingerprint);
    audit.rollback.lkg = lkg;
    audit.rollback.lkg_is_pre_snapshot = lkg == audit.pre_snapshot;
    audit.rollback.runtime = old;
    let ok = audit.rollback.config_hash_restored && audit.rollback.lkg_is_pre_snapshot && old.ok;
    audit.phase = ok ? "rolled_back" : "needs_attention";
    audit.status = audit.phase;
    audit.reason = !ok && interrupted ? why + ":proof_interrupted" : why;
    audit.finished_at = now();
    state_write(audit);
    rollback_event(restored, audit.phase, trigger, audit.selected);
    return audit;
}

function valid_plan(p) {
    return type(p) == "object" && p.status == "ready" && type(p.changes) == "array" && length(p.changes) == 1 &&
        type(p.changes[0]) == "object" && type(p.owner) == "object" && type(p.target) == "object" &&
        type(p.selection) == "object" && index([ "high", "medium" ], p.selection.confidence) >= 0 &&
        type(p.selected) == "string" && p.selected != "direct" &&
        type(p.owner.section) == "string" && p.changes[0].section == p.owner.section && p.changes[0].option == "nfqws_opt" &&
        type(p.changes[0].from) == "string" && type(p.changes[0].to) == "string" &&
        valid_hash(p.config_hash) && valid_hash(p.candidate_hash);
}

function apply(plan_file, resolver) {
    let p = read_json(plan_file);
    if (!valid_plan(p)) return { status: "failed", reason: "invalid_plan", applied: false };
    let previous = state_read();
    if (type(previous) == "object") {
        let d = diagnose(previous);
        if (unresolved(previous, d))
            return { status: "failed", reason: "previous_apply_unresolved", previous_phase: previous.phase, diagnosis: d.diagnosis, applied: false };
    }
    let audit = { target: p.target, selected: p.selected, selection: p.selection, plan_config_hash: p.config_hash,
        candidate_hash: p.candidate_hash, mutation: p.changes[0], scope: p.scope, started_at: now(),
        pre_snapshot: null, reload: null, verification: null, rollback: null, phase: "checking", applied: false };
    // A refusal before any mutation never erases the record of an earlier
    // apply that reached the transaction: its pre-apply snapshot and explicit
    // rollback stay reachable; the refusal is kept as last_attempt.
    let refuse = (status, reason) => {
        audit.phase = status; audit.status = status; audit.reason = reason; audit.finished_at = now();
        if (type(previous) == "object" && previous.reload != null) {
            previous.last_attempt = { status, reason, selected: p.selected, started_at: audit.started_at, finished_at: audit.finished_at };
            state_write(previous);
        }
        else state_write(audit);
        return audit;
    };
    let reason = stale_reason(p, resolver);
    // A terminal signal also hits the checks' children (dig, curl): the
    // interruption, not their failure, is the reason.
    if (interrupted) return refuse("failed", "interrupted_before_mutation");
    if (reason != null) return refuse("stale", reason);
    let text = fs.readfile(CONFIG_FILE);
    let candidate = build_candidate(text, p.owner.section, p.changes[0].to);
    if (interrupted) return refuse("failed", "interrupted_before_mutation");
    if (candidate.error || candidate.hash != p.candidate_hash) return refuse("stale", candidate.error || "candidate_differs_from_plan");
    audit.plan_config_fingerprint = fingerprint(text);
    audit.candidate_fingerprint = candidate.fingerprint;
    if (interrupted) return refuse("failed", "interrupted_before_mutation");
    let file = trim(capture([ "mktemp", TMP_DIR + "/prokop-autotune-candidate.XXXXXX" ]).output);
    if (file == "" || fs.writefile(file, candidate.text) == null) {
        if (file != "") fs.unlink(file);
        return refuse("failed", "candidate_write_failed");
    }
    audit.phase = "applying";
    if (!state_write(audit)) { fs.unlink(file); return refuse("failed", "state_write_failed"); }
    if (interrupted) { fs.unlink(file); return refuse("failed", "interrupted_before_mutation"); }
    // The earlier apply's pre-apply snapshot stays protected from retention
    // while its record remains the one to roll back to.
    let keep = type(previous) == "object" && previous.reload != null ? as_string(previous.pre_snapshot) : "";
    let applied = snapshots([ "apply", file, p.config_hash, keep ]);
    fs.unlink(file);
    audit.reload = { status: applied.status, reason: applied.reason || null, guard: applied.guard || null };
    audit.pre_snapshot = applied.pre_snapshot || null;
    if (applied.status == "stale") { audit.reload = null; return refuse("stale", applied.reason || "config_changed"); }
    if (applied.status == "no_change") { audit.reload = null; return refuse("no_change_required", "candidate_already_active"); }
    if (applied.status != "success" && applied.status != "recovered" && applied.status != "needs_attention" && !applied.started) {
        // The transaction refused before writing the configuration (busy,
        // snapshot or guard unavailable, concurrent change, tool failure):
        // proven by the file and the guards, never assumed.
        let now_hash = sha_text(fs.readfile(CONFIG_FILE));
        if (valid_hash(now_hash) && length(guards_present()) == 0 && (now_hash == p.config_hash || applied.reason == "concurrent_change")) {
            audit.reload = null;
            return refuse(applied.reason == "concurrent_change" ? "stale" : "failed",
                applied.reason == "concurrent_change" ? "config_changed" : "apply_failed:" + as_string(applied.reason || applied.status));
        }
    }
    if (applied.status == "needs_attention") {
        audit.phase = "needs_attention"; audit.status = "needs_attention"; audit.reason = "apply_" + as_string(applied.reason);
        audit.finished_at = now();
        state_write(audit); return audit;
    }
    if (applied.status != "success") {
        // The transaction put the previous configuration and runtime back
        // (recovered) or never replaced them (failed): nothing was applied.
        // A candidate reload that was only queued behind another lifecycle
        // action never ran: it is named, not reported as a failed candidate.
        let now_hash = sha_text(fs.readfile(CONFIG_FILE));
        audit.phase = "failed"; audit.status = "failed";
        audit.reason = applied.status != "recovered" ? "apply_failed:" + as_string(applied.reason) :
            applied.reason == "target_reload_queued" ? "reload_queued_recovered" : "reload_failed_recovered";
        audit.config_restored = valid_hash(now_hash) && now_hash == p.config_hash;
        audit.guards = guards_present();
        if (!audit.config_restored || length(audit.guards) > 0 || snapshot_operation_active()) { audit.phase = "needs_attention"; audit.status = "needs_attention"; }
        audit.finished_at = now();
        state_write(audit); return audit;
    }

    audit.phase = "verifying";
    state_write(audit);
    let v = verify_production(p, p.changes[0].to, true);
    audit.verification = v;
    if (v.interrupted || interrupted) {
        // Reload succeeded but the verdict is missing: nothing is guessed.
        // LKG still points at the pre-apply state; `rollback` restores it.
        audit.phase = "failed"; audit.status = "failed"; audit.reason = "interrupted_after_apply";
        audit.rollback_available = true; audit.finished_at = now();
        state_write(audit); return audit;
    }
    if (!v.ok) return rollback_to(audit, p, type(v.traffic) == "object" && v.traffic.network_unavailable === true ?
        "verification_network_unavailable" : "verification_failed");
    audit.applied = true;
    // Confirm exactly the verified configuration, never a later edit.
    if (fingerprint(fs.readfile(CONFIG_FILE)) != candidate.fingerprint) {
        audit.phase = "needs_attention"; audit.status = "needs_attention"; audit.reason = "config_changed_during_verification";
        audit.lkg = "not_confirmed"; audit.finished_at = now();
        state_write(audit); return audit;
    }
    // The one confirmation of a candidate: a start or reload never confirms
    // it while this record is unfinished or undecided (config/snapshots.uc).
    // Its snapshot may not push out the pre-apply one the rollback needs.
    let confirmed = snapshots([ "confirm-working", "autotune", as_string(audit.pre_snapshot) ]);
    audit.lkg = confirmed.status;
    audit.finished_at = now();
    if (confirmed.status != "confirmed") {
        // Verified and running, but LKG still names the pre-apply snapshot.
        audit.phase = "needs_attention"; audit.status = "needs_attention"; audit.reason = "lkg_confirm_failed";
        state_write(audit); return audit;
    }
    audit.phase = "applied"; audit.status = "applied";
    state_write(audit); return audit;
}

// The plan view of a recorded apply against the routing as it is now: the
// queue, outbound and mark of the rule that owns the target.
function recorded_plan(s, sections) {
    let p = { target: s.target, owner: { section: s.mutation.section, queue: null }, changes: [ s.mutation ], config_hash: s.plan_config_hash };
    let owner = owner_of(sections, s.target.host, s.target.ip, true);
    p.owner.queue = owner.queue;
    p.owner.outbound = owner.outbound;
    p.owner.mark_value = owner.mark_value;
    return { plan: p, owner };
}

// Production verification checks that need the traffic to have taken the
// rule's path; with them all passed, a failed transport is the candidate's.
const PATH_CHECKS = [ "traffic_sing_box_path", "traffic_dpi_queue", "traffic_rule_path", "traffic_rule_mark",
    "verify_path_available", "verify_path_created", "verify_path_removed" ];

// One observation check of an applied candidate (autotune/manager.uc
// observation_tick), read-only: the same production verification as right
// after the apply, normal requests through the rule included. The verdict:
//   ok            the candidate runs and the target works through it
//   failed        the runtime runs the candidate, the requests took the
//                 rule's path and failed there: the candidate fails
//   inconclusive  nothing can be said now (WAN down, a transaction or a
//                 service action, the runtime or the routing not coherent)
//   ended         the record is no longer this applied candidate (phase,
//                 configuration changed since, another apply)
// started_at names the apply: anything else ends the observation.
function observe(started_at) {
    let s = state_read();
    if (type(s) != "object" || s.unreadable || s.mutation == null || s.started_at !== started_at)
        return { status: "ended", reason: "record_changed" };
    if (s.phase != "applied") return { status: "ended", reason: "apply_" + as_string(s.phase), phase: s.phase };
    let d = diagnose(s);
    if (d.diagnosis == "superseded") return { status: "ended", reason: "config_changed" };
    if (d.diagnosis == "not_applied") return { status: "ended", reason: "not_applied" };
    if (d.diagnosis != "candidate_active") return { status: "inconclusive", reason: d.diagnosis };
    if (service_stopped()) return { status: "inconclusive", reason: "service_stopped" };
    if (runtime_guard_kept()) return { status: "inconclusive", reason: "runtime_guard_active" };
    let action = service_action();
    if (action != null) return { status: "inconclusive", reason: action };
    if (table_present(PROBE_TABLE) != false) return { status: "inconclusive", reason: "probe_path_present" };
    let r = recorded_plan(s, parse_config(fs.readfile(CONFIG_FILE)));
    if (!r.owner.decided || r.owner.kind != "zapret" || r.owner.section != s.mutation.section)
        return { status: "inconclusive", reason: "rule_owner_changed" };
    let v = verify_production(r.plan, s.mutation.to, true);
    if (v.interrupted || interrupted) return { status: "interrupted", reason: "interrupted" };
    let failing = map(filter(v.checks, (c) => !c.ok), (c) => c.name);
    let t = v.traffic;
    let probes = type(t) == "object" && type(t.probes) == "array" ? t.probes : [];
    let output = { status: "inconclusive", reason: null, failing, at: now(),
        successes: length(filter(probes, (p) => p.class == "success")), attempted: length(probes),
        classes: map(probes, (p) => p.class) };
    if (v.ok) { output.status = "ok"; return output; }
    // The coherence checks failed before any request was sent.
    if (type(t) != "object") { output.reason = "runtime_not_coherent"; return output; }
    if (t.network_unavailable === true) { output.reason = "network_unavailable"; return output; }
    if (length(failing) == 1 && failing[0] == "traffic_transport") { output.status = "failed"; output.reason = "traffic_failed"; return output; }
    output.reason = length(filter(failing, (n) => index(PATH_CHECKS, n) >= 0)) > 0 ? "path_unproven" : "runtime_not_coherent";
    return output;
}

// The snapshot a rollback of the record returns to, or null: the recorded
// before-autotune snapshot; else the last-known-working one while it still
// holds the pre-apply user configuration (checked before any mutation, and
// only a verified apply moves it). An unreadable record returns to the
// last-known-working one (rollback_unreadable).
function rollback_source(s, pre) {
    let id = trim(as_string(fs.readfile(SNAPSHOT_DIR + "/last-known-working")));
    let item = match(id, /^[0-9]+_[0-9]+$/) != null ? read_json(SNAPSHOT_DIR + "/" + id + ".json") : null;
    let working = type(item) == "object" && type(item.content) == "string";
    if (s.unreadable) return working ? id : null;
    if (pre != null && read_json(SNAPSHOT_DIR + "/" + pre + ".json") != null) return pre;
    return working && valid_hash(s.plan_config_fingerprint) && fingerprint(item.content) == s.plan_config_fingerprint ? id : null;
}

// An unreadable record names neither its candidate nor its snapshot. Nothing
// confirms a candidate as last-known-working while the record is unreadable
// (config/snapshots.uc confirm-working), so the last-known-working snapshot
// is the configuration to return to: restored when the configuration differs
// from it, then the record is set aside (.corrupt) for inspection.
function rollback_unreadable() {
    if (runtime_guard_kept()) return { status: "failed", reason: "runtime_guard_active" };
    if (length(guards_present()) > 0) return { status: "failed", reason: "restore_guard_active" };
    if (snapshot_operation_active()) return { status: "failed", reason: "snapshot_operation_in_progress" };
    if (service_stopped()) return { status: "failed", reason: "service_stopped" };
    let action = service_action();
    if (action != null) return { status: "failed", reason: action };
    let id = trim(as_string(fs.readfile(SNAPSHOT_DIR + "/last-known-working")));
    let item = match(id, /^[0-9]+_[0-9]+$/) != null ? read_json(SNAPSHOT_DIR + "/" + id + ".json") : null;
    if (type(item) != "object" || type(item.content) != "string") return { status: "failed", reason: "last_known_working_missing" };
    let result = { phase: "rolled_back", status: "rolled_back", reason: "apply_state_unreadable", mutation: null,
        rollback: { status: "not_needed", reason: null, guard: null, lkg: id }, started_at: now(), finished_at: null };
    if (fingerprint(fs.readfile(CONFIG_FILE)) != fingerprint(item.content)) {
        let restored = snapshots([ "restore", id, "", "autotune" ]);
        result.rollback = { status: restored.status, reason: restored.reason || null, guard: restored.guard || null, lkg: id };
        // The operator's; the record names no candidate.
        rollback_event(restored, restored.status == "success" ? "rolled_back" : "failed", "manual", null);
        if (restored.status != "success")
            return { status: "failed", reason: "rollback_" + as_string(restored.reason || restored.status), rollback: result.rollback };
    }
    result.finished_at = now();
    // A copy is set aside: the unreadable record stays the record until the
    // record of this rollback is on flash, as the autotune state (UC-074).
    let unreadable = fs.readfile(STATE_FILE);
    if (unreadable != null) fs.writefile(STATE_FILE + ".corrupt", unreadable);
    if (!state_write(result))
        return { status: "failed", reason: "state_write_failed", rollback: result.rollback };
    return result;
}

// Explicit rollback of a recorded apply (after an interrupted verification,
// an unconfirmed LKG or on operator request): only while the configuration is
// still exactly the applied candidate and no transaction is active.
// observed: the started_at of the apply an observation found failing; its
// rollback only replaces that very apply, still applied and still the
// configuration (autotune/manager.uc observation_tick).
function rollback(observed) {
    let s = state_read();
    if (observed != null) {
        if (type(s) != "object" || s.unreadable || s.mutation == null || s.started_at !== observed)
            return { status: "failed", reason: "observed_apply_changed" };
        if (s.phase != "applied") return { status: "failed", reason: "nothing_to_roll_back", phase: s.phase };
    }
    if (type(s) == "object" && s.unreadable) return rollback_unreadable();
    if (type(s) != "object" || s.mutation == null) return { status: "failed", reason: "no_recorded_apply" };
    let d = diagnose(s);
    let unfinished = index(TERMINAL_PHASES, s.phase) < 0;
    if (!(s.phase == "applied" || s.phase == "needs_attention" || (s.phase == "failed" && s.reason == "interrupted_after_apply") || unfinished))
        return { status: "failed", reason: "nothing_to_roll_back", phase: s.phase };
    // The restore refuses before any change while a failed lifecycle
    // transition keeps its guard; the record stays as it is (UC-019).
    if (runtime_guard_kept()) return { status: "failed", reason: "runtime_guard_active", phase: s.phase };
    if (d.diagnosis != "candidate_active") return { status: "failed", reason: "rollback_needs_candidate_config", diagnosis: d.diagnosis };
    if (service_stopped()) return { status: "failed", reason: "service_stopped" };
    let action = service_action();
    if (action != null) return { status: "failed", reason: action };
    let pre = rollback_source(s, d.pre_snapshot);
    // Nothing is attempted without a source; the record stays as it is.
    if (pre == null) return { status: "failed", reason: "pre_apply_snapshot_missing", phase: s.phase };
    s.pre_snapshot = pre;
    let p = recorded_plan(s, parse_config(fs.readfile(CONFIG_FILE))).plan;
    delete s.last_attempt;
    return rollback_to(s, p, observed != null ? "observation_failed" : "operator_rollback");
}

function status() {
    let s = state_read();
    let text = fs.readfile(CONFIG_FILE);
    let hash = text != null ? sha_text(text) : "";
    let result = { state: s, config_hash: hash, guards: guards_present(), runtime_guard: runtime_guard_kept(),
        snapshot_operation: snapshot_operation_active(),
        service_action: service_action(), service_stopped: service_stopped(), autotune_lock_held: autotune_lock.held() };
    if (type(s) == "object") {
        let d = diagnose(s);
        result.config_is = d.config_is;
        result.pre_snapshot = d.pre_snapshot;
        result.pre_snapshot_present = d.pre_snapshot != null && fs.stat(SNAPSHOT_DIR + "/" + d.pre_snapshot + ".json") != null;
        // Whether a rollback would find a snapshot to return to.
        result.rollback_source_present = rollback_source(s, d.pre_snapshot) != null;
        // A record left unfinished by a process that died (SIGKILL, power
        // loss) is judged by what it left behind, as a finished one: while
        // its candidate is active or a transaction is open it blocks; once
        // the configuration is no longer the candidate it does not (UC-020).
        let finished = index(TERMINAL_PHASES, s.phase) >= 0 || !autotune_lock.held();
        result.resolved = finished && !unresolved(s, d);
        result.diagnosis = d.diagnosis;
        // Superseded, the record blocks nothing (UC-020). But while it is
        // undecided and its candidate never passed verification, a rule that
        // still runs the candidate's strategy keeps the configuration from
        // becoming last-known-working (config/snapshots.uc
        // autotune_objection), and every apply waits for that
        // (config_not_last_known_good) until the strategy is changed, the
        // rule disabled or a snapshot restored: the page says so.
        result.unverified_strategy = d.diagnosis == "superseded" && s.applied !== true && undecided(s) &&
            runs_candidate_strategy(s, text);
    }
    return result;
}

// ---- entry ----------------------------------------------------------------------

if (sourcepath(1) != null && sourcepath(1) != "")
    return { parse_config, route_owner, plan };

if (type(signal) == "function")
    for (let name in [ "SIGINT", "SIGTERM", "SIGHUP" ])
        if (signal(name) != "ignore")
            signal(name, function() { interrupted = true; });

let mode = ARGV[0] || "";
let output = null, code = 1;
if (mode == "plan") { output = plan(ARGV[1], ARGV[2]); code = index([ "ready", "no_change_required" ], output.status) >= 0 ? 0 : 1; }
else if (mode == "verify") {
    let p = read_json(ARGV[1]);
    if (type(p) != "object" || type(p.owner) != "object" || p.owner.section == null) output = { status: "failed", reason: "invalid_plan" };
    else {
        let expected = ARGV[2] == "current" ? p.current_strategy : (p.proposed_strategy || p.current_strategy);
        output = verify_production(p, expected, ARGV[3] == "traffic");
        output.status = output.ok ? "verified" : "failed";
        code = output.ok ? 0 : 1;
    }
}
else if (mode == "status") { output = status(); code = 0; }
else if (mode == "path") {
    if (!probe_module.valid_host(ARGV[1])) output = { status: "failed", reason: "invalid_host" };
    else {
        let sections = parse_config(fs.readfile(CONFIG_FILE));
        let dns = probe_module.production_dns(ARGV[1]);
        let seen = dns.fakeip ? path_probe(ARGV[1], singbox_config(sections)) : { ok: false, reason: "target_not_fakeip_routed", chains: null };
        output = { status: seen.ok ? "observed" : "failed", host: ARGV[1], production_dns: dns.fakeip ? "fakeip" : dns.answers > 0 ? "real_address" : "no_answer",
            chains: seen.chains, network: seen.network || null, reason: seen.reason };
        code = seen.ok ? 0 : 1;
    }
}
else if (mode == "apply" || mode == "rollback" || mode == "observe") {
    // The apply an observation names: its started_at, digits only.
    let observed = mode == "observe" ? ARGV[1] : mode == "rollback" && ARGV[1] == "observation" ? ARGV[2] : null;
    let started = observed != null && match(as_string(observed), /^[1-9][0-9]{0,11}$/) != null ? int(observed) : null;
    if (observed != null && started == null) output = { status: "failed", reason: "invalid_apply_id" };
    else if (mode == "rollback" && ARGV[1] != null && ARGV[1] != "observation") output = { status: "failed", reason: "invalid_arguments" };
    else if (!autotune_lock.acquire())
        output = autotune_lock.busy() ? { status: "busy", reason: "autotune_in_progress" } : { status: "failed", reason: "lock_unavailable" };
    else {
        output = mode == "apply" ? apply(ARGV[1], ARGV[2]) : mode == "observe" ? observe(started) : rollback(started);
        autotune_lock.release();
        // Exit 0 only when the requested outcome happened: apply applied (or
        // nothing to do), rollback rolled back, an observation check made.
        code = index(mode == "apply" ? [ "applied", "no_change_required" ] : mode == "observe" ? [ "ok", "failed", "inconclusive", "ended" ] :
            [ "rolled_back" ], output.status) >= 0 ? 0 : 1;
    }
}
else {
    warn("Usage: autotune/apply.uc <plan <selection.json> [resolver]|apply <plan.json> [resolver]|verify <plan.json> [proposed|current] [traffic]|rollback [observation <started_at>]|observe <started_at>|status|path <host>>\n");
    exit(1);
}
print(sprintf("%J\n", output));
exit(code);
