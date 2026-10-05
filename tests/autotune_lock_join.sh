#!/usr/bin/env bash
set -euo pipefail

# The control run of an apply joins the apply's autotune lock (autotune/lock.uc,
# AT-6) with an owner record of its own (AT-11): when the apply dies by
# SIGKILL (OOM, kill -9) while the control runs, the lock stays held by the
# joined run until it ends, and no other operation takes it meanwhile (a new
# tune would tear down the live probe table). The joined run removes only its
# own record; the lock is free once both are gone.
# The real lock.uc; stand-ins at the paths of autotune/apply.uc and
# autotune/isolation.uc in a copy of the library (the lock identifies its
# owners by that command line).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
WORK="$(mktemp -d)"
BG_PIDS=()
cleanup() { owned_kill KILL "${BG_PIDS[@]}" || true; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

LIB="$WORK/lib"
mkdir -p "$LIB/autotune"
for entry in "$ROOT_DIR/prokop/files/usr/lib"/*; do [ "${entry##*/}" = autotune ] || ln -s "$entry" "$LIB/${entry##*/}"; done
for entry in "$ROOT_DIR/prokop/files/usr/lib/autotune"/*; do ln -s "$entry" "$LIB/autotune/${entry##*/}"; done
rm "$LIB/autotune/apply.uc" "$LIB/autotune/isolation.uc"
export PROKOP_LIB="$LIB" PROKOP_AUTOTUNE_STATE_DIR="$WORK/run/autotune" T="$WORK"

# The apply: takes the lock and starts the control run with its record, as
# autotune/apply.uc control_run does, then waits for it.
cat >"$LIB/autotune/apply.uc" <<'UC'
let lock = require("autotune.lock");
if (!lock.acquire()) { print("apply: no lock\n"); exit(1); }
system("PROKOP_AUTOTUNE_LOCK_OWNER='" + lock.record_name() + "' ucode -L " + getenv("PROKOP_LIB") + " " +
    getenv("PROKOP_LIB") + "/autotune/isolation.uc");
lock.release();
UC
# The control run: joins, says so, runs until released, ends by releasing.
cat >"$LIB/autotune/isolation.uc" <<'UC'
let lock = require("autotune.lock"), fs = require("fs"), t = getenv("T");
let joined = lock.acquire();
fs.writefile(t + "/joined", joined ? "joined\n" : "refused\n");
// A joined run never names a record others could join with.
fs.writefile(t + "/joined.record", sprintf("%J\n", lock.record_name()));
while (joined && fs.stat(t + "/release") == null && fs.stat(t) != null) system("sleep 0.05");
lock.release();
UC

held() { ucode -L "$LIB" -e 'print(require("autotune.lock").held() ? "held" : "free");'; }
another() { ucode -L "$LIB" "$LIB/autotune/apply.uc"; }

# ---- the apply dies by SIGKILL while its control runs -----------------------
ucode -L "$LIB" "$LIB/autotune/apply.uc" >/dev/null 2>&1 &
apply=$!
BG_PIDS+=("$apply")
wait_until 20 test -s "$WORK/joined" || fail "the control run did not start"
iso="$(pgrep -f "$LIB/autotune/isolation.uc" | head -n 1 || true)"
[ -z "$iso" ] || BG_PIDS+=("$iso")
[ "$(cat "$WORK/joined")" = joined ] || fail "the control run could not join: $(cat "$WORK/joined")"
[ "$(cat "$WORK/joined.record")" = null ] || fail "a joined run names a record: $(cat "$WORK/joined.record")"
[ "$(find "$PROKOP_AUTOTUNE_STATE_DIR/lock" -name 'owner.*' | wc -l)" = 2 ] || fail "the joined run has no record of its own: $(ls "$PROKOP_AUTOTUNE_STATE_DIR/lock")"
kill -9 "$apply"; wait "$apply" 2>/dev/null || true
if [ -z "$iso" ] || ! kill -0 "$iso" 2>/dev/null; then fail "fixture: the control run died with the apply"; fi
[ "$(held)" = held ] || fail "the lock counts as free while the joined control run is alive"
[ "$(another)" = "apply: no lock" ] || fail "another operation took the lock while the joined control run is alive"
[ "$(find "$PROKOP_AUTOTUNE_STATE_DIR/lock" -name 'owner.*' | wc -l)" = 2 ] || fail "a refused acquire removed a live record"

# ---- the joined run ends: its record goes, the lock is free ------------------
: >"$WORK/release"
gone() { ! kill -0 "$iso" 2>/dev/null; }
wait_until 20 gone || fail "the control run did not end"
[ "$(held)" = free ] || fail "the lock is still held after the joined run ended"
rm -f "$WORK/release" "$WORK/joined"
# The dead apply's record is stale: the next apply takes the lock.
cat >"$LIB/autotune/isolation.uc" <<'UC'
require("fs").writefile(getenv("T") + "/joined", "done\n");
UC
another >/dev/null || fail "the lock stayed taken after both owners were gone"
[ ! -e "$PROKOP_AUTOTUNE_STATE_DIR/lock" ] || fail "the lock outlived its owners: $(ls "$PROKOP_AUTOTUNE_STATE_DIR/lock")"

echo "autotune lock join: OK"
