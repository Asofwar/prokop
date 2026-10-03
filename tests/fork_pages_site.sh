#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SITE="$ROOT_DIR/ops/pages/build-site.py"
PREPARE="$ROOT_DIR/ops/hosting/prepare-release.sh"
BASE_URL="https://asofwar.github.io/prokop"
REPOSITORY="Asofwar/prokop"
PYTHON_BIN="${PYTHON_BIN:-python3}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# Nothing here may reach the network or leave byte code in the checkout.
export PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX="$WORK_DIR/pycache"
export PROKOP_RELEASE_CATALOG_OFFLINE=1
unset GITHUB_TOKEN PROKOP_RELEASE_BASE_URL PROKOP_RELEASE_REPO

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

"$PYTHON_BIN" -m py_compile "$BUILD_SITE" "$ROOT_DIR/ops/hosting/build-release-catalog.py"

# Fixture: GitHub's release list plus the asset files, laid out as
# assets/<tag>/<name>. Only 1.10.0 and 1.2.1 must be published with --limit 2:
# 1.10.0 sorts above 1.2.x numerically, and the draft, the prerelease and the
# tags that are not strict X.Y.Z are never published, however new they are.
"$PYTHON_BIN" - "$WORK_DIR" "$REPOSITORY" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

work, repository = Path(sys.argv[1]), sys.argv[2]
packages = ("prokop", "luci-app-prokop", "luci-i18n-prokop-ru")


def release(tag, draft=False, prerelease=False, installer=True, digests=True):
    folder = work / "assets" / tag
    folder.mkdir(parents=True)
    names = [f"{package}_{tag}.{extension}"
             for extension in ("ipk", "apk") for package in packages]
    if installer:
        names.append("install.sh")
    assets = []
    for name in names:
        data = (f"#!/bin/sh\necho installer {tag}\n" if name == "install.sh"
                else f"package {name}\n").encode()
        (folder / name).write_bytes(data)
        assets.append({
            "name": name,
            "size": len(data),
            "digest": f"sha256:{hashlib.sha256(data).hexdigest()}" if digests else None,
            "browser_download_url":
                f"https://github.com/{repository}/releases/download/{tag}/{name}",
        })
    return {"tag_name": tag, "name": tag, "draft": draft,
            "prerelease": prerelease, "assets": assets}


releases = [
    release("1.2.0"),
    release("1.2.1", installer=False, digests=False),
    release("1.10.0"),
    release("2.0.0", prerelease=True),
    release("2.1.0", draft=True),
    release("v3.0.0"),
    release("3.0.0-rc1"),
]
(work / "releases.json").write_text(json.dumps(releases), encoding="utf-8")
PY

build() {
  local output="$1"
  shift
  "$PYTHON_BIN" "$BUILD_SITE" --output "$output" \
    --releases-json "$WORK_DIR/releases.json" --assets-dir "$WORK_DIR/assets" \
    --raw-url "file://$WORK_DIR/raw" --limit 2 "$@"
}

build "$WORK_DIR/site" >"$WORK_DIR/build.log" 2>&1 || {
  cat "$WORK_DIR/build.log" >&2
  fail "the site was not built from complete releases"
}
SITE="$WORK_DIR/site"

# Exactly the channel layout, nothing else.
expected_files="$(printf '%s\n' \
  LATEST index.html install.sh updates/latest.json updates/releases.json \
  releases/1.10.0/SHA256SUMS releases/1.2.1/SHA256SUMS \
  releases/{1.10.0,1.2.1}/{prokop,luci-app-prokop,luci-i18n-prokop-ru}_VERSION.{ipk,apk} |
  sed -E 's#^releases/([^/]+)/(.*)_VERSION#releases/\1/\2_\1#' | sort)"
actual_files="$(cd "$SITE" && find . -type f | sed 's#^\./##' | sort)"
[[ "$actual_files" == "$expected_files" ]] || {
  diff <(printf '%s\n' "$expected_files") <(printf '%s\n' "$actual_files") >&2 || true
  fail "the site layout differs from the release channel layout"
}

[[ "$(cat "$SITE/LATEST")" == "1.10.0" ]] || fail "LATEST is not the newest X.Y.Z release"
cmp -s "$SITE/install.sh" "$WORK_DIR/assets/1.10.0/install.sh" ||
  fail "install.sh is not the newest release's install.sh asset"
for version in 1.10.0 1.2.1; do
  (cd "$SITE/releases/$version" && sha256sum --quiet -c SHA256SUMS) ||
    fail "SHA256SUMS of $version does not match its packages"
  for file in "$SITE/releases/$version"/*_"$version".*; do
    cmp -s "$file" "$WORK_DIR/assets/$version/${file##*/}" ||
      fail "${file##*/} differs from its release asset"
  done
