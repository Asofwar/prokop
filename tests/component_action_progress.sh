#!/usr/bin/env bash
set -euo pipefail

# Progress of a component action the UI runs as a background job
# (components/progress.uc). The worker reports the stage it is in and the
# bytes of a download already on disk; component-action-status and
# get_ui_state pass that on while the job runs, and the finished job keeps
# the stages it went through. Only what was observed: the stages a failed
# action never reached are not reported, and a run outside a tracked job
# (cron, the command line) writes nothing.
#
# The real TorrServer install runs against the stand-ins of
# tests/torrserver_install.sh; the asset arrives in three parts a second
# apart, so a reader sees it grow.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'kill $(cat "$WORK/hang-pids" 2>/dev/null) 2>/dev/null; rm -rf "${WORK:?}"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'component_action_progress: FAIL: %s\n' "$1" >&2
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
export PROKOP_TORRSERVER_ECHO_URL="http://127.0.0.1:8090/echo"
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
# from what the fake service answers.
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
out=""
url=""
printf '%s\n' "$*" >>"$TEST_WORK/curl-args"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -x|-m|--connect-timeout|--speed-time|--speed-limit|--max-filesize) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://api.github.com/repos/YouROK/TorrServer/releases/latest) src="$TEST_FIX/release.json" ;;
  https://github.com/YouROK/TorrServer/releases/download/*) src="$TEST_FIX/asset/${url##*/}" ;;
  http://127.0.0.1:8090/echo) src="$TEST_WORK/echo" ;;
  *) exit 6 ;;
esac
[ -f "$src" ] || exit 22
if [ -n "$out" ] && [ -n "${TEST_HANG:-}" ] && [ "${url#https://github.com/YouROK/TorrServer/releases/download/}" != "$url" ]; then
  printf '%s\n' "$$" >>"$TEST_WORK/hang-pids"
  exec sleep 300
fi
if [ -n "$out" ] && [ -n "${TEST_SLOW:-}" ] && [ "${url#https://github.com/YouROK/TorrServer/releases/download/}" != "$url" ]; then
  size="$(wc -c <"$src")"; third=$(( (size + 2) / 3 ))
  : >"$out"
  for part in 0 1 2; do
    dd if="$src" bs="$third" skip="$part" count=1 2>/dev/null >>"$out"
    [ "$part" = 2 ] || sleep 1
  done
elif [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
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
  mkdir -p "$TEST_PROC/4242/fd" "$TEST_PROC/net"
  printf '%s\0-d\0x\0' "$TEST_BIN" >"$TEST_PROC/4242/cmdline"
  ln -sfn "$TEST_BIN" "$TEST_PROC/4242/exe"
  # It listens on :8090 (0x1F9A) with the socket of inode 31337.
  ln -sfn 'socket:[31337]' "$TEST_PROC/4242/fd/3"
  printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 00000000:1F9A 00000000:0000 0A 00000000:00000000 00:00000000 00000000 65536        0 31337 1 0 100 0 0 10 0\n' \
    >"$TEST_PROC/net/tcp"
  printf '%s' "$version" >"$TEST_WORK/echo"
}
stop() { rm -rf "$TEST_PROC/4242" "$TEST_PROC/net/tcp" "$TEST_WORK/echo"; }
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


JOBS="$WORK/run/component-actions"
export UPDATES_JOB_DIR="$JOBS"
export UPDATES_JOB_STALE_GRACE_SECONDS=30
mkdir -p "$JOBS"

make_asset() { # make_asset <version>: a program that reports its version, padded to a few KiB
  mkdir -p "$FIX/asset"
  {
    # shellcheck disable=SC2016 # expanded by the fake binary
    printf '#!/bin/sh\n[ "$1" = --version ] && echo "TorrServer %s"\nexit 0\n' "$1"
    head -c 6000 /dev/zero | tr '\0' '#'
    printf '\n'
  } >"$FIX/asset/TorrServer-linux-arm64"
  chmod 0755 "$FIX/asset/TorrServer-linux-arm64"
}
make_release() { # make_release <version> [digest]
  local sha size
  sha="${2:-$(sha256sum "$FIX/asset/TorrServer-linux-arm64" | cut -d' ' -f1)}"
  size="$(stat -c %s "$FIX/asset/TorrServer-linux-arm64")"
  cat >"$FIX/release.json" <<JSON
{"tag_name":"$1","draft":false,"prerelease":false,"html_url":"https://github.com/YouROK/TorrServer/releases/tag/$1",
 "assets":[{"name":"TorrServer-linux-arm64","size":$size,"digest":"sha256:$sha","browser_download_url":"https://github.com/YouROK/TorrServer/releases/download/$1/TorrServer-linux-arm64"}]}
JSON
}
json_get() { # json_get <file> <js expression over v>
  node -e 'const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const r = eval(process.argv[2]); process.stdout.write(typeof r === "string" ? r : JSON.stringify(r));' "$1" "$2"
}
updates() { ucode -L "$LIB" "$LIB/components/updates.uc" "$@"; }

