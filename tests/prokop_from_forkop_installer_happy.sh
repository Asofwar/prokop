#!/usr/bin/env bash
set -euo pipefail

# The installer switches a router from Forkop (the installation Prokop was
# renamed from) to Prokop, with opkg and with apk: Prokop is installed next
# to it, its configuration and data are moved over, Forkop is stopped with
# its own code, removed by its package manager and cleaned up from an
# explicit path list, and Prokop takes over its service state. The scenarios
# run under dash (tests/helpers/prokop_from_forkop_installer.sh).

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

# The old names live in one marked block; elsewhere install.sh names the old
# product only in legacy_forkop identifiers, so a rename completeness check
# can allow exactly that block.
[ "$(grep -c -x '# Legacy Forkop names' "$ROOT_DIR/install.sh")" -eq 1 ] &&
  [ "$(grep -c -x '# End of legacy Forkop names' "$ROOT_DIR/install.sh")" -eq 1 ] ||
  fail "install.sh must keep its old names in exactly one marked block"
outside_block="$(sed '/^# Legacy Forkop names$/,/^# End of legacy Forkop names$/d' "$ROOT_DIR/install.sh")"
[ -n "$outside_block" ] || fail "install.sh is empty outside the legacy names block"
stray_names="$(printf '%s\n' "$outside_block" |
  sed -E 's/[Ll][Ee][Gg][Aa][Cc][Yy][-_][Ff][Oo][Rr][Kk][Oo][Pp]//g' | grep -n -i 'forkop' || true)"
[ -z "$stray_names" ] ||
  fail "install.sh names the old product outside its legacy names block:
$stray_names"

cat >"$WORK_DIR/opkg-running.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup opkg
pff_install_forkop
root="$PFF_ROOT"

pff_run_installer || pff_fail "the switch from Forkop failed"
pff_assert_log 'Installation mode: legacy_forkop' 'a Forkop router must take the Forkop mode'
pff_assert_log 'Переход с Forkop на Prokop завершен' 'the Russian interface of Forkop selects Russian progress lines'

# Packages: Prokop with its Russian interface (Forkop had it), no Forkop.
for package in prokop luci-app-prokop luci-i18n-prokop-ru; do
    pff_installed "$package" || pff_fail "$package was not installed"
done
for package in forkop luci-app-forkop luci-i18n-forkop-ru; do
    if pff_installed "$package"; then pff_fail "$package is still installed"; fi
done
first() { grep -Fxn -- "$1" "$PFF_EVENTS" | head -n 1 | cut -d: -f1; }
[ "$(first 'remove luci-i18n-forkop-ru')" -lt "$(first 'remove luci-app-forkop')" ] &&
    [ "$(first 'remove luci-app-forkop')" -lt "$(first 'remove forkop')" ] ||
    pff_fail "the Forkop packages must be removed i18n, app, backend"
[ "$(first 'install prokop 2.0.0')" -lt "$(first 'forkop stop source=package')" ] ||
    pff_fail "Prokop must be installed before Forkop is stopped"
[ "$(first 'forkop stop source=package')" -lt "$(first 'remove luci-i18n-forkop-ru')" ] ||
    pff_fail "Forkop must be stopped with its own code before its packages are removed"
[ "$(first 'remove forkop')" -lt "$(first 'install luci-app-prokop 2.0.0')" ] ||
    pff_fail "the Prokop interface is installed only after Forkop is removed"

# Deactivated with its own init scripts, the stop marked as the package's.
pff_assert_event 'forkop-killswitch stop'
pff_assert_event 'forkop-killswitch disable'
pff_assert_event 'forkop-torrserver-direct stop'
pff_assert_event 'forkop-torrserver-direct disable'
pff_assert_event 'forkop disable source='
pff_assert_event 'old prerm remove killswitch-runtime=absent' 'the old prerm must run without the kill-switch runtime'
pff_refute_event 'old prerm lifted the kill-switch'

# Configuration and data moved over.
grep -Fq "vless://forkop-migration-test" "$root/etc/config/prokop" ||
    pff_fail "the Forkop configuration was not copied to /etc/config/prokop"
pff_assert_event 'migrate vless://forkop-migration-test' 'the copied configuration must go through migration.uc migrate'
for path in tailscale/node/node.key lists/russia_inside.lst sing-box-variant .ui-state; do
    pff_assert_exists "$root/etc/prokop/$path" "Forkop state must be copied"
