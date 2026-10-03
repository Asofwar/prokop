#!/usr/bin/env bash
set -euo pipefail

# An upgrade by the package manager (opkg upgrade, apk upgrade, an install
# over the installed release) stops a running Prokop in prerm for the start
# that postinst makes: prerm hands the start over (service/package.uc
# PACKAGE_UPGRADE_STATE) and records its stop as Prokop's own
# (stop.requested, by=package). The user may stop Prokop between the two
# (LuCI, `service prokop stop`; a package manager that downloads the next
# package can take minutes on a slow router). That stop is the user's: it
# holds Prokop down until the user starts it again (D-15 (a)). postinst
# started Prokop from the hand-off without looking at it and undid it.
#
# postinst leaves Prokop down when the user stopped it after prerm's stop:
# it keeps the record, consumes the hand-off and logs why. Its start follows
# prerm's own stop (PROKOP_START_AFTER_STOP, service/initd.uc start_service):
# a user's Stop that gets procd's lock just before that start wins as well,
# and postinst reports it as the user's stop, not as a failed start.
#
# A stop of the user's that lands during prerm's own stop holds Prokop down
# as well: a `prokop stop` (service/lifecycle.uc, which takes neither procd's
# lock nor reload.lock) recorded while prerm's stop runs, and a Stop that
# waited for procd's lock behind it and records before prerm goes on. Every
# stop recorded on top of the user's is the user's (service/initd.uc
# stop_request_source), except over a user's stop that the user's Start
# deferred for reload.lock followed: that start is the user's last request.
# prerm hands it over, its stop, Prokop's own, cancels it, and postinst
# starts Prokop in its place (UC-012). A user's stop that is under way when
# prerm looks (recorded, the runtime not down yet) holds Prokop down.
#
# service/package.uc, service/initd.uc and the init script are the real
# ones; the init script runs behind an rc.common stand-in that holds fd 1000
# like procd.sh. Its backend `prokop`, logger, nft, ip and the modules of
# DNS, health and the kill-switch are test doubles.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
REAL_INITD="$ROOT_DIR/prokop/files/etc/init.d/prokop"
REAL_UCODE="$(command -v ucode)"
PACKAGE_UC="${PACKAGE_POSTINST_USER_STOP_UC:-$LIB/service/package.uc}"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
# shellcheck source=tests/helpers/migrated_config.sh
. "$ROOT_DIR/tests/helpers/migrated_config.sh"

# A failed start schedules its retry: `/bin/sh -c '...; sleep "$1"; rm -f
# .../start-retry.pid; exec init retry_start_on_wan_up' sh N`.
kill_retry_workers() {
  local pid
  for pid in $(pgrep -f "${WORK_DIR:?}/run/prokop/start-retry.pid" 2>/dev/null); do
    owned_kill_children KILL "$pid"
    owned_kill KILL "$pid" || true
  done
  rm -f "${WORK_DIR:?}/run/prokop/start-retry.pid"
}

