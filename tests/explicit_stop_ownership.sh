#!/usr/bin/env bash
set -euo pipefail

# An explicit Stop ends Prokop's interception and stops the sing-box that
# Prokop owns, and no other process (UC-194, UC-213, UC-215, UC-216, UC-217,
# UC-229).
#
# Before (1.0.28, e6c31a4d): an explicit Stop or Restart sent TERM and KILL to
# every process whose executable is named sing-box, a user's own sing-box
# included, after deleting procd's 'sing-box' service, and failed when that
# service was not registered, which it is not after any stop of it. So
# stopping a stopped Prokop failed, a restart of a stopped Prokop never
# reached its start (init.d now exits on a failed stop) and recorded a stop
# by the user, Full uninstall of a stopped Prokop failed at its stop phase,
# and a stray Prokop runtime outside procd was not stopped at all. A refused
# package stop restored DNS away from the runtime it left serving traffic,
# and a leftover upgrade marker turned the user's Stop into a refusal.
#
# Now an explicit Stop removes Prokop's nft table, ip rules and DNS, and
# signals only processes proven to be Prokop's: procd's 'sing-box' instance,
# the process recorded for a managed upgrade, a sing-box that runs Prokop's
# own configuration file. Each signal re-checks the process identity
# (core/process_identity.uc) right before it is sent. An unregistered service
# is a stopped one. Other sing-box processes are reported, not signalled. A
# refused internal stop changes nothing: not DNS, not the stop request. A
# stale upgrade marker does not make the user's Stop an internal one.
#
# init.d, service/initd.uc, service/lifecycle.uc and the sing-box process
# handling of service/state.uc are real, with procd's 'sing-box' service
# modelled by a ubus stand-in; nft, ip, DNS and the other modules the stop
# calls are modelled and record what they are asked to do. A modelled
# state.uc mode that this test does not know fails loudly (UC-229).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The stop must neither see nor signal sing-box processes of the host or of
# tests running in parallel: run in a private PID namespace with its own
# /proc where available; without one, a foreign sing-box is a failed
# precondition.
if [ "${PROKOP_EXPLICIT_STOP_ISOLATED:-}" != 1 ]; then
  if unshare --pid --fork --mount-proc true 2>/dev/null; then
    PROKOP_EXPLICIT_STOP_ISOLATED=1 exec unshare --pid --fork --mount-proc bash "$0" "$@"
  elif unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
    PROKOP_EXPLICIT_STOP_ISOLATED=1 exec unshare --user --map-root-user --pid --fork --mount-proc bash "$0" "$@"
  fi
  for exe in /proc/[0-9]*/exe; do
    case "$(readlink "$exe" 2>/dev/null)" in
      */sing-box | */'sing-box (deleted)')
        printf 'FAIL: precondition: a sing-box process (%s) is running and no private PID namespace is available\n' "${exe%/exe}" >&2
        exit 1
        ;;
    esac
  done
fi

REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
REAL_INITD="$ROOT_DIR/prokop/files/etc/init.d/prokop"
STATE_UC="$REAL_LIB/service/state.uc"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

doubles=()
cleanup() {
  owned_kill KILL "${doubles[@]}" || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
SYSLOG="$WORK_DIR/syslog"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  [ ! -s "$SYSLOG" ] || sed 's/^/  syslog: /' "$SYSLOG" >&2
  exit 1
}

LIB="$WORK_DIR/lib"
STATE_DIR="$WORK_DIR/run/prokop"
CONFIG_PATH="$WORK_DIR/etc/sing-box/config.json"
mkdir -p "$WORK_DIR/bin" "$STATE_DIR" "$WORK_DIR/tmp" "$WORK_DIR/singbox-tmp/rulesets" "$WORK_DIR/procd" \
  "$WORK_DIR/ui-state" "$LIB/service" "$LIB/config" "$LIB/singbox" "$LIB/subscription" "$LIB/dns" "$LIB/nft" \
  "$(dirname "$CONFIG_PATH")"
ln -s "$REAL_LIB/core" "$LIB/core"
ln -s "$REAL_LIB/service/lifecycle.uc" "$LIB/service/lifecycle.uc"

