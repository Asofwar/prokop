#!/usr/bin/env bash
set -euo pipefail

# Autotune runs on top of the diagnosis (autotune/manager.uc): every tune
# takes the diagnosis probes and the group's provider; tier 2 of the catalog
# is measured only when tier 1 found nothing stable for a target the
# diagnosis does not rule out; Zapret2 groups are measured, never applied; a
# target may name a large object for the 16-20 KB cut check; and nothing is
# measured, applied or judged while the router clock is not synchronized
# (core/clock.uc). Stand-ins: tests/helpers/autotune_scheduler.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"

state_edit() { node -e 'const f=process.argv[1],s=require(f);(new Function("s",process.argv[2]))(s);require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$PROKOP_AUTOTUNE_STATE_FILE" "$1"; }
tier2_calls() { if [ -e "$WORK/tune/calls-tier2.log" ]; then awk '{print $2}' "$WORK/tune/calls-tier2.log" | tr '\n' ' '; fi; }
log_count() { if [ -e "$WORK/tune/apply.log" ]; then grep -c "$1" "$WORK/tune/apply.log" || true; else echo 0; fi; }
unsynced() { PROKOP_CLOCK_MARKER="$WORK/no-marker" PROKOP_CLOCK_NOW=1700000000 "$@"; }
# The catalog validates candidates with the installed nfqws: a stand-in that
# accepts every strategy.
export ZAPRET_NFQWS_BIN="$WORK/nfqws"
printf '#!/bin/sh\nexit 0\n' >"$ZAPRET_NFQWS_BIN"; chmod +x "$ZAPRET_NFQWS_BIN"
pass=0
ok() { pass=$((pass + 1)); printf 'ok %s\n' "$1"; }

manager policy-set mode recommend >/dev/null

# ---- tier 2 only after tier 1 found nothing stable ---------------------------
printf '{"status":"inconclusive","reason":"all_failed","tier":1,"target":{"host":"www.youtube.com","ip":"198.18.0.9"},"candidates":[]}\n' >"$WORK/tune/www.youtube.com.json"
printf '{"status":"selected","selected":"fake_ttl","confidence":"high","reason":"direct_failed_candidate_stable","tier":2,"provider":"zapret","target":{"host":"www.youtube.com","ip":"198.18.0.9"},"candidates":[{"id":"fake_ttl","stability":"stable","success":5,"attempted":5,"success_ratio":1}]}\n' >"$WORK/tune/www.youtube.com.tier2.json"
printf '{"status":"inconclusive","reason":"ip_blocked","tier":1,"block":{"type":"ip_block"},"target":{"host":"i.ytimg.com","ip":"198.18.0.11"},"candidates":[]}\n' >"$WORK/tune/i.ytimg.com.json"
reset_calls; rm -f "$WORK/tune/calls-tier2.log"
manager run youtube >"$WORK/run.json"
[ "$(calls)" = 'www.youtube.com i.ytimg.com ' ] || fail "tier 1 runs: $(calls)"
[ "$(tier2_calls)" = 'www.youtube.com ' ] || fail "tier 2 only for the target without a stable candidate: $(tier2_calls)"
grep -q 'diag=1,provider=zapret,tier=2' "$WORK/tune/calls-tier2.log" || fail "tier 2 options: $(cat "$WORK/tune/calls-tier2.log")"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" targets.yt.selected)" = '"fake_ttl"' ] || fail "the tier 2 result counts"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" targets.yt.tier)" = 2 ] || fail "the tier is kept"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" targets.ytimg.block)" = '{"type":"ip_block"}' ] || fail "the block type is kept"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" targets.ytimg.reason)" = '"ip_blocked"' ] || fail "an address block is reported"
ok "tier 2 is measured only after tier 1 found nothing stable, never for an address block"

# A candidate that depends on the hop count is never more than medium on one
# address (one target selected it, the other has no result).
[ "$(json_get "$WORK/run.json" groups.youtube.result.confidence)" = '"medium"' ] ||
  fail "a ttl-based candidate on one address: $(json_get "$WORK/run.json" groups.youtube.result)"
[ "$(json_get "$WORK/run.json" groups.youtube.result.confidence_capped)" = '"ttl_single_address"' ] || fail "the cap is named"
ok "a ttl-based candidate measured on one address is capped at medium confidence"
rm -f "$WORK/tune/www.youtube.com.tier2.json" "$WORK/tune/i.ytimg.com.json"
selected www.youtube.com fake high
selected i.ytimg.com fake high

# ---- large object of a host target -------------------------------------------
manager target-set yt www.youtube.com 1 192.0.2.53 "" "" "" /s/player.js 40000 >"$WORK/set.json"
[ "$(json_get "$WORK/set.json" target.large)" = '{"path":"/s/player.js","min_bytes":40000}' ] || fail "large object: $(cat "$WORK/set.json")"
grep -q "option large_path '/s/player.js'" "$PROKOP_CONFIG_FILE" || fail "large_path not written"
reset_calls
manager run youtube >/dev/null
grep -q 'path=/s/player.js,min_bytes=40000' "$WORK/tune/calls.log" || fail "the large object is not measured: $(cat "$WORK/tune/calls.log")"
for bad in "relative.js 40000" "/x.js 100" "/x.js 70000" "/a?b 40000"; do
  # shellcheck disable=SC2086
  if manager target-set yt www.youtube.com 1 192.0.2.53 "" "" "" $bad >"$WORK/bad.json"; then fail "large object $bad accepted"; fi
