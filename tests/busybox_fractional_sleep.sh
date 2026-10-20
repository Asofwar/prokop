#!/usr/bin/env bash
# OpenWrt's busybox sleep takes whole seconds only ("sleep 0.1" fails at
# once): a wait loop that relies on it alone spins without waiting. Every
# fractional sleep of Prokop's falls back to a whole second.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

found="$(grep -rnE 'sleep 0\.[0-9]' "$ROOT_DIR/prokop/files" "$ROOT_DIR/luci-app-prokop" "$ROOT_DIR/install.sh" 2>/dev/null |
  grep -vE 'sleep 0\.[0-9]+ 2>/dev/null \|\| sleep [1-9]' || true)"
if [ -n "$found" ]; then
  printf 'FAIL: a fractional sleep without a whole-second fallback:\n%s\n' "$found" >&2
  exit 1
fi
printf 'busybox_fractional_sleep: PASS\n'
