#!/usr/bin/env bash
set -euo pipefail

# A damaged autotune state is replaced only by a complete new one (UC-074).
# The damaged file stays state.json until its replacement, which records
# recovered_at, is on flash; it is kept aside as state.json.corrupt. A failed
# write therefore never turns "recovered, wait out a cooldown" into a fresh
# state without its cooldown and apply budget. A run whose state cannot be
# written stops before it measures, and an autonomous apply is not started
# while its crash marker cannot be written: the budget and the cooldown of
# a crashed apply depend on that marker. A write fails here when its flush
# fails (sync, core/durable.uc) or when the filesystem is full.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"

# sync fails while a file of $SYNC_FAIL_GLOB exists that holds
# $SYNC_FAIL_MATCH (any such file when it is not set).
mkdir -p "$WORK/bin"
cat >"$WORK/bin/sync" <<'SH'
#!/bin/sh
for file in ${SYNC_FAIL_GLOB:-}; do
  [ -e "$file" ] || continue
  [ -z "${SYNC_FAIL_MATCH:-}" ] || grep -qF -- "$SYNC_FAIL_MATCH" "$file" || continue
  exit 1
done
exit 0
SH
chmod +x "$WORK/bin/sync"
export PATH="$WORK/bin:$PATH"
STATE_TMP="$PROKOP_AUTOTUNE_STATE_FILE.tmp.*"
CORRUPT='{"version":1,"targets":{'
state_edit() { node -e 'const f=process.argv[1],s=require(f);(new Function("s",process.argv[2]))(s);require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$PROKOP_AUTOTUNE_STATE_FILE" "$1"; }
corrupt_state() { mkdir -p "$(dirname "$PROKOP_AUTOTUNE_STATE_FILE")"; printf '%s' "$CORRUPT" >"$PROKOP_AUTOTUNE_STATE_FILE"; rm -f "$PROKOP_AUTOTUNE_STATE_FILE.corrupt"; }
applies() { if [ -e "$WORK/tune/apply.log" ]; then grep -c '^apply ' "$WORK/tune/apply.log" || true; else echo 0; fi; }

# One recovery write of the state module: what the read before it found, the
# result of the write and what the next read finds.
cat >"$WORK/recover.uc" <<'UC'
let state = require("autotune.state");
let s = state.read();
let from = s.recovered_from;
let written = state.write(s);
let again = state.read();
print(sprintf("%J\n", { from, written, again_from: again.recovered_from || null, again_at: again.recovered_at }));
UC
recover() { ucode -L "$LIB" "$WORK/recover.uc" >"$WORK/$1.json"; }

# ---- a recovery whose write fails keeps the damaged file --------------------------
corrupt_state
SYNC_FAIL_GLOB="$STATE_TMP" recover unflushed
[ "$(json_get "$WORK/unflushed.json" from)" = '"corrupt"' ] || fail "fixture: the state must read as corrupt: $(cat "$WORK/unflushed.json")"
[ "$(json_get "$WORK/unflushed.json" written)" = false ] || fail "a recovery write that was not flushed must fail: $(cat "$WORK/unflushed.json")"
[ "$(cat "$PROKOP_AUTOTUNE_STATE_FILE" 2>/dev/null)" = "$CORRUPT" ] || fail "a failed recovery write must leave the damaged state.json in place"
[ "$(json_get "$WORK/unflushed.json" again_from)" = '"corrupt"' ] ||
  fail "after a failed recovery write the state must still read as recovered: $(cat "$WORK/unflushed.json")"
manager status >"$WORK/status-unflushed.json"
[ "$(json_get "$WORK/status-unflushed.json" state_recovered)" = '"corrupt"' ] ||
  fail "the status must still report the damaged state: $(cat "$WORK/status-unflushed.json")"

# The write that succeeds records the recovery and keeps the damaged file aside.
recover recovered
[ "$(json_get "$WORK/recovered.json" written)" = true ] || fail "recovery write: $(cat "$WORK/recovered.json")"
[ "$(json_get "$WORK/recovered.json" again_from)" = null ] || fail "a recorded recovery is not read as damaged again"
[ "$(json_get "$WORK/recovered.json" again_at)" != null ] || fail "recovered_at must be recorded: $(cat "$WORK/recovered.json")"
[ "$(cat "$PROKOP_AUTOTUNE_STATE_FILE.corrupt")" = "$CORRUPT" ] || fail "the damaged state must be kept aside"

# ---- the same with a full filesystem ---------------------------------------------
cat >"$WORK/full.sh" <<'SH'
set -euo pipefail
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
CORRUPT='{"version":1,"targets":{'
FULL="$WORK/full"
mkdir -p "$FULL"
mount -t tmpfs -o size=64k tmpfs "$FULL"
trap 'umount "$FULL" 2>/dev/null || true' EXIT
export PROKOP_AUTOTUNE_STATE_FILE="$FULL/autotune/state.json"
mkdir -p "$FULL/autotune"
printf '%s' "$CORRUPT" >"$PROKOP_AUTOTUNE_STATE_FILE"
head -c 1048576 /dev/zero >"$FULL/fill" 2>/dev/null || true
ucode -L "$LIB" "$WORK/recover.uc" >"$WORK/full.json"
grep -q '"written": false' "$WORK/full.json" || fail "a recovery write on a full filesystem must fail: $(cat "$WORK/full.json")"
[ "$(cat "$PROKOP_AUTOTUNE_STATE_FILE" 2>/dev/null)" = "$CORRUPT" ] || fail "a full filesystem must leave the damaged state.json in place"
grep -q '"again_from": "corrupt"' "$WORK/full.json" || fail "after a full filesystem the state must still read as recovered: $(cat "$WORK/full.json")"
SH
export WORK LIB
if unshare --mount true 2>/dev/null; then
  unshare --mount bash "$WORK/full.sh" || fail "full filesystem"
elif unshare --user --map-root-user --mount true 2>/dev/null; then
  unshare --user --map-root-user --mount bash "$WORK/full.sh" || fail "full filesystem"
else
  printf 'autotune_state_recovery_write: no mount namespace, the full filesystem case is skipped\n'
fi

# ---- a run whose state cannot be written stops before it measures ---------------
manager policy-set mode recommend >/dev/null
corrupt_state
reset_calls
if SYNC_FAIL_GLOB="$STATE_TMP" manager run youtube >"$WORK/run-unwritable.json"; then
  fail "a run whose state cannot be written must fail: $(cat "$WORK/run-unwritable.json")"
fi
[ "$(json_get "$WORK/run-unwritable.json" reason)" = '"state_write_failed"' ] || fail "run without a written state: $(cat "$WORK/run-unwritable.json")"
[ -z "$(calls)" ] || fail "a run whose state cannot be written must not measure: $(calls)"
[ "$(cat "$PROKOP_AUTOTUNE_STATE_FILE")" = "$CORRUPT" ] || fail "a run that could not write must leave the damaged state.json in place"
manager status >"$WORK/status-run.json"
[ "$(json_get "$WORK/status-run.json" state_recovered)" = '"corrupt"' ] || fail "the damaged state must still be reported after the run"

# ---- no autonomous apply without its crash marker ---------------------------------
rm -f "$PROKOP_AUTOTUNE_STATE_FILE" "$PROKOP_AUTOTUNE_STATE_FILE.corrupt"
manager policy-set mode auto >/dev/null
manager run youtube >/dev/null
manager run youtube >/dev/null
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = true ] || fail "fixture: youtube not confirmed"
# One earlier scheduled confirmation (D-11a): the due run is the second.
state_edit 's.next_run_at=1; s.rotation=1; s.groups.youtube.pending.scheduled=1'
SYNC_FAIL_GLOB="$STATE_TMP" SYNC_FAIL_MATCH='"phase": "applying"' manager if-due >"$WORK/unmarked.json"
[ "$(json_get "$WORK/unmarked.json" applied.reason)" = '"state_write_failed"' ] ||
  fail "an apply whose crash marker cannot be written: $(cat "$WORK/unmarked.json")"
[ "$(applies)" = 0 ] || fail "an apply must not start without its crash marker on flash"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.state)" = '"finished"' ] || fail "the run must still be recorded as finished"
state_edit 's.next_run_at=1; s.rotation=1'
manager if-due >"$WORK/marked.json"
[ "$(json_get "$WORK/marked.json" applied.status)" = '"applied"' ] || fail "with its marker written the apply runs: $(cat "$WORK/marked.json")"

echo "autotune state recovery write: OK"
