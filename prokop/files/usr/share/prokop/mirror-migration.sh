#!/bin/sh
# Reconciles the OpenWrt package feeds with the Prokop dependency mirror
# setting. Every package install and upgrade runs it from postinst; the
# installer runs it once more after it saved an opted-in mirror.
#
# The mirror is opt-in: PROKOP_MIRROR_BASE_URL wins whenever it is set, even
# to the empty string; otherwise prokop.settings.mirror_base_url applies, and
# an empty value means no mirror. A mirror problem never fails the package:
# each one only prints a warning, leaves the feeds as they were and exits 0.
set -u

SETTINGS_SECTION="prokop.settings"
MIGRATION_ROOT="${PROKOP_MIGRATION_ROOT:-}"
APK_BIN="${PROKOP_MIGRATION_APK_BIN:-apk}"
OPKG_BIN="${PROKOP_MIGRATION_OPKG_BIN:-opkg}"
CURL_BIN="${PROKOP_MIGRATION_CURL_BIN:-curl}"
UCI_BIN="${PROKOP_MIGRATION_UCI_BIN:-uci}"
OFFICIAL_RELEASES_URL="https://downloads.openwrt.org/releases/"
OFFICIAL_RELEASES_REGEX='https://downloads\.openwrt\.org/releases/'
# Former upstream mirrors. They are recognised only to move feeds off them
# and are never used unless configured explicitly.
LEGACY_MIRROR_REGEX='https?://mirror\.(infotechtg|51343)\.ru/'

warn() {
    echo "Prokop mirror: $*" >&2
}

root_path() {
    printf '%s%s\n' "$MIGRATION_ROOT" "$1"
}

# The content of source becomes destination: a copy next to it, read back,
# renamed over it. Feeds and keys are never truncated and rewritten in
# place, where a crash or a full overlay left them cut short and package
# management broken (UC-076). The copy is flushed before the rename and the
# rename after it, as core/durable.uc does (UC-025): on UBIFS the rename
# reaches the flash before the data, and a power cut in between left an
# empty feed. An existing destination keeps its mode.
replace_file() {
    source="$1"
    destination="$2"
    staged="$destination.prokop-new.$$"
    rm -f "$staged"
    if [ -e "$destination" ]; then
        cp -p "$destination" "$staged" && cat "$source" > "$staged"
    else
        cp "$source" "$staged" && chmod 0644 "$staged"
    fi && cmp -s "$source" "$staged" && sync && mv -f "$staged" "$destination" && {
        # Renamed: destination holds the content, whatever this flush reports.
        sync
        return 0
    }
    rm -f "$staged"
    return 1
}

if [ "${PROKOP_MIRROR_BASE_URL+set}" = set ]; then
    MIRROR_BASE_URL="$PROKOP_MIRROR_BASE_URL"
else
    MIRROR_BASE_URL="$("$UCI_BIN" -q get "$SETTINGS_SECTION.mirror_base_url" 2>/dev/null || true)"
fi
while [ "${MIRROR_BASE_URL%/}" != "$MIRROR_BASE_URL" ]; do
    MIRROR_BASE_URL="${MIRROR_BASE_URL%/}"
done

repositories="$(root_path /etc/apk/repositories)"
repositories_dir="$(root_path /etc/apk/repositories.d)"
keys_dir="$(root_path /etc/apk/keys)"
opkg_distfeeds="$(root_path /etc/opkg/distfeeds.conf)"
opkg_customfeeds="$(root_path /etc/opkg/customfeeds.conf)"

# apk trusts every key in /etc/apk/keys for every repository, and the former
# upstream mirror feed carries upstream Forkop builds that would replace this
# one. Prokop never installs either any more; remove what older releases left.
for upstream_file in "$repositories_dir/forkop.list" "$keys_dir/forkop-mirror.pem"; do
    [ -e "$upstream_file" ] || [ -L "$upstream_file" ] || continue
    if rm -f "$upstream_file"; then
        echo "Removed the former upstream Forkop package source $upstream_file"
    else
        warn "could not remove $upstream_file"
    fi
