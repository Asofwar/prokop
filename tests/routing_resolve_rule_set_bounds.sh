#!/usr/bin/env bash
set -euo pipefail

# The cost of asking sing-box about lists (UC-220). route_trace and
# autotune_groups, which a read-only session calls and the UI polls, resolve
# every target, and each question is one sing-box process that parses the
# whole list. So:
# - each question is bounded: sing-box is killed after
#   PROKOP_RULESET_MATCH_TIMEOUT seconds, and the list is undecidable;
# - one process asks each (list file, value) once, however many rules name
#   the list and however many times the target is resolved; a changed file
#   is asked again;
# - one pass over the rules (each target resolved) spends at most
#   PROKOP_RULESET_MATCH_BUDGET seconds in sing-box, and a run never outlasts
#   what is left of it; after that, lists are undecidable instead of asked;
# - a caller that resolves many targets for a waiting page (autotune_groups)
#   limits the whole process (limit_ruleset_time) the same way;
# - the watchdog that kills a run leaves no process behind.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
cleanup() {
    pkill -KILL -f -- "$WORK/" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$WORK/sing-box" <<EOF
#!/bin/sh
exec ucode -- "$ROOT_DIR/tests/helpers/sing_box_rule_set_stub.uc" "\$@"
EOF
chmod +x "$WORK/sing-box"
export PROKOP_RULESET_MATCH_BIN="$WORK/sing-box"
export RULESET_STUB_CALLS="$WORK/calls"
: >"$WORK/calls"

# Stored the way singbox/ruleset_cache.uc leaves a list: with its record.
RECORD="$ROOT_DIR/tests/helpers/rule_set_record.uc"
export RECORD
binary_list() {
    printf 'SRS\n%s\n' "$2" >"$WORK/$1"
    ucode -L "$LIB" "$RECORD" "$WORK/$1"
}
binary_list youtube.srs '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ] } ] }'
for n in 1 2 3; do binary_list "other$n.srs" "{ \"version\": 3, \"rules\": [ { \"domain\": [ \"example$n.org\" ] } ] }"; done
binary_list hang.srs '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ] } ] }'

cat >"$WORK/prokop" <<'EOF'
config settings 'settings'
config section 'youtube'
	option action 'zapret'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=multisplit'
config section 'main'
	option action 'connection'
EOF

# Resolves each step's host in ONE process and reports, per step, the answer
# and how many "rule-set match" questions it took. A step may first rewrite
# a list file (as a refresh of the cache does: with a new record).
cat >"$WORK/steps.uc" <<'EOF'
let fs = require("fs"), r = require("routing.resolve");
let sections = r.parse_config(fs.readfile(ARGV[0]));
let c = json(fs.readfile(ARGV[1]));
let asked = () => length(filter(split(fs.readfile(getenv("RULESET_STUB_CALLS")) || "", "\n"), (l) => index(l, "rule-set match ") == 0));
let config = { route: { final: "direct-out", rule_set: c.rule_set, rules: c.rules },
    outbounds: [ { type: "direct", tag: "direct-out" }, { type: "vless", tag: "main-out" },
        { type: "direct", tag: "youtube-out", routing_mark: 16777217 } ] };
if (c.limit != null) r.limit_ruleset_time(c.limit);
let out = [];
for (let step in c.steps) {
    if (step.rewrite != null) {
        fs.writefile(step.rewrite.path, step.rewrite.text);
        system([ "ucode", "-L", getenv("PROKOP_LIB"), getenv("RECORD"), step.rewrite.path ]);
    }
    let before = asked();
    let got = r.resolve(config, sections, r.target(step.host, "198.18.0.9", { fakeip: true }));
    push(out, join(" ", map([ got.status, got.route_rule, got.section, asked() - before ], (v) => v == null ? "null" : "" + v)));
}
print(join("\n", out), "\n");
EOF

run_steps() { # json -> one line per step: status rule section questions
    printf '%s' "$1" >"$WORK/case.json"
    timeout 30 env PROKOP_LIB="$LIB" ucode -L "$LIB" "$WORK/steps.uc" "$WORK/prokop" "$WORK/case.json" ||
        fail "the resolver did not finish"
}

local_set() { printf '{ "type": "local", "tag": "%s", "format": "binary", "path": "%s" }' "$1" "$WORK/$2"; }
route() { printf '{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": [ "%s" ], "outbound": "%s" }' "$1" "$2"; }
sets="[ $(local_set yt youtube.srs), $(local_set other1 other1.srs), $(local_set other2 other2.srs),
  $(local_set other3 other3.srs), $(local_set hang hang.srs) ]"

