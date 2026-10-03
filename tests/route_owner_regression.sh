#!/usr/bin/env bash
set -euo pipefail

# Route ownership as autotune apply (Stage 5) decides it: the first sing-box
# route rule a TCP/443 connection to the target takes, FakeIP versus real
# address, undecidable matchers and the zapret rule identity (index, route
# mark, queue). The expected owners were recorded from autotune/apply.uc
# before the resolver moved into a shared module; any change here changes
# Stage 5 semantics.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS="$ROOT_DIR/tests/helpers/route_owner"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

node "$HELPERS/run_apply.js" "$ROOT_DIR/prokop/files/usr/lib" "$WORK" "$HELPERS/cases.js" > "$WORK/owners.json"
node - "$WORK/owners.json" "$HELPERS/apply_owner.golden.json" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const actual = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const expected = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
assert.deepEqual(Object.keys(actual), Object.keys(expected), 'every recorded case ran');
// The golden file holds the answers of the shared resolver, which never guesses
// a source. Autotune apply asks for the devices of a rule limited to devices:
// the owner is decided for them and carries source_scoped.
expected.source_scoped = { decided: true, kind: 'outbound', rule: 0, outbound: 'main-out', source_scoped: true };
for (const name of Object.keys(expected)) assert.deepEqual(actual[name], expected[name], `owner changed: ${name}`);
console.log(`route_owner_regression: PASS (${Object.keys(expected).length} cases)`);
NODE
