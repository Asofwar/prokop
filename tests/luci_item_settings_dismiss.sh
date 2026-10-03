#!/usr/bin/env bash
set -euo pipefail

# The item settings modals of a rule (subscription source, interface,
# URLTest, priority and its levels, rule set) stack on top of the rule modal
# and write their Save into uci right away: the rule modal map shares the
# page's uci state. Dismiss of the rule modal must discard them together with
# the rest of the modal, or the next Save & Apply sends edits the user never
# confirmed; the Save button of the rule modal keeps them (UC-045). The real
# section.js runs on the LuCI model of tests/helpers/luci_form_harness.js,
# whose uci keeps staged edits the way luci-base uci.js does, including the
# merge of staged edits into the loaded values on a whole-section read.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

const B4 = 'https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs';
const VALVE = `${B4}/valve.srs`;
const CUSTOM = 'https://example.com/custom.srs';

function section(name, type, values) {
  return Object.assign({ '.name': name, '.type': type, '.anonymous': false }, values);
}
const urltest = {
  check_interval: '3m', tolerance: '50', testing_url: 'https://www.gstatic.com/generate_204',
  idle_timeout: '30m', interrupt_exist_connections: '1', pin_dashboard: '1', filter_mode: 'disabled',
  detect_server_country: 'flag_emoji',
};
const priority = {
  health_url: 'https://www.gstatic.com/generate_204', active_check_interval: '5s', check_timeout: '2s',
  recovery_check_interval: '15s', pick_fastest: '0', switch_to_faster_same_priority: '0',
  fastest_check_interval: '3m', interrupt_exist_connections: '1', pin_dashboard: '1',
};
const level = { direct: '0', filter_mode: 'include', detect_server_country: 'flag_emoji' };
const config = {
  rule: section('rule', 'section', { enabled: '1', action: 'connection', mixed_proxy_enabled: '0',
    community_lists: ['youtube'], rule_set: [CUSTOM], rule_set_with_subnets: [VALVE],
    selector_proxy_links: ['socks5://10.0.0.1:1080'] }),
  sub: section('sub', 'subscription_url', { section: 'rule', url: 'https://example.com/sub',
    subscription_update_enabled: '1', subscription_update_interval: '4h' }),
  wan: section('wan', 'section_interface', { section: 'rule', name: 'wan', domain_resolver_enabled: '0',
    domain_resolver_dns_type: 'udp', domain_resolver_dns_server: '8.8.8.8' }),
  // An older editor also stored id and display_name; saving the item drops them.
  fastest: section('fastest', 'urltest', { section: 'rule', name: 'Fastest', id: 'fastest',
    display_name: 'Fastest', ...urltest }),
  pg_main: section('pg_main', 'priority_group', { section: 'rule', name: 'Main', ...priority }),
  lvl_a: section('lvl_a', 'priority_level', { group: 'pg_main', name: 'First', order: '0', ...level }),
  lvl_b: section('lvl_b', 'priority_level', { group: 'pg_main', name: 'Second', order: '1', ...level }),
};

// The item settings modal of a list item of the rule modal.
const item = (option, value, context) => (modal) => modal.openItemSettings(option, value, context);

