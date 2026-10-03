#!/usr/bin/env bash
set -euo pipefail

# The installer resolves the fork's release from its static channel first and
# from the fork's GitHub Releases second, and reports the source it used.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

unset FORKOP_RELEASE_REPO FORKOP_RELEASE_BASE_URL FORKOP_MIRROR_BASE_URL
sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090
. "$WORK_DIR/install-library.sh"
TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$TMP_DIR"

[ "$RELEASE_REPO" = "Asofwar/forkop" ] ||
  fail_test "the release repository must default to Asofwar/forkop"
[ "$RELEASE_BASE_URL" = "https://asofwar.github.io/forkop" ] ||
  fail_test "the release channel must default to https://asofwar.github.io/forkop"

release_hash='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
channel_json="{\"tag_name\":\"0.0.1\",\"assets\":[
  {\"name\":\"forkop_0.0.1.ipk\",\"browser_download_url\":\"https://asofwar.github.io/forkop/releases/0.0.1/forkop_0.0.1.ipk\",\"sha256\":\"$release_hash\"},
  {\"name\":\"luci-app-forkop_0.0.1.ipk\",\"browser_download_url\":\"https://asofwar.github.io/forkop/releases/0.0.1/luci-app-forkop_0.0.1.ipk\",\"sha256\":\"$release_hash\"}]}"
github_json="{\"tag_name\":\"0.0.1\",\"assets\":[
  {\"name\":\"install.sh\",\"browser_download_url\":\"https://github.com/Asofwar/forkop/releases/download/0.0.1/install.sh\"},
  {\"name\":\"forkop_0.0.1.ipk\",\"browser_download_url\":\"https://github.com/Asofwar/forkop/releases/download/0.0.1/forkop_0.0.1.ipk\",\"digest\":\"sha256:$release_hash\"},
  {\"name\":\"luci-app-forkop_0.0.1.ipk\",\"browser_download_url\":\"https://github.com/Asofwar/forkop/releases/download/0.0.1/luci-app-forkop_0.0.1.ipk\",\"digest\":\"sha256:$release_hash\"}]}"

CHANNEL_RESPONSE=""
GITHUB_RESPONSE=""
http_get() {
  printf '%s\n' "$1" >>"$WORK_DIR/requests.log"
  case "$1" in
    */updates/latest.json) printf '%s' "$CHANNEL_RESPONSE" ;;
    https://api.github.com/repos/*/releases/latest) printf '%s' "$GITHUB_RESPONSE" ;;
    *) return 1 ;;
  esac
}

reset_release() {
  : >"$WORK_DIR/requests.log"
  FORKOP_RELEASE_JSON=""
  FORKOP_RELEASE_SOURCE=""
  FORKOP_RELEASE_TAG=""
}

# 1. The static channel serves the release.
reset_release
CHANNEL_RESPONSE="$channel_json"
GITHUB_RESPONSE="$github_json"
PKG_IS_APK=0
FORKOP_I18N_REQUESTED=0
resolve_forkop_release >"$WORK_DIR/channel.out"
[ "$FORKOP_RELEASE_SOURCE" = "https://asofwar.github.io/forkop" ] ||
  fail_test "a release from the channel must name the channel as its source: $FORKOP_RELEASE_SOURCE"
grep -Fxq 'https://asofwar.github.io/forkop/updates/latest.json' "$WORK_DIR/requests.log" ||
  fail_test "the installer must query the fork's release channel first"
if grep -Fq 'api.github.com' "$WORK_DIR/requests.log"; then
  fail_test "the GitHub fallback must not run while the release channel works"
fi
[ "$FORKOP_BACKEND_URL" = "https://asofwar.github.io/forkop/releases/0.0.1/forkop_0.0.1.ipk" ] ||
  fail_test "the backend package must come from the release channel: $FORKOP_BACKEND_URL"
grep -Fq 'Forkop release 0.0.1 from https://asofwar.github.io/forkop' "$WORK_DIR/channel.out" ||
  fail_test "the installer must print the release source it used"

# 2. The channel is down: the fork's GitHub Releases serve the release, and
#    neither the progress output nor the summary claims the channel.
for broken_channel in "" "<html>Not Found</html>" '{"tag_name":""}'; do
  reset_release
  CHANNEL_RESPONSE="$broken_channel"
  resolve_forkop_release >"$WORK_DIR/github.out"
  grep -Fxq 'https://api.github.com/repos/Asofwar/forkop/releases/latest' "$WORK_DIR/requests.log" ||
    fail_test "the fallback must query the fork's GitHub Releases"
  [ "$FORKOP_RELEASE_SOURCE" = "GitHub Releases of Asofwar/forkop" ] ||
    fail_test "a GitHub release must be reported as such: $FORKOP_RELEASE_SOURCE"
  [ "$FORKOP_BACKEND_URL" = "https://github.com/Asofwar/forkop/releases/download/0.0.1/forkop_0.0.1.ipk" ] ||
    fail_test "the backend package must come from the GitHub release: $FORKOP_BACKEND_URL"
  [ "$FORKOP_BACKEND_SHA256" = "$release_hash" ] ||
    fail_test "the GitHub release digest must be used to verify the package"
  grep -Fq 'Forkop release 0.0.1 from GitHub Releases of Asofwar/forkop' "$WORK_DIR/github.out" ||
    fail_test "the installer must print that GitHub served the release"
  FORKOP_PACKAGE_VERSION="0.0.1"
  MIRROR_BASE_URL=""
  summary="$(print_installation_summary)"
  printf '%s\n' "$summary" | grep -Fq 'Forkop release source: GitHub Releases of Asofwar/forkop (0.0.1)' ||
    fail_test "the summary must name the GitHub fallback"
  if printf '%s\n' "$summary" | grep -Fq 'asofwar.github.io'; then
    fail_test "the summary must not claim the release channel when GitHub served the release"
  fi
done

# 3. A different release repository is used for the fallback.
reset_release
CHANNEL_RESPONSE=""
RELEASE_REPO="someone/forkop-fork"
fetch_forkop_latest_release_json >/dev/null
grep -Fxq 'https://api.github.com/repos/someone/forkop-fork/releases/latest' "$WORK_DIR/requests.log" ||
  fail_test "FORKOP_RELEASE_REPO must select the GitHub fallback repository"
[ "$FORKOP_RELEASE_SOURCE" = "GitHub Releases of someone/forkop-fork" ] ||
  fail_test "the fallback source must name the selected repository"
RELEASE_REPO="Asofwar/forkop"

# 4. Neither source answers: the installer stops.
reset_release
CHANNEL_RESPONSE=""
GITHUB_RESPONSE=""
if (resolve_forkop_release) >/dev/null 2>&1; then
  fail_test "the installer must stop when no release source answers"
fi

# 5. FORKOP_RELEASE_REPO and FORKOP_RELEASE_BASE_URL are validated.
expect_settings_accepted() {
  RELEASE_REPO="$1"
  RELEASE_BASE_URL="$2"
  MIRROR_BASE_URL=""
  validate_installer_settings >/dev/null 2>&1 ||
    fail_test "valid release settings were rejected: $1 $2"
}
expect_settings_rejected() {
  if (RELEASE_REPO="$1"; RELEASE_BASE_URL="$2"; MIRROR_BASE_URL=""; validate_installer_settings) >/dev/null 2>&1; then
    fail_test "invalid release settings were accepted: '$1' '$2'"
  fi
}
expect_settings_accepted "Asofwar/forkop" "https://asofwar.github.io/forkop"
expect_settings_accepted "some-org/repo.name_1" "http://releases.example/forkop"
expect_settings_accepted "Asofwar/forkop" "https://asofwar.github.io/forkop//"
[ "$RELEASE_BASE_URL" = "https://asofwar.github.io/forkop" ] ||
  fail_test "trailing slashes must be stripped from the release channel"
for bad_repo in "" "Asofwar" "Asofwar/" "/forkop" "a/b/c" "../forkop" "Asofwar/.." "Asofwar/." \
  "Asofwar/fork op" "Asofwar/forkop;id" "Aso.fwar/forkop" "Asofwar/forkop?x=1"; do
  expect_settings_rejected "$bad_repo" "https://asofwar.github.io/forkop"
done
for bad_base in "asofwar.github.io/forkop" "ftp://asofwar.github.io/forkop" "https://" "https:///"; do
  expect_settings_rejected "Asofwar/forkop" "$bad_base"
done

printf 'Installer release source tests passed\n'
