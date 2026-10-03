#!/usr/bin/env ucode

// The single DPI autotune lock. Probing/tuning (autotune/isolation.uc) and
// production application (autotune/apply.uc) exclude each other: an apply
// reloads Prokop and must never overlap a temporary probe path, and a probe
// must never measure a runtime that an apply is replacing. Snapshot
// operations keep their own lock (config/snapshots.uc); apply takes both.
//
// Same owner-record scheme as the config snapshot lock: a directory holding
// one "owner.<pid>.<start ticks>" record, published by an atomic rename. A
// record only counts while a process with that start time still runs one of
// the owner commands:
//   ucode -L <lib> <lib>/autotune/isolation.uc ...
//   ucode -L <lib> <lib>/autotune/apply.uc ...
let fs = require("fs");
let identity = require("core.process_identity");

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const STATE_DIR = getenv("PROKOP_AUTOTUNE_STATE_DIR") || "/var/run/prokop/autotune";
const LOCK = STATE_DIR + "/lock";
const OWNER_SCRIPTS = [ "autotune/isolation.uc", "autotune/apply.uc" ];

let lock_record = null;
let lock_busy = false;

function as_string(v) { return v == null ? "" : "" + v; }

function owner_pid() {
    let pid = as_string(fs.readlink("/proc/self"));
    return match(pid, /^[1-9][0-9]*$/) != null ? pid : "";
}
function active_owner(name) {
    let parsed = match(as_string(name), /^owner\.([1-9][0-9]*)\.([0-9]+)$/);
    if (parsed == null) return false;
    for (let script in OWNER_SCRIPTS)
        if (identity.matches_record({ pid: parsed[1], ticks: parsed[2] }, "ucode",
            [ "ucode", "-L", LIB_DIR, LIB_DIR + "/" + script ], false, true) != "")
            return true;
    return false;
}
function remove_dir(dir) {
    for (let name in fs.lsdir(dir) || []) fs.unlink(dir + "/" + name);
    return fs.rmdir(dir);
}
function ensure_state_dir() {
    let parent = fs.dirname(STATE_DIR);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return false;
    if (fs.stat(STATE_DIR) == null && !fs.mkdir(STATE_DIR, 0700)) return false;
    return fs.chmod(STATE_DIR, 0700);
}
function acquire() {
    if (!ensure_state_dir()) return false;
    let pid = owner_pid(), ticks = identity.start_ticks(pid);
    if (ticks == "") return false;
    let name = "owner." + pid + "." + ticks;
    let pending = LOCK + ".new." + pid + "." + ticks;
    remove_dir(pending);
    if (!fs.mkdir(pending, 0700) || !identity.record(pending + "/" + name, pid) || !active_owner(name)) {
        remove_dir(pending);
        return false;
    }
    for (let attempt = 0; attempt < 3; attempt++) {
        if (fs.rename(pending, LOCK)) {
            lock_record = LOCK + "/" + name;
            return true;
        }
        let stat = fs.lstat(LOCK);
        let entries = stat != null && stat.type == "directory" ? fs.lsdir(LOCK) : null;
        if (entries == null) { fs.unlink(LOCK); continue; }
        let busy = false;
        for (let entry in entries) if (active_owner(entry)) busy = true;
        if (busy) { lock_busy = true; break; }
        for (let entry in entries)
            if (!fs.unlink(LOCK + "/" + entry)) fs.rmdir(LOCK + "/" + entry);
    }
    remove_dir(pending);
    return false;
}
function release() {
    if (lock_record == null) return;
    fs.unlink(lock_record);
    fs.rmdir(LOCK);
    lock_record = null;
    // Leave no runtime directory behind; fails harmlessly while not empty.
    fs.rmdir(STATE_DIR);
}
function busy() { return lock_busy; }
// Is any autotune operation holding the lock right now?
function held() {
    let entries = fs.lsdir(LOCK);
    if (entries == null) return false;
    for (let entry in entries) if (active_owner(entry)) return true;
    return false;
}

return { acquire, release, busy, held, owner_pid, STATE_DIR };
