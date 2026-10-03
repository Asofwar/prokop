#!/usr/bin/env bash
set -eo pipefail

# The production owners of what core/helpers.uc once also did (UC-179):
# core/helpers.uc keeps only version-at-least, which components/action.uc
# and diagnostics/runtime.uc run; the run-time tag allocation is
# singbox/constants.uc tag() (the generator path is in tests/outbound_tags.sh).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
HELPERS_UC="$LIB/core/helpers.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# --- version-at-least --------------------------------------------------------------
at_least() { ucode "$HELPERS_UC" version-at-least "$1" "$2"; }
for pair in "1.12.4 1.12.4" "1.12.10 1.12.4" "1.13.0 1.12.4" "1.12.4-r1 1.12.4" "1.012.4 1.12.4" "2 1.99"; do
  # shellcheck disable=SC2086
  at_least $pair || fail "version-at-least $pair must hold"
done
for pair in "1.12.3 1.12.4" "1.9.9 1.12.4" "1.12.4~rc1 1.12.4" "1.12 1.12.4"; do
  # shellcheck disable=SC2086
  if at_least $pair; then fail "version-at-least $pair must not hold"; fi
done
if ucode "$HELPERS_UC" outbound-tag proxy >/dev/null 2>&1; then
  fail "core/helpers.uc must not keep the removed modes"
fi

# --- run-time tags (singbox/constants.uc) ----------------------------------------
tag() { ucode -L "$LIB" -e "print(require(\"singbox.constants\").tag(ARGV[0], ARGV[1]))" "$1" "$2"; }
assert_eq proxy-out "$(tag proxy out)" "outbound tag"
assert_eq proxy-in "$(tag proxy in)" "inbound tag"
assert_eq proxy-domain-resolver "$(tag proxy domain-resolver)" "domain resolver tag"
assert_eq direct-out-1 "$(tag direct out)" "reserved direct outbound tag"
assert_eq bypass-out-1 "$(tag bypass out)" "reserved bypass outbound tag"
assert_eq tproxy6-in-1 "$(tag tproxy6 in)" "reserved IPv6 TProxy inbound tag"
assert_eq service-mixed-in-1 "$(tag service-mixed in)" "reserved service mixed inbound tag"
assert_eq direct-1-out "$(tag direct-1 out)" "numbered direct outbound tag"

printf 'core helpers checks passed\n'
