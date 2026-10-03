#!/usr/bin/env bash
set -euo pipefail

# Legacy rule options (UC-042, UC-043): the validator must reach the verdict
# the sing-box generator reaches for the same rule, so that a configuration
# the generator accepts is not refused, and one the generator refuses is
# refused before apply with a message that names the fix.
# - A DNS rule whose only domain source is remote_domain_lists: the generator
#   uses the lists (rule sets / the materialized list), so it is accepted.
# - remote_subnet_lists never feed DNS rules: a DNS rule with only them is
#   refused by both.
# - local_domain_lists, local_subnet_lists, subnet, subnet_text: the generator
#   refuses the rule ("unsupported matcher"); the validator refuses it too.
# - Text mode (<key>_text_mode, conditions_text_mode): domains are read from
#   the *_text options and the lists are ignored, as routing/rule_conditions.uc
#   reads them for the generator.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

SETTINGS='{ ".name": "settings", ".type": "settings", "log_level": "warn",
  "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret" }'
DNS='"action": "dns", "dns_type": "udp", "dns_server": "1.1.1.1"'

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

fixture() {
  local name="$1"
  shift
  local IFS=,
  printf '{ "settings": %s, "section": [ %s ] }\n' "$SETTINGS" "$*" >"$WORK/$name.json"
}

rule() {
  printf '{ ".name": "%s", ".type": "section", "enabled": "1", %s }' "$1" "$2"
}

generator_accepts() {
  mkdir -p "$WORK/$1.out.section-cache"
  TMP_SUBSCRIPTION_FOLDER="$WORK/subs" ucode -L "$LIB" "$LIB/singbox/generator.uc" \
    generate-config-fixture "$WORK/$1.json" "$WORK/$1.out" 127.0.0.1 0 >/dev/null 2>"$WORK/$1.gen"
}

validator_accepts() {
  PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/validator.uc" \
    validate-runtime-fixture "$WORK/$1.json" '{}' >"$WORK/$1.val" 2>&1
}

# expect <fixture> accept|reject [validator message regex]
expect() {
  local name="$1" verdict="$2" message="${3:-}" generator=reject validator=reject
  generator_accepts "$name" && generator=accept
  validator_accepts "$name" && validator=accept
  [ "$generator" = "$verdict" ] ||
    fail "$name: generator should $verdict ($(cat "$WORK/$name.gen"))"
  [ "$validator" = "$verdict" ] ||
    fail "$name: validator should $verdict like the generator ($(cat "$WORK/$name.val"))"
  if [ -n "$message" ] && ! grep -Eq "$message" "$WORK/$name.val"; then
    fail "$name: validator message should match /$message/ ($(cat "$WORK/$name.val"))"
  fi
}

# DNS rule with legacy remote domain lists only: a sing-box rule set ...
fixture dns_remote_srs "$(rule d "$DNS, \"remote_domain_lists\": [\"https://example.com/domains.srs\"]")"
expect dns_remote_srs accept
# ... and a plain list the list update materialized for the rule.
fixture dns_remote_plain "$(rule d "$DNS, \"remote_domain_lists\": [\"https://example.com/domains.lst\"]")"
mkdir -p "$WORK/dns_remote_plain.out.rulesets"
printf '{ "version": 3, "rules": [ { "domain_suffix": [ "example.org" ] } ] }\n' \
  >"$WORK/dns_remote_plain.out.rulesets/d-remote-domains-ruleset.json"
expect dns_remote_plain accept
# Remote subnet lists do not feed DNS rules.
fixture dns_remote_subnets "$(rule d "$DNS, \"remote_subnet_lists\": [\"https://example.com/subnets.srs\"]")"
expect dns_remote_subnets reject 'at least one domain condition'

# Unsupported podkop-era matchers, whatever else the rule matches.
for key in local_domain_lists local_subnet_lists subnet_text; do
  fixture "unsupported_$key" "$(rule b "\"action\": \"block\", \"domain\": \"example.com\", \"$key\": [\"/etc/prokop/list.lst\"]")"
  expect "unsupported_$key" reject "legacy option '$key'.*no longer supported.*Remove it"
done
fixture unsupported_subnet "$(rule c "\"action\": \"bypass\", \"ip_cidr\": \"10.0.0.0/8\", \"subnet\": \"192.168.0.0/16\"")"
expect unsupported_subnet reject "legacy option 'subnet'"
fixture unsupported_dns "$(rule d "$DNS, \"domain\": \"example.com\", \"local_domain_lists\": \"/etc/prokop/list.lst\"")"
expect unsupported_dns reject "legacy option 'local_domain_lists'"
# A disabled rule is not generated and not validated.
fixture unsupported_disabled \
  "$(rule b "\"action\": \"block\", \"domain\": \"example.com\"")" \
  "{ \".name\": \"off\", \".type\": \"section\", \"enabled\": \"0\", \"action\": \"block\", \"domain\": \"example.net\", \"local_domain_lists\": [\"/etc/prokop/list.lst\"] }"
expect unsupported_disabled accept

# Text mode: the list is ignored and the text is read.
fixture dns_text_mode_list_only "$(rule d "$DNS, \"domain_keyword\": [\"video\"], \"domain_keyword_text_mode\": \"1\"")"
expect dns_text_mode_list_only reject 'at least one domain condition'
fixture dns_text_mode_text "$(rule d "$DNS, \"domain_keyword\": [\"video\"], \"domain_keyword_text\": \"music\", \"domain_keyword_text_mode\": \"1\"")"
expect dns_text_mode_text accept
fixture dns_all_text_mode "$(rule d "$DNS, \"domain_regex\": [\"^a\"], \"conditions_text_mode\": \"true\"")"
expect dns_all_text_mode reject 'at least one domain condition'
fixture dns_all_text_mode_text "$(rule d "$DNS, \"domain_text\": \"exact.example\", \"conditions_text_mode\": \"1\"")"
expect dns_all_text_mode_text accept
# Without text mode a list shadows its *_text option, and a text option alone is used.
fixture dns_list_over_text "$(rule d "$DNS, \"domain_keyword\": [\"video\"], \"domain_keyword_text\": \"music\"")"
expect dns_list_over_text accept
fixture dns_text_fallback "$(rule d "$DNS, \"domain_regex_text\": \"^video\"")"
expect dns_text_fallback accept
# A legacy value the domain normalizer drops leaves no condition.
fixture dns_invalid_keyword "$(rule d "$DNS, \"domain_keyword\": [\"two words\"]")"
expect dns_invalid_keyword reject 'at least one domain condition'

if [ "$failures" -ne 0 ]; then
  printf '%d legacy option verdict(s) differ\n' "$failures" >&2
  exit 1
fi
printf 'validator and generator agree on legacy rule options\n'