done

PACKAGE_MANAGER=""
if command -v "$APK_BIN" >/dev/null 2>&1; then
    PACKAGE_MANAGER="apk"
elif command -v "$OPKG_BIN" >/dev/null 2>&1; then
    PACKAGE_MANAGER="opkg"
else
    exit 0
fi

TRANSACTION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prokop-mirror-migration.XXXXXX" 2>/dev/null)" || {
    warn "no temporary directory; package feeds were not changed"
    exit 0
}
TRANSACTION_MANIFEST="$TRANSACTION_DIR/manifest"
TRANSACTION_ACTIVE=0
TRANSACTION_COUNT=0
USED_BACKUPS="$TRANSACTION_DIR/used-backups"
: > "$TRANSACTION_MANIFEST"
: > "$USED_BACKUPS"

# Files the rollback could not restore (UC-076).
ROLLBACK_FAILED=""

rollback_transaction() {
    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0

    while IFS='|' read -r destination backup original_state; do
        [ -n "$destination" ] || continue
        if [ "$original_state" = "absent" ]; then
            rm -f "$destination" 2>/dev/null || true
            [ ! -e "$destination" ] || ROLLBACK_FAILED="$ROLLBACK_FAILED $destination"
        elif [ ! -f "$backup" ] || ! replace_file "$backup" "$destination" 2>/dev/null; then
            ROLLBACK_FAILED="$ROLLBACK_FAILED $destination"
        fi
    done < "$TRANSACTION_MANIFEST"
    TRANSACTION_ACTIVE=0
}

