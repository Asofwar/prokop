#!/usr/bin/env bash
set -euo pipefail

# A state write of autotune that fails is never reported as success (UC-074,
# S5: write errors are not masked). A run whose results cannot be recorded,
# a manual apply whose record cannot be written, an operator rollback whose
# pause of the rolled back candidate cannot be written and a target change
# whose old measurements cannot be forgotten report status failed with
# reason state_write_failed (recorded: false), keeping what they did. A run
# that cannot even mark itself running leaves that failure in RAM, so the
# page shows it without a flash write. A manual apply whose mark cannot be
# written is refused before any plan. A write fails here when its flush
# fails (sync, core/durable.uc).

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

# The catalog validates manual apply candidates with the installed nfqws.
export ZAPRET_NFQWS_BIN="$WORK/nfqws"
printf '#!/bin/sh\nexit 0\n' >"$ZAPRET_NFQWS_BIN"
chmod +x "$ZAPRET_NFQWS_BIN"

state_edit() { node -e 'const f=process.argv[1],s=require(f);(new Function("s",process.argv[2]))(s);require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$PROKOP_AUTOTUNE_STATE_FILE" "$1"; }
count() { if [ -e "$WORK/tune/apply.log" ]; then grep -c "^$1" "$WORK/tune/apply.log" || true; else echo 0; fi; }
got() { json_get "$WORK/$1.json" "$2"; }
fingerprint() { stat -c '%i %Y %s' "$PROKOP_AUTOTUNE_STATE_FILE"; }
# unrecorded <name>: the output says the state does not hold what happened.
unrecorded() {
  [ "$(got "$1" status)" = '"failed"' ] || fail "$1 must not report success: $(cat "$WORK/$1.json")"
  [ "$(got "$1" reason)" = '"state_write_failed"' ] || fail "$1 reason: $(cat "$WORK/$1.json")"
  [ "$(got "$1" recorded)" = false ] || fail "$1 must say it is not recorded: $(cat "$WORK/$1.json")"
}
confirm_youtube() {
  manager run youtube >/dev/null
  manager run youtube >/dev/null
  [ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = true ] || fail "fixture: youtube not confirmed"
}

manager policy-set mode recommend >/dev/null
manager run youtube >/dev/null

# ---- a run whose results cannot be recorded fails ---------------------------------
reset_calls
if SYNC_FAIL_GLOB="$STATE_TMP" SYNC_FAIL_MATCH='"state": "finished"' manager run youtube >"$WORK/run.json"; then
  fail "a run whose results are not recorded must not exit 0: $(cat "$WORK/run.json")"
fi
unrecorded run
[ "$(got run result)" = '"completed"' ] || fail "the run still reports what it measured: $(cat "$WORK/run.json")"
[ -n "$(calls)" ] || fail "fixture: the run measured"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.state)" = '"running"' ] || fail "fixture: the final write failed"
# The state keeps the run marked running: the next run records it as crashed.
manager status >"$WORK/status-run.json"
[ "$(json_get "$WORK/status-run.json" worker.state)" = '"crashed"' ] || fail "an unrecorded run shows as interrupted"
manager run youtube >"$WORK/after-run.json"
[ "$(got after-run recovered.trigger)" = '"manual"' ] || fail "the next run records the unrecorded one: $(cat "$WORK/after-run.json")"

# ---- a scheduled run that cannot mark itself running is shown from RAM -------------
make_due
before="$(fingerprint)"
cp "$PROKOP_AUTOTUNE_STATE_FILE" "$WORK/state.before"
reset_calls
if SYNC_FAIL_GLOB="$STATE_TMP" manager if-due >"$WORK/begin.json"; then
  fail "a run that cannot mark itself running must not exit 0: $(cat "$WORK/begin.json")"
fi
[ "$(got begin status)" = '"failed"' ] || fail "run without its mark: $(cat "$WORK/begin.json")"
[ "$(got begin reason)" = '"state_write_failed"' ] || fail "run without its mark, reason: $(cat "$WORK/begin.json")"
[ -z "$(calls)" ] || fail "a run without its mark must not measure: $(calls)"
[ "$(fingerprint)" = "$before" ] || fail "a run without its mark must not replace state.json"
cmp -s "$PROKOP_AUTOTUNE_STATE_FILE" "$WORK/state.before" || fail "a run without its mark must leave state.json as it was"
manager status >"$WORK/status-begin.json"
[ "$(json_get "$WORK/status-begin.json" worker.result)" = '"failed"' ] ||
  fail "the page must show the failed run: $(json_get "$WORK/status-begin.json" worker)"
[ "$(json_get "$WORK/status-begin.json" worker.reason)" = '"state_write_failed"' ] || fail "failed run reason"
next="$(json_get "$WORK/status-begin.json" next_run_at)"
[ "$next" -gt "$(($(date +%s) + 800))" ] || fail "a failed scheduled run is retried after the retry delay: $next"
manager if-due >"$WORK/begin-again.json"
[ "$(got begin-again reason)" = '"not_due"' ] || fail "the retry time holds: $(cat "$WORK/begin-again.json")"
make_due
manager if-due >"$WORK/begin-ok.json"
[ "$(got begin-ok status)" = '"ok"' ] || fail "with the state writable again the run goes: $(cat "$WORK/begin-ok.json")"
[ ! -e "$PROKOP_AUTOTUNE_STATE_DIR/postponed.json" ] || fail "a recorded run replaces the failed one"

