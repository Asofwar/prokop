#!/usr/bin/env bash
set -euo pipefail

# UC-117: the CLI diagnostics print their progress and verdict lines on a
# terminal. nolog() used to test `test -t 1` with stdout redirected to
# /dev/null, so it never printed: `prokop show_config` on a terminal failed
# without a word. Off a terminal (the UI, scripts, pipes) stdout stays the bare
# result the callers parse, and a failure says why on stderr, which the UI
# shows when the command fails.
#
# The terminal is a pty from util-linux script(1).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
RUNTIME_UC="$PROKOP_LIB/diagnostics/runtime.uc"
WORK="$(mktemp -d)"
cleanup() {
  [ -n "${KEEP_WORK:-}" ] || rm -rf "${WORK:?}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v ucode >/dev/null || fail "ucode is required"
command -v node >/dev/null || fail "node is required"
command -v script >/dev/null || fail "script (util-linux) is required for the pty"

export PROKOP_LIB
uci_state="${WORK:?}/uci-state"
printf '%s\n' 'prokop.settings=settings' "prokop.settings.config_path=${WORK:?}/missing-sing-box.json" >"$uci_state"
export PROKOP_UCI_STATE_FILE="$uci_state"

# on_tty OUT MODE ARG...: runs a runtime.uc mode on a pty; its output (the
# pty merges stdout and stderr) goes to OUT, its exit code to RC.
on_tty() {
  local out="$1" command=""
  shift
  printf -v command '%q ' ucode -L "$PROKOP_LIB" "$RUNTIME_UC" "$@"
  set +e
  script -qec "$command" /dev/null </dev/null >"$out" 2>&1
  RC=$?
  set -e
}

# off_tty MODE ARG...: runs it with stdout and stderr in files.
off_tty() {
  set +e
  ucode -L "$PROKOP_LIB" "$RUNTIME_UC" "$@" >"${WORK:?}/stdout" 2>"${WORK:?}/stderr" </dev/null
  RC=$?
  set -e
}

has_escape() {
  grep -q $'\033' "$1"
}

# --- A failure says why ------------------------------------------------------
export PROKOP_CONFIG="${WORK:?}/missing-prokop"

on_tty "${WORK:?}/tty" show-config masked
[ "$RC" -eq 1 ] || fail "show_config without a configuration must fail on a terminal (rc $RC)"
grep -Fq 'Configuration file not found' "${WORK:?}/tty" ||
  fail "show_config on a terminal must say that the configuration is missing"

off_tty show-config masked
[ "$RC" -eq 1 ] || fail "show_config without a configuration must fail off a terminal (rc $RC)"
[ ! -s "${WORK:?}/stdout" ] || fail "a failed show_config must keep stdout empty off a terminal"
grep -Fxq 'Configuration file not found' "${WORK:?}/stderr" ||
  fail "a failed show_config must say why on stderr off a terminal"
has_escape "${WORK:?}/stderr" && fail "the stderr verdict must not carry terminal colours"

on_tty "${WORK:?}/tty" show-sing-box-config masked
[ "$RC" -eq 1 ] || fail "show_sing_box_config without a configuration must fail (rc $RC)"
grep -Fq 'Current sing-box configuration:' "${WORK:?}/tty" ||
  fail "show_sing_box_config must print its progress line on a terminal"
grep -Fq 'Configuration file not found' "${WORK:?}/tty" ||
  fail "show_sing_box_config on a terminal must say that the configuration is missing"

off_tty show-sing-box-config masked
[ "$RC" -eq 1 ] || fail "show_sing_box_config must fail off a terminal (rc $RC)"
[ ! -s "${WORK:?}/stdout" ] || fail "show_sing_box_config must keep stdout empty off a terminal"
grep -Fxq 'Configuration file not found' "${WORK:?}/stderr" ||
  fail "show_sing_box_config must say why on stderr off a terminal"
grep -Fq 'Current sing-box configuration:' "${WORK:?}/stderr" &&
  fail "a progress line is no failure: it must not reach stderr off a terminal"

# A tool that is missing: logread is looked up on PATH.
mkdir -p "${WORK:?}/empty-bin"
ln -s "$(command -v ucode)" "${WORK:?}/empty-bin/ucode"
for tool in sh date test cat; do
  ln -s "$(command -v "$tool")" "${WORK:?}/empty-bin/$tool"
done
PATH="${WORK:?}/empty-bin" off_tty check-logs
[ "$RC" -eq 1 ] || fail "check_logs without logread must fail (rc $RC)"
grep -Fxq 'Error: logread command not found' "${WORK:?}/stderr" ||
  fail "check_logs without logread must say why on stderr off a terminal"

# --- A success keeps stdout to its result off a terminal -------------------------
printf '%s\n' "config settings 'settings'" "	option dns_type 'doh'" >"${WORK:?}/prokop"
export PROKOP_CONFIG="${WORK:?}/prokop"
off_tty show-config masked
[ "$RC" -eq 0 ] || fail "show_config must succeed (rc $RC)"
grep -Fq "option dns_type 'doh'" "${WORK:?}/stdout" || fail "show_config must print the configuration"
has_escape "${WORK:?}/stdout" && fail "show_config off a terminal must not print terminal colours"
[ ! -s "${WORK:?}/stderr" ] || fail "a successful show_config must keep stderr empty"

printf '%s\n' '{"log":{"level":"warn"},"outbounds":[]}' >"${WORK:?}/sing-box.json"
printf '%s\n' 'prokop.settings=settings' "prokop.settings.config_path=${WORK:?}/sing-box.json" >"$uci_state"
off_tty show-sing-box-config masked
[ "$RC" -eq 0 ] || fail "show_sing_box_config must succeed (rc $RC)"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "${WORK:?}/stdout" ||
  fail "show_sing_box_config off a terminal must print bare JSON (the UI parses it)"

on_tty "${WORK:?}/tty" show-sing-box-config masked
[ "$RC" -eq 0 ] || fail "show_sing_box_config must succeed on a terminal (rc $RC)"
grep -Fq 'Current sing-box configuration:' "${WORK:?}/tty" ||
  fail "show_sing_box_config must print its progress line on a terminal"

# --- A report keeps a failure next to its part -------------------------------------
# global_check, which the support report embeds, prints why a part failed in
# place on stdout: the UI shows that stdout, and on stderr the reason would be
# detached from its part (the support report collects itself with 2>&1, where
# stdout is buffered and stderr is not).
ISOLATE=()
if unshare --mount --net --propagation private sh -c 'mount -t tmpfs tmpfs /run' 2>/dev/null; then
  ISOLATE=(unshare --mount --net --propagation private)
elif unshare --user --map-root-user --mount --net --propagation private sh -c 'mount -t tmpfs tmpfs /run' 2>/dev/null; then
  ISOLATE=(unshare --user --map-root-user --mount --net --propagation private)
fi
[ "${#ISOLATE[@]}" -gt 0 ] && ISOLATE+=(sh -c 'mount -t tmpfs tmpfs /run && exec "$@"' sh)
printf '%s\n' 'prokop.settings=settings' "prokop.settings.config_path=${WORK:?}/missing-sing-box.json" >"$uci_state"
set +e
PROKOP_CONFIG="${WORK:?}/missing-prokop" PROKOP_RUNTIME_STATE_DIR="${WORK:?}/run" \
  PROKOP_SYSTEM_INFO_CACHE_FILE="${WORK:?}/system-info.json" \
  "${ISOLATE[@]}" timeout 60 ucode -L "$PROKOP_LIB" "$RUNTIME_UC" global-check masked \
  >"${WORK:?}/stdout" 2>"${WORK:?}/stderr" </dev/null
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "global_check must finish (rc $RC): $(cat "${WORK:?}/stderr")"
grep -A1 -F 'Prokop config' "${WORK:?}/stdout" | grep -Fxq 'Configuration file not found' ||
  fail "global_check must say in place that the Prokop configuration is missing: $(cat "${WORK:?}/stdout")"
grep -Fq 'Configuration file not found' "${WORK:?}/stderr" &&
  fail "global_check must not detach a failure to stderr"

printf 'diagnostics terminal verdict checks passed\n'
