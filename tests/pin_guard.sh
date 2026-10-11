#!/usr/bin/env bash
set -euo pipefail

# R2 pin_guard (singbox/pin_guard.uc, after cergo666/netshift 28560be6): a
# server chosen by hand in a rule's selector that stops answering stays
# selected, and the rule silently stops working. With the rule's opt-in
# option pin_guard, three failed checks in a row switch the selector to the
# rule's first URLTest group; the switch is recorded, the choice saved for a
# reboot (C4) keeps the server the user chose, and the dashboard shows it.
#
#  1. generation: the section cache names the selector and the group only
#     when the rule asks for it and has a URLTest group; the reload
#     signature changes only for such a rule;
#  2. the worker against a Clash API double: three failures in a row and
#     only then a switch, marked "auto"; a passed check starts the count
#     again; fresh latency entries are used and cost no test; a group,
#     Direct, and an unreachable API are left alone; the record goes when
#     the user chooses again;
#  3. it starts and stops with the Priority worker, and a rule that no
#     longer asks for it loses its record;
#  4. the stop capture leaves the saved choice of a switched selector;
#  5. the dashboard metadata carries the record.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
GUARD_UC="$LIB/singbox/pin_guard.uc"
W="$(mktemp -d)"
cleanup() {
  local pid
  pid="$(head -n1 "$W/run/pin-guard.pid" 2>/dev/null || true)"
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  rm -rf "$W"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$GUARD_UC" ] || fail "there is no pin guard: a dead server chosen by hand stays selected (singbox/pin_guard.uc is missing)"

# 1. Generation.
links='"vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha",
  "vless://00000000-0000-4000-8000-000000000002@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta"'
fixture() { # name pin_guard with_urltest
  local urltest='[]'
  [ "$3" = 1 ] && urltest='[ { ".name": "cfg_fast", ".type": "urltest", "section": "proxy", "name": "Fastest" } ]'
  cat >"$W/$1.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8" },
  "section": [ { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy",
    "domain_suffix": ["a.example"], $( [ -n "$2" ] && printf '"pin_guard": "%s",' "$2" )
    "selector_proxy_links": [ $links ] } ],
  "urltest": $urltest
}
JSON
}
generate() {
  mkdir -p "$W/$1-config.json.section-cache"
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$W/$1.json" "$W/$1-config.json" 127.0.0.1 \
    >/dev/null 2>"$W/$1.log" || fail "$1 was not generated: $(cat "$W/$1.log")"
  ucode -e 'let c = json(require("fs").readfile(ARGV[0])); print(sprintf("%J", c.pinGuard ?? null));' -- \
    "$W/$1-config.json.section-cache/proxy.json"
}
fixture on 1 1
fixture off 0 1
fixture absent "" 1
fixture nogroup 1 0
guard="$(generate on)"
printf '%s' "$guard" | grep -q '"selector": *"proxy-out"' || fail "the guard does not name the rule's selector: $guard"
fallback="$(ucode -e 'print(json(ARGV[0]).fallback);' -- "$guard")"
case "$fallback" in proxy-*) ;; *) fail "the guard does not fall back to the rule's URLTest group: $guard" ;; esac
ucode -e '
  let c = json(require("fs").readfile(ARGV[0]));
  let sel = null, ut = null;
  for (let o in c.outbounds) { if (o.tag == "proxy-out") sel = o; if (o.tag == ARGV[1]) ut = o; }
  exit(sel && ut && ut.type == "urltest" && index(sel.outbounds, ARGV[1]) >= 0 && json(ARGV[2]).url == ut.url ? 0 : 1);' -- \
  "$W/on-config.json" "$fallback" "$guard" || fail "the fallback is not the selector's URLTest group, or its test URL differs"
[ "$(generate off)" = null ] || fail "pin_guard=0 still asks for the guard"
[ "$(generate absent)" = null ] || fail "the guard is on by default"
[ "$(generate nogroup)" = null ] || fail "a rule without a URLTest group asks for the guard"
cmp -s "$W/on-config.json" "$W/off-config.json" || fail "the guard changes the sing-box configuration itself"
for name in on off absent; do
  ucode -L "$LIB" "$LIB/service/state.uc" reload-state-text-fixture "$W/$name.json" >"$W/state-$name" ||
    fail "no reload state for $name"
done
cmp -s "$W/state-off" "$W/state-absent" || fail "pin_guard=0 changed the signature of a rule that never had it"
ucode -L "$LIB" "$LIB/service/reload.uc" plan-state-files "$W/state-off" "$W/state-on" 0 0 0 0 0 >"$W/plan"
actual="$(awk -F'\t' '$2 == 1 && ($1 ~ /^(changed|needs)_/ || $1 == "has_work") { print $1 }' "$W/plan" | tr '\n' ' ')"
[ "$actual" = "changed_sing_box needs_sing_box_reload has_work " ] ||
  fail "turning the guard on does not plan a sing-box reload (which restarts the workers) and nothing more: $actual"

