#!/usr/bin/env bash
set -euo pipefail

# The operator's rollback of the recorded autotune apply (design H.7,
# UC-020, UC-069): `prokop autotune_rollback` -> autotune/manager.uc rollback
# -> the Stage 5 rollback (autotune/apply.uc rollback). Only the admin CLI
# carries it (the read-only wrapper has no grant for it, tests/acl_boundary).
# It never runs next to a run or an apply of the worker; a rolled back
# candidate pauses in its group and the group shows the rollback as its last
# change. The status of the page names the recorded apply, whether it still
# needs a decision and whether it can be rolled back, without any of the
# configuration (hashes, options, target addresses).
# Stand-ins: tests/helpers/autotune_scheduler (apply.uc answers from files).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"
CLI="$ROOT_DIR/prokop/files/usr/bin/prokop"
export PROKOP_AUTOTUNE_APPLY_STATE="$WORK/etc/autotune-apply.json"
mkdir -p "$WORK/etc"
rollbacks() { grep -c '^rollback$' "$WORK/tune/apply.log" 2>/dev/null || true; }
status_with() { # status_with <apply status JSON>: the page status while apply.uc reports it
  printf '%s\n' "$1" >"$STUB_APPLY_STATUS"
  manager status >"$WORK/status.json"
}

# 1. The CLI command: the manager's rollback, no arguments.
grep -Fq 'autotune_rollback: [ "autotune/manager.uc", "rollback", 0 ]' "$CLI" ||
  fail "prokop autotune_rollback must run the manager's rollback without arguments"

# 2. Status: no apply record -> nothing to show.
rm -f "$PROKOP_AUTOTUNE_APPLY_STATE" "$STUB_APPLY_STATUS"
manager status >"$WORK/status.json"
[ "$(json_get "$WORK/status.json" apply)" = null ] || fail "an apply summary without a record: $(cat "$WORK/status.json")"

# A crash during verification: unresolved, the candidate is active -> can
# be rolled back; nothing of the configuration leaves the summary.
: >"$PROKOP_AUTOTUNE_APPLY_STATE"
status_with '{"state":{"phase":"verifying","reason":null,"selected":"fake","mutation":{"section":"youtube","option":"nfqws_opt","from":"SECRET-FROM","to":"SECRET-TO"},"target":{"host":"secret.example","ip":"192.0.2.77"},"plan_config_hash":"'"$(printf 'a%.0s' $(seq 64))"'","started_at":5},"config_hash":"'"$(printf 'b%.0s' $(seq 64))"'","resolved":false,"diagnosis":"candidate_active","guards":[],"snapshot_operation":false,"service_action":null,"autotune_lock_held":false,"rollback_source_present":true}'
node -e '
const a = require("node:assert/strict");
const r = require(process.argv[1]).apply;
a.deepEqual(r, { phase: "verifying", reason: null, group: "youtube", candidate: "fake", finished_at: null,
  resolved: false, diagnosis: "candidate_active", in_progress: false, rollback: true, unverified_strategy: false });' "$WORK/status.json" ||
  fail "summary of an interrupted verification: $(cat "$WORK/status.json")"
! grep -Eq 'SECRET|secret\.example|192\.0\.2\.77|aaaa|bbbb' "$WORK/status.json" || fail "the summary leaks the configuration"

# The same phase while the apply still runs: no rollback offered.
status_with '{"state":{"phase":"verifying","selected":"fake","mutation":{"section":"youtube"}},"resolved":false,"diagnosis":"candidate_active","autotune_lock_held":true,"rollback_source_present":true}'
[ "$(json_get "$WORK/status.json" apply.in_progress)" = true ] || fail "a running apply is not in progress: $(cat "$WORK/status.json")"
[ "$(json_get "$WORK/status.json" apply.rollback)" = false ] || fail "a running apply offered a rollback"

# A verified apply whose candidate is still the configuration: resolved,
# and the operator may still roll it back.
status_with '{"state":{"phase":"applied","status":"applied","selected":"fake","mutation":{"section":"youtube"},"finished_at":9},"resolved":true,"diagnosis":"candidate_active","autotune_lock_held":false,"rollback_source_present":true}'
node -e '
const a = require("node:assert/strict");
const r = require(process.argv[1]).apply;
a.equal(r.resolved, true); a.equal(r.rollback, true); a.equal(r.finished_at, 9);' "$WORK/status.json" ||
  fail "summary of a verified apply: $(cat "$WORK/status.json")"

