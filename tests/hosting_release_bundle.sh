#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
VERSION="1.0.2"
BASE_URL="https://downloads.example/forkop"
FORK_BASE_URL="https://asofwar.github.io/forkop"
PYTHON_BIN="${PYTHON_BIN:-python3}"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The catalog builder lists only the release being built: no GitHub API call
# and no HEAD request, so the bundle does not depend on the network.
export FORKOP_RELEASE_CATALOG_OFFLINE=1

packages=(
  "forkop_${VERSION}.ipk"
  "luci-app-forkop_${VERSION}.ipk"
  "luci-i18n-forkop-ru_${VERSION}.ipk"
  "forkop_${VERSION}.apk"
  "luci-app-forkop_${VERSION}.apk"
  "luci-i18n-forkop-ru_${VERSION}.apk"
)

mkdir -p "$WORK_DIR/artifacts"
for package in "${packages[@]}"; do
  printf 'test package: %s\n' "$package" >"$WORK_DIR/artifacts/$package"
done

FORKOP_RELEASE_BASE_URL="$BASE_URL" \
  "$ROOT_DIR/ops/hosting/prepare-release.sh" \
  "$VERSION" "$WORK_DIR/artifacts" "$WORK_DIR/output"

[[ "$(cat "$WORK_DIR/output/forkop/LATEST")" == "$VERSION" ]] ||
  fail "LATEST does not contain the release version"
[[ -s "$WORK_DIR/output/forkop/install.sh" ]] || fail "install.sh was not included"
[[ -s "$WORK_DIR/output/forkop/releases/$VERSION/SHA256SUMS" ]] ||
  fail "SHA256SUMS was not generated"
[[ -s "$WORK_DIR/output/forkop-timeweb-$VERSION.tar.gz" ]] ||
  fail "Timeweb archive was not generated"

for package in "${packages[@]}"; do
  [[ -s "$WORK_DIR/output/forkop/releases/$VERSION/$package" ]] ||
    fail "$package was not copied"
done

check_metadata() {
  "$PYTHON_BIN" - "$1/forkop/updates" "$VERSION" "$2" <<'PY'
import json
import hashlib
import sys
from pathlib import Path

updates, version, base_url = sys.argv[1:]
updates = Path(updates)
with open(updates / "latest.json", encoding="utf-8") as source:
    document = json.load(source)
assert document["tag_name"] == version
assert document["draft"] is False
assert document["prerelease"] is False
assert len(document["assets"]) == 6
digests = {}
for asset in document["assets"]:
    package_path = updates.parent / "releases" / version / asset["name"]
    digest = hashlib.sha256(package_path.read_bytes()).hexdigest()
    digests[asset["name"]] = digest
    assert asset["browser_download_url"] == (
        f"{base_url}/releases/{version}/{asset['name']}"
    )
    assert asset["sha256"] == digest
    assert asset["digest"] == f"sha256:{digest}"

with open(updates / "releases.json", encoding="utf-8") as source:
    catalog = json.load(source)
assert catalog["format"] == 1, catalog
assert [entry["tag_name"] for entry in catalog["releases"]] == [version], catalog
entry = catalog["releases"][0]
assert entry["channel"] == "stable"
assert entry["html_url"] == f"{base_url}/releases/{version}/"
assert {asset["name"]: asset["sha256"] for asset in entry["assets"]} == digests
for asset in entry["assets"]:
    assert asset["browser_download_url"] == f"{base_url}/releases/{version}/{asset['name']}"
PY
}

check_metadata "$WORK_DIR/output" "$BASE_URL" ||
  fail "release metadata does not describe the bundled packages"

tar -tzf "$WORK_DIR/output/forkop-timeweb-$VERSION.tar.gz" |
  grep -Fxq 'forkop/updates/latest.json' || fail "archive does not contain latest.json"
tar -tzf "$WORK_DIR/output/forkop-timeweb-$VERSION.tar.gz" |
  grep -Fxq 'forkop/updates/releases.json' || fail "archive does not contain releases.json"

# Without an explicit address the bundle describes the fork's Pages channel.
env -u FORKOP_RELEASE_BASE_URL -u FORKOP_RELEASE_REPO \
  "$ROOT_DIR/ops/hosting/prepare-release.sh" \
  "$VERSION" "$WORK_DIR/artifacts" "$WORK_DIR/default" >/dev/null
check_metadata "$WORK_DIR/default" "$FORK_BASE_URL" ||
  fail "the default release channel is not $FORK_BASE_URL"
if grep -RFq -e 'fold8.ru' -e 'slayer326' "$WORK_DIR/default/forkop/updates"; then
  fail "release metadata still points at the upstream channel"
fi

printf 'hosting release bundle checks passed\n'
