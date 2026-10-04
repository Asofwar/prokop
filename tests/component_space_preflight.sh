#!/usr/bin/env bash
set -euo pipefail

# Components are refused before anything changes when /tmp, the RAM behind
# it or the overlay cannot hold them (UPD-7, B3). The size of a download comes
# from the release metadata; a package manager or tar that runs out of room
# is reported as such instead of a bare "failed".
#
# The functions are components/action.uc's own, extracted; df, /proc and the
# package manager are stand-ins.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
ACTION_UC="$LIB/components/action.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/tmp"

python3 - "$ACTION_UC" "$WORK_DIR/probe.uc" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding='utf-8').read()
names = ('as_string', 'read_file', 'parse_json_object', 'file_bytes', 'memory_available_kib', 'path_on_tmpfs',
         'component_download_space_error', 'component_install_space_error', 'out_of_space_hint',
         'release_asset_object_size', 'release_json_asset', 'release_url_asset', 'release_url_asset_size',
         'install_byedpi')
parts = []
for name in names:
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    parts.append(match.group())
prefix = r'''
let fs = require("fs");
const WORK = getenv("WORK_DIR");
const LIB_DIR = WORK;
const COMPONENT_MEMORY_RESERVE_KIB = 16384;
let tmp_dir = WORK + "/tmp";
let free_kib = { "/usr": 100000 };
free_kib[tmp_dir] = 100000;
let last_logged_output = "";
let steps = [];
let package_size = 0;
let install_output = "";
function available_kib(path) { return free_kib[path] ?? -1; }
function init_tmp_dir() { return true; }
function action_fail(component, action, message) { die("action_fail: " + message); }
function action_success(component, action, message) { die("action_success: " + message); }
function check_success() { die("check"); }
function resolve_arch_candidates() { return { candidates: "aarch64" }; }
function retry_resolve(description, fn) { return fn(); }
function resolve_byedpi_release(arch) {
    return { arch: "aarch64", package_name: "byedpi.ipk", package_url: "https://example.test/byedpi.ipk",
        package_size, release_url: "", version: "1.0" };
}
function provider_installed(module) { return true; }
function provider_package_version(module) { return "0.9"; }
function pkg_list_update_command() { return "update"; }
function pkg_install_files_command(files) { return "install"; }
function run_logged(description, command) {
    push(steps, command);
    if (command == "install" && install_output != "") {
        last_logged_output = install_output;
        return false;
    }
    return true;
}
function download_byedpi_package(release) {
    push(steps, "download");
    let file = tmp_dir + "/byedpi.ipk";
    fs.writefile(file, "x" * 4096);
    return { name: "byedpi.ipk", file, version: "1.0" };
}
function disable_standalone_service(name) { }
function restart_prokop_after_successful_change() { return true; }
function clear_version_caches() { }
function prokop_not_restarted_text() { return ""; }
'''
open(sys.argv[2], 'w', encoding='utf-8').write(prefix + '\n\n'.join(parts) + '\n')
PY

cat >"$WORK_DIR/mounts" <<EOF
rootfs / rootfs rw 0 0
overlayfs:/overlay / overlay rw 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev 0 0
/dev/sda1 /mnt/data ext4 rw 0 0
EOF
cat >"$WORK_DIR/meminfo" <<EOF
MemTotal:         245000 kB
MemFree:           30000 kB
MemAvailable:      60000 kB
EOF
cat >"$WORK_DIR/meminfo-old" <<EOF
MemTotal:         245000 kB
MemFree:           30000 kB
EOF

cat >>"$WORK_DIR/probe.uc" <<'UC'
function check(ok, message) {
    if (!ok) {
        warn("FAIL: " + message + "\n");
        exit(1);
    }
}
function attempt(fn) {
    try {
        fn();
    }
    catch (e) {
        return as_string(e.message);
    }
    return "";
}

// Memory and mounts.
check(memory_available_kib() == 60000, "MemAvailable was not read");
check(path_on_tmpfs("/tmp/prokop-updates.1"), "/tmp is a tmpfs");
check(!path_on_tmpfs("/mnt/data/prokop"), "an ext4 mount is not a tmpfs");
check(!path_on_tmpfs("/tmpx/a"), "a sibling of /tmp is not inside it");

// Download preflight: /tmp space first, then the RAM behind a tmpfs.
const MIB = 1024 * 1024;
free_kib["/tmp/d"] = 100000;
free_kib["/mnt/data/d"] = 100000;
check(component_download_space_error("x", 0, 3, "/tmp/d") == "", "an unknown size must refuse nothing");
check(component_download_space_error("x", 10 * MIB, 2, "/tmp/d") == "", "a download that fits was refused");
let error = component_download_space_error("sing-box-extended", 40 * MIB, 3, "/tmp/d");
check(index(error, "Not enough free space in /tmp to download sing-box-extended: 100000 KiB available where 123904 KiB is needed") == 0,
    "a download larger than /tmp was not refused: " + error);
