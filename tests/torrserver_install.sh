#!/usr/bin/env bash
set -euo pipefail

# TorrServer installed and updated from Prokop (components/action.uc
# install_torrserver and remove_torrserver, torrserver/manager.uc).
#
# The official build of YouROK/TorrServer for the router's CPU is downloaded,
# checked against the size and sha256 GitHub publishes for it, run once for
# its version, and only then put at its fixed path; the service must come up
# and answer with that version. An update keeps the previous binary until
# the new one answers and puts it back when it does not. A TorrServer that
# Prokop did not install is never overwritten, started over or removed.
#
# The real action runs against stand-ins for the network (curl), the CPU
# (uname), the init script (procd's process tree under a fake /proc) and the
# log; its files stay in the test's directory.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'torrserver_install: FAIL: %s\n' "$1" >&2
  for log in out events syslog; do
    [ ! -s "$WORK/$log" ] || sed "s|^|  $log: |" "$WORK/$log" >&2
  done
  exit 1
}

command -v ucode >/dev/null || fail "ucode is required"
command -v node >/dev/null || fail "node is required"

# The library, with the action's temporary directory under the test's own.
LIB="$WORK/lib"
cp -a "$ROOT_DIR/prokop/files/usr/lib/." "$LIB/"
sed -i "s|/tmp/prokop-updates\.XXXXXX|$WORK/tmp/prokop-updates.XXXXXX|" "$LIB/components/action.uc"
grep -Fq "$WORK/tmp/prokop-updates" "$LIB/components/action.uc" || fail "could not move the action's temporary directory"
MANAGER="$LIB/torrserver/manager.uc"

TS_DIR="$WORK/opt/torrserver"
BIN="$TS_DIR/torrserver"
MARKER="$TS_DIR/prokop-managed.json"
PROC="$WORK/proc"
FIX="$WORK/fixtures"
mkdir -p "$WORK/bin" "$WORK/run" "$WORK/tmp" "$PROC" "$FIX" "$WORK/rc.d"
printf 'prokop.settings=settings\n' >"$WORK/uci.state"
: >"$WORK/events"

export PATH="$WORK/bin:$PATH"
export TMPDIR="$WORK/tmp"
export TEST_WORK="$WORK" TEST_FIX="$FIX" TEST_PROC="$PROC" TEST_BIN="$BIN" TEST_MARKER="$MARKER"
export PROKOP_LIB="$LIB"
export PROKOP_TORRSERVER_DIR="$TS_DIR"
export PROKOP_TORRSERVER_INIT="$WORK/bin/torrserver-init"
export PROKOP_TORRSERVER_START_TIMEOUT=3
export PROKOP_TORRSERVER_API_URL="http://127.0.0.1:8090"
export PROKOP_MEMINFO_PATH="$WORK/meminfo"
# 1 GiB, as the GL-MT6000: a 128 MiB cache.
printf 'MemTotal:        1006668 kB\n' >"$WORK/meminfo"
export PROKOP_PROC_DIR="$PROC"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_SYSTEM_INFO_CACHE_FILE="$WORK/run/system-info.json"
export PROKOP_UCI_STATE_FILE="$WORK/uci.state"
export PROKOP_SERVICE_INIT="$WORK/missing-prokop-init"
export PROKOP_OPKG_RECOVERY_DIR="$WORK/recovery"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK/run/managed-upgrade-sing-box"
export UPDATES_LOCK_DIR="$WORK/run/component-action.lock"
export PROKOP_TORRSERVER_DIRECT_INIT="$WORK/missing-direct-init"

cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_WORK/syslog"
SH
cat >"$WORK/bin/uname" <<'SH'
#!/bin/sh
cat "$TEST_WORK/machine"
SH
printf 'aarch64\n' >"$WORK/machine"
# curl: the GitHub API and the asset from the fixtures, TorrServer's /echo
# and /settings from what the fake service answers (its settings live in
# ts-settings.json while it runs).
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
out=""
url=""
data=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -x|-m|--connect-timeout|--speed-time|--speed-limit) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://api.github.com/repos/YouROK/TorrServer/releases/latest) src="$TEST_FIX/release.json" ;;
  https://github.com/YouROK/TorrServer/releases/download/*) src="$TEST_FIX/asset/${url##*/}" ;;
  http://127.0.0.1:8090/echo) src="$TEST_WORK/echo" ;;
  http://127.0.0.1:8090/settings)
    [ -f "$TEST_WORK/echo" ] || exit 7
    printf '%s\n' "$(cat "$data")" >>"$TEST_WORK/settings-requests"
    exec node -e '
      const fs = require("fs");
      const [body, store] = process.argv.slice(1);
      const req = JSON.parse(fs.readFileSync(body, "utf8"));
      if (req.action === "get") process.stdout.write(fs.readFileSync(store, "utf8"));
      else if (req.action === "set") fs.writeFileSync(store, JSON.stringify(req.sets));
      else process.exit(22);' "$data" "$TEST_WORK/ts-settings.json" ;;
  *) exit 6 ;;
