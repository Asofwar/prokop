#!/usr/bin/env bash
set -euo pipefail

# Short-lived sing-box processes next to the runtime (F4 of the 2026-10-12
# fork review).
#
# The ownership check (service/state.uc sing-box-process-conflict, and the
# "sole procd-owned sing-box" proof behind the UI's "running") counted every
# process whose executable is sing-box, once. Prokop itself runs such
# processes for a moment: `sing-box check`, `sing-box version`,
# `sing-box rule-set ...` (list and subscription updates, the requirements
# check), and Smart Detect runs a probe `sing-box run -c <dir>/probe.json`
# for a few seconds. One of them alive at that instant made reload, restart
# and stop refuse with "ownership is ambiguous" and the UI show Prokop as not
# running.
#
# Now:
# - a sing-box running a one-shot command (check, version, format,
#   rule-set, merge, generate, help, completion) binds no listener and is no
#   runtime: it is not counted;
# - the Smart Detect probe that its identity record (PID, start ticks, exact
#   command line) names is Prokop's and is not counted, like the temporary
#   list sing-box;
# - an ambiguity that comes only from extra sing-box processes is looked at
#   again, up to 3 times 1 s apart, before it is reported.
# A second long-lived sing-box that is not Prokop's still fails closed.
#
# service/state.uc is real; procd (ubus) is modelled and the sing-box
# processes are doubles: a copy of bash named sing-box that runs the
# script named by its first argument.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The ownership checks look at every sing-box of the host: run in a private
# PID namespace with its own /proc where available; without one, a sing-box
# of the host or of another test is a failed precondition.
if [ "${PROKOP_SING_BOX_TRANSIENT_ISOLATED:-}" != 1 ]; then
  if unshare --pid --fork --mount-proc true 2>/dev/null; then
    PROKOP_SING_BOX_TRANSIENT_ISOLATED=1 exec unshare --pid --fork --mount-proc bash "$0" "$@"
  elif unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
    PROKOP_SING_BOX_TRANSIENT_ISOLATED=1 exec unshare --user --map-root-user --pid --fork --mount-proc bash "$0" "$@"
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
STATE_UC="$REAL_LIB/service/state.uc"
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

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

STATE_DIR="$WORK_DIR/run/prokop"
SMART_DIR="$STATE_DIR/smart-detect"
mkdir -p "$WORK_DIR/bin" "$STATE_DIR" "$SMART_DIR" "$WORK_DIR/tmp"
: >"$WORK_DIR/uci.state"
export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export PROKOP_SMART_DETECT_DIR="$SMART_DIR"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export SERVICE_PID_FILE="$WORK_DIR/service.pid"

printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
# procd's sing-box instance is the PID in service.pid.
cat >"$WORK_DIR/bin/ubus" <<'SH'
#!/bin/sh
pid="$(cat "$SERVICE_PID_FILE" 2>/dev/null)"
if [ -n "$pid" ]; then
  printf '{"sing-box":{"instances":{"sing-box":{"running":true,"pid":%s}}}}\n' "$pid"
else
  printf '{}\n'
fi
SH
chmod +x "$WORK_DIR/bin/"*

# Sing-box doubles: `sing-box <command> ...` runs the script ./<command>.
# Every command blocks on a FIFO (a helper caught while it runs), except
# `run -c transient.json`, a process that exits by itself after 1.5 s.
mkdir -p "$WORK_DIR/boot-bin" "$WORK_DIR/doubles"
cp "$(command -v bash)" "$WORK_DIR/boot-bin/sing-box"
mkfifo "$WORK_DIR/doubles/block"
printf 'case "$2" in *transient.json) sleep 1.5; exit 0 ;; esac\nread -r _ <"%s"\n' "$WORK_DIR/doubles/block" \
  >"$WORK_DIR/doubles/run"
for command in check version rule-set; do
  printf 'read -r _ <"%s"\n' "$WORK_DIR/doubles/block" >"$WORK_DIR/doubles/$command"
done

LAST_DOUBLE=''
start_double() { # start_double [arguments of sing-box...]
  (cd "$WORK_DIR/doubles" && exec "$WORK_DIR/boot-bin/sing-box" "$@") &
  LAST_DOUBLE=$!
  disown "$LAST_DOUBLE"
  doubles+=("$LAST_DOUBLE")
  wait_until 10 process_exec_is "$LAST_DOUBLE" sing-box || fail "a sing-box double did not start"
}
double_gone() { ! owned_process "$1"; }
reset_case() {
  local pid
  owned_kill KILL "${doubles[@]}" || true
  for pid in "${doubles[@]}"; do
    wait_until 10 double_gone "$pid" || fail "a sing-box double of the previous case did not exit"
  done
  doubles=()
  rm -f "$SERVICE_PID_FILE" "$SMART_DIR/probe.pid"
}
state() { ucode -L "$REAL_LIB" "$STATE_UC" "$@"; }
service_double() {
  start_double run -c /etc/sing-box/config.json
  printf '%s\n' "$LAST_DOUBLE" >"$SERVICE_PID_FILE"
}
record_probe() {
  ucode -L "$REAL_LIB" "$REAL_LIB/core/pidfile_cli.uc" record "$1" "$SMART_DIR/probe.pid" ||
    fail "could not record the Smart Detect probe"
}
expect_owned() { # expect_owned <case>
  state sing-box-process-conflict && fail "$1: the runtime is reported ambiguous"
  state sing-box-single-owned-service-runtime || fail "$1: procd's sing-box is not the sole owned runtime"
  state foreign-sing-box-present && fail "$1: a foreign sing-box is reported"
  return 0
}
expect_conflict() { # expect_conflict <case>
  state sing-box-process-conflict || fail "$1: the second sing-box is not a conflict"
  state sing-box-single-owned-service-runtime && fail "$1: procd's sing-box counts as the sole runtime next to it"
  return 0
}

