#!/usr/bin/env bash
# Prokop never starts next to the active product before the rename
# (core/legacy_forkop.uc): both drive the same sing-box service, dnsmasq and
# policy routing table. A start, a restart and init.d's start (a package
# install starts every init script) are refused with the installer to run,
# record no explicit start and schedule no retry, while that product's nft
# runtime table exists or its init script reports it running. Its installed
# but stopped files alone do not block. Prokop's own stop then touches nothing
# the two share.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
FAKE_LIB="$WORK_DIR/fake-lib"
LEGACY_ROOT="$WORK_DIR/legacy-root"
RUN="$WORK_DIR/run/prokop"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in events syslog out; do
    printf '%s:\n' "$log" >&2
    cat "$WORK_DIR/$log" >&2 2>/dev/null || true
  done
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/tables" "$RUN"
# Every module lifecycle.uc runs is a double that records its call. The
# ownership check reports a conflict (unless FAKE_CONFLICT=1): a start that
# passed the guard stops there, before any runtime change. Prokop's own
# runtime is down.
for module in service/state.uc diagnostics/health.uc dns/apply.uc nft/apply.uc singbox/dns_failover.uc \
  singbox/priority.uc subscription/cache.uc components/updates.uc providers/zapret/runtime.uc \
  providers/zapret2/runtime.uc providers/byedpi/runtime.uc config/validator.uc config/snapshots.uc; do
  mkdir -p "$(dirname "$FAKE_LIB/$module")"
  cat >"$FAKE_LIB/$module" <<UCODE
let fs = require("fs");
let log = fs.open(getenv("EVENTS"), "a");
log.write("$module " + join(" ", ARGV) + "\n");
log.close();
if (ARGV[0] == "sing-box-process-conflict")
    exit(int(getenv("FAKE_CONFLICT") || "0"));
exit(ARGV[0] == "prokop-stably-running" || ARGV[0] == "prokop-running" || ARGV[0] == "has-managed-state" ? 1 : 0);
UCODE
done
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf 'nft %s\n' "$*" >>"$EVENTS"
case "$1 $2" in
  "list tables")
    for table in "$TABLES"/*; do
      [ -e "$table" ] && printf 'table inet %s\n' "${table##*/}"
    done
    exit 0 ;;
  "list table") [ -e "$TABLES/$4" ]; exit $? ;;
esac
exit 1
SH
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK_DIR/syslog" >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
# `prokop start|stop` behind init.d: records the call; FAKE_START_FAILURE makes
# the start fail with a not-retryable mark, as service/lifecycle.uc does.
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
printf 'prokop %s\n' "$*" >>"$EVENTS"
if [ "$1" = start ] && [ -n "${FAKE_START_FAILURE:-}" ]; then
  printf 'reason=%s\n' "$FAKE_START_FAILURE" >"$PROKOP_RUNTIME_STATE_DIR/start.failure"
  exit 1
fi
exit 0
SH
chmod 0755 "$WORK_DIR/bin/"*
cat >"$WORK_DIR/uci.state" <<'EOF'
prokop.settings=settings
prokop.settings.dont_touch_dhcp=0
EOF

export EVENTS="$WORK_DIR/events" TABLES="$WORK_DIR/tables"
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LEGACY_FORKOP_ROOT="$LEGACY_ROOT"
export PROKOP_RUNTIME_STATE_DIR="$RUN"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/prokop.reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$RUN/reload.pending"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$RUN/subscription-update.lock"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_CONFIG_FILE="$WORK_DIR/prokop.config"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_UI_ACTION_TRACKED=1
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
: >"$WORK_DIR/prokop.config"

INSTALL_HINT='Run the Prokop installer to migrate: wget -qO- https://asofwar.github.io/prokop/install.sh | sh'

