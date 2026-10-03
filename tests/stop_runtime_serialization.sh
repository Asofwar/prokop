#!/usr/bin/env bash
set -euo pipefail

# An explicit stop against the work that holds reload.lock (UC-012).
#
# A forced subscription update holds reload.lock across its downloads and then
# stops, reconfigures and starts sing-box; `prokop dns_failover_apply`, the
# child of the DNS-failover worker, survives the TERM that stop sends to its
# worker and holds reload.lock around its own stop/patch/start of sing-box.
# A stop that neither waits for nor fences off these holders returns success,
# after which they bring sing-box and the auxiliary workers back.
#
# The stop is the real init.d stop_service and service/initd.uc; its backend
# stands in for `prokop stop` (tears down the modelled runtime). The update is
# the real components/updates.uc and the DNS-failover apply the real
# service/lifecycle.uc; their locks and the "may the runtime be started"
# predicate go through the real service/state.uc, sing-box and nft are
# modelled by files. Background reloads after a stop and the stop marker's
# lifetime are checked on the real lifecycle.uc.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
REAL_INITD="$ROOT_DIR/prokop/files/etc/init.d/prokop"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

actors=()
cleanup() {
  local pid
  for pid in "${actors[@]}"; do
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
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
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/prokop" "$WORK_DIR/tmp" "$WORK_DIR/singbox-tmp/rulesets" \
  "$WORK_DIR/fake-lib/service" "$WORK_DIR/fake-lib/subscription" "$WORK_DIR/fake-lib/config" \
  "$WORK_DIR/fake-lib/singbox"
cat >"$WORK_DIR/uci.state" <<'EOF'
prokop.settings=settings
prokop.settings.yacd_secret_key=0123456789abcdef
prokop.settings.dont_touch_dhcp=1
EOF
: >"$WORK_DIR/prokop.config"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS REAL_LIB REAL_INITD
export RELOAD_LOCK="$WORK_DIR/run/prokop.reload.lock"
export SING_BOX_STATE="$WORK_DIR/singbox.state"
export NFT_TABLE_FILE="$WORK_DIR/nft.table"
export NFT_LOG="$WORK_DIR/nft.log"
export STOP_MARKER="$WORK_DIR/run/prokop/stop.requested"
START_RECORD="$WORK_DIR/run/prokop/start.explicit"
export PROKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK"
export PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK_DIR/run/prokop/subscription-update.lock"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/prokop"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/prokop/reload.pending"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_CONFIG_FILE="$WORK_DIR/prokop.config"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export PROKOP_UI_ACTION_TRACKED=1
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export PROKOP_SING_BOX_RELOAD_PID_TIMEOUT=2

# Nothing here may reach the host's syslog, firewall or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK_DIR/syslog" >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/no-init"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
# The production table exists while the modelled runtime is up; listing it
# fails while nft.list-fails exists (a transient nft error).
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$NFT_LOG"
[ "$1" != -t ] || shift
# Only the production table is modelled: no DPI guard of a failed transition
# or of a restore (ProkopTableDpiGuard, ProkopConfigRestoreDpiGuard).
if [ "$1 $2 $3" = "list table inet" ] && [ "$4" != ProkopTable ]; then
  exit 1
fi
if [ "$1 $2 $3" = "list table inet" ]; then
  [ ! -e "$NFT_TABLE_FILE.list-fails" ] || exit 1
  [ -e "$NFT_TABLE_FILE" ]
  exit $?
fi
if [ "$1 $2 $3" = "delete table inet" ]; then
  rm -f "$NFT_TABLE_FILE"
fi
# No failed-transition guard chain in the modelled runtime.
[ "$1 $2" != "list chain" ]
SH

# `prokop stop` behind initd.uc: records whether it runs inside reload.lock,
# then tears the modelled runtime down.
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
ev() { printf '%s\n' "$1" >>"$EVENTS"; }
case "$1" in
  stop)
    owner="$(ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" runtime-dir-lock-owner "$RELOAD_LOCK" || true)"
    cmd=""
    [ -z "$owner" ] || cmd="$(tr '\0' ' ' <"/proc/$owner/cmdline" 2>/dev/null || true)"
    case "$cmd" in
      *"service/initd.uc stop-service"*) ev "stop begin (locked)" ;;
      *) ev "stop begin (unlocked)" ;;
    esac
    printf 'stopped\n' >"$SING_BOX_STATE"
    rm -f "$NFT_TABLE_FILE"
    ev "stop end"
    exit 0
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

