#!/usr/bin/env bash
set -euo pipefail

# UC-159, the crontab erase path on a nearly full overlay. BusyBox crontab
# copies the new crontab into <user>.new, ignores a failed copy, renames what
# it got over the crontab anyway and exits 0 (miscutils/crontab.c, Replace).
# With room for the new file's inode but not for its data, every rewrite left
# the router's crontab cut short or empty while Prokop reported success.
# Prokop reads the crontab back after crontab: a crontab that does not hold
# the new text fails the rewrite, with an error naming the file, and the
# previous crontab is put back (the space of the old one is free again once
# crontab renamed over it). The autotune cron line is written the same way.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
UPDATES_UC="$PROKOP_LIB/components/updates.uc"
MANAGER_UC="$PROKOP_LIB/autotune/manager.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/tmp"
# BusyBox crontab on an overlay with $WORK/free bytes left: the copy keeps
# what fits, the rename happens anyway, the space of the replaced crontab is
# free again afterwards, and the exit status is 0. $WORK/refund 0: another
# writer takes that space at once.
cat >"$WORK/bin/crontab" <<SH
#!/bin/sh
printf '%s\n' "\$1" >>"$WORK/crontab.calls"
free=\$(cat "$WORK/free")
old=0
[ ! -e "$WORK/crontab" ] || old=\$(wc -c <"$WORK/crontab")
head -c "\$free" "\$1" >"$WORK/crontab.new"
written=\$(wc -c <"$WORK/crontab.new")
mv "$WORK/crontab.new" "$WORK/crontab"
[ "\$(cat "$WORK/refund")" = 0 ] || free=\$((free + old))
echo \$((free - written)) >"$WORK/free"
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
*/10 * * * * /root/watchdog.sh # keep me
0 0 * * * /usr/bin/prokop list_update_if_due # prokop-list-update
*/15 * * * * /usr/bin/prokop autotune_if_due >/dev/null 2>&1 # prokop-autotune
CRON

# setup <free bytes> <refund 0|1>
setup() {
  cp "$WORK/crontab.orig" "$WORK/crontab"
  echo "$1" >"$WORK/free"
  echo "$2" >"$WORK/refund"
  : >"$WORK/syslog"
  : >"$WORK/crontab.calls"
}
remove_jobs() {
  ucode -L "$PROKOP_LIB" "$UPDATES_UC" remove-cron-jobs '# prokop-list-update' '# prokop-subscription-update' \
    '# prokop-component-update' >"$WORK/remove.out" 2>&1 && STATUS=0 || STATUS=$?
}
autotune_remove() {
  ucode -L "$PROKOP_LIB" "$MANAGER_UC" cron-remove >"$WORK/autotune.json" 2>&1 && STATUS=0 || STATUS=$?
}
json_get() {
  node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(v[process.argv[2]]))' "$1" "$2"
}
no_leftovers() {
  [ -z "$(ls -A "$WORK/tmp")" ] || fail "$1 left a staged crontab behind: $(ls -A "$WORK/tmp")"
}

# Room to spare: only Prokop's line goes, every other job stays.
setup 100000 1
remove_jobs
[ "$STATUS" = 0 ] || fail "the cron removal failed with room to spare: $(cat "$WORK/remove.out")"
grep -vF '# prokop-list-update' "$WORK/crontab.orig" | cmp -s - "$WORK/crontab" ||
  fail "the cron removal did not remove exactly Prokop's line: $(cat "$WORK/crontab")"
no_leftovers "the cron removal"
printf 'ok - with room to spare the cron removal removes only its own line\n'

# No room for the data: crontab empties the crontab and exits 0. The removal
# fails, says so, and the previous crontab is back.
setup 0 1
remove_jobs
[ "$STATUS" != 0 ] || fail "the cron removal reported success although crontab kept none of the new crontab"
cmp -s "$WORK/crontab.orig" "$WORK/crontab" ||
  fail "the previous crontab was not put back ($(wc -c <"$WORK/crontab") bytes): $(cat "$WORK/crontab")"
grep -F "$WORK/crontab" "$WORK/syslog" | grep -Fq '[error]' ||
  fail "the failed crontab rewrite logged no error naming the crontab: $(cat "$WORK/syslog")"
grep -Fq 'The cron job removed' "$WORK/syslog" && fail "a failed cron removal must not be logged as done"
no_leftovers "the failed cron removal"
printf 'ok - a crontab that kept none of the rewrite fails the cron removal and is put back\n'

# Cut short: part of the new crontab fits.
setup 40 1
remove_jobs
[ "$STATUS" != 0 ] || fail "the cron removal reported success although the crontab was cut short"
cmp -s "$WORK/crontab.orig" "$WORK/crontab" || fail "the cut short crontab was not put back: $(cat "$WORK/crontab")"
printf 'ok - a crontab cut short fails the cron removal and is put back\n'

# The space is gone for good: the crontab cannot be put back either. The
# removal still fails and says the jobs may be incomplete.
setup 0 0
remove_jobs
[ "$STATUS" != 0 ] || fail "the cron removal reported success although the crontab could not be written"
grep -F "$WORK/crontab" "$WORK/syslog" | grep -Fq '[error]' ||
  fail "a crontab that could not be put back logged no error: $(cat "$WORK/syslog")"
no_leftovers "the failed cron removal"
printf 'ok - a crontab that cannot be put back fails the cron removal with an error\n'

# The autotune cron line.
setup 100000 1
autotune_remove
[ "$(json_get "$WORK/autotune.json" status)" = '"ok"' ] || fail "the autotune cron removal failed: $(cat "$WORK/autotune.json")"
grep -vF '# prokop-autotune' "$WORK/crontab.orig" | cmp -s - "$WORK/crontab" ||
  fail "the autotune cron removal did not remove exactly its line: $(cat "$WORK/crontab")"
for room in 0 40; do
  setup "$room" 1
  autotune_remove
  [ "$(json_get "$WORK/autotune.json" status)" = '"failed"' ] ||
    fail "the autotune cron removal reported success with $room bytes left: $(cat "$WORK/autotune.json")"
  cmp -s "$WORK/crontab.orig" "$WORK/crontab" ||
    fail "the autotune cron removal did not put the crontab back with $room bytes left: $(cat "$WORK/crontab")"
  no_leftovers "the failed autotune cron removal"
  # The lifecycle discards the manager's output: only the system log tells.
  grep -F '[error]' "$WORK/syslog" | grep -Fi autotune | grep -Fq "$WORK/crontab" ||
    fail "the failed autotune cron removal was not logged as an error naming the crontab: $(cat "$WORK/syslog")"
done
setup 0 0
autotune_remove
[ "$(json_get "$WORK/autotune.json" status)" = '"failed"' ] ||
  fail "the autotune cron removal reported success although the crontab could not be put back: $(cat "$WORK/autotune.json")"
[ "$(json_get "$WORK/autotune.json" restored)" = false ] ||
  fail "the autotune cron removal must say the crontab was not put back: $(cat "$WORK/autotune.json")"
printf 'ok - the autotune cron line fails the same way and puts the crontab back\n'

printf 'crontab partial write checks passed\n'