# The configuration changed since: nothing to roll back.
status_with '{"state":{"phase":"applied","selected":"fake","mutation":{"section":"youtube"}},"resolved":true,"diagnosis":"superseded","autotune_lock_held":false,"rollback_source_present":true}'
[ "$(json_get "$WORK/status.json" apply.rollback)" = false ] || fail "a superseded apply offered a rollback"
[ "$(json_get "$WORK/status.json" apply.unverified_strategy)" = false ] || fail "a superseded apply named an unverified strategy"

# Edited during a failed check, the rule still runs the candidate's strategy:
# the record blocks nothing, but no start or reload confirms the
# configuration, and the page is told so.
status_with '{"state":{"phase":"needs_attention","reason":"verification_failed:config_changed_during_transaction","selected":"fake","mutation":{"section":"youtube"}},"resolved":true,"diagnosis":"superseded","unverified_strategy":true,"autotune_lock_held":false,"rollback_source_present":true}'
node -e '
const a = require("node:assert/strict");
const r = require(process.argv[1]).apply;
a.equal(r.resolved, true); a.equal(r.unverified_strategy, true); a.equal(r.rollback, false);' "$WORK/status.json" ||
  fail "summary of an edited, unverified strategy: $(cat "$WORK/status.json")"

# An unreadable record: needs attention, the rollback settles it.
status_with '{"state":{"phase":"needs_attention","status":"needs_attention","reason":"apply_state_unreadable","unreadable":true},"resolved":false,"diagnosis":"state_unreadable","autotune_lock_held":false,"rollback_source_present":true}'
node -e '
const a = require("node:assert/strict");
const r = require(process.argv[1]).apply;
a.equal(r.resolved, false); a.equal(r.diagnosis, "state_unreadable"); a.equal(r.rollback, true);
a.equal(r.group, null); a.equal(r.reason, "apply_state_unreadable");' "$WORK/status.json" ||
  fail "summary of an unreadable record: $(cat "$WORK/status.json")"

# Nothing to return to (the before-autotune snapshot is gone and
# last-known-working no longer holds the pre-apply configuration, or it is
# gone for an unreadable record): no rollback that could only fail.
status_with '{"state":{"phase":"verifying","selected":"fake","mutation":{"section":"youtube"}},"resolved":false,"diagnosis":"candidate_active","autotune_lock_held":false,"rollback_source_present":false}'
[ "$(json_get "$WORK/status.json" apply.resolved)" = false ] || fail "a record without a rollback source was shown as settled"
[ "$(json_get "$WORK/status.json" apply.rollback)" = false ] || fail "a rollback without a snapshot to return to was offered"
status_with '{"state":{"phase":"needs_attention","reason":"apply_state_unreadable","unreadable":true},"resolved":false,"diagnosis":"state_unreadable","autotune_lock_held":false,"rollback_source_present":false}'
[ "$(json_get "$WORK/status.json" apply.rollback)" = false ] || fail "the rollback of an unreadable record without last-known-working was offered"

# The apply tool does not answer: shown as unknown, never as resolved.
status_with 'not json'
[ "$(json_get "$WORK/status.json" apply.resolved)" = null ] || fail "an unknown apply state was shown as settled: $(cat "$WORK/status.json")"
[ "$(json_get "$WORK/status.json" apply.rollback)" = false ] || fail "an unknown apply state offered a rollback"
rm -f "$STUB_APPLY_STATUS"

# 3. A rollback: the Stage 5 rollback runs once; its candidate pauses in its
#    group, which shows the rollback as its last change.
manager policy-set mode recommend >/dev/null
manager rollback >"$WORK/rollback.json" || true
node -e '
const a = require("node:assert/strict");
const r = require(process.argv[1]);
a.equal(r.status, "ok"); a.equal(r.result, "rolled_back"); a.equal(r.group, "youtube"); a.equal(r.candidate, "fake");
a.equal(r.restored, true);' \
  "$WORK/rollback.json" || fail "rollback result: $(cat "$WORK/rollback.json")"
[ "$(rollbacks)" = 1 ] || fail "the Stage 5 rollback did not run exactly once"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.last_apply.status)" = '"rolled_back"' ] ||
  fail "the group does not show the rollback: $(cat "$PROKOP_AUTOTUNE_STATE_FILE")"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.last_apply.reason)" = '"operator_rollback"' ] || fail "rollback reason"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.last_apply.trigger)" = '"manual"' ] || fail "rollback trigger"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.cooldowns.fake)" -gt "$(date +%s)" ] ||
  fail "the rolled back candidate does not pause"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" applies)" = '[]' ] || fail "an operator rollback counts as an apply"

