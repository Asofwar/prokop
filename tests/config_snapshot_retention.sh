#!/bin/sh
set -eu

# Snapshot retention (D-14 (a)+(b), UC-022, UC-225). The store holds 10
# snapshots here (config/retention.uc, set on the History page), and two
# places are reserved for the automatic safety snapshots: before a restore,
# before Save & Apply (and a reload), before an autotune apply, the
# last-known-working one and a concurrent edit. Manual snapshots stop at
# RETENTION-2 = 8 with a reason the UI names, and nothing ever removes a
# manual snapshot. An automatic snapshot is never refused for room: the
# automatic ones rotate among themselves, oldest first, and never push out
# the last-known-working snapshot, a manual one or one that the running
# operation still needs. An install that already holds 10 manual snapshots
# (taken before the cap) keeps every one of them and still restores, confirms
# the last-known-working configuration and applies autotune. A restore that
# was refused before its transaction started changed nothing and is no
# restore event in the history.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REAL_UCODE="$(command -v ucode)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/state" "$WORK/etc" "$WORK/uci-save"
export PROKOP_CONFIG_FILE="$WORK/etc/prokop"
export PROKOP_SNAPSHOT_DIR="$WORK/snapshots"
export PROKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export PROKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export PROKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json"
export PROKOP_LIB="$LIB"
export PROKOP_BIN="$WORK/bin/prokop"
export PROKOP_RELOAD_COMMAND="$WORK/reload"
export PROKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export PROKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
export PROKOP_LIST_UPDATE_PID_FILE="$WORK/run/list-update.pid"
export PROKOP_HISTORY_FILE="$WORK/history.jsonl"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_UCI_SAVEDIR="$WORK/uci-save"
export STATE="$WORK/state"
export PROKOP_RETENTION_FILE="$WORK/retention.json"
printf '{"history_limit":50,"snapshot_limit":10}\n' > "$PROKOP_RETENTION_FILE"

# The restore guard, validation and the history are recorded, not run; no
# fail-closed guard of a failed lifecycle transition is installed.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    echo "$4" >> "$STATE/events"
    case "$4" in
      dpi-transition-guard-state) echo absent ;;
    esac
    exit 0 ;;
  */config/validator.uc) echo validate >> "$STATE/events"; exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
esac
exit 0
STUB
cat > "$WORK/bin/nft" <<'STUB'
#!/bin/sh
exit 1
STUB
cat > "$WORK/bin/prokop" <<'STUB'
#!/bin/sh
echo test
STUB
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
echo "reload:$*" >> "$STATE/events"
[ "${FAIL_RELOAD:-0}" = 1 ] && exit 1
exit 0
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/nft" "$WORK/bin/prokop" "$WORK/reload"

config() { printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption marker '%s'\n" "$1" > "$PROKOP_CONFIG_FILE"; }
marker() { grep -o "marker '[a-z0-9]*'" "$PROKOP_CONFIG_FILE" | sed "s/marker '\(.*\)'/\1/"; }
hash() { sha256sum "$PROKOP_CONFIG_FILE" | cut -d' ' -f1; }
# snapshots.uc <args>: the answer in result.json, the exit status in $code.
run() {
  : > "$STATE/events"
  code=0
  PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" "$@" > "$WORK/result.json" || code=$?
}
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));let v=r;for(const k of process.argv[2].split("."))v=v==null?v:v[k];console.log(v===undefined||v===null?"":v)' "$WORK/result.json" "$1"; }
answer() { tr -d '\n' < "$WORK/result.json"; }
events() { tr '\n' ' ' < "$STATE/events"; }
lkg() { cat "$PROKOP_SNAPSHOT_DIR/last-known-working"; }
# What the store holds, from the list the UI reads: "<total> <manual>".
store() {
  "$REAL_UCODE" -L "$LIB" "$SCRIPT" list |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s);console.log(r.length+" "+r.filter(x=>x.kind==="manual").length)})'
}
manual_ids() {
  "$REAL_UCODE" -L "$LIB" "$SCRIPT" list |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).filter(x=>x.kind==="manual").map(x=>x.id).sort().join(" ")))'
}
exists() { [ -f "$PROKOP_SNAPSHOT_DIR/$1.json" ]; }
holds() { grep -q "marker '$2'" "$PROKOP_SNAPSHOT_DIR/$1.json"; }

# 1. Manual snapshots stop at RETENTION-2 = 8; the refusal names the limit
#    and changes nothing.
for n in 1 2 3 4 5 6 7 8; do
  config "m$n"; run create manual
  [ "$(field status)" = created ] || fail "manual snapshot $n: $(answer)"
