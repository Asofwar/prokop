#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"

cleanup_test() {
  rm -rf "$WORK_DIR"
}
trap cleanup_test EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

unset FORKOP_MIRROR_BASE_URL
sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" > "$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090
. "$WORK_DIR/install-library.sh"

TMP_DIR="$WORK_DIR/tmp"
MIRROR_BASE_URL="https://mirror.example"
mkdir -p "$TMP_DIR" "$WORK_DIR/etc/opkg"
distfeeds="$WORK_DIR/etc/opkg/distfeeds.conf"
cat > "$distfeeds" <<'EOF'
src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.7/targets/rockchip/armv8/packages
src/gz openwrt_base https://archive.openwrt.org/releases/24.10.7/packages/aarch64_generic/base
src/gz old_mirror https://mirror.51343.ru/openwrt/releases/24.10.1/targets/rockchip/armv8/kmods/6.6.86-1-example
src/gz upstream_mirror https://mirror.infotechtg.ru/openwrt/releases/24.10.7/packages/aarch64_generic/luci
src/gz glinet_core https://firmware.example/openwrt/releases/v24.x/v24.10.7/mediatek/filogic
src/gz glinet_plain https://firmware.example/openwrt/releases/v24.x/24.10.7/mediatek/filogic/
https://downloads.openwrt.org/releases/v25.x/v25.12.5/rockchip/armv8/packages/packages.adb
https://downloads.openwrt.org/releases/v25.x/v25.12.5/aarch64_generic/video/packages.adb
EOF
cp "$distfeeds" "$WORK_DIR/original"

begin_package_mirror_transaction
rewrite_package_repository_file "$distfeeds"

grep -Fxq 'src/gz glinet_core https://firmware.example/openwrt/releases/v24.x/v24.10.7/mediatek/filogic' "$distfeeds" ||
  fail_test "transaction changed a vendor feed"
grep -Fxq 'src/gz glinet_plain https://firmware.example/openwrt/releases/v24.x/24.10.7/mediatek/filogic/' "$distfeeds" ||
  fail_test "transaction changed a custom feed"
grep -Fq 'https://mirror.example/openwrt/releases/24.10.7/' "$distfeeds" ||
  fail_test "transaction did not rewrite OpenWrt 24 feeds"
grep -Fxq 'https://mirror.example/openwrt/releases/25.12.5/targets/rockchip/armv8/packages/packages.adb' "$distfeeds" ||
  fail_test "transaction did not normalize an OpenWrt 25 target feed"
grep -Fxq 'https://mirror.example/openwrt/releases/25.12.5/packages/aarch64_generic/video/packages.adb' "$distfeeds" ||
  fail_test "transaction did not normalize an OpenWrt 25 package feed"
[ -s "$distfeeds.pre-forkop-mirror" ] ||
  fail_test "transaction did not create a persistent recovery copy"
grep -Fxq 'src/gz old_mirror https://mirror.example/openwrt/releases/24.10.1/targets/rockchip/armv8/kmods/6.6.86-1-example' "$distfeeds" ||
  fail_test "legacy mirror migration changed the release or kernel ABI"
grep -Fxq 'src/gz upstream_mirror https://mirror.example/openwrt/releases/24.10.7/packages/aarch64_generic/luci' "$distfeeds" ||
  fail_test "an opted-in mirror must replace feeds left on the former upstream mirror"

rollback_package_mirror >/dev/null
cmp -s "$WORK_DIR/original" "$distfeeds" ||
  fail_test "transaction rollback did not restore original feeds"

transaction_key="$WORK_DIR/new-forkop-key.pem"
begin_package_mirror_transaction
backup_package_mirror_file "$transaction_key"
printf '%s\n' 'temporary key' > "$transaction_key"
rollback_package_mirror >/dev/null
[ ! -e "$transaction_key" ] ||
  fail_test "transaction rollback did not remove a newly created key"

printf '%s\n' 'existing key' > "$transaction_key"
begin_package_mirror_transaction
backup_package_mirror_file "$transaction_key"
printf '%s\n' 'replacement key' > "$transaction_key"
rollback_package_mirror >/dev/null
grep -Fxq 'existing key' "$transaction_key" ||
  fail_test "transaction rollback did not restore an existing key"

begin_package_mirror_transaction
rewrite_package_repository_file "$distfeeds"
commit_package_mirror_transaction
cleanup
grep -Fq 'https://mirror.example/openwrt/releases/24.10.7/' "$distfeeds" ||
  fail_test "committed transaction was unexpectedly rolled back"
