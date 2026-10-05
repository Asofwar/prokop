#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let netstat = require("core.netstat");
let runtime_lock = require("core.runtime_lock");
let process_identity = require("core.process_identity");
let durable = require("core.durable");
let legacy_forkop = require("core.legacy_forkop");
// components/progress.uc, called as progress?.stage?.(...): a library
// without it (a test's partial copy, a probe built from some of these
// functions) runs the action without reporting progress.
let progress = null;
try {
    progress = require("components.progress");
}
catch (e) {
}

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || constants.PROKOP_CONFIG_NAME || "prokop";
const BIN_PATH = getenv("PROKOP_BIN") || constants.PROKOP_BIN || "/usr/bin/prokop";
const SERVICE_INIT = getenv("PROKOP_SERVICE_INIT") || constants.PROKOP_SERVICE_INIT || "/etc/init.d/prokop";
const PROKOP_VERSION = getenv("PROKOP_VERSION") || constants.PROKOP_VERSION || "";
const PROKOP_RELEASE_REPO = getenv("PROKOP_RELEASE_REPO") || constants.PROKOP_RELEASE_REPO || "";
const PROKOP_RELEASE_BASE_URL = getenv("PROKOP_RELEASE_BASE_URL") || constants.PROKOP_RELEASE_BASE_URL || "";
// The dependency mirror is opt-in: an empty value means "use the sources".
const PROKOP_MIRROR_BASE_URL = replace(getenv("PROKOP_MIRROR_BASE_URL") || constants.PROKOP_MIRROR_BASE_URL || "", /\/+$/, "");
const RUNTIME_STATE_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const MANAGED_UPGRADE_SING_BOX_MARKER = getenv("PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER") || "/tmp/prokop-managed-upgrade-sing-box";
const SYSTEM_INFO_CACHE_FILE = getenv("PROKOP_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
const COMPONENT_LOCK_DIR = getenv("UPDATES_LOCK_DIR") || RUNTIME_STATE_DIR + "/component-action.lock";
// Written by every stop with who asked for it (service/initd.uc
// mark_stop_requested), removed by an explicit start.
const STOP_REQUESTED_FILE = getenv("PROKOP_STOP_REQUESTED_FILE") || RUNTIME_STATE_DIR + "/stop.requested";
const PROKOP_OPKG_RECOVERY_DIR = getenv("PROKOP_OPKG_RECOVERY_DIR") || "/etc/prokop/opkg-package-set-recovery";
// Set for an action the UI runs as a background job: where it reports its
// progress (components/progress.uc).
const PROGRESS_FILE = getenv("PROKOP_COMPONENT_ACTION_PROGRESS_FILE") || "";
const TMP_STALE_TTL_MINUTES = getenv("UPDATES_TMP_STALE_TTL_MINUTES") || "30";
const TMP_FILE_STALE_TTL_MINUTES = getenv("UPDATES_TMP_FILE_STALE_TTL_MINUTES") || "10";
const SB_MANAGED_SERVICE_MARKER = getenv("SB_MANAGED_SERVICE_MARKER") || constants.SB_MANAGED_SERVICE_MARKER || "Prokop managed sing-box service for binary variants";
// Forkop wrote the same service under its own marker. The migrating installer
// rewrites it to SB_MANAGED_SERVICE_MARKER before Forkop's prerm runs; once
// Forkop's package is gone, a service that still carries it is Prokop's all
// the same (as for service/package.uc).
const SB_LEGACY_MANAGED_SERVICE_MARKER = legacy_forkop.SING_BOX_MANAGED_MARKER;
const TORRSERVER_DIRECT_INIT = getenv("PROKOP_TORRSERVER_DIRECT_INIT") || "/etc/init.d/prokop-torrserver-direct";
const TORRSERVER_DIRECT_UC = LIB_DIR + "/torrserver/direct.uc";
const TORRSERVER_UC = LIB_DIR + "/torrserver/manager.uc";
const TORRSERVER_INIT = getenv("PROKOP_TORRSERVER_INIT") || "/etc/init.d/prokop-torrserver";
// How long a freshly installed TorrServer has to answer on its port.
const TORRSERVER_START_TIMEOUT = getenv("PROKOP_TORRSERVER_START_TIMEOUT") || "30";

let tmp_dir = "";
// Whether a fresh TorrServer took the recommended settings (1 or 0); null
// when the action did not try. The response carries it, so the UI can warn
// instead of showing a plain success (TS-11).
let torrserver_settings_applied = null;
let lock_held = false;
let prokop_was_running = false;
let last_logged_output = "";
// Memory kept free for the router itself when a download goes to RAM.
const COMPONENT_MEMORY_RESERVE_KIB = int(getenv("PROKOP_COMPONENT_MEMORY_RESERVE_KIB") || "16384");
let prokop_stopped_for_sing_box_change = false;
let prokop_stopped_for_upgrade = false;
let managed_upgrade_marker_written = false;
// Prokop's own stop for the restart after the change was refused
// (prokop_restart_and_wait).
let prokop_restart_refused = false;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_env(assignments) {
    let parts = [];
    for (let name, value in assignments)
        push(parts, name + "=" + shell_quote(value));
    return join(" ", parts);
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success(command) {
    return command_status("(" + command + ") >/dev/null 2>&1") == 0;
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
}

function command_status_from_args(args) {
    return command_status("(" + command_from_args(args) + ") >/dev/null 2>&1");
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", name ]);
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_file(path, value) {
    return fs.writefile(as_string(path), as_string(value)) != null;
}

function read_file(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? "" : as_string(data);
}

function parse_json_object(value) {
    try {
        let parsed = json(as_string(value));
        return type(parsed) == "object" ? parsed : {};
    }
    catch (e) {
        return {};
    }
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", as_string(path) ]);
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && int(stat.size || 0) > 0;
}

function path_basename(path) {
    let parts = split(as_string(path), "/");
    return length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
}

function file_bytes(path) {
    let stat = fs.stat(as_string(path));
    return stat == null ? 0 : int(stat.size || 0);
}

function available_kib(path) {
    let fields = split(trim(command_output_from_args([ "df", "-k", as_string(path) ])), "\n");
    if (length(fields) < 2)
        return -1;
    let columns = split(trim(fields[length(fields) - 1]), /[ \t]+/);
    return length(columns) >= 4 && match(as_string(columns[3]), /^[0-9]+$/) != null ?
        int(columns[3]) : -1;
}

// MemAvailable from the kernel (MemFree on kernels without it); -1 when the
// file cannot be read. Tests point PROKOP_MEMINFO_PATH elsewhere.
function memory_available_kib() {
    let text = read_file(getenv("PROKOP_MEMINFO_PATH") || "/proc/meminfo");
    let free = -1;
    for (let line in split(text, "\n")) {
        let m = match(line, /^(MemAvailable|MemFree):[ \t]+([0-9]+)/);
        if (m == null)
            continue;
        if (m[1] == "MemAvailable")
            return int(m[2]);
        free = int(m[2]);
    }
    return free;
}

// Whether `path` lives on a tmpfs, by the longest mount point that holds it.
function path_on_tmpfs(path) {
    path = as_string(path);
    let best = "";
    let best_type = "";
    for (let line in split(read_file(getenv("PROKOP_MOUNTS_PATH") || "/proc/mounts"), "\n")) {
        let fields = split(trim(line), /[ \t]+/);
        if (length(fields) < 3)
            continue;
        let mount_point = fields[1];
        let inside = mount_point == "/" || path == mount_point ||
            substr(path, 0, length(mount_point) + 1) == mount_point + "/";
        if (inside && length(mount_point) >= length(best)) {
            best = mount_point;
            best_type = fields[2];
        }
    }
    return best_type == "tmpfs" || best_type == "ramfs";
}

// A component download lands in the temporary directory, and is unpacked
// there too: `factor` counts those copies. On a tmpfs every copy is RAM the
// router has to spare, so a download that would leave it short is refused
// before it starts (UPD-7, B3). An unknown size refuses nothing.
function component_download_space_error(label, size_bytes, factor, dir) {
    size_bytes = int(size_bytes || 0);
    if (size_bytes <= 0)
        return "";
    let needed_kib = int(size_bytes * factor / 1024) + 1024;
    let tmp_kib = available_kib(dir);
    if (tmp_kib >= 0 && tmp_kib < needed_kib)
        return "Not enough free space in /tmp to download " + as_string(label) + ": " +
            as_string(tmp_kib) + " KiB available where " + as_string(needed_kib) + " KiB is needed";
    if (!path_on_tmpfs(dir))
        return "";
    // What stays for the router's own processes once the files are in RAM.
    let needed_memory_kib = needed_kib + COMPONENT_MEMORY_RESERVE_KIB;
    let memory_kib = memory_available_kib();
    if (memory_kib >= 0 && memory_kib < needed_memory_kib)
        return "Not enough free memory to download " + as_string(label) + ": " +
            as_string(memory_kib) + " KiB available where " + as_string(needed_memory_kib) + " KiB is needed";
    return "";
}

// Room on the overlay for `bytes` of newly installed files, checked while
// the running variant is still in place (UPD-7, B3).
function component_install_space_error(label, bytes) {
    let needed_kib = int(int(bytes || 0) / 1024) + 2048;
    let overlay_kib = available_kib("/usr");
    if (overlay_kib >= 0 && overlay_kib < needed_kib)
        return "Not enough free space on the router's storage to install " + as_string(label) + ": " +
            as_string(overlay_kib) + " KiB available where " + as_string(needed_kib) + " KiB is needed";
    return "";
}

// A package manager or tar that ran out of room says so in its own words;
// the failure message names the cause instead of a bare "failed".
function out_of_space_hint(output) {
    return match(as_string(output), /No space left on device|Only have [0-9]+kb available|[Nn]ot enough (free )?space|ENOSPC/) != null ?
        ": the router ran out of storage space" : "";
}

function now_seconds() {
    return int(clock()[0]);
}

function owner_pid() {
    let pid = trim(command_output_from_args([ "sh", "-c", "echo $PPID" ]));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "prokop", "[" + level + "] " + as_string(message) ]);
}

function updates_log(message, level) {
    log_message("Updates: " + as_string(message), level || "info");
}

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_output(args) {
    return command_output(module_command(args));
}

function module_success(args) {
    return command_success(module_command(args));
}

function module_success_env(assignments, args) {
    return command_success(command_env(assignments) + " " + module_command(args));
}

function helper_output(mode, args) {
    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_output(command_args);
}

function helper_success(mode, args) {
    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

function cleanup_stale_tmp_files() {
    command_success_from_args([ "find", "/tmp", "-maxdepth", "1", "-type", "d", "-name", "prokop-updates.*", "-mmin", "+" + as_string(TMP_STALE_TTL_MINUTES), "-exec", "rm", "-rf", "{}", "+" ]);
    command_success_from_args([ "find", "/tmp", "-maxdepth", "1", "-type", "f", "(", "-name", "prokop-updates-command.*", "-o", "-name", "prokop-updates-http.*", ")", "-mmin", "+" + as_string(TMP_FILE_STALE_TTL_MINUTES), "-delete" ]);
}

function init_tmp_dir() {
    if (tmp_dir != "")
        return true;

    cleanup_stale_tmp_files();
    tmp_dir = trim(command_output_from_args([ "mktemp", "-d", "/tmp/prokop-updates.XXXXXX" ]));
    if (tmp_dir == "") {
        tmp_dir = "/tmp/prokop-updates." + owner_pid();
        if (!ensure_dir(tmp_dir)) {
            tmp_dir = "";
            return false;
        }
    }
    return true;
}

function make_tmp_file(prefix) {
    init_tmp_dir();
    let base = tmp_dir != "" ? tmp_dir + "/" + as_string(prefix) + ".XXXXXX" : "/tmp/prokop-updates-" + as_string(prefix) + ".XXXXXX";
    let path = trim(command_output_from_args([ "mktemp", base ]));
    if (path == "") {
        path = (tmp_dir != "" ? tmp_dir : "/tmp") + "/" + as_string(prefix) + "." + owner_pid() + "." + now_seconds();
        if (!write_file(path, ""))
            return "";
    }
    return path;
}

function helper_output_input(input, mode, args) {
    let input_path = make_tmp_file("helper-input");
    if (input_path == "")
        return "";
    write_file(input_path, as_string(input));

    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    let output = command_output(command_from_args([ "cat", input_path ]) + " | " + module_command(command_args));
    remove_file(input_path);
    return output;
}

function helper_success_input(input, mode, args) {
    let input_path = make_tmp_file("helper-input");
    if (input_path == "")
        return false;
    write_file(input_path, as_string(input));

    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    let ok = command_success(command_from_args([ "cat", input_path ]) + " | " + module_command(command_args));
    remove_file(input_path);
    return ok;
}

function cleanup_tmp_dir() {
    if (tmp_dir != "") {
        command_success_from_args([ "rm", "-rf", tmp_dir ]);
        tmp_dir = "";
    }
    cleanup_stale_tmp_files();
}

// The lock protocol and the owner record: core/runtime_lock.uc (UC-157).
// full-uninstall.sh takes the same lock in the previous format (mkdir, then
// <lock>/pid): it runs while the packages are removed and cannot load Prokop
// modules; runtime_lock counts such a record as the owner while it runs.
// The owner is this process: owner_pid() can name the short-lived shell
// that popen() starts to run `echo $PPID`.
function component_lock_owner() {
    let pid = as_string(fs.readlink("/proc/self"));
    return match(pid, /^[1-9][0-9]*$/) != null ? pid : "";
}

function acquire_component_lock() {
    ensure_dir(RUNTIME_STATE_DIR);
    lock_held = runtime_lock.acquire(COMPONENT_LOCK_DIR, component_lock_owner());
    return lock_held;
}

function release_component_lock() {
    if (!lock_held)
        return;
    runtime_lock.release(COMPONENT_LOCK_DIR, component_lock_owner());
    lock_held = false;
}

// The upgrade marker lets the start that follows this action's package
// upgrade wait for the old sing-box. Once the action ends it names no
// transition, and a leftover would turn the user's next Stop into a guarded
// one (UC-217): the action removes the marker it wrote.
function remove_managed_upgrade_sing_box_marker() {
    if (managed_upgrade_marker_written)
        remove_file(MANAGED_UPGRADE_SING_BOX_MARKER);
    managed_upgrade_marker_written = false;
}

function cleanup_action() {
    remove_managed_upgrade_sing_box_marker();
    cleanup_tmp_dir();
    release_component_lock();
}

// A failed action also says why with a stable reason (UC-119): busy,
// invalid_input or failure; message stays the English text.
function updates_response(success, component, action, message, current_version, latest_version, changed, status, release_url, reason) {
    let value = {
        success: !!success,
        kind: "component",
        component: as_string(component),
        action: as_string(action),
        message: as_string(message),
        current_version: as_string(current_version),
        latest_version: as_string(latest_version),
        changed: int(changed || 0),
        status: as_string(status),
        release_url: as_string(release_url)
    };
    if (!value.success)
        value.reason = as_string(reason) != "" ? as_string(reason) : "failure";
    if (torrserver_settings_applied != null)
        value.settings_applied = torrserver_settings_applied;
    write_json(value);
}

function prokop_status_running_with_timeout() {
    init_tmp_dir();
    let output_file = make_tmp_file("prokop-status");
    if (output_file == "")
        return false;

    let command = command_from_args([ BIN_PATH, "get_status" ]) + " >" + shell_quote(output_file) + " 2>/dev/null & pid=$!; " +
        "( sleep 6; kill $pid 2>/dev/null || true ) & watcher=$!; " +
        "wait $pid 2>/dev/null; rc=$?; kill $watcher 2>/dev/null || true; wait $watcher 2>/dev/null || true; exit $rc";
    let ok = command_status("sh -c " + shell_quote(command)) == 0 &&
        match(read_file(output_file), /"running"[ \t]*:[ \t]*1/) != null;
    remove_file(output_file);
    return ok;
}

// `init.d start|restart` exits 0 under procd before the detached start has
// run; service/initd.uc start-and-wait waits for the start's own result and
// then checks the runtime (UC-013). An older release that this action has
// just installed has no start-and-wait: then the runtime is polled after
// init.d, as restore_prokop_opkg_service does. A start that follows
// Prokop's own stop names that stop's request (after_stop): a stop requested
// after it wins over the start (service/initd.uc start_service).
function prokop_start_and_wait(action, after_stop) {
    let initd_module = LIB_DIR + "/service/initd.uc";
    if (index(read_file(initd_module), '"start-and-wait"') >= 0) {
        if (as_string(after_stop) == "")
            return module_success([ initd_module, "start-and-wait", action ]);
        return module_success_env({ PROKOP_START_AFTER_STOP: after_stop }, [ initd_module, "start-and-wait", action ]);
    }
    if (!command_success_from_args([ SERVICE_INIT, action ]))
        return false;
    for (let attempt = 0; attempt < 45; attempt++) {
        command_success_from_args([ "sleep", "4" ]);
        if (prokop_status_running_with_timeout())
            return true;
    }
    return false;
}

// The user's stop holds Prokop down until an explicit start (D-15). A stop
// made while the action ran stays the user's through Prokop's own stops for
// the change (service/initd.uc stop_request_source); the start that puts
// back the state noted when the action began must not undo it.
function stop_request_by_user(request) {
    let by = match(request, /(^|\n)by=([a-z]*)/);
    return by == null || by[2] == "user";
}

function prokop_stopped_by_user() {
    let request = fs.readfile(STOP_REQUESTED_FILE);
    return request != null && stop_request_by_user(request);
}

// The stop request after Prokop's own stop, read once: its first line, ""
// when none is recorded, null when it is the user's stop (D-15).
function own_stop_request() {
    let request = fs.readfile(STOP_REQUESTED_FILE);
    if (request == null)
        return "";
    if (stop_request_by_user(request))
        return null;
    return split(request, "\n")[0];
}

// Prokop's own stop for a component change, followed by a start: not the
// user's stop (service/initd.uc stop_request_source). With cleanup, Prokop
// is down already, stopped for this change: no runtime runs that the
// ownership guard would keep, and the stop ends what is left of it (a
// sing-box that runs Prokop's configuration) as the user's Stop does
// (PROKOP_STOP_CLEANUP, service/lifecycle.uc stop).
function prokop_stop_for_component_change_args(cleanup) {
    let args = [ "env", "PROKOP_STOP_SOURCE=component" ];
    if (cleanup)
        push(args, "PROKOP_STOP_CLEANUP=1");
    push(args, SERVICE_INIT, "stop");
    return args;
}

// The restart that applies a change: Prokop's own stop for it, then the
// awaited start. The stop of an init.d restart is recorded as the user's,
// and a restart that failed before its start removed that record (its stop
// failed, its start was deferred past the wait) then read as the user's
// stop: the failed change as one that the user's stop overtook (UC-235).
// A stop that the user made meanwhile holds: no start follows it. The stop
// and the start each take procd's lock, and a user's stop that waited for
// it behind Prokop's own stop runs before the start, also after the request
// was read here: the start compares with Prokop's own stop request and
// leaves Prokop down after any later stop. 0 when Prokop runs again, 2 when
// its own stop was refused: another sing-box makes the ownership of the
// runtime ambiguous, and service/lifecycle.uc changed nothing (UC-215).
// That is no failed start, and a second restart is refused alike.
function prokop_restart_and_wait() {
    let status = command_status_from_args(prokop_stop_for_component_change_args(prokop_stopped_for_sing_box_change));
    if (status != 0)
        return status == 2 ? 2 : 1;
    let after_stop = own_stop_request();
    if (after_stop == null)
        return 1;
    return prokop_start_and_wait("start", after_stop) ? 0 : 1;
}

const PROKOP_RESTART_REFUSED = "Prokop was not restarted: another sing-box process makes the ownership of its runtime ambiguous";
// For a change that stays in place.
const PROKOP_RESTART_REFUSED_APPLIES_LATER = PROKOP_RESTART_REFUSED + "; the change applies at its next start";

// How a change ends that did not bring Prokop back; the change stays.
function prokop_not_restarted_text() {
    return prokop_restart_refused ? PROKOP_RESTART_REFUSED_APPLIES_LATER : "Prokop did not start again";
}

// Nor does its restart fallback: a start that the user's stop overtook
// failed for the stop, which wins (UC-235). The start follows Prokop's own
// stop for the change, as prokop_restart_and_wait's does: a user's stop
// that comes after the check here, before the start, wins as well.
function restart_prokop_after_failed_sing_box_change() {
    if (!prokop_stopped_for_sing_box_change || !prokop_was_running || !file_exists(SERVICE_INIT))
        return;
    let after_stop = own_stop_request();
    if (after_stop == null) {
        updates_log("Prokop was stopped by the user during the sing-box component change; it is not started again");
        return;
    }
    updates_log("Restarting Prokop after failed sing-box component change");
    if (prokop_start_and_wait("start", after_stop) || prokop_stopped_by_user())
        return;
    if (prokop_restart_and_wait() != 0 && !prokop_stopped_by_user())
        updates_log("Prokop did not start again after the failed sing-box component change", "error");
}

// Prokop's own stop for an in-app upgrade is followed by a start. When the
// upgrade fails after that stop, nothing else brings back the Prokop that was
// running: a reload does not start a stopped runtime (D-15). It is started
// here and its start awaited (UC-196, UC-013), unless the package scripts or
// the rollback already did. The upgrade marker names no transition any more,
// and a stale one would refuse this start (UC-217). Only a start: the stop of
// an init.d restart would be recorded as the user's. It follows the stop
// request in effect, Prokop's own: a user's stop requested after the check
// here wins over it (service/initd.uc start_service; D-15(a)).
function restart_prokop_after_failed_upgrade() {
    if (!prokop_stopped_for_upgrade || !prokop_was_running || !file_exists(SERVICE_INIT))
        return;
    prokop_stopped_for_upgrade = false;
    if (prokop_status_running_with_timeout())
        return;
    let after_stop = own_stop_request();
    if (after_stop == null) {
        updates_log("Prokop was stopped by the user during the upgrade; it is not started again");
        return;
    }
    remove_managed_upgrade_sing_box_marker();
    updates_log("Starting Prokop again after the failed Prokop upgrade");
    if (!prokop_start_and_wait("start", after_stop) && !prokop_stopped_by_user())
        updates_log("Prokop did not start again after the failed Prokop upgrade", "error");
}

function action_success(component, action, message, current_version, latest_version, changed, status, release_url) {
    progress?.finish?.(true);
    updates_response(true, component, action, message, current_version, latest_version, changed || 0, status || "", release_url || "");
    cleanup_action();
    exit(0);
}

function action_fail(component, action, message, current_version, latest_version, status, release_url, reason) {
    updates_log(message, "error");
    // Starting the stopped Prokop again may take minutes: not under the
    // stage that failed (PRG-4).
    if (prokop_was_running && (prokop_stopped_for_sing_box_change || prokop_stopped_for_upgrade))
        progress?.stage?.("rollback");
    restart_prokop_after_failed_sing_box_change();
    restart_prokop_after_failed_upgrade();
    progress?.finish?.(false);
    updates_response(false, component, action, message, current_version || "", latest_version || "", 0, status || "", release_url || "",
        reason);
    cleanup_action();
    exit(1);
}

function run_logged_status(description, command) {
    init_tmp_dir();
    let output_file = make_tmp_file("command");
    if (output_file == "")
        output_file = "/tmp/prokop-updates-command." + owner_pid();

    updates_log(description);
    let status = command_status(as_string(command) + " >" + shell_quote(output_file) + " 2>&1");
    last_logged_output = read_file(output_file);
    for (let line in split(last_logged_output, "\n"))
        if (trim(as_string(line)) != "")
            updates_log(line);
    remove_file(output_file);
    if (status != 0)
        updates_log(description + " failed with exit code " + status, "warn");
    return status;
}

function run_logged(description, command) {
    return run_logged_status(description, command) == 0;
}

function is_apk() {
    return command_exists("apk");
}

function pkg_is_installed(package_name) {
    package_name = as_string(package_name);
    if (is_apk())
        return command_success_from_args([ "apk", "info", "-e", package_name ]);
    return module_success([ LIB_DIR + "/core/packages.uc", "opkg-installed", package_name ]);
}

function installed_package_version(package_name) {
    package_name = as_string(package_name);
    if (is_apk()) {
        if (!pkg_is_installed(package_name))
            return "";
        return trim(module_output([ LIB_DIR + "/core/packages.uc", "apk-version", package_name ]));
    }
    return trim(module_output([ LIB_DIR + "/core/packages.uc", "opkg-version", package_name ]));
}

function opkg_package_version_from_list(package_name, output) {
    return trim(helper_output_input(output, "updates-opkg-package-version", [ package_name ]));
}

function available_package_version(package_name) {
    package_name = as_string(package_name);
    if (is_apk())
        return trim(module_output([ LIB_DIR + "/core/packages.uc", "apk-available-version", package_name ]));
    return opkg_package_version_from_list(package_name, command_output_from_args([ "opkg", "list", package_name ]));
}

const PKG_LIST_UPDATE_TIMEOUT = int(getenv("PROKOP_PKG_LIST_UPDATE_TIMEOUT") || "180");
const PKG_LOCK_RETRIES = int(getenv("PROKOP_PKG_LOCK_RETRIES") || "15");

// The list update gets a deadline: a feed that never answers held the
// component action forever. When another opkg or apk (LuCI Software, cron)
// holds the package database lock, it is retried every 2 s instead of
// failing at once (A4).
function pkg_list_update_command() {
    let update = is_apk() ? "apk update" : "opkg update";
    let script = "tries=0; " +
        "while :; do " +
        "out=$(mktemp \"${TMPDIR:-/tmp}/prokop-pkg-update.XXXXXX\") || exit 1; " +
        update + " </dev/null >\"$out\" 2>&1 & child=$!; " +
        "elapsed=0; while kill -0 \"$child\" 2>/dev/null && [ \"$elapsed\" -lt " + PKG_LIST_UPDATE_TIMEOUT + " ]; do sleep 1; elapsed=$((elapsed + 1)); done; " +
        "timed_out=0; if kill -0 \"$child\" 2>/dev/null; then timed_out=1; kill -TERM \"$child\" 2>/dev/null; sleep 1; kill -KILL \"$child\" 2>/dev/null; fi; " +
        "wait \"$child\"; rc=$?; cat \"$out\"; " +
        "if [ \"$timed_out\" -eq 1 ]; then rm -f \"$out\"; echo \"" + update + " did not finish in " + PKG_LIST_UPDATE_TIMEOUT + " s\"; exit 124; fi; " +
        "if [ \"$rc\" -ne 0 ] && [ \"$tries\" -lt " + PKG_LOCK_RETRIES + " ] && " +
        "grep -Eq 'Could not lock|Unable to lock database|Resource temporarily unavailable' \"$out\"; then " +
        "rm -f \"$out\"; tries=$((tries + 1)); echo \"Package database is locked; retrying ($tries/" + PKG_LOCK_RETRIES + ")\"; sleep 2; continue; fi; " +
        "rm -f \"$out\"; exit \"$rc\"; " +
        "done";
    return command_from_args([ "sh", "-c", script ]);
}

function pkg_install_name_command(package_name) {
    return is_apk() ? command_from_args([ "apk", "add", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "install", package_name ]) + " </dev/null";
}

function pkg_install_name_downgrade(package_name, package_version) {
    package_name = as_string(package_name);
    if (is_apk()) {
        package_version = as_string(package_version);
        if (package_version == "")
            return false;
        let package_spec = package_name + "=" + package_version;
        let installed = pkg_is_installed(package_name)
            ? command_success(command_from_args([ "apk", "add", "--force-reinstall", "--upgrade", package_spec ]) + " </dev/null")
            : command_success(command_from_args([ "apk", "add", package_spec ]) + " </dev/null");
        // apk keeps "name=version" in /etc/apk/world: apk upgrade and LuCI
        // Software would never update the package again, security releases
        // included (UPD-3). The same version, named without one, unpins it.
        if (installed && !command_success(command_from_args([ "apk", "add", package_name ]) + " </dev/null"))
            updates_log("Could not unpin " + package_name + " in /etc/apk/world; apk upgrade will keep version " + package_version, "warn");
        return installed;
    }

    return command_success(command_from_args([ "opkg", "install", "--force-overwrite", "--force-reinstall", "--force-downgrade", package_name ]) + " </dev/null") ||
        command_success(command_from_args([ "opkg", "install", "--force-downgrade", package_name ]) + " </dev/null");
}

const OPKG_LISTS_DIR = getenv("PROKOP_OPKG_LISTS_DIR") || "";

function opkg_lists_dir() {
    if (OPKG_LISTS_DIR != "")
        return OPKG_LISTS_DIR;
    for (let line in split(read_file("/etc/opkg.conf"), "\n")) {
        let found = match(trim(line), /^lists_dir[ \t]+[^ \t]+[ \t]+([^ \t]+)$/);
        if (found != null)
            return found[1];
    }
    return "/var/opkg-lists";
}

// The SHA256sum values the feed indexes list for a package; opkg update
// checked those indexes against their signatures. Streamed through awk: the
// indexes are megabytes once unpacked.
function opkg_feed_package_sha256s(package_name) {
    let script = 'for f in "$2"/*; do case "$f" in *.sig) continue ;; esac; [ -f "$f" ] || continue; ' +
        'if gunzip -t "$f" 2>/dev/null; then gunzip -c "$f"; else cat "$f"; fi; echo; done | ' +
        'awk -v pkg="$1" \'/^Package: / { name = $2 } name == pkg && /^SHA256sum: / { print tolower($2) }\'';
    return filter(split(command_output_from_args([ "sh", "-c", script, "sh", package_name, opkg_lists_dir() ]), "\n"),
        (line) => match(line, /^[0-9a-f]{64}$/) != null);
}

// UPD-14: the package fetched while the running variant still served (B7) is
// the one installed, so the feed is not asked again while Prokop is stopped.
// apk checks the signature of the file with its trusted keys (no
// --allow-untrusted); for opkg the file must match a SHA256sum of the signed
// feed index. false sends the caller to the install by name, as before.
function pkg_install_fetched_file(package_name, package_file) {
    package_name = as_string(package_name);
    package_file = as_string(package_file);
    if (package_file == "" || !file_exists(package_file))
        return false;
    if (is_apk()) {
        let args = pkg_is_installed(package_name) ?
            [ "apk", "add", "--force-reinstall", "--upgrade", package_file ] : [ "apk", "add", package_file ];
        if (!command_success(command_from_args(args) + " </dev/null"))
            return false;
        // A file is kept in /etc/apk/world by its hash: naming the package
        // unpins it, as for an exact version (UPD-3).
        if (!command_success(command_from_args([ "apk", "add", package_name ]) + " </dev/null"))
            updates_log("Could not unpin " + package_name + " in /etc/apk/world; apk upgrade will keep this version", "warn");
        return true;
    }
    let sum = split(trim(command_output_from_args([ "sha256sum", package_file ])), /[ \t]+/)[0];
    if (match(sum, /^[0-9a-f]{64}$/) == null || index(opkg_feed_package_sha256s(package_name), sum) < 0) {
        updates_log("The downloaded " + package_name + " package is not listed in the package feed index; installing it from the feed", "warn");
        return false;
    }
    return command_success(command_from_args([ "opkg", "install", "--force-overwrite", "--force-reinstall", "--force-downgrade", package_file ]) + " </dev/null") ||
        command_success(command_from_args([ "opkg", "install", "--force-downgrade", package_file ]) + " </dev/null");
}

function pkg_install_files_command(files) {
    let args = is_apk() ? [ "apk", "add", "--allow-untrusted" ] : [ "opkg", "install", "--force-overwrite", "--force-downgrade" ];
    for (let file in files)
        push(args, file);
    return command_from_args(args) + " </dev/null";
}

function array_has(values, needle) {
    for (let value in values)
        if (as_string(value) == as_string(needle))
            return true;
    return false;
}

// opkg refuses a package whose dependencies are not installed yet, and the
// sing-box variant switch removes the current package first. Resolve the
// dependencies from a dry run and install them while the old variant is still
// in place, so a missing dependency cannot leave the router without sing-box.
// Returns null when the dry run itself could not be interpreted.
function opkg_sing_box_dependencies_to_install(package_path, package_name) {
    if (is_apk())
        return [];

    let simulation = command_from_args([
        "opkg", "--noaction", "--force-space", "install", "--force-overwrite", "--force-downgrade", package_path
    ]);
    if (!run_logged("Checking sing-box package dependencies", simulation)) {
        let pending = "";
        let missing = [];
        for (let line in split(last_logged_output, "\n")) {
            line = trim(line);
            if (match(line, /^[A-Za-z0-9][A-Za-z0-9._+-]*:$/) != null)
                pending = replace(line, /:$/, "");
            if (match(line, /masked in: --no-network/) != null && pending != "") {
                if (!array_has(missing, pending))
                    push(missing, pending);
                pending = "";
            }
        }
        return length(missing) > 0 ? missing : null;
    }

    let dependencies = [];
    for (let line in split(last_logged_output, "\n")) {
        let parsed = match(trim(line), /^Installing ([A-Za-z0-9][A-Za-z0-9._+-]*) \(/);
        if (parsed != null && parsed[1] != as_string(package_name) && !array_has(dependencies, parsed[1]))
            push(dependencies, parsed[1]);
    }
    return dependencies;
}

function install_opkg_sing_box_dependencies(package_path, package_name) {
    let dependencies = opkg_sing_box_dependencies_to_install(package_path, package_name);
    if (dependencies == null)
        return false;
    for (let dependency in dependencies) {
        if (!run_logged("Installing required sing-box dependency " + dependency,
            pkg_install_name_command(dependency)))
            return false;
    }
    return true;
}

function pkg_install_files(files) {
    return command_success(pkg_install_files_command(files));
}

function pkg_remove_sing_box_conflict(package_name) {
    package_name = as_string(package_name);
    if (!pkg_is_installed(package_name))
        return true;
    if (is_apk())
        return command_success(command_from_args([ "apk", "del", "--force-broken-world", package_name ]) + " </dev/null");
    return command_success(command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null");
}

function run_logged_pkg_remove_sing_box_conflict(package_name, description) {
    if (!pkg_is_installed(package_name)) {
        updates_log(description);
        return true;
    }

    let command = is_apk() ?
        command_from_args([ "apk", "del", "--force-broken-world", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null";
    return run_logged(description, command);
}

function compare_versions(lhs, rhs) {
    lhs = as_string(lhs);
    rhs = as_string(rhs);
    if (lhs == "" || rhs == "")
        return null;
    if (lhs == rhs)
        return 0;

    if (is_apk()) {
        let apk_result = trim(command_output_from_args([ "apk", "version", "-t", lhs, rhs ]));
        if (apk_result == ">")
            return 1;
        if (apk_result == "<")
            return -1;
        if (apk_result == "=")
            return 0;
    }

    if (command_exists("opkg")) {
        if (command_success_from_args([ "opkg", "compare-versions", lhs, ">", rhs ]))
            return 1;
        if (command_success_from_args([ "opkg", "compare-versions", lhs, "<", rhs ]))
            return -1;
        if (command_success_from_args([ "opkg", "compare-versions", lhs, "=", rhs ]))
            return 0;
    }

    return module_success([ LIB_DIR + "/core/helpers.uc", "version-at-least", lhs, rhs ]) ? 1 : -1;
}

function status_from_compare(compare_result) {
    if (compare_result == -1)
        return "outdated";
    if (compare_result == 0)
        return "latest";
    if (compare_result == 1)
        return "dev";
    return "";
}

function check_success_compared(component, current_version, latest_version, compare_current_version, compare_latest_version, release_url) {
    let compare_result = compare_versions(compare_current_version, compare_latest_version);
    if (compare_result == null)
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let status = status_from_compare(compare_result);
    if (status == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let result_row = trim(helper_output("updates-check-result-row", [ component, current_version, latest_version, status ]));
    if (result_row == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let fields = split(result_row, "\t");
    let message = as_string(fields[0] || "");
    let log_line = length(fields) > 1 ? as_string(fields[1]) : message;
    updates_log(log_line);
    action_success(component, "check_update", message, current_version, latest_version, 0, status, release_url || "");
}

function check_success(component, current_version, latest_version, release_url) {
    check_success_compared(component, current_version, latest_version, current_version, latest_version, release_url || "");
}

function read_openwrt_release_value(key) {
    return trim(helper_output("openwrt-release-value", [ "/etc/openwrt_release", key ]));
}

function service_proxy_address() {
    if (!file_exists(LIB_DIR + "/singbox/runtime.uc"))
        return "";
    if (file_exists(LIB_DIR + "/service/state.uc") &&
        !module_success([ LIB_DIR + "/service/state.uc", "sing-box-service-running" ]))
        return "";
    return trim(module_output([ LIB_DIR + "/singbox/runtime.uc", "service-proxy-address", "components" ]));
}

// Runs the download in the background and reports the bytes already in
// OUTPUT_PATH once a second until it exits; its exit status, or 1 when it
// cannot be followed. A download that outlives its own timeout by a margin
// is stopped, after its identity is checked.
// The download runs in the background of a subshell that records its pid and
// waits for it: on the deadline the download itself is killed, not only the
// subshell, which left curl or wget running as an orphan (PRG-5). The
// deadline is on the monotonic clock: an NTP step right after boot must not
// cut a transfer as stalled (PRG-2). The poll sleeps in-process instead of
// forking sleep(1) every second.
const DOWNLOAD_DEADLINE_SLACK = int(getenv("PROKOP_DOWNLOAD_DEADLINE_SLACK") || "30");

function download_status_watched(command, output_path, timeout, watch) {
    let rc_file = make_tmp_file("download-rc");
    if (rc_file == "")
        return command_status(command);
    remove_file(rc_file);
    let pid_file = rc_file + ".pid";
    remove_file(pid_file);
    let pid = trim(command_output("sh -c " + shell_quote("(" + command + " >/dev/null 2>&1 </dev/null & echo $! >" + shell_quote(pid_file) +
        "; wait $!; echo $? >" + shell_quote(rc_file) + ") </dev/null >/dev/null 2>&1 & echo $!")));
    if (match(pid, /^[1-9][0-9]*$/) == null) {
        remove_file(pid_file);
        return 1;
    }
    let ticks = process_identity.start_ticks(pid);
    let deadline = clock(true)[0] + int(timeout) + DOWNLOAD_DEADLINE_SLACK;
    let reported = -1;
    let finish = (rc) => {
        remove_file(rc_file);
        remove_file(pid_file);
        return rc;
    };
    for (;;) {
        let rc = trim(read_file(rc_file));
        if (match(rc, /^[0-9]+$/) != null)
            return finish(int(rc));
        let alive = ticks != "" && process_identity.start_ticks(pid) == ticks;
        if (!alive) {
            // It may have written the status just before it exited.
            rc = trim(read_file(rc_file));
            return finish(match(rc, /^[0-9]+$/) != null ? int(rc) : 1);
        }
        if (clock(true)[0] > deadline) {
            let child = trim(read_file(pid_file));
            if (match(child, /^[1-9][0-9]*$/) != null && process_identity.parent_pid(child) == pid)
                command_success_from_args([ "kill", child ]);
            command_success_from_args([ "kill", pid ]);
            return finish(1);
        }
        let bytes = file_bytes(output_path);
        if (bytes != reported) {
            progress?.download?.(watch.label, bytes, watch.total, watch.index, watch.count);
            reported = bytes;
        }
        sleep(1000);
    }
}

function http_get_once(url, output_path, proxy_address, timeout, watch) {
    url = as_string(url);
    output_path = as_string(output_path);
    proxy_address = as_string(proxy_address);
    timeout = as_string(timeout || "30");

    if (command_exists("curl")) {
        // A stalled transfer is cut after 30 s below 1 KiB/s, so a slow but
        // moving download may use the whole -m budget (B4).
        let args = [ "curl", "--connect-timeout", "5", "-m", timeout, "-fsSL",
            "--speed-time", "30", "--speed-limit", "1024" ];
        // The size the release publishes caps the transfer: a wrong or
        // endless answer stops there instead of filling tmpfs.
        if (type(watch) == "object" && int(watch.total) > 0) {
            push(args, "--max-filesize");
            push(args, sprintf("%d", int(watch.total)));
        }
        if (proxy_address != "") {
            push(args, "-x");
            push(args, "http://" + proxy_address);
        }
        push(args, url);
        push(args, "-o");
        push(args, output_path);
        if (type(watch) == "object" && progress?.active?.())
            return download_status_watched(command_from_args(args), output_path, timeout, watch) == 0;
        return command_success_from_args(args);
    }

    if (command_exists("wget")) {
        let command = command_from_args([ "wget", "-T", timeout, "-q", "-O", output_path, url ]);
        if (proxy_address != "")
            command = command_env({ http_proxy: "http://" + proxy_address, https_proxy: "http://" + proxy_address }) + " " + command;
        if (type(watch) == "object" && progress?.active?.())
            return download_status_watched(command, output_path, timeout, watch) == 0;
        return command_success(command);
    }

    return false;
}

function http_get(url) {
    init_tmp_dir();
    let output_path = make_tmp_file("http");
    if (output_path == "")
        return "";

    let proxy_address = service_proxy_address();
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, "30")) {
            let data = read_file(output_path);
            remove_file(output_path);
            return data;
        }
        remove_file(output_path);
        updates_log("HTTP request via service proxy failed for " + as_string(url) + "; retrying directly", "warn");
    }

    if (http_get_once(url, output_path, "", "30")) {
        let data = read_file(output_path);
        remove_file(output_path);
        return data;
    }

    remove_file(output_path);
    return "";
}

// Package archives run to tens of megabytes: on a slow uplink 120 s was not
// enough to finish one that was still arriving (B4).
const COMPONENT_DOWNLOAD_TIMEOUT = getenv("PROKOP_COMPONENT_DOWNLOAD_TIMEOUT") || "600";

function download_file_once(url, output_path, watch) {
    let proxy_address = service_proxy_address();
    if (proxy_address != "") {
        if (http_get_once(url, output_path, proxy_address, COMPONENT_DOWNLOAD_TIMEOUT, watch))
            return true;
        remove_file(output_path);
        updates_log("Download via service proxy failed for " + as_string(url) + "; retrying directly", "warn");
    }
    return http_get_once(url, output_path, "", COMPONENT_DOWNLOAD_TIMEOUT, watch);
}

// TOTAL is the size the release publishes (0 when unknown); NUMBER and COUNT
// say which of the action's downloads this is, when it makes several.
function download_with_retry(url, output_path, label, total, number, count) {
    // The rollback copy prepare_prokop_package_set fetches stays in its stage.
    if (progress?.current?.() != "prepare")
        progress?.stage?.("download");
    let watch = { label: path_basename(label), total: int(total || 0), index: int(number || 0), count: int(count || 0) };
    for (let attempt = 1; attempt <= 3; attempt++) {
        updates_log("Downloading " + as_string(label) + " (" + attempt + "/3)");
        progress?.download?.(watch.label, 0, watch.total, watch.index, watch.count);
        if (download_file_once(url, output_path, watch) && file_nonempty(output_path))
            return true;
        remove_file(output_path);
        updates_log("Retrying " + as_string(label), "warn");
    }
    return false;
}

// GitHub reports an asset checksum as digest "sha256:<hex>" (older assets have
// none); the static release channel also writes a plain sha256 field.
function release_asset_object_sha256(asset) {
    if (type(asset) != "object")
        return "";
    let value = lc(as_string(asset.sha256));
    if (match(value, /^[a-f0-9]{64}$/) != null)
        return value;
    value = lc(as_string(asset.digest));
    if (substr(value, 0, 7) == "sha256:" && match(substr(value, 7), /^[a-f0-9]{64}$/) != null)
        return substr(value, 7);
    return "";
}

// The size in bytes GitHub reports for an asset; 0 when it reports none.
function release_asset_object_size(asset) {
    return type(asset) == "object" && type(asset.size) == "int" && asset.size > 0 ? asset.size : 0;
}

// The asset record in a release document whose `key` field equals `value`.
function release_json_asset(release_json, key, value) {
    let release = parse_json_object(release_json);
    for (let asset in (type(release.assets) == "array" ? release.assets : []))
        if (type(asset) == "object" && as_string(asset[key]) == as_string(value))
            return asset;
    return null;
}

// The checksum published for that asset; empty when it publishes none.
function release_json_asset_sha256(release_json, key, value) {
    return release_asset_object_sha256(release_json_asset(release_json, key, value));
}

// The asset record for the download at `url`, in a release document or a
// list of releases; null when none matches.
function release_url_asset(releases_json, url) {
    let value = null;
    try {
        value = json(as_string(releases_json));
    }
    catch (e) {
        return null;
    }
    for (let release in (type(value) == "array" ? value : [ value ])) {
        if (type(release) != "object" || type(release.assets) != "array")
            continue;
        for (let asset in release.assets)
            if (type(asset) == "object" && as_string(asset.browser_download_url) == as_string(url))
                return asset;
    }
    return null;
}

// The checksum GitHub publishes for the asset downloaded from `url`; empty
// when it publishes none.
function release_url_asset_sha256(releases_json, url) {
    return release_asset_object_sha256(release_url_asset(releases_json, url));
}

function release_url_asset_size(releases_json, url) {
    return release_asset_object_size(release_url_asset(releases_json, url));
}

// An empty expectation means the source published no checksum to compare.
function download_checksum_ok(path, expected) {
    expected = as_string(expected);
    if (expected == "")
        return true;
    if (progress?.current?.() != "prepare")
        progress?.stage?.("verify");
    let actual = split(trim(command_output_from_args([ "sha256sum", path ])), /[ \t]+/)[0];
    return lc(as_string(actual)) == expected;
}

function fetch_github_release_json(owner, repo) {
    let response = http_get("https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases/latest");
    if (response == "" || !helper_success_input(response, "github-response-ok", []))
        return "";
    return response;
}

function fetch_github_releases_json(owner, repo, per_page) {
    let response = http_get("https://api.github.com/repos/" + as_string(owner) + "/" + as_string(repo) + "/releases?per_page=" + as_string(per_page || "30"));
    if (response == "" || !helper_success_input(response, "github-response-ok", []))
        return "";
    return response;
}

function latest_prokop_release_json() {
    if (PROKOP_RELEASE_BASE_URL != "") {
        let release_base_url = PROKOP_RELEASE_BASE_URL;
        while (substr(release_base_url, length(release_base_url) - 1, 1) == "/")
            release_base_url = substr(release_base_url, 0, length(release_base_url) - 1);
        let response = http_get(release_base_url + "/updates/latest.json");
        if (response != "" && trim(helper_output_input(response, "release-metadata-tsv", [])) != "")
            return response;
    }

    let parts = split(PROKOP_RELEASE_REPO, "/");
    if (length(parts) != 2 || as_string(parts[0]) == "" || as_string(parts[1]) == "")
        return "";
    return fetch_github_release_json(parts[0], parts[1]);
}

function prokop_release_url(value) {
    value = as_string(value);
    if (value == "" || substr(value, 0, 7) == "http://" || substr(value, 0, 8) == "https://")
        return value;
    if (PROKOP_RELEASE_BASE_URL != "") {
        let release_base_url = PROKOP_RELEASE_BASE_URL;
        while (substr(release_base_url, length(release_base_url) - 1, 1) == "/")
            release_base_url = substr(release_base_url, 0, length(release_base_url) - 1);
        if (substr(value, 0, 1) == "/")
            return release_base_url + value;
        return release_base_url + "/" + value;
    }
    return value;
}

function prokop_mirror_url(value) {
    value = as_string(value);
    if (value == "" || substr(value, 0, 7) == "http://" || substr(value, 0, 8) == "https://")
        return value;
    if (PROKOP_MIRROR_BASE_URL != "") {
        if (substr(value, 0, 1) == "/")
            return PROKOP_MIRROR_BASE_URL + value;
        return PROKOP_MIRROR_BASE_URL + "/" + value;
    }
    return value;
}

// The catalog is an index of what the release channel actually holds, shipped
// with each release bundle. Accept an entry only when every package it names
// carries a checksum and a download URL under this release's own directory: a
// rewritten catalog must not be able to point an install at some other file.
function parse_prokop_release_catalog(response, ext) {
    let catalog;
    try { catalog = json(response); } catch (e) { return []; }
    if (type(catalog) != "object" || catalog.format != 1 || type(catalog.releases) != "array")
        return [];

    let releases = [];
    for (let release in catalog.releases) {
        if (type(release) != "object" || type(release.assets) != "array" ||
            match(as_string(release.tag_name), /^[0-9]+[.][0-9]+[.][0-9]+$/) == null)
            continue;

        let suffix = "/releases/" + release.tag_name + "/";
        let complete = true;
        for (let kind in [ "prokop", "luci-app-prokop", "luci-i18n-prokop-ru" ]) {
            let wanted = kind + "_" + release.tag_name + "." + ext;
            let found = false;
            for (let asset in release.assets) {
                if (type(asset) != "object" || as_string(asset.name) != wanted ||
                    match(as_string(asset.sha256), /^[a-f0-9]{64}$/) == null)
                    continue;
                let url = as_string(asset.browser_download_url);
                if (url == prokop_release_url(suffix + wanted) ||
                    url == suffix + wanted)
                    found = true;
            }
            if (!found)
                complete = false;
        }
        if (complete)
            push(releases, release);
    }
    return releases;
}

function prokop_release_catalog() {
    if (PROKOP_RELEASE_BASE_URL == "")
        return [];
    let base = PROKOP_RELEASE_BASE_URL;
    while (substr(base, length(base) - 1, 1) == "/")
        base = substr(base, 0, length(base) - 1);
    return parse_prokop_release_catalog(http_get(base + "/updates/releases.json"),
        is_apk() ? "apk" : "ipk");
}

function selected_prokop_release(version) {
    version = as_string(version);
    for (let release in prokop_release_catalog())
        if (as_string(release.tag_name) == version)
            return release;
    return null;
}

function prokop_releases() {
    let rows = [];
    for (let release in prokop_release_catalog())
        push(rows, { version: as_string(release.tag_name), channel: "stable" });
    // No release could be listed: a failure, with its exit code (UC-118).
    let answer = { success: length(rows) > 0, releases: rows };
    if (!answer.success) {
        answer.reason = "failure";
        answer.message = "No Prokop release could be listed";
    }
    print(sprintf("%J", answer), "\n");
    cleanup_tmp_dir();
    return answer.success;
}

function prokop_release_page_url(version, fallback) {
    let parts = split(PROKOP_RELEASE_REPO, "/");
    version = as_string(version);
    if (length(parts) == 2 &&
        match(as_string(parts[0]), /^[A-Za-z0-9_.-]+$/) != null &&
        match(as_string(parts[1]), /^[A-Za-z0-9_.-]+$/) != null &&
        match(version, /^[0-9]+[.][0-9]+[.][0-9]+$/) != null)
        return "https://github.com/" + parts[0] + "/" + parts[1] + "/releases/tag/" + version;

    return prokop_release_url(fallback);
}

function latest_prokop_version() {
    let response = latest_prokop_release_json();
    if (response == "")
        return "";
    return trim(helper_output_input(response, "object-get-default", [ "tag_name", "" ]));
}

function fetch_prokop_latest_release_metadata() {
    let response = latest_prokop_release_json();
    if (response == "")
        return "";
    return trim(helper_output_input(response, "release-metadata-tsv", []));
}

function write_prokop_latest_version_cache(value, timestamp) {
    if (as_string(value) == "")
        return;
    write_file("/tmp/prokop.latest-version.cache", as_string(value) + "\n" + as_string(timestamp) + "\n");
}

function retry_resolve(description, fn) {
    for (let attempt = 1; attempt <= 3; attempt++) {
        if (fn())
            return true;
        updates_log(as_string(description) + " failed (" + attempt + "/3)", "warn");
        command_success_from_args([ "sleep", "2" ]);
    }
    return false;
}

function ensure_package_tool(tool_name, package_name, component, action) {
    if (command_exists(tool_name))
        return true;
    progress?.stage?.("lists");
    if (!run_logged("Updating package lists before installing " + as_string(package_name), pkg_list_update_command()))
        return false;
    return run_logged("Installing bootstrap package " + as_string(package_name), pkg_install_name_command(package_name));
}

function clear_version_caches() {
    remove_file("/tmp/prokop.latest-version.cache");
    remove_file(SYSTEM_INFO_CACHE_FILE);
    remove_file("/tmp/prokop/system-info.json");
}

function managed_sing_box_service_source(source) {
    source = as_string(source);
    return index(source, SB_MANAGED_SERVICE_MARKER) >= 0 ||
        (index(source, SB_LEGACY_MANAGED_SERVICE_MARKER) >= 0 && !legacy_forkop.installed());
}

function managed_sing_box_service_installed() {
    return file_exists("/etc/init.d/sing-box") && managed_sing_box_service_source(read_file("/etc/init.d/sing-box"));
}

// The script of singbox/managed_service.uc, the one every writer installs
// (UC-085): written only when it differs, read back and flushed before and
// after the rename, stale copies of it removed. Loaded here, as only the
// sing-box actions install it.
function install_managed_sing_box_service_script() {
    return require("singbox.managed_service").install();
}

function remove_managed_sing_box_service_script() {
    if (!managed_sing_box_service_installed())
        return true;
    command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
    command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    remove_file("/etc/init.d/sing-box");
    return true;
}

function disable_sing_box_service_config() {
    if (!uci_core.available())
        return true;
    if (!uci_core.exists("sing-box.main") && !uci_core.set_section("sing-box.main", "sing-box"))
        return false;
    if (!uci_core.set("sing-box.main.enabled", "0"))
        return false;
    return uci_core.commit("sing-box");
}

function prepare_sing_box_service_disabled() {
    disable_sing_box_service_config();
    if (file_exists("/etc/init.d/sing-box")) {
        command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
        command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    }
}

function prepare_sing_box_package_service_install() {
    prepare_sing_box_service_disabled();
    remove_managed_sing_box_service_script();
}

function capture_prokop_running_state() {
    prokop_was_running = file_exists(BIN_PATH) && prokop_status_running_with_timeout();
}

// Prokop that runs when its own stop for an upgrade comes, or whose start
// the user asked for and that waits for reload.lock (service/initd.uc
// deferred start), runs again after the upgrade: the stop takes it down or
// cancels that start, and no prerm hands a start over for it then
// (service/package.uc remember_upgrade_state). The state noted when the
// action began misses both (D-15(a), UC-012).
function capture_prokop_start_before_upgrade() {
    if (prokop_was_running || !file_exists(BIN_PATH))
        return;
    let initd_module = LIB_DIR + "/service/initd.uc";
    prokop_was_running = prokop_status_running_with_timeout() ||
        (file_exists(initd_module) && module_success([ initd_module, "deferred-start-pending" ]));
}

function capture_managed_upgrade_sing_box_marker() {
    let state_module = LIB_DIR + "/service/state.uc";
    if (!file_exists(state_module))
        return;
    if (module_success([ state_module, "write-managed-upgrade-sing-box-marker", MANAGED_UPGRADE_SING_BOX_MARKER ])) {
        managed_upgrade_marker_written = true;
        updates_log("Recorded managed sing-box provenance for package upgrade");
    }
}

// False when Prokop was running before the change and did not start again.
// A Prokop that the user stopped while the change ran stays stopped (D-15,
// UC-235), also when the user's stop overtook the restart: the stop won,
// the change itself did not fail.
function restart_prokop_after_successful_change() {
    if (!file_exists(SERVICE_INIT))
        return true;
    if (!prokop_was_running) {
        updates_log("Prokop was not running before component change; restart skipped");
        prepare_sing_box_service_disabled();
        return true;
    }
    if (prokop_stopped_by_user()) {
        updates_log("Prokop was stopped by the user during the component change; it is not started again");
        prepare_sing_box_service_disabled();
        return true;
    }
    progress?.stage?.("restart");
    updates_log("Restarting Prokop after successful component change");
    let status = prokop_restart_and_wait();
    if (status == 0)
        return true;
    if (prokop_stopped_by_user()) {
        updates_log("Prokop was stopped by the user during its restart after the component change");
        prepare_sing_box_service_disabled();
        return true;
    }
    if (status == 2) {
        prokop_restart_refused = true;
        updates_log(PROKOP_RESTART_REFUSED, "warn");
        return false;
    }
    updates_log("Prokop did not start again after the component change", "error");
    return false;
}

const SING_BOX_CHANGE_STOP_REFUSED = "Prokop was not stopped: another sing-box process makes the ownership of its runtime ambiguous; the current sing-box variant was kept";

// False when the stop was refused (status 2): another sing-box makes the
// ownership of the runtime ambiguous, and Prokop runs on untouched. The
// change must not then move DNS away from that runtime or stop its sing-box
// under ProkopTable and ip rule 105, and its failure must not restart the
// Prokop it never stopped (UC-197, UC-215).
function stop_prokop_before_sing_box_change() {
    if (prokop_stopped_for_sing_box_change)
        return true;

    progress?.stage?.("stop");
    if (prokop_was_running && file_exists(SERVICE_INIT) &&
        run_logged_status("Stopping Prokop before sing-box package change", command_from_args(prokop_stop_for_component_change_args())) == 2)
        return false;
    prokop_stopped_for_sing_box_change = true;

    if (prokop_was_running && file_exists(BIN_PATH))
        command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);

    prepare_sing_box_service_disabled();
    return true;
}

function wait_prokop_running_after_sing_box_change() {
    if (!prokop_was_running)
        return true;
    progress?.stage?.("check");
    if (!file_exists(BIN_PATH))
        return false;

    let waited = 0;
    // A cold start after a package upgrade can take minutes on slow routers:
    // lists, rule-sets and the runtime config are all rebuilt. Giving up too
    // early reported a failure for a start that was still making progress.
    // A Prokop that the user stopped is not waited for (UC-235).
    while (waited < 180) {
        if (prokop_stopped_by_user())
            return true;
        if (prokop_status_running_with_timeout()) {
            command_success_from_args([ "sleep", "8" ]);
            if (prokop_status_running_with_timeout())
                return true;
        }
        command_success_from_args([ "sleep", "4" ]);
        waited += 4;
    }
    return false;
}

function opkg_arch_list() {
    return trim(helper_output_input(command_output_from_args([ "opkg", "print-architecture" ]), "updates-opkg-arch-list", []));
}

function resolve_arch_candidates() {
    let arch_list = "";
    if (is_apk()) {
        if (file_exists("/etc/apk/arch"))
            arch_list += " " + trim(helper_output("file-whitespace-list", [ "/etc/apk/arch" ]));
        arch_list += " " + trim(command_output_from_args([ "apk", "--print-arch" ]));
    }
    else {
        arch_list = opkg_arch_list();
    }

    let release_arch = read_openwrt_release_value("DISTRIB_ARCH");
    if (release_arch != "")
        arch_list += " " + release_arch;
    if (!helper_success("string-has-whitespace-field", [ arch_list ]))
        arch_list = trim(command_output_from_args([ "uname", "-m" ]));

    let resolved = trim(helper_output("updates-arch-candidates", [ arch_list ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 2 || as_string(fields[0]) == "" || as_string(fields[1]) == "")
        return null;

    updates_log("Detected package architecture candidates: " + fields[1]);
    return {
        target: as_string(fields[0]),
        candidates: as_string(fields[1])
    };
}

function select_inner_package_path(bundle_file, component, arch, ext) {
    return trim(helper_output_input(command_output_from_args([ "unzip", "-l", bundle_file ]), "updates-zip-inner-package-path", [ component, arch, ext ]));
}

function select_archive_member_path(archive_file, member_name) {
    return trim(helper_output_input(command_output_from_args([ "tar", "-tzf", archive_file ]), "updates-archive-member-path", [ member_name ]));
}

function extract_arch_package_version(package_name, package_arch) {
    return trim(helper_output("updates-arch-package-version", [ package_name, package_arch ]));
}

function extract_zapret_bundle_version(bundle_name) {
    return trim(helper_output("updates-zapret-bundle-version", [ bundle_name ]));
}

function extract_zapret2_bundle_version(bundle_name) {
    return trim(helper_output("updates-zapret2-bundle-version", [ bundle_name ]));
}

function normalize_zapret_version(value) {
    return trim(helper_output("updates-normalize-zapret-version", [ value ]));
}

function normalize_sing_box_version(value) {
    return trim(helper_output("updates-normalize-sing-box-version", [ value ]));
}

function resolve_zapret_release(arch) {
    let release_json = fetch_github_release_json("remittor", "zapret-openwrt");
    if (release_json == "")
        return null;
    let resolved = trim(helper_output_input(release_json, "release-select-arch-suffix-asset", [ "zip", arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    let version = extract_zapret_bundle_version(fields[1]);
    if (version == "")
        version = trim(helper_output("string-remove-suffix", [ fields[1], ".zip" ]));
    return {
        arch: fields[0],
        bundle_name: fields[1],
        bundle_url: fields[2],
        bundle_sha256: release_url_asset_sha256(release_json, fields[2]),
        bundle_size: release_url_asset_size(release_json, fields[2]),
        release_url: fields[3],
        version
    };
}

function resolve_zapret2_release(arch) {
    let releases_json = fetch_github_releases_json("remittor", "zapret-openwrt", "30");
    if (releases_json == "")
        return null;
    let resolved = trim(helper_output_input(releases_json, "named-release-select-asset", [ "zapret2 ", "zapret2", "zip", arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    let version = extract_zapret2_bundle_version(fields[1]);
    if (version == "")
        version = trim(helper_output("string-remove-suffix", [ fields[1], ".zip" ]));
    return {
        arch: fields[0],
        bundle_name: fields[1],
        bundle_url: fields[2],
        bundle_sha256: release_url_asset_sha256(releases_json, fields[2]),
        bundle_size: release_url_asset_size(releases_json, fields[2]),
        release_url: fields[3],
        version
    };
}

function download_and_extract_zip_package(release, component) {
    let bundle_file = tmp_dir + "/" + release.bundle_name;
    if (!download_with_retry(release.bundle_url, bundle_file, release.bundle_name, release.bundle_size))
        return null;
    // GitHub publishes a digest for each asset: a bundle that does not match
    // it is not installed as root (UPD-4).
    if (!download_checksum_ok(bundle_file, release.bundle_sha256)) {
        updates_log("Downloaded " + release.bundle_name + " does not match its published sha256", "error");
        remove_file(bundle_file);
        return null;
    }

    let inner_package_path = is_apk() ?
        select_inner_package_path(bundle_file, component, "", "apk") :
        select_inner_package_path(bundle_file, component, release.arch, "ipk");
    if (inner_package_path == "")
        return null;

    let package_name = path_basename(inner_package_path);
    let package_file = tmp_dir + "/" + package_name;
    if (!command_success(command_from_args([ "unzip", "-p", bundle_file, inner_package_path ]) + " >" + shell_quote(package_file)) ||
        !file_nonempty(package_file))
        return null;

    let version = as_string(release.version || "");
    if (version == "")
        version = component == "zapret2" ? extract_zapret2_bundle_version(release.bundle_name) : extract_zapret_bundle_version(release.bundle_name);
    if (version == "")
        version = extract_arch_package_version(package_name, release.arch);

    return {
        name: package_name,
        file: package_file,
        version
    };
}

function resolve_byedpi_release(arch) {
    let asset_ext = is_apk() ? "apk" : "ipk";
    let release_series = trim(helper_output("openwrt-release-series", [ "/etc/openwrt_release" ]));
    let releases_json = fetch_github_releases_json("DPITrickster", "ByeDPI-OpenWrt", "30");
    if (releases_json == "")
        return null;
    let resolved = trim(helper_output_input(releases_json, "byedpi-select-asset", [ release_series, asset_ext, arch.candidates ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 4)
        return null;
    return {
        arch: fields[0],
        package_name: fields[1],
        package_url: fields[2],
        package_sha256: release_url_asset_sha256(releases_json, fields[2]),
        package_size: release_url_asset_size(releases_json, fields[2]),
        release_url: fields[3],
        version: extract_arch_package_version(fields[1], fields[0])
    };
}

function download_byedpi_package(release) {
    let package_file = tmp_dir + "/" + release.package_name;
    if (!download_with_retry(release.package_url, package_file, release.package_name, release.package_size) || !file_nonempty(package_file))
        return null;
    if (!download_checksum_ok(package_file, release.package_sha256)) {
        updates_log("Downloaded " + release.package_name + " does not match its published sha256", "error");
        remove_file(package_file);
        return null;
    }
    let version = as_string(release.version || "");
    if (version == "")
        version = extract_arch_package_version(release.package_name, release.arch);
    return {
        name: release.package_name,
        file: package_file,
        version
    };
}

function disable_standalone_service(name) {
    let init = "/etc/init.d/" + as_string(name);
    if (!file_exists(init))
        return;
    run_logged("Stopping standalone " + as_string(name) + " service", command_from_args([ init, "stop" ]));
    run_logged("Disabling standalone " + as_string(name) + " autostart", command_from_args([ init, "disable" ]));
}

function provider_installed(runtime_module) {
    return module_success([ runtime_module, "installed" ]);
}

function provider_package_version(runtime_module) {
    return trim(module_output([ runtime_module, "package-version" ]));
}

function install_zapret_like(component, action, runtime_module, resolve_fn, label) {
    init_tmp_dir() || action_fail(component, action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail(component, action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving " + label + " package", function() {
        release = resolve_fn(arch);
        return release != null;
    });
    if (release == null)
        action_fail(component, action, "Failed to resolve " + label + " package for this router architecture");

    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_fail(component, action, label + " is not installed", current_version, release.version, "", release.release_url || "");
        check_success_compared(component, current_version, release.version, normalize_zapret_version(current_version), normalize_zapret_version(release.version), release.release_url || "");
    }

    if (!ensure_package_tool("unzip", "unzip", component, action))
        action_fail(component, action, "Failed to install unzip");
    // The package's dependencies (kmod-nft-queue and the like) come from the
    // feeds: on opkg the lists are gone after every reboot (UPD-5).
    progress?.stage?.("lists");
    run_logged("Updating package lists before " + label + " installation", pkg_list_update_command());
    // The bundle, the package taken out of it and the package manager's
    // working copy (UPD-7, B3).
    let space_error = component_download_space_error(label, release.bundle_size, 3, tmp_dir);
    if (space_error != "")
        action_fail(component, action, space_error, current_version, release.version, "", release.release_url || "");
    let pkg = download_and_extract_zip_package(release, component);
    if (pkg == null)
        action_fail(component, action, "Failed to download " + label + " package", current_version, release.version, "", release.release_url || "");
    space_error = component_install_space_error(label, file_bytes(pkg.file) * 3);
    if (space_error != "")
        action_fail(component, action, space_error, current_version, pkg.version, "", release.release_url || "");

    progress?.stage?.("install");
    if (!run_logged("Installing " + label + " package " + pkg.name, pkg_install_files_command([ pkg.file ])))
        action_fail(component, action, "Failed to install " + label + " package" + out_of_space_hint(last_logged_output), current_version, pkg.version, "", release.release_url || "");

    disable_standalone_service(component);
    let restarted = restart_prokop_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = "unknown";
    if (!restarted)
        action_fail(component, action, label + " package has been installed, but " + prokop_not_restarted_text(), current_version, pkg.version, "", release.release_url || "");
    action_success(component, action, label + " package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_zapret(action) {
    install_zapret_like("zapret", action, LIB_DIR + "/providers/zapret/runtime.uc", resolve_zapret_release, "zapret");
}

function install_zapret2(action) {
    install_zapret_like("zapret2", action, LIB_DIR + "/providers/zapret2/runtime.uc", resolve_zapret2_release, "zapret2");
}

function install_byedpi(action) {
    init_tmp_dir() || action_fail("byedpi", action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail("byedpi", action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving ByeDPI package", function() {
        release = resolve_byedpi_release(arch);
        return release != null;
    });
    if (release == null)
        action_fail("byedpi", action, "Failed to resolve ByeDPI package for this router architecture");

    let runtime_module = LIB_DIR + "/providers/byedpi/runtime.uc";
    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_fail("byedpi", action, "ByeDPI is not installed", current_version, release.version);
        check_success("byedpi", current_version, release.version, release.release_url || "");
    }

    progress?.stage?.("lists");
    run_logged("Updating package lists before ByeDPI installation", pkg_list_update_command());
    let space_error = component_download_space_error("ByeDPI", release.package_size, 2, tmp_dir);
    if (space_error != "")
        action_fail("byedpi", action, space_error, current_version, release.version);
    let pkg = download_byedpi_package(release);
    if (pkg == null)
        action_fail("byedpi", action, "Failed to download ByeDPI package");
    space_error = component_install_space_error("ByeDPI", file_bytes(pkg.file) * 3);
    if (space_error != "")
        action_fail("byedpi", action, space_error, current_version, pkg.version);
    progress?.stage?.("install");
    if (!run_logged("Installing ByeDPI package " + pkg.name, pkg_install_files_command([ pkg.file ])))
        action_fail("byedpi", action, "Failed to install ByeDPI package" + out_of_space_hint(last_logged_output), current_version, pkg.version);

    disable_standalone_service("byedpi");
    let restarted = restart_prokop_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = "unknown";
    if (!restarted)
        action_fail("byedpi", action, "ByeDPI package has been installed, but " + prokop_not_restarted_text(), current_version, pkg.version);
    action_success("byedpi", action, "ByeDPI package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

const ZAPRET_MANAGER_SOURCE = "raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh";
// Every launcher Prokop writes carries this line. Forkop wrote its launchers
// under its own marker line, and launchers written by still older releases
// always went through the mirror and are known by its proxy path. Those are
// Prokop's once Forkop's package is gone, never while a migration can still
// roll back to it.
const ZAPRET_MANAGER_LAUNCHER_MARKER = "# Prokop Zapret-Manager launcher";
const ZAPRET_MANAGER_FORKOP_MARKER = legacy_forkop.ZAPRET_MANAGER_MARKER;
const ZAPRET_MANAGER_LEGACY_MARKER = "/zapret-manager/proxy/";
// Where zms and zmsA live; tests point it elsewhere.
const ZAPRET_MANAGER_BIN_DIR = getenv("PROKOP_ZAPRET_MANAGER_BIN_DIR") || "/usr/bin";

function zapret_manager_launcher_managed(source) {
    source = as_string(source);
    if (index(source, ZAPRET_MANAGER_LAUNCHER_MARKER) >= 0)
        return true;
    return (index(source, ZAPRET_MANAGER_FORKOP_MARKER) >= 0 || index(source, ZAPRET_MANAGER_LEGACY_MARKER) >= 0) &&
        !legacy_forkop.installed();
}

// Binaries and scripts from the mirror run as root, and the mirror publishes
// the digests along with them: over http:// anyone on the path could swap
// both. They come only from an https:// mirror, and a configured mirror is
// never bypassed, so an http:// one refuses them (UPD-2). OpenWrt feed
// packages through the mirror keep their signatures and are not affected.
function mirror_refuses_executables() {
    return PROKOP_MIRROR_BASE_URL != "" && lc(substr(PROKOP_MIRROR_BASE_URL, 0, 8)) != "https://";
}

const INSECURE_MIRROR_MESSAGE = "The configured mirror uses http://; binaries and scripts are installed only from an https:// mirror";

// A configured mirror proxies the script and the downloads it makes;
// without one the launcher runs the project's own script.
function zapret_manager_url() {
    return PROKOP_MIRROR_BASE_URL != "" ?
        PROKOP_MIRROR_BASE_URL + "/zapret-manager/proxy/" + ZAPRET_MANAGER_SOURCE :
        "https://" + ZAPRET_MANAGER_SOURCE;
}

// The launcher for the current mirror setting; zms and zmsA are the same.
// An http:// mirror would hand the launcher a script to run as root over
// plain HTTP on every start, so the launcher then runs the project's own
// script over https:// instead (UPD-9), as install refuses that mirror.
function zapret_manager_launcher() {
    let mirrored = PROKOP_MIRROR_BASE_URL != "" && !mirror_refuses_executables();
    let url = mirrored ? zapret_manager_url() : "https://" + ZAPRET_MANAGER_SOURCE;
    return "#!/bin/sh\n" + ZAPRET_MANAGER_LAUNCHER_MARKER + "\n" +
        (mirrored ? "export ZAPRET_MANAGER_MIRROR=" + shell_quote(PROKOP_MIRROR_BASE_URL) + "\n" : "") +
        "exec sh <(wget -q -O - " + shell_quote(url) + ") \"$@\"\n";
}

function install_zapret_manager(action) {
    let component = "zapret_manager";
    let mirrored = PROKOP_MIRROR_BASE_URL != "";
    let manager_url = zapret_manager_url();
    let manager_file = tmp_dir + "/Zapret-Manager.sh";
    let zms = ZAPRET_MANAGER_BIN_DIR + "/zms";
    let zmsa = ZAPRET_MANAGER_BIN_DIR + "/zmsA";
    let current_version = file_exists(zms) ? "installed" : "not installed";

    if (mirror_refuses_executables())
        action_fail(component, action, INSECURE_MIRROR_MESSAGE, current_version);
    if (!download_with_retry(manager_url, manager_file, "Zapret-Manager"))
        action_fail(component, action, mirrored ? "Failed to download Zapret-Manager from the mirror" :
            "Failed to download Zapret-Manager", current_version);

    let source = read_file(manager_file);
    let matched = match(source, /ZAPRET_MANAGER_VERSION="([^"]+)"/);
    let latest_version = matched != null ? as_string(matched[1]) : (mirrored ? "mirror" : "unknown");
    let wrapper = zapret_manager_launcher();
    let auto_wrapper = wrapper;

    progress?.stage?.("install");
    if (!write_file(zms, wrapper) || !write_file(zmsa, auto_wrapper) ||
        !command_success_from_args([ "chmod", "0755", zms, zmsa ]))
        action_fail(component, action, "Failed to install Zapret-Manager launchers", current_version, latest_version);

    clear_version_caches();
    action_success(component, action, mirrored ? "Zapret-Manager has been installed from the Prokop mirror" :
        "Zapret-Manager has been installed", current_version, latest_version, 1, "latest", manager_url);
}

function remove_zapret_manager(action) {
    let component = "zapret_manager";
    let paths = [ ZAPRET_MANAGER_BIN_DIR + "/zms", ZAPRET_MANAGER_BIN_DIR + "/zmsA" ];
    let removed = 0;

    for (let path in paths) {
        if (!file_exists(path))
            continue;
        if (!zapret_manager_launcher_managed(read_file(path)))
            action_fail(component, action, "Existing " + path + " was not created by Prokop and was not removed");
        remove_file(path);
        if (file_exists(path))
            action_fail(component, action, "Failed to remove " + path);
        removed++;
    }

    clear_version_caches();
    action_success(component, action, removed > 0 ?
        "Zapret-Manager launchers have been removed" :
        "Zapret-Manager launchers are already removed", "installed", "", 1);
}

// A launcher written for another mirror, a former upstream one among them,
// keeps downloading and running Zapret-Manager from that host. Every package
// install rewrites Prokop's own launchers for the current mirror setting
// (service/package.uc); a launcher that is missing, not a regular file or not
// written by Prokop stays as it is.
function reconcile_zapret_manager_launchers() {
    let launcher = zapret_manager_launcher();
    let ok = true;

    if (mirror_refuses_executables())
        warn("The configured mirror uses http://; Zapret-Manager launchers run the script from " +
            "https://" + ZAPRET_MANAGER_SOURCE + " instead\n");

    for (let path in [ ZAPRET_MANAGER_BIN_DIR + "/zms", ZAPRET_MANAGER_BIN_DIR + "/zmsA" ]) {
        let stat = fs.lstat(path);
        let source = read_file(path);
        if (stat == null || stat.type != "file" || source == launcher || !zapret_manager_launcher_managed(source))
            continue;
        if (write_file(path, launcher))
            print("Updated " + path + " for the current dependency mirror setting\n");
        else {
            warn("Failed to update " + path + " for the current dependency mirror setting\n");
            ok = false;
        }
    }
    return ok;
}

function remove_optional_component(component, package_name, label, runtime_module) {
    if (!pkg_is_installed(package_name)) {
        if (provider_installed(runtime_module))
            action_fail(component, "remove", label + " exists outside the package manager and was not removed automatically");
        action_success(component, "remove", label + " is already removed", "", "", 0);
    }

    let current_version = provider_package_version(runtime_module);
    let command = is_apk() ?
        command_from_args([ "apk", "del", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null";
    if (!run_logged("Removing " + label + " package", command))
        action_fail(component, "remove", "Failed to remove " + label + " package", current_version);

    clear_version_caches();
    if (provider_installed(runtime_module))
        action_fail(component, "remove", label + " package was removed, but provider files are still present", current_version);
    if (!restart_prokop_after_successful_change())
        action_fail(component, "remove", label + " package has been removed, but " + prokop_not_restarted_text(), current_version);
    action_success(component, "remove", label + " package has been removed", current_version, "", 1);
}

function read_sing_box_binary_version(binary, library_dir) {
    binary = as_string(binary);
    if (binary == "" || !file_exists(binary))
        return "";

    let command = command_from_args([ binary, "version" ]);
    if (as_string(library_dir || "") != "")
        command = command_env({ LD_LIBRARY_PATH: as_string(library_dir) }) + " " + command;

    return trim(helper_output_input(command_output(command), "stdin-first-line-last-field", []));
}

function validate_sing_box_extended_binary(binary, library_dir) {
    let version = read_sing_box_binary_version(binary, library_dir || "");
    return index(version, "extended") >= 0 ? version : "";
}

function move_file_portable(source_path, target_path) {
    if (fs.rename(source_path, target_path))
        return true;

    let staged_path = as_string(target_path) + ".prokop-move." + owner_pid();
    remove_file(staged_path);
    if (!command_success_from_args([ "cp", "-p", source_path, staged_path ]) ||
        !fs.rename(staged_path, target_path)) {
        remove_file(staged_path);
        return false;
    }
    remove_file(source_path);
    return true;
}

function install_staged_file(source_path, target_path, mode) {
    let staged_path = as_string(target_path) + ".prokop-new." + owner_pid();
    remove_file(staged_path);
    if (!command_success_from_args([ "cp", "-f", source_path, staged_path ]) ||
        !command_success_from_args([ "chmod", mode, staged_path ]) ||
        !fs.rename(staged_path, target_path)) {
        remove_file(staged_path);
        return false;
    }
    remove_file(source_path);
    return true;
}

function move_file_to_backup(target_path, backup_path) {
    if (!file_exists(target_path))
        return true;
    remove_file(backup_path);
    return move_file_portable(target_path, backup_path);
}

function restore_sing_box_backup(backup_binary) {
    if (as_string(backup_binary) != "" && file_nonempty(backup_binary)) {
        if (!move_file_portable(backup_binary, "/usr/bin/sing-box"))
            return false;
        return command_success_from_args([ "chmod", "0755", "/usr/bin/sing-box" ]);
    }
    remove_file("/usr/bin/sing-box");
    return true;
}

function restore_file_backup(target_path, backup_path) {
    if (as_string(backup_path) != "" && file_nonempty(backup_path))
        return move_file_portable(backup_path, target_path);
    remove_file(target_path);
    return true;
}

function sing_box_variant_is_package_managed(variant) {
    return variant == "stable" || variant == "tiny" || variant == "extended";
}

function restore_sing_box_service_from_marker(marker) {
    if (as_string(marker) == "extended-compressed")
        return install_managed_sing_box_service_script();
    // apk parks the package's own init script as .apk-new when Prokop's
    // managed script occupies the path. Hand the path back to the package
    // variant instead of leaving it managed by Prokop.
    if (sing_box_variant_is_package_managed(as_string(marker)) && is_apk() &&
        file_exists("/etc/init.d/sing-box.apk-new") &&
        (managed_sing_box_service_installed() || !file_exists("/etc/init.d/sing-box"))) {
        remove_managed_sing_box_service_script();
        if (!move_file_portable("/etc/init.d/sing-box.apk-new", "/etc/init.d/sing-box"))
            return false;
        return command_success_from_args([ "chmod", "0755", "/etc/init.d/sing-box" ]);
    }
    if (!file_exists("/etc/init.d/sing-box") && file_nonempty("/usr/bin/sing-box"))
        return install_managed_sing_box_service_script();
    remove_managed_sing_box_service_script();
    return true;
}

function resolve_sing_box_extended_arch_suffix() {
    let host_arch = trim(command_output_from_args([ "uname", "-m" ]));
    let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
    return trim(helper_output("sing-box-extended-arch-suffix", [ host_arch, distrib_arch ]));
}

function sing_box_extended_tag_is_stable(tag) {
    tag = lc(as_string(tag));
    return tag != "" && index(tag, "alpha") < 0 && index(tag, "beta") < 0 && index(tag, "rc") < 0;
}

function set_sing_box_extended_release_from_json(release_json, compressed) {
    if (as_string(release_json) == "")
        return null;
    let tag = trim(helper_output_input(release_json, "object-get-default", [ "tag_name", "" ]));
    if (!sing_box_extended_tag_is_stable(tag))
        return null;

    let asset_url = "";
    if (compressed) {
        let arch_suffix = resolve_sing_box_extended_arch_suffix();
        if (arch_suffix == "")
            return null;
        asset_url = trim(helper_output_input(release_json, "sing-box-extended-asset-url", [ arch_suffix, "0", "1" ]));
    }
    else {
        let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
        if (distrib_arch == "")
            return null;
        let asset_ext = is_apk() ? "apk" : "ipk";
        asset_url = trim(helper_output_input(release_json, "sing-box-extended-package-asset-url", [ distrib_arch, asset_ext ]));
    }

    if (asset_url == "")
        return null;

    return {
        tag,
        release_url: prokop_mirror_url(trim(helper_output_input(release_json, "object-get-default", [ "html_url", "" ]))),
        asset_url: prokop_mirror_url(asset_url),
        asset_name: path_basename(asset_url),
        // The mirror copies the GitHub asset records, digests included.
        asset_sha256: release_json_asset_sha256(release_json, "browser_download_url", asset_url),
        asset_size: release_asset_object_size(release_json_asset(release_json, "browser_download_url", asset_url))
    };
}

// The mirror publishes a copy of the project's latest GitHub release with the
// assets cut down to the OpenWrt packages; without a mirror the release comes
// from GitHub itself. A configured mirror is never bypassed.
function resolve_sing_box_extended_release(compressed) {
    if (mirror_refuses_executables()) {
        updates_log(INSECURE_MIRROR_MESSAGE, "error");
        return null;
    }
    let release_json = PROKOP_MIRROR_BASE_URL != "" ?
        http_get(PROKOP_MIRROR_BASE_URL + "/forkop/sing-box-extended/latest.json") :
        fetch_github_release_json("shtorm-7", "sing-box-extended");
    return set_sing_box_extended_release_from_json(release_json, compressed);
}

// A download whose checksum differs from the published one is discarded.
function sing_box_extended_download_verified(release, path) {
    if (download_checksum_ok(path, release.asset_sha256))
        return true;
    updates_log("Checksum mismatch for " + as_string(release.asset_name), "error");
    remove_file(path);
    return false;
}

function sing_box_runtime_output(mode, args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return trim(module_output(command_args));
}

function sing_box_runtime_success(mode, args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

function write_sing_box_variant_state(marker, version) {
    if (!sing_box_runtime_success("write-variant-marker", [ marker ]))
        updates_log("Failed to write sing-box variant marker", "warn");
    if (!sing_box_runtime_success("write-version-state", [ version ]))
        updates_log("Failed to write sing-box version state", "warn");
}

function restore_sing_box_variant_state(previous_marker, previous_version_state) {
    sing_box_runtime_success("restore-variant-marker", [ previous_marker ]);
    sing_box_runtime_success("restore-version-state", [ previous_version_state ]);
}

function restore_sing_box_extended_package_variant() {
    init_tmp_dir();
    let release = resolve_sing_box_extended_release(false);
    if (release == null)
        return false;
    let package_file = tmp_dir + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, package_file, release.asset_name, release.asset_size) ||
        !sing_box_extended_download_verified(release, package_file))
        return false;
    prepare_sing_box_package_service_install();
    pkg_remove_sing_box_conflict("sing-box-tiny");
    pkg_remove_sing_box_conflict("sing-box");
    progress?.stage?.("install");
    if (!pkg_install_files([ package_file ])) {
        remove_file(package_file);
        return false;
    }
    remove_file(package_file);
    let new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "")
        return false;
    write_sing_box_variant_state("extended", new_version);
    return true;
}

function replace_sing_box_package_variant(target_package, conflict_package, target_version, package_file) {
    prepare_sing_box_package_service_install();
    if ((as_string(conflict_package) == "" || !pkg_is_installed(conflict_package)) &&
        (target_package == "sing-box-extended" || !pkg_is_installed("sing-box-extended")))
        return pkg_install_fetched_file(target_package, package_file) ||
            pkg_install_name_downgrade(target_package, target_version);

    if (target_package != "sing-box-extended" && !pkg_remove_sing_box_conflict("sing-box-extended"))
        return false;
    if (as_string(conflict_package) != "" && !pkg_remove_sing_box_conflict(conflict_package))
        return false;
    return pkg_install_fetched_file(target_package, package_file) ||
        pkg_install_name_downgrade(target_package, target_version);
}

function restore_sing_box_package_variant(previous_variant) {
    if (previous_variant == "tiny")
        return replace_sing_box_package_variant("sing-box-tiny", "sing-box", available_package_version("sing-box-tiny"));
    if (previous_variant == "stable")
        return replace_sing_box_package_variant("sing-box", "sing-box-tiny", available_package_version("sing-box"));
    if (previous_variant == "extended")
        return restore_sing_box_extended_package_variant();
    if (previous_variant == "not-installed") {
        pkg_remove_sing_box_conflict("sing-box-extended");
        pkg_remove_sing_box_conflict("sing-box-tiny");
        pkg_remove_sing_box_conflict("sing-box");
        remove_managed_sing_box_service_script();
        remove_file("/usr/bin/sing-box");
        return true;
    }
    return false;
}

function restore_sing_box_install_backup(previous_variant, backup_binary) {
    if (sing_box_variant_is_package_managed(previous_variant)) {
        if (restore_sing_box_package_variant(previous_variant))
            return true;
        if (as_string(backup_binary) != "" && restore_sing_box_backup(backup_binary)) {
            updates_log("Package rollback failed; restored the previous sing-box binary backup", "warn");
            return true;
        }
        return false;
    }

    if (as_string(backup_binary) != "")
        return restore_sing_box_backup(backup_binary);
    return restore_sing_box_package_variant(previous_variant);
}

function restore_sing_box_after_failed_extended_install(previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched) {
    progress?.stage?.("rollback");
    if (as_string(archive_file) != "")
        remove_file(archive_file);
    let restore_status = true;
    if (cronet_touched)
        restore_file_backup("/usr/lib/libcronet.so", backup_cronet);
    if (!restore_sing_box_install_backup(previous_variant, backup_binary))
        restore_status = false;
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    restore_sing_box_service_from_marker(previous_marker);
    clear_version_caches();
    return restore_status;
}

function restore_sing_box_after_failed_extended_package_install(previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched) {
    progress?.stage?.("rollback");
    if (as_string(package_file) != "")
        remove_file(package_file);
    pkg_remove_sing_box_conflict("sing-box-extended");
    let restore_status = restore_sing_box_install_backup(previous_variant, backup_binary);
    if (cronet_touched) {
        restore_file_backup("/usr/lib/libcronet.so", backup_cronet);
        if (file_nonempty("/usr/lib/libcronet.so"))
            command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ]);
    }
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    restore_sing_box_service_from_marker(previous_marker);
    clear_version_caches();
    return restore_status;
}

function restore_sing_box_after_failed_package_install(target_package, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched) {
    progress?.stage?.("rollback");
    pkg_remove_sing_box_conflict(target_package);
    let restore_status = restore_sing_box_install_backup(previous_variant, backup_binary);
    if (cronet_touched) {
        if (!restore_file_backup("/usr/lib/libcronet.so", backup_cronet))
            restore_status = false;
        if (file_nonempty("/usr/lib/libcronet.so") && !command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ]))
            restore_status = false;
    }
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    if (!restore_sing_box_service_from_marker(previous_marker))
        restore_status = false;
    if (restore_status) {
        remove_file(backup_binary);
        remove_file(backup_cronet);
    }
    clear_version_caches();
    return restore_status;
}

function fail_package_sing_box_install(action, tiny, reason, current_version, latest_version,
    target_package, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched) {
    let restored = restore_sing_box_after_failed_package_install(
        target_package,
        previous_variant,
        backup_binary,
        backup_cronet,
        previous_marker,
        previous_version_state,
        cronet_touched
    );

    let prefix = tiny ? "sing-box-tiny" : "Stable sing-box";
    if (restored)
        action_fail("sing_box", action, prefix + " " + reason + "; previous sing-box variant was restored", current_version, latest_version);
    action_fail("sing_box", action, prefix + " " + reason + " and previous sing-box variant could not be restored", current_version, latest_version);
}

function install_sing_box_extended_package(action) {
    init_tmp_dir() || action_fail("sing_box", action, "Failed to create temporary directory");
    let current_version = sing_box_runtime_output("version", []);
    let current_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    let release = resolve_sing_box_extended_release(false);
    if (release == null)
        action_fail("sing_box", action, "Failed to resolve sing-box-extended package release", current_version);
    let latest_version = normalize_sing_box_version(release.tag);

    if (action == "check_update") {
        if (!sing_box_runtime_success("is-extended", [ current_version ]))
            action_fail("sing_box", action, "sing-box-extended is not installed", current_version, latest_version);
        check_success("sing_box", normalize_sing_box_version(current_version), normalize_sing_box_version(latest_version), release.release_url);
    }

    let space_error = component_download_space_error("sing-box-extended", release.asset_size, 2, tmp_dir);
    if (space_error != "")
        action_fail("sing_box", action, space_error, current_version, latest_version);
    let package_file = tmp_dir + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, package_file, release.asset_name, release.asset_size))
        action_fail("sing_box", action, "Failed to download sing-box-extended package", current_version, latest_version);
    if (!sing_box_extended_download_verified(release, package_file))
        action_fail("sing_box", action, "Downloaded sing-box-extended package failed checksum verification", current_version, latest_version);
    // The package unpacks to about three times its size; with the current
    // binary kept as the backup, the overlay has to hold both.
    space_error = component_install_space_error("sing-box-extended", file_bytes(package_file) * 3);
    if (space_error != "") {
        remove_file(package_file);
        action_fail("sing_box", action, space_error, current_version, latest_version);
    }

    progress?.stage?.("lists");
    if (!run_logged("Updating package lists before sing-box-extended package installation", pkg_list_update_command()))
        action_fail("sing_box", action, "Failed to update package lists", current_version, latest_version);

    // Pull the dependencies in before the current variant is removed: a
    // failure here still leaves the router with a working sing-box.
    if (!install_opkg_sing_box_dependencies(package_file, "sing-box-extended"))
        action_fail("sing_box", action, "Failed to install required sing-box dependencies; the current sing-box variant was kept", current_version, latest_version);

    if (!stop_prokop_before_sing_box_change())
        action_fail("sing_box", action, SING_BOX_CHANGE_STOP_REFUSED, current_version, latest_version);
    prepare_sing_box_package_service_install();

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (current_variant == "extended" || current_variant == "extended-compressed") {
        if (file_exists("/usr/bin/sing-box")) {
            backup_binary = "/usr/bin/sing-box.prokop-backup." + owner_pid();
            if (!move_file_to_backup("/usr/bin/sing-box", backup_binary))
                action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
        }
        if (file_exists("/usr/lib/libcronet.so")) {
            cronet_touched = true;
            backup_cronet = "/usr/lib/libcronet.so.prokop-backup." + owner_pid();
            if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
                restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
                action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
            }
        }
    }

    if (!run_logged_pkg_remove_sing_box_conflict("sing-box-tiny", "Removing sing-box-tiny before sing-box-extended package installation")) {
        restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
        action_fail("sing_box", action, "Failed to remove sing-box-tiny before sing-box-extended package installation", current_version, latest_version);
    }
    if (!run_logged_pkg_remove_sing_box_conflict("sing-box", "Removing sing-box before sing-box-extended package installation")) {
        restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
        action_fail("sing_box", action, "Failed to remove sing-box before sing-box-extended package installation", current_version, latest_version);
    }

    if (backup_binary == "" && file_exists("/usr/bin/sing-box")) {
        backup_binary = "/usr/bin/sing-box.prokop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary)) {
            restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
            action_fail("sing_box", action, "Failed to backup existing sing-box binary", current_version, latest_version);
        }
    }
    if (!cronet_touched && file_exists("/usr/lib/libcronet.so")) {
        cronet_touched = true;
        backup_cronet = "/usr/lib/libcronet.so.prokop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
            restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
            action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
        }
    }

    progress?.stage?.("install");
    if (!run_logged("Installing sing-box-extended package " + release.asset_name, pkg_install_files_command([ package_file ]))) {
        restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
        action_fail("sing_box", action, "Failed to install sing-box-extended package" + out_of_space_hint(last_logged_output), current_version, latest_version);
    }
    remove_file(package_file);

    let new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "") {
        if (restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched))
            action_fail("sing_box", action, "Installed sing-box-extended package failed validation; previous sing-box variant was restored", current_version, latest_version);
        action_fail("sing_box", action, "Installed sing-box-extended package failed validation and previous sing-box variant could not be restored", current_version, latest_version);
    }

    write_sing_box_variant_state("extended", new_version);
    if (!restart_prokop_after_successful_change() || !wait_prokop_running_after_sing_box_change()) {
        updates_log("sing-box-extended package did not start cleanly; restoring previous sing-box variant", "error");
        if (file_exists(SERVICE_INIT))
            command_success_from_args(prokop_stop_for_component_change_args());
        if (restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched)) {
            remove_file(backup_binary);
            remove_file(backup_cronet);
            action_fail("sing_box", action, "sing-box-extended package was installed but Prokop did not start cleanly; previous sing-box variant was restored", current_version, latest_version);
        }
        action_fail("sing_box", action, "sing-box-extended package was installed but Prokop did not start cleanly and previous sing-box variant could not be restored", current_version, latest_version);
    }

    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    updates_log("Installed sing-box-extended " + (new_version != "" ? new_version : "unknown") + " from package");
    action_success("sing_box", action, "sing-box-extended has been installed", new_version, latest_version, new_version == current_version ? 0 : 1, "latest", release.release_url);
}

function install_sing_box_extended(action, compressed) {
    if (!compressed) {
        install_sing_box_extended_package(action);
        return;
    }

    init_tmp_dir() || action_fail("sing_box", action, "Failed to create temporary directory");
    let label = "sing-box-extended compressed";
    let current_version = sing_box_runtime_output("version", []);
    let current_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    let release = resolve_sing_box_extended_release(true);
    if (release == null)
        action_fail("sing_box", action, "Failed to resolve " + label + " release", current_version);
    let latest_version = normalize_sing_box_version(release.tag);

    if (action == "check_update") {
        if (!sing_box_runtime_success("is-extended", [ current_version ]))
            action_fail("sing_box", action, "sing-box-extended is not installed", current_version, latest_version);
        if (!sing_box_runtime_success("marker-is", [ "extended-compressed" ]))
            action_fail("sing_box", action, "sing-box-extended compressed is not installed", current_version, latest_version);
        check_success("sing_box", normalize_sing_box_version(current_version), normalize_sing_box_version(latest_version), release.release_url);
    }

    // The archive, the binary and libcronet.so all sit in /tmp at once.
    let space_error = component_download_space_error(label, release.asset_size, 3, tmp_dir);
    if (space_error != "")
        action_fail("sing_box", action, space_error, current_version, latest_version);
    let archive_file = tmp_dir + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, archive_file, release.asset_name, release.asset_size))
        action_fail("sing_box", action, "Failed to download " + label, current_version, latest_version);
    if (!sing_box_extended_download_verified(release, archive_file))
        action_fail("sing_box", action, "Downloaded " + label + " failed checksum verification", current_version, latest_version);

    let binary_path = select_archive_member_path(archive_file, "sing-box");
    if (binary_path == "") {
        remove_file(archive_file);
        action_fail("sing_box", action, "sing-box binary was not found in the downloaded archive", current_version, latest_version);
    }
    let cronet_path = select_archive_member_path(archive_file, "libcronet.so");
    let extract_error = tmp_dir + "/sing-box-extract.err";
    let tmp_binary = tmp_dir + "/sing-box.compressed." + owner_pid();
    let tmp_cronet = "";
    if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", binary_path ]) + " >" + shell_quote(tmp_binary) + " 2>" + shell_quote(extract_error)) ||
        !file_nonempty(tmp_binary) ||
        !command_success_from_args([ "chmod", "0755", tmp_binary ])) {
        for (let line in split(read_file(extract_error), "\n"))
            if (trim(as_string(line)) != "")
                updates_log(line);
        let hint = out_of_space_hint(read_file(extract_error));
        remove_file(tmp_binary);
        remove_file(archive_file);
        action_fail("sing_box", action, "Failed to extract " + label + hint, current_version, latest_version);
    }

    if (cronet_path != "") {
        tmp_cronet = tmp_dir + "/libcronet.so";
        if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", cronet_path ]) + " >" + shell_quote(tmp_cronet) + " 2>" + shell_quote(extract_error)) ||
            !file_nonempty(tmp_cronet) ||
            !command_success_from_args([ "chmod", "0644", tmp_cronet ])) {
            for (let line in split(read_file(extract_error), "\n"))
                if (trim(as_string(line)) != "")
                    updates_log(line);
            let hint = out_of_space_hint(read_file(extract_error));
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            remove_file(archive_file);
            action_fail("sing_box", action, "Failed to extract libcronet.so from sing-box-extended archive" + hint, current_version, latest_version);
        }
    }

    remove_file(archive_file);
    // Refused while the running variant is untouched: the binary and the
    // library are copied to the overlay next to their backups (UPD-7).
    space_error = component_install_space_error(label, file_bytes(tmp_binary) + file_bytes(tmp_cronet));
    if (space_error != "") {
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, space_error, current_version, latest_version);
    }
    if (!stop_prokop_before_sing_box_change())
        action_fail("sing_box", action, SING_BOX_CHANGE_STOP_REFUSED, current_version, latest_version);
    let new_version = validate_sing_box_extended_binary(tmp_binary, tmp_dir);
    if (new_version == "") {
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, "Downloaded " + label + " failed validation", current_version, latest_version);
    }

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (file_exists("/usr/bin/sing-box")) {
        backup_binary = "/usr/bin/sing-box.prokop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary)) {
            remove_file(backup_binary);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            remove_file(archive_file);
            action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
        }
    }
    if (cronet_path != "") {
        cronet_touched = true;
        if (file_exists("/usr/lib/libcronet.so")) {
            backup_cronet = "/usr/lib/libcronet.so.prokop-backup." + owner_pid();
            if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
                restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
                remove_file(tmp_binary);
                remove_file(tmp_cronet);
                action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
            }
        }
    }

    for (let item in [
        [ "sing-box-extended", "Removing sing-box-extended package before " + label + " installation" ],
        [ "sing-box-tiny", "Removing sing-box-tiny package before " + label + " installation" ],
        [ "sing-box", "Removing sing-box package before " + label + " installation" ]
    ]) {
        if (!run_logged_pkg_remove_sing_box_conflict(item[0], item[1])) {
            restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            action_fail("sing_box", action, "Failed to remove " + item[0] + " before " + label + " installation", current_version, latest_version);
        }
    }

    remove_managed_sing_box_service_script();
    if (!install_managed_sing_box_service_script()) {
        restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, "Failed to install managed sing-box service for " + label, current_version, latest_version);
    }

    remove_file("/usr/bin/sing-box");
    progress?.stage?.("install");
    if (!install_staged_file(tmp_binary, "/usr/bin/sing-box", "0755")) {
        remove_file("/usr/bin/sing-box");
        restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
        action_fail("sing_box", action, "Failed to install " + label + " binary", current_version, latest_version);
    }
    if (tmp_cronet != "") {
        remove_file("/usr/lib/libcronet.so");
        if (!install_staged_file(tmp_cronet, "/usr/lib/libcronet.so", "0644")) {
            remove_file("/usr/lib/libcronet.so");
            restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
            action_fail("sing_box", action, "Failed to install libcronet.so for " + label, current_version, latest_version);
        }
    }
    remove_file(archive_file);

    new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "") {
        if (restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched))
            action_fail("sing_box", action, "Installed " + label + " failed validation; previous sing-box variant was restored", current_version, latest_version);
        action_fail("sing_box", action, "Installed " + label + " failed validation and previous sing-box variant could not be restored", current_version, latest_version);
    }

    write_sing_box_variant_state("extended-compressed", new_version);
    if (!restart_prokop_after_successful_change() || !wait_prokop_running_after_sing_box_change()) {
        updates_log(label + " did not start cleanly; restoring previous sing-box binary", "error");
        if (file_exists(SERVICE_INIT))
            command_success_from_args(prokop_stop_for_component_change_args());
        if (restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched)) {
            remove_file(backup_binary);
            remove_file(backup_cronet);
            action_fail("sing_box", action, label + " was installed but Prokop did not start cleanly; previous sing-box variant was restored", current_version, latest_version);
        }
        action_fail("sing_box", action, label + " was installed but Prokop did not start cleanly and previous sing-box variant could not be restored", current_version, latest_version);
    }

    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    updates_log("Installed " + label + " " + (new_version != "" ? new_version : "unknown"));
    action_success("sing_box", action, label + " has been installed", new_version, latest_version, 1, "latest", release.release_url);
}

