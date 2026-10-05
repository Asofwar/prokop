#!/usr/bin/env bash
# Old optimization 4: the kill-switch watcher's quiet interval (sing-box
# answers, nothing redirected) is 5 s, half the 10 s it was, so a dead
# sing-box is noticed within about 10 s. A pass without a saved policy
# sleeps exactly that interval.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/ks" "$WORK_DIR/run"
for name in logger nft dig ubus; do
  printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/$name"
done
chmod 0755 "$WORK_DIR/bin/"*

start="$(date +%s%N)"
PATH="$WORK_DIR/bin:$PATH" PROKOP_LIB="$PROKOP_LIB" KILLSWITCH_STATE_DIR="$WORK_DIR/ks" \
  PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" PROKOP_KILLSWITCH_WATCH_ITERATIONS=1 \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/killswitch/runtime.uc" watch || fail "watch failed"
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ "$elapsed_ms" -ge 4500 ] || fail "the quiet pass slept only ${elapsed_ms} ms"
[ "$elapsed_ms" -lt 8000 ] || fail "the quiet pass slept ${elapsed_ms} ms, expected about 5 s"
printf 'killswitch_watch_interval: ok (%d ms)\n' "$elapsed_ms"