TMP_DIR="$WORK_DIR/tmp-after-cleanup"
mkdir -p "$TMP_DIR"

PKG_IS_APK=1
apk() {
  case "$1:$2:$3" in
    'info:-e:sing-box-tiny') printf '%s\n' 'sing-box-tiny'; return 0 ;;
    'info:-e:sing-box') printf '%s\n' 'sing-box-tiny'; return 0 ;;
    'info:-W:/usr/bin/sing-box') printf '%s\n' '/usr/bin/sing-box is owned by sing-box-tiny-1.13.18-r1'; return 0 ;;
  esac
  return 1
}
installed_sing_box_package | grep -Fxq 'sing-box-tiny' ||
  fail_test "APK ownership lookup did not recognize sing-box-tiny"
if pkg_is_installed sing-box; then
  fail_test "APK virtual sing-box dependency was mistaken for the normal sing-box package"
fi
unset -f apk

# configure_package_mirror on APK. The upstream feed and key are removed on
# every path and never installed; nothing is downloaded for them.
APK_ROOT="$WORK_DIR/apk-root"
APK_REPOSITORIES_FILE="$APK_ROOT/etc/apk/repositories"
APK_DISTFEEDS_FILE="$APK_ROOT/etc/apk/repositories.d/distfeeds.list"
UPSTREAM_APK_REPOSITORY_FILE="$APK_ROOT/etc/apk/repositories.d/forkop.list"
UPSTREAM_APK_KEY_FILE="$APK_ROOT/etc/apk/keys/forkop-mirror.pem"
APK_EXTRA_LIST="$APK_ROOT/etc/apk/repositories.d/extra.list"
OPKG_DISTFEEDS_FILE="$APK_ROOT/etc/opkg/distfeeds.conf"

download_with_retry() {
  printf '%s\n' "$1" >>"$WORK_DIR/downloads.log"
  return 1
}
download_file_once() {
  printf '%s\n' "$1" >>"$WORK_DIR/downloads.log"
  return 1
}
pkg_list_update() {
  printf '%s\n' update >>"$WORK_DIR/updates.log"
  return "${PKG_LIST_UPDATE_STATUS:-0}"
}

prepare_apk_root() {
  rm -rf "$APK_ROOT"
  mkdir -p "$APK_ROOT/etc/apk/repositories.d" "$APK_ROOT/etc/apk/keys"
  printf '%s\n' \
    'https://downloads.openwrt.org/releases/25.12.5/targets/rockchip/armv8/packages/packages.adb' \
    'https://mirror.infotechtg.ru/openwrt/releases/25.12.5/packages/aarch64_generic/base/packages.adb' \
    'http://mirror.51343.ru/openwrt/releases/v25.x/v25.12.5/rockchip/armv8/packages/packages.adb' \
    'https://mirror.51343.ru/openwrt/releases/v25.x/v25.12.5/aarch64_generic/video/packages.adb' \
    >"$APK_DISTFEEDS_FILE"
  # Another feed list: a lookalike host, vendor and official feeds in the
  # vNN.x layout, an upstream feed outside the OpenWrt release tree.
  printf '%s\n' \
    'https://mirror.infotechtg.ru.example/openwrt/releases/25.12.5/packages/aarch64_generic/luci/packages.adb' \
    'https://vendor.example/openwrt/releases/v25.x/v25.12.5/rockchip/armv8/packages/packages.adb' \
    'https://downloads.openwrt.org/releases/v25.x/v25.12.5/rockchip/armv8/packages/packages.adb' \
    'https://mirror.51343.ru/forkop/apk/current/packages.adb' \
    'https://mirror.infotechtg.ru/openwrt/releases/25.12.5/packages/aarch64_generic/luci/packages.adb' \
    >"$APK_EXTRA_LIST"
  printf '%s\n' 'https://vendor.example/custom/packages.adb' >"$APK_REPOSITORIES_FILE"
  printf '%s\n' 'https://mirror.infotechtg.ru/forkop/mirror/current/packages.adb' >"$UPSTREAM_APK_REPOSITORY_FILE"
  printf '%s\n' '-----BEGIN PUBLIC KEY-----' 'upstream' '-----END PUBLIC KEY-----' >"$UPSTREAM_APK_KEY_FILE"
  printf '%s\n' 'official key' >"$APK_ROOT/etc/apk/keys/openwrt.pem"
  rm -rf "$WORK_DIR/apk-original"
  cp -R "$APK_ROOT" "$WORK_DIR/apk-original"
  : >"$WORK_DIR/downloads.log"
  : >"$WORK_DIR/updates.log"
  MIRROR_TRANSACTION_ACTIVE=0
}

