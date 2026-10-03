#!/usr/bin/env bash
# The install and upgrade scripts of the backend package as build.sh writes
# them: the ipk's postinst and the apk's post-install and post-upgrade.
#
# UC-026: they ran the configuration migration, then mirror-migration.sh,
# then `forkop package_postinst`, and stopped at the first that failed. The
# mirror script needs its mirror on every upgrade (the platform index, on
# apk the key): an unreachable mirror, or one that does not list this
# platform yet, ended the script before package_postinst, the only step
# that starts again a Forkop that the upgrade stopped. Forkop stayed down
# and the package manager reported a broken package.
#
# Now the mirror step is best effort (the dependency mirror is opt-in; a
# mirror problem only warns and leaves the feeds as they were), package_postinst always runs, and the script ends with the first
# failure of the migration and package_postinst. package_postinst starts
# Forkop only on a configuration that the migrations of this release have
# migrated: when the migration could not be saved (a read-only overlay) it
# runs, refuses the start, records it and fails (fail closed).
#
# UC-077: a missing or empty /etc/config/forkop came back from the packaged
# defaults only in package_postinst, after the migrations that fail without
# it. Now it comes back first.
#
# The real service/package.uc, service/initd.uc, config/migration.uc and
# mirror-migration.sh run behind the real CLI; the init script, the package
# managers, curl and logger are stubs, UCI is a state file.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
CLI="$ROOT_DIR/forkop/files/usr/bin/forkop"
MIRROR="$ROOT_DIR/forkop/files/usr/share/forkop/mirror-migration.sh"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT
trap 'exit 1' HUP INT TERM
# shellcheck source=tests/helpers/build_recipe.sh
. "$ROOT_DIR/tests/helpers/build_recipe.sh"
# shellcheck source=tests/helpers/migrated_config.sh
. "$ROOT_DIR/tests/helpers/migrated_config.sh"

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  [ ! -s "$WORK_DIR/stderr" ] || sed 's/^/  stderr: /' "$WORK_DIR/stderr" >&2
  exit 1
}

build_recipe_scripts "$BUILD_SCRIPT" "$WORK_DIR/scripts" || fail "could not write build.sh's package scripts"

# A library with a migration whose outcome a case sets; every other mode is
# the real config/migration.uc.
STUB_LIB="$WORK_DIR/stub-lib"
cp -a "$LIB" "$STUB_LIB"
cat >"$STUB_LIB/config/migration.uc" <<UC
let fs = require("fs");
if (ARGV[0] != "migrate")
    exit(system([ "ucode", "-L", "$LIB", "$LIB/config/migration.uc", ...ARGV ]));
let config = fs.readfile(getenv("FORKOP_CONFIG_PATH"));
let present = config != null && trim(config) != "";
system("printf 'migrate config=%s\\\\n' " + (present ? "present" : "missing") + " >>'" + getenv("EVENTS") + "'");
// The migrations need the configuration: without it they fail.
if (getenv("MIGRATE_NEEDS_CONFIG") == "1" && !present)
    exit(1);