// B7: the package of a stable or tiny sing-box comes from the package feed.
// It is downloaded into the temporary directory while the running variant
// still serves, so a feed that does not answer, or a package that would not
// fit, refuses the change before Prokop is stopped for it; the change then
// installs this file (UPD-14). Returns the path, "" when the download failed.
function fetch_repository_package(package_name, package_version) {
    let dir = tmp_dir + "/feed-" + package_name;
    command_success_from_args([ "rm", "-rf", dir ]);
    if (!ensure_dir(dir))
        return "";
    let command = is_apk() ?
        command_from_args([ "apk", "fetch", "-o", dir, package_name + "=" + package_version ]) + " </dev/null" :
        "cd " + shell_quote(dir) + " && " + command_from_args([ "opkg", "download", package_name ]) + " </dev/null";
    let files = run_logged("Downloading " + package_name + " package", command) ? (fs.glob(dir + "/*") || []) : [];
    if (length(files) != 1 || file_bytes(files[0]) <= 0) {
        command_success_from_args([ "rm", "-rf", dir ]);
        return "";
    }
    return files[0];
}

function install_package_sing_box(action, tiny) {
    let package_name = tiny ? "sing-box-tiny" : "sing-box";
    let conflict = tiny ? "sing-box" : "sing-box-tiny";
    let label = tiny ? "tiny sing-box" : "stable sing-box";
    let package_version = installed_package_version(package_name);
    let binary_version = sing_box_runtime_output("version", []);
    let current_version = package_version;
    if (sing_box_runtime_success("is-extended", [ binary_version ]))
        current_version = binary_version;
    if (current_version == "")
        current_version = binary_version;
    let latest_version = available_package_version(package_name);
    if (latest_version == "")
        latest_version = installed_package_version(package_name);

    if (action == "check_update") {
        if (latest_version == "")
            action_fail("sing_box", action, "Failed to resolve " + (tiny ? "tiny" : "stable") + " sing-box package version", current_version);
        if (tiny && !sing_box_runtime_success("is-tiny", [ binary_version ]))
            action_fail("sing_box", action, "sing-box-tiny is not installed", current_version, latest_version);
        check_success("sing_box", current_version, latest_version, "");
    }

    progress?.stage?.("lists");
    if (!run_logged("Updating package lists before " + package_name + " installation", pkg_list_update_command()))
        action_fail("sing_box", action, "Failed to update package lists", current_version, latest_version);
    latest_version = available_package_version(package_name);
    if (latest_version == "")
        latest_version = installed_package_version(package_name);
    if (latest_version == "")
        action_fail("sing_box", action, "Failed to resolve " + (tiny ? "tiny" : "stable") + " sing-box package version", current_version);

    init_tmp_dir() || action_fail("sing_box", action, "Failed to create temporary directory", current_version, latest_version);
    let package_file = fetch_repository_package(package_name, latest_version);
    if (package_file == "")
        action_fail("sing_box", action, "Failed to download the " + package_name + " package; the current sing-box was kept" +
            out_of_space_hint(last_logged_output), current_version, latest_version);
    // The package unpacks to about three times its size; the current binary
    // stays as the backup until the new one runs.
    let space_error = component_install_space_error(label, file_bytes(package_file) * 3);
    if (space_error != "")
        action_fail("sing_box", action, space_error, current_version, latest_version);

    let previous_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    if (!stop_prokop_before_sing_box_change())
        action_fail("sing_box", action, SING_BOX_CHANGE_STOP_REFUSED, current_version, latest_version);

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    let backup_on_tmpfs = previous_variant == "extended-compressed";
    if (file_exists("/usr/bin/sing-box")) {
        backup_binary = backup_on_tmpfs ? tmp_dir + "/sing-box.prokop-backup" :
            "/usr/bin/sing-box.prokop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary))
            action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
    }
    if (file_exists("/usr/lib/libcronet.so")) {
        cronet_touched = true;
        backup_cronet = backup_on_tmpfs ? tmp_dir + "/libcronet.so.prokop-backup" :
            "/usr/lib/libcronet.so.prokop-backup." + owner_pid();
        if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
            restore_sing_box_backup(backup_binary);
            action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
        }
    }

    if (!run_logged("Installing " + label + " package", "sh -c " + shell_quote("exit 0")) ||
        !replace_sing_box_package_variant(package_name, conflict, latest_version, package_file))
        fail_package_sing_box_install(action, tiny, "package installation failed", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);

    command_success_from_args([ "rm", "-rf", tmp_dir + "/feed-" + package_name ]);

    let new_version = read_sing_box_binary_version("/usr/bin/sing-box", "");
    if (new_version == "")
        fail_package_sing_box_install(action, tiny, "package was installed, but sing-box binary is not available", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);
    if (sing_box_runtime_success("is-extended", [ new_version ]))
        fail_package_sing_box_install(action, tiny, "package was installed, but the active binary is still sing-box-extended", new_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);
    write_sing_box_variant_state(tiny ? "tiny" : "stable", new_version);
    if (!restart_prokop_after_successful_change() || !wait_prokop_running_after_sing_box_change())
        fail_package_sing_box_install(action, tiny, "was installed, but Prokop did not start cleanly", new_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);
    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    action_success("sing_box", action, label + " has been installed", new_version, latest_version, new_version == current_version ? 0 : 1, "latest");
}

