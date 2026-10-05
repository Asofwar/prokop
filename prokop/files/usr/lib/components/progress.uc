// Progress of a component action the UI started as a background job
// (components/updates.uc component_action_async). The worker,
// components/action.uc, writes what it is doing to <job>.progress next to
// the job's state; component-action-status and get_ui_state hand it to the
// UI, and the finished job keeps the last one. Only what was observed: the
// stage the action entered and when, and the bytes of a download already on
// disk. There is no estimate of what is left.
let fs = require("fs");

const FORMAT = 1;
// The order the UI lists them in; an action passes through some of them.
const STAGES = [ "resolve", "lists", "download", "verify", "backup", "prepare", "stop", "install", "remove", "apply",
    "start", "restart", "check" ];
const MAX_STAGES = 32;
const MAX_LABEL = 120;

let path = "";
let value = null;

function as_string(v) {
    return v == null ? "" : "" + v;
}

function non_negative_int(v) {
    return type(v) == "int" && v >= 0 ? v : (type(v) == "double" && v >= 0 ? int(v) : null);
}

function stage_id(v) {
    v = as_string(v);
    return index(STAGES, v) >= 0 ? v : "";
}

function label_text(v) {
    v = replace(as_string(v), /[[:cntrl:]]/g, "");
    // A file name, never a URL: a mirror's address may carry credentials.
    if (index(v, "/") >= 0)
        v = split(v, "/")[-1];
    return length(v) > MAX_LABEL ? substr(v, 0, MAX_LABEL) : v;
}

function now_seconds() {
    return time();
}

function write() {
    if (path == "" || value == null)
        return false;
    value.updated_at = now_seconds();
    let stamp = clock();
    let tmp = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);
    if (fs.writefile(tmp, sprintf("%J\n", value)) == null) {
        fs.unlink(tmp);
        return false;
    }
    if (!fs.rename(tmp, path)) {
        fs.unlink(tmp);
        return false;
    }
    return true;
}

function active() {
    return path != "" && value != null;
}

function current() {
    return value != null ? value.stage : "";
}

// Enters STAGE; the stage before it ends now. Entering the current stage
// again changes nothing.
function stage(id) {
    id = stage_id(id);
    if (path == "" || value == null || id == "")
        return false;
    if (value.stage == id)
        return true;
    let now = now_seconds();
    let stages = value.stages;
    if (length(stages) > 0 && stages[-1].finished_at == null)
        stages[-1].finished_at = now;
    if (length(stages) >= MAX_STAGES)
        splice(stages, 0, 1);
    push(stages, { id, started_at: now, finished_at: null });
    value.stage = id;
    value.download = null;
    return write();
}

// The tracked job's progress file comes from the environment; any other run
// of the action (cron, the command line, a test) writes nothing.
function begin(progress_path, component, action, first_stage) {
    path = as_string(progress_path);
    if (path == "")
        return false;
    value = {
        format: FORMAT,
        component: as_string(component),
        action: as_string(action),
        stage: "",
        stages: [],
        download: null,
        outcome: "",
        started_at: now_seconds(),
        updated_at: null
    };
    return stage(first_stage);
}

// One file of the current download: its name, the bytes already on disk,
// the size the release publishes (0 when it publishes none), and which of
// COUNT files it is.
function download(label, bytes, total, number, count) {
    if (path == "" || value == null)
        return false;
    value.download = {
        file: label_text(label),
        bytes: non_negative_int(bytes) ?? 0,
        total: non_negative_int(total) ?? 0,
        index: non_negative_int(number) ?? 0,
        count: non_negative_int(count) ?? 0
    };
    return write();
}

function finish(ok) {
    if (path == "" || value == null || value.outcome != "")
        return false;
    let stages = value.stages;
    if (length(stages) > 0 && stages[-1].finished_at == null)
        stages[-1].finished_at = now_seconds();
    value.outcome = ok ? "done" : "failed";
    return write();
}

// What a reader passes on: known fields of the right type only.
function sanitize(raw) {
    if (type(raw) != "object" || raw.format != FORMAT)
        return null;
    let stages = [];
    for (let item in (type(raw.stages) == "array" ? raw.stages : [])) {
        if (type(item) != "object" || stage_id(item.id) == "" || non_negative_int(item.started_at) == null)
            continue;
        push(stages, {
            id: item.id,
            started_at: non_negative_int(item.started_at),
            finished_at: non_negative_int(item.finished_at)
        });
        if (length(stages) >= MAX_STAGES)
            break;
    }
    let result = {
        stage: stage_id(raw.stage),
        stages,
        download: null,
        outcome: index([ "done", "failed" ], raw.outcome) >= 0 ? raw.outcome : "",
        started_at: non_negative_int(raw.started_at),
        updated_at: non_negative_int(raw.updated_at)
    };
    if (type(raw.download) == "object")
        result.download = {
            file: label_text(raw.download.file),
            bytes: non_negative_int(raw.download.bytes) ?? 0,
            total: non_negative_int(raw.download.total) ?? 0,
            index: non_negative_int(raw.download.index) ?? 0,
            count: non_negative_int(raw.download.count) ?? 0
        };
    return result;
}

function read(file) {
    let data = fs.readfile(as_string(file));
    if (data == null)
        return null;
    try {
        return sanitize(json(data));
    }
    catch (e) {
        return null;
    }
}

return { FORMAT, STAGES, begin, active, stage, current, download, finish, sanitize, read };
