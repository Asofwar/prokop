#!/usr/bin/env bash
# musl's regcomp, which ucode uses on OpenWrt, refuses a repeat count above
# RE_DUP_MAX (255): such a pattern is a runtime "Syntax error" on the router
# while a glibc build accepts it. No pattern of Prokop's may use one.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

found="$(grep -rnoE '\{[0-9]*,?[0-9]*\}' --include='*.uc' "$ROOT_DIR/prokop/files" "$ROOT_DIR/luci-app-prokop" 2>/dev/null |
  awk -F: '{ n = $NF; gsub(/[{}]/, "", n); split(n, b, ","); if (b[1] + 0 > 255 || b[2] + 0 > 255) print }' || true)"
if [ -n "$found" ]; then
  printf 'FAIL: a regex repeat count above 255 fails on musl:\n%s\n' "$found" >&2
  exit 1
fi
printf 'ucode_regex_repeat_limit: PASS\n'
