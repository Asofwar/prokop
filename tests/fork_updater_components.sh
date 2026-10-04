#!/usr/bin/env bash
# The dependency mirror is opt-in. Without one, sing-box Extended comes from
# its GitHub releases and Zapret-Manager runs the project's own script; with
# one, both keep going through the mirror. Published checksums are enforced
# either way, and every launcher Prokop writes stays recognisable as its own.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
ACTION_UC="$PROKOP_LIB/components/action.uc"
DIAGNOSTICS_UC="$PROKOP_LIB/diagnostics/runtime.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# The probes read both from the environment.
export WORK_DIR PROKOP_LIB
# No Forkop package on this "router": launchers Forkop wrote are Prokop's.
export PROKOP_LEGACY_FORKOP_ROOT="$WORK_DIR/no-forkop"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

TAG="v1.14.1-extended-2.7.2"
VERSION="1.14.1-extended-2.7.2"
DOWNLOAD="https://github.com/shtorm-7/sing-box-extended/releases/download/$TAG"

mkdir -p "$WORK_DIR/payload" "$WORK_DIR/tmp" "$WORK_DIR/keep"
names=(
  "sing-box-$VERSION-android-arm64-compressed.tar.gz"
  "sing-box-$VERSION-linux-arm64-compressed.tar.gz"
  "sing-box-$VERSION-linux-arm64.tar.gz"
  "sing-box-extended_${VERSION}_openwrt_aarch64_cortex-a53.apk"
  "sing-box-extended_${VERSION}_openwrt_aarch64_cortex-a53.ipk"
  "sing-box-extended_${VERSION}_openwrt_x86_64.ipk"
)
for name in "${names[@]}"; do
  printf 'payload %s\n' "$name" >"$WORK_DIR/payload/$name"
done
printf '#!/bin/sh\nZAPRET_MANAGER_VERSION="7.4"\n' >"$WORK_DIR/payload/Zapret-Manager.sh"

# A GitHub "latest release" document, shaped like the API's answer: digests on
# the assets, the x86_64 package without one.
WORK_DIR="$WORK_DIR" TAG="$TAG" DOWNLOAD="$DOWNLOAD" python3 - "${names[@]}" <<'PY'
import hashlib
import json
import os
import sys

work = os.environ['WORK_DIR']
tag = os.environ['TAG']
assets = []
for name in sys.argv[1:]:
    asset = {'name': name, 'browser_download_url': os.environ['DOWNLOAD'] + '/' + name}
    if 'x86_64' not in name:
        digest = hashlib.sha256(open(os.path.join(work, 'payload', name), 'rb').read()).hexdigest()
        asset['digest'] = 'sha256:' + digest
    assets.append(asset)
release = {
    'tag_name': tag,
    'html_url': 'https://github.com/shtorm-7/sing-box-extended/releases/tag/' + tag,
    'prerelease': False,
    'assets': assets,
}
json.dump(release, open(os.path.join(work, 'github.json'), 'w'))

# The mirror copy, as ops/mirror/sync-sing-box-extended.sh writes it: only the
# OpenWrt packages and the Linux compressed archives, addressed under the
# mirror, every other field kept.
prefix = '/forkop/sing-box-extended/releases/' + tag + '/'
mirror = dict(release)
mirror['html_url'] = prefix
mirror['assets'] = []
for asset in release['assets']:
    name = asset['name']
    if (name.startswith('sing-box-extended_') and '_openwrt_' in name and name.endswith(('.apk', '.ipk'))) or \
            (name.startswith('sing-box-') and '-linux-' in name and name.endswith('-compressed.tar.gz')):
        copy = dict(asset)
        copy['browser_download_url'] = prefix + name
        mirror['assets'].append(copy)
json.dump(mirror, open(os.path.join(work, 'mirror.json'), 'w'))
json.dump({'message': 'API rate limit exceeded for 192.0.2.1.'}, open(os.path.join(work, 'limited.json'), 'w'))
PY

