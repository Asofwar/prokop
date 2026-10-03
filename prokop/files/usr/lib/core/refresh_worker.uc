// The rule-set refresh workers: service/lifecycle.uc
// refresh-rulesets-after-start (after a start) and singbox/ruleset_cache.uc
// refresh-and-reload / refresh-if-due-and-reload (after a reload that changed
// rule sets, after a list update). They download for a while and then request
// a reload of the runtime. Each records itself in DIR for its run, under its
// pid (pid + start ticks, core/process_identity.uc), and an explicit stop
// terminates the recorded ones by that identity: their reload is not the
// next trigger after the stop, and their downloads end with it (UC-056).
//
// A record names a worker only while its process is that worker: a pid that
// a dead worker left there and another process now holds is neither
// signalled nor kept.
let fs = require("fs");
let identity = require("core.process_identity");

const DIR = getenv("PROKOP_RULESET_REFRESH_WORKER_DIR") ||
    (getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop") + "/ruleset-refresh-workers";

function own_pid() {
    let pid = "" + fs.readlink("/proc/self");
    return match(pid, /^[1-9][0-9]*$/) != null ? pid : "";
}

// The command lines the workers run under (the launchers: module_background
// in service/lifecycle.uc and components/updates.uc); extra arguments (the
// download proxy) follow.
function worker_argvs(lib_dir) {
    lib_dir = lib_dir == null ? "" : "" + lib_dir;
    let lifecycle = [ "ucode", "-L", lib_dir, lib_dir + "/service/lifecycle.uc" ];
    let ruleset_cache = [ "ucode", "-L", lib_dir, lib_dir + "/singbox/ruleset_cache.uc" ];
    return [
        [ ...lifecycle, "refresh-rulesets-after-start" ],
        [ ...ruleset_cache, "refresh-and-reload" ],
        [ ...ruleset_cache, "refresh-if-due-and-reload" ]
    ];
}

function register() {
    let pid = own_pid();
    if (pid == "")
        return false;
    let parent = fs.dirname(DIR);
    if (fs.stat(parent) == null)
        fs.mkdir(parent, 0755);
    if (fs.stat(DIR) == null)
        fs.mkdir(DIR, 0700);
    return identity.record(DIR + "/" + pid, pid);
}

function unregister() {
    let pid = own_pid();
    if (pid != "")
        fs.unlink(DIR + "/" + pid);
}

// TERM to every recorded worker of this installation; returns how many were
// signalled. Every record is removed (a record still being written is not
// one yet).
function stop_all(lib_dir) {
    let stopped = 0;
    for (let name in fs.lsdir(DIR) || []) {
        if (match(name, /^[1-9][0-9]*$/) == null)
            continue;
        let path = DIR + "/" + name;
        let saved = identity.read_record(path);
        for (let argv in worker_argvs(lib_dir)) {
            if (identity.signal_record(saved, "ucode", argv, false, "TERM")) {
                stopped++;
                break;
            }
        }
        fs.unlink(path);
    }
    return stopped;
}

return { DIR, register, unregister, stop_all };
