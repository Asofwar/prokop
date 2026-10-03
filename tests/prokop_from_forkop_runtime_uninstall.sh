#!/bin/sh
# A full removal also sweeps what the product before the rename left after an
# interrupted migration: its packages (stopped with its own code first), its
# services, nft tables including the old kill-switch, the fw4 include,
# dnsmasq's servers file under its state directory, its paths, cron lines and
# rt_tables entry, by explicit names only. Its kill-switch state directory
# stays while dnsmasq still reads it; .pre-forkop-mirror handling is unchanged.
set -eu
REPO="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$REPO/prokop/files/usr/lib/full-uninstall.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    for log in calls output; do
        printf '%s:\n' "$log" >&2
        cat "$ROOT/$log" >&2 2>/dev/null || true
    done
    exit 1
}

# fixture NAME: a router whose migration stopped after the Prokop backend was
# installed. Both products are installed, the old one still holds its
# kill-switch (table, include, attached servers file).
fixture() {
    ROOT="$WORK/$1"
    mkdir -p "$ROOT/etc/opkg" "$ROOT/bin" "$ROOT/packages" "$ROOT/www" "$ROOT/etc/init.d" "$ROOT/etc/rc.d" \
        "$ROOT/etc/config" "$ROOT/etc/forkop/killswitch" "$ROOT/etc/forkop/subscription-cache" "$ROOT/etc/forkop-backups" \
        "$ROOT/usr/lib/forkop/core" "$ROOT/usr/share/forkop" "$ROOT/usr/bin" "$ROOT/usr/libexec" \
        "$ROOT/www/luci-static/resources/view/forkop" "$ROOT/usr/share/luci/menu.d" "$ROOT/usr/share/rpcd/acl.d" \
        "$ROOT/etc/uci-defaults" "$ROOT/usr/lib/lua/luci/i18n" "$ROOT/usr/share/nftables.d/ruleset-post" \
        "$ROOT/lib/upgrade/keep.d" "$ROOT/tmp/forkop-killswitch" "$ROOT/var/run/forkop" "$ROOT/etc/crontabs" \
        "$ROOT/etc/iproute2" "$ROOT/tables" "$ROOT/tmp/prokop-full-uninstall.lock" \
        "$ROOT/var/run/prokop/component-action.lock"
    printf 'original vendor repositories\n' >"$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
    printf 'https://mirror.51343.ru/openwrt/releases/test\n' >"$ROOT/etc/opkg/distfeeds.conf"
    printf 'unrelated backup\n' >"$ROOT/etc/config/firewall.pre-forkop-mirror"
    for package in forkop luci-app-forkop luci-i18n-forkop-ru prokop; do : >"$ROOT/packages/$package"; done
    for service in forkop forkop-killswitch forkop-torrserver-direct prokop; do
        cat >"$ROOT/etc/init.d/$service" <<SH
#!/bin/sh
printf '%s %s\n' "$service" "\$*" >>"\$PROKOP_UNINSTALL_ROOT/calls"
SH
        chmod +x "$ROOT/etc/init.d/$service"
    done
    for service in cron dnsmasq; do
        printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"$PROKOP_UNINSTALL_ROOT/calls"\n' "$service" >"$ROOT/etc/init.d/$service"
        chmod +x "$ROOT/etc/init.d/$service"
    done
    for bin in forkop prokop; do
        printf '#!/bin/sh\nprintf "%%s %%s\\n" bin-%s "$*" >>"$PROKOP_UNINSTALL_ROOT/calls"\n' "$bin" >"$ROOT/usr/bin/$bin"
        chmod +x "$ROOT/usr/bin/$bin"
    done
    ln -s ../init.d/forkop "$ROOT/etc/rc.d/S99forkop"
    ln -s ../init.d/forkop-killswitch "$ROOT/etc/rc.d/S20forkop-killswitch"
    ln -s ../init.d/forkop-killswitch "$ROOT/etc/rc.d/K90forkop-killswitch"
    ln -s ../init.d/forkop-torrserver-direct "$ROOT/etc/rc.d/S100forkop-torrserver-direct"
    ln -s ../init.d/forkop-torrserver-direct "$ROOT/etc/rc.d/K9forkop-torrserver-direct"
    ln -s ../init.d/other "$ROOT/etc/rc.d/S50forkop-other"
    ln -s ../init.d/other "$ROOT/etc/rc.d/S10myforkop"
    : >"$ROOT/etc/config/forkop"; : >"$ROOT/etc/config/forkop-opkg"; : >"$ROOT/etc/config/forkop.apk-new"
    : >"$ROOT/etc/config/forkopx"
    : >"$ROOT/usr/libexec/forkop-ro"; : >"$ROOT/usr/lib/forkop/core/constants.uc"
    : >"$ROOT/usr/share/luci/menu.d/luci-app-forkop.json"; : >"$ROOT/usr/share/rpcd/acl.d/luci-app-forkop.json"
    : >"$ROOT/etc/uci-defaults/50_luci-forkop"; : >"$ROOT/usr/lib/lua/luci/i18n/forkop.ru.lmo"
    : >"$ROOT/usr/lib/lua/luci/i18n/other.ru.lmo"
    : >"$ROOT/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft"
    : >"$ROOT/usr/share/nftables.d/ruleset-post/90-other.nft"
    : >"$ROOT/lib/upgrade/keep.d/forkop-killswitch"
    printf 'server=/example.com/\n' >"$ROOT/etc/forkop/killswitch/dnsmasq.servers"
    : >"$ROOT/etc/forkop/subscription-cache/main.json"; : >"$ROOT/etc/forkop-backups/configuration.tar.gz"
    : >"$ROOT/tmp/forkop-killswitch/standby.conf"; : >"$ROOT/tmp/forkop-package-was-running"
    : >"$ROOT/var/run/forkop/start.explicit"; : >"$ROOT/tmp/unrelated"
    printf '%s\n' '*/5 * * * * /usr/bin/forkop list_update_if_due # forkop-list-update' \
        '0 4 * * * /usr/bin/backup' '0 3 * * * /usr/bin/forkop autotune_if_due # forkop-autotune' >"$ROOT/etc/crontabs/root"
    printf '%s\n' '100 main' '105 forkop' '200 custom' >"$ROOT/etc/iproute2/rt_tables"
    for table in ForkopTable ForkopKillswitch ForkopTorrServerDirect; do : >"$ROOT/tables/$table"; done
    printf '/etc/forkop/killswitch/dnsmasq.servers\n' >"$ROOT/serversfile"
    cat >"$ROOT/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
 status) [ -e "$PROKOP_UNINSTALL_ROOT/packages/$2" ] && echo 'Status: install ok installed';;
 remove)
  shift
  printf 'opkg remove %s\n' "$*" >>"$PROKOP_UNINSTALL_ROOT/calls"
  for p in "$@"; do rm -f "$PROKOP_UNINSTALL_ROOT/packages/$p"; done;;
 *) exit 1;;