function check_prokop() {
    let metadata = fetch_prokop_latest_release_metadata();
    let fields = split(metadata, "\t");
    let latest_version = length(fields) > 0 && as_string(fields[0]) != "" ? as_string(fields[0]) : "unknown";
    let release_url = prokop_release_page_url(latest_version,
        length(fields) > 1 ? as_string(fields[1]) : "");
    if (latest_version == "unknown")
        action_fail("prokop", "check_update", "Failed to check Prokop updates", PROKOP_VERSION, latest_version);

    write_prokop_latest_version_cache(latest_version, now_seconds());
    if (!helper_success("prokop-release-version-valid", [ PROKOP_VERSION ])) {
        updates_log("Prokop current version is not a release version (" + PROKOP_VERSION + ")");
        action_success("prokop", "check_update", "Installed version is newer than release", PROKOP_VERSION, latest_version, 0, "dev", release_url);
    }

    let compare = trim(helper_output("prokop-release-version-compare", [ PROKOP_VERSION, latest_version ]));
    if (compare == "")
        action_fail("prokop", "check_update", "Failed to compare Prokop versions", PROKOP_VERSION, latest_version);
    let status = status_from_compare(int(compare));
    if (status == "")
        action_fail("prokop", "check_update", "Failed to compare Prokop versions", PROKOP_VERSION, latest_version);
    if (status == "latest") {
        updates_log("Prokop is already up to date (" + PROKOP_VERSION + ")");
        action_success("prokop", "check_update", "Latest version is installed", PROKOP_VERSION, latest_version, 0, status, release_url);
    }
    if (status == "outdated") {
        updates_log("Prokop update found: " + PROKOP_VERSION + " -> " + latest_version);
        action_success("prokop", "check_update", "Update is available", PROKOP_VERSION, latest_version, 0, status, release_url);
    }
    updates_log("Prokop installed version is newer than upstream release: " + PROKOP_VERSION + " -> " + latest_version);
    action_success("prokop", "check_update", "Installed version is newer than release", PROKOP_VERSION, latest_version, 0, status, release_url);
}

