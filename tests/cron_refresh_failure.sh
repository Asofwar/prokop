#!/usr/bin/env bash
set -euo pipefail

# A cron refresh that fails does not take the proxy down (S5 integration,
# UC-159).
#
# Since the crontab is read back after `crontab` (cddbba56), a nearly full
# overlay or a change another writer made at the same moment fails the
# refresh of Prokop's scheduled jobs. Start and reload aborted at phase
# cron-refresh then: the start left Prokop down and the reload rolled back,
# because the scheduled-jobs file could not be written. Now both carry on,
# and the failure is not masked: an error in the system log and a
# cron_refresh failure in the history (diagnostics/health.uc).
#
# The real service/lifecycle.uc start and reload; every module they call is
# a double that records its call (as tests/shutdown_state_runtime.sh and
# tests/dnsmasq_reload_rollback.sh do).
#
# The next reload refreshes the jobs again: the reload state that the start
# or reload records keeps the cron settings unapplied. It recorded them as
# applied, so a reload with unchanged settings skipped the refresh and only
# a start brought the jobs back (S5 integration review). Here the reload
# state and the reload plan are the real service/state.uc and
# service/reload.uc.
#
# An invalid interval in the settings (components/updates.uc exit status 2)
# is a configuration error, not a crontab that could not be written: it
# still fails the start and the reload, as before.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