reset_case() {
  rm -rf "$LEGACY_ROOT" "$RUN" "$WORK_DIR/tables"/*
  mkdir -p "$RUN"
  : >"$EVENTS"; : >"$WORK_DIR/syslog"; : >"$WORK_DIR/out"
}

# legacy STATE: the old product is "running" (its init script says so),
# "stopped" (installed, nothing runs) or left only its runtime state, with
# its nft runtime table when "table" follows.
legacy() {
  mkdir -p "$LEGACY_ROOT/etc/init.d" "$LEGACY_ROOT/var/run/forkop"
  case "$1" in
    running) printf '#!/bin/sh\n[ "$1" != status ] || exit 0\nexit 1\n' >"$LEGACY_ROOT/etc/init.d/forkop" ;;
    stopped) printf '#!/bin/sh\nexit 1\n' >"$LEGACY_ROOT/etc/init.d/forkop" ;;
  esac
  [ ! -e "$LEGACY_ROOT/etc/init.d/forkop" ] || chmod 0755 "$LEGACY_ROOT/etc/init.d/forkop"
  [ "${2:-}" != table ] || touch "$WORK_DIR/tables/ForkopTable"
}

lifecycle() {
  env PROKOP_LIB="$FAKE_LIB" ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" "$@" >"$WORK_DIR/out" 2>&1
}

initd() {
  env PROKOP_LIB="$FAKE_LIB" ucode -L "$REAL_LIB" "$REAL_LIB/service/initd.uc" "$@" >"$WORK_DIR/out" 2>&1
}

# reload.lock (taken by the command-line lifecycle itself, LC-3) is no runtime.
runtime_events() { grep -Ev '^service/state.uc (acquire|release)-runtime-dir-lock' "$EVENTS" || true; }

refused_quietly() {
  if runtime_events | grep -Eq '^service/state.uc|^dns/apply.uc|^nft/apply.uc|^prokop '; then
    fail "$1 reached the runtime"
  fi
  [ ! -e "$RUN/start.explicit" ] || fail "$1 was recorded as an explicit start"
  [ ! -e "$RUN/start.in-progress" ] || fail "$1 left a start in progress"
  [ ! -e "$RUN/start.retry" ] && [ ! -e "$RUN/start-retry.pid" ] || fail "$1 scheduled a retry"
}

# 1. The old runtime table exists (left by just the runtime state of the old
#    product): start is refused, says what to run and is not retried.
reset_case
legacy none table
printf '1\nby=user\n' >"$RUN/stop.requested"
if lifecycle start; then fail "a start next to the old runtime table succeeded"; fi
grep -Fq "Refusing Prokop start: Forkop is still active (nft table ForkopTable is present). $INSTALL_HINT" "$WORK_DIR/syslog" ||
  fail "the refused start must name the reason and the installer"
grep -Fxq 'reason=legacy_runtime_active' "$RUN/start.failure" || fail "the refused start must not be retried"
[ -e "$RUN/stop.requested" ] || fail "a refused start must not end the explicit stop"
refused_quietly "start next to the old runtime table"

# 2. The old init script reports its runtime running.
reset_case
legacy running
if lifecycle start; then fail "a start next to the running old product succeeded"; fi
grep -Fq "Forkop is still active (/etc/init.d/forkop reports it running)" "$WORK_DIR/syslog" ||
  fail "the refusal must name the running old init script"
refused_quietly "start next to the running old product"

# 3. Restart, and the restart a reload makes of a runtime that is down.
reset_case
legacy stopped table
if lifecycle restart; then fail "a restart next to the old runtime table succeeded"; fi
grep -Fq 'Refusing Prokop restart: Forkop is still active' "$WORK_DIR/syslog" || fail "the refused restart must be logged"
refused_quietly "restart next to the old runtime table"
reset_case
legacy stopped table
: >"$RUN/start.explicit"
FAKE_CONFLICT=1 lifecycle reload manual || true
grep -Fq 'Refusing Prokop reload restart: Forkop is still active' "$WORK_DIR/syslog" ||
  fail "a reload must not start the runtime next to the old product"
if grep -Eq '^service/state.uc (stop|start)-|^nft/apply.uc' "$EVENTS"; then fail "a refused reload restart changed the runtime"; fi

# 4. Installed but stopped old files alone do not block a start.
reset_case
legacy stopped
lifecycle start || true
grep -Fq 'service/state.uc sing-box-process-conflict' "$EVENTS" || fail "a start next to stopped old files must go on"
if grep -Fq 'Forkop is still active' "$WORK_DIR/syslog"; then fail "stopped old files must not block a start"; fi
[ -e "$RUN/start.explicit" ] || fail "the start that went on must be recorded"
reset_case
lifecycle start || true
grep -Fq 'service/state.uc sing-box-process-conflict' "$EVENTS" || fail "a start without the old product must go on"
if grep -q '^nft list tables' "$EVENTS"; then fail "without any old traces nothing may be queried"; fi

# 5. Prokop's stop with the old product running and no runtime of its own:
#    nothing shared is touched. With its own runtime table it stops as usual.
reset_case
legacy running table
lifecycle stop || fail "a stop next to the running old product failed"
grep -Fq 'Prokop has no runtime to stop' "$WORK_DIR/syslog" || fail "the skipped stop must be logged"
if runtime_events | grep -Eq '^service/state.uc|^dns/apply.uc|^nft/apply.uc|^singbox/|^providers/'; then
  fail "a stop next to the running old product touched shared state"
fi
reset_case
legacy running table
touch "$WORK_DIR/tables/ProkopTable"
lifecycle stop || true
grep -Fq 'dns/apply.uc restore' "$EVENTS" && grep -Eq '^service/state.uc stop-' "$EVENTS" ||
  fail "a stop of Prokop's own runtime must stop it"

# 6. init.d: the start a package install makes is refused before it records
#    anything, and its waiting caller gets the failure.
reset_case
legacy running table
if PROKOP_START_REQUEST=guard initd start-service manual "$$"; then fail "init.d started next to the old product"; fi
grep -Fq "Prokop start refused: Forkop is still active (nft table ForkopTable is present). $INSTALL_HINT" "$WORK_DIR/out" ||
  fail "init.d must print the refusal"
grep -Fq "Prokop start refused: Forkop is still active" "$WORK_DIR/syslog" || fail "init.d must log the refusal"
grep -Fxq 'status=1' "$RUN/start-result.guard" || fail "the waiting caller must get the failure"
refused_quietly "init.d start next to the old product"

reset_case
legacy stopped
initd start-service manual "$$" || fail "init.d start next to stopped old files failed: $(cat "$WORK_DIR/out")"
grep -Fxq 'prokop start' "$EVENTS" || fail "init.d must start Prokop next to stopped old files"

# 7. A start that lifecycle refused for the old product is not retried.
reset_case
legacy stopped
if FAKE_START_FAILURE=legacy_runtime_active initd start-service manual "$$"; then fail "the failed start succeeded"; fi
grep -Fq 'retry suppressed: Forkop is still active' "$WORK_DIR/syslog" || fail "the suppressed retry must name the old product"
[ ! -e "$RUN/start.retry" ] && [ ! -e "$RUN/start-retry.pid" ] || fail "a start refused for the old product was retried"

printf 'prokop_from_forkop_runtime_start_guard: PASS\n'
