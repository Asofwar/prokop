#!/bin/sh
set -eu
umask 077

# An optional filesystem root is used only by the isolated regression tests.
ROOT="${PROKOP_UNINSTALL_ROOT:-}"
if [ -n "$ROOT" ]; then ROOT="$(cd "$ROOT" && pwd -P)"; fi
# The dependency mirror is opt-in: a set PROKOP_MIRROR_BASE_URL wins, even when
# empty, then UCI. Feeds on the former upstream mirrors are always restored.
if [ "${PROKOP_MIRROR_BASE_URL+set}" = set ]; then MIRROR="$PROKOP_MIRROR_BASE_URL"
else MIRROR="$(uci -q get prokop.settings.mirror_base_url 2>/dev/null || true)"; fi
while [ "${MIRROR%/}" != "$MIRROR" ]; do MIRROR="${MIRROR%/}"; done
BIN="$ROOT/usr/bin/prokop"
# The removal's own variables have names that no environment exports: an
# inherited variable it assigned (a LIB, a RUNNING) would change the
# environment of the init and package scripts it runs.
UNINSTALL_LIB="$ROOT/usr/lib/prokop"
# Only root writes in /var/run/prokop; the lock holds while the process its
# pid file names runs (/usr/bin/prokop full_uninstall_running, CFG-3).
LOCK="$ROOT/var/run/prokop/full-uninstall.lock"
COMPONENT_LOCK="$ROOT/var/run/prokop/component-action.lock"
PACKAGES="luci-i18n-prokop-ru luci-app-prokop prokop sing-box sing-box-tiny sing-box-extended"
PHASE=preflight
# Live router state (nft, UCI, procd, cron) is changed only on the router
# itself; the isolated regression tests opt in with stubbed commands.
if [ -z "$ROOT" ] || [ "${PROKOP_UNINSTALL_LIVE:-}" = 1 ]; then LIVE=1; else LIVE=0; fi

# Legacy Forkop names: what Forkop 1.0.x, the product before the rename,
# leaves on a router. An interrupted migration may leave any of it behind; a
# full removal sweeps it by these explicit names only, never by a name scan.
LEGACY_PACKAGES="luci-i18n-forkop-ru luci-app-forkop forkop"
LEGACY_SERVICES="forkop forkop-killswitch forkop-torrserver-direct"
LEGACY_INIT=/etc/init.d/forkop
LEGACY_BIN=/usr/bin/forkop
LEGACY_NFT_TABLES="ForkopTable ForkopTableDpiGuard ForkopConfigRestore ForkopConfigRestoreDpiGuard
    ForkopAutotuneProbe ForkopAutotuneVerify ForkopTorrServerDirect ForkopKillswitch ForkopVpnGuard"
LEGACY_KILLSWITCH_INCLUDE=/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft
LEGACY_KILLSWITCH_KEEP=/lib/upgrade/keep.d/forkop-killswitch
LEGACY_STATE_DIR=/etc/forkop
LEGACY_KILLSWITCH_DIR=/etc/forkop/killswitch
LEGACY_KILLSWITCH_SERVERSFILE=/etc/forkop/killswitch/dnsmasq.servers
LEGACY_DIRECTORIES="/etc/forkop-backups /usr/lib/forkop /usr/share/forkop /www/luci-static/resources/view/forkop"
LEGACY_FILES="/etc/config/forkop /etc/config/forkop.apk-new /etc/config/forkop.apk-old
    /etc/config/forkop-opkg /etc/config/forkop.opkg-new /etc/config/forkop.opkg-old /etc/config/forkop.opkg-dist
    /usr/bin/forkop /usr/libexec/forkop-ro /etc/init.d/forkop /etc/init.d/forkop-killswitch
    /etc/init.d/forkop-torrserver-direct /etc/uci-defaults/50_luci-forkop
    /usr/share/luci/menu.d/luci-app-forkop.json /usr/share/rpcd/acl.d/luci-app-forkop.json
    /etc/init.d/forkop-guard /etc/hotplug.d/iface/95-forkop-guard /lib/upgrade/keep.d/forkop-guard"
LEGACY_PATH_PREFIXES="/tmp/forkop /var/run/forkop /usr/lib/lua/luci/i18n/forkop."
LEGACY_CRON_MARKER="# forkop-"
LEGACY_RT_TABLE_ID=105
LEGACY_RT_TABLE_NAME=forkop

