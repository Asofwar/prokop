#!/usr/bin/env ucode

// Autotune product layer: policy, targets, groups, cached results,
// hysteresis, scheduling and safe application on top of the Stage 3-5
// tools (autotune/isolation.uc tune, autotune/apply.uc plan/apply/rollback),
// which are called as they are and never bypassed.
//
// Modes:
//   status          policy, targets and cached results (read-only)
//   target <id>     the last full tune output of one target (read-only)
//   groups          targets classified into DPI groups now (read-only; DNS)
//   policy-set <option> <value>                     (write)
//   target-set <id> <host> [enabled] [resolver] [rule_set] [sample] [pins]
//                   a host target, or with an empty host a rule-list
//                   target (autotune/lists.uc); pins: comma-separated (write)
//   target-remove <id>                              (write)
//   list-domains <rule_set>  the domains of a list a DPI rule uses, for
//                   choosing pinned domains (read-only)
//   run <all|group>     tune the targets of the groups now (write)
//   if-due              the scheduled run, when enabled and due (cron); in
//                       mode "auto" it may apply one confirmed group
//                       recommendation through autotune/apply.uc, and it
//                       watches an automatic apply afterwards (observation)
//   run-async <all|group>  start a run as a background job; prints its id
//   run-status <job>    state and result of a job (read-only)
//   rollback            the operator's rollback of the recorded apply
//                       through autotune/apply.uc rollback (write)
//   cron-sync | cron-remove   the scheduling cron line
//
// A run is marked running in the persistent state; the next run finds a
// run that died (crash, kill, reboot), records it in the history and, when
// it died while applying, counts that apply and cools its candidate down.
// A run that a blocker postpones before it begins stays in RAM (UC-075), as
// does one whose running mark cannot be written (UC-074). A state write
// that fails after the work is never reported as success.
//
// Must be invoked as: ucode -L <lib> <lib>/autotune/manager.uc <mode> ...
let fs = require("fs");
let resolver = require("routing.resolve");
let policy_module = require("autotune.policy");
let state_module = require("autotune.state");
let groups_module = require("autotune.groups");
let probe_module = require("autotune.probe");
let hysteresis = require("autotune.hysteresis");
let autoapply = require("autotune.autoapply");
let identity = require("core.process_identity");
let catalog = require("autotune.catalog");
let lists_module = require("autotune.lists");
let dpi_strategy = require("core.dpi_strategy");

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const CONFIG_FILE = getenv("PROKOP_CONFIG_FILE") || "/etc/config/" + (getenv("PROKOP_CONFIG_NAME") || "prokop");
const CONFIG_PACKAGE = fs.basename(CONFIG_FILE);
const SINGBOX_CONFIG = getenv("PROKOP_AUTOTUNE_SINGBOX_CONFIG") || "";
const UCI = getenv("PROKOP_AUTOTUNE_UCI") || "uci";
const UCI_SAVEDIR = getenv("PROKOP_AUTOTUNE_UCI_SAVEDIR") || "/tmp/.uci";
const TMP_DIR = getenv("PROKOP_AUTOTUNE_TMPDIR") || "/tmp";
const STATE_DIR = getenv("PROKOP_AUTOTUNE_STATE_DIR") || "/var/run/prokop/autotune";
const WORKER_LOCK = STATE_DIR + "/worker.lock";
// The phase of the running tune (autotune/isolation.uc progress), tmpfs.
const TUNE_PROGRESS = STATE_DIR + "/tune-progress.json";
// The targets of the running run and their states, tmpfs (never the state
// file on flash: it changes with every target).
const RUN_PROGRESS = STATE_DIR + "/run-progress.json";
// A target never measured before is expected to take this long.
const DEFAULT_TUNE_SECONDS = 150;
// Samples of rule-list targets (autotune/lists.uc), tmpfs.
const LIST_CACHE_DIR = STATE_DIR + "/lists";
const STATE_LOCK = STATE_DIR + "/state.lock";
const JOBS_DIR = getenv("PROKOP_AUTOTUNE_JOBS_DIR") || STATE_DIR + "/jobs";
const BIN = getenv("PROKOP_BIN") || "/usr/bin/prokop";
const CRONTAB_FILE = getenv("PROKOP_CRONTAB_FILE") || "/etc/crontabs/root";
const RUNTIME_STATE_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const STOP_REQUESTED_FILE = getenv("PROKOP_STOP_REQUESTED_FILE") || RUNTIME_STATE_DIR + "/stop.requested";
const EXPLICIT_START_FILE = getenv("PROKOP_EXPLICIT_START_FILE") || RUNTIME_STATE_DIR + "/start.explicit";
const CRONTAB = getenv("PROKOP_AUTOTUNE_CRONTAB") || "crontab";
const CRON_MARKER = "# prokop-autotune";
// The cron line only asks "is a run due?"; the policy interval decides.
const CRON_SCHEDULE = "*/15 * * * *";
// A scheduled run that could not start is retried after this delay.
const RETRY_SECONDS = 900;
// The last run a blocker postponed and its retry time, tmpfs (UC-075): a
// blocker can last for days (an apply that waits for the operator, a kept
// guard), and the cron line asks every 15 minutes; such a run changes
// nothing worth a flash write. So is a run that failed because its running
// mark could not be written (UC-074). A run that measures replaces it.
const POSTPONED = STATE_DIR + "/postponed.json";
const JOB_KEEP = 10;
const JOB_STARTING_GRACE = 30;
const APPLY_STATE_FILE = getenv("PROKOP_AUTOTUNE_APPLY_STATE") || "/etc/prokop/autotune-apply.json";
// Stage 5 transaction phases a running manual apply reports.
const APPLY_PHASES = [ "checking", "applying", "verifying", "rolling_back" ];
// A recommendation measured longer ago than this many intervals is stale.
const MANUAL_MAX_AGE_INTERVALS = 2;
// The observation of an automatic apply: failed checks in a row that roll it
// back, the longest it may wait for its conclusive checks (a Prokop stopped
// or blocked meanwhile), how early a check may come before its tick (cron
// starts are not exact) and how many checks the state keeps.
const OBSERVATION_FAILURES = 2;
// The share of failed conclusive checks one in five (AT-12): an observation
// passes only at or below it, and two or more failed checks above it roll
// the apply back, in a row or not (a strategy failing every second check).
const OBSERVATION_FAILED_SHARE_NUM = 1, OBSERVATION_FAILED_SHARE_DEN = 5;
const OBSERVATION_MAX_SECONDS = 86400;
const OBSERVATION_SLACK = 60;
const OBSERVATION_CHECKS_KEPT = 12;