fake_header='let fs = require("fs");
function q(value) { return "'"'"'" + replace("" + value, /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'"; }
function ev(line) { system("printf '"'"'%s\\n'"'"' " + q(line) + " >> " + q(getenv("EVENTS"))); }
function wait_gate(name) {
    let gate = getenv(name) || "";
    for (let n = 0; gate != "" && fs.stat(gate) == null && n < 600; n++)
        system("sleep 0.05");
}
let mode = "" + (ARGV[0] ?? "");
'

# Locks and the start predicate go to the real service/state.uc; sing-box is
# the state file. stop-managed can be held at a gate while its caller owns
# reload.lock.
cat >"$WORK_DIR/fake-lib/service/state.uc" <<UC
$fake_header
if (index(mode, "runtime-dir-lock") >= 0 || mode == "runtime-apply-allowed" || mode == "stop-requested") {
    let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    let status = system(command);
    if (mode == "runtime-apply-allowed")
        ev("runtime-apply-allowed rc=" + status);
    exit(status);
}
// Armed failures: a stop request can arrive while the step runs (it is then
// recorded before the step fails), and a stop-managed can leave nft listing
// broken for a while.
function armed(name) {
    let path = getenv("SING_BOX_STATE") + "." + name;
    if (fs.stat(path) == null)
        return false;
    fs.unlink(path);
    return true;
}
function stop_requested_meanwhile() {
    if (armed("stop-meanwhile"))
        fs.writefile(getenv("STOP_MARKER"), "stop\n");
}
if (mode == "stop-managed-sing-box-runtime") {
    ev("stop-managed");
    if (armed("nft-list-fails"))
        fs.writefile(getenv("NFT_TABLE_FILE") + ".list-fails", "1\n");
    if (armed("stop-fails")) {
        stop_requested_meanwhile();
        ev("stop-managed failed");
        exit(1);
    }
    if (fs.stat(getenv("SING_BOX_STATE") + ".gate-armed") != null) {
        fs.unlink(getenv("SING_BOX_STATE") + ".gate-armed");
        ev("stop-managed held");
        wait_gate("STOP_MANAGED_GATE");
    }
    fs.writefile(getenv("SING_BOX_STATE"), "stopped\n");
    exit(0);
}
if (mode == "start-managed-sing-box-runtime") {
    ev("start-managed");
    if (armed("start-fails")) {
        stop_requested_meanwhile();
        ev("start-managed failed");
        exit(1);
    }
    fs.writefile(getenv("SING_BOX_STATE"), "running\n");
    if (fs.stat(getenv("SING_BOX_STATE") + ".start-gate-armed") != null) {
        fs.unlink(getenv("SING_BOX_STATE") + ".start-gate-armed");
        ev("start-managed held");
        wait_gate("START_MANAGED_GATE");
    }
    exit(0);
}
if (mode == "prokop-running" || mode == "prokop-stably-running")
    exit(trim(fs.readfile(getenv("SING_BOX_STATE")) ?? "") == "running" && fs.stat(getenv("NFT_TABLE_FILE")) != null ? 0 : 1);
if (mode == "sing-box-process-conflict")
    exit(getenv("FAKE_CONFLICT") == "1" ? 0 : 1);
if (mode == "sing-box-service-running") {
    ev("state " + mode);
    exit(trim(fs.readfile(getenv("SING_BOX_STATE")) ?? "") == "running" ? 0 : 1);
}
// A queued reload is handed over only by a holder that let reload.lock go.
if (mode == "run-pending-reload-if-requested") {
    ev("state " + mode + (fs.stat(getenv("RELOAD_LOCK")) == null ? "" : " (reload.lock held)"));
    exit(0);
}
ev("state " + mode);
exit(0);
UC

