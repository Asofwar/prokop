#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
# Recorded events must stay out of /etc/prokop and /var/run/prokop.
export PROKOP_HISTORY_FILE="$TEST_DIR/history.jsonl"
export PROKOP_RUNTIME_STATE_DIR="$TEST_DIR"
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"prokop":{"running":1,"dns_configured":1},"sing_box":{"running":1}}},"guard":false,"package_pending":false,"events":[]}
JSON
ucode "$ROOT/prokop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const value = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(value.overall, 'ok');
assert.equal(value.dns.status, 'unknown');
assert.equal(value.dns.configured, true);
assert.equal(value.recovery.pending, false);
assert.equal(JSON.stringify(value).includes('secret'), false);
JS
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"prokop":{"running":1,"dns_configured":1},"sing_box":{"running":1}}},"guard":true,"package_pending":false,"events":[{"kind":"recovery","status":"recovered","timestamp":42}]}
JSON
ucode "$ROOT/prokop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const value = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(value.overall, 'error');
assert.equal(value.guard.active, true);
assert.equal(value.recovery.last_event.status, 'recovered');
JS
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"prokop":{"running":1,"dns_configured":1},"sing_box":{"running":1}}},"guard":false,"package_pending":false,"events":[{"kind":"recovery","status":"recovered","timestamp":42}]}
JSON
ucode "$ROOT/prokop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).overall, 'recovered');
JS
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"prokop":{"running":1,"dns_configured":1},"sing_box":{"running":1}}},"guard":false,"package_pending":true,"events":[]}
JSON
ucode "$ROOT/prokop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const result = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(result.overall, 'error');
assert.equal(result.package_recovery.pending, true);
JS
cat > "$TEST_DIR/fixture.json" <<'JSON'
{"ui":{"service":{"prokop":{"running":1},"sing_box":{"running":1}}},"guard":false,"package_pending":false,"events":[{"kind":"restore","status":"failure","timestamp":42}]}
JSON
ucode "$ROOT/prokop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const result = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(result.overall, 'error');
assert.equal(result.recovery.pending, true);
JS
# The guard that is left names what ends it (UC-019, UC-066): a guard kept by
# a failed lifecycle transition needs a restart, the guard of an unfinished
# restore a restore of a snapshot, and a guard that a running service action
# or snapshot operation may still hold its end. A failed last event without
# a guard needs no action of its own.
recovery_case() { # recovery_case <fixture json> <expected action> <runtime> <restore>
  printf '%s\n' "$1" > "$TEST_DIR/fixture.json"
  ucode "$ROOT/prokop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
  node - "$TEST_DIR/output.json" "$2" "$3" "$4" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [file, action, runtime, restore] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file));
assert.equal(value.recovery.action, action === 'null' ? null : action, JSON.stringify(value));
assert.equal(value.guard.runtime, runtime === 'true', JSON.stringify(value));
assert.equal(value.guard.restore, restore === 'true', JSON.stringify(value));
assert.equal(value.guard.active, runtime === 'true' || restore === 'true', JSON.stringify(value));
if (value.guard.active) assert.equal(value.recovery.pending, true);
JS
}
RUNNING='"ui":{"service":{"prokop":{"running":1,"dns_configured":1},"sing_box":{"running":1}}}'
RELOADING='"ui":{"service":{"prokop":{"running":1,"status":"reloading"},"sing_box":{"running":1}}}'
recovery_case "{$RUNNING,\"runtime_guard\":true,\"events\":[]}" restart true false
recovery_case "{$RUNNING,\"runtime_guard\":true,\"restore_guard\":true,\"events\":[]}" restart true true
recovery_case "{$RUNNING,\"restore_guard\":true,\"events\":[]}" restore false true
recovery_case "{$RELOADING,\"restore_guard\":true,\"events\":[]}" wait false true
recovery_case "{$RUNNING,\"restore_guard\":true,\"transaction\":true,\"events\":[]}" wait false true
recovery_case "{$RUNNING,\"events\":[{\"kind\":\"reload\",\"status\":\"failure\",\"timestamp\":42}]}" null false false
recovery_case "{$RUNNING,\"events\":[]}" null false false
printf '{broken' > "$TEST_DIR/fixture.json"
ucode "$ROOT/prokop/files/usr/lib/diagnostics/health.uc" fixture "$TEST_DIR/fixture.json" > "$TEST_DIR/output.json"
node - "$TEST_DIR/output.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).overall, 'unknown');
JS
PROKOP_RUNTIME_STATE_DIR="$TEST_DIR" ucode "$ROOT/prokop/files/usr/lib/diagnostics/health.uc" record reload success
test "$(stat -c %a "$TEST_DIR/health-events.json")" = 600
for n in 1 2 3 4 5 6 7 8 9 10 11; do
  PROKOP_RUNTIME_STATE_DIR="$TEST_DIR" ucode "$ROOT/prokop/files/usr/lib/diagnostics/health.uc" record reload failure
done
node - "$TEST_DIR/health-events.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).events.length, 10);
JS
test "$(grep -c '"kind": *"reload"' "$PROKOP_HISTORY_FILE")" = 12
printf 'health_status: PASS\n'
