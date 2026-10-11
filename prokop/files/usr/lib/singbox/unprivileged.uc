#!/usr/bin/env ucode

// sing-box without root (opt-in: settings.sing_box_unprivileged, off by
// default). sing-box is the process that parses what the internet sends
// (subscriptions, every proxied protocol); run as root, a flaw in it is a
// flaw with every right on the router.
//
// With the option on, sing-box runs as its own system user (prokop-sb) with
// only the capabilities it needs: CAP_NET_ADMIN (TPROXY, routing marks),
// CAP_NET_RAW, CAP_NET_BIND_SERVICE (the DNS inbound on port 53), and
// no_new_privs, as homeproxy runs it (immortalwrt/homeproxy,
// root/etc/init.d/homeproxy and root/etc/capabilities/homeproxy.json,
// GPL-2.0: the capability set and the procd parameters follow it).
//
// Prokop decides before every publish of config.json (prepare) and leaves
// the decision in DECISION_FILE; the managed sing-box service script
// (singbox/managed_service.uc) reads it at each start. Every precondition
// that does not hold leaves sing-box as root, the way it always ran, and
// says why (STATUS_FILE, shown under Settings): fail closed means never a
// sing-box that cannot read its configuration or bind its inbounds.
//
// - Only the service script Prokop installs can pass the user and the
//   capabilities to procd: the script of a sing-box package cannot.
// - procd hands capabilities over through ujail (procd-ujail).
// - The capabilities file is written by Prokop and read back.
// - The user is created as OpenWrt packages create theirs (TorrServer's
//   user in init.d/prokop-torrserver does the same).
// - A configuration with a tun inbound, a WireGuard or a Tailscale
//   endpoint needs more than those capabilities and stays on root.
// - config.json becomes the user's (0600: the secrets stay unreadable by
//   every other user), so do the FakeIP/cache file and the working
//   directory; every file the configuration names (local rule sets,
//   certificates) must be readable by the user. Files in Prokop's own rule
//   set and list caches are given to the user's group (g+r, and g+x on
//   their directories); any other file it cannot read leaves sing-box on
//   root.
//
// NOT TESTED on a router: the procd/ujail side is written after homeproxy
// and procd's documented parameters; the tests run with stubs.

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");

const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || "prokop";
const RUNTIME_STATE_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const USER = getenv("PROKOP_SING_BOX_USER") || "prokop-sb";
// The managed service script reads these two at fixed paths.
const DECISION_FILE = getenv("PROKOP_SING_BOX_USER_DECISION_FILE") || "/var/run/prokop/sing-box-user";
const CAPABILITIES_FILE = getenv("PROKOP_SING_BOX_CAPABILITIES_FILE") || "/etc/capabilities/prokop-sing-box.json";
const STATUS_FILE = getenv("PROKOP_SING_BOX_USER_STATUS_FILE") || RUNTIME_STATE_DIR + "/sing-box-user.json";
const PASSWD_FILE = getenv("PROKOP_PASSWD_FILE") || "/etc/passwd";
const GROUP_FILE = getenv("PROKOP_GROUP_FILE") || "/etc/group";
const FUNCTIONS_SH = getenv("PROKOP_FUNCTIONS_SH") || "/lib/functions.sh";
const UJAIL = getenv("PROKOP_UJAIL_BIN") || "/sbin/ujail";
const INIT_SCRIPT = getenv("PROKOP_SING_BOX_INIT_SCRIPT") || "/etc/init.d/sing-box";
const MANAGED_MARKER = getenv("SB_MANAGED_SERVICE_MARKER") || "Prokop managed sing-box service for binary variants";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || "/tmp/sing-box";
// Prokop's own caches of the files a configuration names: their files
// may be handed to the user's group.
const MANAGED_ROOTS = [
    getenv("PROKOP_RULESET_CACHE_DIR") || "/etc/prokop/ruleset-cache",
    getenv("PROKOP_PERSISTENT_LIST_CACHE_DIR") || "/etc/prokop/list-cache",
    getenv("PROKOP_RULESET_RUNTIME_CACHE_DIR") || TMP_SING_BOX_FOLDER + "/ruleset-cache",
    getenv("TMP_RULESET_FOLDER") || TMP_SING_BOX_FOLDER + "/rulesets"
];
// Test only: chown is recorded here instead of done (a test cannot hand a
// file to another user). Empty in production.
const TEST_CHOWN_LOG = getenv("PROKOP_SING_BOX_USER_TEST_CHOWN_LOG") || "";

