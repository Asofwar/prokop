#!/usr/bin/env bash
set -euo pipefail
# Optimization 7 of the 2026-10-04 audit: check_logs (every 10 s per open
# LuCI tab) pipes logread straight into the renderer, with no mktemp process
# and no copy of the whole log in /tmp, and shows at most the last 500 lines
# since Prokop started.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
RUNTIME_UC="$PROKOP_LIB/diagnostics/runtime.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
export PROKOP_LIB
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho mktemp >>"%s/calls"\nexec /bin/false\n' "$WORK" >"$WORK/bin/mktemp"
{
  printf '#!/bin/sh\n'
  printf 'echo "Sun Oct  4 10:00:00 2026 user.notice prokop: [info] Old run"\n'
  printf 'echo "Sun Oct  4 10:00:01 2026 user.notice prokop: [info] Starting Prokop"\n'
  # shellcheck disable=SC2016 # expanded by the fake logread
  printf 'i=1; while [ $i -le 700 ]; do echo "Sun Oct  4 10:00:02 2026 user.notice prokop: [info] line $i"; echo "Sun Oct  4 10:00:02 2026 daemon.info other: noise $i"; i=$((i+1)); done\n'
} >"$WORK/bin/logread"
chmod +x "$WORK/bin/mktemp" "$WORK/bin/logread"

out="$(PATH="$WORK/bin:$PATH" ucode -L "$PROKOP_LIB" "$RUNTIME_UC" check-logs 2>"$WORK/stderr")" ||
  fail "check_logs failed: $(cat "$WORK/stderr")"
[ ! -e "$WORK/calls" ] || fail "check_logs still runs mktemp"
grep -q '^Showing the last 500 lines since Prokop started$' <<<"$out" || fail "no truncation note"
grep -q 'line 700$' <<<"$out" || fail "last line missing"
grep -q 'line 201$' <<<"$out" || fail "line 201 must be in the last 500"
! grep -q 'line 200$' <<<"$out" || fail "line 200 is older than the last 500"
! grep -q 'noise' <<<"$out" || fail "unrelated lines leaked"
[ "$(printf '%s\n' "$out" | wc -l)" -eq 501 ] || fail "expected the note and 500 lines"

out="$(PATH="$WORK/bin:$PATH" ucode -L "$PROKOP_LIB" "$RUNTIME_UC" check-sing-box-logs 2>/dev/null)" && fail "no sing-box lines must fail"
[ ! -e "$WORK/calls" ] || fail "check_sing_box_logs still runs mktemp"
echo "check_logs_pipe: OK"
