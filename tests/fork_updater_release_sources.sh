#!/usr/bin/env bash
# The router updater follows the fork's own release channel: the rollback copy
# of the installed release comes from the static catalog first and GitHub
# second, every published checksum is enforced, and a router running a build
# this channel never published is told how to switch to the fork.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
ACTION_UC="$FORKOP_LIB/components/action.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# The probe reads both from the environment.
export WORK_DIR FORKOP_LIB

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=tests/helpers/source_checks.sh
source "$ROOT_DIR/tests/helpers/source_checks.sh"

BASE_URL="https://asofwar.github.io/forkop"
GITHUB_DOWNLOAD="https://github.com/Asofwar/forkop/releases/download"

mkdir -p "$WORK_DIR/payload" "$WORK_DIR/tmp"
for version in 1.0.29 1.0.30; do
  for package in forkop luci-app-forkop luci-i18n-forkop-ru; do
    printf 'payload %s_%s.ipk\n' "$package" "$version" >"$WORK_DIR/payload/${package}_${version}.ipk"
  done
done
digest() { sha256sum "$WORK_DIR/payload/$1" | cut -d' ' -f1; }

# assets VERSION URL_PREFIX STYLE: STYLE "catalog" writes a plain sha256 like
# the static channel, "github" a GitHub digest, "none" no checksum at all.
assets() {
  local version="$1" prefix="$2" style="$3" out="" name checksum
  for package in forkop luci-app-forkop luci-i18n-forkop-ru; do
    name="${package}_${version}.ipk"
    case "$style" in
      catalog) checksum=",\"sha256\":\"$(digest "$name")\"" ;;
      latest) checksum=",\"sha256\":\"$(digest "$name")\",\"digest\":\"sha256:$(digest "$name")\"" ;;
      github) checksum=",\"digest\":\"sha256:$(digest "$name")\"" ;;
      *) checksum="" ;;
    esac
    [ -n "$out" ] && out="$out,"
    out="$out{\"name\":\"$name\",\"browser_download_url\":\"${prefix}${name}\"$checksum}"
  done
  printf '%s' "$out"
}

cat >"$WORK_DIR/catalog.json" <<JSON
{"format":1,"releases":[
 {"tag_name":"1.0.30","channel":"stable","html_url":"$BASE_URL/releases/1.0.30/",
  "assets":[$(assets 1.0.30 "$BASE_URL/releases/1.0.30/" catalog)]}
]}
JSON
# The same release, rewritten to download from elsewhere: the catalog guard
# must reject it, and the rollback lookup must then ask GitHub instead.
cat >"$WORK_DIR/catalog-foreign.json" <<JSON
{"format":1,"releases":[
 {"tag_name":"1.0.30","channel":"stable","html_url":"$BASE_URL/releases/1.0.30/",
  "assets":[$(assets 1.0.30 "https://evil.test/" catalog)]}
]}
JSON
cat >"$WORK_DIR/github-1.0.29.json" <<JSON
{"tag_name":"1.0.29","html_url":"https://github.com/Asofwar/forkop/releases/tag/1.0.29",
 "assets":[$(assets 1.0.29 "$GITHUB_DOWNLOAD/1.0.29/" github)]}
JSON
cat >"$WORK_DIR/github-1.0.30.json" <<JSON
{"tag_name":"1.0.30","html_url":"https://github.com/Asofwar/forkop/releases/tag/1.0.30",
 "assets":[$(assets 1.0.30 "$GITHUB_DOWNLOAD/1.0.30/" github)]}
JSON
cat >"$WORK_DIR/latest-static.json" <<JSON
{"tag_name":"1.0.30","html_url":"$BASE_URL/releases/1.0.30/",
 "assets":[$(assets 1.0.30 "$BASE_URL/releases/1.0.30/" latest)]}
JSON
cat >"$WORK_DIR/latest-github-nodigest.json" <<JSON
{"tag_name":"1.0.30","html_url":"https://github.com/Asofwar/forkop/releases/tag/1.0.30",
 "assets":[$(assets 1.0.30 "$GITHUB_DOWNLOAD/1.0.30/" none)]}
