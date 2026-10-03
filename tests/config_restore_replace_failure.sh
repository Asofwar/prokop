#!/bin/sh
set -eu

# Config restore whose configuration write fails. No reload runs, so nothing
# proves a coherent runtime: a restore guard left by an earlier needs_attention
# restore (reused through ensure semantics) stays active. Only a guard this
# restore installed itself may be released again, restoring the state from
# before the call.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REAL_UCODE="$(command -v ucode)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The replacement is written next to the configuration as
# "<name>.<sec>.<nsec>.tmp": with a 250-character name that exceeds NAME_MAX,
# so the write fails for any user while reading the configuration still works.
NAME="$(printf 'f%.0s' $(seq 1 250))"
mkdir -p "$WORK/bin" "$WORK/run" "$WORK/etc" "$WORK/state"
export PROKOP_CONFIG_FILE="$WORK/etc/$NAME"
export PROKOP_SNAPSHOT_DIR="$WORK/snapshots"
# Changes staged with uci refuse a restore (UC-068): the test has its own
# save directory, never the host's /tmp/.uci.
export PROKOP_UCI_SAVEDIR="$WORK/uci-save"
export PROKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export PROKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export PROKOP_LIB="$LIB"
export PROKOP_RELOAD_COMMAND="$WORK/reload"
export PROKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export PROKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
# Real history records (snapshot creation) stay out of /etc/prokop and /run/prokop.
export PROKOP_HISTORY_FILE="$WORK/history.jsonl"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export STATE="$WORK/state"

# Guard model (absent | valid) with the real contracts of the state query,
# ensure (reuse valid, create absent) and remove.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    guard="$(cat "$STATE/guard")"
    echo "$4:$guard" >> "$STATE/events"
    case "$4" in
      dpi-transition-guard-state) echo "$guard"; exit 0 ;;
      ensure-dpi-transition-guard) echo valid > "$STATE/guard"; exit 0 ;;
      remove-dpi-transition-guard) echo absent > "$STATE/guard"; exit 0 ;;
    esac
    exit 1 ;;
  */config/validator.uc) echo validate >> "$STATE/events"; exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
esac
exit 0
STUB
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
echo "reload:$*" >> "$STATE/events"
exit 0
STUB
chmod +x "$WORK/bin/ucode" "$WORK/reload"

config() { printf "config settings 'settings'\n option marker '%s'\n" "$1" > "$PROKOP_CONFIG_FILE"; }
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=r[process.argv[2]];console.log(v===undefined?"":v)' "$WORK/result.json" "$1"; }
restore() { # restore <initial guard>
  echo "$1" > "$STATE/guard"; : > "$STATE/events"
  PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$good_id" > "$WORK/result.json" || true
}

config good
good_id="$("$REAL_UCODE" -L "$LIB" "$SCRIPT" create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
[ -n "$good_id" ] || fail "fixture: target snapshot not created"
config bad
echo "stale" > "$PROKOP_SNAPSHOT_DIR/last-known-working"

# 1. The guard of an earlier needs_attention restore is still active: the
#    failed write changes nothing and the guard stays.
restore valid
[ "$(cat "$STATE/guard")" = valid ] || fail "a guard protecting an unproven runtime was removed without a reload: $(tr '\n' ' ' < "$STATE/events")"
[ "$(field status)" = failed ] || fail "inherited guard: $(cat "$WORK/result.json")"
[ "$(field reason)" = replace_failed ] || fail "inherited guard: $(cat "$WORK/result.json")"
[ "$(field guard)" = active ] || fail "inherited guard: result does not name the active guard: $(cat "$WORK/result.json")"
! grep -q '^remove-dpi-transition-guard' "$STATE/events" || fail "inherited guard: remove requested"
! grep -q '^reload:' "$STATE/events" || fail "inherited guard: a reload ran"
grep -q "marker 'bad'" "$PROKOP_CONFIG_FILE" || fail "inherited guard: configuration changed"
[ "$(cat "$PROKOP_SNAPSHOT_DIR/last-known-working")" = stale ] || fail "inherited guard: last-known-working moved"
grep -q '^health:restore:failure$' "$STATE/events" || fail "inherited guard: failure not recorded"

# 2. No guard before the restore: the guard it installed is released again,
#    so the failed restore leaves the state it found.
restore absent
[ "$(field status)" = failed ] || fail "own guard: $(cat "$WORK/result.json")"
[ "$(field reason)" = replace_failed ] || fail "own guard: $(cat "$WORK/result.json")"
[ "$(cat "$STATE/guard")" = absent ] || fail "own guard left installed after a failed write"
grep -q '^ensure-dpi-transition-guard:absent$' "$STATE/events" || fail "own guard: not installed"
! grep -q '^reload:' "$STATE/events" || fail "own guard: a reload ran"
grep -q "marker 'bad'" "$PROKOP_CONFIG_FILE" || fail "own guard: configuration changed"
[ "$(cat "$PROKOP_SNAPSHOT_DIR/last-known-working")" = stale ] || fail "own guard: last-known-working moved"

printf 'config_restore_replace_failure: PASS\n'
