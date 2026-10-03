# shellcheck shell=sh
# shellcheck disable=SC2034,SC2154 # installer variables set and read across the sourced library
# Harness for tests/prokop_from_forkop_installer_*.sh: the installer's switch
# from Forkop (the installation Prokop was renamed from) run under dash, the
# shell closest to BusyBox ash, against a scratch root. Fakes stand in for
# the package manager (with the old backend prerm modelled on
# a657f9cf:forkop/files/usr/lib/service/package.uc prerm_cleanup), the old and
# new init scripts, nft, ubus, conntrack and the UCI module (its state is
# JSON). Every path the installer touches is rebased into the scratch root.
#
# Use: PFF_REPO=<repo> PFF_WORK=<empty dir> dash scenario.sh, where the
# scenario sources this file and calls pff_setup opkg|apk.

pff_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    if [ -n "${PFF_LOG:-}" ] && [ -r "$PFF_LOG" ]; then
        printf -- '--- last installer output (%s) ---\n' "$PFF_LOG" >&2
        tail -n 80 "$PFF_LOG" >&2
    fi
    if [ -r "${PFF_EVENTS:-}" ]; then
        printf -- '--- events ---\n' >&2
        tail -n 80 "$PFF_EVENTS" >&2
    fi
    exit 1
}

pff_assert_exists() {
    [ -e "$1" ] || [ -L "$1" ] || pff_fail "${2:-expected path}: $1 is missing"
}

pff_assert_absent() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        pff_fail "${2:-expected removal}: $1 still exists"
    fi
}

pff_assert_event() {
    grep -Fxq -- "$1" "$PFF_EVENTS" || pff_fail "${2:-expected event}: '$1' was not recorded"
}

pff_refute_event() {
    if grep -Fq -- "$1" "$PFF_EVENTS"; then
        pff_fail "${2:-unexpected event}: '$1' was recorded"
    fi
}

pff_assert_log() {
    grep -Fq -- "$1" "$PFF_LOG" || pff_fail "${2:-expected output}: '$1' is not in the installer output"
}

pff_event_count() {
    grep -Fxc -- "$1" "$PFF_EVENTS" || true
}

pff_installed() {
    [ -e "$FAKE_PKG_DIR/installed/$1" ]
}

# pff_uci EXPRESSION: evaluates a ucode expression with `s` bound to the UCI
# state and prints the result (null prints nothing).
pff_uci() {
    {
        printf '%s\n' 'let s = json(require("fs").readfile(getenv("FAKE_UCI_STATE")));'
        printf '%s\n' 'function dnsmasq() {'
        printf '%s\n' '    for (let name in keys(s.dhcp))'
        printf '%s\n' '        if (s.dhcp[name][".type"] == "dnsmasq")'
        printf '%s\n' '            return s.dhcp[name];'
        printf '%s\n' '    return null;'
        printf '%s\n' '}'
        printf 'let value = (%s);\n' "$1"
        printf '%s\n' 'if (type(value) == "array")'
        printf '%s\n' '    print(join(" ", value), "\n");'
        printf '%s\n' 'else if (value != null)'
        printf '%s\n' '    print(value, "\n");'
    } >"$PFF_WORK/uci-query.uc"
    "$PFF_REAL_UCODE" "$PFF_WORK/uci-query.uc" || pff_fail "ucode could not evaluate: $1"
}

pff_write_fakes() {
    mkdir -p "$PFF_BIN" "$FAKE_UCI_DIR" "$FAKE_NFT_DIR" \
        "$FAKE_PKG_DIR/installed" "$FAKE_PKG_DIR/files" "$FAKE_PKG_DIR/prerm"

    # A UCI cursor over a JSON file. Like libuci it resolves @type[n]
    # sections, keeps changes until commit and refuses options of a missing
    # section. Each commit is logged.
    cat >"$FAKE_UCI_DIR/uci.uc" <<'UC'
let fs = require("fs");

function read_state() {
    let data = fs.readfile(getenv("FAKE_UCI_STATE"));
    return data == null || data == "" ? {} : json(data);
}

function copy(value) {
    return value == null ? null : json(sprintf("%J", value));
}

function resolve(conf, section) {
    if (conf == null || section == null)
        return null;
    let m = match(section, /^@([A-Za-z0-9_]+)\[(-?[0-9]+)\]$/);
    if (!m)
        return conf[section] != null ? section : null;
    let found = [];
    for (let name in keys(conf))
        if (conf[name][".type"] == m[1])
            push(found, name);
    let wanted = int(m[2]);
    if (wanted < 0)
        wanted = length(found) + wanted;
    return found[wanted];
}

return {
    cursor: function() {
        let state = read_state();
        return {
            load: function(conf) {
                state[conf] = read_state()[conf];
                return state[conf] != null;
            },
            get: function(conf, section, option) {
                let name = resolve(state[conf], section);
                if (name == null)
                    return null;
                return option == null ? state[conf][name][".type"] : copy(state[conf][name][option]);
            },
            get_all: function(conf, section) {
                if (state[conf] == null)
                    return null;
                if (section == null) {
                    let all = {};
                    for (let name in keys(state[conf])) {
                        all[name] = copy(state[conf][name]);
                        all[name][".name"] = name;
                    }
                    return all;
                }
                let name = resolve(state[conf], section);
                if (name == null)
                    return null;
                let values = copy(state[conf][name]);
                values[".name"] = name;
                return values;
            },
            set: function(conf, section, option, value) {
                if (state[conf] == null)
                    return null;
                if (value == null) {
                    state[conf][section] = { ".type": option };
                    return true;
                }
                let name = resolve(state[conf], section);
                if (name == null)
                    return null;
                state[conf][name][option] = copy(value);
                return true;
            },
            delete: function(conf, section, option) {
                let name = resolve(state[conf], section);
                if (name == null)
                    return null;
                if (option == null)
                    delete state[conf][name];
                else
                    delete state[conf][name][option];
                return true;
            },
            commit: function(conf) {
                let saved = read_state();
                saved[conf] = state[conf];
                fs.writefile(getenv("FAKE_UCI_STATE"), sprintf("%.2J\n", saved));
                let log = fs.open(getenv("FAKE_UCI_LOG"), "a");
                log.write("commit " + conf + "\n");
                log.close();
                return true;
            }
        };
    }
};
UC

    cat >"$PFF_BIN/ucode" <<'SH'
#!/bin/sh
exec "$PFF_REAL_UCODE" -L "$FAKE_UCI_DIR" "$@"
SH

    cat >"$PFF_BIN/nft" <<'SH'
#!/bin/sh
printf 'nft %s\n' "$*" >>"$PFF_NFT_LOG"
case "$1 $2" in
    "list table"|"list chain"|"flush chain")
        [ -e "$FAKE_NFT_DIR/$4" ]
        exit
        ;;
    "delete table")
        [ -e "$FAKE_NFT_DIR/$4" ] || exit 1
        rm -f "$FAKE_NFT_DIR/$4"
        exit
        ;;
