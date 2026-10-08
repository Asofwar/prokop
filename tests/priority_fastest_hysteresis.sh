#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT/prokop/files/usr/lib/singbox/priority.uc" "$WORK/check.uc" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
prelude = '''let now = 0, latencies = {}, responses = {}, switches = [];
function now_seconds() { return now; }
function duration_to_seconds(value, fallback) { return int(value || fallback); }
function as_string(value) { return value == null ? "" : sprintf("%s", value); }
function array_or_empty(value) { return value || []; }
function object_or_empty(value) { return value || {}; }
function clash_probe(tag, group) {
    let queue = responses[tag];
    let delay = queue != null && length(queue) > 0 ? shift(queue) : latencies[tag];
    return {alive: delay != null, delay: delay == null ? 0 : delay};
}
function payload_transfer(group, tag) { return true; }
function set_group_proxy(group, tag) { push(switches, tag); return true; }
function log_message(message, level) {}
function check(ok, message) { if (!ok) { warn(message, "\\n"); exit(1); } }
'''
functions = []
for name in ['new_payload_state', 'checked_probe', 'choose_from_level',
             'choose_from_level_range', 'choose_fastest_same_level',
             'switch_group', 'init_group_state', 'tick_group']:
    found = re.search(r'^function ' + name + r'\([^\n]*\) \{[\s\S]*?^\}', source, re.M)
    assert found, name
    functions.append(found[0])
checks = '''
let group = {tag:"group", levels:[{outbounds:["A", "B"]}],
    active_check_interval:5, fastest_check_interval:5,
    switch_to_faster_same_priority:true};
let state = init_group_state(group);
state.active="A"; state.levelIndex=0; state.activeDelay=300;
state.nextActiveCheck=5; state.nextFastestCheck=5;
latencies={A:null, B:100}; now=5;
tick_group(state, group);
check(state.active=="A" && state.failures==1 && length(switches)==0,
    "coincident active/fastest timers must retain A after its first failed probe");
now=10; tick_group(state, group);
check(state.active=="B" && state.failures==0 && length(switches)==1,
    "second scheduled active failure must fail over to B");
// A fastest-only scan is not a scheduled active failure check.
now=20; switches=[];
state=init_group_state(group);
state.active="A"; state.levelIndex=0; state.activeDelay=300;
state.nextActiveCheck=25; state.nextFastestCheck=20;
latencies={A:null, B:100};
tick_group(state, group);
check(state.active=="A" && state.failures==0 && length(switches)==0,
    "fastest-only scan must not fail over when its active probe fails");
// A successful scan re-probe must not override the scheduled failure streak.
now=30; switches=[];
state=init_group_state(group);
state.active="A"; state.levelIndex=0; state.activeDelay=300;
state.nextActiveCheck=30; state.nextFastestCheck=30;
latencies={A:300, B:100}; responses={A:[null, 300]};
tick_group(state, group);
check(state.active=="A" && state.failures==1 && length(switches)==0,
    "a pending active failure must suppress even a healthy fastest scan");
responses={}; now=35; tick_group(state, group);
check(state.active=="B" && state.failures==0 && length(switches)==1,
    "scheduled active success must clear the streak and permit healthy latency selection");

// Exercise both latency thresholds with the real fastest selector.
for (let candidate_delay in [270, 245, 240]) {
    now=50; switches=[];
    state=init_group_state(group);
    state.active="A"; state.levelIndex=0; state.activeDelay=300;
    state.nextActiveCheck=50; state.nextFastestCheck=50;
    latencies={A:300, B:candidate_delay};
    tick_group(state, group);
    check(state.active==(candidate_delay==240 ? "B" : "A"),
        "healthy fastest selection must retain the 50 ms and 20 percent thresholds");
}

// Higher-priority recovery remains independent of same-level hysteresis.
now=70; switches=[];
let recovery_group={...group, levels:[{outbounds:["R"]}, {outbounds:["A", "B"]}]};
state=init_group_state(recovery_group);
state.active="A"; state.levelIndex=1; state.activeDelay=300;
state.nextActiveCheck=70; state.nextRecoveryCheck=70; state.nextFastestCheck=70;
latencies={R:350, A:null, B:100};
tick_group(state, recovery_group);
check(state.active=="R" && state.levelIndex==0 && state.failures==0 && length(switches)==1,
    "higher-priority recovery must still run during an active failure streak");
print("priority fastest hysteresis passed\\n");
'''
Path(sys.argv[2]).write_text(prelude + '\n'.join(functions) + checks)
PY
ucode "$WORK/check.uc"