function as_string(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(as_string(v), /'/g, "'\\''") + "'"; }
function command(args) { return join(" ", map(args, quote)); }
function capture(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return { status: -1, output: "" };
    let data = pipe.read("all");
    return { status: int(pipe.close()), output: as_string(data) };
}
function success(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function now() { return time(); }

function config_sections() {
    let text = fs.readfile(CONFIG_FILE);
    return text == null ? null : resolver.parse_config(text);
}

// ---- read-only views -----------------------------------------------------

// A run marked running while nobody holds the worker lock ended without
// finishing: the worker crashed or the router rebooted during the run.
function worker_view(worker) {
    if (type(worker) != "object" || worker.state != "running") return worker;
    let run = null, tune = null;
    try { run = json(fs.readfile(RUN_PROGRESS)); } catch (e) { run = null; }
    try { tune = json(fs.readfile(TUNE_PROGRESS)); } catch (e) { tune = null; }
    // Only the progress of this very run.
    if (type(run) == "object" && run.started_at == worker.started_at)
        worker = { ...worker, progress: run, tune: type(tune) == "object" ? tune : null };
    let handle = fs.open(WORKER_LOCK, "re");
    if (!handle) return { ...worker, state: "crashed" };
    let free = handle.lock("xn");
    if (free) handle.lock("u");
    handle.close();
    return free ? { ...worker, state: "crashed" } : worker;
}

// A Stage 3-5 tool, invoked as its lock identity requires; its JSON output.
function run_tool(name, args, env) {
    let r = capture([ ...(env ? [ "env", ...env ] : []), "ucode", "-L", LIB_DIR, LIB_DIR + "/autotune/" + name + ".uc", ...args ]);
    let parsed = null;
    try { parsed = json(r.output); } catch (e) { parsed = null; }
    return type(parsed) == "object" ? parsed : null;
}

// The recorded Stage 5 apply as the page shows it: the group and candidate
// it changed, how it ended, whether it still waits for a decision
// (resolved: false; null when the apply tool gave no answer) and whether the
// operator can roll it back now: its candidate is still the configuration
// (an unreadable record is settled by a rollback), no apply runs and there
// is a snapshot to return to (a rollback without one can only fail), and
// whether the rule still runs a strategy that never passed its check.
// Nothing of the configuration itself (hashes, options, targets) is shown.
function apply_summary() {
    if (fs.stat(APPLY_STATE_FILE) == null) return null;
    let st = run_tool("apply", [ "status" ]);
    let s = st != null && type(st.state) == "object" ? st.state : null;
    if (s == null)
        return { phase: null, reason: "apply_status_unavailable", group: null, candidate: null, finished_at: null,
            resolved: null, diagnosis: null, in_progress: false, rollback: false, unverified_strategy: false };
    let open = index(APPLY_PHASES, s.phase) >= 0;
    let in_progress = open && st.autotune_lock_held === true;
    let candidate_active = (st.diagnosis == "candidate_active" &&
        (open || s.phase == "applied" || s.phase == "needs_attention" || (s.phase == "failed" && s.reason == "interrupted_after_apply"))) ||
        // An edit left the applied candidate in effect (AT-10).
        (st.diagnosis == "superseded" && st.candidate_in_effect === true && s.phase == "applied");
    return {
        phase: type(s.phase) == "string" ? s.phase : null,
        reason: type(s.reason) == "string" ? s.reason : null,
        group: type(s.mutation) == "object" && state_module.valid_id(s.mutation.section) ? s.mutation.section : null,
        candidate: match(as_string(s.selected), /^[a-z0-9_]{1,32}$/) != null ? s.selected : null,
        finished_at: type(s.finished_at) == "int" ? s.finished_at : null,
        resolved: st.resolved === true,
        diagnosis: type(st.diagnosis) == "string" ? st.diagnosis : null,
        in_progress,
        rollback: !in_progress && st.rollback_source_present === true && (s.unreadable === true || candidate_active),
        // The rule still runs a strategy that never passed its check, on a
        // configuration edited since: nothing confirms it as last known
        // working, so applies wait (autotune/apply.uc status).
        unverified_strategy: st.unverified_strategy === true
    };
}

// The tune resolves the target itself and needs the real addresses, never
// the FakeIP answers of production DNS: the resolver of the target, else the
// first plain IPv4 bootstrap or upstream DNS server of Prokop.
function resolver_for(t, sections) {
    if (t.resolver) return { ip: t.resolver, source: "target" };
    let settings = resolver.settings_of(sections);
    for (let key in [ "bootstrap_dns_server", "dns_server" ]) {
        let values = settings[key];
        for (let v in type(values) == "array" ? values : [ values ])
            if (probe_module.valid_ipv4(trim(as_string(v)))) return { ip: trim(as_string(v)), source: "settings" };
    }
    return null;
}

function singbox_config(sections) {
    return resolver.load_json(SINGBOX_CONFIG != "" ? SINGBOX_CONFIG : resolver.singbox_config_path(sections));
}

// The targets measured: host targets as they are, a rule-list target as its
// member targets "<id>__<n>" (autotune/lists.uc). A list that gives no
// member, or a disabled one, stays one entry { list_error } that the groups
// show as outside. { targets, lists: { id: list view } }.
function expand_targets(sections, configured) {
    let targets = [], lists = {}, local = null;
    for (let t in configured) {
        if (t.rule_set == null) { push(targets, t); continue; }
        if (!t.enabled) { push(targets, { ...t, host: t.rule_set, list_error: "target_disabled" }); continue; }
        if (local == null) local = lists_module.local_rule_sets(singbox_config(sections));
        let dns = resolver_for(t, sections);
        let view = lists_module.expand(t, local[t.rule_set], dns ? dns.ip : null, LIST_CACHE_DIR, TMP_DIR, now());
        lists[t.id] = view;
        if (length(view.members) == 0) { push(targets, { ...t, host: t.rule_set, list_error: view.error || "list_has_no_domains" }); continue; }
        for (let i = 0; i < length(view.members); i++)
            push(targets, { id: lists_module.member_id(t.id, i + 1), host: view.members[i], enabled: true,
                resolver: t.resolver, parent: t.id });
    }
    return { targets, lists };
}

// The cached summary of a target, when it was measured for its host now: a
// list member keeps its id when the sample changes.
function summary_of(state, t) {
    let s = state.targets[t.id];
    return type(s) == "object" && (t.parent == null || s.host == t.host) ? s : null;
}

// Local lists the routing sends to an enabled DPI rule, for the target
// editor: [{ tag, rule, label }].
function rule_lists(sections, config) {
    let local = lists_module.local_rule_sets(config), seen = {}, result = [];
    let rules = type(config) == "object" && type(config.route) == "object" && type(config.route.rules) == "array" ? config.route.rules : [];
    for (let r in rules) {
        if (type(r) != "object" || (r.action || "route") != "route" || r.rule_set == null) continue;
        let s = resolver.section_for_outbound(sections, r.outbound);
        if (s == null || !dpi_strategy.is_dpi_action(s.options.action)) continue;
        for (let tag in type(r.rule_set) == "array" ? r.rule_set : [ r.rule_set ]) {
            if (local[tag] == null || seen[tag]) continue;
            seen[tag] = true;
            push(result, { tag, rule: s.name, label: as_string(s.options.label) || s.name });
        }
    }
    return result;
}

// The domains a list target can measure, for choosing pinned domains: only
// lists the routing sends to a DPI rule. At most LIST_DOMAINS_MAX are sent.
const LIST_DOMAINS_MAX = 2000;
function list_domains(tag) {
    tag = as_string(tag);
    if (!lists_module.valid_tag(tag)) return { status: "failed", reason: "invalid_rule_set" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let config = singbox_config(sections);
    if (length(filter(rule_lists(sections, config), (l) => l.tag == tag)) == 0) return { status: "failed", reason: "invalid_rule_set" };
    let d = lists_module.domains(lists_module.local_rule_sets(config)[tag], TMP_DIR);
    if (d.error) return { status: "failed", reason: d.error, rule_set: tag };
    return { status: "ok", rule_set: tag, total: length(d.domains), skipped: d.skipped,
        truncated: length(d.domains) > LIST_DOMAINS_MAX, domains: slice(d.domains, 0, LIST_DOMAINS_MAX) };
}

// The state as the page and the schedule see it: a run postponed after the
// stored last run is the last run, its retry time the next one. A run
// marked running in the state (live or crashed) stays what it is.
function with_postponed(state) {
    let p = null;
    try { p = json(fs.readfile(POSTPONED)); } catch (e) { p = null; }
    let w = state.worker;
    if (type(p) != "object" || type(p.worker) != "object" ||
        (type(w) == "object" && (w.state == "running" || int(w.started_at) > int(p.worker.started_at))))
        return state;
    return { ...state, worker: p.worker, next_run_at: type(p.next_run_at) == "int" ? p.next_run_at : state.next_run_at };
}

function status() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections);
    let state = with_postponed(state_module.read());
    let expanded = expand_targets(sections, read.targets);
    return {
        status: "ok",
        policy: read.policy,
        errors: read.errors,
        // Configured targets, then the members of rule-list targets (parent).
        targets: [
            ...map(read.targets, (t) => ({ ...t, last: t.rule_set == null ? summary_of(state, t) : null,
                list: expanded.lists[t.id] || null })),
            ...map(filter(expanded.targets, (t) => t.parent != null), (t) => ({ ...t, last: summary_of(state, t) }))
        ],
        lists: rule_lists(sections, singbox_config(sections)),
        groups: state.groups,
        next_run_at: state.next_run_at,
        worker: worker_view(state.worker),
        recovered_at: state.recovered_at,
        state_recovered: state.recovered_from || null,
        observation: state.observation,
        apply: apply_summary()
    };
}

function target(id) {
    if (!state_module.valid_id(id)) return { status: "failed", reason: "invalid_target" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let known = filter(expand_targets(sections, policy_module.read(sections).targets).targets, (t) => t.id == id && t.list_error == null);
    if (length(known) == 0) return { status: "failed", reason: "unknown_target" };
    let state = state_module.read();
    let last = summary_of(state, known[0]);
    return { status: "ok", target: known[0], last, full: last != null ? state_module.load_full(id) : null };
}

// ---- groups ----------------------------------------------------------------

// Targets classified into groups and the group results from the cached
// target summaries. Strategy identities only, never raw strategies.
// A recommendation autotune could never apply is "not_applicable" before
// hysteresis, autonomous apply and the page see it (UC-032, D-7a): apply.uc
// replaces only the TCP/443 profile of the rule's strategy, so a strategy
// without exactly one such profile of its own cannot take the candidate.
// The reason is the one apply.uc plan would give. The raw strategy never
// leaves this function: group views reach the read-only role.
function applicable(aggregate, sections, name) {
    if (aggregate.status != "recommendation" || !aggregate.candidate || aggregate.candidate == "direct") return aggregate;
    let entry = catalog.find(aggregate.candidate);
    let section = resolver.find_section(sections, name);
    if (entry == null || section == null) return aggregate;
    let current = dpi_strategy.effective(section.options.nfqws_opt);
    let splice = dpi_strategy.tcp443_splice(current, entry.nfqws_opt);
    if (splice.error) return { ...aggregate, status: "not_applicable", reason: splice.error };
    // The rule already runs what the candidate would make of it (the
    // default strategy is such a case): nothing to recommend, the same
    // answer apply.uc plan gives (AT-5, UC-202).
    if (splice.opt == current) return { ...aggregate, status: "no_change", reason: "candidate_already_active" };
    return aggregate;
}

function compute_groups(sections, targets, state) {
    let config = singbox_config(sections);
    let groups = {}, outside = [];
    for (let t in targets) {
        if (t.list_error != null) { push(outside, { id: t.id, host: t.host, reason: t.list_error, detail: null }); continue; }
        if (!t.enabled) { push(outside, { id: t.id, host: t.host, reason: "target_disabled", detail: null }); continue; }
        let dns = probe_module.production_dns(t.host);
        // A target names no device: a rule limited to devices owns it for
        // those devices, and the group says so (source_scoped).
        let r = resolver.resolve(config, sections, resolver.target(t.host, dns.ip, { fakeip: dns.fakeip, assume_rule_source: true }));
        let c = groups_module.classify(dns, r);
        if (c.in_group == null) { push(outside, { id: t.id, host: t.host, reason: c.reason, detail: c.detail || null }); continue; }
        let g = groups[c.in_group];
        if (g == null) {
            let section = resolver.find_section(sections, c.in_group);
            g = groups[c.in_group] = { label: c.label, targets: [], current: r.dpi ? r.dpi.strategy : null,
                custom: r.dpi ? r.dpi.custom : null, fingerprint: groups_module.fingerprint(section), result: null,
                source_scoped: false };
        }
        if (c.source_scoped) g.source_scoped = true;
        push(g.targets, t.id);
    }
    for (let name, g in groups)
        g.result = applicable(groups_module.aggregate(map(g.targets, (id) => ({ id, summary: summary_of(state, filter(targets, (t) => t.id == id)[0]) })), g.current), sections, name);
    return { groups, outside };
}

// The page waits 45s for the groups (AUTOTUNE_GROUPS_RPC_TIMEOUT_MS): up to
// 16 targets with one DNS lookup of at most 2s each, then the list questions
// of the resolver, limited for the whole call. Past the limit a list is
// undecidable and its targets are outside (UC-220).
const GROUPS_LIST_SECONDS = int(getenv("PROKOP_AUTOTUNE_GROUPS_LIST_SECONDS")) > 0 ? int(getenv("PROKOP_AUTOTUNE_GROUPS_LIST_SECONDS")) : 8;
function groups() {
    resolver.limit_ruleset_time(GROUPS_LIST_SECONDS);
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections);
    return { status: "ok", ...compute_groups(sections, expand_targets(sections, read.targets).targets, state_module.read()) };
}

// ---- cron ----------------------------------------------------------------------

function cron_line() {
    return CRON_SCHEDULE + " " + BIN + " autotune_if_due >/dev/null 2>&1 " + CRON_MARKER;
}

// Only the autotune line is added or removed; every other line stays as is.
function cron_rewrite(enabled) {
    let existing = fs.readfile(CRONTAB_FILE);
    // A crontab that exists but cannot be read is never rewritten.
    if (existing == null && fs.stat(CRONTAB_FILE) != null) return { status: "failed", reason: "crontab_unreadable" };
    existing = as_string(existing);
    let lines = split(existing, "\n"), text = "";
    if (length(lines) > 0 && lines[length(lines) - 1] == "") pop(lines);
    for (let line in lines) if (index(line, CRON_MARKER) < 0) text += line + "\n";
    if (enabled) text += cron_line() + "\n";
    if (text == existing) return { status: "ok", enabled, changed: false };
    let tmp = trim(capture([ "mktemp", TMP_DIR + "/prokop-autotune-cron.XXXXXX" ]).output);
    if (tmp == "") return { status: "failed", reason: "tempfile_unavailable" };
    // Read back: a full /tmp can take the write and keep none of it, and that
    // empty file would become the crontab, without anyone's jobs.
    if (fs.writefile(tmp, text) == null || fs.readfile(tmp) !== text) {
        fs.unlink(tmp);
        return { status: "failed", reason: "tempfile_unavailable" };
    }
    let ok = success([ CRONTAB, tmp ]);
    // BusyBox crontab ignores a failed copy into the crontab directory,
    // renames what it got over the crontab and exits 0: a nearly full overlay
    // leaves the crontab cut short or empty. A crontab that still holds the
    // previous text was not written at all (on a full overlay crontab cannot
    // even create its copy): nothing to put back. One that holds the new text
    // cut short is this failed write: the previous one is put back (the space
    // of the replaced crontab is free again). Anything else is a change
    // someone else made since crontab ran: it stays.
    let written = ok ? fs.readfile(CRONTAB_FILE) : null;
    if (ok && written !== text) {
        if (as_string(written) === existing) {
            fs.unlink(tmp);
            return { status: "failed", reason: "crontab_not_written" };
        }
        if (written == null || length(written) >= length(text) || substr(text, 0, length(written)) !== written) {
            fs.unlink(tmp);
            return { status: "failed", reason: "crontab_changed" };
        }
        let restored = fs.writefile(tmp, existing) != null && fs.readfile(tmp) === existing &&
            success([ CRONTAB, tmp ]) && fs.readfile(CRONTAB_FILE) === existing;
        fs.unlink(tmp);
        return { status: "failed", reason: "crontab_incomplete", restored };
    }
    fs.unlink(tmp);
    return ok ? { status: "ok", enabled, changed: true } : { status: "failed", reason: "crontab_failed" };
}

const CRON_FAILURES = {
    crontab_unreadable: "the crontab cannot be read",
    tempfile_unavailable: "the new crontab could not be staged in " + TMP_DIR,
    crontab_failed: "crontab failed",
    crontab_not_written: "the crontab was not written (is the overlay full?); it was left unchanged",
    crontab_incomplete: "the crontab was cut short (is the overlay full?)",
    crontab_changed: "another writer changed the crontab meanwhile; it was left as that writer saved it"
};

// The lifecycle discards what the manager prints (service/lifecycle.uc
// sync_autotune_cron), so a failure is logged where it is seen.
function cron_write(enabled) {
    let result = cron_rewrite(enabled);
    if (result.status == "failed")
        success([ "logger", "-t", "prokop", "[error] Autotune: could not update its schedule line in " + CRONTAB_FILE + ": " +
            (CRON_FAILURES[result.reason] ?? result.reason) +
            (result.restored === true ? "; the previous crontab was put back" :
                result.restored === false ? "; the scheduled jobs may be incomplete" : "") ]);
    return result;
}

function cron_sync() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    return cron_write(policy_module.read(sections).policy.mode != "off");
}

function cron_remove() { return cron_write(false); }

// ---- policy and targets (write) -----------------------------------------------

function ensure_state_dir() {
    for (let dir in [ fs.dirname(STATE_DIR), STATE_DIR ])
        if (fs.stat(dir) == null && !fs.mkdir(dir, 0700) && fs.stat(dir) == null) return false;
    return true;
}

// An exclusive flock on a file in the runtime directory; released by the
// kernel when the holder exits, so a crashed worker never leaves it behind.
// Close-on-exec: the tools a run spawns, and the production daemons an
// apply's reload restarts from inside them, must not inherit the lock and
// keep it after the manager died (UC-055).
function flock(path, wait) {
    if (!ensure_state_dir()) return null;
    let handle = fs.open(path, "ae");
    if (!handle) return null;
    if (!handle.lock(wait ? "x" : "xn")) { handle.close(); return null; }
    return handle;
}
function unlock(handle) {
    if (handle) { handle.lock("u"); handle.close(); }
}

// Read-modify-write of the state file, serialized between the worker and the
// target commands.
function with_state(change) {
    let handle = flock(STATE_LOCK, true);
    let state = state_module.read();
    change(state);
    let ok = state_module.write(state);
    unlock(handle);
    return ok;
}

// The output of work done whose state write failed (UC-074): it keeps what
// was done, says that the state does not show it, and is never a success.
function unrecorded(output) {
    let ok = output.status == "ok";
    return { ...output, status: ok ? "failed" : output.status, reason: ok ? "state_write_failed" : output.reason,
        recorded: false };
}

function uncommitted_changes() {
    let st = fs.stat(UCI_SAVEDIR + "/" + CONFIG_PACKAGE);
    return st != null && st.size > 0;
}

// trigger and candidate (a catalog id) only for autotune applies.
function history(kind, status, trigger, candidate) {
    success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", kind, status,
        as_string(trigger), as_string(candidate) ]);
}