cat >"$WORK_DIR/fake-lib/subscription/cache.uc" <<UC
$fake_header
if (mode == "update-request") {
    ev("update begin");
    wait_gate("UPDATE_GATE");
    ev("update end");
    print("1 0 0 0\n");
    exit(0);
}
exit(mode == "ensure-runtime-dirs" ? 0 : 64);
UC

cat >"$WORK_DIR/fake-lib/config/validator.uc" <<UC
$fake_header
exit(0);
UC

cat >"$WORK_DIR/fake-lib/singbox/runtime.uc" <<UC
$fake_header
ev("singbox " + mode);
if (mode == "commit-config-stage" && ("" + (ARGV[2] ?? "")) != "")
    fs.writefile(ARGV[2], "backup\n");
if (mode == "patch-dns-config" && fs.stat(getenv("SING_BOX_STATE") + ".patch-fails") != null) {
    fs.unlink(getenv("SING_BOX_STATE") + ".patch-fails");
    fs.writefile(getenv("STOP_MARKER"), "stop\n");
    ev("singbox patch-dns-config failed");
    exit(1);
}
if (mode == "patch-dns-config") {
    let backup = getenv("TMPDIR") + "/dns-backup.json";
    fs.writefile(backup, "{}\n");
    print("1\t" + backup + "\n");
}
exit(0);
UC

for module in priority dns_failover; do
  cat >"$WORK_DIR/fake-lib/singbox/$module.uc" <<UC
$fake_header
ev("$module " + mode);
exit(0);
UC
done
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }
no_event() { ! grep -q "$1" "$EVENTS" 2>/dev/null; }

before() {
  awk -v first="$1" -v second="$2" '
    $0 == first && !seen_second { seen_first = 1 }
    $0 == second { seen_second = 1 }
    END { exit seen_first && seen_second ? 0 : 1 }
  ' "$EVENTS"
}

# Actors run in their own process group under a hard deadline.
start_actor() {
  setsid timeout -s KILL 90 "$@" &
  LAST_ACTOR=$!
  actors+=("$LAST_ACTOR")
}

runtime_up() {
  printf 'running\n' >"$SING_BOX_STATE"
  printf 'ProkopTable\n' >"$NFT_TABLE_FILE"
}

runtime_down() {
  printf 'stopped\n' >"$SING_BOX_STATE"
  rm -f "$NFT_TABLE_FILE"
}

reset_case() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  rm -f "$WORK_DIR/update.gate" "$WORK_DIR/stop-managed.gate" "$WORK_DIR/start-managed.gate" \
    "$SING_BOX_STATE.gate-armed" "$SING_BOX_STATE.start-gate-armed" "$STOP_MARKER" "$START_RECORD" \
    "$SING_BOX_STATE".*-fails "$SING_BOX_STATE.stop-meanwhile" "$NFT_TABLE_FILE.list-fails" "$NFT_LOG"
  [ ! -e "$RELOAD_LOCK" ] || fail "reload.lock leaked from the previous case"
}

launch_update() {
  start_actor env PROKOP_LIB="$WORK_DIR/fake-lib" UPDATE_GATE="${UPDATE_GATE:-}" \
    STOP_MANAGED_GATE="${STOP_MANAGED_GATE:-}" START_MANAGED_GATE="${START_MANAGED_GATE:-}" \
    ucode -L "$REAL_LIB" "$REAL_LIB/components/updates.uc" subscription-update >"$WORK_DIR/update.out" 2>&1
  UPDATE_PID="$LAST_ACTOR"
}

launch_stop() {
  start_actor env PROKOP_BIN="$WORK_DIR/bin/prokop" PROKOP_LIB="$REAL_LIB" \
    PROKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS="${STOP_WAIT:-20}" sh "$WORK_DIR/rc" stop >"$WORK_DIR/stop.out" 2>&1
  STOP_PID="$LAST_ACTOR"
}

