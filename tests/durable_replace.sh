#!/usr/bin/env bash
# Critical files on flash are replaced durably (UC-025). A rename alone is
# not enough on UBIFS: it reaches the flash within seconds, the data of the
# new file only with the write-back, so a power cut in between leaves the
# file empty. The new content is complete in a temporary file next to the
# file and flushed (sync) before the rename makes it the file, and the
# rename is flushed right after it (core/durable.uc). The writers: the
# configuration a snapshot restore writes, the snapshots, the
# last-known-working pointer, the autotune apply record, the autotune state
# and the rotated history journal (the kill-switch files:
# killswitch_durable.sh). A write that cannot be flushed, or that a full
# filesystem cut short, fails and leaves the old file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
REAL_UCODE="$(command -v ucode)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/sync" "$WORK/etc" "$WORK/run" "$WORK/uci-save"
# sync: every call keeps a copy of the watched directories ($SYNC_WATCH) as
# they are at that moment in $SYNC_LOG/<n>/; it fails while a file of
# $SYNC_FAIL_GLOB exists.
cat > "$WORK/bin/sync" <<'SH'
#!/bin/sh
n=$(( $(cat "$SYNC_LOG/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$SYNC_LOG/count"
for dir in $SYNC_WATCH; do
  mkdir -p "$SYNC_LOG/$n$dir"
  cp -a "$dir/." "$SYNC_LOG/$n$dir/" 2>/dev/null || true
done
for file in ${SYNC_FAIL_GLOB:-}; do [ ! -e "$file" ] || exit 1; done
exit 0
SH
# The restore guard, the validator and the history of a restore are stand-ins
# (config_snapshots.sh); snapshots.uc itself runs as it is.
cat > "$WORK/bin/ucode" <<'SH'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc) [ "${4:-}" != dpi-transition-guard-state ] || echo absent ;;
esac
exit 0
SH
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/nft"
printf '#!/bin/sh\nexit 0\n' > "$WORK/reload"
chmod +x "$WORK/bin/"* "$WORK/reload"

export PATH="$WORK/bin:$PATH" SYNC_LOG="$WORK/sync" SYNC_WATCH="" SYNC_FAIL_GLOB=""
export PROKOP_LIB="$LIB"
export PROKOP_CONFIG_FILE="$WORK/etc/config/prokop"
export PROKOP_SNAPSHOT_DIR="$WORK/etc/snapshots"
export PROKOP_SNAPSHOT_HASH_DIR="$WORK/run/hash"
export PROKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export PROKOP_UCI_SAVEDIR="$WORK/uci-save"
export PROKOP_RELOAD_COMMAND="$WORK/reload"
export PROKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export PROKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_HISTORY_FILE="$WORK/etc/history/history.jsonl"
export PROKOP_AUTOTUNE_APPLY_STATE="$WORK/etc/autotune-apply.json"
export PROKOP_AUTOTUNE_STATE_FILE="$WORK/etc/autotune/state.json"
export PROKOP_AUTOTUNE_STATE_DIR="$WORK/run/autotune"
export PROKOP_AUTOTUNE_LAST_DIR="$WORK/run/autotune-last"
mkdir -p "$WORK/etc/config"

snapshots() { "$REAL_UCODE" -L "$LIB" "$LIB/config/snapshots.uc" "$@"; }
config() { printf "config settings 'settings'\n\toption marker '%s'\n" "$1" > "$PROKOP_CONFIG_FILE"; }
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],r);console.log(v===undefined||v===null?"":v)' "$1" "$2"; }
watch() { rm -rf "$WORK/sync"; mkdir -p "$WORK/sync"; SYNC_WATCH="$*"; }
sync_count() { cat "$WORK/sync/count" 2>/dev/null || echo 0; }
tmp_of() { compgen -G "$1/$2.*tmp*" >/dev/null; }
# durable FILE LABEL: the present content of FILE was flushed while it was
# complete in a temporary file next to FILE that did not hold it yet, and
# flushed again right after the rename (the next sync), when FILE held it and
# no temporary file of it was left.
durable() {
  local file=$1 label=$2 dir base want n snap tmp before="" after=""
  dir="$(dirname "$file")"; base="$(basename "$file")"; want="$(cat "$file")"
  for ((n = 1; n <= $(sync_count); n++)); do
    snap="$WORK/sync/$n$dir"
    if [ -n "$before" ]; then
      [ -f "$snap/$base" ] && [ "$(cat "$snap/$base")" = "$want" ] && ! tmp_of "$snap" "$base" && after=$n
      break
    fi
    for tmp in "$snap/$base".*tmp*; do
      [ -f "$tmp" ] && [ "$(cat "$tmp")" = "$want" ] || continue
      [ -f "$snap/$base" ] && [ "$(cat "$snap/$base")" = "$want" ] && continue
      before=$n
    done
  done
  [ -n "$before" ] || fail "$label: not flushed to flash while complete in its temporary file, before the rename"
  [ -n "$after" ] || fail "$label: the rename was not flushed to flash right after it"
}