done

grep -Fq '<meta charset="utf-8">' "$SITE/index.html" || fail "index.html does not declare UTF-8"
grep -Fq "wget -qO- $BASE_URL/install.sh | sh" "$SITE/index.html" ||
  fail "index.html lacks the one-line install command"
grep -Fq "wget -qO- https://github.com/$REPOSITORY/releases/latest/download/install.sh | sh" \
  "$SITE/index.html" || fail "index.html lacks the GitHub Releases alternative"
grep -Fq 'Установка' "$SITE/index.html" || fail "index.html is not the Russian page"

# The metadata is exactly what the static hosting bundle writes for the same
# packages: compare with prepare-release.sh, file for file.
for version in 1.10.0 1.2.1; do
  PROKOP_RELEASE_BASE_URL="$BASE_URL" PROKOP_RELEASE_REPO="$REPOSITORY" \
    "$PREPARE" "$version" "$WORK_DIR/assets/$version" "$WORK_DIR/bundle-$version" >/dev/null
done
cmp -s "$SITE/updates/latest.json" "$WORK_DIR/bundle-1.10.0/forkop/updates/latest.json" ||
  fail "latest.json differs from the one prepare-release.sh writes"
"$PYTHON_BIN" - "$SITE/updates/releases.json" \
  "$WORK_DIR/bundle-1.10.0/forkop/updates/releases.json" \
  "$WORK_DIR/bundle-1.2.1/forkop/updates/releases.json" <<'PY' ||
import json
import sys

site, *bundles = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:])
assert site["format"] == 1 and list(site) == ["format", "releases"], site
assert [entry["tag_name"] for entry in site["releases"]] == ["1.10.0", "1.2.1"], site
for bundle in bundles:
    (entry,) = bundle["releases"]
    assert entry in site["releases"], entry["tag_name"]
PY
  fail "releases.json differs from the catalog build-release-catalog.py writes"

# install.sh falls back to the tagged repository file when the newest release
# has no install.sh asset.
mkdir -p "$WORK_DIR/raw/$REPOSITORY/1.2.1"
printf '#!/bin/sh\necho tagged installer\n' >"$WORK_DIR/raw/$REPOSITORY/1.2.1/install.sh"
"$PYTHON_BIN" - "$WORK_DIR/releases.json" "$WORK_DIR/older.json" <<'PY'
import json
import sys

releases = json.load(open(sys.argv[1], encoding="utf-8"))
json.dump([r for r in releases if r["tag_name"] != "1.10.0"], open(sys.argv[2], "w"))
PY
"$PYTHON_BIN" "$BUILD_SITE" --output "$WORK_DIR/fallback" \
  --releases-json "$WORK_DIR/older.json" --assets-dir "$WORK_DIR/assets" \
  --raw-url "file://$WORK_DIR/raw" >/dev/null 2>&1 ||
  fail "a release without an install.sh asset was not published"
cmp -s "$WORK_DIR/fallback/install.sh" "$WORK_DIR/raw/$REPOSITORY/1.2.1/install.sh" ||
  fail "install.sh did not fall back to the file at the release tag"
[[ "$(cat "$WORK_DIR/fallback/LATEST")" == "1.2.1" ]] || fail "fallback LATEST is wrong"
[[ -d "$WORK_DIR/fallback/releases/1.2.0" ]] || fail "the default limit dropped 1.2.0"

# Failures leave no site at all, never a partial one.
must_fail() {
  local label="$1" releases="$2" output="$WORK_DIR/failed-$1"
  shift 2
  if "$PYTHON_BIN" "$BUILD_SITE" --output "$output" --releases-json "$releases" \
      --assets-dir "$WORK_DIR/assets" --raw-url "file://$WORK_DIR/raw" "$@" \
      >"$WORK_DIR/$label.log" 2>&1; then
    fail "$label: the site was built"
  fi
  grep -Fq 'FAIL:' "$WORK_DIR/$label.log" || fail "$label: no failure reason was printed"
  [[ ! -e "$output" ]] || fail "$label: a partial site was left behind"
  if find "$WORK_DIR" -maxdepth 1 -name '.site-*' | grep -q .; then
    fail "$label: a temporary site directory was left behind"
  fi
}

edit_releases() {
  "$PYTHON_BIN" - "$WORK_DIR/releases.json" "$WORK_DIR/$1.json" "$2" <<'PY'
import json
import sys

releases = json.load(open(sys.argv[1], encoding="utf-8"))
exec(sys.argv[3])
json.dump(releases, open(sys.argv[2], "w"))
PY
}

