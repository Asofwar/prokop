#!/usr/bin/env bash
set -euo pipefail

# Destructive or disruptive actions must ask for confirmation before the
# backend call: stopping Prokop, removing a component package, closing all
# connections and restoring or deleting a configuration snapshot.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

function functionBody(source, signature) {
  const start = source.indexOf(signature);
  assert(start >= 0, `${signature} not found`);
  const open = source.indexOf('{', start + signature.length - 1);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(open, i + 1);
  }
  throw Error(`${signature} is not closed`);
}

function assertConfirmedBefore(body, confirmCall, backendCall, label) {
  const confirmAt = body.indexOf(confirmCall);
  const backendAt = body.indexOf(backendCall);
  assert(confirmAt >= 0, `${label}: no confirmation`);
  assert(backendAt > confirmAt, `${label}: backend call runs before the confirmation`);
  assert.match(body.slice(confirmAt, backendAt), /if \(!confirmed[^)]*\)\s*\{?\s*return/,
    `${label}: a declined confirmation must stop the action`);
}

// Service control lives on the Overview only; Diagnostics has no stop.
const diagnostics = read('fe-app-prokop/src/prokop/tabs/diagnostic/initController.ts');
assert.doesNotMatch(diagnostics, /serviceActionStart\(|handleStop|ProkopShellMethods\.(enable|disable)\(/,
  'Diagnostics must not control the service');

const dashboard = read('fe-app-prokop/src/prokop/tabs/dashboard/initController.ts');
assert.match(functionBody(dashboard, 'async function handleServiceAction(action: ProkopServiceAction)'),
  /action === 'stop' && !\(await confirmStopProkop\(\)\)\) return;[\s\S]*runProkopServiceAction\(action\)/,
  'overview: stop Prokop must be confirmed before the service job');
const control = read('fe-app-prokop/src/prokop/tabs/shared/serviceControl.ts');
assert.match(functionBody(control, 'export function confirmStopProkop()'), /confirmAction\(\{[\s\S]*danger: true/,
  'the shared stop confirmation must be a destructive confirmAction');

const monitoring = read('fe-app-prokop/src/prokop/tabs/monitoring/initController.ts');
assertConfirmedBefore(functionBody(monitoring, 'async function closeAllConnections()'),
  'confirmAction(', 'closeAllClashApiConnections(', 'close all connections');

const updates = read('fe-app-prokop/src/prokop/tabs/updates/initController.ts');
const componentAction = functionBody(updates,
  'async function handleComponentAction(button: ComponentActionButton)');
assert.match(componentAction,
  /button\.action === 'remove' &&\s*!\(await confirmComponentRemoval\(button\)\)[\s\S]*?return;/,
  'component removal must be confirmed');
assert(componentAction.indexOf('confirmComponentRemoval') < componentAction.indexOf('componentActionStart('),
  'component removal is confirmed before the backend call');

const history = read('fe-app-prokop/src/prokop/tabs/history/initController.ts');
assertConfirmedBefore(functionBody(history, 'async function restoreSnapshot(id: string, label: string)'),
  'confirmAction(', 'snapshotRestore(', 'restore snapshot');
assertConfirmedBefore(functionBody(history, 'async function deleteSnapshot(id: string, label: string)'),
  'confirmAction(', 'snapshotDelete(', 'delete snapshot');
const settings = read('luci-app-prokop/htdocs/luci-static/resources/view/prokop/settings.js');
assert.doesNotMatch(settings, /snapshotRestore|snapshotDelete|window\.confirm\(/,
  'snapshots live on the History and recovery page only');

console.log('Destructive actions ask for confirmation first');
NODE
