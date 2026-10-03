#!/usr/bin/env bash
set -euo pipefail

# An enabled Connection rule needs a connection: a connection URL, a
# subscription, a network interface or a JSON outbound. The sing-box
# generator refuses a rule without one ("connection section has no usable
# outbounds"), so a configuration with such a rule never started; the
# validator accepted it, and Save & Apply ended in a generator error instead
# of an actionable message (UC-092). The validator refuses it now, before
# the reload touches the runtime, and its verdict is the generator's:
# - an enabled Connection rule (or one with a legacy proxy/vpn action)
#   without a source is refused by both, the validator naming the fix;
# - each source kind alone is accepted by both (a subscription waiting for
#   its first download is deferred by the runtime, as here);
# - a disabled rule without a source is neither generated nor validated, so
#   a configuration that keeps one, as a rule whose sources were removed
#   and that was switched off, still starts.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

SETTINGS='{ ".name": "settings", ".type": "settings", "log_level": "warn",
  "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret" }'

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
  printf '{ ".name": "%s", ".type": "section", "enabled": "%s", %s }' "$1" "$2" "$3"
}

# generator_accepts <fixture> [deferred sections]
generator_accepts() {
  mkdir -p "$WORK/$1.out.section-cache"
  TMP_SUBSCRIPTION_FOLDER="$WORK/subs" ucode -L "$LIB" "$LIB/singbox/generator.uc" \
    generate-config-fixture "$WORK/$1.json" "$WORK/$1.out" 127.0.0.1 0 1 "${2:-}" >/dev/null 2>"$WORK/$1.gen"
}

validator_accepts() {
  PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/validator.uc" \
    validate-runtime-fixture "$WORK/$1.json" '{}' >"$WORK/$1.val" 2>&1
}

# expect <fixture> accept|reject [validator message regex] [deferred sections]
expect() {
  local name="$1" verdict="$2" message="${3:-}" deferred="${4:-}" generator=reject validator=reject
  generator_accepts "$name" "$deferred" && generator=accept
  validator_accepts "$name" && validator=accept
  [ "$generator" = "$verdict" ] ||
    fail "$name: generator should $verdict ($(cat "$WORK/$name.gen"))"
  [ "$validator" = "$verdict" ] ||
    fail "$name: validator should $verdict like the generator ($(cat "$WORK/$name.val"))"
  if [ -n "$message" ] && ! grep -Eq "$message" "$WORK/$name.val"; then
    fail "$name: validator message should match /$message/ ($(cat "$WORK/$name.val"))"
  fi
}

MATCH='"community_lists": ["youtube"], "domain": "example.com"'
NO_SOURCE="Connection rule 'c' has no connection.*connection URL.*subscription.*network interface.*JSON outbound.*disable the rule"

fixture none "$(rule c 1 "\"action\": \"connection\", $MATCH")"
expect none reject "$NO_SOURCE"
for legacy in proxy vpn; do
  fixture "legacy_$legacy" "$(rule c 1 "\"action\": \"$legacy\", $MATCH")"
  expect "legacy_$legacy" reject "$NO_SOURCE"
done
# Empty values are no source.
fixture empty_values "$(rule c 1 "\"action\": \"connection\", \"selector_proxy_links\": \"\", \"interfaces\": [], $MATCH")"
expect empty_values reject "$NO_SOURCE"

fixture link "$(rule c 1 "\"action\": \"connection\", \"selector_proxy_links\": \"socks5://10.0.0.1:1080\", $MATCH")"
expect link accept
fixture interface "$(rule c 1 "\"action\": \"connection\", \"interfaces\": [\"wg0\"], $MATCH")"
expect interface accept
fixture json "$(rule c 1 "\"action\": \"connection\", \"outbound_json\": \"{\\\"type\\\":\\\"direct\\\",\\\"tag\\\":\\\"out\\\"}\", $MATCH")"
expect json accept
fixture subscription "$(rule c 1 "\"action\": \"connection\", \"subscription_urls\": [\"https://sub.example.com/list\"], $MATCH")"
expect subscription accept "" c

fixture disabled \
  "$(rule b 1 "\"action\": \"block\", \"domain\": \"blocked.example\"")" \
  "$(rule c 0 "\"action\": \"connection\", $MATCH")"
expect disabled accept

if [ "$failures" -ne 0 ]; then
  printf '%d Connection source verdict(s) differ\n' "$failures" >&2
  exit 1
fi
printf 'validator and generator agree on Connection rules without a source\n'