esac
SH
    cat >"$ROOT/bin/nft" <<'SH'
#!/bin/sh
printf 'nft %s\n' "$*" >>"$PROKOP_UNINSTALL_ROOT/calls"
[ "$1" != -t ] || shift
case "$1 $2 $3" in
 "delete table inet") rm -f "$PROKOP_UNINSTALL_ROOT/tables/$4";;
 "list table inet") [ -e "$PROKOP_UNINSTALL_ROOT/tables/$4" ] || exit 1;;
esac
exit 0
SH
    cat >"$ROOT/bin/uci" <<'SH'
#!/bin/sh
printf 'uci %s\n' "$*" >>"$PROKOP_UNINSTALL_ROOT/calls"
[ "$1" != -q ] || shift
case "$1 $2" in
 "get dhcp.@dnsmasq[0].serversfile") [ -s "$PROKOP_UNINSTALL_ROOT/serversfile" ] && cat "$PROKOP_UNINSTALL_ROOT/serversfile";;
 "delete dhcp.@dnsmasq[0].serversfile") [ -z "${FAIL_UCI_DELETE:-}" ] || exit 1; : >"$PROKOP_UNINSTALL_ROOT/serversfile";;
 "get prokop.settings.mirror_base_url") exit 1;;
esac
exit 0
SH
    printf '#!/bin/sh\nprintf "ubus %%s\\n" "$*" >>"$PROKOP_UNINSTALL_ROOT/calls"\n' >"$ROOT/bin/ubus"
    # The delayed status cleanup must not outlive the test.
    printf '#!/bin/sh\nexit 1\n' >"$ROOT/bin/sleep"
    chmod +x "$ROOT/bin/"*
}

run_worker() {
    mkdir -p "$ROOT/job"
    PROKOP_UNINSTALL_ROOT="$ROOT" PROKOP_UNINSTALL_LIVE=1 PROKOP_MIRROR_BASE_URL=https://mirror.51343.ru \
        PATH="$ROOT/bin:$PATH" sh "$SCRIPT" worker "$ROOT/job" "$ROOT/www/state.json" >"$ROOT/output" 2>&1 ||
        fail "removal failed"
    grep -Fq '"state":"complete"' "$ROOT/www/state.json" || fail "removal did not complete"
}

line_of() {
    grep -nF -- "$1" "$ROOT/calls" | head -n 1 | cut -d: -f1
}

fixture interrupted
run_worker
# The old product is stopped with its own code, before Prokop and before the
# package removal.
[ -n "$(line_of 'forkop stop')" ] && [ "$(line_of 'forkop stop')" -lt "$(line_of 'prokop stop')" ] ||
    fail "the old product must be stopped first, with its own init script"