# detach_servers_file: dnsmasq no longer reads the kill-switch block list.
# 0: it was detached; 1: dhcp could not be changed; 2: dnsmasq did not read
# it. A uci commit of dhcp would also commit what someone staged for dhcp in
# /tmp/.uci (LuCI before Save & Apply), and no option of the uci CLI keeps
# that out: libuci merges /tmp/.uci whatever save directory -t names, and
# then leaves it staged a second time. So, as core/uci.uc does, the option
# is deleted on a copy of dhcp under a package name nobody stages for, and
# the copy replaces dhcp: written next to it with its mode, read back and
# flushed (UC-025), renamed under the lock a uci commit takes and only while
# dhcp still holds what was copied. A dhcp someone committed meanwhile is
# read again. A symbolic link stays one: the file it points to is replaced,
# as a uci commit does.
UNINSTALL_SERVERS_FILE=/etc/prokop/killswitch/dnsmasq.servers
detach_servers_file() {
    dhcp="$ROOT/etc/config/dhcp"
    if [ -L "$dhcp" ]; then dhcp="$(readlink -f "$dhcp")" || return 1; fi
    [ -f "$dhcp" ] || return 2
    copy="$JOB/dhcp"
    staged="$dhcp.prokop-detach.$$"
    attempt=0
    while [ "$attempt" -lt 5 ]; do
        attempt=$((attempt + 1))
        rm -rf "$copy"
        mkdir -p "$copy/save" && cp "$dhcp" "$copy/read" && cp "$copy/read" "$copy/prokop_detach" || return 1
        [ "$(uci -q -c "$copy" -t "$copy/save" get 'prokop_detach.@dnsmasq[0].serversfile' || true)" = \
            "$UNINSTALL_SERVERS_FILE" ] || return 2
        uci -q -c "$copy" -t "$copy/save" delete 'prokop_detach.@dnsmasq[0].serversfile' &&
            uci -q -c "$copy" -t "$copy/save" commit prokop_detach || return 1
        if ! { cp -p "$dhcp" "$staged" && cat "$copy/prokop_detach" > "$staged" &&
            cmp -s "$copy/prokop_detach" "$staged" && sync; }; then
            rm -f "$staged"
            return 1
        fi
        if flock "$dhcp" sh -c 'cmp -s "$1" "$2" && mv -f "$3" "$1"' detach "$dhcp" "$copy/read" "$staged"; then
            # Renamed: dhcp holds the change, whatever this flush reports.
            sync || true
            return 0
        fi
        rm -f "$staged"
    done
    return 1
}

has_mirror() {
    { [ -n "$MIRROR" ] && grep -Fq "$MIRROR/" "$1"; } || grep -Fq 'mirror.51343.ru/' "$1" ||
        grep -Fq 'mirror.infotechtg.ru/' "$1"
}

repository_plan() {
    : > "$JOB/repositories"
    for file in "$ROOT/etc/opkg/distfeeds.conf" "$ROOT/etc/opkg/customfeeds.conf" \
        "$ROOT/etc/apk/repositories" "$ROOT"/etc/apk/repositories.d/*.list; do
        [ -f "$file" ] || continue
        [ "$file" != "$ROOT/etc/apk/repositories.d/forkop.list" ] || continue
        source="${file}.pre-forkop-mirror"
        if [ -f "$source" ] && ! has_mirror "$source"; then
            :
        elif has_mirror "$file"; then
            source="$ROOT/rom${file#"$ROOT"}"
            if [ ! -f "$source" ] || has_mirror "$source"; then
                echo "Cannot restore original repositories: $file" >&2
                return 1
            fi
        else
            continue
        fi
        printf '%s|%s\n' "$file" "$source" >> "$JOB/repositories"
    done
}

installed() {
    if [ "$MANAGER" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed$'; fi
}

# The configuration transactions of Prokop (UC-084): a snapshot create,
# delete, restore or apply (the last two also autotune's) and the snapshot of
# a start or reload, an autotune run, apply or rollback with the probes it
# runs, a change of the autotune policy or its targets (which also writes
# the crontab), an URLTest override. Each runs as
# `ucode -L <lib> <lib>/<module> <mode> ...`, the identity under which the
# snapshot and autotune locks accept an owner. transaction_of <pid> prints
# "<module> <mode>" for such a process and nothing for any other.
transaction_of() {
    # A process may end in between: no message, no transaction.
    tr '\0' '\n' 2>/dev/null <"/proc/$1/cmdline" | (
        read -r _ && read -r flag && read -r lib && read -r module || exit 0
        read -r mode || mode=
        [ "$flag" = -L ] && [ "$lib" = "$UNINSTALL_LIB" ] || exit 0
        case "${module#"$UNINSTALL_LIB/"} $mode" in
            "config/snapshots.uc create" | "config/snapshots.uc delete" | \
            "config/snapshots.uc restore" | "config/snapshots.uc apply" | \
            "config/snapshots.uc confirm-working" | \
            "autotune/apply.uc apply" | "autotune/apply.uc rollback" | \
            "autotune/isolation.uc run" | "autotune/isolation.uc tune" | "autotune/isolation.uc cleanup" | \
            "autotune/manager.uc run" | "autotune/manager.uc run-async" | "autotune/manager.uc run-job" | \
            "autotune/manager.uc if-due" | "autotune/manager.uc apply" | \
            "autotune/manager.uc apply-async" | "autotune/manager.uc apply-job" | \
            "autotune/manager.uc rollback" | "autotune/manager.uc policy-set" | \
            "autotune/manager.uc target-set" | "autotune/manager.uc target-remove" | \
            "config/urltest_override.uc save" | "config/urltest_override.uc reset")
                printf '%s %s\n' "${module#"$UNINSTALL_LIB/"}" "$mode" ;;
        esac
    )
}

# transaction_running: such a transaction runs; UNINSTALL_TRANSACTIONS names
# each one. No grep picks the processes out: OpenWrt's grep is BusyBox's,
# which reads a command line as a C string, up to the NUL after argv[0]. A
# transaction runs the executable its lock requires, ucode, so its comm says
# "ucode": read by a builtin, that leaves transaction_of, and its forks, to
# the few ucode processes.
transaction_running() {
    UNINSTALL_TRANSACTIONS=
    for cmdline in /proc/[0-9]*/cmdline; do
        pid="${cmdline#/proc/}"
        pid="${pid%/cmdline}"
        if ! read -r comm 2>/dev/null <"/proc/$pid/comm" || [ "$comm" != ucode ]; then continue; fi
        found="$(transaction_of "$pid")"
        if [ -n "$found" ]; then
            UNINSTALL_TRANSACTIONS="${UNINSTALL_TRANSACTIONS:+$UNINSTALL_TRANSACTIONS, }$found (pid $pid)"
        fi
    done
    [ -n "$UNINSTALL_TRANSACTIONS" ]
}
UNINSTALL_TRANSACTION_WAIT=60

