#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_BIN="$ROOT_DIR/prokop/files/usr/bin/prokop"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
PACKAGE_UC="$PROKOP_LIB/service/package.uc"
PROKOP_MAKEFILE="$ROOT_DIR/prokop/Makefile"
LUCI_UCI_DEFAULTS="$ROOT_DIR/luci-app-prokop/root/etc/uci-defaults/50_luci-prokop"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
WORK_DIR="$(mktemp -d)"
export PROKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
# prerm reads service/initd.uc runtime state (a deferred start); never the
# host's.
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
mkdir -p "$PROKOP_RUNTIME_STATE_DIR"
# A refused start is recorded in the health history; never the host's.
export PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
# shellcheck source=tests/helpers/migrated_config.sh
. "$ROOT_DIR/tests/helpers/migrated_config.sh"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -r "$PACKAGE_UC" ] ||
  fail "service/package.uc must own package lifecycle logic"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$PACKAGE_UC" >/dev/null 2>&1; then
  fail "service/package.uc must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$PACKAGE_UC" ||
  fail "service/package.uc must import core.uci"
grep -Fq 'package_prerm: [ "service/package.uc", "prerm", 2 ]' "$PROKOP_BIN" ||
  fail "prokop entrypoint must dispatch package prerm cleanup through service/package.uc"
grep -Fq 'package_postinst: [ "service/package.uc", "postinst", 0 ]' "$PROKOP_BIN" ||
  fail "prokop entrypoint must dispatch package postinst recovery through service/package.uc"
grep -Fq 'luci_postinst: [ "service/package.uc", "luci-postinst", 0 ]' "$PROKOP_BIN" ||
  fail "prokop entrypoint must dispatch LuCI postinstall cleanup through service/package.uc"
grep -Fq '#!/bin/sh' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must remain a shell script because OpenWrt default_postinst runs it through shell"
grep -Fq '/usr/bin/prokop luci_postinst' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must delegate cache/rpcd handling to ucode"
if grep -E 'rm -f /var/luci-indexcache|rm -f /tmp/luci-indexcache|logger -t "prokop"' "$LUCI_UCI_DEFAULTS" >/dev/null; then
  fail "LuCI uci-defaults must not own cache/logger shell logic"
fi

if grep -n -E 'grep -q "105 prokop"|sed -i "/105 prokop|prokop_dont_touch_dhcp=.*uci|cp /etc/config/prokop|rm -f /tmp/luci-indexcache|killall -HUP rpcd' "$PROKOP_MAKEFILE" "$BUILD_SCRIPT" >/dev/null; then
  fail "package scripts must not keep backend/LuCI lifecycle business logic in shell"
fi
# OpenWrt sources the SDK package's prerm and postinst from /bin/sh
# (default_prerm, default_postinst) and runs its preinst with it;
# killswitch_owner_package.sh and package_recipe_parity.sh run them that way.
for hook in preinst prerm postinst; do
  [ "$(awk -v start="define Package/prokop/$hook" '$0 == start { getline; print; exit }' "$PROKOP_MAKEFILE")" = '#!/bin/sh' ] ||
    fail "prokop Makefile $hook must be a shell script: OpenWrt sources it from /bin/sh"
done
grep -Fq '/usr/bin/prokop package_prerm' "$PROKOP_MAKEFILE" ||
  fail "prokop Makefile prerm must delegate cleanup to package_prerm"
grep -Fq '/usr/bin/prokop package_postinst' "$PROKOP_MAKEFILE" ||
  fail "prokop Makefile postinst must restore a service that was running before upgrade"
grep -Fq '/usr/bin/prokop package_prerm upgrade' "$BUILD_SCRIPT" ||
  fail "manual APK pre-upgrade must record and stop the running service"
grep -Fq '/usr/bin/prokop package_postinst' "$BUILD_SCRIPT" ||
  fail "manual packages must restore a service that was running before upgrade"
grep -Fq '/usr/share/prokop/defaults/prokop' "$PROKOP_MAKEFILE" ||
  fail "prokop package must include a recovery copy of the default configuration"
grep -Fq 'usr/share/prokop/defaults/prokop' "$BUILD_SCRIPT" ||
  fail "manual packages must include a recovery copy of the default configuration"
