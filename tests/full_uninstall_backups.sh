#!/usr/bin/env bash
set -euo pipefail

# Full uninstall removes Prokop's configuration backups (D-10(a), UC-079).
#
# Before: installing another release from the version picker saves the whole
# configuration (subscription URLs, proxy credentials) as
# /etc/prokop-backups/configuration.tar.gz, and the removal, whose
# confirmation promises to delete the settings, left it behind.
#
# Now the removal deletes what Prokop writes there: configuration.tar.gz and
# the temporary .configuration.XXXXXX of a save that did not finish, as
# regular files, and the directory once it is empty. Nothing else in it is
# touched, and nothing behind a symbolic link: a directory that is a link is
# never followed, and its archive is named as left in place instead.
#
# full-uninstall.sh runs against a fixture root; the package manager, nft, ip
# and Prokop's CLI are stubs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/prokop/files/usr/lib/full-uninstall.sh"
REAL_SLEEP="$(command -v sleep)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

ROOT=""
fail() {
  printf 'FAIL: %s: %s\n' "$CASE" "$1" >&2
  [ -z "$ROOT" ] || cat "$ROOT"/tmp/prokop-uninstall.*/output.log 2>/dev/null | sed 's/^/  log: /' >&2 || true
  exit 1
}

# The status stays readable until the test is over: the timed cleanup of the
# status waits for the work directory to go.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/sleep" <<SH
#!/bin/sh
case "\$1" in
  300) while [ -d "$WORK" ]; do "$REAL_SLEEP" 0.1; done; exit 0 ;;
esac
exec "$REAL_SLEEP" "\$@"
SH
chmod +x "$WORK/bin/sleep"

fixture() {
  CASE="$1"
  ROOT="$WORK/$1"
  BACKUPS="$ROOT/etc/prokop-backups"
  mkdir -p "$ROOT/etc/opkg" "$ROOT/usr/bin" "$ROOT/bin" "$ROOT/packages" "$ROOT/etc/prokop" \
    "$ROOT/etc/config" "$ROOT/usr/lib/prokop"
  printf 'original vendor repositories\n' >"$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
  printf 'https://mirror.51343.ru/openwrt/releases/test\n' >"$ROOT/etc/opkg/distfeeds.conf"
  printf 'subscription secret\n' >"$ROOT/etc/config/prokop"
  touch "$ROOT/usr/lib/prokop/test" "$ROOT/packages/prokop" "$ROOT/packages/luci-app-prokop"
  printf '#!/bin/sh\nexit 0\n' >"$ROOT/usr/bin/prokop"
  cat >"$ROOT/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
  status) [ -e "$PROKOP_UNINSTALL_ROOT/packages/$2" ] && echo 'Status: install ok installed' ;;
  remove) shift; for p in "$@"; do rm -f "$PROKOP_UNINSTALL_ROOT/packages/$p"; done ;;
  *) exit 1 ;;
esac
SH
  # Nothing of Prokop's runtime is in place: never the host's nft and ip.
  printf '#!/bin/sh\nexit 1\n' >"$ROOT/bin/nft"
  printf '#!/bin/sh\nexit 0\n' >"$ROOT/bin/ip"
  chmod +x "$ROOT/usr/bin/prokop" "$ROOT/bin/opkg" "$ROOT/bin/nft" "$ROOT/bin/ip"
}

# backup DIR: what the version picker leaves in DIR, a save that finished and
# one that did not.
backup() {
  mkdir -p "$1"
  printf 'prokop configuration with secrets\n' >"$1/configuration.tar.gz"
  printf 'unfinished save\n' >"$1/.configuration.Ab12Cd"
  chmod 600 "$1/configuration.tar.gz" "$1/.configuration.Ab12Cd"
}

settled() {
  status="$(cat "$ROOT"/www/prokop-uninstall.*.json 2>/dev/null)"
  case "$status" in *'"state":"complete"'* | *'"state":"failed"'*) return 0 ;; esac
  return 1
}

