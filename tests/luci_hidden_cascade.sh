#!/usr/bin/env bash
set -euo pipefail

# Hidden cascade settings (UC-041, D-22 b). The Cascade editor is gone, but
# rules may still carry outbound_detour_enabled/outbound_detour_section and
# the validator refuses them when they point nowhere useful. The rule modal
# (real section.js under tests/helpers/luci_form_harness.js) shows an
# administrator that the setting exists, what it does or why it fails, and
# offers to clear it after a confirmation; a plain save keeps it (retain).
# Changing the action away from Connection drops it on save, and the modal
# warns about that before Save.
# A role that may only read the configuration sees that a hidden setting
# exists, without the transit rule or any action.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# The read-only role never opens the rule editor (Settings needs the admin
# ACL); its only view of rules, get_readonly_config_sections, does not carry
# the hidden cascade either.
cat >"$WORK/prokop" <<'CONF'
config settings 'settings'
config section 'rule'
config section 'transit'
CONF
cat >"$WORK/state" <<'STATE'
prokop.settings=settings
prokop.rule=section
prokop.rule.action=connection
prokop.rule.outbound_detour_enabled=1
prokop.rule.outbound_detour_section=transit
prokop.transit=section
prokop.transit.action=connection
STATE
PROKOP_CONFIG="$WORK/prokop" PROKOP_UCI_STATE_FILE="$WORK/state" \
  ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" get-readonly-config-sections >"$WORK/sections.json"
grep -q '"rule"' "$WORK/sections.json" || { echo "FAIL: read-only sections are missing the rule" >&2; exit 1; }
if grep -q 'outbound_detour' "$WORK/sections.json"; then
  echo "FAIL: read-only sections expose the hidden cascade" >&2
  exit 1
fi

node - "$ROOT_DIR/tests/helpers" <<'NODE'
const assert = require('node:assert/strict');
const helpers = process.argv[2];
const { createEnvironment } = require(`${helpers}/luci_form_harness.js`);
const backend = require(`${helpers}/uci_backend.js`);

function section(name, values) {
  return Object.assign({ '.name': name, '.type': 'section', '.anonymous': false, enabled: '1' }, values);
}
const routed = { mixed_proxy_enabled: '0' };
const transit = section('transit', { label: 'Transit VPN', action: 'connection', ...routed,
  selector_proxy_links: ['socks5://10.0.0.1:1080'], domain: 'transit.example' });
const cascade = (values) => section('rule', Object.assign({ label: 'Work', action: 'connection', ...routed,
  selector_proxy_links: ['socks5://10.0.0.2:1080'], domain: 'work.example',
  outbound_detour_enabled: '1', outbound_detour_section: 'transit' }, values));

const cases = {
  working: { config: { rule: cascade(), transit }, valid: true,
    text: /servers of this rule connect through the rule “Transit VPN”/ },
  target_disabled: { config: { rule: cascade(), transit: { ...transit, enabled: '0' } },
    text: /the transit rule “Transit VPN” is disabled/ },
  target_deleted: { config: { rule: cascade() }, text: /the transit rule “transit” no longer exists/ },
  target_not_connection: { config: { rule: cascade(), transit: { ...transit, action: 'block' } },
    text: /the transit rule “Transit VPN” is not a Connection rule/ },
  source_not_connection: { config: { rule: cascade({ action: 'bypass', mixed_proxy_enabled: undefined,
    selector_proxy_links: undefined }), transit }, text: /this rule is not a Connection rule/ },
  no_target: { config: { rule: cascade({ outbound_detour_section: undefined }), transit },
    text: /no transit rule is selected/ },
  itself: { config: { rule: cascade({ outbound_detour_section: 'rule' }), transit },
    text: /the rule cannot use itself/ },
  loop: { config: { rule: cascade(), transit: { ...transit, outbound_detour_enabled: '1',
    outbound_detour_section: 'rule' } }, text: /the rules connect through each other in a loop/ },
  switched_off: { config: { rule: cascade({ outbound_detour_enabled: '0' }), transit }, valid: true,
    text: /switched-off cascade setting .*“Transit VPN”.* no effect/ },
};
for (const value of Object.values(cases))
  for (const item of Object.values(value.config))
    for (const [key, v] of Object.entries(item)) if (v === undefined) delete item[key];

