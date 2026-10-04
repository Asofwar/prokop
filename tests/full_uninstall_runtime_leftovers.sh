#!/usr/bin/env bash
set -euo pipefail

# Full uninstall removes Prokop only once its runtime is down, and reports
# success only when nothing of it is left (UC-028, UC-083).
#
# Before: the stop phase trusted the exit status of /etc/init.d/prokop stop.
# A stop that left Prokop's interception in place and still exited 0 (rc.common
# drops the status of stop_service unless a service_stopped hook passes it on;
# a stop that could not delete the table or rule logs and goes on) let the
# removal go on: the packages, the managed sing-box that served ProkopTable
# and the feeds went, the job reported "complete", and ProkopTable and the
# fwmark rule at priority 105 kept diverting traffic to a port nobody served
# until a reboot. Cron lines calling the removed /usr/bin/prokop stayed.
# prokop-torrserver-direct was neither stopped nor disabled, and the rc.d
# links of the package's services stayed behind.
#
# Now, right after Prokop's stop, the removal checks what is left of its
# interception: ProkopTable and an IPv4 or IPv6 rule at priority 105 that
# looks up Prokop's table (by name or, once rt_tables lost the name, by
# number). Anything left refuses the removal before anything is disabled,
# stopped or removed, and says what is left (also in the status the UI
# reads). At the end it checks again, with Prokop's lines in the crontab,
# the TorrServer Direct table, the kill-switch table and the kill-switch
# loader of fw4, and fails instead of reporting success when any of it is
# still there. Lines left in the crontab do not hold the removal up: they
# divert no traffic, and the stop leaves them only when it cannot rewrite
# the crontab (a full overlay), which no retry and no restart would change.
#
# full-uninstall.sh runs against a fixture root with an init.d, nft, ip and a
# package manager that record what they are asked to do.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/prokop/files/usr/lib/full-uninstall.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

ROOT=""
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -n "$ROOT" ]; then
    [ ! -s "$ROOT/calls" ] || sed 's/^/  call: /' "$ROOT/calls" >&2
    cat "$ROOT"/tmp/prokop-uninstall.*/output.log 2>/dev/null | sed 's/^/  log: /' >&2 || true
  fi
  exit 1
}

PROKOP_CRON='0 */6 * * * /usr/bin/prokop list_update_if_due # prokop-list-update'
FOREIGN_CRON='0 3 * * * /usr/bin/backup # mine'

# fixture <name>: a router with Prokop running. Prokop's stop takes its
# runtime down unless $ROOT/stop-leaves names what it leaves.
fixture() {
  ROOT="$WORK/$1"
  mkdir -p "$ROOT/etc/opkg" "$ROOT/usr/bin" "$ROOT/bin" "$ROOT/packages" "$ROOT/etc/prokop" \
    "$ROOT/etc/config" "$ROOT/usr/lib/prokop" "$ROOT/etc/init.d" "$ROOT/etc/rc.d" \
    "$ROOT/etc/crontabs" "$ROOT/nft" "$ROOT/usr/share/nftables.d/ruleset-post"
  : >"$ROOT/calls"
  printf 'original vendor repositories\n' >"$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
  printf 'https://mirror.51343.ru/openwrt/releases/test\n' >"$ROOT/etc/opkg/distfeeds.conf"
  touch "$ROOT/usr/lib/prokop/test" "$ROOT/packages/prokop" "$ROOT/packages/luci-app-prokop" \
    "$ROOT/packages/sing-box" "$ROOT/nft/ProkopTable" "$ROOT/nft/ProkopTorrServerDirect"
  printf '# loader\n' >"$ROOT/usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft"
  printf '105:\tfrom all fwmark 0x4000000/0x4000000 lookup prokop\n' >"$ROOT/rules4"
  printf '105:\tfrom all fwmark 0x4000000/0x4000000 lookup prokop\n' >"$ROOT/rules6"
  printf '%s\n%s\n' "$FOREIGN_CRON" "$PROKOP_CRON" >"$ROOT/etc/crontabs/root"
  for link in S99prokop S20prokop-killswitch K90prokop-killswitch S100prokop-torrserver-direct \
    K9prokop-torrserver-direct S19dnsmasq K50dropbear; do
    ln -s "../init.d/${link##*[0-9]}" "$ROOT/etc/rc.d/$link"
  done

  cat >"$ROOT/usr/bin/prokop" <<'SH'
#!/bin/sh
printf 'prokop %s\n' "$*" >>"$PROKOP_UNINSTALL_ROOT/calls"
SH
  # /etc/init.d/prokop: its stop takes Prokop's runtime down (table, rules,
  # cron lines) except what stop-leaves names, and exits with stop-status.
  cat >"$ROOT/etc/init.d/prokop" <<'SH'
#!/bin/sh
R="$PROKOP_UNINSTALL_ROOT"
printf 'init.d/prokop %s\n' "$1" >>"$R/calls"
case "$1" in
  stop)
    leaves="$(cat "$R/stop-leaves" 2>/dev/null || true)"
    case "$leaves" in *table*) ;; *) rm -f "$R/nft/ProkopTable" ;; esac
    case "$leaves" in *rule4*) ;; *) : >"$R/rules4" ;; esac
    case "$leaves" in *rule6*) ;; *) : >"$R/rules6" ;; esac
    case "$leaves" in *cron*) ;; *) grep -v '# prokop-' "$R/etc/crontabs/root" >"$R/cron.new"; mv "$R/cron.new" "$R/etc/crontabs/root" ;; esac
    exit "$(cat "$R/stop-status" 2>/dev/null || echo 0)"
    ;;
  disable) rm -f "$R"/etc/rc.d/S??prokop "$R"/etc/rc.d/K??prokop ;;