# ---- snapshots, the configuration of a restore, last-known-working ------------
config good
watch "$PROKOP_SNAPSHOT_DIR"
snapshots create manual > "$WORK/create.json"
[ "$(field "$WORK/create.json" status)" = created ] || fail "snapshot: $(cat "$WORK/create.json")"
good_id="$(field "$WORK/create.json" snapshot.id)"
durable "$PROKOP_SNAPSHOT_DIR/$good_id.json" "a new snapshot"
[ "$(stat -c %a "$PROKOP_SNAPSHOT_DIR/$good_id.json")" = 600 ] || fail "a snapshot must stay private"

config bad
printf 'stale\n' > "$PROKOP_SNAPSHOT_DIR/last-known-working"
watch "$(dirname "$PROKOP_CONFIG_FILE")" "$PROKOP_SNAPSHOT_DIR"
snapshots restore "$good_id" > "$WORK/restore.json" || true
[ "$(field "$WORK/restore.json" status)" = success ] || fail "restore: $(cat "$WORK/restore.json")"
grep -q "marker 'good'" "$PROKOP_CONFIG_FILE" || fail "restore: the configuration was not replaced"
durable "$PROKOP_CONFIG_FILE" "the configuration a restore writes"
durable "$PROKOP_SNAPSHOT_DIR/last-known-working" "the last-known-working pointer"
[ "$(cat "$PROKOP_SNAPSHOT_DIR/last-known-working")" = "$good_id" ] || fail "restore: last-known-working was not moved"
[ "$(stat -c %a "$PROKOP_CONFIG_FILE")" = 600 ] || fail "the configuration a restore writes must stay private"

# A configuration that cannot be flushed is never renamed into place: the
# restore fails before its reload and the old file stays.
config bad
before_inode="$(stat -c %i "$PROKOP_CONFIG_FILE")"
watch "$(dirname "$PROKOP_CONFIG_FILE")"
SYNC_FAIL_GLOB="$PROKOP_CONFIG_FILE.*tmp*" snapshots restore "$good_id" > "$WORK/restore-unflushed.json" || true
[ "$(field "$WORK/restore-unflushed.json" status)" = failed ] && [ "$(field "$WORK/restore-unflushed.json" reason)" = replace_failed ] ||
  fail "an unflushed configuration: $(cat "$WORK/restore-unflushed.json")"
grep -q "marker 'bad'" "$PROKOP_CONFIG_FILE" || fail "an unflushed configuration replaced the old one"
[ "$(stat -c %i "$PROKOP_CONFIG_FILE")" = "$before_inode" ] || fail "an unflushed configuration was renamed into place"
! tmp_of "$(dirname "$PROKOP_CONFIG_FILE")" prokop || fail "an unflushed configuration left its temporary file"

# ---- the autotune apply record -----------------------------------------------
# A plan refused as stale (Prokop stopped by the user) is recorded.
export PROKOP_STOP_REQUESTED_FILE="$WORK/run/stop.requested"
touch "$PROKOP_STOP_REQUESTED_FILE"
hash64="$(printf '%064d' 0)"
cat > "$WORK/plan.json" <<JSON
{"status":"ready","selected":"multisplit","target":{"host":"example.com","ip":"192.0.2.1"},
 "selection":{"confidence":"high"},"owner":{"section":"dpi"},"scope":"group",
 "changes":[{"section":"dpi","option":"nfqws_opt","from":"--a","to":"--b"}],
 "config_hash":"$hash64","candidate_hash":"$hash64"}
JSON
watch "$(dirname "$PROKOP_AUTOTUNE_APPLY_STATE")"
"$REAL_UCODE" -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/apply.json" || true
[ "$(field "$WORK/apply.json" reason)" = service_stopped ] || fail "apply record fixture: $(cat "$WORK/apply.json")"
[ "$(field "$PROKOP_AUTOTUNE_APPLY_STATE" reason)" = service_stopped ] || fail "the refusal was not recorded"
durable "$PROKOP_AUTOTUNE_APPLY_STATE" "the autotune apply record"
cp "$PROKOP_AUTOTUNE_APPLY_STATE" "$WORK/apply-record.before"
SYNC_FAIL_GLOB="$PROKOP_AUTOTUNE_APPLY_STATE.*tmp*" "$REAL_UCODE" -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > /dev/null || true
cmp -s "$PROKOP_AUTOTUNE_APPLY_STATE" "$WORK/apply-record.before" || fail "an unflushed apply record replaced the old one"
! tmp_of "$(dirname "$PROKOP_AUTOTUNE_APPLY_STATE")" autotune-apply.json || fail "an unflushed apply record left its temporary file"
rm -f "$PROKOP_STOP_REQUESTED_FILE"