# LEFT: what of Prokop is still in place (UC-028), comma-separated: its nft
# table and its fwmark rule at priority 105 (by the table's name, by number
# once rt_tables lost it, or by Prokop's fwmark under another name of table
# 105, such as Podkop's: NET-3), which divert traffic to a listener the
# packages take away. With "all" also its lines in the crontab, which would
# call a removed /usr/bin/prokop, and what the removal itself takes away:
# the TorrServer Direct table, the kill-switch table and its fw4 loader,
# and the fail-closed DPI guards. LEFT says it in words for the log,
# LEFT_CODES names the same items for the status the UI reads, which says
# them in the user's language: table:<name>, rule:4, rule:6, cron, loader.
LEFT=
LEFT_CODES=
DPI_GUARD_TABLES="ProkopTableDpiGuard ProkopConfigRestoreDpiGuard"
left_behind() { # left_behind <code> <words>
    LEFT="$LEFT, $2"
    LEFT_CODES="$LEFT_CODES,$1"
}
find_left_behind() {
    LEFT=
    LEFT_CODES=
    if nft -t list table inet ProkopTable >/dev/null 2>&1; then
        left_behind table:ProkopTable "nft table inet ProkopTable"
    fi
    for family in 4 6; do
        if ip "-$family" rule show 2>/dev/null |
            grep -Eq '^105:.*[[:space:]](lookup[[:space:]]+(prokop|105)([[:space:]]|$)|fwmark[[:space:]]+0x0*4000000/0x0*4000000[[:space:]])'; then
            left_behind "rule:$family" "IPv$family rule 105"
        fi
    done
    if [ "${1:-}" = all ]; then
        if grep -Eqs '# prokop-(list-update|subscription-update|component-update-check|autotune|notify)' \
            "$ROOT/etc/crontabs/root"; then
            left_behind cron "lines marked # prokop- in /etc/crontabs/root"
        fi
        for table in ProkopTorrServerDirect ProkopTraffic ProkopKillswitch $DPI_GUARD_TABLES; do
            if nft -t list table inet "$table" >/dev/null 2>&1; then
                left_behind "table:$table" "nft table inet $table"
            fi
        done
        loader=/usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft
        if [ -e "$ROOT$loader" ]; then left_behind loader "kill-switch loader $loader"; fi
        # Kept only behind a link remove_backups does not follow, or when
        # its removal failed.
        if [ -f "$ROOT$UNINSTALL_BACKUP_ARCHIVE" ] && [ ! -L "$ROOT$UNINSTALL_BACKUP_ARCHIVE" ]; then
            left_behind backup "configuration backup $UNINSTALL_BACKUP_ARCHIVE"
        fi
    fi
    LEFT="${LEFT#, }"
    LEFT_CODES="${LEFT_CODES#,}"
}