esac
exit 0
SH

    cat >"$PFF_BIN/ubus" <<'SH'
#!/bin/sh
printf 'ubus %s\n' "$*" >>"$PFF_EVENTS"
exit 0
SH

    cat >"$PFF_BIN/conntrack" <<'SH'
#!/bin/sh
printf 'conntrack %s\n' "$*" >>"$PFF_EVENTS"
exit 0
SH

    # The package database: installed/<name> holds the version, files/<name>
    # the root-relative paths the removal deletes, prerm/<name> the script
    # run first (with "remove", as opkg and the apk pre-deinstall of the old
    # packages pass it).
    cat >"$PFF_WORK/package-manager.sh" <<'SH'
#!/bin/sh
db="$FAKE_PKG_DIR"

remove_package() {
    name="$1"
    [ -e "$db/installed/$name" ] || return 0
    [ "${FAKE_PKG_REMOVE_FAILS:-}" != "$name" ] || return 1
    printf 'remove %s\n' "$name" >>"$PFF_EVENTS"
    if [ -x "$db/prerm/$name" ]; then
        "$db/prerm/$name" remove
    fi
    if [ -r "$db/files/$name" ]; then
        while IFS= read -r path; do
            [ -n "$path" ] && rm -rf "$PFF_ROOT$path"
        done <"$db/files/$name"
    fi
    rm -f "$db/installed/$name"
}

install_files() {
    for argument in "$@"; do
        case "$argument" in
            -*) continue ;;
        esac
        file="${argument##*/}"
        name="${file%%_*}"
        version="${file#*_}"
        version="${version%.*}"
        [ "${FAKE_PKG_INSTALL_FAILS:-}" != "$name" ] || return 1
        printf 'install %s %s\n' "$name" "$version" >>"$PFF_EVENTS"
        printf '%s\n' "$version" >"$db/installed/$name"
    done
}

case "${0##*/}" in
    opkg)
        case "$1" in
            list-installed)
                for entry in "$db"/installed/*; do
                    [ -e "$entry" ] || continue
                    printf '%s - %s\n' "${entry##*/}" "$(cat "$entry")"
                done
                ;;
            remove)
                shift
                while [ "${1#-}" != "$1" ]; do shift; done
                remove_package "$1"
                ;;
            install)
                shift
                install_files "$@"
                ;;
        esac
        ;;
    apk)
        case "$1" in
            --version)
                printf '%s\n' 'apk-tools 3.0.0'
                ;;
            info)
                if [ "${2:-}" = -e ]; then
                    [ -e "$db/installed/$3" ] || exit 1
                    printf '%s\n' "$3"
                else
                    for entry in "$db"/installed/*; do
                        [ -e "$entry" ] && printf '%s\n' "${entry##*/}"
                    done
                fi
                ;;
            del)
                shift
                while [ "${1#-}" != "$1" ]; do shift; done
                remove_package "$1"
                ;;
            add)
                shift
                install_files "$@"
                ;;
            list)
                shift
                [ "${1:-}" != --installed ] || shift
                for name in "$@"; do
                    [ -e "$db/installed/$name" ] || continue
                    printf '%s-%s noarch {%s} (GPL-2.0-or-later) [installed]\n' \
                        "$name" "$(cat "$db/installed/$name")" "$name"
                done
                ;;
        esac
        ;;
esac
SH
    chmod 0755 "$PFF_BIN/ucode" "$PFF_BIN/nft" "$PFF_BIN/ubus" "$PFF_BIN/conntrack" \
        "$PFF_WORK/package-manager.sh"

    # The old stop restores dnsmasq like its dns/apply.uc dnsmasq_restore:
    # the forkop_* backups come back and are consumed, the legacy instance
    # goes, and an armed kill-switch attaches its blocking servers file.
    # FAKE_FORKOP_STOP_DNS=keep leaves dnsmasq as it is (a stop that could not
    # restore it); =backups removes 127.0.0.42 but leaves the backups.
    cat >"$PFF_WORK/old-dns-restore.uc" <<'UC'
let fs = require("fs");
let mode = getenv("FAKE_FORKOP_STOP_DNS") || "restore";
if (mode == "keep")
    exit(0);
let s = json(fs.readfile(getenv("FAKE_UCI_STATE")));
let d = null;
for (let name in keys(s.dhcp))
    if (s.dhcp[name][".type"] == "dnsmasq") {
        d = s.dhcp[name];
        break;
    }