// The SHA-256 that the release metadata names for an asset: fold8's
// latest.json and the version catalog give "sha256", the GitHub API gives
// "digest" as "sha256:<hex>" (install.sh reads both). "" when it names none.
function release_asset_sha256(metadata, name) {
    for (let asset in (type(metadata.assets) == "array" ? metadata.assets : [])) {
        if (type(asset) != "object" || as_string(asset.name) != as_string(name))
            continue;
        let digest = lc(as_string(asset.sha256 || asset.digest || ""));
        if (substr(digest, 0, 7) == "sha256:")
            digest = substr(digest, 7);
        return match(digest, /^[0-9a-f]{64}$/) != null ? digest : "";
    }
    return "";
}

// The size the metadata publishes for that asset; 0 when it publishes none.
function release_asset_size(metadata, name) {
    for (let asset in (type(metadata.assets) == "array" ? metadata.assets : []))
        if (type(asset) == "object" && as_string(asset.name) == as_string(name))
            return release_asset_object_size(asset);
    return 0;
}

// "" when the file cannot be read: it matches no checksum.
function file_sha256(path) {
    return split(trim(command_output_from_args([ "sha256sum", path ])), /[ \t]+/)[0];
}

function resolve_prokop_release_json(latest_version, release_json) {
    if (release_json == "")
        return null;
    let asset_ext = is_apk() ? "apk" : "ipk";
    let i18n_required = pkg_is_installed("luci-i18n-prokop-ru") ? "1" : "0";
    // Without the language pack the plan ends in two empty fields: only the
    // line end goes, never the tabs that delimit them (UC-027).
    let plan = replace(helper_output_input(release_json, "prokop-release-plan", [ latest_version, asset_ext, i18n_required ]), /\n+$/, "");
    let fields = split(plan, "\t");
    if (length(fields) < 7 || as_string(fields[1]) == "" || as_string(fields[2]) == "" || as_string(fields[3]) == "" || as_string(fields[4]) == "")
        return null;
    let metadata = parse_json_object(release_json);
    return {
        release_url: prokop_release_page_url(latest_version, fields[0]),
        backend_name: fields[1],
        backend_url: prokop_release_url(fields[2]),
        backend_sha256: release_asset_sha256(metadata, fields[1]),
        app_name: fields[3],
        app_url: prokop_release_url(fields[4]),
        app_sha256: release_asset_sha256(metadata, fields[3]),
        i18n_name: fields[5],
        i18n_url: prokop_release_url(fields[6]),
        i18n_sha256: fields[5] != "" ? release_asset_sha256(metadata, fields[5]) : "",
        backend_size: release_asset_size(metadata, fields[1]),
        app_size: release_asset_size(metadata, fields[3]),
        i18n_size: fields[5] != "" ? release_asset_size(metadata, fields[5]) : 0
    };
}