cat >"$WORK_DIR/uci.state" <<EOF
prokop.settings=settings
prokop.settings.yacd_secret_key=0123456789abcdef
prokop.settings.dont_touch_dhcp=0
prokop.settings.config_path=$CONFIG_PATH
EOF
: >"$WORK_DIR/prokop.config"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS SYSLOG REAL_LIB REAL_INITD LIB
export PROCD="$WORK_DIR/procd"
export NFT_TABLE_FILE="$WORK_DIR/nft.table"
export IP_RULE_FILE="$WORK_DIR/ip.rule"
export PROKOP_LIB="$LIB"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_SERVICE_NAME=prokop
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/prokop.reload.lock"
export PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$STATE_DIR/subscription-update.lock"
export PROKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export PROKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export PROKOP_LIST_UPDATE_PID_FILE="$STATE_DIR/list-update.pid"
export PROKOP_START_IN_PROGRESS_FILE="$STATE_DIR/start.in-progress"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_CONFIG_FILE="$WORK_DIR/prokop.config"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export PROKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export PROKOP_UI_SERVICE_ACTION_DIR="$WORK_DIR/ui-state/service-actions"
export PROKOP_UI_SERVICE_ACTION_LOCK_DIR="$WORK_DIR/ui-state/service-actions.lock"
export PROKOP_UI_ACTION_TRACKED=1
export OWNED_PROCESSES="$ROOT_DIR/tests/helpers/owned_processes.sh"
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export TMP_RULESET_FOLDER="$WORK_DIR/singbox-tmp/rulesets"
export PROKOP_SING_BOX_RELOAD_PID_TIMEOUT=2
export PROKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS=2
# Prokop's sing-box executable (/usr/bin/sing-box on the router).
export PROKOP_SING_BOX_BIN="$WORK_DIR/stray-bin/sing-box"
STOP_MARKER="$STATE_DIR/stop.requested"
START_RECORD="$STATE_DIR/start.explicit"
MARKER="$PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER"

# Nothing here may reach the host's syslog, firewall, routing or procd.
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSLOG"
SH
cat >"$WORK_DIR/bin/ip" <<'SH'
#!/bin/sh
case "$*" in
  *" rule del "*) printf 'ip %s\n' "$*" >>"$EVENTS"; rm -f "$IP_RULE_FILE" ;;
esac
exit 0
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$1" != -t ] || shift
if [ "$1 $2 $3" = "list table inet" ]; then
  [ "$4" = ProkopTable ] && [ -e "$NFT_TABLE_FILE" ]
  exit $?
fi
if [ "$1 $2 $3" = "delete table inet" ]; then
  printf 'nft %s\n' "$*" >>"$EVENTS"
  rm -f "$NFT_TABLE_FILE"
fi
exit 0
SH
# procd's 'sing-box' service: registered while $PROCD/registered exists,
# which names its running instance. Like procd, `service list` with a name
# answers {} for a service it does not know, and `service delete` of one
# fails with NOT_FOUND; deleting a registered service stops its instance.
cat >"$WORK_DIR/bin/ubus" <<'SH'
#!/bin/sh
printf 'ubus %s\n' "$*" >>"$EVENTS"
[ "$1 $2" = "call service" ] || exit 1
case "$3" in
  list)
    if [ ! -f "$PROCD/registered" ]; then
      printf '{}\n'
    else
      pid="$(cat "$PROCD/registered")"
      if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        printf '{"sing-box":{"instances":{"instance1":{"running":true,"pid":%s}}}}\n' "$pid"
      else
        printf '{"sing-box":{"instances":{}}}\n'
      fi
    fi
    exit 0
    ;;
  delete)
    if [ -f "$PROCD/registered" ]; then
      pid="$(cat "$PROCD/registered")"
      rm -f "$PROCD/registered"
      # procd signals the instance it runs, never a process that took the
      # PID of an instance that has exited (UC-233).
      OWNED_PROCESSES_KEEP_MARK=1 . "$OWNED_PROCESSES"
      [ -z "$pid" ] || owned_kill TERM "$pid" || :
      exit 0
    fi
    echo 'Command failed: Not found' >&2
    exit 4
    ;;
esac
exit 1
SH
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
printf 'init %s\n' "$*" >>"$EVENTS"
exit 0
SH
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
case "$1" in
  stop)
    ucode -L "$LIB" "$LIB/service/lifecycle.uc" stop >>"$EVENTS" 2>&1
    rc=$?
    printf 'prokop stop exit=%s\n' "$rc" >>"$EVENTS"
    exit "$rc"
    ;;
  get_status) printf '{"running":0}\n' ;;
esac
exit 0
SH

