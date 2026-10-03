#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

python3 - "$ROOT_DIR" "$WORK_DIR/probe.uc" <<'PY'
import pathlib
import re
import sys

source = (pathlib.Path(sys.argv[1]) / 'forkop/files/usr/lib/components/action.uc').read_text()
names = ('forkop_stop_for_component_change_args',
         'forkop_release_matches', 'opkg_forkop_set_versions_match',
         'pkg_set_extension', 'pkg_forkop_set_command', 'forkop_recovery_files',
         'restore_forkop_opkg_service', 'finish_forkop_opkg_recovery',
         'recover_forkop_opkg_set', 'forkop_package_set_space_error',
         'prepare_forkop_package_set', 'install_forkop_package_set')
functions = []
for name in names:
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    functions.append(match.group())

prefix = r'''
const FORKOP_VERSION = "1.0.0";
const FORKOP_OPKG_RECOVERY_DIR = "/recovery";
const SERVICE_INIT = "/init";
let tmp_dir = "/tmp";
let apk = false;
let forkop_was_running = true;
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
function file_exists(path) { return path == FORKOP_OPKG_RECOVERY_DIR ? recovery_dir : marker != ""; }
function file_nonempty(path) { return index(downloads, path) >= 0; }
function read_file(path) { return marker; }
function write_file(path, value) { marker_tmp = value; return true; }
let fs = { rename: function(source, target) { marker = marker_tmp; marker_tmp = ""; return true; } };
// core/durable.uc: the recovery marker is written, flushed and renamed.
let durable = { durable_replace: function(tmp, path, data) { marker = data; marker_tmp = ""; return true; } };
function check(ok, message) { if (!ok) { warn("FAIL: " + message + "\n"); exit(1); } }
function command_success_from_args(args) {
    // The rollback's own stop is not the user's (D-15).
    if (args[0] == "env") {
        check(args[1] == "FORKOP_STOP_SOURCE=component", "rollback stop is recorded as the user's");
        args = slice(args, 2);
    }
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
// service/initd.uc start-and-wait (UC-013).
function forkop_start_and_wait(action) {
    check(action == "start", "unexpected start action");
    if (service_restart_fail) return false;
    service_running = true;
    return true;
}
function installed_package_version(name) { return versions[name] || ""; }
function forkop_status_running_with_timeout() { return service_running; }
// The user's stop during the upgrade: tests/forkop_upgrade_user_stop.sh.
function forkop_stopped_by_user() { return false; }
// Forkop's own stop request that the start follows:
// tests/component_restart_own_stop.sh.
function own_stop_request() { return "1.000000001.42"; }
// The upgrade marker before the start: tests/forkop_upgrade_refusal_restart.sh.
function remove_managed_upgrade_sing_box_marker() {}
function previous_forkop_release(version) {
    check(version == FORKOP_VERSION, "wrong previous release");
    let ext = apk ? "apk" : "ipk";
    return { backend_name: "forkop_1.0.0." + ext, backend_url: "old-backend",
        app_name: "luci-app-forkop_1.0.0." + ext, app_url: "old-app",
        i18n_name: "luci-i18n-forkop-ru_1.0.0." + ext, i18n_url: "old-i18n" };
}
function download_with_retry(url, path, label) { push(downloads, path); return true; }
function command_from_args(args) { return join(" ", args); }
function command_output_from_args(args) { check(args[0] == "dirname", "unexpected path command"); return "/"; }
function ensure_dir(path) { return path == "/"; }
function is_apk() { return apk; }
// Free space is exercised by its own test, so leave room here.
function available_kib(path) { return 1048576; }
function file_bytes(path) { return 0; }
function path_basename(path) { let parts = split(path, "/"); return parts[length(parts) - 1]; }
function updates_log(message, level) { push(events, message); }
// Staged archives are matched by stem only, so a wrong extension surfaces as
// the recovery failure it causes on a router rather than as a probe error.
function package_name(file) {
    let base = path_basename(file);
    if (index(base, "luci-i18n-forkop-ru_") == 0 || index(base, "i18n.") == 0) return "luci-i18n-forkop-ru";
    if (index(base, "luci-app-forkop_") == 0 || index(base, "app.") == 0) return "luci-app-forkop";
    if (index(base, "forkop_") == 0 || index(base, "backend.") == 0) return "forkop";
    return "";
}
// opkg takes one file per step. apk takes the whole new set in one transaction
// and commits the packages ahead of the one that fails.
function run_logged(description, command) {
    push(events, description);
    if (index(command, apk ? "--simulate" : "--noaction") >= 0)
        return true;
    let files = filter(split(command, " "), (word) => index(word, "/") == 0);
    check(length(files) > 0, "package step without files");
    for (let file in files) {
        let old = index(file, FORKOP_OPKG_RECOVERY_DIR + "/") == 0;
        let name = package_name(file);
        check(name != "", "unknown package file " + file);
        if (old && name == rollback_failure) return false;
        if (old && name == "forkop") service_running = false; // rollback prerm
        if (!old && name == failure) {
            if (name == "forkop") service_running = false;
            return false;
        }
        if (!old && name == uncommitted) continue;
        if (!old && name == "forkop") service_running = false;
        versions[name] = old ? "1.0.0-r1" : "1.1.0-r1";
    }
    return true;
}
'''
suffix = r'''
// Refusals (prepare) come before Forkop is stopped for the upgrade; the
// install follows (components/action.uc install_forkop).
function upgrade_set(latest, backend, app, i18n) {
    let error = prepare_forkop_package_set(backend, app, i18n);
    return error != "" ? error : install_forkop_package_set(latest, backend, app, i18n);
}
function reset() {
    versions = { "forkop": "1.0.0-r1", "luci-app-forkop": "1.0.0-r1",
        "luci-i18n-forkop-ru": "1.0.0-r1" };
    apk = false;
    events = [];
    downloads = [];
    recovery_dir = false;
    marker = "";
    marker_tmp = "";
    rollback_failure = "";
    uncommitted = "";
    forkop_was_running = true;
    service_running = true;
    service_restart_fail = false;
}
for (let target in [ "", "forkop", "luci-app-forkop", "luci-i18n-forkop-ru" ]) {
    reset(); failure = target;
    let error = upgrade_set("1.1.0", "/new/forkop_1.1.0.ipk",
        "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk");
    if (target == "") {
        check(error == "" && opkg_forkop_set_versions_match("1.1.0", true), "success path failed");
        check(marker == "", "successful upgrade retained recovery marker");
    } else {
        check(index(error, "previous release restored") >= 0, "failure not reported as restored");
        check(opkg_forkop_set_versions_match("1.0.0", true), "mixed package versions after " + target);
        let restores = 0;
        for (let event in events)
            if (index(event, "Restoring Forkop release package ") == 0) restores++;
        check(restores == (target == "forkop" ? 0 : 3), "rollback did not restore the old set");
        check(marker == "", "restored upgrade retained recovery marker");
    }
}
reset(); uncommitted = "luci-i18n-forkop-ru";
check(index(upgrade_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && opkg_forkop_set_versions_match("1.0.0", true),
    "uncommitted final package did not trigger rollback");
reset(); failure = "luci-i18n-forkop-ru"; rollback_failure = "luci-app-forkop";
let error = upgrade_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk");
check(index(error, "archives retained") >= 0 && marker != "" && recovery_dir,
    "failed rollback discarded recovery archive");
rollback_failure = ""; failure = "";
check(recover_forkop_opkg_set() == "" && opkg_forkop_set_versions_match("1.0.0", true) && marker == "",
    "pending recovery did not restore previous package set");
reset(); failure = "";
versions["luci-i18n-forkop-ru"] = "";
check(upgrade_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "") == "" &&
    opkg_forkop_set_versions_match("1.1.0", false) && versions["luci-i18n-forkop-ru"] == "",
    "upgrade without optional i18n failed");
reset();
versions["luci-app-forkop"] = "0.9.0-r1";
check(index(upgrade_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "inconsistent") >= 0 && length(events) == 0, "mixed initial set was not refused");
reset(); failure = "forkop";
check(index(upgrade_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && service_running && marker == "",
    "running service was not restored after backend install failure");
reset(); failure = "forkop"; forkop_was_running = false; service_running = false;
check(index(upgrade_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && !service_running && marker == "",
    "stopped service was started by rollback");
reset(); failure = "luci-app-forkop"; rollback_failure = "luci-app-forkop";
check(index(upgrade_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "archives retained") >= 0 && marker != "" && !service_running,
    "interrupted recovery fixture not established");
rollback_failure = ""; forkop_was_running = false;
check(recover_forkop_opkg_set() == "" && service_running && marker == "",
    "new invocation lost original running state");
reset(); failure = "forkop"; service_restart_fail = true;
check(index(upgrade_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "service") >= 0 && marker != "" && !service_running,
    "service restart failure was reported as complete recovery");
service_restart_fail = false;
check(recover_forkop_opkg_set() == "" && service_running && marker == "",
    "service restart retry lost recovery state");
reset(); marker = "1.0.0\t1.1.0\t1\n"; recovery_dir = true;
check(index(recover_forkop_opkg_set(), "unknown") >= 0 && marker != "",
    "legacy marker silently assumed original service state");

// apk installs app, i18n and backend in one transaction, so a failure leaves
// the packages ahead of it upgraded and the rollback has to restore from the
// staged archives, which must be ones apk will read back.
function restored_files() {
    let files = [];
    for (let event in events)
        if (index(event, "Restoring Forkop release package ") == 0)
            push(files, substr(event, length("Restoring Forkop release package ")));
    return join(" ", files);
}
let apk_restores = { "forkop": "i18n.apk app.apk backend.apk",
    "luci-app-forkop": "", "luci-i18n-forkop-ru": "i18n.apk app.apk backend.apk" };
for (let target in [ "", "forkop", "luci-app-forkop", "luci-i18n-forkop-ru" ]) {
    reset(); apk = true; failure = target;
    let error = upgrade_set("1.1.0", "/new/forkop_1.1.0.apk",
        "/new/luci-app-forkop_1.1.0.apk", "/new/luci-i18n-forkop-ru_1.1.0.apk");
    if (target == "") {
        check(error == "" && opkg_forkop_set_versions_match("1.1.0", true) && marker == "",
            "apk success path failed: " + error);
        continue;
    }
    check(index(error, "previous release restored") >= 0,
        "apk failure in " + target + " not restored: " + error);
    check(opkg_forkop_set_versions_match("1.0.0", true) && marker == "",
        "apk mixed package versions after " + target);
    check(restored_files() == apk_restores[target],
        "apk rollback after " + target + " restored [" + restored_files() + "]");
}
reset(); apk = true; failure = "luci-i18n-forkop-ru"; rollback_failure = "luci-app-forkop";
error = upgrade_set("1.1.0", "/new/forkop_1.1.0.apk",
    "/new/luci-app-forkop_1.1.0.apk", "/new/luci-i18n-forkop-ru_1.1.0.apk");
check(index(error, "archives retained") >= 0 && marker != "" && recovery_dir,
    "apk failed rollback did not retain its archives: " + error);
rollback_failure = ""; failure = ""; events = [];
error = recover_forkop_opkg_set();
check(error == "" && opkg_forkop_set_versions_match("1.0.0", true) && marker == "",
    "apk pending recovery did not restore previous package set: " + error);
check(restored_files() == "i18n.apk app.apk backend.apk",
    "apk pending recovery restored [" + restored_files() + "]");
print("Forkop package-set checks passed\n");
'''
pathlib.Path(sys.argv[2]).write_text(prefix + '\n\n'.join(functions) + suffix)
PY

# An uncaught ucode exception can still exit 0, so require the final line.
output="$(ucode "$WORK_DIR/probe.uc")"
printf '%s\n' "$output"
[ "$output" = "Forkop package-set checks passed" ] || {
  echo "FAIL: package-set probe did not run to completion" >&2
  exit 1
}
