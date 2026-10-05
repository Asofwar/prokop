#!/usr/bin/env ucode

let fs = require("fs");
let durable = require("core.durable");

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const RUNTIME_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const EVENT_FILE = RUNTIME_DIR + "/health-events.json";
const PACKAGE_PENDING = getenv("PROKOP_OPKG_RECOVERY_DIR") || "/etc/prokop/opkg-package-set-recovery";
const SNAPSHOT_LOCK = getenv("PROKOP_SNAPSHOT_LOCK_DIR") || "/var/run/prokop/config-snapshot.lock";
const RELOAD_LOCK = getenv("PROKOP_RELOAD_LOCK_DIR") || "/var/run/prokop.reload.lock";
// The last answer of service/ui.uc get-ui-state.
const UI_STATE_FILE = (getenv("PROKOP_UI_STATE_DIR") || "/var/run/prokop/ui-state") + "/current.json";
const UI_STATE_MAX_AGE = 3;
// Significant events survive reboots in a small journal on flash. Only
// recorded events land there (starts, reloads, restores, autotune applies,
// manual snapshot changes), never probes or measurements. When the journal
// outgrows its cap it is rewritten once to the newest HISTORY_KEEP records,
// flushed to flash before and after the rename (UC-025).
const HISTORY_FILE = getenv("PROKOP_HISTORY_FILE") || "/etc/prokop/history.jsonl";
// Serializes the records of concurrent writers (UC-073): a rotation reads the
// journal and replaces it, an append between the two would be lost. An
// flock, released by the kernel when its holder dies.
const HISTORY_LOCK = RUNTIME_DIR + "/history.lock";
// Its holder may sit in the rotation's sync(1), slow with much dirty data,
// and start, reload and autotune record their events synchronously: a
// record waits this long, then goes without the lock.
const HISTORY_LOCK_WAIT_MS = int(getenv("PROKOP_HISTORY_LOCK_WAIT_MS") || "5000");
const HISTORY_MAX = 200;
const HISTORY_MAX_BYTES = 65536;
const HISTORY_KEEP = 150;
// An autotune apply and its rollback have kinds of their own, never restore
// (UC-060, design H.6); autotune_observation: an automatic apply passed the
// observation after it (autotune/manager.uc). cron_refresh: a start or reload that could not
// update the scheduled jobs and went on without them. config_migration: a
// package upgrade migrated the configuration and changed what it does in a
// way the user should know about; its notices say how
// (config/migration.uc).
const EVENT_KINDS = [ "start", "reload", "restore", "autotune_apply", "autotune_rollback", "snapshot_create",
    "snapshot_delete", "autotune_mode", "autotune_recommendation", "autotune_run", "cron_refresh",
    "config_migration", "autotune_observation" ];
// The notices of a config_migration event, in the shape the History page
// reads: a known code, a UCI section name, ids of rule sets or options.
// Anything else is dropped; an event keeps at most MIGRATION_NOTICES_MAX of
// them (the journal and the runtime file stay small).
// update_interval_raised also keeps the interval it replaced and the new
// one (`from`, `to`).
// client_dns_intercept_off keeps the value of intercept_client_dns it
// replaced (`from`: 1, true, yes, on or auto) and `to` (0).
const MIGRATION_NOTICE_CODES = [ "retired_rule_sets", "update_interval_raised", "subscription_options_removed",
    "subscription_user_agent_in_effect", "client_dns_intercept_off" ];
const MIGRATION_NOTICES_MAX = 16;
const MIGRATION_NOTICE_IDS_MAX = 32;
// "not_started": a snapshot restore replaced the configuration while an
// explicit stop held the runtime down; nothing verified it (D-15, UC-056).
const EVENT_STATUSES = [ "success", "failure", "recovered", "not_started" ];
// Autotune applies and rollbacks also carry who started them and the
// catalog candidate id.
const EVENT_TRIGGERS = [ "manual", "automatic" ];

