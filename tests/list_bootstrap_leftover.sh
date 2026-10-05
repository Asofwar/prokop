#!/usr/bin/env bash
set -euo pipefail

# A start after a killed start (LC-7).
#
# A cold start runs a temporary sing-box for its list download (A9,
# singbox/runtime.uc list_bootstrap_*) and records it in
# <runtime>/list-bootstrap/sing-box.pid. When the start died while it ran
# (OOM, kill), that sing-box went on running. Only start_main stopped it,
# and start_inner refused the start before that over an ambiguous sing-box;
# an explicit stop did not count it as Prokop's and left it running, a
# package stop and a restart refused. Prokop did not start again until a
# reboot or a manual kill. The same "foreign" process made the UI report
# restart_blocked during every cold start.
#
# Now the process that record names, with its own command line and start
# ticks, is Prokop's: the next start stops it before its ownership check,
# and every stop stops it. A process with the same command line that the
# record does not name stays foreign.
#
# service/lifecycle.uc, the sing-box process handling of service/state.uc
# and list-bootstrap-stop of singbox/runtime.uc are real; the other modules
# are modelled.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The ownership checks look at every sing-box of the host: run in a private
# PID namespace with its own /proc where available; without one, a sing-box
# of the host or of another test is a failed precondition.
if [ "${PROKOP_LIST_BOOTSTRAP_LEFTOVER_ISOLATED:-}" != 1 ]; then
  if unshare --pid --fork --mount-proc true 2>/dev/null; then
    PROKOP_LIST_BOOTSTRAP_LEFTOVER_ISOLATED=1 exec unshare --pid --fork --mount-proc bash "$0" "$@"
  elif unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
    PROKOP_LIST_BOOTSTRAP_LEFTOVER_ISOLATED=1 exec unshare --user --map-root-user --pid --fork --mount-proc bash "$0" "$@"
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
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

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
BOOTSTRAP_DIR="$STATE_DIR/list-bootstrap"
CONFIG_PATH="$WORK_DIR/etc/sing-box/config.json"
mkdir -p "$WORK_DIR/bin" "$STATE_DIR" "$WORK_DIR/tmp" "$WORK_DIR/singbox-tmp/rulesets" "$LIB/service" \
  "$(dirname "$CONFIG_PATH")"
ln -s "$REAL_LIB/core" "$LIB/core"
ln -s "$REAL_LIB/service/lifecycle.uc" "$LIB/service/lifecycle.uc"

cat >"$WORK_DIR/uci.state" <<EOF
prokop.settings=settings
prokop.settings.yacd_secret_key=0123456789abcdef
prokop.settings.dont_touch_dhcp=0
prokop.settings.config_path=$CONFIG_PATH
prokop.settings.cache_path=$WORK_DIR/cache.db
EOF
: >"$WORK_DIR/prokop.config"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS SYSLOG REAL_LIB LIB
export PROKOP_LIB="$LIB"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_SING_BOX_INIT="$WORK_DIR/bin/init-sing-box"
export PROKOP_SERVICE_NAME=prokop
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/prokop.reload.lock"
export PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$STATE_DIR/subscription-update.lock"
export PROKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export PROKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export PROKOP_START_IN_PROGRESS_FILE="$STATE_DIR/start.in-progress"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_CONFIG_FILE="$WORK_DIR/prokop.config"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export PROKOP_SELECTOR_CHOICES_FILE="$WORK_DIR/selector-choices.json"
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export TMP_RULESET_FOLDER="$WORK_DIR/singbox-tmp/rulesets"
export PROKOP_SING_BOX_RELOAD_PID_TIMEOUT=2
export PROKOP_SING_BOX_BIN="$WORK_DIR/prokop-bin/sing-box"

# Nothing here may reach the host's syslog, firewall, routing or procd.
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSLOG"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
# procd knows no 'sing-box' service: the start that ran the temporary
# sing-box died before it started the real one.
cat >"$WORK_DIR/bin/ubus" <<'SH'
#!/bin/sh
[ "$3" = list ] && { printf '{}\n'; exit 0; }
echo 'Command failed: Not found' >&2
exit 4
SH
printf '#!/bin/sh\nprintf "init %%s\\n" "$*" >>"$EVENTS"\nexit 0\n' >"$WORK_DIR/bin/init"
cp "$WORK_DIR/bin/init" "$WORK_DIR/bin/init-sing-box"
chmod +x "$WORK_DIR/bin/"*

