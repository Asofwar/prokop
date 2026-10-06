#!/usr/bin/env bash
# A device excluded from a section that uses address rule sets (telegram,
# cloudflare, ...) must not leave a DNS rule without conditions: sing-box
# rejects such a config ("parse dns rule[N]: missing conditions"), the reload
# aborts and the exclusion never reaches the router.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name":"settings", ".type":"settings", "dns_server":"77.88.8.8" },
  "section": [
    {
      ".name":"main", ".type":"section", "enabled":"1", "action":"connection",
      "outbound_jsons":["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain":"tradingview.com\nbybit.com", "ip_cidr":"38.180.248.185",
      "community_lists":["russia_inside","telegram","cloudflare"],
      "excluded_source_ip_cidr":["192.168.1.233"]
    }
  ]
}
JSON

for version in 1.13.0 1.14.0; do
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 192.168.1.1 0 1 '' "$version"
  ucode -e '
    let c = json(require("fs").readfile(ARGV[0]));
    let version = ARGV[1];
    let not_conditions = { action: true, server: true, outbound: true, rewrite_ttl: true,
      strategy: true, invert: true, type: true, mode: true };
    function check(value, message) { if (!value) die(sprintf("FAIL (%s): %s\n", version, message)); }
    function has_conditions(rule) {
      if (rule.type == "logical") {
        if (length(rule.rules || []) == 0) return false;
        for (let child in rule.rules) if (!has_conditions(child)) return false;
        return true;
      }
      for (let key in keys(rule)) if (!not_conditions[key]) return true;
      return false;
    }
    function excludes(rule) {
      if (rule.invert && index(sprintf("%J", rule.source_ip_cidr), "192.168.1.233") >= 0) return true;
      for (let child in rule.rules || []) if (excludes(child)) return true;
      return false;
    }
    let evaluate = 0;
    for (let i = 0; i < length(c.dns.rules); i++) {
      let rule = c.dns.rules[i];
      check(has_conditions(rule), sprintf("dns rule[%d] has no conditions: %J", i, rule));
      if (rule.action == "evaluate") {
        evaluate++;
        check(excludes(rule), "the evaluate step must skip the excluded device");
        check(rule.type != "logical", "an evaluate step without matchers must not be wrapped");
      }
      if (rule.server == "fakeip-server" && index(sprintf("%J", rule), "fakeip.podkop.fyi") < 0)
        check(excludes(rule), sprintf("FakeIP rule must exclude the device: %J", rule));
    }
    for (let i = 0; i < length(c.route.rules); i++)
      check(has_conditions(c.route.rules[i]), sprintf("route rule[%d] has no conditions", i));
    if (version == "1.14.0")
      check(evaluate == 1, "sing-box 1.14 must evaluate the answer before response rule sets");
  ' "$WORK_DIR/config.json" "$version"
done

printf 'Excluded device DNS rule checks passed\n'