assert_no_upstream_repository() {
  [ ! -e "$UPSTREAM_APK_REPOSITORY_FILE" ] ||
    fail_test "$1: the upstream forkop.list feed is still configured"
  [ ! -e "$UPSTREAM_APK_KEY_FILE" ] ||
    fail_test "$1: the upstream forkop-mirror.pem key is still trusted"
  [ "$(find "$APK_ROOT/etc/apk/keys" -type f | wc -l)" -eq 1 ] ||
    fail_test "$1: an APK key was added"
  [ ! -s "$WORK_DIR/downloads.log" ] ||
    fail_test "$1: the installer downloaded something for the upstream feed: $(cat "$WORK_DIR/downloads.log")"
}

# Opted-in mirror: official feeds move to it, the list update commits.
prepare_apk_root
PKG_IS_APK=1
MIRROR_BASE_URL="https://mirror.example"
configure_package_mirror >/dev/null
assert_no_upstream_repository "opted-in APK mirror"
grep -Fxq 'https://mirror.example/openwrt/releases/25.12.5/targets/rockchip/armv8/packages/packages.adb' "$APK_DISTFEEDS_FILE" ||
  fail_test "an opted-in APK mirror did not receive the official OpenWrt feed"
cmp -s "$WORK_DIR/apk-original/etc/apk/repositories" "$APK_REPOSITORIES_FILE" ||
  fail_test "a custom APK repository was changed"
[ "$(wc -l <"$WORK_DIR/updates.log")" -eq 1 ] ||
  fail_test "an opted-in APK mirror must be verified by one package list update"
[ "$MIRROR_TRANSACTION_ACTIVE" -eq 0 ] ||
  fail_test "a verified APK mirror must commit the feed transaction"
if grep -R -F 'forkop/mirror/current' "$APK_ROOT/etc/apk" >/dev/null; then
  fail_test "the upstream Forkop feed must not be written anywhere"
fi

# A failed list update restores the feeds and the upstream files together.
prepare_apk_root
PKG_LIST_UPDATE_STATUS=1
if (configure_package_mirror) >/dev/null 2>&1; then
  fail_test "a failed APK list update against the mirror must stop the installation"
fi
PKG_LIST_UPDATE_STATUS=0
diff -r -x '*.pre-forkop-mirror' "$WORK_DIR/apk-original" "$APK_ROOT" >/dev/null ||
  fail_test "a failed APK list update must restore the original feeds and files"

# No mirror: before the first package list update, the OpenWrt release feeds
# an upstream installation left on a former mirror go back to
# downloads.openwrt.org, with the vNN.x layout of those mirrors undone as in
# mirror-migration.sh. Lines on any other host stay byte for byte. No list
# update runs here, no platform index is consulted and the upstream files go.
printf '%s\n' \
  'https://downloads.openwrt.org/releases/25.12.5/targets/rockchip/armv8/packages/packages.adb' \
  'https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_generic/base/packages.adb' \
  'https://downloads.openwrt.org/releases/25.12.5/targets/rockchip/armv8/packages/packages.adb' \
  'https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_generic/video/packages.adb' \
  >"$WORK_DIR/apk-distfeeds-restored"
printf '%s\n' \
  'https://mirror.infotechtg.ru.example/openwrt/releases/25.12.5/packages/aarch64_generic/luci/packages.adb' \
  'https://vendor.example/openwrt/releases/v25.x/v25.12.5/rockchip/armv8/packages/packages.adb' \
  'https://downloads.openwrt.org/releases/v25.x/v25.12.5/rockchip/armv8/packages/packages.adb' \
  'https://mirror.51343.ru/forkop/apk/current/packages.adb' \
  'https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_generic/luci/packages.adb' \
  >"$WORK_DIR/apk-extra-restored"

assert_apk_feeds_restored() {
  cmp -s "$WORK_DIR/apk-distfeeds-restored" "$APK_DISTFEEDS_FILE" ||
    fail_test "$1: APK feeds on a former mirror were not restored to downloads.openwrt.org: $(cat "$APK_DISTFEEDS_FILE")"
  cmp -s "$WORK_DIR/apk-extra-restored" "$APK_EXTRA_LIST" ||
    fail_test "$1: only the release feeds on a former mirror may change in another feed list: $(cat "$APK_EXTRA_LIST")"
  cmp -s "$WORK_DIR/apk-original/etc/apk/repositories" "$APK_REPOSITORIES_FILE" ||
    fail_test "$1: APK repositories on other hosts must remain unchanged"
}

