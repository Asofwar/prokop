#!/usr/bin/env bash
set -euo pipefail

# D-18 (a), UC-091 on the Settings page (real settings.js under
# tests/helpers/luci_form_harness.js): automatic list updates and component
# update checks run at most once an hour.
# - A new interval shorter than 1h (1m, 30m, 100ms) is refused; 1h and more
#   are saved as entered.
# - An interval the configuration already holds below 1h is shown as it is,
#   with a warning, does not block saving, and is saved as 1h.
# - A save that changes nothing leaves the stored values alone.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

const installed = { loaded: true, zapretInstalled: true, zapret2Installed: true, byedpiInstalled: true };
const config = (values) => ({
  settings: Object.assign({ '.name': 'settings', '.type': 'settings', '.anonymous': false,
    yacd_secret_key: 'secret-0123456789', list_update_enabled: '1', component_update_check_enabled: '1' }, values),
});
const KEYS = ['update_interval', 'component_update_check_interval'];

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
    for (const key of KEYS) {
      await check(`${version} ${key}: new values`, async () => {
        for (const [entered, valid] of [['1m', false], ['30m', false], ['100ms', false], ['59m59s', false],
          ['1h', true], ['90m', true], ['1d', true]]) {
          const env = createEnvironment({ version, config: config({ [key]: '1d' }) });
          const settings = await env.openSettings(installed);
          const option = settings.option(key);
          option.getUIElement('settings').setValue(entered);
          assert.equal(option.isValid('settings'), valid, `${entered}: valid ${valid}`);
          if (valid) {
            await settings.save();
            assert.equal(env.uci.data.settings[key], entered, `${entered} is saved as entered`);
          } else {
            assert.match(option.getValidationError('settings'), /at least 1h/);
            await assert.rejects(settings.save());
            assert.equal(env.uci.data.settings[key], '1d', `a refused ${entered} changed UCI`);
          }
        }
      });

      await check(`${version} ${key}: stored short interval`, async () => {
        const env = createEnvironment({ version, config: config({ [key]: '5m' }) });
        const settings = await env.openSettings(installed);
        const option = settings.option(key);
        assert.equal(option.formvalue('settings'), '5m', 'the stored value is shown as it is');
        assert.match(option.description, /saved interval 5m is shorter than 1h/);
        assert.equal(option.isValid('settings'), true, 'a stored short interval does not block saving');
        await settings.save();
        assert.equal(env.uci.data.settings[key], '1h', 'saving raises it to 1h');
      });

      await check(`${version} ${key}: unchanged save`, async () => {
        const stored = config({ update_interval: '6h', component_update_check_interval: '1d' });
        const env = createEnvironment({ version, config: stored });
        const settings = await env.openSettings(installed);
        assert.doesNotMatch(settings.option(key).description, /shorter than 1h/);
        await settings.save();
        assert.equal(env.uci.data.settings[key], stored.settings[key]);
      });

      await check(`${version} ${key}: absent option, unchanged save`, async () => {
        // The field shows the default 1d; a save that changes nothing must
        // not write it (no prokop change to apply).
        const env = createEnvironment({ version, config: config({}) });
        const settings = await env.openSettings(installed);
        assert.equal(settings.option(key).formvalue('settings'), '1d');
        await settings.save();
        assert.equal(env.uci.data.settings[key], undefined, 'an absent interval was written');
      });

      await check(`${version} ${key}: absent option, new value`, async () => {
        const env = createEnvironment({ version, config: config({}) });
        const settings = await env.openSettings(installed);
        settings.option(key).getUIElement('settings').setValue('2h');
        await settings.save();
        assert.equal(env.uci.data.settings[key], '2h');
      });
    }
  }

  if (failures.length) {
    for (const failure of failures) console.error(`FAIL: ${failure}`);
    process.exit(1);
  }
  console.log('luci_update_interval_minimum: ok');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