fake_header='let fs = require("fs");
function q(value) { return "'"'"'" + replace("" + value, /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'"; }
function ev(line) { system("printf '"'"'%s\\n'"'"' " + q(line) + " >> " + q(getenv("EVENTS"))); }
function real(path) {
    let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/" + path);
    for (let arg in ARGV)
        command += " " + q(arg);
    return system(command);
}
let mode = "" + (ARGV[0] ?? "");
'
# service/state.uc is the real module.
cat >"$LIB/service/state.uc" <<UC
$fake_header
if (mode == "has-list-update-sources")
    exit(getenv("LIST_SOURCES") == "1" ? 0 : 1);
exit(real("service/state.uc"));
UC
# singbox/runtime.uc: list-bootstrap-stop is the real one.
mkdir -p "$LIB/singbox"
cat >"$LIB/singbox/runtime.uc" <<UC
$fake_header
ev("singbox " + mode);
if (mode == "list-bootstrap-start")
    exit(getenv("BOOTSTRAP_FAIL") == "1" ? 1 : 0);
exit(mode == "list-bootstrap-stop" ? real("singbox/runtime.uc") : 0);
UC
# The configuration check fails: the start ends right after its gates
# (unless CHECK_PASS=1).
mkdir -p "$LIB/config"
cat >"$LIB/config/validator.uc" <<UC
$fake_header
ev("validator " + mode);
exit(mode == "check-requirements" && getenv("CHECK_PASS") != "1" ? 1 : 0);
UC
mkdir -p "$LIB/components"
cat >"$LIB/components/updates.uc" <<UC
$fake_header
ev("updates " + mode);
exit(mode == "runtime-list-cache-active" || mode == "restore-list-cache" ? 1 : 0);
UC
for module in service/reload service/ui subscription/cache singbox/priority singbox/dns_failover singbox/ruleset_cache \
  autotune/manager notify/manager providers/zapret/runtime providers/zapret2/runtime \
  providers/byedpi/runtime dns/apply nft/apply diagnostics/runtime diagnostics/health diagnostics/traffic \
  killswitch/runtime; do
  mkdir -p "$(dirname "$LIB/$module.uc")"
  printf '%s\nexit(mode == "runtime-list-cache-active" ? 1 : 0);\n' "$fake_header" >"$LIB/$module.uc"
done

# Sing-box doubles: a copy of bash named sing-box; `sing-box run -c <config>
# -D <dir>` runs the script ./run, which blocks on a FIFO.
mkdir -p "$WORK_DIR/boot-bin" "$WORK_DIR/doubles"
cp "$(command -v bash)" "$WORK_DIR/boot-bin/sing-box"
mkfifo "$WORK_DIR/doubles/block"
printf '[ ! -e "%s" ] || trap "" TERM\nread -r _ <"%s"\n' "$WORK_DIR/doubles/ignore-term" "$WORK_DIR/doubles/block" \
  >"$WORK_DIR/doubles/run"

