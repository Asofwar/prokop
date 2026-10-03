#!/usr/bin/env bash
# The package postinst chain of every recipe (build.sh IPK postinst, APK
# post-install and post-upgrade, OpenWrt Makefile postinst): a failed config
# migration stays fatal, the mirror reconciliation is best effort, and
# package_postinst always runs after it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
PROKOP_MAKEFILE="$ROOT_DIR/prokop/Makefile"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

UCODE_BIN="$(command -v ucode)" || fail "ucode is required"
STUB="$WORK_DIR/stub"
mkdir -p "$STUB" "$WORK_DIR/scripts"

cat > "$STUB/ucode" <<'EOF'
#!/bin/sh
printf 'migrate %s\n' "$*" >> "$POSTINST_EVENTS"
exit "${MIGRATE_STATUS:-0}"
EOF
cat > "$STUB/mirror-migration.sh" <<'EOF'
#!/bin/sh
printf 'mirror PROKOP_PACKAGE_POSTINST=%s\n' "${PROKOP_PACKAGE_POSTINST:-}" >> "$POSTINST_EVENTS"
exit "${MIRROR_STATUS:-0}"
EOF
cat > "$STUB/prokop" <<'EOF'
#!/bin/sh
printf 'prokop %s\n' "$*" >> "$POSTINST_EVENTS"
exit "${PACKAGE_POSTINST_STATUS:-0}"
EOF
chmod 0755 "$STUB"/*

# heredoc_body FILE START_LINE: the body of the heredoc that START_LINE opens.
heredoc_body() {
  awk -v start="$2" '
    found && $0 == "EOF" { exit }
    found { print }
    index($0, start) { found = 1 }
  ' "$1"
}

stub_paths() {
  sed -e "s#/usr/share/prokop/mirror-migration.sh#$STUB/mirror-migration.sh#g" \
    -e "s#/usr/bin/prokop#$STUB/prokop#g"
}

heredoc_body "$BUILD_SCRIPT" 'cat > "$control_dir/postinst" <<'"'"'EOF'"'" | stub_paths \
  > "$WORK_DIR/scripts/ipk-postinst"
heredoc_body "$BUILD_SCRIPT" 'cat > "$scripts_dir/backend-post-install.sh" <<'"'"'EOF'"'" | stub_paths \
  > "$WORK_DIR/scripts/apk-post-install"
heredoc_body "$BUILD_SCRIPT" 'cat > "$scripts_dir/backend-post-upgrade.sh" <<'"'"'EOF'"'" | stub_paths \
  > "$WORK_DIR/scripts/apk-post-upgrade"
awk '
  $0 == "define Package/prokop/postinst" { found = 1; next }
  found && $0 == "endef" { exit }
  found { gsub(/\$\$/, "$"); print }
' "$PROKOP_MAKEFILE" | stub_paths > "$WORK_DIR/scripts/makefile-postinst"

for script in ipk-postinst apk-post-install apk-post-upgrade makefile-postinst; do
  [ -s "$WORK_DIR/scripts/$script" ] || fail "$script body was not found"
  grep -Fq "$STUB/mirror-migration.sh" "$WORK_DIR/scripts/$script" ||
    fail "$script does not run mirror-migration.sh"
  grep -Fq "$STUB/prokop package_postinst" "$WORK_DIR/scripts/$script" ||
    fail "$script does not run package_postinst"
done

# run_postinst SCRIPT MIGRATE MIRROR PACKAGE_POSTINST: prints the exit status.
run_postinst() {
  local script="$1"
  local status=0
  : > "$WORK_DIR/events"
  case "$script" in
    apk-*) runner=("$UCODE_BIN") ;;
    *) runner=(sh) ;;
  esac
  env -u IPKG_INSTROOT PATH="$STUB:$PATH" POSTINST_EVENTS="$WORK_DIR/events" \
    MIGRATE_STATUS="$2" MIRROR_STATUS="$3" PACKAGE_POSTINST_STATUS="$4" \
    "${runner[@]}" "$WORK_DIR/scripts/$script" > "$WORK_DIR/out" 2>&1 || status=$?
  printf '%s\n' "$status"
}

for script in ipk-postinst apk-post-install apk-post-upgrade makefile-postinst; do
  status="$(run_postinst "$script" 0 0 0)"
  [ "$status" -eq 0 ] || fail "$script failed on a clean upgrade (status $status)"
  printf '%s\n' 'migrate -L /usr/lib/prokop /usr/lib/prokop/config/migration.uc migrate' \
    'mirror PROKOP_PACKAGE_POSTINST=1' 'prokop package_postinst' > "$WORK_DIR/expected"
  cmp -s "$WORK_DIR/expected" "$WORK_DIR/events" ||
    fail "$script ran an unexpected chain: $(cat "$WORK_DIR/events")"

  status="$(run_postinst "$script" 0 1 0)"
  [ "$status" -eq 0 ] || fail "$script failed because the mirror reconciliation failed (status $status)"
  grep -Fxq 'prokop package_postinst' "$WORK_DIR/events" ||
    fail "$script skipped package_postinst after a mirror failure"
  grep -Fq 'Warning:' "$WORK_DIR/out" || fail "$script hid the mirror failure"

  status="$(run_postinst "$script" 3 0 0)"
  [ "$status" -eq 3 ] || fail "$script did not stop on a failed config migration (status $status)"
  if grep -Eq '^(mirror|prokop) ' "$WORK_DIR/events"; then
    fail "$script continued after a failed config migration"
  fi

  status="$(run_postinst "$script" 0 1 4)"
  [ "$status" -eq 4 ] || fail "$script lost the package_postinst status (status $status)"
done

printf 'fork mirror postinst checks passed\n'
