#!/usr/bin/env python3
"""Rebuild the whole static Prokop release channel from GitHub releases.

GitHub Pages replaces the published site on every deployment, so the channel
is never patched in place: each run lays out the newest stable releases of the
repository from scratch, in the layout ops/hosting/prepare-release.sh bundles
for a plain static host:

    install.sh  LATEST  index.html
    updates/latest.json  updates/releases.json
    releases/<X.Y.Z>/{prokop,luci-app-prokop,luci-i18n-prokop-ru}_<X.Y.Z>.{ipk,apk}
    releases/<X.Y.Z>/SHA256SUMS

Every package is downloaded, checked against the digest GitHub declares for
the asset when there is one, and hashed again here; the hashes written into
latest.json and releases.json are always the ones computed here. The newest
release must be complete and valid: a missing package or a size or digest
mismatch there, a failed download of any release, or no qualifying release
fails the run before the output directory appears, so a partial site is never
published.
An older release that is incomplete or fails verification is skipped with a
warning and never published, so it cannot block every later deploy; the next
older complete release takes its place within --limit.

--releases-json and --assets-dir replace the GitHub API and the downloads with
local files, so the builder can be tested without network access.
"""
import argparse
import hashlib
import html
import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

FORK_REPO = "Asofwar/prokop"
FORK_RELEASE_BASE = "https://asofwar.github.io/prokop"
API_URL = "https://api.github.com"
RAW_URL = "https://raw.githubusercontent.com"
DEFAULT_LIMIT = 8
TIMEOUT = 60
MAX_ASSET_SIZE = 64 * 1024 * 1024
MAX_RELEASE_PAGES = 10
INSTALLER = "install.sh"
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SHA256 = re.compile(r"^[a-f0-9]{64}$")
USER_AGENT = "prokop-pages"

# The catalog module is imported from its file; it must not leave byte code
# next to it in the checkout.
sys.dont_write_bytecode = True


def load_catalog_module():
    path = Path(__file__).resolve().parents[1] / "hosting" / "build-release-catalog.py"
    spec = importlib.util.spec_from_file_location("build_release_catalog", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


catalog = load_catalog_module()


class SiteError(Exception):
    pass


class ReleaseRejected(SiteError):
    """The release itself is incomplete or fails verification."""


def open_url(url, accept=None, token=""):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    if accept:
        request.add_header("Accept", accept)
    if token:
        # Never forwarded on a redirect to another host.
        request.add_unredirected_header("Authorization", f"Bearer {token}")
    return urllib.request.urlopen(request, timeout=TIMEOUT)


def list_releases(api_url, repository, token):
    releases = []
    for page in range(1, MAX_RELEASE_PAGES + 1):
        url = f"{api_url}/repos/{repository}/releases?per_page=100&page={page}"
        with open_url(url, "application/vnd.github+json", token) as response:
            batch = json.load(response)
        if not isinstance(batch, list):
            raise SiteError(f"unexpected response from {url}")
        releases.extend(batch)
        if len(batch) < 100:
            break
    return releases


def read_releases_file(path):
    with open(path, encoding="utf-8") as source:
        releases = json.load(source)
    if not isinstance(releases, list):
        raise SiteError(f"{path} must hold a JSON array of releases")
    return releases


def stable_releases(releases):
    """Non-draft, non-prerelease X.Y.Z releases, newest version first."""
    selected = {}
    for release in releases:
        if not isinstance(release, dict):
            continue
        tag = str(release.get("tag_name", ""))
        if release.get("draft") or release.get("prerelease"):
            continue
        if not catalog.VERSION.fullmatch(tag) or tag in selected:
            continue
        selected[tag] = release
    return sorted(selected.values(), key=catalog.version_key, reverse=True)


def release_asset(release, name):
    for asset in release.get("assets") or []:
        if isinstance(asset, dict) and asset.get("name") == name:
            return asset
    return None


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, destination):
    if urllib.parse.urlsplit(url).scheme not in ("https", "file"):
        raise SiteError(f"refusing to download {url}")
    total = 0
    with open_url(url) as response, open(destination, "wb") as output:
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > MAX_ASSET_SIZE:
                raise SiteError(f"{url} is larger than {MAX_ASSET_SIZE} bytes")
            output.write(chunk)


