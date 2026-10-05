#!/usr/bin/env bash
set -euo pipefail

# FE-14 on the Settings page (real settings.js under
# tests/helpers/luci_form_harness.js): the EDNS Client Subnet field takes
# what the router's validator takes (config/validator.uc
# valid_netip_addr_or_prefix, tests/dns_client_subnet.sh) and refuses the
# rest on save, instead of a saved value that stops the next start. The
# addresses not intercepted by the client DNS intercept (NET-12) are read
# the same way.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

const installed = { loaded: true, zapretInstalled: true, zapret2Installed: true, byedpiInstalled: true };
const config = () => ({
  settings: { '.name': 'settings', '.type': 'settings', '.anonymous': false, yacd_secret_key: 'secret-0123456789' },
});
const accepted = ['203.0.113.0/24', '203.0.113.7', '2001:db8::/56', '2001:db8::1', ' 198.51.100.0/24 '];
const refused = [':', ':::::', '1.2.3.4:', 'fffff::', '1:2:3:4:5:6:7:8:9:a', '203.0.113.0/33', '203.000.113.0/24',
  '203.0.113.0/024', '2001:db8::/129', 'example.com', '203.0.113.0/', '1.2.3'];

(async () => {
  for (const version of ['24.10', '25.12']) {
    const env = createEnvironment({ version, config: config() });
    const settings = await env.openSettings(installed);
    const option = settings.option('dns_client_subnet');
    for (const value of accepted) {
      option.getUIElement('settings').setValue(value);
      assert.equal(option.isValid('settings'), true, `${version}: '${value}' must be accepted`);
    }
    for (const value of refused) {
      option.getUIElement('settings').setValue(value);
      assert.equal(option.isValid('settings'), false, `${version}: '${value}' must be refused`);
    }
    const exclude = settings.option('intercept_client_dns_exclude');
    assert(exclude, 'the exclusions of the client DNS intercept are on the page');
    assert.equal(exclude.validate('settings', '192.168.1.53'), true);
    assert.equal(exclude.validate('settings', '2001:db8:53::/48'), true);
    assert.notEqual(exclude.validate('settings', 'example.com'), true);
    assert.notEqual(exclude.validate('settings', ':::::'), true);
  }
  console.log('luci_dns_client_subnet: ok');
})().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
NODE