function resolve_prokop_release(latest_version, selected) {
    let release_json = selected != null ? sprintf("%J", selected) : latest_prokop_release_json();
    return resolve_prokop_release_json(latest_version, release_json);
}

function prokop_release_matches(package_name, version) {
    let installed = installed_package_version(package_name);
    let revision_prefix = version + "-r";
    return installed == version || (substr(installed, 0, length(revision_prefix)) == revision_prefix &&
        match(substr(installed, length(revision_prefix)), /^[0-9]+$/) != null);
}

// The installed release, as the rollback copy staged before an upgrade. The
// static channel's catalog is asked first: its entries passed the same checks
// as the version picker and carry checksums. GitHub Releases is the fallback.
function previous_prokop_release(version) {
    if (match(version, /^[0-9]+[.][0-9]+[.][0-9]+$/) == null)
        return null;
    let selected = selected_prokop_release(version);
    let release = selected != null ? resolve_prokop_release_json(version, sprintf("%J", selected)) : null;
    if (release != null)
        return release;
    let parts = split(PROKOP_RELEASE_REPO, "/");
    if (length(parts) != 2 || match(parts[0], /^[A-Za-z0-9_.-]+$/) == null ||
        match(parts[1], /^[A-Za-z0-9_.-]+$/) == null)
        return null;
    let metadata = http_get("https://api.github.com/repos/" + parts[0] + "/" + parts[1] + "/releases/tags/" + version);
    return resolve_prokop_release_json(version, metadata);
}

