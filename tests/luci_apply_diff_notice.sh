#!/usr/bin/env bash
set -euo pipefail

# Save & Apply on the Rules and Settings pages (configform.js) takes a
# snapshot first and, once the reload is confirmed, lists what changed since
# it (config_snapshot_diff). The pages are driven as LuCI drives them
# (tests/helpers/luci_form_harness.js): the footer's Save & Apply of the
# view, LuCI's confirmation of the apply, and the page LuCI loads after it,
# which reports the reload (UC-064, UC-224).
# D-2(a), UC-063: an option absent on one side reads "not set", '***' only
# for a value that exists and is hidden. UC-062: a diff longer than the
# backend lists ends with { truncated, total } in place of the rest; the
# notification counts the rest instead of printing the marker as a change.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment, cliAnswers } = require(process.argv[2]);
// main.js logs every CLI call at debug level.
const print = console.log;
console.log = (...args) => `${args[0]}`.startsWith('[DEBUG]') || print(...args);

const config = { settings: { '.name': 'settings', '.type': 'settings', '.anonymous': false,
  dns_rewrite_ttl: '60', yacd_secret_key: 'secret-0123456789' } };
const installed = { loaded: true, zapretInstalled: true, zapret2Installed: true, byedpiInstalled: true };
const health = (timestamp) => ({ service: { prokop: 'ok' },
  last_reload: { kind: 'reload', status: 'success', timestamp } });

// Save & Apply on Settings, then the page LuCI loads once the apply is
// confirmed; the reload of the apply is recorded by then.
async function saveApply(version, entries) {
  const env = createEnvironment({ version, config, fs: cliAnswers({
    config_snapshot_create: { status: 'created', snapshot: { id: '1_1' } },
    get_health_status: health(100),
  }) });
  const settings = await env.openSettings(installed);
  settings.option('dns_rewrite_ttl').getUIElement('settings').setValue('30');
  await settings.saveApply('0');
  assert.deepEqual(env.ui.changes.applies, [true]);
  env.confirmApply();

  const next = createEnvironment({ version, config, sessionStorage: env.sessionStorage, fs: cliAnswers({
    get_health_status: health(105),
    config_snapshot_diff: (args) => (assert.equal(args[1], '1_1'), entries),
  }) });
  await next.openSettings(installed);
  await next.settle();
  assert.equal(next.notifications.length, 1);
  assert.equal(next.notifications[0].type, 'info');
  // Text nodes: a configuration value is never parsed as HTML.
  assert.equal(next.notifications[0].node.markup, undefined);
  return next.notifications[0].text.split('\n');
}

const change = (i) => ({ section: 'settings', option: `opt${i}`, before: 'a', after: 'b' });

(async () => {
  for (const version of ['24.10', '25.12']) {
    // D-2(a): absent sides read "not set"; hidden values stay '***'.
    assert.deepEqual(await saveApply(version, [
      { section: 'settings', option: 'password', before: null, after: '***' },
      { section: '@section_interface[0]', option: 'dns_type', before: 'udp', after: null },
      { section: 'settings', option: 'dns_server', kind: 'list', before: null, after: ['1.1.1.1'] },
    ]), [
      'Configuration applied successfully',
      'settings.password: not set → ***',
      '@section_interface[0].dns_type: udp → not set',
      'settings.dns_server: not set → ["1.1.1.1"]',
    ]);

    // UC-062: 100 listed changes of 250; the marker is no change row.
    const lines = await saveApply(version, [...Array.from({ length: 100 }, (_, i) => change(i)),
      { truncated: true, total: 250 }]);
    assert.equal(lines.length, 102);
    assert.equal(lines[1], 'settings.opt0: a → b');
    assert.equal(lines[100], 'settings.opt99: a → b');
    assert.equal(lines[101], 'and 150 more');
    assert.equal(lines.some((line) => line.includes('undefined')), false);

    // A whole diff has no "more" line.
    assert.deepEqual(await saveApply(version, [change(0)]),
      ['Configuration applied successfully', 'settings.opt0: a → b']);

    // A value that looks like markup is shown as text.
    assert.deepEqual(await saveApply(version, [{ section: 'settings', option: 'label', before: 'a',
      after: '<img src=x onerror=alert(1)>' }]),
    ['Configuration applied successfully', 'settings.label: a → <img src=x onerror=alert(1)>']);
  }

  console.log('luci_apply_diff_notice: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
