#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/pages.yml"
PYTHON_BIN="${PYTHON_BIN:-python3}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require() {
  grep -Fxq -- "$1" "$WORKFLOW" || fail "pages.yml lacks: $1"
}

[[ -s "$WORKFLOW" ]] || fail "pages.yml is missing"

# Republished after every successful package build, or on demand.
require '  workflow_run:'
require '      - Build packages'
require '      - completed'
require '  workflow_dispatch:'
require "    if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'"
# Least privilege: only the deploy job may write Pages.
require 'permissions:'
require '  contents: read'
require '      pages: write'
require '      id-token: write'
require '  group: pages'
require '  cancel-in-progress: false'
# The site is rebuilt for the fork's address from this repository's releases.
require '          FORKOP_RELEASE_BASE_URL: https://asofwar.github.io/forkop'
require '          FORKOP_RELEASE_REPO: ${{ github.repository }}'
require '        run: python3 ops/pages/build-site.py --output "$RUNNER_TEMP/forkop-site"'
require '          path: ${{ runner.temp }}/forkop-site'
require '      name: github-pages'
grep -Eq '^      - uses: actions/checkout@v[0-9]+\.[0-9]+\.[0-9]+$' "$WORKFLOW" ||
  fail "checkout is not pinned to an exact version"
grep -Eq '^        uses: actions/upload-pages-artifact@v[0-9]+\.[0-9]+\.[0-9]+$' "$WORKFLOW" ||
  fail "upload-pages-artifact is not pinned to an exact version"
grep -Eq '^        uses: actions/deploy-pages@v[0-9]+\.[0-9]+\.[0-9]+$' "$WORKFLOW" ||
  fail "deploy-pages is not pinned to an exact version"

# The top-level permissions grant nothing beyond reading the repository.
top_permissions="$(awk '/^permissions:/ { take = 1; next } take && /^[^ ]/ { exit } take' "$WORKFLOW")"
[[ "$top_permissions" == '  contents: read' ]] ||
  fail "top-level permissions must be contents: read only, got: $top_permissions"

if "$PYTHON_BIN" -c 'import yaml' 2>/dev/null; then
  "$PYTHON_BIN" - "$WORKFLOW" "$ROOT_DIR/.github/workflows/build.yml" <<'PY' ||
import sys
import yaml

pages = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
yaml.safe_load(open(sys.argv[2], encoding="utf-8"))
# PyYAML reads the bare key "on" as the boolean True.
triggers = pages.get("on", pages.get(True))
assert triggers["workflow_run"]["workflows"] == ["Build packages"], triggers
assert triggers["workflow_run"]["types"] == ["completed"], triggers
assert "workflow_dispatch" in triggers, triggers
assert pages["permissions"] == {"contents": "read"}, pages["permissions"]
assert pages["concurrency"] == {"group": "pages", "cancel-in-progress": False}
build, deploy = pages["jobs"]["build"], pages["jobs"]["deploy"]
assert "permissions" not in build, build
assert deploy["needs"] == "build", deploy
assert deploy["permissions"] == {"pages": "write", "id-token": "write"}, deploy
assert deploy["environment"]["name"] == "github-pages", deploy
PY
    fail "pages.yml does not parse into the expected workflow"
else
  printf 'PyYAML is unavailable; structural YAML check skipped\n'
fi

printf 'fork pages workflow checks passed\n'
