#!/usr/bin/env bash
set -euo pipefail

# Stage 6.8.6: crash recovery and history of the autotune worker. A run is
# marked running in the persistent state; a run that dies (crash, kill,
# reboot) is found by the next one and recorded; an apply of unknown outcome
# counts against the daily limit and cools its candidate down; stale
# temporary files are removed; a corrupt state is kept aside and autonomous
# applies wait out a cooldown. Stand-ins: tests/helpers/autotune_scheduler.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"

state_edit() { node -e 'const f=process.argv[1],s=require(f);(new Function("s",process.argv[2]))(s);require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$PROKOP_AUTOTUNE_STATE_FILE" "$1"; }
events() { if [ -e "$PROKOP_HISTORY_FILE" ]; then node -e 'console.log(require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(e=>e.kind.startsWith("autotune_")&&e.kind!="autotune_mode").map(e=>e.kind+":"+e.status).join(","))' "$PROKOP_HISTORY_FILE"; fi; }
# Kill a worker and whatever tool it was running, as a crash or power loss would.
crash() {
  local pid="$1"
  pkill -9 -P "$pid" 2>/dev/null || true
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pkill -9 -f "$LIB/autotune/(isolation|apply).uc" 2>/dev/null || true
  for _ in $(seq 50); do flock -n "$PROKOP_AUTOTUNE_STATE_DIR/worker.lock" true && return 0; sleep 0.1; done
  fail "the worker lock must be released after a crash"
}
wait_for() { for _ in $(seq 100); do [ -s "$1" ] && grep -q "$2" "$1" && return 0; sleep 0.1; done; fail "timeout waiting for $2 in $1"; }

manager policy-set mode recommend >/dev/null

# ---- a recommendation confirmed for the first time is recorded once ---------
manager run youtube >/dev/null
[ "$(events)" = "" ] || fail "no event before the confirmation: $(events)"
manager run youtube >/dev/null
[ "$(events)" = "autotune_recommendation:success" ] || fail "confirmation event: $(events)"
manager run youtube >/dev/null
[ "$(events)" = "autotune_recommendation:success" ] || fail "a kept confirmation is not recorded again: $(events)"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.state)" = '"finished"' ] || fail "a finished run is marked finished"

# ---- an unknown group is a finished (failed) run, not a crash ---------------
if manager run nosuch >/dev/null; then fail "unknown group must fail"; fi
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.state)" = '"finished"' ] || fail "a failed run is not left running"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.result)" = '"failed"' ] || fail "a failed run is recorded as failed"

# ---- a crash while measuring --------------------------------------------------
rm -f "$WORK/tune/calls.log"
STUB_TUNE_SLEEP=5 ucode -L "$LIB" "$LIB/autotune/manager.uc" run all >/dev/null &
run_pid=$!
wait_for "$WORK/tune/calls.log" discord.com
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.state)" = '"running"' ] || fail "a run is marked running"
manager status >"$WORK/status-running.json"
[ "$(json_get "$WORK/status-running.json" worker.state)" = '"running"' ] || fail "a live run is reported running"
crash "$run_pid"
manager status >"$WORK/status-crashed.json"
[ "$(json_get "$WORK/status-crashed.json" worker.state)" = '"crashed"' ] || fail "a dead run is reported crashed: $(cat "$WORK/status-crashed.json")"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.state)" = '"running"' ] || fail "status never writes"
manager run youtube >"$WORK/after-crash.json"
[ "$(json_get "$WORK/after-crash.json" recovered.phase)" = '"measuring"' ] || fail "the crash is found: $(cat "$WORK/after-crash.json")"
[ "$(json_get "$WORK/after-crash.json" recovered.trigger)" = '"manual"' ] || fail "the crashed run is described"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.state)" = '"finished"' ] || fail "the new run finishes"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.recovered.phase)" = '"measuring"' ] || fail "the crash stays visible"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" applies)" = '[]' ] || fail "a crash while measuring changes no budget"
[ "$(events)" = "autotune_recommendation:success,autotune_run:failure" ] || fail "crash event: $(events)"
manager run youtube >"$WORK/after-crash-2.json"
[ "$(json_get "$WORK/after-crash-2.json" recovered)" = null ] || fail "a crash is recovered once"

