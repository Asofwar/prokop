#!/usr/bin/env bash
set -eo pipefail

workflow="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/build.yml"

if grep -Fiq 'sourceforge' "$workflow"; then
  echo 'Build workflow must leave SourceForge publication to GitHub Integration' >&2
  exit 1
fi

grep -Fq 'uses: softprops/action-gh-release@v2.4.0' "$workflow"
grep -Fq './ops/hosting/prepare-release.sh "$VERSION"' "$workflow"
grep -Fq 'name: timeweb-files-${{ needs.preparation.outputs.version }}' "$workflow"
grep -Fq './filtered-bin/release/*.*' "$workflow"
grep -Fq './filtered-bin/hosting/*.tar.gz' "$workflow"
grep -Fq 'elif [ -f "docs/releases/$VERSION.md" ]; then' "$workflow"
grep -Fq 'RAW_RELEASE_NOTES="$(cat "docs/releases/$VERSION.md")"' "$workflow"

# The bundle and its catalog describe the fork's channel and releases.
grep -Fq 'PROKOP_RELEASE_BASE_URL: https://asofwar.github.io/prokop' "$workflow"
grep -Fq 'PROKOP_RELEASE_REPO: ${{ github.repository }}' "$workflow"
grep -Fq 'GITHUB_TOKEN: ${{ github.token }}' "$workflow"
# Every release carries the installer of its own commit, which the GitHub
# Releases one-liner and the Pages channel serve.
grep -Fq 'ref: ${{ needs.preparation.outputs.commitish }}' "$workflow"
grep -Fxq '            ./install.sh' "$workflow"
grep -Fq 'fail_on_unmatched_files: true' "$workflow"
# Pages deploys only from the default branch; tag runs must not try.
if grep -Fq -e 'deploy-pages' -e 'github-pages' "$workflow"; then
  echo 'Build workflow must leave the Pages deployment to pages.yml' >&2
  exit 1
fi
if grep -Fq -e 'fold8.ru' -e 'slayer326' "$workflow"; then
  echo 'Build workflow still points at the upstream release channel' >&2
  exit 1
fi

printf 'release workflow checks passed\n'
