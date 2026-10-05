#!/bin/sh
set -eu

# Retention limits and "Clear" of the History page (config/retention.uc,
# config/snapshots.uc retention|clear, diagnostics/health.uc clear|prune).
# The limits are validated and stored outside the UCI configuration; a
# lowered limit shrinks the journal and the snapshot store at once. Neither
# retention nor "Clear" ever removes a manual snapshot, the last-known-working
# one, the before-autotune one an autotune rollback may return to, Save &
# Apply's snapshot before its reload, nor the pre-restore and concurrent-edit
# snapshots while a restore guard stands (or its state cannot be read). Both
# take the snapshot lock: while a live snapshot operation holds it they
# change nothing. Clearing the journal keeps the runtime events, so a failed
# change still asks for recovery.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
HEALTH="$LIB/diagnostics/health.uc"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT/tests/helpers/owned_processes.sh"
WORK="$(mktemp -d)"
REAL_UCODE="$(command -v ucode)"
holder=""
cleanup() {
  [ -z "$holder" ] || owned_kill TERM "$holder" || true
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM
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
export PROKOP_HISTORY_FILE="$WORK/etc/history.jsonl"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_UCI_SAVEDIR="$WORK/uci-save"
export PROKOP_RETENTION_FILE="$WORK/etc/retention.json"
export STATE="$WORK/state"
export REAL_UCODE
printf absent > "$STATE/guard"

# The restore guard reads its state from $STATE/guard; validation passes;
# health records are logged, its prune runs for real.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    case "$4" in
      dpi-transition-guard-state) cat "$STATE/guard"; echo ;;
    esac
    exit 0 ;;
  */config/validator.uc) exit 0 ;;
  */diagnostics/health.uc)
    [ "$4" = prune ] && exec "$REAL_UCODE" "$@"
    echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
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
[ -z "${RELOAD_SLEEP:-}" ] || { : > "$STATE/reloading"; sleep "$RELOAD_SLEEP"; }
exit 0
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/nft" "$WORK/bin/prokop" "$WORK/reload"

config() { printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption marker '%s'\n" "$1" > "$PROKOP_CONFIG_FILE"; }
run() {
  : > "$STATE/events"
  code=0
  PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" "$@" > "$WORK/result.json" || code=$?
}
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));let v=r;for(const k of process.argv[2].split("."))v=v==null?v:v[k];console.log(v===undefined||v===null?"":v)' "$WORK/result.json" "$1"; }
answer() { tr -d '\n' < "$WORK/result.json"; }
exists() { [ -f "$PROKOP_SNAPSHOT_DIR/$1.json" ]; }
count() { ls "$PROKOP_SNAPSHOT_DIR"/*.json 2>/dev/null | wc -l | tr -d ' '; }
history_json() { "$REAL_UCODE" -L "$LIB" "$HEALTH" history; }
# A snapshot written as the store keeps it: <id> <kind> <reason> <marker>.
put() {
  node - "$PROKOP_SNAPSHOT_DIR" "$@" <<'JS'
const fs = require('node:fs');
const crypto = require('node:crypto');
const [dir, id, kind, reason, marker] = process.argv.slice(2);
fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
const content = `config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption marker '${marker}'\n`;
const snapshot = { id, created_at: Number(id.split('_')[0]), kind, reason,
  config_hash: crypto.createHash('sha256').update(content).digest('hex'), prokop_version: 'test', content };
fs.writeFileSync(`${dir}/${id}.json`, `${JSON.stringify(snapshot)}\n`, { mode: 0o600 });
JS
}

# 1. Limits: defaults without a file, refusals outside the bounds, and the
#    values the History page reads back.
node -e 'const v=JSON.parse(process.argv[1]).retention;if(v.history_limit!==50||v.snapshot_limit!==20||v.manual_snapshot_limit!==18)process.exit(1)' "$(history_json)" ||
  fail "default limits: $(history_json)"
for bad in "19 20" "201 20" "50 5" "50 51" "abc 20" "50 1e1" "-5 20" " 20"; do
  set -- $bad
  run retention "${1:-}" "${2:-}"
  [ "$code" = 1 ] && [ "$(field status)" = failed ] && [ "$(field reason)" = invalid_input ] ||
    fail "retention $bad was accepted: $(answer)"
done
[ ! -e "$PROKOP_RETENTION_FILE" ] || fail "a refused limit was stored"
run retention 20 6
[ "$code" = 0 ] && [ "$(field status)" = saved ] && [ "$(field history_limit)" = 20 ] && [ "$(field snapshot_limit)" = 6 ] ||
  fail "valid limits refused: $(answer)"
node -e 'const v=JSON.parse(process.argv[1]).retention;if(v.history_limit!==20||v.snapshot_limit!==6||v.manual_snapshot_limit!==4)process.exit(1)' "$(history_json)" ||
  fail "stored limits not read back: $(history_json)"
printf '{"history_limit":9999,"snapshot_limit":"7"}\n' > "$PROKOP_RETENTION_FILE"
node -e 'const v=JSON.parse(process.argv[1]).retention;if(v.history_limit!==50||v.snapshot_limit!==20)process.exit(1)' "$(history_json)" ||
  fail "out-of-range stored limits must fall back to the defaults: $(history_json)"
echo 'not json' > "$PROKOP_RETENTION_FILE"
node -e 'const v=JSON.parse(process.argv[1]).retention;if(v.history_limit!==50||v.snapshot_limit!==20)process.exit(1)' "$(history_json)" ||
  fail "an unreadable limits file must fall back to the defaults"
rm -f "$PROKOP_RETENTION_FILE"
ok "limits: defaults 50/20, bounds 20-200 and 6-50 enforced, stored values read back, bad files fall back"

# 2. A lowered snapshot limit shrinks the store at once, oldest automatic
#    snapshots first; manual, last-known-working, before-autotune (rollback
#    still possible), Save & Apply and guarded pre-restore snapshots stay.
put 1700000001_1 manual manual m1
put 1700000002_2 automatic last-known-working lkg
put 1700000003_3 automatic before-autotune ba
put 1700000004_4 automatic before-apply sa
put 1700000005_5 automatic pre-restore pr
put 1700000006_6 automatic concurrent-change cc
for n in 7 8 9 10 11 12 13 14; do put "17000000$(printf %02d "$n")_$n" automatic before-reload "r$n"; done
printf '1700000002_2\n' > "$PROKOP_SNAPSHOT_DIR/last-known-working"
printf '1700000004_4\n' > "$PROKOP_SNAPSHOT_DIR/apply-snapshot"
printf '{"phase":"applied","mutation":{"section":"Dpi","option":"nfqws_opt","from":"a","to":"b"},"pre_snapshot":"1700000003_3"}\n' > "$PROKOP_AUTOTUNE_APPLY_STATE"
printf valid > "$STATE/guard"
config now
[ "$(count)" = 14 ] || fail "fixture: $(count) snapshots"
run retention 50 8
[ "$(field status)" = saved ] && [ "$(field removed_snapshots)" = 6 ] && [ "$(count)" = 8 ] ||
  fail "lowered snapshot limit: $(answer), $(count) left"
for id in 1700000001_1 1700000002_2 1700000003_3 1700000004_4 1700000005_5 1700000006_6 1700000013_13 1700000014_14; do
  exists "$id" || fail "the lowered limit removed $id"
done
ok "lowered snapshot limit: oldest automatic snapshots go, protected and guarded ones stay"

# Nothing removable is left: a limit below what is protected keeps them all.
run retention 50 6
[ "$(field status)" = saved ] && [ "$(field removed_snapshots)" = 2 ] && [ "$(count)" = 6 ] ||
  fail "limit at the protected size: $(answer), $(count) left"
ok "a limit below the protected snapshots removes only what nothing protects"

# 3. Delete and the list name the guard: while it stands (or its state is
#    unknown) a pre-restore or concurrent-edit snapshot cannot be deleted.
run delete 1700000005_5
[ "$code" = 1 ] && [ "$(field reason)" = restore_guard_protected ] && exists 1700000005_5 ||
  fail "delete of a guarded pre-restore snapshot: $(answer)"
printf '' > "$STATE/guard"
run delete 1700000006_6
[ "$code" = 1 ] && [ "$(field reason)" = restore_guard_protected ] && exists 1700000006_6 ||
  fail "delete of a concurrent-edit snapshot with an unknown guard state: $(answer)"
PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" list |
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s);const p=Object.fromEntries(r.map(x=>[x.id,x.protected_reason||""]));if(p["1700000005_5"]!=="restore_guard_protected"||p["1700000006_6"]!=="restore_guard_protected"||p["1700000002_2"]!=="lkg_protected"||p["1700000001_1"]!=="")process.exit(1)})' ||
  fail "the list does not name the guard protection"
ok "a standing or unknown restore guard protects pre-restore and concurrent-edit snapshots from delete"

# 4. Clear: removes every automatic snapshot that nothing protects, keeps
#    manual and protected ones, records snapshot_clear only when something
#    went.
printf valid > "$STATE/guard"
for n in 20 21 22; do put "17000000${n}_$n" automatic before-reload "c$n"; done
run clear
[ "$code" = 0 ] && [ "$(field status)" = cleared ] && [ "$(field removed)" = 3 ] && [ "$(field manual)" = 1 ] &&
  [ "$(field kept)" = 5 ] || fail "clear with a standing guard: $(answer)"
grep -q '^health:snapshot_clear:success$' "$STATE/events" || fail "clear was not recorded"
for id in 1700000001_1 1700000002_2 1700000003_3 1700000004_4 1700000005_5 1700000006_6; do
  exists "$id" || fail "clear removed $id"
done
run clear
[ "$(field removed)" = 0 ] && [ ! -s "$STATE/events" ] || fail "an empty clear was recorded: $(answer)"
# Guard gone, apply decided, Save & Apply reloaded: only the LKG and the
# manual snapshot are left.
printf absent > "$STATE/guard"
printf '{"phase":"rolled_back","mutation":{"section":"Dpi","option":"nfqws_opt","from":"a","to":"b"},"pre_snapshot":"1700000003_3"}\n' > "$PROKOP_AUTOTUNE_APPLY_STATE"
rm -f "$PROKOP_SNAPSHOT_DIR/apply-snapshot"
run clear
[ "$(field removed)" = 4 ] && [ "$(count)" = 2 ] && exists 1700000001_1 && exists 1700000002_2 ||
  fail "clear without protections: $(answer), $(count) left"
ok "clear removes unprotected automatic snapshots only and records it"

# 5. Lock: a live restore holds the snapshot lock; clear and retention
#    change nothing meanwhile.
for n in 30 31; do put "17000000${n}_$n" automatic before-reload "l$n"; done
config locked
rm -f "$STATE/reloading"
RELOAD_SLEEP=3 PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore 1700000030_30 > "$WORK/restore.json" 2>&1 &
holder=$!
n=0
until [ -e "$STATE/reloading" ]; do
  n=$((n + 1)); [ "$n" -lt 200 ] || fail "the restore did not reach its reload"; sleep 0.05
done
before="$(count)"
limits="$(cat "$PROKOP_RETENTION_FILE")"
run clear
[ "$code" = 1 ] && [ "$(field status)" = busy ] && [ "$(count)" = "$before" ] || fail "clear under a held lock: $(answer)"
run retention 20 6
[ "$code" = 1 ] && [ "$(field status)" = busy ] && [ "$(cat "$PROKOP_RETENTION_FILE")" = "$limits" ] || fail "retention under a held lock: $(answer)"
wait "$holder" || true
holder=""
ok "clear and retention refuse while a live snapshot operation holds the lock"

# 6. The journal: a lowered limit prunes it at once; clear leaves one
#    history_clear record and keeps the runtime events, so a failed change
#    still asks for recovery.
: > "$PROKOP_HISTORY_FILE"
i=0
while [ "$i" -lt 45 ]; do
  printf '{"kind":"reload","status":"success","timestamp":%d}\n' "$((i + 100))" >> "$PROKOP_HISTORY_FILE"
  i=$((i + 1))
done
run retention 30 20
[ "$(field status)" = saved ] && [ "$(field removed_events)" = 15 ] && [ "$(wc -l < "$PROKOP_HISTORY_FILE")" = 30 ] ||
  fail "lowered history limit: $(answer), $(wc -l < "$PROKOP_HISTORY_FILE") lines"
head -n 1 "$PROKOP_HISTORY_FILE" | grep -q '"timestamp": *115' || fail "the prune did not keep the newest records"
"$REAL_UCODE" -L "$LIB" "$HEALTH" record reload failure
"$REAL_UCODE" -L "$LIB" "$HEALTH" clear > "$WORK/clear.json"
grep -q '"status": *"cleared"' "$WORK/clear.json" && grep -q '"removed": *31' "$WORK/clear.json" ||
  fail "history clear: $(cat "$WORK/clear.json")"
history_json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s);if(!v.persistent||v.events.length!==1||v.events[0].kind!=="history_clear")process.exit(1)})' ||
  fail "the cleared journal must hold one history_clear record: $(history_json)"
cat > "$WORK/fixture.json" <<'JSON'
{"ui":{"service":{"prokop":{"running":1},"sing_box":{"running":1}}},"events":[{"kind":"reload","status":"failure","timestamp":10},{"kind":"snapshot_clear","status":"success","timestamp":11},{"kind":"history_clear","status":"success","timestamp":12}]}
JSON
"$REAL_UCODE" -L "$LIB" "$HEALTH" fixture "$WORK/fixture.json" |
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s);if(!v.recovery.pending||v.recovery.last_event.kind!=="reload"||v.overall!=="error")process.exit(1)})' ||
  fail "clearing must not hide a failed change from recovery"
grep -q '"kind": *"reload", *"status": *"failure"' "$PROKOP_RUNTIME_STATE_DIR/health-events.json" ||
  fail "history clear dropped the runtime events"
ok "journal: lowered limit prunes at once, clear keeps one record and the runtime events"

# A clear under a held journal lock changes nothing.
LOCK="$PROKOP_RUNTIME_STATE_DIR/history.lock" READY="$WORK/holder.ready" \
  "$REAL_UCODE" -e 'let fs = require("fs"); let f = fs.open(getenv("LOCK"), "a"); f.lock("x"); fs.writefile(getenv("READY"), "1"); sleep(5000);' &
holder=$!
n=0
until [ -e "$WORK/holder.ready" ]; do
  n=$((n + 1)); [ "$n" -lt 200 ] || fail "the journal lock holder did not start"; sleep 0.05
done
before="$(cat "$PROKOP_HISTORY_FILE")"
code=0
PROKOP_HISTORY_LOCK_WAIT_MS=200 "$REAL_UCODE" -L "$LIB" "$HEALTH" clear > "$WORK/clear.json" || code=$?
[ "$code" = 1 ] && grep -q '"status": *"busy"' "$WORK/clear.json" && [ "$(cat "$PROKOP_HISTORY_FILE")" = "$before" ] ||
  fail "history clear under a held lock: $(cat "$WORK/clear.json")"
owned_kill TERM "$holder" || true
wait "$holder" 2>/dev/null || true
holder=""
ok "history clear refuses while another writer holds the journal lock"

printf 'history_retention: PASS\n'