prepare_apk_root
MIRROR_BASE_URL=""
configure_package_mirror >"$WORK_DIR/no-mirror.out" 2>&1
assert_no_upstream_repository "APK without a mirror"
assert_apk_feeds_restored "APK without a mirror"
grep -Fq "$APK_EXTRA_LIST still names a former upstream mirror outside its OpenWrt release feeds" "$WORK_DIR/no-mirror.out" ||
  fail_test "a former mirror feed outside the OpenWrt release tree must be reported: $(cat "$WORK_DIR/no-mirror.out")"
grep -Fq 'OpenWrt feeds left on the former upstream mirror now use downloads.openwrt.org' "$WORK_DIR/no-mirror.out" ||
  fail_test "the restore of the official feeds must be reported: $(cat "$WORK_DIR/no-mirror.out")"
[ ! -e "$APK_DISTFEEDS_FILE.pre-forkop-mirror" ] ||
  fail_test "restoring the official feeds must not save a mirror recovery copy"
[ ! -s "$WORK_DIR/updates.log" ] ||
  fail_test "no package list update may run while configuring feeds without a mirror"
check_mirror_platform_support >/dev/null
[ ! -s "$WORK_DIR/downloads.log" ] ||
  fail_test "the platform index must not be downloaded without a mirror"
# Until the package lists were updated every change stays revertible.
[ "$MIRROR_TRANSACTION_ACTIVE" -eq 1 ] ||
  fail_test "the feed changes must stay revertible until the list update"
rollback_package_mirror >/dev/null
diff -r -x '*.pre-forkop-mirror' "$WORK_DIR/apk-original" "$APK_ROOT" >/dev/null ||
  fail_test "an installation error before the list update must restore the feeds, the upstream feed and the key"

# A failed package list update stops the installation and restores every
# feed and file it changed, as main does through fail and its EXIT cleanup.
prepare_apk_root
if (
  TMP_DIR="$WORK_DIR/tmp-failed-update"
  mkdir -p "$TMP_DIR"
  trap cleanup EXIT
  configure_package_mirror
  PKG_LIST_UPDATE_STATUS=1
  pkg_list_update || fail "Failed to update package lists"
  commit_package_mirror_transaction
) >/dev/null 2>&1; then
  fail_test "a failed package list update must stop the installation"
fi
[ "$(cat "$WORK_DIR/updates.log")" = update ] ||
  fail_test "the restored official feeds must be checked by one package list update"
diff -r -x '*.pre-forkop-mirror' "$WORK_DIR/apk-original" "$APK_ROOT" >/dev/null ||
  fail_test "a failed package list update must restore the feeds on the former mirror and the upstream files"

prepare_apk_root
configure_package_mirror >/dev/null
pkg_list_update
commit_package_mirror_transaction
cleanup
TMP_DIR="$WORK_DIR/tmp-after-commit"
mkdir -p "$TMP_DIR"
assert_no_upstream_repository "committed removal"
assert_apk_feeds_restored "committed restore"

# Without upstream files and former mirror feeds the transaction records
# nothing.
prepare_apk_root
rm -f "$UPSTREAM_APK_REPOSITORY_FILE" "$UPSTREAM_APK_KEY_FILE" "$APK_EXTRA_LIST"
cp "$WORK_DIR/apk-distfeeds-restored" "$APK_DISTFEEDS_FILE"
configure_package_mirror >"$WORK_DIR/no-mirror.out"
[ "$MIRROR_BACKUP_COUNT" -eq 0 ] ||
  fail_test "absent upstream files and official feeds must not be recorded in the feed transaction"
grep -Fq 'No dependency mirror was requested; OpenWrt package feeds remain unchanged' "$WORK_DIR/no-mirror.out" ||
  fail_test "unchanged feeds must be reported as unchanged: $(cat "$WORK_DIR/no-mirror.out")"
commit_package_mirror_transaction

routerich_feeds="$WORK_DIR/etc/opkg/routerich-distfeeds.conf"
cat >"$routerich_feeds" <<'EOF'
src/gz routerich_core https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/core
src/gz routerich_base https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/base
src/gz routerich_luci https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/luci
src/gz routerich_packages https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/packages
src/gz routerich_routing https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/routing
src/gz routerich_telephony https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/telephony
src/gz routerich https://packages.routerich.ru/24.10/mediatek/filogic/routerich
EOF
cp "$routerich_feeds" "$WORK_DIR/routerich-original"
OPKG_DISTFEEDS_FILE="$routerich_feeds"
PKG_IS_APK=0
command_exists() { return 0; }
: >"$WORK_DIR/updates.log"
MIRROR_BASE_URL="https://mirror.example"
configure_package_mirror >/dev/null
cmp -s "$WORK_DIR/routerich-original" "$routerich_feeds" ||
  fail_test "Routerich OPKG feeds must remain byte-for-byte unchanged"
