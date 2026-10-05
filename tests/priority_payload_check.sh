#!/usr/bin/env bash
set -eo pipefail

# C15: a priority group can count a node as working only when a real HTTPS
# download through it completes ("the handshake works but no data flows").
#   - with payload_check, the generator adds a probe selector with the
#     group's nodes and a mixed inbound on the loopback address routed to
#     it; the priority worker points the probe selector at the node under
#     test, so live traffic never moves; without it nothing is added;
#   - the worker downloads through the probe inbound and wants the whole
#     payload with a 2xx status;
#   - a node whose download failed is quarantined for 60 s, a node that
#     passed is not downloaded again for 180 s, the delay check runs as
#     before;
#   - the generated configuration passes a real sing-box check when
#     PROKOP_TEST_SING_BOX names a binary.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
GENERATOR_UC="$PROKOP_LIB/singbox/generator.uc"
PRIORITY_UC="$PROKOP_LIB/singbox/priority.uc"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/logger"
export PATH="$WORK_DIR/bin:$PATH"

fixture() {
  cat <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn" },
  "section": [ { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy",
    "selector_proxy_links": [
      "vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha",
      "vless://00000000-0000-4000-8000-000000000002@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta"
    ] } ],
  "priority_group": [
    { ".name": "pg_main", ".type": "priority_group", "section": "proxy", "name": "Main", "payload_check": "$1" },
    { ".name": "pg_other", ".type": "priority_group", "section": "proxy", "name": "Other" }
  ],
  "priority_level": [
    { ".name": "pl_main", ".type": "priority_level", "group": "pg_main", "name": "All", "order": "0", "regex": [ "Alpha|Beta" ] },
    { ".name": "pl_other", ".type": "priority_level", "group": "pg_other", "name": "All", "order": "0", "regex": [ "Beta" ] }
  ]
}
JSON
}

generate() {
  fixture "$1" >"$WORK_DIR/fixture-$1.json"
  mkdir -p "$WORK_DIR/config-$1.json.section-cache"
  ucode -L "$PROKOP_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/fixture-$1.json" "$WORK_DIR/config-$1.json" "127.0.0.1" >"$WORK_DIR/generate.log" 2>&1 ||
    fail "generation failed: $(cat "$WORK_DIR/generate.log")"
}

# 1. The probe path of a group that checks payload.
generate 1
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
function fail(message) { die(message + "\n"); }
function find(list, fn) { for (let item in list || []) if (fn(item)) return item; return null; }
let main = find(config.outbounds, (o) => o.tag == "proxy-priority-pg_main-out");
let probe = find(config.outbounds, (o) => o.tag == "proxy-priority-pg_main-out-probe");
if (!probe || probe.type != "selector" || sprintf("%J", probe.outbounds) != sprintf("%J", main.outbounds))
    fail("the probe selector must hold the nodes of the group: " + sprintf("%J", probe));
if (find(config.outbounds, (o) => o.tag == "proxy-priority-pg_other-out-probe"))
    fail("a group without payload_check got a probe selector");
let inbound = find(config.inbounds, (i) => i.listen_port == 4580);
if (!inbound || inbound.type != "mixed" || inbound.listen != "127.0.0.1")
    fail("the probe inbound must be a mixed inbound on 127.0.0.1:4580: " + sprintf("%J", inbound));
let rule = find(config.route.rules, (r) => r.inbound == inbound.tag);
if (!rule || rule.outbound != probe.tag)
    fail("the probe inbound must route to the probe selector: " + sprintf("%J", rule));
let groups = cache.priorityGroups || {};
let cached = groups["proxy-priority-pg_main-out"] || {};
if (cached.payload_check !== true || cached.probe_tag != probe.tag || cached.probe_port != 4580)
    fail("the priority worker does not learn the probe: " + sprintf("%J", cached));
if ((groups["proxy-priority-pg_other-out"] || {}).payload_check !== false)
    fail("a group without payload_check is marked as checking payload");
' "$WORK_DIR/config-1.json" "$WORK_DIR/config-1.json.section-cache/proxy.json" || fail "probe path generation"

