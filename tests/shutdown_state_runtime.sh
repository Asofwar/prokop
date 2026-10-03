#!/usr/bin/env bash
set -euo pipefail

# Whether the last Forkop runtime was stopped cleanly (UC-160).
#
# The lifecycle records it for dns/apply.uc, which skips dnsmasq work that is
# already done. It is runtime state, not configuration: start and stop do not
# write /etc/config/forkop for it (a flash write and a commit of the whole
# package on every start and stop), a failure to record it fails neither of
# them (a full or read-only overlay must not keep Forkop from starting), it
# is written only when it changes, and dns/apply.uc reads the record, not the
# shutdown_correctly option that older releases kept in the configuration.
#
# Part 1 runs the real dns/apply.uc on the UCI fixture. Part 2 runs the real
# service/lifecycle.uc start and stop with every module they call replaced by
# a double (as tests/stop_during_start.sh does).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

FAKE_LIB="$WORK_DIR/fake-lib"
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

no_fake_modules() { ! pgrep -f "$FAKE_LIB/" >/dev/null 2>&1; }

STATE_DIR="$WORK_DIR/run/forkop"
RECORD="$STATE_DIR/shutdown_correctly"
mkdir -p "$WORK_DIR/bin" "$STATE_DIR" "$WORK_DIR/tmp" "$FAKE_LIB"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" EVENTS TEST_LIB="$LIB"
export FORKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/forkop.reload.lock"
export FORKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.config"
export FORKOP_DNSMASQ_CONFIG_FILE="$WORK_DIR/dhcp.config"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_UI_ACTION_TRACKED=1
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_UCI_LOG_FILE="$WORK_DIR/uci.log"
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export FORKOP_CONFIG_NAME=forkop
export SB_DNS_INBOUND_ADDRESS=127.0.0.42

