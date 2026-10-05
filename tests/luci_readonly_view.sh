#!/usr/bin/env bash
set -euo pipefail

# Prokop is a LuCI menu subtree (admin/services/prokop/*), one view per
# page. This test covers the views themselves: a session that cannot read the
# Prokop UCI package is switched to read-only mode before any page content
# renders, status pages have no Save/Apply footer, and the configuration form
# lives only on the Settings page, which the read-only role cannot reach.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const viewDir = path.join(root, 'luci-app-prokop/htdocs/luci-static/resources/view/prokop');
const read = file => fs.readFileSync(path.join(viewDir, file), 'utf8');

// LuCI module: "require x as y" directives, then `return <class>`.
function load(file, modules) {
  const source = read(file);
  const names = [];
  const values = [];
  for (const [, dep, alias] of source.matchAll(/^"require ([\w.]+)(?: as (\w+))?";$/gm)) {
    const name = alias || dep.split('.').pop();
    assert(name in modules, `${file}: no stub for ${dep}`);
    names.push(name);
    values.push(modules[name]);
  }
  return new Function(...names, '_', 'E', 'window', 'CustomEvent', source)(
    ...values, value => value, (tag, attrs, children) => ({ tag, attrs, children }),
    { dispatchEvent() {}, setTimeout() {} }, class {});
}

function stubs(canReadUci, calls, { stale = false } = {}) {
  const main = {
    PROKOP_UCI_PACKAGE: 'prokop',
    PROKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT: 'x',
    injectGlobalStyles() {},
    coreService() { calls.push('core'); },
    setReadonlyMode(value) { calls.push(`readonly:${value}`); },
    setProkopPage(page) { calls.push(`page:${page}`); },
    store: { get: () => ({ diagnosticsSystemInfo: {} }), set() {} },
    ProkopShellMethods: { getUiCapabilities: async () => ({ success: true, data: {} }) },
  };
  if (stale) delete main.setReadonlyMode;
  for (const tab of ['DashboardTab', 'MonitoringTab', 'DiagnosticTab', 'AutotuneTab', 'HistoryTab']) {
    main[tab] = {
      initController() { calls.push(`init:${tab}`); },
      render() {
        assert(!canReadUci ? calls.includes('readonly:true') || stale : true,
          `${tab} rendered before the read-only mode was set`);
        calls.push(`render:${tab}`);
        return tab;
      },
    };
  }
  const uci = { load: async () => { if (!canReadUci) throw Error('Permission denied'); } };
  const baseclass = { extend: value => value };
  const shell = load('shell.js', { baseclass, uci, main });
  return {
    view: { extend: value => value }, baseclass, uci, main, shell,
    localDevices: { loadLocalDeviceChoices() {} },
  };
}