fake_header='let fs = require("fs");
function q(value) { return "'"'"'" + replace("" + value, /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'"; }
function ev(line) { system("printf '"'"'%s\\n'"'"' " + q(line) + " >> " + q(getenv("EVENTS"))); }
let mode = "" + (ARGV[0] ?? "");
'
# service/state.uc: locks, the stop request and everything about sing-box
# processes and the upgrade marker are the real module's; the reload state
# is recorded. Any other mode is a mode this test does not model: it fails
# instead of passing silently.
cat >"$LIB/service/state.uc" <<UC
$fake_header
if (index(mode, "runtime-dir-lock") >= 0 || mode == "runtime-apply-allowed" || mode == "stop-requested" ||
    index(mode, "sing-box") >= 0 || index(mode, "managed-upgrade") >= 0) {
    let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    let status = system(command);
    if (index(mode, "stop") >= 0 && index(mode, "sing-box") >= 0)
        ev("state " + mode + " -> " + status);
    exit(status);
}
if (mode == "clear-reload-state") {
    ev("state " + mode);
    exit(0);
}
ev("unmodelled state mode " + mode);
exit(97);
UC
cat >"$LIB/dns/apply.uc" <<UC
$fake_header
ev("dns " + mode);
exit(0);
UC
# The fwmark rule at priority 105 is present while \$IP_RULE_FILE exists.
cat >"$LIB/nft/apply.uc" <<UC
$fake_header
if (mode == "tproxy-marking-rule4-present")
    exit(fs.stat(getenv("IP_RULE_FILE")) != null ? 0 : 1);
exit(mode == "remove-dpi-transition-guard" ? 0 : 1);
UC
mkdir -p "$LIB/components" "$LIB/autotune" "$LIB/providers/zapret" "$LIB/providers/zapret2" "$LIB/providers/byedpi"
for module in config/validator service/reload subscription/cache singbox/priority singbox/dns_failover \
  components/updates autotune/manager providers/zapret/runtime providers/zapret2/runtime providers/byedpi/runtime; do
  printf '%s\nexit(mode == "runtime-list-cache-active" ? 1 : 0);\n' "$fake_header" >"$LIB/$module.uc"
done

# /etc/init.d/prokop as rc.common runs it: restart() is stop() and then
# start() unless the script defines its own; for a procd script stop() is
# stop_service and then procd_kill.
cat >"$WORK_DIR/rc" <<'SH'
#!/usr/bin/env bash
action="$1"
shift
initscript="$REAL_INITD"
restart() {
  trap '' TERM
  stop "$@"
  trap - TERM
  start "$@"
}
# shellcheck disable=SC1090
. "$REAL_INITD"
PROKOP_LIB="$LIB"
PROKOP_INITD_UC="$REAL_LIB/service/initd.uc"
stop() {
  stop_service "$@"
  echo 'procd_kill prokop' >>"$EVENTS"
}
start() {
  echo 'start reached' >>"$EVENTS"
}
case "$action" in
  stop | restart) "$action" "$@" ;;
  disable) ;;
  *) exit 64 ;;
esac
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

# sing-box doubles. A copy of sleep, for a process whose command line does
# not matter (procd's instance is known by its PID). A copy of bash named
# sing-box, for one with a sing-box command line: `sing-box run -c <config>`
# runs the script ./run, which blocks on a FIFO without a child process, and
# ignores TERM when IGNORE_TERM=1.
mkdir -p "$WORK_DIR/procd-bin" "$WORK_DIR/stray-bin" "$WORK_DIR/foreign-bin" "$WORK_DIR/doubles"
cp "$(command -v sleep)" "$WORK_DIR/procd-bin/sing-box"
cp "$(command -v bash)" "$WORK_DIR/stray-bin/sing-box"
cp "$(command -v bash)" "$WORK_DIR/foreign-bin/sing-box"
mkfifo "$WORK_DIR/doubles/block"
cat >"$WORK_DIR/doubles/run" <<'SH'
[ "${IGNORE_TERM:-}" != 1 ] || trap '' TERM
read -r _ <"$BLOCK_FIFO"
SH
export BLOCK_FIFO="$WORK_DIR/doubles/block"

