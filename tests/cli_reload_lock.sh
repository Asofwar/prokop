#!/usr/bin/env bash
set -euo pipefail

# `prokop start|stop|reload|restart` run from the command line take
# reload.lock themselves (LC-3). They used to run service/lifecycle.uc with no
# lock at all, so an SSH reload during a list update, a DNS failover switch or
# an init.d reload ran a second nft and sing-box transition next to it. Under
# init.d (service/initd.uc holds the lock with an ancestor's pid) nothing
# changes.
#
# The lifecycle is the real service/lifecycle.uc (harness of
# tests/reload_failure_keeps_workers.sh).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
REAL_INITD="$ROOT_DIR/prokop/files/etc/init.d/prokop"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

actors=()
cleanup() {
  owned_kill KILL "${actors[@]}" || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -s "$EVENTS" ]; then
    sed 's/^/  event: /' "$EVENTS" >&2
  fi
  if [ -s "$WORK_DIR/syslog" ]; then
    sed 's/^/  syslog: /' "$WORK_DIR/syslog" >&2
  fi
  exit 1
}

FAKE_LIB="$WORK_DIR/fake-lib"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/prokop" "$WORK_DIR/tmp" "$WORK_DIR/singbox-tmp/rulesets" \
  "$FAKE_LIB/service" "$FAKE_LIB/subscription" "$FAKE_LIB/config" "$FAKE_LIB/singbox" "$FAKE_LIB/nft" \
  "$FAKE_LIB/dns" "$FAKE_LIB/components" "$FAKE_LIB/autotune" "$FAKE_LIB/diagnostics" \
  "$FAKE_LIB/providers/zapret" "$FAKE_LIB/providers/zapret2" "$FAKE_LIB/providers/byedpi"
cat >"$WORK_DIR/uci.state" <<'EOF'
prokop.settings=settings
prokop.settings.yacd_secret_key=0123456789abcdef
prokop.settings.dont_touch_dhcp=0
EOF
: >"$WORK_DIR/prokop.config"
printf 'config dnsmasq\n' >"$WORK_DIR/dhcp"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS REAL_LIB REAL_INITD FAKE_LIB
export RELOAD_LOCK="$WORK_DIR/run/prokop.reload.lock"
export SING_BOX_STATE="$WORK_DIR/singbox.state"
export NFT_TABLE_FILE="$WORK_DIR/nft.table"
export STOP_MARKER="$WORK_DIR/run/prokop/stop.requested"
export GATE="$WORK_DIR/gate"
export PROKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK"
export PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK_DIR/run/prokop/subscription-update.lock"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/prokop"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/prokop/reload.pending"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_CONFIG_FILE="$WORK_DIR/prokop.config"
export PROKOP_DNSMASQ_CONFIG_FILE="$WORK_DIR/dhcp"
export DNSMASQ_INIT="$WORK_DIR/bin/no-init"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export PROKOP_UI_ACTION_TRACKED=1
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export TMP_RULESET_FOLDER="$WORK_DIR/singbox-tmp/rulesets"
export PROKOP_SING_BOX_RELOAD_PID_TIMEOUT=2

# Nothing here may reach the host's syslog, firewall or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK_DIR/syslog" >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/no-init"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$1" != -t ] || shift
# Only the production table is modelled: no DPI guard of a failed transition
# or of a restore (ProkopTableDpiGuard, ProkopConfigRestoreDpiGuard).
if [ "$1 $2 $3" = "list table inet" ] && [ "$4" != ProkopTable ]; then
  exit 1
fi
if [ "$1 $2 $3" = "list table inet" ]; then
  [ -e "$NFT_TABLE_FILE" ]
  exit $?
fi
if [ "$1 $2 $3" = "delete table inet" ]; then
  rm -f "$NFT_TABLE_FILE"
fi
[ "$1 $2" != "list chain" ]
SH

# `prokop stop` behind initd.uc: tears the modelled runtime down.
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
case "$1" in
  stop)
    printf 'stopped\n' >"$SING_BOX_STATE"
    rm -f "$NFT_TABLE_FILE"
    printf 'stop end\n' >>"$EVENTS"
    ;;
  get_status) printf '{"running":false}\n' ;;
esac
exit 0
SH

