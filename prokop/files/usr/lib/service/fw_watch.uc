#!/usr/bin/env ucode

// NET-4: `/etc/init.d/firewall stop` and `restart` run `fw4 flush`, which
// deletes every nftables table, ProkopTable included. The kill-switch comes
// back with fw4 (its ruleset-post loader); ProkopTable did not, and routing
// stayed off until someone reloaded Prokop by hand.
//
// This watcher runs as its own procd service (/etc/init.d/prokop-fw-watch),
// whether or not the kill-switch is on. Every pass costs one stat of fw4's
// state file and no process: only when that file changed (a firewall start,
// reload or restart), or once a minute as a safety net, does it ask nft
// whether ProkopTable is there. When the table is gone while Prokop should
// run (started, not stopped by the user, no lifecycle action in progress),
// it reloads Prokop; the reload sees the incomplete runtime and restarts it
// (service/lifecycle.uc).
//
// Once an hour it also lets the per-device traffic accounting drop the
// addresses idle for a week (diagnostics/traffic.uc expire): their sets
// carry no kernel timeout, so that no packet rewrites an expiry.

let fs = require("fs");
let common = require("core.common");
let runtime_lock = require("core.runtime_lock");

function env(name, fallback) {
    let value = getenv(name);
    return value == null || value == "" ? fallback : value;
}

const FW4_STATE_FILE = env("PROKOP_FW4_STATE_FILE", "/var/run/fw4.state");
const RUNTIME_STATE_DIR = env("PROKOP_RUNTIME_STATE_DIR", "/var/run/prokop");
const SHUTDOWN_STATE_FILE = RUNTIME_STATE_DIR + "/shutdown_correctly";
const STOP_REQUESTED_FILE = env("PROKOP_STOP_REQUESTED_FILE", RUNTIME_STATE_DIR + "/stop.requested");
const RELOAD_LOCK_DIR = env("PROKOP_RELOAD_LOCK_DIR", "/var/run/prokop.reload.lock");
const SERVICE_INIT = env("PROKOP_SERVICE_INIT", "/etc/init.d/prokop");
const NFT_TABLE = env("PROKOP_NFT_TABLE", "ProkopTable");
const INTERVAL_MS = int(env("PROKOP_FW_WATCH_INTERVAL_MS", "2000"));
// Passes between table checks while the firewall did not change (60 s).
const SWEEP_PASSES = int(env("PROKOP_FW_WATCH_SWEEP_PASSES", "30"));
// Passes after a reload before the next one (30 s): a reload that cannot
// bring the table back must not run in a loop.
const BACKOFF_PASSES = int(env("PROKOP_FW_WATCH_BACKOFF_PASSES", "15"));
const ITERATIONS = int(env("PROKOP_FW_WATCH_ITERATIONS", "0"));
const LIB_DIR = env("PROKOP_LIB", "/usr/lib/prokop");
// Passes between runs of the traffic expiry (an hour), only while the
// accounting is set up (its state file is there).
const TRAFFIC_PASSES = int(env("PROKOP_FW_WATCH_TRAFFIC_PASSES", "1800"));
const TRAFFIC_STATE_FILE = RUNTIME_STATE_DIR + "/traffic.json";

function run_quiet(args) {
    return system(common.shell_command(args) + " >/dev/null 2>&1") == 0;
}

function log_message(message, level) {
    run_quiet([ "logger", "-t", "prokop", "[" + (level || "info") + "] " + message ]);
}

// What changes when fw4 writes its state file again.
function fw4_stamp() {
    let st = fs.stat(FW4_STATE_FILE);
    return st == null ? "absent" : sprintf("%d:%d:%d", st.mtime, st.inode, st.size);
}

// Started by Prokop's own start (service/lifecycle.uc records "0") and not
// stopped since, by the user or otherwise.
function prokop_should_run() {
    return common.as_string(fs.readfile(SHUTDOWN_STATE_FILE)) == "0\n" &&
        fs.stat(STOP_REQUESTED_FILE) == null;
}

function table_present() {
    return run_quiet([ "nft", "-t", "list", "table", "inet", NFT_TABLE ]);
}

// "reloaded", "present", "idle" (nothing to do now) or "failed".
function check(trigger) {
    if (!prokop_should_run() || runtime_lock.busy(RELOAD_LOCK_DIR))
        return "idle";
    if (table_present())
        return "present";
    log_message("Firewall: " + NFT_TABLE + " is gone (" + trigger + "); reloading Prokop", "warn");
    if (run_quiet([ SERVICE_INIT, "reload", "firewall" ]))
        return "reloaded";
    log_message("Firewall: the reload after " + NFT_TABLE + " was gone failed", "error");
    return "failed";
}

function watch() {
    let stamp = fw4_stamp();
    let since_check = 0;
    let backoff = 0;
    let orphaned = 0;
    let since_traffic = 0;
    for (let iteration = 1; ITERATIONS == 0 || iteration <= ITERATIONS; iteration++) {
        sleep(INTERVAL_MS);
        // A package upgrade replaces the script in place; only a script
        // missing for several passes means that the package is gone.
        if (fs.stat(SERVICE_INIT) == null) {
            if (++orphaned >= 5) {
                run_quiet([ "ubus", "call", "service", "delete", sprintf("%J", { name: "prokop-fw-watch" }) ]);
                return 0;
            }
            continue;
        }
        orphaned = 0;

        let current = fw4_stamp();
        let changed = current != stamp;
        stamp = current;
        since_check++;
        if (++since_traffic >= TRAFFIC_PASSES) {
            since_traffic = 0;
            if (fs.stat(TRAFFIC_STATE_FILE) != null)
                run_quiet([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/traffic.uc", "expire" ]);
        }
        if (backoff > 0) {
            backoff--;
            continue;
        }
        if (!changed && since_check < SWEEP_PASSES)
            continue;
        since_check = 0;
        let result = check(changed ? "firewall restarted" : "periodic check");
        if (result == "reloaded" || result == "failed")
            backoff = BACKOFF_PASSES;
    }
    return 0;
}

switch (ARGV[0]) {
case "watch":
    exit(watch());
case "check":
    print(check("manual check"), "\n");
    exit(0);
default:
    warn("usage: fw_watch.uc watch|check\n");
    exit(2);
}
