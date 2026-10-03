#!/bin/sh
set -eu

# A snapshot restore, the autotune apply transaction and autotune/apply.uc
# see a running list update as a lifecycle action, although the list worker
# runs its DNS probe and downloads without reload.lock (UC-057).
#
# While the list worker runs, init.d queues every reload for it (service/
# initd.uc), as when it held reload.lock for the whole update. A restore
# that checked only reload.lock went ahead: it installed the restore guard
# and replaced the configuration, and both its target reload and its
# rollback reload came back queued -> needs_attention with the guard left
# active until the user acted. It must be refused before anything changes,
# as under a live reload.lock owner; the autotune apply transaction must be
# stale, and autotune/apply.uc must report the service action (its
# automatic rollback waits for it). A record that a dead worker left behind
# is no running update.
#
# snapshots.uc, initd.uc, the init.d script and autotune/apply.uc are the
# real code. The list worker is a stand-in updates.uc that records itself
# exactly as components/updates.uc list_update_pid_begin() does and waits.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT/tests/helpers/owned_processes.sh"
REAL_LIB="$ROOT/prokop/files/usr/lib"
REAL_UCODE="$(command -v ucode)"
WORK="$(mktemp -d)"
cleanup() {
  : > "$WORK/release"
  [ ! -s "$WORK/worker.pid" ] || owned_kill TERM "$(cat "$WORK/worker.pid")" || true
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A library with the real modules and the stand-in list worker.
LIB="$WORK/lib"
mkdir -p "$LIB/components"
for entry in "$REAL_LIB"/*; do [ "${entry##*/}" = components ] || ln -s "$entry" "$LIB/${entry##*/}"; done
for entry in "$REAL_LIB"/components/*; do ln -s "$entry" "$LIB/components/${entry##*/}"; done
rm "$LIB/components/updates.uc"
cat > "$LIB/components/updates.uc" <<'UC'
let fs = require("fs");
let identity = require("core.process_identity");
identity.record(getenv("PROKOP_LIST_UPDATE_PID_FILE"), fs.readlink("/proc/self"));
for (let i = 0; i < 1200 && fs.stat(getenv("WORK") + "/release") == null; i++)
    system("sleep 0.05");
UC

export WORK STATE="$WORK/state" REAL_UCODE TEST_LIB="$LIB" REAL_INITD="$ROOT/prokop/files/etc/init.d/prokop"
export PROKOP_LIB="$LIB" PROKOP_BIN="$WORK/bin/prokop"
export PROKOP_CONFIG_FILE="$WORK/prokop"
export PROKOP_SNAPSHOT_DIR="$WORK/snapshots" PROKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
# Changes staged with uci refuse a restore (UC-068): the test has its own
# save directory, never the host's /tmp/.uci.
export PROKOP_UCI_SAVEDIR="$WORK/uci-save"
export PROKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run/prokop"
export PROKOP_PENDING_RELOAD_FILE="$WORK/run/prokop/reload.pending"
export PROKOP_RELOAD_LOCK_DIR="$WORK/run/prokop.reload.lock"
export PROKOP_LIST_UPDATE_PID_FILE="$WORK/run/list.pid"
export PROKOP_RELOAD_COMMAND="$WORK/init.d" PROKOP_SERVICE_INIT="$WORK/init.d"
export PROKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json" PROKOP_AUTOTUNE_STATE_DIR="$WORK/run/autotune"
mkdir -p "$WORK/bin" "$WORK/run/prokop" "$STATE"
echo absent > "$STATE/guard"

# ucode: restore guard, validator and health are modelled, UI state is out of
# scope; everything else is the real code.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    echo "$4:$(cat "$STATE/guard")" >> "$STATE/events"
    case "$4" in
      ensure-dpi-transition-guard) echo valid > "$STATE/guard" ;;
      remove-dpi-transition-guard) echo absent > "$STATE/guard" ;;
      dpi-transition-guard-state) cat "$STATE/guard" ;;
    esac
    exit 0 ;;
  */config/validator.uc) echo validate >> "$STATE/events"; exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
  */service/ui.uc|*/dns/apply.uc) exit 0 ;;
esac
exec "$REAL_UCODE" "$@"
STUB
# No nft tables: no restore guard and no probe path for autotune/apply.uc,
# and no guard kept by a failed lifecycle transition (config/snapshots.uc
# asks for that one table or chain by name).
cat > "$WORK/bin/nft" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "list table"|"list chain") exit 1 ;;
esac
exit 0
STUB
# prokop: the runtime reload records which configuration it loaded.
cat > "$WORK/bin/prokop" <<'STUB'
#!/bin/sh
case "$1" in
  show_version) echo 1.0.26-test ;;
  get_status) echo '{"running":true}' ;;
  reload) echo "runtime-reload:${2:-}:$(grep -o "marker '[a-z]*'" "$PROKOP_CONFIG_FILE")" >> "$STATE/events" ;;
esac
exit 0
STUB
# rc.common stand-in around the real init.d script.
cat > "$WORK/init.d" <<'STUB'
#!/bin/sh
action="$1"; shift
initscript="$REAL_INITD"
. "$REAL_INITD"
PROKOP_LIB="$TEST_LIB"
PROKOP_INITD_UC="$TEST_LIB/service/initd.uc"
[ "$action" = reload ] || exit 1
echo "init.d-reload:${1:-}" >> "$STATE/events"
reload_service "$@"
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/nft" "$WORK/bin/prokop" "$WORK/init.d"
export PATH="$WORK/bin:$PATH"