error = component_download_space_error("zapret", 15 * MIB, 3, "/tmp/d");
check(index(error, "Not enough free memory to download zapret: 60000 KiB available where 63488 KiB is needed") == 0,
    "a download that leaves the router short of RAM was not refused: " + error);
check(component_download_space_error("zapret", 15 * MIB, 3, "/mnt/data/d") == "",
    "a download to disk must not be held to the RAM limit");

// Overlay preflight.
free_kib["/usr"] = 30000;
check(component_install_space_error("ByeDPI", 20 * MIB) == "", "an install that fits was refused");
error = component_install_space_error("sing-box-extended compressed", 40 * MIB);
check(error == "Not enough free space on the router's storage to install sing-box-extended compressed: 30000 KiB available where 43008 KiB is needed",
    "an install larger than the overlay was not refused: " + error);
free_kib["/usr"] = -1;
check(component_install_space_error("x", 400 * MIB) == "", "an unreadable df must refuse nothing");

// Sizes from release metadata.
const URL = "https://github.com/o/r/releases/download/v1/a.ipk";
let releases = sprintf("%J", [ { assets: [ { browser_download_url: "https://example.test/b", size: 5 } ] },
    { assets: [ { browser_download_url: URL, size: 123456 } ] } ]);
check(release_url_asset_size(releases, URL) == 123456, "the asset size was not found in the release list");
check(release_url_asset_size(releases, "https://example.test/none") == 0, "a size was invented for an unknown asset");
check(release_url_asset_size(sprintf("%J", { assets: [ { browser_download_url: URL, size: "9" } ] }), URL) == 0,
    "a size that is not a number must be ignored");
check(release_asset_object_size(release_json_asset(sprintf("%J", { assets: [ { browser_download_url: URL, size: 7 } ] }),
    "browser_download_url", URL)) == 7, "the size was not found in a single release document");

// Package manager and tar output.
check(out_of_space_hint("Collected errors:\n * verify_pkg_installable: Only have 1200kb available on filesystem /overlay, pkg byedpi needs 2000") != "",
    "opkg's out-of-space message was not recognised");
check(out_of_space_hint("ERROR: byedpi-1.0: No space left on device") != "", "apk's ENOSPC was not recognised");
check(out_of_space_hint("tar: write error: No space left on device") == ": the router ran out of storage space",
    "tar's ENOSPC was not recognised");
check(out_of_space_hint("unknown package byedpi") == "", "an unrelated failure was blamed on space");

// End to end through install_byedpi: nothing is downloaded or installed
// when there is no room for it.
free_kib["/usr"] = 100000;
free_kib[tmp_dir] = 1000;
package_size = 4 * MIB;
steps = [];
error = attempt(() => install_byedpi("install"));
check(index(error, "action_fail: Not enough free space in /tmp to download ByeDPI") == 0, "ByeDPI download was not refused: " + error);
check(index(steps, "download") < 0 && index(steps, "install") < 0, "ByeDPI was downloaded with no room in /tmp");

free_kib[tmp_dir] = 100000;
free_kib["/usr"] = 2000;
steps = [];
error = attempt(() => install_byedpi("install"));
check(index(error, "action_fail: Not enough free space on the router's storage to install ByeDPI") == 0,
    "ByeDPI install was not refused: " + error);
check(index(steps, "download") >= 0 && index(steps, "install") < 0, "ByeDPI was installed with no room on the overlay");

free_kib["/usr"] = 100000;
install_output = "ERROR: No space left on device";
steps = [];
error = attempt(() => install_byedpi("install"));
check(error == "action_fail: Failed to install ByeDPI package: the router ran out of storage space",
    "the package manager's ENOSPC was not named: " + error);

install_output = "";
error = attempt(() => install_byedpi("install"));
check(index(error, "action_success:") == 0, "ByeDPI with room for it was refused: " + error);
UC

export WORK_DIR
PROKOP_MEMINFO_PATH="$WORK_DIR/meminfo" PROKOP_MOUNTS_PATH="$WORK_DIR/mounts" \
  ucode -L "$LIB" "$WORK_DIR/probe.uc" || fail "the space preflight probe failed"

{
  printf 'let fs = require("fs");\n'
  sed -n '/^function as_string(/,/^}/p; /^function read_file(/,/^}/p; /^function memory_available_kib(/,/^}/p' "$ACTION_UC"
  printf 'print(memory_available_kib(), "\\n");\n'
} >"$WORK_DIR/memfree.uc"
[[ "$(PROKOP_MEMINFO_PATH="$WORK_DIR/meminfo-old" ucode "$WORK_DIR/memfree.uc")" == "30000" ]] ||
  fail "a kernel without MemAvailable must fall back to MemFree"

printf 'component space preflight checks passed\n'