python3 - "$ACTION_UC" "$WORK_DIR/probe.uc" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding='utf-8').read()
consts = ('PROKOP_MIRROR_BASE_URL', 'INSECURE_MIRROR_MESSAGE', 'ZAPRET_MANAGER_SOURCE', 'ZAPRET_MANAGER_LAUNCHER_MARKER',
          'ZAPRET_MANAGER_FORKOP_MARKER', 'ZAPRET_MANAGER_LEGACY_MARKER', 'ZAPRET_MANAGER_BIN_DIR')
names = ('as_string', 'shell_quote', 'command_from_args', 'command_status',
         'command_success', 'command_success_from_args', 'command_output',
         'command_output_from_args', 'write_file', 'read_file', 'parse_json_object',
         'remove_file', 'file_exists', 'file_nonempty', 'path_basename',
         'module_command', 'module_output', 'helper_output', 'make_tmp_file',
         'helper_output_input', 'helper_success_input',
         'release_asset_object_sha256', 'release_asset_object_size', 'release_json_asset', 'release_json_asset_sha256', 'download_checksum_ok',
         'fetch_github_release_json', 'prokop_mirror_url', 'mirror_refuses_executables',
         'sing_box_extended_tag_is_stable',
         'set_sing_box_extended_release_from_json', 'resolve_sing_box_extended_release',
         'sing_box_extended_download_verified', 'zapret_manager_launcher_managed',
         'zapret_manager_url', 'zapret_manager_launcher',
         'install_zapret_manager', 'remove_zapret_manager')
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
let legacy_forkop = require("core.legacy_forkop");
const WORK = getenv("WORK_DIR");
const LIB_DIR = getenv("PROKOP_LIB");
// The launchers land here (PROKOP_ZAPRET_MANAGER_BIN_DIR) instead of /usr/bin.
const BIN = WORK + "/bin";
let tmp_dir = WORK + "/tmp";
let apk = false;
let http_log = [];
let http_bodies = {};
let download_log = [];
let download_bodies = {};
let result = null;
function init_tmp_dir() { return true; }
function owner_pid() { return "1"; }
function now_seconds() { return 0; }
function is_apk() { return apk; }
function read_openwrt_release_value(key) { return key == "DISTRIB_ARCH" ? "aarch64_cortex-a53" : ""; }
function resolve_sing_box_extended_arch_suffix() { return "arm64"; }
function updates_log(message, level) { }
function clear_version_caches() { }
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
function action_success(component, action, message, current_version, latest_version, changed, status, release_url) {
    result = { success: true, message, latest_version, release_url };
    die("action finished");
}
function action_fail(component, action, message) {
    result = { success: false, message };
    die("action finished");
}
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
function run_action(fn) {
    result = null;
    try { fn(); } catch (e) { }
    check(result != null, "the component action did not finish");
    return result;
}
function digest(name) {
    return split(trim(command_output_from_args([ "sha256sum", WORK + "/payload/" + name ])), " ")[0];
}
const MIRRORED = getenv("PROKOP_MIRROR_BASE_URL") != "";
const MIRROR = "https://mirror.test";
const API = "https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest";
const TAG = "v1.14.1-extended-2.7.2";
const VERSION = "1.14.1-extended-2.7.2";
const GH = "https://github.com/shtorm-7/sing-box-extended/releases/download/" + TAG + "/";
const MIRROR_FILES = MIRROR + "/forkop/sing-box-extended/releases/" + TAG + "/";
const ZMS_DIRECT = "https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh";
const ZMS_MIRRORED = MIRROR + "/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh";
const IPK = "sing-box-extended_" + VERSION + "_openwrt_aarch64_cortex-a53.ipk";
const APK = "sing-box-extended_" + VERSION + "_openwrt_aarch64_cortex-a53.apk";
const ARCHIVE = "sing-box-" + VERSION + "-linux-arm64-compressed.tar.gz";

