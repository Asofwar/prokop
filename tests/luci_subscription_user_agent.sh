#!/usr/bin/env bash
set -euo pipefail

# D-17 (a), UC-090 in the subscription settings of the rule modal (real
# section.js under tests/helpers/luci_form_harness.js): the User-Agent a
# source sends when it names one.
# - The field shows the stored user_agent; an unchanged save keeps the item
#   as it is.
# - A User-Agent entered and saved is stored on the item; cleared, it goes
#   (automatic profiles again).
# - A value with control characters is refused.
# - What the backend sends follows the stored value
#   (config/connections.uc subscription_user_agent).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers" "$ROOT_DIR/prokop/files/usr/lib" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const [helpers, LIB] = process.argv.slice(2);
const { createEnvironment } = require(`${helpers}/luci_form_harness.js`);

const rule = { '.name': 'rule', '.type': 'section', '.anonymous': false, enabled: '1', label: 'VPN',
  action: 'connection', mixed_proxy_enabled: '0', community_lists: ['youtube'], subscription_url: ['sub'] };
const sub = (values) => Object.assign({ '.name': 'sub', '.type': 'subscription_url', '.anonymous': false,
  section: 'rule', url: 'https://example.com/sub', subscription_update_enabled: '1',
  subscription_update_interval: '4h', download_via_proxy_enabled: '0' }, values);

// The User-Agent the backend sends for the stored state.
function sentUserAgent(data) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'prokop-ua-'));
  try {
    const fixture = { settings: { '.name': 'settings', '.type': 'settings' }, section: [], subscription_url: [] };
    for (const item of Object.values(data)) (fixture[item['.type']] ??= []).push(item);
    fs.writeFileSync(path.join(work, 'fixture.json'), JSON.stringify(fixture));
    fs.writeFileSync(path.join(work, 'agent.uc'), `
      let connections = require("config.connections");
      let data = json(require("fs").readfile(ARGV[0]));
      connections.set_item_sections_from_data(data);
      print(connections.subscription_user_agent(data.section[0], "https://example.com/sub"));
    `);
    return execFileSync('ucode', ['-L', LIB, path.join(work, 'agent.uc'), path.join(work, 'fixture.json')]).toString();
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
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
    await check(`${version} stored User-Agent`, async () => {
      const config = { rule, sub: sub({ user_agent: 'Clash/1.0' }) };
      const env = createEnvironment({ version, config });
      const settings = await (await env.openRule('rule')).openItemSettings('subscription_url', 'sub');
      const option = settings.map.children[0].children.find((o) => o.option === 'user_agent');
      assert.equal(option.formvalue('settings'), 'Clash/1.0');
      await settings.save();
      assert.deepEqual(env.uci.data, config, 'an unchanged save changed UCI');
      assert.equal(sentUserAgent(env.uci.data), 'Clash/1.0');
    });

    await check(`${version} set and clear`, async () => {
      let env = createEnvironment({ version, config: { rule, sub: sub({}) } });
      let settings = await (await env.openRule('rule')).openItemSettings('subscription_url', 'sub');
      assert.equal(sentUserAgent(env.uci.data), '', 'automatic without a User-Agent');
      settings.setValue('user_agent', 'Mihomo');
      await settings.save();
      assert.equal(env.uci.data.sub.user_agent, 'Mihomo');
      assert.equal(sentUserAgent(env.uci.data), 'Mihomo');

      env = createEnvironment({ version, config: { rule, sub: sub({ user_agent: 'Mihomo' }) } });
      settings = await (await env.openRule('rule')).openItemSettings('subscription_url', 'sub');
      settings.setValue('user_agent', '');
      await settings.save();
      assert.equal(env.uci.data.sub.user_agent, undefined, 'a cleared User-Agent is removed');
      assert.equal(sentUserAgent(env.uci.data), '');
    });

    await check(`${version} control characters`, async () => {
      const env = createEnvironment({ version, config: { rule, sub: sub({}) } });
      const settings = await (await env.openRule('rule')).openItemSettings('subscription_url', 'sub');
      const option = settings.map.children[0].children.find((o) => o.option === 'user_agent');
      settings.setValue('user_agent', 'Bad\r\nX-Injected: 1');
      assert.equal(option.isValid('settings'), false);
    });
  }

  if (failures.length) {
    for (const failure of failures) console.error(`FAIL: ${failure}`);
    process.exit(1);
  }
  console.log('luci_subscription_user_agent: ok');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