def fetch_asset(release, asset, repository, assets_dir, destination):
    """Copy or download one release asset and return its verified sha256."""
    tag, name = release["tag_name"], asset["name"]
    if assets_dir is not None:
        source = assets_dir / tag / name
        if not source.is_file():
            raise SiteError(f"{tag}: {source} is missing")
        shutil.copyfile(source, destination)
    else:
        url = str(asset.get("browser_download_url", ""))
        expected = f"/{repository}/releases/download/{tag}/{name}"
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.path != expected:
            raise ReleaseRejected(f"{tag}: unexpected download URL for {name}: {url}")
        download(url, destination)

    digest = sha256_file(destination)
    size = asset.get("size")
    if isinstance(size, int) and size != destination.stat().st_size:
        raise ReleaseRejected(f"{tag}: {name} is {destination.stat().st_size} bytes, "
                              f"GitHub declares {size}")
    declared = asset.get("digest")
    if declared:
        declared = str(declared)
        if not declared.startswith("sha256:") or not SHA256.fullmatch(declared[7:]):
            raise ReleaseRejected(f"{tag}: unsupported digest for {name}: {declared}")
        if declared[7:] != digest:
            raise ReleaseRejected(f"{tag}: {name} does not match its GitHub digest")
    return digest


def fetch_release(release, repository, assets_dir, release_dir):
    tag = release["tag_name"]
    names = catalog.package_names(tag)
    missing = [name for name in names if release_asset(release, name) is None]
    if missing:
        raise ReleaseRejected(f"{tag}: release is missing {', '.join(missing)}")
    release_dir.mkdir(parents=True)
    digests = {}
    for name in names:
        print(f"{tag}: {name}", flush=True)
        digests[name] = fetch_asset(release, release_asset(release, name),
                                    repository, assets_dir, release_dir / name)
    with open(release_dir / "SHA256SUMS", "w", encoding="utf-8", newline="\n") as sums:
        for name in names:
            sums.write(f"{digests[name]}  {name}\n")
    return digests


def fetch_installer(release, repository, assets_dir, raw_url, destination):
    """install.sh of the newest release: its release asset, else the tagged file."""
    tag = release["tag_name"]
    asset = release_asset(release, INSTALLER)
    if asset is not None:
        fetch_asset(release, asset, repository, assets_dir, destination)
        source = "release asset"
    else:
        url = f"{raw_url}/{repository}/{tag}/{INSTALLER}"
        print(f"{tag}: no {INSTALLER} release asset, using {url}", file=sys.stderr)
        download(url, destination)
        source = url
    data = destination.read_bytes()
    if not data.startswith(b"#!") or b"\0" in data:
        raise SiteError(f"{tag}: {INSTALLER} from {source} is not a shell script")


def latest_document(version, base_url, digests):
    """updates/latest.json, in the shape ops/hosting/prepare-release.sh writes."""
    def asset(name):
        return {
            "name": name,
            "browser_download_url": f"{base_url}/releases/{version}/{name}",
            "sha256": digests[name],
            "digest": f"sha256:{digests[name]}",
        }

    return {
        "tag_name": version,
        "name": version,
        "html_url": f"{base_url}/releases/{version}/",
        "draft": False,
        "prerelease": False,
        "assets": [asset(name) for name in catalog.package_names(version)],
    }


def index_page(version, base_url, repository):
    page = f"https://github.com/{repository}"
    fallback = f"{page}/releases/latest/download/{INSTALLER}"
    escape = html.escape
    return f"""<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Prokop — установка</title>
<style>
body {{ font-family: system-ui, sans-serif; line-height: 1.5; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; }}
pre {{ padding: .75rem 1rem; overflow-x: auto; border: 1px solid rgba(127, 127, 127, .4); border-radius: 6px; }}
</style>
</head>
<body>
<h1>Prokop</h1>
<p>Текущая версия: <strong>{escape(version)}</strong></p>
<h2>Установка и обновление</h2>
<p>Выполните на роутере с OpenWrt (по SSH):</p>
<pre><code>wget -qO- {escape(base_url)}/{INSTALLER} | sh</code></pre>
<p>Если этот сайт недоступен, тот же установщик лежит в GitHub Releases:</p>
<pre><code>wget -qO- {escape(fallback)} | sh</code></pre>
<p>Зеркало зависимостей по умолчанию выключено. Своё зеркало включается явно:
<code>… | sh -s -- --mirror https://ваше-зеркало</code></p>
<p>Исходный код, релизы и обратная связь:
<a href="{escape(page)}">{escape(page)}</a></p>
</body>
</html>
"""