exit(int(getenv("MIGRATE_STATUS") || "0"));
UC

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/mroot/etc/opkg" "$WORK_DIR/defaults" "$WORK_DIR/tmp"
export EVENTS
export PATH="$WORK_DIR/bin:$PATH"
export TMPDIR="$WORK_DIR/tmp"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/etc/uci.state"
export FORKOP_CONFIG_PATH="$WORK_DIR/etc/forkop"
export FORKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/defaults/forkop"
export FORKOP_INIT="$WORK_DIR/bin/forkop-init"
export FORKOP_BIN="$WORK_DIR/bin/forkop-status"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK_DIR/run/config-snapshot.lock"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export FORKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export FORKOP_UI_STATE_DIR="$WORK_DIR/run/ui-state"
export FORKOP_OPKG_RECOVERY_DIR="$WORK_DIR/opkg-recovery"
export FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
export FORKOP_KILLSWITCH_UC="$WORK_DIR/missing-killswitch.uc"
export FORKOP_LEGACY_GUARD_ROOT="$WORK_DIR/legacy"
export FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK_DIR/run/component-update-checks"
export FORKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK_DIR/run/component-update-check.timestamp"
export FORKOP_PROC_DIR="$WORK_DIR/proc"
export FORKOP_START_WAIT_TIMEOUT_SECONDS=5
export FORKOP_START_SETTLE_SECONDS=5
export FORKOP_POSTINST_START_WAIT_SECONDS=5
export TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions"
export FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-subscriptions"
export FORKOP_MIGRATION_ROOT="$WORK_DIR/mroot"
export FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl"
export FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci-cli"
export FORKOP_MIGRATION_OPKG_BIN="$WORK_DIR/bin/opkg"
export FORKOP_MIGRATION_APK_BIN="$WORK_DIR/missing-apk"
export REAL_CLI="$CLI" REAL_MIRROR="$MIRROR" WORK_DIR

# /usr/bin/forkop: the real CLI.
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
printf 'cli %s\n' "$*" >>"$EVENTS"
exec ucode "$REAL_CLI" "$@"
SH
# /usr/share/forkop/mirror-migration.sh: the real one, or, for a case about
# the configuration, one that needs it as the real one's uci set does.
cat >"$WORK_DIR/bin/mirror" <<'SH'
#!/bin/sh
printf 'mirror config=%s\n' "$([ -s "$FORKOP_CONFIG_PATH" ] && echo present || echo missing)" >>"$EVENTS"
if [ "${MIRROR_NEEDS_CONFIG:-}" = 1 ]; then
  [ -s "$FORKOP_CONFIG_PATH" ]
  exit $?
fi
exec sh "$REAL_MIRROR" "$@"
SH
# /etc/init.d/forkop under procd: init.d accepts the start, the start
# worker reports it.
cat >"$FORKOP_INIT" <<'SH'
#!/bin/sh
printf 'init %s\n' "$*" >>"$EVENTS"
if [ "$1" = start ]; then
  : >"$WORK_DIR/running"
  [ -z "${FORKOP_START_REQUEST:-}" ] ||
    printf 'status=0\n' >"$FORKOP_RUNTIME_STATE_DIR/start-result.$FORKOP_START_REQUEST"
fi
exit 0
SH
cat >"$FORKOP_BIN" <<'SH'
#!/bin/sh
[ "$1" = get_status ] || exit 0
if [ -e "$WORK_DIR/running" ]; then echo '{"running":1}'; else echo '{"running":0}'; fi
SH
# The mirror's platform index: unreachable, or without this platform, or
# with it.
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf 'curl %s\n' "$*" >>"$EVENTS"
out=
while [ "$#" -gt 0 ]; do
  [ "$1" != -o ] || out="$2"
  shift
done
case "${MIRROR_INDEX:-unreachable}" in
  unreachable) echo 'curl: (6) Could not resolve host: mirror.infotechtg.ru' >&2; exit 6 ;;
  other) printf 'x86\t64\tx86_64\t24.10.5\tipk\n' >"$out" ;;
  listed) printf 'x86/64\tx86_64\t24.10.6\tipk\n' >"$out" ;;
esac
SH
cat >"$WORK_DIR/bin/uci-cli" <<'SH'
#!/bin/sh
printf 'uci %s\n' "$*" >>"$EVENTS"
[ "$2" != get ] || exit 1
SH
for name in logger opkg apk nft ip conntrack; do
  # shellcheck disable=SC2016 # expanded by the stub when it runs
  printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"$EVENTS"\n' "$name" >"$WORK_DIR/bin/$name"
done
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
chmod 0755 "$WORK_DIR/bin/"*
cat >"$WORK_DIR/mroot/etc/openwrt_release" <<'EOF'
DISTRIB_RELEASE='24.10.6'
DISTRIB_TARGET='x86/64'
DISTRIB_ARCH='x86_64'
EOF
printf 'src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.6/targets/x86/64/packages\n' \
  >"$WORK_DIR/mroot/etc/opkg/distfeeds.conf"

