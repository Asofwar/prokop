#!/usr/bin/env bash
set -euo pipefail

# The holder of procd's service lock (fd 1000 of /etc/init.d/prokop) applies a
# queued reload by running "init.d reload pending" and waiting for it. rc.common
# takes the same lock in the nested init.d: procd_lock first tries the inherited
# fd 1000 and only opens the lock file anew, and blocks, when that fails. The
# waited-for child must therefore keep fd 1000: closing it makes the child wait
# for a lock its waiting ancestor holds, and every later init.d call queues up
# behind them (observed on OpenWrt 25.12: reload, status and enabled all hung).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
command -v flock >/dev/null || fail "flock is required"

LOCK="$WORK/procd_prokop.lock"
mkdir -p "$WORK/bin" "$WORK/run"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"

# procd_lock of /lib/functions/procd.sh, then the reload itself. bash: dash,
# the /bin/sh of the test hosts, has no multi-digit descriptors (BusyBox ash,
# the /bin/sh of OpenWrt, has them). There "1000>&-" is not a redirection of
# fd 1000 at all: it closes stdout and hands "1000" to init.d as an argument.
cat >"$WORK/init" <<EOF
#!/bin/bash
how=inherited
flock -n 1000 2>/dev/null
if [ "\$?" != "0" ]; then
    how=own
    exec 1000>"$LOCK"
    flock 1000
fi
printf '%s: %s\n' "\$how" "\$*" >>"$WORK/calls"
EOF
chmod +x "$WORK/bin/logger" "$WORK/init"

export PATH="$WORK/bin:$PATH"
export PROKOP_LIB="$LIB" PROKOP_SERVICE_INIT="$WORK/init"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run" PROKOP_RELOAD_LOCK_DIR="$WORK/reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"

# Runs "$@" as the outer init.d does: holding the service lock on fd 1000.
under_service_lock() {
    (
        exec 1000>"$LOCK"
        flock 1000
        timeout 20 "$@"
    )
}

handoff() { # name command...
    local name="$1" status=0
    shift
    : >"$WORK/calls"
    printf 'pending\n' >"$PROKOP_PENDING_RELOAD_FILE"
    under_service_lock "$@" >/dev/null 2>&1 || status=$?
    [ "$status" != 124 ] || fail "$name: the nested init.d waited for the service lock of its own caller"
    [ "$status" = 0 ] || fail "$name: handoff failed with status $status"
    [ "$(cat "$WORK/calls")" = "inherited: reload pending" ] ||
        fail "$name: expected one 'reload pending' under the inherited service lock, got '$(cat "$WORK/calls")'"
    [ ! -e "$PROKOP_PENDING_RELOAD_FILE" ] || fail "$name: the applied request was retained"
}

handoff "initd reload-finish" ucode -L "$LIB" "$LIB/service/initd.uc" reload-finish list-content "" 0 "$$"
handoff "state run-pending-reload" ucode -L "$LIB" "$LIB/service/state.uc" \
    run-pending-reload-if-requested "$PROKOP_PENDING_RELOAD_FILE" "$WORK/init"

# Without an inherited lock the nested init.d takes and releases it itself.
: >"$WORK/calls"
printf 'pending\n' >"$PROKOP_PENDING_RELOAD_FILE"
timeout 20 ucode -L "$LIB" "$LIB/service/state.uc" run-pending-reload-if-requested \
    "$PROKOP_PENDING_RELOAD_FILE" "$WORK/init" >/dev/null 2>&1 || fail "handoff without the service lock failed"
[ "$(cat "$WORK/calls")" = "own: reload pending" ] || fail "handoff without the service lock: got '$(cat "$WORK/calls")'"
flock -n "$LOCK" true || fail "the nested init.d left the service lock held"

echo "pending_reload_procd_lock: ok"
