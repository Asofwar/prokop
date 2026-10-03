#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION="$ROOT_DIR/forkop/files/usr/share/forkop/mirror-migration.sh"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/platforms.tsv" <<'EOF'
# target architecture release format
rockchip/armv8 aarch64_generic 25.12.4 apk
mediatek/filogic aarch64_cortex-a53 24.10.5 ipk
EOF

cat > "$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; output="$1" ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
printf 'curl %s\n' "$url" >> "${MIGRATION_EVENT_LOG:?}"
case "$url" in
  */openwrt/forkop-platforms.tsv)
    [ "${MIGRATION_PLATFORM_UNAVAILABLE:-0}" -eq 0 ] || exit 22
    cp "${MIGRATION_PLATFORM_INDEX:?}" "$output"
    ;;
  *) exit 22 ;;
esac
EOF
cat > "$WORK_DIR/bin/apk" <<'EOF'
#!/bin/sh
printf 'apk %s\n' "$*" >> "${MIGRATION_EVENT_LOG:?}"
if [ "${MIGRATION_PACKAGE_UPDATE_FAIL:-0}" -eq 1 ] && [ "${1:-}" = "update" ]; then
  exit 1
fi
EOF
cat > "$WORK_DIR/bin/opkg" <<'EOF'
#!/bin/sh
printf 'opkg %s\n' "$*" >> "${MIGRATION_EVENT_LOG:?}"
if [ "${MIGRATION_PACKAGE_UPDATE_FAIL:-0}" -eq 1 ] && [ "${1:-}" = "update" ]; then
  exit 1
fi
EOF
# Reads answer from the environment; what changes UCI goes to the event log.
cat > "$WORK_DIR/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
  *' get '*'mirror_base_url') printf '%s' "${MIGRATION_CONFIGURED_MIRROR:-}"; exit 0 ;;
  *' get '*'applied_migrations')
    printf '%s\n' "${MIGRATION_APPLIED:-interface_sections enable_component_checks}"
    exit 0
    ;;
esac
printf 'uci %s\n' "$*" >> "${MIGRATION_EVENT_LOG:?}"
EOF
chmod 0755 "$WORK_DIR/bin/"*

# run_migration ROOT EVENT_LOG [VAR=value...]: runs the script against a fake
# root with stub tools, after `env -u FORKOP_MIRROR_BASE_URL` so that only the
# test decides whether the variable is set.
run_migration() {
  local root="$1"
  local events="$2"
  shift 2
  : >> "$events"
  env -u FORKOP_MIRROR_BASE_URL -u FORKOP_PACKAGE_POSTINST \
    PATH="$WORK_DIR/bin:$PATH" \
    FORKOP_MIGRATION_ROOT="$root" \
    FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
    FORKOP_MIGRATION_OPKG_BIN="$WORK_DIR/bin/opkg" \
    FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
    FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
    MIGRATION_PLATFORM_INDEX="$WORK_DIR/platforms.tsv" \
    MIGRATION_EVENT_LOG="$events" \
    "$@" sh "$MIGRATION"
}

apk_root() {
  local root="$1"
  mkdir -p "$root/etc/apk/repositories.d" "$root/etc/apk/keys"
  cat > "$root/etc/openwrt_release" <<'EOF'
DISTRIB_RELEASE='25.12.4'
DISTRIB_TARGET='rockchip/armv8'
DISTRIB_ARCH='aarch64_generic'
EOF
  printf '%s\n' 'https://mirror.infotechtg.ru/forkop/mirror/current/packages.adb' \
    > "$root/etc/apk/repositories.d/forkop.list"
  printf '%s\n' '-----BEGIN PUBLIC KEY-----' 'upstream-key' '-----END PUBLIC KEY-----' \
    > "$root/etc/apk/keys/forkop-mirror.pem"
  printf '%s\n' '-----BEGIN PUBLIC KEY-----' 'openwrt-key' '-----END PUBLIC KEY-----' \
    > "$root/etc/apk/keys/openwrt.pem"
}

