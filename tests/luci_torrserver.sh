#!/usr/bin/env bash
set -euo pipefail

# The TorrServer tab of Settings (torrserver.js): the API password is never
# put on the page, an empty field keeps the saved one, a new one replaces
# it, protection turned on needs a user name and a password, turning it
# off keeps both; the jail can only be turned on where the firmware has
# procd-ujail, and turned off anywhere.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

function config(values) {
  return {
    settings: Object.assign({ '.name': 'settings', '.type': 'settings', '.anonymous': false,
      yacd_secret_key: 'secret-0123456789' }, values),
  };
}
const caps = (ujailAvailable) => ({ loaded: true, zapretInstalled: false, zapret2Installed: false,
  byedpiInstalled: false, ujailAvailable });

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
    await check(`${version} the password is not shown and an empty field keeps it`, async () => {
      const env = createEnvironment({ version, config: config({ torrserver_auth_enabled: '1',
        torrserver_auth_user: 'admin', torrserver_auth_password: 'p@ss secret' }) });
      const settings = await env.openSettings(caps(true));
      const option = settings.option('torrserver_auth_password');
      assert.equal(option.cfgvalue('settings'), '', 'the password must never be filled from the config');
      assert.equal(option.formvalue('settings'), '');
      assert.equal(option.password, true, 'a password field');
      assert.match(option.placeholder, /Saved/);
      assert.equal(option.validate('settings', ''), true, 'empty keeps the saved one');
      await settings.save();
      assert.equal(env.uci.data.settings.torrserver_auth_password, 'p@ss secret');
      settings.option('torrserver_auth_password').getUIElement('settings').setValue('other');
      await settings.save();
      assert.equal(env.uci.data.settings.torrserver_auth_password, 'other', 'a new password replaces the saved one');
    });

    await check(`${version} protection needs a user name and a password`, async () => {
      const env = createEnvironment({ version, config: config({ torrserver_auth_enabled: '1' }) });
      const settings = await env.openSettings(caps(true));
      const password = settings.option('torrserver_auth_password');
      assert.notEqual(password.validate('settings', ''), true, 'on without a password must be refused');
      assert.notEqual(password.validate('settings', 'a\nb'), true, 'a line break must be refused');
      assert.equal(password.validate('settings', 'secret'), true);
      const user = settings.option('torrserver_auth_user');
      for (const bad of ['', 'ad:min', 'a b', 'x'.repeat(65)])
        assert.notEqual(user.validate('settings', bad), true, `user name ${JSON.stringify(bad)} must be refused`);
      assert.equal(user.validate('settings', 'tv.user@home'), true);
    });

    await check(`${version} turning protection off keeps the user and the password`, async () => {
      const env = createEnvironment({ version, config: config({ torrserver_auth_enabled: '1',
        torrserver_auth_user: 'admin', torrserver_auth_password: 'secret' }) });
      const settings = await env.openSettings(caps(true));
      settings.option('torrserver_auth_enabled').getUIElement('settings').setValue('0');
      await settings.save();
      const data = env.uci.data.settings;
      assert.equal(data.torrserver_auth_enabled, '0');
      assert.equal(data.torrserver_auth_user, 'admin');
      assert.equal(data.torrserver_auth_password, 'secret');
    });

    await check(`${version} the jail needs procd-ujail to be turned on`, async () => {
      let env = createEnvironment({ version, config: config({}) });
      let settings = await env.openSettings(caps(false));
      let jail = settings.option('torrserver_jail');
      assert.match(jail.description, /no procd-ujail/);
      assert.equal(jail.readonly, true, 'without ujail the jail cannot be turned on');
      env = createEnvironment({ version, config: config({ torrserver_jail: '1' }) });
      settings = await env.openSettings(caps(false));
      jail = settings.option('torrserver_jail');
      assert.notEqual(jail.readonly, true, 'a jail that is on can always be turned off');
      env = createEnvironment({ version, config: config({}) });
      settings = await env.openSettings(caps(true));
      jail = settings.option('torrserver_jail');
      assert.notEqual(jail.readonly, true);
      assert.doesNotMatch(jail.description, /procd-ujail package/);
      jail.getUIElement('settings').setValue('1');
      await settings.save();
      assert.equal(env.uci.data.settings.torrserver_jail, '1');
    });
  }

  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_torrserver: PASS');
})();
NODE
