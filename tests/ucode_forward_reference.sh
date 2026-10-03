#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ucode resolves a name that is not a declared local yet as a global load, and a
# top-level `function name()` declares a local. A call placed above its own
# declaration therefore compiles, passes `ucode -c`, and only raises
# "left-hand side is not a function" when that line actually runs - which for an
# error-recovery path can stay hidden for releases.
cat >"$WORK_DIR/forward.uc" <<'UC'
function caller() { return callee(); }
function callee() { return 1; }
print(caller(), "\n");
UC
ucode -c -o /dev/null "$WORK_DIR/forward.uc" ||
  fail 'a forward reference is expected to compile cleanly'
if ucode "$WORK_DIR/forward.uc" >/dev/null 2>&1; then
  printf 'NOTE: ucode now resolves top-level forward references at runtime.\n'
  printf 'NOTE: the ordering guard below may be relaxed to a style rule.\n'
fi

python3 - "$ROOT_DIR/prokop/files/usr/lib" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
problems = []
for path in sorted(root.rglob('*.uc')):
    lines = path.read_text(encoding='utf-8').split('\n')
    declared = {}
    for number, line in enumerate(lines, 1):
        found = re.match(r'function ([A-Za-z_][A-Za-z0-9_]*)\s*\(', line)
        if found:
            declared.setdefault(found.group(1), number)
    for number, line in enumerate(lines, 1):
        # Truncating at // can only drop a call, never invent one.
        code = line.split('//')[0]
        for name, declaration in declared.items():
            if number >= declaration:
                continue
            if re.search(r'(?<![A-Za-z0-9_$.])' + re.escape(name) + r'\s*\(', code):
                problems.append(
                    '%s:%d: calls %s() declared below at line %d'
                    % (path.relative_to(root), number, name, declaration))

if problems:
    print('Top-level ucode functions must be declared above their first use:')
    for problem in problems:
        print('  ' + problem)
    raise SystemExit(1)
PY

printf 'ucode forward reference checks passed\n'
