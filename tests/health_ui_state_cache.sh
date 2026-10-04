#!/usr/bin/env bash
set -euo pipefail
# Optimization 2 of the 2026-10-04 audit: the health poll (every 10 s) reuses
# the UI state an open page asked for within the last 3 seconds instead of
# running the whole get-ui-state chain again.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
UCODE_BIN="$(command -v ucode)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK/bin" "$WORK/ui" "$WORK/run"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/ucode.log"\nexec "%s" "$@"\n' "$WORK" "$UCODE_BIN" >"$WORK/bin/ucode"
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/nft"
cp "$WORK/bin/nft" "$WORK/bin/ubus"
chmod +x "$WORK/bin/ucode" "$WORK/bin/nft" "$WORK/bin/ubus"
export PATH="$WORK/bin:$PATH" PROKOP_LIB="$LIB" PROKOP_UI_STATE_DIR="$WORK/ui" PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_HISTORY_FILE="$WORK/history.jsonl" PROKOP_RELOAD_LOCK_DIR="$WORK/reload.lock"
export PROKOP_OPKG_RECOVERY_DIR="$WORK/opkg" PROKOP_SNAPSHOT_LOCK_DIR="$WORK/snapshot.lock"
export PROKOP_UCI_STATE_FILE="$WORK/uci.state"
printf 'prokop.settings=settings\n' >"$PROKOP_UCI_STATE_FILE"

health() {
  : >"$WORK/ucode.log"
  "$UCODE_BIN" -L "$LIB" "$LIB/diagnostics/health.uc" get
}

printf '%s' '{"service":{"prokop":{"running":1,"enabled":1,"status":"running","dns_configured":1},"sing_box":{"running":1}},"actions":{"service":[]}}' >"$WORK/ui/current.json"
fresh="$(health)" || fail "health get failed"
! grep -q 'service/ui\.uc' "$WORK/ucode.log" || fail "a fresh UI state was asked for again"
printf '%s' "$fresh" | grep -q '"status"' || fail "no health answer: $fresh"

touch -d '-10 seconds' "$WORK/ui/current.json"
health >/dev/null || fail "health get failed"
grep -q 'service/ui\.uc get-ui-state' "$WORK/ucode.log" || fail "a stale UI state must be asked for again"

rm -f "$WORK/ui/current.json"
printf 'not json' >"$WORK/ui/current.json"
health >/dev/null || fail "health get failed"
grep -q 'service/ui\.uc get-ui-state' "$WORK/ucode.log" || fail "a broken UI state file must be ignored"
echo "health_ui_state_cache: OK"
