#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT/prokop/files/usr/lib/singbox/priority.uc" "$WORK/check.uc" <<'PY'
import re,sys
from pathlib import Path
source=Path(sys.argv[1]).read_text()
prelude='''let now = 0, delay = 300, fallback = null, faster = null, switches = [];
function now_seconds() { return now; }
function duration_to_seconds(value, fallback) { return 1; }
function new_payload_state() { return {observations:{}}; }
function clash_probe(tag, group) { return {alive:delay != null,delay:delay || 0}; }
function payload_transfer(group,tag) { return true; }
function checked_probe(payload, group, tag, probe, transfer, now) { return probe(tag,group); }
function choose_from_level_range(group,start,end,probe,skip) { return fallback; }
function choose_fastest_same_level(group,level,active,probe) { return faster; }
function set_group_proxy(group,tag) { push(switches,tag); return true; }
function log_message(message,level) {}
function check(ok, message) { if (!ok) {warn(message,"\\n");exit(1);} }
'''
functions=[]
for name in ['switch_group','init_group_state','tick_group']:
 found=re.search(r'^function '+name+r'\([^\n]*\) \{[\s\S]*?^\}',source,re.M)
 assert found,name
 functions.append(found[0])
checks='''
let group = {tag:"group", levels:[{}],switch_to_faster_same_priority:true};
let state = init_group_state(group);
state.active="A"; state.levelIndex=0; state.activeDelay=300;
delay=null; fallback={tag:"B",levelIndex:0,delay:300};
tick_group(state,group);
check(state.active=="A" && state.failures==1 && length(switches)==0,"one failed probe must not switch");
now=1; tick_group(state,group);
check(state.active=="B" && state.failures==0 && length(switches)==1,"second consecutive failure must switch");
delay=300; now=2; faster={tag:"C",levelIndex:0,delay:270}; tick_group(state,group);
check(state.active=="B","less than 50 ms improvement must not switch");
now=3; faster={tag:"C",levelIndex:0,delay:245}; tick_group(state,group);
check(state.active=="B","less than 20 percent improvement must not switch");
// A single latency spike does not change the median used for switching.
now=4; delay=10; faster=null; tick_group(state,group);
check(state.activeDelay==300,"three-sample median must suppress a single latency spike");
now=5; delay=300; faster={tag:"C",levelIndex:0,delay:240}; tick_group(state,group);
check(state.active=="C" && length(switches)==2,"50 ms and 20 percent improvement must switch");
now=6; faster=null; delay=null; tick_group(state,group);
now=7; delay=300; tick_group(state,group);
check(state.failures==0,"successful probe must reset the failure streak");
print("priority hysteresis passed\\n");
'''
Path(sys.argv[2]).write_text(prelude+'\n'.join(functions)+checks)
PY
ucode "$WORK/check.uc" >"$WORK/result" 2>"$WORK/error" || { cat "$WORK/error" >&2; exit 1; }
grep -q '^priority hysteresis passed' "$WORK/result" || { cat "$WORK/error" >&2; exit 1; }
cat "$WORK/result"