# ---- the autotune state ------------------------------------------------------
cat > "$WORK/state-write.uc" <<'UC'
let state = require("autotune.state");
let s = state.read();
s.rotation = int(ARGV[0]);
print(state.write(s) ? "written\n" : "failed\n");
UC
state_write() { "$REAL_UCODE" -L "$LIB" "$WORK/state-write.uc" "$1"; }
watch "$(dirname "$PROKOP_AUTOTUNE_STATE_FILE")"
[ "$(state_write 1)" = written ] || fail "autotune state: first write failed"
[ "$(state_write 2)" = written ] || fail "autotune state: second write failed"
[ "$(field "$PROKOP_AUTOTUNE_STATE_FILE" rotation)" = 2 ] || fail "autotune state: not written"
durable "$PROKOP_AUTOTUNE_STATE_FILE" "the autotune state"
[ "$(stat -c %a "$PROKOP_AUTOTUNE_STATE_FILE")" = 600 ] || fail "the autotune state must stay private"
cp "$PROKOP_AUTOTUNE_STATE_FILE" "$WORK/state.before"
[ "$(SYNC_FAIL_GLOB="$PROKOP_AUTOTUNE_STATE_FILE.*tmp*" state_write 3)" = failed ] || fail "an unflushed autotune state must be a failed write"
cmp -s "$PROKOP_AUTOTUNE_STATE_FILE" "$WORK/state.before" || fail "an unflushed autotune state replaced the old one"

# ---- the rotated history journal ---------------------------------------------
mkdir -p "$(dirname "$PROKOP_HISTORY_FILE")"
for i in $(seq 1 200); do printf '{"kind":"reload","status":"success","timestamp":%d}\n' "$i"; done > "$PROKOP_HISTORY_FILE"
watch "$(dirname "$PROKOP_HISTORY_FILE")"
"$REAL_UCODE" -L "$LIB" "$LIB/diagnostics/health.uc" record start success
[ "$(wc -l < "$PROKOP_HISTORY_FILE")" = 150 ] || fail "history: not rotated ($(wc -l < "$PROKOP_HISTORY_FILE") lines)"
durable "$PROKOP_HISTORY_FILE" "the rotated history journal"
for i in $(seq 1 200); do printf '{"kind":"reload","status":"success","timestamp":%d}\n' "$i"; done > "$PROKOP_HISTORY_FILE"
SYNC_FAIL_GLOB="$PROKOP_HISTORY_FILE.*tmp*" "$REAL_UCODE" -L "$LIB" "$LIB/diagnostics/health.uc" record start success || true
[ "$(wc -l < "$PROKOP_HISTORY_FILE")" = 201 ] || fail "an unflushed rotation replaced the journal"
! tmp_of "$(dirname "$PROKOP_HISTORY_FILE")" history.jsonl || fail "an unflushed rotation left its temporary file"

# ---- a full filesystem ---------------------------------------------------------
# fs.writefile reports a small file as written when the filesystem is full
# (stdio writes it on close, whose error is lost): the empty file must never
# replace a snapshot or the configuration. A full tmpfs in a mount namespace.
cat > "$WORK/full.sh" <<'SH'
set -euo pipefail
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
FULL="$WORK/full"
mkdir -p "$FULL"
mount -t tmpfs -o size=64k tmpfs "$FULL"
trap 'umount "$FULL" 2>/dev/null || true' EXIT
export PROKOP_CONFIG_FILE="$FULL/config/prokop" PROKOP_SNAPSHOT_DIR="$FULL/snapshots"
mkdir -p "$FULL/config"
snapshots() { "$REAL_UCODE" -L "$LIB" "$LIB/config/snapshots.uc" "$@"; }
printf "config settings 'settings'\n\toption marker 'good'\n" > "$PROKOP_CONFIG_FILE"
snapshots create manual > "$WORK/full-good.json"
good_id="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).snapshot.id)' "$WORK/full-good.json")"
printf "config settings 'settings'\n\toption marker 'bad'\n" > "$PROKOP_CONFIG_FILE"
cp "$PROKOP_CONFIG_FILE" "$WORK/full-config.before"
head -c 1048576 /dev/zero > "$FULL/fill" 2>/dev/null || true
snapshots create manual > "$WORK/full-create.json" || true
grep -q '"status": *"failed"' "$WORK/full-create.json" || fail "a snapshot written to a full filesystem was reported created: $(cat "$WORK/full-create.json")"
for file in "$PROKOP_SNAPSHOT_DIR"/*; do
  [ -s "$file" ] || fail "a full filesystem left an empty file among the snapshots: ${file##*/}"
done
snapshots restore "$good_id" > "$WORK/full-restore.json" || true
cmp -s "$PROKOP_CONFIG_FILE" "$WORK/full-config.before" || fail "a restore on a full filesystem replaced the configuration with: '$(cat "$PROKOP_CONFIG_FILE")'"
for file in "$PROKOP_SNAPSHOT_DIR"/*; do
  [ -s "$file" ] || fail "a restore on a full filesystem left an empty file among the snapshots: ${file##*/}"
done
SH
export WORK REAL_UCODE LIB
if unshare --mount true 2>/dev/null; then
  unshare --mount bash "$WORK/full.sh" || fail "full filesystem"
elif unshare --user --map-root-user --mount true 2>/dev/null; then
  unshare --user --map-root-user --mount bash "$WORK/full.sh" || fail "full filesystem"
else
  printf 'durable_replace: no mount namespace, the full filesystem cases are skipped\n'
fi

printf 'durable_replace: PASS\n'
