// Separate ephemeral Tailscale instance. Keys never enter UCI or argv.
let fs = require("fs");
let c = require("experiments.common");
let identity = require("core.process_identity");
const LIB = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const DIR = getenv("PROKOP_SUPPORT_DIR") || "/var/run/prokop-support";
const DAEMON = getenv("PROKOP_TAILSCALED") || "/usr/sbin/tailscaled";
const CLIENT = getenv("PROKOP_TAILSCALE") || "/usr/bin/tailscale";
const SCRIPT = LIB + "/experiments/support.uc";
const SOCKET = DIR + "/tailscaled.sock";
const AUTH = DIR + "/authkey";
const ARGS = [ DAEMON, "--state=mem:", "--tun=userspace-networking", "--socket=" + SOCKET, "--port=0" ];
function client(args) { return c.capture([ CLIENT, "--socket=" + SOCKET, ...args ]); }
function status() {
    let saved = c.read(DIR + "/session.json", {});
    let active = identity.matches(DIR + "/daemon.pid", DAEMON, ARGS, true, true) != "";
    let remaining = max(0, int(saved.expires_uptime || 0) - c.uptime());
    let data;
    try { data = json(client([ "status", "--json" ]).output); } catch (e) { data = {}; }
    return { success: true, active: active && remaining > 0, remaining_seconds: remaining,
        address: active ? data.Self?.TailscaleIPs || [] : [], state: data.BackendState || "Stopped", port: saved.port || null };
}
function network_bypass(enable) {
    const table = require("core.constants").NFT_TABLE_NAME || "ProkopTable";
    let result = c.capture([ "nft", "-j", "list", "chain", "inet", table, "mangle_output" ]), rules;
    // Prokop stopped: there is no output capture to bypass.
    if (result.code != 0) return true;
    try { rules = json(result.output); } catch (e) { return false; }
    for (let entry in rules.nftables || [])
        if (entry.rule?.comment == "prokop-temporary-support")
            if (c.capture([ "nft", "delete", "rule", "inet", table, "mangle_output", "handle", entry.rule.handle ]).code != 0) return false;
    return !enable || c.capture([ "nft", "insert", "rule", "inet", table, "mangle_output",
        "meta", "mark", "&", "0x00ff0000", "==", "0x00080000", "return", "comment", '"prokop-temporary-support"' ]).code == 0;
}
function cleanup() {
    // No system tailscaled service or global socket is touched.
    identity.signal(DIR + "/daemon.pid", DAEMON, ARGS, true, "TERM", true);
    for (let i = 0; i < 30 && identity.matches(DIR + "/daemon.pid", DAEMON, ARGS, true, true) != ""; i++) system("sleep 0.1");
    identity.signal(DIR + "/daemon.pid", DAEMON, ARGS, true, "KILL", true);
    network_bypass(false);
    fs.unlink(DIR + "/daemon.pid"); fs.unlink(AUTH); fs.unlink(SOCKET); fs.unlink(DIR + "/session.json");
}
function background(args, record) {
    let pipe = fs.popen(c.command(args) + " >/dev/null 2>&1 & echo $!", "r");
    let pid = pipe ? trim(pipe.read("all")) : "";
    if (pipe) pipe.close();
    return identity.record(record, pid);
}
function prepare() {
    if (!c.directory(DIR)) return c.fail("support_storage_unavailable");
    if (fs.stat(DAEMON) == null || fs.stat(CLIENT) == null) return c.fail("install_tailscale_first");
    if (status().active) return c.fail("support_session_already_active");
    if (fs.lstat(AUTH)?.type == "link") return c.fail("invalid_key_file");
    // The UI writes only inside this private directory and consumes it at start.
    if (!c.write(DIR + "/prepared.json", { uptime: c.uptime() }, false)) return c.fail("support_prepare_failed");
    return { success: true, path: AUTH };
}
function cleanup_daemon_before_start() {
    identity.signal(DIR + "/daemon.pid", DAEMON, ARGS, true, "TERM", true);
    identity.signal(DIR + "/daemon.pid", DAEMON, ARGS, true, "KILL", true);
    fs.unlink(DIR + "/daemon.pid"); fs.unlink(SOCKET);
}
function same_session(expires, token) {
    let saved = c.read(DIR + "/session.json", {});
    return saved.expires_uptime == expires && (token == "" || saved.token == token);
}
function start(port) {
    if (index([ "22", "80", "443" ], port) < 0) return c.fail("invalid_support_port");
    if (!c.directory(DIR)) return c.fail("support_storage_unavailable");
    if (!c.locks.acquire(DIR + "/lock", c.self())) return c.fail("support_busy");
    let result;
    function work() {
        if (status().active) return c.fail("support_session_already_active");
        let prepared = c.read(DIR + "/prepared.json", {});
        if (c.uptime() - int(prepared.uptime || 0) > 120 || fs.lstat(AUTH)?.type != "file") return c.fail("prepare_support_first");
        let key = trim(c.value(fs.readfile(AUTH)));
        if (match(key, /^tskey-auth-[A-Za-z0-9_-]{10,200}$/) == null) { fs.unlink(AUTH); return c.fail("invalid_tailscale_auth_key"); }
        if (!fs.chmod(AUTH, 0600)) return c.fail("key_permissions_failed");
        cleanup_daemon_before_start();
        let expires = c.uptime() + 1800;
        let token = c.self() + "." + identity.start_ticks(c.self());
        if (!c.write(DIR + "/session.json", { expires_uptime: expires, port: int(port), token }, false)) return c.fail("session_write_failed");
        // A second, independent process enforces the deadline even if the
        // setup worker crashes. A process-lifetime token disambiguates starts
        // in the same uptime second; deadlines alone are not identities.
        let expiry_args = [ "ucode", "-L", LIB, SCRIPT, "expire", "" + expires, token ];
        if (!background(expiry_args, DIR + "/expiry.pid")) { cleanup(); return c.fail("expiry_start_failed"); }
        function valid() {
            return same_session(expires, token) && c.uptime() < expires &&
                identity.matches(DIR + "/expiry.pid", "ucode", expiry_args, true, true) != "";
        }
        function cancelled() { cleanup(); return c.fail("support_session_cancelled"); }
        if (!network_bypass(true)) { cleanup(); return c.fail("support_capture_bypass_failed"); }
        if (!valid()) return cancelled();
        if (!background(ARGS, DIR + "/daemon.pid")) { cleanup(); return c.fail("tailscaled_start_failed"); }
        let daemon = identity.read_record(DIR + "/daemon.pid");
        function running() {
            return valid() && identity.matches_record(daemon, DAEMON, ARGS, true, true) != "";
        }
        for (let i = 0; i < 30 && fs.stat(SOCKET) == null && valid(); i++) system("sleep 0.1");
        if (!running() || fs.stat(SOCKET) == null) return cancelled();
        let logged_in = client([ "up", "--auth-key=file:" + AUTH, "--timeout=20s", "--hostname=prokop-support", "--accept-dns=false", "--accept-routes=false", "--reset" ]);
        fs.unlink(AUTH); fs.unlink(DIR + "/prepared.json");
        if (!running()) return cancelled();
        if (logged_in.code != 0) { cleanup(); return c.fail("tailscale_login_failed"); }
        if (client([ "serve", "--bg", "--tcp=" + port, "tcp://127.0.0.1:" + port ]).code != 0) { cleanup(); return c.fail("support_forward_failed"); }
        if (!running()) return cancelled();
        let result = status();
        if (!result.active || !running()) return cancelled();
        return result;
    }
    try { result = work(); } catch (e) { cleanup(); result = c.fail("support_start_failed"); }
    c.locks.release(DIR + "/lock", c.self());
    return result;
}
let mode = c.value(ARGV[0]);
if (mode == "status") c.reply(status());
if (mode == "prepare") c.reply(prepare());
if (mode == "start") c.reply(start(c.value(ARGV[1])));
if (mode == "stop") {
    if (!c.directory(DIR)) c.reply(c.fail("support_storage_unavailable"));
    if (!c.locks.acquire(DIR + "/lock", c.self())) c.reply(c.fail("support_busy"));
    cleanup();
    c.locks.release(DIR + "/lock", c.self());
    c.reply({ success: true, active: false });
}
if (mode == "expire") {
    let expires = int(ARGV[1]), token = c.value(ARGV[2]);
    while (same_session(expires, token)) {
        if (c.uptime() < expires) { system("sleep 2"); continue; }
        if (c.locks.acquire(DIR + "/lock", c.self())) {
            // Read back after acquisition: a completed stop/restart may have
            // replaced the session while this watchdog was contending.
            if (same_session(expires, token)) cleanup();
            c.locks.release(DIR + "/lock", c.self());
            break;
        }
        // Never wait for a hung setup/client/nft call before revoking access.
        // Only signal the captured, exact process identity; shared files and
        // nft rules remain protected by the lock. Start reads back its lease
        // after every blocking operation and cannot publish expired access.
        let daemon = identity.read_record(DIR + "/daemon.pid");
        if (same_session(expires, token)) {
            identity.signal_record(daemon, DAEMON, ARGS, true, "TERM");
            identity.signal_record(daemon, DAEMON, ARGS, true, "KILL");
        }
        system("sleep 0.1");
    }
    exit(0);
}
c.reply(c.fail("invalid_action"));
