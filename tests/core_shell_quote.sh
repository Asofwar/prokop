#!/usr/bin/env bash
set -euo pipefail

# core/common.uc shell_quote/shell_command: every value reaches the command
# as exactly one argument, unchanged, and nothing in it is run (UC-219: a
# copy written as "'\''" in ucode, which is three quotes, broke on a quote).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$WORK/check.uc" <<'EOF'
let fs = require("fs"), common = require("core.common");
let values = json(fs.readfile(ARGV[0]));
let failed = 0;
for (let v in values) {
    // printf prints each argument on its own line, NUL-free: one line per value
    // only when the value arrived as one argument.
    let pipe = fs.popen(common.shell_command([ "printf", "%s\\n", v ]) + " 2>&1", "r");
    let out = pipe.read("all");
    pipe.close();
    if (out != v + "\n") { warn(sprintf("value %J came back as %J\n", v, out)); failed++; }
    if (common.shell_quote(v) == null || substr(common.shell_quote(v), 0, 1) != "'") { warn("not quoted\n"); failed++; }
}
exit(failed > 0 ? 1 : 0);
EOF

cat >"$WORK/values.json" <<'EOF'
[ "", "plain", "a'b", "'", "''", "'\\''", "a';touch${IFS}PWNED;'b", "$(touch PWNED)", "`touch PWNED`",
  "a b\tc", "; touch PWNED", "\"double\"", "back\\slash", "*", "-n", "trailing'" ]
EOF

(cd "$WORK" && PROKOP_LIB="$LIB" ucode -L "$LIB" "$WORK/check.uc" "$WORK/values.json") || fail "a value did not reach the command as one argument"
[ ! -e "$WORK/PWNED" ] || fail "a command in a value was run"

echo "core_shell_quote: ok"
