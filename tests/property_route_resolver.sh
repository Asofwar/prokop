#!/usr/bin/env bash
set -euo pipefail

# Seeded metamorphic properties of routing/resolve.uc (first match, rules the
# connection cannot take, undecidable matchers, domain matcher semantics).
# PROPERTY_SEED and PROPERTY_CASES override the fixed seed and case count; see
# tests/helpers/property/scaffold.js.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export PROPERTY_WORK="$WORK"

node "$ROOT_DIR/tests/helpers/property/route_resolver.js" \
  "$ROOT_DIR/prokop/files/usr/lib" "$ROOT_DIR/tests/helpers/route_owner/prokop.uci"