# The configuration backups (D-10(a), UC-079). Before it installs another
# release, the version picker saves the whole configuration, subscriptions
# and credentials included, as configuration.tar.gz (components/action.uc
# save_prokop_configuration_backup, through a temporary .configuration.XXXXXX
# beside it). The removal promises to delete the settings, so these go too,
# but only these, as regular files of the real directory: a directory that
# is a symbolic link is not followed (what it points at is not Prokop's to
# remove; the final check names the archive left behind it), a link in it
# is no file Prokop wrote (a save replaces it with its archive), and the
# directory itself goes only once nothing else is in it.
UNINSTALL_BACKUP_DIR=/etc/prokop-backups
UNINSTALL_BACKUP_ARCHIVE="$UNINSTALL_BACKUP_DIR/configuration.tar.gz"
remove_backups() {
    [ -d "$ROOT$UNINSTALL_BACKUP_DIR" ] && [ ! -L "$ROOT$UNINSTALL_BACKUP_DIR" ] || return 0
    for file in "$ROOT$UNINSTALL_BACKUP_ARCHIVE" "$ROOT$UNINSTALL_BACKUP_DIR"/.configuration.??????; do
        if [ -f "$file" ] && [ ! -L "$file" ]; then rm -f "$file"; fi
    done
    rmdir "$ROOT$UNINSTALL_BACKUP_DIR" 2>/dev/null || true
}

# The product before the rename is stopped with its own code while it is
# still installed: its stop restores dnsmasq and its kill-switch lifts its own
# policy. A half-removed installation may fail at that; the sweep after the
# package removal takes what is left.
legacy_stop() {
    if [ -x "$ROOT$LEGACY_INIT" ]; then
        "$ROOT$LEGACY_INIT" stop || echo "Could not stop $LEGACY_INIT" >&2
        "$ROOT$LEGACY_INIT" disable || true
    fi
    if [ -x "$ROOT$LEGACY_BIN" ]; then "$ROOT$LEGACY_BIN" killswitch_disable || true; fi
    for service in $LEGACY_SERVICES; do
        [ "/etc/init.d/$service" != "$LEGACY_INIT" ] || continue
        if [ -x "$ROOT/etc/init.d/$service" ]; then
            "$ROOT/etc/init.d/$service" stop || true
            "$ROOT/etc/init.d/$service" disable || true
        fi
    done
    if [ -x "$ROOT$LEGACY_BIN" ]; then "$ROOT$LEGACY_BIN" dnsmasq_restore || true; fi
}

legacy_rc_d_link() {
    name="${1##*/}"
    rest="${name#[SK]}"
    [ "$rest" != "$name" ] || return 1
    digits="${rest%%[!0-9]*}"
    [ -n "$digits" ] || return 1
    case " $LEGACY_SERVICES " in *" ${rest#"$digits"} "*) return 0;; esac
    return 1
}

