#!/bin/sh
set -eu
# CFG-2: History may not delete a snapshot Prokop still needs. Besides the
# last-known-working one, delete refuses the before-autotune snapshot that
# the recorded autotune apply may still roll back to, and the snapshot Save
# & Apply took until the reload of its change runs. list says which ones are
# protected and why, so the page disables their Delete.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export PROKOP_CONFIG_FILE="$WORK/prokop"
export PROKOP_SNAPSHOT_DIR="$WORK/snapshots"
export PROKOP_UCI_SAVEDIR="$WORK/uci-save"
export PROKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json"
export PROKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export PROKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export PROKOP_LIB="$LIB"
export PROKOP_HISTORY_FILE="$WORK/history.jsonl"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export PROKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
mkdir -p "$WORK/run"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
snap() { ucode -L "$LIB" "$SCRIPT" "$@" 2>/dev/null || true; }
take() {
  printf "config settings 'settings'\n\toption dns_server '%s'\n" "$1" > "$PROKOP_CONFIG_FILE"
  snap create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))'
}
reason_of() { printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).reason ?? ""))'; }
listed() {
  snap list | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const e=JSON.parse(s).find(i=>i.id===process.argv[1]);console.log(e?.protected_reason ?? "")})' "$1"
}

pre="$(take 1.1.1.1)"
applying="$(take 2.2.2.2)"
free="$(take 3.3.3.3)"
printf '{"phase":"applied","mutation":{"section":"youtube","to":"--x"},"pre_snapshot":"%s"}\n' "$pre" > "$PROKOP_AUTOTUNE_APPLY_STATE"
printf '%s\n' "$applying" > "$PROKOP_SNAPSHOT_DIR/apply-snapshot"

[ "$(listed "$pre")" = autotune_rollback_protected ] || fail "list does not mark the autotune rollback snapshot"
[ "$(listed "$applying")" = apply_snapshot_protected ] || fail "list does not mark the Save & Apply snapshot"
[ -z "$(listed "$free")" ] || fail "list marks an ordinary snapshot as protected"

[ "$(reason_of "$(snap delete "$pre")")" = autotune_rollback_protected ] || fail "the autotune rollback snapshot was not refused"
[ -f "$PROKOP_SNAPSHOT_DIR/$pre.json" ] || fail "the autotune rollback snapshot was deleted"
[ "$(reason_of "$(snap delete "$applying")")" = apply_snapshot_protected ] || fail "the Save & Apply snapshot was not refused"
[ -f "$PROKOP_SNAPSHOT_DIR/$applying.json" ] || fail "the Save & Apply snapshot was deleted"
snap delete "$free" | grep -q '"deleted"' || fail "an ordinary snapshot was not deleted"

# A decided apply no longer needs its snapshot: it can go.
printf '{"phase":"rolled_back","mutation":{"section":"youtube","to":"--x"},"pre_snapshot":"%s"}\n' "$pre" > "$PROKOP_AUTOTUNE_APPLY_STATE"
[ -z "$(listed "$pre")" ] || fail "a decided apply still protects its snapshot"
snap delete "$pre" | grep -q '"deleted"' || fail "the snapshot of a decided apply was not deleted"

echo "snapshot_delete_protected: OK"
