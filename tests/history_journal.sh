#!/bin/sh
set -eu
# Persistent history (/etc/prokop/history.jsonl): significant events survive
# reboots, the journal stays within its cap without rewriting on every
# event, autotune applies keep their own kind, and snapshots mark the
# last-known-working one.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
HEALTH="$ROOT/prokop/files/usr/lib/diagnostics/health.uc"
export PROKOP_RUNTIME_STATE_DIR="$TEST_DIR/run"
export PROKOP_HISTORY_FILE="$TEST_DIR/etc/history.jsonl"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# No journal yet: fall back to the runtime events, marked non-persistent.
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" history > "$TEST_DIR/empty.json"
grep -q '"persistent": false' "$TEST_DIR/empty.json" || fail "missing journal must be reported as non-persistent"

ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" record start success
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" record autotune_apply recovered
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" record snapshot_create success
if ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" record probe success; then fail "unknown event kinds must be refused"; fi
# Nothing ever recorded a recovery event; the kind is gone (UC-173).
if ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" record recovery success; then fail "the retired recovery kind must be refused"; fi
[ "$(wc -l < "$PROKOP_HISTORY_FILE")" -eq 3 ] || fail "each recorded event must append exactly one journal line"

ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" history > "$TEST_DIR/history.json"
node - "$TEST_DIR/history.json" <<'JS'
const assert = require('node:assert/strict');
const value = JSON.parse(require('node:fs').readFileSync(process.argv[2]));
assert.equal(value.persistent, true);
assert.deepEqual(value.events.map((event) => [event.kind, event.status]), [
  ['start', 'success'],
  ['autotune_apply', 'recovered'],
  ['snapshot_create', 'success'],
]);
assert(value.events.every((event) => Number.isInteger(event.timestamp)));
JS

# The runtime events (health) see the same kinds.
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" get > "$TEST_DIR/health.json" 2>/dev/null || true

# Cap (config/retention.uc, default 50 records): the history shows the
# newest 50, and the journal is rewritten only when it outgrows them by a
# quarter (12 records here), then keeps the newest 50, so appends stay cheap.
i=0
while [ "$i" -lt 58 ]; do
  printf '{"kind":"reload","status":"success","timestamp":%d}\n' "$i" >> "$PROKOP_HISTORY_FILE"
  i=$((i + 1))
done
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" record reload success
[ "$(wc -l < "$PROKOP_HISTORY_FILE")" -eq 62 ] || fail "journal within the slack must only be appended to"
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" history > "$TEST_DIR/capped.json"
node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1]));if(v.events.length!==50||v.events[0].timestamp!==9||v.retention.history_limit!==50||v.retention.snapshot_limit!==20||v.retention.manual_snapshot_limit!==18)process.exit(1)' "$TEST_DIR/capped.json" ||
  fail "history must show the newest 50 records and the limits: $(cat "$TEST_DIR/capped.json")"
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" record reload success
[ "$(wc -l < "$PROKOP_HISTORY_FILE")" -eq 50 ] || fail "trimmed journal must keep the newest 50 records"
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" record restore success
[ "$(wc -l < "$PROKOP_HISTORY_FILE")" -eq 51 ] || fail "journal under the cap must only be appended to"
tail -n 1 "$PROKOP_HISTORY_FILE" | grep -q '"kind": *"restore"' || fail "newest event must be last"

# Corrupt lines are skipped, not fatal.
printf 'not json\n' >> "$PROKOP_HISTORY_FILE"
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" history > /dev/null || fail "corrupt journal lines must not break history"

# An autotune apply is a configuration transaction for last_reload.
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"prokop":{"running":1,"dns_configured":1},"sing_box":{"running":1}}},"guard":false,"package_pending":false,"events":[{"kind":"reload","status":"success","timestamp":10},{"kind":"autotune_apply","status":"success","timestamp":20}]}
JSON
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" fixture "$TEST_DIR/fixture.json" | grep -q '"kind": *"autotune_apply"' ||
  fail "autotune apply must count as the last reload"

# An autotune rollback is an event of its own kind, never a restore, with who
# started it and the candidate it rolled back (UC-060, design H.6); its
# restore reloads the runtime, so it counts as the last reload too.
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" record autotune_rollback success automatic multisplit || fail "autotune rollback event refused"
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" record autotune_rollback failure manual 'bad name' || fail "autotune rollback event refused"
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" history > "$TEST_DIR/rollback.json"
node - "$TEST_DIR/rollback.json" <<'JS'
const assert = require('node:assert/strict');
const events = JSON.parse(require('node:fs').readFileSync(process.argv[2])).events;
assert.deepEqual(events.slice(-2).map(({ kind, status, trigger, candidate }) => ({ kind, status, trigger, candidate })), [
  { kind: 'autotune_rollback', status: 'success', trigger: 'automatic', candidate: 'multisplit' },
  { kind: 'autotune_rollback', status: 'failure', trigger: 'manual', candidate: undefined },
]);
JS
sed 's/"autotune_apply"/"autotune_rollback"/' "$TEST_DIR/fixture.json" > "$TEST_DIR/rollback-fixture.json"
ucode -L "$ROOT/prokop/files/usr/lib" "$HEALTH" fixture "$TEST_DIR/rollback-fixture.json" | grep -q '"kind": *"autotune_rollback"' ||
  fail "autotune rollback must count as the last reload"

# Snapshot list marks the last-known-working snapshot.
SNAP="$TEST_DIR/snapshots"
mkdir -p "$SNAP"
hash=$(printf 'x' | sha256sum | cut -c1-64)
for id in 1_a 2_b; do
  printf '{"id":"%s","created_at":%s,"kind":"automatic","reason":"before-reload","config_hash":"%s","prokop_version":"1.0.0","content":"x"}' \
    "$id" "${id%%_*}" "$hash" > "$SNAP/$id.json"
done
printf '2_b\n' > "$SNAP/last-known-working"
PROKOP_SNAPSHOT_DIR="$SNAP" ucode -L "$ROOT/prokop/files/usr/lib" "$ROOT/prokop/files/usr/lib/config/snapshots.uc" list > "$TEST_DIR/list.json"
node - "$TEST_DIR/list.json" <<'JS'
const assert = require('node:assert/strict');
const list = JSON.parse(require('node:fs').readFileSync(process.argv[2]));
assert.deepEqual(list.map((item) => [item.id, item.is_lkg]), [['1_a', false], ['2_b', true]]);
JS

# The CLI exposes history as a read command.
grep -q 'get_history: \[ "diagnostics/health.uc", "history", 0 \]' "$ROOT/prokop/files/usr/bin/prokop" ||
  fail "prokop get_history must dispatch to health.uc history"

echo "history journal checks passed"
