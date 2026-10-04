#!/usr/bin/env bash
set -euo pipefail
# Optimization 9 of the 2026-10-04 audit: /usr/bin/prokop starts the module
# of a command directly, not through sh -c, and keeps its exit status.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cp -a "$ROOT_DIR/prokop/files/usr/lib" "$WORK/lib"
cat >"$WORK/lib/autotune/manager.uc" <<'UC'
let fs = require("fs");
let stat = fs.readfile("/proc/self/stat");
let ppid = split(substr(stat, rindex(stat, ")") + 2), " ")[1];
print(fs.readlink("/proc/" + ppid + "/exe"), "\n");
if (getenv("TEST_SIGNAL"))
    system([ "kill", "-TERM", split(stat, " ")[0] ]);
exit(ARGV[0] == "status" ? 7 : 0);
UC
export PROKOP_LIB="$WORK/lib" PROKOP_FULL_UNINSTALL_LOCK="$WORK/full-uninstall.lock"
set +e
out="$(ucode "$ROOT_DIR/prokop/files/usr/bin/prokop" autotune_status 2>&1)"
rc=$?
set -e
[ "$rc" -eq 7 ] || fail "exit status lost: $rc ($out)"
case "$out" in
  */ucode) ;;
  *) fail "the module's parent is not the dispatcher: $out" ;;
esac
set +e
TEST_SIGNAL=1 ucode "$ROOT_DIR/prokop/files/usr/bin/prokop" autotune_status >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 143 ] || fail "a module ended by SIGTERM must give 143, as through a shell: $rc"
echo "cli_dispatch_no_shell: OK"
