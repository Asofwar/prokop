#!/bin/sh
set -eu

# A component change stops Prokop for the start that follows it; that stop is
# Prokop's own, not the user's (UC-056, D-15(a)).
#
# Before: components/action.uc stopped Prokop through init.d like a user
# would, so a change whose restart failed left Prokop shown as "Stopped by
# user" instead of failed. Now its stops carry PROKOP_STOP_SOURCE=component,
# which init.d records with the stop (tests/user_stop_sticky.sh) and the UI
# state tells apart from the user's (tests/stopped_by_user_state.sh).
#
# The real stop helpers of components/action.uc run against an init.d stand-in
# that records the source it was stopped with.

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
ACTION="$ROOT_DIR/prokop/files/usr/lib/components/action.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

fail() {
  printf 'component_stop_source: FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK_DIR/init.log" ] || sed 's/^/  init.d: /' "$WORK_DIR/init.log" >&2
  exit 1
}

cat >"$WORK_DIR/init" <<'SH'
#!/bin/sh
printf '%s source=%s\n' "$*" "${PROKOP_STOP_SOURCE:-}" >>"$INIT_LOG"
SH
chmod +x "$WORK_DIR/init"

cat >"$WORK_DIR/harness.uc" <<'UCODE'
const SERVICE_INIT = getenv("INIT");
const BIN_PATH = getenv("INIT");
let prokop_was_running = true;
let prokop_stopped_for_sing_box_change = false;
function as_string(value) { return value == null ? "" : "" + value; }
function shell_quote(value) { return "'" + replace(as_string(value), /'/g, "'\\''") + "'"; }
function command_from_args(args) { return join(" ", map(args, shell_quote)); }
function command_success_from_args(args) { return system(command_from_args(args)) == 0; }
function run_logged(description, command) { return system(command) == 0; }
function file_exists(path) { return true; }
function prepare_sing_box_service_disabled() {}
UCODE
source_between "$ACTION" '^function prokop_stop_for_component_change_args\(' '^function wait_prokop_running_after_sing_box_change\(' \
  >>"$WORK_DIR/harness.uc" || fail "the component stop helpers were not found"
cat >>"$WORK_DIR/harness.uc" <<'UCODE'
if (ARGV[0] == "before-change")
    stop_prokop_before_sing_box_change();
else if (ARGV[0] == "after-failed-start")
    command_success_from_args(prokop_stop_for_component_change_args());
UCODE

# The stop before a sing-box package change, and the one after a change whose
# restart failed (the previous variant is then restored, Prokop stays down).
for step in before-change after-failed-start; do
  : >"$WORK_DIR/init.log"
  INIT="$WORK_DIR/init" INIT_LOG="$WORK_DIR/init.log" ucode "$WORK_DIR/harness.uc" "$step" ||
    fail "$step: the harness failed"
  grep -Fxq 'stop source=component' "$WORK_DIR/init.log" ||
    fail "$step: Prokop was not stopped as a component change"
done

printf 'component_stop_source: PASS\n'
