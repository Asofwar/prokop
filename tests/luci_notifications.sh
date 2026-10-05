#!/usr/bin/env bash
set -euo pipefail

# The Notifications tab of Settings (notifications.js): the bot token and
# the webhook URL are never put on the page, an empty field keeps the saved
# value, a new one replaces it, values the backend would not take are
# refused, the rule for the proxy route is chosen like the download rules,
# and the test answer is told in words, never as raw codes.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" "$ROOT_DIR" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createEnvironment } = require(process.argv[2]);
const root = process.argv[3];

const TOKEN = '123456789:AAH-secretsecretsecretsecretsecret_x';
function config(values) {
  return {
    vpn: { '.name': 'vpn', '.type': 'section', '.anonymous': false, enabled: '1', action: 'connection',
      label: 'VPN', selector_proxy_links: ['socks5://10.0.0.1:1080'] },
    settings: Object.assign({ '.name': 'settings', '.type': 'settings', '.anonymous': false,
      yacd_secret_key: 'secret-0123456789' }, values),
  };
}
const installed = { loaded: true, zapretInstalled: true, zapret2Installed: true, byedpiInstalled: true };

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
    await check(`${version} secrets are not shown and an empty field keeps them`, async () => {
      const env = createEnvironment({ version, config: config({ notify_enabled: '1', notify_telegram_token: TOKEN,
        notify_telegram_chat_id: '-1001234567', notify_webhook_url: 'https://ntfy.example/topic' }) });
      const settings = await env.openSettings(installed);
      for (const name of ['notify_telegram_token', 'notify_webhook_url']) {
        const option = settings.option(name);
        assert.equal(option.cfgvalue('settings'), '', `${name} must never be filled from the config`);
        assert.equal(option.formvalue('settings'), '', `${name} widget must stay empty`);
        assert.equal(option.password, true, `${name} must be a password field`);
      }
      assert.match(settings.option('notify_telegram_token').placeholder, /Saved/);
      await settings.save();
      assert.equal(env.uci.data.settings.notify_telegram_token, TOKEN, 'an empty field removed the token');
      assert.equal(env.uci.data.settings.notify_webhook_url, 'https://ntfy.example/topic');
    });

    await check(`${version} a new token replaces the saved one`, async () => {
      const env = createEnvironment({ version, config: config({ notify_enabled: '1', notify_telegram_token: TOKEN }) });
      const settings = await env.openSettings(installed);
      const other = '987654321:BBH-othersecretothersecretothersecret';
      settings.option('notify_telegram_token').getUIElement('settings').setValue(other);
      await settings.save();
      assert.equal(env.uci.data.settings.notify_telegram_token, other);
    });

    await check(`${version} invalid values are refused`, async () => {
      for (const [name, value] of [['notify_telegram_token', 'not a token'], ['notify_telegram_chat_id', 'chat 1'],
        ['notify_webhook_url', 'ftp://x'], ['notify_webhook_url', 'https://a/b"c'],
        ['notify_subscription_expire_days', '45']]) {
        const env = createEnvironment({ version, config: config({ notify_enabled: '1' }) });
        const settings = await env.openSettings(installed);
        const option = settings.option(name);
        assert.notEqual(option.validate('settings', value), true, `${name}=${value} must be refused`);
      }
      const env = createEnvironment({ version, config: config({ notify_enabled: '1' }) });
      const settings = await env.openSettings(installed);
      assert.equal(settings.option('notify_telegram_chat_id').validate('settings', '@my_channel'), true);
      assert.equal(settings.option('notify_telegram_chat_id').validate('settings', '-1001234567'), true);
      assert.equal(settings.option('notify_webhook_url').validate('settings', 'https://gotify.lan/message?token=abc'), true);
      assert.equal(settings.option('notify_telegram_token').validate('settings', ''), true, 'empty keeps the saved one');
    });

    await check(`${version} the proxy rule is chosen like the download rules`, async () => {
      const env = createEnvironment({ version, config: config({ notify_enabled: '1', notify_via_proxy: '1',
        notify_via_proxy_section: 'gone' }) });
      const settings = await env.openSettings(installed);
      const select = settings.option('notify_via_proxy_section');
      assert.equal(select.formvalue('settings'), 'gone');
      assert.equal(select.keylist.includes('vpn'), true);
      await assert.rejects(settings.save());
      select.getUIElement('settings').setValue('vpn');
      await settings.save();
      assert.equal(env.uci.data.settings.notify_via_proxy_section, 'vpn');
    });

    await check(`${version} turning the route off forgets the rule`, async () => {
      const env = createEnvironment({ version, config: config({ notify_enabled: '1', notify_via_proxy: '1',
        notify_via_proxy_section: 'vpn' }) });
      const settings = await env.openSettings(installed);
      settings.option('notify_via_proxy').getUIElement('settings').setValue('0');
      await settings.save();
      assert.equal(env.uci.data.settings.notify_via_proxy, '0');
      assert.equal(env.uci.data.settings.notify_via_proxy_section, undefined);
    });
  }

  // The test answer, as the page words it.
  const env = createEnvironment({ version: '25.12', config: config({}) });
  await env.openSettings(installed);
  const source = fs.readFileSync(path.join(root,
    'luci-app-prokop/htdocs/luci-static/resources/view/prokop/notifications.js'), 'utf8');
  assert.match(source, /fs\s*\.exec\(PROKOP_BIN, \["notify_test"\]\)/, 'the button must run notify_test');
  const notifications = env.notificationsView;
  {
    const lines = notifications.resultLines({ status: 'failed', channels: [
      { channel: 'telegram', status: 'failed', reason: 'token_rejected', route: 'proxy' },
      { channel: 'webhook', status: 'ok', route: 'direct' },
      { channel: 'webhook', status: 'failed', reason: 'http_502' }] });
    assert.deepEqual(lines, ['Telegram: Telegram did not accept the bot token (through the rule)',
      'Webhook: Delivered (directly)', 'Webhook: The server answered HTTP 502']);
  }

  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_notifications: PASS');
})();
NODE
