#!/usr/bin/env bash
set -euo pipefail

# The status of a full removal does not outlive it, a restart of the router
# included (S0/S6 remainder).
#
# The removal writes its status to /www/prokop-uninstall.XXXXXX.json, which
# the browser reads while LuCI is being removed, and a background job
# removes it 300 seconds after the end. /www is on flash: a router that
# restarted within those 300 seconds (the job dies with it) kept the status
# file in /www for good.
#
# Now the removal also leaves a one-shot script in /etc/uci-defaults that
# removes the status at the next boot (OpenWrt runs each such script once
# and deletes it when it succeeds); the background job removes the script
# together with the status.
#
# full-uninstall.sh runs against a fixture root; the package manager, nft, ip
# and Prokop's CLI are stubs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/prokop/files/usr/lib/full-uninstall.sh"
REAL_SLEEP="$(command -v sleep)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
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

# sleep 300 lasts until $WORK/expire exists: the test decides whether the
# status job gets to the end of its wait or the router "restarts" before.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/sleep" <<SH
#!/bin/sh
case "\$1" in
  300) while [ -d "$WORK" ] && [ ! -e "$WORK/expire" ]; do "$REAL_SLEEP" 0.05; done; exit 0 ;;
esac
exec "$REAL_SLEEP" "\$@"
SH
chmod +x "$WORK/bin/sleep"

fixture() {
  CASE="$1"
  ROOT="$WORK/$1"
  rm -f "$WORK/expire"
  mkdir -p "$ROOT/etc/opkg" "$ROOT/usr/bin" "$ROOT/bin" "$ROOT/packages" "$ROOT/etc/prokop" \
    "$ROOT/etc/config" "$ROOT/usr/lib/prokop" "$ROOT/etc/uci-defaults"
  printf 'original vendor repositories\n' >"$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
  printf 'https://mirror.51343.ru/openwrt/releases/test\n' >"$ROOT/etc/opkg/distfeeds.conf"
  # A first-boot script of someone else that has not succeeded yet.
  printf '# not done yet\nexit 1\n' >"$ROOT/etc/uci-defaults/90_someone_elses"
  touch "$ROOT/packages/prokop"
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

settled() {
  status="$(cat "$ROOT"/www/prokop-uninstall.*.json 2>/dev/null)"
  case "$status" in *'"state":"complete"'* | *'"state":"failed"'*) return 0 ;; esac
  return 1
}

run_removal() {
  PROKOP_UNINSTALL_ROOT="$ROOT" PROKOP_MIRROR_BASE_URL=https://mirror.51343.ru PATH="$WORK/bin:$ROOT/bin:$PATH" \
    sh "$SCRIPT" start >"$ROOT/response"
  wait_until 60 settled || fail "the removal did not finish"
  printf '%s\n' "$status" | grep -q "\"state\":\"$1\"" || fail "the removal did not end $1: $status"
  STATUS_FILE="$(ls "$ROOT"/www/prokop-uninstall.*.json)"
}

# The one-shot scripts of the removal in /etc/uci-defaults.
boot_scripts() { find "$ROOT/etc/uci-defaults" -type f ! -name 90_someone_elses; }
# A command for wait_until, which then looks again on every try: a
# $(boot_scripts) in its arguments is expanded once, before the wait.
no_boot_scripts() { [ -z "$(boot_scripts)" ]; }

# boot: what OpenWrt's boot does with /etc/uci-defaults (uci_apply_defaults
# in /lib/functions/system.sh): each script is sourced in a subshell from
# that directory and deleted once it succeeds.
boot() {
  local file
  for file in $(cd "$ROOT/etc/uci-defaults" && find . -type f | sort); do
    # shellcheck disable=SC1090 # the scripts the removal writes
    if (cd "$ROOT/etc/uci-defaults" && . "./${file#./}") >/dev/null 2>&1; then
      rm -f "$ROOT/etc/uci-defaults/${file#./}"
    fi
  done
}

# 1. The router restarts before the status job's wait ends: the next boot
#    removes the status and the script that did it, nothing else.
for end in complete failed; do
  fixture "restart-$end"
  [ "$end" = complete ] || rm "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
  run_removal "$end"
  [ -n "$(boot_scripts)" ] || fail "the removal left nothing that removes its status at the next boot"
  boot
  [ ! -e "$STATUS_FILE" ] || fail "the status outlived a restart of the router"
  [ -z "$(boot_scripts)" ] || fail "the boot script stayed after it ran: $(boot_scripts)"
  [ ! -e "$STATUS_FILE.new" ] || fail "a status being written outlived the restart"
  [ -e "$ROOT/etc/uci-defaults/90_someone_elses" ] || fail "a script of someone else was removed"
done

# 2. The status job gets to the end of its wait: it removes the status and
#    the boot script with it.
fixture expired
run_removal complete
[ -n "$(boot_scripts)" ] || fail "the removal left nothing that removes its status at the next boot"
: >"$WORK/expire"
wait_until 20 test ! -e "$STATUS_FILE" || fail "the status job did not remove the status"
wait_until 20 no_boot_scripts || fail "the status job left the boot script: $(boot_scripts)"
[ -e "$ROOT/etc/uci-defaults/90_someone_elses" ] || fail "a script of someone else was removed"

printf 'full_uninstall_status_cleanup: ok\n'
