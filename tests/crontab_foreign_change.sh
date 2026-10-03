#!/usr/bin/env bash
set -euo pipefail

# A crontab that another writer changed between Prokop's `crontab` and its
# read-back is not overwritten (S5 integration, UC-159).
#
# Prokop reads the crontab back after `crontab`, because BusyBox crontab
# renames a copy cut short by a full overlay over the crontab and exits 0
# (tests/crontab_partial_write.sh). Only a crontab that holds Prokop's own
# new text cut short is Prokop's failed write: the previous crontab is put
# back then. Any other content is someone else's change made in between (a
# LuCI Scheduled Tasks save, an opkg postinst, the autotune manager or the
# list update cron refresh): putting the previous crontab back would erase
# it. The rewrite fails and says so, and the crontab keeps that change.
#
# A crontab that `crontab` never touched is neither: on a completely full
# overlay BusyBox crontab cannot even create <user>.new, says "can't create"
# and exits 0. The crontab still holds what Prokop read before; nothing is
# put back, and the rewrite fails as one that did not land (is the overlay
# full?), not as another writer's change (S5 integration review).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
UPDATES_UC="$PROKOP_LIB/components/updates.uc"
MANAGER_UC="$PROKOP_LIB/autotune/manager.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/tmp"
# BusyBox crontab <file>: installs the file. With $WORK/foreign present,
# another writer replaces the crontab right after it, once. With
# $WORK/no-room present, the overlay has no room for <user>.new.
cat >"$WORK/bin/crontab" <<SH
#!/bin/sh
printf '%s\n' "\$1" >>"$WORK/crontab.calls"
if [ -e "$WORK/no-room" ]; then
  echo "crontab: can't create $WORK/crontab.new: No space left on device" >&2
  exit 0
fi
cp "\$1" "$WORK/crontab"
if [ -e "$WORK/foreign" ]; then
  cp "$WORK/foreign" "$WORK/crontab"
  rm -f "$WORK/foreign"
fi
exit 0
SH
cat >"$WORK/bin/logger" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK/syslog"
SH
chmod +x "$WORK/bin/crontab" "$WORK/bin/logger"
export PATH="$WORK/bin:$PATH"
export PROKOP_CRONTAB_FILE="$WORK/crontab" PROKOP_AUTOTUNE_CRONTAB="$WORK/bin/crontab" PROKOP_AUTOTUNE_TMPDIR="$WORK/tmp"
export TMPDIR="$WORK/tmp"

cat >"$WORK/crontab.orig" <<'CRON'
0 4 * * * /usr/local/bin/backup.sh
0 0 * * * /usr/bin/prokop list_update_if_due # prokop-list-update
*/15 * * * * /usr/bin/prokop autotune_if_due >/dev/null 2>&1 # prokop-autotune
CRON
# What the other writer saves: the crontab as it read it, plus its own job.
{
  cat "$WORK/crontab.orig"
  printf '%s\n' '30 2 * * * /usr/local/bin/rotate-logs.sh'
} >"$WORK/crontab.foreign"

setup() {
  cp "$WORK/crontab.orig" "$WORK/crontab"
  cp "$WORK/crontab.foreign" "$WORK/foreign"
  : >"$WORK/syslog"
  : >"$WORK/crontab.calls"
}
json_get() {
  node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(v[process.argv[2]]))' "$1" "$2"
}

# The cron refresh of components/updates.uc.
setup
status=0
ucode -L "$PROKOP_LIB" "$UPDATES_UC" remove-cron-jobs '# prokop-list-update' '# prokop-subscription-update' \
  '# prokop-component-update' >"$WORK/remove.out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "a crontab another writer changed meanwhile was reported as written"
cmp -s "$WORK/crontab.foreign" "$WORK/crontab" ||
  fail "the change another writer made to the crontab was overwritten: $(cat "$WORK/crontab")"
[ "$(wc -l <"$WORK/crontab.calls")" = 1 ] || fail "crontab was called again after the read-back: $(cat "$WORK/crontab.calls")"
grep -F "$WORK/crontab" "$WORK/syslog" | grep -F '[error]' | grep -Fq 'another writer' ||
  fail "the conflict was not logged as an error naming the crontab: $(cat "$WORK/syslog")"