esac
[ -f "$src" ] || exit 22
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
SH
# The init script as procd runs it: start runs the binary at its path when
# its marker is there (a pid in the fake /proc whose exe is that path), and
# it answers /echo with the version the binary reports, unless that version
# is one the test makes fail.
cat >"$WORK/bin/torrserver-init" <<'SH'
#!/bin/sh
printf 'init %s\n' "$1" >>"$TEST_WORK/events"
start() {
  [ -x "$TEST_BIN" ] && [ -f "$TEST_MARKER" ] || return 0
  version="$("$TEST_BIN" --version | sed 's/^TorrServer //')"
  if [ -f "$TEST_WORK/fail-version" ] && [ "$(cat "$TEST_WORK/fail-version")" = "$version" ]; then
    return 0
  fi
  mkdir -p "$TEST_PROC/4242"
  printf '%s\0-d\0x\0' "$TEST_BIN" >"$TEST_PROC/4242/cmdline"
  ln -sfn "$TEST_BIN" "$TEST_PROC/4242/exe"
  printf '%s' "$version" >"$TEST_WORK/echo"
  # TorrServer's first start writes its defaults to its database.
  if [ ! -e "$(dirname "$TEST_BIN")/config.db" ]; then
    : >"$(dirname "$TEST_BIN")/config.db"
    printf '{"CacheSize":67108864,"ReaderReadAHead":95,"PreloadCache":50,"ConnectionsLimit":25,"TorrentDisconnectTimeout":30,"ResponsiveMode":false,"EnableDLNA":true,"FriendlyName":"tv"}' \
      >"$TEST_WORK/ts-settings.json"
  fi
}
stop() { rm -rf "$TEST_PROC/4242" "$TEST_WORK/echo"; }
case "$1" in
  start) start ;;
  restart) stop; start ;;
  stop) stop ;;
  enable) : >"$TEST_WORK/rc.d/S95prokop-torrserver" ;;
  disable) rm -f "$TEST_WORK/rc.d/S95prokop-torrserver" ;;
  enabled) [ -e "$TEST_WORK/rc.d/S95prokop-torrserver" ] ;;
esac
SH
chmod 0755 "$WORK/bin/"*

# A TorrServer build: a program that reports its version.
make_asset() { # make_asset <version> [reported version]
  mkdir -p "$FIX/asset"
  # shellcheck disable=SC2016 # expanded by the fake binary
  printf '#!/bin/sh\n[ "$1" = --version ] && echo "TorrServer %s"\n' "${2:-$1}" >"$FIX/asset/TorrServer-linux-arm64"
  chmod 0755 "$FIX/asset/TorrServer-linux-arm64"
}
# The release document; DIGEST overrides the published sha256 ("none" for
# none), URL_HOST the download host.
make_release() { # make_release <version>
  local sha size digest
  sha="$(sha256sum "$FIX/asset/TorrServer-linux-arm64" | cut -d' ' -f1)"
  size="$(stat -c %s "$FIX/asset/TorrServer-linux-arm64")"
  digest="\"sha256:${DIGEST:-$sha}\""
  [ "${DIGEST:-}" != none ] || digest=null
  cat >"$FIX/release.json" <<JSON
{"tag_name":"$1","draft":false,"prerelease":false,"html_url":"https://github.com/YouROK/TorrServer/releases/tag/$1",
 "assets":[
  {"name":"TorrServer-linux-amd64","size":10,"digest":"sha256:$(printf '%064d' 0)","browser_download_url":"https://github.com/YouROK/TorrServer/releases/download/$1/TorrServer-linux-amd64"},
  {"name":"TorrServer-linux-arm64","size":$size,"digest":$digest,"browser_download_url":"https://${URL_HOST:-github.com}/YouROK/TorrServer/releases/download/$1/TorrServer-linux-arm64"}]}
JSON
}
publish() { # publish <version> [reported version]
  make_asset "$@"
  make_release "$1"
}

