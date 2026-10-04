// What a DPI provider supervisor keeps between respawns (OBS-3): the log it
// appends to stays bounded, a binary that keeps failing is restarted less
// and less often, and the number of restarts is kept for the status.
// Starts and stops of the providers poll for their processes instead of
// sleeping whole seconds per rule (opt. 11, 12).

let fs = require("fs");

// A log over the limit keeps its newest half. The provider appends to the
// same file through O_APPEND, so rewriting it in place loses nothing it
// writes afterwards.
const LOG_MAX_BYTES = int(getenv("PROKOP_PROVIDER_LOG_MAX_BYTES") || "262144");
// Delays double from the base up to the cap while the binary keeps dying;
// a run that lasted RESET_AFTER seconds starts the count over.
const DELAY_MAX_SECONDS = int(getenv("PROKOP_PROVIDER_RESPAWN_MAX_DELAY") || "300");
const RESET_AFTER_SECONDS = int(getenv("PROKOP_PROVIDER_RESPAWN_RESET_AFTER") || "300");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function trim_log(path, max_bytes) {
    path = as_string(path);
    max_bytes = int(max_bytes || LOG_MAX_BYTES);
    let stat = fs.stat(path);
    if (stat == null || stat.size <= max_bytes)
        return false;
    let file = fs.open(path, "r");
    if (!file)
        return false;
    let keep = int(max_bytes / 2);
    file.seek(stat.size - keep);
    let tail = file.read(keep);
    file.close();
    // Start at a line boundary.
    let newline = index(as_string(tail), "\n");
    if (newline >= 0)
        tail = substr(tail, newline + 1);
    return fs.writefile(path, "[log trimmed by Prokop]\n" + as_string(tail)) != null;
}

function next_delay(previous_delay, base_delay, lived_seconds) {
    let base = int(base_delay) > 0 ? int(base_delay) : 5;
    if (int(lived_seconds) >= RESET_AFTER_SECONDS || int(previous_delay) <= 0)
        return base;
    let delay = int(previous_delay) * 2;
    return delay > DELAY_MAX_SECONDS ? DELAY_MAX_SECONDS : delay;
}

function counter_path(log_path) {
    return replace(as_string(log_path), /\.log$/, "") + ".restarts";
}

function record_restart(log_path) {
    let path = counter_path(log_path);
    let count = int(trim(as_string(fs.readfile(path))) || "0") + 1;
    fs.writefile(path, count + "\n");
    return count;
}

// The restarts of every rule whose log is in `log_dir`.
function restart_count(log_dir) {
    let total = 0;
    let dir = fs.lsdir(as_string(log_dir));
    for (let name in (type(dir) == "array" ? dir : []))
        if (match(name, /\.restarts$/) != null)
            total += int(trim(as_string(fs.readfile(log_dir + "/" + name))) || "0");
    return total;
}

function monotonic_seconds() {
    let now = clock(true);
    return now[0] + now[1] / 1000000000.0;
}

// Calls `fn` every 0.1 s until it returns true or `seconds` have passed, and
// returns its last answer. BusyBox without fractional sleep falls back to
// whole seconds; the deadline is the monotonic clock either way.
function poll(fn, seconds) {
    let deadline = monotonic_seconds() + seconds;
    while (true) {
        if (fn())
            return true;
        if (monotonic_seconds() >= deadline)
            return false;
        system("sleep 0.1 2>/dev/null || sleep 1");
    }
}

// Waits out what is left of `seconds` since `since`.
function settle(since, seconds) {
    poll(() => false, since + seconds - monotonic_seconds());
}

return {
    LOG_MAX_BYTES,
    trim_log,
    next_delay,
    record_restart,
    restart_count,
    monotonic_seconds,
    poll,
    settle
};