d.server = filter(d.server || [], (v) => v != "127.0.0.42");
if (mode == "restore") {
    if (d.forkop_server != null)
        d.server = d.forkop_server;
    d.noresolv = d.forkop_noresolv != null ? d.forkop_noresolv : "0";
    d.cachesize = d.forkop_cachesize != null ? d.forkop_cachesize : "150";
    for (let key in [ "forkop_server", "forkop_noresolv", "forkop_cachesize", "forkop_notinterface" ])
        delete d[key];
    delete s.dhcp.forkop;
}
let blocked = getenv("PFF_ROOT") + "/etc/forkop/killswitch/dns-blocked.servers";
let servers = getenv("PFF_ROOT") + "/etc/forkop/killswitch/dnsmasq.servers";
if (fs.stat(blocked) != null) {
    fs.writefile(servers, fs.readfile(blocked));
    d.serversfile = servers;
}
fs.writefile(getenv("FAKE_UCI_STATE"), sprintf("%.2J\n", s));
UC
}

pff_link_package_manager() {
    rm -f "$PFF_BIN/opkg" "$PFF_BIN/apk"
    ln -s "$PFF_WORK/package-manager.sh" "$PFF_BIN/$1"
}

pff_write_executable() {
    mkdir -p "${1%/*}"
    cat >"$1"
    chmod 0755 "$1"
}

pff_write_system() {
    mkdir -p "$PFF_ROOT/etc/rc.d" "$PFF_ROOT/etc/init.d" "$PFF_ROOT/etc/crontabs" \
        "$PFF_ROOT/etc/iproute2" "$PFF_ROOT/etc/config" "$PFF_ROOT/etc/opkg" "$PFF_ROOT/tmp" \
        "$PFF_ROOT/var/run" "$PFF_ROOT/tmp/luci-modulecache"
    : >"$PFF_ROOT/tmp/luci-indexcache.0"
    : >"$PFF_ROOT/tmp/luci-modulecache/admin.lua"

    for service in dnsmasq rpcd cron; do
        pff_write_executable "$PFF_ROOT/etc/init.d/$service" <<SH
#!/bin/sh
printf '$service %s\n' "\$1" >>"\$PFF_EVENTS"
exit 0
SH
    done

    printf '%s\n' '0 4 * * * /usr/bin/foreign-job # foreign-job' >"$PFF_ROOT/etc/crontabs/root"
    printf '%s\n' '255	local' '254	main' '253	default' '200 vpn' >"$PFF_ROOT/etc/iproute2/rt_tables"
    printf '%s\n' 'src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.4/targets/x/y/packages' \
        >"$PFF_ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
    : >"$FAKE_NFT_DIR/fw4"

    cat >"$FAKE_UCI_STATE" <<'JSON'
{
  "dhcp": {
    "cfg01411c": { ".type": "dnsmasq", "server": [ "8.8.8.8" ], "noresolv": "0", "cachesize": "150" },
    "lan": { ".type": "dhcp", "interface": "lan" }
  },
  "rpcd": {
    "cfg01": { ".type": "rpcd", "socket": "/var/run/ubus/ubus.sock" },
    "cfg02": { ".type": "login", "username": "root", "read": [ "*" ], "write": [ "*" ] }
  },
  "luci": { "main": { ".type": "core", "lang": "auto" } }
}
JSON
}

# pff_install_forkop: a router running Forkop. PFF_KILLSWITCH=1 (default)
# arms its kill-switch, PFF_MANAGED_SING_BOX=1 gives it a binary sing-box
# under its marker instead of a sing-box package, PFF_I18N=1 (default)
# installs its Russian interface, PFF_FORKOP_ENABLED/PFF_FORKOP_RUNNING
# (default 1) set its service state.
pff_install_forkop() {
    root="$PFF_ROOT"
    mkdir -p "$root/usr/lib/forkop/killswitch" "$root/usr/lib/forkop/service" "$root/usr/share/forkop/defaults" \
        "$root/www/luci-static/resources/view/forkop" "$root/usr/share/luci/menu.d" "$root/usr/share/rpcd/acl.d" \
        "$root/etc/uci-defaults" "$root/usr/lib/lua/luci/i18n" "$root/lib/upgrade/keep.d" \
        "$root/usr/share/nftables.d/ruleset-post" "$root/usr/libexec" "$root/var/run/forkop" \
        "$root/var/run/forkop.reload.lock" "$root/tmp/forkop-killswitch" \
        "$root/etc/forkop/tailscale/node" "$root/etc/forkop/lists" "$root/etc/forkop/vpn-guard" \
        "$root/etc/forkop/opkg-package-set-recovery" "$root/etc/forkop-backups"

    cat >"$root/etc/config/forkop" <<'CONFIG'
config settings 'settings'
	option dont_touch_dhcp '0'
	option shutdown_correctly '0'
	list applied_migrations 'fork_mirror_opt_in_v1'

config section 'main'
	option action 'connection'
	option kill_switch '1'
	list selector_proxy_links 'vless://forkop-migration-test'
CONFIG
    chmod 0600 "$root/etc/config/forkop"
    printf '%s\n' "config settings 'settings'" >"$root/usr/share/forkop/defaults/forkop"

    pff_write_executable "$root/etc/init.d/forkop" <<'SH'
#!/bin/sh
printf 'forkop %s source=%s\n' "$1" "${FORKOP_STOP_SOURCE:-}" >>"$PFF_EVENTS"
case "$1" in
    enabled) [ -e "$PFF_ROOT/etc/rc.d/S99forkop" ] ;;
    status)
        if [ -e "$FAKE_NFT_DIR/ForkopTable" ]; then echo running; else echo inactive; fi
        ;;
    running) [ -e "$FAKE_NFT_DIR/ForkopTable" ] ;;
    stop)
        [ "${FAKE_FORKOP_STOP:-ok}" != fail ] || exit 1
        rm -f "$FAKE_NFT_DIR/ForkopTable"
        ucode "$PFF_WORK/old-dns-restore.uc"
        ;;
    disable) rm -f "$PFF_ROOT"/etc/rc.d/S??forkop "$PFF_ROOT"/etc/rc.d/K??forkop ;;
    enable)
        ln -sf ../init.d/forkop "$PFF_ROOT/etc/rc.d/S99forkop"
        ln -sf ../init.d/forkop "$PFF_ROOT/etc/rc.d/K10forkop"
        ;;
    start) : >"$FAKE_NFT_DIR/ForkopTable" ;;
