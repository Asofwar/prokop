#!/usr/bin/env bash
set -euo pipefail

# nfqws tokenises a comma list in place while it parses its options, so a
# process started with "--dpi-desync=fake,multisplit" reads back from
# /proc/<pid>/cmdline as "--dpi-desync=fake" "multisplit". The process identity
# must still know its own process (observed on GL-MT6000: autotune declared such
# a candidate not started and left it running), without matching a process
# whose arguments really differ.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
pid=""
cleanup() {
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A long-lived process that keeps its arguments in /proc/<pid>/cmdline: bash
# waiting on a fifo. cmdline: bash -c <script> <args...>.
mkfifo "$WORK/fifo"
script="read -r _ <'$WORK/fifo'"
# As nfqws leaves it: the comma list of --dpi-desync split into two arguments,
# the comma of another option untouched.
bash -c "$script" --qnum=4603 --dpi-desync=fake multisplit --dpi-desync-split-pos=1,midsld &
pid=$!
for _ in $(seq 100); do
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q -- '--dpi-desync=fake multisplit' && break
    sleep 0.05
done
ucode -L "$LIB" "$LIB/core/pidfile_cli.uc" record "$pid" "$WORK/process.pid" || fail "pid record"

cat >"$WORK/match.uc" <<'EOF'
let identity = require("core.process_identity");
let rest = json(ARGV[1]);
// argv[0] and the script are not what is compared here.
print(identity.matches(ARGV[0], "bash", [ null, "-c", null, ...rest ], ARGV[2] == "exact", true) != "" ? "match" : "no", "\n");
EOF
matches() { ucode -L "$LIB" "$WORK/match.uc" "$WORK/process.pid" "$1" "${2:-exact}"; }

want='["--qnum=4603","--dpi-desync=fake,multisplit","--dpi-desync-split-pos=1,midsld"]'
[ "$(matches "$want")" = match ] || fail "a comma list tokenised in place is the same process"
[ "$(matches '["--qnum=4603","--dpi-desync=fake,multisplit"]' prefix)" = match ] || fail "prefix match with a tokenised comma list"
[ "$(matches '["--qnum=4603","--dpi-desync=fake,multisplit"]')" = no ] || fail "an exact match ignored a missing argument"

[ "$(matches '["--qnum=4603","--dpi-desync=fake,multidisorder","--dpi-desync-split-pos=1,midsld"]')" = no ] ||
    fail "another desync mode matched"
[ "$(matches '["--qnum=4603","--dpi-desync=fake","--dpi-desync-split-pos=1,midsld"]')" = no ] ||
    fail "a shorter mode list matched exactly"
[ "$(matches '["--qnum=4604","--dpi-desync=fake,multisplit","--dpi-desync-split-pos=1,midsld"]')" = no ] ||
    fail "another queue matched"

cat >"$WORK/tokens.uc" <<'EOF'
let identity = require("core.process_identity");
print(sprintf("%J\n", identity.argv_tokens([ "/opt/a,b/nfqws", "--x=1,2", null, "plain" ])));
EOF
[ "$(ucode -L "$LIB" "$WORK/tokens.uc")" = '[ "/opt/a,b/nfqws", "--x=1", "2", null, "plain" ]' ] ||
    fail "argv_tokens: $(ucode -L "$LIB" "$WORK/tokens.uc")"

echo "process_identity_comma_argv: ok"
