#!/usr/bin/env bash
set -euo pipefail

# What the switch from Forkop hands over instead of letting Forkop's package
# removal tear it down (its prerm: a657f9cf service/package.uc
# prerm_cleanup):
#  * a binary sing-box under Forkop's marker gets Prokop's marker, so the old
#    prerm keeps /etc/init.d/sing-box, /usr/bin/sing-box and libcronet.so;
#    a sing-box lost anyway is reinstalled through Prokop;
#  * the kill-switch stays fail-closed: its service stops (no DNS redirect to
#    a standby that is gone, the chain is flushed as well), but the old
#    prerm finds no killswitch/runtime.uc to lift the policy with, its table,
#    fw4 include and sysupgrade keep list stay, and /etc/forkop/killswitch
#    stays while dnsmasq or the policy still uses it;
#  * dnsmasq: Forkop's own stop restores it; when it could not, its fail-safe
#    restore and then the installer's restore it with one restart; backups
#    left behind go to Prokop's option names in one commit without a
#    restart, never over Prokop's own;
#  * an old stop that fails still leaves no Forkop runtime table behind.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v dash >/dev/null 2>&1 ||
  fail "dash is required: the installer runs under BusyBox ash on the router"

run_scenario() {
  mkdir -p "$WORK_DIR/$1"
  PFF_REPO="$ROOT_DIR" PFF_WORK="$WORK_DIR/$1" dash "$WORK_DIR/$1.sh" ||
    fail "scenario $1 failed"
}

cat >"$WORK_DIR/managed-sing-box.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
PFF_MANAGED_SING_BOX=1 PFF_I18N=0 pff_install_forkop
root="$PFF_ROOT"

pff_run_installer || pff_fail "the switch with a Forkop-managed sing-box failed"
pff_assert_log 'The sing-box managed by Forkop will be handed over to Prokop'
pff_assert_log 'The sing-box managed by Forkop is now managed by Prokop'
pff_refute_event 'old prerm removed the managed sing-box' 'the old prerm must not delete the managed sing-box'
grep -Fq 'Prokop managed sing-box service for binary variants' "$root/etc/init.d/sing-box" ||
    pff_fail "the sing-box init script must carry the Prokop marker"
grep -Fq 'Forkop managed sing-box service for binary variants' "$root/etc/init.d/sing-box" &&
    pff_fail "the sing-box init script still carries the Forkop marker"
[ -x "$root/etc/init.d/sing-box" ] || pff_fail "the sing-box init script must stay executable"
pff_assert_exists "$root/usr/bin/sing-box"
pff_assert_exists "$root/usr/lib/libcronet.so"
[ "$(cat "$root/etc/prokop/sing-box-variant")" = extended-compressed ] ||
    pff_fail "the sing-box variant state must be copied"
pff_assert_event 'sing-box install variant=none' 'a sing-box that is still there is not reinstalled'
pff_assert_event 'validate sing-box=' 'the requirements check runs with the handed-over sing-box'
SCENARIO

cat >"$WORK_DIR/managed-sing-box-lost.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup apk
PFF_MANAGED_SING_BOX=1 PFF_I18N=0 pff_install_forkop
export FAKE_PRERM_LOSES_SING_BOX=1

pff_run_installer || pff_fail "the switch must complete when the managed sing-box is lost"
pff_assert_log 'The sing-box managed by Forkop is gone; reinstalling it through Prokop'
pff_assert_event 'sing-box install variant=extended-compressed' \
    'a lost managed sing-box must be reinstalled as its binary variant'
SCENARIO

cat >"$WORK_DIR/killswitch-fail-closed.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
PFF_I18N=0 pff_install_forkop
root="$PFF_ROOT"
cp "$root/lib/upgrade/keep.d/forkop-killswitch" "$PFF_WORK/keep.original"

pff_run_installer || pff_fail "the switch with an armed kill-switch failed"
first() { grep -Fxn -- "$1" "$PFF_EVENTS" | head -n 1 | cut -d: -f1; }
[ "$(first 'forkop-killswitch stop')" -lt "$(first 'forkop stop source=package')" ] ||
    pff_fail "the kill-switch service must stop before Forkop"
