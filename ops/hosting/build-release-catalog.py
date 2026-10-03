#!/usr/bin/env python3
"""Build the release catalog the LuCI version picker reads.

A plain static host is updated by extracting one bundle per release, so
earlier versions stay on the host and can be reinstalled. Nothing on such a
host can generate an index, and its directory listing may be closed, so the
catalog is written here, at build time, and shipped inside the bundle. The
GitHub Pages channel (ops/pages/build-site.py) imports these functions and
writes the same catalog for the whole site.

The release being built is always listed: its packages travel in the same
bundle. Earlier releases come from the GitHub releases of this repository and
are listed only once every package has been confirmed present on the host --
a version whose bundle was never uploaded must not be offered for rollback.
With --offline (or PROKOP_RELEASE_CATALOG_OFFLINE=1) only the release being
built is listed and nothing is fetched.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

FORK_REPO = "Asofwar/prokop"
VERSION = re.compile(r"^\d+\.\d+\.\d+$")
PACKAGES = ("prokop", "luci-app-prokop", "luci-i18n-prokop-ru")
EXTENSIONS = ("ipk", "apk")
TIMEOUT = 20


def package_names(version):
    return [f"{package}_{version}.{extension}"
            for extension in EXTENSIONS for package in PACKAGES]


def release_entry(version, base_url, digests):
    assets = []
    for name in package_names(version):
        digest = digests.get(name, "")
        if not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise ValueError(f"missing or malformed sha256 for {name}")
        assets.append({
            "name": name,
            "sha256": digest,
            "browser_download_url": f"{base_url}/releases/{version}/{name}",
        })
    return {
        "tag_name": version,
        "channel": "stable",
        "html_url": f"{base_url}/releases/{version}/",
        "assets": assets,
    }


def current_digests(release_dir, version):
    return {name: hashlib.sha256((release_dir / name).read_bytes()).hexdigest()
            for name in package_names(version)}


def github_releases(repository, limit):
    url = f"https://api.github.com/repos/{repository}/releases?per_page={limit}"
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "prokop-release-catalog",
    })
    token = os.environ.get("GITHUB_TOKEN", "")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.load(response)


def published_digests(release):
    """Read each package checksum from the GitHub asset digests, no download."""
    digests = {}
    for asset in release.get("assets", []):
        digest = str(asset.get("digest", ""))
        if digest.startswith("sha256:"):
            digests[str(asset.get("name", ""))] = digest[len("sha256:"):]
    return digests


def mirror_has_every_package(base_url, version):
    for name in package_names(version):
        request = urllib.request.Request(
            f"{base_url}/releases/{version}/{name}", method="HEAD",
            headers={"User-Agent": "prokop-release-catalog"})
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                if response.status != 200:
                    return False
        except (urllib.error.URLError, OSError):
            return False
    return True


def previous_releases(repository, base_url, current, limit):
    try:
        published = github_releases(repository, limit)
    except (urllib.error.URLError, OSError, ValueError) as error:
        print(f"Listing previous releases failed, shipping only {current}: {error}",
              file=sys.stderr)
        return []

    entries = []
    for release in published:
        version = str(release.get("tag_name", ""))
        if version == current or not VERSION.fullmatch(version):
            continue
        if release.get("draft") or release.get("prerelease"):
            continue
        try:
            entry = release_entry(version, base_url, published_digests(release))
        except ValueError as error:
            print(f"Skipping {version}: {error}", file=sys.stderr)
            continue
        if not mirror_has_every_package(base_url, version):
            print(f"Skipping {version}: not published on the host yet", file=sys.stderr)
            continue
        entries.append(entry)
    return entries


def version_key(entry):
    return tuple(int(part) for part in entry["tag_name"].split("."))


def write_catalog(output, releases):
    """Write the format-1 catalog atomically, newest release first."""
    releases = sorted(releases, key=version_key, reverse=True)
    catalog = {"format": 1, "releases": releases}
    handle, temporary = tempfile.mkstemp(prefix=".releases-", suffix=".json",
                                         dir=output.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(catalog, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return len(releases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("release_dir", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--repository", default=os.environ.get(
        "PROKOP_RELEASE_REPO", FORK_REPO))
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--offline", action="store_true",
                        default=os.environ.get("PROKOP_RELEASE_CATALOG_OFFLINE") == "1",
                        help="list only the release being built; fetch nothing")
    arguments = parser.parse_args()

    if not VERSION.fullmatch(arguments.version):
        parser.error("release version must use x.y.z format")
    base_url = arguments.base_url.rstrip("/")

    releases = [release_entry(arguments.version, base_url,
                              current_digests(arguments.release_dir, arguments.version))]
    if not arguments.offline:
        releases.extend(previous_releases(arguments.repository, base_url,
                                          arguments.version, arguments.limit))

    count = write_catalog(arguments.output, releases)
    print(f"Release catalog: {count} version(s)")


if __name__ == "__main__":
    main()
