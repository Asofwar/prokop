#!/usr/bin/env bash
set -euo pipefail

# Save & Apply on the Rules and Settings pages, through the path LuCI takes
# (UC-064, UC-224): the footer button is bound to the view's
# handleSaveApply (luci.js, OpenWrt 24.10 and 25.12), which saves the page's
# maps and then calls ui.changes.apply(); form.Map has no handleSaveApply.
# The pages take a snapshot of the configuration before the apply first. A
# refused snapshot saves the changes but applies nothing, and says so. LuCI
# reloads the page once it has confirmed the apply, before the Prokop reload
# that the commit starts has finished: the page that loads then reports that
# reload (confirmed with what changed, failed, Prokop not running, or not
# confirmed in time) from the health record, never from the apply alone.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment, cliAnswers } = require(process.argv[2]);
// main.js logs every CLI call at debug level.
const print = console.log;
console.log = (...args) => `${args[0]}`.startsWith('[DEBUG]') || print(...args);

const config = () => ({
  vpn: { '.name': 'vpn', '.type': 'section', '.anonymous': false, enabled: '1', label: 'VPN',
    action: 'connection', selector_proxy_links: ['socks5://10.0.0.1:1080'] },
  settings: { '.name': 'settings', '.type': 'settings', '.anonymous': false, dns_rewrite_ttl: '60',
    yacd_secret_key: 'secret-0123456789' },
});
const installed = { loaded: true, zapretInstalled: true, zapret2Installed: true, byedpiInstalled: true };
const created = { status: 'created', snapshot: { id: '1_1', kind: 'automatic' } };
const reloadAt = (timestamp, status = 'success') => ({ kind: 'reload', status, timestamp });
// busy: a reload runs or the list worker that ends in one (reload.lock).
const health = (last_reload, prokop = 'ok', busy = false) => ({ overall: 'ok', service: { prokop, sing_box: 'ok' },
  last_reload, reload: { busy } });

// A page load with the CLI answering `answers`; log keeps the order of the
// CLI calls, the map saves and the apply.
function page(version, answers, sessionStorage) {
  const log = [];
  const env = createEnvironment({ version, config: config(), fs: cliAnswers(answers, log), sessionStorage });
  const save = env.uci.save;
  env.uci.save = () => {
    log.push('uci.save');
    return save();
  };
  const apply = env.ui.changes.apply;
  env.ui.changes.apply = function (checked) {
    log.push(`apply ${checked}`);
    return apply.call(this, checked);
  };
  const calls = (pattern) => log.filter((entry) => pattern.test(entry));
  return { env, log, calls };
}

// The Rules page with the rule disabled, or Settings with a new TTL.
const pages = {
  async rules(env) {
    const rules = await env.openRules();
    rules.setEnabled('vpn', '0');
    return { view: rules, edited: () => env.uci.data.vpn.enabled === '0' };
  },
  async settings(env) {
    const settings = await env.openSettings(installed);
    settings.option('dns_rewrite_ttl').getUIElement('settings').setValue('30');
    return { view: settings, edited: () => env.uci.data.settings.dns_rewrite_ttl === '30' };
  },
};

