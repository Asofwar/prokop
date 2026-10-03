#!/usr/bin/env bash
set -euo pipefail

# The LuCI pages read a rule's enabled flag the way the backend does
# (core/common.uc section_enabled, UC-105/UC-172): unset is on; 1, true, yes
# or on in any letter case is on; anything else is off. A hand-edited 'On'
# rule is enabled in sing-box and nft, so the Rules grid shows it checked and
# an untouched save keeps it; an 'Off'/'false' rule is disabled there, so the
# rule modal and Settings do not offer it as a DNS or download section. The
# pages are the shipped section.js and settings.js under
# tests/helpers/luci_form_harness.js.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

function section(name, values) {
  return Object.assign({ '.name': name, '.type': 'section', '.anonymous': false, enabled: '1',
    label: name.toUpperCase() }, values);
}
const routed = { mixed_proxy_enabled: '0' };
const targets = (on, off) => ({
  vpn: section('vpn', { enabled: on, action: 'connection', ...routed, selector_proxy_links: ['socks5://10.0.0.1:1080'] }),
  off: section('off', { enabled: off, action: 'connection', ...routed, selector_proxy_links: ['socks5://10.0.0.2:1080'] }),
});
const dnsThrough = (target) => section('rule', { action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1',
  domain: 'example.net', dns_detour_enabled: '1', dns_detour_section: target });
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
    for (const [on, off] of [['On', 'Off'], ['TRUE', 'false'], ['yes', 'NO']]) {
      await check(`${version} ${on}/${off}: rule modal DNS section`, async () => {
        const config = { rule: dnsThrough('off'), ...targets(on, off) };
        const env = createEnvironment({ version, config });
        const modal = await env.openRule('rule');
        const option = modal.option('dns_detour_section');
        assert.match(option.vallist[option.keylist.indexOf('off')], /^OFF \(disabled\)$/);
        assert.equal(option.vallist[option.keylist.indexOf('vpn')], 'VPN', 'an enabled rule is a plain choice');
        await assert.rejects(modal.save());
        assert.deepEqual(env.uci.data, config, 'a refused save changed UCI');
      });

      await check(`${version} ${on}/${off}: Settings download section`, async () => {
        const config = { ...targets(on, off), settings: { '.name': 'settings', '.type': 'settings', '.anonymous': false,
          yacd_secret_key: 'secret-0123456789', download_lists_via_proxy: '1',
          download_lists_via_proxy_section: 'off' } };
        const env = createEnvironment({ version, config });
        const settings = await env.openSettings(installed);
        const select = settings.option('download_lists_via_proxy_section');
        assert.match(select.vallist[select.keylist.indexOf('off')], /^OFF \(disabled\)$/);
        assert.equal(select.vallist[select.keylist.indexOf('vpn')], 'VPN', 'an enabled rule is offered');
        await assert.rejects(settings.save());
        select.getUIElement('settings').setValue('vpn');
        await settings.save();
        assert.equal(env.uci.data.settings.download_lists_via_proxy_section, 'vpn');
      });

      await check(`${version} ${on}/${off}: Rules grid Enable flag`, async () => {
        const config = targets(on, off);
        const env = createEnvironment({ version, config });
        const rules = await env.openRules();
        const [enabledOn, rowOn] = rules.map.lookupOption('enabled', 'vpn');
        const [enabledOff, rowOff] = rules.map.lookupOption('enabled', 'off');
        assert.equal(enabledOn.cfgvalue(rowOn), enabledOn.enabled, `'${on}' shows checked`);
        assert.equal(enabledOff.cfgvalue(rowOff), enabledOff.disabled, `'${off}' shows unchecked`);
        await rules.save();
        assert.deepEqual(env.uci.data, config, 'an untouched page save rewrote the flag');

        // A changed checkbox writes the LuCI spelling.
        const toggled = createEnvironment({ version, config });
        const page = await toggled.openRules();
        page.setEnabled('vpn', '0');
        page.setEnabled('off', '1');
        await page.save();
        assert.equal(toggled.uci.data.vpn.enabled, '0', 'unchecking writes 0');
        assert.equal(toggled.uci.data.off.enabled, '1', 'checking writes 1');
      });
    }
  }

  if (failures.length) {
    console.error(failures.join('\n'));
    process.exit(1);
  }
  console.log('luci_enabled_flag_case: PASS');
})();
NODE
