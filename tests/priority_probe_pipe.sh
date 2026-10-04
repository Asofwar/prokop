#!/usr/bin/env bash
set -euo pipefail
# Optimization 5 of the 2026-10-04 audit: a Priority probe (every 5 s per
# group) reads the clash-api answer and exit status through a pipe, with no
# mktemp process and no temporary file.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho mktemp >>"%s/calls"\nexec /bin/false\n' "$WORK" >"$WORK/bin/mktemp"
chmod +x "$WORK/bin/mktemp"
cat >"$WORK/diag.uc" <<'UC'
print(sprintf("%J\n", { delay: ARGV[2] == "dead" ? null : 42, args: ARGV }));
exit(ARGV[2] == "fail" ? 2 : 0);
UC
{
  echo 'let fs = require("fs"); let common = require("core.common"); let as_string = common.as_string;'
  echo "const LIB_DIR = \"$LIB\"; const DIAGNOSTICS_UC = \"$WORK/diag.uc\";"
  sed -n '/^function shell_quote(/,/^}/p;/^function command_from_args(/,/^}/p;/^function module_capture(/,/^}/p' "$LIB/singbox/priority.uc"
  cat <<'UC'
let ok = module_capture([ "get_proxy_latency", "alive", "2000" ]);
let bad = module_capture([ "get_proxy_latency", "fail", "2000" ]);
print(ok.status, " ", json(ok.output).delay, " ", bad.status, "\n");
UC
} >"$WORK/t.uc"
grep -q '^function module_capture' "$WORK/t.uc" || fail "fixture: module_capture not found"
out="$(PATH="$WORK/bin:$PATH" ucode -L "$LIB" "$WORK/t.uc")"
[ "$out" = "0 42 2" ] || fail "probe answer or status lost: $out"
[ ! -e "$WORK/calls" ] || fail "a probe still runs mktemp"
echo "priority_probe_pipe: OK"
