#!/usr/bin/env bash
set -euo pipefail

# Stage 6.8.5: autonomous application of a confirmed group recommendation.
# Only scheduled runs in mode "auto" apply, only after hysteresis confirmed
# the candidate, with high confidence, outside a cooldown and within the
# daily limit, and always through the Stage 5 plan + apply transaction
# (stand-ins here: tests/helpers/autotune_scheduler). A custom strategy of
# the user is never replaced; "direct" is never applied.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"

state_edit() { node -e 'const f=process.argv[1],s=require(f);(new Function("s",process.argv[2]))(s);require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$PROKOP_AUTOTUNE_STATE_FILE" "$1"; }
# The next scheduled run is due and its turn is the youtube group.
scheduled_youtube() { state_edit 's.next_run_at=1; s.rotation=1'; manager if-due >"$WORK/$1.json"; }
# Two manual checks confirm the recommendation for a manual apply. An
# automatic apply also needs scheduled confirmations (D-11a): one earlier
# scheduled run is recorded, so the next scheduled run that agrees makes it
# ready and applies it.
confirm_youtube() {
  manager run youtube >/dev/null
  manager run youtube >"$WORK/confirm.json"
  [ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = true ] || fail "youtube not confirmed: $(cat "$WORK/confirm.json")"
  state_edit 's.groups.youtube.pending.scheduled=1'
}
applies() { if [ -e "$WORK/tune/apply.log" ]; then grep -c '^apply ' "$WORK/tune/apply.log" || true; else echo 0; fi; }
plans() { if [ -e "$WORK/tune/apply.log" ]; then grep -c '^plan ' "$WORK/tune/apply.log" || true; else echo 0; fi; }
decision() { json_get "$WORK/$1.json" groups.youtube.decision; }
history_kinds() { if [ -e "$PROKOP_HISTORY_FILE" ]; then node -e 'console.log(require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(e=>e.kind=="autotune_apply").map(e=>e.status).join(","))' "$PROKOP_HISTORY_FILE"; fi; }

# ---- pure decision and outcome matrix --------------------------------------
cat >"$WORK/pure.uc" <<'UC'
let a = require("autotune.autoapply");
let policy = { mode: "auto", apply_min_confidence: "high", max_applies_per_day: 1 };
let ok = { status: "recommendation", candidate: "fake", confidence: "high" };
let base = { policy, trigger: "schedule", group: { ready: true, ready_auto: true }, result: ok, custom: false, applies: [], now: 100000, cooldown_until: null };
let d = (over) => a.decide({ ...base, ...over }).reason;
print(sprintf("%J\n", {
  ok: a.decide(base),
  recommend: d({ policy: { ...policy, mode: "recommend" } }),
  manual: d({ trigger: "manual" }),
  unconfirmed: d({ group: { ready: false } }),
  manual_only: d({ group: { ready: true, ready_auto: false } }),
  not_applicable: d({ result: { ...ok, status: "not_applicable", reason: "tcp443_profile_shared" } }),
  conflict: d({ result: { status: "conflict" } }),
  direct: d({ result: { ...ok, candidate: "direct" } }),
  medium: d({ result: { ...ok, confidence: "medium" } }),
  custom: d({ custom: true }),
  cooldown: d({ cooldown_until: 100001 }),
  cooldown_over: d({ cooldown_until: 100000 }),
  disabled: d({ policy: { ...policy, max_applies_per_day: 0 } }),
  limit: d({ applies: [ { at: 99000, counted: true } ] }),
  limit_old: d({ applies: [ { at: 100000 - 86400, counted: true } ] }),
  limit_uncounted: d({ applies: [ { at: 99000, counted: false } ] }),
  outcomes: map([ { status: "applied" }, { status: "rolled_back" }, { status: "no_change_required" }, { status: "stale" },
    { status: "busy" }, { status: "failed" }, { status: "needs_attention" }, null,
    { status: "rolled_back", reason: "verification_network_unavailable" } ], (r) => a.outcome(r))
}));
UC
ucode -L "$LIB" "$WORK/pure.uc" >"$WORK/pure.json"
node - "$WORK/pure.json" <<'NODE'
const assert = require('node:assert/strict');
const p = require(process.argv[2]);
assert.deepEqual(p.ok, { apply: true, reason: null });
assert.equal(p.manual_only, 'not_confirmed', 'manual confirmations never allow an automatic apply (D-11a)');
assert.equal(p.not_applicable, 'plan_not_applicable:tcp443_profile_shared');
assert.deepEqual([p.recommend, p.manual, p.unconfirmed, p.conflict, p.direct, p.medium, p.custom, p.cooldown],
  ['mode_not_auto', 'manual_run', 'not_confirmed', 'no_recommendation', 'direct_not_applicable', 'confidence_too_low',
   'custom_strategy_kept', 'candidate_in_cooldown']);
assert.equal(p.cooldown_over, null, 'a cooldown ends at its time');
assert.deepEqual([p.disabled, p.limit, p.limit_old, p.limit_uncounted], ['applies_disabled', 'daily_limit_reached', null, null]);
const o = p.outcomes.map((x) => [x.status, x.counted, x.cooldown, x.reset, x.history]);
assert.deepEqual(o, [
  ['applied', true, false, true, 'success'],
  ['rolled_back', true, true, true, 'recovered'],
  ['no_change_required', false, false, true, null],
  ['stale', false, false, false, null],
  ['busy', false, false, false, null],
  ['failed', true, true, true, 'failure'],
  ['needs_attention', true, true, true, 'failure'],
  ['unknown', true, true, true, 'failure'],
  ['rolled_back', false, false, true, 'recovered'],
]);
NODE

# ---- mode recommend: a confirmed recommendation is only shown ---------------
manager policy-set mode recommend >/dev/null
confirm_youtube
scheduled_youtube recommend
[ "$(decision recommend)" = '"mode_not_auto"' ] || fail "recommend mode: $(cat "$WORK/recommend.json")"
[ "$(plans)" = 0 ] || fail "recommend mode never plans"

# ---- mode auto: manual runs never apply -------------------------------------
manager policy-set mode auto >/dev/null
confirm_youtube
[ "$(json_get "$WORK/confirm.json" groups.youtube.decision)" = '"manual_run"' ] || fail "manual run: $(cat "$WORK/confirm.json")"
[ "$(plans)" = 0 ] || fail "manual runs never plan"
# Confirmations of manual checks alone: the next scheduled run is the first
# scheduled confirmation and applies nothing (D-11a).
state_edit 's.groups.youtube.pending=null; s.groups.youtube.ready=false; s.groups.youtube.ready_auto=false'
manager run youtube >/dev/null
manager run youtube >/dev/null
scheduled_youtube manual_only
[ "$(decision manual_only)" = '"not_confirmed"' ] || fail "manual confirmations allowed an automatic apply: $(cat "$WORK/manual_only.json")"
[ "$(plans)" = 0 ] || fail "manual confirmations planned an automatic apply"

# ---- a custom strategy is never replaced ------------------------------------
manager groups >"$WORK/groups.json"
[ "$(json_get "$WORK/groups.json" groups.discord.custom)" = true ] || fail "fixture: discord must carry a custom strategy"
manager run discord >/dev/null
state_edit 's.next_run_at=1; s.rotation=0'
manager if-due >"$WORK/custom.json"
[ "$(json_get "$WORK/custom.json" groups.discord.decision)" = '"custom_strategy_kept"' ] || fail "custom: $(cat "$WORK/custom.json")"
[ "$(plans)" = 0 ] || fail "a custom strategy is never planned over"

# ---- a scheduled confirmed recommendation is applied through Stage 5 --------
scheduled_youtube applied
[ "$(json_get "$WORK/applied.json" applied.status)" = '"applied"' ] || fail "apply: $(cat "$WORK/applied.json")"
grep -Fxq 'plan www.youtube.com fake 192.0.2.53' "$WORK/tune/apply.log" || fail "plan from the representative's tune of this run: $(cat "$WORK/tune/apply.log")"
grep -Fxq 'apply youtube fake 192.0.2.53' "$WORK/tune/apply.log" || fail "apply of that plan"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" applies.0.counted)" = true ] || fail "the apply counts"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.pending)" = null ] || fail "confirmations start over"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.last_apply.status)" = '"applied"' ] || fail "last apply stored"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" worker.applied)" = '"applied"' ] || fail "worker record"
[ "$(history_kinds)" = success ] || fail "history: $(history_kinds)"
if find "$WORK/tmp" -name 'prokop-autotune-apply.*' | grep -q .; then fail "selection and plan files are removed"; fi
if grep -E 'dpi-desync|nfqws_opt' "$PROKOP_AUTOTUNE_STATE_FILE" >/dev/null; then fail "no raw strategies in the state"; fi
# The automatic apply is watched afterwards (tests/autotune_observation.sh).
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" observation.status)" = '"observing"' ] || fail "observation started"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" observation.apply_started_at)" = 1700000000 ] || fail "observation names the apply"

