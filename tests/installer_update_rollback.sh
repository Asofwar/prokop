#!/usr/bin/env bash
# shellcheck disable=SC2034 # the sourced installer reads these variables
set -euo pipefail

# B8: an update through install.sh keeps the configuration and the package
# files of the installed release (from the GitHub Releases, checked by
# SHA-256) before it changes anything. A failure after it started to install
# packages reinstalls them from those files and restores the configuration;
# a package the update had not replaced yet is left alone. A release that
# cannot be kept does not stop the update, and its failure says that nothing
# was rolled back. A clean installation keeps nothing.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

unset PROKOP_MIRROR_BASE_URL
sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090,SC1091
. "$WORK_DIR/install-library.sh"

TMP_DIR="$WORK_DIR/tmp"
ASSETS="$WORK_DIR/assets"
mkdir -p "$TMP_DIR" "$ASSETS"
PKG_IS_APK=0
RELEASE_REPO="Asofwar/prokop"
UPDATE_CONFIG_FILE="$WORK_DIR/prokop.conf"
LOG="$WORK_DIR/commands.log"

for name in prokop luci-app-prokop luci-i18n-prokop-ru; do
  printf '%s 2.12.0\n' "$name" >"$ASSETS/${name}_2.12.0.ipk"
done
sha() { sha256sum "$ASSETS/$1" | awk '{print $1}'; }
release_json() {
  cat <<JSON
{ "tag_name": "2.12.0", "assets": [
  { "name": "prokop_2.12.0.ipk", "browser_download_url": "https://github.example/prokop_2.12.0.ipk", "digest": "sha256:$(sha prokop_2.12.0.ipk)" },
  { "name": "luci-app-prokop_2.12.0.ipk", "browser_download_url": "https://github.example/luci-app-prokop_2.12.0.ipk", "digest": "sha256:$(sha luci-app-prokop_2.12.0.ipk)" },
  { "name": "luci-i18n-prokop-ru_2.12.0.ipk", "browser_download_url": "https://github.example/luci-i18n-prokop-ru_2.12.0.ipk", "digest": "sha256:${I18N_SHA:-$(sha luci-i18n-prokop-ru_2.12.0.ipk)}" }
] }
JSON
}

# Doubles: the network answers from $ASSETS, the package manager records.
http_get() {
  printf 'GET %s\n' "$1" >>"$LOG"
  [ -z "${NETWORK_DOWN:-}" ] || return 1
  case "$1" in
    https://api.github.com/repos/Asofwar/prokop/releases/tags/2.12.0) release_json ;;
    *) return 1 ;;
  esac
}
download_file_once() {
  [ -z "${NETWORK_DOWN:-}" ] || return 1
  cp "$ASSETS/$(basename "$1")" "$2"
}
msg() { :; }
warn() { printf 'WARN %s\n' "$1" >>"$LOG"; }
declare -A INSTALLED
pkg_installed_version() { printf '%s\n' "${INSTALLED[$1]:-}"; }
pkg_is_installed() { [ -n "${INSTALLED[$1]:-}" ]; }
pkg_install_files() {
  printf 'install %s\n' "$*" >>"$LOG"
  # UPD-10: what the postinst of the reinstalled package would start on.
  printf 'config at install: %s\n' "$(sed -n "s/.*option marker '\(.*\)'/\1/p" "$UPDATE_CONFIG_FILE")" >>"$LOG"
  [ -z "${INSTALL_FAILS:-}" ]
}

reset_case() {
  : >"$LOG"
  INSTALL_MODE="update"
  UPDATE_PACKAGES_STARTED=0
  INSTALLED=([prokop]=2.12.0-r1 [luci-app-prokop]=2.12.0-r1 [luci-i18n-prokop-ru]=2.12.0-r1)
  printf "config settings 'settings'\n\toption marker 'old'\n" >"$UPDATE_CONFIG_FILE"
  unset NETWORK_DOWN INSTALL_FAILS I18N_SHA
}
# The update installs new packages and changes the configuration, then fails.
failed_update() {
  UPDATE_PACKAGES_STARTED=1
  INSTALLED[prokop]=2.13.0-r1
  INSTALLED[luci-app-prokop]=2.13.0-r1
  printf "config settings 'settings'\n\toption marker 'new'\n" >"$UPDATE_CONFIG_FILE"
  rollback_current_update
}

# 1. Kept before the update, rolled back after its failure.
reset_case
prepare_current_update_rollback
grep -Fq 'GET https://api.github.com/repos/Asofwar/prokop/releases/tags/2.12.0' "$LOG" ||
  fail_test "the installed release was not looked up by its tag: $(cat "$LOG")"