LAST_DOUBLE=''
start_double() { # start_double <sing-box binary> [arguments...]
  (cd "$WORK_DIR/doubles" && exec "$@") &
  LAST_DOUBLE=$!
  # The stop kills doubles: no job notices for them.
  disown "$LAST_DOUBLE"
  doubles+=("$LAST_DOUBLE")
  wait_until 10 process_exec_is "$LAST_DOUBLE" sing-box || fail "a sing-box double did not start"
}
term_ignored() { # SigIgn of /proc/<pid>/status has bit 15 (TERM)
  local mask
  mask="$(sed -n 's/^SigIgn:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null)"
  [ -n "$mask" ] && [ $((0x$mask & 0x4000)) -ne 0 ]
}
procd_instance() { # Prokop's runtime: procd's 'sing-box' instance
  start_double "$WORK_DIR/procd-bin/sing-box" 300
  printf '%s\n' "$LAST_DOUBLE" >"$PROCD/registered"
}
foreign_sing_box() { # another program's sing-box, e.g. HomeProxy's
  start_double "$WORK_DIR/foreign-bin/sing-box" run -c "$WORK_DIR/homeproxy/config.json"
}
stray_runtime() { # Prokop's own configuration, outside procd [ignore TERM]
  IGNORE_TERM="${1:-}" start_double "$WORK_DIR/stray-bin/sing-box" run -c "$CONFIG_PATH" -D /usr/share/sing-box
}
alive() { process_running "$1"; }
gone() { process_gone "$1"; }
has_event() { grep -q -- "$1" "$EVENTS" 2>/dev/null; }
no_event() { ! grep -q -- "$1" "$EVENTS" 2>/dev/null; }

runtime_up() { # Prokop's interception: its nft table and its ip rule
  printf 'ProkopTable\n' >"$NFT_TABLE_FILE"
  printf '105\n' >"$IP_RULE_FILE"
}

double_gone() { ! owned_process "$1"; }
reset_case() {
  local pid
  owned_kill KILL "${doubles[@]}" || true
  for pid in "${doubles[@]}"; do
    wait_until 10 double_gone "$pid" || fail "a sing-box double of the previous case did not exit"
  done
  doubles=()
  : >"$EVENTS"
  : >"$SYSLOG"
  rm -f "$PROCD/registered" "$NFT_TABLE_FILE" "$IP_RULE_FILE" "$STOP_MARKER" "$START_RECORD" "$MARKER"
  printf 'explicit\n' >"$START_RECORD"
  [ ! -e "$PROKOP_RELOAD_LOCK_DIR" ] || fail "reload.lock leaked from the previous case"
}

rc() { # rc <action> [PROKOP_STOP_SOURCE [NAME=value...]]: status of /etc/init.d/prokop <action>
  local rc=0 action="$1" source="${2:-}"
  shift
  [ "$#" -eq 0 ] || shift
  env ${source:+PROKOP_STOP_SOURCE="$source"} "$@" bash "$WORK_DIR/rc" "$action" >>"$EVENTS" 2>&1 || rc=$?
  no_event '^unmodelled state mode' || fail "the stop asked service/state.uc for a mode this test does not model"
  printf '%s\n' "$rc"
}

# 1. Prokop is stopped: nothing runs and procd knows no 'sing-box' service.
#    Stopping it again succeeds, and a restart reaches its start.
reset_case
[ "$(rc stop)" = 0 ] || fail "stopping a stopped Prokop failed"
no_event 'dns failsafe-restore' || fail "stopping a stopped Prokop applied the DNS failsafe"
reset_case
[ "$(rc restart)" = 0 ] || fail "a restart of a stopped Prokop failed in its stop"
has_event '^start reached$' || fail "a restart of a stopped Prokop did not reach its start"

# 2. Prokop's procd instance and another program's sing-box: Prokop's
#    interception and runtime go, the other sing-box stays and is reported.
reset_case
runtime_up
procd_instance
prokop_pid=$LAST_DOUBLE
foreign_sing_box
foreign_pid=$LAST_DOUBLE
[ "$(rc stop)" = 0 ] || fail "an explicit stop next to another program's sing-box failed"
wait_until 10 gone "$prokop_pid" || fail "an explicit stop left Prokop's procd-owned sing-box running"
alive "$foreign_pid" || fail "an explicit stop signalled a sing-box that Prokop does not own"
[ ! -e "$NFT_TABLE_FILE" ] || fail "an explicit stop left ProkopTable"
[ ! -e "$IP_RULE_FILE" ] || fail "an explicit stop left the ip rule at priority 105"
has_event '^dns restore' || fail "an explicit stop did not restore DNS"
grep -q "pid=$foreign_pid" "$SYSLOG" || fail "the sing-box left running is not reported with its pid"
grep -q "$WORK_DIR/homeproxy/config.json" "$SYSLOG" || fail "the sing-box left running is not reported with its command line"