done
for path in killswitch vpn-guard opkg-package-set-recovery; do
    pff_assert_absent "$root/etc/prokop/$path" "$path must not be copied"
done
pff_assert_exists "$root/etc/prokop-backups/configuration.tar.gz" "the Forkop backups must be copied"
# The Forkop subscription cache is not carried over, not even into the cache
# of the current format the Prokop postinst created: Prokop would take its
# __forkop_* outbound keys as its own until the next download.
pff_assert_absent "$root/etc/prokop/subscription-cache/main-1.json" "the Forkop subscription cache must not be copied"
[ "$(cat "$root/etc/prokop/subscription-cache/cache-format")" = 10 ] ||
    pff_fail "the subscription cache format of the Prokop postinst must stay"
if grep -rl '__forkop_' "$root/etc/prokop" "$root/etc/prokop-backups"; then
    pff_fail "no Forkop cache may be carried over to Prokop"
fi

# Prokop's legacy cleanup (service/package.uc) runs once the old init script
# is gone, and before the old state it reads is removed.
pff_assert_event 'prokop package.uc legacy-cleanup forkop-init=absent vpn-guard-policy=present' \
    "the Prokop legacy cleanup must see the old guard's policy and no old init script"
[ "$(grep -c '^prokop package.uc ' "$PFF_EVENTS")" -eq 1 ] || pff_fail "the Prokop legacy cleanup must run once"

# Explicit cleanup.
for path in etc/init.d/forkop etc/init.d/forkop-killswitch etc/init.d/forkop-torrserver-direct \
    etc/rc.d/S99forkop etc/rc.d/K10forkop etc/rc.d/S20forkop-killswitch etc/rc.d/S99forkop-torrserver-direct \
    usr/bin/forkop usr/lib/forkop usr/share/forkop usr/libexec/forkop-ro \
    www/luci-static/resources/view/forkop usr/share/luci/menu.d/luci-app-forkop.json \
    usr/share/rpcd/acl.d/luci-app-forkop.json etc/uci-defaults/50_luci-forkop \
    etc/uci-defaults/luci-i18n-forkop-ru usr/lib/lua/luci/i18n/forkop.ru.lmo \
    var/run/forkop var/run/forkop.reload.lock tmp/forkop-killswitch tmp/forkop-package-was-running \
    etc/config/forkop etc/forkop-backups etc/forkop/tailscale etc/forkop/lists etc/forkop/vpn-guard \
    etc/forkop/opkg-package-set-recovery etc/forkop/.ui-state etc/forkop/subscription-cache \
    tmp/luci-indexcache.0 tmp/luci-modulecache; do
    pff_assert_absent "$root/$path" "the switch must remove"
done
pff_assert_exists "$root/etc/opkg/distfeeds.conf.pre-forkop-mirror" "*.pre-forkop-mirror files must stay"
for table in ForkopTable ForkopTorrServerDirect ForkopConfigRestore; do
    pff_assert_absent "$FAKE_NFT_DIR/$table" "the Forkop runtime table must go"
done
pff_assert_exists "$FAKE_NFT_DIR/fw4" "foreign nftables tables must stay"
for service in forkop forkop-killswitch forkop-torrserver-direct; do
    pff_assert_event "ubus call service delete {\"name\":\"$service\"}"
done
grep -Fq '# forkop-' "$root/etc/crontabs/root" && pff_fail "Forkop cron jobs remain"
grep -Fxq '0 4 * * * /usr/bin/foreign-job # foreign-job' "$root/etc/crontabs/root" ||
    pff_fail "foreign cron jobs must stay"
pff_assert_event 'cron restart' 'cron must reread the crontab'
grep -Eq '^105[[:space:]]+forkop' "$root/etc/iproute2/rt_tables" && pff_fail "the Forkop routing table name remains"
grep -Fxq '200 vpn' "$root/etc/iproute2/rt_tables" || pff_fail "foreign routing table names must stay"

# The kill-switch stays fail-closed until Prokop arms its own.
pff_assert_exists "$FAKE_NFT_DIR/ForkopKillswitch" "the Forkop kill-switch table must stay"
pff_assert_exists "$root/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft" "its fw4 include must stay"
pff_assert_exists "$root/etc/forkop/killswitch/dnsmasq.servers" "the servers file dnsmasq uses must stay"
grep -Fxq 'nft flush chain inet ForkopKillswitch ks_dns' "$PFF_NFT_LOG" ||
    pff_fail "the client DNS redirect of the old kill-switch must be flushed"
