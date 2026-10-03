#!/usr/bin/env bash
set -euo pipefail

# A DPI strategy is checked by the backend parser (/usr/bin/prokop
# validate_*_strategy_json) before the rule editor saves it. A failed call
# (rpcd timeout, access denied, unparsable output) refuses this Save and the
# strategy field says the check is unavailable (LuCI drops the rejection of a
# modal save silently), but it is not remembered as a verdict: the next Save
# asks the backend again and succeeds once it answers (UC-040). Real verdicts
# stay cached. A read-only session, which may not run the backend parser and
# cannot save, does not ask it when the field renders.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

const cases = [
  ['zapret', 'nfqws_opt', 'validate_nfqws_strategy_json', '--filter-tcp=443 --dpi-desync=fake'],
  ['zapret2', 'nfqws2_opt', 'validate_nfqws2_strategy_json',
    '--filter-tcp=443 --lua-desync=fake:blob=fake_default_tls'],
  ['byedpi', 'byedpi_cmd_opts', 'validate_byedpi_strategy_json', '-o 1 -d 1'],
];

const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.stack || error.message}`);
  }
}

function rule(action, option, value) {
  return { '.name': 'rule', '.type': 'section', '.anonymous': false, enabled: '1', action,
    mixed_proxy_enabled: '0', community_lists: ['youtube'], [option]: value };
}

(async () => {
  for (const version of ['24.10', '25.12'])
    for (const [action, option, command, original] of cases)
      for (const [label, failure] of [
        ['rpc rejects', () => Promise.reject(new Error('Access denied'))],
        ['empty output', () => Promise.resolve({ code: 1, stdout: '', stderr: 'timeout' })],
        ['unparsable output', () => Promise.resolve({ code: 0, stdout: 'Segmentation fault', stderr: '' })],
      ]) await check(`${version} ${action}: ${label}`, async () => {
        const answers = [failure, () => Promise.resolve({ code: 0, stdout: '{"valid":true}', stderr: '' })];
        let calls = 0;
        const env = createEnvironment({ version, config: { rule: rule(action, option, original) },
          fs: {
            exec(_command, args) {
              if (args && args[0] === command) return answers[Math.min(calls++, answers.length - 1)]();
              return Promise.resolve({ code: 0, stdout: '{}', stderr: '' });
            },
          } });
        const modal = await env.openRule('rule');
        const edited = `${original} ${action === 'byedpi' ? '-d 2' : '--new --filter-udp=443'}`;
        modal.option(option).getUIElement('rule').setValue(edited);

        await assert.rejects(modal.save(), (error) => {
          assert.match(error.message, /Backend validation unavailable: .*[^.]\. Save again to retry\.$/);
          return true;
        });
        assert.equal(env.uci.data.rule[option], original, 'a failed validation saved the strategy');
        assert.match(modal.option(option).getValidationError('rule'),
          /Backend validation unavailable: .*Save again to retry\./,
          'the strategy field must say why Save did nothing');

        await modal.save();
        assert.equal(calls, 2, 'the backend must be asked again');
        assert.equal(env.uci.data.rule[option], edited);
        assert.equal(modal.option(option).isValid('rule'), true, 'the answered check must clear the field');
      });

  // The rendered NFQWS and NFQWS2 fields ask the backend at once. The ACL
  // grants /usr/bin/prokop only with write access, so for a read-only
  // session the call fails, and the field would show "Backend validation
  // unavailable ... Save again to retry" to a user who cannot save.
  for (const version of ['24.10', '25.12'])
    for (const [action, option, command, original] of cases.filter(([action]) => action !== 'byedpi'))
      for (const readonly of [true, false])
        await check(`${version} ${action}: rendered field, ${readonly ? 'read-only' : 'writable'} session`, async () => {
          let calls = 0;
          const env = createEnvironment({ version, config: { rule: rule(action, option, original) },
            fs: {
              exec(_command, args) {
                if (args && args[0] === command) {
                  calls += 1;
                  return Promise.reject(new Error('Access denied'));
                }
                return Promise.resolve({ code: 0, stdout: '{}', stderr: '' });
              },
            } });
          const modal = await env.openRule('rule', { readonly });
          env.window.setTimeout = (fn) => { fn(); return 1; };
          modal.option(option).renderWidget('rule', 0, original);
          await new Promise((resolve) => setImmediate(resolve));
          if (readonly) {
            assert.equal(calls, 0, 'a read-only field must not ask the backend');
            assert.equal(modal.option(option).isValid('rule'), true, 'a read-only field must not show a failed check');
          } else {
            assert.equal(calls, 1, 'the rendered field must ask the backend');
            assert.match(modal.option(option).getValidationError('rule'), /Backend validation unavailable/);
          }
        });

  // A real verdict is cached: an invalid strategy is not re-sent.
  for (const version of ['24.10', '25.12'])
    await check(`${version} verdict is cached`, async () => {
      let calls = 0;
      const env = createEnvironment({ version, config: { rule: rule('byedpi', 'byedpi_cmd_opts', '-o 1') },
        fs: {
          exec(_command, args) {
            if (args && args[0] === 'validate_byedpi_strategy_json') {
              calls++;
              return Promise.resolve({ code: 0, stdout: '{"valid":false,"message":"Unknown ByeDPI option"}' });
            }
            return Promise.resolve({ code: 0, stdout: '{}', stderr: '' });
          },
        } });
      const modal = await env.openRule('rule');
      modal.option('byedpi_cmd_opts').getUIElement('rule').setValue('-o 1 -d 1');
      await assert.rejects(modal.save(), /Unknown ByeDPI option/);
      await assert.rejects(modal.save(), /Unknown ByeDPI option/);
      assert.equal(calls, 1);
    });

  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_strategy_validation_retry: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
