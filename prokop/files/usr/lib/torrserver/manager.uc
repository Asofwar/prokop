#!/usr/bin/ucode

// TorrServer installed and kept up to date by Prokop: the official build of
// YouROK/TorrServer for the router's CPU, in one fixed directory, run by
// /etc/init.d/prokop-torrserver. components/action.uc installs, updates and
// removes it; this module answers what is installed and whether it runs,
// and holds the pure helpers the tests check (asset choice, versions).
//
// Prokop owns the binary only while its marker file names it: a TorrServer
// someone installed by other means is never overwritten, stopped or removed.

let fs = require("fs");
let procs = require("torrserver.procs");

const DIR = getenv("PROKOP_TORRSERVER_DIR") || "/opt/torrserver";
const BIN = DIR + "/torrserver";
const MARKER = DIR + "/prokop-managed.json";
// TorrServer's own directory (its database), the only one its unprivileged
// user may write (/etc/init.d/prokop-torrserver, TS-1).
const DATA_DIR = DIR + "/data";
// Written when the recommended settings were applied: on the first install
// of a TorrServer that had no database yet, or by the card's button. Prokop
// never applies them on its own after that (TS-8).
const SETTINGS_STAMP = DIR + "/prokop-settings-applied";
const INIT = getenv("PROKOP_TORRSERVER_INIT") || "/etc/init.d/prokop-torrserver";
const PORT = "8090";
// TorrServer's own HTTP API on the router (tests point it at a stand-in).
const API_URL = getenv("PROKOP_TORRSERVER_API_URL") || "http://127.0.0.1:" + PORT;
const ECHO_URL = API_URL + "/echo";
const MEMINFO_PATH = getenv("PROKOP_MEMINFO_PATH") || "/proc/meminfo";
// Where processes are read (tests point it at a fake tree).
const PROC_DIR = procs.PROC_DIR;
const RELEASE_OWNER = "YouROK";
const RELEASE_REPO = "TorrServer";

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
function parse_object(value) {
    try {
        let parsed = json(text(value));
        return type(parsed) == "object" ? parsed : null;
    }
    catch (e) {
        return null;
    }
}

// A release tag as TorrServer names them (MatriX.145.2) or a plain version.
function valid_version(value) {
    return match(text(value), /^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/) != null;
}

// The numeric part of a tag (MatriX.145.2 -> 145.2), for comparing versions
// with the package managers' rules; empty when it has none.
function version_key(value) {
    let m = match(text(value), /^[^0-9]*([0-9]+(\.[0-9]+)*)$/);
    return m != null ? m[1] : "";
}

function marker() {
    let value = parse_object(read(MARKER));
    if (value == null || !valid_version(value.version) ||
        match(text(value.sha256), /^[a-f0-9]{64}$/) == null)
        return null;
    return value;
}

function file_sha256(path) {
    return lc(split(trim(command_output([ "sha256sum", path ])), /[ \t]+/)[0] || "");
}

// The binary is Prokop's: the marker names it and its size, and for a change
// (`verify`) its checksum, still match. Status, read on every page load,
// does not hash tens of megabytes.
function managed(verify) {
    let value = marker();
    let stat = fs.stat(BIN);
    if (value == null || stat == null || stat.type != "file" || stat.size != int(value.size || -1))
        return false;
    return !verify || file_sha256(BIN) == value.sha256;
}

function process_exe(pid) {
    return replace(text(fs.readlink(PROC_DIR + "/" + pid + "/exe")), / \(deleted\)$/, "");
}

// Every TorrServer process: the one run from BIN, and any other; `named`
// lists every process named TorrServer, as TorrServer Direct looks for it.
function processes() {
    let own = [];
    let other = [];
    let named = [];
    procs.each_process(function(pid, cmdline) {
        let is_named = procs.is_torrserver_cmdline(cmdline);
        if (is_named)
            push(named, pid);
        if (process_exe(pid) == BIN)
            push(own, pid);
        else if (is_named)
            push(other, pid);
    });
    return { own, other, named };
}

