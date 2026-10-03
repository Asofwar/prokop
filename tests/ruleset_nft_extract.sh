#!/usr/bin/env bash
# Which addresses of a JSON rule-set nft may decide before sing-box
# (routing/rulesets.uc extract-ip-cidr-nft, used for the priority sets of
# rule_set_with_subnets). A bypass section accepts them without sing-box, so
# only addresses a rule matches by destination alone (with an optional port
# constraint) may be taken: never the addresses of an inverted rule, of an
# AND that also needs a domain or another address, or of a rule limited by
# network, source or process (UC-101). A missing fast path is safe: sing-box
# still applies the section's rule.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# extract RULESET_JSON [PORTS_JSON] [PORT_RANGES_JSON]: unscoped lines, a
# "--" line, scoped lines.
extract() {
  printf '%s\n' "$1" >"$WORK_DIR/rules.json"
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/routing/rulesets.uc" extract-ip-cidr-nft "$WORK_DIR/rules.json" \
    "$WORK_DIR/unscoped" "$WORK_DIR/scoped" "${2:-[]}" "${3:-[]}" || fail "extract-ip-cidr-nft failed for $1"
  cat "$WORK_DIR/unscoped"
  printf -- '--\n'
  cat "$WORK_DIR/scoped"
}

expect() {
  local label="$1" want="$2" got
  shift 2
  got="$(extract "$@")"
  [ "$got" = "$want" ] || fail "$label: expected
$want
got
$got"
  printf 'ok - %s\n' "$label"
}

# Still extracted: destination-only rules, their ports, an OR of them, an AND
# of one address rule with port rules, a rule whose domains are an
# alternative to its addresses.
expect "plain address rules" $'1.1.1.0/24\n2001:db8::/32\n--\n2.2.2.0/24 . 443' \
  '{"version":3,"rules":[{"ip_cidr":["1.1.1.0/24","2001:db8::/32"]},{"ip_cidr":["2.2.2.0/24"],"port":[443]}]}'
expect "domains are an alternative within one rule" $'3.3.3.0/24\n--' \
  '{"version":3,"rules":[{"domain_suffix":["example.com"],"ip_cidr":["3.3.3.0/24"],"invert":false}]}'
expect "OR of address rules" $'4.4.4.0/24\n--\n5.5.5.0/24 . 80' \
  '{"version":3,"rules":[{"type":"logical","mode":"or","rules":[{"ip_cidr":["4.4.4.0/24"]},{"ip_cidr":["5.5.5.0/24"],"port":[80]}]}]}'
expect "AND of an address rule and a port rule" $'--\n6.6.6.0/24 . 1000-1002' \
  '{"version":3,"rules":[{"type":"logical","mode":"and","rules":[{"ip_cidr":["6.6.6.0/24"]},{"port_range":["1000:1002"]}]}]}'
expect "section ports intersect rule ports" $'--\n2.2.2.0/24 . 443\n7.7.7.0/24 . 443\n7.7.7.0/24 . 8443' \
  '{"version":3,"rules":[{"ip_cidr":["2.2.2.0/24"],"port":[443,22]},{"ip_cidr":["7.7.7.0/24"]}]}' '[443,8443]'

# Never extracted.
expect "inverted rule" $'--' \
  '{"version":3,"rules":[{"ip_cidr":["1.2.3.0/24"],"invert":true}]}'
expect "inverted logical rule" $'--' \
  '{"version":3,"rules":[{"type":"logical","mode":"or","invert":true,"rules":[{"ip_cidr":["1.2.4.0/24"]}]}]}'
expect "AND with a domain" $'--' \
  '{"version":3,"rules":[{"type":"logical","mode":"and","rules":[{"domain_suffix":["only.example"]},{"ip_cidr":["5.6.7.0/24"]}]}]}'
expect "AND of two address rules" $'--' \
  '{"version":3,"rules":[{"type":"logical","mode":"and","rules":[{"ip_cidr":["10.1.0.0/16"]},{"ip_cidr":["10.1.2.0/24"]}]}]}'
expect "AND with an inverted child" $'--' \
  '{"version":3,"rules":[{"type":"logical","mode":"and","rules":[{"ip_cidr":["5.6.8.0/24"]},{"port":[443],"invert":true}]}]}'
expect "AND with a nested logical rule" $'--' \
  '{"version":3,"rules":[{"type":"logical","mode":"and","rules":[{"ip_cidr":["5.6.9.0/24"]},{"type":"logical","mode":"or","rules":[{"port":[443]}]}]}]}'
expect "network limit" $'--' \
  '{"version":3,"rules":[{"ip_cidr":["9.9.9.0/24"],"network":["udp"]}]}'
expect "source limit" $'--' \
  '{"version":3,"rules":[{"ip_cidr":["8.8.8.0/24"],"source_ip_cidr":["192.168.1.50/32"]}]}'
expect "source port limit" $'--' \
  '{"version":3,"rules":[{"ip_cidr":["8.8.4.0/24"],"source_port":[5000]}]}'
expect "process limit" $'--' \
  '{"version":3,"rules":[{"ip_cidr":["8.8.5.0/24"],"process_name":["curl"]}]}'
expect "unusable port values" $'--' \
  '{"version":3,"rules":[{"ip_cidr":["8.8.6.0/24"],"port":["none"]}]}'
expect "OR keeps its plain children only" $'11.0.0.0/8\n--' \
  '{"version":3,"rules":[{"type":"logical","mode":"or","rules":[{"ip_cidr":["11.0.0.0/8"]},{"ip_cidr":["12.0.0.0/8"],"network":["tcp"]}]}]}'

printf 'rule-set nft extraction checks passed\n'