esac
SH
    pff_write_executable "$root/etc/init.d/forkop-killswitch" <<'SH'
#!/bin/sh
printf 'forkop-killswitch %s\n' "$1" >>"$PFF_EVENTS"
case "$1" in
    enabled) [ -e "$PFF_ROOT/etc/rc.d/S20forkop-killswitch" ] ;;
    stop) printf '%s\n' 'forkop-killswitch dns-redirect off' >>"$PFF_EVENTS" ;;
    disable) rm -f "$PFF_ROOT"/etc/rc.d/S??forkop-killswitch "$PFF_ROOT"/etc/rc.d/K??forkop-killswitch ;;
esac
exit 0
SH
    pff_write_executable "$root/etc/init.d/forkop-torrserver-direct" <<'SH'
#!/bin/sh
printf 'forkop-torrserver-direct %s\n' "$1" >>"$PFF_EVENTS"
case "$1" in
    stop) rm -f "$FAKE_NFT_DIR/ForkopTorrServerDirect" ;;
    disable) rm -f "$PFF_ROOT"/etc/rc.d/S??forkop-torrserver-direct ;;
esac
exit 0
SH
    pff_write_executable "$root/usr/bin/forkop" <<'SH'
#!/bin/sh
case "$1" in
    get_status)
        if [ -e "$FAKE_NFT_DIR/ForkopTable" ]; then echo '{"running":1}'; else echo '{"running":0}'; fi
        ;;
esac
exit 0
SH
    pff_write_executable "$root/usr/libexec/forkop-ro" <<'SH'
#!/bin/sh
exit 0
SH
    printf '%s\n' '// killswitch runtime' >"$root/usr/lib/forkop/killswitch/runtime.uc"
    printf '%s\n' '// lifecycle' >"$root/usr/lib/forkop/service/lifecycle.uc"
    printf '%s\n' '// view' >"$root/www/luci-static/resources/view/forkop/main.js"
    printf '%s\n' '{}' >"$root/usr/share/luci/menu.d/luci-app-forkop.json"
    printf '%s\n' '{}' >"$root/usr/share/rpcd/acl.d/luci-app-forkop.json"
    printf '%s\n' '#!/bin/sh' >"$root/etc/uci-defaults/50_luci-forkop"

    if [ "${PFF_FORKOP_ENABLED:-1}" = 1 ]; then
        ln -s ../init.d/forkop "$root/etc/rc.d/S99forkop"
        ln -s ../init.d/forkop "$root/etc/rc.d/K10forkop"
    fi
    ln -s ../init.d/forkop-killswitch "$root/etc/rc.d/S20forkop-killswitch"
    ln -s ../init.d/forkop-torrserver-direct "$root/etc/rc.d/S99forkop-torrserver-direct"
    if [ "${PFF_FORKOP_RUNNING:-1}" = 1 ]; then
        : >"$FAKE_NFT_DIR/ForkopTable"
    fi
    : >"$FAKE_NFT_DIR/ForkopTorrServerDirect"
    : >"$FAKE_NFT_DIR/ForkopConfigRestore"

    printf '%s\n' 'tailscale node key' >"$root/etc/forkop/tailscale/node/node.key"
    printf '%s\n' 'list cache' >"$root/etc/forkop/lists/russia_inside.lst"
    printf '%s\n' '{}' >"$root/etc/forkop/vpn-guard/policy.json"
    printf '%s\n' 'old ipk' >"$root/etc/forkop/opkg-package-set-recovery/forkop.ipk"
    printf '%s\n' 'hidden' >"$root/etc/forkop/.ui-state"
    # Its subscription cache: an older format, with its own outbound keys.
    mkdir -p "$root/etc/forkop/subscription-cache"
    printf '%s\n' 9 >"$root/etc/forkop/subscription-cache/cache-format"
    printf '%s\n' '{"outbounds":[{"tag":"node","__forkop_hidden":true}]}' \
        >"$root/etc/forkop/subscription-cache/main-1.json"
    printf '%s\n' 'backup archive' >"$root/etc/forkop-backups/configuration.tar.gz"
    printf '%s\n' '12345' >"$root/var/run/forkop/list-update.pid"
    printf '%s\n' '1' >"$root/tmp/forkop-package-was-running"
    printf '%s\n' 'standby' >"$root/tmp/forkop-killswitch/standby.conf"

    printf '%s\n' \
        '0 4 * * * /usr/bin/forkop list_update # forkop-list-update' \
        '0 3 * * * /usr/bin/forkop subscription_update # forkop-subscription-update' \
        >>"$root/etc/crontabs/root"
    printf '%s\n' '105 forkop' >>"$root/etc/iproute2/rt_tables"
    printf '%s\n' '/etc/forkop/killswitch/' '/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft' \
        >"$root/lib/upgrade/keep.d/forkop-killswitch"

    printf '%s\n' /etc/init.d/forkop /etc/init.d/forkop-killswitch /etc/init.d/forkop-torrserver-direct \
        /usr/bin/forkop /usr/libexec/forkop-ro /usr/lib/forkop /usr/share/forkop \
        /lib/upgrade/keep.d/forkop-killswitch >"$FAKE_PKG_DIR/files/forkop"
    printf '%s\n' /www/luci-static/resources/view/forkop /usr/share/luci/menu.d/luci-app-forkop.json \
        /usr/share/rpcd/acl.d/luci-app-forkop.json /etc/uci-defaults/50_luci-forkop \
        >"$FAKE_PKG_DIR/files/luci-app-forkop"
    printf '%s\n' 1.0.26 >"$FAKE_PKG_DIR/installed/forkop"
    printf '%s\n' 1.0.26 >"$FAKE_PKG_DIR/installed/luci-app-forkop"
    if [ "${PFF_I18N:-1}" = 1 ]; then
        printf '%s\n' 'lmo' >"$root/usr/lib/lua/luci/i18n/forkop.ru.lmo"
        printf '%s\n' '#!/bin/sh' >"$root/etc/uci-defaults/luci-i18n-forkop-ru"
        printf '%s\n' /usr/lib/lua/luci/i18n/forkop.ru.lmo >"$FAKE_PKG_DIR/files/luci-i18n-forkop-ru"
        printf '%s\n' 1.0.26 >"$FAKE_PKG_DIR/installed/luci-i18n-forkop-ru"
    fi

    # The old backend prerm (/usr/bin/forkop package_prerm remove): its own
    # stop, the kill-switch lift while killswitch/runtime.uc exists, the
    # removal of a sing-box under its marker, the "105 forkop" line.
    pff_write_executable "$FAKE_PKG_DIR/prerm/forkop" <<'SH'