# Nothing here may reach the host's syslog, nftables, dnsmasq or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/init"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/forkop"
printf '#!/bin/sh\nprintf "dnsmasq %%s\\n" "$*" >>"$EVENTS"\n' >"$DNSMASQ_INIT"
chmod 0755 "$WORK_DIR"/bin/*
printf 'config dnsmasq\n' >"$FORKOP_DNSMASQ_CONFIG_FILE"
: >"$FORKOP_CONFIG_FILE"

# ---- 1. dns/apply.uc follows the runtime record ------------------------------

# dnsmasq already forwards to sing-box.
complete_dhcp() {
  cat >"$FORKOP_UCI_STATE_FILE" <<EOF
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].noresolv=1
dhcp.@dnsmasq[0].cachesize=0
dhcp.@dnsmasq[0].forkop_server=1.1.1.1
forkop.settings=settings
${1:-}
EOF
}
# dnsmasq has its own upstream.
plain_dhcp() {
  cat >"$FORKOP_UCI_STATE_FILE" <<EOF
dhcp.@dnsmasq[0].server=1.1.1.1
forkop.settings=settings
${1:-}
EOF
}
# record <0|1|absent>
record() {
  rm -rf "$RECORD"
  [ "$1" = absent ] || printf '%s\n' "$1" >"$RECORD"
}
dns_apply() {
  : >"$EVENTS"
  : >"$FORKOP_UCI_LOG_FILE"
  ucode -L "$LIB" "$LIB/dns/apply.uc" "$@" >/dev/null 2>&1
}
restarted() { grep -Fxq 'dnsmasq restart' "$EVENTS"; }

# Running (or crashed) Forkop, or a new boot: dnsmasq already runs with the
# configuration that forwards to sing-box.
for state in 0 absent; do
  complete_dhcp; record "$state"
  dns_apply configure || fail "configure with record $state failed"
  restarted && fail "configure with record $state restarted dnsmasq that already forwards to sing-box"
  ok "configure with record $state leaves dnsmasq that already forwards to sing-box alone"
done
# After a clean stop the configuration is applied in full.
complete_dhcp; record 1
dns_apply configure || fail "configure after a clean stop failed"
restarted || fail "configure after a clean stop did not restart dnsmasq"
ok "configure after a clean stop applies the configuration and restarts dnsmasq"
# The UCI option of older releases is no longer read.
complete_dhcp 'forkop.settings.shutdown_correctly=0'; record 1
dns_apply configure || fail "configure with a stale UCI option failed"
restarted || fail "configure followed the stale shutdown_correctly option in UCI, not the runtime record"
ok "configure ignores the shutdown_correctly option older releases kept in UCI"

# Stopped cleanly, or a new boot: dnsmasq uses its own upstream already.
for state in 1 absent; do
  plain_dhcp; record "$state"
  dns_apply restore || fail "restore with record $state failed"
  restarted && fail "restore with record $state restarted dnsmasq that already uses its own upstream"
  ok "restore with record $state leaves dnsmasq with its own upstream alone"
done
plain_dhcp; record 0
dns_apply restore || fail "restore after an unclean shutdown failed"
restarted || fail "restore after an unclean shutdown did not restart dnsmasq"
ok "restore after an unclean shutdown restores in full"
plain_dhcp 'forkop.settings.shutdown_correctly=1'; record 0
dns_apply restore || fail "restore with a stale UCI option failed"
restarted || fail "restore followed the stale shutdown_correctly option in UCI, not the runtime record"
ok "restore ignores the shutdown_correctly option older releases kept in UCI"

# ---- 2. lifecycle start and stop -----------------------------------------------

# Every module start and stop call: records "<module> <mode>" and succeeds.
# Locks go to the real service/state.uc.
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
system("printf '%s\\\\n' " + q(name + " " + mode) + " >> " + q(getenv("EVENTS")));
if (name == "service/state.uc" && (mode == "has-list-update-sources" || mode == "forkop-stably-running" ||
    mode == "sing-box-process-conflict" || mode == "forkop-running"))
    exit(1);
exit(0);
UC
}
for module in service/state.uc subscription/cache.uc config/validator.uc nft/apply.uc singbox/runtime.uc \
  singbox/priority.uc singbox/dns_failover.uc singbox/ruleset_cache.uc components/updates.uc \
  autotune/manager.uc providers/byedpi/runtime.uc providers/zapret/runtime.uc providers/zapret2/runtime.uc \
  dns/apply.uc diagnostics/runtime.uc diagnostics/health.uc config/snapshots.uc core/packages.uc \
  service/ui.uc service/reload.uc service/lifecycle.uc killswitch/runtime.uc; do
  fake_module "$module"
done

printf 'forkop.settings=settings\nforkop.settings.yacd_secret_key=0123456789abcdef\nforkop.settings.dont_touch_dhcp=0\n' \
  >"$WORK_DIR/uci.base"

# lifecycle <start|stop>: the exit status in LIFECYCLE_STATUS.
lifecycle() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  LIFECYCLE_STATUS=0
  env FORKOP_LIB="$FAKE_LIB" ucode -L "$LIB" "$LIB/service/lifecycle.uc" "$1" >"$WORK_DIR/lifecycle.out" 2>&1 ||
    LIFECYCLE_STATUS=$?
  wait_until 20 no_fake_modules || fail "the background workers of $1 did not finish"
}
uci_flag_written() { grep -q 'shutdown_correctly' "$FORKOP_UCI_STATE_FILE" || grep -q 'commit forkop' "$UCI_LOG"; }

# 2a. A full or read-only overlay: every commit of a configuration fails.
cp "$WORK_DIR/uci.base" "$FORKOP_UCI_STATE_FILE"
rm -rf "$RECORD" "$FORKOP_UCI_LOG_FILE"
mkdir "$FORKOP_UCI_LOG_FILE"
UCI_LOG="/dev/null"
lifecycle start
[ "$LIFECYCLE_STATUS" = 0 ] || fail "start failed (status $LIFECYCLE_STATUS) while the configuration cannot be committed"
grep -Fxq 'dns/apply.uc configure' "$EVENTS" || fail "the start did not configure dnsmasq"
[ "$(cat "$RECORD" 2>/dev/null)" = 0 ] || fail "the start did not record a running Forkop"
grep -q 'shutdown_correctly' "$FORKOP_UCI_STATE_FILE" && fail "the start wrote shutdown_correctly into the configuration"
ok "start records the running runtime outside the configuration and succeeds on a read-only overlay"
lifecycle stop
[ "$LIFECYCLE_STATUS" = 0 ] || fail "stop failed (status $LIFECYCLE_STATUS) while the configuration cannot be committed"
grep -Fxq 'dns/apply.uc restore' "$EVENTS" || fail "the stop did not restore dnsmasq"
grep -Fxq 'dns/apply.uc failsafe-restore' "$EVENTS" && fail "a clean stop ran the DNS failsafe"
[ "$(cat "$RECORD" 2>/dev/null)" = 1 ] || fail "the stop did not record a clean stop"
grep -q 'shutdown_correctly' "$FORKOP_UCI_STATE_FILE" && fail "the stop wrote shutdown_correctly into the configuration"
ok "stop records the clean stop outside the configuration and succeeds on a read-only overlay"
# br_netfilter's hooks go back at the stop, not at the start (D-19, UC-109).
grep -Fxq 'nft/apply.uc restore-bridge-netfilter' "$EVENTS" || fail "the stop did not restore br_netfilter's hooks"
lifecycle start
grep -Fxq 'nft/apply.uc restore-bridge-netfilter' "$EVENTS" && fail "the start restored br_netfilter's hooks"
grep -Fxq 'nft/apply.uc ensure-bridge-netfilter-disabled' "$EVENTS" || fail "the start did not turn br_netfilter's hooks off"
lifecycle restart
grep -Fxq 'nft/apply.uc ensure-bridge-netfilter-disabled' "$EVENTS" || fail "the restart did not start again"
grep -Fxq 'nft/apply.uc restore-bridge-netfilter' "$EVENTS" && fail "lifecycle's restart put br_netfilter's hooks back between its stop and start"
lifecycle stop
# (/etc/init.d/forkop restart is a stop and a start: it puts them back and
# turns them off again.)
ok "stop puts br_netfilter's hooks back, start and lifecycle's restart do not"
rmdir "$FORKOP_UCI_LOG_FILE"

# 2b. Neither writes the configuration, also where it can be written.
cp "$WORK_DIR/uci.base" "$FORKOP_UCI_STATE_FILE"
UCI_LOG="$FORKOP_UCI_LOG_FILE"
: >"$UCI_LOG"
lifecycle start
[ "$LIFECYCLE_STATUS" = 0 ] || fail "start failed (status $LIFECYCLE_STATUS)"
lifecycle stop
[ "$LIFECYCLE_STATUS" = 0 ] || fail "stop failed (status $LIFECYCLE_STATUS)"
uci_flag_written && fail "start or stop wrote the configuration: $(cat "$UCI_LOG")"
ok "start and stop leave /etc/config/forkop alone"

# 2c. The record is written only when it changes.
printf '1\n' >"$RECORD"
touch -d '@1000000000' "$RECORD"
lifecycle stop
[ "$LIFECYCLE_STATUS" = 0 ] || fail "a second stop failed (status $LIFECYCLE_STATUS)"
[ "$(stat -c %Y "$RECORD")" = 1000000000 ] || fail "a stop rewrote an unchanged record"
lifecycle start
[ "$(cat "$RECORD")" = 0 ] || fail "the start did not record a running Forkop after a stop"
touch -d '@1000000000' "$RECORD"
lifecycle start
[ "$LIFECYCLE_STATUS" = 0 ] || fail "a second start failed (status $LIFECYCLE_STATUS)"
[ "$(stat -c %Y "$RECORD")" = 1000000000 ] || fail "a start rewrote an unchanged record"
ok "the record is written only when it changes"

# 2d. A record that cannot be written fails neither start nor stop.
rm -f "$RECORD"
mkdir "$RECORD"
lifecycle start
[ "$LIFECYCLE_STATUS" = 0 ] || fail "start failed (status $LIFECYCLE_STATUS) because the record cannot be written"
grep -q 'Could not record' "$WORK_DIR/syslog" || fail "a record that cannot be written was not logged"
lifecycle stop
[ "$LIFECYCLE_STATUS" = 0 ] || fail "stop failed (status $LIFECYCLE_STATUS) because the record cannot be written"
grep -Fxq 'dns/apply.uc failsafe-restore' "$EVENTS" && fail "a record that cannot be written ran the DNS failsafe"
rmdir "$RECORD"
ok "a record that cannot be written fails neither start nor stop"

# 2e. A start that fails after dnsmasq was configured is cleaned up and
#     recorded as stopped cleanly.
rm -f "$RECORD"
: >"$UCI_LOG"
cp "$WORK_DIR/uci.base" "$FORKOP_UCI_STATE_FILE"
fake_module_fail() {
  sed -i 's|^exit(0);$|if (name + " " + mode == "service/state.uc wait-forkop-stable-start") exit(1);\nexit(0);|' \
    "$FAKE_LIB/service/state.uc"
}
fake_module_fail
lifecycle start
[ "$LIFECYCLE_STATUS" != 0 ] || fail "a start whose verification failed reported success"
grep -Fxq 'dns/apply.uc failsafe-restore' "$EVENTS" || fail "the failed start did not roll back dnsmasq"
[ "$(cat "$RECORD" 2>/dev/null)" = 1 ] || fail "the cleaned-up start was not recorded as stopped cleanly"
uci_flag_written && fail "the failed start wrote the configuration: $(cat "$UCI_LOG")"
ok "a failed start is cleaned up and recorded as stopped, outside the configuration"

# ---- 3. a dhcp change that cannot be saved (UC-024) ----------------------------

# The real dns/apply.uc behind the lifecycle, on the UCI fixture, whose
# commits fail while its log cannot be written (a full or read-only
# overlay). The stop and the start then fail and run their DNS failsafe.
cat >"$FAKE_LIB/dns/apply.uc" <<'UC'
function q(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
system("printf '%s\\n' " + q("dns/apply.uc " + join(" ", ARGV)) + " >> " + q(getenv("EVENTS")));
let command = "ucode -L " + q(getenv("TEST_LIB")) + " " + q(getenv("TEST_LIB") + "/dns/apply.uc");
for (let arg in ARGV)
    command += " " + q(arg);
exit(system(command));
UC
sed -i 's|^if (name + " " + mode == "service/state.uc wait-forkop-stable-start") exit(1);$||' "$FAKE_LIB/service/state.uc"
rm -f "$FORKOP_UCI_LOG_FILE"
mkdir "$FORKOP_UCI_LOG_FILE"

cat "$WORK_DIR/uci.base" - >"$FORKOP_UCI_STATE_FILE" <<'EOF'
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].forkop_server=1.1.1.1
dhcp.@dnsmasq[0].noresolv=1
dhcp.@dnsmasq[0].forkop_noresolv=0
dhcp.@dnsmasq[0].cachesize=0
dhcp.@dnsmasq[0].forkop_cachesize=150
EOF
printf '0\n' >"$RECORD"
lifecycle stop
[ "$LIFECYCLE_STATUS" != 0 ] || fail "a stop whose dnsmasq settings could not be saved reported success"
grep -Fxq 'dns/apply.uc failsafe-restore' "$EVENTS" || fail "the failed stop did not run the DNS failsafe"
grep -Fxq 'dnsmasq restart' "$EVENTS" && fail "the stop restarted dnsmasq with settings that were not saved"
grep -q 'Could not save the dnsmasq settings' "$WORK_DIR/syslog" || fail "the failed dhcp commit was not logged"
ok "a stop whose dnsmasq settings cannot be saved fails and runs the DNS failsafe"

cat "$WORK_DIR/uci.base" - >"$FORKOP_UCI_STATE_FILE" <<'EOF'
dhcp.@dnsmasq[0].server=1.1.1.1
EOF
printf '1\n' >"$RECORD"
lifecycle start
[ "$LIFECYCLE_STATUS" != 0 ] || fail "a start whose dnsmasq settings could not be saved reported success"
grep -Fxq 'dns/apply.uc configure' "$EVENTS" || fail "the start did not configure dnsmasq"
grep -Fxq 'dns/apply.uc failsafe-restore' "$EVENTS" || fail "the failed start did not run the DNS failsafe"
# The failsafe finds the settings as they were (nothing of the configure was
# saved) and may restart dnsmasq with them; the configure must not.
sed '/^dns\/apply.uc failsafe-restore$/,$d' "$EVENTS" | grep -Fxq 'dnsmasq restart' &&
  fail "the start restarted dnsmasq with settings that were not saved"
grep -Fxq 'dhcp.@dnsmasq[0].server=1.1.1.1' "$FORKOP_UCI_STATE_FILE" && ! grep -q '127.0.0.42\|forkop_' "$FORKOP_UCI_STATE_FILE" ||
  fail "the failed start left Forkop settings in dnsmasq: $(cat "$FORKOP_UCI_STATE_FILE")"
ok "a start whose dnsmasq settings cannot be saved fails and is cleaned up"
rmdir "$FORKOP_UCI_LOG_FILE"

printf 'shutdown state runtime checks passed\n'