JSON

python3 - "$ACTION_UC" "$WORK_DIR/probe.uc" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding='utf-8').read()
consts = ('FORKOP_RELEASE_REPO', 'FORKOP_RELEASE_BASE_URL')
names = ('as_string', 'shell_quote', 'command_from_args', 'command_status',
         'command_success', 'command_success_from_args', 'command_output',
         'command_output_from_args', 'write_file', 'read_file', 'parse_json_object',
         'remove_file', 'ensure_dir', 'file_exists', 'file_nonempty', 'path_basename',
         'module_command', 'module_output', 'helper_output', 'make_tmp_file',
         'helper_output_input', 'helper_success_input',
         'release_asset_object_sha256', 'release_asset_sha256', 'release_json_asset_sha256', 'download_checksum_ok',
         'forkop_release_url', 'parse_forkop_release_catalog', 'forkop_release_catalog',
         'selected_forkop_release', 'forkop_release_page_url', 'resolve_forkop_release_json',
         'forkop_release_matches', 'previous_forkop_release',
         'forkop_channel_installer_command', 'unpublished_forkop_release_error',
         'opkg_forkop_set_versions_match', 'pkg_set_extension', 'forkop_recovery_files',
         'pkg_forkop_set_command',
         'file_sha256', 'prepare_forkop_package_set', 'verify_latest_release_downloads')
parts = []
for name in consts:
    match = re.search(r'^const ' + name + r' = [^\n]*;$', source, re.M)
    if match is None:
        raise SystemExit('missing production constant: ' + name)
    parts.append(match.group())
for name in names:
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    parts.append(match.group())

prefix = r'''
let fs = require("fs");
let constants = require("core.constants");
let durable = require("core.durable");
const WORK = getenv("WORK_DIR");
const LIB_DIR = getenv("FORKOP_LIB");
let FORKOP_VERSION = "";
let FORKOP_OPKG_RECOVERY_DIR = WORK + "/state/recovery";
let forkop_was_running = false;
let tmp_dir = WORK + "/tmp";
let apk = false;
let http_log = [];
let http_bodies = {};
let download_log = [];
let download_bodies = {};
let events = [];
function init_tmp_dir() { return true; }
function owner_pid() { return "1"; }
function now_seconds() { return 0; }
function is_apk() { return apk; }
function pkg_is_installed(name) { return true; }
function installed_package_version(name) { return FORKOP_VERSION + "-r1"; }
function updates_log(message, level) { push(events, message); }
function run_logged(description, command) { push(events, description); return false; }
function http_get(url) {
    push(http_log, url);
    let path = http_bodies[url];
    return path ? "" + fs.readfile(path) : "";
}
function download_with_retry(url, path, label) {
    push(download_log, url);
    let source = download_bodies[url];
    if (!source)
        return false;
    fs.writefile(path, fs.readfile(source));
    return true;
}
function action_fail(component, action, message) { die("action_fail: " + message); }
'''
open(sys.argv[2], 'w', encoding='utf-8').write(prefix + '\n\n'.join(parts) + '\n')
PY

cat >>"$WORK_DIR/probe.uc" <<'UC'
function check(ok, message) {
    if (!ok) {
        warn("FAIL: " + message + "\n");
        exit(1);
    }
}
function failure(fn) {
    try { fn(); return ""; }
    catch (e) { return "" + e.message; }
}
function has(list, value) { return index(list, value) >= 0; }
const BASE = "https://asofwar.github.io/forkop";
const API = "https://api.github.com/repos/Asofwar/forkop/releases/tags/";
const GH = "https://github.com/Asofwar/forkop/releases/download/";
function digest(name) {
    return split(trim(command_output_from_args([ "sha256sum", WORK + "/payload/" + name ])), " ")[0];
}
function reset(catalog) {
    http_log = [];
    download_log = [];
    events = [];
    http_bodies = {};
    http_bodies[BASE + "/updates/releases.json"] = catalog ? WORK + "/" + catalog : null;
    http_bodies[API + "1.0.29"] = WORK + "/github-1.0.29.json";
    http_bodies[API + "1.0.30"] = WORK + "/github-1.0.30.json";
    download_bodies = {};
    for (let version in [ "1.0.29", "1.0.30" ])
        for (let package in [ "forkop", "luci-app-forkop", "luci-i18n-forkop-ru" ]) {
            let name = package + "_" + version + ".ipk";
            download_bodies[BASE + "/releases/" + version + "/" + name] = WORK + "/payload/" + name;
            download_bodies[GH + version + "/" + name] = WORK + "/payload/" + name;
        }
}

