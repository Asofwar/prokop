#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/ops/mirror/sync-prokop-release.py"
SERVICE="$ROOT_DIR/ops/mirror/prokop-release-sync.service"
PUBLISH="$ROOT_DIR/ops/mirror/publish-prokop-feed.sh"
PYTHON_BIN="${PYTHON_BIN:-python}"
PYCACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$PYCACHE_DIR"' EXIT
# Byte code of the checked script goes to a private cache, not into ops/mirror.
export PYTHONPYCACHEPREFIX="$PYCACHE_DIR" PYTHONDONTWRITEBYTECODE=1

"$PYTHON_BIN" -m py_compile "$SCRIPT"
bash -n "$PUBLISH"
# The defaults are checked, so an operator's environment must not leak in.
env -u PROKOP_GITHUB_REPOSITORY "$PYTHON_BIN" - "$SCRIPT" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("sync_prokop_release", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
# Without an override the mirror copies the fork's releases.
assert module.REPOSITORY == "Asofwar/prokop", module.REPOSITORY
assert module.safe_url("https://api.github.com/repos/Asofwar/prokop/releases/latest")
for url in [
    "http://github.com/Asofwar/prokop/releases/download/1.0.10/prokop_1.0.10.apk",
    "https://github.com.evil.test/Asofwar/prokop/releases/download/1.0.10/prokop_1.0.10.apk",
]:
    try:
        module.safe_url(url)
    except ValueError:
        pass
    else:
        raise AssertionError(url)


def release_from(repository):
    release = {
        "tag_name": "1.0.10",
        "draft": False,
        "prerelease": False,
        "assets": [],
    }
    for package, extension in module.PACKAGE_SPECS:
        name = f"{package}_1.0.10.{extension}"
        release["assets"].append({
            "name": name,
            "size": 1,
            "digest": "sha256:" + "a" * 64,
            "browser_download_url": f"https://github.com/{repository}/releases/download/1.0.10/{name}",
        })
    return release


version, assets = module.release_assets(release_from("Asofwar/prokop"))
assert version == "1.0.10" and len(assets) == 6
# Assets of another repository (the upstream one included) are not mirrored.
try:
    module.release_assets(release_from("slayer326/forkop"))
except ValueError:
    pass
else:
    raise AssertionError("an upstream release asset was accepted")
missing_digest = release_from("Asofwar/prokop")
missing_digest["assets"][0]["digest"] = None
try:
    module.release_assets(missing_digest)
except ValueError:
    pass
else:
    raise AssertionError("a release asset without a SHA-256 digest was accepted")
PY

for script in "$ROOT_DIR/ops/mirror/sync-prokop.sh" "$ROOT_DIR/ops/mirror/update-prokop-from-git.sh"; do
  grep -Fq 'GITHUB_REPOSITORY="${PROKOP_GITHUB_REPOSITORY:-Asofwar/prokop}"' "$script" || {
    echo "$script does not default to the fork repository" >&2
    exit 1
  }
done
# A Git rebuild must refuse a source that follows another repository's releases.
grep -Fq 'grep -Fq "\"$GITHUB_REPOSITORY\"" "$source_dir/prokop/files/usr/lib/core/constants.uc"' \
  "$ROOT_DIR/ops/mirror/update-prokop-from-git.sh" || {
  echo "update-prokop-from-git.sh does not check the release repository of the source" >&2
  exit 1
}

grep -Fq 'digest.removeprefix("sha256:")' "$SCRIPT" || {
  echo "release sync does not require GitHub SHA-256 digests" >&2
  exit 1
}
grep -Fq 'expected_path = f"/{REPOSITORY}/releases/download/{tag}/{name}"' "$SCRIPT" || {
  echo "release sync does not constrain asset URLs to the selected repository" >&2
  exit 1
}
grep -Fq 'subprocess.run([PUBLISH_COMMAND' "$SCRIPT" || {
  echo "release sync does not call the signed feed publisher" >&2
  exit 1
}
grep -Fq 'PROKOP_APK_PRIVATE_KEY=/mnt/storage/prokop-mirror/keys/forkop-apk.pem' "$SERVICE" || {
  echo "release service does not isolate its signing key path" >&2
  exit 1
}
grep -Fq 'APK_BIN=/mnt/storage/prokop-mirror/tools/apk-runtime/bin/apk' "$SERVICE" || {
  echo "release service does not point to the complete apk runtime" >&2
  exit 1
}
grep -Fq 'RequiresMountsFor=/mnt/storage/prokop-mirror' "$SERVICE" || {
  echo "release service does not require the mirror volume" >&2
  exit 1
}

printf 'Prokop release sync contract checks passed\n'