# 3. A stray Prokop runtime outside procd (no service registered) that
#    ignores TERM: it runs Prokop's configuration, so it is Prokop's and an
#    explicit stop ends it, escalating to KILL. Another program's sing-box
#    stays.
reset_case
runtime_up
stray_runtime 1
stray_pid=$LAST_DOUBLE
wait_until 10 term_ignored "$stray_pid" || fail "the stray double does not ignore TERM"
foreign_sing_box
foreign_pid=$LAST_DOUBLE
[ "$(rc stop)" = 0 ] || fail "an explicit stop of a stray Prokop runtime failed"
gone "$stray_pid" || fail "an explicit stop left a stray sing-box that runs Prokop's configuration"
alive "$foreign_pid" || fail "an explicit stop signalled a sing-box that Prokop does not own"
[ ! -e "$NFT_TABLE_FILE" ] || fail "an explicit stop left ProkopTable next to a stray runtime"

# 2b. A restart next to another program's sing-box is refused before its
#     stop: that sing-box outlives the stop, and the start after it refuses
#     the ambiguous runtime, so the restart could only take Prokop down
#     (as `prokop restart`, service/lifecycle.uc). Its refusal changes
#     nothing.
reset_case
runtime_up
procd_instance
prokop_pid=$LAST_DOUBLE
foreign_sing_box
foreign_pid=$LAST_DOUBLE
[ "$(rc restart)" != 0 ] || fail "a restart next to another program's sing-box reported success"
no_event '^start reached$' || fail "a restart next to another program's sing-box went on to its start"
alive "$prokop_pid" || fail "a refused restart stopped Prokop's sing-box"
alive "$foreign_pid" || fail "a refused restart signalled another program's sing-box"
[ -e "$NFT_TABLE_FILE" ] || fail "a refused restart removed ProkopTable"
no_event '^dns ' || fail "a refused restart changed DNS"
[ ! -e "$STOP_MARKER" ] || fail "a refused restart recorded a stop: $(cat "$STOP_MARKER")"
[ -e "$START_RECORD" ] || fail "a refused restart ended the explicit start"
grep -q 'Refusing Prokop restart' "$SYSLOG" || fail "the refused restart is not logged"

# A restart with only Prokop's own sing-box processes (here a stray one
# outside procd) goes on: its stop ends them and its start is reached.
reset_case
runtime_up
stray_runtime
stray_pid=$LAST_DOUBLE
[ "$(rc restart)" = 0 ] || fail "a restart of a stray Prokop runtime failed"
wait_until 10 gone "$stray_pid" || fail "a restart left a stray sing-box that runs Prokop's configuration"
has_event '^start reached$' || fail "a restart of a stray Prokop runtime did not reach its start"

# 3b. A sing-box with a configuration at Prokop's path is Prokop's only when
#     it runs Prokop's executable in Prokop's mount namespace: the sing-box
#     of a container commonly keeps its own configuration at that same path.
#     Neither is signalled; both are reported.
reset_case
runtime_up
start_double "$WORK_DIR/foreign-bin/sing-box" run -c "$CONFIG_PATH"
other_exe_pid=$LAST_DOUBLE
other_ns_pid=''
if unshare --mount true 2>/dev/null; then
  start_double unshare --mount "$WORK_DIR/stray-bin/sing-box" run -c "$CONFIG_PATH"
  other_ns_pid=$LAST_DOUBLE
else
  printf 'NOTE: no mount namespace can be created here; a sing-box in another mount namespace is not checked\n' >&2
fi
[ "$(rc stop)" = 0 ] || fail "an explicit stop next to sing-box processes of other programs failed"
alive "$other_exe_pid" || fail "an explicit stop signalled another executable's sing-box that uses Prokop's configuration path"
[ -z "$other_ns_pid" ] || alive "$other_ns_pid" ||
  fail "an explicit stop signalled a sing-box in another mount namespace that uses Prokop's configuration path"
grep -q "pid=$other_exe_pid" "$SYSLOG" || fail "the sing-box of another executable left running is not reported"
[ -z "$other_ns_pid" ] || grep -q "pid=$other_ns_pid" "$SYSLOG" ||
  fail "the sing-box in another mount namespace left running is not reported"
[ ! -e "$NFT_TABLE_FILE" ] || fail "an explicit stop left ProkopTable next to sing-box processes of other programs"

