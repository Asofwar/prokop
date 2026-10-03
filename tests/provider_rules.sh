#!/usr/bin/env bash
# Route marks and NFQUEUE numbers of the per-rule DPI providers. The provider
# runtime (providers/nfqueue/runtime.uc) starts the queue workers and
# nft/apply.uc writes the rules that mark and queue their traffic; both take
# the numbers from providers/marks.uc (UC-168).
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
NFQUEUE_RUNTIME="$PROKOP_LIB/providers/nfqueue/runtime.uc"
NFT_APPLY="$PROKOP_LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# shellcheck source=tests/helpers/source_checks.sh
source "$ROOT_DIR/tests/helpers/source_checks.sh"

marks() {
  ucode -L "$PROKOP_LIB" -e "let m = require('providers.marks'); print(m.$1, '\n');"
}

assert_eq "16777217" "$(marks 'route_mark_value("0x01000000", 1)')" "hex base mark value"
assert_eq "0x01000002" "$(marks 'route_mark_hex("0x01000000", 2)')" "hex mark formatting"
assert_eq "0x02000001" "$(marks 'route_mark_hex(" 0X02000000 ", "1")')" "case and blanks of the base"
assert_eq "0x00000065" "$(marks 'route_mark_hex("100", 1)')" "decimal base"
assert_eq "4001" "$(marks 'queue_number("4000", 2)')" "queue number offset"
assert_eq "4300" "$(marks 'queue_number(4300, 1)')" "first queue of the range"
for invalid in '"invalid"' '"0x"' '"0x01g00000"' '""' 'null'; do
  assert_eq "" "$(marks "route_mark_hex($invalid, 1)")" "base $invalid is rejected"
done
assert_eq "" "$(marks 'route_mark_hex("0x01000000", 0)')" "index below 1 is rejected"

# Both production owners take the numbers from providers/marks.uc and carry
# no copy of the arithmetic.
for owner in "$NFQUEUE_RUNTIME" "$NFT_APPLY"; do
  grep -Fq 'require("providers.marks")' "$owner" ||
    fail "$owner must take route marks and queues from providers/marks.uc"
  source_refute "$owner must not carry its own number parser" \
    -E 'function (hex_digit_value|parse_number|parse_mark_number|nft_provider_mark_hex)\(' "$owner"
done
[ ! -e "$PROKOP_LIB/providers/rules.uc" ] ||
  fail "the orphan providers/rules.uc must stay removed"

# The queue rules nft/apply.uc writes for the provider's enabled rules use
# the marks and queues of providers/marks.uc, also for bases other than the
# defaults.
cat >"$WORK_DIR/sections.json" <<'JSON'
{
  "section": [
    { ".name": "direct", "enabled": "1", "action": "bypass" },
    { ".name": "one", "enabled": "1", "action": "zapret" },
    { ".name": "off", "enabled": "0", "action": "zapret" },
    { ".name": "two", "enabled": "1", "action": "zapret" }
  ]
}
JSON
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/provider"
chmod 0755 "$WORK_DIR/provider"
for bases in "0x01000000 4000" "0x01000010 4100"; do
  read -r mark_base queue_base <<<"$bases"
  batch="$WORK_DIR/batch-$queue_base.nft"
  : >"$batch"
  PROKOP_NFT_BATCH_FILE="$batch" ucode -L "$PROKOP_LIB" "$NFT_APPLY" \
    nft-create-provider-output-rules-fixture "$WORK_DIR/sections.json" ProkopTable zapret \
    "$WORK_DIR/provider" "$mark_base" "$queue_base" 0x40000000 0x20000000 ||
    fail "nft provider output rules failed for $bases"
  for index in 1 2; do
    mark="$(marks "route_mark_hex(\"$mark_base\", $index)")"
    queue="$(marks "queue_number(\"$queue_base\", $index)")"
    for proto in tcp udp; do
      grep -Fqx "add rule inet ProkopTable mangle_output meta mark & 0xff0000ff == $mark meta l4proto $proto counter queue num $queue bypass" "$batch" ||
        fail "rule $index ($proto) of bases $bases does not queue mark $mark to $queue: $(cat "$batch")"
    done
  done
  [ "$(grep -c ' queue num ' "$batch")" -eq 4 ] ||
    fail "the disabled and non-provider rules must not be queued: $(cat "$batch")"
done

printf 'Provider rule checks passed\n'