assert_no_upstream_feed() {
  local root="$1"
  local label="$2"
  [ ! -e "$root/etc/apk/repositories.d/forkop.list" ] ||
    fail "$label: the upstream Forkop APK feed was not removed"
  [ ! -e "$root/etc/apk/keys/forkop-mirror.pem" ] ||
    fail "$label: the upstream mirror APK key was not removed"
  grep -Fq openwrt-key "$root/etc/apk/keys/openwrt.pem" ||
    fail "$label: an unrelated APK key was touched"
}

assert_no_mirror_downloads() {
  local events="$1"
  local label="$2"
  if grep -Eq 'forkop-apk\.pem|forkop/mirror/' "$events"; then
    fail "$label: the upstream mirror key or Forkop feed was requested"
  fi
  if grep -Eq '^uci ' "$events"; then
    fail "$label: the package script changed UCI settings"
  fi
}

# 1. No mirror (the default): APK feeds on a former upstream mirror go back to
# OpenWrt by rewriting the release prefix (including the old vNN.x layout) in
# the current file, so edits made since the mirror was applied stay. The copy
# saved before the mirror is used only when former-mirror lines would remain
# outside the release feeds, and only when it is clean itself. Other hosts
# stay.
root="$WORK_DIR/apk-off"
apk_root "$root"
cat > "$root/etc/apk/repositories" <<'EOF'
https://mirror.infotechtg.ru/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb
http://mirror.51343.ru/openwrt/releases/v25.x/v25.12.4/rockchip/armv8/packages/packages.adb
EOF
# The saved copy predates a feed the user added and a release they changed.
cat > "$root/etc/apk/repositories.d/distfeeds.list" <<'EOF'
https://mirror.infotechtg.ru/openwrt/releases/25.12.5/packages/aarch64_generic/base/packages.adb
https://vendor.example/openwrt/releases/25.12.4/packages/aarch64_generic/vendor/packages.adb
https://user-feed.example/apk/aarch64_generic/extra/packages.adb
EOF
cat > "$root/etc/apk/repositories.d/distfeeds.list.pre-forkop-mirror" <<'EOF'
https://ftp.snt.utwente.nl/pub/software/openwrt/releases/25.12.4/packages/aarch64_generic/base/packages.adb
https://vendor.example/openwrt/releases/25.12.4/packages/aarch64_generic/vendor/packages.adb
EOF
# A former-mirror line outside the release feeds cannot be moved by prefix:
# the clean saved copy replaces this file.
cat > "$root/etc/apk/repositories.d/snapshot.list" <<'EOF'
https://mirror.infotechtg.ru/openwrt/releases/25.12.4/packages/aarch64_generic/luci/packages.adb
https://mirror.infotechtg.ru/openwrt/snapshots/packages/aarch64_generic/luci/packages.adb
EOF
cat > "$root/etc/apk/repositories.d/snapshot.list.pre-forkop-mirror" <<'EOF'
https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/luci/packages.adb
EOF
cp "$root/etc/apk/repositories.d/snapshot.list.pre-forkop-mirror" "$WORK_DIR/apk-off-snapshot-original"
# When the saved copy names a former mirror too, only the release feeds move
# and the copy is kept.
cat > "$root/etc/apk/repositories.d/stuck.list" <<'EOF'
https://mirror.infotechtg.ru/openwrt/releases/25.12.4/packages/aarch64_generic/routing/packages.adb
https://mirror.infotechtg.ru/openwrt/snapshots/packages/aarch64_generic/routing/packages.adb
EOF
cat > "$root/etc/apk/repositories.d/stuck.list.pre-forkop-mirror" <<'EOF'
https://mirror.51343.ru/openwrt/snapshots/packages/aarch64_generic/routing/packages.adb
EOF
cp "$root/etc/apk/repositories.d/stuck.list.pre-forkop-mirror" "$WORK_DIR/apk-off-stuck-original"
cat > "$root/etc/apk/repositories.d/custom.list" <<'EOF'
https://mirror.infotechtg.ru/openwrt/releases/v25.x/v25.12.4/aarch64_generic/packages/packages.adb
https://own-mirror.example/openwrt/releases/25.12.4/packages/aarch64_generic/luci/packages.adb
EOF
run_migration "$root" "$WORK_DIR/apk-off.log" FORKOP_PACKAGE_POSTINST=1 \
  > "$WORK_DIR/apk-off.out" 2>&1 || fail "disabled mirror reconciliation failed"
