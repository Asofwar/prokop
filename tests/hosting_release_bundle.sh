#!/usr/bin/env bash
# ops/hosting/prepare-release.sh builds the hosting bundle of a release: the
# packages, their checksums, latest.json and the release catalog of the
# version picker (ops/hosting/build-release-catalog.py), which lists the
# earlier GitHub releases that the mirror serves.
#
# The test has no network: the catalog builder's GitHub API and mirror are
# test doubles (tests/helpers/hosting_network/sitecustomize.py, a copy in the
# test's directory on PYTHONPATH, so that Python's bytecode cache stays
# there too) that answer from the test's fixtures, log every request and
# refuse every socket.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
VERSION="1.0.2"
BASE_URL="https://downloads.example/prokop"
REPOSITORY="example/prokop"
GITHUB_URL="https://api.github.com/repos/$REPOSITORY/releases?per_page=10"
FORK_BASE_URL="https://asofwar.github.io/prokop"
PYTHON_BIN="${PYTHON_BIN:-python3}"
NETWORK="$WORK_DIR/network"

cleanup() {
  rm -rf "${WORK_DIR:?}"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

packages=(
  "prokop_${VERSION}.ipk"
  "luci-app-prokop_${VERSION}.ipk"
  "luci-i18n-prokop-ru_${VERSION}.ipk"
  "prokop_${VERSION}.apk"
  "luci-app-prokop_${VERSION}.apk"
  "luci-i18n-prokop-ru_${VERSION}.apk"
)

mkdir -p "$WORK_DIR/artifacts"
for package in "${packages[@]}"; do
  printf 'test package: %s\n' "$package" >"$WORK_DIR/artifacts/$package"
done

# The GitHub releases of the repository and the packages on the mirror:
# 1.0.1 is published and on the mirror; 1.0.0 lacks a package on the
# mirror, 0.9.1 is a prerelease, 0.9.0 a draft and 0.8.0 lacks a checksum.
# The release being built comes from its own packages.
mkdir -p "$NETWORK"
"$PYTHON_BIN" - "$NETWORK" "$VERSION" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

network, current = Path(sys.argv[1]), sys.argv[2]


def names(version):
    return [f"{package}_{version}.{extension}" for extension in ("ipk", "apk")
            for package in ("prokop", "luci-app-prokop", "luci-i18n-prokop-ru")]


def release(version, draft=False, prerelease=False, mirrored=None, digested=None):
    for name in names(version) if mirrored is None else mirrored:
        path = network / "mirror" / "releases" / version / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"published package: {name}\n")
    assets = []
    for name in names(version) if digested is None else digested:
        digest = hashlib.sha256(f"published package: {name}\n".encode()).hexdigest()
        assets.append({"name": name, "digest": f"sha256:{digest}"})
    return {"tag_name": version, "draft": draft, "prerelease": prerelease,
            "assets": assets}


releases = [
    release(current, mirrored=[]),
    release("1.0.1"),
    release("1.0.0", mirrored=names("1.0.0")[1:]),
    release("0.9.1", prerelease=True),
    release("0.9.0", draft=True),
    release("0.8.0", digested=names("0.8.0")[1:]),
]
(network / "github-releases.json").write_text(json.dumps(releases))
PY

mkdir -p "$WORK_DIR/pythonpath"
cp "$ROOT_DIR/tests/helpers/hosting_network/sitecustomize.py" "$WORK_DIR/pythonpath/"
: >"$WORK_DIR/started"
HOSTING_TEST_NETWORK="$NETWORK" \
  HOSTING_TEST_GITHUB_URL="$GITHUB_URL" \
  HOSTING_TEST_BASE_URL="$BASE_URL" \
  PYTHONPATH="$WORK_DIR/pythonpath" \
  PROKOP_RELEASE_REPO="$REPOSITORY" \
  PROKOP_RELEASE_BASE_URL="$BASE_URL" \
  "$ROOT_DIR/ops/hosting/prepare-release.sh" \
  "$VERSION" "$WORK_DIR/artifacts" "$WORK_DIR/output"