// The one-line installer of this channel. It replaces the whole package set,
// which is the way off a build this channel never published.
function prokop_channel_installer_command() {
    let base = replace(PROKOP_RELEASE_BASE_URL, /\/+$/, "");
    if (base != "")
        return "wget -qO- " + base + "/install.sh | sh";
    let parts = split(PROKOP_RELEASE_REPO, "/");
    if (length(parts) == 2 && match(parts[0], /^[A-Za-z0-9_.-]+$/) != null &&
        match(parts[1], /^[A-Za-z0-9_.-]+$/) != null)
        return "wget -qO- https://github.com/" + parts[0] + "/" + parts[1] + "/releases/latest/download/install.sh | sh";
    return "";
}

function unpublished_prokop_release_error(version) {
    let message = "Installed Prokop " + as_string(version) + " is not published in this Prokop channel, " +
        "so it cannot be staged for rollback; automatic upgrade refused";
    let installer = prokop_channel_installer_command();
    if (installer != "")
        message += ". Run the one-line installer to switch this router to this fork: " + installer;
    return message;
}

function opkg_prokop_set_versions_match(version, with_i18n) {
    return prokop_release_matches("prokop", version) &&
        prokop_release_matches("luci-app-prokop", version) &&
        (!with_i18n || prokop_release_matches("luci-i18n-prokop-ru", version));
}

function pkg_set_extension() {
    return is_apk() ? "apk" : "ipk";
}

// The staged rollback set is installed the same way on both package managers:
// from local files, over whatever is installed, without consulting a feed.
function pkg_prokop_set_command(files, noaction, reinstall) {
    let args;
    if (is_apk()) {
        args = [ "apk", "add" ];
        if (noaction)
            push(args, "--simulate");
        push(args, "--allow-untrusted", "--force-overwrite");
        if (reinstall)
            push(args, "--force-reinstall");
    }
    else {
        args = [ "opkg" ];
        if (noaction)
            push(args, "--noaction");
        push(args, "install", "--force-overwrite", "--force-downgrade");
        if (reinstall)
            push(args, "--force-reinstall");
    }
    for (let file in files)
        push(args, file);
    return command_from_args(args) + " </dev/null";
}

// Where the previous release is staged and where its recovery looks for it
// (UC-195). Releases from 1.0.27 until this was fixed staged it as *.ipk on
// apk systems as well; the recovery of a rollback such a release left pending
// takes those names.
function prokop_recovery_files(with_i18n, extension) {
    extension = extension || pkg_set_extension();
    let files = [ PROKOP_OPKG_RECOVERY_DIR + "/backend." + extension,
        PROKOP_OPKG_RECOVERY_DIR + "/app." + extension ];
    if (with_i18n)
        push(files, PROKOP_OPKG_RECOVERY_DIR + "/i18n." + extension);
    return files;
}

// The service state from before the upgrade. Stopping a Prokop that the
// package scripts started is Prokop's own stop for the upgrade, not the
// user's (D-15); a start is awaited (UC-013). A stop by the user since then
// holds (D-15), also one that overtook that start: the stop won, and the
// package set is in place (UC-235). This action's upgrade marker names no
// transition any more: the old sing-box was proven gone before the package
// step, which can outlast the marker's age (a slow router, the downloads of
// the mirror migration), and a stale marker would refuse this start
// (UC-217). The start follows the stop request in effect, Prokop's own: a
// user's stop requested after the check here wins over it as well.
function restore_prokop_opkg_service(was_running) {
    if (!was_running) {
        if (!prokop_status_running_with_timeout())
            return true;
        return command_success_from_args(prokop_stop_for_component_change_args()) &&
            !prokop_status_running_with_timeout();
    }
    if (prokop_status_running_with_timeout())
        return true;
    let after_stop = own_stop_request();
    if (after_stop == null) {
        updates_log("Prokop was stopped by the user; the restored release is not started");
        return true;
    }
    remove_managed_upgrade_sing_box_marker();
    if (prokop_start_and_wait("start", after_stop))
        return true;
    if (prokop_stopped_by_user()) {
        updates_log("Prokop was stopped by the user during its start; it is not started again");
        return true;
    }
    return false;
}

function finish_prokop_opkg_recovery(service_state) {
    if (service_state == "")
        return "Prokop package-set service state is unknown; recovery archives retained for manual recovery";
    if (!restore_prokop_opkg_service(service_state == "1"))
        return "Prokop package-set service state could not be restored; recovery archives retained in " + PROKOP_OPKG_RECOVERY_DIR;
    if (!command_success_from_args([ "rm", "-rf", PROKOP_OPKG_RECOVERY_DIR ]) ||
        file_exists(PROKOP_OPKG_RECOVERY_DIR + "/pending"))
        return "Prokop package-set recovery metadata could not be cleared";
    return "";
}

function recover_prokop_opkg_set() {
    let marker = split(trim(read_file(PROKOP_OPKG_RECOVERY_DIR + "/pending")), "\t");
    if ((length(marker) != 3 && length(marker) != 4) ||
        match(marker[0], /^[0-9]+[.][0-9]+[.][0-9]+$/) == null ||
        match(marker[1], /^[0-9]+[.][0-9]+[.][0-9]+$/) == null ||
        (marker[2] != "0" && marker[2] != "1") ||
        (length(marker) == 4 && marker[3] != "0" && marker[3] != "1"))
        return "Prokop package-set recovery marker is invalid; manual recovery required";
    let with_i18n = marker[2] == "1";
    if (!opkg_prokop_set_versions_match(marker[1], with_i18n) &&
        !opkg_prokop_set_versions_match(marker[0], with_i18n)) {
        let files = prokop_recovery_files(with_i18n);
        if (!file_nonempty(files[0]))
            files = prokop_recovery_files(with_i18n, "ipk");
        for (let file in files)
            if (!file_nonempty(file))
                return "Prokop package-set recovery archive is missing; manual recovery required";
        // Restore the UI before the backend, so an old backend is never paired
        // with a newer LuCI app during the recovery sequence.
        let restored = true;
        for (let i = length(files) - 1; i >= 0; i--)
            if (!run_logged("Restoring Prokop release package " + path_basename(files[i]),
                pkg_prokop_set_command([ files[i] ], false, true))) {
                restored = false;
                updates_log("Restoring " + path_basename(files[i]) + " failed", "error");
            }
        if (!restored || !opkg_prokop_set_versions_match(marker[0], with_i18n))
            return "Prokop package-set rollback failed; recovery archives retained in " + PROKOP_OPKG_RECOVERY_DIR;
    }
    return finish_prokop_opkg_recovery(length(marker) == 4 ? marker[3] : "");
}

// Unpacking a package set needs room for the new files while the old ones are
// still in place, and the staged rollback set has to survive alongside them.
// Running out of space mid-install is exactly the failure this staging exists
// to recover from, so refuse before touching anything.
function prokop_package_set_space_error(new_files, staged_files) {
    let overlay_kib = available_kib("/usr");
    let tmp_kib = available_kib("/tmp");
    if (overlay_kib < 0 || tmp_kib < 0)
        return "";

    let new_bytes = 0;
    for (let file in new_files)
        new_bytes += file_bytes(file);
    let staged_bytes = 0;
    for (let file in staged_files)
        staged_bytes += file_bytes(file);

    // Installed files run well past their compressed size, and both package
    // managers keep working copies while they unpack.
    let required_overlay_kib = int((new_bytes * 3 + staged_bytes) / 1024) + 2048;
    if (overlay_kib < required_overlay_kib)
        return "Not enough free space to upgrade Prokop: " + as_string(overlay_kib) +
            " KiB available where " + as_string(required_overlay_kib) + " KiB is needed";

    let required_tmp_kib = int((new_bytes + staged_bytes) / 1024) + 1024;
    if (tmp_kib < required_tmp_kib)
        return "Not enough free space in /tmp to upgrade Prokop: " + as_string(tmp_kib) +
            " KiB available where " + as_string(required_tmp_kib) + " KiB is needed";
    return "";
}

// Every refusal of the upgrade, before Prokop is stopped for it (UC-196):
// the installed set, the previous release and its staging, the dry run of
// both sets and the free space. Nothing is installed yet; the staged set has
// no recovery marker until install_prokop_package_set records one.
function prepare_prokop_package_set(backend_file, app_file, i18n_file) {
    let with_i18n = i18n_file != "";
    if (file_exists(PROKOP_OPKG_RECOVERY_DIR + "/pending"))
        return "Prokop package-set recovery is pending; a fresh component action is required";
    if (!opkg_prokop_set_versions_match(PROKOP_VERSION, with_i18n))
        return "Installed Prokop package versions are inconsistent; automatic upgrade refused";

    let previous = previous_prokop_release(PROKOP_VERSION);
    if (previous == null)
        return unpublished_prokop_release_error(PROKOP_VERSION);
    if (with_i18n && previous.i18n_url == "")
        return "Previous Prokop release packages are unavailable; automatic upgrade refused";

    // A directory without the marker predates every package mutation.
    if (file_exists(PROKOP_OPKG_RECOVERY_DIR))
        command_success_from_args([ "rm", "-rf", PROKOP_OPKG_RECOVERY_DIR ]);
    if (file_exists(PROKOP_OPKG_RECOVERY_DIR))
        return "Failed to clear incomplete Prokop package-set staging";
    let recovery_parent = trim(command_output_from_args([ "dirname", PROKOP_OPKG_RECOVERY_DIR ]));
    if (recovery_parent == "" || !ensure_dir(recovery_parent))
        return "Failed to prepare Prokop package-set recovery storage";
    if (!command_success_from_args([ "mkdir", "-m", "0700", PROKOP_OPKG_RECOVERY_DIR ]))
        return "Failed to reserve Prokop package-set recovery storage";
    let old_files = prokop_recovery_files(with_i18n);
    if (!download_with_retry(previous.backend_url, old_files[0], previous.backend_name) ||
        !download_with_retry(previous.app_url, old_files[1], previous.app_name) ||
        (with_i18n && !download_with_retry(previous.i18n_url, old_files[2], previous.i18n_name))) {
        command_success_from_args([ "rm", "-rf", PROKOP_OPKG_RECOVERY_DIR ]);
        return "Failed to stage previous Prokop release packages; automatic upgrade refused";
    }
    // The rollback installs this set: it is checked as the new one is,
    // wherever its GitHub metadata names a digest (UC-080). Older assets
    // name none (digest null); their set is staged unchecked.
    let old_names = [ previous.backend_name, previous.app_name, previous.i18n_name ];
    let old_sums = [ previous.backend_sha256, previous.app_sha256, previous.i18n_sha256 ];
    for (let i = 0; i < length(old_files); i++) {
        if (old_sums[i] && file_sha256(old_files[i]) != old_sums[i]) {
            command_success_from_args([ "rm", "-rf", PROKOP_OPKG_RECOVERY_DIR ]);
            return "Previous Prokop release package checksum mismatch for " + old_names[i] + "; automatic upgrade refused";
        }
    }

    let new_files = [ backend_file, app_file ];
    if (with_i18n)
        push(new_files, i18n_file);
    if (!run_logged("Checking new Prokop package set", pkg_prokop_set_command(new_files, true)) ||
        !run_logged("Checking previous Prokop package set", pkg_prokop_set_command(old_files, true, true))) {
        command_success_from_args([ "rm", "-rf", PROKOP_OPKG_RECOVERY_DIR ]);
        return "Prokop package-set preflight failed; automatic upgrade refused";
    }

    let space_error = prokop_package_set_space_error(new_files, old_files);
    if (space_error != "") {
        command_success_from_args([ "rm", "-rf", PROKOP_OPKG_RECOVERY_DIR ]);
        return space_error;
    }
    return "";
}

// A staged set that no recovery marker claims is dropped with the action
// that staged it: nothing was installed from it.
function discard_staged_prokop_package_set() {
    if (file_exists(PROKOP_OPKG_RECOVERY_DIR) && !file_exists(PROKOP_OPKG_RECOVERY_DIR + "/pending"))
        command_success_from_args([ "rm", "-rf", PROKOP_OPKG_RECOVERY_DIR ]);
}

// The set that prepare_prokop_package_set staged and checked, installed
// once Prokop is stopped for it, and rolled back to the staged previous
// release when the install leaves it incomplete.
function install_prokop_package_set(latest_version, backend_file, app_file, i18n_file) {
    let with_i18n = i18n_file != "";
    let new_files = [ backend_file, app_file ];
    if (with_i18n)
        push(new_files, i18n_file);
    // Read back, and flushed before and after the rename (core/durable.uc):
    // the recovery after a power cut mid-install reads it, and a full
    // overlay took the write and left an empty marker in place.
    let marker_tmp = PROKOP_OPKG_RECOVERY_DIR + "/pending.new";
    if (!durable.durable_replace(marker_tmp, PROKOP_OPKG_RECOVERY_DIR + "/pending",
        PROKOP_VERSION + "\t" + latest_version + "\t" + (with_i18n ? "1" : "0") + "\t" + (prokop_was_running ? "1" : "0") + "\n")) {
        command_success_from_args([ "rm", "-rf", PROKOP_OPKG_RECOVERY_DIR ]);
        return "Failed to record Prokop package-set recovery state";
    }

    // apk resolves one transaction for all three files and refreshes its index
    // once, so keep that. Order still matters inside it: the backend goes last
    // because its postinst is what restores the service, and it must find the
    // matching LuCI files already in place. opkg installs sequentially and
    // takes the backend first, so an old UI cannot call a newer API than the
    // backend behind it. Neither is atomic, which is what the staged set is for.
    let failed = false;
    if (is_apk()) {
        let files = [ app_file ];
        if (with_i18n)
            push(files, i18n_file);
        push(files, backend_file);
        failed = !run_logged("Installing Prokop release packages",
            pkg_prokop_set_command(files, false));
    }
    else {
        for (let file in new_files) {
            if (!run_logged("Installing Prokop release package " + path_basename(file), pkg_prokop_set_command([ file ], false))) {
                failed = true;
                break;
            }
        }
    }
    if (!failed && opkg_prokop_set_versions_match(latest_version, with_i18n)) {
        return finish_prokop_opkg_recovery(prokop_was_running ? "1" : "0");
    }

    if (opkg_prokop_set_versions_match(latest_version, with_i18n)) {
        let recovery_error = finish_prokop_opkg_recovery(prokop_was_running ? "1" : "0");
        if (recovery_error != "")
            return recovery_error;
        return "OPKG reported an error after the complete Prokop package set was installed";
    }

    updates_log("Prokop package-set upgrade failed; restoring previous release", "warn");
    progress?.stage?.("rollback");
    let recovery_error = recover_prokop_opkg_set();
    if (recovery_error != "")
        return recovery_error;
    return "Prokop package-set upgrade failed; previous release restored";
}

function upgrade_sing_box_ticks(pid) {
    let ticks = process_identity.start_ticks(pid);
    return ticks != "" ? ticks : null;
}

