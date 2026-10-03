#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_BIN="$ROOT_DIR/prokop/files/usr/bin/prokop"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
CLI_UC="$PROKOP_BIN"
PROKOP_MAKEFILE="$ROOT_DIR/prokop/Makefile"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
CONSTANTS_SH="$PROKOP_LIB/constants.sh"
LIFECYCLE_UC="$PROKOP_LIB/service/lifecycle.uc"
CONSTANTS_UC="$PROKOP_LIB/core/constants.uc"
SINGBOX_CONSTANTS_UC="$PROKOP_LIB/singbox/constants.uc"
FRONTEND_CONSTANTS="$ROOT_DIR/fe-app-prokop/src/constants.ts"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=tests/helpers/source_checks.sh
source "$ROOT_DIR/tests/helpers/source_checks.sh"

[ ! -e "$CONSTANTS_SH" ] ||
  fail "constants.sh shell owner must be removed"

grep -Fq '#!/usr/bin/ucode' "$PROKOP_BIN" ||
  fail "prokop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch lifecycle orchestration through service/lifecycle.uc"
grep -Fq 'core.constants' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must load constants from core/constants.uc"

# Every runtime file: the ucode entrypoint has no .uc suffix.
source_refute "shell constants owner or parser references must not remain" \
  -E 'constants\.sh|read_shell_constants|expand_shell_constants|unquote_shell_value' "$PROKOP_BIN" "$PROKOP_LIB"

if grep -n 'constants\.sh' "$PROKOP_MAKEFILE" "$BUILD_SCRIPT" >/dev/null 2>&1; then
  fail "package build must not patch removed constants.sh"
fi
grep -Fq 'core/constants.uc' "$PROKOP_MAKEFILE" ||
  fail "prokop/Makefile must patch core/constants.uc"
grep -Fq 'core/constants.uc' "$BUILD_SCRIPT" ||
  fail "release build must patch core/constants.uc"

config_name="$(ucode -L "$PROKOP_LIB" "$CONSTANTS_UC" get PROKOP_CONFIG_NAME)"
[ "$config_name" = "prokop" ] ||
  fail "core/constants.uc get returned unexpected PROKOP_CONFIG_NAME"

eval "$(ucode -L "$PROKOP_LIB" "$CONSTANTS_UC" shell-env)"
[ "$PROKOP_CONFIG" = "/etc/config/prokop" ] ||
  fail "core/constants.uc shell-env did not derive PROKOP_CONFIG"
[ "$TMP_RULESET_FOLDER" = "/tmp/sing-box/rulesets" ] ||
  fail "core/constants.uc shell-env did not derive TMP_RULESET_FOLDER"
[ "$BYEDPI_PID_DIR" = "/var/run/prokop/byedpi/pid" ] ||
  fail "core/constants.uc shell-env did not derive BYEDPI_PID_DIR"

[ "$(ucode -L "$PROKOP_LIB" "$CONSTANTS_UC" get FAKEIP_TEST_DOMAIN)" = "fakeip.podkop.fyi" ] ||
  fail "FakeIP diagnostics must use the deployed public endpoint"
[ "$(ucode -L "$PROKOP_LIB" "$CONSTANTS_UC" get CHECK_PROXY_IP_DOMAIN)" = "ip.podkop.fyi" ] ||
  fail "public IP diagnostics must use the deployed public endpoint"
grep -Fq 'const FAKEIP_TEST_DOMAIN = "fakeip.podkop.fyi";' "$SINGBOX_CONSTANTS_UC" ||
  fail "sing-box constants must match the deployed FakeIP endpoint"
grep -Fq "export const FAKEIP_CHECK_DOMAIN = 'fakeip.podkop.fyi';" "$FRONTEND_CONSTANTS" ||
  fail "LuCI diagnostics must use the deployed FakeIP endpoint"
grep -Fq "export const IP_CHECK_DOMAIN = 'ip.podkop.fyi';" "$FRONTEND_CONSTANTS" ||
  fail "LuCI diagnostics must use the deployed public IP endpoint"

printf 'constants ownership checks passed\n'