# The test writes only into its own directory, also no bytecode cache next
# to the test doubles in the checkout.
written="$(find "$ROOT_DIR/tests/helpers/hosting_network" -newer "$WORK_DIR/started" -print)"
[[ -z "$written" ]] || fail "the test wrote into the checkout: $written"

grep -Fxq "GET $GITHUB_URL" "$NETWORK/requests" ||
  fail "the catalog builder did not list the releases through the test's GitHub API"
if grep -E '^socket$|^unexpected ' "$NETWORK/requests" >&2; then
  fail "the catalog builder reached for the network"
fi

[[ "$(cat "$WORK_DIR/output/prokop/LATEST")" == "$VERSION" ]] ||
  fail "LATEST does not contain the release version"
[[ -s "$WORK_DIR/output/prokop/install.sh" ]] || fail "install.sh was not included"
[[ -s "$WORK_DIR/output/prokop/releases/$VERSION/SHA256SUMS" ]] ||
  fail "SHA256SUMS was not generated"
[[ -s "$WORK_DIR/output/prokop-timeweb-$VERSION.tar.gz" ]] ||
  fail "Timeweb archive was not generated"

for package in "${packages[@]}"; do
  [[ -s "$WORK_DIR/output/prokop/releases/$VERSION/$package" ]] ||
    fail "$package was not copied"
done

check_metadata() {
  "$PYTHON_BIN" - "$1/prokop/updates" "$VERSION" "$2" <<'PY'
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
# Newest first: the release being built (earlier ones are checked below).
assert catalog["releases"][0]["tag_name"] == version, catalog
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

# The catalog: the release being built and the earlier one the mirror
# serves, with the checksums of their packages.
"$PYTHON_BIN" - "$WORK_DIR/output/prokop/updates/releases.json" \
  "$NETWORK/github-releases.json" "$VERSION" "$BASE_URL" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

path, published_path, version, base_url = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    catalog = json.load(source)
with open(published_path, encoding="utf-8") as source:
    published = {release["tag_name"]: release for release in json.load(source)}
assert catalog["format"] == 1
listed = [release["tag_name"] for release in catalog["releases"]]
assert listed == [version, "1.0.1"], listed
for release in catalog["releases"]:
    tag = release["tag_name"]
    assert release["html_url"] == f"{base_url}/releases/{tag}/"
    assert len(release["assets"]) == 6
    digests = {asset["name"]: asset["digest"][len("sha256:"):]
               for asset in published[tag]["assets"]}
    for asset in release["assets"]:
        if tag == version:
            package = Path(path).parent.parent / "releases" / version / asset["name"]
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
        else:
            digest = digests[asset["name"]]
        assert asset["sha256"] == digest, asset
        assert asset["browser_download_url"] == f"{base_url}/releases/{tag}/{asset['name']}"
PY

# The listing goes to a file first: grep -q stops reading at its match, and
# a tar still listing would die of SIGPIPE, which pipefail reports.
tar -tzf "$WORK_DIR/output/prokop-timeweb-$VERSION.tar.gz" >"$WORK_DIR/archive.list" ||
  fail "the archive cannot be listed"
for published in prokop/updates/latest.json prokop/updates/releases.json; do
  grep -Fxq "$published" "$WORK_DIR/archive.list" || fail "archive does not contain $published"
done

# Without an explicit address the bundle describes the fork's Pages channel.
# The catalog builder lists only the release being built here (offline): no
# GitHub API call and no HEAD request.
env -u PROKOP_RELEASE_BASE_URL -u PROKOP_RELEASE_REPO PROKOP_RELEASE_CATALOG_OFFLINE=1 \
  "$ROOT_DIR/ops/hosting/prepare-release.sh" \
  "$VERSION" "$WORK_DIR/artifacts" "$WORK_DIR/default" >/dev/null
check_metadata "$WORK_DIR/default" "$FORK_BASE_URL" ||
  fail "the default release channel is not $FORK_BASE_URL"
if grep -RFq -e 'fold8.ru' -e 'slayer326' "$WORK_DIR/default/prokop/updates"; then
  fail "release metadata still points at the upstream channel"
fi

printf 'hosting release bundle checks passed\n'
