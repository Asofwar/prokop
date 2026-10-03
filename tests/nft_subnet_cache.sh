#!/usr/bin/env bash
set -euo pipefail

# nft/apply.uc caches the prepared elements of a rule-set subnet import in
# tmpfs, keyed by the rule set's content and the rule's port filter: a second
# import of the same rule set (a reload, the final apply of a list update)
# adds the same elements without preparing them again. A changed rule set or
# port filter is prepared anew, and a damaged cache entry is never used.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
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
export PATH="$WORK/bin:$PATH" FORKOP_NFT_SUBNET_CACHE_DIR="$WORK/cache" NFT_LOG

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
grep -q '^add element inet T forkop_rule_all_subnets { 198.51.100.0/24 }' "$WORK/cold.log" || fail "IPv4 subnet added: $(cat "$WORK/cold.log")"
grep -q '^add element inet T forkop_rule_all_subnets6 { 2001:db8::/48 }' "$WORK/cold.log" || fail "IPv6 subnet added"
grep -q '^add element inet T forkop_rule_all_ip_ports { 203.0.113.5 . 8443 }' "$WORK/cold.log" || fail "port-scoped subnet added"

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

# entry JSON: the cache file of an import of the rule set JSON without ports.
entry() { printf '%s/v3-capture-%s-5000-all.json' "$WORK/cache" "$(md5sum "$1" | cut -c1-32)"; }

# A hit counts as use (UC-222): an entry that a reload keeps importing is not
# the first to go because it was prepared long ago, a superseded one is.
rm -rf "$WORK/cache"
printf '{"version":3,"rules":[{"ip_cidr":["10.1.0.0/16"]}]}\n' >"$WORK/hot.json"
import all "$WORK/hot.json" "$WORK/n.log"
touch -d '2000-01-01 00:00:00' "$(entry "$WORK/hot.json")"
for i in $(seq 1 31); do
  import all "$WORK/r$i.json" "$WORK/n.log"
  touch -d "2001-01-01 00:00:$(printf '%02d' "$((i % 60))")" "$(entry "$WORK/r$i.json")"
done
[ "$(entries)" = 32 ] || fail "the fixture did not fill the cache: $(entries)"
rm -f "$WORK/u" "$WORK/s"
import all "$WORK/hot.json" "$WORK/n.log"
[ ! -e "$WORK/u" ] || fail "the hot entry was not used from the cache"
import all "$WORK/r40.json" "$WORK/n.log"
[ "$(entries)" -le 32 ] || fail "the cache is bounded: $(entries)"
[ -e "$(entry "$WORK/hot.json")" ] || fail "an entry in use was evicted before unused ones"
[ ! -e "$(entry "$WORK/r1.json")" ] || fail "the least recently used entry was kept"

# The cache is bounded by its size in tmpfs as well, not by the number of
# entries alone: a few large rule sets must not fill the RAM.
rm -rf "$WORK/cache"
big() { # big N FILE: a rule set of N subnets
  awk -v n="$1" 'BEGIN {
    printf "{\"version\":3,\"rules\":[{\"ip_cidr\":["
    for (i = 0; i < n; i++) printf "%s\"10.%d.%d.0/24\"", (i ? "," : ""), int(i / 256) % 256, i % 256
    print "]}]}"
  }' >"$2"
}
# backdate: the entries were last used by earlier reloads, long ago, in
# the order they were last used.
backdate() {
  local i=0 f
  while IFS= read -r f; do
    i=$((i + 1))
    touch -d "2001-01-01 00:00:$(printf '%02d' "$i")" "$f"
  done < <(find "$WORK/cache" -name '*.json' -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-)
}
for i in 1 2 3 4 5 6; do
  big "$((300 + i))" "$WORK/big$i.json"
  FORKOP_NFT_SUBNET_CACHE_MAX_BYTES=16384 import all "$WORK/big$i.json" "$WORK/n.log"
  total="$(find "$WORK/cache" -name '*.json' -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')"
  [ "$total" -le 16384 ] || fail "the cache outgrew its size limit: $total bytes in $(entries) entries"
  backdate
done
[ -e "$(entry "$WORK/big6.json")" ] || fail "the newest entry that fits was not cached"
# An entry larger than the whole limit is not cached; the import still works.
big 3000 "$WORK/huge.json"
FORKOP_NFT_SUBNET_CACHE_MAX_BYTES=16384 import all "$WORK/huge.json" "$WORK/huge.log"
grep -q '10.11.183.0/24' "$WORK/huge.log" || fail "an import too large for the cache lost elements"
[ ! -e "$(entry "$WORK/huge.json")" ] || fail "an entry larger than the size limit was cached"
[ -e "$(entry "$WORK/big6.json")" ] || fail "an entry too large for the cache evicted the others"

# The rule sets every reload imports need more room than the cache has: the
# entries the reloads keep using stay, the one that does not fit is
# prepared each time. Evicting the least recently used entry instead evicts
# the next one the same reload imports, and no import ever hits.
rm -rf "$WORK/cache"
for x in 1 2 3; do big "$((300 + x))" "$WORK/set$x.json"; done
reload() { # the imports of one reload: hit or miss for each rule set
  local x
  for x in 1 2 3; do
    rm -f "$WORK/u" "$WORK/s"
    FORKOP_NFT_SUBNET_CACHE_MAX_BYTES=10000 import all "$WORK/set$x.json" "$WORK/n.log"
    grep -q '10.1.44.0/24' "$WORK/n.log" || fail "an import of set$x lost elements"
    if [ -e "$WORK/u" ]; then printf 'miss '; else printf 'hit '; fi
  done
}
first="$(reload)"
[ "$first" = "miss miss miss " ] || fail "the first reload found entries: $first"
for day in 2 3; do
  backdate
  result="$(reload)"
  [ "$result" = "hit hit miss " ] || fail "reload $day of a working set larger than the cache: $result (cache: $(ls "$WORK/cache"))"
done
total="$(find "$WORK/cache" -name '*.json' -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')"
[ "$total" -le 10000 ] || fail "the cache outgrew its size limit: $total bytes"

printf 'nft_subnet_cache: PASS\n'