# A script as the package would run it, its absolute paths in this test.
# $1: ipk/postinst, apk/backend-post-install.sh or apk/backend-post-upgrade.sh.
hook() {
  local lib="$2"
  sed -e "s#/usr/share/forkop/mirror-migration.sh#$WORK_DIR/bin/mirror#g" \
    -e "s#/usr/bin/forkop#$WORK_DIR/bin/forkop#g" \
    -e "s#/usr/lib/forkop#$lib#g" "$WORK_DIR/scripts/$1" >"$WORK_DIR/hook"
  grep -q "$WORK_DIR/bin/forkop package_postinst" "$WORK_DIR/hook" || fail "could not read the $1 package script"
}
cat >"$WORK_DIR/run-hook" <<'SH'
#!/bin/sh
# Runs the script with the interpreter its first line names.
case "$(head -n 1 "$1")" in
  '#!/usr/bin/ucode') exec ucode "$@" ;;
  *) exec sh "$@" ;;
esac
SH
chmod 0755 "$WORK_DIR/run-hook"

# The arguments the package managers pass.
hook_args() {
  case "$1" in
    ipk/postinst) echo configure ;;
    apk/backend-post-install.sh) echo 1.0.40 ;;
    apk/backend-post-upgrade.sh) echo 1.0.40 1.0.39 ;;
  esac
}

migrated_settings_state "$LIB" "$WORK_DIR" >"$WORK_DIR/migrated.state" || fail "could not describe a migrated configuration"
# $1: migrated (this release's migrations recorded) or old (1.0.1, none).
configure() {
  rm -rf "${WORK_DIR:?}/etc" "${WORK_DIR:?}/run" "${WORK_DIR:?}/running" "${WORK_DIR:?}/proc"
  mkdir -p "$WORK_DIR/etc" "$WORK_DIR/run/component-update-checks" "$WORK_DIR/proc"
  : >"$EVENTS"
  : >"$WORK_DIR/stderr"
  touch "$WORK_DIR/run/component-update-checks/forkop.json"
  printf "config settings 'settings'\n" >"$FORKOP_CONFIG_PATH"
  printf "config settings 'settings'\n\toption config_version '1.0.5'\n" >"$FORKOP_DEFAULT_CONFIG_PATH"
  if [ "$1" = migrated ]; then
    {
      printf 'forkop.settings=settings\nforkop.settings.yacd_secret_key=0123456789abcdef0123456789abcdef\n'
      cat "$WORK_DIR/migrated.state"
    } >"$FORKOP_UCI_STATE_FILE"
  else
    printf 'forkop.settings=settings\nforkop.settings.config_version=1.0.1\nforkop.settings.component_update_check_enabled=0\n' >"$FORKOP_UCI_STATE_FILE"
  fi
}

# $1: script; $2: library; $3: running before the upgrade (1) or not.
STATUS=0
run_case() {
  hook "$1" "$2"
  rm -f "$FORKOP_PACKAGE_UPGRADE_STATE"
  [ "$3" != 1 ] || printf '1\n' >"$FORKOP_PACKAGE_UPGRADE_STATE"
  STATUS=0
  # shellcheck disable=SC2046 # the package manager's arguments
  FORKOP_LIB="$2" "$WORK_DIR/run-hook" "$WORK_DIR/hook" $(hook_args "$1") 2>"$WORK_DIR/stderr" || STATUS=$?
}

started() { grep -Eq '^init start( |$)' "$EVENTS"; }
postinst_ran() { grep -Fxq 'cli package_postinst' "$EVENTS"; }
handoff_consumed() { [ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ]; }
start_failure_recorded() {
  grep -q '"kind": *"start"' "$FORKOP_RUNTIME_STATE_DIR/health-events.json" 2>/dev/null &&
    grep -q '"status": *"failure"' "$FORKOP_RUNTIME_STATE_DIR/health-events.json"
}