# An interrupted run restores the feeds it had already changed; files it
# could not restore are named rather than reported as restored.
finish() {
    rollback_transaction
    [ -z "$ROLLBACK_FAILED" ] || warn "could not restore:$ROLLBACK_FAILED"
    rm -rf "$TRANSACTION_DIR"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

backup_transaction_file() {
    destination="$1"
    backup="$TRANSACTION_DIR/original.$TRANSACTION_COUNT"

    if [ -e "$destination" ]; then
        cp "$destination" "$backup" || return 1
        printf '%s|%s|present\n' "$destination" "$backup" >> "$TRANSACTION_MANIFEST"
    else
        printf '%s||absent\n' "$destination" >> "$TRANSACTION_MANIFEST"
    fi
    TRANSACTION_COUNT=$((TRANSACTION_COUNT + 1))
}

replace_repository_file() {
    destination="$1"
    replacement="$2"

    if cmp -s "$destination" "$replacement"; then
        rm -f "$replacement"
        return 0
    fi
    backup_transaction_file "$destination" || return 1
    replace_file "$replacement" "$destination" || return 1
    rm -f "$replacement"
}

# Writes $1 to $2 with every OpenWrt release feed moved to the release tree
# $3 (a URL ending in /releases/, $4 is the same as an ERE). The remaining
# arguments are sed expressions that move a feed host to that tree. Older
# mirrors served a vNN.x/vX.Y.Z/<target>/<subtarget> layout; it becomes the
# standard OpenWrt layout under the new tree.
rewrite_release_feeds() {
    input="$1"
    output="$2"
    tree="$3"
    tree_regex="$4"
    shift 4

    sed -E "$@" \
        -e "s#${tree_regex}v[0-9]+\\.x/v?([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/?([[:space:]]|$)#${tree}\\1/targets/\\2/\\3/packages\\4#" \
        -e "s#${tree_regex}v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages/packages\\.adb#${tree}\\1/targets/\\2/\\3/packages/packages.adb#" \
        -e "s#${tree_regex}v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages\\.adb#${tree}\\1/packages/\\2/\\3/packages.adb#" \
        "$input" > "$output"
}

mirror_repository_file() {
    repository_file="$1"
    [ -e "$repository_file" ] || return 0

    temporary="$TRANSACTION_DIR/repository.$TRANSACTION_COUNT.new"
    rewrite_release_feeds "$repository_file" "$temporary" \
        "$MIRROR_BASE_URL/openwrt/releases/" "$MIRROR_REGEX/openwrt/releases/" \
        -e "s#${LEGACY_MIRROR_REGEX}openwrt/releases/#${MIRROR_BASE_URL}/openwrt/releases/#" \
        -e "s#https?://(downloads|archive)\\.openwrt\\.org/releases/#${MIRROR_BASE_URL}/openwrt/releases/#" \
        -e "s#https?://[^/]+/pub/software/openwrt/releases/#${MIRROR_BASE_URL}/openwrt/releases/#" ||
        return 1

    if grep -E 'https?://(downloads|archive)\.openwrt\.org/releases/|https?://[^/]+/pub/software/openwrt/releases/' "$temporary" >/dev/null; then
        warn "could not move every official OpenWrt feed in $repository_file to $MIRROR_BASE_URL"
        return 1
    fi
    cmp -s "$repository_file" "$temporary" && { rm -f "$temporary"; return 0; }

    persistent_backup="${repository_file}.pre-forkop-mirror"
    [ -e "$persistent_backup" ] || replace_file "$repository_file" "$persistent_backup" || return 1
    replace_repository_file "$repository_file" "$temporary"
}

# Puts back a feed file that still points at a former upstream mirror: its
# release feeds move to downloads.openwrt.org in the current file, so edits
# made since the mirror was applied stay. Only when former-mirror lines would
# remain elsewhere does the copy saved before the mirror was first applied
# replace the file, and only when that copy is free of them.
restore_repository_file() {
    repository_file="$1"
    [ -f "$repository_file" ] || return 0
    grep -Eq "$LEGACY_MIRROR_REGEX" "$repository_file" || return 0

    temporary="$TRANSACTION_DIR/repository.$TRANSACTION_COUNT.new"
    persistent_backup="${repository_file}.pre-forkop-mirror"
    rewrite_release_feeds "$repository_file" "$temporary" \
        "$OFFICIAL_RELEASES_URL" "$OFFICIAL_RELEASES_REGEX" \
        -e "s#${LEGACY_MIRROR_REGEX}openwrt/releases/#${OFFICIAL_RELEASES_URL}#" || return 1
    if grep -Eq "$LEGACY_MIRROR_REGEX" "$temporary" &&
        [ -f "$persistent_backup" ] && ! grep -Eq "$LEGACY_MIRROR_REGEX" "$persistent_backup"; then
        cp "$persistent_backup" "$temporary" || return 1
    fi

    if grep -Eq "$LEGACY_MIRROR_REGEX" "$temporary"; then
        warn "$repository_file still names a former upstream mirror outside its OpenWrt release feeds; those lines were left unchanged"
    elif [ -f "$persistent_backup" ]; then
        # The restored file supersedes the saved copy: neither a later
        # restore nor the full uninstall may put that older copy back.
        printf '%s\n' "$persistent_backup" >> "$USED_BACKUPS"
    fi
    replace_repository_file "$repository_file" "$temporary"
}

update_package_index() {
    if [ "$PACKAGE_MANAGER" = "apk" ]; then
        "$APK_BIN" update </dev/null
    else
        "$OPKG_BIN" update </dev/null
    fi
}

read_release_value() {
    key="$1"
    release_file="$(root_path /etc/openwrt_release)"

    [ -f "$release_file" ] || return 0
    sed -n "s/^${key}='\(.*\)'/\1/p" "$release_file" 2>/dev/null | head -n 1
}

# The mirror must carry this exact OpenWrt platform before any feed moves.
mirror_has_platform() {
    release="$(read_release_value DISTRIB_RELEASE)"
    target="$(read_release_value DISTRIB_TARGET)"
    architecture="$(read_release_value DISTRIB_ARCH)"
    format="$PACKAGE_MANAGER"
    [ "$format" != "opkg" ] || format="ipk"

    [ -n "$release" ] && [ -n "$target" ] && [ -n "$architecture" ] || return 0
    platform_index="$TRANSACTION_DIR/forkop-platforms.tsv"
    if ! "$CURL_BIN" -fsSL --connect-timeout 15 --max-time 60 \
        "$MIRROR_BASE_URL/openwrt/forkop-platforms.tsv" -o "$platform_index"; then
        warn "the platform index of $MIRROR_BASE_URL is unavailable; package feeds were not changed"
        return 1
    fi

    if awk -v target="$target" -v architecture="$architecture" \
        -v release="$release" -v format="$format" '
            /^[[:space:]]*(#|$)/ { next }
            $1 == target && $2 == architecture && $3 == release && $4 == format { found = 1 }
            END { exit(found ? 0 : 1) }
        ' "$platform_index"; then
        return 0
    fi

    warn "$MIRROR_BASE_URL does not carry $target / $architecture for OpenWrt $release ($format); package feeds were not changed"
    return 1
}

use_mirror() {
    case "$MIRROR_BASE_URL" in
        http://?*|https://?*) ;;
        *) warn "invalid mirror URL '$MIRROR_BASE_URL'; package feeds were not changed"; return 0 ;;
    esac
    # The URL lands in sed expressions; a narrow character set keeps it literal.
    case "$MIRROR_BASE_URL" in
        *[!A-Za-z0-9._~:/%-]*)
            warn "unsupported characters in mirror URL '$MIRROR_BASE_URL'; package feeds were not changed"
            return 0 ;;
    esac
    MIRROR_REGEX="$(printf '%s\n' "$MIRROR_BASE_URL" | sed 's/\./\\./g')"
    mirror_has_platform || return 0

    TRANSACTION_ACTIVE=1
    if [ "$PACKAGE_MANAGER" = "apk" ]; then
        mirror_repository_file "$repositories" &&
            mirror_repository_file "$repositories_dir/distfeeds.list"
    else
        mirror_repository_file "$opkg_distfeeds"
    fi || {
        rollback_transaction
        [ -n "$ROLLBACK_FAILED" ] || warn "package feeds were left unchanged"
        return 0
    }

    # Package managers hold their database lock while package scripts run:
    # never call apk/opkg from postinst. Elsewhere the new index is checked
    # before the change is kept.
    if [ "$TRANSACTION_COUNT" -gt 0 ] && [ "${PROKOP_PACKAGE_POSTINST:-0}" != "1" ] &&
        ! update_package_index; then
        rollback_transaction
        if [ -n "$ROLLBACK_FAILED" ]; then
            warn "the package index of $MIRROR_BASE_URL could not be loaded"
        else
            warn "the package index of $MIRROR_BASE_URL could not be loaded; the previous feeds were restored"
        fi
        return 0
    fi
    TRANSACTION_ACTIVE=0
    [ "$TRANSACTION_COUNT" -eq 0 ] || echo "OpenWrt package feeds now use $MIRROR_BASE_URL"
}