config() { printf "config settings 'settings'\n option dns_server '1.1.1.1'\n option marker '%s'\n" "$1" > "$PROKOP_CONFIG_FILE"; }
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=r[process.argv[2]];console.log(v===undefined?"":v)' "$1" "$2"; }
snap() { "$REAL_UCODE" -L "$LIB" "$LIB/config/snapshots.uc" "$@"; }
lkg() { cat "$PROKOP_SNAPSHOT_DIR/last-known-working" 2>/dev/null || true; }
snaps() { find "$PROKOP_SNAPSHOT_DIR" -maxdepth 1 -name '*.json' | wc -l; }
chash() { sha256sum "$PROKOP_CONFIG_FILE" | cut -d' ' -f1; }
events() { cat "$STATE/events" 2>/dev/null || true; }
autotune_action() { "$REAL_UCODE" -L "$LIB" "$LIB/autotune/apply.uc" status | grep -o '"service_action": *[a-z_"]*' || true; }
# run <snapshots.uc args...>: result in $WORK/result.json, exit status in $rc.
run() {
  : > "$STATE/events"
  rc=0
  snap "$@" > "$WORK/result.json" || rc=$?
}
expect() { # expect <status> <reason> <what>
  [ "$(field "$WORK/result.json" status)" = "$1" ] || fail "$3: $(cat "$WORK/result.json"); events: $(events)"
  [ -z "$2" ] || [ "$(field "$WORK/result.json" reason)" = "$2" ] || fail "$3: $(cat "$WORK/result.json")"
}
unchanged() { # unchanged <what>
  [ "$(snaps)" = "$before" ] || fail "$1 created a snapshot"
  { [ "$(chash)" = "$base_hash" ] && [ "$(lkg)" = "$base_lkg" ]; } || fail "$1 changed the configuration or last-known-working"
  [ "$(cat "$STATE/guard")" = absent ] || fail "$1 installed the restore guard"
  [ -z "$(events)" ] || fail "$1 acted: $(events)"
  [ ! -e "$PROKOP_PENDING_RELOAD_FILE" ] || fail "$1 queued a reload"
}

# Target snapshot "good"; production runs "bad", confirmed as last-known-working.
config good
good_id="$(snap create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
config good; cp "$PROKOP_CONFIG_FILE" "$WORK/candidate"
config bad
snap confirm-working > /dev/null
base_lkg="$(lkg)"; base_hash="$(chash)"
if [ -z "$base_lkg" ] || [ "$base_lkg" = "$good_id" ]; then fail "fixture: last-known-working not set"; fi

# The list worker, as `prokop list_update` starts it: it downloads and holds
# no reload.lock.
"$REAL_UCODE" -L "$LIB" "$LIB/components/updates.uc" list-update </dev/null >/dev/null 2>&1 &
echo "$!" > "$WORK/worker.pid"
for _ in $(seq 1 200); do [ -s "$PROKOP_LIST_UPDATE_PID_FILE" ] && break; sleep 0.05; done
[ -s "$PROKOP_LIST_UPDATE_PID_FILE" ] || fail "fixture: the list worker did not record itself"
[ ! -e "$PROKOP_RELOAD_LOCK_DIR" ] || fail "fixture: reload.lock is held"

# 1. Restore during the list update: busy, nothing changed.
before="$(snaps)"
run restore "$good_id"
expect busy service_action_in_progress "restore during a list update"
[ "$rc" != 0 ] || fail "busy restore exited 0"
unchanged "restore during a list update"

# 2. The autotune apply transaction during the list update: stale, nothing
#    changed.
run apply "$WORK/candidate" "$base_hash"
expect stale service_action_in_progress "autotune apply during a list update"
unchanged "autotune apply during a list update"

# 3. autotune/apply.uc (its checks and the wait of an automatic rollback).
[ "$(autotune_action)" = '"service_action": "service_action_in_progress"' ] ||
  fail "autotune/apply.uc did not see the list update: '$(autotune_action)'"

# 4. The worker is gone and left its record behind: no service action.
: > "$WORK/release"
worker="$(cat "$WORK/worker.pid")"
for _ in $(seq 1 200); do kill -0 "$worker" 2>/dev/null || break; sleep 0.05; done
! kill -0 "$worker" 2>/dev/null || fail "fixture: the list worker did not exit"
: > "$WORK/worker.pid"
[ -s "$PROKOP_LIST_UPDATE_PID_FILE" ] || fail "fixture: the dead worker's record is gone"
[ "$(autotune_action)" = '"service_action": null' ] ||
  fail "autotune/apply.uc took a dead list worker's record for a service action: '$(autotune_action)'"
run restore "$good_id"
expect success "" "restore after the list update"
[ "$(cat "$STATE/guard")" = absent ] || fail "restore after the list update kept the guard"
[ "$(lkg)" = "$good_id" ] || fail "restore after the list update did not move last-known-working"
events | grep -q "^runtime-reload:config-restore:marker 'good'$" || fail "restore after the list update did not reload: $(events)"

echo "restore_during_list_update: ok"
