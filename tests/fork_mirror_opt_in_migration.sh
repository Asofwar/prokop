#!/usr/bin/env bash
# fork_mirror_opt_in_v1: a router that already ran the upstream mirror
# migrations names the upstream mirror; the fork drops it (the mirror is
# opt-in) and moves list and rule-set URLs on it to their direct sources.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

migrate() {
  FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$FORKOP_LIB/config/migration.uc" \
    migrate-fixture "$1" > "$2"
}

# fixture MIRROR: a configuration on which every migration but the opt-in one ran.
fixture() {
  node - "$1" <<'NODE'
const mirror = process.argv[2];
console.log(JSON.stringify({
  settings: {
    '.name': 'settings', '.type': 'settings', config_version: '1.0.5',
    mirror_base_url: mirror,
    yacd_secret_key: '0123456789abcdef0123456789abcdef',
    applied_migrations: ['interface_sections', 'enable_component_checks', 'http_connection_urls',
      'flintnet_urltest_default', 'retired_secondary_rulesets', 'retired_secondary_rulesets_v2',
      'secondary_rulesets_mirror_v1', 'own_dependency_mirror_v1', 'mirror_infotechtg_ru_v1',
      'clash_api_secret_v1', 'urltest_section_names_v1', 'vpn_guard_kill_switch_v1'],
  },
  section: [{
    '.name': 'main', '.type': 'section', action: 'connection',
    rule_set: [
      'https://mirror.infotechtg.ru/forkop/lists/rulesets/community/youtube.srs',
      'http://mirror.infotechtg.ru/forkop/lists/rulesets/adlist.srs',
      'https://mirror.infotechtg.ru/forkop/lists/rulesets/supercell.srs',
      'https://mirror.51343.ru/forkop/lists/rulesets/github.srs',
      'https://mirror.infotechtg.ru/forkop/lists/unknown/tree.srs',
      'https://own-mirror.example/forkop/lists/rulesets/community/discord.srs',
    ],
    rule_set_with_subnets: [
      'https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs/valve.srs',
      'https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs/valve.srs',
      'https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs/google.srs',
      '/etc/forkop/local.srs',
    ],
    remote_domain_lists: ['https://mirror.infotechtg.ru/forkop/lists/allow-domains/Russia/inside-raw.lst'],
    remote_subnet_lists: ['http://mirror.51343.ru/forkop/lists/allow-domains/Subnets/IPv4/telegram.lst',
      'https://custom.example/subnets.txt'],
  }],
  subscription_url: [{ '.name': 'provider', '.type': 'subscription_url', section: 'main',
    url: 'https://mirror.infotechtg.ru/forkop/lists/allow-domains/not-a-list-option.txt' }],
}));
NODE
}

for mirror in 'https://mirror.infotechtg.ru' 'http://mirror.infotechtg.ru/' 'https://mirror.51343.ru/' \
  'http://mirror.51343.ru' ''; do
  fixture "$mirror" > "$WORK_DIR/fixture.json"
  migrate "$WORK_DIR/fixture.json" "$WORK_DIR/result.json"
  node - "$WORK_DIR/result.json" "$mirror" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).config;
const mirror = process.argv[3];
assert.equal(out.settings.mirror_base_url, '', `former mirror ${mirror} must be disabled`);
assert.equal(out.settings.applied_migrations.at(-1), 'fork_mirror_opt_in_v1');
assert(out.settings.applied_migrations.includes('mirror_infotechtg_ru_v1'), 'unknown ids stay recorded');
const section = out.section[0];
assert.deepEqual(section.rule_set, [
  'https://github.com/itdoginfo/allow-domains/releases/latest/download/youtube.srs',
  'https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.srs',
  'https://raw.githubusercontent.com/ushan0v/sing-box-supercell-ruleset/main/supercell.srs',
  'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/github.srs',
  // No known direct source: kept as it is.
  'https://mirror.infotechtg.ru/forkop/lists/unknown/tree.srs',
  'https://own-mirror.example/forkop/lists/rulesets/community/discord.srs',
]);
assert.deepEqual(section.rule_set_with_subnets, [
  'https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs/valve.srs',
  'https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs/google.srs',
  '/etc/forkop/local.srs',
], 'b4geoip URLs move to raw GitHub without duplicates');
assert.deepEqual(section.remote_domain_lists,
  ['https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst']);
assert.deepEqual(section.remote_subnet_lists, [
  'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/telegram.lst',
  'https://custom.example/subnets.txt',
]);
assert.equal(out.subscription_url[0].url,
  'https://mirror.infotechtg.ru/forkop/lists/allow-domains/not-a-list-option.txt',
  'subscriptions are never rewritten');
fs.writeFileSync(process.argv[2] + '.config', JSON.stringify(out));
NODE
  # The migration runs once: a second pass changes nothing.
  migrate "$WORK_DIR/result.json.config" "$WORK_DIR/again.json"
  node - "$WORK_DIR/result.json.config" "$WORK_DIR/again.json" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
assert.deepEqual(JSON.parse(fs.readFileSync(process.argv[3], 'utf8')).config,
  JSON.parse(fs.readFileSync(process.argv[2], 'utf8')));
NODE
done

# A custom mirror is the user's opt-in: it and its URLs stay, while URLs on
# the former upstream mirror still move to their direct sources.
fixture 'https://own-mirror.example/' > "$WORK_DIR/custom.json"
migrate "$WORK_DIR/custom.json" "$WORK_DIR/custom-result.json"
node - "$WORK_DIR/custom-result.json" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).config;
assert.equal(out.settings.mirror_base_url, 'https://own-mirror.example/');
assert(out.section[0].rule_set.includes('https://own-mirror.example/forkop/lists/rulesets/community/discord.srs'));
assert(out.section[0].rule_set.includes('https://github.com/itdoginfo/allow-domains/releases/latest/download/youtube.srs'));
assert(out.settings.applied_migrations.includes('fork_mirror_opt_in_v1'));
NODE

# The shipped configuration needs no change from it.
grep -Fq "list applied_migrations 'fork_mirror_opt_in_v1'" "$ROOT_DIR/forkop/files/etc/config/forkop" ||
  { echo 'FAIL: the shipped configuration must mark fork_mirror_opt_in_v1 as applied' >&2; exit 1; }
printf 'fork mirror opt-in migration checks passed\n'
