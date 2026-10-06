#!/usr/bin/env bash
set -euo pipefail

# The Built-in rule sets list of a rule names each list by its upstream list
# name (main.domainListLabel: "Russia inside", "Russia outside", "Porn", ...),
# untranslated, both for the items already in the list and for the ones
# offered below it, never by the raw keys. Translated names hid what a list
# is ("blocked from outside" read as the opposite of russia_outside). The
# widget is the real one of section.js in the rule modal, for LuCI 24.10 and
# 25.12.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

const config = {
  dpi: { '.name': 'dpi', '.type': 'section', '.anonymous': false, enabled: '1', label: 'DPI',
    action: 'zapret', mixed_proxy_enabled: '0', community_lists: ['russia_inside', 'porn'] },
};

(async () => {
  for (const version of ['24.10', '25.12']) {
    const env = createEnvironment({ version, config });
    const lists = [];
    env.ui.DynamicList = env.ui.DynamicList.extend({
      __init__(value, choices, options) {
        this.super('__init__', [value, choices, options]);
        // The labels the list starts with: its items show these.
        this.itemLabels = Object.assign({}, choices);
        lists.push(this);
      },
    });
    const modal = await env.openRule('dpi');
    modal.option('community_lists').renderWidget('dpi', 0, ['russia_inside', 'porn']);
    assert.equal(lists.length, 1, `${version}: the built-in rule sets widget was not built`);
    const [widget] = lists;
    const label = (key) => env.main.domainListLabel(key);
    const keys = Object.keys(env.main.DOMAIN_LIST_OPTIONS);

    assert.equal(widget.itemLabels.russia_inside, 'Russia inside');
    assert.equal(widget.itemLabels.porn, 'Porn');
    for (const key of keys)
      assert.equal(widget.itemLabels[key], label(key), `${version}: ${key} is not named by its list name`);

    // Offered below the list: what is not in it yet, with the same names.
    assert.deepEqual(Object.keys(widget.choices).sort(),
      keys.filter((key) => !['russia_inside', 'porn'].includes(key)).sort());
    for (const [key, text] of Object.entries(widget.choices))
      assert.equal(text, label(key), `${version}: offered ${key} is not named by its list name`);
    assert.equal(widget.choices.geoblock, 'Geo Block');
    assert.deepEqual(widget.htmlChoiceLabels, [], `${version}: a label went to addChoices as HTML (FE-13)`);
  }
  console.log('luci_builtin_ruleset_labels: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