finish() {
  local label="$1" pid="$2" out="$3" status=0
  wait_until 40 process_gone "$pid" || fail "$label did not finish"
  wait "$pid" || status=$?
  [ "$status" = 0 ] || fail "$label failed with status $status: $(cat "$out")"
}

assert_stopped_for_good() {
  local label="$1"
  [ "$(cat "$SING_BOX_STATE")" = stopped ] || fail "$label: sing-box runs after a successful stop"
  [ ! -e "$NFT_TABLE_FILE" ] || fail "$label: the stopped runtime still has its nft table"
  no_event '^start-managed$' || fail "$label: sing-box was started after the stop request"
  no_event '^priority start-runtime$' || fail "$label: Priority was started after the stop request"
  no_event '^dns_failover start-runtime$' || fail "$label: DNS failover was started after the stop request"
  [ ! -e "$RELOAD_LOCK" ] || fail "$label: reload.lock was left behind"
  [ -e "$STOP_MARKER" ] || fail "$label: the explicit stop is not recorded for later work"
}

# 1. Stop while a forced subscription update holds reload.lock in its
#    download: the stop records itself, waits for the lock, and runs after
#    the update; the update sees the stop request and leaves sing-box down.
reset_case
runtime_up
UPDATE_GATE="$WORK_DIR/update.gate" launch_update
wait_until 10 has_event '^update begin$' || fail "update did not reach its download: $(cat "$WORK_DIR/update.out")"
[ -d "$RELOAD_LOCK" ] || fail "the update downloads without reload.lock"
STOP_WAIT=20 launch_stop
wait_until 10 file_nonempty "$STOP_MARKER" || fail "stop did not record the stop request before waiting: $(cat "$WORK_DIR/stop.out")"
# Let the stop poll reload.lock while the update holds it.
sleep 1
no_event '^stop begin' || fail "stop tore the runtime down while the update held reload.lock"
touch "$WORK_DIR/update.gate"
finish "subscription update" "$UPDATE_PID" "$WORK_DIR/update.out"
finish "stop" "$STOP_PID" "$WORK_DIR/stop.out"
before "update end" "stop begin (locked)" || fail "stop did not run inside reload.lock after the update"
no_event '^singbox configure-service$' || fail "the update reconfigured the sing-box service after the stop request"
no_event '^state mark-pending-reload$' || fail "the update queued a reload for a runtime that is being stopped"
assert_stopped_for_good "stop during subscription update"

# 1b. The stop request arrives after the update has decided to apply, while
#     it holds sing-box stopped for the new configuration: the update saves
#     the configuration but does not start sing-box again.
reset_case
runtime_up
: >"$SING_BOX_STATE.gate-armed"
UPDATE_GATE="" STOP_MANAGED_GATE="$WORK_DIR/stop-managed.gate" launch_update
wait_until 10 has_event '^stop-managed held$' || fail "update did not reach its sing-box stop: $(cat "$WORK_DIR/update.out")"
STOP_WAIT=20 launch_stop
wait_until 10 file_nonempty "$STOP_MARKER" || fail "stop did not record the stop request before waiting"
touch "$WORK_DIR/stop-managed.gate"
finish "subscription update" "$UPDATE_PID" "$WORK_DIR/update.out"
finish "stop" "$STOP_PID" "$WORK_DIR/stop.out"
has_event '^singbox commit-config-stage$' || fail "the update dropped the configuration it had prepared"
before "singbox commit-config-stage" "stop begin (locked)" || fail "stop did not wait for the update's transition"
assert_stopped_for_good "stop during the update's sing-box transition"