# ---- memoised per process --------------------------------------------------
# Two rules name the same list above the owner: it is asked once. Resolving
# the target again asks nothing; a new name asks each list once; a list file
# that changed (here: its size) is asked again, the others are not.
rewrite="{ \"path\": \"$WORK/youtube.srs\", \"text\": \"SRS\\n{ \\\"version\\\": 3, \\\"rules\\\": [ { \\\"domain_suffix\\\": [ \\\"example.network\\\" ] } ] }\\n\" }"
got="$(run_steps "{ \"rule_set\": $sets,
  \"rules\": [ $(route other1 main-out), $(route other1 main-out), $(route yt youtube-out) ],
  \"steps\": [ { \"host\": \"youtube.com\" }, { \"host\": \"youtube.com\" }, { \"host\": \"www.youtube.com\" },
    { \"host\": \"youtube.com\", \"rewrite\": $rewrite } ] }")"
want="decided 2 youtube 2
decided 2 youtube 0
decided 2 youtube 2
decided null null 1"
[ "$got" = "$want" ] || fail "memoisation: got
$got
want
$want"

# ---- one question is bounded -----------------------------------------------
binary_list youtube.srs '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ] } ] }'
start=$SECONDS
got="$(RULESET_STUB_HANG=youtube.com PROKOP_RULESET_MATCH_TIMEOUT=1 run_steps "{ \"rule_set\": $sets,
  \"rules\": [ $(route hang youtube-out), $(route yt youtube-out) ], \"steps\": [ { \"host\": \"youtube.com\" } ] }")"
[ "$got" = "undecidable 0 null 1" ] || fail "timeout: got $got"
[ $((SECONDS - start)) -le 8 ] || fail "timeout: the resolver waited $((SECONDS - start))s for a hung sing-box"
if pgrep -f -- "$WORK/hang.srs" >/dev/null; then fail "timeout: the hung sing-box was left running"; fi

# ---- a run never outlasts the budget ---------------------------------------
# The timeout of one run is 20s, but only 2s of the budget are left: the hung
# sing-box is killed after 2s.
start=$SECONDS
got="$(RULESET_STUB_HANG=youtube.com PROKOP_RULESET_MATCH_TIMEOUT=20 PROKOP_RULESET_MATCH_BUDGET=2 run_steps "{ \"rule_set\": $sets,
  \"rules\": [ $(route hang youtube-out), $(route yt youtube-out) ], \"steps\": [ { \"host\": \"youtube.com\" } ] }")"
[ "$got" = "undecidable 0 null 1" ] || fail "clamped run: got $got"
[ $((SECONDS - start)) -le 6 ] || fail "clamped run: the resolver waited $((SECONDS - start))s with a 2s budget"

# ---- one budget per pass over the rules ------------------------------------
# Every question takes 1.5s and the budget is 3s. The first list is asked
# (it does not hold the host); the second is asked with the 1s left (and
# killed) or not at all: undecidable at rule 1, never at a later rule. The
# next target has a budget of its own and is asked again.
four="[ $(route other1 main-out), $(route other2 main-out), $(route other3 main-out), $(route yt youtube-out) ]"
start=$SECONDS
got="$(RULESET_STUB_DELAY_MS=1500 PROKOP_RULESET_MATCH_BUDGET=3 run_steps "{ \"rule_set\": $sets, \"rules\": $four,
  \"steps\": [ { \"host\": \"youtube.com\" }, { \"host\": \"www.youtube.com\" } ] }")"
elapsed=$((SECONDS - start))
case "$got" in
    "undecidable 1 null "[12]"
undecidable 1 null "[12]) ;;
    *) fail "budget per pass: got
$got" ;;
esac
[ "$elapsed" -le 12 ] || fail "budget per pass: two passes of 3s took ${elapsed}s"

# ---- a limit for the whole process -----------------------------------------
# The caller limits the process to 2s: the first pass asks one list (1.5s),
# then nothing is asked any more, whatever the budget of a pass.
got="$(RULESET_STUB_DELAY_MS=1500 PROKOP_RULESET_MATCH_BUDGET=30 run_steps "{ \"rule_set\": $sets, \"rules\": $four,
  \"limit\": 2, \"steps\": [ { \"host\": \"youtube.com\" }, { \"host\": \"www.youtube.com\" } ] }")"
want="undecidable 1 null 1
undecidable 0 null 0"
[ "$got" = "$want" ] || fail "process limit: got
$got
want
$want"

# ---- the watchdog leaves nothing behind ------------------------------------
# A sing-box that ends at once (here: true) raced the old watchdog: killed
# before it had set its trap, it left its sleep running for the whole
# timeout, about one run in three. 200 runs (one per target) with a timeout
# nobody else uses; every process they leave carries RESOLVER_RUN_MARK. A
# killed watchdog may leave its current one-second sleep: give it 3s.
targets=""
for n in $(seq 1 200); do targets="$targets${targets:+, }{ \"host\": \"host$n.test\" }"; done
PROKOP_RULESET_MATCH_BIN=true PROKOP_RULESET_MATCH_TIMEOUT=29 PROKOP_RULESET_MATCH_BUDGET=59 RESOLVER_RUN_MARK="$WORK" \
    run_steps "{ \"rule_set\": $sets, \"rules\": [ $(route yt youtube-out) ], \"steps\": [ $targets ] }" >/dev/null
marked() {
    local count=0 environ
    for environ in /proc/[0-9]*/environ; do
        if tr '\0' '\n' 2>/dev/null <"$environ" | grep -qxF "RESOLVER_RUN_MARK=$WORK"; then count=$((count + 1)); fi
    done 2>/dev/null
    echo "$count"
}
deadline=$((SECONDS + 3))
while [ "$(marked)" != 0 ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
left="$(marked)"
[ "$left" = 0 ] || fail "watchdog: $left processes of 200 runs were left behind"

echo "routing_resolve_rule_set_bounds: ok"
