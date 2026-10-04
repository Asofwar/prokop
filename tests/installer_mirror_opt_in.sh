#!/usr/bin/env bash
set -euo pipefail

# The dependency mirror is off unless the user asks for it with --mirror URL
# or PROKOP_MIRROR_BASE_URL. An opted-in mirror reaches the package scripts,
# is saved after the Prokop packages and reconciles the feeds once more.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$WORK_DIR/install-library.sh"

# Runs a snippet against a freshly sourced installer library; the remaining
# arguments are environment assignments for that run.
run_installer() {
  local snippet="$1"
  shift
  env -u PROKOP_MIRROR_BASE_URL -u PROKOP_RELEASE_REPO -u PROKOP_RELEASE_BASE_URL "$@" \
    WORK_DIR="$WORK_DIR" bash -c '
      set -eu
      . "$WORK_DIR/install-library.sh"
      TMP_DIR="$WORK_DIR/tmp"
      mkdir -p "$TMP_DIR"
      eval "$1"
    ' run-installer "$snippet"
}

child_mirror_env='if [ "${PROKOP_MIRROR_BASE_URL+set}" = set ]; then printf "set:%s\n" "$PROKOP_MIRROR_BASE_URL"; else printf "unset\n"; fi'

# 1. No default mirror; nothing is exported to the package scripts.
[ "$(run_installer 'printf "[%s]\n" "$MIRROR_BASE_URL"')" = "[]" ] ||
  fail_test "the installer must not default to a dependency mirror"
[ "$(run_installer "validate_installer_settings; sh -c '$child_mirror_env'")" = "unset" ] ||
  fail_test "without an opt-in the package scripts must fall back to prokop.settings.mirror_base_url"
# An explicitly empty variable keeps the mirror off and stays empty for them.
[ "$(run_installer "validate_installer_settings; printf '[%s]\n' \"\$MIRROR_BASE_URL\"; sh -c '$child_mirror_env'" \
  PROKOP_MIRROR_BASE_URL=)" = "$(printf '[]\nset:')" ] ||
  fail_test "an empty PROKOP_MIRROR_BASE_URL must keep the mirror off"

# 2. --mirror URL, --mirror=URL and the environment variable opt in.
for args in "--mirror https://mirror.example/" "--mirror=https://mirror.example//"; do
  # shellcheck disable=SC2016 # expanded by the child shell
  output="$(run_installer "parse_args $args; validate_installer_settings; printf '%s\n' \"\$MIRROR_BASE_URL\"; sh -c '$child_mirror_env'")"
  [ "$output" = "$(printf 'https://mirror.example\nset:https://mirror.example')" ] ||
    fail_test "$args must opt in to the mirror and reach the package scripts: $output"
done
output="$(run_installer "validate_installer_settings; printf '%s\n' \"\$MIRROR_BASE_URL\"; sh -c '$child_mirror_env'" \
  PROKOP_MIRROR_BASE_URL=https://env-mirror.example/)"
[ "$output" = "$(printf 'https://env-mirror.example\nset:https://env-mirror.example')" ] ||
  fail_test "PROKOP_MIRROR_BASE_URL must opt in to the mirror: $output"
output="$(run_installer 'parse_args --mirror https://flag-mirror.example; validate_installer_settings; printf "%s\n" "$MIRROR_BASE_URL"' \
  PROKOP_MIRROR_BASE_URL=https://env-mirror.example)"
[ "$output" = "https://flag-mirror.example" ] ||
  fail_test "--mirror must take precedence over PROKOP_MIRROR_BASE_URL: $output"

for args in "--mirror" "--mirror ''" "--mirror="; do
  if run_installer "parse_args $args" >/dev/null 2>&1; then
    fail_test "$args without a URL must be rejected"
  fi
done
for bad_mirror in "mirror.example" "ftp://mirror.example" "https://" "https:///" \
  "https://mirror.example/a b" "https://mirror.example/#x" "https://mirror.example/a&b" 'https://mirror.example/a\b' \
  "https://user@mirror.example" "https://mirror.example/?x" "https://mirror.example/a=b" \
  "https://mirror.example/a+b" "https://mirror.example/(a)" "https://mirror.example/[a]" \
  "https://mirror.example/a|b" "https://mirror.example/a;b" "https://mirror.example/a'b" \
  'https://mirror.example/a"b' 'https://mirror.example/a$b' "https://mirror.example/a*b"; do
  if run_installer 'parse_args --mirror "$BAD_MIRROR"; validate_installer_settings' BAD_MIRROR="$bad_mirror" >/dev/null 2>&1; then
    fail_test "an invalid mirror URL was accepted: $bad_mirror"
  fi
done
output="$(run_installer 'parse_args --mirror "https://mirror.example/a+b"; validate_installer_settings' 2>&1)" || true
printf '%s\n' "$output" | grep -Fq 'only letters, digits and . _ ~ : / % - are supported' ||
  fail_test "an unsupported mirror URL character must be named in the error: $output"
output="$(run_installer 'parse_args --mirror "http://Mirror-1.example:8080/my_path/~x/%7Ey/"; validate_installer_settings; printf "%s\n" "$MIRROR_BASE_URL"' | tail -n 1)"
[ "$output" = "http://Mirror-1.example:8080/my_path/~x/%7Ey" ] ||
  fail_test "a mirror URL of letters, digits and . _ ~ : / % - must be accepted: $output"
# An http:// mirror serves the signed OpenWrt feeds, but the installer says
# that binaries and scripts will not come from it; the Prokop release base,
# which carries the packages and their checksums together, must be https://
# (UPD-2).
output="$(run_installer 'parse_args --mirror "http://mirror.example"; validate_installer_settings' 2>&1)"
printf '%s\n' "$output" | grep -Fq 'installed only from an https:// mirror' ||
  fail_test "an http:// mirror must be reported as not used for binaries: $output"
