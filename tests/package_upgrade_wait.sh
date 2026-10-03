#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
PACKAGE_UC="$PROKOP_LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# prerm stops the service, but its sing-box child exits asynchronously. postinst
# must not reach the guarded start while that process is still around: the start
# refuses an ambiguous runtime by design, which would leave Prokop stopped after
# an ordinary package upgrade.

# init.d under procd accepts the start at once; its detached worker reports
# the outcome to the waiting postinst (service/initd.uc start-and-wait).
cat >"$WORK_DIR/init" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${PROKOP_TEST_INIT_LOG:?}"
if [ "$1" = start ] && [ -n "${PROKOP_START_REQUEST:-}" ]; then
  printf 'status=0\n' >"$PROKOP_RUNTIME_STATE_DIR/start-result.$PROKOP_START_REQUEST"
fi
exit 0
SH
cat >"$WORK_DIR/prokop" <<'SH'
#!/bin/sh
[ "$1" != get_status ] || printf '{"running":1}\n'
SH
chmod 0755 "$WORK_DIR/init" "$WORK_DIR/prokop"
mkdir -p "$WORK_DIR/run"

printf "config settings 'settings'\n" >"$WORK_DIR/prokop.conf"
# The restart needs a configuration this release has migrated (UC-026).
# shellcheck source=tests/helpers/migrated_config.sh
. "$ROOT_DIR/tests/helpers/migrated_config.sh"
{
  printf 'prokop.settings=settings\n'
  migrated_settings_state "$PROKOP_LIB" "$WORK_DIR"
} >"$WORK_DIR/uci.state" || fail "could not describe a migrated configuration"

# A fake /proc: one process whose exe resolves to a binary named sing-box.
mkdir -p "$WORK_DIR/proc/4242" "$WORK_DIR/proc/7/" "$WORK_DIR/bin"
: >"$WORK_DIR/bin/sing-box"
: >"$WORK_DIR/bin/unrelated"
ln -s "$WORK_DIR/bin/unrelated" "$WORK_DIR/proc/7/exe"

run_postinst() {
  : >"$WORK_DIR/init.log"
  printf '1\n' >"$WORK_DIR/was-running"
  PROKOP_INIT="$WORK_DIR/init" \
  PROKOP_LIB="$PROKOP_LIB" \
  PROKOP_BIN="$WORK_DIR/prokop" \
  PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
  PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" \
  PROKOP_START_WAIT_TIMEOUT_SECONDS=5 \
  PROKOP_TEST_INIT_LOG="$WORK_DIR/init.log" \
  PROKOP_CONFIG_PATH="$WORK_DIR/prokop.conf" \
  PROKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/prokop.conf" \
  PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  PROKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/was-running" \
  PROKOP_PROC_DIR="$WORK_DIR/proc" \
  PROKOP_RC_D_DIR="$WORK_DIR/rc.d" \
  PROKOP_TORRSERVER_DIRECT_INIT="$WORK_DIR/missing-torrserver-direct-init" \
  PROKOP_UPGRADE_SING_BOX_WAIT_SECONDS="${1:-15}" \
    ucode -L "$PROKOP_LIB" "$PACKAGE_UC" postinst
}

# 1. No sing-box left: the restore proceeds immediately.
run_postinst 15 || fail "postinst must restore the service once sing-box has exited"
grep -Fxq start "$WORK_DIR/init.log" ||
  fail "postinst must start Prokop when no sing-box process remains"
[ ! -e "$WORK_DIR/was-running" ] ||
  fail "postinst must consume the upgrade marker after a successful restore"

# 2. A surviving sing-box: the start must not be attempted at all.
ln -s "$WORK_DIR/bin/sing-box" "$WORK_DIR/proc/4242/exe"
start=$(date +%s)
if run_postinst 2 2>/dev/null; then
  fail "postinst must fail while the previous sing-box runtime is still present"
fi
elapsed=$(( $(date +%s) - start ))
[ ! -s "$WORK_DIR/init.log" ] ||
  fail "postinst must not start Prokop while an ambiguous sing-box runtime survives"
[ -e "$WORK_DIR/was-running" ] ||
  fail "a timed-out restore must keep the marker so the next attempt can retry"
[ "$elapsed" -ge 2 ] ||
  fail "postinst must actually wait for the configured timeout"

# 3. The scan matches the executable name, not any process that happens to exist.
rm -f "$WORK_DIR/proc/4242/exe"
run_postinst 2 || fail "an unrelated process must not be mistaken for sing-box"
grep -Fxq start "$WORK_DIR/init.log" ||
  fail "postinst must start Prokop when only unrelated processes are running"

printf 'package upgrade wait checks passed\n'