# 2. The worker, against a Clash API double: proxies.json answers GET
#    /proxies; a delay test answers by probe-plan (P passes, F fails, empty
#    passes) and writes a latency entry as sing-box does; autobump makes a
#    URLTest group test the node on every read; api.down fails every call.
mkdir -p "$W/run/section-cache" "$W/api"
cat >"$W/clash.uc" <<'UC'
let fs = require("fs");
let dir = getenv("PIN_TEST_API");
let args = slice(ARGV, 1);
let log = fs.open(dir + "/calls", "a"); log.write(join(" ", args) + "\n"); log.close();
if (fs.stat(dir + "/api.down") != null) exit(1);
let p = json(fs.readfile(dir + "/proxies.json"));
let n = int(trim(fs.readfile(dir + "/stamp") || "0"));
function save() { fs.writefile(dir + "/proxies.json", sprintf("%J", p)); fs.writefile(dir + "/stamp", "" + n); }
if (args[0] == "get_proxies") {
  for (let tag in split(trim(fs.readfile(dir + "/autobump") || ""), " "))
    if (tag != "") p.proxies[tag].history = [ { time: "t" + (++n), delay: 30 } ];
  save();
  print(sprintf("%J", p));
  exit(0);
}
if (args[0] == "get_proxy_latency") {
  let plan = split(trim(fs.readfile(dir + "/probe-plan") || ""), " ");
  let result = plan[0] || "P";
  fs.writefile(dir + "/probe-plan", join(" ", slice(plan, 1)));
  if (result == "F") { p.proxies[args[1]].history = []; save(); exit(1); }
  p.proxies[args[1]].history = [ { time: "t" + (++n), delay: 40 } ];
  save();
  print('{"delay":40}');
  exit(0);
}
if (args[0] == "set_group_proxy") {
  p.proxies[args[1]].now = args[2];
  save();
  exit(0);
}
exit(1);
UC
printf '{"section":"proxy","pinGuard":%s}\n' "$guard" >"$W/run/section-cache/proxy.json"
export PROKOP_RUNTIME_STATE_DIR="$W/run" PROKOP_DIAGNOSTICS_UC="$W/clash.uc" PIN_TEST_API="$W/api" \
  PROKOP_PIN_GUARD_INTERVAL_MS=1 PROKOP_LIB="$LIB"
EVENTS="$W/run/pin-guard.json"

api() { # now [now-type]
  cat >"$W/api/proxies.json" <<JSON
{"proxies":{
  "proxy-out":{"type":"Selector","now":"$1","all":["$fallback","node-a","node-b","direct-out"]},
  "$fallback":{"type":"URLTest","now":"node-b","all":["node-a","node-b"],"history":[]},
  "node-a":{"type":"VLESS","history":[{"time":"t0","delay":50}]},
  "node-b":{"type":"VLESS","history":[]},
  "direct-out":{"type":"Direct","history":[]}
}}
JSON
  : >"$W/api/calls"
  rm -f "$W/api/probe-plan" "$W/api/autobump" "$W/api/api.down" "$W/api/stamp"
}
run() { PROKOP_PIN_GUARD_CYCLES="$1" ucode -L "$LIB" "$GUARD_UC" worker || fail "the worker failed"; }
now() { ucode -e 'print(json(require("fs").readfile(ARGV[0])).proxies["proxy-out"].now);' -- "$W/api/proxies.json"; }
count() { grep -c "^$1" "$W/api/calls" || true; }

# 2a. A dead server: two failures are not enough, the third switches.
api node-a
printf 'F F F' >"$W/api/probe-plan"
run 2
[ "$(now)" = node-a ] || fail "the guard switched before three failures"
[ ! -e "$EVENTS" ] || fail "a record without a switch"
rm -f "$EVENTS"
api node-a
printf 'F F F' >"$W/api/probe-plan"
run 3
[ "$(now)" = "$fallback" ] || fail "three failed checks in a row did not switch the rule to its URLTest group (now $(now))"
grep -qx "set_group_proxy proxy-out $fallback auto" "$W/api/calls" ||
  fail "the switch is not marked auto, so it would replace the saved choice: $(grep set_group "$W/api/calls")"
[ "$(count get_proxy_latency)" = 3 ] || fail "one delay test per check expected: $(count get_proxy_latency)"
grep -q 'get_proxy_latency node-a 5000 https\?://' "$W/api/calls" || fail "the test does not use the group's URL"
ucode -e '
  let e = json(require("fs").readfile(ARGV[0]))["proxy-out"];
  exit(e.section == "proxy" && e.from == "node-a" && e.to == ARGV[1] && e.time > 0 ? 0 : 1);' -- "$EVENTS" "$fallback" ||
  fail "the switch was not recorded: $(cat "$EVENTS" 2>&1)"

# 2b. The record stays while the selector is where the guard put it, the
#     group is not tested; it goes once the user chooses again.
: >"$W/api/calls"
run 2
[ -e "$EVENTS" ] || fail "the record went while the selector stayed on the group"
[ "$(count get_proxy_latency)" = 0 ] || fail "the guard tested a group"
cp "$EVENTS" "$W/events.saved"
api node-b
run 1
[ ! -e "$EVENTS" ] || fail "the record stayed after the user chose a server again: $(cat "$EVENTS")"