// What each item settings modal edits, and how its Save shows in uci.
const edits = [
  ['subscription source interval', item('subscription_url', 'sub'), (settings) => {
    settings.setValue('subscription_update_interval', '12h');
  }, (data) => assert.equal(data.sub.subscription_update_interval, '12h')],
  ['interface resolver', item('interfaces', 'wan'), (settings) => {
    settings.setValue('domain_resolver_enabled', '1');
    // LuCI re-checks dependencies on widget-change: the resolver fields show.
    settings.map.checkDepends();
    settings.setValue('domain_resolver_dns_server', '1.1.1.1');
  }, (data) => {
    assert.equal(data.wan.domain_resolver_enabled, '1');
    assert.equal(data.wan.domain_resolver_dns_server, '1.1.1.1');
  }],
  ['URLTest tolerance', item('urltest', 'fastest'), (settings) => {
    settings.setValue('tolerance', '150');
  }, (data) => {
    assert.equal(data.fastest.tolerance, '150');
    assert.equal(data.fastest.id, undefined);
  }],
  ['priority renamed and a level removed', item('priority_group', 'pg_main'), (settings) => {
    settings.setValue('name', 'Renamed');
    settings.setValue('priority_level', ['lvl_a']);
  }, (data) => {
    assert.equal(data.pg_main.name, 'Renamed');
    assert.equal(data.lvl_b, undefined);
  }],
  ['new priority', item('priority_group', '', { adding: true }), (settings) => {
    settings.setValue('name', 'Backup');
  }, (data) => {
    assert.equal(Object.values(data).filter((s) => s['.type'] === 'priority_group').length, 2);
  }],
  // The level modal stacks on the priority modal, which is then closed
  // without its own Save: the level Save is already in uci.
  ['priority level renamed', async (modal) => {
    const group = await modal.openItemSettings('priority_group', 'pg_main');
    const settings = await group.openItemSettings('priority_level', 'lvl_a');
    return Object.assign({}, settings, {
      save: async () => {
        await settings.save();
        await group.close();
      },
    });
  }, (settings) => {
    settings.setValue('name', 'Top');
    settings.setValue('filter_mode', 'disabled');
  }, (data) => {
    assert.equal(data.lvl_a.name, 'Top');
    assert.equal(data.lvl_a.filter_mode, 'disabled');
    assert.equal(data.pg_main.name, 'Main');
  }],
  ['rule set with subnets', item('rule_set', CUSTOM), (settings) => {
    settings.setValue('include_subnets', '1');
  }, (data) => {
    assert.equal(data.rule.rule_set, undefined);
    assert.deepEqual(data.rule.rule_set_with_subnets, [VALVE, CUSTOM]);
  }],
];

// Page code reads whole sections too (uci.get without an option), which
// merges the staged edits into the loaded values in place.
function readWholeSections(env) {
  for (const sid of Object.keys(env.uci.state.values.prokop)) env.uci.get('prokop', sid);
}

const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.stack || error.message}`);
  }
}

(async () => {
  for (const version of ['24.10', '25.12']) {
    for (const [label, open, edit, saved] of edits) {
      await check(`${version} ${label}: Dismiss discards the item settings`, async () => {
        const env = createEnvironment({ version, config });
        const modal = await env.openRule('rule');
        const settings = await open(modal);
        edit(settings);
        await settings.save();
        readWholeSections(env);
        saved(env.uci.data);

        await modal.dismiss();
        assert.deepEqual(env.uci.data, config, 'Dismiss left the item settings in uci');
        await env.uci.save();
        assert.deepEqual(env.uci.data, config, 'Save & Apply after Dismiss sent the item settings');

        // The editor opened again starts from the saved rule.
        const again = await env.openRule('rule');
        await again.saveButton();
        assert.deepEqual(env.uci.data, config, 'an unchanged save after Dismiss changed UCI');
      });

      await check(`${version} ${label}: the rule's Save keeps the item settings`, async () => {
        const env = createEnvironment({ version, config });
        const modal = await env.openRule('rule');
        const settings = await open(modal);
        edit(settings);
        await settings.save();
        readWholeSections(env);
        await modal.saveButton();
        saved(env.uci.data);

        // Closing after the save changes nothing.
        await modal.dismiss();
        saved(env.uci.data);
      });
    }

    // A rule modal whose Save was refused and then dismissed leaves nothing either.
    await check(`${version} refused rule save, then Dismiss`, async () => {
      const env = createEnvironment({ version, config });
      const modal = await env.openRule('rule');
      const settings = await modal.openItemSettings('subscription_url', 'sub');
      settings.setValue('subscription_update_interval', '12h');
      await settings.save();
      modal.option('outbound_jsons').getUIElement('rule').setValue(['{"type":"vless"}']);
      await modal.saveButton();
      assert.equal(env.uci.data.sub.subscription_update_interval, '12h', 'the refused save closed the modal');
      await modal.dismiss();
      assert.deepEqual(env.uci.data, config);
    });
  }
  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_item_settings_dismiss: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
