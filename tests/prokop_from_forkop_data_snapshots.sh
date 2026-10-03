#!/bin/sh
# Configuration snapshots Forkop took (copied by the migrating installer from
# /etc/forkop/config-snapshots) record their version under forkop_version.
# Prokop lists and compares them with that version; new snapshots record
# prokop_version only.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export PROKOP_CONFIG_FILE="$WORK/prokop"
export PROKOP_SNAPSHOT_DIR="$WORK/snapshots"
export PROKOP_UCI_SAVEDIR="$WORK/uci-save"
export PROKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json"
export PROKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export PROKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export PROKOP_LIB="$LIB"
export PROKOP_HISTORY_FILE="$WORK/history.jsonl"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export PROKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
# show_version of the running release, for the snapshot created below.
mkdir -p "$WORK/bin" "$PROKOP_SNAPSHOT_DIR"
printf '#!/bin/sh\n[ "$1" = show_version ] && echo 2.0.0\n' >"$WORK/bin/prokop"
chmod 0755 "$WORK/bin/prokop"
export PROKOP_BIN="$WORK/bin/prokop"
chmod 0700 "$PROKOP_SNAPSHOT_DIR"

cat >"$WORK/forkop-content" <<'UCI'
config settings 'settings'
 option dns_server '1.1.1.1'
UCI
cat >"$PROKOP_CONFIG_FILE" <<'UCI'
config settings 'settings'
 option dns_server '8.8.8.8'
UCI

# A snapshot exactly as Forkop wrote it, and one with an unusable version.
node - "$WORK" <<'JS'
const fs = require('node:fs');
const crypto = require('node:crypto');
const dir = process.argv[2];
const content = fs.readFileSync(`${dir}/forkop-content`, 'utf8');
const config_hash = crypto.createHash('sha256').update(content).digest('hex');
const write = (id, created_at, extra) => fs.writeFileSync(`${dir}/snapshots/${id}.json`,
  JSON.stringify({ id, created_at, kind: 'manual', reason: 'manual', config_hash, ...extra, content }) + '\n',
  { mode: 0o600 });
write('100_1', 100, { forkop_version: '1.0.26' });
write('101_1', 101, { forkop_version: '1.0.26; rm -rf /' });
JS

ucode -L "$LIB" "$SCRIPT" list >"$WORK/list.json" || fail "listing Forkop snapshots failed"
ucode -L "$LIB" "$SCRIPT" diff 100_1 >"$WORK/diff.json" || fail "a Forkop snapshot could not be compared"
ucode -L "$LIB" "$SCRIPT" create manual >"$WORK/create.json" || fail "creating a snapshot failed"

node - "$WORK" <<'JS' || fail "snapshot versions"
const fs = require('node:fs');
const assert = require('node:assert/strict');
const dir = process.argv[2];
const list = JSON.parse(fs.readFileSync(`${dir}/list.json`, 'utf8'));
const byId = Object.fromEntries(list.map((item) => [item.id, item]));
assert.equal(byId['100_1']?.prokop_version, '1.0.26', 'a Forkop snapshot must show the version Forkop recorded');
assert.equal(byId['101_1']?.prokop_version, 'unknown', 'an unusable recorded version must not be shown');
assert.equal('forkop_version' in byId['100_1'], false, 'the list must name the version prokop_version only');
const diff = JSON.parse(fs.readFileSync(`${dir}/diff.json`, 'utf8'));
assert.deepEqual(diff.find((row) => row.option === 'dns_server'),
  { section: 'settings', option: 'dns_server', before: '1.1.1.1', after: '8.8.8.8' });
const created = JSON.parse(fs.readFileSync(`${dir}/create.json`, 'utf8'));
assert.equal(created.status, 'created');
const stored = JSON.parse(fs.readFileSync(`${dir}/snapshots/${created.snapshot.id}.json`, 'utf8'));
assert.equal(stored.prokop_version, '2.0.0');
assert.equal('forkop_version' in stored, false, 'a new snapshot must not be written under the Forkop key');
JS

printf 'prokop from forkop data snapshots: PASS\n'
