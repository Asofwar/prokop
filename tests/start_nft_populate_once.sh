#!/usr/bin/env bash
set -euo pipefail

# Start fills Prokop's nft sets once, inside the candidate transaction it
# commits atomically (UC-162). sing-box init-config ran the same population
# again right after the commit, live and outside any transaction (one
# `nft add element` per chunk): a second, non-atomic pass over sets the
# candidate had already filled. Start now passes populate 0 to init-config,
# as reload's prepare-config-stage does.
#
# The real service/lifecycle.uc start; every module it calls is a double that
# records its call (the harness of tests/cron_refresh_failure.sh).

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
# below. Locks and the stop request go to the real service/state.uc; the
# runtime runs while RUNNING is 1, not yet otherwise (a start).
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
line_of() { grep -nF -- "$1" "$EVENTS" | head -n 1 | cut -d: -f1; }

: >"$EVENTS"
STATUS=0
env PROKOP_LIB="$FAKE_LIB" RUNNING=0 ucode -L "$LIB" "$LIB/service/lifecycle.uc" start >"$WORK_DIR/lifecycle.out" 2>&1 ||
  STATUS=$?
wait_until 20 no_fake_modules || fail "the background workers of the start did not finish"
[ "$STATUS" = 0 ] || fail "the start failed (status $STATUS)"
has_event 'service/state.uc start-managed-sing-box-runtime' || fail "the start did not start sing-box"

[ "$(grep -cF 'nft/apply.uc nft-populate-runtime-sets-from-uci 1 ' "$EVENTS")" = 1 ] ||
  fail "the start must fill the runtime sets exactly once"
populate="$(line_of 'nft/apply.uc nft-populate-runtime-sets-from-uci 1 ')"
commit="$(line_of 'nft/apply.uc nft-apply-candidate-batch ')"
[ -n "$commit" ] || commit="$(line_of 'nft/apply.uc nft-commit-candidate-batch ')"
[ -n "$commit" ] || fail "the start did not commit an nft candidate"
[ "$populate" -lt "$commit" ] || fail "the runtime sets were not filled inside the candidate"
init="$(grep -F 'singbox/runtime.uc init-config ' "$EVENTS" | head -n 1)"
[ -n "$init" ] || fail "the start did not generate the sing-box configuration"
case "$init" in
  'singbox/runtime.uc init-config 0 '*) ;;
  *) fail "init-config after the committed candidate must not fill the nft sets again live: $init" ;;
esac
ok "start fills the nft sets once, inside the atomic candidate"
