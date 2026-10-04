#!/usr/bin/env bash
set -euo pipefail
# B1: `sing-box check` runs with a soft Go heap limit and an eager GC, so the
# check of a candidate config does not push a small router into the OOM
# killer while the working sing-box still runs.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK/bin"
cat >"$WORK/bin/sing-box" <<SH
#!/bin/sh
printf '%s|%s|%s\n' "\$GOMEMLIMIT" "\$GOGC" "\$*" >"$WORK/seen"
SH
chmod +x "$WORK/bin/sing-box"

PATH="$WORK/bin:$PATH" ucode -L "$LIB" -e '
let common = require("core.common");
exit(system(common.shell_command(common.sing_box_check_args("/tmp/x y.json"))));' || fail "the check did not run"
[ "$(cat "$WORK/seen")" = '32MiB|25|-c /tmp/x y.json check' ] || fail "check environment: $(cat "$WORK/seen")"

# Every check of a configuration goes through it.
for file in singbox/runtime.uc diagnostics/runtime.uc; do
  grep -q 'sing_box_check_args(' "$LIB/$file" || fail "$file runs sing-box check without the memory limit"
done
! grep -rnE '"sing-box", "-c", [a-z_]+, "check"' "$LIB" --include=*.uc | grep -v 'core/common.uc' ||
  fail "a sing-box check without the memory limit is left"
echo "sing_box_check_memlimit: OK"
