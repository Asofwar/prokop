#!/usr/bin/env bash
set -euo pipefail

# Packet mark and NFQUEUE layout taken from the production modules: role marks
# and route mark ranges share no bit, the DPI transition guard drops exactly
# the provider route marks, autotune isolation refuses exactly the queues that
# overlap production. PROPERTY_SEED and PROPERTY_CASES override the fixed seed
# and case count; see tests/helpers/property/scaffold.js.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export PROPERTY_WORK="$WORK"

node "$ROOT_DIR/tests/helpers/property/marks.js" "$ROOT_DIR/prokop/files/usr/lib" "$WORK"
