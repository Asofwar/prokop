#!/usr/bin/env bash
set -eo pipefail

# sing-box tags a URLTest group <rule>-urltest-<section name>. libuci names
# an anonymous section after its position in the file (cfg<index><hash of the
# type>), so adding or removing any section before a group changed its tag,
# and sing-box forgot the server or group chosen in the rule's selector
# (UC-044). The editor creates named groups (ut_<8 hex>); the migration
# urltest_section_names_v1 names the anonymous ones once (ut_<hash part>) and
# moves the dashboard overrides of the old tag to the new one. The generated
# tag then no longer depends on the position of the section.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
MIGRATION="$PROKOP_LIB/config/migration.uc"
GENERATOR="$PROKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

migrate_fixture() {
  PROKOP_CONFIG_NAME=prokop ucode -L "$PROKOP_LIB" "$MIGRATION" migrate-fixture "$1" >"$2"
}

# 1. The fixture migration names anonymous groups and moves their overrides.
cat >"$WORK_DIR/groups.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "yacd_secret_key": "secret" },
  "section": [
    { ".name": "main", ".type": "section", "action": "connection", "selector_proxy_links": [ "socks5://10.0.0.1:1080" ] },
    { ".name": "other", ".type": "section", "action": "connection", "selector_proxy_links": [ "socks5://10.0.0.2:1080" ] }
  ],
  "urltest": [
    { ".name": "cfg022898", ".type": "urltest", ".anonymous": true, "section": "main", "name": "Fastest" },
    { ".name": "ut_1a2b3c4d", ".type": "urltest", ".anonymous": false, "section": "main", "name": "Named" },
    { ".name": "cfg052898", ".type": "urltest", "section": "other", "name": "No flag" },
    { ".name": "cfg062898", ".type": "urltest", ".anonymous": false, "section": "other", "name": "Named like anonymous" }
  ],
  "urltest_override": [
    { ".name": "cfg0a2c1f", ".type": "urltest_override", "rule": "main", "tag": "main-urltest-cfg022898-out", "testing_url": "https://example.com/check" },
    { ".name": "cfg0b2c1f", ".type": "urltest_override", "rule": "main", "tag": "Flint Auto", "testing_url": "https://example.com/flint" },
    { ".name": "cfg0c2c1f", ".type": "urltest_override", "rule": "other", "tag": "main-urltest-cfg022898-out", "testing_url": "https://example.com/other" }
  ]
}
JSON
migrate_fixture "$WORK_DIR/groups.json" "$WORK_DIR/groups.out"
node - "$WORK_DIR/groups.out" <<'NODE' || fail "fixture migration of anonymous URLTest groups"
const assert = require('assert/strict');
const out = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const names = out.config.urltest.map((group) => [group['.name'], group.name]);
assert.deepEqual(names, [
  ['ut_022898', 'Fastest'], ['ut_1a2b3c4d', 'Named'], ['ut_052898', 'No flag'],
  ['cfg062898', 'Named like anonymous'],
], 'anonymous URLTest groups must get stable names, named ones keep theirs');
assert.equal(out.config.urltest[0]['.anonymous'], false);
assert.deepEqual(out.operations.filter((op) => op.op === 'rename'), [
  { op: 'rename', section: 'cfg022898', name: 'ut_022898' },
  { op: 'rename', section: 'cfg052898', name: 'ut_052898' },
]);
assert.deepEqual(out.config.urltest_override.map((item) => item.tag), [
  'main-urltest-ut_022898-out', 'Flint Auto', 'main-urltest-cfg022898-out',
], 'only the override of the renamed group of the same rule follows it');
assert.ok(out.config.settings.applied_migrations.includes('urltest_section_names_v1'));
NODE

# A second run changes nothing.
node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[2], JSON.stringify(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).config));
' "$WORK_DIR/groups.out" "$WORK_DIR/groups.again.json"
migrate_fixture "$WORK_DIR/groups.again.json" "$WORK_DIR/groups.again.out"
node -e '
const out = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (out.changed) { console.error(JSON.stringify(out.operations)); process.exit(1); }
' "$WORK_DIR/groups.again.out" || fail "the URLTest naming migration must run once"

# A name that is taken gets a suffix.
node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
data.urltest.push({ ".name": "ut_022898", ".type": "urltest", ".anonymous": false, section: "main", name: "Taken" });
fs.writeFileSync(process.argv[2], JSON.stringify(data));
' "$WORK_DIR/groups.json" "$WORK_DIR/taken.json"
migrate_fixture "$WORK_DIR/taken.json" "$WORK_DIR/taken.out"
node -e '
const out = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const renamed = out.operations.filter((op) => op.op === "rename" && op.section === "cfg022898");
if (renamed.length !== 1 || renamed[0].name !== "ut_022898_2") { console.error(JSON.stringify(out.operations)); process.exit(1); }
' "$WORK_DIR/taken.out" || fail "a taken URLTest name must get a suffix"