done
if manager target-set l_yt "" 1 "" youtube-ruleset "" "" /x.js >"$WORK/bad.json"; then fail "a list target took a large object"; fi
[ "$(json_get "$WORK/bad.json" reason)" = '"large_path_needs_host"' ] || fail "list target reason: $(cat "$WORK/bad.json")"
manager target-set yt www.youtube.com 1 192.0.2.53 >/dev/null
! grep -q "large_path" "$PROKOP_CONFIG_FILE" || fail "large_path not removed"
ok "a host target may name a large object; invalid ones are refused"

# ---- the clock gate ------------------------------------------------------------
manager status >"$WORK/status.json"
[ "$(json_get "$WORK/status.json" clock.state)" = '"synced"' ] || fail "status clock: $(json_get "$WORK/status.json" clock)"
unsynced manager status >"$WORK/status.json"
[ "$(json_get "$WORK/status.json" clock)" = '{"state":"unsynced","source":"release_date","stratum":null,"observed_at":null,"reason":"clock_before_release"}' ] ||
  fail "status clock unsynced: $(json_get "$WORK/status.json" clock)"
reset_calls
unsynced manager run youtube >"$WORK/run.json"
[ "$(json_get "$WORK/run.json" reason)" = '"clock_unsynced"' ] || fail "run on an unsynchronized clock: $(cat "$WORK/run.json")"
[ "$(json_get "$WORK/run.json" result)" = '"skipped"' ] || fail "the run is skipped"
[ -z "$(calls)" ] || fail "measured on an unsynchronized clock: $(calls)"
ok "no run on an unsynchronized clock; the status shows the clock"

# The manual apply of a confirmed recommendation waits for the clock.
manager run youtube >/dev/null; manager run youtube >/dev/null
rm -f "$WORK/tune/apply.log"
if unsynced manager apply youtube >"$WORK/apply.json"; then fail "applied on an unsynchronized clock"; fi
[ "$(json_get "$WORK/apply.json" reason)" = '"clock_unsynced"' ] || fail "manual apply: $(cat "$WORK/apply.json")"
[ "$(log_count '^apply ')" = 0 ] || fail "apply.uc called on an unsynchronized clock"
ok "no manual apply on an unsynchronized clock"

# An observation is neither judged nor expired on an unsynchronized clock.
manager policy-set mode auto >/dev/null
now="$(date +%s)"
state_edit "s.observation={status:'observing',group:'youtube',candidate:'fake',apply_started_at:1700000000,started_at:$now,
  checks_required:4,passed:0,failures_in_row:0,checks:[],next_check_at:1,deadline:$now+86400}; s.next_run_at=$now+3600"
rm -f "$WORK/tune/apply.log"
unsynced manager if-due >"$WORK/tick.json"
[ "$(json_get "$WORK/tick.json" observation.reason)" = '"clock_unsynced"' ] || fail "observation tick: $(cat "$WORK/tick.json")"
[ "$(log_count '^observe ')" = 0 ] || fail "observed on an unsynchronized clock"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" observation.status)" = '"observing"' ] || fail "the observation goes on"
manager if-due >"$WORK/tick.json"
[ "$(log_count '^observe ')" = 1 ] || fail "observed once the clock is set: $(cat "$WORK/tick.json")"
ok "an observation waits for the clock, then goes on"
manager policy-set mode recommend >/dev/null
state_edit 'delete s.observation'

# ---- Zapret2 groups ------------------------------------------------------------
cat >>"$PROKOP_CONFIG_FILE" <<'CONF'
config section 'z2'
	option action 'zapret2'
	option label 'Zapret2'
config autotune_target 'z2t'
	option host 'z2.example.net'
CONF
node -e 'const f=process.argv[1],c=require(f);c.route.rules.push({action:"route",inbound:"tproxy-in",domain_suffix:["z2.example.net"],outbound:"z2-out"});
c.outbounds.push({type:"direct",tag:"z2-out",routing_mark:33554433});require("fs").writeFileSync(f,JSON.stringify(c))' "$PROKOP_AUTOTUNE_SINGBOX_CONFIG"
printf '{"status":"selected","selected":"z2_fake","confidence":"high","reason":"direct_failed_candidate_stable","provider":"zapret2","tier":1,"target":{"host":"z2.example.net","ip":"198.18.0.14"},"candidates":[{"id":"z2_fake","stability":"stable","success":5,"attempted":5,"success_ratio":1}]}\n' >"$WORK/tune/z2.example.net.json"
reset_calls
manager run z2 >"$WORK/z2.json"
grep -q '^tune z2.example.net .*provider=zapret2,tier=1' "$WORK/tune/calls.log" || fail "Zapret2 tune options: $(cat "$WORK/tune/calls.log")"
[ "$(json_get "$WORK/z2.json" groups.z2.result.status)" = '"not_applicable"' ] || fail "Zapret2 result: $(cat "$WORK/z2.json")"
[ "$(json_get "$WORK/z2.json" groups.z2.result.reason)" = '"zapret2_apply_unsupported"' ] || fail "Zapret2 reason"
[ "$(json_get "$WORK/z2.json" groups.z2.result.candidate)" = '"z2_fake"' ] || fail "the Zapret2 candidate is shown"
if manager apply z2 >"$WORK/apply.json"; then fail "a Zapret2 group was applied"; fi
[ "$(json_get "$WORK/apply.json" reason)" = '"plan_not_applicable:zapret2_apply_unsupported"' ] || fail "manual apply: $(cat "$WORK/apply.json")"
ok "a Zapret2 group is measured with its provider and recommended, never applied"

printf 'autotune_tiers_clock: PASS (%d checks)\n' "$pass"
