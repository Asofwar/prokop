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

const DIR = getenv("PROKOP_TORRSERVER_DIR") || "/opt/torrserver";
const BIN = DIR + "/torrserver";
const MARKER = DIR + "/prokop-managed.json";
// Written once the recommended settings were applied: Prokop applies them
// once per TorrServer, and settings changed after that stay.
const SETTINGS_STAMP = DIR + "/prokop-settings-applied";
const INIT = getenv("PROKOP_TORRSERVER_INIT") || "/etc/init.d/prokop-torrserver";
const PORT = "8090";
// TorrServer's own HTTP API on the router (tests point it at a stand-in).
const API_URL = getenv("PROKOP_TORRSERVER_API_URL") || "http://127.0.0.1:" + PORT;
const ECHO_URL = API_URL + "/echo";
const MEMINFO_PATH = getenv("PROKOP_MEMINFO_PATH") || "/proc/meminfo";
// Where processes are read (tests point it at a fake tree).
const PROC_DIR = getenv("PROKOP_PROC_DIR") || "/proc";
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

function is_torrserver_cmdline(value) {
    value = lc(replace(text(value), /\x00/g, " "));
    return match(value, /(^|[/ ])torrserver([^/ ]*)?( |$)/) != null;
}

function process_exe(pid) {
    return replace(text(fs.readlink(PROC_DIR + "/" + pid + "/exe")), / \(deleted\)$/, "");
}

// Every TorrServer process: the one run from BIN, and any other.
function processes() {
    let own = [];
    let other = [];
    for (let cmdline_path in fs.glob(PROC_DIR + "/[0-9]*/cmdline")) {
        let m = match(cmdline_path, /\/([0-9]+)\/cmdline$/);
        if (m == null) continue;
        let pid = m[1];
        let cmdline = read(cmdline_path);
        let exe = process_exe(pid);
        if (exe == BIN)
            push(own, pid);
        else if (is_torrserver_cmdline(cmdline))
            push(other, pid);
    }
    return { own, other };
}

function status() {
    let value = marker();
    let is_managed = managed(false);
    let found = processes();
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
        dir: DIR
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

// The marker of the binary now at BIN, which must hash to `sha256`.
function write_marker(version, sha256) {
    let stat = fs.stat(BIN);
    if (!valid_version(version) || match(text(sha256), /^[a-f0-9]{64}$/) == null ||
        stat == null || stat.type != "file" || file_sha256(BIN) != sha256)
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

// Settings that suit a router: the RAM cache sized to the router's memory
// (an eighth of it to the nearest 16 MiB, 32 to 256 MiB), reading ahead and
// preloading like TorrServer's own recommendations for weak devices, and
// the default connection count. What is not listed stays as the user set it.
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
        ResponsiveMode: true
    };
}

// Reads TorrServer's settings, puts the recommended values over them and
// writes them back whole (its "set" replaces every setting); prints what
// was set. The settings are read back to prove it.
function apply_recommended() {
    let current = parse_object(http_post(API_URL + "/settings", "{\"action\":\"get\"}"));
    if (current == null)
        return null;
    let wanted = recommended_settings();
    for (let key, value in wanted)
        current[key] = value;
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

// Waits up to `seconds` for the TorrServer of BIN to run and answer on its
// port with `version` (its /echo answers the version it runs).
function wait_running(seconds, version) {
    for (let i = 0; i < seconds; i++) {
        if (length(processes().own) > 0 && trim(http_body(ECHO_URL)) == text(version))
            return true;
        system("sleep 1");
    }
    return false;
}

// The recommended settings, once: nothing when the stamp says they were
// applied, otherwise (after waiting up to `seconds` for the TorrServer
// Prokop installed to run) applied and stamped. "applied", "already", or
// null on failure.
function apply_recommended_once(seconds, force) {
    if (!force && fs.stat(SETTINGS_STAMP) != null)
        return "already";
    if (!managed(false))
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
else if (mode == "apply-recommended-once") {
    // apply-recommended-once [seconds to wait for TorrServer to run]
    let result = apply_recommended_once(int(ARGV[1] || "0"), false);
    if (result == null) exit(1);
    print(result, "\n");
}
else if (mode == "apply-recommended-now") {
    // The settings again, stamp or not (the card's button).
    if (apply_recommended_once(1, true) == null) exit(1);
    print("applied\n");
}
else if (mode == "write-marker")
    exit(write_marker(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "wait-running")
    exit(wait_running(int(ARGV[1] || "20"), ARGV[2]) ? 0 : 1);
else if (mode == "paths")
    print(sprintf("%J\n", { dir: DIR, bin: BIN, marker: MARKER, init: INIT, settings_stamp: SETTINGS_STAMP }));
else
    exit(1);