# So does a name that a section of another type holds: the rename would
# fail, and the override would already point at a tag that no group has.
node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
data.priority_group = [{ ".name": "ut_022898", ".type": "priority_group", section: "main", name: "Taken" }];
fs.writeFileSync(process.argv[2], JSON.stringify(data));
' "$WORK_DIR/groups.json" "$WORK_DIR/taken-other.json"
migrate_fixture "$WORK_DIR/taken-other.json" "$WORK_DIR/taken-other.out"
node -e '
const out = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const renamed = out.operations.filter((op) => op.op === "rename" && op.section === "cfg022898");
if (renamed.length !== 1 || renamed[0].name !== "ut_022898_2" ||
    out.config.urltest_override[0].tag !== "main-urltest-ut_022898_2-out") {
  console.error(JSON.stringify(out.operations)); process.exit(1);
}
' "$WORK_DIR/taken-other.out" || fail "a URLTest name taken by a section of another type must get a suffix"

# 2. The runtime migration renames the sections in place through core.uci.
cat >"$WORK_DIR/runtime.state" <<'EOF_UCI'
prokop.settings=settings
prokop.settings.yacd_secret_key=secret
prokop.main=section
prokop.main.action=connection
prokop.cfg022898=urltest
prokop.cfg022898.section=main
prokop.cfg022898.name=Fastest
prokop.cfg032898=urltest_override
prokop.cfg032898.rule=main
prokop.cfg032898.tag=main-urltest-cfg022898-out
prokop.after=section
prokop.after.action=block
EOF_UCI
: >"$WORK_DIR/runtime.log"
PROKOP_UCI_STATE_FILE="$WORK_DIR/runtime.state" \
PROKOP_UCI_LOG_FILE="$WORK_DIR/runtime.log" \
PROKOP_CONFIG_NAME=prokop \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  ucode -L "$PROKOP_LIB" "$MIGRATION" migrate
grep -q 'cfg022898' "$WORK_DIR/runtime.state" && {
  cat "$WORK_DIR/runtime.state" >&2
  fail "the runtime migration must rename the anonymous URLTest section"
}
sed -n '5,7p' "$WORK_DIR/runtime.state" >"$WORK_DIR/runtime.group"
printf '%s\n' 'prokop.ut_022898=urltest' 'prokop.ut_022898.section=main' 'prokop.ut_022898.name=Fastest' |
  cmp -s - "$WORK_DIR/runtime.group" || {
  cat "$WORK_DIR/runtime.state" >&2
  fail "the renamed URLTest section must keep its options and its place"
}
grep -Fxq 'prokop.cfg032898.tag=main-urltest-ut_022898-out' "$WORK_DIR/runtime.state" ||
  fail "the runtime migration must move the override to the new tag"
grep -Fxq 'commit prokop' "$WORK_DIR/runtime.log" || fail "the runtime migration must commit"

# A section of a type the migrations do not read may hold the name.
cat >"$WORK_DIR/taken.state" <<'EOF_UCI'
prokop.settings=settings
prokop.settings.yacd_secret_key=secret
prokop.main=section
prokop.main.action=connection
prokop.ut_022898=priority_group
prokop.ut_022898.section=main
prokop.cfg022898=urltest
prokop.cfg022898.section=main
prokop.cfg032898=urltest_override
prokop.cfg032898.rule=main
prokop.cfg032898.tag=main-urltest-cfg022898-out
EOF_UCI
PROKOP_UCI_STATE_FILE="$WORK_DIR/taken.state" \
PROKOP_CONFIG_NAME=prokop \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  ucode -L "$PROKOP_LIB" "$MIGRATION" migrate
if ! grep -Fxq 'prokop.ut_022898_2=urltest' "$WORK_DIR/taken.state" ||
  ! grep -Fxq 'prokop.ut_022898=priority_group' "$WORK_DIR/taken.state" ||
  ! grep -Fxq 'prokop.cfg032898.tag=main-urltest-ut_022898_2-out' "$WORK_DIR/taken.state"; then
  cat "$WORK_DIR/taken.state" >&2
  fail "a URLTest name taken by a section of another type must get a suffix at runtime"
fi