# ---- the mirror is unreachable: Forkop that ran comes back ----------------

# The mirror cases run with a mirror the user opted in to.
export FORKOP_MIRROR_BASE_URL="https://mirror.example.test"

for script in ipk/postinst apk/backend-post-upgrade.sh; do
  label="$script, mirror unreachable"
  configure migrated
  apk="$WORK_DIR/missing-apk"
  [ "${script%%/*}" != apk ] || apk="$WORK_DIR/bin/apk"
  FORKOP_MIGRATION_APK_BIN="$apk" MIRROR_INDEX=unreachable run_case "$script" "$LIB" 1
  [ "$STATUS" -eq 0 ] || fail "$label: the script exited $STATUS"
  grep -Fq 'platform index of https://mirror.example.test is unavailable; package feeds were not changed' "$WORK_DIR/stderr" ||
    fail "$label: the mirror step did not report its unreachable mirror"
  postinst_ran || fail "$label: package_postinst did not run"
  started || fail "$label: Forkop that ran before the upgrade was not started again"
  handoff_consumed || fail "$label: the running state handed over by prerm was not consumed"
done

label="ipk, platform not in the mirror's index"
configure migrated
MIRROR_INDEX=other run_case ipk/postinst "$LIB" 1
[ "$STATUS" -eq 0 ] || fail "$label: the script exited $STATUS"
grep -Fq 'does not carry x86/64' "$WORK_DIR/stderr" || fail "$label: the mirror step did not refuse the platform"
started || fail "$label: Forkop that ran before the upgrade was not started again"

label="apk install, mirror unreachable"
configure migrated
FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" MIRROR_INDEX=unreachable run_case apk/backend-post-install.sh "$LIB" 0
[ "$STATUS" -eq 0 ] || fail "$label: the script exited $STATUS"
postinst_ran || fail "$label: package_postinst did not run"
started && fail "$label: a fresh install started Forkop"

label="ipk, mirror reachable"
configure migrated
MIRROR_INDEX=listed run_case ipk/postinst "$LIB" 1
[ "$STATUS" -eq 0 ] || fail "$label: the script exited $STATUS"
started || fail "$label: Forkop was not started again"
grep -q '^logger .*mirror migration failed' "$EVENTS" && fail "$label: a mirror migration that worked was logged as failed"
grep -Fq 'https://mirror.example.test/openwrt/releases/' "$WORK_DIR/mroot/etc/opkg/distfeeds.conf" ||
  fail "$label: the mirror migration did not run to its end"
unset FORKOP_MIRROR_BASE_URL

# ---- the migration fails: package_postinst runs and fails closed ----------

label="migration failed"
configure old
MIGRATE_STATUS=3 run_case ipk/postinst "$STUB_LIB" 1
[ "$STATUS" -eq 3 ] || fail "$label: the script must end with the migration's status 3, not $STATUS"
postinst_ran || fail "$label: package_postinst did not run"
started && fail "$label: Forkop was started on a configuration this release has not migrated"
handoff_consumed || fail "$label: the running state handed over by prerm was kept"
start_failure_recorded || fail "$label: the refused start was not recorded"
grep -q '^logger .*not migrated' "$EVENTS" || fail "$label: the refused start was not logged"
[ ! -e "$FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR/forkop.json" ] || fail "$label: package_postinst did not do its other work"

label="package_postinst failed"
configure migrated
printf 'forkop.other=settings\n' >"$FORKOP_UCI_STATE_FILE"
MIGRATE_STATUS=0 run_case apk/backend-post-upgrade.sh "$STUB_LIB" 1
[ "$STATUS" -ne 0 ] || fail "$label: the script must report package_postinst's failure"
started && fail "$label: Forkop was started without its settings"

# A read-only overlay: the real migration cannot save its changes.
if ! unshare -rm true 2>/dev/null; then
  printf 'NOTE: no user and mount namespaces; the read-only overlay case is skipped\n'