// Set/delete UCI values with a private save directory, so the commit carries
// exactly these changes and never anything staged by someone else.
//
// An apply that is changing or checking production (scheduled or manual)
// verifies that the configuration stays exactly the candidate: a policy or
// target commit meanwhile would end it as needs_attention, counted and
// cooled down (UC-113). The write waits for it to finish instead.
function uci_apply(ops) {
    if (uncommitted_changes()) return { status: "refused", reason: "uncommitted_uci_changes" };
    // A worker that crashed while applying holds no lock: it blocks nothing.
    let worker = worker_view(state_module.read().worker);
    let running = apply_summary();
    if ((running != null && running.in_progress) ||
        (type(worker) == "object" && worker.state == "running" && worker.phase == "applying"))
        return { status: "refused", reason: "apply_in_progress" };
    let dir = trim(capture([ "mktemp", "-d", TMP_DIR + "/prokop-autotune-policy.XXXXXX" ]).output);
    if (dir == "") return { status: "failed", reason: "tempdir_unavailable" };
    let base = [ UCI, "-c", fs.dirname(CONFIG_FILE), "-t", dir ];
    let ok = true;
    for (let op in ops) if (ok) ok = success([ ...base, ...op ]);
    if (ok) ok = success([ ...base, "commit", CONFIG_PACKAGE ]);
    system(command([ "rm", "-rf", dir ]));
    return ok ? { status: "ok" } : { status: "failed", reason: "uci_failed" };
}

// ---- observation of an automatic apply ---------------------------------------
//
// An automatic apply passed its verification right after the reload; the
// observation keeps checking it in production for policy.observation, once
// per scheduler tick (autotune/apply.uc observe: the same production
// verification, normal requests through the rule included). It ends:
//   passed        policy.observation_checks checks passed and at most one
//                 conclusive check in five failed
//   rolled_back   OBSERVATION_FAILURES failed checks in a row (inconclusive
//                 ones between them neither count nor break the row), or as
//                 many failed checks that are more than one conclusive check
//                 in five: the candidate fails in production, the apply is
//                 rolled back to the configuration before it
//                 (autotune/apply.uc rollback observation) and the candidate
//                 is paused like one that failed its verification
//   needs_attention  that rollback did not prove the old state back
//   ended         the candidate is no longer in effect (its rule edited
//                 since, rolled back by the operator), the mode is no longer auto,
//                 or OBSERVATION_MAX_SECONDS passed without enough checks:
//                 nothing is changed
// Inconclusive checks (WAN down, a service action, a runtime that is not
// coherent) change nothing. A check skipped by a blocker is not recorded and
// writes nothing to flash. While an observation runs no other automatic
// apply starts, so its rollback stays a plain return to the configuration
// before the apply. The apply itself already counted against the daily
// limit; its rollback does not count again.

function observing(state) {
    return type(state) == "object" && type(state.observation) == "object" && state.observation.status == "observing";
}