if grep -Fq '/usr/bin/prokop luci_postinst' "$BUILD_SCRIPT"; then
  fail "manual package hooks must let default_postinst run luci_postinst exactly once through uci-defaults"
fi
if grep -n -E 'copy_legacy_config|PROKOP_LEGACY_CONFIG|mode == "preinst"' \
  "$PROKOP_MAKEFILE" "$BUILD_SCRIPT" "$PACKAGE_UC" >/dev/null 2>&1; then
  fail "package hooks and runtime service must not own configuration migration"
fi
# The SDK package's preinst is apk's pre-upgrade: it only stops Prokop for
# the upgrade, as build.sh's backend-pre-upgrade.sh
# (tests/package_recipe_parity.sh runs both).
sdk_preinst="$(awk '$0 == "define Package/prokop/preinst" { copy = 1; next } copy && $0 == "endef" { exit } copy { print }' "$PROKOP_MAKEFILE")"
printf '%s\n' "$sdk_preinst" | grep -Fq '/usr/bin/prokop package_prerm upgrade' ||
  fail "prokop Makefile preinst must stop Prokop for an apk upgrade through package_prerm"
if printf '%s\n' "$sdk_preinst" | grep -n -E '/etc/config|migrat|uci |cp ' >/dev/null; then
  fail "prokop Makefile preinst must not own configuration migration"
fi

rt_tables="$WORK_DIR/rt_tables"
cat >"$rt_tables" <<'EOF'
100 main
105 prokop
200 custom
EOF
PROKOP_PACKAGE_TEST_MODE=1 PROKOP_RT_TABLES="$rt_tables" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 1) exited non-zero"
if grep -Fq '105 prokop' "$rt_tables"; then
  fail "package prerm must remove the Prokop routing table entry"
fi
grep -Fq '200 custom' "$rt_tables" ||
  fail "package prerm must preserve unrelated rt_tables entries"

cat >"$WORK_DIR/prokop-init" <<'SH'
#!/usr/bin/env bash
# Model a real init script: only "stop" tears anything down, and "status"
# reports whether the service is running so prerm can decide about a restart.
case "$1" in
  status) exit "${PROKOP_FAKE_STATUS:-0}" ;;
  stop)
    grep -Fq '105 prokop' "${PROKOP_RT_TABLES:?}" || exit 1
    printf '%s\n' 'stop-with-route-table' >>"${PROKOP_STOP_LOG:?}"
    printf 'stop-source=%s\n' "${PROKOP_STOP_SOURCE:-}" >>"${PROKOP_STOP_LOG:?}"
    ;;
esac
SH
chmod 0755 "$WORK_DIR/prokop-init"
cat >"$WORK_DIR/stop-order.state" <<'EOF_UCI'
prokop.settings=settings
prokop.settings.dont_touch_dhcp=1
EOF_UCI
printf '105 prokop\n' >"$WORK_DIR/rt_tables_stop_order"
: >"$WORK_DIR/stop-order.log"
PROKOP_UCI_STATE_FILE="$WORK_DIR/stop-order.state" \
PROKOP_INIT="$WORK_DIR/prokop-init" \
PROKOP_STOP_LOG="$WORK_DIR/stop-order.log" \
PROKOP_BIN="$WORK_DIR/missing-prokop-bin" \
PROKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
PROKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
PROKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
PROKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
PROKOP_RT_TABLES="$WORK_DIR/rt_tables_stop_order" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 2) exited non-zero"
grep -Fxq 'stop-with-route-table' "$WORK_DIR/stop-order.log" ||
  fail "package prerm must stop Prokop before removing its routing table name"
[ ! -s "$WORK_DIR/rt_tables_stop_order" ] ||
  fail "package prerm must remove the routing table name after Prokop stops"
# Its stop is Prokop's own, for the package change, not the user's
# (service/initd.uc stop_request_source; UC-056).
grep -Fxq 'stop-source=package' "$WORK_DIR/stop-order.log" ||
  fail "package prerm must record its stop as the package's, not the user's"