esac
SH
  # As rc.common: disable removes only S?? and K?? links.
  cat >"$ROOT/etc/init.d/prokop-torrserver-direct" <<'SH'
#!/bin/sh
R="$PROKOP_UNINSTALL_ROOT"
printf 'init.d/prokop-torrserver-direct %s\n' "$1" >>"$R/calls"
case "$1" in
  stop) rm -f "$R/nft/ProkopTorrServerDirect" ;;
  disable) rm -f "$R"/etc/rc.d/S??prokop-torrserver-direct "$R"/etc/rc.d/K??prokop-torrserver-direct ;;
esac
SH
  cat >"$ROOT/etc/init.d/prokop-killswitch" <<'SH'
#!/bin/sh
R="$PROKOP_UNINSTALL_ROOT"
printf 'init.d/prokop-killswitch %s\n' "$1" >>"$R/calls"
case "$1" in
  disable) rm -f "$R"/etc/rc.d/S??prokop-killswitch "$R"/etc/rc.d/K??prokop-killswitch ;;
esac
SH
  cat >"$ROOT/etc/init.d/sing-box" <<'SH'
#!/bin/sh
printf 'init.d/sing-box %s\n' "$1" >>"$PROKOP_UNINSTALL_ROOT/calls"
SH
  cat >"$ROOT/bin/nft" <<'SH'
#!/bin/sh
R="$PROKOP_UNINSTALL_ROOT"
[ "$1" != -t ] || shift
case "$1 $2 $3" in
  "list table inet") [ -e "$R/nft/$4" ]; exit $? ;;
  "delete table inet") [ ! -e "$R/nft-stays/$4" ] || exit 1; rm -f "$R/nft/$4"; exit 0 ;;
esac
exit 1
SH
  cat >"$ROOT/bin/ip" <<'SH'
#!/bin/sh
R="$PROKOP_UNINSTALL_ROOT"
case "$*" in
  "-4 rule show") printf '0:\tfrom all lookup local\n'; cat "$R/rules4"; printf '32766:\tfrom all lookup main\n' ;;
  "-6 rule show") printf '0:\tfrom all lookup local\n'; cat "$R/rules6"; printf '32766:\tfrom all lookup main\n' ;;
  *) exit 1 ;;
esac
SH
  cat >"$ROOT/bin/opkg" <<'SH'
#!/bin/sh
R="$PROKOP_UNINSTALL_ROOT"
case "$1" in
  status) [ -e "$R/packages/$2" ] && echo 'Status: install ok installed' ;;
  remove)
    printf 'opkg %s\n' "$*" >>"$R/calls"
    shift
    for p in "$@"; do rm -f "$R/packages/$p"; done
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$ROOT/usr/bin/prokop" "$ROOT"/etc/init.d/* "$ROOT/bin/"*
}