function observation_start(group, applied, policy, at) {
    if (type(applied.apply_started_at) != "int") return null;
    return { status: "observing", group, candidate: applied.candidate, apply_started_at: applied.apply_started_at,
        started_at: at, checks_required: policy.observation_checks, passed: 0, failures_in_row: 0, failed: 0, conclusive: 0, checks: [],
        next_check_at: at + policy_module.OBSERVATION_STEP - OBSERVATION_SLACK, deadline: at + OBSERVATION_MAX_SECONDS };
}

// The observation ends: the state forgets it, the group's apply record keeps
// how it ended. rolled_back and needs_attention pause the candidate.
function observation_finish(state, o, status, reason, policy) {
    state.observation = null;
    let g = type(state.groups[o.group]) == "object" ? state.groups[o.group] : null;
    let result = { status, reason: reason || null, passed: int(o.passed), checks_required: int(o.checks_required),
        failures_in_row: int(o.failures_in_row), failed: int(o.failed), conclusive: int(o.conclusive),
        started_at: o.started_at, finished_at: now() };
    if (g == null) return result;
    if (type(g.last_apply) == "object" && g.last_apply.apply_started_at === o.apply_started_at)
        g.last_apply = { ...g.last_apply, observation: result };
    if (status == "rolled_back" || status == "needs_attention") {
        g.last_apply = { ...(type(g.last_apply) == "object" ? g.last_apply : { group: o.group, candidate: o.candidate }),
            status, reason: "observation_failed", observation: result, rolled_back_at: now() };
        g = hysteresis.start_cooldown(g, o.candidate, policy.cooldown_seconds, now());
        g.pending = null;
        g.ready = false;
        g.ready_auto = false;
    }
    state.groups[o.group] = g;
    return result;
}

// Ends the observation outside a tick (the operator's rollback, the mode
// switched away from auto).
function observation_end(reason) {
    let stored = state_module.read();
    if (!observing(stored)) return true;
    let sections = config_sections();
    let policy = policy_module.read(sections || []).policy;
    return with_state((state) => {
        if (observing(state)) observation_finish(state, state.observation, "ended", reason, policy);
    });
}

function policy_set(key, value) {
    let checked = policy_module.check(key, value);
    if (checked.error) return { status: "failed", reason: checked.error, option: as_string(key) };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let previous = policy_module.read(sections).policy;
    let ops = [];
    if (filter(sections, (s) => s.type == "autotune" && s.name == "autotune")[0] == null)
        push(ops, [ "set", CONFIG_PACKAGE + ".autotune=autotune" ]);
    push(ops, [ "set", CONFIG_PACKAGE + ".autotune." + key + "=" + as_string(checked.value) ]);
    let result = uci_apply(ops);
    if (result.status != "ok") return result;
    let cron = null;
    if (key == "mode") {
        if (previous.mode != checked.value) history("autotune_mode", "success");
        // Only auto mode acts on its own: an observation ends with it.
        if (checked.value != "auto") observation_end("mode_changed");
        cron = cron_sync().status;
    }
    return { status: "ok", option: key, value: checked.value, previous: previous[key], cron };
}

// Every state entry of a target: its own and those of its list members.
function forget_target(state, id) {
    for (let key in keys(state.targets))
        if (key == id || substr(key, 0, length(id) + 2) == id + "__") delete state.targets[key];
}

