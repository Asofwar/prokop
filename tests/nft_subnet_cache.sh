#!/usr/bin/env bash
set -euo pipefail

# nft/apply.uc caches the prepared elements of a rule-set subnet import in
# tmpfs, keyed by the rule set's content and the rule's port filter: a second
# import of the same rule set (a reload, the final apply of a list update)
# adds the same elements without preparing them again. A changed rule set or
# port filter is prepared anew, and a damaged cache entry is never used.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin"
cat >"$WORK/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$NFT_LOG"
SH
cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
printf 'logger %s\n' "$*" >>"$NFT_LOG"
SH
chmod +x "$WORK/bin/nft" "$WORK/bin/logger"
export PATH="$WORK/bin:$PATH" PROKOP_NFT_SUBNET_CACHE_DIR="$WORK/cache" NFT_LOG

cat >"$WORK/fixture.json" <<'JSON'
{ "section": [
  { ".name": "all", ".type": "section", "enabled": "1", "action": "proxy", "ip_cidr": [ "192.0.2.9" ] },
  { ".name": "ported", ".type": "section", "enabled": "1", "action": "proxy", "ip_cidr": [ "192.0.2.9" ], "ports": [ "443" ] } ] }
JSON
cat >"$WORK/rules.json" <<'JSON'
{"version":3,"rules":[{"ip_cidr":["198.51.100.0/24","2001:db8::/48","bad"]},{"ip_cidr":["203.0.113.5"],"port":[8443]}]}
JSON
import() { # section json log
  NFT_LOG="$3"; : >"$NFT_LOG"
  ucode -L "$LIB" "$LIB/nft/apply.uc" nft-add-json-ruleset-subnets-for-section-fixture "$WORK/fixture.json" "$1" "$2" \
    "Rule set test" T s4 p4 "$WORK/u" "$WORK/s" 5000 s6 p6
}
entries() { find "$WORK/cache" -name '*.json' 2>/dev/null | wc -l; }

import all "$WORK/rules.json" "$WORK/cold.log"
[ "$(entries)" = 1 ] || fail "the prepared import is cached: $(ls "$WORK/cache" 2>&1)"
grep -q '^add element inet T prokop_rule_all_subnets { 198.51.100.0/24 }' "$WORK/cold.log" || fail "IPv4 subnet added: $(cat "$WORK/cold.log")"
grep -q '^add element inet T prokop_rule_all_subnets6 { 2001:db8::/48 }' "$WORK/cold.log" || fail "IPv6 subnet added"
grep -q '^add element inet T prokop_rule_all_ip_ports { 203.0.113.5 . 8443 }' "$WORK/cold.log" || fail "port-scoped subnet added"

# The same rule set again: the same commands, from the cache, without the
# extraction (its output files are left untouched).
rm -f "$WORK/u" "$WORK/s"
import all "$WORK/rules.json" "$WORK/warm.log"
cmp -s "$WORK/cold.log" "$WORK/warm.log" || fail "a cached import differs: $(diff "$WORK/cold.log" "$WORK/warm.log")"
[ ! -e "$WORK/u" ] || fail "a cached import prepared the rule set again"

# Another port filter or other content is another entry.
import ported "$WORK/rules.json" "$WORK/ported.log"
[ "$(entries)" = 2 ] || fail "the port filter is part of the key"
sed -i 's/198.51.100.0/198.51.101.0/' "$WORK/rules.json"
import all "$WORK/rules.json" "$WORK/changed.log"
[ "$(entries)" = 3 ] || fail "the content is part of the key"
grep -q '198.51.101.0/24' "$WORK/changed.log" || fail "a changed rule set is prepared anew"

# A damaged entry is ignored and replaced.
for f in "$WORK"/cache/*.json; do printf '{"unscoped":{"v4":1}' >"$f"; done
import all "$WORK/rules.json" "$WORK/damaged.log"
cmp -s "$WORK/changed.log" "$WORK/damaged.log" || fail "a damaged entry was used: $(cat "$WORK/damaged.log")"

# A rule set without subnets still warns, from the cache too.
printf '{"version":3,"rules":[{"domain":["example.org"]}]}\n' >"$WORK/domains.json"
import all "$WORK/domains.json" "$WORK/empty1.log"
import all "$WORK/domains.json" "$WORK/empty2.log"
for l in "$WORK/empty1.log" "$WORK/empty2.log"; do
  grep -q 'has no ip_cidr entries' "$l" || fail "no-subnet warning: $(cat "$l")"
done

# The cache keeps at most 32 entries, the oldest go first.
for i in $(seq 1 40); do printf '{"version":3,"rules":[{"ip_cidr":["10.0.%d.0/24"]}]}\n' "$i" >"$WORK/r$i.json"; import all "$WORK/r$i.json" "$WORK/n.log"; done
[ "$(entries)" -le 32 ] || fail "the cache is bounded: $(entries)"

printf 'nft_subnet_cache: PASS\n'
