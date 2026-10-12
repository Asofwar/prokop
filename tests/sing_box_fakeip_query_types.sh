#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
GENERATOR="$PROKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The FakeIP server only synthesises addresses: sing-box answers any other
# record type with an error, which the client sees as SERVFAIL. Every DNS rule
# that sends a query to it must therefore be limited to A and AAAA, so TXT,
# MX, SRV and the rest of a proxied domain still reach a real resolver.
# Covered: the test domains, plain and per-device proxy sections, a bypass
# section without devices, community lists and rule-sets (query and 1.14
# response rules), and device exclusions that turn a rule into a logical one.

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "plain_bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "plain-bypass.example" ]
    },
    {
      ".name": "source_bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "source-bypass.example" ],
      "source_ip_cidr": [ "192.0.2.20/32" ],
      "fully_routed_ips": [ "192.0.2.21" ]
    },
    {
      ".name": "vpn",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "domain_suffix": [ "vpn.example" ],
      "community_lists": [ "discord", "telegram", "youtube" ],
      "rule_set": [ "discord" ],
      "excluded_source_ip_cidr": [ "192.0.2.50" ]
    },
    {
      ".name": "per_device",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "domain_suffix": [ "device.example" ],
      "community_lists": [ "discord", "meta" ],
      "source_ip_cidr": [ "192.0.2.30/32" ],
      "fully_routed_ips": [ "192.0.2.31" ]
    }
  ]
}
JSON

generate() {
  local version="$1"
  local output="$WORK_DIR/config-$version.json"
  mkdir -p "$output.section-cache" "$output.rulesets"
  ucode -L "$PROKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1" "" "$version" >/dev/null
}

for version in 1.12.25 1.13.18 1.14.0; do
  generate "$version"
done

FAKEIP_WORK_DIR="$WORK_DIR" ucode -e '
let fs = require("fs");

function config(version) { return json(fs.readfile(getenv("FAKEIP_WORK_DIR") + "/config-" + version + ".json")); }
function assert(ok, message) { if (!ok) { warn(message, "\n"); exit(1); } }
function only_address_types(value) {
    if (type(value) != "array" || length(value) == 0) return false;
    for (let item in value) if (item != "A" && item != "AAAA") return false;
    return true;
}
// The rule itself, or a child of an "and" rule, must carry the restriction.
function limited_to_addresses(rule) {
    if (only_address_types(rule.query_type)) return true;
    if (rule.type == "logical" && rule.mode == "and")
        for (let child in rule.rules || []) if (only_address_types(child.query_type)) return true;
    return false;
}
function matches_response(rule) {
    if (rule.match_response === true) return true;
    for (let child in rule.rules || []) if (matches_response(child)) return true;
    return false;
}
for (let version in [ "1.12.25", "1.13.18", "1.14.0" ]) {
    let rules = config(version).dns.rules || [];
    let fakeip = 0;
    for (let rule in rules) {
        if (rule.server != "fakeip-server") continue;
        fakeip++;
        assert(limited_to_addresses(rule),
            version + ": a rule routes to FakeIP without query_type A/AAAA: " + sprintf("%J", rule));
    }
    assert(fakeip >= 6, version + ": expected the FakeIP rules of every section, got " + fakeip);
    let https = null;
    for (let rule in rules) if (rule.action == "reject" && rule.query_type == "HTTPS") { https = rule; break; }
    assert(https != null, version + ": HTTPS queries must still be rejected");
}

// The 1.14 response rules (evaluate, then route on match_response) are
// covered too: the route half is the one that reaches FakeIP.
let response_rules = 0;
for (let rule in config("1.14.0").dns.rules || [])
    if (rule.server == "fakeip-server" && matches_response(rule)) response_rules++;
assert(response_rules >= 2, "1.14: expected FakeIP response rules for the mixed lists, got " + response_rules);
' || fail "every DNS rule that reaches FakeIP must be limited to A/AAAA"

SING_BOX="${PROKOP_TEST_SING_BOX:-}"
if [ -n "$SING_BOX" ] && [ -x "$SING_BOX" ]; then
  # Remote rule-sets are not downloaded by check; keep the config otherwise as generated.
  "$SING_BOX" check -c "$WORK_DIR/config-1.14.0.json" ||
    fail "sing-box check rejected the generated 1.14 config"
  printf 'sing-box check passed for the generated 1.14 config\n'
fi

printf 'FakeIP query type checks passed\n'
