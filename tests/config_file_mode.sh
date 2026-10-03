#!/usr/bin/env bash
# /etc/config/prokop holds secrets: the Clash API secret (D-1), subscription
# URLs with their tokens, WAN credentials. Only root reads it (rpcd, LuCI's
# backend, runs as root; so do Prokop and the read-only wrapper).
#
# The packages installed it 0644 (build.sh; the SDK recipe reached parity
# with build.sh by going from 0600 to 0644), the package scripts restored a
# missing one 0644, and so did the installer's legacy migration. A
# configuration kept across an upgrade keeps its mode. Now both recipes
# install it 0600, a restored or migrated one is 0600, and the package
# scripts narrow a wider one once, on the upgrade; Prokop's writers and
# libuci keep the mode after that.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
PACKAGE_UC="$LIB/service/package.uc"
WORK="$(mktemp -d)"
# A call the uci test shim refused fails the test, even one it tolerated.
cleanup() {
  local rc=$?
  uci_cli_report || [ "$rc" != 0 ] || rc=1
  rm -rf "${WORK:?}"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# libuci commits and core/uci.uc commit_option go through the uci CLI.
# shellcheck source=tests/helpers/uci_cli/select.sh
source "$ROOT_DIR/tests/helpers/uci_cli/select.sh"
# shellcheck source=tests/helpers/build_recipe.sh
. "$ROOT_DIR/tests/helpers/build_recipe.sh"

fail() { printf 'config_file_mode: FAIL: %s\n' "$1" >&2; exit 1; }
mode() { stat -c %a "$1"; }

# 1. build.sh's package (the SDK recipe installs the same files with the
#    same modes: tests/package_recipe_parity.sh).
build_recipe_root "$ROOT_DIR/build.sh" 1.2.3 "$WORK/build-root" >/dev/null || fail "could not build build.sh's backend root"
[ "$(mode "$WORK/build-root/etc/config/prokop")" = 600 ] ||
  fail "build.sh installs /etc/config/prokop $(mode "$WORK/build-root/etc/config/prokop"), not 0600"

# 2. The package scripts (service/package.uc restore-config, which every
#    install and upgrade runs before the migrations): a configuration kept
#    from a release that installed it 0644 is narrowed, and a missing one
#    comes back from the packaged defaults 0600.
mkdir -p "$WORK/etc/config"
CONFIG="$WORK/etc/config/prokop"
printf "config settings 'settings'\n\toption clash_api_secret 's3cret'\n" >"$CONFIG"
printf "config settings 'settings'\n" >"$WORK/defaults"
chmod 0644 "$WORK/defaults"
restore_config() {
  PROKOP_CONFIG_PATH="$CONFIG" PROKOP_DEFAULT_CONFIG_PATH="$WORK/defaults" PROKOP_LIB="$LIB" \
    ucode -L "$LIB" "$PACKAGE_UC" restore-config
}
for kept in 644 640 604; do
  chmod "$kept" "$CONFIG"
  restore_config || fail "restore-config failed on a $kept configuration"
  [ "$(mode "$CONFIG")" = 600 ] || fail "the package scripts kept a $kept configuration $(mode "$CONFIG")"
  grep -Fq "s3cret" "$CONFIG" || fail "narrowing the mode changed the configuration"
done
chmod 0600 "$CONFIG"
restore_config || fail "restore-config failed on a 0600 configuration"
[ "$(mode "$CONFIG")" = 600 ] || fail "the package scripts changed a 0600 configuration to $(mode "$CONFIG")"
rm -f "$CONFIG"
restore_config || fail "restore-config could not restore a missing configuration"
cmp -s "$CONFIG" "$WORK/defaults" || fail "the restored configuration is not the packaged defaults"
[ "$(mode "$CONFIG")" = 600 ] || fail "a restored configuration is $(mode "$CONFIG"), not 0600"

# 3. The writers keep 0600: a libuci commit (the uci CLI, LuCI's rpcd and
#    config/migration.uc commit the same way) and Prokop's own commit of
#    one option (core/uci.uc commit_option, the Clash API secret).
printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n" >"$CONFIG"
chmod 0600 "$CONFIG"
mkdir -p "$WORK/save"
"$UCI_CLI" -c "$WORK/etc/config" -t "$WORK/save" set prokop.settings.dns_server=8.8.8.8 &&
  "$UCI_CLI" -c "$WORK/etc/config" -t "$WORK/save" commit prokop || fail "the uci CLI could not commit"
grep -Fq "8.8.8.8" "$CONFIG" || fail "the uci CLI did not commit"
[ "$(mode "$CONFIG")" = 600 ] || fail "a libuci commit changed the configuration to $(mode "$CONFIG")"
result="$(F="$CONFIG" CLI="$UCI_CLI" PROKOP_RUNTIME_STATE_DIR="$WORK/run" ucode -L "$LIB" -e '
  print(require("core.uci").commit_option(getenv("F"), "prokop.settings.clash_api_secret", "s3cret", true, getenv("CLI")));')"
[ "$result" = written ] || fail "commit_option: $result"
[ "$(mode "$CONFIG")" = 600 ] || fail "commit_option changed the configuration to $(mode "$CONFIG")"

# 4. The installer's legacy (podkop) migration puts the legacy
#    configuration in place for the migration: 0600, too.
LIBRARY="$WORK/install-library.sh"
sed -e '/^main "\$@"$/d' -e "s#/etc/config/prokop#$CONFIG#g" \
  -e "s#/usr/share/prokop/mirror-migration.sh#true#g" "$ROOT_DIR/install.sh" >"$LIBRARY"
printf "config settings 'settings'\n\toption dns_server '8.8.8.8'\n" >"$WORK/legacy.uci"
chmod 0644 "$WORK/legacy.uci" "$CONFIG"
(
  # shellcheck disable=SC1090
  . "$LIBRARY"
  # shellcheck disable=SC2317 # called by migrate_legacy_configuration
  ucode() { case "$*" in *'/config/migration.uc migrate-podkop') return 0 ;; *) return 1 ;; esac; }
  # shellcheck disable=SC2317 # called by migrate_legacy_configuration
  install_json_ucode() { [ "$1" = installer-finalize-legacy ]; }
  # shellcheck disable=SC2034 # read by migrate_legacy_configuration
  PROKOP_LEGACY_DETECTED=1 LEGACY_CONFIG_BACKUP="$WORK/legacy.uci"
  migrate_legacy_configuration
) >"$WORK/legacy.out" 2>&1 || fail "the legacy migration failed: $(cat "$WORK/legacy.out")"
cmp -s "$CONFIG" "$WORK/legacy.uci" || fail "the legacy configuration was not put in place"
[ "$(mode "$CONFIG")" = 600 ] || fail "the legacy migration left the configuration $(mode "$CONFIG"), not 0600"

printf 'config_file_mode: PASS\n'
