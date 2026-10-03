#!/usr/bin/env ucode

// Persistent autotune state (flash) and the last full tune outputs (tmpfs).
//
// /etc/prokop/autotune/state.json — survives reboots, written atomically
// (temporary file + rename) and only when its content changed, at most once
// per worker run:
//   { version, targets: { <id>: summary }, groups: { <section>: group },
//     applies: [ records ], next_run_at, rotation, worker, recovered_at }
// A state file that exists but cannot be trusted (corrupt, foreign version)
// reads as an empty state marked recovered_from; the next write keeps the
// bad file as state.json.corrupt and records recovered_at, after which
// autonomous applies wait out a cooldown (the lost state held the budget
// and the cooldowns).
// A target summary keeps what the UI and hysteresis need: status, reason,
// selected candidate, confidence and per-candidate stability, success ratio,
// median TLS time and failure classes — never raw strategies of the user's
// rules (only catalog candidate ids).
//
// /var/run/prokop/autotune/last/<id>.json — the complete tune output of the
// last run of a target, for technical details; gone after a reboot.
let fs = require("fs");

const STATE_FILE = getenv("PROKOP_AUTOTUNE_STATE_FILE") || "/etc/prokop/autotune/state.json";
const LAST_DIR = getenv("PROKOP_AUTOTUNE_LAST_DIR") || "/var/run/prokop/autotune/last";
const VERSION = 1;
const MAX_APPLY_RECORDS = 20;

function as_string(v) { return v == null ? "" : "" + v; }
function object_or_empty(v) { return type(v) == "object" ? v : {}; }

function empty() {
    return { version: VERSION, targets: {}, groups: {}, applies: [], next_run_at: null, rotation: 0, worker: null,
        recovered_at: null };
}

function valid_id(id) {
    return match(as_string(id), /^[A-Za-z0-9_]{1,64}$/) != null;
}

function mkdir_p(dir, mode) {
    if (dir == "" || fs.stat(dir) != null) return true;
    if (!mkdir_p(fs.dirname(dir), 0755)) return false;
    return fs.mkdir(dir, mode) || fs.stat(dir) != null;
}

// A missing, unreadable or foreign state is an empty state: autotune then
// simply measures again; it never acts on data it cannot trust.
function read() {
    let data = fs.readfile(STATE_FILE), parsed = null;
    try { parsed = data == null ? null : json(data); } catch (e) { parsed = null; }
    if (type(parsed) != "object" || parsed.version != VERSION) {
        let state = empty();
        if (data != null) state.recovered_from = type(parsed) == "object" ? "unsupported_version" : "corrupt";
        return state;
    }
    let state = empty();
    for (let key, value in object_or_empty(parsed.targets)) if (valid_id(key) && type(value) == "object") state.targets[key] = value;
    for (let key, value in object_or_empty(parsed.groups)) if (valid_id(key) && type(value) == "object") state.groups[key] = value;
    state.applies = filter(type(parsed.applies) == "array" ? parsed.applies : [], (a) => type(a) == "object");
    state.next_run_at = type(parsed.next_run_at) == "int" ? parsed.next_run_at : null;
    state.rotation = type(parsed.rotation) == "int" && parsed.rotation >= 0 ? parsed.rotation : 0;
    state.worker = type(parsed.worker) == "object" ? parsed.worker : null;
    state.recovered_at = type(parsed.recovered_at) == "int" ? parsed.recovered_at : null;
    return state;
}

function write_atomic(path, text, mode) {
    if (!mkdir_p(fs.dirname(path), 0700)) return false;
    let tmp = path + ".tmp." + as_string(fs.readlink("/proc/self"));
    if (fs.writefile(tmp, text) == null) { fs.unlink(tmp); return false; }
    fs.chmod(tmp, mode);
    if (!fs.rename(tmp, path)) { fs.unlink(tmp); return false; }
    return true;
}

// Flash is written only when the content changed.
function write(state) {
    if (state.recovered_from != null) {
        // The untrusted file is kept for inspection, never parsed again.
        fs.rename(STATE_FILE, STATE_FILE + ".corrupt");
        if (state.recovered_at == null) state.recovered_at = time();
        delete state.recovered_from;
    }
    state.applies = slice(state.applies || [], -MAX_APPLY_RECORDS);
    let text = sprintf("%J\n", state);
    if (fs.readfile(STATE_FILE) == text) return true;
    return write_atomic(STATE_FILE, text, 0600);
}

function round3(value) {
    return value == null ? null : int(value * 1000 + 0.5) / 1000.0;
}

// The part of a tune output (autotune/isolation.uc tune) worth keeping.
function summarize(result, now) {
    result = object_or_empty(result);
    let target = object_or_empty(result.target);
    return {
        at: now,
        status: as_string(result.status) || "failed",
        reason: result.reason || null,
        selected: result.selected || null,
        confidence: result.confidence || null,
        leading: result.leading || null,
        ip: target.ip || null,
        candidates: map(type(result.candidates) == "array" ? result.candidates : [], (c) => ({
            id: c.id, stability: c.stability, success: c.success, attempted: c.attempted,
            success_ratio: round3(c.success_ratio), median_tls_ms: c.median_tls_ms,
            failure_classes: type(c.failure_classes) == "array" ? c.failure_classes : []
        }))
    };
}

function last_path(id) { return LAST_DIR + "/" + id + ".json"; }

function save_full(id, result) {
    if (!valid_id(id)) return false;
    return write_atomic(last_path(id), sprintf("%J\n", result), 0600);
}

function load_full(id) {
    if (!valid_id(id)) return null;
    let data = fs.readfile(last_path(id));
    try { return data == null ? null : json(data); } catch (e) { return null; }
}

// Record the tune of one target: summary into the state (the caller writes
// it), full output into tmpfs.
function record_tune(state, id, result, context, now) {
    if (!valid_id(id)) return null;
    let summary = summarize(result, now);
    context = object_or_empty(context);
    summary.host = context.host || null;
    summary.group = context.group || null;
    summary.fingerprint = context.fingerprint || null;
    state.targets[id] = summary;
    save_full(id, result);
    return summary;
}

// Forget targets and groups the policy no longer has.
function prune(state, target_ids, group_ids) {
    for (let id in keys(state.targets)) if (index(target_ids, id) < 0) delete state.targets[id];
    if (group_ids != null)
        for (let id in keys(state.groups)) if (index(group_ids, id) < 0) delete state.groups[id];
    return state;
}

return { VERSION, STATE_FILE, LAST_DIR, empty, read, write, summarize, record_tune, save_full, load_full, prune, valid_id };