// An http:// mirror could swap a binary and the digest it publishes with it:
// binaries and scripts are refused from it, not fetched around it (UPD-2).
if (index(PROKOP_MIRROR_BASE_URL, "http://") == 0) {
    check(resolve_sing_box_extended_release(false) == null && resolve_sing_box_extended_release(true) == null,
        "a sing-box Extended release was resolved from an http:// mirror");
    check(length(http_log) == 0, "an http:// mirror was asked for a binary release: " + join(" ", http_log));
    command_success_from_args([ "mkdir", "-p", BIN ]);
    let refused = run_action(() => install_zapret_manager("install"));
    check(!refused.success && index(refused.message, "https://") >= 0,
        "Zapret-Manager was installed from an http:// mirror: " + refused.message);
    check(length(download_log) == 0 && !file_exists(BIN + "/zms"), "an http:// mirror script was downloaded or installed");
    print("probe: PASS\n");
    exit(0);
}

check(PROKOP_MIRROR_BASE_URL == (MIRRORED ? MIRROR : ""), "mirror setting was not normalised: " + PROKOP_MIRROR_BASE_URL);
http_bodies[API] = WORK + "/github.json";
http_bodies[MIRROR + "/forkop/sing-box-extended/latest.json"] = WORK + "/mirror.json";

// --- sing-box Extended release source --------------------------------------
let release = resolve_sing_box_extended_release(false);
check(release != null, "the sing-box Extended package release was not resolved");
if (MIRRORED) {
    check(join(" ", http_log) == MIRROR + "/forkop/sing-box-extended/latest.json",
        "a configured mirror was not the only metadata source: " + join(" ", http_log));
    check(release.asset_url == MIRROR_FILES + IPK, "the package was not taken from the mirror: " + release.asset_url);
    check(release.release_url == MIRROR_FILES, "the release page was not taken from the mirror");
}
else {
    check(join(" ", http_log) == API, "without a mirror the metadata must come from GitHub: " + join(" ", http_log));
    check(release.asset_url == GH + IPK, "the package was not taken from GitHub: " + release.asset_url);
    check(release.release_url == "https://github.com/shtorm-7/sing-box-extended/releases/tag/" + TAG,
        "the release page was not GitHub's");
}
check(release.asset_name == IPK && release.tag == TAG, "the OpenWrt package was not selected");
check(release.asset_sha256 == digest(IPK), "the published digest was not carried");

apk = true;
release = resolve_sing_box_extended_release(false);
check(release != null && release.asset_name == APK && release.asset_sha256 == digest(APK),
    "the apk package was not selected on an apk system");
apk = false;

// The compressed binary variant comes from the mirror too (UPD-1): the
// mirror used to carry only the OpenWrt packages, and this variant could not
// be installed or updated at all with a mirror configured.
release = resolve_sing_box_extended_release(true);
check(release != null && release.asset_url == (MIRRORED ? MIRROR_FILES : GH) + ARCHIVE &&
    release.asset_sha256 == digest(ARCHIVE),
    "the compressed archive for this architecture was not selected: " + (release ? release.asset_url : "none"));

if (!MIRRORED) {

    // A rate-limited API answer is not a release.
    http_bodies[API] = WORK + "/limited.json";
    check(resolve_sing_box_extended_release(false) == null, "a GitHub error answer was taken for a release");
    http_bodies[API] = WORK + "/github.json";
}

// --- published digests are enforced ----------------------------------------
release = resolve_sing_box_extended_release(false);
let downloaded = WORK + "/tmp/" + release.asset_name;
fs.writefile(downloaded, fs.readfile(WORK + "/payload/" + IPK));
check(sing_box_extended_download_verified(release, downloaded) && file_exists(downloaded),
    "a package matching its digest was refused");
fs.writefile(downloaded, fs.readfile(WORK + "/payload/" + APK));
check(!sing_box_extended_download_verified(release, downloaded), "a package with the wrong digest was accepted");
check(!file_exists(downloaded), "a package with the wrong digest was kept");

// An asset published without a digest can only be downloaded, not compared.
check(release_json_asset_sha256("" + fs.readfile(WORK + "/github.json"), "name",
    "sing-box-extended_" + VERSION + "_openwrt_x86_64.ipk") == "", "a digest was invented for an asset without one");