pff_assert_event 'forkop-killswitch dns-redirect off' 'the old service stop turns the DNS redirect off'
pff_assert_event 'forkop-killswitch disable'
grep -Fxq 'nft flush chain inet ForkopKillswitch ks_dns' "$PFF_NFT_LOG" ||
    pff_fail "the old DNS redirect chain must be flushed"
pff_assert_event 'conntrack -D -p udp --dport 53' 'redirected DNS flows must be dropped'
pff_assert_event 'old prerm remove killswitch-runtime=absent' \
    'the old prerm must not find the kill-switch runtime it lifts the policy with'
pff_refute_event 'old prerm lifted the kill-switch'
pff_assert_exists "$FAKE_NFT_DIR/ForkopKillswitch" "the old kill-switch table must stay"
grep -Fq 'delete table inet ForkopKillswitch' "$PFF_NFT_LOG" && pff_fail "the old kill-switch table was deleted"
pff_assert_exists "$root/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft" "its fw4 include must stay"
cmp -s "$root/lib/upgrade/keep.d/forkop-killswitch" "$PFF_WORK/keep.original" ||
    pff_fail "the sysupgrade keep list of the old kill-switch must be kept after its package is gone"
pff_assert_exists "$root/etc/forkop/killswitch/dnsmasq.servers" "the servers file dnsmasq uses must stay"
pff_assert_exists "$root/etc/forkop/killswitch/dns-blocked.servers"
[ "$(ls -A "$root/etc/forkop")" = killswitch ] || pff_fail "only the kill-switch state may stay in /etc/forkop"
[ "$(pff_uci 'dnsmasq().serversfile')" = "$root/etc/forkop/killswitch/dnsmasq.servers" ] ||
    pff_fail "dnsmasq must keep the servers file of the old kill-switch until Prokop takes it over"
SCENARIO

cat >"$WORK_DIR/killswitch-servers-file-only.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
PFF_I18N=0 pff_install_forkop
root="$PFF_ROOT"
# The policy is gone, but dnsmasq still reads the old servers file: its
# directory must stay, or dnsmasq would not start.
rm -f "$FAKE_NFT_DIR/ForkopKillswitch" "$root/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft"

pff_run_installer || pff_fail "the switch failed"
pff_assert_exists "$root/etc/forkop/killswitch/dnsmasq.servers" \
    "the servers file must stay while dnsmasq points at it"
grep -Fq 'flush chain' "$PFF_NFT_LOG" && pff_fail "there is no old table to flush"
pff_assert_absent "$root/lib/upgrade/keep.d/forkop-killswitch" "no keep list without the policy"
SCENARIO

cat >"$WORK_DIR/no-killswitch.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
PFF_KILLSWITCH=0 PFF_I18N=0 pff_install_forkop
root="$PFF_ROOT"

pff_run_installer || pff_fail "the switch without a kill-switch failed"
pff_assert_absent "$root/etc/forkop" "nothing of /etc/forkop stays without a kill-switch"
pff_assert_absent "$root/lib/upgrade/keep.d/forkop-killswitch"
grep -Fq 'Forkop kill-switch keeps blocking' "$PFF_LOG" && pff_fail "no kill-switch, no kill-switch notice"
true
SCENARIO

cat >"$WORK_DIR/dnsmasq-not-restored.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
PFF_I18N=0 pff_install_forkop
root="$PFF_ROOT"
# The old fail-safe restore is there but restores nothing either.
mkdir -p "$root/usr/lib/forkop/dns"
cat >"$root/usr/lib/forkop/dns/apply.uc" <<'UC'
let log = require("fs").open(getenv("PFF_EVENTS"), "a");
log.write("old dns/apply.uc " + ARGV[0] + "\n");
log.close();
UC
export FAKE_FORKOP_STOP_DNS=keep