LAST_DOUBLE=''
start_double() { # start_double [arguments of sing-box...]
  (cd "$WORK_DIR/doubles" && exec "$WORK_DIR/boot-bin/sing-box" "$@") &
  LAST_DOUBLE=$!
  disown "$LAST_DOUBLE"
  doubles+=("$LAST_DOUBLE")
  wait_until 10 process_exec_is "$LAST_DOUBLE" sing-box || fail "a sing-box double did not start"
}
# The temporary sing-box as list_bootstrap_run starts and records it.
leftover_bootstrap() {
  mkdir -p "$BOOTSTRAP_DIR"
  printf '{}\n' >"$BOOTSTRAP_DIR/config.json"
  start_double run -c "$BOOTSTRAP_DIR/config.json" -D "$BOOTSTRAP_DIR"
  ucode -L "$REAL_LIB" "$REAL_LIB/core/pidfile_cli.uc" record "$LAST_DOUBLE" "$BOOTSTRAP_DIR/sing-box.pid" ||
    fail "could not record the temporary sing-box"
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
  rm -rf "$BOOTSTRAP_DIR" "$STATE_DIR/stop.requested"
  [ ! -e "$PROKOP_RELOAD_LOCK_DIR" ] || fail "reload.lock leaked from the previous case"
}
state() { ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" "$@"; }
lifecycle() { # lifecycle <mode> [NAME=value...]: exit status
  local rc=0 mode="$1"
  shift
  env "$@" ucode -L "$LIB" "$LIB/service/lifecycle.uc" "$mode" >>"$EVENTS" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# 1. The leftover is Prokop's: no ownership conflict, no foreign sing-box
#    (init.d restart_blocked, the UI's restart_blocked), and one owned
#    process.
reset_case
leftover_bootstrap
bootstrap=$LAST_DOUBLE
state sing-box-process-conflict && fail "the temporary list sing-box makes the runtime ambiguous"
state foreign-sing-box-present && fail "the temporary list sing-box counts as a foreign sing-box"
[ "$(state owned-sing-box-process-count)" = 1 ] || fail "the temporary list sing-box is not counted as Prokop's"
# The same command line without the record is no proof: it stays foreign.
start_double run -c "$BOOTSTRAP_DIR/config.json" -D "$BOOTSTRAP_DIR"
state sing-box-process-conflict || fail "a second sing-box next to the temporary one is not a conflict"
state foreign-sing-box-present || fail "a sing-box the record does not name counts as Prokop's"
reset_case
mkdir -p "$BOOTSTRAP_DIR"
start_double run -c "$WORK_DIR/other.json" -D "$BOOTSTRAP_DIR"
ucode -L "$REAL_LIB" "$REAL_LIB/core/pidfile_cli.uc" record "$LAST_DOUBLE" "$BOOTSTRAP_DIR/sing-box.pid" ||
  fail "could not record the unrelated sing-box"
state sing-box-process-conflict || fail "a recorded sing-box with another command line is not a conflict"

# 2. The start after a killed start stops the leftover and goes on.
reset_case
leftover_bootstrap
bootstrap=$LAST_DOUBLE
lifecycle start >/dev/null
grep -q 'Refusing Prokop start' "$SYSLOG" && fail "the start was refused over the temporary list sing-box"
wait_until 10 double_gone "$bootstrap" || fail "the start left the temporary list sing-box running"
grep -q '^validator check-requirements' "$EVENTS" || fail "the start did not get past its ownership checks"
[ ! -e "$BOOTSTRAP_DIR" ] || fail "the start left the files of the temporary list sing-box"

# 3. An explicit stop stops it.
reset_case
leftover_bootstrap
bootstrap=$LAST_DOUBLE
[ "$(lifecycle stop)" = 0 ] || fail "the explicit stop failed next to the temporary list sing-box"
wait_until 10 double_gone "$bootstrap" || fail "the explicit stop left the temporary list sing-box running"
grep -q 'does not own' "$SYSLOG" && fail "the explicit stop reported the temporary list sing-box as foreign"

# 4. Prokop's own stop for a package change (the guarded stop) is not
#    refused: it stops the leftover too.
reset_case
leftover_bootstrap
bootstrap=$LAST_DOUBLE
[ "$(lifecycle stop PROKOP_STOP_SOURCE=package)" = 0 ] || fail "the package stop was refused over the temporary list sing-box"
wait_until 10 double_gone "$bootstrap" || fail "the package stop left the temporary list sing-box running"

# 5. A restart is not refused and stops it.
reset_case
leftover_bootstrap
bootstrap=$LAST_DOUBLE
lifecycle restart >/dev/null
grep -q 'Refusing Prokop restart' "$SYSLOG" && fail "the restart was refused over the temporary list sing-box"
wait_until 10 double_gone "$bootstrap" || fail "the restart left the temporary list sing-box running"

# 6. A cold start whose lists download through a rule's proxy stops at once
#    when the temporary sing-box for them did not start: it does not try
#    every list through a proxy nobody serves (LC-12).
reset_case
[ "$(lifecycle start CHECK_PASS=1 LIST_SOURCES=1 BOOTSTRAP_FAIL=1)" != 0 ] ||
  fail "the start went on without the temporary sing-box the lists download through"
grep -q '^singbox list-bootstrap-start' "$EVENTS" || fail "the start did not reach the list download"
grep -q '^updates prepare-list-cache' "$EVENTS" && fail "the start downloaded the lists through a proxy nobody serves"
grep -q 'lists download only through that proxy' "$SYSLOG" || fail "the start does not say why it stopped"
[ ! -e "$BOOTSTRAP_DIR" ] || fail "the failed start left the files of the temporary list sing-box"

# 7. A temporary sing-box that ignores TERM is killed after its grace time;
#    the stop polls it in process, without a forked sleep per poll.
reset_case
: >"$WORK_DIR/doubles/ignore-term"
leftover_bootstrap
bootstrap=$LAST_DOUBLE
rm -f "$WORK_DIR/doubles/ignore-term"
printf '#!/bin/sh\nprintf "sleep %%s\\n" "$*" >>"%s"\nexec %s "$@"\n' "$EVENTS" "$(command -v sleep)" >"$WORK_DIR/bin/sleep"
chmod +x "$WORK_DIR/bin/sleep"
ucode -L "$REAL_LIB" "$REAL_LIB/singbox/runtime.uc" list-bootstrap-stop || fail "the temporary sing-box that ignores TERM was not stopped"
rm -f "$WORK_DIR/bin/sleep"
wait_until 10 double_gone "$bootstrap" || fail "the temporary sing-box that ignores TERM is still running"
grep -q '^sleep ' "$EVENTS" && fail "the stop forked a sleep for every poll: $(grep -c '^sleep ' "$EVENTS") sleeps"

printf 'list_bootstrap_leftover: OK\n'
