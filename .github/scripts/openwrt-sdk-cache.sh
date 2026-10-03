#!/usr/bin/env bash
# The OpenWrt SDK archives build.sh downloads, as an Actions cache entry.
#
#   openwrt-sdk-cache.sh outputs <dir>   write key, dir, paths and enabled to
#                                        $GITHUB_OUTPUT (or stdout)
#   openwrt-sdk-cache.sh download <dir>  download the archives into <dir> the
#                                        way build.sh does, if missing
#
# The key is derived from the exact SDK URLs build.sh will use (its defaults,
# or IPK_SDK_URL / APK_SDK_URL from the environment), and the paths are the
# file names build.sh gives the archives inside SDK_CACHE_DIR. Only the
# downloaded archives are cached, never anything built from them.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-}"
DIR="${2:-}"

if [[ "$MODE" != outputs && "$MODE" != download ]] || [[ -z "$DIR" ]]; then
  echo "usage: $(basename "$0") outputs|download <dir>" >&2
  exit 2
fi

sdk_urls() {
  # Evaluate only build.sh's two URL assignments, in a clean subshell.
  bash -c 'set -eu
    eval "$(grep -E "^(IPK|APK)_SDK_URL=" "$1")"
    printf "%s\n" "$IPK_SDK_URL" "$APK_SDK_URL"' _ "$ROOT_DIR/build.sh"
}

urls=()
if listed="$(sdk_urls 2>/dev/null)"; then
  mapfile -t urls <<<"$listed"
fi
valid=true
if (( ${#urls[@]} != 2 )); then
  valid=false
fi
for url in "${urls[@]}"; do
  [[ "$url" =~ ^https://[^[:space:]]+[.]tar[.]zst$ ]] || valid=false
done

if [[ "$MODE" == download ]]; then
  [[ "$valid" == true ]] || { echo "Could not read the SDK URLs from build.sh" >&2; exit 1; }
  mkdir -p "$DIR"
  for url in "${urls[@]}"; do
    archive="$DIR/$(basename "$url")"
    [[ -f "$archive" ]] && continue
    echo "Downloading SDK: $url" >&2
    curl --fail --location --retry 3 --output "$archive.part" "$url"
    mv "$archive.part" "$archive"
  done
  exit 0
fi

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    cat >>"$GITHUB_OUTPUT"
  else
    cat
  fi
}

if [[ "$valid" != true ]]; then
  echo "::warning::Could not read the OpenWrt SDK URLs from build.sh; the SDK cache is skipped"
  printf 'enabled=false\ndir=%s\n' "$DIR" | emit
  exit 0
fi

digest="$(printf '%s\n' "${urls[@]}" | sha256sum | cut -c1-24)"
{
  echo "enabled=true"
  echo "dir=$DIR"
  echo "key=openwrt-sdk-archives-$digest"
  echo "paths<<PROKOP_SDK_PATHS"
  for url in "${urls[@]}"; do
    echo "$DIR/$(basename "$url")"
  done
  echo "PROKOP_SDK_PATHS"
} | emit
printf 'SDK archives: %s\n' "${urls[@]}"
