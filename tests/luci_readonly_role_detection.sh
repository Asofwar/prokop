#!/usr/bin/env bash
set -euo pipefail

# The read ACL group may run the CLI only through /usr/libexec/prokop-ro
# (UC-001), so a session must be treated as read-only whenever its role lacks
# write access to luci-app-prokop, even if it can read the Prokop UCI package
# (for example a viewer role granted read of every group, including
# luci-app-prokop-admin). LuCI reports that through L.hasViewPermission().

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const source = fs.readFileSync(path.join(root,
  'luci-app-prokop/htdocs/luci-static/resources/view/prokop/shell.js'), 'utf8');

function loadShell({ canReadUci, permission, withL = true }) {
  const calls = [];
  const main = {
    PROKOP_UCI_PACKAGE: 'prokop',
    setReadonlyMode(value) { calls.push(`readonly:${value}`); },
  };
  const uci = { load: async () => { calls.push('uci'); if (!canReadUci) throw Error('Permission denied'); } };
  const L = withL ? { hasViewPermission: () => permission } : undefined;
  const shell = new Function('baseclass', 'uci', 'main', 'L', '_', 'window', 'CustomEvent', source)(
    { extend: value => value }, uci, main, L, value => value, { dispatchEvent() {} }, class {});
  return { shell, calls };
}

(async () => {
  const cases = [
    // [description, options, expected read-only, expected setReadonlyMode(true)]
    ['read-only view with readable UCI', { canReadUci: true, permission: false }, true, true],
    ['read-only view without UCI', { canReadUci: false, permission: false }, true, true],
    ['writable view', { canReadUci: true, permission: true }, false, false],
    ['unknown permission, readable UCI', { canReadUci: true, permission: null }, false, false],
    ['unknown permission, no UCI', { canReadUci: false, permission: null }, true, true],
    ['no LuCI global, readable UCI', { canReadUci: true, withL: false }, false, false],
    ['no LuCI global, no UCI', { canReadUci: false, withL: false }, true, true],
  ];
  for (const [name, options, readonly, marked] of cases) {
    const { shell, calls } = loadShell(options);
    assert.equal(await shell.detectAccess(), readonly, `${name}: wrong access mode`);
    assert.equal(calls.filter(call => call === 'readonly:true').length, marked ? 1 : 0,
      `${name}: read-only mode ${marked ? 'not set' : 'set'}`);
  }
  console.log('luci_readonly_role_detection: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
NODE