# 2. Without payload_check nothing is added.
generate 0
if grep -q -- '-probe' "$WORK_DIR/config-0.json"; then fail "a probe was generated without payload_check"; fi
if grep -q '"listen_port": 4580' "$WORK_DIR/config-0.json"; then fail "a probe inbound was generated without payload_check"; fi

if [ -n "${PROKOP_TEST_SING_BOX:-}" ]; then
  "$PROKOP_TEST_SING_BOX" check -c "$WORK_DIR/config-1.json" >"$WORK_DIR/check.log" 2>&1 ||
    fail "sing-box rejects the configuration with a probe: $(cat "$WORK_DIR/check.log")"
fi

# 3. The download: through the probe inbound, after pointing the probe
#    selector at the node, the whole payload with a 2xx status.
cat >"$WORK_DIR/clash.uc" <<'UC'
system("printf '%s\\n' '" + join(" ", ARGV) + "' >>" + getenv("CLASH_LOG"));
exit(0);
UC
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CURL_LOG"
printf '%s' "$CURL_ANSWER"
SH
chmod +x "$WORK_DIR/bin/curl"
printf '{"tag":"g","payload_check":true,"probe_tag":"g-probe","probe_port":4580,"levels":[{"outbounds":["a"]}]}\n' >"$WORK_DIR/group.json"
transfer() {
  : >"$WORK_DIR/clash.log"
  : >"$WORK_DIR/curl.log"
  CLASH_LOG="$WORK_DIR/clash.log" CURL_LOG="$WORK_DIR/curl.log" CURL_ANSWER="$1" \
    PROKOP_DIAGNOSTICS_UC="$WORK_DIR/clash.uc" \
    ucode -L "$PROKOP_LIB" "$PRIORITY_UC" payload-transfer-fixture "$WORK_DIR/group.json" a
}
transfer "200 32768" || fail "a complete download failed the payload check"
grep -qx 'clash-api set_group_proxy g-probe a auto' "$WORK_DIR/clash.log" ||
  fail "the probe selector was not pointed at the node: $(cat "$WORK_DIR/clash.log")"
grep -q -- '-x http://127.0.0.1:4580 https://speed.cloudflare.com/__down?bytes=32768' "$WORK_DIR/curl.log" ||
  fail "the download did not go through the probe inbound: $(cat "$WORK_DIR/curl.log")"
if transfer "200 1000"; then fail "a short download passed the payload check"; fi
if transfer "403 32768"; then fail "an error status passed the payload check"; fi
if transfer ""; then fail "a failed request passed the payload check"; fi

# 4. Quarantine and recheck (a scenario of selection rounds).
cat >"$WORK_DIR/scenario.json" <<'JSON'
{"group":{"tag":"g","payload_check":true,"probe_tag":"g-probe","probe_port":4580,
 "levels":[{"outbounds":["a","b"]},{"outbounds":["c"]}]},
 "latencies":{"a":100,"b":200,"c":50},
 "payload":{"a":false,"b":true,"c":true},
 "rounds":[{"now":0},{"now":10},{"now":70},{"now":100,"skip":"b"},{"now":200}]}
JSON
rounds="$(ucode -L "$PROKOP_LIB" "$PRIORITY_UC" payload-fixture "$WORK_DIR/scenario.json")"
expected='[ { "selected": "b", "downloads": [ "a", "b" ], "quarantined": [ "a" ] }, { "selected": "b", "downloads": [ ], "quarantined": [ "a" ] }, { "selected": "b", "downloads": [ "a" ], "quarantined": [ "a" ] }, { "selected": "c", "downloads": [ "c" ], "quarantined": [ "a" ] }, { "selected": "b", "downloads": [ "a", "b" ], "quarantined": [ "a" ] } ]'
[ "$rounds" = "$expected" ] || fail "payload check rounds differ:
$rounds"

# A group without payload_check downloads nothing.
sed 's/"payload_check":true/"payload_check":false/' "$WORK_DIR/scenario.json" >"$WORK_DIR/plain.json"
case "$(ucode -L "$PROKOP_LIB" "$PRIORITY_UC" payload-fixture "$WORK_DIR/plain.json")" in
  *'"downloads": [ "'*) fail "a group without payload_check downloaded" ;;
esac

printf 'OK: priority payload check\n'