# Everything else the product before the rename left, after its packages are
# gone. Its kill-switch state directory stays while dnsmasq still reads the
# servers file in it.
legacy_sweep() {
    # The include goes before the table, or a firewall reload loads it again.
    rm -f "$ROOT$LEGACY_KILLSWITCH_INCLUDE" "$ROOT$LEGACY_KILLSWITCH_KEEP"
    keep_killswitch=0
    if [ "$LIVE" = 1 ]; then
        for service in $LEGACY_SERVICES; do
            ubus call service delete "{\"name\":\"$service\"}" >/dev/null 2>&1 || true
        done
        for table in $LEGACY_NFT_TABLES; do
            nft delete table inet "$table" 2>/dev/null || true
        done
        if [ "$(uci -q get dhcp.@dnsmasq[0].serversfile 2>/dev/null || true)" = "$LEGACY_KILLSWITCH_SERVERSFILE" ]; then
            if uci -q delete dhcp.@dnsmasq[0].serversfile && uci -q commit dhcp; then
                [ ! -x "$ROOT/etc/init.d/dnsmasq" ] || "$ROOT/etc/init.d/dnsmasq" restart || true
            else
                keep_killswitch=1
                echo "dnsmasq still uses $LEGACY_KILLSWITCH_SERVERSFILE; keeping $LEGACY_KILLSWITCH_DIR" >&2
            fi
        fi
    fi
    if [ "$keep_killswitch" = 1 ]; then
        for item in "$ROOT$LEGACY_STATE_DIR"/* "$ROOT$LEGACY_STATE_DIR"/.[!.]*; do
            [ -e "$item" ] || [ -L "$item" ] || continue
            [ "$item" = "$ROOT$LEGACY_KILLSWITCH_DIR" ] || rm -rf "$item"
        done
    else
        rm -rf "$ROOT$LEGACY_STATE_DIR"
    fi
    for directory in $LEGACY_DIRECTORIES; do
        rm -rf "$ROOT$directory"
    done
    for file in $LEGACY_FILES; do
        rm -f "$ROOT$file"
    done
    for link in "$ROOT"/etc/rc.d/*; do
        if { [ -e "$link" ] || [ -L "$link" ]; } && legacy_rc_d_link "$link"; then rm -f "$link"; fi
    done
    for prefix in $LEGACY_PATH_PREFIXES; do
        for item in "$ROOT$prefix"*; do
            [ ! -e "$item" ] && [ ! -L "$item" ] || rm -rf "$item"
        done
    done
    crontab="$ROOT/etc/crontabs/root"
    if [ -f "$crontab" ] && grep -Fq "$LEGACY_CRON_MARKER" "$crontab"; then
        grep -Fv "$LEGACY_CRON_MARKER" "$crontab" > "$JOB/crontab" || true
        cat "$JOB/crontab" > "$crontab"
        if [ "$LIVE" = 1 ] && [ -x "$ROOT/etc/init.d/cron" ]; then "$ROOT/etc/init.d/cron" reload || true; fi
    fi
    rt_tables="$ROOT/etc/iproute2/rt_tables"
    rt_pattern="^[[:space:]]*${LEGACY_RT_TABLE_ID}[[:space:]]+${LEGACY_RT_TABLE_NAME}([[:space:]]|\$)"
    if [ -f "$rt_tables" ] && grep -Eq "$rt_pattern" "$rt_tables"; then
        # Replaced whole (UC-076): a cut-short write must not lose the
        # routing tables of the system.
        grep -Ev "$rt_pattern" "$rt_tables" > "$rt_tables.prokop-new" || true
        if ! { chmod 644 "$rt_tables.prokop-new" && sync && mv -f "$rt_tables.prokop-new" "$rt_tables"; }; then
            rm -f "$rt_tables.prokop-new"
            echo "Could not remove the $LEGACY_RT_TABLE_NAME entry from /etc/iproute2/rt_tables" >&2
        fi
    fi
}

state() {
    if [ -n "$LEFT_CODES" ]; then
        printf '{"state":"%s","phase":"%s","left":"%s"}\n' "$1" "$PHASE" "$LEFT_CODES" > "$STATUS.new"
    else
        printf '{"state":"%s","phase":"%s"}\n' "$1" "$PHASE" > "$STATUS.new"
    fi
    chmod 644 "$STATUS.new"
    mv "$STATUS.new" "$STATUS"
}

quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# A short-lived, non-sensitive status file stays readable after LuCI is
# removed, so the browser never has to guess whether the removal succeeded:
# finish() removes it 300 seconds after the end. /www is on flash, and a
# router that restarts before then takes that job with it, so a one-shot
# uci-defaults script removes the status at the next boot instead (OpenWrt
# runs it once and deletes it when it succeeds); the job removes the script
# together with the status.
status_boot_cleanup() {
    mkdir -p "$ROOT/etc/uci-defaults"
    printf '# The status of a full removal of Prokop.\nrm -f %s %s\n' \
        "$(quote "$STATUS")" "$(quote "$STATUS.new")" > "$UNINSTALL_BOOT_CLEANUP"
}

finish() {
    code=$?
    trap - EXIT
    if [ "$code" -ne 0 ]; then state failed; fi
    rm -f "$COMPONENT_LOCK/pid"
    rmdir "$COMPONENT_LOCK" 2>/dev/null || true
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
    (sleep 300; rm -f "$STATUS" "$STATUS.new" "$UNINSTALL_BOOT_CLEANUP") </dev/null >/dev/null 2>&1 &
    exit "$code"
}

run() {
    trap finish EXIT
    state running
    repository_plan
    if command -v apk >/dev/null 2>&1; then MANAGER=apk
    elif command -v opkg >/dev/null 2>&1; then MANAGER=opkg
    else return 1; fi

    # A configuration transaction that began before the removal took its
    # lock may still run (UC-084): it would write /etc/config/prokop, the
    # snapshots or the crontab again after the files below are gone, or keep
    # its nft guard. The CLI refuses new ones from now on (usr/bin/prokop).
    # Wait for the running ones, bounded, before anything is stopped: they
    # take neither the removal's lock nor the component lock (one whose
    # reload the CLI now refuses ends sooner), so waiting while holding both
    # cannot deadlock. One still running then fails the removal with
    # nothing stopped or removed.
    if transaction_running; then
        PHASE=transactions
        state running
        waited=0
        while transaction_running; do
            if [ "$waited" -ge "$UNINSTALL_TRANSACTION_WAIT" ]; then
                echo "Prokop is still changing its configuration: $UNINSTALL_TRANSACTIONS. Nothing was removed; run the removal again once it has finished." >&2
                return 1
            fi
            sleep 1
            waited=$((waited + 1))
        done
    fi

    PHASE=stop
    state running
    stop_status=0
    legacy_stop
    if [ -x "$ROOT/etc/init.d/prokop" ]; then
        "$ROOT/etc/init.d/prokop" stop || stop_status=$?
    fi
    # The exit status of the stop does not tell everything: rc.common drops
    # it unless a hook passes it on, and a stop that could not delete the
    # table or the rule goes on. What decides is what is left. The packages
    # would take away the sing-box that serves it and the code that can take
    # it down, so nothing is disabled, stopped or removed (UC-028). Lines
    # the stop left in the crontab (it could not rewrite it: a full overlay,
    # which no retry or restart changes) divert no traffic: the final check
    # names them.
    find_left_behind
    if [ -n "$LEFT" ]; then
        echo "Prokop is still active after its stop: $LEFT. Nothing was removed; stop Prokop or restart the router, then run the removal again." >&2
        return 1
    fi
    if [ "$stop_status" -ne 0 ]; then
        echo "Prokop could not be stopped (exit status $stop_status). Nothing was removed." >&2
        return 1
    fi
    if [ -x "$ROOT/etc/init.d/prokop" ]; then "$ROOT/etc/init.d/prokop" disable; fi
    # The firewall watcher (NET-4) would reload a Prokop that is going away.
    if [ -x "$ROOT/etc/init.d/prokop-fw-watch" ]; then
        "$ROOT/etc/init.d/prokop-fw-watch" stop || true
        "$ROOT/etc/init.d/prokop-fw-watch" disable || true
    fi
    # TorrServer installed by Prokop goes with it (below); its service first.
    if [ -x "$ROOT/etc/init.d/prokop-torrserver" ]; then
        "$ROOT/etc/init.d/prokop-torrserver" stop || true
        "$ROOT/etc/init.d/prokop-torrserver" disable || true
    fi
    # The package's second service: its stop removes its nft table (UC-083).
    if [ -x "$ROOT/etc/init.d/prokop-torrserver-direct" ]; then
        "$ROOT/etc/init.d/prokop-torrserver-direct" stop
        "$ROOT/etc/init.d/prokop-torrserver-direct" disable
    fi
    # The VPN kill-switch outlives a stopped Prokop by design; removing the
    # product must lift it, or protected traffic would stay blocked forever.
    if [ -x "$BIN" ]; then "$BIN" killswitch_disable || true; fi
    if [ -x "$ROOT/etc/init.d/prokop-killswitch" ]; then
        "$ROOT/etc/init.d/prokop-killswitch" stop || true
        "$ROOT/etc/init.d/prokop-killswitch" disable || true
    fi
    if [ -x "$BIN" ]; then "$BIN" dnsmasq_restore; fi
    if [ -x "$ROOT/etc/init.d/sing-box" ]; then
        "$ROOT/etc/init.d/sing-box" stop
        "$ROOT/etc/init.d/sing-box" disable
    fi

    PHASE=repositories
    state running
    while IFS='|' read -r file source; do
        cp "$source" "$file.prokop-restore"
        chmod 644 "$file.prokop-restore"
        mv "$file.prokop-restore" "$file"
    done < "$JOB/repositories"
    rm -f "$ROOT/etc/apk/repositories.d/forkop.list" "$ROOT/etc/apk/keys/forkop-mirror.pem"

    PHASE=packages
    state running
    set --
    for package in $LEGACY_PACKAGES $PACKAGES; do
        if installed "$package"; then set -- "$@" "$package"; fi
    done
    if [ "$#" -gt 0 ]; then
        if [ "$MANAGER" = apk ]; then apk del "$@"
        else opkg remove "$@"; fi
    fi
    for package in $LEGACY_PACKAGES $PACKAGES; do
        if installed "$package"; then echo "Package was not removed: $package" >&2; return 1; fi
    done

    PHASE=files
    state running
    # Only known product paths are removed. Never recursively delete a path
    # supplied by a UCI option (it might point at /etc or other system data).
    for directory in /etc/prokop /etc/sing-box /tmp/sing-box /usr/lib/prokop \
        /usr/share/prokop /www/luci-static/resources/view/prokop; do
        rm -rf "$ROOT$directory"
    done
    for file in /etc/config/prokop /etc/config/prokop.apk-new /etc/config/prokop.apk-old \
        /etc/config/prokop-opkg /etc/config/prokop.opkg-new /etc/config/prokop.opkg-old \
        /etc/config/prokop.opkg-dist /etc/config/sing-box /etc/config/sing-box.apk-new \
        /etc/config/sing-box.apk-old /etc/config/sing-box-opkg /etc/config/sing-box.opkg-new \
        /etc/config/sing-box.opkg-old /etc/config/sing-box.opkg-dist \
        /usr/bin/prokop /usr/libexec/prokop-ro /usr/bin/sing-box /usr/lib/libcronet.so \
        /etc/init.d/prokop /etc/init.d/prokop-killswitch /etc/init.d/prokop-torrserver-direct \
        /etc/init.d/prokop-torrserver /etc/init.d/prokop-dns-failsafe /etc/init.d/prokop-fw-watch \
        /etc/init.d/sing-box /etc/uci-defaults/50_luci-prokop \
        /usr/share/luci/menu.d/luci-app-prokop.json /usr/share/rpcd/acl.d/luci-app-prokop.json \
        /usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft \
        /usr/share/nftables.d/ruleset-post/90-prokop-killswitch.nft; do
        rm -f "$ROOT$file"
    done
    # zms and zmsA download and run a remote script as root at every start:
    # the launchers Prokop (or Forkop) wrote go with it. One someone else
    # wrote stays (UPD-6).
    for launcher in /usr/bin/zms /usr/bin/zmsA; do
        if [ -f "$ROOT$launcher" ] &&
            grep -Eq '^# (Prokop|Forkop X) Zapret-Manager launcher$|/zapret-manager/proxy/' "$ROOT$launcher"; then
            rm -f "$ROOT$launcher"
        fi
    done
    # The TorrServer binary Prokop installed, while it is still the one its
    # marker names. Its settings and torrent list (the database next to it)
    # stay; a TorrServer installed by other means is not touched.
    torrserver_dir="$ROOT/opt/torrserver"
    if [ -f "$torrserver_dir/prokop-managed.json" ] && [ -f "$torrserver_dir/torrserver" ]; then
        torrserver_sha="$(sha256sum "$torrserver_dir/torrserver" | cut -d' ' -f1)"
        if [ -n "$torrserver_sha" ] && grep -Fq "\"$torrserver_sha\"" "$torrserver_dir/prokop-managed.json"; then
            rm -f "$torrserver_dir/torrserver" "$torrserver_dir/prokop-managed.json"
        fi
    fi
    remove_backups
    # The rc.d links of the removed services. The disable of a release whose
    # TorrServer Direct had START=100 and STOP=9 never removed its links
    # (S100, K9; UC-161).
    rm -f "$ROOT"/etc/rc.d/[SK][0-9][0-9]prokop "$ROOT"/etc/rc.d/[SK][0-9][0-9]prokop-killswitch \
        "$ROOT"/etc/rc.d/[SK][0-9][0-9]prokop-dns-failsafe \
        "$ROOT"/etc/rc.d/[SK][0-9][0-9]prokop-fw-watch \
        "$ROOT"/etc/rc.d/[SK][0-9][0-9]prokop-torrserver-direct \
        "$ROOT"/etc/rc.d/[SK][0-9][0-9]prokop-torrserver \
        "$ROOT/etc/rc.d/S100prokop-torrserver-direct" "$ROOT/etc/rc.d/K9prokop-torrserver-direct"
    # Whatever the kill-switch left (its removal above failed or an older
    # Prokop never lifted it) must not outlive the product (UC-191).
    #
    # The normal path detached the block list already: killswitch_disable
    # above edits dhcp through core/uci.uc (a private copy, replaced only
    # while the file is unchanged, without changes someone staged for dhcp).
    # Prokop's libraries are gone here, and the detach must not be skipped:
    # /etc/prokop with the servers file is already removed, and dnsmasq must
    # not keep reading a file that Prokop no longer owns. detach_servers_file
    # does it the same way in shell, so what someone staged for dhcp in
    # /tmp/.uci stays staged and is not committed (S5: a uci commit of dhcp
    # wrote it too).
    if [ "$LIVE" = 1 ]; then nft delete table inet ProkopKillswitch 2>/dev/null || true; fi
    detached=0
    detach_servers_file || detached=$?
    if [ "$detached" -eq 0 ] && [ -x "$ROOT/etc/init.d/dnsmasq" ]; then
        "$ROOT/etc/init.d/dnsmasq" restart || true
    elif [ "$detached" -eq 1 ]; then
        echo "dnsmasq may still read $UNINSTALL_SERVERS_FILE: /etc/config/dhcp could not be changed." >&2
    fi
    # The fail-closed DPI guards outlive Prokop's stop: the one of a failed
    # transition when its removal failed, the one of a restore or an
    # autotune apply that ended needs_attention always (only a restore,
    # gone with the packages, releases it). Nothing marks DPI traffic for
    # them any more.
    # Per-device traffic accounting goes with Prokop's stop; this catches a
    # stop that did not run or did not finish.
    for table in $DPI_GUARD_TABLES ProkopTraffic; do
        if nft -t list table inet "$table" >/dev/null 2>&1; then
            nft delete table inet "$table" 2>/dev/null || true
        fi
    done
    legacy_sweep
    for file in "$ROOT"/usr/lib/lua/luci/i18n/prokop.* \
        "$ROOT"/tmp/luci-indexcache* "$ROOT"/tmp/luci-modulecache/*; do
        [ ! -f "$file" ] || rm -f "$file"
    done
    while IFS='|' read -r file source; do
        rm -f "${file}.pre-forkop-mirror"
    done < "$JOB/repositories"
    # Leave the locks intact until finish() releases them.
    for item in "$ROOT"/var/run/prokop/*; do
        [ "$item" = "$COMPONENT_LOCK" ] || [ "$item" = "$LOCK" ] || rm -rf "$item"
    done
    # Success only when nothing of Prokop is left (UC-028).
    find_left_behind all
    if [ -n "$LEFT" ]; then
        echo "Prokop was removed, but this is still in place: $LEFT." >&2
        return 1
    fi
    # DPI packages are not Prokop's to remove: the user may run them on their
    # own. Prokop disabled their services, so say they are still there.
    DPI_LEFT=""
    for package in zapret zapret2 byedpi; do
        if installed "$package"; then DPI_LEFT="$DPI_LEFT $package"; fi
    done
    if [ -n "$DPI_LEFT" ]; then
        if [ "$MANAGER" = apk ]; then remove_command="apk del"; else remove_command="opkg remove"; fi
        printf 'Still installed:%s. Prokop disabled their services; enable them again or remove them with: %s%s\n' \
            "$DPI_LEFT" "$remove_command" "$DPI_LEFT" >&2
    fi
    PHASE=complete
    state complete
}

# The removal lock names a running starter or worker of a removal, or was
# made within the last minute and has no pid yet.
removal_lock_held() {
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    case "$holder" in
        '' | *[!0-9]*)
            [ -z "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]
            return
            ;;
    esac
    case "$(tr '\0' ' ' 2>/dev/null <"/proc/$holder/cmdline")" in
        *full-uninstall* | */worker.sh\ worker\ *) return 0 ;;
    esac
    return 1
}