assert_no_upstream_feed "$root" "disabled mirror"
assert_no_mirror_downloads "$WORK_DIR/apk-off.log" "disabled mirror"
grep -Fq 'curl' "$WORK_DIR/apk-off.log" && fail "disabled mirror contacted a mirror"
grep -Fq 'apk update' "$WORK_DIR/apk-off.log" && fail "package postinst ran apk update"
cat > "$WORK_DIR/apk-off-expected" <<'EOF'
https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb
https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb
EOF
cmp -s "$WORK_DIR/apk-off-expected" "$root/etc/apk/repositories" ||
  fail "APK repositories were not restored from the former mirror: $(cat "$root/etc/apk/repositories")"
cat > "$WORK_DIR/apk-off-distfeeds-expected" <<'EOF'
https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_generic/base/packages.adb
https://vendor.example/openwrt/releases/25.12.4/packages/aarch64_generic/vendor/packages.adb
https://user-feed.example/apk/aarch64_generic/extra/packages.adb
EOF
cmp -s "$WORK_DIR/apk-off-distfeeds-expected" "$root/etc/apk/repositories.d/distfeeds.list" ||
  fail "APK distfeeds lost edits made after the mirror was applied: $(cat "$root/etc/apk/repositories.d/distfeeds.list")"
[ ! -e "$root/etc/apk/repositories.d/distfeeds.list.pre-forkop-mirror" ] ||
  fail "a pre-mirror backup superseded by the restored file was kept"
cmp -s "$WORK_DIR/apk-off-snapshot-original" "$root/etc/apk/repositories.d/snapshot.list" ||
  fail "a file with former-mirror lines outside its release feeds was not restored from its clean backup: $(cat "$root/etc/apk/repositories.d/snapshot.list")"
[ ! -e "$root/etc/apk/repositories.d/snapshot.list.pre-forkop-mirror" ] ||
  fail "the used pre-mirror backup was kept"
cat > "$WORK_DIR/apk-off-stuck-expected" <<'EOF'
https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/routing/packages.adb
https://mirror.infotechtg.ru/openwrt/snapshots/packages/aarch64_generic/routing/packages.adb
EOF
cmp -s "$WORK_DIR/apk-off-stuck-expected" "$root/etc/apk/repositories.d/stuck.list" ||
  fail "release feeds next to an unmovable former-mirror line were not restored by prefix: $(cat "$root/etc/apk/repositories.d/stuck.list")"
cmp -s "$WORK_DIR/apk-off-stuck-original" "$root/etc/apk/repositories.d/stuck.list.pre-forkop-mirror" ||
  fail "a backup that names a former mirror itself was not kept for a file that still names one"
grep -Fq "stuck.list still names a former upstream mirror" "$WORK_DIR/apk-off.out" ||
  fail "a former-mirror line that could not be restored was not reported"
cat > "$WORK_DIR/apk-off-custom-expected" <<'EOF'
https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/packages/packages.adb
https://own-mirror.example/openwrt/releases/25.12.4/packages/aarch64_generic/luci/packages.adb
EOF
cmp -s "$WORK_DIR/apk-off-custom-expected" "$root/etc/apk/repositories.d/custom.list" ||
  fail "a custom APK list was not restored only for the former mirror: $(cat "$root/etc/apk/repositories.d/custom.list")"
grep -Fq 'no longer use the former upstream mirror' "$WORK_DIR/apk-off.out" ||
  fail "restoring feeds was not reported"

# A second run has nothing left to change and refreshes nothing.
: > "$WORK_DIR/apk-off-again.log"
feed_files() {
  find "$1/etc/apk" -type f -exec md5sum {} + | sort
}
feed_files "$root" > "$WORK_DIR/apk-off-again-before"
run_migration "$root" "$WORK_DIR/apk-off-again.log" >/dev/null 2>&1 ||
  fail "repeated disabled mirror reconciliation failed"
feed_files "$root" | cmp -s "$WORK_DIR/apk-off-again-before" - ||
  fail "repeated reconciliation changed restored feeds or their backups"