# The preceding case stops a running Prokop, so prerm correctly records a
# restart for postinst. The configuration-recovery cases below own no init
# double, so start from an explicit clean slate instead of inheriting it.
rm -f "$PROKOP_PACKAGE_UPGRADE_STATE"

printf '%s\n' "config settings 'settings'" >"$WORK_DIR/default-prokop"
printf '%s\n' 'prokop.settings=settings' >"$WORK_DIR/config.state"
mkdir -p "$WORK_DIR/component-update-checks"
touch "$WORK_DIR/component-update-checks/prokop.json"
touch "$WORK_DIR/component-update-check.timestamp"
PROKOP_PACKAGE_TEST_MODE=1 \
PROKOP_CONFIG_PATH="$WORK_DIR/config-prokop" \
PROKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-prokop" \
PROKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
PROKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK_DIR/component-update-checks" \
PROKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK_DIR/component-update-check.timestamp" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" postinst ||
    fail "package postinst (case 3) exited non-zero"
cmp -s "$WORK_DIR/default-prokop" "$WORK_DIR/config-prokop" ||
  fail "package postinst must restore a missing Prokop configuration from packaged defaults"
[ ! -e "$WORK_DIR/component-update-checks/prokop.json" ] ||
  fail "package postinst must remove cached component update results"
[ ! -e "$WORK_DIR/component-update-check.timestamp" ] ||
  fail "package postinst must remove the component update check timestamp"

printf '%s\n' "config settings 'custom'" >"$WORK_DIR/config-prokop"
cp "$WORK_DIR/config-prokop" "$WORK_DIR/config-prokop.expected"
PROKOP_PACKAGE_TEST_MODE=1 \
PROKOP_CONFIG_PATH="$WORK_DIR/config-prokop" \
PROKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-prokop" \
PROKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" postinst ||
    fail "package postinst (case 4) exited non-zero"
cmp -s "$WORK_DIR/config-prokop.expected" "$WORK_DIR/config-prokop" ||
  fail "package postinst must preserve an existing user configuration"

cat >"$WORK_DIR/config-prokop" <<'EOF_CONFIG_105'
config settings 'settings'
        option config_version '1.0.5'
        option custom_remote_setting 'preserve-me'
EOF_CONFIG_105
cp "$WORK_DIR/config-prokop" "$WORK_DIR/config-prokop-1.0.5.expected"
PROKOP_PACKAGE_TEST_MODE=1 \
PROKOP_CONFIG_PATH="$WORK_DIR/config-prokop" \
PROKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-prokop" \
PROKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" postinst ||
    fail "package postinst (case 5) exited non-zero"
cmp -s "$WORK_DIR/config-prokop-1.0.5.expected" "$WORK_DIR/config-prokop" ||
  fail "1.0.5 package upgrade must preserve the existing user configuration"
cp "$WORK_DIR/config-prokop.expected" "$WORK_DIR/config-prokop"

if PROKOP_PACKAGE_TEST_MODE=1 \
  PROKOP_CONFIG_PATH="$WORK_DIR/unrecoverable-config" \
  PROKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/missing-default-config" \
  PROKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
    ucode -L "$PROKOP_LIB" "$PACKAGE_UC" postinst 2>/dev/null; then
  fail "package postinst must fail when a missing configuration cannot be restored"
fi

printf '%s\n' 'not-a-prokop-section=value' >"$WORK_DIR/invalid-config.state"
if PROKOP_PACKAGE_TEST_MODE=1 \
  PROKOP_CONFIG_PATH="$WORK_DIR/config-prokop" \
  PROKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-prokop" \
  PROKOP_UCI_STATE_FILE="$WORK_DIR/invalid-config.state" \
    ucode -L "$PROKOP_LIB" "$PACKAGE_UC" postinst 2>/dev/null; then
  fail "package postinst must reject a configuration without the required settings section"
fi
cmp -s "$WORK_DIR/config-prokop.expected" "$WORK_DIR/config-prokop" ||
  fail "package postinst must preserve an invalid non-empty user configuration"

touch "$WORK_DIR/luci-indexcache.one" "$WORK_DIR/luci-indexcache.two"
PROKOP_PACKAGE_TEST_MODE=1 PROKOP_LUCI_CACHE_GLOBS="$WORK_DIR/luci-indexcache*" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" luci-postinst
if compgen -G "$WORK_DIR/luci-indexcache*" >/dev/null; then
  fail "luci-postinst must remove LuCI index cache files"