# The newest release (1.10.0) must be complete and valid: it is latest.json.
edit_releases missing 'releases[2]["assets"] = [a for a in releases[2]["assets"] if not a["name"].endswith(".apk") or "i18n" not in a["name"]]'
must_fail missing "$WORK_DIR/missing.json" --limit 2

edit_releases digest 'releases[2]["assets"][0]["digest"] = "sha256:" + "0" * 64'
must_fail digest "$WORK_DIR/digest.json"

edit_releases size 'releases[2]["assets"][1]["size"] += 1'
must_fail size "$WORK_DIR/size.json"

# An older release that is incomplete or fails verification must not block
# every later deploy: it is left out with a warning on stderr, never published,
# and the next older complete release takes its place within --limit.
must_skip() {
  local label="$1" releases="$2" skipped="$3" expected="$4" output="$WORK_DIR/skipped-$1"
  shift 4
  "$PYTHON_BIN" "$BUILD_SITE" --output "$output" --releases-json "$releases" \
      --assets-dir "$WORK_DIR/assets" --raw-url "file://$WORK_DIR/raw" "$@" \
      >"$WORK_DIR/$label.out" 2>"$WORK_DIR/$label.err" || {
    cat "$WORK_DIR/$label.out" "$WORK_DIR/$label.err" >&2
    fail "$label: a broken older release failed the whole site"
  }
  grep -Eq "^WARNING: skipping $skipped: " "$WORK_DIR/$label.err" ||
    fail "$label: no warning about skipping $skipped on stderr"
  [[ ! -e "$output/releases/$skipped" ]] || fail "$label: $skipped was published"
  [[ "$(cat "$output/LATEST")" == "1.10.0" ]] || fail "$label: LATEST is not 1.10.0"
  [[ "$(find "$output/releases" -mindepth 1 -maxdepth 1 -printf '%f\n' |
        sort -V -r | paste -sd, -)" == "$expected" ]] ||
    fail "$label: releases/ is not $expected"
  local version
  for version in ${expected//,/ }; do
    (cd "$output/releases/$version" && sha256sum --quiet -c SHA256SUMS) ||
      fail "$label: SHA256SUMS of $version does not match its packages"
  done
  "$PYTHON_BIN" - "$output/updates/releases.json" "$expected" <<'PY' ||
import json
import sys

site = json.load(open(sys.argv[1], encoding="utf-8"))
assert [entry["tag_name"] for entry in site["releases"]] == sys.argv[2].split(","), site
PY
    fail "$label: releases.json does not list exactly $expected"
}

edit_releases older-missing 'releases[1]["assets"] = [a for a in releases[1]["assets"] if not a["name"].endswith(".apk") or "i18n" not in a["name"]]'
must_skip older-missing "$WORK_DIR/older-missing.json" 1.2.1 1.10.0,1.2.0 --limit 2

# The mismatch is on the last package fetched, so the others were already
# copied into releases/1.2.0 and must be removed again.
edit_releases older-digest '[a for a in releases[0]["assets"] if a["name"] == "luci-i18n-prokop-ru_1.2.0.apk"][0]["digest"] = "sha256:" + "0" * 64'
must_skip older-digest "$WORK_DIR/older-digest.json" 1.2.0 1.10.0,1.2.1

edit_releases older-size '[a for a in releases[1]["assets"] if a["name"] == "prokop_1.2.1.apk"][0]["size"] += 1'
must_skip older-size "$WORK_DIR/older-size.json" 1.2.1 1.10.0,1.2.0 --limit 3

edit_releases none 'releases = [r for r in releases if r["draft"] or r["prerelease"] or r["tag_name"] in ("v3.0.0", "3.0.0-rc1")]'
must_fail none "$WORK_DIR/none.json"

edit_releases noinstaller 'releases = [r for r in releases if r["tag_name"] != "1.10.0"]'
rm -rf "$WORK_DIR/raw"
must_fail noinstaller "$WORK_DIR/noinstaller.json"

# A missing asset file is a failure too, not a skipped release.
mv "$WORK_DIR/assets/1.2.0/prokop_1.2.0.ipk" "$WORK_DIR/prokop_1.2.0.ipk"
must_fail absent "$WORK_DIR/releases.json" --limit 3
mv "$WORK_DIR/prokop_1.2.0.ipk" "$WORK_DIR/assets/1.2.0/prokop_1.2.0.ipk"

# An existing site is never overwritten or removed.
mkdir -p "$WORK_DIR/occupied"
printf 'keep\n' >"$WORK_DIR/occupied/file"
if build "$WORK_DIR/occupied" >/dev/null 2>&1; then
  fail "a non-empty output directory was overwritten"
fi
[[ "$(cat "$WORK_DIR/occupied/file")" == "keep" ]] || fail "the existing output was modified"

printf 'fork pages site checks passed\n'
