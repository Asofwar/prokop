#!/usr/bin/env bash
set -euo pipefail

# A run that a blocker postpones writes nothing to flash (UC-075). While an
# apply waits for the operator (needs_attention) or a guard stays, the cron
# line asks every 15 minutes; such a run used to mark itself running in
# state.json and then record its skip, two flash writes per tick for days.
# The postponed run and its retry time are kept in RAM: the status and the
# schedule show them over the stored last run, a run that starts later
# replaces them, a reboot forgets them. A run still marked running in the
# state (it crashed) is recorded once, also while blocked.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"

STATE="$PROKOP_AUTOTUNE_STATE_FILE"
POSTPONED="$PROKOP_AUTOTUNE_STATE_DIR/postponed.json"
state_edit() { node -e 'const f=process.argv[1],s=require(f);(new Function("s",process.argv[2]))(s);require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$STATE" "$1"; }
# Identity and modification time (ns) of the state file: any write changes it.
written() { stat -c '%i %y' "$STATE"; }
unresolved() { printf '{"state":{"phase":"needs_attention"},"guards":[],"resolved":false}\n' >"$STUB_APPLY_STATUS"; }
# A retry time 15 minutes after the run (which took less than 100 s).
retry_after_run() { local now; now=$(date +%s); [ "$1" -le $((now + 900)) ] && [ "$1" -gt $((now + 800)) ]; }

manager policy-set mode recommend >/dev/null
manager if-due >"$WORK/first.json"
[ "$(json_get "$WORK/first.json" result)" = '"completed"' ] || fail "fixture: first run: $(cat "$WORK/first.json")"
completed_at="$(json_get "$STATE" worker.started_at)"

# ---- a scheduled run postponed by an unresolved apply ---------------------------
unresolved
make_due
before="$(written)"
reset_calls
manager if-due >"$WORK/blocked.json"
[ "$(json_get "$WORK/blocked.json" result)" = '"skipped"' ] && [ "$(json_get "$WORK/blocked.json" reason)" = '"apply_unresolved"' ] ||
  fail "blocked run: $(cat "$WORK/blocked.json")"
[ -z "$(calls)" ] || fail "a blocked run measures nothing"
[ "$(written)" = "$before" ] || fail "a run postponed by a blocker must not write the state on flash"
retry="$(json_get "$WORK/blocked.json" next_run_at)"
retry_after_run "$retry" || fail "the postponed run is retried after 15 minutes: $retry"

# The status shows the postponed run and its retry time, not the stored run.
manager status >"$WORK/status.json"
[ "$(json_get "$WORK/status.json" worker.result)" = '"skipped"' ] && [ "$(json_get "$WORK/status.json" worker.reason)" = '"apply_unresolved"' ] ||
  fail "the status must show the postponed run: $(json_get "$WORK/status.json" worker)"
[ "$(json_get "$WORK/status.json" next_run_at)" = "$retry" ] || fail "the status must show the retry time: $(json_get "$WORK/status.json" next_run_at)"
[ "$(json_get "$STATE" worker.started_at)" = "$completed_at" ] || fail "the stored last run must stay the completed one"

# The schedule follows the retry time: not due before it, then postponed
# again (still nothing on flash).
manager if-due >"$WORK/not-due.json"
[ "$(json_get "$WORK/not-due.json" reason)" = '"not_due"' ] || fail "the retry time must hold: $(cat "$WORK/not-due.json")"
node -e 'const f=process.argv[1],p=require(f);p.next_run_at=1;require("fs").writeFileSync(f,JSON.stringify(p)+"\n")' "$POSTPONED"
manager if-due >"$WORK/blocked-again.json"
[ "$(json_get "$WORK/blocked-again.json" result)" = '"skipped"' ] || fail "second blocked tick: $(cat "$WORK/blocked-again.json")"
[ "$(written)" = "$before" ] || fail "a second postponed run must not write the state either"

# A manual run while blocked: shown as postponed, the schedule keeps its retry time.
retry="$(json_get "$WORK/blocked-again.json" next_run_at)"
manager run youtube >"$WORK/manual-blocked.json"
[ "$(json_get "$WORK/manual-blocked.json" result)" = '"skipped"' ] || fail "manual blocked run: $(cat "$WORK/manual-blocked.json")"
[ "$(written)" = "$before" ] || fail "a manual run postponed by a blocker must not write the state"
manager status >"$WORK/status-manual.json"
[ "$(json_get "$WORK/status-manual.json" worker.trigger)" = '"manual"' ] || fail "the status must show the manual postponed run"
[ "$(json_get "$WORK/status-manual.json" next_run_at)" = "$retry" ] || fail "a manual run keeps the retry time of the schedule"

# After a reboot (tmpfs is gone) the stored last run is shown again.
mv "$POSTPONED" "$WORK/postponed.saved"
manager status >"$WORK/status-reboot.json"
[ "$(json_get "$WORK/status-reboot.json" worker.result)" = '"completed"' ] || fail "without the RAM record the stored run is shown"
mv "$WORK/postponed.saved" "$POSTPONED"

# ---- a run that crashed is recorded, once, even while blocked -------------------
state_edit 's.worker={state:"running",pid:"999999",ticks:"1",trigger:"schedule",scope:"auto",started_at:1,phase:"measuring"}'
make_due
manager if-due >"$WORK/crashed.json"
[ "$(json_get "$WORK/crashed.json" recovered.started_at)" = 1 ] || fail "a crashed run must be found while blocked: $(cat "$WORK/crashed.json")"
[ "$(json_get "$STATE" worker.state)" = '"finished"' ] || fail "the crashed run must be recorded"
[ "$(json_get "$STATE" worker.recovered.started_at)" = 1 ] || fail "the crash must stay visible"
make_due
before="$(written)"
manager if-due >"$WORK/after-crash.json"
[ "$(json_get "$WORK/after-crash.json" result)" = '"skipped"' ] || fail "blocked after the crash: $(cat "$WORK/after-crash.json")"
[ "$(written)" = "$before" ] || fail "once the crash is recorded, blocked runs write nothing again"

# ---- the blocker gone: the run measures and is stored, the RAM record goes ----------
rm -f "$STUB_APPLY_STATUS"
make_due
reset_calls
manager if-due >"$WORK/resumed.json"
[ "$(json_get "$WORK/resumed.json" result)" = '"completed"' ] || fail "resumed run: $(cat "$WORK/resumed.json")"
[ -n "$(calls)" ] || fail "the resumed run must measure"
[ ! -e "$POSTPONED" ] || fail "a completed run replaces the postponed record"
manager status >"$WORK/status-resumed.json"
[ "$(json_get "$WORK/status-resumed.json" worker.result)" = '"completed"' ] || fail "the status shows the completed run"
[ "$(json_get "$WORK/status-resumed.json" next_run_at)" = "$(json_get "$STATE" next_run_at)" ] || fail "the stored schedule applies again"

echo "autotune blocked flash: OK"