fi

cat >"$WORK_DIR/prokop-bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PROKOP_RESTORE_LOG:?}"
SH
chmod 0755 "$WORK_DIR/prokop-bin"

cat >"$WORK_DIR/dont-touch.state" <<'EOF_UCI'
prokop.settings=settings
prokop.settings.dont_touch_dhcp=1
EOF_UCI
printf '105 prokop\n' >"$WORK_DIR/rt_tables_dont_touch"
: >"$WORK_DIR/restore-dont-touch.log"
PROKOP_UCI_STATE_FILE="$WORK_DIR/dont-touch.state" \
PROKOP_RESTORE_LOG="$WORK_DIR/restore-dont-touch.log" \
PROKOP_BIN="$WORK_DIR/prokop-bin" \
PROKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
PROKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
PROKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
PROKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
PROKOP_RT_TABLES="$WORK_DIR/rt_tables_dont_touch" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 8) exited non-zero"
[ ! -s "$WORK_DIR/restore-dont-touch.log" ] ||
  fail "package prerm must skip dnsmasq restore when dont_touch_dhcp is enabled"

cat >"$WORK_DIR/restore.state" <<'EOF_UCI'
prokop.settings=settings
prokop.settings.dont_touch_dhcp=0
EOF_UCI
printf '105 prokop\n' >"$WORK_DIR/rt_tables_restore"
: >"$WORK_DIR/restore.log"
PROKOP_UCI_STATE_FILE="$WORK_DIR/restore.state" \
PROKOP_RESTORE_LOG="$WORK_DIR/restore.log" \
PROKOP_BIN="$WORK_DIR/prokop-bin" \
PROKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
PROKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
PROKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
PROKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
PROKOP_RT_TABLES="$WORK_DIR/rt_tables_restore" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 9) exited non-zero"
grep -Fxq 'restore_dnsmasq' "$WORK_DIR/restore.log" ||
  fail "package prerm must restore dnsmasq when dont_touch_dhcp is disabled"

# init.d under procd accepts the start at once; its detached worker reports
# the outcome to the waiting postinst (service/initd.uc start-and-wait).
cat >"$WORK_DIR/upgrade-init" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) exit "${PROKOP_FAKE_STATUS:-0}" ;;
  start)
    printf '%s\n' start >>"${PROKOP_START_LOG:?}"
    [ -z "${PROKOP_START_REQUEST:-}" ] ||
      printf 'status=0\n' >"$PROKOP_RUNTIME_STATE_DIR/start-result.$PROKOP_START_REQUEST"
    ;;
esac
SH
cat >"$WORK_DIR/upgrade-prokop" <<'SH'
#!/bin/sh
[ "$1" != get_status ] || printf '{"running":1}\n'
SH
chmod 0755 "$WORK_DIR/upgrade-init" "$WORK_DIR/upgrade-prokop"
mkdir -p "$WORK_DIR/upgrade-run"
: >"$WORK_DIR/upgrade-start.log"
# A restart after an upgrade needs a configuration this release has
# migrated (UC-026); tests/package_postinst_chain.sh covers the others.
{
  printf 'prokop.settings=settings\n'
  migrated_settings_state "$PROKOP_LIB" "$WORK_DIR"
} >"$WORK_DIR/migrated.state" || fail "could not describe a migrated configuration"
: >"$WORK_DIR/rt_tables_upgrade"
PROKOP_PACKAGE_TEST_MODE=1 \
PROKOP_INIT="$WORK_DIR/upgrade-init" \
PROKOP_START_LOG="$WORK_DIR/upgrade-start.log" \
PROKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" prerm upgrade ||
    fail "package prerm upgrade (case 10) exited non-zero"