function upgrade_sing_box_processes() {
    let processes = {};
    for (let exe in fs.glob("/proc/[0-9]*/exe")) {
        let path = trim(command_output_from_args([ "readlink", exe ]));
        let name = replace(path, /^.*\//, "");
        if (name != "sing-box" && name != "sing-box (deleted)")
            continue;
        let pid = split(exe, "/")[2];
        let ticks = upgrade_sing_box_ticks(pid);
        if (ticks == null)
            return null;
        processes[pid] = ticks;
    }
    return processes;
}

function upgrade_sing_box_count(processes) {
    let count = 0;
    for (let _ in processes)
        count++;
    return count;
}

function upgrade_procd_owns_all(processes) {
    let data = command_output_from_args([ "ubus", "call", "service", "list" ]);
    let service;
    try { service = json(data)["sing-box"]; } catch (e) { return false; }
    let instances = service && type(service.instances) == "object" ? service.instances : {};
    for (let pid, ticks in processes) {
        let owned = false;
        for (let _, instance in instances) {
            if (type(instance) != "object")
                continue;
            let command = instance.command;
            if (instance.running === true && as_string(instance.pid) == pid &&
                type(command) == "array" && length(command) >= 4 &&
                command[0] == "/usr/bin/sing-box" && command[1] == "run" &&
                command[2] == "-c" && command[3] == "/etc/sing-box/config.json" &&
                upgrade_sing_box_ticks(pid) == ticks)
                owned = true;
        }
        if (!owned)
            return false;
    }
    return true;
}

// An init script that never returns would hang the whole upgrade. Run the stop
// in the background and kill it once the deadline passes. Prokop's stop is
// its own for the upgrade, not the user's: it keeps the ownership guard and
// never signals a sing-box that Prokop does not own (UC-213).
function upgrade_bounded_stop(script) {
    let seconds = int(getenv("PROKOP_UPGRADE_STOP_TIMEOUT_SECONDS") || "60");
    if (seconds < 1)
        seconds = 60;
    let args = script == SERVICE_INIT ? prokop_stop_for_component_change_args() : [ script, "stop" ];
    let command = command_from_args(args) + " >/dev/null 2>&1 & pid=$!; " +
        "( sleep " + seconds + "; kill $pid 2>/dev/null || true ) & watcher=$!; " +
        "wait $pid 2>/dev/null; rc=$?; kill $watcher 2>/dev/null || true; " +
        "wait $watcher 2>/dev/null || true; exit $rc";
    return command_status("sh -c " + shell_quote(command));
}

// The old sing-box processes, once Prokop is stopped for the upgrade: none
// left, or every one procd owns stopped.
function stop_old_sing_box_processes_for_upgrade() {
    let processes = upgrade_sing_box_processes();
    if (processes == null)
        return false;
    if (upgrade_sing_box_count(processes) == 0)
        return true;
    if (!upgrade_procd_owns_all(processes))
        return false;

    let confirmed = upgrade_sing_box_processes();
    if (confirmed == null || upgrade_sing_box_count(confirmed) != upgrade_sing_box_count(processes))
        return false;
    for (let pid, ticks in processes)
        if (confirmed[pid] != ticks)
            return false;
    if (!upgrade_procd_owns_all(confirmed) || !file_exists("/etc/init.d/sing-box"))
        return false;

    upgrade_bounded_stop("/etc/init.d/sing-box");
    let quiet = 0;
    for (let attempt = 0; attempt < 17; attempt++) {
        let remaining = upgrade_sing_box_processes();
        if (remaining == null)
            return false;
        quiet = upgrade_sing_box_count(remaining) == 0 ? quiet + 1 : 0;
        if (quiet >= 2)
            return true;
        command_success_from_args([ "sleep", "1" ]);
    }
    return false;
}

// The package manager replaces the binary underneath a running sing-box, and
// the new Prokop then waits for a runtime that can no longer be identified.
// Retire the old processes first, but only ones procd demonstrably owns: an
// unrelated sing-box must never be signalled from here. A refused stop of
// Prokop (status 2: another sing-box makes the ownership of its runtime
// ambiguous) leaves it running untouched: the upgrade does not go on, and its
// failure does not start the Prokop it never stopped (UC-196, UC-197).
const PROKOP_UPGRADE_STOP_REFUSED = "Prokop was not stopped: another sing-box process makes the ownership of its runtime ambiguous; the upgrade was not started";
const PROKOP_UPGRADE_OLD_SING_BOX = "Old sing-box processes have ambiguous ownership or did not stop";

// The reason the upgrade cannot go on, or "".
function stop_old_sing_box_before_prokop_upgrade() {
    if (file_exists(SERVICE_INIT)) {
        if (upgrade_bounded_stop(SERVICE_INIT) == 2)
            return PROKOP_UPGRADE_STOP_REFUSED;
        prokop_stopped_for_upgrade = true;
    }
    return stop_old_sing_box_processes_for_upgrade() ? "" : PROKOP_UPGRADE_OLD_SING_BOX;
}

// Keep one archive of the working configuration. Installing a different
// version is the moment a configuration is most likely to need restoring.
function save_prokop_configuration_backup(config_dir, backup_dir) {
    if (!ensure_dir(backup_dir) || !command_success_from_args([ "chmod", "700", backup_dir ]))
        return "";
    let backup = backup_dir + "/configuration.tar.gz";
    let temporary = trim(command_output_from_args([ "mktemp", backup_dir + "/.configuration.XXXXXX" ]));
    if (temporary == "")
        return "";
    // Keep the previous copy until the new archive is complete and readable.
    if (!command_success_from_args([ "tar", "-czf", temporary, "-C", config_dir, "prokop" ]) ||
        !command_success_from_args([ "tar", "-tzf", temporary ]) ||
        !command_success_from_args([ "chmod", "600", temporary ]) ||
        !fs.rename(temporary, backup)) {
        remove_file(temporary);
        return "";
    }
    return backup;
}

// LuCI serves the new release's views and ACLs only once its caches are gone
// and rpcd has reloaded.
function refresh_luci_after_prokop_upgrade() {
    remove_file("/var/luci-indexcache");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    command_success("rm -rf /tmp/luci-modulecache/ 2>/dev/null");
    if (file_exists("/etc/init.d/rpcd") && !command_success_from_args([ "/etc/init.d/rpcd", "reload" ]))
        command_success_from_args([ "/etc/init.d/rpcd", "restart" ]);
    command_success_from_args([ "killall", "-HUP", "rpcd" ]);
}

// The packages to install are the ones the release metadata names, the
// latest release as much as a version picked in the version picker (UC-080).
// Metadata without a checksum refuses the upgrade, as install.sh does. Both
// refusals come before anything is staged or Prokop is stopped.
function release_packages(release, backend_file, app_file, i18n_file) {
    let packages = [ [ backend_file, release.backend_name, release.backend_sha256 ],
        [ app_file, release.app_name, release.app_sha256 ] ];
    if (i18n_file != "")
        push(packages, [ i18n_file, release.i18n_name, release.i18n_sha256 ]);
    return packages;
}

function require_release_checksums(packages, latest_version) {
    for (let item in packages)
        if (item[2] == "")
            action_fail("prokop", "install", "Release metadata has no SHA-256 for " + item[1] +
                "; automatic upgrade refused", PROKOP_VERSION, latest_version);
}

function verify_release_downloads(packages, latest_version) {
    progress?.stage?.("verify");
    for (let item in packages) {
        if (file_sha256(item[0]) != item[2])
            action_fail("prokop", "install", "Release package checksum mismatch for " + item[1] +
                "; automatic upgrade refused", PROKOP_VERSION, latest_version);
    }
}

// The latest release is held to the checksums its source publishes:
// latest.json lists one for every package, GitHub a digest per asset.
function verify_latest_release_downloads(release, backend_file, app_file, i18n_file, latest_version) {
    if (!download_checksum_ok(backend_file, release.backend_sha256) ||
        !download_checksum_ok(app_file, release.app_sha256) ||
        (i18n_file != "" && !download_checksum_ok(i18n_file, release.i18n_sha256)))
        action_fail("prokop", "install", "Release package checksum mismatch", PROKOP_VERSION, latest_version);
}

function install_prokop(requested_version) {
    requested_version = as_string(requested_version);
    let selected = requested_version != "" ? selected_prokop_release(requested_version) : null;
    if (requested_version != "" && selected == null)
        action_fail("prokop", "install", "Selected release is unavailable or incompatible", PROKOP_VERSION, requested_version);

    let latest_version = selected != null ? as_string(selected.tag_name) : latest_prokop_version();
    if (latest_version == "")
        latest_version = "unknown";
    if (latest_version == "unknown")
        action_fail("prokop", "install", "Failed to resolve Prokop release", PROKOP_VERSION, latest_version);

    // An explicit version says nothing about what the newest release is.
    if (requested_version == "")
        write_prokop_latest_version_cache(latest_version, now_seconds());
    init_tmp_dir() || action_fail("prokop", "install", "Failed to create temporary directory", PROKOP_VERSION, latest_version);
    updates_log("Resolving Prokop release " + latest_version + " packages");
    let release = resolve_prokop_release(latest_version, selected);
    if (release == null)
        action_fail("prokop", "install", "Failed to resolve Prokop release packages", PROKOP_VERSION, latest_version);

    let backend_file = tmp_dir + "/" + release.backend_name;
    let app_file = tmp_dir + "/" + release.app_name;
    let i18n_file = release.i18n_url != "" ? tmp_dir + "/" + release.i18n_name : "";
    let packages = release_packages(release, backend_file, app_file, i18n_file);
    require_release_checksums(packages, latest_version);
    let count = length(packages);
    if (!download_with_retry(release.backend_url, backend_file, release.backend_name, release.backend_size, 1, count) ||
        !download_with_retry(release.app_url, app_file, release.app_name, release.app_size, 2, count) ||
        (release.i18n_url != "" && !download_with_retry(release.i18n_url, i18n_file, release.i18n_name, release.i18n_size, 3, count)))
        action_fail("prokop", "install", "Failed to download Prokop release packages", PROKOP_VERSION, latest_version);
    verify_release_downloads(packages, latest_version);

    if (selected != null) {
        progress?.stage?.("backup");
        let backup = save_prokop_configuration_backup("/etc/config", "/etc/prokop-backups");
        if (backup == "")
            action_fail("prokop", "install", "Failed to back up Prokop configuration", PROKOP_VERSION, latest_version);
        updates_log("Prokop configuration backup: " + backup);
    }
    else
        verify_latest_release_downloads(release, backend_file, app_file, i18n_file, latest_version);

    // Every refusal comes before Prokop is stopped for the upgrade: a refused
    // upgrade leaves Prokop running (UC-196).
    progress?.stage?.("prepare");
    let error = prepare_prokop_package_set(backend_file, app_file, i18n_file);
    if (error != "")
        action_fail("prokop", "install", error, PROKOP_VERSION, latest_version);

    // Capture the exact managed sing-box process before apk/opkg runs the
    // currently installed package's prerm.
    capture_managed_upgrade_sing_box_marker();

    capture_prokop_start_before_upgrade();
    progress?.stage?.("stop");
    error = stop_old_sing_box_before_prokop_upgrade();
    if (error != "") {
        discard_staged_prokop_package_set();
        action_fail("prokop", "install", error, PROKOP_VERSION, latest_version);
    }

    progress?.stage?.("install");
    error = install_prokop_package_set(latest_version, backend_file, app_file, i18n_file);
    if (error != "")
        action_fail("prokop", "install", error, PROKOP_VERSION, latest_version);
    // The new release is installed: its start follows below.
    prokop_stopped_for_upgrade = false;

    progress?.stage?.("restart");
    refresh_luci_after_prokop_upgrade();

    // The backend package post-install hook has already restored a Prokop
    // instance that was running before this release upgrade. Avoid a second
    // full restart and its readiness wait, but retain the restart fallback
    // if the package lifecycle did not leave Prokop healthy.
    let restarted = true;
    if (prokop_was_running && prokop_status_running_with_timeout())
        updates_log("Prokop was restored by the package upgrade; final restart skipped");
    else if (prokop_was_running && prokop_stopped_by_user())
        updates_log("Prokop was stopped by the user during the upgrade; final start skipped");
    else
        restarted = restart_prokop_after_successful_change();
    progress?.stage?.("check");
    clear_version_caches();
    let new_version = installed_package_version("prokop");
    if (new_version == "")
        new_version = latest_version;
    if (!restarted)
        action_fail("prokop", "install", prokop_restart_refused ? "Prokop has been installed, but " + PROKOP_RESTART_REFUSED_APPLIES_LATER :
            "Prokop has been installed, but did not start again", new_version, latest_version, "", release.release_url);
    updates_log("Prokop updated to " + new_version);
    action_success("prokop", "install", "Prokop has been installed", new_version, latest_version, 1, "latest", release.release_url);
}

function dispatch_sing_box(action) {
    if (action == "install_extended") {
        install_sing_box_extended(action, false);
        return;
    }
    if (action == "install_extended_compressed") {
        install_sing_box_extended(action, true);
        return;
    }
    if (action == "install_tiny") {
        install_package_sing_box(action, true);
        return;
    }
    if (action == "install_stable") {
        install_package_sing_box(action, false);
        return;
    }

    let variant = sing_box_runtime_output("variant", []);
    if (variant == "extended-compressed")
        install_sing_box_extended(action, true);
    else if (variant == "extended")
        install_sing_box_extended(action, false);
    else if (variant == "tiny")
        install_package_sing_box(action, true);
    else
        install_package_sing_box(action, false);
}

function set_packet_steering(action) {
    let init_script = "/etc/init.d/packet_steering";
    let config_path = "network.@globals[0].packet_steering";
    let current_mode = trim(uci_core.get(config_path));
    let target_mode = action == "enable" ? "2" : "1";

    if (!file_exists(init_script))
        action_fail("packet_steering", action, "Packet Steering service is not available", current_mode, target_mode);
    if (!uci_core.available() ||
        !uci_core.set(config_path, target_mode) ||
        !uci_core.commit("network") ||
        !command_success_from_args([ init_script, "restart" ]))
        action_fail("packet_steering", action, "Failed to apply Packet Steering mode " + target_mode, current_mode, target_mode);

    remove_file(SYSTEM_INFO_CACHE_FILE);
    action_success("packet_steering", action,
        target_mode == "2" ? "Packet Steering mode 2 has been enabled" : "Packet Steering normal mode has been restored",
        target_mode, target_mode, current_mode == target_mode ? 0 : 1, "", "");
}

// A setting change applies through a restart, but does not start a Prokop
// that the user stopped (D-15), or one that is not up at all: its next start
// applies the setting. The status probe taken before the action misses a
// runtime whose sing-box is being restarted (a DNS-failover switch, a
// subscription update, a reload) or that answers slowly; its nft table shows
// it is still there.
function prokop_active_for_setting_change() {
    let state_module = LIB_DIR + "/service/state.uc";
    if (module_success([ state_module, "stop-requested" ]))
        return false;
    return prokop_was_running ||
        module_success([ state_module, "runtime-apply-allowed", constants.NFT_TABLE_NAME ]);
}

function set_direct_proxy(action) {
    let enabled_path = CONFIG_NAME + ".settings.direct_proxy_enabled";
    let port_path = CONFIG_NAME + ".settings.direct_proxy_port";
    let current_enabled = trim(uci_core.get(enabled_path)) == "1" ? "1" : "0";
    let target_enabled = action == "enable" ? "1" : "0";
    let current_port = trim(uci_core.get(port_path));
    let current_port_number = match(current_port, /^[0-9]+$/) != null ? int(current_port, 10) : 0;
    let target_port = current_port_number >= 1 && current_port_number <= 65535 ? current_port : "2080";

    if (!file_exists(SERVICE_INIT))
        action_fail("direct_proxy", action, "Prokop service is not available", current_enabled, target_enabled);
    if (target_enabled == "1" && current_enabled != "1") {
        let listen = trim(module_output([ LIB_DIR + "/singbox/runtime.uc", "service-listen-address" ]));
        if (listen == "")
            action_fail("direct_proxy", action, "Failed to determine the Direct Proxy LAN address", current_enabled, target_enabled);
        if (!command_exists("netstat"))
            action_fail("direct_proxy", action, "Failed to verify whether Direct Proxy port " + target_port + " is available", current_enabled, target_enabled);
        let listeners = command_output_from_args([ "netstat", "-ln" ]);
        if (listeners == "")
            action_fail("direct_proxy", action, "Failed to verify whether Direct Proxy port " + target_port + " is available", current_enabled, target_enabled);
        if (netstat.listen_port_in_use(listeners, listen, target_port))
            action_fail("direct_proxy", action, "Direct Proxy port " + target_port + " is already in use", current_enabled, target_enabled);
    }
    if (!uci_core.available() ||
        !uci_core.set(enabled_path, target_enabled) ||
        !uci_core.set(port_path, target_port) ||
        !uci_core.commit(CONFIG_NAME))
        action_fail("direct_proxy", action, "Failed to save Direct Proxy settings", current_enabled, target_enabled);

    let restart_status = 0;
    if (!prokop_active_for_setting_change())
        updates_log("Prokop is not running; the Direct Proxy setting applies at its next start");
    else if ((restart_status = prokop_restart_and_wait()) != 0) {
        // The user's stop overtook the restart: it wins, and the setting
        // applies at the next start. The restart with the previous settings
        // would start Prokop again (D-15, UC-235).
        if (prokop_stopped_by_user())
            updates_log("Prokop was stopped by the user during its restart; the Direct Proxy setting applies at its next start");
        else {
            uci_core.set(enabled_path, current_enabled);
            if (current_port != "")
                uci_core.set(port_path, current_port);
            else
                uci_core.delete(port_path);
            uci_core.commit(CONFIG_NAME);
            // A refused stop changed nothing: Prokop runs on with the
            // previous settings, and their restart would be refused alike.
            if (restart_status == 2)
                action_fail("direct_proxy", action, "Failed to apply Direct Proxy settings: " + PROKOP_RESTART_REFUSED +
                    "; Prokop runs on with the previous Direct Proxy settings", current_enabled, target_enabled);
            if (!prokop_stopped_by_user() && prokop_restart_and_wait() != 0 && !prokop_stopped_by_user())
                updates_log("Prokop did not start again with the previous Direct Proxy settings", "error");
            action_fail("direct_proxy", action, "Failed to apply Direct Proxy settings", current_enabled, target_enabled);
        }
    }

    remove_file(SYSTEM_INFO_CACHE_FILE);
    action_success("direct_proxy", action,
        target_enabled == "1" ? "Direct Proxy has been enabled" : "Direct Proxy has been disabled",
        target_enabled, target_enabled, current_enabled == target_enabled ? 0 : 1, "", "");
}

function set_torrserver_direct(action) {
    let enabled_path = CONFIG_NAME + ".settings.torrserver_direct_enabled";
    let current_enabled = trim(uci_core.get(enabled_path)) == "1" ? "1" : "0";
    let target_enabled = action == "enable" ? "1" : "0";

    if (!file_exists(TORRSERVER_DIRECT_INIT) || !file_exists(TORRSERVER_DIRECT_UC))
        action_fail("torrserver_direct", action, "TorrServer Direct service is not available", current_enabled, target_enabled);
    if (target_enabled == "1") {
        if (!command_success_from_args([ "modprobe", "nft_socket" ]) &&
            (!run_logged("Installing TorrServer Direct kernel support", pkg_install_name_command("kmod-nft-socket")) ||
             !command_success_from_args([ "modprobe", "nft_socket" ])))
            action_fail("torrserver_direct", action, "This firmware does not provide kmod-nft-socket required for TorrServer Direct", current_enabled, target_enabled);
        let status = parse_json_object(module_output([ TORRSERVER_DIRECT_UC, "status" ]));
        if (type(status) != "object" || int(status.running || 0) != 1)
            action_fail("torrserver_direct", action, "TorrServer is not running", current_enabled, target_enabled);
        if (int(status.available || 0) != 1)
            action_fail("torrserver_direct", action, "TorrServer does not have a dedicated cgroup", current_enabled, target_enabled);
    }
    if (!uci_core.available() || !uci_core.set(enabled_path, target_enabled) || !uci_core.commit(CONFIG_NAME))
        action_fail("torrserver_direct", action, "Failed to save TorrServer Direct settings", current_enabled, target_enabled);

    let applied = target_enabled == "1"
        ? command_success_from_args([ TORRSERVER_DIRECT_INIT, "enable" ]) &&
            command_success_from_args([ TORRSERVER_DIRECT_INIT, "restart" ]) &&
            module_success([ TORRSERVER_DIRECT_UC, "reconcile" ])
        : command_success_from_args([ TORRSERVER_DIRECT_INIT, "stop" ]) &&
            command_success_from_args([ TORRSERVER_DIRECT_INIT, "disable" ]);
    if (!applied) {
        uci_core.set(enabled_path, current_enabled);
        uci_core.commit(CONFIG_NAME);
        action_fail("torrserver_direct", action, "Failed to apply TorrServer Direct settings", current_enabled, target_enabled);
    }
    remove_file(SYSTEM_INFO_CACHE_FILE);
    action_success("torrserver_direct", action,
        target_enabled == "1" ? "TorrServer Direct has been enabled" : "TorrServer Direct has been disabled",
        target_enabled, target_enabled, current_enabled == target_enabled ? 0 : 1, "", "");
}

// --- TorrServer -------------------------------------------------------------
// The official build of YouROK/TorrServer for the router's CPU, verified by
// the sha256 GitHub publishes for it, in torrserver/manager.uc's directory
// and run by /etc/init.d/prokop-torrserver. A TorrServer installed by other
// means is never touched: install refuses while one runs or sits at
// Prokop's path, remove refuses to delete a binary Prokop does not own.
// Prokop itself keeps running throughout: nothing of its routing changes.

function torrserver_status() {
    return parse_json_object(module_output([ TORRSERVER_UC, "status" ]));
}

function torrserver_paths() {
    return parse_json_object(module_output([ TORRSERVER_UC, "paths" ]));
}

// The release to install: an object with version, url, sha256, size and
// release_url; { unsupported: true } when TorrServer has no build for this
// CPU; null when the release could not be read (retried).
function resolve_torrserver_release() {
    let arch = trim(module_output([ TORRSERVER_UC, "asset-arch", read_openwrt_release_value("DISTRIB_ARCH"),
        trim(command_output_from_args([ "uname", "-m" ])) ]));
    if (arch == "")
        return { unsupported: true };
    let release_json = fetch_github_release_json("YouROK", "TorrServer");
    if (release_json == "")
        return null;
    let input_path = make_tmp_file("torrserver-release");
    if (input_path == "" || !write_file(input_path, release_json))
        return null;
    let release = parse_json_object(command_output(module_command([ TORRSERVER_UC, "select-asset", arch ]) +
        " <" + shell_quote(input_path)));
    remove_file(input_path);
    if (as_string(release.version) == "")
        return { missing: true, arch };
    release.arch = arch;
    return release;
}

function torrserver_version_key(version) {
    return trim(module_output([ TORRSERVER_UC, "version-key", version ]));
}

function torrserver_stop_disable() {
    let stopped = command_success_from_args([ TORRSERVER_INIT, "stop" ]);
    command_success_from_args([ TORRSERVER_INIT, "disable" ]);
    return stopped;
}

function torrserver_enable_start() {
    return command_success_from_args([ TORRSERVER_INIT, "enable" ]) &&
        command_success_from_args([ TORRSERVER_INIT, "restart" ]);
}

function torrserver_wait_running(version) {
    return module_success([ TORRSERVER_UC, "wait-running", TORRSERVER_START_TIMEOUT, version ]);
}

// TorrServer Direct marks the sockets of TorrServer's cgroup, which procd
// makes anew for the new process: the rule follows it at once instead of
// at the worker's next pass.
function torrserver_direct_follow() {
    if (trim(uci_core.get(CONFIG_NAME + ".settings.torrserver_direct_enabled")) == "1" && file_exists(TORRSERVER_DIRECT_UC))
        module_success([ TORRSERVER_DIRECT_UC, "reconcile" ]);
}

// Puts back the binary and marker moved aside before the change; true when
// there were none to put back or they are back.
function restore_torrserver_backup(paths, had_backup) {
    if (!had_backup) {
        remove_file(paths.bin);
        remove_file(paths.marker);
        return true;
    }
    return move_file_portable(paths.bin + ".prokop-old", paths.bin) &&
        move_file_portable(paths.marker + ".prokop-old", paths.marker);
}

// An install or update cut off midway (power loss, a worker killed) left
// its files behind: the staged binary goes, and when the binary at the
// path is not the whole one its marker names, the previous pair kept aside
// comes back. Before this, such leftovers read as a foreign TorrServer that
// the card could neither remove nor install over (TS-3).
function recover_torrserver_files(paths) {
    remove_file(paths.bin + ".prokop-new");
    remove_file(paths.marker + ".tmp");
    let old_bin = paths.bin + ".prokop-old";
    let old_marker = paths.marker + ".prokop-old";
    let kept_aside = file_exists(old_bin) || file_exists(old_marker);
    if (!kept_aside) {
        // A first install cut off between its marker and its binary.
        if (file_exists(paths.marker) && !file_exists(paths.bin))
            remove_file(paths.marker);
        return;
    }
    if (!module_success([ TORRSERVER_UC, "managed" ])) {
        updates_log("Restoring the TorrServer kept aside by an update that did not finish", "warn");
        if (file_exists(old_bin))
            move_file_portable(old_bin, paths.bin);
        if (file_exists(old_marker))
            move_file_portable(old_marker, paths.marker);
    }
    remove_file(old_bin);
    remove_file(old_marker);
}

// Whether TorrServer has its own settings yet: its database, in data/ or,
// from an install before TS-1, beside the binary.
function torrserver_has_database(paths) {
    return file_exists(as_string(paths.data_dir) + "/config.db") || file_exists(paths.dir + "/config.db");
}

// Gives the TorrServer Prokop just installed the recommended settings
// (torrserver/manager.uc). Only for a TorrServer that had no database
// before: the settings of one that had are the user's, and an update, a
// start or an upgrade of Prokop leaves them alone; the card's button
// applies them on request (TS-8). A note for the action's message when they
// could not be applied.
function torrserver_settings_fresh(fresh) {
    if (!fresh)
        return "";
    if (module_success([ TORRSERVER_UC, "apply-recommended-now", "10" ])) {
        updates_log("Recommended TorrServer settings have been applied");
        torrserver_settings_applied = 1;
        return "";
    }
    updates_log("TorrServer did not take the recommended settings", "warn");
    torrserver_settings_applied = 0;
    return "; the recommended settings were not applied";
}

function install_torrserver(action) {
    if (!file_exists(TORRSERVER_INIT) || !file_exists(TORRSERVER_UC))
        action_fail("torrserver", action, "TorrServer service is not available in this Prokop build");
    let status = torrserver_status();
    let paths = torrserver_paths();
    if (as_string(paths.bin) == "" || as_string(paths.marker) == "")
        action_fail("torrserver", action, "Failed to read TorrServer paths");
    if (action != "check_update") {
        recover_torrserver_files(paths);
        status = torrserver_status();
    }
    let installed = int(status.installed || 0) == 1;
    let current_version = installed ? as_string(status.version) : "";

    let release = null;
    retry_resolve("Resolving TorrServer release", function() {
        release = resolve_torrserver_release();
        return release != null;
    });
    if (release == null)
        action_fail("torrserver", action, "Failed to read the latest TorrServer release", current_version);
    if (release.unsupported)
        action_fail("torrserver", action, "TorrServer publishes no build for this router's CPU", current_version);
    if (release.missing)
        action_fail("torrserver", action, "The latest TorrServer release has no verified build for " + release.arch, current_version);

    if (action == "check_update") {
        if (!installed)
            action_fail("torrserver", action, "TorrServer is not installed", "", release.version, "", release.release_url || "");
        check_success_compared("torrserver", current_version, release.version,
            torrserver_version_key(current_version), torrserver_version_key(release.version), release.release_url || "");
    }

    // Fail closed on a TorrServer that is not Prokop's: it would be
    // overwritten, or two servers would compete for the port.
    if (int(status.foreign || 0) == 1)
        action_fail("torrserver", action, "Another TorrServer is installed or running on this router; Prokop does not replace it",
            current_version, release.version, "", release.release_url || "");
    if (installed && !module_success([ TORRSERVER_UC, "managed" ]))
        action_fail("torrserver", action, "The installed TorrServer binary does not match the checksum Prokop recorded; it was not replaced",
            current_version, release.version, "", release.release_url || "");
    if (installed && current_version == release.version && int(status.running || 0) == 1)
        action_success("torrserver", action, "Latest TorrServer is already installed",
            current_version, release.version, 0, "latest", release.release_url || "");

    // TorrServer is downloaded straight to the router's storage, next to the
    // binary it replaces, which stays until the new one answers. The old
    // binary already has its place there: the new one needs only its own
    // size (TS-2), and nothing passes through /tmp, the router's RAM.
    if (!ensure_dir(paths.dir))
        action_fail("torrserver", action, "Failed to create " + paths.dir, current_version, release.version, "", release.release_url || "");
    let needed_kib = int(int(release.size) / 1024) + 2048;
    let dir_kib = available_kib(paths.dir);
    if (dir_kib >= 0 && dir_kib < needed_kib)
        action_fail("torrserver", action, "Not enough free space on the router's storage to install TorrServer: " +
            dir_kib + " KiB available where " + needed_kib + " KiB is needed",
            current_version, release.version, "", release.release_url || "");

    let staged = paths.bin + ".prokop-new";
    remove_file(staged);
    if (!download_with_retry(release.url, staged, release.name, release.size)) {
        remove_file(staged);
        action_fail("torrserver", action, "Failed to download TorrServer", current_version, release.version, "", release.release_url || "");
    }
    // Hashed once, where it is installed from: the marker records what was
    // checked here.
    if (file_bytes(staged) != int(release.size) || !download_checksum_ok(staged, release.sha256)) {
        remove_file(staged);
        action_fail("torrserver", action, "Downloaded TorrServer does not match its published size and sha256",
            current_version, release.version, "", release.release_url || "");
    }
    if (!command_success_from_args([ "chmod", "0755", staged ])) {
        remove_file(staged);
        action_fail("torrserver", action, "Failed to stage TorrServer on the router's storage",
            current_version, release.version, "", release.release_url || "");
    }
    // The build must run on this CPU and be the release it claims.
    let staged_version = trim(module_output([ TORRSERVER_UC, "binary-version", staged ]));
    if (staged_version != release.version) {
        remove_file(staged);
        action_fail("torrserver", action, "The downloaded TorrServer does not run on this router or reports another version (" +
            (staged_version != "" ? staged_version : "no version") + ")", current_version, release.version, "", release.release_url || "");
    }

    if (installed) {
        progress?.stage?.("stop");
        updates_log("Stopping TorrServer " + current_version + " for the update");
        command_success_from_args([ TORRSERVER_INIT, "stop" ]);
    }
    let had_backup = installed;
    if (had_backup && (!move_file_to_backup(paths.bin, paths.bin + ".prokop-old") ||
        !move_file_to_backup(paths.marker, paths.marker + ".prokop-old"))) {
        restore_torrserver_backup(paths, true);
        remove_file(staged);
        torrserver_enable_start();
        action_fail("torrserver", action, "Failed to keep the installed TorrServer aside for the update; it runs on unchanged",
            current_version, release.version, "", release.release_url || "");
    }
    progress?.stage?.("install");
    // The marker first, then the binary it names: cut off between the two,
    // the marker names no binary and recover_torrserver_files() puts the
    // previous one back (TS-3).
    if (!module_success([ TORRSERVER_UC, "write-marker", release.version, release.sha256, staged ]) ||
        !fs.rename(staged, paths.bin)) {
        remove_file(staged);
        let restored = restore_torrserver_backup(paths, had_backup);
        if (had_backup && restored)
            torrserver_enable_start();
        action_fail("torrserver", action, "Failed to install TorrServer" + (had_backup ? (restored ? "; the previous version was restored" :
            "; the previous version could not be restored") : ""), current_version, release.version, "", release.release_url || "");
    }

    progress?.stage?.("start");
    // Read before TorrServer's first start writes its database.
    let fresh = !installed && !torrserver_has_database(paths);
    updates_log("Starting TorrServer " + release.version);
    if (!torrserver_enable_start() || !torrserver_wait_running(release.version)) {
        updates_log("TorrServer " + release.version + " did not start", "error");
        command_success_from_args([ TORRSERVER_INIT, "stop" ]);
        let restored = restore_torrserver_backup(paths, had_backup);
        let back = false;
        if (had_backup && restored)
            back = torrserver_enable_start() && torrserver_wait_running(current_version);
        else
            command_success_from_args([ TORRSERVER_INIT, "disable" ]);
        clear_version_caches();
        action_fail("torrserver", action, "TorrServer " + release.version + " did not start" +
            (had_backup ? (back ? "; the previous version " + current_version + " runs again" :
                "; the previous version " + current_version + " could not be started again") : " and was removed"),
            current_version, release.version, "", release.release_url || "");
    }
    remove_file(paths.bin + ".prokop-old");
    remove_file(paths.marker + ".prokop-old");
    torrserver_direct_follow();
    clear_version_caches();
    action_success("torrserver", action, (installed ? "TorrServer has been updated" : "TorrServer has been installed") + torrserver_settings_fresh(fresh),
        release.version, release.version, 1, "latest", release.release_url || "");
}

// Starts the TorrServer Prokop installed again (stopped by hand, or after a
// failure procd gave up respawning) and waits for it to answer. Its
// settings stay as they are (TS-8). Refused while another TorrServer runs
// or holds the port: the start would only compete with it (TS-10).
function start_torrserver() {
    let paths = torrserver_paths();
    if (as_string(paths.bin) != "" && as_string(paths.marker) != "")
        recover_torrserver_files(paths);
    let status = torrserver_status();
    let current_version = as_string(status.version);
    if (int(status.installed || 0) != 1)
        action_fail("torrserver", "start", "TorrServer is not installed");
    if (int(status.foreign || 0) == 1)
        action_fail("torrserver", "start", "Another TorrServer is installed or running on this router; Prokop does not replace it",
            current_version);
    if (int(status.running || 0) == 1)
        action_success("torrserver", "start", "TorrServer is already running", current_version, "", 0);
    if (!torrserver_enable_start() || !torrserver_wait_running(current_version))
        action_fail("torrserver", "start", "TorrServer " + current_version + " did not start", current_version);
    torrserver_direct_follow();
    clear_version_caches();
    action_success("torrserver", "start", "TorrServer has been started", current_version, "", 1);
}

// The card's button: the recommended settings (torrserver/manager.uc) over
// TorrServer's own again, whatever was applied before; the others stay.
function apply_torrserver_settings() {
    let status = torrserver_status();
    let current_version = as_string(status.version);
    if (int(status.installed || 0) != 1)
        action_fail("torrserver", "apply_settings", "TorrServer is not installed");
    if (int(status.foreign || 0) == 1)
        action_fail("torrserver", "apply_settings", "Another TorrServer is installed or running on this router; Prokop does not replace it",
            current_version);
    if (int(status.running || 0) != 1)
        action_fail("torrserver", "apply_settings", "TorrServer is stopped; start it to apply the settings", current_version);
    if (!module_success([ TORRSERVER_UC, "apply-recommended-now" ]))
        action_fail("torrserver", "apply_settings", "TorrServer did not take the recommended settings", current_version);
    updates_log("Recommended TorrServer settings have been applied");
    action_success("torrserver", "apply_settings", "Recommended TorrServer settings have been applied", current_version, "", 1);
}

// Removes the binary Prokop installed and stops its service; TorrServer's
// settings and torrent list (its database in the same directory) stay.
function remove_torrserver() {
    let paths = torrserver_paths();
    if (as_string(paths.bin) == "" || as_string(paths.marker) == "")
        action_fail("torrserver", "remove", "Failed to read TorrServer paths");
    recover_torrserver_files(paths);
    let status = torrserver_status();
    let current_version = as_string(status.version);
    if (int(status.installed || 0) != 1) {
        if (file_exists(paths.bin))
            action_fail("torrserver", "remove", "This TorrServer was not installed by Prokop and was not removed");
        if (file_exists(TORRSERVER_INIT))
            command_success_from_args([ TORRSERVER_INIT, "disable" ]);
        action_success("torrserver", "remove", "TorrServer is already removed", "", "", 0);
    }
    if (!module_success([ TORRSERVER_UC, "managed" ]))
        action_fail("torrserver", "remove", "The installed TorrServer binary does not match the checksum Prokop recorded; it was not removed",
            current_version);
    if (file_exists(TORRSERVER_INIT) && !torrserver_stop_disable())
        action_fail("torrserver", "remove", "Failed to stop TorrServer", current_version);
    remove_file(paths.bin);
    remove_file(paths.marker);
    if (file_exists(paths.bin))
        action_fail("torrserver", "remove", "Failed to remove TorrServer", current_version);
    clear_version_caches();
    action_success("torrserver", "remove", "TorrServer has been removed; its settings stay in " + paths.dir, current_version, "", 1);
}

function normalize_component_name(component) {
    component = as_string(component);
    if (component == "sing-box" || component == "singbox")
        return "sing_box";
    if (component == "prokop")
        return "prokop";
    return component;
}

// components/catalog.uc, loaded on use: a library without it (a test's
// partial copy) leaves the decision to the dispatch below.
function component_action_in_catalog(component, action) {
    let catalog = null;
    try {
        catalog = require("components.catalog");
    }
    catch (e) {
        return true;
    }
    return catalog.supported(component, action);
}

function component_action(component, action, version) {
    component = normalize_component_name(component);
    action = as_string(action);
    version = as_string(version);
    if (!acquire_component_lock())
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Another component action is already running",
            "", "", "", "", "busy");
    if (!init_tmp_dir())
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Failed to create temporary directory");
    // Only what the catalog lists runs, the list the UI's background start
    // refuses by (UC-119): an action added to the dispatch below and not to
    // the catalog is refused here as well, not only in the UI.
    if (!component_action_in_catalog(component, action))
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Unknown component action",
            "", "", "", "", "invalid_input");
    if (component == "prokop" && action == "install" &&
        file_exists(PROKOP_OPKG_RECOVERY_DIR + "/pending")) {
        // Restoring the backend runs its prerm, which stops Prokop for the
        // package. A rollback that fails again starts the Prokop that was
        // running when this action began (UC-196); a completed one restores
        // the state recorded before the upgrade.
        capture_prokop_running_state();
        prokop_stopped_for_upgrade = true;
        // The card shows the recovery, not a release without stages (PRG-4).
        progress?.begin?.(PROGRESS_FILE, component, action, "rollback");
        let recovery_error = recover_prokop_opkg_set();
        if (recovery_error != "")
            action_fail("prokop", "install", recovery_error);
        action_success("prokop", "install",
            "Prokop package-set recovery completed; no new update was attempted, and a fresh invocation is required",
            installed_package_version("prokop"), "", 0, "recovered");
    }
    capture_prokop_running_state();
    // What the UI shows while the action runs; a check reports nothing.
    if (action != "check_update")
        progress?.begin?.(PROGRESS_FILE, component, action, action == "remove" ? "remove" : action == "start" ? "start" :
            (action == "enable" || action == "disable" || action == "restore" || action == "apply_settings") ? "apply" : "resolve");

    if (component == "prokop" && action == "check_update")
        check_prokop();
    else if (component == "prokop" && action == "install")
        install_prokop(version);
    else if (component == "sing_box" && (action == "check_update" || action == "install" ||
        action == "install_extended" || action == "install_extended_compressed" ||
        action == "install_tiny" || action == "install_stable"))
        dispatch_sing_box(action);
    else if (component == "zapret" && (action == "check_update" || action == "install"))
        install_zapret(action);
    else if (component == "zapret" && action == "remove")
        remove_optional_component("zapret", "zapret", "zapret", LIB_DIR + "/providers/zapret/runtime.uc");
    else if (component == "zapret2" && (action == "check_update" || action == "install"))
        install_zapret2(action);
    else if (component == "zapret2" && action == "remove")
        remove_optional_component("zapret2", "zapret2", "zapret2", LIB_DIR + "/providers/zapret2/runtime.uc");
    else if (component == "byedpi" && (action == "check_update" || action == "install"))
        install_byedpi(action);
    else if (component == "byedpi" && action == "remove")
        remove_optional_component("byedpi", "byedpi", "ByeDPI", LIB_DIR + "/providers/byedpi/runtime.uc");
    else if (component == "zapret_manager" && action == "install")
        install_zapret_manager(action);
    else if (component == "zapret_manager" && action == "remove")
        remove_zapret_manager(action);
    else if (component == "packet_steering" && (action == "enable" || action == "restore"))
        set_packet_steering(action);
    else if (component == "direct_proxy" && (action == "enable" || action == "disable"))
        set_direct_proxy(action);
    else if (component == "torrserver" && (action == "check_update" || action == "install"))
        install_torrserver(action);
    else if (component == "torrserver" && action == "remove")
        remove_torrserver();
    else if (component == "torrserver" && action == "start")
        start_torrserver();
    else if (component == "torrserver" && action == "apply_settings")
        apply_torrserver_settings();
    else if (component == "torrserver_direct" && (action == "enable" || action == "disable"))
        set_torrserver_direct(action);
    else
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Unknown component action",
            "", "", "", "", "invalid_input");
}