grep -Fq 'delete table inet ForkopKillswitch' "$PFF_NFT_LOG" && pff_fail "the old kill-switch table was deleted"
pff_assert_log 'Kill-switch Forkop продолжает блокировать' 'the user must learn that the old kill-switch stays'

# dnsmasq restored by the old stop; nothing left for the installer.
[ "$(pff_uci 'dnsmasq().server')" = 8.8.8.8 ] || pff_fail "dnsmasq servers were not restored"
[ "$(pff_uci 'dnsmasq().noresolv')" = 0 ] || pff_fail "dnsmasq noresolv was not restored"
[ -z "$(pff_uci 'join(" ", filter(keys(dnsmasq()), (k) => index(k, "forkop_") == 0 || index(k, "prokop_") == 0))')" ] ||
    pff_fail "dnsmasq backups were left behind"
[ "$(pff_uci 'dnsmasq().serversfile')" = "$root/etc/forkop/killswitch/dnsmasq.servers" ] ||
    pff_fail "the installer must not touch the kill-switch servers file"
[ "$(pff_event_count 'dnsmasq restart')" -eq 0 ] || pff_fail "dnsmasq must not be restarted after a clean old stop"
grep -Fxq 'commit dhcp' "$FAKE_UCI_LOG" && pff_fail "dhcp must not be committed after a clean old stop"

# LuCI users keep their access under the new ACL groups.
[ "$(pff_uci 's.rpcd.cfg03.read')" = 'luci-app-prokop luci-base' ] || pff_fail "rpcd read grants were not rewritten"
[ "$(pff_uci 's.rpcd.cfg03.write')" = 'luci-app-prokop-admin' ] || pff_fail "rpcd write grants were not rewritten"
[ "$(pff_uci 's.rpcd.cfg02.read')" = '*' ] || pff_fail "other rpcd logins must stay"
pff_assert_event 'rpcd reload'

# Enabled and started as Forkop was; nothing of the migration remains.
pff_assert_event 'prokop enable'
pff_assert_event 'prokop start'
pff_assert_absent "$root/etc/prokop/.migrating-from-forkop" "the resume marker must go after a success"
pff_assert_absent "$root/etc/prokop-forkop-migration" "the backups must go after a success"
grep -Eq '^flash plan with [1-9][0-9]* KB of copied state$' "$PFF_EVENTS" ||
    pff_fail "the flash plan must count the copied Forkop state"
SCENARIO

cat >"$WORK_DIR/apk-stopped.sh" <<'SCENARIO'
. "$PFF_REPO/tests/helpers/prokop_from_forkop_installer.sh"
pff_setup apk
PFF_I18N=0 PFF_FORKOP_ENABLED=0 PFF_FORKOP_RUNNING=0 pff_install_forkop
root="$PFF_ROOT"

pff_run_installer || pff_fail "the switch from Forkop failed with apk"
pff_assert_log 'The switch from Forkop to Prokop is complete' 'English progress lines without a Russian interface'
for package in prokop luci-app-prokop; do
    pff_installed "$package" || pff_fail "$package was not installed with apk"
done
if pff_installed luci-i18n-prokop-ru; then
    pff_fail "the Russian interface must not be installed when Forkop had none and LuCI is not Russian"
fi
for package in forkop luci-app-forkop; do
    if pff_installed "$package"; then pff_fail "$package is still installed with apk"; fi
done
pff_assert_event 'forkop stop source=package' 'a stopped Forkop is still stopped with its own code'
pff_refute_event 'prokop enable'
pff_refute_event 'prokop start'
pff_assert_log 'Prokop was not started, as Forkop was not' 'a disabled Forkop leaves Prokop disabled'
grep -Fq "vless://forkop-migration-test" "$root/etc/config/prokop" ||
    pff_fail "the Forkop configuration was not copied with apk"
pff_assert_absent "$root/etc/config/forkop"
pff_assert_absent "$root/usr/lib/forkop"
pff_assert_absent "$root/etc/prokop/subscription-cache/main-1.json" "the Forkop subscription cache must not be copied with apk"
pff_assert_absent "$root/etc/prokop/.migrating-from-forkop"
pff_assert_absent "$root/etc/prokop-forkop-migration"
SCENARIO

run_scenario opkg-running
run_scenario apk-stopped

printf 'Prokop from Forkop installer happy path tests passed\n'
