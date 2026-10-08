let fs = require("fs");
let c = require("experiments.common");
let uci = require("core.uci");
let providers = require("experiments.sidecar_config");
const LIB = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const INIT = getenv("PROKOP_SIDECAR_INIT") || "/etc/init.d/prokop-sidecars";
const DIR = providers.DIR;
const FILE = DIR + "/manifest.json";
function plan() { return providers.plan(uci.section_objects("prokop", "sidecar")); }
function public_plan(data) {
    if (!data.success) return data;
    return { success: true, providers: map(data.providers, (p) => ({ name: p.name, kind: p.kind, port: p.port, url: p.url, installed: fs.stat(p.binary) != null })) };
}
function status() {
    let state = c.capture([ "ubus", "call", "service", "list", '{"name":"prokop-sidecars"}' ]);
    let services;
    try { services = json(state.output); } catch (e) { services = {}; }
    let result = public_plan(plan());
    for (let provider in result.providers || [])
        provider.running = services["prokop-sidecars"]?.instances?.[provider.name]?.running === true;
    return result;
}
function ports_available(desired) {
    if (!length(desired.providers)) return true;
    let listeners = c.capture([ "ss", "-H", "-lnt" ]);
    if (listeners.code != 0) return false;
    let previous = c.read(FILE, {}).providers || [];
    let service;
    try { service = json(c.capture([ "ubus", "call", "service", "list", '{"name":"prokop-sidecars"}' ]).output); } catch (e) { service = {}; }
    let identity = require("core.process_identity");
    for (let p in desired.providers) {
        let occupied = false;
        for (let line in split(listeners.output, "\n"))
            if (match(line, regexp(":" + p.port + "[ \t]")) != null) occupied = true;
        if (!occupied) continue;
        let owned = false;
        for (let old in previous) {
            let instance = service["prokop-sidecars"]?.instances?.[old.name];
            if (old.port != p.port || !instance?.running) continue;
            let pid = c.value(instance.pid);
            if (identity.matches_record({ pid, ticks: identity.start_ticks(pid) }, old.binary, old.args, true, true) != "") owned = true;
        }
        if (!owned) return false;
    }
    return true;
}
function ensure_user() {
    let desired = plan();
    if (!desired.success || !length(desired.providers)) return public_plan(desired);
    if (providers.uid() == "") {
        let code = system(". /lib/functions.sh; provider_gid=$(group_add_next prokop-sidecar); user_add prokop-sidecar '' \"$provider_gid\" 'Prokop local providers' /var/empty /bin/false >/dev/null 2>&1");
        if (code != 0 || providers.uid() == "") return c.fail("provider_user_unavailable");
    }
    return { success: true };
}
function prepare() {
    let desired = plan();
    if (!desired.success) return desired;
    if (!length(desired.providers) && fs.stat(FILE) == null) return public_plan(desired);
    for (let p in desired.providers) {
        if (fs.stat(p.binary) == null) return c.fail("provider_binary_missing_" + p.kind);
    }
    if (!ports_available(desired)) return c.fail("provider_port_already_in_use");
    // Unlike private data directories, the active parent must stay traversable
    // throughout preparation, including every failure path.
    let parent = fs.lstat(DIR);
    if ((parent != null && parent.type != "directory") ||
        (parent == null && !fs.mkdir(DIR, 0711)) || !fs.chmod(DIR, 0711))
        return c.fail("provider_storage_unavailable");
    // Native binaries run as a dedicated unprivileged user. Its sockets
    // bypass Prokop output capture; neither global provider service is stopped.
    let user = ensure_user();
    if (!user.success) return user;
    let staged = [], previous = {};
    for (let p in desired.providers) {
        if (!c.directory(p.data) || !c.write(p.path + ".candidate", p.config, false)) return c.fail("provider_config_write_failed");
        if (p.kind == "xray" && c.capture([ p.binary, "run", "-test", "-config", p.path + ".candidate" ]).code != 0) {
            for (let path in staged) fs.unlink(path + ".candidate");
            fs.unlink(p.path + ".candidate");
            return c.fail("xray_config_check_failed");
        }
        if (c.capture([ "chown", "prokop-sidecar", p.path + ".candidate", p.data ]).code != 0) return c.fail("provider_permissions_failed");
        previous[p.path] = fs.readfile(p.path);
        push(staged, p.path);
        delete p.config;
    }
    for (let path in staged)
        if (!fs.rename(path + ".candidate", path)) {
            for (let restore in staged) {
                if (previous[restore] == null) fs.unlink(restore);
                else {
                    require("core.durable").checked_replace(restore + ".rollback", restore, previous[restore], 0600);
                    c.capture([ "chown", "prokop-sidecar", restore ]);
                }
                fs.unlink(restore + ".candidate");
            }
            return c.fail("provider_config_replace_failed");
        }
    // The parent is traversable; every secret config and data directory is private.
    if (!c.write(FILE, desired, false)) return c.fail("provider_manifest_write_failed");
    return public_plan(desired);
}
let mode = c.value(ARGV[0]);
if (mode == "status") c.reply(status());
if (mode == "fixture") c.reply(providers.plan(c.read(ARGV[1], [])));
if (mode == "prepare") c.reply(prepare());
if (mode == "ensure-user") c.reply(ensure_user());
if (mode == "names") { for (let p in c.read(FILE, {}).providers || []) print(p.name, "\n"); exit(0); }
if (mode == "kind") { for (let p in c.read(FILE, {}).providers || []) if (p.name == ARGV[1]) { print(p.kind, "\n"); exit(0); } exit(1); }
if (mode == "start-runtime") {
    let desired = plan();
    if (!desired.success) c.reply(desired);
    if (!length(desired.providers)) exit(0);
    c.reply(c.capture([ INIT, "start" ]).code == 0 ? { success: true } : c.fail("provider_start_failed"));
}
if (mode == "stop-runtime") { c.reply(c.capture([ INIT, "stop" ]).code == 0 ? { success: true } : c.fail("provider_stop_failed")); }
if (mode == "apply") {
    let result = prepare();
    if (!result.success) c.reply(result);
    // Reload capture after the dedicated uid exists, before launching clients.
    let reloaded = c.capture([ getenv("PROKOP_BIN") || "/usr/bin/prokop", "reload" ]);
    if (reloaded.code != 0) c.reply(c.fail("provider_capture_reload_failed"));
    c.reply(c.capture([ INIT, "restart" ]).code == 0 ? status() : c.fail("provider_start_failed"));
}
c.reply(c.fail("invalid_action"));
