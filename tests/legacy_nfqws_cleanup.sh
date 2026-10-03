#!/usr/bin/env bash
set -euo pipefail

# The zapret runtime stops nfqws processes of the legacy runtime, which ran
# a copy of nfqws from <legacy base>/nfq/nfqws as `<that path> --qnum=<n>
# ...`, only by that exact identity: the executable is that file and the
# command line is the one the legacy runtime used (UC-058). A process whose
# command line merely mentions the path (a `tail -f` of its log, a process
# named after it, another binary given the path as an argument) is never
# signalled. The cleanup has one owner, providers/nfqueue/runtime.uc; the
# requirements check of every start no longer carries a copy of it, so the
# zapret start-runtime of every start runs it, also without zapret rules.
#
# On OpenWrt /var is a symlink to /tmp and the kernel reports the executable
# by its resolved path, also for a binary whose directory is already gone:
# the legacy base here is reached through such a symlink.
#
# The zapret runtime, its supervisor and process identity are real; nfqws is
# a stand-in binary.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

actors=()
cleanup() {
  owned_kill KILL "${actors[@]}" || true
  wait 2>/dev/null || true
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/tmpfs/run"
ln -s tmpfs "$WORK_DIR/var"
LEGACY="$WORK_DIR/var/run/zapret-runtime"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/other" "$LEGACY/nfq" "$WORK_DIR/tmp"
zapret_rule() {
  cat >"$WORK_DIR/uci.state" <<UCI
prokop.settings=settings
prokop.dpi=section
prokop.dpi.enabled=$1
prokop.dpi.action=zapret
UCI
}
zapret_rule 1

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB="$LIB"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export ZAPRET_LEGACY_RUNTIME_BASE_DIR="$LEGACY"
export ZAPRET_NFQWS_BIN="$WORK_DIR/bin/nfqws"
export ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/bin/nfqws"
export ZAPRET_STATE_DIR="$WORK_DIR/zapret"
export ZAPRET_PID_DIR="$WORK_DIR/zapret/pid"
export ZAPRET_CHILD_PID_DIR="$WORK_DIR/zapret/child-pid"
export ZAPRET_LOG_DIR="$WORK_DIR/zapret/log"
export ZAPRET_HOSTLIST_DIR="$WORK_DIR/zapret/hostlist"
export ZAPRET_NFQWS_RESPAWN_DELAY=1

# Nothing here may reach the host's syslog.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/syslog"\n' "$WORK_DIR" >"$WORK_DIR/bin/logger"
# BusyBox `ps w`, as on the router: every process with its command line.
cat >"$WORK_DIR/bin/ps" <<'SH'
#!/bin/sh
printf '  PID USER       VSZ STAT COMMAND\n'
for dir in /proc/[0-9]*; do
  command="$(tr '\0' ' ' <"$dir/cmdline" 2>/dev/null)" || continue
  [ -n "$command" ] || continue
  printf '%5s root      1000 S    %s\n' "${dir#/proc/}" "$command"
done
SH
# nfqws stand-in: a real binary, so /proc identity applies; it runs until
# killed.
cat >"$WORK_DIR/nfqws.c" <<'C'
#include <unistd.h>
int main(void) {
  for (;;)
    pause();
}
C
cc -O0 -o "$WORK_DIR/bin/nfqws" "$WORK_DIR/nfqws.c"
chmod +x "$WORK_DIR/bin/"*
cp "$WORK_DIR/bin/nfqws" "$LEGACY/nfq/nfqws"
cp "$WORK_DIR/bin/nfqws" "$WORK_DIR/other/nfqws"
: >"$LEGACY/nfq/nfqws.log"

# The supervisor gets the strategy as an argument after the script; the
# musl getopt of OpenWrt's ucode stops at the script, glibc's only when
# POSIXLY_CORRECT is set.
zapret() { POSIXLY_CORRECT=1 ucode -L "$LIB" "$LIB/providers/zapret/runtime.uc" "$@"; }

started() {
  local pid="$1" exe="$2"
  wait_until 10 process_exec_is "$pid" "$exe" || fail "$3 did not start"
}

# The legacy runtime's nfqws.
"$LEGACY/nfq/nfqws" --qnum=4000 --dpi-desync-fwmark=0x40000000 --filter-tcp=443 &
LEGACY_NFQWS=$!
actors+=("$LEGACY_NFQWS")
started "$LEGACY_NFQWS" nfqws "the legacy nfqws"
# Processes that only mention the legacy path.
tail -f "$LEGACY/nfq/nfqws.log" >/dev/null 2>&1 &
TAIL=$!
actors+=("$TAIL")
started "$TAIL" tail "tail -f of the legacy log"
(exec -a "$LEGACY/nfq/nfqws" sleep 300) &
NAMED=$!
actors+=("$NAMED")
started "$NAMED" sleep "a process named after the legacy binary"
"$WORK_DIR/other/nfqws" --qnum=4000 "$LEGACY/nfq/nfqws" &
OTHER=$!
actors+=("$OTHER")
started "$OTHER" nfqws "another nfqws given the legacy path"

survived() {
  process_running "$1" || fail "$2 was signalled by the legacy nfqws cleanup"
}

# The zapret runtime start stops the legacy nfqws, and only it.
zapret start-runtime >"$WORK_DIR/start.log" 2>&1 ||
  fail "zapret start-runtime failed: $(cat "$WORK_DIR/start.log" "$WORK_DIR/syslog" "$ZAPRET_LOG_DIR"/*.log 2>/dev/null)"
wait_until 10 process_gone "$LEGACY_NFQWS" || fail "the legacy runtime's nfqws was left running"
survived "$TAIL" "tail -f of the legacy log"
survived "$NAMED" "a process named after the legacy binary"
survived "$OTHER" "another binary given the legacy path"
[ ! -e "$LEGACY" ] || fail "the legacy runtime directory was left behind"
zapret stop-runtime >/dev/null 2>&1 || fail "zapret stop-runtime failed"
survived "$OTHER" "another binary given the legacy path (stop)"

# Without zapret rules the start still cleans the legacy runtime up.
zapret_rule 0
legacy_nfqws() {
  mkdir -p "$LEGACY/nfq"
  cp "$WORK_DIR/bin/nfqws" "$LEGACY/nfq/nfqws"
  "$LEGACY/nfq/nfqws" --qnum=4001 --dpi-desync=fake &
  LEGACY_NFQWS=$!
  actors+=("$LEGACY_NFQWS")
  started "$LEGACY_NFQWS" nfqws "the legacy nfqws ($1)"
}
legacy_nfqws "no zapret rules"
zapret start-runtime >"$WORK_DIR/start.log" 2>&1 ||
  fail "zapret start-runtime without rules failed: $(cat "$WORK_DIR/start.log")"
wait_until 10 process_gone "$LEGACY_NFQWS" || fail "the legacy runtime's nfqws was left running without zapret rules"
[ ! -e "$LEGACY" ] || fail "the legacy runtime directory was left behind without zapret rules"

# The legacy directory is already gone under a running nfqws (stop-runtime
# removes it without stopping the process).
legacy_nfqws "directory removed"
rm -rf "$LEGACY"
zapret start-runtime >"$WORK_DIR/start.log" 2>&1 ||
  fail "zapret start-runtime failed: $(cat "$WORK_DIR/start.log")"
wait_until 10 process_gone "$LEGACY_NFQWS" || fail "the legacy nfqws of a removed directory was left running"
survived "$TAIL" "tail -f of the legacy log"
survived "$NAMED" "a process named after the legacy binary"
survived "$OTHER" "another binary given the legacy path"

# One owner: the requirements check of every start carries no copy.
source_refute "config/validator.uc must not carry a second legacy nfqws cleanup" \
  -F 'nfq/nfqws' "$LIB/config/validator.uc"

printf 'legacy_nfqws_cleanup: PASS\n'
