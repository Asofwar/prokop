#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js" <<'NODE'
const fs = require('fs');
const assert = require('assert');

const source = fs.readFileSync(process.argv[2], 'utf8');
const match = source.match(
  /function configureSectionSection\(sectionRef, options = \{\}\) \{[\s\S]*?\n\}\n\nconst EntryPoint/,
);
assert(match, 'configureSectionSection not found');

const cleanupCalls = [];
function setActionProvidersAvailabilityLoader() {}
function loadSectionTableOptions() {}
function cleanupRemovedChildItems(...args) {
  cleanupCalls.push(args);
}
const overrideCleanups = [];
function cleanupRuleUrlTestOverrides(...args) {
  overrideCleanups.push(args);
}
// The staged uci state is captured before the cleanups and put back when the
// save that follows the removal is refused.
const snapshot = { staged: true };
const restored = [];
function captureStagedUciState() {
  assert.deepStrictEqual(cleanupCalls, [], 'the staged state must be captured before the cleanups');
  return snapshot;
}
function restoreStagedUciState(value) {
  restored.push(value);
}
// A rule that Settings use is refused before anything is staged.
let settingsRefusal = null;
function settingsRuleUseRefusal() {
  return settingsRefusal;
}
const notifications = [];
const ui = { addNotification: (...args) => notifications.push(args) };
const E = (...args) => args;
const _ = (text) => ({ format: (...values) => `${text} ${values.join(' ')}` });
eval(match[0].slice(0, -'\n\nconst EntryPoint'.length));

const event = {};
const result = {};
let parentArgs;
let parentThis;
const sectionRef = {
  handleRemove(...args) {
    parentArgs = args;
    parentThis = this;
    return result;
  },
};
configureSectionSection(sectionRef);

const removal = sectionRef.handleRemove('parent', event);
assert.deepStrictEqual(cleanupCalls, [
  ['parent', 'subscription_url', []],
  ['parent', 'section_interface', []],
  ['parent', 'urltest', []],
  ['parent', 'priority_group', []],
]);
assert.deepStrictEqual(overrideCleanups, [['parent']], 'URLTest overrides of the rule are not removed');
assert.deepStrictEqual(parentArgs, ['parent', event]);
assert.strictEqual(parentThis, sectionRef);
assert.match(
  source,
  /typeName === "priority_group"[\s\S]*cleanupPriorityLevelsForGroup\(itemId\)/,
  'priority_group cleanup does not cascade to priority_level',
);

removal
  .then((value) => {
    assert.strictEqual(value, result);
    assert.deepStrictEqual(restored, [], 'a saved removal must not restore the staged state');

    cleanupCalls.length = 0;
    sectionRef.handleRemove = function () {
      return Promise.reject(new Error('refused'));
    };
    configureSectionSection(sectionRef);
    return sectionRef.handleRemove('parent', event);
  })
  .then(() => {
    assert.deepStrictEqual(restored, [snapshot], 'a refused removal must restore the staged state');
    assert.strictEqual(notifications.length, 1, 'a refused removal must be reported');

    cleanupCalls.length = 0;
    overrideCleanups.length = 0;
    let parentCalled = false;
    sectionRef.handleRemove = function () {
      parentCalled = true;
      return Promise.resolve();
    };
    configureSectionSection(sectionRef);
    settingsRefusal = 'in use';
    return sectionRef.handleRemove('parent', event).then(() => {
      assert.strictEqual(parentCalled, false, 'a rule that Settings use must not be removed');
      assert.deepStrictEqual(cleanupCalls, [], 'its child items must not be cleaned up');
      assert.deepStrictEqual(overrideCleanups, [], 'its URLTest overrides must not be removed');
      assert.strictEqual(notifications.length, 2, 'the refusal must be reported');
    });
  })
  .then(() => {
    console.log('LuCI section cascade checks passed');
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
NODE
