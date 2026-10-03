#!/bin/sh
set -eu
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$REPO/prokop/files/usr/lib/full-uninstall.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=tests/helpers/wait.sh
. "$REPO/tests/helpers/wait.sh"

fixture() {
    ROOT="$WORK/$1"
    mkdir -p "$ROOT/etc/opkg" "$ROOT/usr/bin" "$ROOT/bin" "$ROOT/packages" \
        "$ROOT/etc/prokop" "$ROOT/etc/sing-box" "$ROOT/etc/config" "$ROOT/usr/lib/prokop"
    printf 'original vendor repositories\n' > "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
    printf 'https://mirror.51343.ru/openwrt/releases/test\n' > "$ROOT/etc/opkg/distfeeds.conf"
    printf 'wifi configuration\n' > "$ROOT/etc/config/wireless"
    touch "$ROOT/etc/config/wireless.apk-new"
    touch "$ROOT/etc/config/prokop.apk-new" "$ROOT/etc/config/prokop.apk-old" \
        "$ROOT/etc/config/prokop-opkg" "$ROOT/etc/config/prokop.opkg-new" \
        "$ROOT/etc/config/prokop.opkg-old" "$ROOT/etc/config/prokop.opkg-dist"
    touch "$ROOT/etc/config/sing-box.apk-new" "$ROOT/etc/config/sing-box.apk-old" \
        "$ROOT/etc/config/sing-box-opkg" "$ROOT/etc/config/sing-box.opkg-new" \
        "$ROOT/etc/config/sing-box.opkg-old" "$ROOT/etc/config/sing-box.opkg-dist"
    touch "$ROOT/etc/prokop/secret" "$ROOT/etc/sing-box/config.json" "$ROOT/usr/lib/prokop/test"
    touch "$ROOT/packages/prokop" "$ROOT/packages/luci-app-prokop" "$ROOT/packages/sing-box"
    cat > "$ROOT/usr/bin/prokop" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PROKOP_UNINSTALL_ROOT/service-calls"
exit "${FAIL_STOP:-0}"
SH
    cat > "$ROOT/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
 status) [ -e "$PROKOP_UNINSTALL_ROOT/packages/$2" ] && echo 'Status: install ok installed';;
 remove)
  [ "${FAIL_PACKAGE:-0}" = 0 ] || exit 1
  shift
  for p in "$@"; do rm -f "$PROKOP_UNINSTALL_ROOT/packages/$p"; done;;
 *) exit 1;;
esac
SH
    # Nothing of Prokop's runtime is in place: never the host's nft and ip.
    printf '#!/bin/sh\nexit 1\n' > "$ROOT/bin/nft"
    printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/ip"
    chmod +x "$ROOT/usr/bin/prokop" "$ROOT/bin/opkg" "$ROOT/bin/nft" "$ROOT/bin/ip"
}

worker_settled() {
    status="$(cat "$ROOT"/www/prokop-uninstall.*.json)"
    case "$status" in *'"state":"complete"'*|*'"state":"failed"'*) return 0;; esac
    return 1
}

run_case() {
    PROKOP_UNINSTALL_ROOT="$ROOT" PATH="$ROOT/bin:$PATH" sh "$SCRIPT" start > "$ROOT/response"
    wait_until 60 worker_settled || { echo 'worker timed out'; exit 1; }
    printf '%s\n' "$status" | grep -q "\"state\":\"$1\""
}

fixture opkg
run_case complete
grep -qx 'original vendor repositories' "$ROOT/etc/opkg/distfeeds.conf"
[ ! -e "$ROOT/usr/lib/prokop" ] && [ ! -e "$ROOT/etc/prokop" ] && [ ! -e "$ROOT/etc/sing-box" ]
[ ! -e "$ROOT/packages/prokop" ]
grep -qx 'wifi configuration' "$ROOT/etc/config/wireless"
[ -e "$ROOT/etc/config/wireless.apk-new" ]
for file in prokop.apk-new prokop.apk-old prokop-opkg prokop.opkg-new prokop.opkg-old \
    prokop.opkg-dist sing-box.apk-new sing-box.apk-old sing-box-opkg sing-box.opkg-new \
    sing-box.opkg-old sing-box.opkg-dist; do
    [ ! -e "$ROOT/etc/config/$file" ]
done
grep -qx dnsmasq_restore "$ROOT/service-calls"

fixture missing_backup
rm "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
run_case failed
[ -e "$ROOT/packages/prokop" ] && [ -e "$ROOT/etc/prokop/secret" ]
[ ! -e "$ROOT/service-calls" ]

fixture rom_fallback
rm "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
mkdir -p "$ROOT/rom/etc/opkg"
printf 'firmware repositories\n' > "$ROOT/rom/etc/opkg/distfeeds.conf"
run_case complete
grep -qx 'firmware repositories' "$ROOT/etc/opkg/distfeeds.conf"

fixture failed_package
export FAIL_PACKAGE=1
run_case failed
unset FAIL_PACKAGE
[ -e "$ROOT/packages/prokop" ] && [ -e "$ROOT/usr/lib/prokop/test" ]

fixture apk
mkdir -p "$ROOT/etc/apk/repositories.d" "$ROOT/etc/apk/keys"
printf 'https://mirror.51343.ru/openwrt/releases/test\n' > "$ROOT/etc/apk/repositories.d/distfeeds.list"
printf 'original apk repositories\n' > "$ROOT/etc/apk/repositories.d/distfeeds.list.pre-forkop-mirror"
touch "$ROOT/etc/apk/repositories.d/forkop.list" "$ROOT/etc/apk/keys/forkop-mirror.pem"
cat > "$ROOT/bin/apk" <<'SH'
#!/bin/sh
case "$1" in
 info) test -f "$PROKOP_UNINSTALL_ROOT/packages/$3";;
 del) shift; for p in "$@"; do rm -f "$PROKOP_UNINSTALL_ROOT/packages/$p"; done;;
 *) exit 1;;
esac
SH
chmod +x "$ROOT/bin/apk"
run_case complete
grep -qx 'original apk repositories' "$ROOT/etc/apk/repositories.d/distfeeds.list"
[ ! -e "$ROOT/etc/apk/repositories.d/forkop.list" ] && [ ! -e "$ROOT/etc/apk/keys/forkop-mirror.pem" ]
printf 'Full uninstall checks passed\n'
