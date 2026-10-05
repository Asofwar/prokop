// What TorrServer Direct (torrserver/direct.uc) reads of the running system:
// the TorrServer processes, their cgroup, whether the setting is on and
// whether its nft rule is in place. torrserver/manager.uc reads the same
// for the card in one pass over /proc (card-status), instead of a second
// process walking /proc again.

let fs = require("fs");
let uci = require("core.uci");

const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || "prokop";
const TABLE = "ProkopTorrServerDirect";
// Where processes and cgroups are read (tests point them at a fake tree).
const PROC_DIR = getenv("PROKOP_PROC_DIR") || "/proc";
const CGROUP_DIR = getenv("PROKOP_CGROUP_DIR") || "/sys/fs/cgroup";

function text(value) { return value == null ? "" : "" + value; }
function quote(value) { return "'" + replace(text(value), /'/g, "'\\''") + "'"; }
function command_output(args) {
    let values = [];
    for (let arg in args) push(values, quote(arg));
    let pipe = fs.popen(join(" ", values) + " 2>/dev/null", "r");
    if (!pipe) return "";
    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? text(data) : "";
}
function read(path) { let value = fs.readfile(path); return value == null ? "" : text(value); }

function is_torrserver_cmdline(value) {
    value = lc(replace(text(value), /\x00/g, " "));
    return match(value, /(^|[/ ])torrserver([^/ ]*)?( |$)/) != null;
}

// Every process, as { pid, cmdline }, in /proc's order; `each` is called
// with each one (the single pass both modules share).
function each_process(each) {
    for (let cmdline_path in fs.glob(PROC_DIR + "/[0-9]*/cmdline")) {
        let m = match(cmdline_path, /\/([0-9]+)\/cmdline$/);
        if (m != null)
            each(m[1], read(cmdline_path));
    }
}

function process_cgroup(pid) {
    for (let line in split(read(PROC_DIR + "/" + pid + "/cgroup"), "\n")) {
        let match_value = match(line, /^[0-9]+::(\/.+)$/);
        if (match_value != null) return match_value[1];
    }
    return "";
}
function valid_cgroup(path) {
    if (match(path, /^\/[A-Za-z0-9_.@:-]+(\/[A-Za-z0-9_.@:-]+)+$/) == null)
        return false;
    return path != "/services" && path != "/system.slice" && path != "/user.slice";
}
function dedicated_cgroup(path) {
    let pids = split(replace(read(CGROUP_DIR + path + "/cgroup.procs"), /[\r\n]+$/g, ""), /[\r\n]+/);
    let found = 0;
    for (let pid in pids) {
        if (pid == "") continue;
        found++;
        if (!is_torrserver_cmdline(read(PROC_DIR + "/" + pid + "/cmdline"))) return false;
    }
    return found > 0;
}

// The first TorrServer process of `pids` (TorrServer processes in /proc's
// order) and whether its cgroup is one Direct may mark.
function discover_from(pids) {
    for (let pid in pids) {
        let path = process_cgroup(pid);
        if (valid_cgroup(path) && dedicated_cgroup(path))
            return { running: 1, available: 1, pid, cgroup: path };
        return { running: 1, available: 0, pid, cgroup: path };
    }
    return { running: 0, available: 0, pid: "", cgroup: "" };
}
function discover() {
    let pids = [];
    each_process(function(pid, cmdline) {
        if (is_torrserver_cmdline(cmdline)) push(pids, pid);
    });
    return discover_from(pids);
}

// Read afresh on every check: the worker runs for days, and core.uci keeps a
// package loaded for the life of the process, so a snapshot restore or a
// `uci set` + commit would never reach it (UC-110).
function enabled() {
    uci.refresh(CONFIG_NAME);
    return trim(uci.get(CONFIG_NAME + ".settings.torrserver_direct_enabled")) == "1";
}

function rule_output_active(output, info) {
    if (!info.available) return false;
    let path = substr(info.cgroup, 1);
    let parts = split(path, "/");
    let level = length(parts);
    return (index(output, "type route hook output priority mangle - 1") >= 0 ||
            index(output, "type route hook output priority -151") >= 0) &&
        index(output, "socket cgroupv2 level " + level + " \"" + path + "\"") >= 0 &&
        (index(output, "meta mark set 0x08000000") >= 0 ||
         index(output, "meta mark set 0x8000000") >= 0) &&
        index(output, "Prokop TorrServer Direct") >= 0;
}
function active(info) {
    if (!info.available) return false;
    return rule_output_active(command_output([ "nft", "list", "chain", "inet", TABLE, "output" ]), info);
}

// Direct's state for `info` (from discover or discover_from). The rule is
// looked up only while the setting is on: the card shows it only then.
function status_of(info) {
    info.enabled = enabled() ? 1 : 0;
    info.active = info.enabled && active(info) ? 1 : 0;
    return info;
}

return {
    TABLE, PROC_DIR, is_torrserver_cmdline, each_process, valid_cgroup, discover, discover_from,
    enabled, rule_output_active, active, status_of
};
