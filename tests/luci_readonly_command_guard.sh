#!/usr/bin/env bash
set -euo pipefail

# A read-only LuCI session must not issue a single command outside the read
# grants of the ACL: the frontend refuses everything else locally
# (fe-app-prokop/src/prokop/services/readonlyCommandGuard.ts). The allowlist
# there must stay identical to the ACL, and the pages must ask for the
# masked variants the read role is allowed to run. Read-only sessions run the
# CLI through /usr/libexec/prokop-ro, which drops the caller environment.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];

const acl = JSON.parse(fs.readFileSync(
  path.join(root, 'luci-app-prokop/root/usr/share/rpcd/acl.d/luci-app-prokop.json'), 'utf8'));
const grants = Object.entries(acl['luci-app-prokop'].read.file)
  .filter(([, permissions]) => permissions.includes('exec'))
  .map(([pattern]) => pattern)
  .sort();

const guard = fs.readFileSync(
  path.join(root, 'fe-app-prokop/src/prokop/services/readonlyCommandGuard.ts'), 'utf8');
const block = guard.match(/READONLY_EXEC_PATTERNS = \[([\s\S]*?)\];/);
assert(block, 'READONLY_EXEC_PATTERNS not found');
const patterns = [...block[1].matchAll(/'([^']+)'/g)].map(match => match[1]).sort();
assert.deepEqual(patterns, grants, 'frontend read-only allowlist differs from the ACL read grants');

const shell = fs.readFileSync(
  path.join(root, 'fe-app-prokop/src/helpers/executeShellCommand.ts'), 'utf8');
assert.match(shell, /shouldRefuseCommand\(command, args\)[\s\S]*?return \{[^}]*READONLY_REFUSED/,
  'executeShellCommand must refuse commands before fs.exec');
assert(shell.indexOf('shouldRefuseCommand(') < shell.indexOf('fs.exec('),
  'the read-only check must run before fs.exec');

// UC-001: rpcd passes the caller's env table to file.exec children; the read
// role only reaches the CLI through the wrapper that clears the environment.
const wrapper = '/usr/libexec/prokop-ro';
for (const pattern of patterns) {
  assert(pattern.startsWith(`${wrapper} `), `read grant bypasses ${wrapper}: ${pattern}`);
}
assert.match(guard, new RegExp(`PROKOP_READONLY_CLI = '${wrapper}'`),
  'read-only sessions must be routed to the wrapper');
assert.match(shell, /const command = resolveReadonlyCommand\(requestedCommand\);/,
  'executeShellCommand must route read-only sessions to the wrapper');
assert(shell.indexOf('resolveReadonlyCommand(') < shell.indexOf('shouldRefuseCommand('),
  'the wrapper must be chosen before the allowlist check');
assert.match(shell, /fs\.exec\(command, args\)/, 'fs.exec must run the resolved command');
const bundle = fs.readFileSync(
  path.join(root, 'luci-app-prokop/htdocs/luci-static/resources/view/prokop/main.js'), 'utf8');
assert(bundle.includes(`"${wrapper}"`), 'main.js bundle is not rebuilt with the read-only wrapper');
assert(!/"\/usr\/bin\/prokop (get_status|global_check masked)"/.test(bundle),
  'main.js bundle still lists the direct CLI as a read-only command');

const diagnostics = fs.readFileSync(
  path.join(root, 'fe-app-prokop/src/prokop/tabs/diagnostic/initController.ts'), 'utf8');
for (const method of ['globalCheck', 'showSingBoxConfig']) {
  assert.doesNotMatch(diagnostics, new RegExp(`${method}\\(false\\)`),
    `${method} must not request raw output regardless of the role`);
  assert.match(diagnostics, new RegExp(`${method}\\(\\s*readonly\\s*\\)`),
    `${method} must request the masked output in a read-only session`);
}

console.log('LuCI read-only command guard matches the ACL');
NODE
