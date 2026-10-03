#!/usr/bin/env bash
# prokop_state_paths_v1: a configuration the migrating installer copied from
# /etc/config/forkop names files under /etc/forkop, which it copied to
# /etc/prokop and which goes away with Forkop. The migration moves every such
# path, alone, after file:// or inside a longer value, in every section and
# every list, and leaves every other path alone. It runs for "migrate" (the
# installer's step) and is recorded like every named migration.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
MIGRATION="$PROKOP_LIB/config/migration.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# Forkop's package is gone (core/legacy_forkop.uc), as after the installer's
# point of no return.
export PROKOP_LEGACY_FORKOP_ROOT="$WORK_DIR/no-forkop"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# --- the model (migrate-fixture) -----------------------------------------------
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings", "config_version": "1.0.5",
    "yacd_secret_key": "0123456789abcdef0123456789abcdef",
    "applied_migrations": [ "interface_sections", "enable_component_checks", "http_connection_urls",
      "flintnet_urltest_default", "retired_secondary_rulesets", "retired_secondary_rulesets_v2",
      "secondary_rulesets_mirror_v1", "own_dependency_mirror_v1", "clash_api_secret_v1",
      "urltest_section_names_v1", "vpn_guard_kill_switch_v1", "fork_mirror_opt_in_v1" ],
    "cache_path": "/etc/forkop/cache.db",
    "config_path": "/etc/sing-box/config.json"
  },
  "section": [
    {
      ".name": "main", ".type": "section", "action": "connection",
      "rule_set": [ "/etc/forkop/local.srs", "file:///etc/forkop/rules/games.srs",
        "https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs/valve.srs" ],
      "rule_set_with_subnets": [ "/etc/forkop-backups/kept.srs", "/mnt/etc/forkop/kept.srs",
        "https://example.com/etc/forkop/kept.srs", "/etc/forkopx/kept.srs", "/etc/prokop/kept.srs" ]
    },
    {
      ".name": "dpi", ".type": "section", "action": "zapret",
      "zapret_nfqws_opt": "--filter-tcp=443 --hostlist=/etc/forkop/hosts.txt --hostlist-exclude='/etc/forkop/exclude.txt' --new",
      "local_file": "/etc/forkop"
    }
  ],
  "subscription_url": [
    { ".name": "provider", ".type": "subscription_url", "section": "main", "url": "file:///etc/forkop/subscription.txt" }
  ],
  "server": [
    { ".name": "custom", ".type": "server", "certificate_path": "/etc/forkop/certs/ca.pem" }
  ]
}
JSON
PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/fixture.json" \
  >"$WORK_DIR/out.json" || fail "migrate-fixture failed"

node - "$WORK_DIR/out.json" <<'NODE' || fail "state path migration (model)"
const fs = require('fs');
const assert = require('assert/strict');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const config = out.config;
const sections = Object.fromEntries(config.section.map((s) => [s['.name'], s]));
assert.equal(config.settings.cache_path, '/etc/prokop/cache.db');
assert.equal(config.settings.config_path, '/etc/sing-box/config.json');
assert.deepEqual(sections.main.rule_set, [ '/etc/prokop/local.srs', 'file:///etc/prokop/rules/games.srs',
  'https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs/valve.srs' ]);
assert.deepEqual(sections.main.rule_set_with_subnets, [ '/etc/forkop-backups/kept.srs', '/mnt/etc/forkop/kept.srs',
  'https://example.com/etc/forkop/kept.srs', '/etc/forkopx/kept.srs', '/etc/prokop/kept.srs' ],
  'paths that are not under Forkop\'s state directory must stay as they are');
assert.equal(sections.dpi.zapret_nfqws_opt,
  "--filter-tcp=443 --hostlist=/etc/prokop/hosts.txt --hostlist-exclude='/etc/prokop/exclude.txt' --new");