[ -f "$PROKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must remember a running service"
PROKOP_PACKAGE_TEST_MODE=1 \
PROKOP_INIT="$WORK_DIR/upgrade-init" \
PROKOP_LIB="$PROKOP_LIB" \
PROKOP_BIN="$WORK_DIR/upgrade-prokop" \
PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/upgrade-run" \
PROKOP_START_WAIT_TIMEOUT_SECONDS=5 \
PROKOP_START_LOG="$WORK_DIR/upgrade-start.log" \
PROKOP_CONFIG_PATH="$WORK_DIR/config-prokop" \
PROKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-prokop" \
PROKOP_UCI_STATE_FILE="$WORK_DIR/migrated.state" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" postinst ||
    fail "package postinst (case 11) exited non-zero"
grep -Fxq start "$WORK_DIR/upgrade-start.log" ||
  fail "package postinst must restart a service that was running before upgrade"
# That restart is an explicit start, also when init.d records none (an older
# init.d, a start that never comes): reloads may repair the runtime after it
# (service/initd.uc EXPLICIT_START_FILE; D-15(a)).
[ -e "$WORK_DIR/upgrade-run/start.explicit" ] ||
  fail "package postinst must record the restart after an upgrade as an explicit start"
[ ! -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package postinst must clear the consumed upgrade state"

PROKOP_PACKAGE_TEST_MODE=1 \
PROKOP_FAKE_STATUS=1 \
PROKOP_INIT="$WORK_DIR/upgrade-init" \
PROKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" prerm upgrade ||
    fail "package prerm upgrade (case 12) exited non-zero"
[ ! -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must not mark an already stopped service"

# A prerm without an action (the package scripts pass none on only under
# PKG_UPGRADE=1, which no known opkg sends without one; package_prerm run by
# hand) is decided by the service's state: a running service must still be
# restored.
PROKOP_PACKAGE_TEST_MODE=1 \
PROKOP_INIT="$WORK_DIR/upgrade-init" \
PROKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 13) exited non-zero"
[ -f "$PROKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "prerm without an action must remember a running service"

PROKOP_PACKAGE_TEST_MODE=1 \
PROKOP_FAKE_STATUS=1 \
PROKOP_INIT="$WORK_DIR/upgrade-init" \
PROKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 14) exited non-zero"
[ ! -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "prerm without an action must not mark an already stopped service"

# A start deferred for reload.lock (service/initd.uc) was requested but does
# not run yet: the package's own stop cancels it, so postinst starts Prokop
# in its place. A stop requested after that start has won over it (D-15), and
# the retry of a failed start is no requested start.
mkdir -p "$WORK_DIR/deferred-run"
prerm_with_stopped_runtime() {
  local lib="$PROKOP_LIB"
  PROKOP_PACKAGE_TEST_MODE=1 \
  PROKOP_FAKE_STATUS=1 \
  PROKOP_INIT="$WORK_DIR/upgrade-init" \
  PROKOP_LIB="$lib" \
  PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/deferred-run" \
  PROKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
    ucode -L "$lib" "$PACKAGE_UC" prerm upgrade ||
      fail "package prerm upgrade ($1) exited non-zero"
}
printf 'reason=start_deferred\nupdated_at=1\nstop_request=\n' >"$WORK_DIR/deferred-run/start.retry"
prerm_with_stopped_runtime "deferred start"
[ -f "$PROKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must restart a start deferred for the runtime lock"
rm -f "$PROKOP_PACKAGE_UPGRADE_STATE"
printf 'later\nby=user\n' >"$WORK_DIR/deferred-run/stop.requested"
prerm_with_stopped_runtime "deferred start, later stop"
[ ! -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must not restart a deferred start that a later stop cancelled"
rm -f "$WORK_DIR/deferred-run/stop.requested"
printf 'reason=start_failed\nupdated_at=1\n' >"$WORK_DIR/deferred-run/start.retry"
prerm_with_stopped_runtime "failed start retry"
[ ! -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must not take the retry of a failed start for a requested start"
rm -f "$WORK_DIR/deferred-run/start.retry"

# An explicit removal stays unambiguous: nothing is restored afterwards.
PROKOP_PACKAGE_TEST_MODE=1 \
PROKOP_INIT="$WORK_DIR/upgrade-init" \
PROKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$PROKOP_LIB" "$PACKAGE_UC" prerm remove ||
    fail "package prerm remove (case 15) exited non-zero"
[ ! -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package removal must not schedule a restart"

printf 'package lifecycle checks passed\n'
