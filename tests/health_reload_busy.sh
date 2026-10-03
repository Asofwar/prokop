#!/bin/sh
set -eu

# The health record says whether a reload runs (reload.lock held by a live
# owner) or the list update worker does, which ends in one (reload.busy).
# Save & Apply on the Rules and Settings pages (configform.js) takes the
# first reload event newer than the one before the apply as the reload of
# that apply only while no other reload runs or waits: one that runs when
# the page loads may be an earlier apply's, with this one queued behind it.
# A lock that its dead owner left behind, or a record of a dead list worker,
# is no reload.
#
# health.uc, the lock reader and the list worker reader are the real code;
# the UI state and nft are stand-ins. The list worker is a stand-in
# updates.uc that records itself as components/updates.uc does and waits.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT/tests/helpers/owned_processes.sh"
REAL_LIB="$ROOT/prokop/files/usr/lib"
REAL_UCODE="$(command -v ucode)"
WORK="$(mktemp -d)"
holder=""
cleanup() {
  : > "$WORK/release"
  [ -z "$holder" ] || owned_kill TERM "$holder" || true
  [ ! -s "$WORK/worker.pid" ] || owned_kill TERM "$(cat "$WORK/worker.pid")" || true
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

LIB="$WORK/lib"
mkdir -p "$LIB/components" "$WORK/bin" "$WORK/run"
for entry in "$REAL_LIB"/*; do [ "${entry##*/}" = components ] || ln -s "$entry" "$LIB/${entry##*/}"; done
cat > "$LIB/components/updates.uc" <<'UC'
let fs = require("fs");
let identity = require("core.process_identity");
identity.record(getenv("PROKOP_LIST_UPDATE_PID_FILE"), fs.readlink("/proc/self"));
for (let i = 0; i < 1200 && fs.stat(getenv("WORK") + "/release") == null; i++)
    system("sleep 0.05");
UC
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */service/ui.uc) echo '{"service":{"prokop":{"running":1,"status":"running"},"sing_box":{"running":1}}}'; exit 0 ;;
esac
exec "$REAL_UCODE" "$@"
STUB
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/nft"
chmod +x "$WORK/bin/ucode" "$WORK/bin/nft"

export WORK REAL_UCODE PROKOP_LIB="$LIB"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run/prokop"
export PROKOP_RELOAD_LOCK_DIR="$WORK/run/prokop.reload.lock"
export PROKOP_LIST_UPDATE_PID_FILE="$WORK/run/list.pid"
export PROKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export PROKOP_HISTORY_FILE="$WORK/history.jsonl"
export PROKOP_OPKG_RECOVERY_DIR="$WORK/opkg-recovery"

busy() {
  PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$LIB/diagnostics/health.uc" get > "$WORK/health.json" ||
    fail "health get: $(cat "$WORK/health.json")"
  node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(r.reload?.busy)' "$WORK/health.json"
}

[ "$(busy)" = false ] || fail "no reload runs: $(cat "$WORK/health.json")"
ok "no reload, no list update -> reload.busy false"

# A reload holds reload.lock (a record of the previous release: <lock>/pid).
sleep 300 &
holder=$!
mkdir "$PROKOP_RELOAD_LOCK_DIR"
echo "$holder" > "$PROKOP_RELOAD_LOCK_DIR/pid"
[ "$(busy)" = true ] || fail "a reload holds reload.lock: $(cat "$WORK/health.json")"
kill "$holder"; wait "$holder" 2>/dev/null || true; holder=""
[ "$(busy)" = false ] || fail "a lock that its dead owner left counts as a reload"
rm -rf "$PROKOP_RELOAD_LOCK_DIR"
ok "a live reload.lock owner -> reload.busy true; a dead one's lock -> false"

# The list worker runs without reload.lock until its final reload.
"$REAL_UCODE" -L "$LIB" "$LIB/components/updates.uc" &
echo "$!" > "$WORK/worker.pid"
for _ in $(seq 1 100); do [ -s "$PROKOP_LIST_UPDATE_PID_FILE" ] && break; sleep 0.05; done
[ -s "$PROKOP_LIST_UPDATE_PID_FILE" ] || fail "fixture: the list worker did not record itself"
[ "$(busy)" = true ] || fail "the list worker runs: $(cat "$WORK/health.json")"
: > "$WORK/release"; wait "$(cat "$WORK/worker.pid")" 2>/dev/null || true
[ "$(busy)" = false ] || fail "the record of a list worker that ended counts as a reload"
ok "a running list worker -> reload.busy true; its record after it ended -> false"

printf 'health_reload_busy: PASS\n'
