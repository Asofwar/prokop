#!/usr/bin/env bash
set -euo pipefail

# D-23 in the rule editor: the option that lets a protected rule's excluded
# devices resolve its names while Forkop is stopped sits next to the
# kill-switch on the Advanced tab, only for rules that can have the
# kill-switch and only while it is on. Unchecked means absent; an untouched
# save writes nothing, also for a rule whose kill-switch is off (the option
# is kept, the backend ignores it then). The Rules page needs the
# administrator's ACL, and read-only sessions never get the option
# (diagnostics/runtime.uc get_readonly_config_sections). The status of the
# rule shows how many of its names its excluded devices resolve.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" "$ROOT_DIR" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createEnvironment } = require(process.argv[2]);
const ROOT = process.argv[3];

const NAME = 'kill_switch_dns_exempt';
// A Connection rule has a connection: the rule modal refuses to save one
// without (UC-092).
function rule(values) {
  return Object.assign({ '.name': 'rule', '.type': 'section', '.anonymous': false, enabled: '1',
    action: 'connection', mixed_proxy_enabled: '0', domain: 'example.com',
    selector_proxy_links: ['socks5://10.0.0.1:1080'], excluded_source_ip_cidr: ['192.168.1.9'] }, values);
}

const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.message}`);
  }
}

(async () => {
  for (const version of ['24.10', '25.12']) {
    await check(`${version} placement and visibility`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ kill_switch: '1' }) } });
      const modal = await env.openRule('rule');
      const option = modal.option(NAME);
      assert.equal(option.tab, 'advanced', 'next to the kill-switch on the Advanced tab');
      // What it costs: the devices' whole DNS bypasses the router's own
      // settings while Forkop is stopped, and every group runs a resolver.
      assert.match(option.description, /all DNS of these devices goes through that resolver, past the router's own DNS settings/);
      assert.match(option.description, /rebind protection/);
      assert.match(option.description, /own resolver with a copy of the block list in memory, at most 4/);
      const names = modal.map.children[0].children.map((child) => child.option);
      assert.equal(names.indexOf(NAME), names.indexOf('kill_switch') + 1, 'right after the kill-switch');
      assert.equal(modal.active(NAME), true, 'shown while the kill-switch is on');
      assert.equal(option.getUIElement('rule').isChecked(), false, 'off by default');
      modal.option('kill_switch').getUIElement('rule').setValue('0');
      modal.map.checkDepends();
      assert.equal(modal.active(NAME), false, 'hidden while the kill-switch is off');
      modal.option('kill_switch').getUIElement('rule').setValue('1');
      modal.option('action').getUIElement('rule').setValue('bypass');
      modal.map.checkDepends();
      assert.equal(modal.active(NAME), false, 'hidden for actions without the kill-switch');
    });

    await check(`${version} enable and disable`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ kill_switch: '1' }) } });
      let modal = await env.openRule('rule');
      modal.option(NAME).getUIElement('rule').setValue('1');
      await modal.save();
      assert.equal(env.uci.data.rule[NAME], '1', 'checking it stores 1');
      modal = await env.openRule('rule');
      assert.equal(modal.option(NAME).getUIElement('rule').isChecked(), true, 'a stored 1 shows checked');
      modal.option(NAME).getUIElement('rule').setValue('0');
      await modal.save();
      assert.equal(NAME in env.uci.data.rule, false, 'unchecking it removes the option, never writes 0');
    });

    // S2: an untouched save is a no-op.
    for (const [name, values] of [
      ['off', { kill_switch: '1' }],
      ['on', { kill_switch: '1', [NAME]: '1' }],
      ['on without the kill-switch', { [NAME]: '1' }],
    ]) {
      await check(`${version} unchanged modal save, ${name}`, async () => {
        const fixture = rule(values);
        const env = createEnvironment({ version, config: { rule: fixture } });
        await (await env.openRule('rule')).save();
        assert.deepEqual(env.uci.data.rule, fixture, 'an unchanged rule modal save changed UCI');
      });
      await check(`${version} unchanged Rules page save, ${name}`, async () => {
        const fixture = rule(values);
        const env = createEnvironment({ version, config: { rule: fixture } });
        await (await env.openRules()).save();
        assert.deepEqual(env.uci.data.rule, fixture, 'an unchanged Rules page save changed UCI');
      });
    }

    // The CLI may spell both flags as core/common.uc bool_option() reads
    // them (in any letter case, UC-105): they show as the backend reads them, and an untouched save keeps
    // the spelling. Before, a kill-switch stored as "yes" showed unchecked
    // and an untouched save removed it.
    for (const [killSwitch, exempt, checked] of [
      ['yes', 'true', true], ['on', 'yes', true], ['true', 'on', true], ['1', 'off', false],
      ['TRUE', '1', true], ['yes', 'no', false], ['true', 'false', false], ['on', '0', false],
    ]) {
      const values = { kill_switch: killSwitch, [NAME]: exempt };
      const ksOn = ['1', 'true', 'yes', 'on'].includes(killSwitch.toLowerCase());
      await check(`${version} spelled ${killSwitch}/${exempt}`, async () => {
        const fixture = rule(values);
        const env = createEnvironment({ version, config: { rule: fixture } });
        const modal = await env.openRule('rule');
        assert.equal(modal.option('kill_switch').getUIElement('rule').isChecked(), ksOn,
          'the kill-switch shows as the backend reads it');
        if (ksOn) {
          assert.equal(modal.active(NAME), true, 'the option shows while the kill-switch is on');
          assert.equal(modal.option(NAME).getUIElement('rule').isChecked(), checked,
            'the option shows as the backend reads it');
        }
        await modal.save();
        assert.deepEqual(env.uci.data.rule, fixture, 'an unchanged rule modal save changed UCI');
      });
    }
    await check(`${version} spelled kill-switch marker`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ kill_switch: 'yes' }) } });
      const rules = await env.openRules();
      const column = rules.grid.children.find((child) => child.option === '_action_display');
      assert.match(column.cfgvalue('rule'), /🛡/, 'the Rules page marks a kill-switch stored as "yes"');
    });
    await check(`${version} spelled flags changed`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ kill_switch: 'yes', [NAME]: 'on' }) } });
      let modal = await env.openRule('rule');
      modal.option(NAME).getUIElement('rule').setValue('0');
      await modal.save();
      assert.equal(NAME in env.uci.data.rule, false, 'unchecking a stored "on" removes the option');
      assert.equal(env.uci.data.rule.kill_switch, 'yes', 'the untouched kill-switch keeps its spelling');
      modal = await env.openRule('rule');
      modal.option('kill_switch').getUIElement('rule').setValue('0');
      await modal.save();
      assert.equal('kill_switch' in env.uci.data.rule, false, 'unchecking a stored "yes" removes the kill-switch');
      const off = createEnvironment({ version, config: { rule: rule({ kill_switch: 'yes', [NAME]: 'no' }) } });
      modal = await off.openRule('rule');
      modal.option(NAME).getUIElement('rule').setValue('1');
      await modal.save();
      assert.equal(off.uci.data.rule[NAME], '1', 'checking a stored "no" stores 1');
    });

    // The status of the rule: how many of its names its excluded devices
    // resolve, instead of the count of names blocked for them as well.
    await check(`${version} rule status`, async () => {
      const status = { configured: ['rule'], active: true, persistent: true, forkop_running: false, counters: {},
        state: { sections: ['rule'], rule_sections: ['rule'], dns: { domains: 3, sections: {
          rule: { domains: 3, uncovered: 0, client_limited: 0, excluded_devices: 1, excluded_exempt: 2 } } } } };
      const env = createEnvironment({ version, config: { rule: rule({ kill_switch: '1', [NAME]: '1' }) },
        fs: { exec: () => Promise.resolve({ code: 0, stdout: JSON.stringify(status), stderr: '' }) } });
      const modal = await env.openRule('rule');
      const rendered = modal.option('_kill_switch_status').renderWidget('rule');
      await env.settle();
      assert.match(rendered.textContent,
        /Domains the excluded devices of this section resolve while Forkop is stopped \(through their own resolver\): 2/);
      assert.match(rendered.textContent, /Domains also blocked for the excluded devices of this section .*: 1/);
    });

    // Switching the kill-switch off keeps the choice for when it is on again.
    await check(`${version} kill-switch switched off`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ kill_switch: '1', [NAME]: '1' }) } });
      const modal = await env.openRule('rule');
      modal.option('kill_switch').getUIElement('rule').setValue('0');
      await modal.save();
      assert.equal('kill_switch' in env.uci.data.rule, false);
      assert.equal(env.uci.data.rule[NAME], '1', 'the option is kept while the kill-switch is off');
    });
  }

  // Read-only sessions: the allowlist of what they may read leaves it out.
  const runtime = fs.readFileSync(path.join(ROOT, 'forkop/files/usr/lib/diagnostics/runtime.uc'), 'utf8');
  const safe = runtime.match(/let safe_keys = \[([^\]]*)\]/);
  assert(safe, 'the read-only allowlist was not found');
  assert(!safe[1].includes(NAME), 'read-only sessions must not read the option');
  const menu = JSON.parse(fs.readFileSync(path.join(ROOT, 'luci-app-forkop/root/usr/share/luci/menu.d/luci-app-forkop.json'), 'utf8'));
  assert.deepEqual(menu['admin/services/forkop/rules'].depends.acl, ['luci-app-forkop-admin'],
    'the rule editor is for administrators only');

  if (failures.length) {
    console.error(failures.join('\n'));
    process.exit(1);
  }
  console.log('luci_killswitch_dns_exempt: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
