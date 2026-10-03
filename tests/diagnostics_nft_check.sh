#!/usr/bin/env bash
set -euo pipefail

# The NFT check of Diagnostics (diagnostics/runtime.uc check-nft-rules and
# check-nft) must not raise false alarms or pass vacuously (UC-107):
#   - Forkop's own tables (TorrServer Direct, the autotune probe, the DPI
#     guard, the kill-switch) set marks too; they are no "additional marking
#     rules" of another program;
#   - the router-originated capture counters of mangle_output count only the
#     rules that mark traffic for sing-box, not the 'meta mark ... counter
#     return' bypass of sing-box's own egress, which counts all of it;
#   - the set statistics show the per-rule sets (forkop_rule_*) that hold the
#     data, not only the shared sets nothing fills.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

mkdir -p "$WORK/bin" "$WORK/nft"
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$WORK/bin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
# nft answers from files: $NFT_DIR/<args joined by _>
cat >"$WORK/bin/nft" <<'SH'
#!/bin/sh
key="$(printf '%s_' "$@")"
file="${NFT_DIR:?}/${key%_}"
[ -f "$file" ] || exit 1
cat "$file"
SH
chmod 0755 "$WORK/bin/curl" "$WORK/bin/sleep" "$WORK/bin/nft"

state() { # name content
  printf '%s\n' "$2" >"$WORK/nft/$1"
}

scenario() { # mangle_output_counter_packets other_table
  rm -f "$WORK/nft/"*
  state "list_table_inet_ForkopTable" "table inet ForkopTable {}"
  state "list_chain_inet_ForkopTable_mangle" "chain mangle {
    iifname @forkop_interfaces ip daddr 198.18.0.0/15 meta l4proto tcp meta mark set 0x00100000 counter packets 9 bytes 900
}"
  state "list_chain_inet_ForkopTable_mangle_output" "chain mangle_output {
    ip daddr @localv4 return
    meta mark 0x08000000 counter packets 5000 bytes 500000 return
    jump priority_output_rules
    ip daddr 198.18.0.0/15 meta l4proto tcp meta mark set 0x00100000 counter packets $1 bytes 0
}"
  state "list_chain_inet_ForkopTable_proxy" "chain proxy {
    meta mark & 0x00100000 == 0x00100000 meta l4proto tcp tproxy ip to 127.0.0.1:1602 counter packets 9 bytes 900
}"
  local tables="table inet ForkopTable
table inet ForkopTorrServerDirect
table inet ForkopAutotuneProbe
table inet ForkopTableDpiGuard
table inet ForkopKillswitch"
  [ -n "$2" ] && tables="$tables
table inet $2"
  state "list_tables" "$tables"
  for t in ForkopTorrServerDirect ForkopAutotuneProbe ForkopTableDpiGuard ForkopKillswitch; do
    state "list_table_inet_$t" "table inet $t { chain c { meta mark set 0x08000000 } }"
  done
  [ -n "$2" ] && state "list_table_inet_$2" "table inet $2 { chain c { meta mark set 0x00000001 } }"
  state "list_ruleset" "table inet ForkopTable {
	meta mark set 0x00100000
}
table inet ForkopTorrServerDirect {
	meta mark set 0x08000000
}
$( [ -n "$2" ] && printf 'table inet %s {\n\tmeta mark set 0x00000001 counter\n}' "$2" )"
  return 0
}

check() {
  PATH="$WORK/bin:$PATH" NFT_DIR="$WORK/nft" FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" check-nft-rules
}

scenario 7 ""
check >"$WORK/own.json" || fail "check-nft-rules failed: $(cat "$WORK/own.json")"
scenario 0 ""
check >"$WORK/idle.json" || fail "check-nft-rules failed"
scenario 7 "fw4mark"
check >"$WORK/foreign.json" || fail "check-nft-rules failed"

node - "$WORK" <<'NODE' || failures=$((failures + 1))
const assert = require('node:assert/strict');
const fs = require('node:fs');
const read = (n) => JSON.parse(fs.readFileSync(`${process.argv[2]}/${n}.json`, 'utf8'));
const own = read('own'), idle = read('idle'), foreign = read('foreign');
assert.equal(own.rules_other_mark_exist, 0, 'Forkop tables are not foreign marking');
assert.equal(foreign.rules_other_mark_exist, 1, 'a foreign table that sets marks is reported');
assert.equal(own.rules_mangle_output_exist, 1);
assert.equal(own.rules_mangle_output_counters, 1, 'a capture rule that counted packets passes');
assert.equal(idle.rules_mangle_output_exist, 1, 'capture rules exist');
assert.equal(idle.rules_mangle_output_counters, 0, 'the egress bypass counter alone does not pass the capture counters');
assert.equal(own.rules_proxy_counters, 1);
NODE

# The ruleset excerpt shown under the warning lists foreign tables only.
scenario 7 "fw4mark"
PATH="$WORK/bin:$PATH" NFT_DIR="$WORK/nft" ucode -L "$LIB" "$LIB/diagnostics/status.uc" nft-ruleset-other-mark-lines ForkopTable \
  <"$WORK/nft/list_ruleset" >"$WORK/lines.txt"
grep -q '0x00000001' "$WORK/lines.txt" || fail "the foreign marking rule is listed"
if grep -q '0x08000000' "$WORK/lines.txt"; then fail "Forkop's TorrServer Direct table is listed as foreign: $(cat "$WORK/lines.txt")"; fi

# Set statistics name the per-rule sets.
cat >"$WORK/nft/-j_list_sets_inet" <<'JSON'
{"nftables":[{"metainfo":{}},{"set":{"family":"inet","name":"forkop_rule_other","table":"ForkopTorrServerDirect"}},{"set":{"family":"inet","name":"forkop_subnets","table":"ForkopTable"}},{"set":{"family":"inet","name":"forkop_rule_vpn_subnets","table":"ForkopTable"}},{"set":{"family":"inet","name":"forkop_rule_vpn_ports","table":"ForkopTable"}},{"set":{"family":"inet","name":"localv4","table":"ForkopTable"}}]}
JSON
printf '{"nftables":[{"set":{"name":"forkop_rule_vpn_subnets","elem":["10.0.0.0/8","192.0.2.0/24"]}}]}\n' >"$WORK/nft/-j_list_set_inet_ForkopTable_forkop_rule_vpn_subnets"
printf '{"nftables":[{"set":{"name":"forkop_rule_vpn_ports","elem":[443]}}]}\n' >"$WORK/nft/-j_list_set_inet_ForkopTable_forkop_rule_vpn_ports"
for s in forkop_rule_vpn_subnets forkop_rule_vpn_ports; do : >"$WORK/nft/list_set_inet_ForkopTable_$s"; done
PATH="$WORK/bin:$PATH" NFT_DIR="$WORK/nft" FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" nft-rule-set-statistics \
  >"$WORK/stats.txt" 2>&1 || fail "nft-rule-set-statistics failed: $(cat "$WORK/stats.txt")"
grep -q 'forkop_rule_vpn_subnets: 2 elements' "$WORK/stats.txt" || fail "per-rule subnet set counted: $(cat "$WORK/stats.txt")"
grep -q 'forkop_rule_vpn_ports: 1 elements' "$WORK/stats.txt" || fail "per-rule port set counted: $(cat "$WORK/stats.txt")"
if grep -q 'forkop_rule_other' "$WORK/stats.txt"; then fail "a set of another table is not Forkop's rule set"; fi

if [ "$failures" -ne 0 ]; then
  printf 'diagnostics_nft_check: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'diagnostics_nft_check: PASS\n'