# rc.common stand-in: sources the real init script and runs its handler.
cat >"$WORK_DIR/rc" <<'SH'
#!/bin/sh
action="$1"
shift
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
PROKOP_LIB="$REAL_LIB"
PROKOP_INITD_UC="$REAL_LIB/service/initd.uc"
case "$action" in
  stop) stop_service "$@" ;;
  *) exit 64 ;;
esac
SH

# init.d holds reload.lock around `prokop reload`; what init.d then finds
# (service/initd.uc reload_service) is recorded before the lock is released.
cat >"$WORK_DIR/reload" <<'SH'
#!/bin/sh
state() { ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" "$@"; }
state acquire-runtime-dir-lock "$PROKOP_RELOAD_LOCK_DIR" "$$" || exit 99
env PROKOP_LIB="$FAKE_LIB" ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" reload "$1"
status=$?
printf 'reload returned, sing-box %s\n' "$(cat "$SING_BOX_STATE")" >>"$EVENTS"
state release-runtime-dir-lock "$PROKOP_RELOAD_LOCK_DIR" "$$"
exit "$status"
SH

fake_header='let fs = require("fs");
function q(value) { return "'"'"'" + replace("" + value, /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'"; }
function ev(line) { system("printf '"'"'%s\\n'"'"' " + q(line) + " >> " + q(getenv("EVENTS"))); }
// The step armed by the test (HOLD_AT) waits for the gate once.
function hold(step) {
    if (getenv("HOLD_AT") != step || fs.stat(getenv("GATE") + ".armed") == null)
        return;
    fs.unlink(getenv("GATE") + ".armed");
    ev("held at " + step);
    for (let n = 0; fs.stat(getenv("GATE")) == null && n < 1200; n++)
        system("sleep 0.05");
}
function running() {
    return trim(fs.readfile(getenv("SING_BOX_STATE")) ?? "") == "running" && fs.stat(getenv("NFT_TABLE_FILE")) != null;
}
let mode = "" + (ARGV[0] ?? "");
'

cat >"$FAKE_LIB/service/state.uc" <<UC
$fake_header
if (index(mode, "runtime-dir-lock") >= 0 || mode == "runtime-apply-allowed" || mode == "stop-requested") {
    let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    exit(system(command));
}
if (mode == "prokop-running" || mode == "prokop-stably-running")
    exit(running() ? 0 : 1);
if (mode == "sing-box-process-conflict")
    exit(1);
if (mode == "stop-managed-sing-box-runtime") {
    ev("stop-managed");
    fs.writefile(getenv("SING_BOX_STATE"), "stopped\n");
    exit(0);
}
if (mode == "start-managed-sing-box-runtime") {
    ev("start-managed");
    fs.writefile(getenv("SING_BOX_STATE"), "running\n");
    exit(0);
}
if (mode == "wait-prokop-stable-start") {
    hold("wait-stable");
    ev("wait-stable " + (running() ? "ok" : "failed"));
    exit(running() ? 0 : 1);
}
if (mode == "sing-box-service-runtime-pid") {
    if (trim(fs.readfile(getenv("SING_BOX_STATE")) ?? "") == "running")
        print("4242\n");
    exit(0);
}
if (mode == "has-list-update-sources" || mode == "has-nft-list-update-sources")
    exit(1);
if (mode == "run-pending-reload-if-requested") {
    ev("pending reload drained");
    exit(0);
}
exit(0);
UC

# The reload plan comes from the test (PLAN: "key=value ...").
cat >"$FAKE_LIB/service/reload.uc" <<UC
$fake_header
if (mode != "plan-state-files")
    exit(0);
for (let item in split(trim(getenv("PLAN") ?? ""), " "))
    if (item != "")
        print(replace(item, "=", "\t"), "\n");
exit(0);
UC

cat >"$FAKE_LIB/service/ui.uc" <<UC
$fake_header
exit(0);
UC

cat >"$FAKE_LIB/config/validator.uc" <<UC
$fake_header
exit(0);
UC

cat >"$FAKE_LIB/config/snapshots.uc" <<UC
$fake_header
exit(0);
UC

cat >"$FAKE_LIB/diagnostics/health.uc" <<UC
$fake_header
ev("health " + join(" ", ARGV));
exit(0);
UC

cat >"$FAKE_LIB/subscription/cache.uc" <<UC
$fake_header
exit(mode == "runtime-cache-needs-rebuild" ? 1 : 0);
UC

cat >"$FAKE_LIB/singbox/runtime.uc" <<UC
$fake_header
if (getenv("FAIL_AT") == mode) {
    ev("singbox " + mode + " FAILED");
    exit(1);
}
// The live config was copied to the backup and then replacing it failed.
if (getenv("FAIL_AT") == "commit-after-backup" && mode == "commit-config-stage") {
    fs.writefile(ARGV[2], "backup\n");
    ev("singbox " + mode + " FAILED");
    exit(1);
}
if (mode == "commit-config-stage") {
    hold("commit-config-stage");
    if (("" + (ARGV[2] ?? "")) != "")
        fs.writefile(ARGV[2], "backup\n");
}
ev("singbox " + mode);
exit(0);
UC

cat >"$FAKE_LIB/nft/apply.uc" <<UC
$fake_header
if (mode == "nft-rebuild-runtime-from-uci")
    hold("nft-rebuild");
if (mode == "remove-dpi-transition-guard")
    hold("dpi-guard-removal");
if (getenv("FAIL_AT") == mode) {
    ev("nft " + mode + " FAILED");
    exit(1);
}
if (mode == "nft-apply-candidate-batch" || mode == "nft-commit-candidate-batch")
    fs.writefile(getenv("NFT_TABLE_FILE"), "ProkopTable\n");
ev("nft " + mode);
exit(0);
UC

cat >"$FAKE_LIB/dns/apply.uc" <<UC
$fake_header
ev("dns " + mode);
exit(0);
UC

for module in singbox/priority singbox/dns_failover components/updates autotune/manager \
  providers/zapret/runtime providers/zapret2/runtime providers/byedpi/runtime; do
  name="${module#*/}"
  case "$module" in providers/*) name="${module#providers/}"; name="${name%/runtime}" ;; esac
  cat >"$FAKE_LIB/$module.uc" <<UC
$fake_header
if (mode == "snapshot-runtime")
    hold("$name snapshot-runtime");
ev("$name " + mode);
exit(0);
UC
done
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc" "$WORK_DIR/reload"

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }

# Whether an event matching $1 follows the event $2.
event_after() {
  awk -v pattern="$1" -v anchor="$2" '
    $0 == anchor { seen = 1; next }
    seen && $0 ~ pattern { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$EVENTS"
}

reset_case() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  rm -f "$GATE" "$GATE.armed" "$STOP_MARKER" "$PROKOP_PENDING_RELOAD_FILE" "$WORK_DIR/holder.ready"
  [ ! -e "$RELOAD_LOCK" ] || fail "reload.lock leaked from the previous case"
  printf 'running\n' >"$SING_BOX_STATE"
  printf 'ProkopTable\n' >"$NFT_TABLE_FILE"
  : >"$GATE"
}

state() { ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" "$@"; }

# Another process (an init.d reload, a list update) holds reload.lock.
holder=""
hold_lock() {
  sh -c '
    ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" acquire-runtime-dir-lock "$PROKOP_RELOAD_LOCK_DIR" "$$" || exit 1
    : >"$1"
    exec sleep 60
  ' holder "$WORK_DIR/holder.ready" &
  holder=$!
  actors+=("$holder")
  wait_until 5 test -e "$WORK_DIR/holder.ready" || fail "the holder never took reload.lock"
}
drop_lock() {
  owned_kill KILL "$holder" || true
  wait "$holder" 2>/dev/null || true
  state release-runtime-dir-lock "$PROKOP_RELOAD_LOCK_DIR" "$holder" || true
  rm -rf "$RELOAD_LOCK"
}

# `prokop <mode>` as the dispatcher runs it, with no lock of its own.
# Leading NAME=value arguments go to its environment.
cli() {
  local envs=()
  while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
    envs+=("$1")
    shift
  done
  env PROKOP_LIB="$FAKE_LIB" "${envs[@]}" ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" "$@"
}

SINGBOX_PLAN="has_work=1 needs_sing_box_reload=1 changed_sing_box=1"

# 1. A command-line reload that never gets the lock changes nothing.
reset_case
hold_lock
status=0
cli PLAN="$SINGBOX_PLAN" PROKOP_CLI_RELOAD_LOCK_WAIT_SECONDS=2 reload "" >"$WORK_DIR/cli.out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "a command-line reload ran while another process held reload.lock"
grep -q 'reload refused: another start, stop, reload or update held the runtime lock' "$WORK_DIR/cli.out" ||
  fail "the refused reload does not say why: $(cat "$WORK_DIR/cli.out")"
! has_event 'stop-runtime\|stop-managed\|singbox \|nft ' || fail "the refused reload touched the runtime"
[ "$(state runtime-dir-lock-owner "$RELOAD_LOCK")" = "$holder" ] || fail "the refused reload took reload.lock from its holder"
drop_lock

# 2. So does a command-line start, and restart.
reset_case
hold_lock
for mode in start restart; do
  status=0
  cli PROKOP_CLI_RELOAD_LOCK_WAIT_SECONDS=1 "$mode" >"$WORK_DIR/cli.out" 2>&1 || status=$?
  [ "$status" != 0 ] || fail "a command-line $mode ran while another process held reload.lock"
  grep -q "$mode refused" "$WORK_DIR/cli.out" || fail "the refused $mode does not say why: $(cat "$WORK_DIR/cli.out")"
done
! has_event 'stop-runtime\|stop-managed\|start-managed\|singbox \|nft ' || fail "a refused start or restart touched the runtime"
drop_lock

# 3. A command-line reload with the lock free holds it for the whole
#    transition, so an init.d reload meanwhile is queued, not run beside it;
#    the queued reload runs once the lock is released.
reset_case
: >"$GATE.armed"
rm -f "$GATE"
cli PLAN="$SINGBOX_PLAN" HOLD_AT=commit-config-stage reload "" >"$WORK_DIR/cli.out" 2>&1 &
reload_pid=$!
actors+=("$reload_pid")
wait_until 10 has_event '^held at commit-config-stage$' || fail "the command-line reload never reached the commit"
owner="$(state runtime-dir-lock-owner "$RELOAD_LOCK" || true)"
[ -n "$owner" ] || fail "the command-line reload runs without reload.lock"
! state acquire-runtime-dir-lock "$RELOAD_LOCK" "$$" || fail "another process took reload.lock during a command-line reload"
printf 'reload\n' >"$PROKOP_PENDING_RELOAD_FILE"
: >"$GATE"
status=0
wait "$reload_pid" || status=$?
[ "$status" = 0 ] || fail "the command-line reload failed: $(cat "$WORK_DIR/cli.out")"
[ ! -e "$RELOAD_LOCK" ] || fail "the command-line reload did not release reload.lock"
has_event '^pending reload drained$' || fail "the reload queued behind the command-line reload was not run"

# 4. Under init.d the lock belongs to an ancestor: the lifecycle neither waits
#    for it nor releases it.
reset_case
env PLAN="$SINGBOX_PLAN" PROKOP_CLI_RELOAD_LOCK_WAIT_SECONDS=1 "$WORK_DIR/reload" "" >"$WORK_DIR/reload.out" 2>&1 ||
  fail "a reload under init.d's lock failed: $(cat "$WORK_DIR/reload.out")"
has_event '^singbox commit-config-stage$' || fail "a reload under init.d's lock did not run"
! has_event '^pending reload drained$' || fail "the lifecycle drained the queue of init.d's lock"

# 5. A command-line stop waits for the lock and then stops without it, as
#    init.d's stop does; the stop request makes the holder give way.
reset_case
hold_lock
status=0
cli PROKOP_CLI_RELOAD_LOCK_WAIT_SECONDS=1 stop >"$WORK_DIR/cli.out" 2>&1 || status=$?
[ -e "$STOP_MARKER" ] || fail "the command-line stop did not run without the lock: $(cat "$WORK_DIR/cli.out")"
grep -q 'stop did not get the runtime lock within 1 s; stopping without it' "$WORK_DIR/syslog" ||
  fail "the stop without the lock is not logged"
[ "$(state runtime-dir-lock-owner "$RELOAD_LOCK")" = "$holder" ] || fail "the stop released the holder's reload.lock"

# 6. A stop that init.d already let go without the lock does not wait again.
rm -f "$STOP_MARKER"
: >"$WORK_DIR/syslog"
cli PROKOP_RELOAD_LOCK_WAIVED=1 PROKOP_CLI_RELOAD_LOCK_WAIT_SECONDS=30 stop >"$WORK_DIR/cli.out" 2>&1 || true
[ -e "$STOP_MARKER" ] || fail "init.d's stop without the lock did not run"
! grep -q 'did not get the runtime lock' "$WORK_DIR/syslog" || fail "init.d's stop without the lock waited for it once more"
drop_lock

printf 'cli reload lock checks passed\n'