check(download_checksum_ok(WORK + "/payload/" + IPK, ""), "an empty expectation must not refuse a download");

// --- Zapret-Manager launchers ----------------------------------------------
command_success_from_args([ "mkdir", "-p", BIN ]);
download_bodies[ZMS_DIRECT] = WORK + "/payload/Zapret-Manager.sh";
download_bodies[ZMS_MIRRORED] = WORK + "/payload/Zapret-Manager.sh";
let outcome = run_action(() => install_zapret_manager("install"));
check(outcome.success, "Zapret-Manager was not installed: " + outcome.message);
check(join(" ", download_log) == (MIRRORED ? ZMS_MIRRORED : ZMS_DIRECT),
    "Zapret-Manager came from the wrong source: " + join(" ", download_log));
check(outcome.release_url == (MIRRORED ? ZMS_MIRRORED : ZMS_DIRECT) && outcome.latest_version == "7.4",
    "the installed Zapret-Manager was not reported");
let launcher = "" + fs.readfile(BIN + "/zms");
check(launcher == "" + fs.readfile(BIN + "/zmsA"), "the two launchers differ");
check(index(launcher, "#!/bin/sh\n# Prokop Zapret-Manager launcher\n") == 0, "the launcher lacks its marker");
check(command_success_from_args([ "test", "-x", BIN + "/zms" ]) && command_success_from_args([ "test", "-x", BIN + "/zmsA" ]),
    "the launchers are not executable");
if (MIRRORED) {
    check(index(launcher, "export ZAPRET_MANAGER_MIRROR='" + MIRROR + "'\n") >= 0,
        "the mirrored launcher does not hand the mirror to Zapret-Manager");
    check(index(launcher, "exec sh <(wget -q -O - '" + ZMS_MIRRORED + "') \"$@\"\n") >= 0,
        "the mirrored launcher does not run the mirrored script");
    check(outcome.message == "Zapret-Manager has been installed from the Prokop mirror", "wrong mirrored install message");
}
else {
    check(index(launcher, "ZAPRET_MANAGER_MIRROR") < 0, "the direct launcher exports a mirror");
    check(index(launcher, "/zapret-manager/proxy/") < 0, "the direct launcher goes through a mirror proxy");
    check(index(launcher, "exec sh <(wget -q -O - '" + ZMS_DIRECT + "') \"$@\"\n") >= 0,
        "the direct launcher does not run the project's script");
    check(outcome.message == "Zapret-Manager has been installed", "wrong direct install message");
}
fs.writefile(WORK + "/keep/" + (MIRRORED ? "mirrored" : "direct"), launcher);

outcome = run_action(() => remove_zapret_manager("remove"));
check(outcome.success && !file_exists(BIN + "/zms") && !file_exists(BIN + "/zmsA"),
    "Prokop's own launchers were not removed: " + outcome.message);

// Launchers from older releases carried only the mirror proxy path.
let legacy = "#!/bin/sh\nexport ZAPRET_MANAGER_MIRROR='https://mirror.infotechtg.ru'\n" +
    "exec sh <(wget -q -O - 'https://mirror.infotechtg.ru/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') \"$@\"\n";
fs.writefile(BIN + "/zms", legacy);
fs.writefile(BIN + "/zmsA", legacy);
outcome = run_action(() => remove_zapret_manager("remove"));
check(outcome.success && !file_exists(BIN + "/zms"), "a launcher from an older release was not removed");

// Forkop wrote its launchers, direct ones included, under its own marker.
let forkop = "#!/bin/sh\n# Forkop X Zapret-Manager launcher\n" +
    "exec sh <(wget -q -O - 'https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') \"$@\"\n";
fs.writefile(BIN + "/zms", forkop);
fs.writefile(BIN + "/zmsA", forkop);
outcome = run_action(() => remove_zapret_manager("remove"));
check(outcome.success && !file_exists(BIN + "/zms") && !file_exists(BIN + "/zmsA"),
    "a launcher Forkop wrote was not removed: " + outcome.message);