# 0. procd's sing-box alone is the runtime.
reset_case
service_double
expect_owned "procd's sing-box alone"
ok "procd's sing-box alone is the owned runtime"

# 1. One-shot commands next to it: check, version, rule-set (a bash double
#    cannot take sing-box's global options; case 7 reads those).
reset_case
service_double
start_double check -c "$WORK_DIR/check.json"
start_double version
start_double rule-set match "$WORK_DIR/list.srs" 1.1.1.1
expect_owned "sing-box check, version and rule-set"
ui="$(state ui-runtime-state 100 ProkopTable 0x00100000 2)"
case "$ui" in *'"process_conflict": false'*) ;; *) fail "the UI state reports a conflict next to one-shot commands: $ui" ;; esac
ok "sing-box check, version and rule-set are no competitor of the runtime"

# 2. Without procd's instance a one-shot command is no conflict either.
reset_case
start_double check -c "$WORK_DIR/check.json"
state sing-box-process-conflict && fail "a lone sing-box check makes a stopped runtime ambiguous"
ok "a lone one-shot command is no conflict"

# 3. The Smart Detect probe its record names is Prokop's.
reset_case
service_double
start_double run -c "$SMART_DIR/probe.json"
record_probe "$LAST_DOUBLE"
expect_owned "the recorded Smart Detect probe"
ok "the recorded Smart Detect probe is Prokop's"

# 4. The same command line without the record, or a record naming another
#    command line, proves nothing: a conflict, after the re-checks.
reset_case
service_double
start_double run -c "$SMART_DIR/probe.json"
started="$(date +%s)"
expect_conflict "an unrecorded probe command line"
[ "$(( $(date +%s) - started ))" -ge 2 ] || fail "a conflict of extra sing-box processes was not looked at again"
reset_case
service_double
start_double run -c "$WORK_DIR/other.json"
record_probe "$LAST_DOUBLE"
expect_conflict "a probe record naming another command line"
ok "an unrecorded probe or a record of another command line stays a conflict"

# 5. A second long-lived sing-box of another program fails closed, however
#    it is spelt (the global -c takes the next word as its value).
reset_case
service_double
start_double run -c "$WORK_DIR/other.json"
expect_conflict "a foreign sing-box run"
state foreign-sing-box-present || fail "a foreign sing-box run is not reported as foreign"
reset_case
start_double run -c "$WORK_DIR/other.json"
state sing-box-process-conflict || fail "a foreign sing-box without procd's instance is not a conflict"
ok "a foreign long-lived sing-box still fails closed"

# 6. An extra sing-box that exits within the re-checks is no conflict.
reset_case
service_double
start_double run -c "$WORK_DIR/transient.json"
transient=$LAST_DOUBLE
state sing-box-process-conflict && fail "a sing-box that exited after 1.5 s made the runtime ambiguous"
double_gone "$transient" || fail "precondition: the transient sing-box is still running"
ok "an extra sing-box that exits within 3 s is no conflict"

# 7. The command a sing-box runs, as the check reads it from its argv.
# (As a JSON array: ucode would read -D and -c itself.)
one_shot() { state sing-box-one-shot-argv-fixture "$(node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' -- "$@")"; }
one_shot sing-box check -c x || fail "check is not a one-shot command"
one_shot /usr/bin/sing-box version || fail "version is not a one-shot command"
one_shot sing-box -D /tmp/x -c /tmp/y rule-set compile in.json || fail "rule-set after global options is not a one-shot command"
one_shot sing-box --config=/tmp/y format || fail "format after --config= is not a one-shot command"
one_shot sing-box -c check run && fail "-c check run counts as a check"
one_shot sing-box run -c /etc/sing-box/config.json && fail "run counts as a one-shot command"
one_shot sing-box tools fetch https://example.com && fail "tools counts as a one-shot command"
one_shot sing-box && fail "a sing-box without a command counts as a one-shot command"
one_shot sing-box -c && fail "a dangling -c counts as a one-shot command"
ok "the command is read after the global options"

printf 'sing_box_transient_helpers: PASS\n'