#!/bin/sh
[ -x "$PFF_ROOT/usr/bin/forkop" ] || exit 0
runtime=absent
[ ! -e "$PFF_ROOT/usr/lib/forkop/killswitch/runtime.uc" ] || runtime=present
printf 'old prerm %s killswitch-runtime=%s\n' "$1" "$runtime" >>"$PFF_EVENTS"
FORKOP_STOP_SOURCE=package "$PFF_ROOT/etc/init.d/forkop" stop
if [ "$runtime" = present ]; then
    printf '%s\n' 'old prerm lifted the kill-switch' >>"$PFF_EVENTS"
    rm -f "$FAKE_NFT_DIR/ForkopKillswitch" "$PFF_ROOT/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft"
fi
if grep -Fq 'Forkop managed sing-box service for binary variants' "$PFF_ROOT/etc/init.d/sing-box" 2>/dev/null; then
    printf '%s\n' 'old prerm removed the managed sing-box' >>"$PFF_EVENTS"
    rm -f "$PFF_ROOT/etc/init.d/sing-box" "$PFF_ROOT/usr/bin/sing-box" "$PFF_ROOT/usr/lib/libcronet.so"
fi
if [ "${FAKE_PRERM_LOSES_SING_BOX:-0}" = 1 ]; then
    rm -f "$PFF_ROOT/usr/bin/sing-box"
fi
grep -v '105 forkop' "$PFF_ROOT/etc/iproute2/rt_tables" >"$PFF_WORK/rt_tables.prerm"
cat "$PFF_WORK/rt_tables.prerm" >"$PFF_ROOT/etc/iproute2/rt_tables"
exit 0
SH

    if [ "${PFF_MANAGED_SING_BOX:-0}" = 1 ]; then
        mkdir -p "$root/usr/lib"
        pff_write_executable "$root/etc/init.d/sing-box" <<'SH'
#!/bin/sh /etc/rc.common
# Forkop managed sing-box service for binary variants

START=99
SH
        pff_write_executable "$root/usr/bin/sing-box" <<'SH'
#!/bin/sh
echo 'sing-box version 1.13.0'
SH
        printf '%s\n' 'cronet' >"$root/usr/lib/libcronet.so"
        printf '%s\n' 'extended-compressed' >"$root/etc/forkop/sing-box-variant"
    else
        printf '%s\n' 1.13.0 >"$FAKE_PKG_DIR/installed/sing-box"
        printf '%s\n' 'stable' >"$root/etc/forkop/sing-box-variant"
    fi

    if [ "${PFF_KILLSWITCH:-1}" = 1 ]; then
        mkdir -p "$root/etc/forkop/killswitch"
        printf '%s\n' 'server=/blocked.example/' >"$root/etc/forkop/killswitch/dns-blocked.servers"
        : >"$root/etc/forkop/killswitch/dnsmasq.servers"
        printf '%s\n' '{"active":true}' >"$root/etc/forkop/killswitch/state.json"
        printf '%s\n' 'table inet ForkopKillswitch {}' \
            >"$root/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft"
        : >"$FAKE_NFT_DIR/ForkopKillswitch"
    fi

    PFF_ROOT_FOR_UCI="$root" PFF_KILLSWITCH="${PFF_KILLSWITCH:-1}" "$PFF_REAL_UCODE" -e '
        let fs = require("fs");
        let path = getenv("FAKE_UCI_STATE");
        let root = getenv("PFF_ROOT_FOR_UCI");
        let s = json(fs.readfile(path));
        let d = s.dhcp.cfg01411c;
        d.forkop_server = d.server;
        d.forkop_noresolv = d.noresolv;
        d.forkop_cachesize = d.cachesize;
        d.server = [ "127.0.0.42" ];
        d.noresolv = "1";
        d.cachesize = "0";
        if (getenv("PFF_KILLSWITCH") != "0")
            d.serversfile = root + "/etc/forkop/killswitch/dnsmasq.servers";
        s.rpcd.cfg03 = {
            ".type": "login", username: "viewer", password: "$p$viewer",
            read: [ "luci-app-forkop", "luci-base" ],
            write: [ "luci-app-forkop-admin", "luci-app-prokop-admin" ]
        };
        s.forkop = { settings: { ".type": "settings", dont_touch_dhcp: "0" } };
        fs.writefile(path, sprintf("%.2J\n", s));
    ' || pff_fail "failed to write the Forkop UCI fixture"
}

