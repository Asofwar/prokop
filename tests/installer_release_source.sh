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

unset PROKOP_RELEASE_REPO PROKOP_RELEASE_BASE_URL PROKOP_MIRROR_BASE_URL
sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090
. "$WORK_DIR/install-library.sh"
TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$TMP_DIR"

[ "$RELEASE_REPO" = "Asofwar/prokop" ] ||
  fail_test "the release repository must default to Asofwar/prokop"
[ "$RELEASE_BASE_URL" = "https://asofwar.github.io/prokop" ] ||
  fail_test "the release channel must default to https://asofwar.github.io/prokop"

release_hash='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
channel_json="{\"tag_name\":\"0.0.1\",\"assets\":[
  {\"name\":\"prokop_0.0.1.ipk\",\"browser_download_url\":\"https://asofwar.github.io/prokop/releases/0.0.1/prokop_0.0.1.ipk\",\"sha256\":\"$release_hash\"},
  {\"name\":\"luci-app-prokop_0.0.1.ipk\",\"browser_download_url\":\"https://asofwar.github.io/prokop/releases/0.0.1/luci-app-prokop_0.0.1.ipk\",\"sha256\":\"$release_hash\"}]}"
github_json="{\"tag_name\":\"0.0.1\",\"assets\":[
  {\"name\":\"install.sh\",\"browser_download_url\":\"https://github.com/Asofwar/prokop/releases/download/0.0.1/install.sh\"},
  {\"name\":\"prokop_0.0.1.ipk\",\"browser_download_url\":\"https://github.com/Asofwar/prokop/releases/download/0.0.1/prokop_0.0.1.ipk\",\"digest\":\"sha256:$release_hash\"},
  {\"name\":\"luci-app-prokop_0.0.1.ipk\",\"browser_download_url\":\"https://github.com/Asofwar/prokop/releases/download/0.0.1/luci-app-prokop_0.0.1.ipk\",\"digest\":\"sha256:$release_hash\"}]}"

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
  PROKOP_RELEASE_JSON=""
  PROKOP_RELEASE_SOURCE=""
  PROKOP_RELEASE_TAG=""
}

# 1. The static channel serves the release.
reset_release
CHANNEL_RESPONSE="$channel_json"
GITHUB_RESPONSE="$github_json"
PKG_IS_APK=0
PROKOP_I18N_REQUESTED=0
resolve_prokop_release >"$WORK_DIR/channel.out"
[ "$PROKOP_RELEASE_SOURCE" = "https://asofwar.github.io/prokop" ] ||
  fail_test "a release from the channel must name the channel as its source: $PROKOP_RELEASE_SOURCE"
grep -Fxq 'https://asofwar.github.io/prokop/updates/latest.json' "$WORK_DIR/requests.log" ||
  fail_test "the installer must query the fork's release channel first"
if grep -Fq 'api.github.com' "$WORK_DIR/requests.log"; then
  fail_test "the GitHub fallback must not run while the release channel works"
fi
[ "$PROKOP_BACKEND_URL" = "https://asofwar.github.io/prokop/releases/0.0.1/prokop_0.0.1.ipk" ] ||
  fail_test "the backend package must come from the release channel: $PROKOP_BACKEND_URL"
grep -Fq 'Prokop release 0.0.1 from https://asofwar.github.io/prokop' "$WORK_DIR/channel.out" ||
  fail_test "the installer must print the release source it used"

# 2. The channel is down: the fork's GitHub Releases serve the release, and
#    neither the progress output nor the summary claims the channel.
for broken_channel in "" "<html>Not Found</html>" '{"tag_name":""}'; do
  reset_release
  CHANNEL_RESPONSE="$broken_channel"
  resolve_prokop_release >"$WORK_DIR/github.out"
  grep -Fxq 'https://api.github.com/repos/Asofwar/prokop/releases/latest' "$WORK_DIR/requests.log" ||
    fail_test "the fallback must query the fork's GitHub Releases"
  [ "$PROKOP_RELEASE_SOURCE" = "GitHub Releases of Asofwar/prokop" ] ||
    fail_test "a GitHub release must be reported as such: $PROKOP_RELEASE_SOURCE"
  [ "$PROKOP_BACKEND_URL" = "https://github.com/Asofwar/prokop/releases/download/0.0.1/prokop_0.0.1.ipk" ] ||
    fail_test "the backend package must come from the GitHub release: $PROKOP_BACKEND_URL"
  [ "$PROKOP_BACKEND_SHA256" = "$release_hash" ] ||
    fail_test "the GitHub release digest must be used to verify the package"
  grep -Fq 'Prokop release 0.0.1 from GitHub Releases of Asofwar/prokop' "$WORK_DIR/github.out" ||
    fail_test "the installer must print that GitHub served the release"
  PROKOP_PACKAGE_VERSION="0.0.1"
  MIRROR_BASE_URL=""
  summary="$(print_installation_summary)"
  printf '%s\n' "$summary" | grep -Fq 'Prokop release source: GitHub Releases of Asofwar/prokop (0.0.1)' ||
    fail_test "the summary must name the GitHub fallback"
  if printf '%s\n' "$summary" | grep -Fq 'asofwar.github.io'; then
    fail_test "the summary must not claim the release channel when GitHub served the release"
  fi
done

# 3. A different release repository is used for the fallback.
reset_release
CHANNEL_RESPONSE=""
RELEASE_REPO="someone/prokop-fork"
fetch_prokop_latest_release_json >/dev/null
grep -Fxq 'https://api.github.com/repos/someone/prokop-fork/releases/latest' "$WORK_DIR/requests.log" ||
  fail_test "PROKOP_RELEASE_REPO must select the GitHub fallback repository"
[ "$PROKOP_RELEASE_SOURCE" = "GitHub Releases of someone/prokop-fork" ] ||
  fail_test "the fallback source must name the selected repository"
RELEASE_REPO="Asofwar/prokop"

# 4. Neither source answers: the installer stops.
reset_release
CHANNEL_RESPONSE=""
GITHUB_RESPONSE=""
if (resolve_prokop_release) >/dev/null 2>&1; then
  fail_test "the installer must stop when no release source answers"
fi

# 5. PROKOP_RELEASE_REPO and PROKOP_RELEASE_BASE_URL are validated.
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
expect_settings_accepted "Asofwar/prokop" "https://asofwar.github.io/prokop"
expect_settings_accepted "some-org/repo.name_1" "https://releases.example/prokop"
expect_settings_accepted "Asofwar/prokop" "https://asofwar.github.io/prokop//"
[ "$RELEASE_BASE_URL" = "https://asofwar.github.io/prokop" ] ||
  fail_test "trailing slashes must be stripped from the release channel"
for bad_repo in "" "Asofwar" "Asofwar/" "/prokop" "a/b/c" "../prokop" "Asofwar/.." "Asofwar/." \
  "Asofwar/fork op" "Asofwar/prokop;id" "Aso.fwar/prokop" "Asofwar/prokop?x=1"; do
  expect_settings_rejected "$bad_repo" "https://asofwar.github.io/prokop"
done
# Packages and their checksums come from the release base together (UPD-2).
for bad_base in "http://releases.example/prokop" "asofwar.github.io/prokop" "ftp://asofwar.github.io/prokop" "https://" "https:///"; do
  expect_settings_rejected "Asofwar/prokop" "$bad_base"
done

printf 'Installer release source tests passed\n'
