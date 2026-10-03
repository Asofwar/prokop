#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
ACTION_UC="$PROKOP_LIB/components/action.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"
export PATH="$WORK_DIR/bin:$PATH"

# The package manager is chosen by whether apk is on PATH, so both branches can
# be exercised by providing or withholding a stub.
make_apk_stub() {
  cat >"$WORK_DIR/bin/apk" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$WORK_DIR/bin/apk"
}
drop_apk_stub() { rm -f "$WORK_DIR/bin/apk"; }

action() { ucode -L "$PROKOP_LIB" "$ACTION_UC" "$@"; }

# --- package format follows the package manager -----------------------------

make_apk_stub
[ "$(action pkg-set-extension-fixture)" = apk ] ||
  fail "an apk system must stage .apk rollback packages"
drop_apk_stub
[ "$(action pkg-set-extension-fixture)" = ipk ] ||
  fail "an opkg system must stage .ipk rollback packages"

# --- the restore command is valid for each package manager ------------------

make_apk_stub
apk_restore="$(action pkg-prokop-set-command-fixture /tmp/prokop.apk 0 1)"
case "$apk_restore" in
  *apk*add*--allow-untrusted*--force-reinstall*/tmp/prokop.apk*) ;;
  *) fail "apk restore command is missing its flags: $apk_restore" ;;
esac
apk_dry="$(action pkg-prokop-set-command-fixture /tmp/prokop.apk 1 0)"
case "$apk_dry" in
  *--simulate*) ;;
  *) fail "apk preflight must not modify the system: $apk_dry" ;;
esac

drop_apk_stub
opkg_restore="$(action pkg-prokop-set-command-fixture /tmp/prokop.ipk 0 1)"
case "$opkg_restore" in
  *opkg*install*--force-reinstall*/tmp/prokop.ipk*) ;;
  *) fail "opkg restore command is missing its flags: $opkg_restore" ;;
esac
opkg_dry="$(action pkg-prokop-set-command-fixture /tmp/prokop.ipk 1 0)"
case "$opkg_dry" in
  *--noaction*) ;;
  *) fail "opkg preflight must not modify the system: $opkg_dry" ;;
esac

# --- free space is read from the filesystem, not guessed ---------------------

kib="$(action available-kib-fixture /tmp)"
[[ "$kib" =~ ^[0-9]+$ ]] || fail "free space on /tmp was not reported as a number: $kib"
[ "$kib" -gt 0 ] || fail "free space on /tmp was reported as zero"
[ "$(action available-kib-fixture /prokop-no-such-mount)" = "-1" ] ||
  fail "an unreadable path must report unknown free space, not zero"

# --- a package set that fits is accepted ------------------------------------

printf 'x%.0s' $(seq 4096) >"$WORK_DIR/new-backend"
printf 'x%.0s' $(seq 4096) >"$WORK_DIR/staged-backend"
[ -z "$(action prokop-package-set-space-error-fixture "$WORK_DIR/new-backend" -- "$WORK_DIR/staged-backend")" ] ||
  fail "a small package set was refused on a filesystem with room for it"

# Packages that are not there yet count as zero bytes, so only the fixed
# headroom is demanded. This must not fail on a system with room to spare.
[ -z "$(action prokop-package-set-space-error-fixture "$WORK_DIR/absent-new" -- "$WORK_DIR/absent-staged")" ] ||
  fail "the headroom check refused an upgrade on a filesystem with free space"

printf 'prokop package set rollback: PASS\n'