worker_settled() {
  status="$(cat "$ROOT"/www/prokop-uninstall.*.json 2>/dev/null)"
  case "$status" in *'"state":"complete"'* | *'"state":"failed"'*) return 0 ;; esac
  return 1
}

run_removal() {
  PROKOP_UNINSTALL_ROOT="$ROOT" PATH="$ROOT/bin:$PATH" sh "$SCRIPT" start >"$ROOT/response"
  wait_until 60 worker_settled || fail "$CASE: the removal did not finish"
  LOG="$(cat "$ROOT"/tmp/prokop-uninstall.*/output.log)"
}

# Nothing was removed, disabled or stopped after Prokop's own stop.
refused_at_stop() {
  printf '%s\n' "$status" | grep -q '"state":"failed","phase":"stop"' ||
    fail "$CASE: the removal went on although Prokop's runtime is still up: $status"
  if [ ! -e "$ROOT/packages/prokop" ] || [ ! -e "$ROOT/packages/sing-box" ]; then
    fail "$CASE: packages were removed"
  fi
  grep -q 'mirror.51343.ru' "$ROOT/etc/opkg/distfeeds.conf" || fail "$CASE: the feeds were changed"
  [ -e "$ROOT/usr/lib/prokop/test" ] || fail "$CASE: Prokop's files were removed"
  [ "$(cat "$ROOT/calls")" = 'init.d/prokop stop' ] ||
    fail "$CASE: the removal did more than Prokop's stop"
  [ -L "$ROOT/etc/rc.d/S99prokop" ] || fail "$CASE: Prokop's autostart was removed"
}
# says_left <code> <text>...: the log names each item in words, the status
# the UI reads by its code (the UI says it in the user's language).
says_left() {
  local code text codes
  codes="$(printf '%s\n' "$status" | sed -n 's/.*"left":"\([^"]*\)".*/\1/p')"
  while [ "$#" -ge 2 ]; do
    code="$1" text="$2"
    shift 2
    printf '%s\n' "$LOG" | grep -Fq "$text" || fail "$CASE: the log does not say that $text is left: $LOG"
    case ",$codes," in *",$code,"*) ;; *) fail "$CASE: the status does not name $code: $status" ;; esac
  done
}

# 1. Prokop's stop exited 0 and left everything in place.
CASE="stop left the runtime"
fixture runtime_left
printf 'table rule4 rule6 cron\n' >"$ROOT/stop-leaves"
run_removal
refused_at_stop
says_left table:ProkopTable 'nft table inet ProkopTable' rule:4 'IPv4 rule 105' rule:6 'IPv6 rule 105'

# 2. Any one of them is enough: the IPv6 rule once rt_tables lost the name
#    (it shows "lookup 105"), the table.
CASE="IPv6 rule by number"
fixture rule_by_number
printf 'rule6\n' >"$ROOT/stop-leaves"
printf '105:\tfrom all fwmark 0x4000000/0x4000000 lookup 105\n' >"$ROOT/rules6"
run_removal
refused_at_stop
says_left rule:6 'IPv6 rule 105'
if printf '%s\n' "$status" | grep -Fq 'ProkopTable'; then
  fail "$CASE: the status names a table that is gone: $status"
fi
# Under another name of table 105 (Podkop's entry after Prokop's, NET-3):
# the rule with Prokop's fwmark is still Prokop's.
CASE="IPv6 rule under another table name"
fixture rule_other_name
printf 'rule6\n' >"$ROOT/stop-leaves"
printf '105:\tfrom all fwmark 0x4000000/0x4000000 lookup podkop\n' >"$ROOT/rules6"
run_removal
refused_at_stop
says_left rule:6 'IPv6 rule 105'
CASE="table only"
fixture table_only
printf 'table\n' >"$ROOT/stop-leaves"
run_removal
refused_at_stop
says_left table:ProkopTable 'nft table inet ProkopTable'

# 2b. Only Prokop's lines in the crontab stayed: the removal goes on, and
#     does not report success while they are there.
CASE="scheduled jobs only"
fixture cron_only
printf 'cron\n' >"$ROOT/stop-leaves"
run_removal
printf '%s\n' "$status" | grep -q '"state":"failed","phase":"files"' ||
  fail "$CASE: the removal did not go on to the end, or reported success: $status"
