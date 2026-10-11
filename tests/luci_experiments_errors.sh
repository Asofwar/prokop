#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT/luci-app-prokop/htdocs/luci-static/resources/view/prokop/page/experiments.js" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const source = fs.readFileSync(process.argv[2], 'utf8');
let response;
// Evaluate only the trusted repository command helper, not user-supplied code.
const helper = source.slice(source.indexOf('function reasonText('), source.indexOf('function button('));
const command = new Function('fs', '_', helper + '\nreturn command;')(
  { exec: async () => response }, text => text);
(async () => {
  for (const stdout of ['', 'not-json']) {
    response = {code: 1, stdout};
    await assert.rejects(command(['priority_health']), {message: 'Operation failed'});
  }
  response = {code: 1, stdout: JSON.stringify({success: false, reason: 'profile_not_found'})};
  // Reason codes reach the page in words, unknown ones with their code.
  await assert.rejects(command(['profile_activate', 'Missing']), {message: 'Profile not found.'});
  response = {code: 1, stdout: JSON.stringify({success: false, reason: 'some_new_reason'})};
  await assert.rejects(command(['profile_activate', 'Missing']), {message: 'Operation failed (some_new_reason)'});
  response = {code: 1, stdout: JSON.stringify({status: 'busy', reason: 'snapshot_operation_in_progress', success: false})};
  await assert.rejects(command(['profile_activate', 'Office']), {message: /Another snapshot operation/});
  response = {code: 0, stdout: JSON.stringify({success: true, available: false})};
  assert.deepEqual(await command(['priority_health']), {success: true, available: false});
  console.log('Experiments error messages preserve the operation failure');
})().catch(error => { console.error(error); process.exit(1); });
NODE