FAKE_LIB="$WORK_DIR/fake-lib"
no_fake_modules() { ! pgrep -f "$FAKE_LIB/" >/dev/null 2>&1; }
cleanup() {
  # The lifecycle leaves its background workers (doubles) running briefly.
  wait_until 20 no_fake_modules || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in "$EVENTS" "$WORK_DIR/syslog" "$WORK_DIR/lifecycle.out"; do
    [ ! -s "$log" ] || sed "s|^|  $(basename "$log"): |" "$log" >&2
  done
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

STATE_DIR="$WORK_DIR/run/prokop"
mkdir -p "$WORK_DIR/bin" "$STATE_DIR" "$WORK_DIR/tmp" "$FAKE_LIB"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" EVENTS TEST_LIB="$LIB"
export PROKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/prokop.reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$STATE_DIR/subscription-update.lock"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export PROKOP_CONFIG_FILE="$WORK_DIR/prokop.config"
export PROKOP_DNSMASQ_CONFIG_FILE="$WORK_DIR/dhcp.config"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_UI_ACTION_TRACKED=1
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_UCI_LOG_FILE="$WORK_DIR/uci.log"
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export KILLSWITCH_STATE_DIR="$WORK_DIR/killswitch"
export PROKOP_CONFIG_NAME=prokop
export SB_DNS_INBOUND_ADDRESS=127.0.0.42

# Nothing here may reach the host's syslog, nftables, dnsmasq or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/init"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/prokop"
printf '#!/bin/sh\nexit 0\n' >"$DNSMASQ_INIT"
chmod 0755 "$WORK_DIR"/bin/*
printf 'config dnsmasq\n' >"$PROKOP_DNSMASQ_CONFIG_FILE"
: >"$PROKOP_CONFIG_FILE"
printf 'prokop.settings=settings\nprokop.settings.yacd_secret_key=0123456789abcdef\nprokop.settings.dont_touch_dhcp=1\n' \
  >"$PROKOP_UCI_STATE_FILE"

# Every module call: records "<module> <arguments>" and succeeds, except as
# below. Locks and the stop request go to the real service/state.uc. The
# cron refresh exits with CRON_FAILS (1: the crontab could not be written,
# 2: an invalid interval in the settings); the runtime runs while RUNNING
# is 1 (a reload), not yet otherwise (a start). The reload plan comes from
# PLAN ("key=value ...").
fake_module() {
  mkdir -p "$(dirname "$FAKE_LIB/$1")"
  cat >"$FAKE_LIB/$1" <<UC
function q(value) { return "'" + replace("" + value, /'/g, "'\\\\''") + "'"; }
let mode = "" + (ARGV[0] ?? "");
let name = "$1";
if (name == "service/state.uc" && (index(mode, "runtime-dir-lock") >= 0 || mode == "runtime-apply-allowed" ||
    mode == "stop-requested")) {
    let command = "ucode -L " + q(getenv("TEST_LIB")) + " " + q(getenv("TEST_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    exit(system(command));
}
system("printf '%s\\\\n' " + q(name + " " + join(" ", ARGV)) + " >> " + q(getenv("EVENTS")));
let running = getenv("RUNNING") == "1";
if (name == "service/state.uc" && (mode == "has-list-update-sources" || mode == "has-nft-list-update-sources" ||
    mode == "sing-box-process-conflict"))
    exit(1);
if (name == "service/state.uc" && (mode == "prokop-stably-running" || mode == "prokop-running"))
    exit(running ? 0 : 1);
if (name == "service/state.uc" && mode == "sing-box-service-runtime-pid") {
    print("4242\\n");
    exit(0);
}
// REAL_RELOAD_STATE=1: the reload state goes through the real service/state.uc
// (without its cleanup of the rule-condition caches) and, without PLAN, the
// reload plan through the real service/reload.uc.
let real_state = { "capture-reload-state": true, "write-captured-reload-state": true,
    "write-current-reload-state-clean": true, "mark-reload-state-cron-unapplied": true };
if (getenv("REAL_RELOAD_STATE") == "1" && ((name == "service/state.uc" && real_state[mode]) ||
    (name == "service/reload.uc" && mode == "plan-state-files" && getenv("PLAN") == null))) {
    let args = [ ...ARGV ];
    if (mode == "write-current-reload-state-clean")
        args = [ "write-current-reload-state", ARGV[1], ARGV[2] ];
    else if (mode == "write-captured-reload-state")
        args = [ mode, ARGV[1], ARGV[2], ARGV[3], "", "0", ARGV[6] ];
    let command = "ucode -L " + q(getenv("TEST_LIB")) + " " + q(getenv("TEST_LIB") + "/" + name);
    for (let arg in args)
        command += " " + q(arg);
    exit(system(command));
}
if (name == "service/reload.uc" && mode == "plan-state-files") {
    for (let item in split(trim(getenv("PLAN") ?? ""), " "))
        if (item != "")
            print(replace(item, "=", "\\t"), "\\n");
    exit(0);
}
if (name == "components/updates.uc" && mode == "refresh-cron-from-uci")
    exit(int(getenv("CRON_FAILS") ?? "0"));
exit(mode == "runtime-cache-needs-rebuild" ? 1 : 0);
UC
}
for module in service/state.uc subscription/cache.uc config/validator.uc nft/apply.uc singbox/runtime.uc \
  singbox/priority.uc singbox/dns_failover.uc singbox/ruleset_cache.uc components/updates.uc \
  autotune/manager.uc providers/byedpi/runtime.uc providers/zapret/runtime.uc providers/zapret2/runtime.uc \
  dns/apply.uc diagnostics/runtime.uc diagnostics/health.uc config/snapshots.uc core/packages.uc \
  service/ui.uc service/reload.uc service/lifecycle.uc killswitch/runtime.uc; do
  fake_module "$module"
done

has_event() { grep -Fq -- "$1" "$EVENTS"; }
cron_failure_reported() {
  has_event 'components/updates.uc refresh-cron-from-uci' || fail "$1: the cron refresh did not run"
  grep -F '[error]' "$WORK_DIR/syslog" | grep -Fiq 'scheduled jobs' ||
    fail "$1: the failed cron refresh was not logged as an error"
  has_event 'diagnostics/health.uc record cron_refresh failure' ||
    fail "$1: the failed cron refresh was not recorded in the history"
}

# ---- start ---------------------------------------------------------------------

start() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  STATUS=0
  env PROKOP_LIB="$FAKE_LIB" RUNNING=0 ucode -L "$LIB" "$LIB/service/lifecycle.uc" start >"$WORK_DIR/lifecycle.out" 2>&1 ||
    STATUS=$?
  wait_until 20 no_fake_modules || fail "the background workers of the start did not finish"
}

CRON_FAILS=0 start
[ "$STATUS" = 0 ] || fail "the control start failed (status $STATUS)"
has_event 'service/state.uc start-managed-sing-box-runtime' || fail "the control start did not start sing-box"
has_event 'record cron_refresh' && fail "a start whose cron refresh succeeded recorded a cron_refresh event"

export CRON_FAILS=1
start
[ "$STATUS" = 0 ] || fail "a start whose cron refresh failed did not bring Prokop up (status $STATUS)"
has_event 'service/state.uc start-managed-sing-box-runtime' || fail "a start whose cron refresh failed did not start sing-box"
grep -q "phase 'cron-refresh' failed" "$WORK_DIR/syslog" && fail "the start still failed at phase cron-refresh"
cron_failure_reported "the start"
has_event 'diagnostics/health.uc record start success' || fail "the start was not recorded as a success"
ok "a start whose cron refresh failed brings Prokop up and reports the failed refresh"

# ---- reload --------------------------------------------------------------------

# The reload under reload.lock, as init.d runs it.
cat >"$WORK_DIR/reload" <<'SH'
#!/bin/sh
state() { ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" "$@"; }
state acquire-runtime-dir-lock "$PROKOP_RELOAD_LOCK_DIR" "$$" || exit 99
env PROKOP_LIB="$FAKE_LIB" RUNNING=1 ucode -L "$TEST_LIB" "$TEST_LIB/service/lifecycle.uc" reload "${RELOAD_REASON:-}"
status=$?
state release-runtime-dir-lock "$PROKOP_RELOAD_LOCK_DIR" "$$"
exit "$status"
SH
chmod 0755 "$WORK_DIR/reload"
export FAKE_LIB
reload() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  STATUS=0
  env PLAN="has_work=1 changed_cron=1 needs_cron_refresh=1" "$WORK_DIR/reload" >"$WORK_DIR/lifecycle.out" 2>&1 ||
    STATUS=$?
  wait_until 20 no_fake_modules || fail "the background workers of the reload did not finish"
}

CRON_FAILS=0 reload
[ "$STATUS" = 0 ] || fail "the control reload failed (status $STATUS)"
has_event 'service/state.uc write-captured-reload-state' || fail "the control reload did not record its state"

reload
[ "$STATUS" = 0 ] || fail "a reload whose cron refresh failed was rolled back (status $STATUS)"
has_event 'service/state.uc write-captured-reload-state' ||
  fail "a reload whose cron refresh failed did not record the applied state"
cron_failure_reported "the reload"
has_event 'diagnostics/health.uc record reload success' || fail "the reload was not recorded as a success"
ok "a reload whose cron refresh failed completes and reports the failed refresh"

# ---- an invalid interval -------------------------------------------------------

CRON_FAILS=2 start
[ "$STATUS" != 0 ] || fail "a start with an invalid cron interval succeeded"
grep -q "phase 'cron-refresh' failed" "$WORK_DIR/syslog" || fail "a start with an invalid cron interval did not fail at phase cron-refresh"
has_event 'service/state.uc start-managed-sing-box-runtime' && fail "a start with an invalid cron interval started sing-box"
has_event 'record cron_refresh' && fail "a start with an invalid cron interval recorded a cron_refresh event"
CRON_FAILS=2 reload
[ "$STATUS" != 0 ] || fail "a reload with an invalid cron interval succeeded"
has_event "service/state.uc write-captured-reload-state $STATE_DIR/reload-state " &&
  fail "a reload with an invalid cron interval recorded the applied state"
ok "an invalid cron interval still fails the start and the reload"

# ---- the next reload refreshes the jobs again ----------------------------------

export REAL_RELOAD_STATE=1
state() { ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }
# A reload after a change of the configuration (procd's config trigger, a
# Save & Apply), with the real plan from the reload state recorded before it.
reload_real() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  STATUS=0
  RELOAD_REASON=on_config_change "$WORK_DIR/reload" >"$WORK_DIR/lifecycle.out" 2>&1 || STATUS=$?
  wait_until 20 no_fake_modules || fail "the background workers of the reload did not finish"
}
refreshed() { has_event 'components/updates.uc refresh-cron-from-uci'; }

# The cron settings changed since the last reload.
state write-current-reload-state "$STATE_DIR/reload-state" 1 || fail "could not write the reload state"
sed -i 's/^cron_signature=.*/cron_signature=before/' "$STATE_DIR/reload-state"
CRON_FAILS=1 reload_real
[ "$STATUS" = 0 ] || fail "the reload with changed cron settings failed (status $STATUS)"
refreshed || fail "the reload with changed cron settings did not refresh the jobs"
cron_failure_reported "the reload with changed cron settings"
CRON_FAILS=0 reload_real
[ "$STATUS" = 0 ] || fail "the reload after a failed cron refresh failed (status $STATUS)"
refreshed || fail "the reload after a failed cron refresh did not refresh the jobs again"
CRON_FAILS=0 reload_real
[ "$STATUS" = 0 ] || fail "the reload after a cron refresh failed (status $STATUS)"
refreshed && fail "a reload with unchanged cron settings refreshed the jobs although the last refresh succeeded"
grep -q 'Reload skipped' "$WORK_DIR/syslog" || fail "a reload with nothing to apply was not skipped"
ok "the next reload refreshes the jobs that a reload could not write"

CRON_FAILS=1 start
[ "$STATUS" = 0 ] || fail "a start whose cron refresh failed did not bring Prokop up (status $STATUS)"
cron_failure_reported "the start before the reload"
CRON_FAILS=0 reload_real
[ "$STATUS" = 0 ] || fail "the reload after a start whose cron refresh failed failed (status $STATUS)"
refreshed || fail "the reload after a start whose cron refresh failed did not refresh the jobs again"
ok "the next reload refreshes the jobs that a start could not write"

printf 'cron refresh failure checks passed\n'
