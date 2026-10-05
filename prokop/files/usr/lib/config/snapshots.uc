#!/usr/bin/env ucode

let fs = require("fs");
let identity = require("core.process_identity");
let runtime_lock = require("core.runtime_lock");
let list_worker = require("core.list_worker");
let durable = require("core.durable");
let legacy_forkop = require("core.legacy_forkop");

const CONFIG = getenv("PROKOP_CONFIG_FILE") || "/etc/config/prokop";
const ROOT = getenv("PROKOP_SNAPSHOT_DIR") || "/etc/prokop/config-snapshots";
const HASH_DIR = getenv("PROKOP_SNAPSHOT_HASH_DIR") || "/var/run/prokop/snapshot-hash";
const LOCK = getenv("PROKOP_SNAPSHOT_LOCK_DIR") || "/var/run/prokop/config-snapshot.lock";
const LKG = ROOT + "/last-known-working";
// The snapshot that Save & Apply took (or found) before LuCI applied its
// change, kept until the reload of that change has taken its own snapshot
// (trim_retention).
const APPLY_SNAPSHOT = ROOT + "/apply-snapshot";
const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const BIN = getenv("PROKOP_BIN") || "/usr/bin/prokop";
const RELOAD = getenv("PROKOP_RELOAD_COMMAND") || "/etc/init.d/prokop";
const MAX_CONFIG = 2 * 1024 * 1024;
const PENDING_RELOAD = getenv("PROKOP_PENDING_RELOAD_FILE") || "/var/run/prokop/reload.pending";
const RELOAD_LOCK = getenv("PROKOP_RELOAD_LOCK_DIR") || "/var/run/prokop.reload.lock";
// An explicit stop (service/initd.uc, service/lifecycle.uc): until an
// explicit start no reload brings the runtime back (D-15, UC-056).
const STOP_REQUESTED = getenv("PROKOP_STOP_REQUESTED_FILE") ||
    (getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop") + "/stop.requested";
// The record of the last DPI autotune apply (autotune/apply.uc) and the
// phases in which that apply is finished.
const AUTOTUNE_APPLY_STATE = getenv("PROKOP_AUTOTUNE_APPLY_STATE") || "/etc/prokop/autotune-apply.json";
const AUTOTUNE_TERMINAL_PHASES = [ "applied", "rolled_back", "failed", "stale", "no_change_required", "needs_attention" ];
// The "lkg" of an apply record whose candidate waits for its observation
// (autotune/apply.uc).
const AUTOTUNE_LKG_OBSERVATION = "observation_pending";
// The save directory of `uci set` without a commit; libuci reads every
// cursor through it (autotune/apply.uc and manager.uc check it too, with the
// override PROKOP_AUTOTUNE_UCI_SAVEDIR). Tests that restore set it.
const UCI_SAVEDIR = getenv("PROKOP_UCI_SAVEDIR") || "/tmp/.uci";
// How many snapshots the store holds (config/retention.uc, set on the
// History page) and the places of it that manual snapshots never take: they
// stay for the automatic safety snapshots (D-14, UC-022). See trim_retention.
let retention = require("config.retention");
const RESERVED = retention.RESERVED;
function retention_limit() { return retention.limits().snapshots; }
function manual_limit() { return retention_limit() - RESERVED; }
const GUARD_SETTLE_SECONDS = int(getenv("PROKOP_RUNTIME_GUARD_SETTLE_SECONDS") || "30");

function value(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(value(v), /'/g, "'\\''") + "'"; }
function cmd(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}
function capture(args) {
    let pipe = fs.popen(cmd(args) + " 2>/dev/null", "r");
    if (!pipe) return "";
    let result = pipe.read("all");
    return pipe.close() == 0 && result != null ? result : "";
}
function success(args) { return system(cmd(args) + " >/dev/null 2>&1") == 0; }
function valid_id(id) { return match(value(id), /^[a-z0-9_-]{1,64}$/) != null; }
function valid_hash(v) { return match(value(v), /^[0-9a-f]{64}$/) != null; }
function snapshot_path(id) { return ROOT + "/" + id + ".json"; }
function read_config() {
    let data = fs.readfile(CONFIG);
    return data != null && length(data) <= MAX_CONFIG ? data : null;
}
function sha(data) {
    let parent = fs.dirname(HASH_DIR);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return "";
    if (fs.stat(HASH_DIR) == null && !fs.mkdir(HASH_DIR, 0700)) return "";
    if (!fs.chmod(HASH_DIR, 0700)) return "";
    let tmp = HASH_DIR + "/.hash." + sprintf("%d.%d", clock()[0], clock()[1]);
    if (fs.writefile(tmp, data) == null) return "";
    let output = capture([ "sha256sum", tmp ]);
    fs.unlink(tmp);
    let hash = split(output, " ")[0];
    return length(hash) == 64 && match(hash, /^[0-9a-f]+$/) != null ? hash : "";
}
// Every file this module writes is on flash: the configuration, the
// snapshots and the pointers to them are flushed before and after the
// rename (UC-025).
function atomic(path, data) {
    let tmp = path + "." + sprintf("%d.%d", clock()[0], clock()[1]) + ".tmp";
    return durable.durable_replace(tmp, path, data, 0600);
}
function ensure_root() {
    let parent = fs.dirname(ROOT);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return false;
    if (fs.stat(ROOT) == null && !fs.mkdir(ROOT, 0700)) return false;
    return fs.chmod(ROOT, 0700);
}
// The lock is a runtime directory holding one "owner.<pid>.<start ticks>"
// record. The name is unique per process lifetime, so unlinking a stale or
// own record by name can never remove the record of a lock that replaced it.
// The modes that take the lock.
const OPERATIONS = [ "create", "delete", "restore", "apply", "confirm-working", "clear", "retention" ];
let lock_record = null;
let lock_busy = false;   // set when a live snapshot operation owns the lock
function owner_pid() {
    let pid = value(fs.readlink("/proc/self"));
    return match(pid, /^[1-9][0-9]*$/) != null ? pid : "";
}
function active_entry(name) {
    let parsed = match(value(name), /^owner\.([1-9][0-9]*)\.([0-9]+)$/);
    if (parsed == null) return false;
    for (let operation in OPERATIONS)
        if (identity.matches_record({ pid: parsed[1], ticks: parsed[2] }, "ucode",
            [ "ucode", "-L", LIB_DIR, LIB_DIR + "/config/snapshots.uc", operation ], false, true) != "")
            return true;
    return false;
}
function remove_lock_dir(dir) {
    for (let name in fs.lsdir(dir) || []) fs.unlink(dir + "/" + name);
    return fs.rmdir(dir);
}
function acquire() {
    if (!ensure_root()) return false;
    let parent = fs.dirname(LOCK);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return false;
    let pid = owner_pid(), ticks = identity.start_ticks(pid);
    if (ticks == "") return false;
    let name = "owner." + pid + "." + ticks;
    // The record is complete before the lock becomes visible, so no observer
    // can mistake a lock that is still being initialised for a stale one.
    let pending = LOCK + ".new." + pid + "." + ticks;
    remove_lock_dir(pending);
    if (!fs.mkdir(pending, 0700) || !identity.record(pending + "/" + name, pid) || !active_entry(name)) {
        remove_lock_dir(pending);
        return false;
    }
    for (let attempt = 0; attempt < 3; attempt++) {
        // rename() refuses a populated lock; an empty one was already released.
        if (fs.rename(pending, LOCK)) {
            lock_record = LOCK + "/" + name;
            return true;
        }
        let stat = fs.lstat(LOCK);
        let entries = stat != null && stat.type == "directory" ? fs.lsdir(LOCK) : null;
        if (entries == null) {
            // Absent, or not a lock directory (never follow a symlink here).
            fs.unlink(LOCK);
            continue;
        }
        let busy = false;
        for (let entry in entries) if (active_entry(entry)) busy = true;
        if (busy) { lock_busy = true; break; }
        for (let entry in entries)
            if (!fs.unlink(LOCK + "/" + entry)) fs.rmdir(LOCK + "/" + entry);
    }
    remove_lock_dir(pending);
    return false;
}
function release() {
    if (lock_record == null) return;
    fs.unlink(lock_record);
    fs.rmdir(LOCK);
    lock_record = null;
}
function read_snapshot(id, verify) {
    if (!valid_id(id)) return null;
    let data = fs.readfile(snapshot_path(id));
    if (data == null || length(data) > MAX_CONFIG + 8192) return null;
    try {
        let parsed = json(data);
        return type(parsed) == "object" && parsed.id == id &&
            type(parsed.content) == "string" && length(parsed.content) <= MAX_CONFIG &&
            length(value(parsed.config_hash)) == 64 && match(value(parsed.config_hash), /^[0-9a-f]+$/) != null &&
            (!verify || sha(parsed.content) == parsed.config_hash) ? parsed : null;
    }
    catch (e) { return null; }
}
function valid_version(v) { return match(value(v), /^[A-Za-z0-9._-]{1,64}$/) != null; }
// Snapshots taken before the rename to Prokop record the version under
// Forkop's key; they are read, never written, that way.
function snapshot_version(snapshot) {
    if (valid_version(snapshot.prokop_version)) return snapshot.prokop_version;
    let legacy = snapshot[legacy_forkop.SNAPSHOT_VERSION_KEY];
    return valid_version(legacy) ? legacy : "unknown";
}
function metadata(snapshot) {
    return { id: snapshot.id, created_at: snapshot.created_at,
        kind: index([ "manual", "automatic" ], snapshot.kind) >= 0 ? snapshot.kind : "unknown",
        reason: index([ "manual", "before-reload", "before-apply", "pre-restore", "last-known-working", "before-autotune", "concurrent-change" ], snapshot.reason) >= 0 ? snapshot.reason : "unknown",
        config_hash: snapshot.config_hash,
        prokop_version: snapshot_version(snapshot) };
}
// The version of the running release, as a snapshot records it.
function prokop_version() {
    let version = trim(capture([ BIN, "show_version" ]));
    return valid_version(version) ? version : "unknown";
}
// The migration state of a configuration (D-16): settings.config_version
// and the ids of settings.applied_migrations, which config/migration.uc
// records. A quick line reader for what a snapshot records when it is taken,
// for the snapshot list, which runs on every refresh of the History page,
// and for a restore to tell whether a migration is needed at all: the
// settings lines a uci commit writes hold single-quoted words, one statement
// a line. A restore that it finds behind reads both configurations again as
// libuci loads them (sections_schema), which decide. Only hand-made text
// misleads it (a quoted value spanning lines that holds a header or one of
// these options, ';' between statements): then the list's hint is wrong, or
// a restore takes a snapshot for migrated that such text makes look so, and
// restores it as it is, as before D-16.
function settings_schema(content) {
    let result = { config_version: "", applied_migrations: [] }, inside = false, applied = null;
    let word = (text) => {
        let found = match(text, /^'([^']*)'/) ?? match(text, /^"([^"\\]*)"/) ?? match(text, /^([^ \t'"#\\]+)/);
        return found != null ? found[1] : text;
    };
    for (let line in split(value(content), "\n")) {
        // Only a section header and these two options matter, and only a
        // header naming settings needs the full pattern: other lines are
        // passed over without a regular expression (a big configuration has
        // thousands, and the list reads every snapshot an older release
        // took).
        if (index(line, "config") < 0 && index(line, "applied_migrations") < 0) continue;
        line = replace(line, /\r$/, "");
        if (match(line, /^[ \t]*config([ \t]|$)/) != null) {
            let start = index(line, "settings") < 0 ? null : match(line, /^[ \t]*config[ \t]+['"]?[^ \t'"#;\\]+['"]?[ \t]+['"]?([A-Za-z0-9_-]*)['"]?[ \t]*(#.*)?$/);
            inside = start != null && start[1] == "settings";
            continue;
        }
        let opt = inside ? match(line, /^[ \t]*(option|list)[ \t]+(config_version|applied_migrations)[ \t]+(.+)$/) : null;
        if (opt == null) continue;
        let raw = word(trim(opt[3]));
        if (opt[2] == "config_version") {
            if (raw != "") result.config_version = raw;
        }
        else if (opt[1] == "list") {
            if (type(applied) != "array") applied = applied == null ? [] : [ applied ];
            push(applied, raw);
        }
        else if (raw != "") applied = raw;
    }
    result.applied_migrations = type(applied) == "array" ? applied :
        filter(split(trim(value(applied)), " "), (id) => id != "");
    return result;
}
// Hash of the configuration the last-known-working snapshot holds.
function lkg_hash() {
    let item = read_snapshot(trim(value(fs.readfile(LKG))), false);
    return item != null ? item.config_hash : "";
}
// The migration state a snapshot recorded when it was taken, or, for one an
// older release wrote, the one its configuration holds.
function snapshot_schema(snapshot) {
    let schema = snapshot.schema;
    if (type(schema) == "object" && type(schema.config_version) == "string" && type(schema.applied_migrations) == "array")
        return schema;
    return settings_schema(snapshot.content);
}
// with_schema: each entry also has the schema of its snapshot.
function list_snapshots(with_schema) {
    let result = [];
    let working = trim(value(fs.readfile(LKG)));
    for (let file in fs.lsdir(ROOT) || []) {
        let id = replace(file, /\.json$/, "");
        if (file != id + ".json" || !valid_id(id)) continue;
        let item = read_snapshot(id, false);
        if (item == null) continue;
        let entry = metadata(item);
        entry.is_lkg = id == working;
        if (with_schema) entry.schema = snapshot_schema(item);
        push(result, entry);
    }
    result = sort(result, function(a, b) { return a.created_at - b.created_at; });
    return result;
}
function manual_count(all) {
    return length(filter(all, (item) => item.kind == "manual"));
}
// The before-autotune snapshot that a rollback of the recorded autotune apply
// returns to (autotune/apply.uc rollback_to, rollback), or null: while the
// apply runs (its verification, its automatic rollback), waits for a decision
// (needs_attention, failed with a rollback left) or applied its candidate,
// which the operator may still roll back. A decided record, one without a
// mutation and an unreadable one name none.
function autotune_rollback_snapshot() {
    if (fs.stat(AUTOTUNE_APPLY_STATE) == null) return null;
    let record = null;
    try { record = json(value(fs.readfile(AUTOTUNE_APPLY_STATE))); } catch (e) { record = null; }
    if (type(record) != "object" || type(record.phase) != "string" || record.mutation == null || !valid_id(record.pre_snapshot))
        return null;
    let rollback = index(AUTOTUNE_TERMINAL_PHASES, record.phase) < 0 || record.phase == "applied" ||
        record.phase == "needs_attention" || (record.phase == "failed" && record.rollback_available === true);
    return rollback ? record.pre_snapshot : null;
}
// An apply record that may still roll back but names no before-autotune
// snapshot yet: the apply is between taking it and recording its id, or
// died there (autotune/apply.uc find_pre_snapshot finds it afterwards by
// configuration hash and time). The time from which every before-autotune
// snapshot counts as possibly that one, or null. An unreadable record or one
// without a start time protects them all (0).
function autotune_unnamed_since() {
    if (fs.stat(AUTOTUNE_APPLY_STATE) == null) return null;
    let record = null;
    try { record = json(value(fs.readfile(AUTOTUNE_APPLY_STATE))); } catch (e) { record = null; }
    if (type(record) != "object" || type(record.phase) != "string") return 0;
    if (valid_id(record.pre_snapshot)) return null;
    let open = index(AUTOTUNE_TERMINAL_PHASES, record.phase) < 0 || record.phase == "needs_attention" ||
        (record.phase == "failed" && record.rollback_available === true);
    if (!open) return null;
    return type(record.started_at) == "int" ? record.started_at - 1 : 0;
}
// Install uses ensure semantics: after needs_attention the guard from the
// failed restore is still active and must protect the recovery restore too.
// It is removed only after a reload proved a coherent runtime.
function restore_guard(remove) {
    return success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/nft/apply.uc",
        remove ? "remove-dpi-transition-guard" : "ensure-dpi-transition-guard", "ProkopConfigRestore" ]);
}
// "absent", "valid" or "invalid"; empty when the state is unknown.
function restore_guard_state() {
    return trim(capture([ "ucode", "-L", LIB_DIR, LIB_DIR + "/nft/apply.uc",
        "dpi-transition-guard-state", "ProkopConfigRestore" ]));
}
// The snapshots that an active restore guard may still need: while the
// guard of a restore (or of an autotune apply) that ended needs_attention
// stands, or its state cannot be read, the configuration it was taken over
// (pre-restore) and an edit committed during it (concurrent-change) are the
// ways back the recovery offers. Read only when such a snapshot is next in
// line, since it asks nft.
function guard_needs(item, ctx) {
    if (item.reason == "before-autotune") {
        if (!ctx.unnamed_read) { ctx.unnamed_read = true; ctx.unnamed = autotune_unnamed_since(); }
        return ctx.unnamed != null && int(item.created_at) >= ctx.unnamed;
    }
    if (item.reason != "pre-restore" && item.reason != "concurrent-change") return false;
    if (ctx.guard == null) ctx.guard = restore_guard_state();
    return ctx.guard != "absent";
}
// Why delete refuses a snapshot, or null (UC-119, CFG-2): the
// last-known-working one, the before-autotune one that the recorded
// autotune apply may still roll back to (autotune_rollback_snapshot), and
// the one Save & Apply took until the reload of its change has run, and one
// that an active restore guard may still need (guard_needs)
// (trim_retention keeps the same ones). reason: the snapshot's own.
let protected_ids = null;
function protected_reason(id, working, reason, created_at) {
    if (id == working) return "lkg_protected";
    if (protected_ids == null)
        protected_ids = { rollback: autotune_rollback_snapshot(), applying: trim(value(fs.readfile(APPLY_SNAPSHOT))) };
    if (id == protected_ids.rollback) return "autotune_rollback_protected";
    if (id == protected_ids.applying) return "apply_snapshot_protected";
    if (reason == "before-autotune" && guard_needs({ reason, created_at }, protected_ids))
        return "autotune_rollback_protected";
    if (guard_needs({ reason }, protected_ids)) return "restore_guard_protected";
    return null;
}
// Whether retention, or "Clear", may remove a snapshot: never a manual one,
// nor the last-known-working one, nor the before-autotune one that the
// recorded autotune apply may still roll back to (an automatic snapshot
// taken during its verification, or after it applied, would otherwise push
// it out next to many manual ones), nor one that the running operation still
// needs (keep), nor the one that Save & Apply took before LuCI applied its
// change, until the reload of that change has taken its own snapshot: the
// reload's snapshot comes right after the commit and would otherwise take
// the restore point of the change it applies, and the list of the change
// that the page shows once the reload has run (configform.js); nor one that
// an active restore guard may still need (guard_needs).
function removable(item, keep, ctx) {
    if (ctx.working == null) {
        ctx.working = trim(value(fs.readfile(LKG)));
        ctx.rollback = autotune_rollback_snapshot();
        ctx.applying = trim(value(fs.readfile(APPLY_SNAPSHOT)));
    }
    return item.kind != "manual" && item.id != ctx.working && item.id != ctx.rollback && item.id != ctx.applying &&
        index(keep || [], item.id) < 0 && !guard_needs(item, ctx);
}
// Retention (D-14, UC-022). Nothing removes a manual snapshot, and create
// refuses one more beyond manual_limit(), so RESERVED places stay for the
// automatic safety snapshots: before a restore, before Save & Apply or a
// reload, before an autotune apply, the last-known-working one and a
// concurrent edit. Only automatic snapshots rotate, oldest first and among
// themselves, and only those that removable() allows.
// The store holds retention_limit() snapshots, or manual + RESERVED while
// more manual ones are left from before the limit (an upgrade, or a limit
// the user lowered).
// room: the store makes room for one more snapshot (create); without it, it
// only shrinks to its size (a lowered limit).
// automatic: a safety snapshot is never refused for room. When nothing but
// manual, protected and kept snapshots is left, it is taken beyond that
// size; the next automatic snapshot replaces it, and once the protected ones
// rotate again the store returns to its size.
// The number of snapshots removed, or -1 when room could not be made.
function trim_retention(keep, automatic, room) {
    let all = list_snapshots();
    let ctx = {};
    let limit = max(retention_limit(), manual_count(all) + RESERVED);
    let removed = 0;
    if (room == null) room = true;
    while (room ? length(all) >= limit : length(all) > limit) {
        let candidate = null;
        for (let item in all)
            if (removable(item, keep, ctx)) { candidate = item; break; }
        if (candidate == null || !fs.unlink(snapshot_path(candidate.id))) return automatic || !room ? removed : -1;
        removed++;
        all = list_snapshots();
    }
    return removed;
}
// "Clear" on the History page: every automatic snapshot that retention may
// remove goes (removable), oldest first. Manual snapshots stay, so do the
// protected ones; the answer says how many went and how many were kept.
function clear_snapshots() {
    let ctx = {}, removed = 0, kept = 0, manual = 0, failed = 0;
    for (let item in list_snapshots()) {
        if (item.kind == "manual") manual++;
        else if (!removable(item, [], ctx)) kept++;
        else if (fs.unlink(snapshot_path(item.id))) removed++;
        else failed++;
    }
    let answer = { status: failed ? "failed" : "cleared", removed, kept, manual };
    if (failed) answer.reason = "delete_failed";
    return answer;
}
// dedupe: true returns any snapshot that already holds the configuration, a
// reason only one of that reason. A new snapshot records the release that
// took it and the migration state of its configuration (schema, D-16); one
// that an older release wrote has no schema, its configuration tells.
// content (optional): the configuration to take instead of the file's, one
// a transaction proved (a migrated restore); the file may hold an edit
// committed since.
function create(kind, reason, dedupe, keep, content) {
    if (content == null) content = read_config();
    if (content == null) return { status: "failed", reason: "config_unavailable" };
    let hash = sha(content);
    if (hash == "") return { status: "failed", reason: "hash_unavailable" };
    if (dedupe)
        for (let item in list_snapshots())
            if (item.config_hash == hash && (dedupe === true || item.reason == dedupe)) return { status: "existing", snapshot: item };
    // A manual snapshot never takes a reserved place, and never pushes out
    // another manual one: the user deletes one first, or more while more are
    // left from before the limit (the page says how many).
    let manual = kind == "manual" ? manual_count(list_snapshots()) : 0;
    if (kind == "manual" && manual >= manual_limit())
        return { status: "failed", reason: "manual_limit_reached", limit: manual_limit(), manual };
    if (trim_retention(keep, kind != "manual") < 0) return { status: "failed", reason: "retention_full" };
    let id = sprintf("%d_%d", clock()[0], clock()[1]);
    let snapshot = { id, created_at: int(clock()[0]), kind, reason,
        config_hash: hash, prokop_version: prokop_version(), schema: settings_schema(content), content };
    if (fs.stat(snapshot_path(id)) != null ||
        !atomic(snapshot_path(id), sprintf("%J\n", snapshot)))
        return { status: "failed", reason: "write_failed" };
    return { status: "created", snapshot: metadata(snapshot) };
}
// An option whose name may hold a secret (a password, a token, a link that
// carries credentials, a chat ID, an ID of the device) is always hidden,
// whatever its value; only its switch (*_enabled) is shown.
const SECRET_OPTION = /pass|secret|token|auth|uuid|key|private|credential|cookie|psk|cert|hwid|chat_id|user|proxy_string|url|link|json/;
// Any other option shows a value only of a shape no secret has: a switch, a
// number, a duration or a lowercase keyword (doh, prefer_ipv4, 3m). Free
// text, addresses and anything with a capital letter stay hidden.
function safe_value(option, raw) {
    if (index([ "dns_server", "bootstrap_dns_server" ], option) >= 0 &&
        match(raw, /^[0-9A-Fa-f:.]{1,45}$/) != null) return raw;
    let name = lc(option);
    if (match(name, SECRET_OPTION) != null && match(name, /_enabled$/) == null) return "***";
    if (match(raw, /^[a-z0-9][a-z0-9_-]{0,31}$/) != null) return raw;
    return "***";
}
// Parses a UCI value made of quoted/unquoted segments ('it'\''s', "a\"b").
// A quoted value may span lines; null means the quote is still open.
function uci_value(text) {
    let result = "", quote = null;
    for (let i = 0; i < length(text); i++) {
        let c = substr(text, i, 1);
        if (quote == "'") {
            if (c == "'") quote = null; else result += c;
        }
        else if (quote == "\"") {
            if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
            else if (c == "\"") quote = null;
            else result += c;
        }
        else if (c == "'" || c == "\"") quote = c;
        else if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
        else if (c == " " || c == "\t") break;
        else result += c;
    }
    return quote == null ? result : null;
}
// Options by "<section>.<option>". Every `config <type> ['<name>']` line
// starts a section. One without a name (libuci writes anonymous sections so)
// is keyed as libuci addresses it, @<type>[<n>], n counting every section of
// that type in file order (a named section that appears again is the same
// section): its options never merge into the named section before it
// (UC-018). A header this reader cannot parse ends the section before it, so
// what follows is attributed to no other section. The \r of a CRLF line end is
// a blank to libuci, so it is no part of a line here. An option followed by a
// list of the same name is one list, the option's value first, as libuci
// loads it.
function options(content) {
    let result = {};
    let section = null, count = {}, named = {};
    let lines = map(split(content, "\n"), (line) => replace(line, /\r$/, ""));
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        if (match(line, /^[ \t]*config([ \t]|$)/) != null) {
            let start = match(line, /^[ \t]*config[ \t]+['"]?([^ \t'"#;\\]+)['"]?([ \t]+['"]?([A-Za-z0-9_-]*)['"]?)?[ \t]*(#.*)?$/);
            section = null;
            if (start != null) {
                let type = start[1], name = start[3], n = count[type] ?? 0;
                if (name == null || name == "") { section = sprintf("@%s[%d]", type, n); count[type] = n + 1; }
                else {
                    section = name;
                    if (!named[name]) { named[name] = true; count[type] = n + 1; }
                }
            }
            continue;
        }
        let opt = match(line, /^[ \t]*(option|list)[ \t]+([A-Za-z0-9_-]+)[ \t]+(.+)$/);
        if (section == null || opt == null) continue;
        // Continuation lines of a quoted multi-line value belong to this option.
        let text = trim(opt[3]), raw = uci_value(text);
        while (raw == null && i + 1 < length(lines)) {
            text += "\n" + lines[++i];
            raw = uci_value(text);
        }
        if (raw == null) raw = text;
        let key = section + "." + opt[2];
        if (opt[1] == "list") {
            if (result[key] == null)
                result[key] = { kind: "list", values: [] };
            else if (result[key].kind != "list")
                result[key] = { kind: "list", values: [ result[key].value ] };
            push(result[key].values, raw);
        }
        // An option statement without a value sets nothing, as libuci loads
        // it (see uci_sections): an earlier value stays, alone it is not set.
        else if (raw != "")
            result[key] = { kind: "option", value: raw };
    }
    return result;
}
function safe_values(option, values) {
    let result = [];
    for (let raw in values) push(result, safe_value(option, raw));
    return result;
}
// A side without the option is null, "not set"; '***' stands only for a
// value that exists and is hidden (D-2, UC-063). Absence tells nothing of a
// value: the option name is shown anyway. An option side stays scalar so
// option <-> list changes remain visible.
function diff_side(option, entry) {
    if (entry == null) return null;
    return entry.kind == "list" ? safe_values(option, entry.values) : safe_value(option, entry.value);
}
// At most DIFF_ROWS changes are listed. A longer diff ends with a marker in
// place of the rest, { truncated: true, total }, total counting every changed
// option, so no reader takes the list for the whole change (UC-062). The
// array form stays for its readers; the marker holds a count, no value.
const DIFF_ROWS = 100;
function diff(before, after) {
    let old = options(before), current = options(after), result = [], total = 0;
    let all = {};
    for (let key in keys(old)) all[key] = true;
    for (let key in keys(current)) all[key] = true;
    for (let key in keys(all)) {
        let a = old[key], b = current[key];
        // An option name has no dot; an anonymous section's type may.
        let dot = rindex(key, "."), option = substr(key, dot + 1);
        let row = { section: substr(key, 0, dot), option };
        if ((a != null && a.kind == "list") || (b != null && b.kind == "list")) {
            if (a != null && b != null && a.kind == b.kind &&
                sprintf("%J", a.values) == sprintf("%J", b.values)) continue;
            row.kind = "list";
        }
        else if (a != null && b != null && a.value == b.value) continue;
        if (++total > DIFF_ROWS) continue;
        row.before = diff_side(option, a);
        row.after = diff_side(option, b);
        push(result, row);
    }
    if (total > DIFF_ROWS) push(result, { truncated: true, total });
    return result;
}
// A lifecycle action (subscription update, WAN-up reload, start, a
// pending-reload drain) owns the reload lock, and a running list update gets
// every reload queued for it, with or without the lock: a reload requested
// now would only be queued behind either. A queued reload without a live
// owner is no such action: the next reload takes the free lock and its
// finish drains that request. A restore relies on this, so recovery stays
// possible while the current configuration cannot reload and keeps failing
// to drain the queue. The lock and its owner record: core/runtime_lock.uc;
// the list worker: core/list_worker.uc.
function service_action() {
    return runtime_lock.busy(RELOAD_LOCK) || list_worker.running(LIB_DIR) ? "service_action_in_progress" : null;
}
// A fail-closed guard that a failed lifecycle transition kept: the DPI guard
// table of a failed DPI rollback or the transition guard chain of a failed
// sing-box rollback (service/lifecycle.uc runtime_guard_kept). It drops the
// traffic it guards until a restart removes it, and the lifecycle refuses
// every reload over it: while it is there no reload proves a coherent
// runtime, whatever its exit status (UC-019).
function runtime_guard_kept() {
    let table = getenv("NFT_TABLE_NAME") || "ProkopTable";
    return success([ "nft", "list", "table", "inet", table + "DpiGuard" ]) ||
        success([ "nft", "list", "chain", "inet", table, "prokop_transition_guard" ]);
}
// The same, read after init.d released reload.lock. A lifecycle action that
// holds the lock by then (a WAN-up or hotplug reload that took it next, the
// holder a queued reload waited for) installs the same guards for its own
// transition and removes them when it ends: a guard seen while one runs is
// kept only if it outlasts that action. Wait for it, bounded; a guard still
// there under a busy lock after the bound counts as kept (fail closed).
function runtime_guard_settled() {
    for (let waited = 0; runtime_guard_kept(); waited++) {
        if (service_action() == null || waited >= GUARD_SETTLE_SECONDS) return true;
        success([ "sleep", "1" ]);
    }
    return false;
}
// Changes to prokop staged with uci but not committed. The validator, the
// generator and the lifecycle read the configuration through them, so a
// restore would validate and load the snapshot plus these changes while LKG
// names the pure snapshot (UC-068). LuCI keeps its unsaved changes per rpcd
// session, outside this directory: no reload reads them (the History page
// asks for those to be saved or reverted first).
function staged_changes() {
    let st = fs.stat(UCI_SAVEDIR + "/prokop");
    return st != null && st.size > 0;
}
// A reload that was only queued (another lifecycle action took the reload
// lock after the check above) exits 0 without touching the runtime. init.d
// acknowledges it with a "queued" line for this caller's reason; a changed
// pending-reload marker (unique per request) is the second witness. A request
// queued before the call is drained by a reload that ran (the marker is
// gone); a drain that failed rewrites it and so never counts as ran.
function pending_stamp() {
    let st = fs.stat(PENDING_RELOAD);
    return st == null ? null : sprintf("%d:%d:%s", st.mtime, st.size, value(fs.readfile(PENDING_RELOAD)));
}
// "ran", "queued", "stopped" or "failed". "stopped": an explicit stop, or
// no explicit start since boot, holds the runtime down, so the reload was
// skipped (or the runtime it reloaded is down again) and nothing runs the
// configuration; init.d says so for this caller's reason (D-15, UC-056).
function reload(reason) {
    let before = pending_stamp();
    let pipe = fs.popen(cmd([ RELOAD, "reload", reason ]) + " 2>/dev/null", "r");
    if (!pipe) return "failed";
    let output = value(pipe.read("all"));
    if (pipe.close() != 0) return "failed";
    for (let line in split(output, "\n")) {
        if (trim(line) == "queued") return "queued";
        if (trim(line) == "stopped") return "stopped";
    }
    let after = pending_stamp();
    return after != null && after != before ? "queued" : "ran";
}
// The user configuration, without the shutdown_correctly bookkeeping that
// releases before UC-160 kept in it, hashed as autotune/apply.uc
// fingerprints it.
function user_fingerprint(content) {
    let lines = [];
    for (let line in split(content, "\n"))
        if (match(line, /^[ \t]*option[ \t]+shutdown_correctly([ \t]|$)/) == null) push(lines, line);
    return sha(join("\n", lines));
}
// Blanks between words: space, \t, \v, \f, \r.
function uci_space(c) { return c == 32 || c == 9 || c == 11 || c == 12 || c == 13; }
// The statements of a configuration file as libuci's parser splits them
// (file.c): words with quotes and escapes resolved, comments dropped; a word
// is raw when it had neither. null for an open quote or for syntax this
// reader does not follow (';', a backslash line continuation).
function uci_statements(text) {
    let result = [], words = [], word = null;
    let end_word = () => { if (word != null) push(words, word); word = null; };
    let lines = split(text, "\n");
    for (let l = 0; l < length(lines); l++) {
        let line = lines[l], i = 0, n = length(line);
        // A backslash at the end of a line (or of the file) continues it.
        let continuation = () => i >= n || (i == n - 1 && substr(line, i, 1) == "\r");
        while (i < n) {
            let c = substr(line, i, 1);
            if (uci_space(ord(c))) { end_word(); i++; continue; }
            if (c == "#") break;
            if (c == ";") return null;
            if (word == null) word = { text: "", raw: true };
            if (c == "'" || c == "\"") {
                // A quoted run may span lines; inside double quotes a
                // backslash takes the next character.
                word.raw = false;
                i++;
                while (true) {
                    let rest = substr(line, i), close = index(rest, c);
                    let escape = c == "\"" ? index(rest, "\\") : -1;
                    if (escape >= 0 && (close < 0 || escape < close)) {
                        word.text += substr(rest, 0, escape);
                        i += escape + 1;
                        if (continuation()) return null;
                        word.text += substr(line, i++, 1);
                    }
                    else if (close >= 0) { word.text += substr(rest, 0, close); i += close + 1; break; }
                    else {
                        word.text += rest + "\n";
                        if (++l >= length(lines)) return null;
                        line = lines[l]; i = 0; n = length(line);
                    }
                }
                continue;
            }
            if (c == "\\") { word.raw = false; i++; if (continuation()) return null; }
            let start = i++;
            while (i < n && !uci_space(ord(line, i)) && index("#;'\"\\", substr(line, i, 1)) < 0) i++;
            word.text += substr(line, start, i - start);
        }
        end_word();
        if (length(words)) push(result, words);
        words = [];
    }
    return result;
}
// The sections of a configuration as libuci loads it: a named section that
// appears again is merged into the first, an option keeps its last value,
// list values stay in order. An option statement without a value changes
// nothing (libuci's uci_set of an empty value on load): an earlier value
// stays, and alone it creates no option. null when libuci would not load it
// the same way (see uci_statements) or not at all.
function uci_sections(text) {
    let statements = uci_statements(text);
    if (statements == null) return null;
    let sections = [], current = null;
    let find = (list, name) => { for (let x in list) if (x.name === name) return x; return null; };
    for (let w in statements) {
        let keyword = w[0].raw ? w[0].text : "", args = length(w) - 1;
        if (keyword == "package" || keyword == "p") {
            if (args != 1) return null;
        }
        else if (keyword == "config" || keyword == "c") {
            if (args < 1 || args > 2 || w[1].text == "") return null;
            let name = args == 2 ? w[2].text : "";
            current = name == "" ? null : find(sections, name);
            if (current != null && current.type != w[1].text) return null;
            if (current == null) push(sections, current = { name: name == "" ? null : name, type: w[1].text, options: [] });
        }
        else if (keyword == "option" || keyword == "o" || keyword == "list" || keyword == "l") {
            if (current == null || args < 1 || args > 2 || w[1].text == "") return null;
            let name = w[1].text, value = args == 2 ? w[2].text : "", option = find(current.options, name);
            if (substr(keyword, 0, 1) == "o") {
                if (value == "") continue;
                if (option != null) { option.list = false; option.value = value; }
                else push(current.options, { name, list: false, value });
            }
            else if (option == null) push(current.options, { name, list: true, value: [ value ] });
            else if (!option.list) { option.list = true; option.value = [ option.value, value ]; }
            else push(option.value, value);
        }
        else return null;
    }
    return sections;
}
// The user configuration as libuci loads it (without the shutdown_correctly
// of older releases), or null (see uci_sections).
function uci_canonical(text) {
    let sections = uci_sections(text);
    if (sections == null) return null;
    for (let s in sections) s.options = filter(s.options, (o) => o.name != "shutdown_correctly");
    return sprintf("%J", sections);
}
// Whether the configuration file still holds `content`: byte for byte, or as
// libuci loads both. A commit inside the reload (a Clash API secret the
// start generates; the shutdown_correctly flag of releases before UC-160)
// rewrites the whole file in libuci's own form (quotes, indentation, blank
// lines; comments go): that is no edit, nor is a change of comments or
// formatting alone, which loads the same configuration (and the next uci
// commit drops it anyway). No hash is involved, so a failing hash tool
// cannot make two files look equal; a file this reader cannot load holds
// nothing (fail closed). Comparing the loaded forms takes a while for a big
// file (seconds on a router): the file is read again afterwards, and an edit
// committed meanwhile is one as well, so the caller writes over nothing it
// has not compared.
function config_holds(content) {
    let current = read_config();
    if (current == null) return false;
    if (current == content) return true;
    let loaded = uci_canonical(current);
    return loaded != null && loaded == uci_canonical(content) && read_config() === current;
}
// A configuration that someone else wrote while a transaction owned the file
// (a LuCI Save & Apply, an autotune policy change, a URLTest override: UCI
// commits never take the snapshot lock). It stays in place and is saved as an
// automatic snapshot (dedupe: once), so a later restore cannot discard it
// either (UC-023, UC-017). Another kind of snapshot that happens to hold the
// same configuration does not count: the id returned is always a "Concurrent
// edit" one, as the page names it, and not, say, a pre-restore snapshot next
// in line for retention. The id, or null when no snapshot could be written
// (the store could not be written; retention never refuses it, D-14): the
// edit then lives in the file only.
function save_concurrent_edit(keep) {
    let saved = create("automatic", "concurrent-change", "concurrent-change", keep);
    return saved.snapshot != null ? saved.snapshot.id : null;
}
// Replace the configuration with `content` under the restore guard, validate
// and reload; on failure put `before` back and reload again. The guard also
// keeps the reload from confirming a last-known-working snapshot, so LKG is
// only ever moved by the caller. on_success runs after the guard is released.
// Only a reload that ran counts: after a queued one the configuration is put
// back, and when the rollback reload is queued too nothing proves a coherent
// runtime, so the guard stays and LKG is not touched.
// apply_mode (autotune apply): the caller proved no guard was active and the
// snapshot lock keeps restores out, so the guard is this call's own.
// A configuration that is put back after the target failed reloaded
// coherently, but that proves no more than it did before: last-known-working
// moves to it (pre) only when it already was the last-known-working one. It
// may be an unconfirmed edit, or an autotune candidate that has just failed
// its production verification (UC-059).
// A reload that an explicit stop, or the lack of an explicit start since
// boot, skipped (D-15, UC-056) proves nothing and starts nothing. on_stopped
// (a restore) keeps the validated configuration for the next explicit start;
// otherwise the configuration is put back. LKG is not moved either way. The
// guard goes, also one inherited from an earlier needs_attention: no runtime
// runs that it could protect (the stop took down the one it protected), and
// only a start, which builds the runtime from the configuration, brings one
// up; kept, it would outlive that start with no reload left to remove it.
// An edit committed by someone else while the transaction owns the file is
// never overwritten: one that lands before the write refuses the transaction;
// one that lands during the target reload (or validation) keeps the file as it
// is instead of putting `before` back, saves it as a snapshot (keep: the ids
// that snapshot may not push out) and ends needs_attention with the guard
// active, since no reload proved a coherent runtime; when a stop skipped the
// reload, the guard goes as described above (UC-023). After a reload that
// ran, a restore does not know whether it loaded the snapshot or the edit:
// the edit is saved the same way, the guard goes (the runtime is coherent)
// and LKG does not move (on_success does not run). An apply's caller checks
// the file itself before it confirms anything (autotune/apply.uc).
// A reload proves nothing while a failed lifecycle transition keeps its
// fail-closed guard (runtime_guard_settled): the transaction ends
// needs_attention runtime_guard_active with the guard active and LKG where
// it was; after a failed target `before` is put back without a rollback
// reload, which the lifecycle would refuse until a restart (UC-019).
function guarded_replace(before, content, pre, on_success, reason, apply_mode, on_stopped, keep) {
    // A guard left by an earlier needs_attention protects a runtime no reload
    // has proved yet: only this call's own guard may go without a reload.
    let inherited = !apply_mode && restore_guard_state() != "absent";
    if (!restore_guard(false)) return { status: "failed", reason: "guard_unavailable" };
    // Nothing written yet: the transaction counts as started (a history
    // event) only when its own guard, which it cannot remove, stays behind.
    if (read_config() != before) {
        if (inherited) return { status: "failed", reason: "concurrent_change", guard: "active" };
        if (!restore_guard(true)) return { status: "needs_attention", reason: "guard_release_failed", guard: "active", started: true };
        return { status: "failed", reason: "concurrent_change" };
    }
    if (!atomic(CONFIG, content)) {
        if (inherited) return { status: "failed", reason: "replace_failed", guard: "active" };
        if (!restore_guard(true)) return { status: "needs_attention", reason: "replace_failed", guard: "active", started: true };
        return { status: "failed", reason: "replace_failed" };
    }
    let result = null;
    let valid = success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/config/validator.uc", "validate-runtime" ]);
    let target = valid ? reload(reason) : "invalid";
    // A guard that a failed lifecycle transition kept, before or during this
    // reload, leaves no coherent runtime whatever the reload's exit status,
    // and the lifecycle refuses every reload over it: the guard stays, LKG
    // does not move, and the result names the restart it needs (UC-019).
    let guarded = target != "stopped" && runtime_guard_settled();
    let holds = config_holds(content);
    if (target == "ran" && !guarded && (holds || apply_mode)) {
        if (!restore_guard(true)) result = { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
        else result = on_success();
    }
    else if (target == "ran" && (holds || apply_mode))
        result = { status: "needs_attention", reason: "runtime_guard_active", guard: "active" };
    else if (!holds) {
        let saved = save_concurrent_edit([ pre.snapshot.id, ...(keep || []) ]);
        // A reload that ran proved a coherent runtime, and a stopped runtime
        // has nothing a guard could protect (see above).
        if ((target != "ran" || guarded) && target != "stopped")
            result = { status: "needs_attention", reason: "config_changed_during_transaction", guard: "active", saved_snapshot: saved };
        else if (!restore_guard(true))
            result = { status: "needs_attention", reason: "guard_release_failed", guard: "active", saved_snapshot: saved };
        else {
            result = { status: "needs_attention", reason: "config_changed_during_transaction", guard: "inactive", saved_snapshot: saved };
            if (target == "stopped") result.runtime = "stopped";
        }
    }
    else if (target == "stopped" && on_stopped != null) {
        if (!restore_guard(true)) result = { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
        else result = on_stopped();
    }
    else if (!atomic(CONFIG, before))
        result = { status: "needs_attention", reason: "config_rollback_failed", guard: "active" };
    else {
        // No rollback reload over a kept guard: the lifecycle would refuse
        // it. The previous configuration waits in the file for the restart.
        let rollback = guarded ? "guarded" : reload(reason);
        if (rollback != "guarded" && rollback != "stopped" && runtime_guard_settled()) rollback = "guarded";
        if (rollback == "guarded")
            result = { status: "needs_attention", reason: "runtime_guard_active", guard: "active" };
        else if (rollback == "stopped") {
            if (!restore_guard(true)) result = { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
            else result = { status: "failed", reason: target == "invalid" ? "target_invalid" : "service_stopped",
                guard: "inactive", runtime: "stopped" };
        }
        else if (rollback != "ran")
            result = { status: "needs_attention", reason: rollback == "queued" ? "rollback_reload_queued" : "runtime_rollback_failed", guard: "active" };
        else if (!restore_guard(true)) result = { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
        else if (pre.snapshot.config_hash == lkg_hash() && !atomic(LKG, pre.snapshot.id + "\n"))
            result = { status: "needs_attention", reason: "lkg_update_failed", guard: "inactive" };
        else result = { status: "recovered", reason: target == "queued" ? "target_reload_queued" : "target_reload_failed", guard: "inactive" };
    }
    result.started = true;
    return result;
}
// Whether the rule an autotune apply changed (mutation: { section, option
// "nfqws_opt", to }) still runs the candidate's strategy in `content`: an
// enabled zapret rule whose nfqws_opt is the candidate's (whitespace as
// autotune/apply.uc normalizes it; its status reports the same as
// unverified_strategy). A configuration this reader cannot load might have
// it (fail closed).
function runs_strategy(content, mutation) {
    if (type(mutation) != "object" || type(mutation.section) != "string" || type(mutation.to) != "string") return false;
    let sections = uci_sections(content);
    if (sections == null) return true;
    let words = (v) => join(" ", filter(split(v, /[ \t\r\n]+/), (w) => w != ""));
    for (let s in sections) {
        if (s.type != "section" || s.name !== mutation.section) continue;
        let opt = {};
        for (let o in s.options) if (!o.list) opt[o.name] = o.value;
        let enabled = opt.enabled == null || index([ "1", "true", "yes", "on" ], lc(opt.enabled)) >= 0;
        return enabled && opt.action == "zapret" && opt.nfqws_opt != null && words(opt.nfqws_opt) == words(mutation.to);
    }
    return false;
}
// Why the configuration may not become last-known-working because of an
// autotune apply, or null. A start or a reload proves that a configuration
// runs, not that an autotune candidate works: a candidate is confirmed only
// by the apply that verified it in production (confirm-working autotune).
// Nothing else confirms while an apply is running, while its record cannot
// be read (it may hide an unresolved apply), or while a record that still
// waits for a decision names the configuration as its candidate: an
// interrupted or crashed verification, a failed one whose rollback did not
// finish (UC-020, UC-069). A configuration edited on top of a candidate
// that never passed its verification (one kept by the automatic rollback
// because it was edited during the check, UC-017) is no candidate any more,
// but while the rule still runs the candidate's strategy it carries what
// has not been, or has just failed to be, verified.
// An automatic apply that is observed after its verification is confirmed
// only by its observation once it passes (autotune/apply.uc confirm): until
// then, and when the observation ends without passing, a configuration that
// is its candidate or still runs the candidate's strategy is not confirmed
// by a start or reload either.
function autotune_objection(content) {
    if (fs.stat(AUTOTUNE_APPLY_STATE) == null) return null;
    let record = null;
    try { record = json(value(fs.readfile(AUTOTUNE_APPLY_STATE))); } catch (e) { record = null; }
    if (type(record) != "object" || type(record.phase) != "string") return "autotune_apply_unreadable";
    if (record.mutation == null) return null;
    let finished = index(AUTOTUNE_TERMINAL_PHASES, record.phase) >= 0;
    if (!finished && require("autotune.lock").held()) return "autotune_apply_in_progress";
    // A decided record objects to nothing: nothing more is read or parsed
    // (this runs in every start and reload).
    let undecided = !finished || record.phase == "needs_attention" || (record.phase == "failed" && record.rollback_available === true);
    if (!undecided) {
        if (record.phase != "applied" || record.lkg != AUTOTUNE_LKG_OBSERVATION) return null;
        let hash = sha(content);
        let candidate = hash != "" && (hash == record.candidate_hash ||
            (record.candidate_fingerprint != null && user_fingerprint(content) == record.candidate_fingerprint));
        return candidate || runs_strategy(content, record.mutation) ? "autotune_observation_pending" : null;
    }
    let hash = sha(content);
    let candidate = hash != "" && (hash == record.candidate_hash ||
        (record.candidate_fingerprint != null && user_fingerprint(content) == record.candidate_fingerprint));
    if (!candidate && record.applied !== true) candidate = runs_strategy(content, record.mutation);
    return candidate ? "autotune_apply_unresolved" : null;
}
// The configuration as service/lifecycle.uc external_config_fingerprint
// compares it: without the shutdown_correctly lines the service itself
// writes.
function config_fingerprint(content) {
    let lines = [];
    for (let line in split(content, "\n"))
        if (match(line, /^[ \t]*option[ \t]+shutdown_correctly([ \t]|$)/) == null)
            push(lines, line);
    return join("\n", lines);
}
// config/migration.uc, loaded when a snapshot may need it (D-16).
let migration_module = null;
function migrations() {
    if (migration_module == null)
        migration_module = require("config.migration");
    return migration_module;
}
// The migration state of a configuration read as libuci loads it
// (uci_sections), as config/migration.uc reads it: the options of the
// section named settings.
function sections_schema(sections) {
    let result = { config_version: "", applied_migrations: [] };
    for (let s in sections) {
        if (s.name !== "settings") continue;
        for (let o in s.options) {
            if (o.name == "config_version")
                result.config_version = o.list ? join(" ", o.value) : o.value;
            else if (o.name == "applied_migrations")
                result.applied_migrations = o.list ? o.value : filter(split(trim(o.value), " "), (id) => id != "");
        }
    }
    return result;
}
// Whether a configuration with `schema` lacks a migration of this release
// that `reference` records, or has an older config_version that the
// migrations raise. A migration unknown to this release (one of a newer
// release after a downgrade, or mirror_infotechtg_ru_v1, which only the
// package's mirror-migration.sh records) is none a restore could run, nor
// is a config_version a newer release wrote: after a downgrade the
// configuration keeps it, and a snapshot of this release has the one this
// release writes.
function schema_behind(schema, reference) {
    let missing = filter(reference.applied_migrations, (id) => index(schema.applied_migrations, id) < 0);
    // The common case, an equal state, needs no migration module.
    if (!length(missing) && schema.config_version == reference.config_version) return false;
    let ids = migrations().migration_ids();
    for (let id in missing)
        if (index(ids, id) >= 0) return true;
    return migrations().raises_config_version(schema.config_version) &&
        migrations().compare_versions(schema.config_version, reference.config_version) < 0;
}
// The sections of a configuration as a uci cursor returns them, for
// config/migration.uc. libuci names an anonymous section when it adds it
// while loading the file, before its options: cfg, its place among the
// sections the file adds (%02x), then the djb hash of its type cut to 16
// bits (%04x) (libuci list.c uci_fixup_section). The type is printable
// ASCII, so the name is the same on every platform; a URLTest group that
// urltest_section_names_v1 names keeps it, and its dashboard overrides
// follow.
function loaded_sections(sections) {
    let result = [];
    for (let i = 0; i < length(sections); i++) {
        let s = sections[i], hash = 5381;
        for (let c = 0; c < length(s.type); c++)
            hash = (hash * 33 + ord(s.type, c)) & 0xFFFFFFFF;
        let section = { ".anonymous": s.name == null, ".type": s.type,
            ".name": s.name ?? sprintf("cfg%02x%04x", i + 1, hash & 0xFFFF) };
        for (let o in s.options)
            section[o.name] = o.list ? [ ...o.value ] : o.value;
        push(result, section);
    }
    return result;
}
// Sections from config/migration.uc in the shape uci_sections reads: an
// anonymous section (one the file had and no migration named, or one a
// migration added) has no name, an empty value is no option (libuci deletes
// an option set to it), a list keeps its order.
function exported_sections(sections, created) {
    let result = [];
    for (let section in sections) {
        let anonymous = section[".anonymous"] === true || created[section[".name"]] === true;
        let shaped = { name: anonymous ? null : value(section[".name"]), type: value(section[".type"]), options: [] };
        for (let key, v in section) {
            if (substr(key, 0, 1) == ".") continue;
            if (type(v) == "array") {
                if (length(v)) push(shaped.options, { name: key, list: true, value: map(v, (item) => value(item)) });
            }
            else if (value(v) != "")
                push(shaped.options, { name: key, list: false, value: value(v) });
        }
        push(result, shaped);
    }
    return result;
}
// Sections as a uci commit writes them (libuci file.c uci_export_package).
// Comments and the file's own layout go, as after any commit through libuci,
// the package's migration included.
function uci_export(sections) {
    let escape = (v) => replace(v, /'/g, "'\\''");
    let text = "";
    for (let s in sections) {
        text += "\nconfig " + escape(s.type) + (s.name == null ? "" : " '" + escape(s.name) + "'") + "\n";
        for (let o in s.options)
            for (let v in (o.list ? o.value : [ o.value ]))
                text += "\t" + (o.list ? "list " : "option ") + escape(o.name) + " '" + escape(v) + "'\n";
    }
    return text + "\n";
}
// The configuration a restore writes for `target` (D-16 (a), UC-065). A
// restore must not take the configuration back behind the migrations of
// the release that runs: config/migration.uc runs only in the package
// scripts, so a snapshot an older release saved would bring back what they
// retired (the old mirror, removed rule sets) and roll applied_migrations
// back, and nothing would migrate it until the next upgrade. The package
// migrated the configuration being replaced: a snapshot that lacks one of
// the migrations it records, or has an older config_version that they
// raise, is migrated the same way, on a copy in memory (config/migration.uc
// migrate_sections); when the configuration being replaced cannot be read,
// to every migration of this release. The source snapshot is never written.
// A snapshot of the same state (or of a newer release after a downgrade,
// which no migration takes back) is restored as it is, byte for byte.
//
// Only what migrate changes in the configuration runs. The runtime caches
// it resets and the package feeds mirror-migration.sh rewrites (other
// packages) belong to the installed package, which already brought them to
// this release; the restore leaves them alone.
//
// The kill-switch follows the restored configuration like any other
// change: the restore's reload syncs it, and a reload that a stop skips
// (D-15) still lifts a protection that no section of the restored
// configuration has (killswitch/runtime.uc follow-stopped-config). The
// global VPN guard of a snapshot from before the kill-switch
// (vpn_fail_closed) becomes the per-section kill-switch here, as on an
// upgrade, instead of a retired option that would silently drop it.
//
// Fail closed: a snapshot to migrate that cannot be read as libuci loads
// it, has no settings section, makes a migration fail, or still lacks a
// migration the configuration being replaced records (the Clash API secret
// when neither has one and no random source exists), or whose migrated copy
// would not load back the same, is refused before anything changes:
// { status "failed", reason "snapshot_migration_failed", detail }. Otherwise
// { content, migration }: migration names the release that saved the
// snapshot, this one and the migrations that ran, or is null.
function restore_content(target, before) {
    let versions = () => ({ from: metadata(target).prokop_version, to: prokop_version() });
    let refused = (detail) => ({ status: "failed", reason: "snapshot_migration_failed", detail, migration: versions() });
    let as_is = { content: target.content, migration: null };
    // Most restores need none (a snapshot of this release, the rollback of
    // an autotune apply). The quick reader tells, as it tells the list: such
    // a snapshot is restored as it is, without reading either configuration
    // in full (seconds for a big one on a router), so also one that libuci
    // loads and the full reader does not follow (see uci_statements).
    let quick = settings_schema(before);
    if ((length(quick.applied_migrations) || quick.config_version != "") &&
        !schema_behind(settings_schema(target.content), quick))
        return as_is;
    // A migration runs on the configurations as libuci loads them, which
    // decide again; a snapshot that the full reader cannot follow is
    // refused then.
    let live = uci_sections(before);
    let reference = live != null ? sections_schema(live) :
        { config_version: "", applied_migrations: migrations().migration_ids() };
    if (!length(reference.applied_migrations) && reference.config_version == "")
        return as_is;
    let sections = uci_sections(target.content);
    if (sections == null) return refused("unreadable");
    let schema = sections_schema(sections);
    if (!schema_behind(schema, reference))
        return as_is;
    // D-1: the secret of the configuration being replaced, for a snapshot
    // from before the secret (migrate_sections).
    let active = "";
    for (let s in live ?? [])
        if (s.name === "settings")
            for (let o in s.options)
                if (o.name == "yacd_secret_key" && !o.list) active = o.value;
    let migrated = null;
    try {
        migrated = migrations().migrate_sections(loaded_sections(sections), active);
    }
    catch (e) {
        return refused("migration_error");
    }
    if (migrated == null) return refused("no_settings");
    let shaped = exported_sections(migrated.sections, migrated.created_anonymous);
    let content = uci_export(shaped);
    let loaded = uci_sections(content);
    if (loaded == null || sprintf("%J", loaded) != sprintf("%J", shaped) || length(content) > MAX_CONFIG)
        return refused("export_failed");
    let result = sections_schema(loaded);
    if (schema_behind(result, reference)) return refused("incomplete");
    let migration = versions();
    migration.migrations = filter(result.applied_migrations, (id) => index(schema.applied_migrations, id) < 0);
    return { content, migration, notices: migrated.notices ?? [] };
}
// expected (optional): the hash, or the user fingerprint, of the
// configuration the caller means to replace. The automatic rollback of
// autotune passes its candidate's: a configuration edited since (during the
// verification) is not the caller's to replace. It is kept, saved as a
// snapshot, and the answer is needs_attention before anything changes
// (UC-017).
function do_restore(id, expected) {
    if (expected != "" && !valid_hash(expected)) return { status: "failed", reason: "invalid_expected_hash" };
    let target = read_snapshot(id, true);
    if (target == null) return { status: "failed", reason: "invalid_snapshot" };
    let before = read_config();
    if (before == null) return { status: "failed", reason: "config_unavailable" };
    if (expected != "" && sha(before) != expected && user_fingerprint(before) != expected)
        return { status: "needs_attention", reason: "config_changed_during_transaction", saved_snapshot: save_concurrent_edit([ id ]) };
    // Refused before anything changes: staged changes would ride along, the
    // reload would only be queued behind a live lifecycle action, or the
    // lifecycle would refuse it over a guard a failed transition kept (a
    // restart removes that guard; UC-019).
    if (staged_changes()) return { status: "failed", reason: "uncommitted_uci_changes" };
    let action = service_action();
    if (action != null) return { status: "busy", reason: action };
    // A guard seen as a lifecycle action takes the lock may be its own.
    if (runtime_guard_kept())
        return service_action() != null ? { status: "busy", reason: "service_action_in_progress" } :
            { status: "failed", reason: "runtime_guard_active" };
    // A snapshot of an older release is migrated on a copy; one that cannot
    // be is refused here, before anything changes (D-16, UC-065). The copy
    // is what the transaction validates, reloads and checks.
    let restored = restore_content(target, before);
    if (restored.status != null) return restored;
    let content = restored.content, migration = restored.migration;
    let pre = create("automatic", "pre-restore", false, [ id ]);
    if (pre.status != "created") return { status: "failed", reason: "pre_restore_snapshot_failed" };
    if (sha(before) != sha(read_config())) return { status: "failed", reason: "concurrent_change" };
    let result = guarded_replace(before, content, pre, () => {
        // Last-known-working names the configuration the reload proved. A
        // migrated copy is not the source snapshot, which stays as it was:
        // a snapshot of the copy is taken (or found) for it, of the copy
        // itself: an edit committed since the check (while the guard was
        // released) is in the file, and no reload proved it.
        let working = id;
        if (migration != null)
            working = create("automatic", "last-known-working", true, [ id, pre.snapshot.id ], content).snapshot?.id;
        if (working == null || !atomic(LKG, working + "\n"))
            return { status: "needs_attention", reason: "lkg_update_failed", guard: "inactive" };
        return { status: "success", snapshot: metadata(target), changes: diff(before, content) };
    }, "config-restore", false, () => ({
        // Replaced and validated; no runtime proved it, so LKG stays.
        status: "restored_not_started", reason: "service_stopped", guard: "inactive",
        snapshot: metadata(target), changes: diff(before, content)
    }), [ id ]);
    if (migration != null) result.migration = migration;
    // What the migrations of the copy changed that the user should know
    // about (retired rule sets, a raised update interval, subscription
    // options removed: D-13 (b), D-18 (a), D-17 (a)), as a package upgrade
    // reports it (config/migration.uc report_notices): only once the copy is
    // in place, not after the previous configuration was put back.
    if (migration != null && length(restored.notices) > 0 && result.started && config_holds(content))
        result.notices = restored.notices;
    return result;
}
// Apply a candidate configuration prepared elsewhere (DPI autotune stage 5)
// through the same transaction as a restore. The current configuration must
// still be the one the candidate was derived from (expected_hash), and it is
// saved first as a "before-autotune" snapshot for the caller's rollback. LKG
// is left untouched on success: the caller confirms it after its own checks.
function do_apply(candidate_file, expected_hash, keep_id) {
    let keep = valid_id(value(keep_id)) ? [ value(keep_id) ] : [];
    let content = fs.readfile(value(candidate_file));
    if (content == null || length(content) > MAX_CONFIG) return { status: "failed", reason: "candidate_unavailable" };
    let before = read_config();
    if (before == null) return { status: "failed", reason: "config_unavailable" };
    if (sha(before) != value(expected_hash)) return { status: "stale", reason: "config_changed" };
    if (content == before) return { status: "no_change", reason: "candidate_equals_config" };
    // An apply never changes a runtime that an explicit stop holds down:
    // nothing could verify the candidate (D-15, UC-056). One not started
    // since boot is refused by the caller (autotune/apply.uc); here its
    // reload answers "stopped" and the candidate is put back.
    if (fs.stat(STOP_REQUESTED) != null) return { status: "stale", reason: "service_stopped" };
    // A queued reload without a live owner is no refusal, as for a restore:
    // the transaction's own reload drains it while the guard stands.
    let action = service_action();
    if (action != null) return { status: "stale", reason: action };
    if (runtime_guard_kept())
        return { status: "stale", reason: service_action() ?? "runtime_guard_active" };
    // Retention never refuses the before-autotune snapshot, nor the
    // pre-restore snapshot of the rollback, which keeps it; the confirmation
    // of the candidate keeps it too (confirm-working autotune <id>), and so
    // does every automatic snapshot while the apply record may still roll
    // back to it (trim_retention), so manual snapshots never stand in the
    // way of an apply or its rollback (D-14, UC-022).
    let pre = create("automatic", "before-autotune", false, keep);
    if (pre.status != "created") return { status: "failed", reason: "pre_apply_snapshot_failed" };
    if (sha(before) != sha(read_config())) return { status: "failed", reason: "concurrent_change", pre_snapshot: pre.snapshot.id };
    let result = guarded_replace(before, content, pre, () => ({ status: "success", changes: diff(before, content) }), "autotune", true, null, keep);
    result.pre_snapshot = pre.snapshot.id;
    return result;
}
let mode = value(ARGV[0]);
// The list is read-only output: the hash of the whole config (secrets
// included) stays internal (UC-150). D-16 (b): a snapshot that a restore
// migrates says from which release to this one (restore_content decides
// the same from the configurations as libuci loads them).
if (mode == "list") {
    let result = fs.stat(ROOT) == null ? [] : list_snapshots(true);
    let live = settings_schema(read_config()), current = null;
    let working = trim(value(fs.readfile(LKG)));
    for (let item in result) {
        let reason = protected_reason(item.id, working, item.reason, item.created_at);
        if (reason != null) item.protected_reason = reason;
        if (schema_behind(item.schema, live)) {
            if (current == null) current = prokop_version();
            item.migration = { from: item.prokop_version, to: current };
        }
        delete item.schema;
        delete item.config_hash;
    }
    print(sprintf("%J\n", result));
    exit(0);
}
if (mode == "diff") {
    let item = read_snapshot(value(ARGV[1]), true);
    let current = read_config();
    if (item == null || current == null) exit(1);
    print(sprintf("%J\n", diff(item.content, current)));
    exit(0);
}
if (mode == "fixture-diff") {
    print(sprintf("%J\n", diff(value(fs.readfile(ARGV[1])), value(fs.readfile(ARGV[2])))));
    exit(0);
}
if (index(OPERATIONS, mode) < 0) exit(1);
// Clear and the limits wait for an autotune run or apply: the verification
// of an apply takes any snapshot operation meanwhile for a failure and rolls
// a good candidate back (autotune/apply.uc no_snapshot_operation).
if ((mode == "clear" || mode == "retention") && require("autotune.lock").held()) {
    print(sprintf("%J\n", { status: "busy", reason: "autotune_in_progress" }));
    exit(1);
}
if (!acquire()) {
    print(sprintf("%J\n", lock_busy ?
        { status: "busy", reason: "snapshot_operation_in_progress" } :
        { status: "failed", reason: "lock_unavailable" }));
    exit(1);
}
let answer = { status: "failed" };
if (mode == "create") {
    // automatic: the lifecycle's snapshot at the start of a reload, taken
    // after the change was committed, so it holds the configuration the
    // reload applies (the reason keeps its old name for the snapshots
    // already stored). before-apply: Save & Apply's snapshot of the
    // configuration before LuCI applies the change (UC-064, UC-067).
    // The reload's snapshot ends the keep of the Save & Apply snapshot
    // (trim_retention), taken or not.
    let kind = value(ARGV[1] || "manual");
    if (index([ "manual", "automatic", "before-apply" ], kind) < 0)
        answer = { status: "failed", reason: "invalid_input" };
    else if (index([ "manual", "automatic" ], kind) >= 0)
        answer = create(kind, kind == "manual" ? "manual" : "before-reload", kind == "automatic");
    else if (kind == "before-apply") {
        answer = create("automatic", "before-apply", true);
        let id = answer.snapshot?.id;
        if (id != null && trim(value(fs.readfile(APPLY_SNAPSHOT))) != id) atomic(APPLY_SNAPSHOT, id + "\n");
    }
    if (kind == "automatic" && fs.stat(APPLY_SNAPSHOT) != null) fs.unlink(APPLY_SNAPSHOT);
    // Automatic snapshots are routine; only a manual one is a history event.
    if (kind == "manual" && answer.status == "created")
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "snapshot_create", "success" ]);
}
else if (mode == "delete") {
    // A refusal says why (UC-119); a protected snapshot (protected_reason)
    // is never deleted.
    let id = value(ARGV[1]);
    if (!valid_id(id)) answer = { status: "failed", reason: "invalid_input" };
    else if (read_snapshot(id, true) == null) answer = { status: "failed", reason: "invalid_snapshot" };
    else if (protected_reason(id, trim(value(fs.readfile(LKG))), metadata(read_snapshot(id, false)).reason,
        metadata(read_snapshot(id, false)).created_at) != null)
        answer = { status: "failed", reason: protected_reason(id, trim(value(fs.readfile(LKG))),
            metadata(read_snapshot(id, false)).reason, metadata(read_snapshot(id, false)).created_at) };
    else if (!fs.unlink(snapshot_path(id))) answer = { status: "failed", reason: "delete_failed" };
    else {
        answer = { status: "deleted" };
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "snapshot_delete", "success" ]);
    }
}
else if (mode == "restore") {
    // "autotune": the rollback of an autotune apply, which autotune/apply.uc
    // records itself as autotune_rollback once it has proven the old
    // strategy again, never as a restore (UC-060).
    let rollback = value(ARGV[3]) == "autotune";
    answer = do_restore(value(ARGV[1]), value(ARGV[2]));
    // The notices of a migrated copy now in place, as after a package
    // upgrade: the History page names what the migrations changed. Before
    // the restore event, which stays the last change.
    if (type(answer.notices) == "array")
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "config_migration", "success",
            "", "", sprintf("%J", { notices: answer.notices }) ]);
    // Health records a restore only when its transaction started, as for an
    // apply: a refusal before it (busy, staged uci changes, a kept runtime
    // guard, a missing snapshot, no pre-restore snapshot) changed nothing
    // and is no recovery that failed (UC-022). One that left its own guard
    // behind did change the runtime (guarded_replace).
    // A restore that an explicit stop kept from starting the runtime is no
    // success: nothing verified it.
    if (answer.started && !rollback)
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "restore",
            answer.status == "success" ? "success" : answer.status == "recovered" ? "recovered" :
            answer.status == "restored_not_started" ? "not_started" : "failure" ]);
}
else if (mode == "apply") {
    // No event here: this is the transaction of an autotune apply, whose
    // outcome is known only after its production verification. The manager
    // records the apply once, with that outcome (UC-060).
    answer = do_apply(ARGV[1], ARGV[2], ARGV[3]);
}
else if (mode == "clear") {
    // "Clear" on the History page (clear_snapshots): a history event when
    // anything went.
    answer = clear_snapshots();
    if (answer.removed > 0)
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "snapshot_clear",
            answer.status == "cleared" ? "success" : "failure" ]);
}
else if (mode == "retention") {
    // The limits of the History page (config/retention.uc): the history
    // journal and the snapshot store shrink to them at once. A lowered
    // snapshot limit removes only what retention may remove (removable):
    // manual and protected snapshots stay, and the store holds more until
    // they go. Under the snapshot lock, so no other snapshot operation runs
    // meanwhile.
    let history = retention.parse(ARGV[1], retention.HISTORY);
    let snapshots = retention.parse(ARGV[2], retention.SNAPSHOTS);
    if (history == null || snapshots == null)
        answer = { status: "failed", reason: "invalid_input",
            history: retention.HISTORY, snapshots: retention.SNAPSHOTS };
    else if (!retention.save(history, snapshots))
        answer = { status: "failed", reason: "write_failed" };
    else {
        let journal = {};
        try {
            journal = json(capture([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "prune" ]));
        }
        catch (e) {}
        answer = { status: "saved", history_limit: history, snapshot_limit: snapshots,
            removed_snapshots: trim_retention([], true, false),
            removed_events: type(journal) == "object" && type(journal.removed) == "int" ? journal.removed : 0 };
        if (type(journal) != "object" || journal.status != "pruned") answer.history_pruned = false;
    }
}
else if (mode == "confirm-working") {
    // A start or reload of the lifecycle; "autotune": the apply that has
    // just verified its candidate in production, with the id of its
    // before-autotune snapshot, which this snapshot may not push out: the
    // rollback returns to it.
    // "lifecycle": the start or reload, with the path of its proof, the
    // configuration it ran (service/lifecycle.uc external_config_fingerprint).
    // The configuration is read once, here under the lock: what is
    // snapshotted is exactly what was compared, so an edit saved after the
    // start or reload checked its configuration never becomes
    // last-known-working (CFG-1). Without an argument (by hand) the
    // configuration read is confirmed as it is.
    let content = read_config();
    let lifecycle = value(ARGV[1]) == "lifecycle";
    let proof = lifecycle ? fs.readfile(value(ARGV[2])) : null;
    let objection = null;
    if (lifecycle && proof == null) objection = "proof_unavailable";
    else if (lifecycle && content != null && config_fingerprint(content) != proof) objection = "config_changed";
    else if (content != null && value(ARGV[1]) != "autotune") objection = autotune_objection(content);
    if (objection != null) answer = { status: "not_confirmed", reason: objection };
    else {
        let keep = value(ARGV[1]) == "autotune" && valid_id(value(ARGV[2])) ? [ value(ARGV[2]) ] : [];
        let found = create("automatic", "last-known-working", true, keep, content);
        if (found.snapshot != null &&
            (trim(value(fs.readfile(LKG))) == found.snapshot.id || atomic(LKG, found.snapshot.id + "\n")))
            answer = { status: "confirmed" };
    }
}
release();
print(sprintf("%J\n", answer));
exit(index([ "failed", "needs_attention", "busy", "not_confirmed" ], answer.status) >= 0 ? 1 : 0);