// Settings that suit a router: the RAM cache sized to the router's memory
// (an eighth of it to the nearest 16 MiB, 32 to 256 MiB), reading ahead and
// preloading like TorrServer's own recommendations for weak devices, and
// the default connection count. UPnP is off: TorrServer runs on the router
// itself, and must not open the router's WAN to peers through miniupnpd
// (TS-1). What is not listed stays as the user set it.
function recommended_settings() {
    let total_kib = 0;
    for (let line in split(read(MEMINFO_PATH), "\n")) {
        let m = match(line, /^MemTotal:[ \t]+([0-9]+)/);
        if (m != null) total_kib = int(m[1]);
    }
    let cache_mib = total_kib > 0 ? int(total_kib / 1024.0 / 8 / 16 + 0.5) * 16 : 64;
    if (cache_mib < 32) cache_mib = 32;
    if (cache_mib > 256) cache_mib = 256;
    return {
        CacheSize: cache_mib * 1024 * 1024,
        ReaderReadAHead: 95,
        PreloadCache: 50,
        ConnectionsLimit: 25,
        TorrentDisconnectTimeout: 30,
        ResponsiveMode: true,
        DisableUPNP: true
    };
}

// The inodes of the sockets listening on TorrServer's port, from the
// kernel's tables (hex port, state 0A = LISTEN).
function listener_inodes() {
    let port = sprintf(":%04X", int(PORT));
    let inodes = {};
    for (let table in [ "tcp", "tcp6" ]) {
        for (let line in split(read(PROC_DIR + "/net/" + table), "\n")) {
            let fields = split(trim(line), /[ \t]+/);
            if (length(fields) < 10 || fields[3] != "0A")
                continue;
            let local = fields[1];
            if (substr(local, length(local) - length(port)) == port && match(fields[9], /^[1-9][0-9]*$/) != null)
                inodes[fields[9]] = true;
        }
    }
    return inodes;
}

// Whether TorrServer's port is held by one of `pids` (TorrServer of BIN):
// the answer on 127.0.0.1:8090 is then this TorrServer's, not another one's
// that took the port first (TS-10).
function port_owned_by(pids) {
    let inodes = listener_inodes();
    if (length(keys(inodes)) == 0)
        return false;
    for (let pid in pids) {
        for (let fd in fs.glob(PROC_DIR + "/" + pid + "/fd/*")) {
            let m = match(text(fs.readlink(fd)), /^socket:\[([0-9]+)\]$/);
            if (m != null && inodes[m[1]])
                return true;
        }
    }
    return false;
}

function status(found) {
    let value = marker();
    let is_managed = managed(false);
    found = found || processes();
    let binary_present = fs.stat(BIN) != null;
    return {
        installed: is_managed ? 1 : 0,
        version: is_managed ? value.version : "",
        running: is_managed && length(found.own) > 0 ? 1 : 0,
        pid: is_managed && length(found.own) > 0 ? found.own[0] : "",
        // A TorrServer Prokop does not own: one run from elsewhere, or a
        // binary at Prokop's path without (or not matching) its marker.
        foreign: length(found.other) > 0 || (binary_present && !is_managed) ? 1 : 0,
        port: PORT,
        dir: DIR,
        // For the card's confirmation of the recommended settings.
        recommended_cache_mib: int(recommended_settings().CacheSize / 1048576)
    };
}

// The release asset for the router's CPU, by OpenWrt's DISTRIB_ARCH
// (aarch64_cortex-a53, mipsel_24kc) and then `uname -m`; empty when
// TorrServer publishes no build for it.
function asset_arch(distrib_arch, machine) {
    distrib_arch = lc(text(distrib_arch));
    machine = lc(text(machine));
    let family = distrib_arch != "" ? split(distrib_arch, "_")[0] : machine;
    if (family == "aarch64" || family == "arm64") return "arm64";
    if (family == "x86" || family == "x86_64" || family == "amd64") return "amd64";
    if (match(family, /^i[3-6]86$/) != null) return "386";
    if (family == "mipsel") return "mipsle";
    if (family == "mips") return "mips";
    if (family == "mips64el") return "mips64le";
    if (family == "mips64") return "mips64";
    if (family == "riscv64") return "riscv64";
    if (family == "arm" || match(family, /^armv/) != null) {
        // DISTRIB_ARCH names the core: Cortex-A (ARMv7 and later) runs the
        // arm7 build, older cores (arm926, xscale, fa526, mpcore) arm5.
        if (match(distrib_arch, /_cortex-a/) != null) return "arm7";
        if (distrib_arch == "" && match(machine, /^armv([7-9]|[1-9][0-9])/) != null) return "arm7";
        return "arm5";
    }
    return "";
}

