#!/usr/bin/env bash
set -euo pipefail

# B6: a restart of a running Prokop first checks what the start will use,
# while the old runtime still serves: the Prokop configuration
# (validate-runtime) and a sing-box configuration generated and checked into
# a stage (prepare-config-stage, from cached data). A refused candidate stops
# nothing: the table, sing-box and DNS stay as they were. A valid one restarts
# as before, and its start is handed the checked stage (init-config publishes
# it when nothing it was generated from changed, tests/restart_stage_reuse.sh),
# which goes afterwards whatever happened. A restart of a stopped Prokop has nothing to keep and goes
# straight to the start, which checks the same itself.
#
# The real service/lifecycle.uc runs against a library where every module is
# a double that records its call (as in tests/runtime_guard_lifecycle.sh).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
LIFECYCLE_UC="$LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
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

FAKE_LIB="$WORK_DIR/lib"
STATE_DIR="$WORK_DIR/run/prokop"
TABLES="$WORK_DIR/tables"
mkdir -p "$WORK_DIR/bin" "$TABLES" "$STATE_DIR" "$WORK_DIR/tmp" "$FAKE_LIB/service"
# Copies, not links: the doubles below replace modules inside the library.
cp -R "$LIB/core" "$FAKE_LIB/core"
cp "$LIFECYCLE_UC" "$FAKE_LIB/service/lifecycle.uc"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" TEST_LIB="$LIB" EVENTS TABLES
export PROKOP_LIB="$FAKE_LIB"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_CONFIG_FILE="$WORK_DIR/prokop.conf"
export PROKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/prokop.reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/prokop.internal-config-change"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export TMP_SING_BOX_FOLDER="$WORK_DIR/tmp/sing-box"
export PROKOP_UI_ACTION_TRACKED=1

# Nothing here may reach the host's syslog, nftables or init scripts. nft
# knows only what the test installs: a table is $TABLES/<table>, a chain is
# $TABLES/<table>.<chain>; deleting a table deletes its chains.
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "nft $*" >>"$EVENTS"
case "$1 $2 $3" in
  "list table inet") [ -e "$TABLES/$4" ] ;;
  "list chain inet") [ -e "$TABLES/$4.$5" ] ;;
  "delete table inet") rm -f "$TABLES/$4" "$TABLES/$4".*; exit 0 ;;
  *) exit 0 ;;
esac
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "init $*" >>"$EVENTS"\nexit 0\n' >"$WORK_DIR/bin/init"
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "prokop $*" >>"$EVENTS"\nexit 0\n' >"$WORK_DIR/bin/prokop"
chmod +x "$WORK_DIR/bin/"*

