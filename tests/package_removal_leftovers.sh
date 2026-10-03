#!/usr/bin/env bash
set -euo pipefail

# A removal judges Prokop's stop by what it left, not by its exit status, and
# never reports success with something of Prokop in place (UC-028).
#
# Before: prerm checked Prokop's interception only when the stop exited
# non-zero. A stop that exited 0 and still left ProkopTable or the fwmark rule
# at priority 105 (rc.common drops the status of stop_service unless a hook
# passes it on; a stop that cannot delete the table or the rule goes on) let
# a removal stop and delete the managed sing-box that served it: the
# interception black-holed traffic until a reboot. Prokop's lines in the
# crontab, the kill-switch and the TorrServer Direct table were never
# checked: a removal that left them reported success.
#
# Now a removal whose package stop left Prokop's interception or its
# scheduled jobs in place stops Prokop again with the explicit stop (no proof
# of ownership needed for its own interception, UC-213), and the managed
# sing-box keeps serving an interception that is still in place. At the end
# a removal checks again, with the kill-switch table and its saved policy and
# the TorrServer Direct table: prerm fails, and the system log (the package
# managers discard prerm's output) says what is left. An upgrade is
# unchanged: a failed stop keeps the runtime (UC-197,
# tests/package_prerm_refused_stop.sh), and the start in postinst brings it
# back after a stop that succeeded.
#
# The real service/package.uc runs against an init.d, nft, ip, logger, a
# crontab and the kill-switch module that record what they are asked to do.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
PACKAGE_UC="$LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  exit 1
}

STATE="$WORK_DIR/state"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$STATE/nft"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS STATE
export PROKOP_LIB="$LIB"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_INIT="$WORK_DIR/prokop-init"
export PROKOP_TORRSERVER_DIRECT_INIT="$WORK_DIR/missing-torrserver-init"
export PROKOP_RC_D_DIR="$WORK_DIR/rc.d"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_DNS_APPLY_UC="$WORK_DIR/dns-apply.uc"
export PROKOP_KILLSWITCH_UC="$WORK_DIR/killswitch.uc"
export PROKOP_SING_BOX_INIT="$WORK_DIR/sing-box-init"
export PROKOP_SING_BOX_BIN="$WORK_DIR/sing-box"
export PROKOP_SING_BOX_CRONET="$WORK_DIR/libcronet.so"
export PROKOP_RT_TABLES="$WORK_DIR/rt_tables"
export PROKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
export PROKOP_CRONTAB_FILE="$WORK_DIR/crontab"
export KILLSWITCH_NFT_POLICY="$WORK_DIR/killswitch-policy.nft"
printf 'prokop.settings=settings\nprokop.settings.dont_touch_dhcp=0\n' >"$PROKOP_UCI_STATE_FILE"

PROKOP_CRON='0 */6 * * * /usr/bin/prokop list_update_if_due # prokop-list-update'
FOREIGN_CRON='0 3 * * * /usr/bin/backup # mine'

# /etc/init.d/prokop: "status" reports a running Prokop. A stop exits 0 and
# takes down Prokop's interception (table, rule) and its scheduled jobs,
# except what $STATE/<source>-leaves names; <source> is "package" for
# Prokop's own stop for the package change and "explicit" otherwise.
cat >"$PROKOP_INIT" <<'SH'
#!/bin/sh
case "$1" in
  status) exit 0 ;;
  stop)
    source=explicit
    [ "${PROKOP_STOP_SOURCE:-}" != package ] || source=package
    printf 'prokop stop %s\n' "$source" >>"$EVENTS"
    leaves="$(cat "$STATE/$source-leaves" 2>/dev/null || true)"
    case "$leaves" in *table*) ;; *) rm -f "$STATE/nft/ProkopTable" ;; esac
    case "$leaves" in *rule*) ;; *) rm -f "$STATE/rule" ;; esac
    case "$leaves" in *cron*) ;; *)
      grep -v '# prokop-' "$PROKOP_CRONTAB_FILE" >"$STATE/cron.new" || true
      mv "$STATE/cron.new" "$PROKOP_CRONTAB_FILE" ;;
    esac
    ;;