[ ! -s "$WORK_DIR/apk-off-again.log" ] ||
  fail "repeated reconciliation ran a package or network command: $(cat "$WORK_DIR/apk-off-again.log")"
printf 'PASS: disabled mirror restores feeds from the former upstream mirror\n'

# 2. Outside package scripts (the installer's second run) a restore refreshes
# the index; a refresh failure only warns and keeps the official feeds.
root="$WORK_DIR/apk-off-installer"
apk_root "$root"
printf '%s\n' 'https://mirror.51343.ru/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  > "$root/etc/apk/repositories"
run_migration "$root" "$WORK_DIR/apk-off-installer.log" MIGRATION_PACKAGE_UPDATE_FAIL=1 \
  > "$WORK_DIR/apk-off-installer.out" 2>&1 || fail "a failed index refresh made the restore fail"
grep -Fxq 'apk update' "$WORK_DIR/apk-off-installer.log" || fail "restore outside postinst did not refresh the index"
grep -Fxq 'https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  "$root/etc/apk/repositories" || fail "restored feeds were rolled back after a refresh failure"
grep -Fq 'Forkop mirror:' "$WORK_DIR/apk-off-installer.out" || fail "refresh failure was not reported"
printf 'PASS: restore outside postinst refreshes the index and keeps official feeds\n'

# 3. An explicitly empty FORKOP_MIRROR_BASE_URL wins over a UCI mirror.
root="$WORK_DIR/apk-env-off"
apk_root "$root"
printf '%s\n' 'https://mirror.infotechtg.ru/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  > "$root/etc/apk/repositories"
run_migration "$root" "$WORK_DIR/apk-env-off.log" FORKOP_PACKAGE_POSTINST=1 FORKOP_MIRROR_BASE_URL= \
  MIGRATION_CONFIGURED_MIRROR=https://own-mirror.example >/dev/null 2>&1 ||
  fail "empty environment mirror failed"
grep -Fxq 'https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  "$root/etc/apk/repositories" || fail "an empty FORKOP_MIRROR_BASE_URL did not disable the UCI mirror"
grep -Fq 'curl' "$WORK_DIR/apk-env-off.log" && fail "an empty FORKOP_MIRROR_BASE_URL still used the UCI mirror"
assert_no_upstream_feed "$root" "empty environment mirror"
printf 'PASS: an empty FORKOP_MIRROR_BASE_URL disables the mirror\n'

# 4. OPKG without a mirror: the old vNN.x layout becomes the OpenWrt layout;
# vendor feeds stay.
root="$WORK_DIR/opkg-off"
mkdir -p "$root/etc/opkg"
cat > "$root/etc/opkg/distfeeds.conf" <<'EOF'
src/gz openwrt_core https://mirror.51343.ru/openwrt/releases/v24.x/v24.10.5/mediatek/filogic
src/gz openwrt_base https://mirror.infotechtg.ru/openwrt/releases/24.10.5/packages/aarch64_cortex-a53/base
src/gz vendor_custom https://packages.vendor.example/24.10/mediatek/filogic/base
EOF
cat > "$root/etc/opkg/distfeeds.conf.pre-forkop-mirror" <<'EOF'
src/gz openwrt_core https://mirror.51343.ru/openwrt/releases/24.10.5/targets/mediatek/filogic/packages
EOF
run_migration "$root" "$WORK_DIR/opkg-off.log" FORKOP_PACKAGE_POSTINST=1 \
  FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/missing-apk" >/dev/null 2>&1 ||
  fail "disabled OPKG reconciliation failed"
cat > "$WORK_DIR/opkg-off-expected" <<'EOF'
src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/packages
src/gz openwrt_base https://downloads.openwrt.org/releases/24.10.5/packages/aarch64_cortex-a53/base
src/gz vendor_custom https://packages.vendor.example/24.10/mediatek/filogic/base
EOF
cmp -s "$WORK_DIR/opkg-off-expected" "$root/etc/opkg/distfeeds.conf" ||
  fail "OPKG feeds were not restored by prefix: $(cat "$root/etc/opkg/distfeeds.conf")"