[ ! -s "$WORK_DIR/updates.log" ] ||
  fail_test "unchanged vendor OPKG feeds must not trigger a list update against the mirror"
commit_package_mirror_transaction

# No mirror on OPKG: feeds on a former mirror go back to downloads.openwrt.org
# in distfeeds.conf and customfeeds.conf; official, vendor and lookalike feeds
# stay byte for byte, official ones in the vNN.x layout included.
OPKG_DISTFEEDS_FILE="$distfeeds"
customfeeds="$WORK_DIR/etc/opkg/customfeeds.conf"
cp "$WORK_DIR/original" "$distfeeds"
cat >"$customfeeds" <<'EOF'
src/gz legacy_layout http://mirror.51343.ru/openwrt/releases/v24.x/v24.10.7/mediatek/filogic
src/gz legacy_layout_slash https://mirror.infotechtg.ru/openwrt/releases/v24.x/24.10.7/mediatek/filogic/
src/gz lookalike https://mirror.infotechtg.ru.example/openwrt/releases/24.10.7/packages/aarch64_cortex-a53/base
src/gz upstream_forkop https://mirror.infotechtg.ru/forkop/ipk/current
EOF
cp "$customfeeds" "$WORK_DIR/customfeeds-original"
sed \
  -e 's#^src/gz old_mirror .*#src/gz old_mirror https://downloads.openwrt.org/releases/24.10.1/targets/rockchip/armv8/kmods/6.6.86-1-example#' \
  -e 's#^src/gz upstream_mirror .*#src/gz upstream_mirror https://downloads.openwrt.org/releases/24.10.7/packages/aarch64_generic/luci#' \
  "$WORK_DIR/original" >"$WORK_DIR/distfeeds-restored"
cat >"$WORK_DIR/customfeeds-restored" <<'EOF'
src/gz legacy_layout https://downloads.openwrt.org/releases/24.10.7/targets/mediatek/filogic/packages
src/gz legacy_layout_slash https://downloads.openwrt.org/releases/24.10.7/targets/mediatek/filogic/packages
src/gz lookalike https://mirror.infotechtg.ru.example/openwrt/releases/24.10.7/packages/aarch64_cortex-a53/base
src/gz upstream_forkop https://mirror.infotechtg.ru/forkop/ipk/current
EOF
! cmp -s "$WORK_DIR/original" "$WORK_DIR/distfeeds-restored" ||
  fail_test "the OPKG fixture must contain feeds on a former mirror"
MIRROR_BASE_URL=""
configure_package_mirror >"$WORK_DIR/no-mirror.out" 2>&1
cmp -s "$WORK_DIR/distfeeds-restored" "$distfeeds" ||
  fail_test "OPKG feeds on a former mirror must be restored, all others kept: $(cat "$distfeeds")"
cmp -s "$WORK_DIR/customfeeds-restored" "$customfeeds" ||
  fail_test "OPKG custom feeds on a former mirror must be restored, all others kept: $(cat "$customfeeds")"
grep -Fq "$customfeeds still names a former upstream mirror" "$WORK_DIR/no-mirror.out" ||
  fail_test "an OPKG feed on a former mirror outside the release tree must be reported"
[ ! -s "$WORK_DIR/updates.log" ] ||
  fail_test "no OPKG list update may run while configuring feeds without a mirror"
rollback_package_mirror >/dev/null
cmp -s "$WORK_DIR/original" "$distfeeds" && cmp -s "$WORK_DIR/customfeeds-original" "$customfeeds" ||
  fail_test "an installation error before the OPKG list update must restore the former feeds"

# Official OPKG feeds stay official.
grep -v -E 'mirror\.(51343|infotechtg)\.ru/' "$WORK_DIR/original" >"$distfeeds"
cp "$distfeeds" "$WORK_DIR/distfeeds-official"
rm -f "$customfeeds"
configure_package_mirror >/dev/null
cmp -s "$WORK_DIR/distfeeds-official" "$distfeeds" ||
  fail_test "OPKG feeds must remain unchanged without a mirror"
[ "$MIRROR_BACKUP_COUNT" -eq 0 ] ||
  fail_test "official OPKG feeds must not be recorded in the feed transaction"
commit_package_mirror_transaction

printf 'Installer feed transaction tests passed\n'
