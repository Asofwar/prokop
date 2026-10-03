#!/usr/bin/env bash
set -euo pipefail

# Seeded properties of autotune hysteresis, autonomous-apply gating and
# candidate selection. PROPERTY_SEED and PROPERTY_CASES override the fixed
# seed and case count; see tests/helpers/property/scaffold.js.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export PROPERTY_WORK="$WORK"

node "$ROOT_DIR/tests/helpers/property/autotune.js" "$ROOT_DIR/prokop/files/usr/lib"
