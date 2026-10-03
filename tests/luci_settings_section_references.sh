#!/usr/bin/env bash
set -euo pipefail

# Settings "through a section" selects (DNS, lists and components downloads)
# keep a saved section that is disabled, uses a DPI provider that is not
# installed, or no longer exists: the value stays selected with a label and
# Save is refused until the user picks another section, instead of silently
# re-pointing to the first eligible rule (UC-008). The provider availability
# the Settings page gets from shell.js follows availability updates after
# Components installs or removes a provider (UC-152). Every selected section
# is checked as the save leaves it: provider changes on the same page, the
# rules as the Rules page saved them. The pages are the shipped
# page/settings.js and page/rules.js: on the Rules page, deleting or
# disabling (row or rule modal) the rule that Settings use, or switching it
# in the rule modal to an action that carries no DNS or downloads, is
# refused and explained, and a rule removal that a refused page save blocks
# is undone and reported instead of failing silently or staying staged for
# the next save (UC-199).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

function section(name, values) {
  return Object.assign({ '.name': name, '.type': 'section', '.anonymous': false, enabled: '1',
    label: name.toUpperCase() }, values);
}
const baseConfig = {
  vpn: section('vpn', { action: 'connection', selector_proxy_links: ['socks5://10.0.0.1:1080'] }),
  off: section('off', { enabled: '0', action: 'connection', selector_proxy_links: ['socks5://10.0.0.2:1080'] }),
  // Stored as a rule modal Save leaves it.
  dpi: section('dpi', { action: 'zapret', mixed_proxy_enabled: '0', community_lists: ['youtube'] }),
};
function settingsConfig(values) {
  return Object.assign({}, baseConfig, {
    settings: Object.assign({ '.name': 'settings', '.type': 'settings', '.anonymous': false,
      yacd_secret_key: 'secret-0123456789' }, values),
  });
}
const installed = { loaded: true, zapretInstalled: true, zapret2Installed: true, byedpiInstalled: true };
const noZapret = Object.assign({}, installed, { zapretInstalled: false });