# 4. Prokop's own stop for a package change keeps the ownership guard: with
#    another sing-box present it refuses (2) and changes nothing - not the
#    runtime, not DNS, not the stop request.
reset_case
runtime_up
procd_instance
prokop_pid=$LAST_DOUBLE
foreign_sing_box
foreign_pid=$LAST_DOUBLE
[ "$(rc stop package)" = 2 ] || fail "a package stop with ambiguous sing-box ownership was not refused"
alive "$prokop_pid" || fail "a refused package stop signalled Prokop's sing-box"
alive "$foreign_pid" || fail "a refused package stop signalled another program's sing-box"
[ -e "$NFT_TABLE_FILE" ] || fail "a refused package stop removed ProkopTable"
[ -e "$IP_RULE_FILE" ] || fail "a refused package stop removed the ip rule at priority 105"
no_event '^dns ' || fail "a refused package stop changed DNS under the runtime it left running"
[ ! -e "$STOP_MARKER" ] || fail "a refused package stop left its stop request: $(cat "$STOP_MARKER")"
[ -e "$START_RECORD" ] || fail "a refused package stop ended the explicit start"

# 4b. Prokop's own stop for a component change whose earlier stop already
#     took the runtime down (PROKOP_STOP_CLEANUP=1, components/action.uc):
#     nothing runs that the guard would keep. A stray sing-box that runs
#     Prokop's configuration is what is left of that runtime, and the stop
#     clears it as the user's Stop does; another program's sing-box stays.
#     It is still Prokop's own stop: recorded as the component's, the
#     explicit start kept for the start that follows. Without the cleanup
#     the stop keeps the guard and refuses; so does a managed upgrade in
#     progress.
reset_case
stray_runtime
stray_pid=$LAST_DOUBLE
foreign_sing_box
foreign_pid=$LAST_DOUBLE
[ "$(rc stop component)" = 2 ] || fail "a component stop with ambiguous sing-box ownership was not refused"
alive "$stray_pid" || fail "a refused component stop signalled the stray sing-box"
[ "$(rc stop component PROKOP_STOP_CLEANUP=1)" = 0 ] || fail "the cleanup stop of a stopped Prokop failed next to a stray runtime"
wait_until 10 gone "$stray_pid" || fail "the cleanup stop left a stray sing-box that runs Prokop's configuration"
alive "$foreign_pid" || fail "the cleanup stop signalled a sing-box that Prokop does not own"
grep -qx 'by=component' "$STOP_MARKER" 2>/dev/null ||
  fail "the cleanup stop was not recorded as Prokop's own stop: $(cat "$STOP_MARKER" 2>/dev/null)"
[ -e "$START_RECORD" ] || fail "the cleanup stop ended the explicit start"

reset_case
runtime_up
procd_instance
prokop_pid=$LAST_DOUBLE
foreign_sing_box
start_ticks="$(ucode -L "$REAL_LIB" -e 'print(require("core.process_identity").start_ticks(ARGV[0]))' "$prokop_pid")"
printf 'format=1\npid=%s\nstart_ticks=%s\ncreated_at=%s\n' "$prokop_pid" "$start_ticks" "$(date +%s)" >"$MARKER"
[ "$(rc stop component PROKOP_STOP_CLEANUP=1)" = 2 ] || fail "a cleanup stop during a managed upgrade did not keep the ownership guard"
alive "$prokop_pid" || fail "a cleanup stop during a managed upgrade signalled Prokop's sing-box"
[ -e "$NFT_TABLE_FILE" ] || fail "a cleanup stop during a managed upgrade tore down Prokop's interception"

# 5. A stale upgrade marker (a failed in-app upgrade left it) does not turn
#    the user's Stop into a refused one; a fresh one keeps the guard of the
#    upgrade in progress, and its refusal changes nothing.
reset_case
runtime_up
procd_instance
prokop_pid=$LAST_DOUBLE
foreign_sing_box
foreign_pid=$LAST_DOUBLE
start_ticks="$(ucode -L "$REAL_LIB" -e 'print(require("core.process_identity").start_ticks(ARGV[0]))' "$prokop_pid")"
printf 'format=1\npid=%s\nstart_ticks=%s\ncreated_at=1\n' "$prokop_pid" "$start_ticks" >"$MARKER"
[ "$(rc stop)" = 0 ] || fail "a stale upgrade marker made the user's Stop fail"
wait_until 10 gone "$prokop_pid" || fail "a stale upgrade marker kept the user's Stop from stopping Prokop's sing-box"
alive "$foreign_pid" || fail "the user's Stop signalled a sing-box that Prokop does not own"
[ ! -e "$NFT_TABLE_FILE" ] || fail "a stale upgrade marker kept the user's Stop from removing ProkopTable"
[ ! -e "$MARKER" ] || fail "a stale upgrade marker outlived the user's Stop and would refuse the next start"