# --- 1. A run outside a tracked job reports nothing --------------------------------
make_asset MatriX.145
make_release MatriX.145
action torrserver install
[ "$(field success)" = true ] || fail "plain install: $(cat "$WORK/out")"
[ -z "$(find "$WORK/run" -name '*.progress*' -print -quit)" ] || fail "an untracked run must not write progress"

# --- 2. The tracked job: stages, bytes while they arrive, the result -------------------
make_asset MatriX.146
make_release MatriX.146
size="$(stat -c %s "$FIX/asset/TorrServer-linux-arm64")"
TEST_SLOW=1 updates component-action-async torrserver install >"$WORK/start"
[ "$(json_get "$WORK/start" v.success)" = true ] || fail "start: $(cat "$WORK/start")"
job="$(json_get "$WORK/start" v.job_id)"
: >"$WORK/seen-bytes"
: >"$WORK/seen-stages"
for _ in $(seq 1 120); do
  updates component-action-status "$job" >"$WORK/status"
  [ "$(json_get "$WORK/status" 'typeof v.now')" = number ] || fail "status must carry the router's clock: $(cat "$WORK/status")"
  if [ "$(json_get "$WORK/status" v.running)" != true ]; then break; fi
  if [ "$(json_get "$WORK/status" '!!v.progress')" = true ]; then
    json_get "$WORK/status" 'v.progress.stage' >>"$WORK/seen-stages"; echo >>"$WORK/seen-stages"
    if [ "$(json_get "$WORK/status" 'v.progress.download ? v.progress.download.bytes : -1')" -ge 0 ]; then
      json_get "$WORK/status" 'v.progress.download.bytes + "/" + v.progress.download.total + " " + v.progress.download.file' >>"$WORK/seen-bytes"
      echo >>"$WORK/seen-bytes"
    fi
  fi
  sleep 0.3
done
[ "$(json_get "$WORK/status" v.running)" = false ] || fail "the job did not finish: $(cat "$WORK/status")"
[ "$(json_get "$WORK/status" v.success)" = true ] || fail "tracked update: $(cat "$WORK/status")"
grep -Fxq download "$WORK/seen-stages" || fail "the download stage was never reported: $(sort -u "$WORK/seen-stages" | tr '\n' ' ')"
# The size grew while it ran, against the size the release publishes.
partial="$(grep -v "^0/" "$WORK/seen-bytes" | grep -v "^$size/" | head -n1 || true)"
[ -n "$partial" ] || fail "no partial download was reported: $(sort -u "$WORK/seen-bytes" | tr '\n' ' ')"
grep -Fq "/$size TorrServer-linux-arm64" "$WORK/seen-bytes" || fail "the published size must be the total: $(head -n3 "$WORK/seen-bytes")"
# The finished job keeps its stages, in order, every one ended.
stages="$(json_get "$WORK/status" 'v.progress.stages.map(s => s.id).join(" ")')"
[ "$stages" = "resolve download verify stop install start" ] || fail "stages of an update: $stages"
[ "$(json_get "$WORK/status" 'v.progress.outcome')" = done ] || fail "outcome: $(cat "$WORK/status")"
[ "$(json_get "$WORK/status" 'v.progress.stages.every(s => s.finished_at !== null && s.finished_at >= s.started_at)')" = true ] ||
  fail "every stage of a finished job must have ended: $(cat "$WORK/status")"
[ ! -e "$JOBS/$job.progress" ] || fail "the progress file must go once the job keeps it"
"$BIN" --version | grep -Fxq "TorrServer MatriX.146" || fail "the tracked update did not install"