action() { # action <component action> <action>
  : >"$WORK/events"
  set +e
  ucode -L "$LIB" "$LIB/components/action.uc" component-action "$1" "$2" >"$WORK/out" 2>>"$WORK/syslog" </dev/null
  set -e
}
field() { # field <name>: of the action's response
  node -e 'const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(v[process.argv[2]]));' \
    "$WORK/out" "$1"
}
status_field() {
  ucode -L "$LIB" "$MANAGER" status |
    node -e 'let s = ""; process.stdin.on("data", (d) => s += d).on("end", () => process.stdout.write(String(JSON.parse(s)[process.argv[1]])));' "$1"
}
expect_success() { [ "$(field success)" = true ] || fail "$1: $(cat "$WORK/out")"; }
expect_failure() { # expect_failure <what> <message part>
  [ "$(field success)" = false ] || fail "$1 must fail: $(cat "$WORK/out")"
  field message | grep -Fq "$2" || fail "$1: the message does not say '$2': $(cat "$WORK/out")"
}
bin_reports() { [ "$("$BIN" --version)" = "TorrServer $1" ] || fail "$2: the installed binary is not $1"; }

# --- Pure helpers ------------------------------------------------------------------
for row in "aarch64_cortex-a53 aarch64 arm64" "x86_64 x86_64 amd64" "i386_pentium4 i686 386" \
  "mipsel_24kc mips mipsle" "mips_24kc mips mips" "mips64el_octeonplus mips64 mips64le" \
  "arm_cortex-a7_neon-vfpv4 armv7l arm7" "arm_cortex-a9_vfpv3-d16 armv7l arm7" \
  "arm_arm926ej-s armv5tejl arm5" "arm_mpcore armv6l arm5" "riscv64_riscv64 riscv64 riscv64" \
  "- aarch64 arm64" "- armv7l arm7"; do
  read -r distrib machine want <<<"$row"
  [ "$distrib" != - ] || distrib=""
  got="$(ucode -L "$LIB" "$MANAGER" asset-arch "$distrib" "$machine" || true)"
  [ "$got" = "$want" ] || fail "asset-arch $distrib $machine: $got, expected $want"
done
! ucode -L "$LIB" "$MANAGER" asset-arch powerpc_464fp ppc >/dev/null || fail "asset-arch must refuse a CPU without a build"
[ "$(ucode -L "$LIB" "$MANAGER" version-key MatriX.145.2)" = 145.2 ] || fail "version-key MatriX.145.2"

# --- 1. Nothing installed: a check says so, an install puts the release in place ----
publish MatriX.145
[ "$(status_field installed)" = 0 ] && [ "$(status_field foreign)" = 0 ] || fail "an empty router must show TorrServer not installed"
action torrserver check_update
expect_failure "check without TorrServer" "TorrServer is not installed"
[ "$(field latest_version)" = MatriX.145 ] || fail "the check must name the latest release: $(cat "$WORK/out")"

action torrserver install
expect_success "fresh install"
[ "$(field current_version)" = MatriX.145 ] || fail "install must report the installed version: $(cat "$WORK/out")"
bin_reports MatriX.145 "fresh install"
cmp -s "$BIN" "$FIX/asset/TorrServer-linux-arm64" || fail "the installed binary is not the published asset"
[ "$(stat -c %a "$BIN")" = 755 ] || fail "the installed binary must be 0755"
grep -Fq '"version": "MatriX.145"' "$MARKER" || fail "the marker must name the version: $(cat "$MARKER")"
if ! grep -Fxq "init enable" "$WORK/events" || ! grep -Fxq "init restart" "$WORK/events"; then
  fail "install must enable and start the service"
fi
[ "$(status_field installed)" = 1 ] && [ "$(status_field running)" = 1 ] && [ "$(status_field version)" = MatriX.145 ] ||
  fail "status after install: $(ucode -L "$LIB" "$MANAGER" status)"
[ -z "$(find "$WORK/tmp" -mindepth 1 -print -quit)" ] || fail "install left files in its temporary directory: $(ls "$WORK/tmp")"

# The same release again changes nothing.
action torrserver check_update
expect_success "check, up to date"
[ "$(field status)" = latest ] || fail "the check must report latest: $(cat "$WORK/out")"
action torrserver install
expect_success "install of the running release"
[ "$(field changed)" = 0 ] || fail "installing the running release must change nothing: $(cat "$WORK/out")"
grep -Fq "init" "$WORK/events" && fail "installing the running release must not restart TorrServer"