# Every module records "<module> <arguments>" and succeeds, except the state
# predicates that decide the paths; runtime-dir locks go to the real
# service/state.uc. The nft double removes what the lifecycle removes: the
# DPI guard table (remove-dpi-transition-guard) and, as the real rebuild
# does, the production table with its chains (nft-rebuild-runtime-from-uci).
fake_module() {
  mkdir -p "$(dirname "$FAKE_LIB/$1")"
  cat >"$FAKE_LIB/$1" <<UC
function q(value) { return "'" + replace("" + value, /'/g, "'\\\\''") + "'"; }
let mode = "" + (ARGV[0] ?? "");
let name = "$1";
if (name == "service/state.uc" && index(mode, "runtime-dir-lock") >= 0) {
    let command = "ucode -L " + q(getenv("TEST_LIB")) + " " + q(getenv("TEST_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    exit(system(command));
}
system("printf '%s\\\\n' " + q(name + " " + join(" ", ARGV)) + " >> " + q(getenv("EVENTS")));
let tables = getenv("TABLES");
if (name == "nft/apply.uc" && mode == "remove-dpi-transition-guard")
    system("rm -f " + q(tables + "/" + ARGV[1] + "DpiGuard"));
if (name == "nft/apply.uc" && mode == "nft-rebuild-runtime-from-uci")
    system("rm -f " + q(tables + "/ProkopTable") + " " + q(tables) + "/ProkopTable.*");
if (name == "service/state.uc" && mode == "sing-box-process-conflict")
    exit(1);
if (name == "service/state.uc" && mode == "prokop-stably-running")
    exit((getenv("FAKE_STABLE") || "") == "1" ? 0 : 1);
if (name == "service/state.uc" && mode == "prokop-running")
    exit((getenv("FAKE_RUNNING") || "") == "1" ? 0 : 1);
if (name == "config/validator.uc" && mode == "validate-runtime" && (getenv("FAKE_INVALID") || "") == "1")
    exit(1);
if (name == "singbox/runtime.uc" && mode == "prepare-config-stage" && (getenv("FAKE_STAGE_FAILS") || "") == "1")
    exit(1);
if (name == "service/state.uc" && mode == "stop-managed-sing-box-runtime" && (getenv("FAKE_STOP_FAILS") || "") == "1")
    exit(1);
if (name == "service/state.uc" && mode == "has-list-update-sources")
    exit(1);
if (name == "singbox/ruleset_cache.uc" && mode == "refresh-if-due")
    exit(1);
exit(0);
UC
}
for module in service/state.uc subscription/cache.uc config/validator.uc nft/apply.uc singbox/runtime.uc \
  singbox/priority.uc singbox/dns_failover.uc singbox/ruleset_cache.uc components/updates.uc \
  autotune/manager.uc providers/byedpi/runtime.uc providers/zapret/runtime.uc providers/zapret2/runtime.uc \
  dns/apply.uc diagnostics/runtime.uc diagnostics/health.uc config/snapshots.uc core/packages.uc \
  service/ui.uc service/reload.uc; do
  fake_module "$module"
done

reset_case() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  rm -rf "${STATE_DIR:?}"/* "$PROKOP_RELOAD_LOCK_DIR" "${TABLES:?}"/*
  printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n" >"$WORK_DIR/prokop.conf"
  printf 'prokop.settings=settings\nprokop.settings.yacd_secret_key=0123456789abcdef\nprokop.settings.dont_touch_dhcp=1\n' \
    >"$WORK_DIR/uci.state"
  : >"$STATE_DIR/start.explicit"
  : >"$TABLES/ProkopTable"
  unset FAKE_RUNNING FAKE_STABLE FAKE_INVALID FAKE_STAGE_FAILS FAKE_STOP_FAILS
}

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }
confirmed() { grep -q '^config/snapshots.uc confirm-working lifecycle ' "$EVENTS" 2>/dev/null; }
logged() { grep -q "$1" "$WORK_DIR/syslog" 2>/dev/null; }
lifecycle() {
  local status=0
  timeout -s KILL 60 ucode -L "$FAKE_LIB" "$FAKE_LIB/service/lifecycle.uc" "$@" >/dev/null 2>&1 || status=$?
  printf '%s\n' "$status"
}
kept_dpi_guard() { : >"$TABLES/ProkopTableDpiGuard"; }
kept_transition_guard() { : >"$TABLES/ProkopTable.prokop_transition_guard"; }
restore_guard() { : >"$TABLES/ProkopConfigRestoreDpiGuard"; }

stopped_nothing() {
  local what="$1"
  ! has_event '^nft delete table' || fail "$what: the table was deleted"
  ! has_event '^service/state.uc stop-' || fail "$what: sing-box was stopped"
  ! has_event '^nft/apply.uc nft-rebuild-runtime-from-uci' || fail "$what: the policy was rebuilt"
  ! has_event '^singbox/runtime.uc init-config' || fail "$what: a start ran"
  [ -e "$TABLES/ProkopTable" ] || fail "$what: the table is gone"
  logged 'the running Prokop is kept' || fail "$what: the refusal is not described"
}

# 1. Running, a sing-box configuration that fails its check: refused, untouched.
reset_case
export FAKE_RUNNING=1 FAKE_STABLE=1 FAKE_STAGE_FAILS=1
[ "$(lifecycle restart)" != 0 ] || fail "a restart with a failing sing-box configuration succeeded"
has_event '^singbox/runtime.uc prepare-config-stage 0 0 1  ' || fail "the candidate was not prepared from cached data"
stopped_nothing "failing sing-box configuration"
has_event '^singbox/runtime.uc discard-config-stage ' || fail "the candidate stage was not discarded"

# 2. Running, an invalid Prokop configuration: refused before any generation.
reset_case
export FAKE_RUNNING=1 FAKE_STABLE=1 FAKE_INVALID=1
[ "$(lifecycle restart)" != 0 ] || fail "a restart with an invalid configuration succeeded"
! has_event '^singbox/runtime.uc prepare-config-stage' || fail "an invalid configuration was generated"
stopped_nothing "invalid configuration"

# 3. Running, a valid candidate: checked first, then the restart as before.
reset_case
export FAKE_RUNNING=1 FAKE_STABLE=1
[ "$(lifecycle restart)" = 0 ] || fail "a restart with a valid candidate failed"
check_line="$(grep -n '^singbox/runtime.uc prepare-config-stage' "$EVENTS" | head -1 | cut -d: -f1)"
rebuild_line="$(grep -n '^nft/apply.uc nft-rebuild-runtime-from-uci' "$EVENTS" | head -1 | cut -d: -f1)"
{ [ -n "$check_line" ] && [ -n "$rebuild_line" ]; } || fail "a valid restart did not check and then rebuild"
[ "$check_line" -lt "$rebuild_line" ] || fail "the candidate was checked after the stop"
has_event '^singbox/runtime.uc init-config' || fail "a valid restart did not start"
# B6: the start is handed the checked stage, to publish it when nothing it
# was generated from changed, and the stage goes afterwards either way.
stage="$(sed -n 's/^singbox\/runtime.uc prepare-config-stage 0 0 1  \(.*\) reusable$/\1/p' "$EVENTS" | head -1)"
[ -n "$stage" ] || fail "the restart did not ask for a reusable stage"
init_line="$(grep -n "^singbox/runtime.uc init-config 0 .* $stage\$" "$EVENTS" | head -1 | cut -d: -f1)"
[ -n "$init_line" ] || fail "the start was not handed the checked stage $stage"
discard_line="$(grep -n "^singbox/runtime.uc discard-config-stage $stage\$" "$EVENTS" | tail -1 | cut -d: -f1)"
{ [ -n "$discard_line" ] && [ "$discard_line" -gt "$init_line" ]; } ||
  fail "the checked stage was not discarded after the start"
grep -c "^singbox/runtime.uc discard-config-stage" "$EVENTS" | grep -qx 1 ||
  fail "the checked stage was discarded before the start used it"

# 3b. Running, a valid candidate, a stop that fails: the checked stage goes.
reset_case
export FAKE_RUNNING=1 FAKE_STABLE=1 FAKE_STOP_FAILS=1
[ "$(lifecycle restart)" != 0 ] || fail "a restart whose stop failed succeeded"
stage="$(sed -n 's/^singbox\/runtime.uc prepare-config-stage 0 0 1  \(.*\) reusable$/\1/p' "$EVENTS" | head -1)"
[ -n "$stage" ] || fail "the restart did not check its candidate"
has_event "^singbox/runtime.uc discard-config-stage $stage\$" || fail "a restart whose stop failed left the checked stage"
! has_event '^singbox/runtime.uc init-config' || fail "a restart whose stop failed started"

# 4. Stopped: nothing to keep, no separate check; the start checks itself.
reset_case
rm -f "$TABLES/ProkopTable"
export FAKE_STABLE=1 FAKE_STAGE_FAILS=1
[ "$(lifecycle restart)" = 0 ] || fail "a restart of a stopped Prokop failed"
! has_event '^singbox/runtime.uc prepare-config-stage' || fail "a stopped Prokop was checked before its start"

echo "restart_precheck: OK"
