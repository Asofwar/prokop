#!/usr/bin/env bash
# NET-12: the client DNS intercept is off by default. The migration of a
# package upgrade turns it off once on a router that had it on (explicitly
# or by the old default), with a notice the History page shows; one that
# had it off keeps it, and turning it on again afterwards sticks (the
# migration is recorded in applied_migrations). The shipped configuration
# has it off.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
export PROKOP_LIB
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -q "^[[:space:]]*option intercept_client_dns '0'$" "$ROOT_DIR/prokop/files/etc/config/prokop" ||
  fail "the shipped configuration must have the intercept off"
grep -Fq "list applied_migrations 'client_dns_intercept_off_v1'" "$ROOT_DIR/prokop/files/etc/config/prokop" ||
  fail "the shipped configuration must mark client_dns_intercept_off_v1 as applied"

# settings fixture: $1 name, $2 extra settings JSON members
fixture() {
  cat >"$WORK_DIR/$1.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.5",
    "dns_server": "1.1.1.1"$2
  },
  "section": []
}
JSON
}
migrate() {
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/migration.uc" migrate-fixture "$WORK_DIR/$1.json" >"$WORK_DIR/$1.out.json" ||
    fail "$1: migration failed"
}

fixture absent ''
fixture on ', "intercept_client_dns": "1"'
fixture auto ', "intercept_client_dns": "auto"'
fixture off ', "intercept_client_dns": "0"'
fixture again ', "intercept_client_dns": "1", "applied_migrations": [ "client_dns_intercept_off_v1" ]'
for name in absent on auto off again; do migrate "$name"; done

node - "$WORK_DIR" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('fs');
const read = (name) => JSON.parse(fs.readFileSync(`${process.argv[2]}/${name}.out.json`, 'utf8'));
const notices = (out) => out.notices.filter((notice) => notice.code === 'client_dns_intercept_off');
for (const [name, from] of [['absent', '1'], ['on', '1'], ['auto', 'auto']]) {
  const out = read(name);
  assert.equal(out.config.settings.intercept_client_dns, '0', name);
  assert(out.config.settings.applied_migrations.includes('client_dns_intercept_off_v1'), name);
  assert.deepEqual(notices(out), [
    { code: 'client_dns_intercept_off', section: 'settings', values: ['intercept_client_dns'], from, to: '0' },
  ], name);
}
const off = read('off');
assert.equal(off.config.settings.intercept_client_dns, '0');
assert(off.config.settings.applied_migrations.includes('client_dns_intercept_off_v1'));
assert.deepEqual(notices(off), []);
// Turned on again after the migration ran: it stays on.
const again = read('again');
assert.equal(again.config.settings.intercept_client_dns, '1');
assert.deepEqual(notices(again), []);
NODE

# The history keeps the notice; a forged value is dropped.
PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/diagnostics/health.uc" record config_migration success "" "" \
  '{"notices":[{"code":"client_dns_intercept_off","section":"settings","values":["intercept_client_dns"],"from":"auto","to":"0"},{"code":"client_dns_intercept_off","section":"settings","values":["intercept_client_dns"],"from":"<b>","to":"0"}]}'
PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/diagnostics/health.uc" history >"$WORK_DIR/history.json"
node - "$WORK_DIR/history.json" <<'NODE'
const assert = require('node:assert/strict');
const history = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
assert.deepEqual(history.events[0].notices, [
  { code: 'client_dns_intercept_off', section: 'settings', values: ['intercept_client_dns'], replacements: [], from: 'auto', to: '0' },
]);
NODE

printf 'client_dns_intercept_migration: ok\n'
