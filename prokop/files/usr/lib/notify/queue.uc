// Hands an event to the notification sender without waiting for it.
//
// Callers sit on paths that must never wait for the network or fail because
// of a notification: the history record of a reload, start, restore or
// autotune rollback (diagnostics/health.uc), a subscription update
// (subscription/cache.uc). enqueue() writes the event as a small file into
// the runtime queue and starts notify/manager.uc flush in the background;
// it returns at once and never throws. Nothing is written while
// notifications are off or the event's category is.
//
// The queue is bounded (QUEUE_MAX files); past it events are dropped, and
// the sender counts what it finds missing as nothing: a full queue means a
// sender that does not run, whose events would be stale anyway.

let fs = require("fs");
let common = require("core.common");
let notify_config = require("notify.config");

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const RUNTIME_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const NOTIFY_DIR = getenv("PROKOP_NOTIFY_DIR") || RUNTIME_DIR + "/notify";
const QUEUE_DIR = NOTIFY_DIR + "/queue";
const QUEUE_MAX = 64;
// Tests run the sender themselves.
const NO_FLUSH = getenv("PROKOP_NOTIFY_NO_FLUSH") == "1";

function ensure_dir(path) {
    if (fs.stat(path) == null)
        fs.mkdir(path, 0700);
    let st = fs.stat(path);
    return st != null && st.type == "directory" && fs.chmod(path, 0700);
}

function start_flush() {
    if (NO_FLUSH)
        return;
    system(common.shell_command([ "ucode", "-L", LIB_DIR, LIB_DIR + "/notify/manager.uc", "flush" ]) +
        " </dev/null >/dev/null 2>&1 &");
}

function math_random() {
    try {
        return require("math").rand() % 100000;
    }
    catch (e) {
        return 0;
    }
}

function write_event(event) {
    if (!ensure_dir(RUNTIME_DIR) || !ensure_dir(NOTIFY_DIR) || !ensure_dir(QUEUE_DIR))
        return false;
    if (length(fs.lsdir(QUEUE_DIR) || []) >= QUEUE_MAX)
        return false;
    let now = clock();
    let name = sprintf("%d.%09d.%d", now[0], now[1], math_random());
    let tmp = QUEUE_DIR + "/." + name + ".tmp";
    let file = fs.open(tmp, "wx", 0600);
    if (file == null)
        return false;
    let ok = file.write(sprintf("%J\n", event)) != null;
    file.close();
    if (!ok || !fs.rename(tmp, QUEUE_DIR + "/" + name + ".json")) {
        fs.unlink(tmp);
        return false;
    }
    return true;
}

// category: one of notify/config.uc CATEGORIES; event: { kind, ... }.
function enqueue(category, event) {
    try {
        if (!notify_config.wants(notify_config.read(), category))
            return false;
        event = common.object_or_empty(event);
        event.category = category;
        event.time = int(clock()[0]);
        if (!write_event(event))
            return false;
        start_flush();
        return true;
    }
    catch (e) {
        return false;
    }
}

return { enqueue, QUEUE_DIR, NOTIFY_DIR };