output="$(run_installer 'parse_args --mirror "https://mirror.example"; validate_installer_settings' 2>&1)"
if printf '%s\n' "$output" | grep -Fq 'https:// mirror'; then
  fail_test "an https:// mirror must not be warned about: $output"
fi
if run_installer 'validate_installer_settings' PROKOP_RELEASE_BASE_URL=http://releases.example >"$WORK_DIR/out" 2>&1; then
  fail_test "an http:// release base must be refused"
fi
grep -Fq 'PROKOP_RELEASE_BASE_URL must use https://' "$WORK_DIR/out" ||
  fail_test "the refused release base must be explained: $(cat "$WORK_DIR/out")"
# install.sh and mirror-migration.sh accept the same characters.
mirror_charset() {
  awk '
    /case "\$MIRROR_BASE_URL" in/ { in_case = 1; next }
    in_case && /esac/ { in_case = 0 }
    in_case && match($0, /\*\[![^]]+\]\*\)/) { print substr($0, RSTART, RLENGTH) }
  ' "$1" | sort -u
}
installer_charset="$(mirror_charset "$ROOT_DIR/install.sh")"
migration_charset="$(mirror_charset "$ROOT_DIR/prokop/files/usr/share/prokop/mirror-migration.sh")"
[ -n "$installer_charset" ] && [ "$installer_charset" = "$migration_charset" ] ||
  fail_test "install.sh and mirror-migration.sh must accept the same mirror URL characters: '$installer_charset' vs '$migration_charset'"
run_installer 'usage' | grep -Fq -- '--mirror URL' ||
  fail_test "the usage text must document --mirror URL"

# 3. Saving the opted-in mirror after the Prokop packages.
cat >"$WORK_DIR/mirror-migration.sh" <<'SH'
#!/bin/sh
printf 'migration:%s\n' "${PROKOP_MIRROR_BASE_URL-unset}" >>"$WORK_DIR/actions.log"
exit "${FAKE_MIGRATION_STATUS:-0}"
SH
chmod 0755 "$WORK_DIR/mirror-migration.sh"
persist_snippet='
  MIRROR_MIGRATION_SCRIPT="$WORK_DIR/mirror-migration.sh"
  install_json_ucode() {
    printf "ucode:%s\n" "$*" >>"$WORK_DIR/actions.log"
    return "${FAKE_PERSIST_STATUS:-0}"
  }
  validate_installer_settings
  persist_mirror_setting
  printf "saved=%s\n" "$MIRROR_SETTING_SAVED"
  print_installation_summary
'

: >"$WORK_DIR/actions.log"
output="$(run_installer "$persist_snippet")"
[ ! -s "$WORK_DIR/actions.log" ] ||
  fail_test "without an opt-in the installer must neither write mirror_base_url nor rerun the mirror migration"
printf '%s\n' "$output" | grep -Fq 'saved=0' ||
  fail_test "without an opt-in nothing may be saved"
printf '%s\n' "$output" | grep -Fq 'Dependency mirror: not requested' ||
  fail_test "the summary must say that no mirror was requested"

: >"$WORK_DIR/actions.log"
output="$(run_installer "parse_args --mirror https://mirror.example/; $persist_snippet")"
[ "$(cat "$WORK_DIR/actions.log")" = "$(printf 'ucode:installer-persist-mirror https://mirror.example\nmigration:https://mirror.example')" ] ||
  fail_test "an opted-in mirror must be saved through the ucode helper, then the feeds reconciled: $(cat "$WORK_DIR/actions.log")"
printf '%s\n' "$output" | grep -Fq 'saved=1' ||
  fail_test "a saved mirror must be recorded"
printf '%s\n' "$output" | grep -Fxq "$(printf '\033[32;1m%s\033[0m' 'Dependency mirror: https://mirror.example')" ||
  fail_test "the summary must name the saved mirror"

# A failed save or a failed reconciliation only warns: Prokop is installed.
: >"$WORK_DIR/actions.log"
output="$(run_installer "parse_args --mirror https://mirror.example; $persist_snippet" FAKE_PERSIST_STATUS=1)" ||
  fail_test "a failed mirror save must not stop the installation"
grep -Fxq 'migration:https://mirror.example' "$WORK_DIR/actions.log" ||
  fail_test "the feeds must be reconciled even when the save failed"
printf '%s\n' "$output" | grep -Fq 'saved=0' ||
  fail_test "a failed save must not be recorded as saved"
printf '%s\n' "$output" | grep -Fq 'is not saved in prokop.settings.mirror_base_url' ||
  fail_test "the summary must warn that the mirror was not saved"

run_installer "parse_args --mirror https://mirror.example; $persist_snippet" FAKE_MIGRATION_STATUS=1 >"$WORK_DIR/out" ||
  fail_test "a failed feed reconciliation must not stop the installation"
grep -Fq 'Failed to reconcile package feeds' "$WORK_DIR/out" ||
  fail_test "a failed feed reconciliation must be reported"

run_installer "parse_args --mirror https://mirror.example; $persist_snippet
  MIRROR_MIGRATION_SCRIPT=\"\$WORK_DIR/missing.sh\"
  persist_mirror_setting" >"$WORK_DIR/out" ||
  fail_test "a missing mirror migration must not stop the installation"
grep -Fq 'missing.sh is missing' "$WORK_DIR/out" ||
  fail_test "a missing mirror migration must be reported"

printf 'Installer mirror opt-in tests passed\n'