# 2c. A passed check starts the count again.
api node-a
printf 'F F P F F' >"$W/api/probe-plan"
run 5
[ "$(now)" = node-a ] || fail "failures around a passed check were added up"
api node-a
printf 'F F P F F F' >"$W/api/probe-plan"
run 6
[ "$(now)" = "$fallback" ] || fail "three failures after a passed check did not switch"
rm -f "$EVENTS"

# 2d. Fresh latency entries (a URLTest group testing the node) are a passed
#     check and cost no test; only the first check, which has nothing to
#     compare with, tests.
api node-a
printf 'node-a' >"$W/api/autobump"
printf 'F F F F F' >"$W/api/probe-plan"
run 5
[ "$(now)" = node-a ] || fail "a server with fresh passed tests was left"
[ "$(count get_proxy_latency)" = 1 ] || fail "fresh latency entries did not spare the test: $(count get_proxy_latency) tests"

# 2e. A group, Direct and an API that does not answer are left alone.
for selected in "$fallback" direct-out; do
  api "$selected"
  printf 'F F F F' >"$W/api/probe-plan"
  run 4
  [ "$(count get_proxy_latency)" = 0 ] && [ "$(now)" = "$selected" ] || fail "the guard acted on $selected"
done
api node-a
: >"$W/api/api.down"
run 4
[ "$(count get_proxy_latency)" = 0 ] || fail "checks without the Clash API were counted"

# 3. With the Priority worker: start, stop, and the records of rules that no
#    longer ask for it.
api "$fallback"
export PROKOP_PIN_GUARD_INTERVAL_MS=60000
cp "$W/events.saved" "$EVENTS"
ucode -L "$LIB" "$LIB/singbox/priority.uc" start-runtime || fail "the Priority start failed"
pid="$(head -n1 "$W/run/pin-guard.pid" 2>/dev/null || true)"
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || fail "the pin guard did not start with the Priority worker"
[ -e "$EVENTS" ] || fail "a start dropped the record of a rule that still has the guard"
ucode -L "$LIB" "$LIB/singbox/priority.uc" stop-runtime
for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
! kill -0 "$pid" 2>/dev/null || fail "the pin guard did not stop with the Priority worker"
[ ! -e "$W/run/pin-guard.pid" ] || fail "the pid file stayed"
[ -e "$EVENTS" ] || fail "a stop dropped the record the stop capture needs"
printf '{"section":"proxy"}\n' >"$W/run/section-cache/proxy.json"
ucode -L "$LIB" "$LIB/singbox/priority.uc" start-runtime || fail "the Priority start failed without guards"
[ ! -e "$W/run/pin-guard.pid" ] || fail "a pin guard started without a rule asking for it"
[ ! -e "$EVENTS" ] || fail "the record of a rule without the guard stayed"
ucode -L "$LIB" "$LIB/singbox/priority.uc" stop-runtime

# 4. The stop capture: the selector the guard switched keeps the server the
#    user chose as the saved choice; any other selection is kept as before.
unset PROKOP_DIAGNOSTICS_UC
mkdir -p "$W/bin" "$W/etc"
cat >"$W/bin/curl" <<'SH'
#!/bin/sh
for arg in "$@"; do case "$arg" in *127.0.0.1:9090/proxies) cat "$PIN_TEST_API/proxies.json"; exit 0 ;; esac; done
exit 0
SH
chmod +x "$W/bin/curl"
printf 'prokop.settings=settings\n' >"$W/uci-state"
CHOICES="$W/etc/selector-choices.json"
capture() {
  printf '{"proxy-out":"node-a"}\n' >"$CHOICES"
  PATH="$W/bin:$PATH" PROKOP_UCI_STATE_FILE="$W/uci-state" PROKOP_SELECTOR_CHOICES_FILE="$CHOICES" \
    ucode -L "$LIB" "$LIB/service/lifecycle.uc" selector-capture-fixture >/dev/null 2>&1
  ucode -e 'print(json(require("fs").readfile(ARGV[0]))["proxy-out"]);' -- "$CHOICES"
}
api "$fallback"
rm -rf "$W/run/section-cache"
cp "$W/events.saved" "$EVENTS"
[ "$(capture)" = node-a ] || fail "the stop capture replaced the user's choice with the guard's switch"
rm -f "$EVENTS"
[ "$(capture)" = "$fallback" ] || fail "a group the user chose is no longer kept at a stop"

# 5. The dashboard reads the record (read-only, no secrets: tags and a time).
cp "$W/events.saved" "$EVENTS"
PATH="$W/bin:$PATH" PROKOP_UCI_STATE_FILE="$W/uci-state" \
  ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" get-dashboard-runtime-metadata >"$W/meta.json" ||
  fail "no dashboard metadata"
ucode -e '
  let e = json(require("fs").readfile(ARGV[0])).pinGuardEvents["proxy-out"];
  exit(e && e.from == "node-a" && e.to == ARGV[1] && e.time > 0 ? 0 : 1);' -- "$W/meta.json" "$fallback" ||
  fail "the dashboard metadata does not carry the switch: $(cat "$W/meta.json")"

printf 'pin_guard: OK\n'