reset_case
runtime_up
procd_instance
prokop_pid=$LAST_DOUBLE
foreign_sing_box
foreign_pid=$LAST_DOUBLE
start_ticks="$(ucode -L "$REAL_LIB" -e 'print(require("core.process_identity").start_ticks(ARGV[0]))' "$prokop_pid")"
printf 'format=1\npid=%s\nstart_ticks=%s\ncreated_at=%s\n' "$prokop_pid" "$start_ticks" "$(date +%s)" >"$MARKER"
[ "$(rc stop)" = 2 ] || fail "a stop during a managed upgrade did not keep the ownership guard"
alive "$prokop_pid" || fail "a refused stop during an upgrade signalled Prokop's sing-box"
alive "$foreign_pid" || fail "a refused stop during an upgrade signalled another program's sing-box"
[ -e "$NFT_TABLE_FILE" ] || fail "a refused stop during an upgrade tore down Prokop's interception"
[ ! -e "$STOP_MARKER" ] || fail "a refused stop during an upgrade left its stop request"
[ -e "$START_RECORD" ] || fail "a refused stop during an upgrade ended the explicit start"

# 6. Full uninstall of a stopped Prokop passes its stop phase.
reset_case
UNINSTALL_ROOT="$WORK_DIR/uninstall-root"
mkdir -p "$UNINSTALL_ROOT/etc/init.d" "$UNINSTALL_ROOT/usr/bin" "$UNINSTALL_ROOT/bin"
printf '#!/bin/sh\nexec bash %q "$@"\n' "$WORK_DIR/rc" >"$UNINSTALL_ROOT/etc/init.d/prokop"
printf '#!/bin/sh\nexit 0\n' >"$UNINSTALL_ROOT/usr/bin/prokop"
cat >"$UNINSTALL_ROOT/bin/opkg" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$UNINSTALL_ROOT/etc/init.d/prokop" "$UNINSTALL_ROOT/usr/bin/prokop" "$UNINSTALL_ROOT/bin/opkg"
PROKOP_UNINSTALL_ROOT="$UNINSTALL_ROOT" PROKOP_MIRROR_BASE_URL=https://mirror.invalid PATH="$UNINSTALL_ROOT/bin:$PATH" \
  sh "$REAL_LIB/full-uninstall.sh" start >"$WORK_DIR/uninstall.response" ||
  fail "full uninstall did not start: $(cat "$WORK_DIR/uninstall.response")"
uninstall_finished() {
  grep -qE '"state":"(complete|failed)"' "$UNINSTALL_ROOT"/www/prokop-uninstall.*.json 2>/dev/null
}
wait_until 30 uninstall_finished || fail "full uninstall did not finish"
grep -q '"state":"complete"' "$UNINSTALL_ROOT"/www/prokop-uninstall.*.json ||
  fail "full uninstall of a stopped Prokop failed: $(cat "$UNINSTALL_ROOT"/www/prokop-uninstall.*.json)"

# 6b. Full uninstall while a managed upgrade runs next to another program's
#     sing-box: Prokop's stop keeps the ownership guard and refuses, so its
#     interception stays. Removing the packages would leave ProkopTable
#     without the sing-box that serves it: the removal is refused before
#     anything is disabled, stopped or removed, and its status names what
#     is left (UC-028).
reset_case
runtime_up
procd_instance
prokop_pid=$LAST_DOUBLE
foreign_sing_box
foreign_pid=$LAST_DOUBLE
start_ticks="$(ucode -L "$REAL_LIB" -e 'print(require("core.process_identity").start_ticks(ARGV[0]))' "$prokop_pid")"
printf 'format=1\npid=%s\nstart_ticks=%s\ncreated_at=%s\n' "$prokop_pid" "$start_ticks" "$(date +%s)" >"$MARKER"
REFUSED_ROOT="$WORK_DIR/uninstall-refused"
mkdir -p "$REFUSED_ROOT/etc/init.d" "$REFUSED_ROOT/usr/bin" "$REFUSED_ROOT/bin" "$REFUSED_ROOT/packages"
touch "$REFUSED_ROOT/packages/prokop"
printf '#!/bin/sh\nexec bash %q "$@"\n' "$WORK_DIR/rc" >"$REFUSED_ROOT/etc/init.d/prokop"
# shellcheck disable=SC2016 # the stub expands its arguments when it runs
printf '#!/bin/sh\nprintf "prokop-cli %%s\\n" "$*" >>"$EVENTS"\n' >"$REFUSED_ROOT/usr/bin/prokop"
cat >"$REFUSED_ROOT/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
  status) [ -e "$PROKOP_UNINSTALL_ROOT/packages/$2" ] && echo 'Status: install ok installed' ;;
  remove) shift; for p in "$@"; do rm -f "$PROKOP_UNINSTALL_ROOT/packages/$p"; done ;;
  *) exit 1 ;;