(async () => {
  const pages = {
    'page/overview.js': 'DashboardTab',
    'page/monitoring.js': 'MonitoringTab',
    'page/diagnostics.js': 'DiagnosticTab',
    'page/autotune.js': 'AutotuneTab',
    'page/history.js': 'HistoryTab',
  };
  for (const [file, tab] of Object.entries(pages)) {
    for (const stale of [false, true]) {
      const calls = [];
      const page = load(file, stubs(false, calls, { stale }));
      assert.equal(await page.load(), true, `${file}: read-only session not detected`);
      const rendered = page.render();
      assert.equal(rendered.children[1], tab, `${file}: page content not rendered`);
      if (!stale) {
        assert.equal(calls.filter(call => call === 'readonly:true').length, 1,
          `${file}: read-only mode not set exactly once`);
        assert(calls.indexOf('readonly:true') < calls.indexOf(`render:${tab}`),
          `${file}: read-only mode must be set before rendering`);
      }
      assert.equal(page.handleSave, null, `${file}: status page must not offer Save`);
      assert.equal(page.handleSaveApply, null, `${file}: status page must not offer Save & Apply`);
      assert.equal(page.handleReset, null, `${file}: status page must not offer Reset`);
    }
    const calls = [];
    const page = load(file, stubs(true, calls));
    assert.equal(await page.load(), false, `${file}: administrator detected as read-only`);
    page.render();
    assert(!calls.some(call => call.startsWith('readonly:')), `${file}: administrator switched to read-only`);
    assert(calls.includes(`init:${tab}`), `${file}: controller not initialised`);
  }

  // Rules and Settings: the only pages with configuration forms, both with
  // the snapshot-first Save & Apply of configform.js. LuCI's footer calls the
  // view's handleSaveApply, so the page views take it (UC-064, UC-224);
  // luci_save_apply_snapshot.sh drives it.
  const formSource = read('configform.js');
  assert.match(formSource, /new form\.Map\(UCI_PACKAGE/, 'configform must build the form');
  const handleSaveApply = function () {};
  for (const [file, modules] of [['page/rules.js', { section: {} }],
    ['page/settings.js', { settings: {}, notifications: {}, torrserver: {}, updates: {} }]]) {
    const view = load(file, { view: { extend: value => value }, form: {}, shell: {},
      configform: { handleSaveApply }, ...modules });
    assert.equal(view.handleSaveApply, handleSaveApply, `${file}: Save & Apply must be configform's`);
  }
  const settingsSource = read('page/settings.js');
  const rulesSource = read('page/rules.js');
  for (const [name, source] of [['settings', settingsSource], ['rules', rulesSource]])
    assert.match(source, /configform\.createMap\(/, `${name} page must host its form through configform`);
  assert(rulesSource.includes('form.GridSection,\n      "section"'), 'the rules page must host the rules grid');
  assert(!settingsSource.includes('"section"'), 'the rules moved out of Settings');
  assert(settingsSource.includes('form.TypedSection,\n      "updates"'), 'settings page lost the components tab');
  assert.match(settingsSource, /prokopMap\.section\(form\.TypedSection, type, title\)/,
    'settings page lost the settings tabs');
  // LuCI keys map tabs by section type: every settings tab needs its own.
  const tabTypes = [...settingsSource.matchAll(/settingsTab\("(settings_\w+)", _\("([^"]+)"\)\)/g)];
  assert.deepEqual(tabTypes.map((m) => m[2]), ['DNS', 'Network', 'Lists and updates', 'Service settings',
    'Notifications', 'TorrServer']);
  assert.equal(new Set(tabTypes.map((m) => m[1])).size, 6, 'settings tabs must not share a section type');
  assert.match(settingsSource, /cfgsections = function \(\) \{\s*return \["settings"\];/,
    'settings tabs must edit the single settings section');
  for (const file of Object.keys(pages))
    assert.doesNotMatch(read(file), /form\.(Map|JSONMap)/, `${file} must not render a form`);

  // The old single view and its wrappers are gone.
  for (const file of ['prokop.js', 'dashboard.js', 'diagnostic.js', 'monitoring.js'])
    assert(!fs.existsSync(path.join(viewDir, file)), `${file} should have been removed`);

  // Menu subtree.
  const menu = JSON.parse(fs.readFileSync(
    path.join(root, 'luci-app-prokop/root/usr/share/luci/menu.d/luci-app-prokop.json'), 'utf8'));
  const parent = menu['admin/services/prokop'];
  assert.deepEqual(parent.action, { type: 'firstchild' },
    'the old URL admin/services/prokop must open the first page');
  assert.deepEqual(parent.depends.acl, ['luci-app-prokop']);
  const children = Object.entries(menu).filter(([key]) => key.startsWith('admin/services/prokop/'));
  const order = children.sort((a, b) => a[1].order - b[1].order).map(([key]) => key.split('/').pop());
  assert.deepEqual(order, ['overview', 'rules', 'monitoring', 'diagnostics', 'autotune', 'history', 'settings']);
  for (const [key, node] of children) {
    assert.equal(node.action.type, 'view', `${key} must be a view`);
    assert(fs.existsSync(path.join(root, 'luci-app-prokop/htdocs/luci-static/resources/view', `${node.action.path}.js`)),
      `${key} points to a missing view ${node.action.path}`);
  }
  assert.deepEqual(menu['admin/services/prokop/settings'].depends, { acl: ['luci-app-prokop-admin'] },
    'Settings must be hidden from the read-only role');
  assert.deepEqual(menu['admin/services/prokop/rules'].depends, { acl: ['luci-app-prokop-admin'] },
    'Rules must be hidden from the read-only role');
  for (const key of ['overview', 'monitoring', 'diagnostics', 'autotune', 'history'])
    assert(!menu[`admin/services/prokop/${key}`].depends,
      `${key} must stay available to the read-only role`);

  const acl = JSON.parse(fs.readFileSync(
    path.join(root, 'luci-app-prokop/root/usr/share/rpcd/acl.d/luci-app-prokop.json'), 'utf8'));
  assert.deepEqual(acl['luci-app-prokop-admin'].read.uci, ['prokop'],
    'the Settings gate group must grant the Prokop UCI read access');

  console.log('luci_readonly_view: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
NODE