# The Prokop backend package as the release installs it, without its
# postinst (which needs a router), but with the persistent subscription cache
# of the current format the postinst creates (config/migration.uc
# ensure_runtime_cache_format). Its prerm, like the real one
# (/usr/bin/prokop package_prerm), restores dnsmasq while its executable is
# there. Its service/package.uc records when the installer runs it and what
# its legacy cleanup would find: it does nothing while the old init script
# exists, and reads the saved flow offload from the old guard's policy.
pff_materialize_prokop_backend() {
    root="$PFF_ROOT"
    mkdir -p "$root/usr/lib/prokop/config" "$root/usr/lib/prokop/service" "$root/usr/share/prokop/defaults"
    if [ ! -e "$root/etc/prokop/subscription-cache/cache-format" ]; then
        mkdir -p "$root/etc/prokop/subscription-cache"
        printf '%s\n' 10 >"$root/etc/prokop/subscription-cache/cache-format"
    fi
    cat >"$root/usr/lib/prokop/service/package.uc" <<'UC'
let fs = require("fs");
let root = getenv("PFF_ROOT");
let log = fs.open(getenv("PFF_EVENTS"), "a");
log.write(sprintf("prokop package.uc %s forkop-init=%s vpn-guard-policy=%s\n", ARGV[0],
    fs.stat(root + "/etc/init.d/forkop") != null ? "present" : "absent",
    fs.stat(root + "/etc/forkop/vpn-guard/policy.json") != null ? "present" : "absent"));
log.close();
UC
    printf '%s\n' "config settings 'settings'" "	option mirror_base_url ''" \
        >"$root/usr/share/prokop/defaults/prokop"
    if [ ! -e "$root/etc/config/prokop" ]; then
        cp "$root/usr/share/prokop/defaults/prokop" "$root/etc/config/prokop"
        chmod 0644 "$root/etc/config/prokop"
        printf '%s\n' /etc/config/prokop >"$PFF_WORK/prokop-config-created-by-package"
    fi
    pff_write_executable "$root/usr/bin/prokop" <<'SH'
#!/bin/sh
printf 'prokop-bin %s\n' "$*" >>"$PFF_EVENTS"
exit 0
SH
    pff_write_executable "$root/etc/init.d/prokop" <<'SH'
#!/bin/sh
printf 'prokop %s\n' "$1" >>"$PFF_EVENTS"
case "$1" in
    enabled) [ -e "$PFF_ROOT/etc/rc.d/S99prokop" ] ;;
    enable) ln -sf ../init.d/prokop "$PFF_ROOT/etc/rc.d/S99prokop" ;;
    disable) rm -f "$PFF_ROOT/etc/rc.d/S99prokop" ;;
    start) : >"$FAKE_NFT_DIR/ProkopTable" ;;
    status) echo inactive ;;
    running) [ -e "$FAKE_NFT_DIR/ProkopTable" ] ;;
esac
SH
    printf '%s\n' /usr/bin/prokop /usr/lib/prokop /usr/share/prokop /etc/init.d/prokop \
        >"$FAKE_PKG_DIR/files/prokop"
    pff_write_executable "$FAKE_PKG_DIR/prerm/prokop" <<'SH'
#!/bin/sh
[ -x "$PFF_ROOT/usr/bin/prokop" ] || exit 0
printf '%s\n' 'prokop prerm restored dnsmasq' >>"$PFF_EVENTS"
exit 0
SH
}