else
  for script in ipk/postinst apk/backend-post-upgrade.sh; do
    label="$script, read-only overlay"
    configure old
    hook "$script" "$LIB"
    printf '1\n' >"$FORKOP_PACKAGE_UPGRADE_STATE"
    STATUS=0
    # shellcheck disable=SC2016,SC2046 # expanded by the inner sh; the package manager's arguments
    MIRROR_INDEX=listed FORKOP_LIB="$LIB" unshare -rm sh -c '
      mount --bind "$1" "$1" && mount -o remount,bind,ro "$1" || exit 90
      shift
      exec "$@"
    ' sh "$WORK_DIR/etc" "$WORK_DIR/run-hook" "$WORK_DIR/hook" $(hook_args "$script") 2>"$WORK_DIR/stderr" || STATUS=$?
    [ "$STATUS" -ne 90 ] || fail "$label: could not mount the read-only overlay"
    [ "$STATUS" -ne 0 ] || fail "$label: the script reported success"
    grep -q 'config_version=1.0.1' "$FORKOP_UCI_STATE_FILE" || fail "$label: the configuration changed on a read-only overlay"
    postinst_ran || fail "$label: package_postinst did not run"
    started && fail "$label: Forkop was started on a configuration this release has not migrated"
    start_failure_recorded || fail "$label: the refused start was not recorded"
  done
fi

# ---- UC-077: the configuration comes back before the migrations -----------

label="empty configuration"
configure migrated
: >"$FORKOP_CONFIG_PATH"
MIGRATE_NEEDS_CONFIG=1 MIRROR_NEEDS_CONFIG=1 run_case ipk/postinst "$STUB_LIB" 1
[ "$STATUS" -eq 0 ] || fail "$label: the script exited $STATUS"
cmp -s "$FORKOP_DEFAULT_CONFIG_PATH" "$FORKOP_CONFIG_PATH" || fail "$label: the packaged defaults were not restored"
grep -Fxq 'migrate config=present' "$EVENTS" || fail "$label: the migrations ran without the configuration"
grep -Fxq 'mirror config=present' "$EVENTS" || fail "$label: the mirror migration ran without the configuration"
started || fail "$label: Forkop was not started again"

label="missing configuration"
configure migrated
rm -f "$FORKOP_CONFIG_PATH"
MIGRATE_NEEDS_CONFIG=1 MIRROR_NEEDS_CONFIG=1 run_case apk/backend-post-upgrade.sh "$STUB_LIB" 1
[ "$STATUS" -eq 0 ] || fail "$label: the script exited $STATUS"
cmp -s "$FORKOP_DEFAULT_CONFIG_PATH" "$FORKOP_CONFIG_PATH" || fail "$label: the packaged defaults were not restored"
grep -Fxq 'migrate config=present' "$EVENTS" || fail "$label: the migrations ran without the configuration"

# ---- one script for every variant -------------------------------------------

for script in backend-post-install.sh backend-post-upgrade.sh; do
  cmp -s "$WORK_DIR/scripts/ipk/postinst" "$WORK_DIR/scripts/apk/$script" ||
    fail "the ipk postinst and the apk $script must be the same script"
done
sh -n "$WORK_DIR/scripts/ipk/postinst" || fail "the postinst is no valid sh"
# The SDK recipe's postinst is the same text; make reads $$ as $.
awk '$0 == "define Package/forkop/postinst" { copy = 1; next } copy && $0 == "endef" { exit } copy { print }' \
  "$ROOT_DIR/forkop/Makefile" | sed 's/[$][$]/$/g' >"$WORK_DIR/sdk-postinst"
cmp -s "$WORK_DIR/scripts/ipk/postinst" "$WORK_DIR/sdk-postinst" ||
  fail "forkop/Makefile's postinst differs from build.sh's: $(diff "$WORK_DIR/scripts/ipk/postinst" "$WORK_DIR/sdk-postinst" | tr '\n' ' ')"

printf 'package postinst chain checks passed\n'
