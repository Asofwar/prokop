#!/usr/bin/env bash
set -euo pipefail

# `prokop uninstall` is a compatibility alias of full_uninstall (UC-169).
#
# The command once ran service/lifecycle.uc uninstall(): it removed
# /usr/lib/prokop, the init scripts, the CLI and the LuCI files by hand, past
# the package manager, and left the prokop package registered, the feeds of
# the mirror unrestored and torrserver-direct in place. The command name and
# its arity stay, but it has to be the very same path as
# `prokop full_uninstall`.
#
# The real /usr/bin/prokop runs against a library where the removal module
# and the lifecycle are doubles that record their call.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
PROKOP_CLI="$ROOT_DIR/prokop/files/usr/bin/prokop"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Static: the dispatcher routes `uninstall` to the full removal, and the
#    lifecycle no longer has a removal of its own.
grep -Eq '^[[:space:]]*uninstall: \[ "components/uninstall\.uc", "start", 0 \],$' "$PROKOP_CLI" ||
  fail "prokop uninstall must dispatch to the full removal with no arguments"
grep -Eq '^[[:space:]]*full_uninstall: \[ "components/uninstall\.uc", "start", 0 \],$' "$PROKOP_CLI" ||
  fail "prokop full_uninstall must dispatch to the full removal with no arguments"
! grep -Eq '^function uninstall\(|mode == "uninstall"' "$LIB/service/lifecycle.uc" ||
  fail "service/lifecycle.uc still has its own removal"

# 2. Behaviour: both commands reach components/uninstall.uc start, print the
#    same answer and exit the same way; the lifecycle is never called.
FAKE_LIB="$WORK_DIR/lib"
mkdir -p "$FAKE_LIB/components" "$FAKE_LIB/service"
for module in components/uninstall.uc service/lifecycle.uc; do
  cat >"$FAKE_LIB/$module" <<UC
let out = require("fs").open(getenv("EVENTS"), "a");
out.write("$module " + join(" ", ARGV) + "\n");
out.close();
print("{\"success\":true,\"status_url\":\"/prokop-uninstall.test.json\"}\n");
UC
done
export EVENTS="$WORK_DIR/events"

run() {
  : >"$EVENTS"
  rc=0
  PROKOP_LIB="$FAKE_LIB" ucode "$PROKOP_CLI" "$@" >"$WORK_DIR/out" 2>"$WORK_DIR/err" </dev/null || rc=$?
}

run full_uninstall extra
full_rc="$rc"
full_out="$(cat "$WORK_DIR/out")"
[ "$(cat "$EVENTS")" = "components/uninstall.uc start" ] ||
  fail "prokop full_uninstall did not start the full removal: $(cat "$EVENTS")"

run uninstall extra
[ "$(cat "$EVENTS")" = "components/uninstall.uc start" ] ||
  fail "prokop uninstall did not take the full removal: $(cat "$EVENTS")"
[ "$rc" = "$full_rc" ] || fail "prokop uninstall exited $rc where prokop full_uninstall exited $full_rc"
[ "$(cat "$WORK_DIR/out")" = "$full_out" ] || fail "prokop uninstall did not answer like prokop full_uninstall"

# 3. The usage names it as the alias.
run no_such_command
grep -Eq '^ +uninstall +Alias of full_uninstall$' "$WORK_DIR/out" ||
  fail "the usage does not name uninstall as the alias of full_uninstall"

printf 'prokop uninstall alias checks passed\n'