printf 'ok - the cron refresh keeps a change another writer made meanwhile and fails\n'

# The autotune cron line.
setup
ucode -L "$PROKOP_LIB" "$MANAGER_UC" cron-remove >"$WORK/autotune.json" 2>&1 || true
[ "$(json_get "$WORK/autotune.json" status)" = '"failed"' ] ||
  fail "an autotune cron rewrite that another writer overtook was reported as done: $(cat "$WORK/autotune.json")"
[ "$(json_get "$WORK/autotune.json" reason)" = '"crontab_changed"' ] ||
  fail "the autotune cron rewrite must report the conflict: $(cat "$WORK/autotune.json")"
cmp -s "$WORK/crontab.foreign" "$WORK/crontab" ||
  fail "the autotune cron rewrite overwrote the change of another writer: $(cat "$WORK/crontab")"
[ "$(wc -l <"$WORK/crontab.calls")" = 1 ] || fail "the autotune manager called crontab again after the read-back"
grep -F '[error]' "$WORK/syslog" | grep -Fi autotune | grep -Fq 'another writer' ||
  fail "the autotune cron conflict was not logged as an error: $(cat "$WORK/syslog")"
printf 'ok - the autotune cron rewrite keeps a change another writer made meanwhile and fails\n'

# ---- crontab could not write at all ---------------------------------------------

no_room() {
  cp "$1" "$WORK/crontab"
  cp "$1" "$WORK/crontab.before"
  : >"$WORK/no-room"
  : >"$WORK/syslog"
  : >"$WORK/crontab.calls"
}
unchanged_reported() {
  cmp -s "$WORK/crontab.before" "$WORK/crontab" || fail "$1: the crontab changed: $(cat "$WORK/crontab")"
  [ "$(wc -l <"$WORK/crontab.calls")" = 1 ] || fail "$1: crontab was called again, to put back a crontab it never changed"
  grep -F "$WORK/crontab" "$WORK/syslog" | grep -F '[error]' | grep -Fq 'overlay full' ||
    fail "$1: the write that did not land was not logged as such: $(cat "$WORK/syslog")"
  grep -Fq 'another writer' "$WORK/syslog" && fail "$1: a write that did not land was logged as another writer's change"
  return 0
}

no_room "$WORK/crontab.orig"
status=0
ucode -L "$PROKOP_LIB" "$UPDATES_UC" remove-cron-jobs '# prokop-list-update' '# prokop-subscription-update' \
  '# prokop-component-update' >"$WORK/remove.out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "a cron removal that crontab could not write was reported as written"
unchanged_reported "the cron removal"
printf "ok - a cron removal that crontab could not write is not taken for another writer's change\n"

no_room "$WORK/crontab.orig"
ucode -L "$PROKOP_LIB" "$MANAGER_UC" cron-remove >"$WORK/autotune.json" 2>&1 || true
[ "$(json_get "$WORK/autotune.json" status)" = '"failed"' ] ||
  fail "an autotune cron rewrite that crontab could not write was reported as done: $(cat "$WORK/autotune.json")"
[ "$(json_get "$WORK/autotune.json" reason)" = '"crontab_not_written"' ] ||
  fail "the autotune cron rewrite must report a write that did not land: $(cat "$WORK/autotune.json")"
unchanged_reported "the autotune cron removal"

# Prokop's line goes at the end: the crontab as it was is the start of the
# new one, and still nothing is put back.
grep -Fv 'prokop-autotune' "$WORK/crontab.orig" >"$WORK/crontab.without-autotune"
no_room "$WORK/crontab.without-autotune"
printf "config autotune 'autotune'\n\toption mode 'recommend'\n" >"$WORK/prokop.config"
PROKOP_CONFIG_FILE="$WORK/prokop.config" ucode -L "$PROKOP_LIB" "$MANAGER_UC" cron-sync >"$WORK/autotune.json" 2>&1 || true
[ "$(json_get "$WORK/autotune.json" reason)" = '"crontab_not_written"' ] ||
  fail "the autotune cron line that crontab could not add must be reported as not written: $(cat "$WORK/autotune.json")"
unchanged_reported "the autotune cron line added at the end"
printf "ok - an autotune cron rewrite that crontab could not write is not taken for another writer's change\n"

printf 'crontab foreign change checks passed\n'