pff_rebase_paths() {
    for variable in \
        LEGACY_FORKOP_CONFIG LEGACY_FORKOP_INIT LEGACY_FORKOP_KILLSWITCH_INIT LEGACY_FORKOP_TORRSERVER_INIT \
        LEGACY_FORKOP_INIT_GLOB LEGACY_FORKOP_BIN LEGACY_FORKOP_LIB LEGACY_FORKOP_KILLSWITCH_RUNTIME \
        LEGACY_FORKOP_SHARE_DIR LEGACY_FORKOP_LIBEXEC_RO LEGACY_FORKOP_STATE_DIR LEGACY_FORKOP_BACKUP_DIR \
        LEGACY_FORKOP_RUN_GLOB LEGACY_FORKOP_TMP_GLOB LEGACY_FORKOP_KILLSWITCH_INCLUDE \
        LEGACY_FORKOP_KILLSWITCH_KEEP LEGACY_FORKOP_KILLSWITCH_STATE_DIR LEGACY_FORKOP_LUCI_VIEW_DIR \
        LEGACY_FORKOP_LUCI_MENU LEGACY_FORKOP_LUCI_ACL LEGACY_FORKOP_LUCI_UCI_DEFAULTS \
        LEGACY_FORKOP_I18N_UCI_DEFAULTS LEGACY_FORKOP_LUCI_I18N_GLOB LEGACY_FORKOP_MIGRATION_MARKER \
        LEGACY_FORKOP_MIGRATION_DIR UPSTREAM_APK_REPOSITORY_FILE UPSTREAM_APK_KEY_FILE \
        PROKOP_TARGET_CONFIG PROKOP_TARGET_DEFAULT_CONFIG PROKOP_TARGET_STATE_DIR PROKOP_TARGET_BACKUPS_DIR \
        PROKOP_TARGET_BIN PROKOP_TARGET_LIB SING_BOX_INIT_SCRIPT SING_BOX_BINARY SYSTEM_RC_DIR \
        SYSTEM_CRONTAB SYSTEM_CRON_INIT SYSTEM_RT_TABLES SYSTEM_DHCP_CONFIG SYSTEM_RPCD_CONFIG; do
        eval "value=\${$variable}"
        case "$value" in
            /*) ;;
            *) pff_fail "$variable is not an absolute path: $value" ;;
        esac
        eval "$variable=\"\$PFF_ROOT\$value\""
    done

    # Every absolute path of the legacy block is rebased above: a new one
    # would otherwise reach the real system from the tests.
    sed -n '/^# Legacy Forkop names$/,/^# End of legacy Forkop names$/p' "$PFF_REPO/install.sh" |
        sed -n 's/^\([A-Z_][A-Z0-9_]*\)="\/.*$/\1/p' >"$PFF_WORK/legacy-path-variables"
    [ -s "$PFF_WORK/legacy-path-variables" ] || pff_fail "the legacy names block of install.sh was not found"
    while IFS= read -r variable; do
        [ "$variable" != LEGACY_FORKOP_MIRROR_PLATFORM_INDEX ] || continue
        eval "value=\${$variable}"
        case "$value" in
            "$PFF_ROOT"/*) ;;
            *) pff_fail "the harness does not rebase $variable: $value" ;;
        esac
    done <"$PFF_WORK/legacy-path-variables"
}

pff_stub_installer() {
    TMP_DIR="$PFF_WORK/tmp"
    mkdir -p "$TMP_DIR"
    CONFIRM_LEGACY_MIGRATION="${PFF_CONFIRM:-1}"
    MIRROR_BASE_URL=""

    interactive_terminal_available() { return 1; }

    # The release channel serves PFF_RELEASE_VERSION (2.0.0 by default).
    resolve_prokop_release() {
        pff_extension=ipk
        [ "$PKG_IS_APK" -eq 0 ] || pff_extension=apk
        pff_version="${PFF_RELEASE_VERSION:-2.0.0}"
        PROKOP_RELEASE_TAG="$pff_version"
        PROKOP_RELEASE_SOURCE="the test release channel"
        PROKOP_PACKAGE_VERSION="$pff_version"
        PROKOP_BACKEND_NAME="prokop_$pff_version.$pff_extension"
        PROKOP_APP_NAME="luci-app-prokop_$pff_version.$pff_extension"
        PROKOP_I18N_NAME=""
        PROKOP_I18N_URL=""
        if [ "$PROKOP_I18N_REQUESTED" -eq 1 ]; then
            PROKOP_I18N_NAME="luci-i18n-prokop-ru_$pff_version.$pff_extension"
            PROKOP_I18N_URL="https://example.invalid/$PROKOP_I18N_NAME"
        fi
    }

    download_prokop_packages() {
        PROKOP_BACKEND_FILE="$TMP_DIR/$PROKOP_BACKEND_NAME"
        PROKOP_APP_FILE="$TMP_DIR/$PROKOP_APP_NAME"
        PROKOP_I18N_FILE=""
        printf '%s\n' backend >"$PROKOP_BACKEND_FILE"
        printf '%s\n' app >"$PROKOP_APP_FILE"
        if [ -n "$PROKOP_I18N_URL" ]; then
            PROKOP_I18N_FILE="$TMP_DIR/$PROKOP_I18N_NAME"
            printf '%s\n' i18n >"$PROKOP_I18N_FILE"
        fi
        printf '%s\n' 'download prokop' >>"$PFF_EVENTS"
    }

    ensure_flash_space() {
        printf 'flash plan with %s KB of copied state\n' "$LEGACY_FORKOP_COPY_KB" >>"$PFF_EVENTS"
    }

    install_backend_package() {
        pkg_install_prokop_file prokop "$PROKOP_BACKEND_FILE" || fail "prokop installation failed"
        pff_materialize_prokop_backend
    }

    legacy_forkop_migrate_configuration() {
        printf 'migrate %s\n' "$(sed -n 's/.*selector_proxy_links .\(.*\).$/\1/p' "$PROKOP_TARGET_CONFIG")" \
            >>"$PFF_EVENTS"
        [ "${FAKE_MIGRATE_FAILS:-0}" = 0 ]
    }

    legacy_forkop_run_validator() {
        printf 'validate sing-box=%s\n' "$SING_BOX_INSTALL_VARIANT" >>"$PFF_EVENTS"
        if [ "${FAKE_VALIDATION_FAILS:-0}" = 1 ]; then
            printf '%s\n' 'Checking required packages' 'Section main has no usable outbound. Aborted.' >"$1"
            return 1
        fi
        : >"$1"
    }

    validate_installed_configuration() {
        PROKOP_CONFIG_READY=1
        PROKOP_CONFIG_VALIDATION_ERROR=""
        if [ "${FAKE_FINAL_VALIDATION_FAILS:-0}" = 1 ]; then
            PROKOP_CONFIG_READY=0
            PROKOP_CONFIG_VALIDATION_ERROR="sing-box is missing"
        fi
    }

    install_selected_sing_box() {
        printf 'sing-box install variant=%s\n' "${SING_BOX_INSTALL_VARIANT:-none}" >>"$PFF_EVENTS"
    }
}

# pff_setup opkg|apk
pff_setup() {
    [ -n "${PFF_REPO:-}" ] && [ -n "${PFF_WORK:-}" ] || pff_fail "PFF_REPO and PFF_WORK must be set"
    PFF_REAL_UCODE="$(command -v ucode)" || pff_fail "ucode is required"
    PFF_ROOT="$PFF_WORK/root"
    PFF_BIN="$PFF_WORK/bin"
    PFF_EVENTS="$PFF_WORK/events.log"
    PFF_NFT_LOG="$PFF_WORK/nft.log"
    FAKE_UCI_DIR="$PFF_WORK/fake-uci"
    FAKE_UCI_STATE="$PFF_WORK/uci.json"
    FAKE_UCI_LOG="$PFF_WORK/uci-commits.log"
    FAKE_NFT_DIR="$PFF_WORK/nft"
    FAKE_PKG_DIR="$PFF_WORK/packages"
    PFF_RUN=0
    export PFF_REAL_UCODE PFF_ROOT PFF_WORK PFF_EVENTS PFF_NFT_LOG FAKE_UCI_DIR FAKE_UCI_STATE \
        FAKE_UCI_LOG FAKE_NFT_DIR FAKE_PKG_DIR

    mkdir -p "$PFF_ROOT"
    : >"$PFF_EVENTS"
    : >"$PFF_NFT_LOG"
    : >"$FAKE_UCI_LOG"
    pff_write_fakes
    pff_link_package_manager "$1"
    pff_write_system
    PATH="$PFF_BIN:$PATH"
    export PATH

    export PROKOP_INSTALLER_INIT="$PFF_ROOT/etc/init.d/prokop"
    export PROKOP_INSTALLER_BIN="$PFF_ROOT/usr/bin/prokop"
    export PROKOP_INSTALLER_RC_DIR="$PFF_ROOT/etc/rc.d"
    export PROKOP_INSTALLER_RPCD_INIT="$PFF_ROOT/etc/init.d/rpcd"
    export PROKOP_INSTALLER_DNSMASQ_INIT="$PFF_ROOT/etc/init.d/dnsmasq"
    export PROKOP_INSTALLER_LUCI_CACHE_GLOBS="$PFF_ROOT/var/luci-indexcache* $PFF_ROOT/tmp/luci-indexcache*"
    export PROKOP_INSTALLER_LUCI_MODULE_CACHE_GLOBS="$PFF_ROOT/tmp/luci-modulecache"
    export PROKOP_INSTALLER_LATEST_VERSION_CACHE="$PFF_ROOT/tmp/prokop.latest-version.cache"
    export PROKOP_INSTALLER_SYSTEM_INFO_CACHE="$PFF_ROOT/var/run/prokop/system-info.json"
    export PROKOP_INSTALLER_SERVER_COUNTRY_CACHE="$PFF_ROOT/var/run/prokop/server-country-cache.json"
    export PROKOP_INSTALLER_SING_BOX_VERSION_CACHE="$PFF_ROOT/var/run/prokop/ui-state/sing-box-version"
    export PROKOP_INSTALLER_TMP_SYSTEM_INFO_CACHE="$PFF_ROOT/tmp/prokop/system-info.json"
    export PROKOP_INSTALLER_SERVICE_PROBE_TIMEOUT=5
    export PROKOP_INSTALLER_SERVICE_ACTION_TIMEOUT=20
    export PROKOP_INSTALLER_LEGACY_FORKOP_STOP_TIMEOUT=20
    unset PROKOP_MIRROR_BASE_URL

    sed '/^main "\$@"$/d' "$PFF_REPO/install.sh" >"$PFF_WORK/install-library.sh"
    # shellcheck disable=SC1091
    . "$PFF_WORK/install-library.sh"
    if [ "$1" = apk ]; then PKG_IS_APK=1; else PKG_IS_APK=0; fi
    pff_rebase_paths
    pff_stub_installer
}

pff_interrupt() {
    printf 'interrupted at %s\n' "$PFF_INTERRUPT" >>"$PFF_EVENTS"
    exit 3
}

# One installer run, from detection to the end of main, in a subshell (as a
# separate run of the installer would be). Its output goes to PFF_LOG.
# PFF_INTERRUPT names an installer function at which the run is cut off
# without any failure handling, as a power loss would.
pff_run_installer() {
    PFF_RUN=$((PFF_RUN + 1))
    PFF_LOG="$PFF_WORK/run.$PFF_RUN.log"
    printf -- '--- run %s ---\n' "$PFF_RUN" >>"$PFF_EVENTS"
    (
        if [ -n "${PFF_INTERRUPT:-}" ]; then
            eval "$PFF_INTERRUPT() { pff_interrupt; }"
        fi
        legacy_forkop_detect_installation
        detect_legacy_installation
        detect_install_mode
        decide_i18n_installation
        select_sing_box_installation || fail "sing-box selection was cancelled"
        if legacy_forkop_mode; then
            legacy_forkop_migrate
            print_installation_summary
            legacy_forkop_print_result
        else
            printf 'NOT MIGRATED: mode %s\n' "$INSTALL_MODE"
        fi
    ) >"$PFF_LOG" 2>&1
}

# A digest of the old installation's files and the router state it relies
# on, to prove a rollback left them as they were.
pff_forkop_digest() {
    (
        cd "$PFF_ROOT" || exit 1
        find etc/config/forkop etc/forkop etc/forkop-backups etc/init.d etc/rc.d usr/bin/forkop usr/lib/forkop \
            usr/share/forkop usr/libexec/forkop-ro www usr/share/luci usr/share/rpcd lib/upgrade \
            usr/share/nftables.d etc/crontabs etc/iproute2 -print 2>/dev/null | LC_ALL=C sort |
            while IFS= read -r path; do
                if [ -L "$path" ]; then
                    printf 'L %s -> %s\n' "$path" "$(readlink "$path")"
                elif [ -f "$path" ]; then
                    printf 'F %s %s\n' "$path" "$(cksum <"$path")"
                else
                    printf 'D %s\n' "$path"
                fi
            done
        printf 'nft %s\n' "$(ls "$FAKE_NFT_DIR" | LC_ALL=C sort | tr '\n' ' ')"
        printf 'packages %s\n' "$(ls "$FAKE_PKG_DIR/installed" | LC_ALL=C sort | tr '\n' ' ')"
        pff_uci 'sprintf("%J", s.dhcp)'
        pff_uci 'sprintf("%J", s.rpcd)'
    )
}