# ---- the daily limit ----------------------------------------------------------
confirm_youtube
scheduled_youtube limit
[ "$(decision limit)" = '"daily_limit_reached"' ] || fail "daily limit: $(cat "$WORK/limit.json")"
[ "$(applies)" = 1 ] || fail "no second apply within the limit"

# ---- no other automatic apply while one is under observation ----------------
manager policy-set max_applies_per_day 3 >/dev/null
scheduled_youtube observing
[ "$(decision observing)" = '"observation_in_progress"' ] || fail "observation blocks applies: $(cat "$WORK/observing.json")"
[ "$(applies)" = 1 ] || fail "no apply while observing"
state_edit 's.observation=null'

# ---- a rollback cools the candidate down ------------------------------------
printf '{"status":"rolled_back","reason":"verification_failed"}\n' >"$WORK/tune/apply.json"
scheduled_youtube rollback
[ "$(json_get "$WORK/rollback.json" applied.status)" = '"rolled_back"' ] || fail "rollback: $(cat "$WORK/rollback.json")"
until_="$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.cooldowns.fake)"
[ "$until_" -gt $(( $(date +%s) + 86000 )) ] || fail "24h cooldown: $until_"
[ "$(history_kinds)" = success,recovered ] || fail "history after rollback: $(history_kinds)"
confirm_youtube
scheduled_youtube cooldown
[ "$(decision cooldown)" = '"candidate_in_cooldown"' ] || fail "cooldown: $(cat "$WORK/cooldown.json")"
[ "$(applies)" = 2 ] || fail "no apply in the cooldown"

