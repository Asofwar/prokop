#!/usr/bin/env bash
set -euo pipefail

# Devices by MAC address in the rule device options (Device filter, Forced
# device routing, Exclude devices): the editor accepts a unicast MAC in any
# case or with '-', stores it in lower case with ':' (as nft and sing-box
# print it, and as the global device policy stores alice_macs), refuses a
# multicast or malformed one, and leaves address values as they were. The
# pickers offer the known devices by MAC next to their addresses, and warn
# about a single address without a static lease.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const { createEnvironment } = require(path.join(root, 'tests/helpers/luci_form_harness.js'));
const print = console.log;
console.log = (...args) => `${args[0]}`.startsWith('[DEBUG]') || print(...args);

function rule(values) {
  return Object.assign({ '.name': 'rule', '.type': 'section', '.anonymous': false, enabled: '1',
    action: 'bypass', ip_cidr: ['10.10.0.0/16'] }, values);
}

// -- the editor ---------------------------------------------------------------
(async () => {
  for (const version of ['24.10', '25.12']) {
    for (const key of ['source_ip_cidr', 'fully_routed_ips', 'excluded_source_ip_cidr']) {
      const env = createEnvironment({ version, config: { rule: rule({}) } });
      const modal = await env.openRule('rule');
      const field = modal.option(key).getUIElement('rule');
      field.setValue(['192.168.1.5', 'AA-BB-CC-00-00-01']);
      await modal.save();
      assert.deepEqual(env.uci.data.rule[key], ['192.168.1.5', 'aa:bb:cc:00:00:01'],
        `${version} ${key}: a MAC is stored in lower case with ':'`);

      // A list validates each item as it is typed (ui.DynamicList).
      const option = modal.option(key);
      for (const bad of ['01:00:5e:00:00:01', '00:00:00:00:00:00', 'aa:bb-cc:00:00:01'])
        assert.match(`${option.validate('rule', bad)}`, /MAC address of one device/,
          `${version} ${key}: '${bad}' must be refused`);
      for (const good of ['aa:bb:cc:00:00:01', 'AA-BB-CC-00-00-01', '192.168.1.5', '192.168.1.0/24'])
        assert.equal(option.validate('rule', good), true, `${version} ${key}: '${good}' must be accepted`);
    }
    // A stored MAC round-trips unchanged.
    const stored = rule({ source_ip_cidr: ['aa:bb:cc:00:00:01'] });
    const env = createEnvironment({ version, config: { rule: stored } });
    await (await env.openRule('rule')).save();
    assert.deepEqual(env.uci.data.rule, stored, `${version}: an unchanged rule with a MAC changed UCI`);
  }

  // -- the pickers ------------------------------------------------------------
  const source = fs.readFileSync(path.join(root,
    'luci-app-prokop/htdocs/luci-static/resources/view/prokop/local_devices.js'), 'utf8');
  const rendered = [];
  const ui = {
    DynamicList: function (values, choices, options) {
      Object.assign(this, { values, choices, options, listeners: {} });
      rendered.push(this);
      this.render = () => ({ addEventListener: (type, listener) => { this.listeners[type] = listener; } });
      this.getValue = () => this.current || values;
      this.clearChoices = () => {};
      this.addChoices = () => {};
    },
  };
  const E = (tag, attrs, children) => ({ tag, attrs, children, style: {}, textContent: '' });
  const main = { validateIP: (ip) => ({ valid: /^\d+\.\d+\.\d+\.\d+$/.test(ip) || /^[0-9a-f:]+::?[0-9a-f]*$/i.test(ip) }) };
  const rpc = {
    declare: ({ method }) => () => Promise.resolve({
      getHostHints: {
        'AA:BB:CC:00:00:01': { name: 'TV.lan', ipaddrs: ['192.168.1.30'] },
        '01:00:5E:00:00:01': { name: 'multicast', ipaddrs: [] },
      },
      getDHCPLeases: { dhcp_leases: [{ ipaddr: '192.168.1.40', macaddr: 'aa:bb:cc:00:00:02', hostname: 'Phone' }] },
      dump: [],
    }[method]),
  };
  const uci = {
    load: () => Promise.resolve(),
    sections: (config, type) => config === 'dhcp' && type === 'host' ? [{ ip: '192.168.1.30' }] : [],
  };
  const api = new Function('baseclass', 'rpc', 'ui', 'uci', 'main', 'E', '_',
    source.replace(/^"(use strict|require [^"]+)";$/gm, ''))({ extend: (o) => o }, rpc, ui, uci, main, E, (s) => s);

  assert.equal(api.normalizeDeviceMac('AA-BB-CC-00-00-01'), 'aa:bb:cc:00:00:01');
  assert.equal(api.normalizeDeviceMac('01:00:5e:00:00:01'), null, 'multicast is refused');
  assert.equal(api.normalizeDeviceMac('aa:bb-cc:00:00:01'), null, 'mixed separators are refused');
  assert.equal(api.looksLikeDeviceMac('fd00::1'), false, 'an IPv6 address is no MAC');

  await api.loadLocalDeviceChoices();
  const wrapper = await api.createLocalDeviceDynamicListWidget(
    { cbid: () => 'cbid', validate: () => true, map: { readonly: false } }, 'rule',
    ['192.168.1.30', '192.168.1.40', '192.168.1.0/24', 'aa:bb:cc:00:00:01']);
  const widget = rendered[0];
  assert.deepEqual(widget.options.sort,
    ['192.168.1.40', '192.168.1.30', 'aa:bb:cc:00:00:02', 'aa:bb:cc:00:00:01'],
    'addresses first, then devices by MAC, each by name');
  assert.equal(widget.choices['aa:bb:cc:00:00:01'], 'TV (MAC aa:bb:cc:00:00:01)');
  assert.equal(widget.choices['aa:bb:cc:00:00:02'], 'Phone (MAC aa:bb:cc:00:00:02)');
  assert(!Object.keys(widget.choices).includes('01:00:5e:00:00:01'), 'a multicast MAC is never offered');
  // The other users of the device list (site check, Monitoring) keep addresses only.
  assert(Object.keys(await api.loadLocalDeviceChoices()).every((value) => !api.looksLikeDeviceMac(value)));

  await new Promise((resolve) => setTimeout(resolve, 10));
  const warning = wrapper.children[1];
  assert.equal(warning.attrs.role, 'status');
  assert.match(warning.textContent, /^No static lease for 192\.168\.1\.40:/,
    'only the single address without a static lease is named, not a network or a MAC');
  assert.equal(warning.style.display, '');
  widget.current = ['192.168.1.30'];
  widget.listeners['cbi-dynlist-change']();
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(warning.textContent, '');
  assert.equal(warning.style.display, 'none', 'no warning when every address has a static lease');

  // Without read access to dhcp nothing is claimed.
  assert.deepEqual(api.addressesWithoutStaticLease(['192.168.1.40'], null), []);
  console.log('PASS: luci_device_mac');
})().catch((error) => {
  console.error(`FAIL: ${error.stack || error}`);
  process.exit(1);
});
NODE