# Groups that the Podkop migration creates from urltest_enabled are named too.
cat >"$WORK_DIR/podkop.state" <<'EOF_UCI'
prokop.settings=settings
prokop.legacy=section
prokop.legacy.connection_type=proxy
prokop.legacy.proxy_config_type=urltest
prokop.legacy.urltest_proxy_links=vless://one vless://two
prokop.legacy.urltest_enabled=1
EOF_UCI
PROKOP_UCI_STATE_FILE="$WORK_DIR/podkop.state" \
PROKOP_CONFIG_NAME=prokop \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  ucode -L "$PROKOP_LIB" "$MIGRATION" migrate-podkop
if ! grep -Fxq 'prokop.ut_000001=urltest' "$WORK_DIR/podkop.state" ||
  ! grep -Fxq 'prokop.ut_000001.section=legacy' "$WORK_DIR/podkop.state" ||
  grep -Eq '^prokop\.cfg[0-9a-f]+=urltest$' "$WORK_DIR/podkop.state"; then
  cat "$WORK_DIR/podkop.state" >&2
  fail "the URLTest group created from urltest_enabled must get a stable name"
fi

# 3. Generated tags: libuci names anonymous sections by position. A model of
# that naming (the counter counts every section of the package in file
# order) renames the anonymous group when a rule is added before it or
# removed; the migrated group keeps its tag.
cat >"$WORK_DIR/libuci-names.js" <<'NODE'
const fs = require('fs');
const [input, output, extra] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(input, 'utf8'));
const sections = [...data.section];
if (extra === 'insert')
  sections.unshift({ '.name': 'added', '.type': 'section', enabled: '0', action: 'block' });
if (extra === 'remove')
  sections.splice(sections.findIndex((section) => section['.name'] === 'spare'), 1);
const typeHash = { urltest: '2898', urltest_override: '2c1f' };
let index = 0;
const name = (section) => {
  index += 1;
  if (section['.anonymous'] === false || !/^cfg[0-9a-f]{6}$/.test(section['.name'])) return;
  section['.name'] = `cfg${index.toString(16).padStart(2, '0')}${typeHash[section['.type']]}`;
};
[data.settings, ...sections, ...(data.urltest || []), ...(data.urltest_override || [])].forEach(name);
data.section = sections;
fs.writeFileSync(output, JSON.stringify(data));
NODE
cat >"$WORK_DIR/rules.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn" },
  "section": [
    { ".name": "spare", ".type": "section", "enabled": "0", "action": "block" },
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#first",
        "vless://00000000-0000-4000-8000-000000000002@example.org:443?encryption=none&security=tls&sni=example.org#second"
      ]
    }
  ],
  "urltest": [
    { ".name": "cfg000000", ".type": "urltest", ".anonymous": true, "section": "proxy", "name": "Fastest" }
  ]
}
JSON

urltest_tags() {
  local output="$WORK_DIR/$2.config.json"
  mkdir -p "$output.section-cache"
  ucode -L "$PROKOP_LIB" "$GENERATOR" generate-config-fixture "$1" "$output" "127.0.0.1"
  node -e '
const cfg = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const selector = cfg.outbounds.find((outbound) => outbound.tag === "proxy-out");
const tags = cfg.outbounds.filter((outbound) => outbound.type === "urltest").map((outbound) => outbound.tag);
if (!selector || !tags.every((tag) => selector.outbounds.includes(tag))) process.exit(1);
console.log(tags.join(" "));
' "$output"
}

node "$WORK_DIR/libuci-names.js" "$WORK_DIR/rules.json" "$WORK_DIR/anon.json"
node "$WORK_DIR/libuci-names.js" "$WORK_DIR/rules.json" "$WORK_DIR/anon-insert.json" insert
anon="$(urltest_tags "$WORK_DIR/anon.json" anon)"
anon_insert="$(urltest_tags "$WORK_DIR/anon-insert.json" anon-insert)"
if [ "$anon" != 'proxy-urltest-cfg042898-out' ] || [ "$anon_insert" != 'proxy-urltest-cfg052898-out' ]; then
  fail "the libuci naming model must reproduce the position-dependent tag (got '$anon' and '$anon_insert')"
fi

# Migrate the config as loaded, then add or remove a rule before the group.
node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[2], JSON.stringify(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).config));
' <(migrate_fixture "$WORK_DIR/anon.json" /dev/stdout) "$WORK_DIR/migrated.json"
node "$WORK_DIR/libuci-names.js" "$WORK_DIR/migrated.json" "$WORK_DIR/migrated-insert.json" insert
node "$WORK_DIR/libuci-names.js" "$WORK_DIR/migrated.json" "$WORK_DIR/migrated-remove.json" remove
for variant in migrated migrated-insert migrated-remove; do
  tags="$(urltest_tags "$WORK_DIR/$variant.json" "$variant")"
  [ "$tags" = 'proxy-urltest-ut_042898-out' ] ||
    fail "$variant: the URLTest tag must not depend on the section position (got '$tags')"
done

printf 'URLTest stable tag checks passed\n'
