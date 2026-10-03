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
# The in-app Prokop upgrade stops Prokop the same way. Before, its bounded
# stop passed no source: it was the user's explicit stop, which (1.0.28)
# signalled every sing-box, also when a second one made the upgrade refuse
# (UC-213). The upgrade marker it records is removed when the action ends:
# left behind, it turned the user's next Stop into a guarded one (UC-217).
#
# A component stop that is refused (another sing-box makes the ownership of
# the runtime ambiguous) leaves Prokop running untouched. Before, the
# sing-box variant change went on regardless: it moved DNS away from the
# running runtime and stopped Prokop's sing-box while ProkopTable and ip rule
# 105 stayed, and its restart then left Prokop down (the component variant of
# UC-197/UC-215). Now the change fails before it touches anything, and the
# failure does not restart the Prokop it never stopped.
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
[ "$1" != stop ] || exit "${STOP_STATUS:-0}"
SH
chmod +x "$WORK_DIR/init"

cat >"$WORK_DIR/harness.uc" <<'UCODE'
let fs = require("fs");
const SERVICE_INIT = getenv("INIT");
const BIN_PATH = getenv("INIT");
const LIB_DIR = getenv("HARNESS_DIR");
const MANAGED_UPGRADE_SING_BOX_MARKER = getenv("HARNESS_DIR") + "/managed-upgrade-sing-box";
let prokop_was_running = true;
let prokop_stopped_for_sing_box_change = false;
let managed_upgrade_marker_written = false;
function as_string(value) { return value == null ? "" : "" + value; }
function shell_quote(value) { return "'" + replace(as_string(value), /'/g, "'\\''") + "'"; }
function command_from_args(args) { return join(" ", map(args, shell_quote)); }
function command_success_from_args(args) { return system(command_from_args(args)) == 0; }
function command_status(command) { return system(command); }
function run_logged(description, command) { return system(command) == 0; }
function run_logged_status(description, command) { return system(command); }
function file_exists(path) { return true; }
function remove_file(path) { fs.unlink(path); }
function prepare_sing_box_service_disabled() { system("echo 'sing-box service disabled' >>\"$INIT_LOG\""); }
function updates_log(message) {}
function cleanup_tmp_dir() {}
function release_component_lock() {}
// service/state.uc write-managed-upgrade-sing-box-marker
function module_success(args) { return fs.writefile(args[2], "format=1\n") != null; }
UCODE
source_function "$ACTION" prokop_stop_for_component_change_args >>"$WORK_DIR/harness.uc" ||
  fail "prokop_stop_for_component_change_args was not found"
source_between "$ACTION" '^const SING_BOX_CHANGE_STOP_REFUSED = ' '^function wait_prokop_running_after_sing_box_change\(' \
  >>"$WORK_DIR/harness.uc" || fail "the component stop helpers were not found"
for function in upgrade_bounded_stop remove_managed_upgrade_sing_box_marker cleanup_action \
  capture_managed_upgrade_sing_box_marker; do
  source_function "$ACTION" "$function" >>"$WORK_DIR/harness.uc" || fail "$function was not found"
done
cat >>"$WORK_DIR/harness.uc" <<'UCODE'
if (ARGV[0] == "before-change")
    exit(stop_prokop_before_sing_box_change() ? 0 : 3);
else if (ARGV[0] == "before-change-refused") {
    if (stop_prokop_before_sing_box_change())
        exit(3);
    // action_fail restarts Prokop only after a stop that took it down.
    exit(prokop_stopped_for_sing_box_change ? 4 : 0);
}
else if (ARGV[0] == "after-failed-start")
    command_success_from_args(prokop_stop_for_component_change_args());
else if (ARGV[0] == "upgrade-stop")
    upgrade_bounded_stop(SERVICE_INIT);
else if (ARGV[0] == "upgrade-action") {
    capture_managed_upgrade_sing_box_marker();
    if (fs.stat(MANAGED_UPGRADE_SING_BOX_MARKER) == null)
        exit(2);
    cleanup_action();
}
UCODE

# The stop before a sing-box package change, the one after a change whose
# restart failed (the previous variant is then restored, Prokop stays down),
# and the bounded stop before an in-app Prokop upgrade.
for step in before-change after-failed-start upgrade-stop; do
  : >"$WORK_DIR/init.log"
  INIT="$WORK_DIR/init" INIT_LOG="$WORK_DIR/init.log" HARNESS_DIR="$WORK_DIR" ucode "$WORK_DIR/harness.uc" "$step" ||
    fail "$step: the harness failed"
  grep -Fxq 'stop source=component' "$WORK_DIR/init.log" ||
    fail "$step: Prokop was not stopped as a component change"
done

# A refused stop before a sing-box package change: nothing is touched, the
# change fails, and its failure does not restart Prokop.
: >"$WORK_DIR/init.log"
status=0
STOP_STATUS=2 INIT="$WORK_DIR/init" INIT_LOG="$WORK_DIR/init.log" HARNESS_DIR="$WORK_DIR" \
  ucode "$WORK_DIR/harness.uc" before-change-refused || status=$?
[ "$status" -ne 3 ] || fail "a refused stop let the sing-box package change go on"
[ "$status" -ne 4 ] || fail "a refused stop counts as Prokop stopped, so the failed change would restart it"
[ "$status" -eq 0 ] || fail "before-change-refused: the harness failed ($status)"
! grep -q '^restore_dnsmasq' "$WORK_DIR/init.log" || fail "a refused stop moved DNS away from the running Prokop"
! grep -q '^sing-box service disabled' "$WORK_DIR/init.log" ||
  fail "a refused stop stopped and disabled the sing-box service of the running Prokop"
# Every sing-box package change acts on that result.
source_refute_text "a sing-box package change must not go on after a refused stop" \
  -E '^[[:space:]]*stop_prokop_before_sing_box_change\(\);' "$(cat "$ACTION")"

# The upgrade marker that the action recorded does not outlive the action.
INIT="$WORK_DIR/init" INIT_LOG="$WORK_DIR/init.log" HARNESS_DIR="$WORK_DIR" ucode "$WORK_DIR/harness.uc" upgrade-action ||
  fail "upgrade-action: the harness failed"
[ ! -e "$WORK_DIR/managed-upgrade-sing-box" ] ||
  fail "the in-app upgrade left its managed upgrade marker behind"

printf 'component_stop_source: PASS\n'
