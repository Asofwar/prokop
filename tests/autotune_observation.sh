#!/usr/bin/env bash
set -euo pipefail

# The observation after an automatic apply (autotune/manager.uc
# observation_tick): once per scheduler tick the applied candidate is checked
# in production (autotune/apply.uc observe). policy.observation_checks passed
# checks end it; two failed checks in a row roll the apply back through the
# Stage 5 rollback (apply.uc rollback observation <id>) and pause the
# candidate; inconclusive checks change nothing; an apply that is no longer
# the configuration, a mode other than auto, the operator's rollback or the
# deadline end it without any change. Stand-ins: tests/helpers/autotune_scheduler.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"

state_edit() { node -e 'const f=process.argv[1],s=require(f);(new Function("s",process.argv[2]))(s);require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$PROKOP_AUTOTUNE_STATE_FILE" "$1"; }
st() { json_get "$PROKOP_AUTOTUNE_STATE_FILE" "$1"; }
log_count() { if [ -e "$WORK/tune/apply.log" ]; then grep -c "$1" "$WORK/tune/apply.log" || true; else echo 0; fi; }
observe_calls() { log_count '^observe '; }
rollback_calls() { log_count '^rollback'; }
check_is() { printf '%s\n' "$1" >"$WORK/tune/observe.json"; }
history_of() { if [ -e "$PROKOP_HISTORY_FILE" ]; then node -e 'console.log(require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(e=>e.kind==process.argv[2]).map(e=>e.status+":"+(e.trigger||"")+":"+(e.candidate||"")).join(","))' "$PROKOP_HISTORY_FILE" "$1"; fi; }
# The next tick of the observation is due; the scheduled run itself is not.
tick() { state_edit 's.observation && (s.observation.next_check_at=1); s.next_run_at=Math.floor(Date.now()/1000)+3600'; manager if-due >"$WORK/$1.json"; }
# An automatic apply of candidate fake in group youtube, just verified.
observe_new() {
  rm -f "$WORK/tune/observe.json" "$WORK/tune/rollback.json" "$WORK/tune/apply.log"
  local now; now="$(date +%s)"
  state_edit "s.groups=s.groups||{}; s.groups.youtube={cooldowns:{},pending:null,last_apply:{at:$now,group:'youtube',candidate:'fake',status:'applied',counted:true,trigger:'automatic',apply_started_at:1700000000}};
    s.applies=[{at:$now,group:'youtube',candidate:'fake',status:'applied',counted:true,trigger:'automatic'}];
    s.observation={status:'observing',group:'youtube',candidate:'fake',apply_started_at:1700000000,started_at:$now,
      checks_required:${1:-4},passed:0,failures_in_row:0,checks:[],next_check_at:$now+840,deadline:$now+86400}"
}

manager policy-set mode auto >/dev/null
# Fresh state file for state_edit.
state_edit 's.next_run_at=Math.floor(Date.now()/1000)+3600' 2>/dev/null || {
  mkdir -p "$(dirname "$PROKOP_AUTOTUNE_STATE_FILE")"; printf '{"version":1}\n' >"$PROKOP_AUTOTUNE_STATE_FILE"; }

# ---- policy: observation duration and the checks it means -------------------
manager status >"$WORK/status.json"
[ "$(json_get "$WORK/status.json" policy.observation)" = '"1h"' ] || fail "default observation 1h: $(cat "$WORK/status.json")"
[ "$(json_get "$WORK/status.json" policy.observation_checks)" = 4 ] || fail "1h = 4 checks"
manager policy-set observation 30m >/dev/null
manager status >"$WORK/status.json"; [ "$(json_get "$WORK/status.json" policy.observation_checks)" = 2 ] || fail "30m = 2 checks"
manager policy-set observation 3h >/dev/null
manager status >"$WORK/status.json"; [ "$(json_get "$WORK/status.json" policy.observation_checks)" = 12 ] || fail "3h = 12 checks"
for bad in 10m 13h 0 x; do
  if manager policy-set observation "$bad" >/dev/null; then fail "observation $bad accepted"; fi
done
manager policy-set observation 1h >/dev/null

# ---- a check is made once per tick, never earlier ----------------------------
observe_new
state_edit 's.next_run_at=Math.floor(Date.now()/1000)+3600'
manager if-due >"$WORK/early.json"
[ "$(json_get "$WORK/early.json" observation.reason)" = '"not_due"' ] || fail "early tick: $(cat "$WORK/early.json")"
[ "$(observe_calls)" = 0 ] || fail "no check before its tick"

# ---- passed: the required checks pass ---------------------------------------
for i in 1 2 3; do
  tick "ok$i"
  [ "$(json_get "$WORK/ok$i.json" observation.result)" = '"observing"' ] || fail "check $i: $(cat "$WORK/ok$i.json")"
done
grep -Fxq 'observe 1700000000' "$WORK/tune/apply.log" || fail "the check names the apply: $(cat "$WORK/tune/apply.log")"
[ "$(st observation.passed)" = 3 ] || fail "three checks passed"
[ "$(st observation.checks.2.successes)" = 3 ] || fail "check details kept"
next="$(st observation.next_check_at)"
[ "$next" -gt $(( $(date +%s) + 800 )) ] || fail "next check one tick later: $next"
tick ok4
[ "$(json_get "$WORK/ok4.json" observation.result)" = '"passed"' ] || fail "passed: $(cat "$WORK/ok4.json")"
[ "$(st observation)" = null ] || fail "a passed observation is over"
[ "$(st groups.youtube.last_apply.status)" = '"applied"' ] || fail "the apply stays"
[ "$(st groups.youtube.last_apply.observation.status)" = '"passed"' ] || fail "the apply record keeps the observation"
[ "$(st groups.youtube.last_apply.observation.passed)" = 4 ] || fail "4 of 4"
[ "$(history_of autotune_observation)" = 'success:automatic:fake' ] || fail "history: $(history_of autotune_observation)"
[ "$(rollback_calls)" = 0 ] || fail "no rollback"
tick after
[ "$(json_get "$WORK/after.json" observation)" = null ] || fail "nothing observed afterwards: $(cat "$WORK/after.json")"

# ---- two failed checks in a row roll the apply back -------------------------
observe_new
check_is '{"status":"failed","reason":"traffic_failed","successes":0,"attempted":3}'
tick fail1
[ "$(st observation.failures_in_row)" = 1 ] || fail "one failure: $(cat "$WORK/fail1.json")"
# An inconclusive check neither counts nor breaks the row.
check_is '{"status":"inconclusive","reason":"network_unavailable","successes":0,"attempted":3}'
tick wan
[ "$(st observation.failures_in_row)" = 1 ] || fail "inconclusive keeps the row"
[ "$(st observation.checks.1.reason)" = '"network_unavailable"' ] || fail "inconclusive recorded"
check_is '{"status":"failed","reason":"traffic_failed","successes":0,"attempted":3}'
tick fail2
[ "$(json_get "$WORK/fail2.json" observation.result)" = '"rolled_back"' ] || fail "rollback: $(cat "$WORK/fail2.json")"
grep -Fxq 'rollback observation 1700000000' "$WORK/tune/apply.log" || fail "the Stage 5 rollback of that apply: $(cat "$WORK/tune/apply.log")"
[ "$(st observation)" = null ] || fail "the observation is over"
[ "$(st groups.youtube.last_apply.status)" = '"rolled_back"' ] || fail "the group shows the rollback"
[ "$(st groups.youtube.last_apply.reason)" = '"observation_failed"' ] || fail "rollback reason"
[ "$(st groups.youtube.last_apply.observation.status)" = '"rolled_back"' ] || fail "observation result"
until_="$(st groups.youtube.cooldowns.fake)"
[ "$until_" -gt $(( $(date +%s) + 86000 )) ] || fail "the candidate pauses for the cooldown: $until_"
[ "$(st 'applies.length')" = 1 ] || fail "the rollback is no second apply of the budget"

# ---- a passed check breaks the row ------------------------------------------
# Rare failures (at most one conclusive check in five) neither pass nor roll
# back on their own.
observe_new 12
check_is '{"status":"ok"}'; for i in 1 2 3 4 5 6 7 8; do tick "rok$i"; done
check_is '{"status":"failed","reason":"traffic_failed"}'; tick r1
check_is '{"status":"ok"}'; tick r2
check_is '{"status":"failed","reason":"traffic_failed"}'; tick r3
[ "$(st observation.failures_in_row)" = 1 ] || fail "ok resets the row"
[ "$(st observation.failed)" = 2 ] || fail "failed checks counted: $(st observation)"
[ "$(rollback_calls)" = 0 ] || fail "no rollback without two failures in a row"

# ---- AT-12: a strategy that fails every second check --------------------------
# A failure no longer hides between passed checks: the share of failed checks
# above one in five rolls the apply back, and keeps it from passing.
observe_new
i=0
for verdict in ok failed ok failed; do
  i=$((i + 1))
  if [ "$verdict" = ok ]; then check_is '{"status":"ok","successes":3,"attempted":3}'
  else check_is '{"status":"failed","reason":"traffic_failed","successes":1,"attempted":3}'; fi
  tick "flap$i"
done
[ "$(json_get "$WORK/flap4.json" observation.result)" = '"rolled_back"' ] || fail "flapping: $(cat "$WORK/flap4.json")"
[ "$(st groups.youtube.last_apply.observation.failed)" = 2 ] || fail "flapping: failed checks kept"
[ "$(history_of autotune_observation)" = 'success:automatic:fake' ] || fail "a flapping strategy passed: $(history_of autotune_observation)"
# One failure among the required checks: passed once the share is low enough.
observe_new
for verdict in ok ok failed ok ok; do
  if [ "$verdict" = ok ]; then check_is '{"status":"ok"}'; else check_is '{"status":"failed","reason":"traffic_failed"}'; fi
  tick "rare$verdict"
done
[ "$(json_get "$WORK/rareok.json" observation.result)" = '"passed"' ] || fail "one failure in five: $(cat "$WORK/rareok.json")"
# Enough passed checks do not pass while the share of failed ones is higher.
observe_new 2
i=0
for verdict in ok failed ok ok; do
  i=$((i + 1))
  if [ "$verdict" = ok ]; then check_is '{"status":"ok"}'; else check_is '{"status":"failed","reason":"traffic_failed"}'; fi
  tick "early$i"
  [ "$(json_get "$WORK/early$i.json" observation.result)" = '"observing"' ] || fail "check $i of one failure in four or fewer: $(cat "$WORK/early$i.json")"
done
check_is '{"status":"ok"}'; tick early5
[ "$(json_get "$WORK/early5.json" observation.result)" = '"passed"' ] || fail "passed at one failure in five: $(cat "$WORK/early5.json")"
observe_new 12
check_is '{"status":"ok"}'; for i in 1 2 3 4 5 6 7 8; do tick "rok$i"; done
check_is '{"status":"failed","reason":"traffic_failed"}'; tick r1
check_is '{"status":"ok"}'; tick r2
check_is '{"status":"failed","reason":"traffic_failed"}'; tick r3

# ---- a rollback that changed nothing: the observation goes on ---------------
printf '{"status":"failed","reason":"rollback_not_started:busy"}\n' >"$WORK/tune/rollback.json"
tick r4
[ "$(json_get "$WORK/r4.json" observation.result)" = '"observing"' ] || fail "rollback not done: $(cat "$WORK/r4.json")"
[ "$(st observation.rollback_attempt.reason)" = '"rollback_not_started:busy"' ] || fail "attempt recorded"
[ "$(st groups.youtube.cooldowns.fake)" = null ] || fail "nothing paused while the apply stays"
# The next tick decides again.
rm -f "$WORK/tune/rollback.json"
tick r5
[ "$(json_get "$WORK/r5.json" observation.result)" = '"rolled_back"' ] || fail "retried rollback: $(cat "$WORK/r5.json")"

# ---- needs_attention after the rollback -------------------------------------
observe_new 2
printf '{"status":"needs_attention","reason":"observation_failed:rollback_failed"}\n' >"$WORK/tune/rollback.json"
check_is '{"status":"failed","reason":"traffic_failed"}'; tick a1; tick a2
[ "$(json_get "$WORK/a2.json" observation.result)" = '"needs_attention"' ] || fail "needs_attention: $(cat "$WORK/a2.json")"
[ "$(st groups.youtube.last_apply.status)" = '"needs_attention"' ] || fail "group shows needs_attention"
[ "$(st groups.youtube.cooldowns.fake)" != null ] || fail "needs_attention pauses the candidate"

# ---- the apply is no longer the configuration: ended, nothing changed -------
observe_new
check_is '{"status":"ended","reason":"config_changed"}'; tick edited
[ "$(json_get "$WORK/edited.json" observation.result)" = '"ended"' ] || fail "ended: $(cat "$WORK/edited.json")"
[ "$(st observation)" = null ] || fail "observation over"
[ "$(st groups.youtube.last_apply.observation.reason)" = '"config_changed"' ] || fail "reason kept"
[ "$(st groups.youtube.last_apply.status)" = '"applied"' ] || fail "the record stays the apply's"
[ "$(st groups.youtube.cooldowns.fake)" = null ] || fail "nothing paused"
[ "$(rollback_calls)" = 0 ] || fail "no rollback of an edited configuration"
# A rollback that finished in a run that died before recording it.
observe_new
check_is '{"status":"ended","reason":"apply_rolled_back","phase":"rolled_back","apply_reason":"observation_failed"}'; tick died
[ "$(json_get "$WORK/died.json" observation.result)" = '"rolled_back"' ] || fail "recorded rollback: $(cat "$WORK/died.json")"
[ "$(st groups.youtube.cooldowns.fake)" != null ] || fail "the candidate pauses"
# AT-15: a rollback by anything else (the operator through apply.uc) is no
# failed observation: it ends it, nothing is paused.
observe_new
check_is '{"status":"ended","reason":"apply_rolled_back","phase":"rolled_back","apply_reason":"operator_rollback"}'; tick foreign
[ "$(json_get "$WORK/foreign.json" observation.result)" = '"ended"' ] || fail "foreign rollback: $(cat "$WORK/foreign.json")"
[ "$(st groups.youtube.last_apply.observation.reason)" = '"apply_rolled_back"' ] || fail "foreign rollback reason"
[ "$(st groups.youtube.last_apply.reason)" != '"observation_failed"' ] || fail "a foreign rollback shown as a failed observation"
[ "$(st groups.youtube.cooldowns.fake)" = null ] || fail "a foreign rollback paused the candidate"

# ---- a blocker skips the tick without any write ------------------------------
observe_new
printf '{"state":null,"guards":[],"service_action":"service_action_in_progress"}\n' >"$STUB_APPLY_STATUS"
state_edit 's.observation.next_check_at=1; s.next_run_at=Math.floor(Date.now()/1000)+3600'
before="$(sha256sum "$PROKOP_AUTOTUNE_STATE_FILE")"
manager if-due >"$WORK/blocked.json"
[ "$(json_get "$WORK/blocked.json" observation.reason)" = '"service_action_in_progress"' ] || fail "blocked: $(cat "$WORK/blocked.json")"
[ "$(observe_calls)" = 0 ] || fail "no check while blocked"
[ "$(sha256sum "$PROKOP_AUTOTUNE_STATE_FILE")" = "$before" ] || fail "a skipped tick writes nothing to flash"
rm -f "$STUB_APPLY_STATUS"

# ---- Prokop stopped by the user: nothing is checked --------------------------
rm "$PROKOP_RUNTIME_STATE_DIR/start.explicit"
manager if-due >"$WORK/stopped.json"
[ "$(json_get "$WORK/stopped.json" reason)" = '"prokop_stopped"' ] || fail "stopped: $(cat "$WORK/stopped.json")"
[ "$(observe_calls)" = 0 ] || fail "no check while stopped"
[ "$(st observation.status)" = '"observing"' ] || fail "the observation waits"
: >"$PROKOP_RUNTIME_STATE_DIR/start.explicit"

# ---- the deadline passes without enough checks -------------------------------
state_edit 's.observation.deadline=Math.floor(Date.now()/1000)-1'
tick expired
[ "$(json_get "$WORK/expired.json" observation.result)" = '"ended"' ] || fail "expired: $(cat "$WORK/expired.json")"
[ "$(st groups.youtube.last_apply.observation.reason)" = '"observation_expired"' ] || fail "expired reason"
# AT-13: a candidate left without a verdict is in the history (and notified).
case "$(history_of autotune_observation)" in *,failure:automatic:fake) ;; *) fail "expiry not in the history: $(history_of autotune_observation)";; esac
[ "$(observe_calls)" = 0 ] || fail "no check after the deadline"