done
manual_before="$(manual_ids)"
config m9; run create manual
[ "$code" != 0 ] && [ "$(field status)" = failed ] && [ "$(field reason)" = manual_limit_reached ] &&
  [ "$(field limit)" = 8 ] && [ "$(field manual)" = 8 ] || fail "ninth manual snapshot: $(answer)"
[ "$(store)" = "8 8" ] && [ "$(manual_ids)" = "$manual_before" ] || fail "the refused manual snapshot changed the store: $(store)"
! grep -q '^health:' "$STATE/events" || fail "a refused manual snapshot was recorded: $(events)"
ok "manual snapshots stop at 8 with manual_limit_reached; nothing is removed or recorded"

# 2. With 8 manual snapshots the automatic ones rotate in the two reserved
#    places; the last-known-working one is never pushed out.
config a1; run confirm-working
[ "$(field status)" = confirmed ] || fail "confirm-working next to 8 manual snapshots: $(answer)"
lkg_a1="$(lkg)"
for n in 2 3 4 5; do
  config "a$n"; run create automatic
  [ "$(field status)" = created ] || fail "automatic snapshot a$n: $(answer)"
  [ "$(store)" = "10 8" ] && exists "$lkg_a1" || fail "automatic snapshot a$n: store $(store), LKG $lkg_a1"
done
target="$(field snapshot.id)"
[ "$(manual_ids)" = "$manual_before" ] || fail "an automatic snapshot removed a manual one"
ok "automatic snapshots rotate among themselves next to 8 manual snapshots; LKG and manual snapshots stay"

# A restore of an automatic snapshot: the pre-restore snapshot is taken
# although only the LKG, the target and manual snapshots are left.
config a6; run restore "$target"
[ "$(field status)" = success ] && [ "$(marker)" = a5 ] && [ "$(lkg)" = "$target" ] ||
  fail "restore next to 8 manual snapshots and LKG: $(answer)"