esac
exit 0
SH
cat >"$PROKOP_BIN" <<'SH'
#!/bin/sh
printf 'prokop %s\n' "$*" >>"$EVENTS"
SH
cat >"$PROKOP_DNS_APPLY_UC" <<'UC'
system("printf 'dns %s\\n' '" + ARGV[0] + "' >>'" + getenv("EVENTS") + "'");
UC
# The kill-switch release lifts the table and the saved policy unless
# $STATE/killswitch-stays exists.
cat >"$PROKOP_KILLSWITCH_UC" <<'UC'
let fs = require("fs");
system("printf 'killswitch %s\\n' '" + join(" ", ARGV) + "' >>'" + getenv("EVENTS") + "'");
if (ARGV[0] == "release" && fs.stat(getenv("STATE") + "/killswitch-stays") == null) {
    fs.unlink(getenv("STATE") + "/nft/ProkopKillswitch");
    fs.unlink(getenv("KILLSWITCH_NFT_POLICY"));
}
UC
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf 'logger %s\n' "$*" >>"$EVENTS"
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$1" != -t ] || shift
case "$1 $2 $3" in
  "list table inet") [ -e "$STATE/nft/$4" ]; exit $? ;;
esac
exit 1
SH
cat >"$WORK_DIR/bin/ip" <<'SH'
#!/bin/sh
case "$*" in
  "-4 rule show")
    printf '0:\tfrom all lookup local\n'
    [ ! -e "$STATE/rule" ] || printf '105:\tfrom all fwmark 0x4000000/0x4000000 lookup prokop\n'
    printf '32766:\tfrom all lookup main\n'
    ;;
esac
exit 0
SH
chmod +x "$PROKOP_INIT" "$PROKOP_BIN" "$WORK_DIR/bin/"*
command -v apk >/dev/null 2>&1 && fail "the host has apk on PATH; the cases need opkg's behaviour"

