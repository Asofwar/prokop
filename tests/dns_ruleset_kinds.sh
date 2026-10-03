#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
GENERATOR_UC="$PROKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# sing-box 1.14 refuses to use an address rule-set as a DNS query filter: the
# addresses only exist once the answer is known, so such a set has to be
# evaluated against the response. Below 1.14 there is no response matching at
# all, so both kinds must collapse back into the single query rule this fork
# has always emitted - that backward compatibility is the point of the test.

# 1. Classification of the built-in lists.
# These modules only return their exports when loaded from a file, so the
# probes are written out instead of passed with -e.
cat >"$WORK_DIR/kinds.uc" <<'UC'
let rs = require("singbox.rulesets");
for (let name in [ "discord", "telegram", "cloudflare", "meta", "twitter", "roblox" ])
    if (rs.community_kind(name) != "mixed") {
        warn(name + " must be classified as mixed, got " + rs.community_kind(name));
        exit(1);
    }
for (let name in [ "russia_inside", "youtube", "porn", "news", "anime" ])
    if (rs.community_kind(name) != "domains") {
        warn(name + " must stay a domain list, got " + rs.community_kind(name));
        exit(1);
    }
if (rs.community_kind("not-a-list") != "unknown")
    exit(1);
UC
ucode -L "$PROKOP_LIB" "$WORK_DIR/kinds.uc" ||
  fail "community lists must be classified as domain-only or mixed"

# 2. Address detection inside a local rule-set file.
printf '%s\n' '{"version":1,"rules":[{"domain_suffix":["example.com"]}]}' >"$WORK_DIR/domains.json"
printf '%s\n' '{"version":1,"rules":[{"ip_cidr":["203.0.113.0/24"]}]}' >"$WORK_DIR/addresses.json"
printf '%s\n' '{"version":1,"rules":[{"domain_suffix":["example.com"],"ip_cidr":["203.0.113.0/24"]}]}' >"$WORK_DIR/mixed.json"
printf '%s\n' '{"version":1,"rules":[{"ip_cidr":[]}]}' >"$WORK_DIR/empty-ip.json"

cat >"$WORK_DIR/matchers.uc" <<UC
let rs = require("routing.rulesets");
let base = "$WORK_DIR";
if (rs.has_ip_matchers(base + "/domains.json")) exit(1);
if (!rs.has_ip_matchers(base + "/addresses.json")) exit(1);
if (!rs.has_ip_matchers(base + "/mixed.json")) exit(1);
if (rs.has_ip_matchers(base + "/empty-ip.json")) exit(1);
if (!rs.has_domain_matchers(base + "/mixed.json")) exit(1);
UC
ucode -L "$PROKOP_LIB" "$WORK_DIR/matchers.uc" ||
  fail "address matchers must be detected inside a rule-set file"

# 3. The generator contract: the split exists and is gated on the runtime flag.
awk '
  /^function add_section_ruleset_dns_rules\(/ { inside = 1 }
  inside && /if \(!runtime_supports_dns_response_matching\)/ { gate = NR }
  inside && /append_unique_tags\(query_tags, response_tags\)/ { merge = NR }
  inside && /add_response_ruleset_dns_rule\(/ { response = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && gate && merge && response && merge > gate && response > merge ? 0 : 1 }
' "$GENERATOR_UC" || fail "below 1.14 both kinds must merge back into the single query rule"

awk '
  /^function add_response_ruleset_dns_rule\(/ { inside = 1 }
  inside && /action = "evaluate"/ { evaluate = NR }
  inside && /match_response: true/ { match_response = NR }
  inside && /action = "route"/ { route = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && evaluate && match_response && route && evaluate < match_response ? 0 : 1 }
' "$GENERATOR_UC" || fail "a response rule must evaluate first, then route on match_response"

# 4. No caller may keep the old single-list shape.
if grep -Fq 'dns_rule_set_tags' "$GENERATOR_UC"; then
  fail "every DNS rule-set caller must use the query/response pair"
fi
grep -Fq 'dns_tags_for_ruleset_kind(ensured.kind, dns_query_rule_set_tags, dns_response_rule_set_tags' "$GENERATOR_UC" ||
  fail "rule-set tags must be routed by kind"

# 5. Below 1.14 the pre-existing behaviour differed by source, and both halves
#    must be preserved: a community list always joined the DNS rule, a custom
#    rule-set only when it carried domains. Collapsing that into one rule once
#    added eight address-only sets to the DNS rules of a live configuration.
awk '
  /^function dns_tags_for_ruleset_kind\(/ { inside = 1 }
  inside && /if \(as_string\(kind\) == "domains"\)/ { domains = NR }
  inside && /if \(runtime_supports_dns_response_matching\)/ { modern = NR }
  inside && /return legacy_always \? query_tags : null;/ { legacy = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && domains && modern && legacy && domains < modern && modern < legacy ? 0 : 1 }
' "$GENERATOR_UC" || fail "the pre-1.14 placement must depend on where the rule-set came from"

grep -Fq 'dns_response_rule_set_tags, true), ensured.tag);' "$GENERATOR_UC" ||
  fail "community lists must keep joining the DNS rule below 1.14"
grep -Fq 'dns_response_rule_set_tags, false);' "$GENERATOR_UC" ||
  fail "custom rule-sets must stay out of the DNS rules below 1.14 unless they carry domains"

# 6. Local domain+ip lists only take the response path when the runtime has it.
awk '
  /^function add_domain_ip_list_ruleset\(/ { inside = 1 }
  inside && /runtime_supports_dns_response_matching && has_addresses/ { gated = NR }
  inside && /else if \(has_domains\)/ { fallback = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && gated && fallback && fallback > gated ? 0 : 1 }
' "$GENERATOR_UC" || fail "a local list with addresses must use the response path only on 1.14"

printf 'dns ruleset kind checks passed\n'
