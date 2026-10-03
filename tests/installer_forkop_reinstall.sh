#!/usr/bin/env bash
set -euo pipefail

# opkg calls a Forkop package file of the installed version up to date and
# keeps the installed build, so an upstream build of the same version would
# stay. The installer reinstalls the Forkop packages in that case, and only
# then: opkg runs a reinstall as a removal of the installed package first.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

unset FORKOP_MIRROR_BASE_URL
sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090
. "$WORK_DIR/install-library.sh"

TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$TMP_DIR"
FORKOP_BACKEND_FILE="$TMP_DIR/forkop_1.0.26.ipk"
FORKOP_APP_FILE="$TMP_DIR/luci-app-forkop_1.0.26.ipk"
FORKOP_I18N_FILE="$TMP_DIR/luci-i18n-forkop-ru_1.0.26.ipk"
FORKOP_PACKAGE_VERSION="1.0.26"
PKG_IS_APK=0
INSTALLED_VERSION=""

opkg() {
  case "$1" in
    list-installed)
      if [ -n "$INSTALLED_VERSION" ]; then
        printf '%s - %s\n' \
          forkop-extra 1.0.26 \
          forkop "$INSTALLED_VERSION" \
          luci-app-forkop "$INSTALLED_VERSION" \
          luci-i18n-forkop-ru "$INSTALLED_VERSION"
      fi
      printf '%s\n' 'sing-box-tiny - 1.13.18-r1'
      ;;
    install)
      printf 'opkg %s\n' "$*" >>"$WORK_DIR/commands.log"
      ;;
    *)
      fail_test "unexpected opkg call: $*"
      ;;
  esac
}
apk() {
  printf 'apk %s\n' "$*" >>"$WORK_DIR/commands.log"
}

# Installs the backend (up to its post-install, which needs a router) and the
# LuCI packages, and prints the package manager commands they ran.
install_forkop_packages() {
  : >"$WORK_DIR/commands.log"
  (
    fail() { exit 1; }
    install_backend_package
  ) >/dev/null 2>&1 || true
  install_ui_packages >/dev/null
  cat "$WORK_DIR/commands.log"
}

[ "$(opkg_installed_version forkop)" = "" ] ||
  fail_test "a package that is not installed must have no installed version"

# 1. The same version is installed (an upstream build): every Forkop package
# file is reinstalled.
INSTALLED_VERSION="1.0.26"
[ "$(opkg_installed_version forkop)" = "1.0.26" ] ||
  fail_test "the installed opkg version was not read"
[ "$(install_forkop_packages)" = "$(printf '%s\n' \
  "opkg install --force-reinstall --force-overwrite --force-downgrade $FORKOP_BACKEND_FILE" \
  "opkg install --force-reinstall --force-overwrite --force-downgrade $FORKOP_APP_FILE" \
  "opkg install --force-reinstall --force-overwrite --force-downgrade $FORKOP_I18N_FILE")" ] ||
  fail_test "Forkop package files of the installed version must be reinstalled on opkg: $(cat "$WORK_DIR/commands.log")"

# 2. Another version is installed, or none: an ordinary upgrade, downgrade or
# installation, never the removal that a reinstall starts with.
for INSTALLED_VERSION in 1.0.25 1.0.27 ""; do
  [ "$(install_forkop_packages)" = "$(printf '%s\n' \
    "opkg install --force-overwrite --force-downgrade $FORKOP_BACKEND_FILE" \
    "opkg install --force-overwrite --force-downgrade $FORKOP_APP_FILE" \
    "opkg install --force-overwrite --force-downgrade $FORKOP_I18N_FILE")" ] ||
    fail_test "installed version '${INSTALLED_VERSION}' must not reinstall the Forkop packages: $(cat "$WORK_DIR/commands.log")"
done

# 3. Dependency and sing-box installs never reinstall.
INSTALLED_VERSION="1.0.26"
: >"$WORK_DIR/commands.log"
pkg_install_files "$TMP_DIR/sing-box-tiny_1.13.18-r1_aarch64_generic.ipk"
pkg_install_name ucode
if grep -Fq -- '--force-reinstall' "$WORK_DIR/commands.log"; then
  fail_test "dependency installs must not reinstall: $(cat "$WORK_DIR/commands.log")"
fi

# 4. apk pins a package file by its hash and needs no reinstall option.
PKG_IS_APK=1
: >"$WORK_DIR/commands.log"
install_ui_packages >/dev/null
[ "$(cat "$WORK_DIR/commands.log")" = "$(printf '%s\n' \
  "apk add --allow-untrusted $FORKOP_APP_FILE" \
  "apk add --allow-untrusted $FORKOP_I18N_FILE")" ] ||
  fail_test "apk must add the Forkop package files as before: $(cat "$WORK_DIR/commands.log")"

printf 'Installer Forkop reinstall tests passed\n'
