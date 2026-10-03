#!/usr/bin/env bash
set -euo pipefail

# Rule options that the modal never shows (they depend on the impossible
# action "__internal_hidden__") are still read by the backend: section cascade
# (singbox/generator.uc), resolve real IP (singbox/route.uc) and dashboard
# sorting. LuCI AbstractValue.parse() removes an inactive option unless it is
# marked `retain`, so saving a rule from the modal must not erase them.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');

const HIDDEN = '"__internal_hidden__"';
const BLOCK_START = 'o = section.taboption(';

function optionBlock(name) {
  const declaration = new RegExp(`taboption\\(\\s*"[^"]+",\\s*form\\.\\w+,\\s*"${name}"`);
  const at = source.search(declaration);
  assert(at >= 0, `${name} option not found`);
  const start = source.lastIndexOf(BLOCK_START, at);
  // The block ends at the first top-level statement that is not `o.…`.
  const end = /\n  (?!o\.|\}|\)|\/\/)\S/g;
  end.lastIndex = at;
  const next = end.exec(source);
  assert(start >= 0 && next, `${name} option block not found`);
  return source.slice(start, next.index);
}

// Every permanently hidden option must be retained.
const hiddenNames = [];
for (let at = source.indexOf(HIDDEN); at >= 0; at = source.indexOf(HIDDEN, at + 1)) {
  const start = source.lastIndexOf(BLOCK_START, at);
  const name = source.slice(start).match(/taboption\(\s*"[^"]+",\s*form\.\w+,\s*"([^"]+)"/)[1];
  if (!hiddenNames.includes(name)) hiddenNames.push(name);
}
assert.deepEqual(hiddenNames.sort(), [
  'outbound_detour_enabled',
  'outbound_detour_section',
  'resolve_real_ip_for_routing',
  'sort_by_latency',
]);

// Round-trip: declare the real option blocks against a UCI store and run the
// LuCI 23.05/24.10 AbstractValue.parse() branches for a modal save.
function saveRule(store, sectionId, state) {
  const options = {};
  const uci = {
    get: (_config, sid, key) => store[sid]?.[key],
    set: (_config, sid, key, value) => { store[sid][key] = value; },
    unset: (_config, sid, key) => { delete store[sid][key]; },
  };
  const context = {
    _: text => text,
    form: { Flag: 'Flag', ListValue: 'ListValue' },
    uci,
    UCI_PACKAGE: 'prokop',
    getOutboundDetourTargetSections: () => [],
    getDefaultOutboundDetourSection: () => '',
    getUciSectionName: item => item,
    refreshOutboundDetourSectionOptionValues() {},
    // The cascade pair drops itself only on an action change
    // (tests/luci_section_hidden_options.sh); here the action is kept.
    loadOutboundDetourOption: load => load,
    parseOutboundDetourOption: parse => parse,
    getRuleResolvedAction: sid => store[sid].action,
    section: {
      taboption(tab, type, name) {
        return options[name] = {
          option: name,
          type,
          dependencies: [],
          depends(key, value) {
            this.dependencies.push(typeof key === 'string' ? { [key]: value } : key);
          },
          remove(sid) { uci.unset('prokop', sid, this.option); },
        };
      },
    },
  };
  for (const name of hiddenNames) vm.runInNewContext(optionBlock(name), context);

  for (const option of Object.values(options)) {
    const active = option.dependencies.some(dependency =>
      Object.entries(dependency).every(([key, value]) => state[key] === value));
    assert.equal(active, false, `${option.option} must stay hidden`);
    // LuCI form.js AbstractValue.parse(): `else if (!this.retain) remove`.
    if (!option.retain) option.remove(sectionId);
  }
}

const configured = {
  outbound_detour_enabled: '1',
  outbound_detour_section: 'transit',
  sort_by_latency: '1',
  resolve_real_ip_for_routing: '1',
};
for (const action of ['connection', 'byedpi', 'zapret', 'zapret2', 'bypass', 'block', 'dns']) {
  const store = { rule: { '.type': 'section', action, ...configured } };
  saveRule(store, 'rule', { action });
  assert.deepEqual(store.rule, { '.type': 'section', action, ...configured },
    `${action}: saving the rule modal erased hidden options`);

  const empty = { rule: { '.type': 'section', action } };
  saveRule(empty, 'rule', { action });
  assert.deepEqual(empty.rule, { '.type': 'section', action },
    `${action}: saving the rule modal must not create hidden options`);
}

console.log('LuCI hidden rule options survive a modal save');
NODE