# 3b. A rollback that did not finish (its restore reload was only queued,
#     the guard stays): the group card shows that, not the outcome of the
#     apply before it; the candidate pauses all the same.
printf '%s\n' '{"status":"needs_attention","phase":"needs_attention","reason":"operator_rollback:rollback_needs_attention","selected":"fake","mutation":{"section":"youtube","option":"nfqws_opt"},"rollback":{"status":"needs_attention"},"applied":false}' >"$WORK/tune/rollback.json"
if manager rollback >"$WORK/rollback.json"; then fail "an unfinished rollback exited 0"; fi
node -e '
const a = require("node:assert/strict");
const r = require(process.argv[1]);
a.equal(r.status, "failed"); a.equal(r.result, "needs_attention"); a.equal(r.group, "youtube"); a.equal(r.restored, false);' \
  "$WORK/rollback.json" || fail "unfinished rollback result: $(cat "$WORK/rollback.json")"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.last_apply.status)" = '"needs_attention"' ] ||
  fail "the group does not show the unfinished rollback: $(cat "$PROKOP_AUTOTUNE_STATE_FILE")"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.last_apply.reason)" = '"operator_rollback"' ] || fail "unfinished rollback reason"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" applies)" = '[]' ] || fail "an unfinished operator rollback counts as an apply"

# 3c. An unreadable record set aside while the configuration already was the
#     last-known-working one: done, but nothing was restored; no group changes.
before="$(cat "$PROKOP_AUTOTUNE_STATE_FILE")"
printf '%s\n' '{"status":"rolled_back","phase":"rolled_back","reason":"apply_state_unreadable","mutation":null,"rollback":{"status":"not_needed","lkg":"1_1"}}' >"$WORK/tune/rollback.json"
manager rollback >"$WORK/rollback.json" || fail "setting an unreadable record aside exited non-zero"
node -e '
const a = require("node:assert/strict");
const r = require(process.argv[1]);
a.equal(r.status, "ok"); a.equal(r.reason, "apply_state_unreadable"); a.equal(r.restored, false); a.equal(r.group, null);' \
  "$WORK/rollback.json" || fail "unreadable record result: $(cat "$WORK/rollback.json")"
[ "$(cat "$PROKOP_AUTOTUNE_STATE_FILE")" = "$before" ] || fail "setting an unreadable record aside changed a group"
rm -f "$WORK/tune/rollback.json"

# 4. A refused rollback changes nothing in the state.
before="$(cat "$PROKOP_AUTOTUNE_STATE_FILE")"
printf '%s\n' '{"status":"failed","reason":"rollback_needs_candidate_config","diagnosis":"superseded"}' >"$WORK/tune/rollback.json"
if manager rollback >"$WORK/rollback.json"; then fail "a refused rollback exited 0"; fi
node -e '
const a = require("node:assert/strict");
const r = require(process.argv[1]);
a.equal(r.status, "failed"); a.equal(r.result, "failed"); a.equal(r.reason, "rollback_needs_candidate_config");' \
  "$WORK/rollback.json" || fail "refused rollback: $(cat "$WORK/rollback.json")"
[ "$(cat "$PROKOP_AUTOTUNE_STATE_FILE")" = "$before" ] || fail "a refused rollback changed the autotune state"
rm -f "$WORK/tune/rollback.json"

# 5. Never next to a run of the worker.
rm -f "$WORK/tune/calls.log"
STUB_TUNE_SLEEP=5 ucode -L "$LIB" "$LIB/autotune/manager.uc" run youtube >/dev/null &
run_pid=$!; BG_PIDS+=("$run_pid")
for _ in $(seq 100); do [ -s "$WORK/tune/calls.log" ] && break; sleep 0.1; done
[ -s "$WORK/tune/calls.log" ] || fail "fixture: the run did not start measuring"
count="$(rollbacks)"
if manager rollback >"$WORK/rollback.json"; then fail "a rollback next to a run exited 0"; fi
[ "$(json_get "$WORK/rollback.json" status)" = '"busy"' ] || fail "rollback next to a run: $(cat "$WORK/rollback.json")"
[ "$(json_get "$WORK/rollback.json" reason)" = '"autotune_worker_running"' ] || fail "busy reason"
[ "$(rollbacks)" = "$count" ] || fail "the Stage 5 rollback ran next to a run"
wait "$run_pid" || true

echo "autotune operator rollback: OK"