esac
SH
chmod +x "$REFUSED_ROOT/etc/init.d/prokop" "$REFUSED_ROOT/usr/bin/prokop" "$REFUSED_ROOT/bin/opkg"
PROKOP_UNINSTALL_ROOT="$REFUSED_ROOT" PROKOP_MIRROR_BASE_URL=https://mirror.invalid PATH="$REFUSED_ROOT/bin:$PATH" \
  sh "$REAL_LIB/full-uninstall.sh" start >"$WORK_DIR/uninstall-refused.response" ||
  fail "full uninstall did not start: $(cat "$WORK_DIR/uninstall-refused.response")"
refused_uninstall_finished() {
  grep -qE '"state":"(complete|failed)"' "$REFUSED_ROOT"/www/prokop-uninstall.*.json 2>/dev/null
}
wait_until 30 refused_uninstall_finished || fail "full uninstall next to a refused stop did not finish"
grep -Fq '"state":"failed","phase":"stop","left":"table:ProkopTable"' "$REFUSED_ROOT"/www/prokop-uninstall.*.json ||
  fail "full uninstall went on after a refused stop: $(cat "$REFUSED_ROOT"/www/prokop-uninstall.*.json)"
[ -e "$REFUSED_ROOT/packages/prokop" ] || fail "full uninstall removed Prokop after a refused stop"
[ -e "$NFT_TABLE_FILE" ] || fail "fixture: the refused stop tore down ProkopTable"
alive "$prokop_pid" || fail "full uninstall stopped the sing-box that serves the interception"
alive "$foreign_pid" || fail "full uninstall signalled another program's sing-box"
no_event '^prokop-cli' || fail "full uninstall went on to lift the kill-switch or restore DNS after a refused stop"

# 7. Stop stays offered while Prokop owns a sing-box, not for another
#    program's (service/ui.uc stop_available).
ui_stop_available() {
  env PROKOP_LIB="$REAL_LIB" PROKOP_UI_SING_BOX_BIN_PATH="$WORK_DIR/missing-sing-box" \
    PROKOP_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/missing-variant" \
    PROKOP_UI_LATENCY_ACTION_DIR="$WORK_DIR/ui-state/latency-actions" \
    PROKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/ui-state/component-actions" \
    PROKOP_UI_SUBSCRIPTION_ACTION_DIR="$WORK_DIR/ui-state/subscription-actions" \
    ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws" ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2" \
    BYEDPI_BIN="$WORK_DIR/missing-ciadpi" \
    ucode -L "$REAL_LIB" "$REAL_LIB/service/ui.uc" get-ui-state >"$WORK_DIR/ui.json" ||
    fail "ui.uc get-ui-state failed"
  ucode -e 'print(json(require("fs").readfile(ARGV[0])).service.prokop.stop_available, "\n");' "$WORK_DIR/ui.json"
}
reset_case
foreign_sing_box
[ "$(ui_stop_available)" = 0 ] || fail "Stop is offered for another program's sing-box: $(cat "$WORK_DIR/ui.json")"
stray_runtime
[ "$(ui_stop_available)" = 1 ] || fail "Stop is not offered for a stray Prokop runtime: $(cat "$WORK_DIR/ui.json")"

# Each signal of the explicit stop goes through the identity re-check of
# core/process_identity.uc, never through a bare kill of a PID (UC-216).
region="$(source_function "$STATE_UC" stop_owned_sing_box_and_wait)" || exit 1
source_refute_text "the explicit stop must signal only through process_identity.signal_record" \
  -E '(^|[^a-z_.])kill([^a-z_]|$)' "$region"
grep -q 'process_identity.signal_record(' <<<"$region" ||
  fail "the explicit stop does not re-check each process identity before it signals"

printf 'explicit stop ownership checks passed\n'