[ ! -e "$root/etc/opkg/distfeeds.conf.pre-forkop-mirror" ] ||
  fail "a pre-mirror backup superseded by the restored OPKG feeds was kept"
grep -Fq 'opkg update' "$WORK_DIR/opkg-off.log" && fail "OPKG postinst ran opkg update"
printf 'PASS: disabled mirror restores OPKG feeds\n'

# 5. Feeds on a custom mirror are the user's choice: without a mirror setting
# they stay as they are.
root="$WORK_DIR/apk-custom-feed"
apk_root "$root"
printf '%s\n' 'https://own-mirror.example/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  > "$root/etc/apk/repositories"
cp "$root/etc/apk/repositories" "$WORK_DIR/apk-custom-feed-before"
run_migration "$root" "$WORK_DIR/apk-custom-feed.log" FORKOP_PACKAGE_POSTINST=1 >/dev/null 2>&1 ||
  fail "custom feed reconciliation failed"
cmp -s "$WORK_DIR/apk-custom-feed-before" "$root/etc/apk/repositories" ||
  fail "a feed on a custom host was changed without a mirror setting"
assert_no_upstream_feed "$root" "custom feed"
printf 'PASS: feeds on other hosts are never restored\n'

# 6. An opted-in mirror (UCI): official and former-mirror feeds move to it,
# vendor feeds stay, and no key or Forkop feed is installed.
root="$WORK_DIR/apk-on"
apk_root "$root"
cat > "$root/etc/apk/repositories" <<'EOF'
https://archive.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb
EOF
cat > "$root/etc/apk/repositories.d/distfeeds.list" <<'EOF'
https://ftp.snt.utwente.nl/pub/software/openwrt/releases/25.12.4/packages/aarch64_generic/base/packages.adb
https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/luci/packages.adb
https://mirror.infotechtg.ru/openwrt/releases/v25.x/v25.12.4/aarch64_generic/packages/packages.adb
https://vendor.example/openwrt/releases/25.12.4/packages/aarch64_generic/vendor/packages.adb
EOF
cp "$root/etc/apk/repositories.d/distfeeds.list" "$WORK_DIR/apk-on-distfeeds-original"
run_migration "$root" "$WORK_DIR/apk-on.log" MIGRATION_CONFIGURED_MIRROR=https://own-mirror.example/ \
  > "$WORK_DIR/apk-on.out" 2>&1 || fail "opted-in mirror reconciliation failed"
assert_no_upstream_feed "$root" "opted-in mirror"
assert_no_mirror_downloads "$WORK_DIR/apk-on.log" "opted-in mirror"
grep -Fxq 'curl https://own-mirror.example/openwrt/forkop-platforms.tsv' "$WORK_DIR/apk-on.log" ||
  fail "the opted-in mirror platform index was not consulted"
grep -Fxq 'https://own-mirror.example/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  "$root/etc/apk/repositories" || fail "APK target feed was not moved to the opted-in mirror"
cat > "$WORK_DIR/apk-on-expected" <<'EOF'
https://own-mirror.example/openwrt/releases/25.12.4/packages/aarch64_generic/base/packages.adb
https://own-mirror.example/openwrt/releases/25.12.4/packages/aarch64_generic/luci/packages.adb
https://own-mirror.example/openwrt/releases/25.12.4/packages/aarch64_generic/packages/packages.adb
https://vendor.example/openwrt/releases/25.12.4/packages/aarch64_generic/vendor/packages.adb
EOF
cmp -s "$WORK_DIR/apk-on-expected" "$root/etc/apk/repositories.d/distfeeds.list" ||
  fail "APK distfeeds were not moved to the opted-in mirror: $(cat "$root/etc/apk/repositories.d/distfeeds.list")"
cmp -s "$WORK_DIR/apk-on-distfeeds-original" "$root/etc/apk/repositories.d/distfeeds.list.pre-forkop-mirror" ||
  fail "the original APK distfeeds were not saved before the mirror was applied"
grep -Fxq 'apk update' "$WORK_DIR/apk-on.log" || fail "the opted-in mirror index was not checked"
printf 'PASS: opted-in mirror moves feeds without the upstream key or feed\n'