// The latest release's asset for `arch` from the GitHub release document on
// stdin, as a tab-separated row: tag, asset name, download URL, sha256,
// size, release page. A release whose asset has no published digest is not
// offered: an unverified binary never runs as root.
function select_asset(release_json, arch) {
    let release = parse_object(release_json);
    if (release == null || release.draft || release.prerelease || !valid_version(release.tag_name))
        return null;
    let name = "TorrServer-linux-" + text(arch);
    for (let asset in (type(release.assets) == "array" ? release.assets : [])) {
        if (type(asset) != "object" || text(asset.name) != name)
            continue;
        let url = text(asset.browser_download_url);
        let prefix = "https://github.com/" + RELEASE_OWNER + "/" + RELEASE_REPO + "/releases/download/";
        if (substr(url, 0, length(prefix)) != prefix)
            return null;
        let digest = lc(text(asset.digest));
        if (substr(digest, 0, 7) != "sha256:" || match(substr(digest, 7), /^[a-f0-9]{64}$/) == null)
            return null;
        let size = type(asset.size) == "int" && asset.size > 0 ? asset.size : 0;
        if (size == 0)
            return null;
        return {
            version: text(release.tag_name),
            name,
            url,
            sha256: substr(digest, 7),
            size,
            release_url: text(release.html_url)
        };
    }
    return null;
}

// The version a binary reports (`TorrServer MatriX.145.2`); empty when it
// does not run or says something else.
function binary_version(path) {
    let m = match(trim(command_output([ path, "--version" ])), /^TorrServer ([A-Za-z0-9._+-]+)$/);
    return m != null ? m[1] : "";
}

// The marker of the binary at `path` (BIN, or the staged binary about to
// become BIN), whose `sha256` the caller has just checked: the binary is
// not hashed a second time.
function write_marker(version, sha256, path) {
    let stat = fs.stat(path || BIN);
    if (!valid_version(version) || match(text(sha256), /^[a-f0-9]{64}$/) == null ||
        stat == null || stat.type != "file")
        return false;
    let staged = MARKER + ".tmp";
    let value = { version, sha256, size: stat.size, source: RELEASE_OWNER + "/" + RELEASE_REPO };
    if (fs.writefile(staged, sprintf("%J\n", value)) == null)
        return false;
    if (!fs.rename(staged, MARKER)) {
        fs.unlink(staged);
        return false;
    }
    return true;
}

function http_body(url) {
    if (success([ "sh", "-c", "command -v curl" ]))
        return command_output([ "curl", "-fsS", "--connect-timeout", "2", "-m", "3", url ]);
    return command_output([ "wget", "-q", "-T", "3", "-O", "-", url ]);
}

// POSTs `body` (JSON) to TorrServer's API; the answer, or null on failure.
function http_post(url, body) {
    let path = trim(command_output([ "mktemp" ]));
    if (path == "" || fs.writefile(path, body) == null)
        return null;
    let curl = success([ "sh", "-c", "command -v curl" ]);
    let pipe = fs.popen(command(curl ?
        [ "curl", "-fsS", "--connect-timeout", "2", "-m", "10", "--data-binary", "@" + path, url ] :
        [ "wget", "-q", "-T", "10", "-O", "-", "--post-file=" + path, url ]) + " 2>/dev/null", "r");
    let data = pipe ? pipe.read("all") : null;
    let status = pipe ? pipe.close() : 1;
    fs.unlink(path);
    return status == 0 ? text(data) : null;
}