# ---- plans that do not fit are never applied ---------------------------------
state_edit 's.groups.youtube.cooldowns={}; s.applies=[]'
rm -f "$WORK/tune/apply.json"
for case in owner not_applicable no_change candidate; do
  rm -f "$WORK/tune/plan.json"; unset STUB_PLAN_OWNER
  case "$case" in
    owner) export STUB_PLAN_OWNER=discord; want='"owner_changed"'; status='"not_applied"' ;;
    not_applicable) printf '{"status":"not_applicable","reason":"target_not_fakeip_routed"}\n' >"$WORK/tune/plan.json"
      want='"plan_not_applicable:target_not_fakeip_routed"'; status='"not_applied"' ;;
    no_change) printf '{"status":"no_change_required","reason":"candidate_already_active"}\n' >"$WORK/tune/plan.json"
      want='"candidate_already_active"'; status='"no_change_required"' ;;
    candidate) printf '{"status":"ready","selected":"multisplit","owner":{"section":"youtube"}}\n' >"$WORK/tune/plan.json"
      want='"plan_candidate_differs"'; status='"not_applied"' ;;
  esac
  confirm_youtube
  scheduled_youtube "plan-$case"
  [ "$(json_get "$WORK/plan-$case.json" applied.reason)" = "$want" ] || fail "$case: $(cat "$WORK/plan-$case.json")"
  [ "$(json_get "$WORK/plan-$case.json" applied.status)" = "$status" ] || fail "$case status"
  [ "$(json_get "$WORK/plan-$case.json" applied.counted)" = false ] || fail "$case does not count"
  [ "$(applies)" = 2 ] || fail "$case: never applied"
done
unset STUB_PLAN_OWNER; rm -f "$WORK/tune/plan.json"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.cooldowns.fake)" = null ] || fail "unapplied plans do not cool down"