fs.writefile(BIN + "/zms", "#!/bin/sh\nexec /opt/zapret-manager \"$@\"\n");
outcome = run_action(() => remove_zapret_manager("remove"));
check(!outcome.success && file_exists(BIN + "/zms"), "a launcher Prokop did not write was removed");
fs.unlink(BIN + "/zms");

print("probe: PASS\n");
UC

# ucode reports a runtime exception but still exits 0, so the verdict is the
# probe's own last line rather than its exit status.
for mirror in "" "https://mirror.test/" "http://mirror.test/"; do
  result="$(PROKOP_MIRROR_BASE_URL="$mirror" PROKOP_ZAPRET_MANAGER_BIN_DIR="$WORK_DIR/bin" \
    ucode -L "$PROKOP_LIB" "$WORK_DIR/probe.uc")" || fail "the component probe failed (mirror '$mirror')"
  [ "$result" = "probe: PASS" ] || fail "the component probe did not finish (mirror '$mirror'): $result"
done

# --- LuCI system info recognises the same launchers --------------------------

python3 - "$DIAGNOSTICS_UC" "$WORK_DIR/diagnostics.uc" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding='utf-8').read()
parts = []
for name in ('managed_zapret_manager_launcher', 'zapret_manager_launchers_installed'):
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    parts.append(re.sub(r'"/usr/bin/(zmsA?)"', r'BIN + "/\1"', match.group()))

prefix = r'''
let fs = require("fs");
let legacy_forkop = require("core.legacy_forkop");
const WORK = getenv("WORK_DIR");
const BIN = WORK + "/diag-bin";
function as_string(value) { return value == null ? "" : "" + value; }
function file_executable(path) { return system([ "test", "-x", path ]) == 0; }
'''
suffix = r'''
function check(ok, message) {
    if (!ok) {
        warn("FAIL: " + message + "\n");
        exit(1);
    }
}
function install(name, text, mode) {
    fs.writefile(BIN + "/" + name, text);
    system([ "chmod", mode, BIN + "/" + name ]);
}
system([ "mkdir", "-p", BIN ]);
for (let kind in [ "direct", "mirrored" ]) {
    let launcher = "" + fs.readfile(WORK + "/keep/" + kind);
    install("zms", launcher, "0755");
    install("zmsA", launcher, "0755");
    check(zapret_manager_launchers_installed() == 1, "the " + kind + " launchers are not reported as installed");
}
let legacy = "#!/bin/sh\nexec sh <(wget -q -O - 'https://mirror.infotechtg.ru/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') \"$@\"\n";
install("zms", legacy, "0755");
install("zmsA", legacy, "0755");
check(zapret_manager_launchers_installed() == 1, "launchers from an older release are not reported as installed");
let forkop = "#!/bin/sh\n# Forkop X Zapret-Manager launcher\n" +
    "exec sh <(wget -q -O - 'https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') \"$@\"\n";
install("zms", forkop, "0755");
install("zmsA", forkop, "0755");
check(zapret_manager_launchers_installed() == 1, "launchers Forkop wrote are not reported as installed");
install("zms", legacy, "0755");
install("zmsA", legacy, "0644");
check(zapret_manager_launchers_installed() == 0, "a launcher that cannot run was reported as installed");
install("zmsA", "#!/bin/sh\nexec /opt/zapret-manager \"$@\"\n", "0755");
check(zapret_manager_launchers_installed() == 0, "a foreign launcher was reported as installed");
print("probe: PASS\n");
'''
open(sys.argv[2], 'w', encoding='utf-8').write(prefix + '\n\n'.join(parts) + suffix)
PY

result="$(ucode -L "$PROKOP_LIB" "$WORK_DIR/diagnostics.uc")" || fail "the diagnostics probe failed"
[ "$result" = "probe: PASS" ] || fail "the diagnostics probe did not finish: $result"

printf 'fork updater components: PASS\n'
