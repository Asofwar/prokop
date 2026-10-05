#!/usr/bin/env bash
set -euo pipefail

# Prokop's scheduled updates need crond, and run only for a started Prokop.
#
# A6: OpenWrt's cron service does not start crond while there is no crontab.
# On a fresh router Prokop wrote its first jobs and they never ran until a
# reboot. The cron refresh now starts an enabled cron service that is not
# running; a disabled one is left alone, and the log says so.
#
# OBS-4: disabling autostart left the cron jobs in place. After a reboot the
# lists and subscriptions were downloaded for a Prokop that nobody started.
# The scheduled list and subscription updates now do nothing until Prokop
# is started, and after an explicit stop.
#
# components/updates.uc runs for real on the UCI fixture; the cron init
# script, crontab and logger are doubles.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in "$WORK/cron.calls" "$WORK/syslog"; do
    [ ! -s "$log" ] || sed "s|^|  $(basename "$log"): |" "$log" >&2
  done
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/crontabs"
export PATH="$WORK/bin:$PATH" WORK
export PROKOP_UCI_STATE_FILE="$WORK/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_CRONTAB_FILE="$WORK/crontabs/root"
export PROKOP_CRON_INIT="$WORK/bin/cron"
# The processes the refresh looks for crond in: none unless a case adds it.
export PROKOP_CROND_PROC_DIR="$WORK/proc"
export PROKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK/run/component-update-checks"
export PROKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK/run/component-update-check.timestamp"

printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$WORK/syslog"\n' >"$WORK/bin/logger"
cat >"$WORK/bin/crontab" <<'SH'
#!/bin/sh
cp "$1" "$PROKOP_CRONTAB_FILE"
SH
# OpenWrt's /etc/init.d/cron (#!/bin/sh /etc/rc.common): enabled, running,
# start as the test sets them.
cat >"$WORK/bin/cron" <<'SH'
#!/bin/sh
# /etc/rc.common stand-in
printf '%s\n' "$1" >>"$WORK/cron.calls"
case "$1" in
  enabled) [ -e "$WORK/cron.enabled" ] ;;
  running) [ -e "$WORK/cron.running" ] ;;
  start) : >"$WORK/cron.running" ;;
  *) exit 1 ;;
esac
SH
chmod 0755 "$WORK/bin/"*

updates() { ucode -L "$LIB" "$LIB/components/updates.uc" "$@"; }
markers=('# prokop-list-update' '# prokop-subscription-update' '# prokop-component-update-check')
reset_case() {
  rm -rf "$WORK/cron.calls" "$WORK/cron.enabled" "$WORK/cron.running" "$WORK/syslog" "$PROKOP_CRONTAB_FILE" "$WORK/proc"
  mkdir -p "$WORK/proc/1"
  printf 'init\n' >"$WORK/proc/1/comm"
  printf '%s\n' 'prokop.settings=settings' 'prokop.settings.component_update_check_enabled=1' \
    'prokop.settings.component_update_check_interval=1d' >"$WORK/uci.state"
}
refresh() { updates refresh-cron-from-uci /usr/bin/prokop "${markers[@]}" || fail "the cron refresh failed"; }
called() { grep -qx "$1" "$WORK/cron.calls" 2>/dev/null; }

# 1. A6: the first jobs start an enabled cron service that is not running.
reset_case
: >"$WORK/cron.enabled"
refresh
grep -Fq '# prokop-component-update-check' "$PROKOP_CRONTAB_FILE" || fail "the cron refresh wrote no job"
called start || fail "the cron service was not started for Prokop's first jobs"
grep -q 'Started the cron service' "$WORK/syslog" || fail "starting the cron service is not logged"

# 2. A running cron service is left alone.
reset_case
: >"$WORK/cron.enabled"
: >"$WORK/cron.running"
refresh
! called start || fail "a running cron service was started again"

# 3. A disabled cron service is not started; the log says why nothing runs.
reset_case
refresh
! called start || fail "a disabled cron service was started"
grep -q 'cron service is disabled' "$WORK/syslog" || fail "a disabled cron service is not logged"

# 4. Without Prokop jobs the cron service is not touched.
reset_case
printf '%s\n' 'prokop.settings=settings' >"$WORK/uci.state"
: >"$WORK/cron.enabled"
refresh
[ ! -e "$WORK/cron.calls" ] || fail "the cron service was touched without Prokop jobs: $(cat "$WORK/cron.calls")"

# 4b. A crond that runs is found without the init script: no rc.common
#     run on every start and reload (optimization 6).
reset_case
: >"$WORK/cron.enabled"
: >"$WORK/cron.running"
mkdir -p "$WORK/proc/812"
printf 'crond\n' >"$WORK/proc/812/comm"
refresh
grep -Fq '# prokop-component-update-check' "$PROKOP_CRONTAB_FILE" || fail "the cron refresh wrote no job next to a running crond"
[ ! -e "$WORK/cron.calls" ] || fail "the init script was asked about a crond that runs: $(cat "$WORK/cron.calls")"

# 5. OBS-4: the scheduled list and subscription updates wait for a start.
reset_case
rm -f "$WORK/run/start.explicit" "$WORK/run/stop.requested"
updates list-update-if-due || fail "a scheduled list update for a Prokop not started failed"
updates subscription-update-if-due || fail "a scheduled subscription update for a Prokop not started failed"
! grep -q 'subscription update' "$WORK/syslog" 2>/dev/null || fail "a subscription update ran for a Prokop not started"
: >"$WORK/run/start.explicit"
: >"$WORK/run/stop.requested"
updates subscription-update-if-due || fail "a scheduled subscription update after a stop failed"
! grep -q 'subscription update' "$WORK/syslog" 2>/dev/null || fail "a subscription update ran after an explicit stop"
rm -f "$WORK/run/stop.requested"
# A started Prokop goes on to the interval (none is set here: status 1).
status=0
updates list-update-if-due >/dev/null 2>&1 || status=$?
[ "$status" = 1 ] || fail "the scheduled list update of a started Prokop did not check its interval (status $status)"

printf 'cron service start checks passed\n'