grep -Fqx 'bin-forkop killswitch_disable' "$ROOT/calls" || fail "the old kill-switch must be lifted with the old code"
grep -Fqx 'forkop-killswitch stop' "$ROOT/calls" && grep -Fqx 'forkop-torrserver-direct stop' "$ROOT/calls" ||
    fail "the old services must be stopped"
grep -Fqx 'bin-forkop dnsmasq_restore' "$ROOT/calls" || fail "the old product must restore dnsmasq itself"
[ "$(line_of 'bin-forkop dnsmasq_restore')" -lt "$(line_of 'opkg remove')" ] || fail "the old code must run before its removal"
grep -Fqx 'opkg remove luci-i18n-forkop-ru luci-app-forkop forkop prokop' "$ROOT/calls" ||
    fail "the old packages must be removed with Prokop's"
# Live state, by explicit names.
for table in ForkopTable ForkopKillswitch ForkopTorrServerDirect; do
    [ ! -e "$ROOT/tables/$table" ] || fail "nft table $table must be deleted"
done
for service in forkop forkop-killswitch forkop-torrserver-direct; do
    grep -Fq "ubus call service delete {\"name\":\"$service\"}" "$ROOT/calls" || fail "procd service $service must be deleted"
done
grep -Fqx 'uci -q delete dhcp.@dnsmasq[0].serversfile' "$ROOT/calls" || fail "dnsmasq must leave the old servers file"
grep -Fqx 'dnsmasq restart' "$ROOT/calls" || fail "dnsmasq must be restarted"
grep -Fqx 'cron reload' "$ROOT/calls" || fail "cron must reload the cleaned crontab"
# Paths, by explicit names only.
for path in etc/forkop etc/forkop-backups usr/lib/forkop usr/share/forkop www/luci-static/resources/view/forkop \
    etc/config/forkop etc/config/forkop-opkg etc/config/forkop.apk-new usr/bin/forkop usr/libexec/forkop-ro \
    etc/init.d/forkop etc/init.d/forkop-killswitch etc/init.d/forkop-torrserver-direct etc/uci-defaults/50_luci-forkop \
    usr/share/luci/menu.d/luci-app-forkop.json usr/share/rpcd/acl.d/luci-app-forkop.json \
    usr/lib/lua/luci/i18n/forkop.ru.lmo usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft \
    lib/upgrade/keep.d/forkop-killswitch tmp/forkop-killswitch tmp/forkop-package-was-running var/run/forkop \
    etc/rc.d/S99forkop etc/rc.d/S20forkop-killswitch etc/rc.d/K90forkop-killswitch \
    etc/rc.d/S100forkop-torrserver-direct etc/rc.d/K9forkop-torrserver-direct; do
    [ ! -e "$ROOT/$path" ] && [ ! -L "$ROOT/$path" ] || fail "$path must be removed"
done
for path in etc/rc.d/S50forkop-other etc/rc.d/S10myforkop etc/config/forkopx usr/lib/lua/luci/i18n/other.ru.lmo \
    usr/share/nftables.d/ruleset-post/90-other.nft tmp/unrelated etc/config/firewall.pre-forkop-mirror; do
    [ -e "$ROOT/$path" ] || [ -L "$ROOT/$path" ] || fail "$path is not the old product's and must stay"
done
[ ! -e "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror" ] && grep -Fqx 'original vendor repositories' "$ROOT/etc/opkg/distfeeds.conf" ||
    fail "the repositories must be restored from the .pre-forkop-mirror copy as before"
[ "$(cat "$ROOT/etc/crontabs/root")" = '0 4 * * * /usr/bin/backup' ] || fail "only the old cron lines may go"
[ "$(cat "$ROOT/etc/iproute2/rt_tables")" = "$(printf '100 main\n200 custom')" ] || fail "only the old rt_tables entry may go"

# dnsmasq keeps reading the old servers file (its UCI change failed): the old
# kill-switch state directory stays, everything else of the old product goes.
fixture kept
FAIL_UCI_DELETE=1
export FAIL_UCI_DELETE
run_worker
unset FAIL_UCI_DELETE
grep -Fqx 'server=/example.com/' "$ROOT/etc/forkop/killswitch/dnsmasq.servers" ||
    fail "the servers file dnsmasq still reads must stay"
[ ! -e "$ROOT/etc/forkop/subscription-cache" ] || fail "the rest of the old state directory must go"
grep -Fq 'dnsmasq still uses /etc/forkop/killswitch/dnsmasq.servers' "$ROOT/output" || fail "the kept directory must be reported"

grep -Fq '# Legacy Forkop names' "$SCRIPT" || fail "the legacy names must be one marked block"
printf 'prokop_from_forkop_runtime_uninstall: PASS\n'
