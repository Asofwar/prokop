#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
UPDATES_UC="$PROKOP_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Prokop rewrites the whole crontab to drop its own markers. Reading it through
# `crontab -l` made that destructive: command_output() returns an empty string
# on any non-zero exit, and writing the filtered empty result back erases every
# unrelated job on the router. Read the backing file instead.

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/crontab" <<'SH'
#!/usr/bin/env bash
# A listing that fails exactly like a broken BusyBox crontab would.
printf 'crontab: unable to read\n' >&2
exit 1
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 0755 "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"

cat >"$WORK_DIR/crontab.root" <<'CRON'
0 4 * * * /usr/local/bin/backup.sh
*/10 * * * * /root/watchdog.sh # keep me
0 0 * * * /usr/bin/prokop list_update_if_due # prokop-list-update
CRON

# The source contract matters more than the helper: the crontab must be read
# from the file, never from a command whose failure is indistinguishable from
# an empty crontab.
# Both the removal and the refresh read it through read_crontab(), which
# refuses a crontab that exists but cannot be read (UC-159,
# tests/flash_write_hygiene.sh runs both).
grep -Fq 'let data = fs.readfile(CRONTAB_FILE);' "$UPDATES_UC" ||
  fail "read_crontab must read the crontab file, not 'crontab -l'"
[ "$(grep -Fc 'let crontab = read_crontab();' "$UPDATES_UC")" = 2 ] ||
  fail "the cron removal and the cron refresh must read the crontab through read_crontab()"
if grep -Fq 'command_output_from_args([ "crontab", "-l" ])' "$UPDATES_UC"; then
  fail "no cron path may still rewrite the crontab from 'crontab -l' output"
fi
grep -Fq 'const CRONTAB_FILE' "$UPDATES_UC" ||
  fail "the crontab path must be overridable for tests"

# Filtering itself must keep foreign jobs and drop only Prokop's own marker.
# filter-cron-markers reads the crontab from stdin; the arguments are markers.
filtered=$(ucode -L "$PROKOP_LIB" "$UPDATES_UC" filter-cron-markers \
  '# prokop-list-update' <"$WORK_DIR/crontab.root")
printf '%s' "$filtered" | grep -Fq '/usr/local/bin/backup.sh' ||
  fail "an unrelated backup job must survive the rewrite"
printf '%s' "$filtered" | grep -Fq '/root/watchdog.sh' ||
  fail "an unrelated watchdog job must survive the rewrite"
if printf '%s' "$filtered" | grep -Fq 'prokop-list-update'; then
  fail "the Prokop marker must be removed"
fi

# The nested reload is captured through a pipe, so it must not inherit stdin.
grep -Fq '"reload", "list-content" ]) + " </dev/null 2>/dev/null" + close_procd_lock' "$UPDATES_UC" ||
  fail "the list-content reload must detach stdin and keep the procd lock handling"

printf 'cron preservation checks passed\n'