# The first install gives TorrServer the recommended settings, over its own
# and keeping the rest.
setting() { node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]]))' "$WORK/ts-settings.json" "$1"; }
[ "$(setting CacheSize)" = 134217728 ] || fail "a fresh install must size the cache to 128 MiB for 1 GiB of RAM: $(cat "$WORK/ts-settings.json")"
[ "$(setting ResponsiveMode)" = true ] && [ "$(setting PreloadCache)" = 50 ] || fail "a fresh install must apply the recommended settings: $(cat "$WORK/ts-settings.json")"
[ "$(setting EnableDLNA)" = true ] && [ "$(setting FriendlyName)" = tv ] || fail "the recommended settings must keep the others: $(cat "$WORK/ts-settings.json")"
[ -e "$TS_DIR/prokop-settings-applied" ] || fail "a fresh install must stamp the applied settings"
for row in "131072 32" "262144 32" "524288 64" "1006668 128" "4194304 256"; do
  read -r kib mib <<<"$row"
  printf 'MemTotal: %s kB\n' "$kib" >"$WORK/meminfo"
  got="$(ucode -L "$LIB" "$MANAGER" recommended-settings | node -e 'let s = ""; process.stdin.on("data", (d) => s += d).on("end", () => process.stdout.write(String(JSON.parse(s).CacheSize / 1048576)))')"
  [ "$got" = "$mib" ] || fail "cache for $kib KiB of RAM: $got MiB, expected $mib"
done
printf 'MemTotal:        1006668 kB\n' >"$WORK/meminfo"

# --- 2. Update ------------------------------------------------------------------
: >"$TS_DIR/config.db"
# A setting the user changed survives an update: the settings are applied once.
node -e 'const f = process.argv[1], fs = require("fs"); const v = JSON.parse(fs.readFileSync(f, "utf8")); v.CacheSize = 33554432; fs.writeFileSync(f, JSON.stringify(v));' "$WORK/ts-settings.json"
publish MatriX.146
action torrserver check_update
[ "$(field status)" = outdated ] || fail "a newer release must read as an update: $(cat "$WORK/out")"
action torrserver install
expect_success "update"
bin_reports MatriX.146 "update"
[ ! -e "$BIN.prokop-old" ] && [ ! -e "$MARKER.prokop-old" ] || fail "a completed update must not keep the previous binary"
[ -e "$TS_DIR/config.db" ] || fail "an update must keep TorrServer's database"
[ "$(setting CacheSize)" = 33554432 ] || fail "an update must not apply the recommended settings over the user's: $(cat "$WORK/ts-settings.json")"

# --- 3. An update that does not start puts the previous release back ------------------
publish MatriX.147
printf 'MatriX.147' >"$WORK/fail-version"
action torrserver install
expect_failure "update that does not start" "the previous version MatriX.146 runs again"
bin_reports MatriX.146 "failed update"
grep -Fq '"version": "MatriX.146"' "$MARKER" || fail "the marker must be the previous one again"
[ "$(status_field running)" = 1 ] || fail "the previous release must run again"
[ ! -e "$BIN.prokop-new" ] && [ ! -e "$BIN.prokop-old" ] || fail "a failed update left staged files: $(ls "$TS_DIR")"
rm -f "$WORK/fail-version"

# --- 4. Downloads that cannot be trusted are not installed ----------------------
publish MatriX.148
DIGEST="$(printf '%064d' 1)" make_release MatriX.148
action torrserver install
expect_failure "checksum mismatch" "does not match its published size and sha256"
bin_reports MatriX.146 "checksum mismatch"
DIGEST=none make_release MatriX.148
action torrserver install
expect_failure "asset without a digest" "no verified build for arm64"
URL_HOST=example.com make_release MatriX.148
action torrserver install
expect_failure "asset from another host" "no verified build"
publish MatriX.148 MatriX.999
action torrserver install
expect_failure "binary that reports another version" "reports another version (MatriX.999)"
bin_reports MatriX.146 "binary that reports another version"
printf 'sparc64\n' >"$WORK/machine"
publish MatriX.148
action torrserver install
expect_failure "CPU without a build" "no build for this router's CPU"
printf 'aarch64\n' >"$WORK/machine"

# --- 5. A binary changed behind Prokop's back is left alone -------------------------
# Same size, other content: only the checksum tells.
cp "$BIN" "$WORK/saved-bin"
sed -i 's/TorrServer/TorrServeR/' "$BIN"
cmp -s "$BIN" "$WORK/saved-bin" && fail "fixture: the binary did not change"
action torrserver install
expect_failure "update of a changed binary" "does not match the checksum Prokop recorded"
action torrserver remove
expect_failure "removal of a changed binary" "does not match the checksum Prokop recorded"
[ -e "$BIN" ] || fail "a changed binary must not be removed"
# Another size: it is not Prokop's binary any more.
printf '\n# edited\n' >>"$BIN"
[ "$(status_field installed)" = 0 ] && [ "$(status_field foreign)" = 1 ] || fail "a binary of another size must read as foreign"
action torrserver install
expect_failure "update over a binary of another size" "Another TorrServer is installed or running"
cp "$WORK/saved-bin" "$BIN"

