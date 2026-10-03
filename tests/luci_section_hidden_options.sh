#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');

// Rule-modal options hidden behind an impossible dependency are still read by
// the backend, so LuCI must not drop them when the modal is saved.
const hiddenBlocks = source.split(/\n  o = section\.taboption\(/)
  .filter(block => block.includes('"__internal_hidden__"'))
  .map(block => [block.match(/^\s*"\w+",\s*form\.\w+,\s*"(\w+)"/)?.[1], block]);
const hiddenNames = ['outbound_detour_enabled', 'outbound_detour_section',
  'sort_by_latency', 'resolve_real_ip_for_routing'];
assert.deepEqual(hiddenBlocks.map(([name]) => name), hiddenNames);
for (const [name, block] of hiddenBlocks)
  assert.match(block, /\n  o\.retain = true;/, `${name} must set retain`);

// isOutboundDetourRuleAction, loadOutboundDetourOption, parseOutboundDetourOption.
const helper = source.match(/\nfunction isOutboundDetourRuleAction\([\s\S]*?\nfunction parseOutboundDetourOption\(parentParse\) \{[\s\S]*?\n\}\n/);
assert(helper, 'parseOutboundDetourOption not found');
const start = source.lastIndexOf('o = section.taboption(', source.search(/form\.\w+,\s*"outbound_detour_enabled"/));
const end = source.indexOf('addTextConditionField(section, {', source.indexOf('"resolve_real_ip_for_routing"'));
assert(start >= 0 && end > start, 'hidden rule options not found');

const UCI_PACKAGE = 'prokop';
let store;
let form;
const uci = {
  get: (config, sid, option) => store[sid]?.[option] ?? null,
  set: (config, sid, option, value) => { store[sid][option] = value; },
  unset: (config, sid, option) => { delete store[sid][option]; },
};

// Mirrors AbstractValue.parse() from luci-base form.js on OpenWrt 23.05 and
// 24.10: an inactive option (dependencies unsatisfied) is removed unless it
// sets `retain`.
class AbstractValue {
  constructor(section, option) {
    Object.assign(this, { section, option, deps: [], rmempty: true, retain: false });
  }
  depends(key, value) { this.deps.push(typeof key === 'string' ? { [key]: value } : key); }
  value() {}
  load(sid) { return uci.get(UCI_PACKAGE, sid, this.option); }
  isActive(sid) {
    return !this.deps.length || this.deps.some(dep => Object.entries(dep).every(([key, value]) => {
      const sibling = options[key];
      return (sibling && sibling.isActive(sid) ? sibling.formvalue(sid) : null) === value;
    }));
  }
  isValid() { return true; }
  cfgvalue(sid) { return uci.get(UCI_PACKAGE, sid, this.option); }
  formvalue(sid) { return this.option in form ? form[this.option] : this.cfgvalue(sid); }
  write(sid, value) { uci.set(UCI_PACKAGE, sid, this.option, value); }
  remove(sid) { uci.unset(UCI_PACKAGE, sid, this.option); }
  parse(sid) {
    const active = this.isActive(sid);
    if (active) {
      const cval = this.cfgvalue(sid);
      const fval = this.formvalue(sid);
      if (fval == null || fval == '') {
        if (this.rmempty || this.optional)
          return Promise.resolve(this.remove(sid));
        return Promise.reject(new TypeError(`${this.option} must not be empty`));
      }
      if (this.forcewrite || cval !== fval)
        return Promise.resolve(this.write(sid, fval));
    }
    else if (!this.retain) {
      return Promise.resolve(this.remove(sid));
    }
    return Promise.resolve();
  }
}

const options = {};
const section = {
  formvalue: (sid, option) => options[option]?.formvalue(sid),
  taboption(tab, Type, name) { return options[name] = new Type(section, name); },
};
options.action = new AbstractValue(section, 'action');
vm.runInNewContext(`${helper[0]}\n${source.slice(start, end)}`, {
  _: text => text,
  E: () => null,
  form: { AbstractValue, DummyValue: AbstractValue, Flag: AbstractValue, ListValue: AbstractValue,
    Value: AbstractValue },
  killswitch: { KILL_SWITCH_ACTIONS: ['connection', 'proxy', 'outbound', 'vpn'], createSectionStatus: () => null },
  section,
  uci,
  UCI_PACKAGE,
  getRuleResolvedAction: sid => uci.get(UCI_PACKAGE, sid, 'action') || 'connection',
  hiddenCascadeState: () => null,
  refreshOutboundDetourSectionOptionValues() {},
});

const saved = {
  outbound_detour_enabled: '1',
  outbound_detour_section: 'transit',
  sort_by_latency: '1',
  resolve_real_ip_for_routing: '1',
};

async function saveModal(action, formValues = {}) {
  store = { rule: { action, mixed_proxy_enabled: '0', mixed_proxy_port: '2080', ...saved } };
  form = { action, ...formValues };
  // LuCI loads every option when the modal opens, then parses it on save.
  await Promise.all(Object.values(options).map(option => option.load('rule')));
  await Promise.all(Object.values(options).map(option => option.parse('rule')));
  return store.rule;
}

(async () => {
  // Harness sanity: a regular inactive option without `retain` is dropped.
  assert.equal((await saveModal('connection')).mixed_proxy_port, undefined);

  for (const action of ['connection', 'proxy', 'outbound', 'vpn']) {
    assert.deepEqual(pick(await saveModal(action)), saved, `${action} keeps hidden settings`);
    assert.deepEqual(pick(await saveModal('connection', { action })), saved,
      `connection changed to ${action} keeps hidden settings`);
  }

  // A save that keeps the action never drops them (D-22 b): the cascade of a
  // rule that is not a Connection rule is shown in the modal, with Clear.
  for (const action of ['dns', 'block', 'bypass', 'byedpi', 'zapret'])
    assert.deepEqual(pick(await saveModal(action)), saved, `unchanged ${action} keeps hidden settings`);

  // Changing the action away from Connection is the deliberate removal path
  // for the cascade: validator.uc rejects cascade on any other action.
  for (const action of ['dns', 'block', 'bypass', 'byedpi', 'zapret']) {
    const rule = await saveModal('connection', { action });
    assert.equal(rule.action, action);
    assert.deepEqual(pick(rule), {
      sort_by_latency: '1',
      resolve_real_ip_for_routing: '1',
    }, `${action} drops only the cascade`);
  }

  // Only a change away from a Connection action drops them.
  assert.deepEqual(pick(await saveModal('bypass', { action: 'block' })), saved,
    'bypass changed to block keeps hidden settings');

  console.log('LuCI hidden rule option retention checks passed');
})().catch(error => {
  console.error(error);
  process.exit(1);
});

function pick(rule) {
  return Object.fromEntries(hiddenNames.filter(name => name in rule).map(name => [name, rule[name]]));
}
NODE
