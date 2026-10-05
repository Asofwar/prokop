#!/usr/bin/env bash
set -euo pipefail

# Stage 6.7: Settings are split into DNS / Network / Lists and updates /
# Service tabs, the YACD secret is a password field, the rule editor walks
# through steps, and rule actions are localized in the grid.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const dir = path.join(process.argv[2], 'luci-app-prokop/htdocs/luci-static/resources/view/prokop');
const settings = fs.readFileSync(path.join(dir, 'settings.js'), 'utf8');
const section = fs.readFileSync(path.join(dir, 'section.js'), 'utf8');

const groupOf = {};
for (const m of settings.matchAll(/sections\.(\w+)\.option\(\s*(?:form|widgets)\.\w+,\s*"([a-z_]+)"/g))
  groupOf[m[2]] = m[1];
const expect = {
  dns: ['dns_type', 'dns_server', 'bootstrap_dns_server', 'dns_rewrite_ttl', 'dns_strategy', 'dns_client_subnet', 'dns_detour_enabled'],
  network: ['_kill_switch_status', 'source_network_interfaces', 'output_network_interface', 'disable_quic', 'exclude_ntp', 'dont_touch_dhcp', 'exclude_bittorrent', 'intercept_client_dns', 'intercept_client_dns_exclude', 'tproxy_low_memory', 'device_traffic'],
  lists: ['list_update_enabled', 'update_interval', 'latency_test_url', 'download_lists_via_proxy'],
  service: ['enable_yacd', 'yacd_secret_key', 'config_path', 'cache_path', 'log_level'],
};
for (const [group, names] of Object.entries(expect))
  for (const name of names) assert.equal(groupOf[name], group, `${name} belongs to the ${group} tab`);
assert.equal(Object.keys(groupOf).length, 41, 'every settings option lives in exactly one tab');
assert.doesNotMatch(settings, /\bsection\.option\(/, 'no option is left outside the tabs');

const secret = settings.slice(settings.indexOf('"yacd_secret_key"'));
assert.match(secret.slice(0, secret.indexOf('sections.')), /o\.password = true;/, 'the YACD secret is a password field');

for (const [tab, title] of [['basic', 'Basics'], ['target', 'Where to'], ['match', 'What'], ['devices', 'For whom'], ['advanced', 'Advanced']])
  assert(section.includes(`section.tab("${tab}", _("${title}"))`), `rule editor step ${title}`);
assert.doesNotMatch(section, /taboption\(\s*"(settings|conditions)"/, 'no option is left on the old tabs');

const labels = section.slice(section.indexOf('function getActionOptionLabel'), section.indexOf('function getRuleActionDisplayValue'));
for (const label of ['Block', 'Bypass', 'Connection', 'Proxy'])
  assert(labels.includes(`return _("${label}")`), `${label} action label is localized`);
assert.doesNotMatch(section, /option\.value\("(bypass|block)", "/, 'action choices are localized');
for (const column of ['_conditions_summary', '_devices_summary'])
  assert.match(section, new RegExp(`form\\.DummyValue,\\s*"${column}"`), `rules grid shows ${column}`);
console.log('Settings tabs, password secret, rule editor steps and grid summaries are in place');
NODE
