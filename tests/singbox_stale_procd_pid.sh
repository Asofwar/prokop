#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
STATE_UC="$PROKOP_LIB/service/state.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=tests/helpers/source_checks.sh
source "$ROOT_DIR/tests/helpers/source_checks.sh"

# procd can keep reporting an exited child for a moment after /proc no longer
# holds any sing-box. Refusing the transition outright there turns a normal
# hand-off into "ownership is ambiguous" and leaves the service down, which
# matters most during a package upgrade. Waiting is safe; signalling the
# reported PID is not, because it may already have been reused.
#
# The scenario needs a genuine process count of 0, so only the procd side gets
# a double. Other tests (possibly running in parallel) start sing-box doubles
# of their own, so the stop runs in a private PID namespace with its own /proc
# where available; without one, a foreign sing-box is a failed precondition.
ISOLATE=()
if unshare --pid --fork --mount-proc true 2>/dev/null; then
  ISOLATE=(unshare --pid --fork --mount-proc)
elif unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
  ISOLATE=(unshare --user --map-root-user --pid --fork --mount-proc)
fi

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/ubus" <<'SH'
#!/usr/bin/env bash
# Report a lingering sing-box PID until the marker file disappears; a marker
# holding a PID names the PID to report.
if [ -e "${STALE_PID_MARKER:?}" ]; then
  pid="$(cat "$STALE_PID_MARKER")"
  printf '{"sing-box":{"instances":{"instance1":{"running":true,"pid":%s}}}}\n' "${pid:-424242}"
else
  printf '{}\n'
fi
SH
cat >"$WORK_DIR/bin/sleep" <<'SH'
#!/usr/bin/env bash
printf 'slept\n' >>"${SLEEP_LOG:?}"
exit 0
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
exit 0
SH
chmod 0755 "$WORK_DIR/bin/"*

REAL_SLEEP="$(command -v sleep)"
export PATH="$WORK_DIR/bin:$PATH"
export STALE_PID_MARKER="$WORK_DIR/stale" SLEEP_LOG="$WORK_DIR/sleep.log" LOGGER_LOG="$WORK_DIR/logger.log"

foreign_sing_box() {
  local exe
  for exe in /proc/[0-9]*/exe; do
    case "$(readlink "$exe" 2>/dev/null)" in
      */sing-box | */'sing-box (deleted)') printf '%s\n' "${exe%/exe}"; return 0 ;;
    esac
  done
  return 1
}

if [ "${#ISOLATE[@]}" -eq 0 ] && pid_dir="$(foreign_sing_box)"; then
  fail "precondition: a sing-box process ($pid_dir) is running and no private PID namespace is available"
fi

run_stop() {
  : >"$SLEEP_LOG"; : >"$LOGGER_LOG"
  "${ISOLATE[@]}" ucode -L "$PROKOP_LIB" "$STATE_UC" stop-managed-sing-box-runtime "${1:-3}"
}

# 1. procd keeps reporting a PID that never clears: fail closed after the
#    timeout rather than pretending the runtime was stopped.
: >"$STALE_PID_MARKER"
if run_stop 3; then
  fail "a procd PID that never clears must not be reported as a completed stop"
fi
grep -q 'timed out waiting for stale procd PID' "$LOGGER_LOG" ||
  fail "the timeout must be logged as a refused controlled transition"
[ "$(wc -l <"$SLEEP_LOG")" -ge 3 ] ||
  fail "the stale-PID wait must actually retry for the configured timeout"

# 2. The stale PID clears: the stop succeeds without touching the reported PID.
rm -f "$STALE_PID_MARKER"
run_stop 3 || fail "a converged runtime must report a successful stop"
[ ! -s "$SLEEP_LOG" ] ||
  fail "an already converged runtime must not wait at all"
grep -q 'Controlled sing-box transition refused' "$LOGGER_LOG" &&
  fail "a converged runtime must not log a refused transition"

# 3. The wait must never signal the PID procd reported: by then it may belong
#    to an unrelated process. procd keeps reporting the PID of a live decoy
#    that is not sing-box; the stop must fail closed and leave it running.
stop_with_reused_pid() {
  : >"$SLEEP_LOG"; : >"$LOGGER_LOG"
  # shellcheck disable=SC2016 # expanded by the inner shell
  "${ISOLATE[@]}" bash -c '
    "$1" 60 &
    decoy=$!
    printf "%s\n" "$decoy" >"$STALE_PID_MARKER"
    rc=0
    ucode -L "$2" "$3" stop-managed-sing-box-runtime 3 || rc=$?
    state="$(sed -n "s/^[0-9]* (.*) \([A-Za-z]\) .*/\1/p" "/proc/$decoy/stat" 2>/dev/null)"
    kill -KILL "$decoy" 2>/dev/null
    wait "$decoy" 2>/dev/null
    printf "%s %s\n" "$rc" "${state:-gone}"
  ' _ "$REAL_SLEEP" "$PROKOP_LIB" "$STATE_UC"
}
result="$(stop_with_reused_pid)"
[ "${result%% *}" != 0 ] ||
  fail "a procd PID now held by an unrelated process must not be reported as a completed stop"
case "${result#* }" in
  [SRD]) ;;
  *) fail "the stale-PID wait must never signal the PID procd reported (decoy state: ${result#* })" ;;
esac
grep -q 'timed out waiting for stale procd PID' "$LOGGER_LOG" ||
  fail "a reused procd PID must be logged as a refused controlled transition"

# A signal on a path the decoy does not exercise stays forbidden as well: the
# whole wait function, however long it grows, holds no kill.
region="$(source_function "$STATE_UC" wait_for_stale_sing_box_service_pid)" || exit 1
source_refute_text "the stale-PID wait must never signal the reported PID" \
  -E '(^|[^a-z_])kill([^a-z_]|$)' "$region"

printf 'stale procd PID checks passed\n'