[ ! -e "$ROOT/packages/prokop" ] || fail "$CASE: the prokop package was not removed"
says_left cron '# prokop- in /etc/crontabs/root'

# 3. A stop that failed (refused: exit 2) says what it left too.
CASE="refused stop"
fixture refused_stop
printf 'table rule4\n' >"$ROOT/stop-leaves"
printf '2\n' >"$ROOT/stop-status"
run_removal
refused_at_stop
says_left table:ProkopTable 'nft table inet ProkopTable' rule:4 'IPv4 rule 105'

# 4. A stop that took everything down: the removal completes, TorrServer
#    Direct is stopped and disabled, and no rc.d link of the package's
#    services is left, also not the links an older release made for
#    TorrServer Direct (S100, K9), which its disable never removed.
CASE="clean stop"
fixture clean
run_removal
printf '%s\n' "$status" | grep -q '"state":"complete"' || fail "$CASE: the removal failed: $status"
grep -Fqx 'init.d/prokop-torrserver-direct stop' "$ROOT/calls" || fail "$CASE: TorrServer Direct was not stopped"
grep -Fqx 'init.d/prokop-torrserver-direct disable' "$ROOT/calls" || fail "$CASE: TorrServer Direct was not disabled"
[ ! -e "$ROOT/nft/ProkopTorrServerDirect" ] || fail "$CASE: the TorrServer Direct table was left"
[ ! -e "$ROOT/etc/init.d/prokop-torrserver-direct" ] || fail "$CASE: the TorrServer Direct init script was left"
left_links="$(find "$ROOT/etc/rc.d" -mindepth 1 -name '*prokop*' -printf '%f ')"
[ -z "$left_links" ] || fail "$CASE: rc.d links of the removed services were left: $left_links"
if [ ! -L "$ROOT/etc/rc.d/S19dnsmasq" ] || [ ! -L "$ROOT/etc/rc.d/K50dropbear" ]; then
  fail "$CASE: rc.d links of other services were removed"
fi
[ "$(cat "$ROOT/etc/crontabs/root")" = "$FOREIGN_CRON" ] || fail "$CASE: the crontab is not as the stop left it: $(cat "$ROOT/etc/crontabs/root")"
[ ! -e "$ROOT/packages/prokop" ] || fail "$CASE: the prokop package was not removed"

# 5. What the removal itself takes away is checked at the end: a kill-switch
#    table that nothing lifted fails the removal instead of "complete".
CASE="kill-switch left"
fixture killswitch_left
touch "$ROOT/nft/ProkopKillswitch"
run_removal
printf '%s\n' "$status" | grep -q '"state":"failed","phase":"files"' ||
  fail "$CASE: the removal reported success with the kill-switch table in place: $status"
says_left table:ProkopKillswitch 'nft table inet ProkopKillswitch'

# 6. The fail-closed DPI guards outlive Prokop's stop: the guard of a
#    restore or an autotune apply that ended needs_attention goes only with
#    a restore, and nothing marks DPI traffic for either once Prokop is
#    gone. The removal deletes them, and does not report success while one
#    stays.
CASE="DPI guards"
fixture dpi_guards
touch "$ROOT/nft/ProkopConfigRestoreDpiGuard" "$ROOT/nft/ProkopTableDpiGuard"
run_removal
printf '%s\n' "$status" | grep -q '"state":"complete"' || fail "$CASE: the removal failed: $status"
if [ -e "$ROOT/nft/ProkopConfigRestoreDpiGuard" ] || [ -e "$ROOT/nft/ProkopTableDpiGuard" ]; then
  fail "$CASE: a DPI guard of Prokop outlived its removal"
fi
CASE="DPI guard stays"
fixture dpi_guard_stays
mkdir -p "$ROOT/nft-stays"
touch "$ROOT/nft/ProkopConfigRestoreDpiGuard" "$ROOT/nft-stays/ProkopConfigRestoreDpiGuard"
run_removal
printf '%s\n' "$status" | grep -q '"state":"failed","phase":"files"' ||
  fail "$CASE: the removal reported success with a DPI guard in place: $status"
says_left table:ProkopConfigRestoreDpiGuard 'nft table inet ProkopConfigRestoreDpiGuard'

printf 'full uninstall runtime leftover checks passed\n'