# 1c. The stop request arrives once the update has started the new sing-box:
#     its workers are not started for a runtime the stop tears down next.
reset_case
runtime_up
: >"$SING_BOX_STATE.start-gate-armed"
UPDATE_GATE="" START_MANAGED_GATE="$WORK_DIR/start-managed.gate" launch_update
wait_until 10 has_event '^start-managed held$' || fail "update did not reach its sing-box start: $(cat "$WORK_DIR/update.out")"
STOP_WAIT=20 launch_stop
wait_until 10 file_nonempty "$STOP_MARKER" || fail "stop did not record the stop request before waiting"
touch "$WORK_DIR/start-managed.gate"
finish "subscription update" "$UPDATE_PID" "$WORK_DIR/update.out"
finish "stop" "$STOP_PID" "$WORK_DIR/stop.out"
no_event '^priority start-runtime$' || fail "Priority was started for a runtime that is being stopped"
no_event '^dns_failover start-runtime$' || fail "DNS failover was started for a runtime that is being stopped"
before "start-managed" "stop begin (locked)" || fail "stop did not wait for the update's sing-box start"
[ "$(cat "$SING_BOX_STATE")" = stopped ] || fail "sing-box runs after a successful stop"

# 2. A stop that gives up waiting still stops (a download must not block
#    it), and the update that finishes afterwards does not start sing-box.
reset_case
runtime_up
UPDATE_GATE="$WORK_DIR/update.gate" launch_update
wait_until 10 has_event '^update begin$' || fail "update did not reach its download: $(cat "$WORK_DIR/update.out")"
STOP_WAIT=1 launch_stop
finish "stop after a lock timeout" "$STOP_PID" "$WORK_DIR/stop.out"
has_event '^stop begin (unlocked)$' || fail "stop did not proceed after its bounded wait"
grep -q 'stop did not get the runtime lock' "$WORK_DIR/syslog" ||
  fail "stop without reload.lock was not logged"
touch "$WORK_DIR/update.gate"
finish "subscription update after the stop" "$UPDATE_PID" "$WORK_DIR/update.out"
no_event '^state mark-pending-reload$' || fail "an update that outlived a stop queued a reload"
assert_stopped_for_good "update that outlived a stop"

# 3. A forced update while Prokop is not running at all (never started,
#    failed start) refreshes the cache only; it never starts a lone sing-box.
reset_case
runtime_down
UPDATE_GATE="" launch_update
finish "subscription update while stopped" "$UPDATE_PID" "$WORK_DIR/update.out"
has_event '^update end$' || fail "the update did not refresh the subscription cache"
no_event '^start-managed$' || fail "an update started sing-box for a stopped Prokop"
no_event '^singbox configure-service$' || fail "an update reconfigured the sing-box service for a stopped Prokop"
no_event '^priority start-runtime$' || fail "an update started Priority for a stopped Prokop"
no_event '^state mark-pending-reload$' || fail "an update queued a reload that would start a stopped Prokop"
[ "$(cat "$SING_BOX_STATE")" = stopped ] || fail "an update left sing-box running for a stopped Prokop"

# 3b. A running Prokop whose table check fails (a transient nft error) when
#     the update decides whether to apply: the committed cache is not
#     silently left unapplied (the next scheduled update finds nothing new);
#     a reload is queued for when the update releases its locks. The update
#     itself does not touch sing-box.
reset_case
runtime_up
: >"$NFT_TABLE_FILE.list-fails"
UPDATE_GATE="" launch_update
finish "subscription update with a failing table check" "$UPDATE_PID" "$WORK_DIR/update.out"
has_event '^state mark-pending-reload$' || fail "an update that could not check the runtime left its cache unapplied"
before "state mark-pending-reload" "state run-pending-reload-if-requested" ||
  fail "the queued reload was not handed over after the update"
no_event '^stop-managed$' || fail "an update that could not check the runtime changed sing-box"
grep -q 'runtime could not be checked' "$WORK_DIR/syslog" || fail "the unapplied update was not logged"
rm -f "$NFT_TABLE_FILE.list-fails"

# 4. Control: a running Prokop still gets the new configuration applied.
reset_case
runtime_up
UPDATE_GATE="" launch_update
finish "subscription update while running" "$UPDATE_PID" "$WORK_DIR/update.out"
before "stop-managed" "start-managed" || fail "a running Prokop did not get the updated sing-box"
has_event '^dns_failover start-runtime$' || fail "a running Prokop lost its DNS failover worker"
[ "$(cat "$SING_BOX_STATE")" = running ] || fail "the update left a running Prokop without sing-box"

