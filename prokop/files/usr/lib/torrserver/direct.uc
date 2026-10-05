#!/usr/bin/ucode

let fs = require("fs");
let procs = require("torrserver.procs");

const TABLE = procs.TABLE;
const OUTBOUND_MARK = getenv("NFT_OUTBOUND_MARK") || "0x08000000";

function text(value) { return value == null ? "" : "" + value; }
function quote(value) { return "'" + replace(text(value), /'/g, "'\\''") + "'"; }
function command(args) {
    let values = [];
    for (let arg in args) push(values, quote(arg));
    return join(" ", values);
}
function success(args) { return system(command(args) + " >/dev/null 2>&1") == 0; }
function command_output(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return "";
    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? text(data) : "";
}
function read(path) { let value = fs.readfile(path); return value == null ? "" : text(value); }
const valid_cgroup = procs.valid_cgroup;
const discover = procs.discover;
const enabled = procs.enabled;
const rule_output_active = procs.rule_output_active;
const active = procs.active;
function remove_rule() { success([ "nft", "delete", "table", "inet", TABLE ]); }
// The nft batch for a dedicated cgroup (an absolute cgroup v2 path). It
// replaces the table in one transaction: the add makes the delete valid when
// there is no table yet, and TorrServer's sockets are never left unmarked
// between an old rule and a new one (UC-108). A connection to a FakeIP
// address is left unmarked: the name behind it is one of Prokop's rules,
// and only sing-box can reach it (marked, it went to the WAN as is, TS-9).
function rule_batch(cgroup) {
    let path = substr(cgroup, 1);
    let parts = split(path, "/");
    // Match the exact dedicated group, not a shared parent of nested services.
    let level = length(parts);
    let match_group = "socket cgroupv2 level " + level + " \"" + path + "\" meta mark set " + OUTBOUND_MARK +
        " counter comment \"Prokop TorrServer Direct\"\n";
    return "add table inet " + TABLE + "\n" +
        "delete table inet " + TABLE + "\n" +
        "add table inet " + TABLE + "\n" +
        "add chain inet " + TABLE + " output { type route hook output priority -151; policy accept; }\n" +
        "add rule inet " + TABLE + " output ip daddr != " + procs.FAKEIP_RANGE + " " + match_group +
        "add rule inet " + TABLE + " output ip6 daddr != " + procs.FAKEIP6_RANGE + " " + match_group;
}
function apply_rule(info) {
    if (!info.available) return false;
    // A fresh file of mktemp (TMPDIR or /tmp), never a fixed path that a
    // symlink could point elsewhere.
    let ruleset_path = trim(command_output([ "mktemp" ]));
    if (ruleset_path == "") return false;
    let applied = fs.writefile(ruleset_path, rule_batch(info.cgroup)) != null &&
        success([ "nft", "-f", ruleset_path ]);
    try { fs.unlink(ruleset_path); } catch (e) { }
    if (!applied || !active(info)) {
        remove_rule();
        return false;
    }
    return true;
}
function status() {
    return procs.status_of(discover());
}
function reconcile() {
    if (!enabled()) { remove_rule(); return 0; }
    let info = discover();
    if (!info.available) { remove_rule(); return 1; }
    return apply_rule(info) ? 0 : 1;
}
// The worker never exits on its own: procd respawns an instance that ends, so
// a worker that ended once the setting went off (a snapshot restore, `uci
// set` + commit) would be respawned into a crash loop. While the setting is
// off, or cannot be read, it keeps no rule and waits; when it is on again, it
// applies the rule again (UC-110).
function worker() {
    let last_cgroup = "";
    while (true) {
        let info = enabled() ? discover() : null;
        if (info == null || !info.available) {
            remove_rule();
            last_cgroup = "";
        }
        else if (info.cgroup != last_cgroup || !active(info)) {
            if (apply_rule(info)) last_cgroup = info.cgroup;
        }
        system("sleep 60");
    }
}

let mode = ARGV[0] || "status";
if (mode == "status") print(sprintf("%J\n", status()));
else if (mode == "reconcile") exit(reconcile());
else if (mode == "remove") { remove_rule(); exit(0); }
else if (mode == "worker") worker();
else if (mode == "rule-output-active") {
    let info = { available: 1, cgroup: ARGV[1] || "" };
    exit(rule_output_active(read("/dev/stdin"), info) ? 0 : 1);
}
else if (mode == "batch") {
    // Prints the batch apply_rule() would submit; changes nothing (tests).
    let cgroup = ARGV[1] || "";
    if (!valid_cgroup(cgroup)) exit(1);
    print(rule_batch(cgroup));
}
else exit(1);
