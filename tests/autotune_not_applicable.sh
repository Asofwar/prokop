#!/usr/bin/env bash
set -euo pipefail

# A recommendation the rule's strategy cannot take is "not_applicable" before
# hysteresis, autonomous apply and the page see it (UC-032, D-7a). Autotune
# replaces only the TCP/443 profile of a strategy (autotune/apply.uc plan);
# a strategy that handles HTTPS together with HTTP in one profile has none of
# its own. Such a group is measured and shows what was measured, but it is
# never confirmed, never offered for a manual apply and never planned on
# schedule. The raw strategy stays out of every view (read-only role).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"

state_edit() { node -e 'const f=process.argv[1],s=require(f);(new Function("s",process.argv[2]))(s);require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$PROKOP_AUTOTUNE_STATE_FILE" "$1"; }
plans() { if [ -e "$WORK/tune/apply.log" ]; then grep -c '^plan ' "$WORK/tune/apply.log" || true; else echo 0; fi; }

sed -i "s|option nfqws_opt '--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld'|option nfqws_opt '--filter-tcp=80,443 --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld'|" \
  "$PROKOP_CONFIG_FILE"
grep -Fq -- '--filter-tcp=80,443' "$PROKOP_CONFIG_FILE" || fail "fixture: the shared profile was not set"

manager policy-set mode recommend >/dev/null
manager run youtube >/dev/null
manager run youtube >"$WORK/run.json"
[ "$(json_get "$WORK/run.json" groups.youtube.result.status)" = '"not_applicable"' ] ||
  fail "a shared HTTPS profile must be not applicable: $(cat "$WORK/run.json")"
[ "$(json_get "$WORK/run.json" groups.youtube.result.reason)" = '"tcp443_profile_shared"' ] || fail "the reason apply.uc would give"
[ "$(json_get "$WORK/run.json" groups.youtube.result.candidate)" = '"fake"' ] || fail "the measured candidate is still shown"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = false ] || fail "a not applicable group is never confirmed"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" groups.youtube.pending)" = null ] || fail "nothing is pending for it"

manager groups >"$WORK/groups.json"
[ "$(json_get "$WORK/groups.json" groups.youtube.result.status)" = '"not_applicable"' ] || fail "the live view agrees: $(cat "$WORK/groups.json")"
if grep -E 'dpi-desync|filter-tcp|nfqws_opt' "$WORK/groups.json" "$WORK/run.json" "$PROKOP_AUTOTUNE_STATE_FILE" >/dev/null; then
  fail "a raw strategy reached a view"
fi

if manager apply youtube >"$WORK/apply.json"; then fail "a manual apply of a not applicable group succeeded"; fi
[ "$(json_get "$WORK/apply.json" reason)" = '"plan_not_applicable:tcp443_profile_shared"' ] ||
  fail "the manual apply names why: $(cat "$WORK/apply.json")"

manager policy-set mode auto >/dev/null
state_edit 's.next_run_at=1; s.rotation=1'
manager if-due >"$WORK/due.json"
[ "$(json_get "$WORK/due.json" groups.youtube.decision)" = '"plan_not_applicable:tcp443_profile_shared"' ] ||
  fail "a scheduled run names why: $(cat "$WORK/due.json")"
[ "$(plans)" = 0 ] || fail "a not applicable group is never planned"

# The strategy gets an HTTPS profile of its own: the group is applicable again.
sed -i "s|--filter-tcp=80,443 --dpi-desync=multisplit|--filter-tcp=80 --dpi-desync=multisplit --new --filter-tcp=443 --dpi-desync=multisplit|" \
  "$PROKOP_CONFIG_FILE"
manager policy-set mode recommend >/dev/null
manager run youtube >"$WORK/fixed.json"
[ "$(json_get "$WORK/fixed.json" groups.youtube.result.status)" = '"recommendation"' ] ||
  fail "a strategy with its own HTTPS profile takes the recommendation: $(cat "$WORK/fixed.json")"

echo "autotune not applicable: OK"