function target_set(id, host, enabled, resolver_ip, rule_set, sample, pins) {
    if (!policy_module.valid_target_id(id)) return { status: "failed", reason: "invalid_target_id" };
    host = lc(as_string(host));
    rule_set = as_string(rule_set);
    sample = as_string(sample);
    pins = uniq(filter(map(split(as_string(pins), /[ ,]+/), (p) => lc(trim(p))), (p) => p != ""));
    let list = rule_set != "";
    if (list) {
        if (host != "") return { status: "failed", reason: "host_and_rule_set" };
        if (!lists_module.valid_tag(rule_set)) return { status: "failed", reason: "invalid_rule_set" };
        if (sample != "" && !lists_module.valid_sample(sample)) return { status: "failed", reason: "invalid_sample" };
        if (length(pins) > lists_module.MAX_SAMPLE || length(filter(pins, (p) => !probe_module.valid_host(p))) > 0)
            return { status: "failed", reason: "invalid_pin" };
    }
    else if (!probe_module.valid_host(host)) return { status: "failed", reason: "invalid_host" };
    enabled = enabled == null || as_string(enabled) == "" ? "1" : as_string(enabled);
    if (index([ "0", "1" ], enabled) < 0) return { status: "failed", reason: "invalid_enabled" };
    resolver_ip = as_string(resolver_ip);
    if (resolver_ip != "" && !probe_module.valid_ipv4(resolver_ip)) return { status: "failed", reason: "invalid_resolver" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let existing = filter(sections, (s) => s.name == id)[0];
    if (existing != null && existing.type != "autotune_target") return { status: "failed", reason: "id_in_use" };
    if (existing == null && length(filter(sections, (s) => s.type == "autotune_target")) >= policy_module.MAX_TARGETS)
        return { status: "refused", reason: "too_many_targets" };
    let path = CONFIG_PACKAGE + "." + id;
    // uci delete of a missing option fails: only delete what exists.
    let ops = [ [ "set", path + "=autotune_target" ], [ "set", path + ".enabled=" + enabled ] ];
    let drop = (option) => { if (existing != null && existing.options[option] != null) push(ops, [ "delete", path + "." + option ]); };
    if (resolver_ip != "") push(ops, [ "set", path + ".resolver=" + resolver_ip ]);
    else drop("resolver");
    drop("pin");
    if (list) {
        drop("host");
        push(ops, [ "set", path + ".rule_set=" + rule_set ]);
        if (sample != "") push(ops, [ "set", path + ".sample=" + sample ]); else drop("sample");
        for (let p in pins) push(ops, [ "add_list", path + ".pin=" + p ]);
    } else {
        drop("rule_set");
        drop("sample");
        push(ops, [ "set", path + ".host=" + host ]);
    }
    let result = uci_apply(ops);
    if (result.status != "ok") return result;
    // Results measured for another host or list say nothing about the new one.
    let forgotten = true;
    if (existing != null && (lc(as_string(existing.options.host)) != host || as_string(existing.options.rule_set) != rule_set))
        forgotten = with_state((state) => forget_target(state, id));
    let output = list ?
        { status: "ok", target: { id, host: null, rule_set, sample: sample != "" ? int(sample) : lists_module.DEFAULT_SAMPLE,
            pins, enabled: enabled == "1", resolver: resolver_ip || null } } :
        { status: "ok", target: { id, host, enabled: enabled == "1", resolver: resolver_ip || null } };
    return forgotten ? output : unrecorded(output);
}

function target_remove(id) {
    if (!policy_module.valid_target_id(id)) return { status: "failed", reason: "invalid_target_id" };
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let existing = filter(sections, (s) => s.name == id && s.type == "autotune_target")[0];
    if (existing == null) return { status: "failed", reason: "unknown_target" };
    let result = uci_apply([ [ "delete", CONFIG_PACKAGE + "." + id ] ]);
    if (result.status != "ok") return result;
    let output = { status: "ok", removed: id };
    return with_state((state) => forget_target(state, id)) ? output : unrecorded(output);
}

// ---- scheduled runs ----------------------------------------------------------

let interrupted = false;

function script(name) { return LIB_DIR + "/autotune/" + name + ".uc"; }
function self_pid() { return as_string(fs.readlink("/proc/self")); }

// Whatever makes a measurement now unsafe or meaningless, as the apply tool
// itself reports it (read-only). for_apply: an apply also waits for an
// explicit start after an explicit stop (D-15, UC-056); measuring does not.
function blocker(for_apply) {
    let s = run_tool("apply", [ "status" ]);
    if (s == null) return "apply_status_unavailable";
    if (for_apply && s.service_stopped === true) return "service_stopped";
    // A guard a failed lifecycle transition kept: only a restart removes it.
    if (s.runtime_guard === true) return "runtime_guard_active";
    if (length(s.guards || []) > 0) return "dpi_guard_present";
    if (s.snapshot_operation) return "snapshot_operation_active";
    if (s.service_action) return s.service_action;
    if (s.autotune_lock_held) return "autotune_in_progress";
    if (type(s.state) == "object" && s.resolved === false) return "apply_unresolved";
    return null;
}


// Changes the observation in the state only while it is still the same one.
function with_observation(o, change) {
    let result = null;
    let ok = with_state((state) => {
        if (!observing(state) || state.observation.apply_started_at !== o.apply_started_at) return;
        result = change(state, state.observation);
    });
    return { ok, result };
}

function observation_record(o, check) {
    let checks = [ ...(type(o.checks) == "array" ? o.checks : []), check ];
    return slice(checks, -OBSERVATION_CHECKS_KEPT);
}

function observation_tick_locked() {
    let state = state_module.read();
    if (!observing(state)) return null;
    let o = state.observation;
    let sections = config_sections();
    if (sections == null) return { result: "skipped", reason: "config_unavailable" };
    let policy = policy_module.read(sections).policy;
    let at = now();
    let finish = (status, reason) => {
        let r = with_observation(o, (st, cur) => observation_finish(st, cur, status, reason, policy));
        return { result: status, reason, recorded: r.ok, group: o.group, candidate: o.candidate };
    };
    // The operator switched autotune away from auto: it no longer acts.
    if (policy.mode != "auto") return finish("ended", "mode_changed");
    // A tick further away than one step was set before the clock jumped back.
    let step = policy_module.OBSERVATION_STEP;
    if (at < int(o.next_check_at) && int(o.next_check_at) <= at + step) return { result: "skipped", reason: "not_due" };
    if (at > int(o.deadline) || at < int(o.started_at) - step) {
        // The candidate stays without a verdict: the history and a
        // notification say so (AT-13).
        let ended = finish("ended", "observation_expired");
        if (ended.recorded) history("autotune_observation", "failure", "automatic", o.candidate);
        return ended;
    }
    let reason = blocker(true);
    if (reason != null) return { result: "skipped", reason };
    let check = run_tool("apply", [ "observe", "" + o.apply_started_at ]);
    if (check == null) return { result: "skipped", reason: "observe_output_invalid" };
    if (check.status == "busy" || check.status == "interrupted") return { result: "skipped", reason: check.reason || check.status };
    if (check.status == "ended") {
        // The apply was rolled back or left needing attention by a run that
        // died before it recorded so: the candidate is paused all the same.
        if (check.phase == "rolled_back" || check.phase == "needs_attention") return finish(check.phase, check.reason);
        return finish("ended", check.reason);
    }
    let verdict = index([ "ok", "failed" ], check.status) >= 0 ? check.status : "inconclusive";
    let entry = { at, result: verdict, reason: check.reason || null,
        successes: type(check.successes) == "int" ? check.successes : null,
        attempted: type(check.attempted) == "int" ? check.attempted : null };
    let next = null;
    let updated = with_observation(o, (st, cur) => {
        cur.checks = observation_record(cur, entry);
        cur.last_check_at = at;
        cur.next_check_at = at + step - OBSERVATION_SLACK;
        if (verdict == "ok") { cur.passed = int(cur.passed) + 1; cur.failures_in_row = 0; }
        else if (verdict == "failed") { cur.failures_in_row = int(cur.failures_in_row) + 1; cur.failed = int(cur.failed) + 1; }
        if (verdict != "inconclusive") cur.conclusive = int(cur.conclusive) + 1;
        // Passing needs the checks and a low share of failed ones; the
        // same share decides a rollback (AT-12).
        let failing = int(cur.failed) * OBSERVATION_FAILED_SHARE_DEN > int(cur.conclusive) * OBSERVATION_FAILED_SHARE_NUM;
        next = cur.failures_in_row >= OBSERVATION_FAILURES || (failing && int(cur.failed) >= OBSERVATION_FAILURES) ? "rollback" :
            cur.passed >= int(cur.checks_required) && !failing ? "passed" : null;
        if (next == "passed") observation_finish(st, cur, "passed", null, policy);
        else st.observation = cur;
        o = cur;
    });
    if (!updated.ok) return { result: "failed", reason: "state_write_failed", check: verdict };
    if (next == "passed") {
        history("autotune_observation", "success", "automatic", o.candidate);
        return { result: "passed", check: verdict, group: o.group, candidate: o.candidate };
    }
    if (next != "rollback") return { result: "observing", check: verdict, reason: entry.reason, group: o.group, candidate: o.candidate };

    // The candidate failed in production twice in a row: back to the
    // configuration before the apply, through the Stage 5 rollback.
    let r = run_tool("apply", [ "rollback", "observation", "" + o.apply_started_at ]) || { status: "failed", reason: "rollback_output_invalid" };
    if (r.status == "rolled_back" || r.status == "needs_attention") {
        // The rollback is in the history already (autotune_rollback).
        return { ...finish(r.status, "observation_failed"), check: verdict };
    }
    // Nothing was changed (busy, a service action outlasting the wait, the
    // configuration edited right before): the observation goes on, the next
    // tick checks and decides again.
    with_observation(o, (st, cur) => { cur.rollback_attempt = { at: now(), reason: as_string(r.reason || r.status) }; st.observation = cur; });
    return { result: "observing", check: verdict, reason: "rollback_not_done:" + as_string(r.reason || r.status), group: o.group,
        candidate: o.candidate };
}

// One scheduler tick of the observation; called by if-due before the
// scheduled run. null when there is nothing to observe.
function observation_tick() {
    let stored = state_module.read();
    if (!observing(stored)) return null;
    let lock = flock(WORKER_LOCK, false);
    if (lock == null) return { result: "skipped", reason: "autotune_worker_running" };
    let output = observation_tick_locked();
    unlock(lock);
    return output;
}

function tune_target(t, probes, dns_resolver) {
    // The policy value is an upper bound: a run has a fixed number of source
    // ports, shared by every supported candidate (isolation.uc tune).
    fs.unlink(TUNE_PROGRESS);
    return run_tool("isolation", [ "tune", t.host, "max:" + as_string(probes), dns_resolver ], [ "PROKOP_AUTOTUNE_PROGRESS=" + TUNE_PROGRESS ]) ||
        { status: "failed", reason: "tune_output_invalid" };
}

// Groups of this run: every group, one named group, or for a scheduled run
// one group in turn, so a run stays short and every group gets its turn.
function choose(names, scope, rotation) {
    names = sort(names);
    if (scope == "all") return names;
    if (scope == "auto") return length(names) > 0 ? [ names[rotation % length(names)] ] : [];
    return index(names, scope) >= 0 ? [ scope ] : null;
}

// The results go into the state as it is now: a target changed or removed
// during the run keeps what the target commands left.
function merge(updates) {
    return with_state((state) => {
        let sections = config_sections();
        // Without the configuration nothing can be checked: only the run
        // itself is recorded.
        if (sections != null) {
            let targets = expand_targets(sections, policy_module.read(sections).targets).targets;
            for (let id, summary in updates.targets) {
                let t = filter(targets, (x) => x.id == id)[0];
                if (t != null && t.host == summary.host) state.targets[id] = summary;
            }
            for (let name, group in updates.groups) state.groups[name] = group;
            // A disabled rule keeps its group (and its cooldowns); a deleted
            // one does not.
            state_module.prune(state, map(targets, (t) => t.id),
                map(filter(sections, (s) => s.type == "section"), (s) => s.name));
        }
        // Apply records are kept whatever else changed: they are the budget.
        for (let a in updates.applies) push(state.applies, a);
        state.worker = updates.worker;
        if (updates.rotation != null) state.rotation = updates.rotation;
        if (updates.next_run_at != null) state.next_run_at = updates.next_run_at;
        if (updates.observation != null) state.observation = updates.observation;
    });
}

// One confirmed recommendation through the Stage 5 transaction: plan from
// the representative's tune output of this run, then apply (snapshot,
// guarded reload, production verification, automatic rollback). Returns the
// apply record for the state.
// trigger: "schedule" (autonomous, mode auto) or "manual" (the operator's
// explicit apply, mode recommend). A manual apply never counts against the
// daily limit of autonomous applies; everything else is the same.
function apply_group(name, aggregate, full, dns_resolver, trigger) {
    let manual = trigger == "manual";
    let record = { at: now(), group: name, candidate: aggregate.candidate, representative: aggregate.representative,
        status: "not_applied", reason: null, counted: false, trigger: manual ? "manual" : "automatic" };
    let reason = blocker(true);
    if (reason != null) { record.reason = reason; return record; }
    // The policy is read again: the mode may have been switched off while
    // the targets were measured.
    let sections = config_sections();
    if (sections == null || policy_module.read(sections).policy.mode != (manual ? "recommend" : "auto")) { record.reason = "mode_changed"; return record; }
    let dir = trim(capture([ "mktemp", "-d", TMP_DIR + "/prokop-autotune-apply.XXXXXX" ]).output);
    if (dir == "") { record.reason = "tempdir_unavailable"; return record; }
    let selection = dir + "/selection.json", plan_file = dir + "/plan.json";
    let plan = fs.writefile(selection, sprintf("%J\n", full)) != null ? run_tool("apply", [ "plan", selection, dns_resolver ]) : null;
    if (plan == null) record.reason = "plan_unavailable";
    // The confirmations start over: the same no-op is not offered again
    // on every pass (AT-5).
    else if (plan.status == "no_change_required") { record.status = "no_change_required"; record.reason = plan.reason;
        record.outcome = autoapply.outcome({ status: "no_change_required" }); }
    else if (plan.status != "ready") record.reason = "plan_" + as_string(plan.status) + ":" + as_string(plan.reason);
    // The plan must change exactly the rule and candidate this group
    // confirmed; routing edits since the classification make it void.
    else if (type(plan.owner) != "object" || plan.owner.section != name) record.reason = "owner_changed";
    else if (plan.selected != aggregate.candidate) record.reason = "plan_candidate_differs";
    else if (fs.writefile(plan_file, sprintf("%J\n", plan)) == null) record.reason = "plan_write_failed";
    // A crash from here on leaves an apply of unknown outcome; the next run
    // counts it and cools the candidate down (recover_crashed_run). Without
    // that mark on flash no apply starts (UC-074).
    else if (!with_state((state) => {
            if (type(state.worker) == "object")
                state.worker = { ...state.worker, phase: "applying", group: name, candidate: aggregate.candidate, phase_at: now() };
        }))
        record.reason = "state_write_failed";
    else {
        let result = run_tool("apply", [ "apply", plan_file, dns_resolver ]);
        let o = autoapply.outcome(result);
        record.status = o.status;
        record.reason = type(result) == "object" ? result.reason || null : "apply_output_invalid";
        record.counted = manual ? false : o.counted;
        record.attempted = o.counted;
        // The apply's own id in the Stage 5 record: an observation acts on
        // that very apply only.
        if (type(result) == "object" && type(result.started_at) == "int") record.apply_started_at = result.started_at;
        record.outcome = o;
        if (o.history != null) history("autotune_apply", o.history, record.trigger, aggregate.candidate);
    }
    system(command([ "rm", "-rf", dir ]));
    return record;
}

// Temporary selection/plan directories of a run that died; only called
// with the worker lock held, so none of them belongs to a live run.
function remove_stale_apply_dirs() {
    for (let name in fs.lsdir(TMP_DIR) || [])
        if (match(name, /^prokop-autotune-apply\.[A-Za-z0-9]+$/) != null)
            system(command([ "rm", "-rf", TMP_DIR + "/" + name ]));
}

// Marks this run as running in the state (flash), so a crash or a reboot
// during the run is found by the next one. A previous run still marked
// running died: it is recorded, and an apply it was doing counts against
// the daily limit and cools its candidate down, since its outcome is not
// known (autotune/apply.uc itself keeps the transaction recoverable).
// A manual apply (kind "apply") is marked the same way; its crash cools the
// candidate down but is not counted against the autonomous daily limit.
// ok: the mark is on flash; without it the caller does nothing (UC-074).
function begin_run(trigger, scope, started, policy, extra) {
    let crashed = null, previous = null;
    let ok = with_state((state) => {
        previous = state.worker;
        if (type(state.worker) == "object" && state.worker.state == "running") {
            crashed = { ...state.worker, state: "crashed", detected_at: now() };
            if (crashed.phase == "applying" && state_module.valid_id(crashed.group)) {
                let manual = crashed.kind == "apply";
                push(state.applies, { at: int(crashed.phase_at) || now(), group: crashed.group, candidate: crashed.candidate,
                    representative: null, status: "unknown", reason: "worker_crashed_during_apply", counted: !manual,
                    attempted: true, trigger: manual ? "manual" : "automatic" });
                let g = type(state.groups[crashed.group]) == "object" ? state.groups[crashed.group] : hysteresis.empty_group();
                g = hysteresis.start_cooldown(g, crashed.candidate, policy.cooldown_seconds, now());
                g.pending = null;
                g.ready = false;
                g.ready_auto = false;
                state.groups[crashed.group] = g;
            }
        }
        let pid = self_pid();
        state.worker = { state: "running", pid, ticks: identity.start_ticks(pid), trigger, scope, started_at: started,
            phase: "measuring", ...(extra || {}) };
    });
    if (ok && crashed != null) history("autotune_run", "failure");
    return { ok, crashed, previous };
}

// A run that did not begin: a blocker postponed it (result skipped), or its
// running mark could not be written (result failed, UC-074). Recorded in
// RAM with its retry time, the state on flash is not touched (UC-075); the
// page shows it all the same. A manual run keeps the retry time of the
// schedule.
function not_begun(scope, trigger, started, result, reason, stored) {
    let worker = { state: "finished", trigger, scope, started_at: started, finished_at: now(), result, reason,
        groups: [], tuned: [], unmeasured: [], applied: null, recovered: null };
    let retry = trigger == "schedule" ? now() + RETRY_SECONDS : null;
    let tmp = POSTPONED + ".tmp";
    if (fs.writefile(tmp, sprintf("%J\n", { worker, next_run_at: retry ?? with_postponed(stored).next_run_at })) == null ||
        !fs.rename(tmp, POSTPONED))
        fs.unlink(tmp);
    return { status: result == "skipped" ? "ok" : "failed", result, reason, trigger, scope, groups: {}, tuned: [],
        unmeasured: [], outside: [], applied: null, recovered: null, next_run_at: retry };
}

function run_locked(scope, trigger) {
    let started = now();
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections), policy = read.policy;
    // Whatever makes measuring unsafe now is asked before the run is marked
    // running: a postponed run is kept in RAM only (UC-075). A run still
    // marked running died; it is recorded first, once.
    let reason = blocker();
    let stored = state_module.read();
    if (reason != null && !(type(stored.worker) == "object" && stored.worker.state == "running"))
        return not_begun(scope, trigger, started, "skipped", reason, stored);
    let begun = begin_run(trigger, scope, started, policy);
    if (!begun.ok) return not_begun(scope, trigger, started, "failed", "state_write_failed", stored);
    let crashed = begun.crashed;
    remove_stale_apply_dirs();
    let local = state_module.read();
    // A state recovered from a corrupt file in this very run.
    let recovered_at = local.recovered_at != null ? local.recovered_at : local.recovered_from != null ? started : null;
    let updates = { targets: {}, groups: {}, applies: [], worker: null, rotation: null, next_run_at: null, observation: null };
    let report = {}, tuned = [], unmeasured = [], outside = [], chosen = [], stop = null, results = {}, applied = null;
    let unknown_group = false;

    if (reason == null) {
        let measured = expand_targets(sections, read.targets).targets;
        let computed = compute_groups(sections, measured, local);
        outside = computed.outside;
        chosen = choose(keys(computed.groups), scope, local.rotation);
        if (chosen == null) { unknown_group = true; chosen = []; }
        // What the page shows while the run goes: every target of the run in
        // order, its state and result, and how long it is expected to take
        // (its last measurement, else a default).
        let items = [];
        for (let name in chosen)
            for (let id in computed.groups[name].targets) {
                let t = filter(measured, (x) => x.id == id)[0];
                let last = summary_of(local, t);
                push(items, { id, host: t.host, parent: t.parent || null, group: name, state: "pending",
                    expected_s: last != null && int(last.duration_s) > 0 ? int(last.duration_s) : DEFAULT_TUNE_SECONDS });
            }
        let set_item = (id, change) => {
            for (let item in items) if (item.id == id) for (let k, v in change) item[k] = v;
            let tmp = RUN_PROGRESS + ".tmp";
            if (fs.writefile(tmp, sprintf("%J
", { started_at: started, total: length(items),
                done: length(filter(items, (i) => i.state == "done" || i.state == "skipped")), items })) != null)
                fs.rename(tmp, RUN_PROGRESS);
        };
        if (length(items) > 0) set_item(null, {});
        for (let name in chosen) {
            let g = computed.groups[name];
            for (let id in g.targets) {
                if (interrupted) { stop = "interrupted"; break; }
                stop = blocker();
                if (stop != null) break;
                let t = filter(measured, (x) => x.id == id)[0];
                let dns_resolver = resolver_for(t, sections);
                if (dns_resolver == null) {
                    push(unmeasured, { id, reason: "resolver_missing" });
                    set_item(id, { state: "skipped", reason: "resolver_missing" });
                    continue;
                }
                let begun = now();
                set_item(id, { state: "running", started_at: begun });
                let result = tune_target(t, policy.probes, dns_resolver.ip);
                // Neither says anything about the target: nothing is recorded.
                if (result.status == "busy") { stop = "autotune_in_progress"; break; }
                if (result.status == "interrupted") { stop = "interrupted"; break; }
                updates.targets[id] = state_module.record_tune(local, id, result,
                    { host: t.host, group: name, fingerprint: g.fingerprint }, now());
                updates.targets[id].duration_s = now() - begun;
                set_item(id, { state: "done", finished_at: now(), status: result.status, selected: result.selected || null,
                    confidence: result.confidence || null, reason: result.reason || null });
                results[id] = { full: result, resolver: dns_resolver.ip };
                push(tuned, id);
            }
            if (stop != null) break;
            // Only what this run measured counts: a cached result never
            // confirms a recommendation a second time.
            let aggregate = applicable(groups_module.aggregate(map(g.targets, (id) => ({ id, summary: updates.targets[id] || null })), g.current), sections, name);
            let observed = hysteresis.observe(local.groups[name], { ...aggregate, fingerprint: g.fingerprint }, policy, now(), trigger);
            let was_ready = type(local.groups[name]) == "object" && local.groups[name].ready === true;
            if (observed.ready && !was_ready) history("autotune_recommendation", "success");
            let group = { ...observed.group, label: g.label, targets: g.targets, current: g.current, source_scoped: g.source_scoped,
                events: observed.events, ready: observed.ready, ready_auto: observed.ready_auto, required: observed.required,
                result: aggregate };
            // At most one production change per run.
            let decision = applied != null ? { apply: false, reason: "one_apply_per_run" } : autoapply.decide({
                policy, trigger, group, result: aggregate, custom: g.custom, applies: local.applies, now: now(),
                cooldown_until: hysteresis.cooldown_until(group, aggregate.candidate), recovered_at,
                observing: observing(local) });
            if (decision.apply && results[aggregate.representative] == null) decision = { apply: false, reason: "representative_not_measured" };
            group.decision = { reason: decision.reason, at: now() };
            if (decision.apply) {
                let rep = results[aggregate.representative];
                applied = apply_group(name, aggregate, rep.full, rep.resolver, trigger);
                group.last_apply = applied;
                if (applied.outcome != null && applied.outcome.cooldown)
                    group = hysteresis.start_cooldown(group, aggregate.candidate, policy.cooldown_seconds, now());
                if (applied.outcome != null && applied.outcome.reset) { group.pending = null; group.ready = false; group.ready_auto = false; }
                push(local.applies, applied);
                push(updates.applies, applied);
                // An automatic apply that passed its verification is watched
                // for policy.observation (observation_tick).
                if (applied.status == "applied" && trigger == "schedule") {
                    let o = observation_start(name, applied, policy, now());
                    if (o != null) local.observation = updates.observation = o;
                    else group.last_apply = applied = { ...applied, observation: { status: "unavailable", reason: "apply_id_missing" } };
                }
            }
            local.groups[name] = updates.groups[name] = group;
            report[name] = { result: aggregate, events: observed.events, ready: observed.ready, required: observed.required,
                decision: decision.reason, apply: decision.apply ? applied : null };
        }
        reason = stop;
    }

    let result = reason == null ? "completed" : reason == "interrupted" ? "interrupted" : "skipped";
    if (unknown_group) { result = "failed"; reason = "unknown_group"; }
    else if (result == "completed" && length(chosen) == 0) reason = "no_groups";
    // An unfinished group keeps its turn.
    if (scope == "auto" && result == "completed" && length(chosen) > 0) updates.rotation = local.rotation + 1;
    if (trigger == "schedule")
        updates.next_run_at = result == "completed" ? started + policy.interval_seconds : now() + RETRY_SECONDS;
    updates.worker = { state: "finished", trigger, scope, started_at: started, finished_at: now(), result, reason,
        groups: chosen, tuned, unmeasured, applied: applied != null ? applied.status : null,
        recovered: crashed != null ? { started_at: crashed.started_at, trigger: crashed.trigger, phase: crashed.phase,
            group: crashed.group || null } : null };
    // A run whose record is not written stays marked running in the state:
    // the next run records it as crashed, with an apply it did.
    let recorded = merge(updates);
    fs.unlink(POSTPONED);
    fs.unlink(RUN_PROGRESS);
    fs.unlink(TUNE_PROGRESS);
    if (unknown_group) return { status: "failed", reason: "unknown_group", group: scope };
    let output = { status: "ok", result, reason, trigger, scope, groups: report, tuned, unmeasured, outside,
        applied, recovered: updates.worker.recovered, next_run_at: updates.next_run_at };
    return recorded ? output : unrecorded(output);
}