// Reads TorrServer's settings, puts the recommended values over them and
// writes them back whole (its "set" replaces every setting); prints what
// was set. The settings are read back to prove it. TorrServer's "set" drops
// every torrent and reconnects: when the values are already there, nothing
// is written and no playback is cut.
function apply_recommended() {
    let current = parse_object(http_post(API_URL + "/settings", "{\"action\":\"get\"}"));
    if (current == null)
        return null;
    let wanted = recommended_settings();
    let differs = false;
    for (let key, value in wanted) {
        if (current[key] != value)
            differs = true;
        current[key] = value;
    }
    if (!differs)
        return wanted;
    if (http_post(API_URL + "/settings", sprintf("%J", { action: "set", sets: current })) == null)
        return null;
    let check = parse_object(http_post(API_URL + "/settings", "{\"action\":\"get\"}"));
    if (check == null)
        return null;
    for (let key, value in wanted)
        if (check[key] != value)
            return null;
    return wanted;
}

// Waits up to `seconds` for the TorrServer of BIN to run, hold its port and
// answer on it with `version` (its /echo answers the version it runs).
function wait_running(seconds, version) {
    for (let i = 0; i < seconds; i++) {
        let own = processes().own;
        if (length(own) > 0 && trim(http_body(ECHO_URL)) == text(version) && port_owned_by(own))
            return true;
        system("sleep 1");
    }
    return false;
}

// The recommended settings for the TorrServer Prokop installed, once it runs
// and holds its port (after waiting up to `seconds`), and stamped. Only on
// request: the first install of a TorrServer without a database, or the
// card's button. Never into a TorrServer Prokop does not own (TS-10).
// "applied", or null on failure.
function apply_recommended_now(seconds) {
    if (!managed(false) || status().foreign)
        return null;
    let version = text((marker() || {}).version);
    if (!wait_running(seconds > 0 ? seconds : 1, version))
        return null;
    if (apply_recommended() == null)
        return null;
    if (fs.writefile(SETTINGS_STAMP, version + "\n") == null)
        return null;
    return "applied";
}

let mode = ARGV[0] || "status";
if (mode == "status")
    print(sprintf("%J\n", status()));
else if (mode == "card-status") {
    // The card's TorrServer and TorrServer Direct, from one pass over /proc
    // (diagnostics/runtime.uc, on every page load: TS-4).
    let found = processes();
    let value = status(found);
    value.direct = procs.status_of(procs.discover_from(found.named));
    print(sprintf("%J\n", value));
}
else if (mode == "managed")
    exit(managed(true) ? 0 : 1);
else if (mode == "managed-quick")
    exit(managed(false) ? 0 : 1);
else if (mode == "asset-arch") {
    let arch = asset_arch(ARGV[1], ARGV[2]);
    if (arch == "") exit(1);
    print(arch, "\n");
}
else if (mode == "select-asset") {
    // select-asset <arch>, the release document on stdin.
    let asset = select_asset(read("/dev/stdin"), ARGV[1]);
    if (asset == null) exit(1);
    print(sprintf("%J\n", asset));
}
else if (mode == "version-key")
    print(version_key(ARGV[1]), "\n");
else if (mode == "binary-version") {
    let version = binary_version(ARGV[1] || BIN);
    if (version == "") exit(1);
    print(version, "\n");
}
else if (mode == "recommended-settings")
    print(sprintf("%J\n", recommended_settings()));
else if (mode == "apply-recommended") {
    let applied = apply_recommended();
    if (applied == null) exit(1);
    print(sprintf("%J\n", applied));
}
else if (mode == "apply-recommended-now") {
    // apply-recommended-now [seconds to wait for TorrServer to run]
    if (apply_recommended_now(int(ARGV[1] || "1")) == null) exit(1);
    print("applied\n");
}
else if (mode == "write-marker")
    // write-marker <version> <sha256> [binary, BIN by default]
    exit(write_marker(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "wait-running")
    exit(wait_running(int(ARGV[1] || "20"), ARGV[2]) ? 0 : 1);
else if (mode == "paths")
    print(sprintf("%J\n", { dir: DIR, data_dir: DATA_DIR, bin: BIN, marker: MARKER, init: INIT, settings_stamp: SETTINGS_STAMP }));
else
    exit(1);