cleanup() {
  kill_retry_workers
  pkill -KILL -f "${WORK_DIR:?}" 2>/dev/null || true
  rm -rf "${WORK_DIR:?}"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'package_postinst_user_stop: FAIL: %s\n' "$1" >&2
  for log in out syslog init.log; do
    [ ! -s "$WORK_DIR/$log" ] || sed "s|^|  $log: |" "$WORK_DIR/$log" >&2
  done
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/prokop" "$WORK_DIR/tmp" "$WORK_DIR/proc" "$WORK_DIR/rc.d"
printf "config settings 'settings'\n" >"$WORK_DIR/prokop.conf"
# postinst starts Prokop only on a configuration this release has migrated
# (UC-026).
{
  printf 'prokop.settings=settings\n'
  migrated_settings_state "$LIB" "$WORK_DIR"
} >"$WORK_DIR/uci.state" || fail "could not describe a migrated configuration"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" REAL_INITD REAL_UCODE
export TEST_LIB="$LIB"
export RC_PROCD_LOCK="$WORK_DIR/procd_prokop.lock"
export PROKOP_LIB="$LIB"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_INIT="$WORK_DIR/bin/init"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/prokop.reload.lock"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/prokop"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/prokop/reload.pending"
export PROKOP_UI_STATE_DIR="$WORK_DIR/run/prokop/ui-state"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_CONFIG_PATH="$WORK_DIR/prokop.conf"
export PROKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/prokop.conf"
export PROKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/was-running"
export PROKOP_PROC_DIR="$WORK_DIR/proc"
export PROKOP_RC_D_DIR="$WORK_DIR/rc.d"
export PROKOP_TORRSERVER_DIRECT_INIT="$WORK_DIR/missing-torrserver-direct-init"
export PROKOP_KILLSWITCH_UC="$WORK_DIR/missing-killswitch.uc"
export PROKOP_LEGACY_GUARD_ROOT="$WORK_DIR/legacy-guard"
export PROKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK_DIR/run/prokop/component-update-checks"
export PROKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK_DIR/run/prokop/component-update-check.timestamp"
export PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export PROKOP_START_RETRY_DELAY_SECONDS=300
export PROKOP_START_DEFERRED_RETRY_DELAY_SECONDS=300
export PROKOP_START_RUNTIME_LOCK_WAIT_SECONDS=1
export PROKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS=1
export PROKOP_START_WAIT_TIMEOUT_SECONDS=4
export PROKOP_START_SETTLE_SECONDS=2
export PROKOP_POSTINST_START_WAIT_SECONDS=8
export PROKOP_UI_ACTION_TRACKED=1
unset PROKOP_STOP_SOURCE PROKOP_START_REQUEST PROKOP_START_AFTER_STOP PKG_ROOT PKG_UPGRADE APK_SCRIPT IPKG_INSTROOT

# Nothing here may reach the host's syslog or nftables.
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_WORK/syslog"
SH
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"

# `prokop` behind initd.uc: start brings the runtime up, stop takes it down.
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
case "$1" in
  start)
    printf 'start\n' >>"$TEST_WORK/starts"
    : >"$TEST_WORK/runtime.up"
    ;;
  stop)
    # The user's `prokop stop` (service/lifecycle.uc stop) records its stop
    # while prerm's stop runs: after prerm's own record, or between the
    # record of service/initd.uc and the one service/lifecycle.uc makes for
    # prerm's stop, which then is the user's (stop_request_source).
    if [ "${PROKOP_STOP_SOURCE:-}" = package ] && [ -e "$TEST_WORK/cli-user-stop" ]; then
      when="$(cat "$TEST_WORK/cli-user-stop")"
      rm -f "$TEST_WORK/cli-user-stop"
      printf '%s.000000001.%s\nby=user\n' "$(date +%s)" "$$" >"$PROKOP_RUNTIME_STATE_DIR/stop.requested"
      rm -f "$PROKOP_RUNTIME_STATE_DIR/start.explicit"
      if [ "$when" = between ]; then
        printf '%s.000000002.%s\nby=user\n' "$(date +%s)" "$$" >"$PROKOP_RUNTIME_STATE_DIR/stop.requested"
      fi
      : >"$TEST_WORK/cli-user-stop.done"
    fi
    rm -f "$TEST_WORK/runtime.up"
    ;;
  get_status)
    if [ -e "$TEST_WORK/runtime.up" ]; then printf '{"running":1}\n'; else printf '{"running":0}\n'; fi
    ;;
esac
exit 0
SH

# /etc/init.d/prokop as procd runs it: rc.common with fd 1000 open and
# flocked. With user-stop.before-start the user's Stop gets procd's lock
# right before the start that postinst requested, after postinst has read
# the stop request. With user-stop.queued the user's Stop waits for procd's
# lock behind prerm's stop and records its stop before prerm goes on.
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
exec bash "$TEST_WORK/rc" "$@"
SH
cat >"$WORK_DIR/rc" <<'SH'
#!/usr/bin/env bash
action="$1"
shift
if [ "$action" = start ] && [ -e "$TEST_WORK/user-stop.before-start" ]; then
  rm -f "$TEST_WORK/user-stop.before-start"
  env -u PROKOP_STOP_SOURCE -u PROKOP_START_REQUEST -u PROKOP_START_AFTER_STOP \
    "$PROKOP_SERVICE_INIT" stop </dev/null >/dev/null 2>&1
  printf '%s\n' "$?" >"$TEST_WORK/user-stop.done"