# 4b. A stop requested while the update's new sing-box fails to start: the
#     rollback to the previous configuration does not start sing-box either.
reset_case
runtime_up
: >"$SING_BOX_STATE.start-fails"
: >"$SING_BOX_STATE.stop-meanwhile"
UPDATE_GATE="" launch_update
wait_until 40 process_gone "$UPDATE_PID" || fail "subscription update did not finish"
has_event '^start-managed failed$' || fail "the modelled sing-box start did not fail"
has_event '^singbox restore-config-stage$' || fail "the failed update did not restore the previous configuration"
[ "$(grep -c '^start-managed$' "$EVENTS")" = 1 ] || fail "the rollback started sing-box after the stop request"
no_event '^priority start-runtime$' || fail "the rollback started Priority after the stop request"
no_event '^dns_failover start-runtime$' || fail "the rollback started DNS failover after the stop request"

# 4c. A stop requested while the previous sing-box refuses to stop: the
#     update's auxiliary workers are not started again.
reset_case
runtime_up
: >"$SING_BOX_STATE.stop-fails"
: >"$SING_BOX_STATE.stop-meanwhile"
UPDATE_GATE="" launch_update
wait_until 40 process_gone "$UPDATE_PID" || fail "subscription update did not finish"
has_event '^stop-managed failed$' || fail "the modelled sing-box stop did not fail"
no_event '^priority start-runtime$' || fail "a refused update started Priority after the stop request"
no_event '^dns_failover start-runtime$' || fail "a refused update started DNS failover after the stop request"

# 4d. Once the update has checked Prokop and holds sing-box stopped under
#     reload.lock, only a stop request keeps sing-box down: a transient nft
#     listing failure does not leave the dataplane without sing-box. The
#     table check itself omits the (possibly huge) set contents.
reset_case
runtime_up
: >"$SING_BOX_STATE.nft-list-fails"
UPDATE_GATE="" launch_update
finish "subscription update with a transient nft error" "$UPDATE_PID" "$WORK_DIR/update.out"
has_event '^start-managed$' || fail "a transient nft error left sing-box stopped after the update"
has_event '^dns_failover start-runtime$' || fail "a transient nft error left the update without DNS failover"
[ "$(cat "$SING_BOX_STATE")" = running ] || fail "the update left a running Prokop without sing-box"
grep -q '^-t list table inet ' "$NFT_LOG" || fail "the runtime check lists the table with its set contents"
if grep -q '^list table inet ' "$NFT_LOG"; then
  fail "the runtime check lists the table with its set contents: $(cat "$NFT_LOG")"
fi

# 5. Stop while `prokop dns_failover_apply` (whose worker a stop TERMs,
#    leaving the apply itself alive) holds reload.lock between stopping and
#    starting sing-box: the apply does not start sing-box after the stop.
reset_case
runtime_up
printf '{}\n' >"$WORK_DIR/candidate.json"
: >"$SING_BOX_STATE.gate-armed"
start_actor env PROKOP_LIB="$WORK_DIR/fake-lib" STOP_MANAGED_GATE="$WORK_DIR/stop-managed.gate" \
  ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" dns-failover-apply "$WORK_DIR/candidate.json" >"$WORK_DIR/apply.out" 2>&1
APPLY_PID="$LAST_ACTOR"
wait_until 10 has_event '^stop-managed held$' || fail "DNS failover apply did not reach its sing-box stop: $(cat "$WORK_DIR/apply.out")"
[ -d "$RELOAD_LOCK" ] || fail "DNS failover apply changes sing-box without reload.lock"
STOP_WAIT=20 launch_stop
wait_until 10 file_nonempty "$STOP_MARKER" || fail "stop did not record the stop request before waiting"
touch "$WORK_DIR/stop-managed.gate"
wait_until 40 process_gone "$APPLY_PID" || fail "DNS failover apply did not finish"
finish "stop during DNS failover apply" "$STOP_PID" "$WORK_DIR/stop.out"
has_event '^stop begin (locked)$' || fail "stop did not run inside reload.lock after the DNS failover apply"
has_event '^singbox restore-dns-config$' || fail "the abandoned DNS failover apply kept its patched configuration"
no_event '^dns_failover commit-state$' || fail "an abandoned DNS failover apply committed its state"
assert_stopped_for_good "stop during DNS failover apply"