# ---- a manual apply whose mark cannot be written is refused ------------------------
confirm_youtube
cp "$PROKOP_AUTOTUNE_STATE_FILE" "$WORK/state.before"
if SYNC_FAIL_GLOB="$STATE_TMP" manager apply youtube >"$WORK/apply-begin.json"; then
  fail "a manual apply without its mark must not exit 0: $(cat "$WORK/apply-begin.json")"
fi
[ "$(got apply-begin status)" = '"refused"' ] || fail "manual apply without its mark: $(cat "$WORK/apply-begin.json")"
[ "$(got apply-begin reason)" = '"state_write_failed"' ] || fail "manual apply without its mark, reason: $(cat "$WORK/apply-begin.json")"
[ "$(count plan)" = 0 ] || fail "no plan without the mark: $(cat "$WORK/tune/apply.log")"
[ "$(count apply)" = 0 ] || fail "no apply without the mark: $(cat "$WORK/tune/apply.log")"
cmp -s "$PROKOP_AUTOTUNE_STATE_FILE" "$WORK/state.before" || fail "a refused manual apply leaves state.json as it was"

# ---- a manual apply whose record cannot be written ---------------------------------
if SYNC_FAIL_GLOB="$STATE_TMP" SYNC_FAIL_MATCH='"outcome"' manager apply youtube >"$WORK/apply-record.json"; then
  fail "a manual apply whose record is not written must not exit 0: $(cat "$WORK/apply-record.json")"
fi
unrecorded apply-record
[ "$(got apply-record result)" = '"applied"' ] || fail "the output keeps what the apply did: $(cat "$WORK/apply-record.json")"
[ "$(count 'apply ')" = 1 ] || fail "fixture: the apply ran"
# The mark stays: the next run counts the apply as one of unknown outcome.
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.phase)" = '"applying"' ] || fail "the apply mark must stay when its record is lost"
manager run youtube >"$WORK/after-apply.json"
[ "$(got after-apply recovered.phase)" = '"applying"' ] || fail "the next run records the unrecorded apply: $(cat "$WORK/after-apply.json")"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.cooldowns.fake)" != null ] || fail "its candidate pauses"

# ---- an operator rollback whose pause cannot be written ----------------------------
cp "$PROKOP_AUTOTUNE_STATE_FILE" "$WORK/state.before"
if SYNC_FAIL_GLOB="$STATE_TMP" manager rollback >"$WORK/rollback.json"; then
  fail "a rollback whose pause is not written must not exit 0: $(cat "$WORK/rollback.json")"
fi
unrecorded rollback
[ "$(got rollback result)" = '"rolled_back"' ] || fail "the output keeps the rollback: $(cat "$WORK/rollback.json")"
[ "$(got rollback restored)" = true ] || fail "the output keeps the restore: $(cat "$WORK/rollback.json")"
cmp -s "$PROKOP_AUTOTUNE_STATE_FILE" "$WORK/state.before" || fail "fixture: the rollback record was not written"
manager rollback >"$WORK/rollback-ok.json"
[ "$(got rollback-ok status)" = '"ok"' ] || fail "a recorded rollback: $(cat "$WORK/rollback-ok.json")"
[ "$(got rollback-ok recorded)" = null ] || fail "a recorded rollback has no recorded flag: $(cat "$WORK/rollback-ok.json")"

# ---- a target change whose old measurements cannot be forgotten --------------------
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" targets.yt.host)" = '"www.youtube.com"' ] || fail "fixture: yt measured"
if SYNC_FAIL_GLOB="$STATE_TMP" manager target-set yt m.youtube.com >"$WORK/target-set.json"; then
  fail "a target change that keeps old measurements must not exit 0: $(cat "$WORK/target-set.json")"
fi
unrecorded target-set
[ "$(got target-set target.host)" = '"m.youtube.com"' ] || fail "the output keeps the saved target: $(cat "$WORK/target-set.json")"
grep -q "option host 'm.youtube.com'" "$PROKOP_CONFIG_FILE" || fail "fixture: the target change is committed"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" targets.ytimg.host)" = '"i.ytimg.com"' ] || fail "fixture: ytimg measured"
if SYNC_FAIL_GLOB="$STATE_TMP" manager target-remove ytimg >"$WORK/target-remove.json"; then
  fail "a removal that keeps old measurements must not exit 0: $(cat "$WORK/target-remove.json")"
fi
unrecorded target-remove
[ "$(got target-remove removed)" = '"ytimg"' ] || fail "the output keeps the removal: $(cat "$WORK/target-remove.json")"

echo "autotune state write errors: OK"