assert.equal(sections.dpi.local_file, '/etc/prokop');
assert.equal(config.subscription_url[0].url, 'file:///etc/prokop/subscription.txt');
assert.equal(config.server?.[0]?.certificate_path, '/etc/prokop/certs/ca.pem',
  'sections of types no other migration reads must be migrated too');
assert.equal(config.settings.applied_migrations.at(-1), 'prokop_state_paths_v1');
assert.ok(!JSON.stringify(config).includes('"/etc/forkop/'), 'a path under /etc/forkop was left');
const changed = out.operations.filter((op) => op.op === 'set' || op.op === 'set_list').map((op) => `${op.section}.${op.option}`);
for (const name of [ 'settings.cache_path', 'main.rule_set', 'dpi.zapret_nfqws_opt', 'dpi.local_file', 'provider.url', 'custom.certificate_path' ])
  assert.ok(changed.includes(name), `no operation rewrote ${name}`);
assert.ok(!changed.includes('main.rule_set_with_subnets'), 'an untouched list was rewritten');
fs.writeFileSync(process.argv[2] + '.config', JSON.stringify(config));
NODE

# Once recorded, the migration never runs again.
PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/out.json.config" \
  >"$WORK_DIR/again.json" || fail "the second migrate-fixture failed"
node -e 'const out = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  if (out.changed) { console.error("a migrated configuration changed again"); process.exit(1); }' "$WORK_DIR/again.json" ||
  fail "state path migration must be idempotent"

# --- the router (migrate, through core/uci.uc) ----------------------------------
STATE="$WORK_DIR/uci.state"
cat >"$STATE" <<'EOF_UCI'
prokop.settings=settings
prokop.settings.config_version=1.0.5
prokop.settings.yacd_secret_key=0123456789abcdef0123456789abcdef
prokop.settings.applied_migrations=interface_sections enable_component_checks http_connection_urls flintnet_urltest_default retired_secondary_rulesets retired_secondary_rulesets_v2 secondary_rulesets_mirror_v1 own_dependency_mirror_v1 clash_api_secret_v1 urltest_section_names_v1 vpn_guard_kill_switch_v1 fork_mirror_opt_in_v1
prokop.settings.cache_path=/etc/forkop/cache.db
prokop.main=section
prokop.main.action=connection
prokop.main.rule_set=/etc/forkop/local.srs https://example.com/etc/forkop/kept.srs
prokop.cfg0a1b2c=subscription_url
prokop.cfg0a1b2c.section=main
prokop.cfg0a1b2c.url=file:///etc/forkop/subscription.txt
prokop.custom=server
prokop.custom.certificate_path=/etc/forkop/certs/ca.pem
EOF_UCI
migrate() {
  : >"$WORK_DIR/uci.log"
  PROKOP_UCI_STATE_FILE="$STATE" \
  PROKOP_UCI_LOG_FILE="$WORK_DIR/uci.log" \
  PROKOP_CONFIG_NAME="prokop" \
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
  PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
  PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/subscription-cache" \
  PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
    ucode -L "$PROKOP_LIB" "$MIGRATION" migrate
}
migrate || fail "migrate failed"

for line in \
  'prokop.settings.cache_path=/etc/prokop/cache.db' \
  'prokop.main.rule_set=/etc/prokop/local.srs https://example.com/etc/forkop/kept.srs' \
  'prokop.cfg0a1b2c.url=file:///etc/prokop/subscription.txt' \
  'prokop.custom.certificate_path=/etc/prokop/certs/ca.pem'; do
  grep -Fxq "$line" "$STATE" || fail "migrate did not write: $line"
done
grep -Eq '^prokop\.settings\.applied_migrations=.* prokop_state_paths_v1( |$)' "$STATE" ||
  fail "migrate did not record prokop_state_paths_v1"
grep -Fxq 'commit prokop' "$WORK_DIR/uci.log" || fail "migrate did not commit prokop"

migrate || fail "the second migrate failed"
if grep -Fq 'commit prokop' "$WORK_DIR/uci.log"; then
  fail "a migrated router configuration was committed again"
fi

printf 'prokop from forkop data state paths: PASS\n'
