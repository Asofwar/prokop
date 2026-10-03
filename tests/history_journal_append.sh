#!/usr/bin/env bash
# The persistent history (/etc/prokop/history.jsonl) loses at most the record
# that a power cut or a full flash cut short, never the next one, and
# concurrent records never lose each other around the rotation (UC-073).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
HEALTH="$LIB/diagnostics/health.uc"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT/tests/helpers/owned_processes.sh"
WORK="$(mktemp -d)"
holder=""
trap '[ -z "$holder" ] || owned_kill TERM "$holder" || true; rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/etc" "$WORK/run"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_HISTORY_FILE="$WORK/etc/history.jsonl"
record() { ucode -L "$LIB" "$HEALTH" record "$@"; }
# kinds: the kind:status:candidate of every event the history shows, in order.
kinds() {
  ucode -L "$LIB" "$HEALTH" history | node -e '
    const value = JSON.parse(require("fs").readFileSync(0, "utf8"));
    for (const e of value.events) console.log([e.kind, e.status, e.candidate || ""].join(":"));'
}

# ---- a torn last line --------------------------------------------------------
# A record cut short mid-line: the next record still starts a line of its own.
printf '{"kind":"start","status":"success","timestamp":1}\n{"kind":"reload","status":"succ' > "$PROKOP_HISTORY_FILE"
record restore success
[ "$(kinds | tr '\n' ' ')" = "start:success: restore:success: " ] ||
  fail "a torn last line swallowed the next record: $(kinds | tr '\n' ' ') / $(cat "$PROKOP_HISTORY_FILE")"

# A record complete but for its newline is kept, and so is the next one.
printf '{"kind":"start","status":"success","timestamp":1}' > "$PROKOP_HISTORY_FILE"
record reload failure
[ "$(kinds | tr '\n' ' ')" = "start:success: reload:failure: " ] ||
  fail "a record without its newline swallowed the next record: $(cat "$PROKOP_HISTORY_FILE")"
[ "$(wc -l < "$PROKOP_HISTORY_FILE")" -eq 2 ] || fail "each record must end its own line"

# A journal that ends with a newline gets no empty lines.
record snapshot_create success
[ "$(grep -c '^$' "$PROKOP_HISTORY_FILE" || true)" -eq 0 ] || fail "an intact journal got an empty line"

# ---- concurrent records around the rotation ----------------------------------
# A journal at the cap: the next record rotates it to the newest records.
# sync (core/durable.uc, before and after the rename) takes SYNC_SLEEP: the
# first rotation to read the journal is the last to replace it, as on a
# router whose flush is slow. Without serialization that rotation drops
# every record appended after its read.
cat > "$WORK/bin/sync" <<'SH'
#!/bin/sh
sleep "${SYNC_SLEEP:-0}"
SH
chmod +x "$WORK/bin/sync"
: > "$PROKOP_HISTORY_FILE"
i=0
while [ "$i" -lt 199 ]; do
  printf '{"kind":"reload","status":"success","timestamp":%d}\n' "$i" >> "$PROKOP_HISTORY_FILE"
  i=$((i + 1))
done
pids=()
for n in 1 2 3 4 5 6 7 8; do
  PATH="$WORK/bin:$PATH" SYNC_SLEEP="0.$((9 - n))" record autotune_apply success manual "c$n" &
  pids+=("$!")
  sleep 0.05
done
for pid in "${pids[@]}"; do wait "$pid" || fail "a concurrent record failed"; done
for n in 1 2 3 4 5 6 7 8; do
  [ "$(kinds | grep -c "^autotune_apply:success:c$n\$" || true)" -eq 1 ] ||
    fail "concurrent records lost c$n: $(kinds | grep autotune_apply | tr '\n' ' ')"
done
[ "$(wc -l < "$PROKOP_HISTORY_FILE")" -le 200 ] || fail "the journal outgrew its cap"
for tmp in "$WORK"/etc/*.tmp; do
  [ ! -e "$tmp" ] || fail "a rotation left its temporary file: ${tmp##*/}"
done

# ---- a lock held too long ----------------------------------------------------
# A record waits for the lock a bounded time: its holder may sit in a slow
# sync(1), and start, reload and autotune record their events synchronously.
# Then the event is recorded without the lock and without a rotation, which
# would replace the journal under the holder.
: > "$PROKOP_HISTORY_FILE"
i=0
while [ "$i" -lt 200 ]; do
  printf '{"kind":"reload","status":"success","timestamp":%d}\n' "$i" >> "$PROKOP_HISTORY_FILE"
  i=$((i + 1))
done
LOCK="$PROKOP_RUNTIME_STATE_DIR/history.lock" READY="$WORK/holder.ready" \
  ucode -e 'let fs = require("fs"); let f = fs.open(getenv("LOCK"), "a"); f.lock("x"); fs.writefile(getenv("READY"), "1"); sleep(30000);' &
holder=$!
n=0
until [ -e "$WORK/holder.ready" ]; do
  n=$((n + 1))
  [ "$n" -lt 200 ] || fail "the lock holder did not start"
  sleep 0.05
done
status=0
PROKOP_HISTORY_LOCK_WAIT_MS=300 timeout 10 ucode -L "$LIB" "$HEALTH" record restore success || status=$?
[ "$status" -eq 0 ] || fail "a record behind a held lock did not finish (status $status)"
owned_kill TERM "$holder" || true
wait "$holder" 2>/dev/null || true
holder=""
[ "$(kinds | tail -n 1)" = "restore:success:" ] || fail "a record behind a held lock was lost: $(kinds | tail -n 1)"
[ "$(wc -l < "$PROKOP_HISTORY_FILE")" -eq 201 ] || fail "a record without the lock rotated the journal: $(wc -l < "$PROKOP_HISTORY_FILE") lines"
# With the lock free again, the next record rotates.
record reload failure
[ "$(wc -l < "$PROKOP_HISTORY_FILE")" -le 150 ] || fail "the next record did not rotate the journal: $(wc -l < "$PROKOP_HISTORY_FILE") lines"
[ "$(kinds | tail -n 2 | tr '\n' ' ')" = "restore:success: reload:failure: " ] || fail "the rotation lost records: $(kinds | tail -n 2 | tr '\n' ' ')"

printf 'history_journal_append: PASS\n'