let mode = ARGV[0] || "";

if (mode == "component-action")
    component_action(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "prokop-releases")
    exit(prokop_releases() ? 0 : 1);
else if (mode == "available-kib-fixture")
    print(available_kib(ARGV[1]), "\n");
else if (mode == "install-managed-sing-box-service-fixture")
    exit(install_managed_sing_box_service_script() ? 0 : 1);
else if (mode == "prokop-package-set-space-error-fixture") {
    // Arguments are the new files, then "--", then the staged rollback files.
    let new_files = [];
    let staged_files = [];
    let staged = false;
    for (let i = 1; i < length(ARGV); i++) {
        if (as_string(ARGV[i]) == "--") {
            staged = true;
            continue;
        }
        push(staged ? staged_files : new_files, ARGV[i]);
    }
    print(prokop_package_set_space_error(new_files, staged_files), "\n");
}
else if (mode == "pkg-prokop-set-command-fixture")
    print(pkg_prokop_set_command([ ARGV[1] ], ARGV[2] == "1", ARGV[3] == "1"), "\n");
else if (mode == "pkg-set-extension-fixture")
    print(pkg_set_extension(), "\n");
else if (mode == "prokop-release-catalog-fixture")
    print(sprintf("%J", parse_prokop_release_catalog(read_file(ARGV[1]), ARGV[2])), "
");
else if (mode == "latest-prokop-release-json")
    print(latest_prokop_release_json());
else if (mode == "latest-prokop-version")
    print(latest_prokop_version(), "\n");
else if (mode == "prokop-release-metadata")
    print(fetch_prokop_latest_release_metadata(), "\n");
else if (mode == "reconcile-zapret-manager-launchers")
    exit(reconcile_zapret_manager_launchers() ? 0 : 1);
else {
    warn("Usage: components/action.uc <component-action|latest-prokop-version|prokop-release-metadata> ...\n");
    exit(1);
}
