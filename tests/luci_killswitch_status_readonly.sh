#!/usr/bin/env bash
set -euo pipefail

# The kill-switch status of the Settings page (and of each Connection rule
# on the Rules page) is read through /usr/libexec/prokop-ro killswitch_status,
# the read grant of luci-app-prokop. Those pages are not admin-only: a viewer
# role that may read every ACL group, luci-app-prokop-admin included (it only
# grants read access), opens them in read-only mode (L.hasViewPermission()
# is false, the form map is read-only), and the read-only session may run the
# CLI only through the wrapper (UC-001). So the grant stays in the read group
# and in readonlyCommandGuard (UC-231 checked: a read-only page needs it).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const { createEnvironment } = require(path.join(root, 'tests/helpers/luci_form_harness.js'));
// main.js logs every CLI call at debug level.
const print = console.log;
console.log = (...args) => `${args[0]}`.startsWith('[DEBUG]') || print(...args);

const RO = '/usr/libexec/prokop-ro';
const read = (file) => JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
const acl = read('luci-app-prokop/root/usr/share/rpcd/acl.d/luci-app-prokop.json');
const menu = read('luci-app-prokop/root/usr/share/luci/menu.d/luci-app-prokop.json');

// Settings and Rules need luci-app-prokop-admin, which has no write level:
// a role that may read it opens both pages read-only.
for (const page of ['settings', 'rules'])
  assert.deepEqual(menu[`admin/services/prokop/${page}`].depends, { acl: ['luci-app-prokop-admin'] });
assert.deepEqual(Object.keys(acl['luci-app-prokop-admin']), ['description', 'read']);
assert.deepEqual(acl['luci-app-prokop'].read.file[`${RO} killswitch_status`], ['exec'],
  'the read-only Settings and Rules pages read the kill-switch status through the wrapper');

(async () => {
  for (const version of ['24.10', '25.12']) {
    const calls = [];
    const env = createEnvironment({
      version,
      config: { settings: { '.name': 'settings', '.type': 'settings', '.anonymous': false } },
      fs: {
        exec(command, args) {
          calls.push([command, ...args].join(' '));
          return Promise.resolve({ code: 0, stdout: JSON.stringify({ configured: ['vpn'], prokop_running: true,
            active: true, persistent: true }), stderr: '' });
        },
      },
    });
    const settings = await env.openSettings({ loaded: true, zapretInstalled: true, zapret2Installed: true,
      byedpiInstalled: true });
    // A read-only session: LuCI marks the form map read-only.
    settings.map.readonly = true;
    const rendered = settings.option('_kill_switch_status').renderWidget('settings');
    await env.settle();
    assert(rendered, `${version}: no kill-switch status rendered`);
    assert.deepEqual(calls.filter((call) => /killswitch/.test(call)), [`${RO} killswitch_status`],
      `${version}: the read-only status must be read through the wrapper only`);
    assert(!calls.some((call) => call.startsWith('/usr/bin/prokop ')),
      `${version}: a read-only page ran the CLI directly: ${calls.join(', ')}`);
  }
  console.log('luci_killswitch_status_readonly: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
