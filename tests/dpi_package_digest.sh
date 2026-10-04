#!/usr/bin/env bash
set -euo pipefail

# zapret, zapret2 and ByeDPI packages are checked against the sha256 GitHub
# publishes for each asset (UPD-4). The check existed for sing-box-extended
# only: these packages, installed as root, were taken as downloaded.
#
# The functions are components/action.uc's own, extracted; the network is a
# stand-in.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
ACTION_UC="$LIB/components/action.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/tmp" "$WORK_DIR/payload"
printf 'good package\n' >"$WORK_DIR/payload/good"
printf 'tampered package\n' >"$WORK_DIR/payload/bad"

python3 - "$ACTION_UC" "$WORK_DIR/probe.uc" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding='utf-8').read()
names = ('as_string', 'shell_quote', 'command_from_args', 'command_output', 'command_output_from_args',
         'remove_file', 'file_nonempty', 'release_asset_object_sha256', 'release_url_asset_sha256',
         'download_checksum_ok', 'download_and_extract_zip_package', 'download_byedpi_package')
parts = []
for name in names:
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    parts.append(match.group())
prefix = r'''
let fs = require("fs");
const WORK = getenv("WORK_DIR");
let tmp_dir = WORK + "/tmp";
let served = "good";
let unzipped = false;
function updates_log(message, level) { }
function is_apk() { return false; }
function select_inner_package_path(bundle_file, component, arch, ext) { unzipped = true; return ""; }
function extract_arch_package_version(name, arch) { return "1.0"; }
function extract_zapret_bundle_version(name) { return "1.0"; }
function extract_zapret2_bundle_version(name) { return "1.0"; }
function command_success(command) { return false; }
function download_with_retry(url, path, label) {
    fs.writefile(path, fs.readfile(WORK + "/payload/" + served));
    return true;
}
'''
open(sys.argv[2], 'w', encoding='utf-8').write(prefix + '\n\n'.join(parts) + '\n')
PY

good_sha="$(sha256sum "$WORK_DIR/payload/good" | cut -d' ' -f1)"
cat >>"$WORK_DIR/probe.uc" <<UC
function check(ok, message) {
    if (!ok) {
        warn("FAIL: " + message + "\n");
        exit(1);
    }
}
const URL = "https://github.com/DPITrickster/ByeDPI-OpenWrt/releases/download/v1/byedpi_1.0_aarch64.ipk";
let releases = sprintf("%J", [
    { tag_name: "v2", assets: [ { name: "other.ipk", browser_download_url: "https://example.test/other.ipk", digest: "sha256:" + "0" * 64 } ] },
    { tag_name: "v1", assets: [ { name: "byedpi_1.0_aarch64.ipk", browser_download_url: URL, digest: "sha256:$good_sha" } ] }
]);
check(release_url_asset_sha256(releases, URL) == "$good_sha", "the digest of the downloaded asset was not found in the release list");
check(release_url_asset_sha256(sprintf("%J", { assets: [ { browser_download_url: URL, digest: "sha256:$good_sha" } ] }), URL) == "$good_sha",
    "the digest was not found in a single release document");
check(release_url_asset_sha256(releases, "https://example.test/none") == "", "a digest was invented for an asset without one");
check(release_url_asset_sha256("not json", URL) == "", "a broken document must give no digest");

let release = { arch: "aarch64", package_name: "byedpi_1.0_aarch64.ipk", package_url: URL,
    package_sha256: release_url_asset_sha256(releases, URL) };
served = "good";
check(download_byedpi_package(release) != null, "a ByeDPI package matching its digest was refused");
served = "bad";
check(download_byedpi_package(release) == null, "a ByeDPI package with the wrong digest was accepted");
check(!file_nonempty(tmp_dir + "/byedpi_1.0_aarch64.ipk"), "a ByeDPI package with the wrong digest was kept");

let bundle = { arch: "aarch64", bundle_name: "zapret_v1_aarch64.zip", bundle_url: URL + ".zip",
    bundle_sha256: "$good_sha", version: "1.0" };
served = "bad";
check(download_and_extract_zip_package(bundle, "zapret") == null && !unzipped,
    "a zapret bundle with the wrong digest was opened");
served = "good";
download_and_extract_zip_package(bundle, "zapret");
check(unzipped, "a zapret bundle matching its digest was not opened");
UC

export WORK_DIR
ucode -L "$LIB" "$WORK_DIR/probe.uc" || fail "the digest probe failed"
printf 'dpi package digest checks passed\n'