# 5b. An apply that gets reload.lock only after the stop (whose wait timed
#     out) does not touch sing-box or its configuration at all.
reset_case
runtime_down
printf '1\n' >"$STOP_MARKER"
status=0
env PROKOP_LIB="$WORK_DIR/fake-lib" \
  ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" dns-failover-apply "$WORK_DIR/candidate.json" >"$WORK_DIR/apply.out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "a DNS failover switch after a stop was reported as applied"
no_event '^stop-managed$' || fail "a DNS failover apply after a stop stopped sing-box"
no_event '^singbox patch-dns-config$' || fail "a DNS failover apply after a stop patched the sing-box configuration"
no_event '^start-managed$' || fail "a DNS failover apply after a stop started sing-box"
[ ! -e "$RELOAD_LOCK" ] || fail "a skipped DNS failover apply left reload.lock behind"

# 5c. A stop requested while the apply patches the configuration, and the
#     patch fails: sing-box is not started again.
reset_case
runtime_up
: >"$SING_BOX_STATE.patch-fails"
status=0
env PROKOP_LIB="$WORK_DIR/fake-lib" \
  ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" dns-failover-apply "$WORK_DIR/candidate.json" >"$WORK_DIR/apply.out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "a failed DNS failover patch was reported as applied"
has_event '^singbox patch-dns-config failed$' || fail "the modelled patch did not fail"
no_event '^start-managed$' || fail "a failed DNS failover patch started sing-box after the stop request"
[ ! -e "$RELOAD_LOCK" ] || fail "a failed DNS failover patch left reload.lock behind"

# 5d. A reload queued behind the apply (init.d found reload.lock held) is
#     applied once the apply lets the lock go: no other holder is left to
#     apply it, and a UI reload job that init.d queued behind the apply has
#     ended by then (UC-061).
reset_case
runtime_up
printf 'reason=on_config_change\n' >"$PROKOP_PENDING_RELOAD_FILE"
status=0
env PROKOP_LIB="$WORK_DIR/fake-lib" \
  ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" dns-failover-apply "$WORK_DIR/candidate.json" >"$WORK_DIR/apply.out" 2>&1 || status=$?
rm -f "$PROKOP_PENDING_RELOAD_FILE"
[ "$status" = 0 ] || fail "a DNS failover switch with a queued reload failed: $(cat "$WORK_DIR/apply.out")"
has_event '^state run-pending-reload-if-requested$' ||
  fail "the reload queued behind the DNS failover apply was not applied after it"
[ ! -e "$RELOAD_LOCK" ] || fail "a DNS failover apply left reload.lock behind"

# 6. A reload after an explicit stop does not bring the runtime back, whoever
#    requests it: background work (the list worker's final apply, the
#    rule-set refresh, a queued request, the deferred subscription recovery),
#    a manual reload, a snapshot restore, an autotune apply (D-15, UC-056).
run_reload() {
  env PROKOP_LIB="$WORK_DIR/fake-lib" FAKE_CONFLICT="${FAKE_CONFLICT:-}" \
    ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" reload "$1" >"$WORK_DIR/reload.out" 2>&1
}
for reason in list-content ruleset-cache pending subscription_deferred_recovery on_config_change badwan_interface_up \
  "" config-restore autotune; do
  reset_case
  runtime_down
  printf '1\n' >"$STOP_MARKER"
  run_reload "$reason" || fail "reload '$reason' after a stop failed: $(cat "$WORK_DIR/reload.out")"
  [ ! -s "$EVENTS" ] || fail "reload '$reason' touched the stopped runtime"
  grep -q "Reload '$reason' skipped" "$WORK_DIR/syslog" || fail "skipped reload '$reason' was not logged"
  [ -e "$STOP_MARKER" ] || fail "reload '$reason' ended the explicit stop"