const RECORD = 'prokop-pending-apply';
const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.stack || error.message}`);
  }
}

(async () => {
  for (const version of ['24.10', '25.12']) {
    for (const [name, open] of Object.entries(pages)) {
      await check(`${version} ${name}: snapshot, then LuCI's save and apply`, async () => {
        const { env, log, calls } = page(version, { config_snapshot_create: created,
          get_health_status: health(reloadAt(100)) });
        const { view, edited } = await open(env);
        // LuCI binds the footer to the view; the form map has no
        // handleSaveApply of its own to override.
        assert.equal(view.map.handleSaveApply, undefined, 'a Save & Apply hook on the form map is never called');
        await view.saveApply('0');
        const order = log.filter((entry) => /^exec config_snapshot_create|^uci\.save$|^apply /.test(entry));
        assert.deepEqual(order, ['exec config_snapshot_create before-apply', 'uci.save', 'apply true'],
          'the snapshot must come before LuCI saves and applies');
        assert.equal(edited(), true);
        assert.deepEqual(env.ui.changes.applies, [true]);
        assert.equal(env.notifications.length, 0, 'nothing to report before LuCI has applied');
        // Apply unchecked keeps the snapshot first as well.
        await view.saveApply('1');
        assert.deepEqual(calls(/^exec config_snapshot_create|^apply /).slice(2),
          ['exec config_snapshot_create before-apply', 'apply false']);
      });

      await check(`${version} ${name}: a refused snapshot saves but does not apply`, async () => {
        const { env, calls } = page(version, { config_snapshot_create:
          { code: 1, data: { status: 'busy', reason: 'snapshot_operation_in_progress' } } });
        const { view, edited } = await open(env);
        await view.saveApply('0');
        assert.deepEqual(env.ui.changes.applies, [], 'applied without a pre-apply snapshot');
        assert.equal(calls(/^uci\.save$/).length, 1, 'the changes must be saved as Save does');
        assert.equal(edited(), true);
        assert.equal(calls(/get_health_status/).length, 0);
        assert.equal(env.notifications.length, 1);
        assert.equal(env.notifications[0].type, 'error');
        assert.match(env.notifications[0].text, /Another snapshot operation is already in progress/);
        assert.match(env.notifications[0].text,
          /The changes are saved: Save & Apply applies them once a snapshot can be taken\./);
        // LuCI never confirmed an apply: the next page reports nothing.
        env.confirmApply();
        assert.equal(env.sessionStorage.has(RECORD), false);
      });
    }

    // The page LuCI reloads into after it confirmed the apply.
    const applied = async (answers) => {
      const first = page(version, { config_snapshot_create: created, get_health_status: health(reloadAt(100)) });
      await (await pages.rules(first.env)).view.saveApply('0');
      first.env.confirmApply();
      assert.equal(first.env.sessionStorage.has(RECORD), true, 'the confirmed apply must be kept for the next page');
      return { first, next: () => {
        const next = page(version, answers, first.env.sessionStorage);
        return next.env.openRules().then(() => next.env.settle()).then(() => next);
      } };
    };

    await check(`${version} reload confirmed after the page reload`, async () => {
      let polls = 0;
      const { next } = await applied({
        // Before the reload has run, then the reload of this apply.
        get_health_status: () => health(reloadAt(polls++ ? 105 : 100)),
        config_snapshot_diff: (args) => (assert.equal(args[1], '1_1'),
          [{ section: 'vpn', option: 'enabled', before: '1', after: '0' }]),
      });
      const reloaded = await next();
      assert.equal(reloaded.env.sessionStorage.has(RECORD), false, 'the record must be used once');
      assert.equal(reloaded.env.notifications.length, 0, 'reported before the reload ran');
      await reloaded.env.runTimers();
      assert.equal(reloaded.env.notifications.length, 1);
      assert.equal(reloaded.env.notifications[0].type, 'info');
      assert.equal(reloaded.env.notifications[0].text, 'Configuration applied successfully\nvpn.enabled: 1 → 0');
      assert.equal(reloaded.calls(/config_snapshot_diff 1_1/).length, 1);
    });

    await check(`${version} failed reload after the page reload`, async () => {
      const { next } = await applied({ get_health_status: health(reloadAt(105, 'failure')) });
      const reloaded = await next();
      assert.equal(reloaded.env.notifications.length, 1);
      assert.equal(reloaded.env.notifications[0].type, 'warning');
      assert.equal(reloaded.env.notifications[0].text,
        'Configuration saved. Runtime reload failed; check History and recovery.');
      assert.equal(reloaded.calls(/config_snapshot_diff/).length, 0);
    });

    // An explicit stop holds the runtime down: no reload follows (D-15).
    for (const state of ['stopped', 'not_started'])
      await check(`${version} Prokop ${state} after the page reload`, async () => {
        const { next } = await applied({ get_health_status: health(reloadAt(100), state) });
        const reloaded = await next();
        assert.equal(reloaded.env.notifications.length, 1);
        assert.equal(reloaded.env.notifications[0].type, 'warning');
        assert.equal(reloaded.env.notifications[0].text,
          'Configuration saved. Prokop is not running: the changes take effect when it is started.');
      });

    // Another kind of event (a restore, an autotune apply) is not the
    // reload of this apply.
    await check(`${version} no reload within the wait`, async () => {
      const { first, next } = await applied({ get_health_status: health({ kind: 'restore', status: 'success',
        timestamp: 105 }) });
      const record = JSON.parse(first.env.sessionStorage.get(RECORD));
      record.confirmedAt -= 91 * 1000;
      first.env.sessionStorage.set(RECORD, JSON.stringify(record));
      const reloaded = await next();
      assert.equal(reloaded.env.notifications.length, 1);
      assert.equal(reloaded.env.notifications[0].type, 'warning');
      assert.equal(reloaded.env.notifications[0].text,
        'Configuration saved. Runtime reload has not been confirmed; check History and recovery.');
    });

    await check(`${version} an old record is dropped unreported`, async () => {
      const { first, next } = await applied({ get_health_status: health(reloadAt(105)) });
      const record = JSON.parse(first.env.sessionStorage.get(RECORD));
      record.confirmedAt -= 11 * 60 * 1000;
      first.env.sessionStorage.set(RECORD, JSON.stringify(record));
      const reloaded = await next();
      assert.equal(reloaded.env.notifications.length, 0);
      assert.equal(reloaded.env.sessionStorage.has(RECORD), false);
      assert.equal(reloaded.calls(/get_health_status/).length, 0);
    });

    // The change list cannot be read (the snapshot is gone, the CLI failed):
    // the reload is confirmed, and the notice says that its list is missing
    // instead of a bare success.
    await check(`${version} change list unavailable`, async () => {
      let polls = 0;
      const { next } = await applied({
        get_health_status: () => health(reloadAt(polls++ ? 105 : 100)),
        config_snapshot_diff: { code: 1, stdout: '' },
      });
      const reloaded = await next();
      await reloaded.env.runTimers();
      assert.equal(reloaded.env.notifications.length, 1);
      assert.equal(reloaded.env.notifications[0].type, 'info');
      assert.equal(reloaded.env.notifications[0].text,
        'Configuration applied successfully\nThe list of changes is unavailable.');
    });

    // A reload newer than the one before the apply is this apply's only once
    // no other reload runs or waits: one that ran when the page reloaded may
    // be an older apply's, with this one queued behind it.
    await check(`${version} reload reported once the runtime has settled`, async () => {
      let polls = 0;
      const { next } = await applied({
        get_health_status: () => (polls++ ? health(reloadAt(107)) : health(reloadAt(105), 'ok', true)),
        config_snapshot_diff: [{ section: 'vpn', option: 'enabled', before: '1', after: '0' }],
      });
      const reloaded = await next();
      assert.equal(reloaded.env.notifications.length, 0, 'reported while another reload still ran');
      await reloaded.env.runTimers();
      assert.equal(reloaded.env.notifications.length, 1);
      assert.equal(reloaded.env.notifications[0].type, 'info');
      assert.equal(reloaded.calls(/get_health_status/).length, 2);
    });

    // A reload that runs when Save & Apply is clicked (an earlier apply's,
    // a list update's) ends with a reload event that may come before or
    // after this apply's: nothing tells them apart, so nothing is claimed.
    await check(`${version} reload running at the click`, async () => {
      const first = page(version, { config_snapshot_create: created,
        get_health_status: health(reloadAt(100), 'ok', true) });
      await (await pages.rules(first.env)).view.saveApply('0');
      first.env.confirmApply();
      const reloaded = page(version, { get_health_status: health(reloadAt(105)) }, first.env.sessionStorage);
      await reloaded.env.openRules();
      await reloaded.env.settle();
      assert.equal(reloaded.env.notifications.length, 1);
      assert.equal(reloaded.env.notifications[0].type, 'warning');
      assert.match(reloaded.env.notifications[0].text, /Runtime reload has not been confirmed/);
      assert.equal(reloaded.calls(/config_snapshot_diff/).length, 0);
    });

    // An apply that commits nothing of Prokop (only changes of other
    // packages were staged) starts no Prokop reload: nothing to report.
    await check(`${version} apply without Prokop changes`, async () => {
      const { env, calls } = page(version, { config_snapshot_create: created,
        get_health_status: health(reloadAt(100)) });
      const rules = await env.openRules();
      env.uci.state.saved.network = [['set', 'lan']];
      await rules.saveApply('0');
      assert.deepEqual(env.ui.changes.applies, [true], 'LuCI applies the other packages');
      assert.equal(calls(/^exec config_snapshot_create/).length, 1);
      env.confirmApply();
      assert.equal(env.sessionStorage.has(RECORD), false, 'an apply without Prokop changes was kept for a report');
    });

    // An apply that LuCI never confirmed (no changes, refused, rolled back)
    // leaves nothing that a later apply from the header could take as its own.
    await check(`${version} unconfirmed apply forgotten`, async () => {
      const { env } = page(version, { config_snapshot_create: created, get_health_status: health(reloadAt(100)) });
      await (await pages.rules(env)).view.saveApply('0');
      const now = Date.now;
      Date.now = () => now() + 10 * 60 * 1000;
      try {
        env.confirmApply();
      } finally {
        Date.now = now;
      }
      assert.equal(env.sessionStorage.has(RECORD), false, 'a confirmation long after the click was taken for it');
    });

    // During a package upgrade the backend may still be the previous release,
    // which takes only manual and automatic snapshots: its refusal of
    // before-apply names no reason. The same snapshot is taken as automatic.
    await check(`${version} previous backend without before-apply`, async () => {
      const { env, log } = page(version, {
        config_snapshot_create: (args) => (args[1] === 'before-apply' ? { code: 1, data: { status: 'failed' } } : created),
        get_health_status: health(reloadAt(100)),
      });
      await (await pages.rules(env)).view.saveApply('0');
      assert.deepEqual(log.filter((entry) => /^exec config_snapshot_create|^uci\.save$|^apply /.test(entry)),
        ['exec config_snapshot_create before-apply', 'exec config_snapshot_create automatic', 'uci.save', 'apply true']);
      assert.equal(env.notifications.length, 0);
    });
    await check(`${version} a refusal with its reason is not retried`, async () => {
      const { env, calls } = page(version, { config_snapshot_create:
        { code: 1, data: { status: 'failed', reason: 'write_failed' } } });
      await (await pages.rules(env)).view.saveApply('0');
      assert.deepEqual(calls(/^exec config_snapshot_create/), ['exec config_snapshot_create before-apply']);
      assert.deepEqual(env.ui.changes.applies, []);
      assert.match(env.notifications[0].text, /it could not be written/);
    });

    // Without the health record from before the apply nothing tells this
    // reload from an older one.
    await check(`${version} no health before the apply`, async () => {
      const first = page(version, { config_snapshot_create: created, get_health_status: { code: 1, data: {} } });
      await (await pages.rules(first.env)).view.saveApply('0');
      first.env.confirmApply();
      const reloaded = page(version, { get_health_status: health(reloadAt(105)) }, first.env.sessionStorage);
      await reloaded.env.openRules();
      await reloaded.env.settle();
      assert.equal(reloaded.env.notifications.length, 1);
      assert.equal(reloaded.env.notifications[0].type, 'warning');
      assert.match(reloaded.env.notifications[0].text, /Runtime reload has not been confirmed/);
    });
  }

  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_save_apply_snapshot: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
