#!/usr/bin/env bash
# nft/apply.uc parses the text lists of a rule with the parser of
# config/rule.uc, the one the validator and the sing-box rules use: the
# subnets nft puts into a rule's sets are the subnets sing-box expects for
# that rule (UC-182).
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
NFT_APPLY="$PROKOP_LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export PROKOP_NFT_SUBNET_CACHE_DIR="$WORK_DIR/nft-subnet-cache"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=tests/helpers/source_checks.sh
source "$ROOT_DIR/tests/helpers/source_checks.sh"

source_refute "nft/apply.uc must use the list parser of config/rule.uc" \
  -E 'function (strip_list_comment|text_list_values|normalize_domain_subnet_value|filter_domain_subnet_values)\(' "$NFT_APPLY"

# Separators, comments, CRLF, blanks, IPv6 and values that are not subnets.
text=$'198.51.100.7, 203.0.113.0/24 # office\r\n2001:db8::7 // v6\n\n  not-an-ip 198.51.100.300\n192.0.2.1,,192.0.2.0/30 2001:db8:1::/48\n# 192.0.2.99\nexample.com'

# The subnets the rule parser accepts, all and by family.
TEXT="$text" ucode -L "$PROKOP_LIB" -e '
let rule = require("config.rule");
let all = rule.filter_domain_subnet_values(rule.text_list_values(getenv("TEXT"), "comma-space"), "subnets");
let v4 = [], v6 = [];
for (let value in all)
    push(index(value, ":") >= 0 ? v6 : v4, value);
print(join(",", all), "\n", join(",", v4), "\n", join(",", v6), "\n", join(",", rule.text_list_values(getenv("TEXT"), "comma")), "\n");
' >"$WORK_DIR/expected.txt"
{ read -r expected_all; read -r expected_v4; read -r expected_v6; read -r expected_comma; } <"$WORK_DIR/expected.txt"
[ "$expected_v4" = "198.51.100.7,203.0.113.0/24,192.0.2.1,192.0.2.0/30" ] ||
  fail "unexpected IPv4 subnets of the rule parser: $expected_v4"
[ "$expected_v6" = "2001:db8::7,2001:db8:1::/48" ] ||
  fail "unexpected IPv6 subnets of the rule parser: $expected_v6"

# The CSV modes of nft/apply.uc.
[ "$(ucode -L "$PROKOP_LIB" "$NFT_APPLY" domain-subnet-text-csv "$text" subnets)" = "$expected_all" ] ||
  fail "domain-subnet-text-csv differs from the rule parser"
[ "$(ucode -L "$PROKOP_LIB" "$NFT_APPLY" text-list-to-csv "$text" comma)" = "$expected_comma" ] ||
  fail "text-list-to-csv differs from the rule parser"

# The elements nft/apply.uc adds to the rule's sets.
TEXT="$text" ucode -e 'print(sprintf("%J", { section: [ {
    ".name": "parity", ".type": "section", enabled: "1", action: "connection",
    ip_cidr_text_mode: "1", ip_cidr_text: getenv("TEXT")
} ] }), "\n");' >"$WORK_DIR/fixture.json"
batch="$WORK_DIR/batch.nft"
: >"$batch"
PROKOP_NFT_BATCH_FILE="$batch" ucode -L "$PROKOP_LIB" "$NFT_APPLY" nft-populate-runtime-sets-fixture \
  "$WORK_DIR/fixture.json" 1 "" ProkopTable prokop_subnets prokop_ports prokop_ip_ports prokop_interfaces localv4 0x00100000 ||
  fail "populating the rule's sets failed"
grep -Fqx "add element inet ProkopTable prokop_rule_parity_subnets { $expected_v4 }" "$batch" ||
  fail "the IPv4 set of the rule differs from the rule parser: $(cat "$batch")"
grep -Fqx "add element inet ProkopTable prokop_rule_parity_subnets6 { $expected_v6 }" "$batch" ||
  fail "the IPv6 set of the rule differs from the rule parser: $(cat "$batch")"

printf 'nft list parser parity checks passed\n'