# get_ui_state's reader: a running job's progress next to its state.
cat >"$JOBS/9-9.json" <<'JSON'
{"success":true,"running":true,"kind":"component","component":"torrserver","action":"install","pid":null,"started_at":1}
JSON
printf '{"format":1,"stage":"download","stages":[{"id":"resolve","started_at":1,"finished_at":2},{"id":"download","started_at":2,"finished_at":null}],"download":{"file":"https://user:secret@example.com/x/TorrServer-linux-arm64","bytes":10,"total":20,"index":1,"count":1},"outcome":"","started_at":1,"updated_at":3,"extra":"x"}\n' >"$JOBS/9-9.progress"
ucode -L "$LIB" -e '
  let p = require("components.progress").read(ARGV[0]);
  print(sprintf("%J", p), "\n");' "$JOBS/9-9.progress" >"$WORK/read"
[ "$(json_get "$WORK/read" 'v.download.file')" = TorrServer-linux-arm64 ] || fail "a reported file must be a bare name: $(cat "$WORK/read")"
[ "$(json_get "$WORK/read" '"extra" in v')" = false ] || fail "unknown fields must not pass: $(cat "$WORK/read")"
grep -Fq secret "$WORK/read" && fail "credentials in a URL must not pass: $(cat "$WORK/read")"
sed -i "s/\"started_at\":1}/\"started_at\":$(date +%s)}/" "$JOBS/9-9.json"
PROKOP_UI_COMPONENT_ACTION_DIR="$JOBS" ucode -L "$LIB" "$LIB/service/ui.uc" get-ui-state >"$WORK/ui-state" 2>/dev/null
[ "$(json_get "$WORK/ui-state" 'v.actions.component.find(c => c.job_id === "9-9").progress.download.bytes')" = 10 ] ||
  fail "get_ui_state must pass a running job's progress: $(json_get "$WORK/ui-state" v.actions.component)"
rm -f "$JOBS/9-9.json" "$JOBS/9-9.progress"

# --- 3. A failed update ends at the stage that failed ------------------------------
make_asset MatriX.147
make_release MatriX.147 "$(printf '%064d' 1)"
updates component-action-async torrserver install >"$WORK/start"
job="$(json_get "$WORK/start" v.job_id)"
for _ in $(seq 1 100); do
  updates component-action-status "$job" >"$WORK/status"
  [ "$(json_get "$WORK/status" v.running)" = true ] || break
  sleep 0.3
done
[ "$(json_get "$WORK/status" v.success)" = false ] || fail "a checksum mismatch must fail: $(cat "$WORK/status")"
[ "$(json_get "$WORK/status" 'v.progress.outcome')" = failed ] || fail "outcome of a failure: $(cat "$WORK/status")"
[ "$(json_get "$WORK/status" 'v.progress.stages.map(s => s.id).join(" ")')" = "resolve download verify" ] ||
  fail "a failure must report only the stages it reached: $(json_get "$WORK/status" 'v.progress.stages')"
"$BIN" --version | grep -Fxq "TorrServer MatriX.146" || fail "a failed update must keep the installed release"

# --- 4. The deadline of a stalled download kills the download itself (PRG-5) --------
# The published size caps the transfer (curl --max-filesize).
grep -Fq -- "--max-filesize $size " "$WORK/curl-args" ||
  fail "the published size must cap the download: $(grep -F TorrServer-linux-arm64 "$WORK/curl-args" | head -n 2)"
make_asset MatriX.148
make_release MatriX.148
: >"$WORK/hang-pids"
TEST_HANG=1 PROKOP_COMPONENT_DOWNLOAD_TIMEOUT=1 PROKOP_DOWNLOAD_DEADLINE_SLACK=0 \
  updates component-action-async torrserver install >"$WORK/start"
job="$(json_get "$WORK/start" v.job_id)"
for _ in $(seq 1 100); do
  updates component-action-status "$job" >"$WORK/status"
  [ "$(json_get "$WORK/status" v.running)" = true ] || break
  sleep 0.3
done
[ "$(json_get "$WORK/status" v.running)" = false ] || fail "a stalled download did not end at its deadline: $(cat "$WORK/status")"
[ "$(json_get "$WORK/status" v.success)" = false ] || fail "a stalled download must fail: $(cat "$WORK/status")"
[ -s "$WORK/hang-pids" ] || fail "the stalled download never started"
while read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then fail "the stalled download $pid outlived its deadline"; fi
done <"$WORK/hang-pids"

printf 'component action progress checks passed\n'