# Without a mirror only feeds that still point at a former upstream mirror
# are restored; feeds on any other host are left alone. The file set matches
# the full uninstall.
restore_official_feeds() {
    TRANSACTION_ACTIVE=1
    for repository_file in "$opkg_distfeeds" "$opkg_customfeeds" "$repositories" \
        "$repositories_dir"/*.list; do
        restore_repository_file "$repository_file" || {
            rollback_transaction
            if [ -n "$ROLLBACK_FAILED" ]; then
                warn "could not restore $repository_file"
            else
                warn "could not restore $repository_file; package feeds were left unchanged"
            fi
            return 0
        }
    done
    TRANSACTION_ACTIVE=0
    [ "$TRANSACTION_COUNT" -gt 0 ] || return 0

    # The restored feeds supersede their saved originals; a later opt-in
    # saves fresh ones.
    while IFS= read -r used_backup; do
        rm -f "$used_backup"
    done < "$USED_BACKUPS"
    echo "OpenWrt package feeds no longer use the former upstream mirror"
    if [ "${PROKOP_PACKAGE_POSTINST:-0}" != "1" ] && ! update_package_index; then
        warn "the package index could not be refreshed; run '$PACKAGE_MANAGER update' later"
    fi
}

if [ -n "$MIRROR_BASE_URL" ]; then
    use_mirror
else
    restore_official_feeds
fi
exit 0