fi
exec 1000>"$RC_PROCD_LOCK"
flock 1000
queued=""
if [ "$action" = stop ] && [ "${PROKOP_STOP_SOURCE:-}" = package ] && [ -e "$TEST_WORK/user-stop.queued" ]; then
  rm -f "$TEST_WORK/user-stop.queued"
  queued=1
  (
    env -u PROKOP_STOP_SOURCE -u PROKOP_START_REQUEST -u PROKOP_START_AFTER_STOP \
      "$PROKOP_SERVICE_INIT" stop </dev/null >/dev/null 2>&1
    printf '%s\n' "$?" >"$TEST_WORK/user-stop.done"
  ) 1000>&- &
fi
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
PROKOP_LIB="$TEST_LIB"
PROKOP_INITD_UC="$TEST_LIB/service/initd.uc"
stop() { stop_service "$@"; }
start() { start_service "$@"; service_started; }
printf '%s source=%s\n' "$action" "${PROKOP_STOP_SOURCE:-}" >>"$TEST_WORK/init.log"
case "$action" in
  start) start "$@" ;;
  stop) stop "$@" ;;
  status) status_service ;;
  *) exit 64 ;;
esac
status=$?
if [ -n "$queued" ]; then
  flock -u 1000
  exec 1000>&-
  for _ in $(seq 1 100); do
    [ ! -e "$TEST_WORK/user-stop.done" ] || break
    sleep 0.1
  done
fi
exit "$status"
SH

# No sing-box of another program runs; DNS, health and the kill-switch stay
# the router's.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "${3:-}" in
  */service/state.uc)
    case "${4:-}" in
      prokop-stably-running) [ -e "$TEST_WORK/runtime.up" ]; exit $? ;;
      foreign-sing-box-present) exit 1 ;;
    esac
    ;;
  */dns/apply.uc | */diagnostics/health.uc | */killswitch/runtime.uc) exit 0 ;;
esac
exec "$REAL_UCODE" "$@"
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

stop_request_by() {
  sed -n 's/^by=//p' "$PROKOP_RUNTIME_STATE_DIR/stop.requested" 2>/dev/null || true
}

reset_state() {
  kill_retry_workers
  rm -f "$WORK_DIR"/starts "$WORK_DIR"/user-stop.before-start "$WORK_DIR"/user-stop.done \
    "$WORK_DIR"/user-stop.queued "$WORK_DIR"/cli-user-stop "$WORK_DIR"/cli-user-stop.done \
    "$WORK_DIR"/out "$PROKOP_RUNTIME_STATE_DIR"/stop.requested "$PROKOP_PACKAGE_UPGRADE_STATE" \
    "$PROKOP_RUNTIME_STATE_DIR"/start.retry "$PROKOP_RUNTIME_STATE_DIR"/start-result.*
  : >"$WORK_DIR/syslog"
  : >"$WORK_DIR/init.log"
}

# prerm of the upgrade (service/package.uc prerm_cleanup, as the package
# scripts run it): it hands the start over to postinst and stops Prokop.
# rt_tables, the managed sing-box and DNS are the test's.
prerm_upgrade() {
  PROKOP_RT_TABLES="$WORK_DIR/rt_tables" \
  PROKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
  PROKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
  PROKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box" \
  PROKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
    "$REAL_UCODE" -L "$LIB" "$PACKAGE_UC" prerm upgrade 9.9.9 >"$WORK_DIR/out" 2>&1 ||
      fail "prerm of the upgrade failed"
}

# Prokop runs, started explicitly.
prokop_runs() {
  reset_state
  : >"$WORK_DIR/runtime.up"
  printf 'explicit\n' >"$PROKOP_RUNTIME_STATE_DIR/start.explicit"
}