done
# procd's reload for a monitored interface other than wan coming up is such
# a background reload too, not a manual one.
printf '{"settings":{"enable_badwan_interface_monitoring":"1","badwan_monitored_interfaces":"wan vpn0"}}\n' \
  >"$WORK_DIR/trigger-settings.json"
ucode -L "$REAL_LIB" "$REAL_LIB/service/initd.uc" trigger-plan-fixture "$WORK_DIR/trigger-settings.json" \
  >"$WORK_DIR/trigger-plan" || fail "the procd trigger plan could not be built"
grep -q "^interface	interface\.\*\.up	vpn0	.*	reload	badwan_interface_up\$" "$WORK_DIR/trigger-plan" ||
  fail "the reload for a monitored interface coming up is not marked as a background reload: $(cat "$WORK_DIR/trigger-plan")"
# Nor does a reload start a runtime that nobody started since boot: no stop,
# and no explicit start is recorded (D-15(a); tests/reboot_not_started.sh).
for reason in list-content ""; do
  reset_case
  runtime_down
  run_reload "$reason" || fail "reload '$reason' of a Prokop not started failed: $(cat "$WORK_DIR/reload.out")"
  [ ! -s "$EVENTS" ] || fail "reload '$reason' touched the runtime of a Prokop not started"
  grep -q "Reload '$reason' skipped: Prokop was not started" "$WORK_DIR/syslog" ||
    fail "skipped reload '$reason' of a Prokop not started was not logged"
done
# After an explicit start and without a stop the gate stays open, for a
# background and a manual reload alike (the refused ownership check stands
# in for the rest of the reload): a runtime that went down after the start is
# left to the reload to repair.
for reason in list-content ""; do
  reset_case
  runtime_down
  : >"$START_RECORD"
  FAKE_CONFLICT=1 run_reload "$reason" && fail "reload '$reason' without a stop request skipped the runtime checks"
  grep -q 'Reload refused' "$WORK_DIR/syslog" || fail "reload '$reason' without a stop request did not reach the runtime"
done
# A reload that restarts a runtime that is down without a stop does not
# record a stop either (the modelled start fails early; the attempt counts).
reset_case
runtime_down
: >"$START_RECORD"
run_reload "" || true
grep -q 'restarting Prokop runtime' "$WORK_DIR/syslog" || fail "a reload did not repair a runtime that is down without a stop"
[ ! -e "$STOP_MARKER" ] || fail "a reload that repaired the runtime recorded an explicit stop"

# 7. `prokop stop` records the explicit stop and ends the explicit start; a
#    start clears the stop and records itself, also when it fails (only a
#    stop, not a failure, keeps the runtime down).
reset_case
runtime_up
: >"$START_RECORD"
env PROKOP_LIB="$WORK_DIR/fake-lib" ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" stop >"$WORK_DIR/lifecycle.out" 2>&1 || true
[ -e "$STOP_MARKER" ] || fail "prokop stop did not record the explicit stop"
[ ! -e "$START_RECORD" ] || fail "prokop stop kept the explicit start"
env PROKOP_LIB="$WORK_DIR/fake-lib" ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" start >"$WORK_DIR/lifecycle.out" 2>&1 || true
[ ! -e "$STOP_MARKER" ] || fail "prokop start did not clear the explicit stop"
[ -e "$START_RECORD" ] || fail "prokop start did not record the explicit start"
# A start that finds the runtime already running (a stop that failed and kept
# it) does not start it again, and still ends the explicit stop.
reset_case
runtime_up
printf '1\n' >"$STOP_MARKER"
env PROKOP_LIB="$WORK_DIR/fake-lib" ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" start >"$WORK_DIR/lifecycle.out" 2>&1 ||
  fail "a duplicate start of a running runtime failed: $(cat "$WORK_DIR/lifecycle.out")"
grep -q 'already stably running' "$WORK_DIR/syslog" || fail "the running runtime was not recognised by the start"
[ ! -e "$STOP_MARKER" ] || fail "a start of an already running runtime kept the explicit stop"

printf 'stop runtime serialization checks passed\n'
