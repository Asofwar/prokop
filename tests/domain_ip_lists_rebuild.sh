#!/usr/bin/env bash
set -euo pipefail
# A8: the generator rebuilds a rule's domain_ip_lists set from its local
# files. A rule that also has remote lists keeps the set the list updater
# wrote (local and downloaded entries); the rebuild used to drop the
# downloaded entries until the next update. A local file that is gone keeps
# the previous set instead of a smaller one.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SET="$WORK/out.json.rulesets/proxy-lists-ruleset.json"
# fixture <references...>
fixture() {
  node - "$WORK/fixture.json" "$@" <<'JS'
const fs = require('fs');
const [path, ...lists] = process.argv.slice(2);
fs.writeFileSync(path, JSON.stringify({
  settings: { '.name': 'settings', '.type': 'settings', log_level: 'warn' },
  section: [ { '.name': 'proxy', '.type': 'section', enabled: '1', action: 'connection',
    outbound_json: '{"type":"direct"}', domain_ip_lists: lists } ]
}));
JS
}
# previous_set <domain>: the set as an earlier run left it.
previous_set() {
  mkdir -p "${SET%/*}"
  printf '{"version":3,"rules":[{"domain_suffix":["%s"]}]}\n' "$1" >"$SET"
}
generate() {
  mkdir -p "$WORK/out.json.section-cache"
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/out.json" 127.0.0.1 \
    >/dev/null 2>"$WORK/err" || fail "the generator failed: $(cat "$WORK/err")"
}
has() { grep -Fq "\"$1\"" "$SET"; }

printf 'local.example\n' >"$WORK/local.lst"

# 1. Local and remote lists: the downloaded entries stay.
fixture "$WORK/local.lst" "https://lists.example/remote.lst"
previous_set remote.example
generate
has remote.example || fail "the rebuild dropped the downloaded entries: $(cat "$SET")"

# 2. Only local lists: the set is rebuilt from the files.
fixture "$WORK/local.lst"
previous_set old.example
generate
has local.example || fail "the local list was not imported: $(cat "$SET")"
! has old.example || fail "the old entries stayed after the rebuild"
[ ! -e "$SET.new" ] || fail "the staging file was left behind"

# 3. A local file that is gone keeps the previous set.
fixture "$WORK/local.lst" "$WORK/gone.lst"
previous_set kept.example
generate
has kept.example || fail "a missing local file shrank the set: $(cat "$SET")"
grep -q 'local domain/IP list not found' "$WORK/err" || fail "the missing file was not named"

# 4. Without a previous set the files that are there still count.
rm -f "$SET"
generate
has local.example || fail "the first set lost the files that exist"

echo "domain_ip_lists_rebuild: OK"