const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.stack || error.message}`);
  }
}

const references = [
  ['dns_detour_enabled', 'dns_detour_section'],
  ['download_lists_via_proxy', 'download_lists_via_proxy_section'],
  ['download_components_via_proxy', 'download_components_via_proxy_section'],
];

(async () => {
  for (const version of ['24.10', '25.12']) {
    for (const [flag, option] of references)
      for (const [label, value, capabilities, mark] of [
        ['disabled section', 'off', installed, /^OFF \(disabled\)$/],
        ['provider not installed', 'dpi', noZapret, /^DPI \(provider not installed\)$/],
        ['deleted section', 'gone', installed, /^gone \(unavailable\)$/],
      ]) await check(`${version} ${option}: ${label}`, async () => {
        const env = createEnvironment({ version, config: settingsConfig({ [flag]: '1', [option]: value }) });
        const settings = await env.openSettings(capabilities);
        const select = settings.option(option);
        assert.equal(select.formvalue('settings'), value, 'the widget must keep the saved section');
        assert.match(select.vallist[select.keylist.indexOf(value)], mark);
        assert.equal(select.keylist.includes('vpn'), true, 'eligible sections are still offered');
        await assert.rejects(settings.save());
        assert.equal(env.uci.data.settings[option], value, 'a refused save re-pointed the section');

        select.getUIElement('settings').setValue('vpn');
        await settings.save();
        assert.equal(env.uci.data.settings[option], 'vpn', 'an explicit choice is saved');
      });

    // An available saved section saves unchanged.
    await check(`${version} available section`, async () => {
      const env = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'dpi' }) });
      const settings = await env.openSettings(installed);
      await settings.save();
      assert.equal(env.uci.data.settings.dns_detour_section, 'dpi');
    });

    // The selected section is checked as this save leaves it: the Settings
    // page reads the rules as the Rules page saved them (uci.get with staged
    // edits), not as LuCI loaded them (uci.state.values).
    const loadedValues = (env) => {
      env.uci.state.values = { prokop: JSON.parse(JSON.stringify(env.uci.data)) };
    };
    await check(`${version} section enabled on the Rules page`, async () => {
      const env = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'off' }) });
      loadedValues(env);
      const rules = await env.openRules();
      rules.setEnabled('off', '1');
      await rules.save();
      assert.equal(env.uci.data.off.enabled, '1');
      const settings = await env.openSettings(installed);
      assert.equal(settings.option('dns_detour_section').isValid('settings'), true);
      await settings.save();
      assert.equal(env.uci.data.settings.dns_detour_section, 'off');
    });

    // UC-152 both ways: Components removes the provider on the same page.
    await check(`${version} provider removed on the same page`, async () => {
      const env = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'dpi' }) });
      const shell = env.shell();
      env.main.ProkopShellMethods.getUiCapabilities = () => Promise.resolve({ success: true,
        data: { zapret_installed: 1, zapret2_installed: 1, byedpi_installed: 1 } });
      await shell.loadUiCapabilities();
      const settings = await env.openSettings(shell.uiCapabilities);
      env.window.dispatchEvent(new env.CustomEvent(env.main.PROKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT,
        { detail: { zapretInstalled: false, zapret2Installed: true, byedpiInstalled: true } }));
      await assert.rejects(settings.save(), /The DPI provider of the selected section is not installed/);
      assert.equal(env.uci.data.settings.dns_detour_section, 'dpi');

      settings.option('dns_detour_section').getUIElement('settings').setValue('vpn');
      await settings.save();
      assert.equal(env.uci.data.settings.dns_detour_section, 'vpn');
    });

    // UC-199: the Rules page is a page of its own. Deleting or disabling the
    // rule that Settings use for DNS or for downloads is refused there and
    // explained, instead of leaving Settings pointing to a rule that the
    // backend then rejects as missing or disabled. Nothing stays staged: the
    // next save (a rule modal Save sends the whole package through uci.save)
    // must not apply the refused change, nor the cleanup of the rule's child
    // items.
    const usedFor = {
      dns: [{ dns_detour_enabled: '1', dns_detour_section: 'vpn' }, 'DNS through proxy'],
      lists: [{ download_lists_via_proxy: '1', download_lists_via_proxy_section: 'vpn' },
        'Download lists through a section'],
      components: [{ download_components_via_proxy: '1', download_components_via_proxy_section: 'vpn' },
        'Download components through a section'],
      // validator.uc downloads components through the lists section when
      // none is selected for them.
      'components through the lists section': [{ download_components_via_proxy: '1',
        download_lists_via_proxy_section: 'vpn' }, 'Download components through a section'],
    };
    const referencedConfig = (settings) => {
      const config = settingsConfig(settings);
      config.vpn = Object.assign({}, config.vpn, { subscription_url: ['vpnsub'] });
      config.vpnsub = { '.name': 'vpnsub', '.type': 'subscription_url', '.anonymous': false, section: 'vpn',
        url: 'https://example.com/sub', subscription_update_enabled: '1', subscription_update_interval: '4h' };
      return config;
    };
    const capture = (env) => {
      const notifications = [];
      env.ui.addNotification = (_title, node, type) => notifications.push({ type, text: node.textContent });
      return notifications;
    };
    const inSettings = (title) => new RegExp(`This rule is selected in Settings for: ${title}\\. ` +
      'Choose another section there first\\.');
    const modalRefusal = (modal) =>
      modal.map.root.querySelector('.fkp-rule-save-refusal')?.textContent || '';
    // The next save of the page: a rule modal Save sends every staged edit.
    const nextSave = async (env, config) => {
      await (await env.openRule('dpi')).saveButton();
      assert.deepEqual(env.uci.data, config, 'the next save applied a refused change');
    };
    for (const [use, [settings, title]] of Object.entries(usedFor)) {
      await check(`${version} Rules page: removing the rule used for ${use}`, async () => {
        const config = referencedConfig(settings);
        const env = createEnvironment({ version, config });
        loadedValues(env);
        const notifications = capture(env);
        await (await env.openRules()).removeRule('vpn');
        assert.equal(notifications.length, 1, 'the refused removal must be reported');
        assert.equal(notifications[0].type, 'error');
        assert.match(notifications[0].text, /^The rule was not removed\. /);
        assert.match(notifications[0].text, inSettings(title));
        assert.deepEqual(env.uci.data, config, 'a refused removal stayed staged');
        await nextSave(env, config);
      });

      await check(`${version} Rules page: disabling the rule used for ${use}`, async () => {
        const config = referencedConfig(settings);
        const env = createEnvironment({ version, config });
        loadedValues(env);
        const rules = await env.openRules();
        rules.setEnabled('vpn', '0');
        await assert.rejects(rules.save(), inSettings(title));
        assert.deepEqual(env.uci.data, config, 'a refused disable stayed staged');
        await nextSave(env, config);
      });

      await check(`${version} rule modal: disabling the rule used for ${use}`, async () => {
        const config = referencedConfig(settings);
        const env = createEnvironment({ version, config });
        loadedValues(env);
        const modal = await env.openRule('vpn');
        modal.option('enabled').getUIElement('vpn').setValue('0');
        await assert.rejects(modal.save(), inSettings(title));
        assert.deepEqual(env.uci.data, config, 'a refused modal save changed UCI');

        // LuCI drops the refusal of the modal Save, and the checkbox shows
        // it only as a tooltip: the modal says why.
        await modal.saveButton();
        assert.match(modalRefusal(modal), inSettings(title), 'the refusal must be shown in the modal');
        assert.deepEqual(env.uci.data, config, 'a refused modal save changed UCI');
        await nextSave(env, config);
      });

      // An action that cannot carry DNS or downloads (validator.uc
      // download_section_action_available) makes the rule as unusable for
      // Settings as removing it. The action is edited only in the rule modal.
      for (const action of ['block', 'bypass', 'dns'])
        await check(`${version} rule modal: switching the rule used for ${use} to ${action}`, async () => {
          const config = referencedConfig(settings);
          const env = createEnvironment({ version, config });
          loadedValues(env);
          const modal = await env.openRule('vpn');
          modal.option('action').getUIElement('vpn').setValue(action);
          await assert.rejects(modal.save(), inSettings(title));
          assert.deepEqual(env.uci.data, config, 'a refused modal save changed UCI');

          await modal.saveButton();
          assert.match(modalRefusal(modal), inSettings(title), 'the refusal must be shown in the modal');
          assert.deepEqual(env.uci.data, config, 'a refused modal save changed UCI');
          await (await env.openRules()).save();
          assert.deepEqual(env.uci.data, config, 'the Rules page saved a refused action');
          await nextSave(env, config);
        });
    }

    // Another action that carries DNS and downloads keeps the rule usable.
    await check(`${version} rule modal: the rule used for DNS switched to another usable action`, async () => {
      const config = referencedConfig(usedFor.dns[0]);
      config.vpn.mixed_proxy_enabled = '0';
      config.vpn.community_lists = ['youtube'];
      const env = createEnvironment({ version, config, fs: { exec: (_command, args) => Promise.resolve({ code: 0,
        stdout: args && args[0] === 'validate_byedpi_strategy_json' ? '{"valid":true}' : '{}', stderr: '' }) } });
      const modal = await env.openRule('vpn');
      modal.option('action').getUIElement('vpn').setValue('byedpi');
      modal.option('byedpi_cmd_opts').getUIElement('vpn').setValue('-o 1 -d 2');
      await modal.save();
      assert.equal(env.uci.data.vpn.action, 'byedpi');
      assert.equal(modalRefusal(modal), '', 'a save that passes must not show a refusal');
    });

    // Every setting that uses the rule is named.
    await check(`${version} Rules page: a rule used for DNS and downloads`, async () => {
      const config = referencedConfig(Object.assign({}, usedFor.dns[0], usedFor.lists[0]));
      const env = createEnvironment({ version, config });
      const notifications = capture(env);
      await (await env.openRules()).removeRule('vpn');
      assert.match(notifications[0].text,
        inSettings('DNS through proxy, Download lists through a section'));
      assert.deepEqual(env.uci.data, config);
    });

    // Only a setting that is on uses its section; a rule left selected in a
    // setting that is off is removed and disabled as usual.
    await check(`${version} Rules page: a rule left selected in settings that are off`, async () => {
      const settings = { dns_detour_enabled: '0', dns_detour_section: 'vpn', download_lists_via_proxy: '0',
        download_lists_via_proxy_section: 'vpn', download_components_via_proxy: '0',
        download_components_via_proxy_section: 'vpn' };
      const disabled = createEnvironment({ version, config: settingsConfig(settings) });
      const rules = await disabled.openRules();
      rules.setEnabled('vpn', '0');
      await rules.save();
      assert.equal(disabled.uci.data.vpn.enabled, '0');

      const removed = createEnvironment({ version, config: settingsConfig(settings) });
      const notifications = capture(removed);
      await (await removed.openRules()).removeRule('vpn');
      assert.equal(removed.uci.data.vpn, undefined, 'the rule was not removed');
      assert.deepEqual(notifications, []);

      const switched = createEnvironment({ version, config: settingsConfig(settings) });
      const modal = await switched.openRule('vpn');
      modal.option('action').getUIElement('vpn').setValue('block');
      await modal.save();
      assert.equal(switched.uci.data.vpn.action, 'block');
    });

    // A Settings section that is already unavailable is fixed in Settings: it
    // does not hold up other changes on the Rules page, and a rule that was
    // already disabled stays as it is.
    await check(`${version} Rules page: Settings already on an unavailable section`, async () => {
      for (const section of ['off', 'gone']) {
        const env = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
          dns_detour_section: section }) });
        const notifications = capture(env);
        const rules = await env.openRules();
        await rules.save();
        assert.equal(env.uci.data.off.enabled, '0');
        await rules.removeRule('dpi');
        assert.equal(env.uci.data.dpi, undefined, 'an unrelated removal was refused');
        assert.deepEqual(notifications, []);
      }

      // Neither does a rule that Settings could not use before this save: a
      // disabled one switched to another action, one whose action already
      // carries no DNS switched again or disabled.
      const config = settingsConfig({ dns_detour_enabled: '1', dns_detour_section: 'off',
        download_lists_via_proxy: '1', download_lists_via_proxy_section: 'blk' });
      config.blk = section('blk', { action: 'block', domain: 'blocked.example' });
      for (const [name, edit, saved] of [
        ['off', (modal) => modal.option('action').getUIElement('off').setValue('block'), { action: 'block' }],
        ['blk', (modal) => modal.option('action').getUIElement('blk').setValue('bypass'), { action: 'bypass' }],
        ['blk', (modal) => modal.option('enabled').getUIElement('blk').setValue('0'), { enabled: '0' }],
      ]) {
        const env = createEnvironment({ version, config });
        const modal = await env.openRule(name);
        edit(modal);
        await modal.save();
        for (const [key, value] of Object.entries(saved)) assert.equal(env.uci.data[name][key], value);
      }
      const env = createEnvironment({ version, config });
      const rules = await env.openRules();
      rules.setEnabled('blk', '0');
      await rules.save();
      assert.equal(env.uci.data.blk.enabled, '0');
    });

    // Deleting a rule saves the whole page silently in LuCI. When another
    // field refuses that save, the row stays, the removal and the cleanup of
    // its child items are undone, and the user is told why.
    await check(`${version} rule removal refused by the page save`, async () => {
      const config = referencedConfig(usedFor.dns[0]);
      config.off = Object.assign({}, config.off, { subscription_url: ['offsub'] });
      config.offsub = Object.assign({}, config.vpnsub, { '.name': 'offsub', section: 'off' });
      const env = createEnvironment({ version, config });
      loadedValues(env);
      const notifications = capture(env);
      const rules = await env.openRules();
      rules.setEnabled('vpn', '0');
      await rules.removeRule('off');
      assert.equal(notifications.length, 1, 'a refused removal must be reported');
      assert.equal(notifications[0].type, 'error');
      assert.match(notifications[0].text, /The rule was not removed because the page could not be saved/);
      assert.match(notifications[0].text, inSettings('DNS through proxy'));
      assert.deepEqual(env.uci.data, config, 'a refused removal stayed staged');
      await nextSave(env, config);

      // Control: a removal that saves reports nothing.
      const ok = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'vpn' }) });
      const okNotifications = capture(ok);
      await (await ok.openRules()).removeRule('off');
      assert.equal(ok.uci.data.off, undefined);
      assert.deepEqual(okNotifications, [], 'a saved removal must not report an error');
    });

    // UC-152: shell.uiCapabilities (what page/settings.js passes to the
    // Settings tabs) follows the provider availability event.
    await check(`${version} shell capabilities follow availability updates`, async () => {
      const env = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'dpi' }) });
      const shell = env.shell();
      env.main.ProkopShellMethods.getUiCapabilities = () => Promise.resolve({ success: true,
        data: { zapret_installed: 0, zapret2_installed: 0, byedpi_installed: 0 } });
      await shell.loadUiCapabilities();
      assert.equal(shell.uiCapabilities.zapretInstalled, false);
      let settings = await env.openSettings(shell.uiCapabilities);
      await assert.rejects(settings.save(), /not installed/);

      // Components installed Zapret.
      env.window.dispatchEvent(new env.CustomEvent(env.main.PROKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT,
        { detail: { zapretInstalled: true, zapret2Installed: false, byedpiInstalled: false } }));
      assert.equal(shell.uiCapabilities.zapretInstalled, true, 'shell capabilities were not refreshed');
      // Components is a tab of the same page: Settings saves without a reload.
      await settings.save();
      assert.equal(env.uci.data.settings.dns_detour_section, 'dpi');

      settings = await env.openSettings(shell.uiCapabilities);
      const select = settings.option('dns_detour_section');
      assert.equal(select.vallist[select.keylist.indexOf('dpi')], 'DPI');
      await settings.save();
      assert.equal(env.uci.data.settings.dns_detour_section, 'dpi');

      // Status polling refreshes the store; a removal reaches the shell copy too.
      const setZapret = (installed) => env.main.store.set({ diagnosticsSystemInfo: {
        ...env.main.store.get().diagnosticsSystemInfo, providerInfoLoaded: true, zapret_installed: installed } });
      setZapret(1);
      assert.equal(shell.uiCapabilities.zapretInstalled, true);
      setZapret(0);
      assert.equal(shell.uiCapabilities.zapretInstalled, false, 'store update did not reach the shell');
    });
  }
  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_settings_section_references: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