# The same mirror again changes nothing and refreshes nothing.
: > "$WORK_DIR/apk-on-again.log"
run_migration "$root" "$WORK_DIR/apk-on-again.log" MIGRATION_CONFIGURED_MIRROR=https://own-mirror.example \
  >/dev/null 2>&1 || fail "repeated opted-in reconciliation failed"
grep -Fxq 'apk update' "$WORK_DIR/apk-on-again.log" &&
  fail "an unchanged opted-in mirror forced a package index update"
printf 'PASS: idempotent opted-in mirror\n'

# Turning the opted-in mirror off later keeps feeds on that custom mirror.
run_migration "$root" "$WORK_DIR/apk-on-off.log" FORKOP_PACKAGE_POSTINST=1 >/dev/null 2>&1 ||
  fail "disabling a custom mirror failed"
grep -Fq 'https://own-mirror.example/openwrt/releases/' "$root/etc/apk/repositories" ||
  fail "disabling the mirror rewrote feeds on the custom mirror"

# 7. Inside package scripts the opted-in mirror never runs apk update.
root="$WORK_DIR/apk-on-postinst"
apk_root "$root"
printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  > "$root/etc/apk/repositories"
run_migration "$root" "$WORK_DIR/apk-on-postinst.log" FORKOP_PACKAGE_POSTINST=1 \
  FORKOP_MIRROR_BASE_URL=https://env-mirror.example MIGRATION_CONFIGURED_MIRROR=https://own-mirror.example \
  >/dev/null 2>&1 || fail "postinst with an opted-in mirror failed"
grep -Fq 'apk update' "$WORK_DIR/apk-on-postinst.log" &&
  fail "package postinst recursively invoked apk update while apk owns the database lock"
grep -Fxq 'https://env-mirror.example/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  "$root/etc/apk/repositories" || fail "FORKOP_MIRROR_BASE_URL did not win over UCI"
assert_no_upstream_feed "$root" "postinst mirror"
printf 'PASS: package postinst avoids nested package-manager lock\n'

# 8. A failed index check rolls the feeds back and still exits 0.
root="$WORK_DIR/apk-on-failure"
apk_root "$root"
printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  > "$root/etc/apk/repositories"
printf '%s\n' 'https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/base/packages.adb' \
  > "$root/etc/apk/repositories.d/distfeeds.list"
cp "$root/etc/apk/repositories" "$WORK_DIR/apk-on-failure-repositories"
cp "$root/etc/apk/repositories.d/distfeeds.list" "$WORK_DIR/apk-on-failure-distfeeds"
run_migration "$root" "$WORK_DIR/apk-on-failure.log" MIGRATION_CONFIGURED_MIRROR=https://own-mirror.example \
  MIGRATION_PACKAGE_UPDATE_FAIL=1 > "$WORK_DIR/apk-on-failure.out" 2>&1 ||
  fail "a failed mirror index check made the script fail"
cmp -s "$WORK_DIR/apk-on-failure-repositories" "$root/etc/apk/repositories" ||
  fail "APK repositories were not rolled back"
cmp -s "$WORK_DIR/apk-on-failure-distfeeds" "$root/etc/apk/repositories.d/distfeeds.list" ||
  fail "APK distfeeds were not rolled back"
grep -Fq 'Forkop mirror:' "$WORK_DIR/apk-on-failure.out" || fail "rollback was not reported"
assert_no_upstream_feed "$root" "rollback"
printf 'PASS: mirror index failure rolls back and exits 0\n'