function run(scope, trigger) {
    scope = as_string(scope);
    if (scope != "all" && scope != "auto" && !state_module.valid_id(scope)) return { status: "failed", reason: "invalid_scope" };
    if (!ensure_state_dir()) return { status: "failed", reason: "state_dir_unavailable" };
    let lock = flock(WORKER_LOCK, false);
    if (lock == null) return { status: "busy", reason: "autotune_worker_running" };
    let output = run_locked(scope, trigger || "manual");
    unlock(lock);
    return output;
}

// The cron entry: a run when autotune is enabled and the interval passed.
function if_due() {
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable" };
    let read = policy_module.read(sections);
    // Ends an observation the mode no longer allows.
    let observation = read.policy.mode != "auto" ? observation_tick() : null;
    if (read.policy.mode == "off") return { status: "ok", result: "skipped", reason: "mode_off", observation };
    // Only for a Prokop that was started and not stopped since (D-15): a
    // disabled autostart left the cron line in place (OBS-4).
    if (fs.stat(STOP_REQUESTED_FILE) != null || fs.stat(EXPLICIT_START_FILE) == null)
        return { status: "ok", result: "skipped", reason: "prokop_stopped", observation };
    if (read.policy.mode == "auto") observation = observation_tick();
    let with_observation_result = (output) => observation != null ? { ...output, observation } : output;
    let state = with_postponed(state_module.read());
    // A next run further away than one interval was set before the clock
    // jumped back: it is due now instead of waiting for that date (AT-4).
    if (state.next_run_at != null && now() < state.next_run_at &&
        state.next_run_at <= now() + read.policy.interval_seconds + RETRY_SECONDS)
        return with_observation_result({ status: "ok", result: "skipped", reason: "not_due", next_run_at: state.next_run_at });
    if (length(filter(read.targets, (t) => t.enabled)) == 0) return with_observation_result({ status: "ok", result: "skipped", reason: "no_targets" });
    return with_observation_result(run("auto", "schedule"));
}