run_removal() {
  PROKOP_UNINSTALL_ROOT="$ROOT" PROKOP_MIRROR_BASE_URL=https://mirror.51343.ru PATH="$WORK/bin:$ROOT/bin:$PATH" \
    sh "$SCRIPT" start >"$ROOT/response"
  wait_until 60 settled || fail "the removal did not finish"
}

completed() {
  printf '%s\n' "$status" | grep -q '"state":"complete"' || fail "the removal did not complete: $status"
  [ ! -e "$ROOT/etc/config/prokop" ] || fail "the configuration was kept"
}

# 1. Only Prokop's files: the archive, the unfinished save and the directory
#    go.
fixture owned
backup "$BACKUPS"
run_removal
completed
[ ! -e "$BACKUPS/configuration.tar.gz" ] || fail "the configuration backup with its secrets was kept"
[ ! -e "$BACKUPS/.configuration.Ab12Cd" ] || fail "the unfinished save was kept"
[ ! -e "$BACKUPS" ] || fail "the empty backup directory was kept: $(ls -A "$BACKUPS")"

# 2. What the user put there stays, and so does the directory that holds it.
fixture foreign
backup "$BACKUPS"
printf 'my notes\n' >"$BACKUPS/notes.txt"
mkdir "$BACKUPS/older"
printf 'my copy\n' >"$BACKUPS/older/configuration.tar.gz"
run_removal
completed
[ ! -e "$BACKUPS/configuration.tar.gz" ] || fail "the configuration backup was kept"
[ ! -e "$BACKUPS/.configuration.Ab12Cd" ] || fail "the unfinished save was kept"
grep -qx 'my notes' "$BACKUPS/notes.txt" || fail "a file of the user was removed"
grep -qx 'my copy' "$BACKUPS/older/configuration.tar.gz" || fail "a directory of the user was removed"

# 3. The directory is a symbolic link out of /etc: nothing behind it is
#    removed, the link stays, and the removal names the archive as left.
fixture linked_directory
backup "$WORK/elsewhere"
ln -s "$WORK/elsewhere" "$BACKUPS"
run_removal
printf '%s\n' "$status" | grep -q '"state":"failed","phase":"files"' ||
  fail "the removal did not report the archive it kept: $status"
case "$(printf '%s\n' "$status" | sed -n 's/.*"left":"\([^"]*\)".*/\1/p')" in
  *backup*) ;;
  *) fail "the status does not name the configuration backup: $status" ;;
esac
grep -Fq "/etc/prokop-backups/configuration.tar.gz" "$ROOT"/tmp/prokop-uninstall.*/output.log ||
  fail "the log does not name the configuration backup"
[ -L "$BACKUPS" ] || fail "the link was removed"
grep -qx 'prokop configuration with secrets' "$WORK/elsewhere/configuration.tar.gz" ||
  fail "a file behind the link was removed"
grep -qx 'unfinished save' "$WORK/elsewhere/.configuration.Ab12Cd" || fail "a file behind the link was removed"
[ ! -e "$ROOT/packages/prokop" ] || fail "the packages were not removed"

# 4. Links in the directory are not Prokop's (a save replaces the link with
#    its archive): neither they nor what they point at are touched.
fixture linked_files
mkdir -p "$BACKUPS"
printf 'outside\n' >"$WORK/outside"
ln -s "$WORK/outside" "$BACKUPS/configuration.tar.gz"
ln -s "$WORK/outside" "$BACKUPS/.configuration.Zz99Yy"
run_removal
completed
grep -qx outside "$WORK/outside" || fail "the file a link points at was changed"
if [ ! -L "$BACKUPS/configuration.tar.gz" ] || [ ! -L "$BACKUPS/.configuration.Zz99Yy" ]; then
  fail "a link that Prokop did not create was removed"
fi

printf 'full_uninstall_backups: ok\n'