# A running Prokop: its table and rule, its scheduled jobs next to another
# program's, the kill-switch with its saved policy, the TorrServer Direct
# table and the managed sing-box.
reset_case() {
  : >"$EVENTS"
  rm -f "$STATE"/*-leaves "$STATE/killswitch-stays" "$PROKOP_PACKAGE_UPGRADE_STATE"
  touch "$STATE/nft/ProkopTable" "$STATE/rule" "$STATE/nft/ProkopKillswitch" "$KILLSWITCH_NFT_POLICY"
  rm -f "$STATE/nft/ProkopTorrServerDirect" "$STATE/nft/ProkopConfigRestoreDpiGuard" "$STATE/nft/ProkopTableDpiGuard"
  printf '%s\n%s\n' "$FOREIGN_CRON" "$PROKOP_CRON" >"$PROKOP_CRONTAB_FILE"
  printf '100 main\n105 prokop\n' >"$PROKOP_RT_TABLES"
  cat >"$PROKOP_SING_BOX_INIT" <<'SH'
#!/bin/sh
# Prokop managed sing-box service for binary variants
printf 'sing-box init %s\n' "$1" >>"$EVENTS"
SH
  chmod +x "$PROKOP_SING_BOX_INIT"
  : >"$PROKOP_SING_BOX_BIN"
  : >"$PROKOP_SING_BOX_CRONET"
}
prerm() { # prerm <action> [new version]: status of service/package.uc prerm
  local rc=0
  ucode -L "$LIB" "$PACKAGE_UC" prerm "$@" >>"$EVENTS" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}
called() { grep -Fqx "$1" "$EVENTS"; }
line_of() { grep -Fnx "$1" "$EVENTS" | head -1 | cut -d: -f1; }
left_logged() { # left_logged <case> <item>...
  local case_name="$1" item
  shift
  for item in "$@"; do
    grep -q "^logger -t prokop \\[warn\\] Prokop's removal left in place: .*$item" "$EVENTS" ||
      fail "$case_name: the system log does not say that $item is left"
  done
}
nothing_left_logged() {
  ! grep -q "removal left in place" "$EVENTS" || fail "$1: the system log names something left after a clean removal"
}

# 1. Removal: the package stop exited 0 but left the interception. The
#    explicit stop takes it down before the managed sing-box goes.
reset_case
printf 'table rule\n' >"$STATE/package-leaves"
[ "$(prerm remove)" = 0 ] || fail "prerm failed although the explicit stop took Prokop down"
called 'prokop stop explicit' || fail "a removal did not stop Prokop again when its stop left the interception"
[ "$(line_of 'prokop stop explicit')" -lt "$(line_of 'sing-box init stop')" ] ||
  fail "the managed sing-box was stopped before the interception it serves was taken down"
if [ -e "$STATE/nft/ProkopTable" ] || [ -e "$STATE/rule" ]; then fail "the interception survived the removal"; fi
nothing_left_logged "stop left the interception"

# 2. Removal: both stops exited 0 and left the table and the rule. The
#    managed sing-box keeps serving them until a reboot, and prerm says so.
reset_case
printf 'table rule\n' >"$STATE/package-leaves"
printf 'table rule\n' >"$STATE/explicit-leaves"
[ "$(prerm remove)" != 0 ] || fail "prerm reported success although the interception survived the removal"
! called 'sing-box init stop' || fail "the removal stopped the sing-box that still serves the interception"
left_logged "interception left" 'nft table inet ProkopTable' 'IPv4 rule 105'

# 3. Removal: Prokop's scheduled jobs stayed in the crontab. The explicit
#    stop tries again; what still stays is reported. Another program's jobs
#    are not touched.
reset_case
printf 'cron\n' >"$STATE/package-leaves"
[ "$(prerm remove)" = 0 ] || fail "prerm failed although the explicit stop removed the scheduled jobs"
called 'prokop stop explicit' || fail "a removal did not stop Prokop again when its stop left the scheduled jobs"
reset_case
printf 'cron\n' >"$STATE/package-leaves"
printf 'cron\n' >"$STATE/explicit-leaves"
[ "$(prerm remove)" != 0 ] || fail "prerm reported success with Prokop's scheduled jobs in the crontab"
left_logged "scheduled jobs left" "scheduled jobs in $PROKOP_CRONTAB_FILE"
grep -Fqx "$FOREIGN_CRON" "$PROKOP_CRONTAB_FILE" || fail "another program's scheduled job was removed"

# 4. Removal: the kill-switch could not be lifted, and the TorrServer Direct
#    table is still there.
reset_case
: >"$STATE/killswitch-stays"
touch "$STATE/nft/ProkopTorrServerDirect"
[ "$(prerm remove)" != 0 ] || fail "prerm reported success with the kill-switch in place"
called 'killswitch release package removal' || fail "a removal did not release the kill-switch"
left_logged "kill-switch left" 'nft table inet ProkopKillswitch' "saved kill-switch policy $KILLSWITCH_NFT_POLICY" \
  'nft table inet ProkopTorrServerDirect'

# 4b. Removal: the fail-closed DPI guard of a restore that ended
#     needs_attention, which Prokop's stop leaves and only a restore
#     releases, and the one of a failed transition.
reset_case
touch "$STATE/nft/ProkopConfigRestoreDpiGuard" "$STATE/nft/ProkopTableDpiGuard"
[ "$(prerm remove)" != 0 ] || fail "prerm reported success with a DPI guard of Prokop in place"
left_logged "DPI guards left" 'nft table inet ProkopTableDpiGuard' 'nft table inet ProkopConfigRestoreDpiGuard'

# 5. A clean removal reports success and nothing left.
reset_case
[ "$(prerm remove)" = 0 ] || fail "a clean removal failed"
! called 'prokop stop explicit' || fail "a clean removal stopped Prokop twice"
called 'sing-box init stop' || fail "a clean removal did not stop the managed sing-box"
nothing_left_logged "clean removal"

printf 'package removal leftover checks passed\n'
