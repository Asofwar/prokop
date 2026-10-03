#!/usr/bin/env bash
# core/constants.uc: the fork's release channel by default, and an opt-in
# dependency mirror (a set PROKOP_MIRROR_BASE_URL wins, even when empty; then
# UCI; empty means none; no built-in default host).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
CONSTANTS_UC="$PROKOP_LIB/core/constants.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# constant NAME [VAR=value...]: the constant with only the given overrides.
constant() {
  local name="$1"
  shift
  env -u PROKOP_MIRROR_BASE_URL -u PROKOP_RELEASE_REPO -u PROKOP_RELEASE_BASE_URL \
    -u GITHUB_RAW_URL -u SRS_MAIN_URL "$@" ucode -L "$PROKOP_LIB" "$CONSTANTS_UC" get "$name"
}

assert_eq() {
  [ "$2" = "$1" ] || fail "$3: expected '$1', got '$2'"
}

assert_eq 'Asofwar/prokop' "$(constant PROKOP_RELEASE_REPO)" "fork release repository"
assert_eq 'https://asofwar.github.io/prokop' "$(constant PROKOP_RELEASE_BASE_URL)" "fork release channel"
assert_eq 'owner/repo' "$(constant PROKOP_RELEASE_REPO PROKOP_RELEASE_REPO=owner/repo)" "release repository override"

assert_eq '' "$(constant PROKOP_MIRROR_BASE_URL PROKOP_MIRROR_BASE_URL=)" "an empty environment mirror"
assert_eq 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main' \
  "$(constant GITHUB_RAW_URL PROKOP_MIRROR_BASE_URL=)" "lists without a mirror"
assert_eq 'https://github.com/itdoginfo/allow-domains/releases/latest/download' \
  "$(constant SRS_MAIN_URL PROKOP_MIRROR_BASE_URL=)" "community rule sets without a mirror"
assert_eq 'https://own-mirror.example' \
  "$(constant PROKOP_MIRROR_BASE_URL PROKOP_MIRROR_BASE_URL=https://own-mirror.example//)" "trailing slashes"
assert_eq 'https://own-mirror.example/forkop/lists/allow-domains' \
  "$(constant GITHUB_RAW_URL PROKOP_MIRROR_BASE_URL=https://own-mirror.example/)" "lists through an opted-in mirror"

if grep -Eq 'infotechtg|51343|fold8|slayer326' "$CONSTANTS_UC"; then
  fail "core/constants.uc must not name an upstream mirror or release channel"
fi
grep -Fq 'cursor.get("prokop", "settings", "mirror_base_url")' "$CONSTANTS_UC" ||
  fail "the mirror must still be read from UCI when the environment does not set it"

printf 'fork mirror constants checks passed\n'