# ---- the mode switched away from auto ends it ---------------------------------
observe_new
manager policy-set mode recommend >/dev/null
[ "$(st observation)" = null ] || fail "mode recommend ends the observation"
[ "$(st groups.youtube.last_apply.observation.reason)" = '"mode_changed"' ] || fail "mode_changed"
manager policy-set mode auto >/dev/null
# Also when the mode was changed behind the manager's back.
observe_new
sed -i "s/option mode 'auto'/option mode 'recommend'/" "$PROKOP_CONFIG_FILE"
grep -q "option mode 'recommend'" "$PROKOP_CONFIG_FILE" || fail "fixture: mode recommend"
manager if-due >"$WORK/off.json"
[ "$(json_get "$WORK/off.json" observation.reason)" = '"mode_changed"' ] || fail "mode changed: $(cat "$WORK/off.json")"
[ "$(st observation)" = null ] || fail "ended"
manager policy-set mode auto >/dev/null

# ---- the operator's rollback ends it --------------------------------------------
observe_new
export PROKOP_AUTOTUNE_APPLY_STATE="$WORK/etc/autotune-apply.json"
manager rollback >"$WORK/operator.json"
[ "$(json_get "$WORK/operator.json" result)" = '"rolled_back"' ] || fail "operator rollback: $(cat "$WORK/operator.json")"
[ "$(st observation)" = null ] || fail "the operator's rollback ends the observation"
[ "$(st groups.youtube.last_apply.reason)" = '"operator_rollback"' ] || fail "the group shows the operator's rollback"

# ---- the page status carries the observation, without configuration -----------
observe_new
manager status >"$WORK/status.json"
[ "$(json_get "$WORK/status.json" observation.status)" = '"observing"' ] || fail "status: $(cat "$WORK/status.json")"
if grep -E 'dpi-desync|nfqws_opt' "$PROKOP_AUTOTUNE_STATE_FILE" >/dev/null; then fail "no raw strategies in the state"; fi

echo "autotune observation: OK"