const buttons = (node) => node.querySelectorAll('button');
const button = (node, label) => {
  const found = buttons(node).find((b) => b.textContent === label);
  assert(found, `no "${label}" button in: ${node.textContent}`);
  return found;
};

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
    for (const [name, { config, valid, text }] of Object.entries(cases)) {
      await check(`${version} ${name}`, async () => {
        const refused = backend.validate(config);
        assert.equal(refused.ok, Boolean(valid), 'validator verdict of the fixture');
        // The refusal names the fix the editor offers, not the removed
        // Cascade switch.
        if (!valid) {
          assert.match(refused.message, /Clear the cascade setting of rule '(rule|transit)' in the rule editor/);
          assert.doesNotMatch(refused.message, /disable cascade connection/);
        }

        // An administrator sees the setting and what it does.
        let env = createEnvironment({ version, config });
        let modal = await env.openRule('rule');
        const notice = modal.option('_hidden_cascade');
        assert.equal(modal.active('_hidden_cascade'), true, 'the notice must be shown');
        const node = notice.renderWidget('rule');
        assert.match(node.textContent, /cascade setting from an earlier version/);
        assert.match(node.textContent, text);

        // A plain save keeps the hidden options.
        await modal.save();
        assert.deepEqual(env.uci.data, config, 'an unchanged save changed UCI');

        // Clear asks first; Cancel changes nothing.
        env = createEnvironment({ version, config });
        modal = await env.openRule('rule');
        let widget = modal.option('_hidden_cascade').renderWidget('rule');
        button(widget, 'Clear…').attrs.click();
        assert.match(widget.textContent, /outbound_detour_enabled/);
        assert.match(widget.textContent, /outbound_detour_section/);
        button(widget, 'Cancel').attrs.click();
        await modal.save();
        assert.deepEqual(env.uci.data, config, 'a cancelled clear changed UCI');

        // Confirmed, the rule loses exactly the two options on save, and
        // the configuration the validator refused is accepted.
        env = createEnvironment({ version, config });
        modal = await env.openRule('rule');
        widget = modal.option('_hidden_cascade').renderWidget('rule');
        button(widget, 'Clear…').attrs.click();
        button(widget, 'Clear').attrs.click();
        assert.match(widget.textContent, /cleared/);
        assert.equal(buttons(widget).length, 0, 'nothing left to click after clearing');
        await modal.save();
        const expected = JSON.parse(JSON.stringify(config));
        delete expected.rule.outbound_detour_enabled;
        delete expected.rule.outbound_detour_section;
        assert.deepEqual(env.uci.data, expected, 'clearing must remove only the cascade options');
        const verdict = backend.validate(env.uci.data);
        assert.equal(verdict.ok, true, verdict.message);

        // Dismiss discards a clear that was not saved.
        env = createEnvironment({ version, config });
        modal = await env.openRule('rule');
        widget = modal.option('_hidden_cascade').renderWidget('rule');
        button(widget, 'Clear…').attrs.click();
        button(widget, 'Clear').attrs.click();
        await modal.dismiss();
        assert.deepEqual(env.uci.data, config, 'Dismiss must discard the clear');

        // A read-only role: that it exists, nothing else.
        env = createEnvironment({ version, config });
        modal = await env.openRule('rule', { readonly: true });
        const ro = modal.option('_hidden_cascade').renderWidget('rule');
        assert.match(ro.textContent, /hidden cascade setting/);
        assert.equal(buttons(ro).length, 0, 'a read-only role cannot clear it');
        for (const secret of ['transit', 'Transit VPN', 'outbound_detour', 'socks5'])
          assert.equal(ro.textContent.includes(secret), false, `read-only notice shows ${secret}`);
      });
    }

    // Changing the action away from Connection drops the cascade pair on
    // save (the validator refuses cascade on any other action); the other
    // hidden options stay. Choosing Connection again before saving keeps it.
    await check(`${version} action changed away from Connection`, async () => {
      const config = { rule: cascade({ sort_by_latency: '1', resolve_real_ip_for_routing: '1' }), transit };
      let env = createEnvironment({ version, config });
      let modal = await env.openRule('rule');
      modal.option('action').getUIElement('rule').setValue('bypass');
      await modal.save();
      const saved = env.uci.data.rule;
      assert.equal(saved.action, 'bypass');
      assert.equal(saved.outbound_detour_enabled, undefined);
      assert.equal(saved.outbound_detour_section, undefined);
      assert.equal(saved.sort_by_latency, '1');
      assert.equal(saved.resolve_real_ip_for_routing, '1');
      const verdict = backend.validate(env.uci.data);
      assert.equal(verdict.ok, true, verdict.message);

      env = createEnvironment({ version, config });
      modal = await env.openRule('rule');
      const action = modal.option('action').getUIElement('rule');
      action.setValue('bypass');
      action.setValue('connection');
      await modal.save();
      assert.deepEqual(env.uci.data, config, 'choosing Connection again changed UCI');
    });

    // The removal is never silent: once another action is chosen, the modal
    // warns before Save that the cascade goes, and the warning goes away when
    // Connection is chosen again or the cascade was cleared already.
    for (const [name, rule, text] of [
      ['working', cascade(), /saving the rule removes it.*through the rule “Transit VPN”/],
      ['switched off', cascade({ outbound_detour_enabled: '0' }), /removes the switched-off cascade setting/],
    ]) await check(`${version} action change warning: ${name}`, async () => {
      const config = { rule, transit };
      let env = createEnvironment({ version, config });
      let modal = await env.openRule('rule');
      const action = modal.option('action').getUIElement('rule');
      assert.equal(modal.active('_cascade_action_warning'), false, 'no warning while the action is kept');
      action.setValue('block');
      modal.map.checkDepends();
      assert.equal(modal.active('_cascade_action_warning'), true, 'the warning must be shown');
      assert.match(modal.option('_cascade_action_warning').renderWidget('rule').textContent, text);
      action.setValue('connection');
      modal.map.checkDepends();
      assert.equal(modal.active('_cascade_action_warning'), false, 'no warning after choosing Connection again');

      // Cleared first: nothing left to remove, nothing to warn about.
      env = createEnvironment({ version, config });
      modal = await env.openRule('rule');
      const widget = modal.option('_hidden_cascade').renderWidget('rule');
      button(widget, 'Clear…').attrs.click();
      button(widget, 'Clear').attrs.click();
      modal.option('action').getUIElement('rule').setValue('block');
      modal.map.checkDepends();
      assert.equal(modal.active('_cascade_action_warning'), false, 'a cleared cascade needs no warning');
    });

    // A rule that is not a Connection rule keeps its cascade whatever action
    // it gets (the notice offers Clear): no warning. A read-only role cannot
    // change the action.
    await check(`${version} action change warning: not a Connection rule`, async () => {
      const env = createEnvironment({ version, config: cases.source_not_connection.config });
      const modal = await env.openRule('rule');
      modal.option('action').getUIElement('rule').setValue('block');
      modal.map.checkDepends();
      assert.equal(modal.active('_cascade_action_warning'), false);
    });
    await check(`${version} action change warning: read-only`, async () => {
      const env = createEnvironment({ version, config: { rule: cascade(), transit } });
      const modal = await env.openRule('rule', { readonly: true });
      modal.option('action').getUIElement('rule').setValue('block');
      modal.map.checkDepends();
      assert.equal(modal.active('_cascade_action_warning'), false);
    });

    // Rules without a stored cascade (or with the old default "0") show nothing.
    for (const [name, values] of [['none', {}], ['old default', { outbound_detour_enabled: '0' }]])
      await check(`${version} no cascade: ${name}`, async () => {
        const config = { rule: section('rule', { action: 'connection', ...routed, domain: 'a.example',
          selector_proxy_links: ['socks5://10.0.0.2:1080'], ...values }) };
        const env = createEnvironment({ version, config });
        const modal = await env.openRule('rule');
        assert.equal(modal.active('_hidden_cascade'), false);
        await modal.save();
        assert.deepEqual(env.uci.data, config);
      });
  }

  if (failures.length) {
    console.error(failures.map((failure) => `FAIL: ${failure}`).join('\n'));
    process.exit(1);
  }
  console.log('LuCI shows hidden cascade settings and clears them on request');
})();
NODE