// ---- manual apply ------------------------------------------------------------
//
// The operator's explicit apply of a confirmed recommendation (mode
// recommend). The caller names only the group: the candidate, the current
// strategy, the owner and the measurement all come from the state and are
// checked again against the configuration and the routing right now. The
// change itself is the Stage 5 plan + apply transaction (apply_group), never
// a lighter path. Every refusal happens before any production change.

// What the stored recommendation of a group says, or why it cannot be
// applied: { reason } or { group, result }.
function manual_recommendation(state, name, policy, at) {
    let g = state.groups[name];
    if (type(g) != "object" || type(g.result) != "object") return { reason: "no_recommendation" };
    let r = g.result;
    if (r.status == "conflict") return { reason: "conflict" };
    if (r.status == "direct_stable" || r.candidate == "direct") return { reason: "direct_not_applicable" };
    if (r.status == "not_applicable") return { reason: "plan_not_applicable:" + as_string(r.reason) };
    if (r.status != "recommendation" || !r.candidate) return { reason: "no_recommendation" };
    if (g.ready !== true || type(g.pending) != "object" || g.pending.candidate != r.candidate) return { reason: "not_confirmed" };
    if (!policy_module.confidence_at_least(r.confidence, policy.min_confidence)) return { reason: "confidence_too_low" };
    let measured = type(g.last) == "object" ? int(g.last.at) : 0;
    if (measured <= 0 || at - measured > MANUAL_MAX_AGE_INTERVALS * int(policy.interval_seconds))
        return { reason: "recommendation_stale" };
    if (hysteresis.in_cooldown(g, r.candidate, at)) return { reason: "candidate_in_cooldown" };
    return { group: g, result: r };
}

// The group as the configuration and the routing define it now must still
// be the one measured: same rule, same targets, same rule options, same
// strategy, and the stored measurements still recommend the same candidate.
function manual_fresh(sections, targets, state, name, stored) {
    let computed = compute_groups(sections, targets, state);
    let now_g = computed.groups[name];
    if (now_g == null) return { reason: "owner_changed" };
    // As for autonomous applies: a custom strategy of the user is kept.
    if (now_g.custom === true) return { reason: "custom_strategy_kept" };
    if (now_g.fingerprint != stored.group.fingerprint) return { reason: "rule_changed" };
    if (as_string(now_g.current) != as_string(stored.group.current)) return { reason: "strategy_changed" };
    if (join(",", sort([ ...now_g.targets ])) != join(",", sort([ ...(stored.group.targets || []) ]))) return { reason: "targets_changed" };
    let r = now_g.result;
    if (r.status != "recommendation" || r.candidate != stored.result.candidate || r.representative == null)
        return { reason: "recommendation_changed" };
    for (let id in now_g.targets) {
        let summary = state.targets[id];
        if (type(summary) == "object" && summary.fingerprint != null && summary.fingerprint != now_g.fingerprint)
            return { reason: "rule_changed" };
    }
    return { group: now_g, result: r };
}

function manual_apply_locked(name, job) {
    let started = now();
    let sections = config_sections();
    if (sections == null) return { status: "failed", reason: "config_unavailable", group: name };
    let read = policy_module.read(sections), policy = read.policy;
    let refuse = (reason) => ({ status: "refused", result: "refused", reason, group: name });
    if (policy.mode != "recommend") return refuse(policy.mode == "off" ? "mode_off" : "mode_not_recommend");
    let state = state_module.read();
    if (state.recovered_from != null) return refuse("state_recovered");
    if (observing(state)) return refuse("observation_in_progress");
    let stored = manual_recommendation(state, name, policy, started);
    if (stored.reason) return refuse(stored.reason);
    let candidate = stored.result.candidate;
    let entry = catalog.find(candidate);
    let checked = entry ? catalog.validate_entry(entry) : null;
    if (checked == null || checked.state != "supported" || checked.protocol != "tcp") return refuse("candidate_unsupported");
    let reason = blocker(true);
    if (reason != null) return refuse(reason);

    let begun = begin_run("manual", name, started, policy,
        { kind: "apply", job: job || null, phase: "checking", group: name, candidate, phase_at: started });
    if (!begun.ok) return refuse("state_write_failed");
    let finish = (output) => with_state((s) => {
            // The last run stays what the status shows; the apply is in the
            // group record and the apply list.
            let prev = begun.previous;
            s.worker = type(prev) == "object" && prev.state == "running" ? { ...prev, state: "crashed", detected_at: now() } : prev;
        }) ? output : unrecorded(output);

    let measured = expand_targets(sections, read.targets).targets;
    let fresh = manual_fresh(sections, measured, state, name, stored);
    if (fresh.reason) return finish(refuse(fresh.reason));
    let rep = fresh.result.representative;
    let t = filter(measured, (x) => x.id == rep)[0];
    let full = state_module.load_full(rep);
    if (t == null || type(full) != "object" || full.status != "selected" || full.selected != candidate ||
        type(full.target) != "object" || full.target.host != t.host)
        return finish(refuse("measurement_unavailable"));
    let dns_resolver = resolver_for(t, sections);
    if (dns_resolver == null) return finish(refuse("resolver_missing"));

    let record = apply_group(name, fresh.result, full, dns_resolver.ip, "manual");
    let recorded = with_state((s) => {
        let g = type(s.groups[name]) == "object" ? s.groups[name] : hysteresis.empty_group();
        g.last_apply = record;
        if (record.outcome != null && record.outcome.cooldown)
            g = hysteresis.start_cooldown(g, candidate, policy.cooldown_seconds, now());
        if (record.outcome != null && record.outcome.reset) { g.pending = null; g.ready = false; g.ready_auto = false; }
        s.groups[name] = g;
        push(s.applies, record);
    });
    let ran = record.outcome != null || record.status == "no_change_required";
    let output = { status: record.status == "applied" || record.status == "no_change_required" ? "ok" : ran ? "failed" : "refused",
        result: ran ? record.status : "refused", reason: record.reason, group: name, candidate,
        trigger: "manual", finished_at: now() };
    // Without its record the apply keeps its mark in the state: the next run
    // records it as one of unknown outcome and pauses its candidate.
    return recorded ? finish(output) : unrecorded(output);
}

function manual_apply(name, job) {
    name = as_string(name);
    if (!state_module.valid_id(name)) return { status: "failed", reason: "invalid_group" };
    if (!ensure_state_dir()) return { status: "failed", reason: "state_dir_unavailable" };
    let lock = flock(WORKER_LOCK, false);
    if (lock == null) return { status: "busy", result: "refused", reason: "autotune_worker_running", group: name };
    let output = manual_apply_locked(name, job);
    unlock(lock);
    return output;
}