[ -n "$UPDATE_ROLLBACK_PACKAGES" ] || fail_test "the installed packages were not kept: $(cat "$LOG")"
[ "$(stat -c %a "$UPDATE_ROLLBACK_DIR")" = 700 ] || fail_test "the rollback directory is readable by others"
: >"$LOG"
failed_update
grep -Fxq "install $UPDATE_ROLLBACK_DIR/prokop_2.12.0.ipk" "$LOG" || fail_test "the backend was not reinstalled: $(cat "$LOG")"
grep -Fxq "install $UPDATE_ROLLBACK_DIR/luci-app-prokop_2.12.0.ipk" "$LOG" || fail_test "the LuCI app was not reinstalled: $(cat "$LOG")"
if grep -Fq 'luci-i18n-prokop-ru' "$LOG"; then
  fail_test "a package the update had not replaced was reinstalled: $(cat "$LOG")"
fi
grep -q "marker 'old'" "$UPDATE_CONFIG_FILE" || fail_test "the configuration was not restored"
if grep -Fq 'config at install: new' "$LOG"; then
  fail_test "a previous package was reinstalled over the configuration of the failed update (UPD-10): $(cat "$LOG")"
fi
[ "$(stat -c %a "$UPDATE_CONFIG_FILE")" = 600 ] || fail_test "the restored configuration is readable by others"
grep -q '^WARN The previous Prokop 2.12.0-r1 and its configuration were restored' "$LOG" || fail_test "the rollback is not reported: $(cat "$LOG")"
: >"$LOG"
rollback_current_update
[ ! -s "$LOG" ] || fail_test "the rollback ran twice: $(cat "$LOG")"

# 2. A failure before any package was installed rolls nothing back.
reset_case
prepare_current_update_rollback
: >"$LOG"
rollback_current_update
[ ! -s "$LOG" ] || fail_test "a failure before the packages rolled back: $(cat "$LOG")"

# 3. The release cannot be kept (no network, a wrong checksum): the update is
#    not stopped, and its failure says what was not rolled back.
for cause in network checksum; do
  reset_case
  case "$cause" in
    network) export NETWORK_DOWN=1 ;;
    checksum) I18N_SHA="$(printf '0%.0s' $(seq 64))" ;;
  esac
  prepare_current_update_rollback
  [ -z "$UPDATE_ROLLBACK_PACKAGES" ] || fail_test "$cause: packages counted as kept"
  : >"$LOG"
  failed_update
  if grep -q '^install ' "$LOG"; then fail_test "$cause: a reinstall was tried: $(cat "$LOG")"; fi
  grep -q 'previous Prokop packages were not kept' "$LOG" || fail_test "$cause: the failure does not say so: $(cat "$LOG")"
  grep -q "marker 'new'" "$UPDATE_CONFIG_FILE" || fail_test "$cause: the configuration was replaced without the packages"
done

# 4. A failed reinstall still restores the configuration (a newer Prokop
#    reads it, UPD-10) and says where the files are; they are moved out of
#    TMP_DIR, which the EXIT trap removes (UPD-11).
reset_case
prepare_current_update_rollback
INSTALL_FAILS=1
: >"$LOG"
failed_update
grep -q 'was not fully reinstalled; its packages are in' "$LOG" || fail_test "a failed reinstall is not reported: $(cat "$LOG")"
grep -q "marker 'old'" "$UPDATE_CONFIG_FILE" || fail_test "the configuration was not restored when a reinstall failed"
kept_dir="$(sed -n 's/.*its packages are in //p' "$LOG")"
case "$kept_dir" in
  "$TMP_DIR"|"$TMP_DIR"/*) fail_test "the reported rollback files are inside TMP_DIR, removed on exit: $kept_dir" ;;
esac
[ -f "$kept_dir/prokop_2.12.0.ipk" ] && [ -f "$kept_dir/prokop.config" ] ||
  fail_test "the reported rollback files are missing: $kept_dir"
cleanup
[ -f "$kept_dir/prokop_2.12.0.ipk" ] || fail_test "the rollback files did not survive the exit cleanup"
rm -rf "$kept_dir"
mkdir -p "$TMP_DIR"

# 5. A clean installation keeps nothing and rolls nothing back.
reset_case
INSTALL_MODE="clean"
UPDATE_ROLLBACK_PACKAGES=""
prepare_current_update_rollback
UPDATE_PACKAGES_STARTED=1
rollback_current_update
[ ! -s "$LOG" ] || fail_test "a clean installation used the rollback: $(cat "$LOG")"

# 6. The installer wires it: kept after the downloads, before any change;
#    rolled back in fail() before the service state is restored.
main_body="$(sed -n '/^main() {$/,/^}$/p' "$ROOT_DIR/install.sh")"
printf '%s\n' "$main_body" | awk '/download_prokop_packages/ {d=NR} /prepare_current_update_rollback/ {p=NR} /ensure_flash_space/ {e=NR} END {exit !(d && p > d && e > p)}' ||
  fail_test "main does not keep the release between the downloads and the first change"
sed -n '/^fail() {$/,/^}$/p' "$ROOT_DIR/install.sh" |
  awk '/rollback_current_update/ {r=NR} /restore_current_prokop_on_failure/ {s=NR} END {exit !(r && s > r)}' ||
  fail_test "fail() does not roll the update back before restoring the service state"

printf 'Installer update rollback tests passed\n'