function read_object(path) {
    let raw = fs.readfile(path);
    if (raw == null || length(raw) > 32768)
        return {};
    try {
        let value = json(raw);
        return type(value) == "object" && type(value) != "array" ? value : {};
    }
    catch (e) {
        return {};
    }
}

function quote(value) {
    return "'" + replace("" + value, /'/g, "'\\''") + "'";
}

function command(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}

function capture(args) {
    let pipe = fs.popen(command(args), "r");
    if (!pipe)
        return "";
    let output = pipe.read("all");
    return pipe.close() == 0 && output != null ? output : "";
}

function command_ok(args) {
    return system(command(args) + " >/dev/null 2>&1") == 0;
}

function valid_event(event) {
    return type(event) == "object" && index(EVENT_KINDS, event.kind) >= 0 &&
        index(EVENT_STATUSES, event.status) >= 0 && type(event.timestamp) == "int";
}

function notice_ids(values) {
    let result = [];
    for (let value in type(values) == "array" ? values : [])
        if (type(value) == "string" && match(value, /^[a-z0-9_]{1,32}$/) != null &&
            length(result) < MIGRATION_NOTICE_IDS_MAX)
            push(result, value);
    return result;
}

function notice_view(notice) {
    if (type(notice) != "object" || index(MIGRATION_NOTICE_CODES, notice.code) < 0 ||
        type(notice.section) != "string" || match(notice.section, /^[A-Za-z0-9_]{1,64}$/) == null)
        return null;
    let values = notice_ids(notice.values);
    if (length(values) == 0)
        return null;
    let view = { code: notice.code, section: notice.section, values, replacements: notice_ids(notice.replacements) };
    if (notice.code == "update_interval_raised") {
        for (let key in [ "from", "to" ]) {
            if (type(notice[key]) != "string" || match(notice[key], /^[0-9][0-9.a-z]{0,15}$/) == null)
                return null;
            view[key] = notice[key];
        }
    }
    if (notice.code == "client_dns_intercept_off") {
        if (index([ "1", "true", "yes", "on", "auto" ], notice.from) < 0 || notice.to !== "0")
            return null;
        view.from = notice.from;
        view.to = notice.to;
    }
    return view;
}

// The event as stored and shown: only known fields, extras only when valid.
function event_view(event) {
    let view = { kind: event.kind, status: event.status, timestamp: event.timestamp };
    if (event.kind == "autotune_apply" || event.kind == "autotune_rollback" || event.kind == "autotune_observation") {
        if (index(EVENT_TRIGGERS, event.trigger) >= 0) view.trigger = event.trigger;
        if (type(event.candidate) == "string" && match(event.candidate, /^[a-z0-9_]{1,32}$/) != null)
            view.candidate = event.candidate;
    }
    if (event.kind == "config_migration" && type(event.notices) == "array") {
        let notices = [];
        for (let notice in event.notices) {
            let item = notice_view(notice);
            if (item != null && length(notices) < MIGRATION_NOTICES_MAX)
                push(notices, item);
        }
        if (length(notices) > 0)
            view.notices = notices;
    }
    return view;
}

function history_events(all) {
    let raw = fs.readfile(HISTORY_FILE);
    if (raw == null)
        return null;
    let result = [];
    for (let line in split(raw, "\n")) {
        if (line == "") continue;
        let event;
        try { event = json(line); } catch (e) { continue; }
        if (valid_event(event))
            push(result, event_view(event));
    }
    return !all && length(result) > HISTORY_MAX ? slice(result, length(result) - HISTORY_MAX) : result;
}

// The journal ends in the middle of a line: an append that a power cut or a
// full flash cut short.
function history_torn() {
    let file = fs.open(HISTORY_FILE, "r");
    if (!file)
        return false;
    let torn = file.seek(-1, 2) && file.read(1) != "\n";
    file.close();
    return torn;
}

// Called under HISTORY_LOCK; without it rotate is false. A torn last line
// is ended first, so that it costs only its own record, never the next one
// (UC-073).
function append_history(event, rotate) {
    let dir = replace(HISTORY_FILE, /\/[^\/]*$/, "");
    if (dir != "" && fs.stat(dir) == null)
        fs.mkdir(dir, 0755);
    let torn = history_torn();
    let file = fs.open(HISTORY_FILE, "a");
    if (!file)
        return false;
    file.write((torn ? "\n" : "") + sprintf("%J\n", event));
    file.close();

    if (!rotate)
        return true;
    let stat = fs.stat(HISTORY_FILE);
    let events = history_events(true) || [];
    if ((stat != null && stat.size <= HISTORY_MAX_BYTES) && length(events) <= HISTORY_MAX)
        return true;
    let lines = "";
    for (let item in slice(events, max(0, length(events) - HISTORY_KEEP)))
        lines += sprintf("%J\n", item);
    return durable.durable_replace(sprintf("%s.%d.tmp", HISTORY_FILE, clock()[1]), HISTORY_FILE, lines);
}

function event_state() {
    let value = read_object(EVENT_FILE);
    let result = [];
    if (type(value.events) != "array") return result;
    for (let event in value.events) {
        if (!valid_event(event)) continue;
        push(result, event_view(event));
    }
    return length(result) > 10 ? slice(result, length(result) - 10) : result;
}

// A failed change or a rollback the user should hear of when away from the
// page: handed to the notification sender, which never holds up this record
// (notify/queue.uc). What the user did and saw succeed is not sent.
function notify_event(event) {
    let wanted = (event.kind == "reload" || event.kind == "start") ? event.status == "failure" :
        event.kind == "restore" ? (event.status == "recovered" || event.status == "failure") :
        event.kind == "autotune_rollback" ? (event.status == "failure" ||
            (event.status == "success" && event.trigger == "automatic")) : false;
    if (!wanted)
        return;
    try {
        require("notify.queue").enqueue("rollback", { kind: event.kind, status: event.status,
            trigger: event.trigger, candidate: event.candidate });
    }
    catch (e) {}
}

// details: the extra fields of the kind, as JSON text (config_migration:
// { "notices": [ ... ] }).
function record_event(kind, status, trigger, candidate, details) {
    if (index(EVENT_KINDS, kind) < 0 || index(EVENT_STATUSES, status) < 0)
        return 1;
    fs.mkdir(RUNTIME_DIR, 0700);
    let extra = {};
    try {
        extra = details != null && details != "" ? json(details) : {};
    }
    catch (e) {}
    let event = event_view({ kind, status, timestamp: int(clock()[0]), trigger, candidate,
        notices: type(extra) == "object" ? extra.notices : null });
    // Both journals are read, changed and replaced: one writer at a time.
    // Without the lock (an unwritable runtime directory) as before. A lock
    // held longer than HISTORY_LOCK_WAIT_MS: the event is recorded without
    // it, but the journal is not rotated under its holder.
    let lock = fs.open(HISTORY_LOCK, "ae");
    let rotate = lock == null;
    for (let waited = 0; lock != null && !rotate; waited += 50) {
        if (lock.lock("xn"))
            rotate = true;
        else if (waited >= HISTORY_LOCK_WAIT_MS) {
            lock.close();
            lock = null;
        }
        else
            sleep(50);
    }
    // The journal is best effort: a full or read-only flash must not stop
    // health from recording the event.
    append_history(event, rotate);
    let events = event_state();
    push(events, event);
    while (length(events) > 10)
        shift(events);
    let path = sprintf("%s.%d.tmp", EVENT_FILE, clock()[1]);
    let result = 0;
    if (fs.writefile(path, sprintf("%J\n", { events })) == null ||
        !fs.chmod(path, 0600) || !fs.rename(path, EVENT_FILE)) {
        fs.unlink(path);
        result = 1;
    }
    if (lock) {
        lock.lock("u");
        lock.close();
    }
    notify_event(event);
    return result;
}


function as_string(value) {
    return value == null ? "" : "" + value;
}

// A snapshot restore or autotune apply is running: its lock holds the owner
// record of a live config/snapshots.uc process (as autotune/apply.uc reads
// it; a crashed operation leaves a stale one).
function snapshot_operation_active() {
    let identity = require("core.process_identity");
    for (let name in fs.lsdir(SNAPSHOT_LOCK) || []) {
        let m = match(name, /^owner\.([1-9][0-9]*)\.([0-9]+)$/);
        if (m != null && identity.matches_record({ pid: m[1], ticks: m[2] }, "ucode",
            [ "ucode", "-L", LIB_DIR, LIB_DIR + "/config/snapshots.uc" ], false, true) != "")
            return true;
    }
    return false;
}

// guards: the fail-closed DPI guards that are installed. runtime: one that a
// failed lifecycle transition kept (ProkopTableDpiGuard, the
// prokop_transition_guard chain); the lifecycle refuses start and reload
// over it and only a restart removes it. restore: the guard of a snapshot
// restore or an autotune apply (ProkopConfigRestoreDpiGuard); only a restore
// of a snapshot releases one that such a transaction left. transaction: a
// snapshot operation is running, whose own guard that may be (UC-019,
// UC-066). reload_busy: a reload runs, or the list worker that ends in one
// (reload_running); until it ends, the newest reload event may belong to an
// earlier change than the one just applied (configform.js). bridge: the
// state of br_netfilter (nft/bridge_netfilter.uc status()); while it is
// loaded Prokop turns its iptables hooks off for the whole system, which
// health shows as a warning (D-19, UC-109).
function health(ui, guards, package_pending, events, reload_busy, bridge) {
    let guard = guards.active === true || guards.runtime === true || guards.restore === true;
    let service = type(ui.service) == "object" ? ui.service : {};
    let prokop = type(service.prokop) == "object" ? service.prokop : {};
    let sing_box = type(service.sing_box) == "object" ? service.sing_box : {};
    let transition = match(as_string(prokop.status), /^(starting|stopping|restarting|reloading)$/) != null;
    // Down because the user stopped it (an explicit stop holds it down until
    // an explicit start; D-15, UC-056), or because nobody started it since
    // boot (D-15(a)), is no failure, unlike a runtime that is down after an
    // explicit start.
    let service_status = transition ? "transitioning" :
        prokop.running == null ? "unknown" : prokop.running == 1 ? "ok" :
        prokop.stopped_by_user == 1 ? "stopped" : prokop.not_started == 1 ? "not_started" : "error";
    // The last configuration change: a cron_refresh event tells about the
    // scheduled jobs only, and is last in the history when its start or
    // reload gave way to a stop; it never asks for recovery. A
    // config_migration event changes nothing in the runtime: a package
    // upgrade that does not start Prokop again (stopped by the user) leaves
    // it last, and a failed change before it still counts.
    let last = null;
    for (let i = length(events) - 1; i >= 0 && last == null; i--)
        if (events[i].kind != "cron_refresh" && events[i].kind != "config_migration")
            last = events[i];
    let last_reload = null;
    for (let i = length(events) - 1; i >= 0; i--)
        if (index([ "reload", "restore", "autotune_apply", "autotune_rollback" ], events[i].kind) >= 0) {
            last_reload = events[i];
            break;
        }
    let failed = last != null && last.status == "failure";
    // What ends the guard that is left, named for the recovery pages: none
    // while a service action or a snapshot operation may still hold its own.
    let action = !guard ? null : transition || guards.transaction === true ? "wait" :
        guards.runtime === true ? "restart" : guards.restore === true ? "restore" : null;
    let overall = guard || package_pending || failed ? "error" :
        transition ? "transitioning" : service_status;
    if (overall == "ok" && last != null && last.status == "recovered")
        overall = "recovered";
    return {
        overall,
        service: {
            prokop: service_status,
            sing_box: sing_box.running == null ? "unknown" : sing_box.running == 1 ? "ok" : "error"
        },
        // Not pointed at Prokop is a warning, unless the user manages the
        // router's DNS themselves (dont_touch_dhcp, OBS-6).
        // Pointed at Prokop, but with options changed behind it (C8): an
        // older UI state without dns_complete counts as complete.
        dns: { status: prokop.dhcp_user_managed != 1 &&
                (prokop.dns_configured == 0 || (prokop.dns_configured == 1 && prokop.dns_complete == 0)) ?
                "warning" : "unknown",
            configured: prokop.dns_configured == 1, user_managed: prokop.dhcp_user_managed == 1,
            drift: prokop.dhcp_user_managed != 1 && prokop.dns_configured == 1 && prokop.dns_complete == 0 },
        dpi: { status: guard ? "transitioning" : "unknown" },
        lists: { status: "unknown" },
        guard: { active: guard, runtime: guards.runtime === true, restore: guards.restore === true },
        recovery: { pending: guard || failed, last_event: last, action },
        package_recovery: { pending: package_pending },
        last_reload,
        reload: { busy: reload_busy === true },
        bridge_netfilter: {
            status: type(bridge) != "object" ? "unknown" : bridge.loaded === true ? "warning" : "ok",
            loaded: type(bridge) == "object" && bridge.loaded === true,
            disabled_by_prokop: type(bridge) == "object" && bridge.disabled_by_prokop === true
        },
        recent_activity: events
    };
}

// A reload holds reload.lock (a live owner; a dead one's lock is none), or
// the list worker runs, whose reloads init.d queues for its own final one
// (core/list_worker.uc). A queued reload (reload.pending) without either is
// no reload: the next one drains it.
function reload_running() {
    return require("core.runtime_lock").busy(RELOAD_LOCK) || require("core.list_worker").running(LIB_DIR);
}

let mode = ARGV[0] || "";
if (mode == "record")
    exit(record_event(as_string(ARGV[1]), as_string(ARGV[2]), as_string(ARGV[3]), as_string(ARGV[4]),
        as_string(ARGV[5])));
if (mode == "history") {
    let events = history_events();
    print(sprintf("%J\n", events == null ?
        { persistent: false, events: event_state() } :
        { persistent: true, events }));
    exit(0);
}
if (mode == "fixture") {
    let input = read_object(ARGV[1]);
    print(sprintf("%J\n", health(input.ui || {}, { active: input.guard === true,
        runtime: input.runtime_guard === true, restore: input.restore_guard === true,
        transaction: input.transaction === true }, input.package_pending === true, input.events || [],
        input.reload_busy === true, input.bridge_netfilter)));
    exit(0);
}
if (mode != "get")
    exit(1);

// An open Prokop page asks for the UI state every second; an answer at most
// UI_STATE_MAX_AGE seconds old saves this poll the whole chain again.
let ui = null;
let cached = fs.stat(UI_STATE_FILE);
if (cached != null && cached.type == "file" && time() - cached.mtime >= 0 && time() - cached.mtime <= UI_STATE_MAX_AGE) {
    try { ui = json(fs.readfile(UI_STATE_FILE)); } catch (e) { ui = null; }
}
if (type(ui) != "object") {
    try {
        ui = json(capture([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/ui.uc", "get-ui-state" ]));
    }
    catch (e) {}
}
if (type(ui) != "object")
    ui = {};
let guards = {
    runtime: command_ok([ "nft", "-t", "list", "table", "inet", "ProkopTableDpiGuard" ]) ||
        command_ok([ "nft", "list", "chain", "inet", "ProkopTable", "prokop_transition_guard" ]),
    restore: command_ok([ "nft", "-t", "list", "table", "inet", "ProkopConfigRestoreDpiGuard" ])
};
if (guards.restore)
    guards.transaction = snapshot_operation_active();
let package_pending = fs.stat(PACKAGE_PENDING + "/pending") != null;
let bridge = null;
try { bridge = require("nft.bridge_netfilter").status(); } catch (e) {}
print(sprintf("%J\n", health(ui, guards, package_pending, event_state(), reload_running(), bridge)));