// ---- operator rollback -------------------------------------------------------
//
// The operator's rollback of the recorded apply (design H.7), through the
// Stage 5 tool: it restores the before-autotune snapshot and proves that the
// previous strategy runs again; an unreadable record returns to
// last-known-working (autotune/apply.uc rollback). Never next to a run or an
// apply of the worker. A rolled back candidate pauses in its group like one
// that failed its verification, and the group shows the rollback as its last
// change, also one that did not finish (needs_attention): the card never
// keeps the outcome of the apply before it. It is no apply of the daily
// budget. restored: the configuration was replaced (an unreadable record
// whose configuration already was last-known-working is only set aside).
function operator_rollback() {
    if (!ensure_state_dir()) return { status: "failed", reason: "state_dir_unavailable" };
    let lock = flock(WORKER_LOCK, false);
    if (lock == null) return { status: "busy", result: "refused", reason: "autotune_worker_running" };
    let r = run_tool("apply", [ "rollback" ]) || { status: "failed", reason: "rollback_output_invalid" };
    let group = type(r.mutation) == "object" && state_module.valid_id(r.mutation.section) ? r.mutation.section : null;
    let candidate = match(as_string(r.selected), /^[a-z0-9_]{1,32}$/) != null ? r.selected : null;
    let recorded = true;
    if ((r.status == "rolled_back" || r.status == "needs_attention") && group != null && candidate != null) {
        let sections = config_sections();
        let policy = policy_module.read(sections || []).policy;
        recorded = with_state((state) => {
            let g = type(state.groups[group]) == "object" ? state.groups[group] : hysteresis.empty_group();
            g.last_apply = { at: now(), group, candidate, representative: null, status: r.status,
                reason: "operator_rollback", counted: false, attempted: true, trigger: "manual" };
            g = hysteresis.start_cooldown(g, candidate, policy.cooldown_seconds, now());
            g.pending = null;
            g.ready = false;
            g.ready_auto = false;
            state.groups[group] = g;
            // The operator decided about the apply under observation.
            if (observing(state)) {
                let o = state.observation;
                observation_finish(state, o, "ended", "operator_rollback", policy);
                // The group record is the rollback's, never the apply's.
                state.groups[group] = g;
            }
        });
    }
    unlock(lock);
    let output = { status: r.status == "rolled_back" ? "ok" : r.status == "busy" ? "busy" : "failed",
        result: as_string(r.status) || "failed", reason: r.reason || null, group, candidate,
        restored: r.status == "rolled_back" && type(r.rollback) == "object" && r.rollback.status == "success", finished_at: now() };
    // Without the pause the rolled back candidate could be applied again.
    return recorded ? output : unrecorded(output);
}

// ---- background jobs ---------------------------------------------------------

// Where a running manual apply is: the worker phase, and while the Stage 5
// transaction runs, its phase (only the phase name of the apply record).
function apply_progress(id) {
    let w = state_module.read().worker;
    if (type(w) != "object" || w.kind != "apply" || w.job != id || w.state != "running") return { phase: "starting", apply_phase: null };
    let apply_phase = null;
    if (w.phase == "applying") {
        let data = fs.readfile(APPLY_STATE_FILE), s = null;
        try { s = data == null ? null : json(data); } catch (e) { s = null; }
        if (type(s) == "object" && int(s.started_at) >= int(w.phase_at) - 1 && index(APPLY_PHASES, s.phase) >= 0)
            apply_phase = s.phase;
    }
    return { phase: index([ "checking", "applying" ], w.phase) >= 0 ? w.phase : "checking", apply_phase };
}

function valid_job_id(id) { return match(as_string(id), /^[0-9]{1,12}_[0-9]{1,10}$/) != null; }
function job_path(id) { return JOBS_DIR + "/" + id + ".json"; }
function job_read(id) {
    let data = fs.readfile(job_path(id)), parsed = null;
    try { parsed = data == null ? null : json(data); } catch (e) { parsed = null; }
    return type(parsed) == "object" ? parsed : null;
}
function job_write(job) {
    if (!ensure_state_dir() || (fs.stat(JOBS_DIR) == null && !fs.mkdir(JOBS_DIR, 0700) && fs.stat(JOBS_DIR) == null)) return false;
    let path = job_path(job.id), tmp = path + ".tmp." + self_pid();
    if (fs.writefile(tmp, sprintf("%J\n", job)) == null) { fs.unlink(tmp); return false; }
    if (!fs.rename(tmp, path)) { fs.unlink(tmp); return false; }
    return true;
}
// The newest jobs are kept; ids start with the creation time.
function job_prune() {
    let ids = sort(map(filter(fs.lsdir(JOBS_DIR) || [], (n) => match(n, /^[0-9]+_[0-9]+\.json$/) != null),
        (n) => substr(n, 0, length(n) - 5)), (a, b) => {
        let d = int(split(a, "_")[0]) - int(split(b, "_")[0]);
        return d != 0 ? d : (a < b ? -1 : a > b ? 1 : 0);
    });
    for (let i = 0; i < length(ids) - JOB_KEEP; i++) fs.unlink(job_path(ids[i]));
}

// A job is a run (kind "run", the default of older job files) or a manual
// apply (kind "apply"); both go through the same files and status command.
function job_mode(job) { return job.kind == "apply" ? "apply-job" : "run-job"; }

function job_alive(job) {
    return type(job.pid) == "string" && type(job.ticks) == "string" &&
        identity.matches_record({ pid: job.pid, ticks: job.ticks }, "ucode",
            [ "ucode", "-L", LIB_DIR, script("manager"), job_mode(job), job.id ], false, true) != "";
}

function job_start(kind, scope) {
    if (!ensure_state_dir()) return { status: "failed", reason: "state_dir_unavailable" };
    let probe = flock(WORKER_LOCK, false);
    if (probe == null) return { status: "busy", reason: "autotune_worker_running" };
    unlock(probe);
    let job = { id: now() + "_" + self_pid(), kind, scope, state: "starting", created_at: now(),
        started_at: null, finished_at: null, pid: null, ticks: null, result: null };
    if (!job_write(job)) return { status: "failed", reason: "job_write_failed" };
    let worker = command([ "ucode", "-L", LIB_DIR, script("manager"), job_mode(job), job.id, scope ]);
    if (system(command([ "sh", "-c", worker + " >/dev/null 2>&1 </dev/null &" ])) != 0) {
        fs.unlink(job_path(job.id));
        return { status: "failed", reason: "job_start_failed" };
    }
    job_prune();
    return { status: "ok", job: job.id };
}

function run_async(scope) {
    scope = as_string(scope);
    if (scope != "all" && !state_module.valid_id(scope)) return { status: "failed", reason: "invalid_scope" };
    return job_start("run", scope);
}

function apply_async(name) {
    name = as_string(name);
    if (!state_module.valid_id(name)) return { status: "failed", reason: "invalid_group" };
    return job_start("apply", name);
}

function run_job(id, scope, kind) {
    let job = valid_job_id(id) ? job_read(id) : null;
    if (job == null || job.state != "starting" || job.scope != scope || (job.kind || "run") != kind)
        return { status: "failed", reason: "unknown_job" };
    job.pid = self_pid();
    job.ticks = identity.start_ticks(job.pid);
    job.state = "running";
    job.started_at = now();
    job_write(job);
    let output = kind == "apply" ? manual_apply(scope, id) : run(scope, "manual");
    job.state = "finished";
    job.finished_at = now();
    job.result = output;
    job_write(job);
    return output;
}

function run_status(id) {
    if (!valid_job_id(id)) return { status: "failed", reason: "invalid_job" };
    let job = job_read(id);
    if (job == null) return { status: "failed", reason: "unknown_job" };
    // A job whose worker is gone without finishing is reported, not rewritten.
    if ((job.state == "running" && !job_alive(job)) ||
        (job.state == "starting" && now() - int(job.created_at) > JOB_STARTING_GRACE))
        job.state = "lost";
    if (job.kind == "apply" && job.state == "running") job.progress = apply_progress(id);
    return { status: "ok", job };
}

// ---- entry ---------------------------------------------------------------

if (sourcepath(1) != null && sourcepath(1) != "")
    return { status, target, groups, list_domains, policy_set, target_set, target_remove, run, if_due, run_async, run_status,
        manual_apply, apply_async, operator_rollback, cron_sync, cron_remove };

let mode = ARGV[0] || "";
let output = null;
if (mode == "status") output = status();
else if (mode == "target") output = target(ARGV[1]);
else if (mode == "groups") output = groups();
else if (mode == "policy-set") output = policy_set(ARGV[1], ARGV[2]);
else if (mode == "target-set") output = target_set(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "target-remove") output = target_remove(ARGV[1]);
else if (mode == "list-domains") output = list_domains(ARGV[1]);
else if (index([ "run", "if-due", "run-job", "apply", "apply-job" ], mode) >= 0) {
    // A stop request ends the run after the current target.
    if (type(signal) == "function")
        for (let name in [ "SIGINT", "SIGTERM", "SIGHUP" ])
            signal(name, function() { interrupted = true; });
    output = mode == "run" ? run(ARGV[1], "manual") : mode == "if-due" ? if_due() : mode == "apply" ? manual_apply(ARGV[1]) :
        run_job(ARGV[1], ARGV[2], mode == "apply-job" ? "apply" : "run");
}
else if (mode == "run-async") output = run_async(ARGV[1]);
else if (mode == "apply-async") output = apply_async(ARGV[1]);
else if (mode == "run-status") output = run_status(ARGV[1]);
else if (mode == "rollback") output = operator_rollback();
else if (mode == "cron-sync") output = cron_sync();
else if (mode == "cron-remove") output = cron_remove();
else {
    warn("Usage: autotune/manager.uc <status|target <id>|groups|policy-set <option> <value>|" +
        "target-set <id> <host> [enabled] [resolver] [rule_set] [sample] [pins]|target-remove <id>|list-domains <rule_set>|run <all|group>|if-due|" +
        "run-async <all|group>|run-status <job>|apply <group>|apply-async <group>|rollback|cron-sync|cron-remove>\n");
    exit(1);
}
print(sprintf("%J\n", output));
exit(output.status == "ok" ? 0 : 1);