const CAPABILITIES = [ "CAP_NET_ADMIN", "CAP_NET_BIND_SERVICE", "CAP_NET_RAW" ];

// What the UI shows for each reason (service/ui.uc passes the code).
const REASONS = {
    service_script: "the sing-box package's own service script cannot run sing-box as another user with network capabilities",
    no_ujail: "procd cannot grant capabilities on this firmware (no /sbin/ujail, package procd-ujail)",
    capabilities_file: "the capabilities file " + CAPABILITIES_FILE + " could not be written",
    user: "the system user " + USER + " could not be created",
    unsupported_config: "the configuration has a tun inbound, a WireGuard or a Tailscale endpoint, which need root",
    config_file: "the sing-box configuration could not be handed to the user",
    cache_file: "the sing-box cache file could not be handed to the user",
    workdir: "the sing-box working directory could not be handed to the user",
    path_unreadable: "a file the configuration names is not readable by the user"
};

let as_string = common.as_string;

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function log_message(message, level) {
    system("logger -t prokop " + shell_quote("[" + (level || "info") + "] " + message) + " >/dev/null 2>&1");
}

function requested() {
    let value = lc(trim(as_string(uci_core.get(CONFIG_NAME + ".settings.sing_box_unprivileged"))));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

// name:x:uid:gid:... of the user, or null.
function passwd_entry(name) {
    for (let line in split(as_string(fs.readfile(PASSWD_FILE) || ""), "\n")) {
        let fields = split(line, ":");
        if (length(fields) >= 4 && fields[0] == name &&
            match(fields[2], /^[0-9]+$/) != null && match(fields[3], /^[0-9]+$/) != null)
            return { uid: int(fields[2]), gid: int(fields[3]) };
    }
    return null;
}

function id_taken(id) {
    for (let path in [ PASSWD_FILE, GROUP_FILE ])
        for (let line in split(as_string(fs.readfile(path) || ""), "\n")) {
            let fields = split(line, ":");
            if (length(fields) >= 3 && fields[2] == "" + id)
                return true;
        }
    return false;
}

// As init.d/prokop-torrserver ensure_torrserver_user: a group and a user
// with the same free id from 65536 up, through OpenWrt's own functions.
// Never root, never an id another user has.
function ensure_user() {
    let entry = passwd_entry(USER);
    if (entry == null) {
        let id = 65536;
        while (id_taken(id) && id < 65536 + 4096)
            id++;
        if (id_taken(id) || fs.stat(FUNCTIONS_SH) == null)
            return null;
        system(". " + shell_quote(FUNCTIONS_SH) + " && group_add " + shell_quote(USER) + " " + id +
            " && user_add " + shell_quote(USER) + " " + id + " " + id + " " + shell_quote("Prokop sing-box") +
            " /var/run/prokop /bin/false >/dev/null 2>&1");
        entry = passwd_entry(USER);
    }
    return entry != null && entry.uid != 0 && entry.gid != 0 ? entry : null;
}

function capabilities_text() {
    let caps = {};
    for (let set in [ "bounding", "effective", "ambient", "permitted", "inheritable" ])
        caps[set] = CAPABILITIES;
    return sprintf("%J\n", caps);
}

function install_capabilities_file() {
    let text = capabilities_text();
    if (fs.readfile(CAPABILITIES_FILE) === text)
        return true;
    let slash = rindex(CAPABILITIES_FILE, "/");
    system("mkdir -p " + shell_quote(substr(CAPABILITIES_FILE, 0, slash)) + " >/dev/null 2>&1");
    let tmp = CAPABILITIES_FILE + ".prokop." + as_string(fs.readlink("/proc/self"));
    if (fs.writefile(tmp, text) == null || !fs.chmod(tmp, 0644) || fs.readfile(tmp) !== text ||
        !fs.rename(tmp, CAPABILITIES_FILE)) {
        fs.unlink(tmp);
        return false;
    }
    return fs.readfile(CAPABILITIES_FILE) === text;
}

function managed_script_installed() {
    let data = fs.readfile(INIT_SCRIPT);
    return data != null && index(data, MANAGED_MARKER) >= 0;
}

// A tun inbound, a WireGuard or Tailscale endpoint (or outbound).
function config_needs_root(config) {
    for (let list in [ config.inbounds, config.endpoints, config.outbounds ])
        for (let item in (type(list) == "array" ? list : []))
            if (type(item) == "object" && index([ "tun", "wireguard", "tailscale" ], as_string(item.type)) >= 0)
                return true;
    return false;
}

// The files the configuration names: every absolute string under a key
// that ends in "path" (singbox/runtime.uc config_named_paths), the cache
// file excepted (handed over on its own).
function named_paths(value, paths, key) {
    if (type(value) == "object") {
        for (let name, item in value)
            if (name != "experimental")
                named_paths(item, paths, name);
    }
    else if (type(value) == "array") {
        for (let item in value)
            named_paths(item, paths, key);
    }
    else if (type(value) == "string" && match(as_string(key), /path$/) != null &&
        substr(value, 0, 1) == "/" && index(paths, value) < 0)
        push(paths, value);
}

function chown_path(path, uid, gid) {
    if (TEST_CHOWN_LOG != "") {
        let log = fs.open(TEST_CHOWN_LOG, "a");
        if (log == null)
            return false;
        log.write(sprintf("%s %d:%d\n", path, uid, gid));
        log.close();
        return true;
    }
    return fs.chown(path, uid, gid) == true;
}

function owner_ids(path, stat) {
    if (TEST_CHOWN_LOG != "") {
        let last = null;
        for (let line in split(as_string(fs.readfile(TEST_CHOWN_LOG) || ""), "\n")) {
            let m = match(line, /^(.*) ([0-9]+):([0-9]+)$/);
            if (m != null && m[1] == path)
                last = { uid: int(m[2]), gid: int(m[3]) };
        }
        if (last != null)
            return last;
    }
    return { uid: stat.uid, gid: stat.gid };
}

// Whether ids (uid, gid) may do bits (4 read, 1 search) on path, from its
// owner and mode: the user's rights, not this root process's.
function allowed(path, stat, ids, bits) {
    let owner = owner_ids(path, stat);
    let mode = stat.mode & 0777;
    if (owner.uid == ids.uid)
        return ((mode >> 6) & bits) == bits;
    if (owner.gid == ids.gid)
        return ((mode >> 3) & bits) == bits;
    return (mode & bits) == bits;
}

function parent_dir(path) {
    let slash = rindex(path, "/");
    return slash > 0 ? substr(path, 0, slash) : "/";
}

function under(path, root) {
    return root != "" && substr(path, 0, length(root) + 1) == root + "/";
}

function managed_root_of(path) {
    for (let root in MANAGED_ROOTS)
        if (under(path, root))
            return root;
    return null;
}

// Every directory from / down to path's parent is searchable by the user.
// Directories inside a managed root (and the root itself) are given g+x
// for the user's group when they are not; nothing else is changed.
function reach(path, ids, root) {
    let dirs = [];
    for (let dir = parent_dir(path); ; dir = parent_dir(dir)) {
        unshift(dirs, dir);
        if (dir == "/")
            break;
    }
    for (let dir in dirs) {
        let stat = fs.lstat(dir);
        if (stat == null || stat.type != "directory")
            return false;
        if (allowed(dir, stat, ids, 1))
            continue;
        if (root == null || (dir != root && !under(dir, root)))
            return false;
        if (!chown_path(dir, stat.uid, ids.gid) || !fs.chmod(dir, (stat.mode & 07777) | 0010))
            return false;
    }
    return true;
}

// A file the configuration names, readable by the user.
function grant_read(path, ids) {
    let root = managed_root_of(path);
    let stat = fs.lstat(path);
    // A link is followed by sing-box: only a file that is there.
    if (stat == null || stat.type != "file")
        return stat == null;
    if (!reach(path, ids, root))
        return false;
    if (allowed(path, stat, ids, 4))
        return true;
    if (root == null)
        return false;
    return chown_path(path, stat.uid, ids.gid) && fs.chmod(path, (stat.mode & 07777) | 0040);
}

// The user's own file (config.json, the cache file), private to it.
function hand_over_file(path, ids, create) {
    let stat = fs.lstat(path);
    if (stat == null && create) {
        system("mkdir -p " + shell_quote(parent_dir(path)) + " >/dev/null 2>&1");
        if (fs.writefile(path, "") == null)
            return false;
        stat = fs.lstat(path);
    }
    if (stat == null || stat.type != "file")
        return false;
    return reach(path, ids, null) && chown_path(path, ids.uid, ids.gid) && fs.chmod(path, 0600);
}

function hand_over_dir(path, ids) {
    let stat = fs.lstat(path);
    if (stat == null) {
        system("mkdir -p " + shell_quote(path) + " >/dev/null 2>&1");
        stat = fs.lstat(path);
    }
    if (stat == null || stat.type != "directory")
        return false;
    return reach(path, ids, null) && chown_path(path, ids.uid, ids.gid) && fs.chmod(path, 0750);
}

function write_status(status) {
    system("mkdir -p " + shell_quote(RUNTIME_STATE_DIR) + " >/dev/null 2>&1");
    let text = sprintf("%J\n", status);
    if (fs.readfile(STATUS_FILE) !== text) {
        let tmp = STATUS_FILE + "." + as_string(fs.readlink("/proc/self"));
        if (fs.writefile(tmp, text) != null && fs.rename(tmp, STATUS_FILE))
            return;
        fs.unlink(tmp);
    }
}

function set_decision(user) {
    if (user == null) {
        fs.unlink(DECISION_FILE);
        return fs.stat(DECISION_FILE) == null;
    }
    let text = user + "\n";
    if (fs.readfile(DECISION_FILE) === text)
        return true;
    system("mkdir -p " + shell_quote(parent_dir(DECISION_FILE)) + " >/dev/null 2>&1");
    let tmp = DECISION_FILE + "." + as_string(fs.readlink("/proc/self"));
    if (fs.writefile(tmp, text) == null || !fs.rename(tmp, DECISION_FILE)) {
        fs.unlink(tmp);
        return false;
    }
    return true;
}

// sing-box stays on root, and why. Logged when the reason changes.
function stay_root(reason, detail) {
    set_decision(null);
    let previous = common.read_json_file(STATUS_FILE);
    if (type(previous) != "object" || previous.reason != reason)
        log_message("sing-box runs as root although Settings ask for its own user: " + REASONS[reason] +
            (detail ? " (" + detail + ")" : ""), "warn");
    write_status({ requested: true, active: false, reason, user: USER });
    return false;
}

// Decides for the configuration at config_path, which is to be (or was
// just) published. true when sing-box will run as the user.
function prepare(config_path) {
    if (!requested()) {
        set_decision(null);
        write_status({ requested: false, active: false, reason: "", user: USER });
        return false;
    }
    if (!managed_script_installed())
        return stay_root("service_script");
    if (fs.stat(UJAIL) == null)
        return stay_root("no_ujail");
    if (!install_capabilities_file())
        return stay_root("capabilities_file");
    let ids = ensure_user();
    if (ids == null)
        return stay_root("user");

    let config = common.read_json_file(config_path);
    if (type(config) != "object")
        return stay_root("config_file");
    if (config_needs_root(config))
        return stay_root("unsupported_config");
    if (!hand_over_file(config_path, ids, false))
        return stay_root("config_file");
    let cache = config.experimental?.cache_file;
    if (type(cache) == "object" && cache.enabled === true && as_string(cache.path) != "" &&
        !hand_over_file(cache.path, ids, true))
        return stay_root("cache_file");
    let workdir = trim(as_string(uci_core.get("sing-box.main.workdir"))) || "/usr/share/sing-box";
    if (!hand_over_dir(workdir, ids))
        return stay_root("workdir");
    let paths = [];
    named_paths(config, paths, "");
    for (let path in paths)
        if (!grant_read(path, ids))
            return stay_root("path_unreadable", path);

    if (!set_decision(USER))
        return stay_root("config_file");
    let previous = common.read_json_file(STATUS_FILE);
    if (type(previous) != "object" || previous.active !== true)
        log_message("sing-box runs as the user " + USER + " with network capabilities only", "info");
    write_status({ requested: true, active: true, reason: "", user: USER });
    return true;
}

// For the UI: { requested, active, reason } as last decided.
function status() {
    let value = common.read_json_file(STATUS_FILE);
    if (type(value) != "object")
        return { requested: requested(), active: false, reason: "" };
    return { requested: value.requested === true, active: value.active === true, reason: as_string(value.reason) };
}

return { prepare, status, capabilities_text, config_needs_root, REASONS, DECISION_FILE, CAPABILITIES_FILE, USER };