grep -q '^health:restore:success$' "$STATE/events" || fail "the restore was not recorded: $(events)"
pre=""
for file in "$PROKOP_SNAPSHOT_DIR"/*.json; do
  grep -q '"reason": *"pre-restore"' "$file" && pre="$(basename "$file" .json)"
done
[ -n "$pre" ] && holds "$pre" a6 || fail "no pre-restore snapshot of the replaced configuration"
[ "$(manual_ids)" = "$manual_before" ] && exists "$lkg_a1" || fail "the restore removed a protected snapshot"
# The next automatic snapshot rotates the unprotected automatic ones out,
# oldest first, back to RETENTION.
config a7; run create automatic
[ "$(field status)" = created ] && [ "$(store)" = "10 8" ] && exists "$target" ||
  fail "rotation after the restore: $(answer), store $(store)"
! exists "$lkg_a1" && ! exists "$pre" || fail "former LKG and pre-restore snapshots did not rotate out"
ok "restore next to 8 manual snapshots: pre-restore snapshot taken, history recorded, store back to 10 afterwards"

# An autotune apply next to 8 manual snapshots: the before-autotune snapshot
# survives the confirmation of the candidate, so the rollback still works.
printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption marker 'cand'\n" > "$WORK/candidate"
run apply "$WORK/candidate" "$(hash)"
[ "$(field status)" = success ] && [ "$(marker)" = cand ] || fail "autotune apply next to 8 manual snapshots: $(answer)"
before_autotune="$(field pre_snapshot)"
exists "$before_autotune" && holds "$before_autotune" a7 || fail "no before-autotune snapshot"
run confirm-working autotune "$before_autotune"
[ "$(field status)" = confirmed ] && exists "$before_autotune" && [ "$(lkg)" != "$before_autotune" ] ||
  fail "confirming the candidate removed its before-autotune snapshot: $(answer)"
run restore "$before_autotune" "$(hash)"
[ "$(field status)" = success ] && [ "$(marker)" = a7 ] && [ "$(lkg)" = "$before_autotune" ] ||
  fail "rollback of the autotune apply: $(answer)"
[ "$(manual_ids)" = "$manual_before" ] || fail "autotune removed a manual snapshot"
ok "autotune next to 8 manual snapshots: applied, confirmed and rolled back"

# 3. A restore refused before its transaction started is no history event;
#    one that started and failed still is.
run restore nosuch
[ "$(field status)" = failed ] && [ "$(field reason)" = invalid_snapshot ] || fail "restore of a missing snapshot: $(answer)"
[ ! -s "$STATE/events" ] || fail "a refused restore was recorded or started: $(events)"
mv "$PROKOP_CONFIG_FILE" "$WORK/config.saved"
run restore "$before_autotune"
mv "$WORK/config.saved" "$PROKOP_CONFIG_FILE"
[ "$(field status)" = failed ] && [ "$(field reason)" = config_unavailable ] || fail "restore without a configuration: $(answer)"
[ ! -s "$STATE/events" ] || fail "a refused restore was recorded or started: $(events)"
config a8; export FAIL_RELOAD=1; run restore "$before_autotune"; unset FAIL_RELOAD
[ "$(field status)" = needs_attention ] && [ "$(field started)" = true ] || fail "failed restore: $(answer)"
grep -q '^health:restore:failure$' "$STATE/events" || fail "a restore that started and failed was not recorded: $(events)"
ok "refused restore (missing snapshot, unreadable configuration) not recorded; a started one that failed is"

# Below the cap a manual snapshot is taken again; it pushes out only
# automatic snapshots that nothing protects.
lkg_now="$(lkg)"
victim="${manual_before%% *}"
run delete "$victim"
[ "$(field status)" = deleted ] || fail "delete: $(answer)"
config m10; run create manual
[ "$(field status)" = created ] && [ "$(store)" = "10 8" ] && exists "$lkg_now" ||
  fail "manual snapshot below the cap: $(answer), store $(store)"
ok "a manual snapshot below the cap is taken; LKG stays"

# 4. Upgrade: 10 manual snapshots taken before the cap, the newest of them
#    the last-known-working one. Nothing is removed; safety operations work.
export PROKOP_SNAPSHOT_DIR="$WORK/legacy-snapshots"
node - "$PROKOP_SNAPSHOT_DIR" <<'JS'
const fs = require('node:fs');
const crypto = require('node:crypto');
const dir = process.argv[2];
fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
for (let i = 1; i <= 10; i++) {
  const content = `config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption marker 'm${i}'\n`;
  const id = `${1700000000 + i}_${i}`;
  const snapshot = { id, created_at: 1700000000 + i, kind: 'manual', reason: 'manual',
    config_hash: crypto.createHash('sha256').update(content).digest('hex'), prokop_version: 'old', content };
  fs.writeFileSync(`${dir}/${id}.json`, `${JSON.stringify(snapshot)}\n`, { mode: 0o600 });
}
fs.writeFileSync(`${dir}/last-known-working`, `${1700000000 + 10}_10\n`);
JS
legacy="$(manual_ids)"
[ "$(store)" = "10 10" ] || fail "fixture: $(store)"
config m10

config m11; run create manual
[ "$(field status)" = failed ] && [ "$(field reason)" = manual_limit_reached ] && [ "$(field limit)" = 8 ] &&
  [ "$(field manual)" = 10 ] || fail "manual snapshot over the cap: $(answer)"
[ "$(manual_ids)" = "$legacy" ] || fail "a refused manual snapshot removed one"

config s1; run create automatic
[ "$(field status)" = created ] || fail "Save & Apply snapshot next to 10 manual snapshots: $(answer)"
s1="$(field snapshot.id)"
run confirm-working
[ "$(field status)" = confirmed ] && [ "$(lkg)" = "$s1" ] || fail "confirm-working next to 10 manual snapshots: $(answer)"

run restore 1700000003_3
[ "$(field status)" = success ] && [ "$(marker)" = m3 ] && [ "$(lkg)" = 1700000003_3 ] ||
  fail "restore of a manual snapshot next to 10 manual snapshots: $(answer)"
grep -q '^health:restore:success$' "$STATE/events" || fail "the restore was not recorded: $(events)"
run restore "$s1"
[ "$(field status)" = success ] && [ "$(marker)" = s1 ] && [ "$(lkg)" = "$s1" ] ||
  fail "restore of an automatic snapshot next to 10 manual snapshots: $(answer)"
for n in 2 3 4 5; do
  config "s$n"; run create automatic
  [ "$(field status)" = created ] && [ "$(store)" = "12 10" ] && exists "$s1" ||
    fail "automatic snapshot s$n next to 10 manual snapshots: $(answer), store $(store)"
done
ok "upgrade with 10 manual snapshots: manual refused with the reason; Save & Apply snapshot, LKG and restores work; two automatic places rotate"

run apply "$WORK/candidate" "$(hash)"
[ "$(field status)" = success ] && [ "$(marker)" = cand ] || fail "autotune apply next to 10 manual snapshots: $(answer)"
before_autotune="$(field pre_snapshot)"
run confirm-working autotune "$before_autotune"
[ "$(field status)" = confirmed ] && exists "$before_autotune" || fail "autotune confirmation next to 10 manual snapshots: $(answer)"
run restore "$before_autotune" "$(hash)"
[ "$(field status)" = success ] && [ "$(marker)" = s5 ] && [ "$(lkg)" = "$before_autotune" ] ||
  fail "autotune rollback next to 10 manual snapshots: $(answer)"
config s6; run create automatic
[ "$(field status)" = created ] && [ "$(store)" = "12 10" ] && exists "$before_autotune" ||
  fail "rotation after the autotune rollback: $(answer), store $(store)"
[ "$(manual_ids)" = "$legacy" ] || fail "a manual snapshot taken before the cap was removed"
ok "upgrade with 10 manual snapshots: autotune applied, confirmed and rolled back; no manual snapshot removed"

# The refusal names how many manual snapshots there are, so the page can say
# how many to delete: three here, before a new one is taken.
for n in 1 2; do
  run delete "170000000${n}_$n"
  [ "$(field status)" = deleted ] || fail "delete of manual snapshot $n: $(answer)"
  config "m1$n"; run create manual
  [ "$(field status)" = failed ] && [ "$(field reason)" = manual_limit_reached ] && [ "$(field manual)" = $((10 - n)) ] ||
    fail "manual snapshot with $((10 - n)) manual snapshots: $(answer)"
done
run delete 1700000003_3
config m13; run create manual
[ "$(field status)" = created ] || fail "manual snapshot after three deletions: $(answer)"
ok "upgrade with 10 manual snapshots: the refusal counts them until three are deleted"

# 5. The before-autotune snapshot that a rollback of the recorded autotune
#    apply returns to (autotune/apply.uc) is kept like the last-known-working
#    one while that rollback is still possible: the apply runs (verifying,
#    rolling back), waits for a decision (needs_attention, failed with a
#    rollback left) or applied its candidate, which the operator may still
#    roll back. Automatic snapshots taken meanwhile (a lifecycle reload
#    during the verification, Save & Apply) rotate without it, also next to
#    8 manual snapshots; once the record is decided it rotates as well.
export PROKOP_SNAPSHOT_DIR="$WORK/autotune-snapshots"
apply_record() { # apply_record <phase> <before-autotune snapshot> [more JSON members]
  printf '{"phase":"%s","mutation":{"section":"Dpi","option":"nfqws_opt","from":"a","to":"b"},"pre_snapshot":"%s"%s}\n' \
    "$1" "$2" "${3:-}" > "$PROKOP_AUTOTUNE_APPLY_STATE"
}
for n in 1 2 3 4 5 6 7 8; do config "m$n"; run create manual; done
manual_before="$(manual_ids)"
config base; run confirm-working
[ "$(field status)" = confirmed ] || fail "confirm-working next to 8 manual snapshots: $(answer)"
run apply "$WORK/candidate" "$(hash)"
[ "$(field status)" = success ] || fail "autotune apply next to 8 manual snapshots: $(answer)"
before_autotune="$(field pre_snapshot)"
apply_record verifying "$before_autotune"
# The reload snapshot of the candidate during its verification.
run create automatic
[ "$(field status)" = created ] && exists "$before_autotune" ||
  fail "a reload snapshot during the verification pushed out the before-autotune snapshot: $(answer), store $(store)"
apply_record rolling_back "$before_autotune"
run restore "$before_autotune" "$(hash)"
[ "$(field status)" = success ] && [ "$(marker)" = base ] && [ "$(lkg)" = "$before_autotune" ] ||
  fail "automatic rollback after a reload snapshot during the verification: $(answer)"
ok "a reload snapshot during the verification next to 8 manual snapshots keeps the before-autotune snapshot; the rollback returns to it"

apply_record rolled_back "$before_autotune"
run apply "$WORK/candidate" "$(hash)"
[ "$(field status)" = success ] || fail "second autotune apply: $(answer)"
before_autotune="$(field pre_snapshot)"
n=0
for phase in verifying applied needs_attention failed; do
  extra=""; [ "$phase" != failed ] || extra=',"rollback_available":true'
  apply_record "$phase" "$before_autotune" "$extra"
  for _ in 1 2; do
    n=$((n + 1)); config "v$n"; run create automatic
    [ "$(field status)" = created ] && exists "$before_autotune" ||
      fail "an automatic snapshot pushed out the before-autotune snapshot of a record in phase $phase: $(answer), store $(store)"
  done
done
cp "$WORK/candidate" "$PROKOP_CONFIG_FILE"
run confirm-working autotune "$before_autotune"
[ "$(field status)" = confirmed ] && exists "$before_autotune" || fail "confirmation after the rotation: $(answer)"
apply_record applied "$before_autotune"
config v-edit; run create automatic
cp "$WORK/candidate" "$PROKOP_CONFIG_FILE"
run restore "$before_autotune" "$(hash)"
[ "$(field status)" = success ] && [ "$(marker)" = base ] && [ "$(lkg)" = "$before_autotune" ] ||
  fail "operator rollback of the applied candidate after the rotation: $(answer)"
[ "$(manual_ids)" = "$manual_before" ] || fail "the kept before-autotune snapshot cost a manual snapshot"
ok "the before-autotune snapshot stays while the record verifies, applied, needs attention or failed with a rollback left"

# A decided record keeps nothing: its before-autotune snapshot rotates like
# any other automatic one (here an unprotected one stands in for it).
for phase in rolled_back stale no_change_required failed; do
  config "d-$phase"; run create automatic
  [ "$(field status)" = created ] || fail "automatic snapshot: $(answer)"
  old="$(field snapshot.id)"
  apply_record "$phase" "$old"
  config "e-$phase"; run create automatic
  [ "$(field status)" = created ] && ! exists "$old" ||
    fail "the before-autotune snapshot of a decided record (phase $phase) did not rotate: store $(store)"
done
printf '{"phase":"applied","mutation":null,"pre_snapshot":"%s"}\n' "$(lkg)" > "$PROKOP_AUTOTUNE_APPLY_STATE"
config f1; run create automatic; old="$(field snapshot.id)"
printf '{"phase":"verifying","mutation":null,"pre_snapshot":"%s"}\n' "$old" > "$PROKOP_AUTOTUNE_APPLY_STATE"
config f2; run create automatic
[ "$(field status)" = created ] && ! exists "$old" || fail "a record without a mutation kept a snapshot: store $(store)"
echo 'not json' > "$PROKOP_AUTOTUNE_APPLY_STATE"
config f3; run create automatic
[ "$(field status)" = created ] || fail "an unreadable apply record refused an automatic snapshot: $(answer)"
[ "$(manual_ids)" = "$manual_before" ] || fail "rotation removed a manual snapshot"
rm -f "$PROKOP_AUTOTUNE_APPLY_STATE"
ok "the before-autotune snapshot of a decided record, or of one without a mutation, rotates like the others"

# 6. Save & Apply's snapshot of the configuration before its change (create
#    before-apply) is the restore point of that change, and the page lists
#    the change from it once the reload has run. The reload that applies the
#    change takes its own snapshot right after: that one does not push it
#    out, also next to 8 manual snapshots, whether it was taken anew or is an
#    older snapshot of the same configuration. After that reload snapshot it
#    rotates like any other, and the store returns to its size.
[ "$(store)" = "10 8" ] || fail "fixture: store $(store) before the Save & Apply cases"
config g1; run create before-apply
[ "$(field status)" = created ] && [ "$(field snapshot.reason)" = before-apply ] || fail "Save & Apply snapshot: $(answer)"
pre="$(field snapshot.id)"
config g2; run create automatic
[ "$(field status)" = created ] || fail "the reload's snapshot: $(answer)"
exists "$pre" || fail "the reload's snapshot pushed out the Save & Apply snapshot of the change it applies: store $(store)"
config g3; run create automatic
[ "$(field status)" = created ] && ! exists "$pre" || fail "the Save & Apply snapshot is still kept after its reload: store $(store)"
[ "$(store)" = "10 8" ] || fail "the store did not return to its size: $(store)"
config h1; run create automatic; old="$(field snapshot.id)"
run create before-apply
[ "$(field status)" = existing ] && [ "$(field snapshot.id)" = "$old" ] || fail "Save & Apply on a configuration already stored: $(answer)"
config h2; run create automatic
[ "$(field status)" = created ] || fail "the reload's snapshot: $(answer)"
exists "$old" || fail "the reload's snapshot pushed out the stored snapshot that Save & Apply refers to: store $(store)"
config h3; run create automatic
[ "$(field status)" = created ] && ! exists "$old" && [ "$(store)" = "10 8" ] ||
  fail "the snapshot Save & Apply referred to is still kept after its reload: store $(store)"
[ "$(manual_ids)" = "$manual_before" ] || fail "rotation removed a manual snapshot"
ok "Save & Apply's snapshot survives the reload snapshot of its change next to 8 manual snapshots, then rotates"

printf 'config_snapshot_retention: PASS\n'