// --- the fork is the default channel --------------------------------------
check(FORKOP_RELEASE_BASE_URL == BASE, "release channel default is not the fork: " + FORKOP_RELEASE_BASE_URL);
check(FORKOP_RELEASE_REPO == "Asofwar/forkop", "release repository default is not the fork: " + FORKOP_RELEASE_REPO);

// --- rollback set: static catalog first ------------------------------------
reset("catalog.json");
let previous = previous_forkop_release("1.0.30");
check(previous != null, "catalog release was not found for rollback");
check(previous.backend_url == BASE + "/releases/1.0.30/forkop_1.0.30.ipk", "rollback did not use the catalog URL: " + previous.backend_url);
check(previous.backend_sha256 == digest("forkop_1.0.30.ipk") &&
    previous.app_sha256 == digest("luci-app-forkop_1.0.30.ipk") &&
    previous.i18n_sha256 == digest("luci-i18n-forkop-ru_1.0.30.ipk"), "catalog checksums were not carried");
check(!has(http_log, API + "1.0.30"), "GitHub was asked although the catalog had the release");

// --- GitHub Releases as the fallback ---------------------------------------
reset("catalog.json");
previous = previous_forkop_release("1.0.29");
check(has(http_log, BASE + "/updates/releases.json") && has(http_log, API + "1.0.29"),
    "rollback lookup did not fall back from the catalog to GitHub");
check(previous != null && previous.backend_url == GH + "1.0.29/forkop_1.0.29.ipk", "GitHub rollback release was not resolved");
check(previous.backend_sha256 == digest("forkop_1.0.29.ipk"), "GitHub digest was not used as the checksum");

reset(null);
previous = previous_forkop_release("1.0.30");
check(previous != null && previous.backend_url == GH + "1.0.30/forkop_1.0.30.ipk",
    "an unreachable catalog did not fall back to GitHub");

reset("catalog-foreign.json");
previous = previous_forkop_release("1.0.30");
check(previous != null && previous.backend_url == GH + "1.0.30/forkop_1.0.30.ipk",
    "a catalog entry pointing elsewhere was trusted for rollback");

// --- neither source has the installed release ------------------------------
reset("catalog.json");
check(previous_forkop_release("1.0.28") == null, "an unpublished release was resolved");
FORKOP_VERSION = "1.0.28";
let error = prepare_forkop_package_set(WORK + "/new/forkop.ipk", WORK + "/new/app.ipk", WORK + "/new/i18n.ipk");
check(index(error, "Installed Forkop 1.0.28 is not published in this Forkop channel") == 0,
    "unpublished installed release was not explained: " + error);
check(index(error, "automatic upgrade refused") >= 0 &&
    index(error, "wget -qO- https://asofwar.github.io/forkop/install.sh | sh") >= 0,
    "unpublished installed release did not point at the fork installer: " + error);
check(length(download_log) == 0 && !file_exists(FORKOP_OPKG_RECOVERY_DIR), "an unpublished release staged files");

// --- staged rollback packages are held to their checksums ------------------
FORKOP_VERSION = "1.0.30";
reset("catalog.json");
download_bodies[BASE + "/releases/1.0.30/luci-app-forkop_1.0.30.ipk"] = WORK + "/payload/forkop_1.0.30.ipk";
error = prepare_forkop_package_set(WORK + "/new/forkop.ipk", WORK + "/new/app.ipk", WORK + "/new/i18n.ipk");
check(index(error, "Previous Forkop release package checksum mismatch for luci-app-forkop_1.0.30.ipk") == 0 &&
    index(error, "automatic upgrade refused") >= 0,
    "a tampered rollback package was staged: " + error);