def write_json(path, document):
    with open(path, "w", encoding="utf-8", newline="\n") as output:
        json.dump(document, output, ensure_ascii=False, indent=2)
        output.write("\n")


def build_site(site, releases, arguments):
    """Publish the newest release and up to --limit complete releases in all.

    The newest release is latest.json, so any fault there fails the run. An
    older release that is incomplete or fails verification is skipped, so it
    cannot block every later deploy; failed downloads still fail the run.
    """
    newest = releases[0]
    version = newest["tag_name"]
    digests = {}
    for release in releases:
        if len(digests) == arguments.limit:
            break
        tag = release["tag_name"]
        release_dir = site / "releases" / tag
        try:
            digests[tag] = fetch_release(release, arguments.repository,
                                         arguments.assets_dir, release_dir)
        except ReleaseRejected as error:
            if release is newest:
                raise
            if release_dir.exists():
                shutil.rmtree(release_dir)
            # Every ReleaseRejected message starts with "<tag>: ".
            print(f"WARNING: skipping {error}", file=sys.stderr, flush=True)
    print("Publishing " + ", ".join(digests), flush=True)

    fetch_installer(newest, arguments.repository, arguments.assets_dir,
                    arguments.raw_url, site / INSTALLER)
    (site / "updates").mkdir()
    write_json(site / "updates" / "latest.json",
               latest_document(version, arguments.base_url, digests[version]))
    catalog.write_catalog(site / "updates" / "releases.json", [
        catalog.release_entry(tag, arguments.base_url, digests[tag])
        for tag in digests
    ])
    with open(site / "LATEST", "w", encoding="utf-8", newline="\n") as latest:
        latest.write(f"{version}\n")
    with open(site / "index.html", "w", encoding="utf-8", newline="\n") as page:
        page.write(index_page(version, arguments.base_url, arguments.repository))


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True,
                        help="site directory to create (must be absent or empty)")
    parser.add_argument("--repository",
                        default=os.environ.get("PROKOP_RELEASE_REPO") or FORK_REPO)
    parser.add_argument("--base-url",
                        default=os.environ.get("PROKOP_RELEASE_BASE_URL") or FORK_RELEASE_BASE)
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT,
                        help=f"newest complete releases to publish (default {DEFAULT_LIMIT})")
    parser.add_argument("--api-url", default=os.environ.get("GITHUB_API_URL") or API_URL)
    parser.add_argument("--raw-url", default=RAW_URL,
                        help="where install.sh is read from when a release lacks it")
    parser.add_argument("--releases-json", type=Path,
                        help="read the release list from this file instead of the API")
    parser.add_argument("--assets-dir", type=Path,
                        help="read assets from DIR/<tag>/<name> instead of downloading")
    arguments = parser.parse_args()

    if not REPOSITORY.fullmatch(arguments.repository):
        parser.error(f"invalid repository: {arguments.repository}")
    arguments.base_url = arguments.base_url.rstrip("/")
    if not re.fullmatch(r"https?://[^\s/]+(/\S*)?", arguments.base_url):
        parser.error("--base-url must be an http:// or https:// URL")
    if arguments.limit < 1:
        parser.error("--limit must be at least 1")
    arguments.api_url = arguments.api_url.rstrip("/")
    arguments.raw_url = arguments.raw_url.rstrip("/")
    return arguments


def main():
    arguments = parse_arguments()
    output = arguments.output
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise SiteError(f"{output} already exists and is not an empty directory")

    if arguments.releases_json is not None:
        published = read_releases_file(arguments.releases_json)
    else:
        published = list_releases(arguments.api_url, arguments.repository,
                                   os.environ.get("GITHUB_TOKEN", ""))
    releases = stable_releases(published)
    if not releases:
        raise SiteError(f"{arguments.repository} has no stable X.Y.Z release")

    output.parent.mkdir(parents=True, exist_ok=True)
    site = Path(tempfile.mkdtemp(prefix=".site-", dir=output.parent))
    try:
        os.chmod(site, 0o755)
        build_site(site, releases, arguments)
        if output.exists():
            output.rmdir()
        os.rename(site, output)
    finally:
        if site.exists():
            shutil.rmtree(site)
    print(f"Site for {releases[0]['tag_name']} written to {output}")


if __name__ == "__main__":
    try:
        main()
    except (SiteError, OSError, ValueError, urllib.error.URLError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
