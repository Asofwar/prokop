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
LOCK="$ROOT/tmp/prokop-full-uninstall.lock"
COMPONENT_LOCK="$ROOT/var/run/prokop/component-action.lock"
PACKAGES="luci-i18n-prokop-ru luci-app-prokop prokop sing-box sing-box-tiny sing-box-extended"
PHASE=preflight

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

state() {
    printf '{"state":"%s","phase":"%s"}\n' "$1" "$PHASE" > "$STATUS.new"
    chmod 644 "$STATUS.new"
    mv "$STATUS.new" "$STATUS"
}

finish() {
    code=$?
    trap - EXIT
    if [ "$code" -ne 0 ]; then state failed; fi
    rm -f "$COMPONENT_LOCK/pid"
    rmdir "$COMPONENT_LOCK" 2>/dev/null || true
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
    # A short-lived, non-sensitive status file remains readable after LuCI is
    # uninstalled, so the browser never has to guess whether removal succeeded.
    (sleep 300; rm -f "$STATUS" "$STATUS.new") </dev/null >/dev/null 2>&1 &
    exit "$code"
}

run() {
    trap finish EXIT
    state running
    repository_plan
    if command -v apk >/dev/null 2>&1; then MANAGER=apk
    elif command -v opkg >/dev/null 2>&1; then MANAGER=opkg
    else return 1; fi

    PHASE=stop
    state running
    if [ -x "$ROOT/etc/init.d/prokop" ]; then
        "$ROOT/etc/init.d/prokop" stop
        "$ROOT/etc/init.d/prokop" disable
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
    for package in $PACKAGES; do
        if installed "$package"; then set -- "$@" "$package"; fi
    done
    if [ "$#" -gt 0 ]; then
        if [ "$MANAGER" = apk ]; then apk del "$@"
        else opkg remove "$@"; fi
    fi
    for package in $PACKAGES; do
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
        /etc/init.d/prokop /etc/init.d/prokop-killswitch /etc/init.d/sing-box /etc/uci-defaults/50_luci-prokop \
        /usr/share/luci/menu.d/luci-app-prokop.json /usr/share/rpcd/acl.d/luci-app-prokop.json \
        /usr/share/nftables.d/ruleset-post/90-prokop-killswitch.nft; do
        rm -f "$ROOT$file"
    done
    if [ -z "$ROOT" ]; then
        nft delete table inet ProkopKillswitch 2>/dev/null || true
        if [ "$(uci -q get dhcp.@dnsmasq[0].serversfile 2>/dev/null || true)" = /etc/prokop/killswitch/dnsmasq.servers ]; then
            uci -q delete dhcp.@dnsmasq[0].serversfile && uci -q commit dhcp && /etc/init.d/dnsmasq restart || true
        fi
    fi
    for file in "$ROOT"/usr/lib/lua/luci/i18n/prokop.* \
        "$ROOT"/tmp/luci-indexcache* "$ROOT"/tmp/luci-modulecache/*; do
        [ ! -f "$file" ] || rm -f "$file"
    done
    while IFS='|' read -r file source; do
        rm -f "${file}.pre-forkop-mirror"
    done < "$JOB/repositories"
    # Leave the component lock intact until finish() releases it.
    for item in "$ROOT"/var/run/prokop/*; do
        [ "$item" = "$COMPONENT_LOCK" ] || rm -rf "$item"
    done
    PHASE=complete
    state complete
}

case "${1:-}" in
    start)
        mkdir -p "$ROOT/tmp" "$ROOT/www" "$ROOT/var/run/prokop"
        if ! mkdir "$LOCK" 2>/dev/null; then
            echo '{"success":false,"message":"Removal is already running"}'
            exit 1
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
        cp "$0" "$JOB/worker.sh"
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