# ... and prerm of the upgrade stopped it for the start that postinst makes.
prerm_stopped() {
  prokop_runs
  prerm_upgrade
  [ -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] || fail "prerm did not hand the start of the running Prokop over"
  [ ! -e "$WORK_DIR/runtime.up" ] || fail "prerm's stop left the runtime up"
  [ "$(stop_request_by)" = package ] || fail "prerm's stop was not recorded as the package's"
  : >"$WORK_DIR/init.log"
}

user_stops() {
  "$PROKOP_SERVICE_INIT" stop >/dev/null 2>&1 || fail "the user's stop failed"
  [ "$(stop_request_by)" = user ] || fail "the user's stop was not recorded as the user's"
}

postinst() {
  local status=0
  "$REAL_UCODE" -L "$LIB" "$PACKAGE_UC" postinst >"$WORK_DIR/out" 2>&1 || status=$?
  return "$status"
}

# Prokop stays down as the user left it: no start ran, the user's stop and
# the end of the explicit start stay recorded, and no hand-off is left.
expect_user_stopped() {
  [ ! -e "$WORK_DIR/runtime.up" ] || fail "$1: Prokop runs after the user stopped it"
  [ ! -s "$WORK_DIR/starts" ] || fail "$1: Prokop was started after the user's stop"
  [ "$(stop_request_by)" = user ] || fail "$1: the user's stop is no longer recorded ($(stop_request_by))"
  [ ! -e "$PROKOP_RUNTIME_STATE_DIR/start.explicit" ] || fail "$1: postinst recorded an explicit start against the user's stop"
  [ ! -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] || fail "$1: the hand-off of the start was not consumed"
}

# ... and postinst consumed the hand-off of the start and logged why it
# made none.
expect_user_stop_holds() {
  expect_user_stopped "$1"
  grep -q 'not started after the package upgrade: it was stopped by the user' "$WORK_DIR/syslog" ||
    fail "$1: the log does not say why Prokop was not started"
  if grep -q 'did not start after the package upgrade' "$WORK_DIR/out"; then
    fail "$1: the user's stop was reported as a failed start"
  fi
}

# 1. Nobody stopped Prokop after prerm: postinst starts it again.
prerm_stopped
case="no stop after prerm"
postinst || fail "$case: postinst failed"
[ -e "$WORK_DIR/runtime.up" ] || fail "$case: Prokop was not started again after the upgrade"
[ ! -e "$PROKOP_RUNTIME_STATE_DIR/stop.requested" ] || fail "$case: the start left prerm's stop request"
[ -e "$PROKOP_RUNTIME_STATE_DIR/start.explicit" ] || fail "$case: the start was not recorded as explicit"
[ ! -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] || fail "$case: the hand-off of the start was not consumed"

# 2. The user stops Prokop between prerm and postinst.
prerm_stopped
user_stops
case="the user's stop between prerm and postinst"
postinst || fail "$case: postinst failed"
expect_user_stop_holds "$case"
# A later run of the package scripts (opkg configures a package again) has
# nothing to start.
postinst || fail "$case, run again: postinst failed"
expect_user_stop_holds "$case, run again"

# 3. The user's Stop gets procd's lock right before postinst's start, after
#    postinst has read prerm's stop request.
prerm_stopped
: >"$WORK_DIR/user-stop.before-start"
case="the user's stop right before postinst's start"
postinst || fail "$case: postinst failed"
[ -e "$WORK_DIR/user-stop.done" ] || fail "$case: the user's stop did not run"
[ "$(cat "$WORK_DIR/user-stop.done")" = 0 ] || fail "$case: the user's stop failed"
expect_user_stop_holds "$case"

# 4. The hand-off of a release whose prerm named no stop request: a stop of
#    the user's that is in effect came after prerm's.
prerm_stopped
printf '1\n' >"$PROKOP_PACKAGE_UPGRADE_STATE"
user_stops
case="the user's stop after the prerm of an older release"
postinst || fail "$case: postinst failed"
expect_user_stop_holds "$case"