pff_run_installer || pff_fail "the switch failed"
pff_assert_event 'old dns/apply.uc failsafe-restore' 'the old fail-safe restore must run first'
pff_assert_log 'The Forkop stop did not restore dnsmasq; its settings were restored'
[ "$(pff_uci 'dnsmasq().server')" = 8.8.8.8 ] || pff_fail "the dnsmasq servers were not restored from the Forkop backup"
[ "$(pff_uci 'dnsmasq().noresolv')" = 0 ] || pff_fail "noresolv was not restored"
[ "$(pff_uci 'dnsmasq().cachesize')" = 150 ] || pff_fail "cachesize was not restored"
[ -z "$(pff_uci 'join(" ", filter(keys(dnsmasq()), (k) => index(k, "forkop_") == 0 || index(k, "prokop_") == 0))')" ] ||
    pff_fail "the restore must consume the backups"
[ "$(pff_uci 'dnsmasq().serversfile')" = "$root/etc/forkop/killswitch/dnsmasq.servers" ] ||
    pff_fail "the restore must not touch the kill-switch servers file"
[ "$(pff_event_count 'dnsmasq restart')" -eq 1 ] || pff_fail "dnsmasq must be restarted exactly once"
[ "$(grep -Fxc 'commit dhcp' "$FAKE_UCI_LOG")" -eq 1 ] || pff_fail "dhcp must be committed exactly once"
SCENARIO

cat >"$WORK_DIR/dnsmasq-backups-left.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
PFF_I18N=0 pff_install_forkop
root="$PFF_ROOT"
# Prokop's own backup of the servers is never overwritten.
"$PFF_REAL_UCODE" -e '
    let fs = require("fs");
    let s = json(fs.readfile(getenv("FAKE_UCI_STATE")));
    s.dhcp.cfg01411c.prokop_server = [ "4.4.4.4" ];
    s.dhcp.cfg01411c.forkop_notinterface = [ "wan" ];
    fs.writefile(getenv("FAKE_UCI_STATE"), sprintf("%.2J\n", s));
'
export FAKE_FORKOP_STOP_DNS=backups

pff_run_installer || pff_fail "the switch failed"
pff_assert_log 'The dnsmasq backups left by Forkop were handed to Prokop'
[ "$(pff_uci 'dnsmasq().prokop_server')" = 4.4.4.4 ] || pff_fail "Prokop's own server backup was overwritten"
[ "$(pff_uci 'dnsmasq().prokop_noresolv')" = 0 ] || pff_fail "the noresolv backup was not handed over"
[ "$(pff_uci 'dnsmasq().prokop_cachesize')" = 150 ] || pff_fail "the cachesize backup was not handed over"
[ "$(pff_uci 'dnsmasq().prokop_notinterface')" = wan ] || pff_fail "the notinterface backup was not handed over"
[ -z "$(pff_uci 'join(" ", filter(keys(dnsmasq()), (k) => index(k, "forkop_") == 0))')" ] ||
    pff_fail "Forkop backup options remain"
[ "$(grep -Fxc 'commit dhcp' "$FAKE_UCI_LOG")" -eq 1 ] || pff_fail "the hand-over must be one dhcp commit"
[ "$(pff_event_count 'dnsmasq restart')" -eq 0 ] || pff_fail "dnsmasq does not read the backups: no restart"
SCENARIO

cat >"$WORK_DIR/old-stop-fails.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
PFF_I18N=0 pff_install_forkop
export FAKE_FORKOP_STOP=fail

pff_run_installer || pff_fail "a failing old stop must not block the switch"
pff_assert_log 'Forkop did not report a clean stop; removing what its stop left behind.'
grep -Fxq 'nft delete table inet ForkopTable' "$PFF_NFT_LOG" ||
    pff_fail "the Forkop runtime table must be removed when its stop could not"
pff_assert_absent "$FAKE_NFT_DIR/ForkopTable"
[ "$(pff_uci 'dnsmasq().server')" = 8.8.8.8 ] || pff_fail "dnsmasq must be restored when the old stop failed"
pff_assert_event 'prokop start'
SCENARIO

run_scenario managed-sing-box
run_scenario managed-sing-box-lost
run_scenario killswitch-fail-closed
run_scenario killswitch-servers-file-only
run_scenario no-killswitch
run_scenario dnsmasq-not-restored
run_scenario dnsmasq-backups-left
run_scenario old-stop-fails

printf 'Prokop from Forkop installer hand-over tests passed\n'