# ---- stale and failed applies -------------------------------------------------
printf '{"status":"stale","reason":"config_changed"}\n' >"$WORK/tune/apply.json"
confirm_youtube; scheduled_youtube stale
[ "$(json_get "$WORK/stale.json" applied.counted)" = false ] || fail "stale: $(cat "$WORK/stale.json")"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = true ] || fail "a stale plan keeps the confirmation"
printf '{"status":"needs_attention","reason":"lkg_confirm_failed"}\n' >"$WORK/tune/apply.json"
scheduled_youtube attention
[ "$(json_get "$WORK/attention.json" applied.counted)" = true ] || fail "needs_attention counts"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.cooldowns.fake)" != null ] || fail "needs_attention cools down"
[ "$(history_kinds)" = success,recovered,failure ] || fail "history after failure: $(history_kinds)"
printf 'garbage\n' >"$WORK/tune/apply.json"
state_edit 's.groups.youtube.cooldowns={}'
confirm_youtube; scheduled_youtube garbage
[ "$(json_get "$WORK/garbage.json" applied.status)" = '"unknown"' ] || fail "unreadable result: $(cat "$WORK/garbage.json")"
[ "$(json_get "$WORK/garbage.json" applied.reason)" = '"apply_output_invalid"' ] || fail "unreadable result reason"
rm -f "$WORK/tune/apply.json"

# ---- confidence below high is never applied ---------------------------------
state_edit 's.groups.youtube.cooldowns={}; s.applies=[]'
manager policy-set min_confidence medium >/dev/null
selected www.youtube.com fake medium; selected i.ytimg.com fake medium
confirm_youtube; scheduled_youtube medium
[ "$(decision medium)" = '"confidence_too_low"' ] || fail "medium: $(cat "$WORK/medium.json")"
selected www.youtube.com fake high; selected i.ytimg.com fake high
manager policy-set min_confidence high >/dev/null

# ---- applies disabled -----------------------------------------------------------
manager policy-set max_applies_per_day 0 >/dev/null
confirm_youtube; scheduled_youtube disabled
[ "$(decision disabled)" = '"applies_disabled"' ] || fail "disabled: $(cat "$WORK/disabled.json")"
manager policy-set max_applies_per_day 3 >/dev/null

# ---- the mode switched off during the run --------------------------------------
before="$(applies)"
confirm_youtube
printf '%s\n' "ucode -L '$LIB' '$LIB/autotune/manager.uc' policy-set mode recommend >/dev/null" >"$WORK/tune/i.ytimg.com.hook"
scheduled_youtube mode-changed
[ "$(json_get "$WORK/mode-changed.json" applied.reason)" = '"mode_changed"' ] || fail "mode changed: $(cat "$WORK/mode-changed.json")"
[ "$(applies)" = "$before" ] || fail "no apply after the mode was switched off"

# ---- a blocker right before the apply ------------------------------------------
manager policy-set mode auto >/dev/null
confirm_youtube
printf '%s\n' "printf '{\"state\":null,\"guards\":[],\"service_action\":\"reload_pending\"}\n' >'$STUB_APPLY_STATUS'" >"$WORK/tune/i.ytimg.com.hook"
scheduled_youtube blocked
[ "$(json_get "$WORK/blocked.json" applied.reason)" = '"reload_pending"' ] || fail "blocked apply: $(cat "$WORK/blocked.json")"
[ "$(applies)" = "$before" ] || fail "no apply while blocked"
rm -f "$STUB_APPLY_STATUS"

# ---- Prokop stopped by the user (D-15, UC-056): measured, never applied ------
confirm_youtube
printf '{"state":null,"guards":[],"service_stopped":true}\n' >"$STUB_APPLY_STATUS"
scheduled_youtube stopped
[ "$(json_get "$WORK/stopped.json" applied.reason)" = '"service_stopped"' ] || fail "stopped: $(cat "$WORK/stopped.json")"
[ "$(json_get "$WORK/stopped.json" applied.counted)" = false ] || fail "a refused apply counts: $(cat "$WORK/stopped.json")"
[ "$(applies)" = "$before" ] || fail "no apply while Prokop is stopped by the user"
rm -f "$STUB_APPLY_STATUS"

echo "autotune autoapply: OK"
