// br_netfilter passes bridged frames through the iptables and ip6tables
// hooks (net.bridge.bridge-nf-call-iptables, -ip6tables), where the TPROXY
// of bridged LAN traffic goes wrong; Prokop's start turns them off. They are
// kernel-wide settings that other programs may rely on (iptables filtering
// of bridged traffic), so Prokop keeps what they were (D-19, UC-109):
//
// - turn_off() records the value of each hook it turns off before it writes
//   0, once per boot: a record that is already there (an earlier start, a
//   reload, a crash) keeps the values from before Prokop. A hook first
//   turned off by a later reload (another program has switched it on while
//   Prokop ran) records the value it had then;
// - restore() at stop puts a recorded value back only where the hook still
//   holds the 0 that Prokop wrote. Something else that has set it since owns
//   it now and it stays; a record that cannot be read changes nothing.
//
// The record lives in the runtime state directory on tmpfs, as the settings
// themselves do: a reboot clears both.

let fs = require("fs");

const PROC_SYS_DIR = getenv("PROKOP_PROC_SYS_DIR") || "/proc/sys";
const RUNTIME_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const RECORD_FILE = RUNTIME_DIR + "/bridge-netfilter.saved";
const HOOKS = {
    iptables: "net/bridge/bridge-nf-call-iptables",
    ip6tables: "net/bridge/bridge-nf-call-ip6tables"
};
const PROKOP_VALUE = "0";

function as_string(value) {
    return value == null ? "" : "" + value;
}

// The value of a hook, or null when there is none (br_netfilter is not
// loaded; the files exist only while it is).
function hook_value(name) {
    let value = fs.readfile(PROC_SYS_DIR + "/" + HOOKS[name]);
    return value == null ? null : trim(as_string(value));
}

function set_hook(name, value) {
    let file = fs.open(PROC_SYS_DIR + "/" + HOOKS[name], "w");
    if (!file)
        return false;
    let written = file.write(value + "\n");
    file.close();
    return written != null && hook_value(name) == value;
}

function loaded() {
    return hook_value("iptables") != null || hook_value("ip6tables") != null;
}

// The recorded values: null without a record, "invalid" when it cannot be
// read as one.
function read_record() {
    let data = fs.readfile(RECORD_FILE);
    if (data == null)
        return null;
    let record = null;
    try { record = json(data); } catch (e) { return "invalid"; }
    if (type(record) != "object")
        return "invalid";
    for (let name in keys(record))
        if (HOOKS[name] == null || match(as_string(record[name]), /^[0-9]+$/) == null)
            return "invalid";
    return record;
}

function write_record(record) {
    fs.mkdir(RUNTIME_DIR);
    let tmp = RECORD_FILE + ".tmp." + as_string(clock()[1]);
    if (fs.writefile(tmp, sprintf("%J\n", record)) == null) {
        fs.unlink(tmp);
        return false;
    }
    if (!fs.rename(tmp, RECORD_FILE)) {
        fs.unlink(tmp);
        return false;
    }
    return true;
}

// Turns off the hooks that are on. log(message, level) reports what it did.
// False when a hook could not be turned off.
function turn_off(log) {
    let on = [];
    for (let name in keys(HOOKS)) {
        let value = hook_value(name);
        if (value != null && value != PROKOP_VALUE)
            push(on, name);
    }
    if (length(on) == 0)
        return true;

    let record = read_record();
    if (record == "invalid") {
        log("The saved br_netfilter settings are unreadable; Prokop will not restore them at stop", "warn");
        record = null;
        fs.unlink(RECORD_FILE);
    }
    let kept = record != null;
    record = record || {};
    let changed = false;
    for (let name in on)
        if (record[name] == null) {
            record[name] = hook_value(name);
            changed = true;
        }
    // Without a record the hooks are still turned off (transparent proxying
    // needs that), but stop cannot put them back.
    if ((changed || !kept) && !write_record(record))
        log("Could not save the br_netfilter settings; they will not be restored at stop", "warn");

    log("br_netfilter is enabled; disabling it for transparent proxy routing", "debug");
    let ok = true;
    for (let name in on)
        if (!set_hook(name, PROKOP_VALUE))
            ok = false;
    return ok;
}

// Puts back what turn_off() recorded, where the hook still holds Prokop's 0.
// The record goes either way.
function restore(log) {
    let record = read_record();
    if (record == null)
        return true;
    if (record == "invalid") {
        log("The saved br_netfilter settings are unreadable; leaving the current ones", "warn");
        fs.unlink(RECORD_FILE);
        return true;
    }
    let ok = true;
    for (let name in keys(record)) {
        let value = hook_value(name);
        if (value == null)
            continue;
        if (value != PROKOP_VALUE) {
            log("bridge-nf-call-" + name + " was changed by another program since Prokop's start; leaving it at " + value, "info");
            continue;
        }
        if (set_hook(name, as_string(record[name])))
            log("Restored bridge-nf-call-" + name + " to " + record[name], "debug");
        else {
            log("Failed to restore bridge-nf-call-" + name + " to " + record[name], "warn");
            ok = false;
        }
    }
    fs.unlink(RECORD_FILE);
    return ok;
}

// For health: br_netfilter is loaded, its hooks now, and whether Prokop
// holds them off: a recorded hook that still holds Prokop's 0, which stop
// would put back.
function status() {
    let record = read_record();
    let held = false;
    if (type(record) == "object")
        for (let name in keys(record))
            if (hook_value(name) == PROKOP_VALUE)
                held = true;
    return {
        loaded: loaded(),
        iptables: hook_value("iptables"),
        ip6tables: hook_value("ip6tables"),
        disabled_by_prokop: held
    };
}

return { turn_off, restore, status };