check(!file_exists(FORKOP_OPKG_RECOVERY_DIR), "a rejected rollback set was left behind");
check(!has(events, "Checking new Forkop package set"), "the upgrade went on after a checksum mismatch");

reset("catalog.json");
download_bodies[BASE + "/releases/1.0.30/luci-i18n-forkop-ru_1.0.30.ipk"] = WORK + "/payload/forkop_1.0.30.ipk";
error = prepare_forkop_package_set(WORK + "/new/forkop.ipk", WORK + "/new/app.ipk", WORK + "/new/i18n.ipk");
check(index(error, "checksum mismatch for luci-i18n-forkop-ru_1.0.30.ipk") >= 0 && !file_exists(FORKOP_OPKG_RECOVERY_DIR),
    "a tampered rollback translation package was staged: " + error);

reset("catalog.json");
error = prepare_forkop_package_set(WORK + "/new/forkop.ipk", WORK + "/new/app.ipk", WORK + "/new/i18n.ipk");
check(has(events, "Checking new Forkop package set") && index(error, "preflight failed") >= 0,
    "verified rollback packages were refused: " + error);
check(!file_exists(FORKOP_OPKG_RECOVERY_DIR), "the preflight failure left the rollback set behind");

// --- the latest release is held to the checksums its source publishes -----
let latest = resolve_forkop_release_json("1.0.30", as_string(fs.readfile(WORK + "/latest-static.json")));
check(latest != null && latest.backend_sha256 == digest("forkop_1.0.30.ipk"), "latest.json checksums were not read");
let good = [ WORK + "/payload/forkop_1.0.30.ipk", WORK + "/payload/luci-app-forkop_1.0.30.ipk",
    WORK + "/payload/luci-i18n-forkop-ru_1.0.30.ipk" ];
check(failure(() => verify_latest_release_downloads(latest, good[0], good[1], good[2], "1.0.30")) == "",
    "matching latest packages were refused");
check(index(failure(() => verify_latest_release_downloads(latest, good[0], good[0], good[2], "1.0.30")),
    "Release package checksum mismatch") >= 0, "a mismatching latest package was accepted");
check(index(failure(() => verify_latest_release_downloads(latest, good[0], good[1], good[0], "1.0.30")),
    "Release package checksum mismatch") >= 0, "a mismatching latest translation package was accepted");

let github_latest = resolve_forkop_release_json("1.0.30", as_string(fs.readfile(WORK + "/github-1.0.30.json")));
check(index(failure(() => verify_latest_release_downloads(github_latest, good[1], good[1], good[2], "1.0.30")),
    "Release package checksum mismatch") >= 0, "a GitHub digest mismatch was accepted");

// Assets without a published checksum cannot be compared, only downloaded.
let unverified = resolve_forkop_release_json("1.0.30", as_string(fs.readfile(WORK + "/latest-github-nodigest.json")));
check(unverified != null && unverified.backend_sha256 == "", "a checksum was invented for an asset without one");
check(failure(() => verify_latest_release_downloads(unverified, good[1], good[0], good[2], "1.0.30")) == "",
    "a release without checksums could not be installed");

print("probe: PASS\n");
UC

# ucode reports a runtime exception but still exits 0, so the verdict is the
# probe's own last line rather than its exit status.
result="$(env -u FORKOP_RELEASE_BASE_URL -u FORKOP_RELEASE_REPO \
  FORKOP_MIRROR_BASE_URL="" \
  ucode -L "$FORKOP_LIB" "$WORK_DIR/probe.uc")" || fail "the release source probe failed"
[ "$result" = "probe: PASS" ] || fail "the release source probe did not finish: $result"

# The install path itself must run the latest-release check.
install_region="$(source_function "$ACTION_UC" install_forkop)" || exit 1
printf '%s\n' "$install_region" |
  grep -Fq 'verify_latest_release_downloads(release, backend_file, app_file, i18n_file, latest_version);' ||
  fail "installing the latest release must verify its published checksums"

printf 'fork updater release sources: PASS\n'
