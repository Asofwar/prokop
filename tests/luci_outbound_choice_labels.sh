#!/usr/bin/env bash
set -euo pipefail

# FE-11: the names of subscription servers offered by "Include servers" /
# "Exclude servers" of a URLTest group come from the subscription provider. ui.DynamicList
# addChoices hands a string label to E(), which parses it as HTML, so the
# labels go in as nodes and a name with markup stays text. The widget is the
# real one of section.js in the URLTest group settings of the rule modal
# (tests/helpers/luci_form_harness.js), for LuCI 24.10 and 25.12.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

const rule = { '.name': 'rule', '.type': 'section', '.anonymous': false, enabled: '1', label: 'VPN',
  action: 'connection', mixed_proxy_enabled: '0', community_lists: ['youtube'],
  selector_proxy_links: ['socks5://10.0.0.1:1080'] };
const hostile = 'NL-1<img src=x onerror=alert(document.domain)>';
const cache = JSON.stringify({ outboundMetadata: { names: { n1: hostile, n2: 'DE-2' } } });

(async () => {
  for (const version of ['24.10', '25.12']) {
    const env = createEnvironment({ version, config: { rule },
      fs: { read: (file) => file.endsWith('/rule.json') ? Promise.resolve(cache) : Promise.reject(new Error('ENOENT')) } });
    const lists = [];
    env.ui.DynamicList = env.ui.DynamicList.extend({
      __init__(value, choices, options) {
        this.super('__init__', [value, choices, options]);
        this.listeners = {};
        lists.push(this);
      },
      render() {
        return { isConnected: true, addEventListener: (type, listener) => { this.listeners[type] = listener; } };
      },
    });
    const settings = await (await env.openRule('rule')).openItemSettings('urltest', '', { adding: true });
    for (const name of ['include_outbounds', 'exclude_outbounds']) {
      const option = settings.map.children[0].children.find((o) => o.option === name);
      assert.ok(option, `${version}: ${name} is missing`);
      await option.load('settings');
      lists.length = 0;
      option.renderWidget('settings', 0, []);
      const [widget] = lists;
      assert.ok(widget, `${version}: ${name} widget was not built`);
      // A name typed into the list since it was drawn: opening the list
      // offers the names again through addChoices.
      widget.value = ['Typed'];
      widget.listeners.mousedown({ target: { closest: (selector) => selector === '.add-item' } });
      assert.equal(widget.choices[hostile], hostile, `${version}: ${name} lost the server name`);
      assert.equal(widget.choices.Typed, 'Typed');
      assert.deepEqual(widget.htmlChoiceLabels, [], `${version}: ${name} passed a label as HTML`);
    }
  }
  console.log('luci_outbound_choice_labels: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
