#!/usr/bin/env bash
set -euo pipefail

# routing/resolve.uc against a seeded first-match model of sing-box and of
# nft's capture of real addresses (UC-096, UC-100, UC-103): every decided
# answer is the model's, and what the model cannot know (IPv6, DNS hijack, a
# FakeIP without its domain, an address replaced by a foreign resolve rule)
# is never decided. PROPERTY_SEED and PROPERTY_CASES override the fixed seed
# and case count; see tests/helpers/property/scaffold.js.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM
export PROPERTY_WORK="$WORK"

node "$ROOT_DIR/tests/helpers/property/route_resolver_model.js" \
  "$ROOT_DIR/forkop/files/usr/lib" "$ROOT_DIR/tests/helpers/route_owner/forkop.uci"
