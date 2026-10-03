#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

python3 - "$ROOT_DIR" "$WORK_DIR/probe.uc" <<'PY'
import pathlib
import re
import sys

source = (pathlib.Path(sys.argv[1]) / 'prokop/files/usr/lib/components/action.uc').read_text()
names = ('prokop_release_matches', 'opkg_prokop_set_versions_match',
         'pkg_set_extension', 'pkg_prokop_set_command', 'prokop_recovery_files',
         'restore_prokop_opkg_service', 'finish_prokop_opkg_recovery',
         'recover_prokop_opkg_set', 'prokop_package_set_space_error',
         'install_prokop_package_set')
functions = []
for name in names:
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    functions.append(match.group())

prefix = r'''
const PROKOP_VERSION = "1.0.0";
const PROKOP_OPKG_RECOVERY_DIR = "/recovery";
const SERVICE_INIT = "/init";
let tmp_dir = "/tmp";
let prokop_was_running = true;
let service_running = true;
let service_restart_fail = false;
let versions = {};
let failure = "";
let uncommitted = "";
let rollback_failure = "";
let events = [];
let downloads = [];
let recovery_dir = false;
let marker = "";
let marker_tmp = "";
function file_exists(path) { return path == PROKOP_OPKG_RECOVERY_DIR ? recovery_dir : marker != ""; }
function file_nonempty(path) { return index(downloads, path) >= 0; }
function read_file(path) { return marker; }
function write_file(path, value) { marker_tmp = value; return true; }
let fs = { rename: function(source, target) { marker = marker_tmp; marker_tmp = ""; return true; } };
function command_success_from_args(args) {
    if (args[0] == "mkdir") { recovery_dir = true; return true; }
    if (args[0] == "rm") { recovery_dir = false; marker = ""; downloads = []; return true; }
    if (args[0] == "sync") return true;
    if (args[0] == SERVICE_INIT) {
        if (args[1] == "status") return service_running;
        if (args[1] == "stop") { service_running = false; return true; }
        if (args[1] == "start" || args[1] == "restart") {
            if (service_restart_fail) return false;
            service_running = true;
            return true;
        }
    }
    check(false, "unexpected filesystem command");
}
function check(ok, message) { if (!ok) { warn("FAIL: " + message + "\n"); exit(1); } }
function installed_package_version(name) { return versions[name] || ""; }
function prokop_status_running_with_timeout() { return service_running; }
function previous_prokop_release(version) {
    check(version == PROKOP_VERSION, "wrong previous release");
    return { backend_name: "prokop_1.0.0.ipk", backend_url: "old-backend",
        app_name: "luci-app-prokop_1.0.0.ipk", app_url: "old-app",
        i18n_name: "luci-i18n-prokop-ru_1.0.0.ipk", i18n_url: "old-i18n" };
}
function download_with_retry(url, path, label) { push(downloads, path); return true; }
function command_from_args(args) { return join(" ", args); }
function command_output_from_args(args) { check(args[0] == "dirname", "unexpected path command"); return "/"; }
function ensure_dir(path) { return path == "/"; }
// This probe drives the opkg branch; the apk branch is covered separately.
function is_apk() { return false; }
// Free space is exercised by its own test, so leave room here.
function available_kib(path) { return 1048576; }
function file_bytes(path) { return 0; }
function path_basename(path) { let parts = split(path, "/"); return parts[length(parts) - 1]; }
function updates_log(message, level) { push(events, message); }
function run_logged(description, command) {
    push(events, description);
    let old = index(command, PROKOP_OPKG_RECOVERY_DIR + "/") >= 0;
    if (index(command, "--noaction") >= 0)
        return true;
    let name = "";
    if (index(command, "luci-i18n-prokop-ru_") >= 0 || index(command, "/i18n.ipk") >= 0) name = "luci-i18n-prokop-ru";
    else if (index(command, "luci-app-prokop_") >= 0 || index(command, "/app.ipk") >= 0) name = "luci-app-prokop";
    else if (index(command, "prokop_") >= 0 || index(command, "/backend.ipk") >= 0) name = "prokop";
    check(name != "", "unknown package step");
    if (old && name == rollback_failure) return false;
    if (old && name == "prokop") service_running = false; // rollback prerm
    if (!old && name == failure) {
        if (name == "prokop") service_running = false;
        return false;
    }
    if (!old && name == uncommitted) return true;
    if (!old && name == "prokop") service_running = false;
    versions[name] = old ? "1.0.0-r1" : "1.1.0-r1";
    return true;
}
'''
suffix = r'''
function reset() {
    versions = { "prokop": "1.0.0-r1", "luci-app-prokop": "1.0.0-r1",
        "luci-i18n-prokop-ru": "1.0.0-r1" };
    events = [];
    downloads = [];
    recovery_dir = false;
    marker = "";
    marker_tmp = "";
    rollback_failure = "";
    uncommitted = "";
    prokop_was_running = true;
    service_running = true;
    service_restart_fail = false;
}
for (let target in [ "", "prokop", "luci-app-prokop", "luci-i18n-prokop-ru" ]) {
    reset(); failure = target;
    let error = install_prokop_package_set("1.1.0", "/new/prokop_1.1.0.ipk",
        "/new/luci-app-prokop_1.1.0.ipk", "/new/luci-i18n-prokop-ru_1.1.0.ipk");
    if (target == "") {
        check(error == "" && opkg_prokop_set_versions_match("1.1.0", true), "success path failed");
        check(marker == "", "successful upgrade retained recovery marker");
    } else {
        check(index(error, "previous release restored") >= 0, "failure not reported as restored");
        check(opkg_prokop_set_versions_match("1.0.0", true), "mixed package versions after " + target);
        let restores = 0;
        for (let event in events)
            if (index(event, "Restoring Prokop release package ") == 0) restores++;
        check(restores == (target == "prokop" ? 0 : 3), "rollback did not restore the old set");
        check(marker == "", "restored upgrade retained recovery marker");
    }
}
reset(); uncommitted = "luci-i18n-prokop-ru";
check(index(install_prokop_package_set("1.1.0", "/new/prokop_1.1.0.ipk",
    "/new/luci-app-prokop_1.1.0.ipk", "/new/luci-i18n-prokop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && opkg_prokop_set_versions_match("1.0.0", true),
    "uncommitted final package did not trigger rollback");
reset(); failure = "luci-i18n-prokop-ru"; rollback_failure = "luci-app-prokop";
let error = install_prokop_package_set("1.1.0", "/new/prokop_1.1.0.ipk",
    "/new/luci-app-prokop_1.1.0.ipk", "/new/luci-i18n-prokop-ru_1.1.0.ipk");
check(index(error, "archives retained") >= 0 && marker != "" && recovery_dir,
    "failed rollback discarded recovery archive");
rollback_failure = ""; failure = "";
check(recover_prokop_opkg_set() == "" && opkg_prokop_set_versions_match("1.0.0", true) && marker == "",
    "pending recovery did not restore previous package set");
reset(); failure = "";
versions["luci-i18n-prokop-ru"] = "";
check(install_prokop_package_set("1.1.0", "/new/prokop_1.1.0.ipk",
    "/new/luci-app-prokop_1.1.0.ipk", "") == "" &&
    opkg_prokop_set_versions_match("1.1.0", false) && versions["luci-i18n-prokop-ru"] == "",
    "upgrade without optional i18n failed");
reset();
versions["luci-app-prokop"] = "0.9.0-r1";
check(index(install_prokop_package_set("1.1.0", "/new/prokop_1.1.0.ipk",
    "/new/luci-app-prokop_1.1.0.ipk", "/new/luci-i18n-prokop-ru_1.1.0.ipk"),
    "inconsistent") >= 0 && length(events) == 0, "mixed initial set was not refused");
reset(); failure = "prokop";
check(index(install_prokop_package_set("1.1.0", "/new/prokop_1.1.0.ipk",
    "/new/luci-app-prokop_1.1.0.ipk", "/new/luci-i18n-prokop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && service_running && marker == "",
    "running service was not restored after backend install failure");
reset(); failure = "prokop"; prokop_was_running = false; service_running = false;
check(index(install_prokop_package_set("1.1.0", "/new/prokop_1.1.0.ipk",
    "/new/luci-app-prokop_1.1.0.ipk", "/new/luci-i18n-prokop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && !service_running && marker == "",
    "stopped service was started by rollback");
reset(); failure = "luci-app-prokop"; rollback_failure = "luci-app-prokop";
check(index(install_prokop_package_set("1.1.0", "/new/prokop_1.1.0.ipk",
    "/new/luci-app-prokop_1.1.0.ipk", "/new/luci-i18n-prokop-ru_1.1.0.ipk"),
    "archives retained") >= 0 && marker != "" && !service_running,
    "interrupted recovery fixture not established");
rollback_failure = ""; prokop_was_running = false;
check(recover_prokop_opkg_set() == "" && service_running && marker == "",
    "new invocation lost original running state");
reset(); failure = "prokop"; service_restart_fail = true;
check(index(install_prokop_package_set("1.1.0", "/new/prokop_1.1.0.ipk",
    "/new/luci-app-prokop_1.1.0.ipk", "/new/luci-i18n-prokop-ru_1.1.0.ipk"),
    "service") >= 0 && marker != "" && !service_running,
    "service restart failure was reported as complete recovery");
service_restart_fail = false;
check(recover_prokop_opkg_set() == "" && service_running && marker == "",
    "service restart retry lost recovery state");
reset(); marker = "1.0.0\t1.1.0\t1\n"; recovery_dir = true;
check(index(recover_prokop_opkg_set(), "unknown") >= 0 && marker != "",
    "legacy marker silently assumed original service state");
print("Prokop OPKG package-set checks passed\n");
'''
pathlib.Path(sys.argv[2]).write_text(prefix + '\n\n'.join(functions) + suffix)
PY

ucode "$WORK_DIR/probe.uc"