# 9. An unready mirror (platform missing or index unavailable) and an invalid
# URL leave the feeds untouched, warn and exit 0.
for case_name in unsupported unavailable invalid; do
  root="$WORK_DIR/apk-$case_name"
  apk_root "$root"
  cp "$WORK_DIR/apk-on-failure-repositories" "$root/etc/apk/repositories"
  cp "$WORK_DIR/apk-on-failure-distfeeds" "$root/etc/apk/repositories.d/distfeeds.list"
  extra=(MIGRATION_CONFIGURED_MIRROR=https://own-mirror.example)
  case "$case_name" in
    unsupported)
      printf '%s\n' 'mediatek/filogic aarch64_cortex-a53 25.12.4 apk' > "$WORK_DIR/unsupported-platforms.tsv"
      extra+=(MIGRATION_PLATFORM_INDEX="$WORK_DIR/unsupported-platforms.tsv") ;;
    unavailable) extra+=(MIGRATION_PLATFORM_UNAVAILABLE=1) ;;
    invalid) extra=(MIGRATION_CONFIGURED_MIRROR='ftp://own-mirror.example') ;;
  esac
  run_migration "$root" "$WORK_DIR/apk-$case_name.log" "${extra[@]}" \
    > "$WORK_DIR/apk-$case_name.out" 2>&1 || fail "$case_name mirror made the script fail"
  cmp -s "$WORK_DIR/apk-on-failure-repositories" "$root/etc/apk/repositories" ||
    fail "$case_name mirror changed APK repositories"
  cmp -s "$WORK_DIR/apk-on-failure-distfeeds" "$root/etc/apk/repositories.d/distfeeds.list" ||
    fail "$case_name mirror changed APK distfeeds"
  grep -Fq 'apk update' "$WORK_DIR/apk-$case_name.log" && fail "$case_name mirror ran apk update"
  grep -Fq 'Forkop mirror:' "$WORK_DIR/apk-$case_name.out" || fail "$case_name mirror was not reported"
  assert_no_upstream_feed "$root" "$case_name mirror"
done
printf 'PASS: unready or invalid mirrors leave feeds untouched\n'

# 10. OPKG with an opted-in mirror.
root="$WORK_DIR/opkg-on"
mkdir -p "$root/etc/opkg"
cat > "$root/etc/openwrt_release" <<'EOF'
DISTRIB_RELEASE='24.10.5'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
EOF
cat > "$root/etc/opkg/distfeeds.conf" <<'EOF'
src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/packages
src/gz openwrt_base https://mirror.51343.ru/openwrt/releases/v24.x/v24.10.5/mediatek/filogic
src/gz vendor_custom https://packages.vendor.example/24.10/mediatek/filogic/base
EOF
run_migration "$root" "$WORK_DIR/opkg-on.log" FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/missing-apk" \
  MIGRATION_CONFIGURED_MIRROR=https://own-mirror.example >/dev/null 2>&1 ||
  fail "opted-in OPKG reconciliation failed"
cat > "$WORK_DIR/opkg-on-expected" <<'EOF'
src/gz openwrt_core https://own-mirror.example/openwrt/releases/24.10.5/targets/mediatek/filogic/packages
src/gz openwrt_base https://own-mirror.example/openwrt/releases/24.10.5/targets/mediatek/filogic/packages
src/gz vendor_custom https://packages.vendor.example/24.10/mediatek/filogic/base
EOF
cmp -s "$WORK_DIR/opkg-on-expected" "$root/etc/opkg/distfeeds.conf" ||
  fail "OPKG feeds were not moved to the opted-in mirror: $(cat "$root/etc/opkg/distfeeds.conf")"
grep -Fxq 'opkg update' "$WORK_DIR/opkg-on.log" || fail "the opted-in OPKG index was not checked"
printf 'PASS: opted-in mirror moves OPKG feeds\n'

# 11. The upstream key and feed are removed even when no package manager is
# found and when the mirror is enabled.
root="$WORK_DIR/no-manager"
apk_root "$root"
run_migration "$root" "$WORK_DIR/no-manager.log" FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/missing-apk" \
  FORKOP_MIGRATION_OPKG_BIN="$WORK_DIR/bin/missing-opkg" MIGRATION_CONFIGURED_MIRROR=https://own-mirror.example \
  >/dev/null 2>&1 || fail "reconciliation without a package manager failed"
assert_no_upstream_feed "$root" "no package manager"
printf 'PASS: upstream key and Forkop feed are always removed\n'

if grep -Eq 'forkop-apk\.pem|forkop/mirror/current|"\$UCI_BIN" -q (set|add_list|delete|commit)' "$MIGRATION"; then
  fail "mirror-migration.sh must never install the upstream key or Forkop feed, or write UCI"
fi
printf 'PASS: mirror reconciliation contract\n'