# 5. The user stopped Prokop, then started it while reload.lock was busy: the
#    start was deferred (service/initd.uc defer_start) and keeps the user's
#    stop recorded until it runs. The upgrade comes first. prerm hands the
#    start over, and its stop, Prokop's own, cancels the deferred start. The
#    user's last request is the start: postinst makes it.
user_start_deferred() {
  reset_state
  user_stops
  local user_stop_line
  user_stop_line="$(sed -n 1p "$PROKOP_RUNTIME_STATE_DIR/stop.requested")"
  printf 'reason=start_deferred\nupdated_at=1\nstop_request=%s\n' "$user_stop_line" \
    >"$PROKOP_RUNTIME_STATE_DIR/start.retry"
  printf 'explicit\n' >"$PROKOP_RUNTIME_STATE_DIR/start.explicit"
  "$REAL_UCODE" -L "$LIB" "$LIB/service/initd.uc" deferred-start-pending ||
    fail "the deferred start after the user's stop is not pending"
}
user_start_deferred
prerm_upgrade
case="the user's start deferred after the user's stop"
[ -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] || fail "$case: prerm did not hand the deferred start over"
[ ! -e "$PROKOP_RUNTIME_STATE_DIR/start.retry" ] || fail "$case: prerm's stop did not cancel the deferred start"
[ "$(stop_request_by)" = package ] || fail "$case: prerm's stop was not recorded as the package's ($(stop_request_by))"
postinst || fail "$case: postinst failed"
[ -e "$WORK_DIR/runtime.up" ] || fail "$case: Prokop was not started after the upgrade"
[ "$(grep -c '^start$' "$WORK_DIR/starts" 2>/dev/null || true)" = 1 ] || fail "$case: Prokop was not started once"
[ ! -e "$PROKOP_RUNTIME_STATE_DIR/stop.requested" ] || fail "$case: the start left the stop request ($(stop_request_by))"
[ -e "$PROKOP_RUNTIME_STATE_DIR/start.explicit" ] || fail "$case: the start was not recorded as explicit"
[ ! -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] || fail "$case: the hand-off of the start was not consumed"
if grep -q 'stopped by the user' "$WORK_DIR/syslog"; then
  fail "$case: the log says the user stopped Prokop during the upgrade"
fi

# 6. The user's stop is under way when prerm looks: recorded, the runtime
#    not down yet (it waits for procd's lock or reload.lock). Its stop holds
#    Prokop down, also across the upgrade.
reset_state
: >"$WORK_DIR/runtime.up"
printf '1.000000001.1\nby=user\n' >"$PROKOP_RUNTIME_STATE_DIR/stop.requested"
prerm_upgrade
case="the user's stop under way when prerm looks"
postinst || fail "$case: postinst failed"
expect_user_stopped "$case"

# 7. The user's `prokop stop` lands while prerm's stop runs: after prerm's
#    own record, or between the record of service/initd.uc and that of
#    service/lifecycle.uc, which records prerm's stop as the user's.
for when in after between; do
  prokop_runs
  printf '%s\n' "$when" >"$WORK_DIR/cli-user-stop"
  prerm_upgrade
  case="the user's prokop stop during prerm's stop ($when)"
  [ -e "$WORK_DIR/cli-user-stop.done" ] || fail "$case: the user's stop did not run"
  postinst || fail "$case: postinst failed"
  expect_user_stop_holds "$case"
done

# 8. The user's Stop waits for procd's lock behind prerm's stop and records
#    its stop before prerm goes on.
prokop_runs
: >"$WORK_DIR/user-stop.queued"
prerm_upgrade
case="the user's stop queued behind prerm's stop"
[ -e "$WORK_DIR/user-stop.done" ] || fail "$case: the user's stop did not run"
[ "$(cat "$WORK_DIR/user-stop.done")" = 0 ] || fail "$case: the user's stop failed"
postinst || fail "$case: postinst failed"
expect_user_stop_holds "$case"

# 9. The user's start deferred after the user's stop, and the user's
#    `prokop stop` while prerm's stop runs: the later stop wins.
user_start_deferred
printf 'after\n' >"$WORK_DIR/cli-user-stop"
prerm_upgrade
case="the user's prokop stop during prerm's stop after the user's deferred start"
[ -e "$WORK_DIR/cli-user-stop.done" ] || fail "$case: the user's stop did not run"
postinst || fail "$case: postinst failed"
expect_user_stop_holds "$case"

printf 'package_postinst_user_stop: PASS\n'