# --- 6. Start: the installed release runs again ---------------------------------------
"$WORK/bin/torrserver-init" stop
[ "$(status_field running)" = 0 ] || fail "fixture: TorrServer did not stop"
# A TorrServer installed before Prokop applied the settings (no stamp)
# gets them once it runs; a stopped one cannot take them.
rm -f "$TS_DIR/prokop-settings-applied"
ucode -L "$LIB" "$MANAGER" apply-recommended-once 1 >/dev/null && fail "a stopped TorrServer cannot take the recommended settings"
action torrserver start
expect_success "start"
[ "$(setting CacheSize)" = 134217728 ] && [ "$(setting EnableDLNA)" = true ] || fail "start must apply the recommended settings once and keep the others: $(cat "$WORK/ts-settings.json")"
[ -e "$TS_DIR/prokop-settings-applied" ] || fail "applied settings must be stamped"
# After that, a setting the user changes stays.
node -e 'const f = process.argv[1], fs = require("fs"); const v = JSON.parse(fs.readFileSync(f, "utf8")); v.CacheSize = 33554432; fs.writeFileSync(f, JSON.stringify(v));' "$WORK/ts-settings.json"
[ "$(ucode -L "$LIB" "$MANAGER" apply-recommended-once 1)" = already ] || fail "stamped settings must not be applied again"
[ "$(setting CacheSize)" = 33554432 ] || fail "settings the user changed must stay"
# The card's button applies them again on request.
action torrserver apply_settings
expect_success "recommended settings button"
[ "$(setting CacheSize)" = 134217728 ] && [ "$(setting EnableDLNA)" = true ] || fail "the button must apply the recommended settings and keep the others: $(cat "$WORK/ts-settings.json")"
"$WORK/bin/torrserver-init" stop
action torrserver apply_settings
expect_failure "recommended settings while stopped" "TorrServer is stopped"
action torrserver start
expect_success "start after the button"
[ "$(status_field running)" = 1 ] || fail "start must run TorrServer again"
action torrserver start
expect_success "start while running"
[ "$(field changed)" = 0 ] || fail "starting a running TorrServer must change nothing"

# --- 7. Removal keeps the settings ----------------------------------------------------
action torrserver remove
expect_success "remove"
[ ! -e "$BIN" ] && [ ! -e "$MARKER" ] || fail "remove must delete the binary and its marker"
[ -e "$TS_DIR/config.db" ] || fail "remove must keep TorrServer's database"
if ! grep -Fxq "init stop" "$WORK/events" || ! grep -Fxq "init disable" "$WORK/events"; then
  fail "remove must stop and disable the service"
fi
action torrserver remove
expect_success "remove again"
[ "$(field changed)" = 0 ] || fail "a second removal must change nothing"
action torrserver start
expect_failure "start without TorrServer" "TorrServer is not installed"

# --- 8. A TorrServer installed by other means ----------------------------------------
# One that runs from elsewhere.
mkdir -p "$PROC/777"
printf '/usr/bin/TorrServer-linux-arm64\0-d\0/opt/ts\0' >"$PROC/777/cmdline"
ln -sfn /usr/bin/TorrServer-linux-arm64 "$PROC/777/exe"
[ "$(status_field foreign)" = 1 ] || fail "a TorrServer run from elsewhere must read as foreign"
action torrserver install
expect_failure "install beside a foreign TorrServer" "Another TorrServer is installed or running"
[ ! -e "$BIN" ] || fail "nothing may be installed beside a foreign TorrServer"
rm -rf "${PROC:?}/777"
# One at Prokop's path without its marker.
cp "$FIX/asset/TorrServer-linux-arm64" "$BIN"
[ "$(status_field foreign)" = 1 ] && [ "$(status_field installed)" = 0 ] || fail "a binary without the marker must read as foreign"
action torrserver install
expect_failure "install over a foreign binary" "Another TorrServer is installed or running"
action torrserver remove
expect_failure "removal of a foreign binary" "was not installed by Prokop"
[ -e "$BIN" ] || fail "a foreign binary must not be removed"

printf 'torrserver install checks passed\n'
