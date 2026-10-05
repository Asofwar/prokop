// How much of its own past Prokop keeps on flash: the newest records of the
// history journal (diagnostics/health.uc) and the configuration snapshots
// (config/snapshots.uc). The user sets both on the History page
// (config/snapshots.uc retention); they live outside the UCI configuration,
// so neither a snapshot restore nor Save & Apply changes them, and setting
// them needs no reload.
//
// A missing, unreadable or out-of-range value stands for its default: the
// file only ever narrows or widens what is kept within these bounds. Of the
// snapshots, RESERVED places are never taken by manual ones: they stay for
// the automatic safety snapshots (D-14, UC-022); the lower bound leaves room
// for manual snapshots next to them. The history bound keeps the journal
// well under its byte cap.

let fs = require("fs");
let durable = require("core.durable");

const FILE = getenv("PROKOP_RETENTION_FILE") || "/etc/prokop/retention.json";
const HISTORY = { min: 20, max: 200, default: 50 };
const SNAPSHOTS = { min: 6, max: 50, default: 20 };
const RESERVED = 2;

function within(v, range) {
    return type(v) == "int" && v >= range.min && v <= range.max;
}

// A decimal count as the CLI passes it, or null.
function parse(text, range) {
    let raw = "" + (text ?? "");
    if (match(raw, /^[0-9]{1,4}$/) == null) return null;
    let v = int(raw);
    return within(v, range) ? v : null;
}

function limits() {
    let stored = null;
    let raw = fs.readfile(FILE);
    if (raw != null && length(raw) <= 4096) {
        try { stored = json(raw); } catch (e) { stored = null; }
    }
    if (type(stored) != "object") stored = {};
    return {
        history: within(stored.history_limit, HISTORY) ? stored.history_limit : HISTORY.default,
        snapshots: within(stored.snapshot_limit, SNAPSHOTS) ? stored.snapshot_limit : SNAPSHOTS.default
    };
}

// Both values already passed parse(). Flushed like every other file Prokop
// keeps on flash (UC-025).
function save(history, snapshots) {
    if (!within(history, HISTORY) || !within(snapshots, SNAPSHOTS)) return false;
    let dir = fs.dirname(FILE);
    if (fs.stat(dir) == null && !fs.mkdir(dir, 0755)) return false;
    let tmp = FILE + "." + sprintf("%d.%d", clock()[0], clock()[1]) + ".tmp";
    return durable.durable_replace(tmp, FILE,
        sprintf("%J\n", { history_limit: history, snapshot_limit: snapshots }), 0644) == true;
}

return { FILE, HISTORY, SNAPSHOTS, RESERVED, parse, limits, save };