case "${1:-}" in
    start)
        mkdir -p "$ROOT/tmp" "$ROOT/www" "$ROOT/var/run/prokop"
        if ! mkdir "$LOCK" 2>/dev/null; then
            # A removal that was killed left its lock: taken over.
            if removal_lock_held || ! { rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null; }; then
                echo '{"success":false,"message":"Removal is already running"}'
                exit 1
            fi
        fi
        if ! mkdir "$COMPONENT_LOCK" 2>/dev/null; then
            rmdir "$LOCK"
            echo '{"success":false,"message":"Another component action is running"}'
            exit 1
        fi
        trap 'rm -f "$LOCK/pid" "$COMPONENT_LOCK/pid"; rmdir "$LOCK" "$COMPONENT_LOCK" 2>/dev/null || true' EXIT
        printf '%s\n' "$$" > "$LOCK/pid"
        printf '%s\n' "$$" > "$COMPONENT_LOCK/pid"
        JOB="$(mktemp -d "$ROOT/tmp/prokop-uninstall.XXXXXX")"
        STATUS="$ROOT/www/$(basename "$JOB").json"
        UNINSTALL_BOOT_CLEANUP="$ROOT/etc/uci-defaults/99_$(basename "$JOB")"
        cp "$0" "$JOB/worker.sh"
        status_boot_cleanup
        state running
        sh "$JOB/worker.sh" worker "$JOB" "$STATUS" "$$" > "$JOB/output.log" 2>&1 </dev/null 1000>&- &
        trap - EXIT
        # The worker writes its own pid only once it runs. Name it now, so the
        # records never name this starter after it exits: a component action
        # would take such a lock as stale and run alongside the removal.
        printf '%s\n' "$!" > "$LOCK/pid" || true
        printf '%s\n' "$!" > "$COMPONENT_LOCK/pid" || true
        # The worker waits for this mark: a write above after its finish()
        # had removed a record would leave the removal lock behind.
        : > "$JOB/started" || true
        printf '{"success":true,"status_url":"/%s.json"}\n' "$(basename "$JOB")"
        ;;
    worker)
        JOB="$2"
        STATUS="$3"
        UNINSTALL_BOOT_CLEANUP="$ROOT/etc/uci-defaults/99_$(basename "$JOB")"
        # Until the starter ($4) has named this worker in the lock records or
        # has exited, it may still write them.
        waited=0
        while [ -n "${4:-}" ] && [ ! -e "$JOB/started" ] && kill -0 "$4" 2>/dev/null &&
            [ "$waited" -lt 60 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        printf '%s\n' "$$" > "$LOCK/pid"
        printf '%s\n' "$$" > "$COMPONENT_LOCK/pid"
        run
        ;;
    *) exit 2 ;;
esac
