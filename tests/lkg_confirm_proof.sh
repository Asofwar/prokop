#!/bin/sh
set -eu
# CFG-1: a start or reload names as last-known-working only the configuration
# it ran. service/lifecycle.uc passes that configuration (its fingerprint,
# without the shutdown_correctly lines) in a private proof file;
# config/snapshots.uc confirm-working reads the configuration once under its
# lock and snapshots that content only while it equals the proof. A Save &
# Apply after the reload checked its configuration is never confirmed.
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
confirm() { ucode -L "$LIB" "$SCRIPT" confirm-working "$@" > "$WORK/answer.json" 2>/dev/null || true; }
field() { node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1]));console.log(a[process.argv[2]] ?? "")' "$WORK/answer.json" "$1"; }
lkg_content() {
  id="$(cat "$PROKOP_SNAPSHOT_DIR/last-known-working" 2>/dev/null || true)"
  [ -n "$id" ] || { echo; return; }
  node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).content)' "$PROKOP_SNAPSHOT_DIR/$id.json"
}

ran="config settings 'settings'
	option dns_server '1.1.1.1'
"
printf '%s' "$ran" > "$PROKOP_CONFIG_FILE"
printf '%s' "$ran" > "$WORK/proof"

# 1. Control: the configuration is the one the reload ran.
confirm lifecycle "$WORK/proof"
[ "$(field status)" = confirmed ] || fail "the proven configuration was not confirmed: $(cat "$WORK/answer.json")"
[ "$(lkg_content)" = "$(printf '%s' "$ran")" ] || fail "last-known-working is not the proven configuration"

# 2. The service's own shutdown_correctly line is no edit.
printf "%s\toption shutdown_correctly '1'\n" "$ran" > "$PROKOP_CONFIG_FILE"
confirm lifecycle "$WORK/proof"
[ "$(field status)" = confirmed ] || fail "shutdown_correctly counted as an edit: $(cat "$WORK/answer.json")"
first="$(cat "$PROKOP_SNAPSHOT_DIR/last-known-working")"

# 3. Save & Apply landed after the reload checked its configuration: nothing
#    unproven becomes last-known-working.
printf "%s\toption dns_server '9.9.9.9'\n" "$ran" > "$PROKOP_CONFIG_FILE"
confirm lifecycle "$WORK/proof"
[ "$(field status)" = not_confirmed ] || fail "an edit made after the reload was confirmed: $(cat "$WORK/answer.json")"
[ "$(field reason)" = config_changed ] || fail "wrong reason: $(cat "$WORK/answer.json")"
[ "$(cat "$PROKOP_SNAPSHOT_DIR/last-known-working")" = "$first" ] || fail "last-known-working moved to the unproven edit"
lkg_content | grep -q 9.9.9.9 && fail "last-known-working holds the unproven edit"

# 4. No proof: fail closed.
confirm lifecycle "$WORK/missing"
[ "$(field reason)" = proof_unavailable ] || fail "a missing proof was not refused: $(cat "$WORK/answer.json")"

# 5. The lifecycle writes the proof privately and removes it.
grep -q 'fs.open(proof, "wx", 0600)' "$LIB/service/lifecycle.uc" || fail "the proof is not written 0600"
grep -q '"confirm-working", "lifecycle", proof' "$LIB/service/lifecycle.uc" || fail "the lifecycle does not pass its proof"

echo "lkg_confirm_proof: OK"