# ---- a reboot during a run (tmpfs gone, state on flash) ----------------------
state_edit 's.worker={state:"running",pid:"999999",ticks:"1",trigger:"schedule",scope:"auto",started_at:1,phase:"measuring"}'
rm -rf "$PROKOP_AUTOTUNE_STATE_DIR"
manager status >"$WORK/status-reboot.json"
[ "$(json_get "$WORK/status-reboot.json" worker.state)" = '"crashed"' ] || fail "a run cut by a reboot is reported crashed"
manager run youtube >"$WORK/after-reboot.json"
[ "$(json_get "$WORK/after-reboot.json" recovered.trigger)" = '"schedule"' ] || fail "the rebooted run is found: $(cat "$WORK/after-reboot.json")"

# ---- a crash while applying ---------------------------------------------------
manager policy-set mode auto >/dev/null
manager run youtube >/dev/null; manager run youtube >/dev/null
state_edit 's.next_run_at=1; s.rotation=1'
mkdir -p "$WORK/tmp/prokop-autotune-apply.leftover"
STUB_APPLY_SLEEP=5 ucode -L "$LIB" "$LIB/autotune/manager.uc" if-due >/dev/null &
run_pid=$!
wait_for "$WORK/tune/apply.log" '^apply '
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.phase)" = '"applying"' ] || fail "the apply phase is marked"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.candidate)" = '"fake"' ] || fail "the applied candidate is marked"
crash "$run_pid"
find "$WORK/tmp" -maxdepth 1 -name 'prokop-autotune-apply.*' | grep -q . || fail "fixture: a crash leaves the apply directory"
manager run youtube >"$WORK/after-apply-crash.json"
[ "$(json_get "$WORK/after-apply-crash.json" recovered.phase)" = '"applying"' ] || fail "apply crash found: $(cat "$WORK/after-apply-crash.json")"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" applies.0.status)" = '"unknown"' ] || fail "an apply of unknown outcome is recorded"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" applies.0.reason)" = '"worker_crashed_during_apply"' ] || fail "its reason"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" applies.0.counted)" = true ] || fail "it counts against the daily limit"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.cooldowns.fake)" -gt "$(date +%s)" ] || fail "its candidate cools down"
if find "$WORK/tmp" -maxdepth 1 -name 'prokop-autotune-apply.*' | grep -q .; then fail "stale apply directories are removed"; fi
manager run youtube >/dev/null
state_edit 's.next_run_at=1; s.rotation=1'
manager if-due >"$WORK/after-apply-crash-due.json"
[ "$(json_get "$WORK/after-apply-crash-due.json" groups.youtube.decision)" = '"candidate_in_cooldown"' ] ||
  fail "no apply of the crashed candidate: $(cat "$WORK/after-apply-crash-due.json")"

# ---- a corrupt state ----------------------------------------------------------
printf '{"version":1,"targets":{' >"$PROKOP_AUTOTUNE_STATE_FILE"
manager status >"$WORK/status-corrupt.json"
[ "$(json_get "$WORK/status-corrupt.json" state_recovered)" = '"corrupt"' ] || fail "a corrupt state is reported: $(cat "$WORK/status-corrupt.json")"
manager run youtube >/dev/null
[ "$(cat "$PROKOP_AUTOTUNE_STATE_FILE.corrupt")" = '{"version":1,"targets":{' ] || fail "the corrupt state is kept aside"
recovered="$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" recovered_at)"
[ "$recovered" != null ] && [ "$recovered" -le "$(date +%s)" ] || fail "recovered_at recorded: $recovered"
manager run youtube >/dev/null
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = true ] || fail "fixture: youtube confirmed again"
state_edit 's.next_run_at=1; s.rotation=1'
manager if-due >"$WORK/recovered-due.json"
[ "$(json_get "$WORK/recovered-due.json" groups.youtube.decision)" = '"state_recovered"' ] ||
  fail "no autonomous apply right after a state recovery: $(cat "$WORK/recovered-due.json")"
state_edit 's.recovered_at=1; s.next_run_at=1; s.rotation=1'
manager if-due >"$WORK/recovered-later.json"
[ "$(json_get "$WORK/recovered-later.json" applied.status)" = '"applied"' ] || fail "applies resume after the cooldown: $(cat "$WORK/recovered-later.json")"

printf '{"version":99}\n' >"$PROKOP_AUTOTUNE_STATE_FILE"
manager status >"$WORK/status-version.json"
[ "$(json_get "$WORK/status-version.json" state_recovered)" = '"unsupported_version"' ] || fail "a foreign state version is not trusted"

echo "autotune recovery: OK"
