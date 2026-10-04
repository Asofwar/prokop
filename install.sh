#!/bin/sh
# shellcheck shell=dash

RELEASE_REPO="${PROKOP_RELEASE_REPO:-Asofwar/prokop}"
RELEASE_BASE_URL="${PROKOP_RELEASE_BASE_URL:-https://asofwar.github.io/prokop}"
# The dependency mirror is opt-in (--mirror URL or PROKOP_MIRROR_BASE_URL).
# Empty keeps the official OpenWrt feeds and the direct download sources.
MIRROR_BASE_URL="${PROKOP_MIRROR_BASE_URL:-}"
MIRROR_MIGRATION_SCRIPT="/usr/share/prokop/mirror-migration.sh"
APK_REPOSITORIES_FILE="/etc/apk/repositories"
APK_DISTFEEDS_FILE="/etc/apk/repositories.d/distfeeds.list"

# Legacy Forkop names
# Prokop is the renamed Forkop. These are the names that an installation of
# this fork's Forkop or of the upstream Forkop, and the upstream package feed,
# left on a router. The installer only detects, hands over and removes them,
# so they keep their old spelling; no line outside this block names the old
# product (identifiers say legacy_forkop instead).
LEGACY_FORKOP_BRAND="Forkop"
# Upstream installations leave a feed of upstream Forkop builds and its key;
# apk trusts every key in /etc/apk/keys for every repository.
UPSTREAM_APK_REPOSITORY_FILE="/etc/apk/repositories.d/forkop.list"
UPSTREAM_APK_KEY_FILE="/etc/apk/keys/forkop-mirror.pem"
# The original feed file kept before the first mirror rewrite. It is still
# the current suffix (mirror-migration.sh and the full uninstall read it).
LEGACY_FORKOP_FEED_BACKUP_SUFFIX=".pre-forkop-mirror"
# The dependency mirror keeps the upstream layout.
LEGACY_FORKOP_MIRROR_PLATFORM_INDEX="/openwrt/forkop-platforms.tsv"
LEGACY_FORKOP_PACKAGE_BACKEND="forkop"
LEGACY_FORKOP_PACKAGE_APP="luci-app-forkop"
LEGACY_FORKOP_PACKAGE_I18N="luci-i18n-forkop-ru"
LEGACY_FORKOP_CONFIG_NAME="forkop"
LEGACY_FORKOP_CONFIG="/etc/config/forkop"
LEGACY_FORKOP_INIT="/etc/init.d/forkop"
LEGACY_FORKOP_KILLSWITCH_INIT="/etc/init.d/forkop-killswitch"
LEGACY_FORKOP_TORRSERVER_INIT="/etc/init.d/forkop-torrserver-direct"
# Its rc.d links are S/K, the START/STOP number (one to three digits:
# S100forkop-torrserver-direct, K9forkop-torrserver-direct) and one of these.
LEGACY_FORKOP_SERVICES="forkop forkop-killswitch forkop-torrserver-direct"
LEGACY_FORKOP_INIT_GLOB="/etc/init.d/forkop*"
# The old service/initd.uc tells Forkop's own stop for a package change from
# the user's stop by this variable.
LEGACY_FORKOP_STOP_SOURCE="FORKOP_STOP_SOURCE=package"
LEGACY_FORKOP_BIN="/usr/bin/forkop"
LEGACY_FORKOP_LIB="/usr/lib/forkop"
LEGACY_FORKOP_KILLSWITCH_RUNTIME="/usr/lib/forkop/killswitch/runtime.uc"
LEGACY_FORKOP_SHARE_DIR="/usr/share/forkop"
LEGACY_FORKOP_LIBEXEC_RO="/usr/libexec/forkop-ro"
LEGACY_FORKOP_STATE_DIR="/etc/forkop"
LEGACY_FORKOP_BACKUP_DIR="/etc/forkop-backups"
# Not copied: the kill-switch, guard and package recovery state, and the
# subscription cache with its __forkop_* outbound keys. The Prokop postinst
# creates its own empty cache of the current format first, so a copied old
# cache would pass as current; subscriptions are downloaded again instead.
LEGACY_FORKOP_STATE_SKIP="killswitch vpn-guard opkg-package-set-recovery subscription-cache"
LEGACY_FORKOP_RUN_GLOB="/var/run/forkop*"
LEGACY_FORKOP_TMP_GLOB="/tmp/forkop*"
LEGACY_FORKOP_NFT_MAIN_TABLE="ForkopTable"
LEGACY_FORKOP_NFT_TABLES="ForkopTable ForkopTableDpiGuard ForkopConfigRestore ForkopConfigRestoreDpiGuard ForkopAutotuneProbe ForkopAutotuneVerify ForkopTorrServerDirect"
LEGACY_FORKOP_KILLSWITCH_TABLE="ForkopKillswitch"
LEGACY_FORKOP_KILLSWITCH_DNS_CHAIN="ks_dns"
LEGACY_FORKOP_KILLSWITCH_INCLUDE="/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft"
LEGACY_FORKOP_KILLSWITCH_KEEP="/lib/upgrade/keep.d/forkop-killswitch"
LEGACY_FORKOP_KILLSWITCH_STATE_DIR="/etc/forkop/killswitch"
LEGACY_FORKOP_RT_TABLE_ID="105"
LEGACY_FORKOP_RT_TABLE_NAME="forkop"
LEGACY_FORKOP_CRON_MARKER="# forkop-"
LEGACY_FORKOP_DHCP_SECTION="forkop"
LEGACY_FORKOP_DHCP_OPTION_PREFIX="forkop_"
LEGACY_FORKOP_SING_BOX_MARKER="Forkop managed sing-box service for binary variants"
LEGACY_FORKOP_ACL_GROUPS="luci-app-forkop luci-app-forkop-admin"
LEGACY_FORKOP_LUCI_VIEW_DIR="/www/luci-static/resources/view/forkop"
LEGACY_FORKOP_LUCI_MENU="/usr/share/luci/menu.d/luci-app-forkop.json"
LEGACY_FORKOP_LUCI_ACL="/usr/share/rpcd/acl.d/luci-app-forkop.json"
LEGACY_FORKOP_LUCI_UCI_DEFAULTS="/etc/uci-defaults/50_luci-forkop"
LEGACY_FORKOP_I18N_UCI_DEFAULTS="/etc/uci-defaults/luci-i18n-forkop-ru"
LEGACY_FORKOP_LUCI_I18N_GLOB="/usr/lib/lua/luci/i18n/forkop.*"
# Resume marker of an interrupted migration (its stage name is inside) and
# the directory with the recorded state and the backups of the migration.
LEGACY_FORKOP_MIGRATION_MARKER="/etc/prokop/.migrating-from-forkop"
LEGACY_FORKOP_MIGRATION_DIR="/etc/prokop-forkop-migration"
# End of legacy Forkop names

# Prokop and system paths of the migration from the renamed installation.
PROKOP_TARGET_CONFIG="/etc/config/prokop"
PROKOP_TARGET_DEFAULT_CONFIG="/usr/share/prokop/defaults/prokop"
PROKOP_TARGET_STATE_DIR="/etc/prokop"
PROKOP_TARGET_BACKUPS_DIR="/etc/prokop-backups"
PROKOP_TARGET_BIN="/usr/bin/prokop"
PROKOP_TARGET_LIB="/usr/lib/prokop"
PROKOP_TARGET_ACL_GROUPS="luci-app-prokop luci-app-prokop-admin"
PROKOP_TARGET_SING_BOX_MARKER="Prokop managed sing-box service for binary variants"
SING_BOX_INIT_SCRIPT="/etc/init.d/sing-box"
SING_BOX_BINARY="/usr/bin/sing-box"
SYSTEM_RC_DIR="/etc/rc.d"
SYSTEM_CRONTAB="/etc/crontabs/root"
SYSTEM_CRON_INIT="/etc/init.d/cron"
SYSTEM_RT_TABLES="/etc/iproute2/rt_tables"
SYSTEM_DHCP_CONFIG="/etc/config/dhcp"
SYSTEM_RPCD_CONFIG="/etc/config/rpcd"

# Former upstream mirrors. Without an opted-in mirror the OpenWrt release feeds
# an upstream installation moved there go back to the official release tree,
# as /usr/share/prokop/mirror-migration.sh restores them.
LEGACY_MIRROR_REGEX='https?://mirror\.(infotechtg|51343)\.ru/'
OFFICIAL_RELEASES_URL="https://downloads.openwrt.org/releases/"
OFFICIAL_RELEASES_REGEX='https://downloads\.openwrt\.org/releases/'

FLASH_RESERVE_KB=1024
PACKAGE_INSTALL_OVERHEAD_KB=512
PACKAGE_ARCHIVE_SPACE_FACTOR=2
MISSING_DEPENDENCY_ALLOWANCE_KB=256
APK_WORLD_FILE="${PROKOP_APK_WORLD_FILE:-/etc/apk/world}"
OPKG_DISTFEEDS_FILE="${PROKOP_OPKG_DISTFEEDS_FILE:-/etc/opkg/distfeeds.conf}"
CONNECT_TIMEOUT_SECONDS=15
METADATA_TIMEOUT_SECONDS=60
DOWNLOAD_TIMEOUT_SECONDS=600

PKG_IS_APK=0
MIRROR_TRANSACTION_ACTIVE=0
MIRROR_BACKUP_COUNT=0
MIRROR_BACKUP_MANIFEST=""
MIRROR_SETTING_SAVED=0
OPENWRT_RELEASE=""
OPENWRT_TARGET=""
OPENWRT_ARCHITECTURE=""
FETCHER=""
TMP_DIR=""
PROKOP_WAS_ENABLED=0
PROKOP_WAS_RUNNING=0
PROKOP_LEGACY_DETECTED=0
LEGACY_CLEANUP_DONE=0
LEGACY_CLEANUP_STARTED=0
PROKOP_I18N_REQUESTED=0
INSTALLER_LANG="ru"
INSTALLER_LANG_EXPLICIT=0
INSTALLER_LANG_DETECTED=0
SING_BOX_INSTALL_VARIANT=""
SING_BOX_INSTALL_VARIANT_EXPLICIT=0
SING_BOX_TINY_FILE=""
SING_BOX_TINY_SWITCHED=0
SING_BOX_CHANGE_STARTED=0
ALLOW_LOW_SPACE_TINY=0
CONFIRM_LEGACY_MIGRATION=0

PROKOP_RELEASE_JSON=""
PROKOP_RELEASE_SOURCE=""
PROKOP_RELEASE_TAG=""
PROKOP_BACKEND_URL=""
PROKOP_BACKEND_SHA256=""
PROKOP_BACKEND_NAME=""
PROKOP_BACKEND_FILE=""
PROKOP_APP_URL=""
PROKOP_APP_SHA256=""
PROKOP_APP_NAME=""
PROKOP_APP_FILE=""
PROKOP_I18N_URL=""
PROKOP_I18N_SHA256=""
PROKOP_I18N_NAME=""
PROKOP_I18N_FILE=""
PROKOP_INSTALL_REQUIRED_KB=0
PROKOP_PACKAGE_VERSION=""
PROKOP_CONFIG_READY=1
PROKOP_CONFIG_VALIDATION_ERROR=""
INSTALL_MODE="clean"
LEGACY_BRAND="$(printf '\160\157\144\153\157\160')"
LEGACY_BACKEND_PACKAGE="${LEGACY_BRAND}-plus"
LEGACY_CONFIG_PACKAGE_ALT="${LEGACY_BRAND}_plus"
LEGACY_CONFIG_BACKUP=""
LEGACY_CONFIG_PATH=""
LEGACY_FORKOP_DETECTED=0
LEGACY_FORKOP_RESUME_STAGE=""
LEGACY_FORKOP_STAGE=""
LEGACY_FORKOP_ACTIVE=0
LEGACY_FORKOP_CHANGES_STARTED=0
LEGACY_FORKOP_POINT_OF_NO_RETURN=0
LEGACY_FORKOP_FAILURE_HANDLED=0
LEGACY_FORKOP_I18N_INSTALLED=0
LEGACY_FORKOP_MANAGED_SING_BOX=0
LEGACY_FORKOP_WAS_ENABLED=0
LEGACY_FORKOP_WAS_RUNNING=0
LEGACY_FORKOP_COPY_KB=0
LEGACY_FORKOP_KEEP_BACKUPS=0

command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

msg() {
    printf '\033[32;1m%s\033[0m\n' "$1"
}

warn() {
    printf '\033[33;1m%s\033[0m\n' "$1"
}

fail() {
    legacy_forkop_on_failure
    rollback_legacy_config_on_failure
    restore_current_prokop_on_failure
    printf '\033[31;1m%s\033[0m\n' "$1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [options]

Installs or updates Prokop packages:
  - prokop
  - luci-app-prokop
  - luci-i18n-prokop-ru when requested or when LuCI language is Russian

sing-box policy:
  - preserve the currently installed sing-box variant
  - ask for tiny, stable, or extended when sing-box is absent
  - install sing-box-tiny by default without an interactive terminal

Interactive setup:
  - choose Russian or English on a clean installation
  - choose tiny, stable, or extended on a clean installation

Selection options:
  --language, --lang ru|en   Select the installer language without a prompt
  --sing-box tiny|stable|extended
                             Select sing-box without a prompt on a clean install

Automation options (must be explicitly requested):
  --allow-low-space-tiny       Allow stable/extended sing-box to be replaced
                               with tiny when no interactive terminal exists
  --confirm-legacy-migration   Confirm removal and migration of a detected
                               legacy installation without an interactive terminal
                               (also the switch from the installation that
                               Prokop was renamed from)

Dependency mirror (off by default):
  --mirror URL                 Use a dependency mirror for the OpenWrt package
                               feeds, lists, rule sets and sing-box downloads.
                               It is saved as prokop.settings.mirror_base_url.
                               Without it the official OpenWrt feeds and the
                               direct download sources are used.

Environment:
  PROKOP_MIRROR_BASE_URL       Same as --mirror (the option takes precedence)
  PROKOP_RELEASE_BASE_URL      Release channel (default: $RELEASE_BASE_URL)
  PROKOP_RELEASE_REPO          GitHub owner/name whose releases are used when
                               the release channel is unavailable
                               (default: $RELEASE_REPO)
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --allow-low-space-tiny)
                ALLOW_LOW_SPACE_TINY=1
                ;;
            --confirm-legacy-migration)
                CONFIRM_LEGACY_MIGRATION=1
                ;;
            --language|--lang)
                [ "$#" -ge 2 ] || fail "$1 requires ru or en"
                case "$2" in
                    ru|en)
                        INSTALLER_LANG="$2"
                        INSTALLER_LANG_EXPLICIT=1
                        ;;
                    *)
                        fail "$1 requires ru or en"
                        ;;
                esac
                shift
                ;;
            --language=*|--lang=*)
                language_value="${1#*=}"
                case "$language_value" in
                    ru|en)
                        INSTALLER_LANG="$language_value"
                        INSTALLER_LANG_EXPLICIT=1
                        ;;
                    *)
                        fail "$1 requires ru or en"
                        ;;
                esac
                ;;
            --sing-box)
                [ "$#" -ge 2 ] || fail "$1 requires tiny, stable, or extended"
                case "$2" in
                    tiny|stable|extended)
                        SING_BOX_INSTALL_VARIANT="$2"
                        SING_BOX_INSTALL_VARIANT_EXPLICIT=1
                        ;;
                    *)
                        fail "$1 requires tiny, stable, or extended"
                        ;;
                esac
                shift
                ;;
            --sing-box=*)
                sing_box_value="${1#*=}"
                case "$sing_box_value" in
                    tiny|stable|extended)
                        SING_BOX_INSTALL_VARIANT="$sing_box_value"
                        SING_BOX_INSTALL_VARIANT_EXPLICIT=1
                        ;;
                    *)
                        fail "$1 requires tiny, stable, or extended"
                        ;;
                esac
                ;;
            --mirror)
                if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                    fail "$1 requires a mirror URL"
                fi
                MIRROR_BASE_URL="$2"
                shift
                ;;
            --mirror=*)
                MIRROR_BASE_URL="${1#*=}"
                [ -n "$MIRROR_BASE_URL" ] || fail "--mirror requires a mirror URL"
                ;;
            *)
                fail "Unknown installer option: $1"
                ;;
        esac
        shift
    done
}

strip_trailing_slashes() {
    stripped_value="$1"
    while :; do
        case "$stripped_value" in
            */) stripped_value="${stripped_value%/}" ;;
            *) break ;;
        esac
    done
    printf '%s\n' "$stripped_value"
}

validate_installer_settings() {
    release_owner=""
    release_name=""
    case "$RELEASE_REPO" in
        */*)
            release_owner="${RELEASE_REPO%%/*}"
            release_name="${RELEASE_REPO#*/}"
            ;;
    esac
    case "$release_owner" in
        ''|*[!A-Za-z0-9-]*) fail "PROKOP_RELEASE_REPO must be a GitHub owner/name: $RELEASE_REPO" ;;
    esac
    case "$release_name" in
        ''|.|..|*[!A-Za-z0-9._-]*) fail "PROKOP_RELEASE_REPO must be a GitHub owner/name: $RELEASE_REPO" ;;
    esac

    RELEASE_BASE_URL="$(strip_trailing_slashes "$RELEASE_BASE_URL")"
    case "$RELEASE_BASE_URL" in
        https://?*|http://?*) ;;
        *) fail "PROKOP_RELEASE_BASE_URL must use http:// or https://: $RELEASE_BASE_URL" ;;
    esac

    MIRROR_BASE_URL="$(strip_trailing_slashes "$MIRROR_BASE_URL")"
    [ -n "$MIRROR_BASE_URL" ] || return 0
    case "$MIRROR_BASE_URL" in
        https://?*|http://?*) ;;
        *)
            fail "Invalid dependency mirror URL: $MIRROR_BASE_URL (expected http:// or https://)"
            ;;
    esac
    # The URL lands in sed expressions here and in mirror-migration.sh; both
    # accept the same narrow character set, which keeps it literal there.
    case "$MIRROR_BASE_URL" in
        *[!A-Za-z0-9._~:/%-]*)
            fail "Invalid dependency mirror URL: $MIRROR_BASE_URL (only letters, digits and . _ ~ : / % - are supported)"
            ;;
    esac
    # Package scripts and the Prokop backend resolve the mirror from this
    # variable first, so they follow the same opt-in during the installation.
    PROKOP_MIRROR_BASE_URL="$MIRROR_BASE_URL"
    export PROKOP_MIRROR_BASE_URL
}

cleanup() {
    rollback_package_mirror
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}

read_openwrt_release_value() {
    key="$1"

    [ -f /etc/openwrt_release ] || return 0
    sed -n "s/^${key}='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

interactive_terminal_available() {
    [ -r /dev/tty ] && [ -w /dev/tty ] && (: </dev/tty) 2>/dev/null
}

read_installer_answer() {
    # stdin may contain the installer itself when invoked via wget | sh.
    read -r "$@" </dev/tty
}

init_tmp_dir() {
    TMP_DIR="$(mktemp -d /tmp/prokop.XXXXXX 2>/dev/null || true)"

    if [ -z "$TMP_DIR" ]; then
        TMP_DIR="/tmp/prokop.$$"
        mkdir -p "$TMP_DIR" || fail "Failed to create temporary directory: $TMP_DIR"
    fi
}

detect_fetcher() {
    if command_exists wget; then
        FETCHER="wget"
        return 0
    fi

    if command_exists curl; then
        FETCHER="curl"
        return 0
    fi

    fail "wget or curl is required to download Prokop"
}

run_with_deadline() {
    prokop_deadline_seconds="$1"
    shift

    prokop_deadline_helper="${PROKOP_DEADLINE_HELPER_PATH:-}"
    if [ -z "$prokop_deadline_helper" ]; then
        prokop_deadline_helper="$(install_deadline_helper_path)" || return 1
    fi

    prokop_deadline_result="$TMP_DIR/deadline-result.$$"
    "$prokop_deadline_helper" run "$prokop_deadline_seconds" "$prokop_deadline_result" "$@"
    prokop_deadline_status=$?
    rm -f "$prokop_deadline_result.output" "$prokop_deadline_result.error" \
        "$prokop_deadline_result.status" "$prokop_deadline_result.timeout"
    return "$prokop_deadline_status"
}

install_deadline_helper_path() {
    deadline_helper_path="$TMP_DIR/install-deadline.sh"

    if [ ! -s "$deadline_helper_path" ]; then
        cat > "$deadline_helper_path" <<'EOF'
#!/bin/sh

process_starttime() {
    local pid="$1"
    local stat rest

    [ -r "/proc/$pid/stat" ] || return 1
    IFS= read -r stat < "/proc/$pid/stat" || return 1
    rest="${stat##*) }"
    set -- $rest
    [ "$#" -ge 20 ] || return 1
    shift 19
    printf '%s\n' "$1"
}

child_pids() {
    local parent="$1"
    local status key value pid ppid

    for status in /proc/[0-9]*/status; do
        [ -r "$status" ] || continue
        pid=""
        ppid=""
        while IFS=: read -r key value; do
            case "$key" in
                Pid)
                    set -- $value
                    pid="${1:-}"
                    ;;
                PPid)
                    set -- $value
                    ppid="${1:-}"
                    ;;
            esac
        done < "$status"
        [ "$ppid" = "$parent" ] && [ -n "$pid" ] && printf '%s\n' "$pid"
    done
}

kill_descendants() {
    local parent="$1"
    local signal="$2"
    local child

    for child in $(child_pids "$parent"); do
        kill_descendants "$child" "$signal"
        kill "-$signal" "$child" 2>/dev/null || true
    done
}

kill_process_tree() {
    local root="$1"
    local expected_starttime="$2"
    local current_starttime

    current_starttime="$(process_starttime "$root" 2>/dev/null || true)"
    [ -n "$current_starttime" ] && [ "$current_starttime" = "$expected_starttime" ] || return 0

    kill -STOP "$root" 2>/dev/null || return 0
    kill_descendants "$root" TERM
    sleep 1
    kill_descendants "$root" KILL
    kill -KILL "$root" 2>/dev/null || true
}

run_command() {
    local seconds="$1"
    local result="$2"
    local command_pid command_starttime watchdog_pid status
    shift 2

    rm -f "$result.output" "$result.error" "$result.status" "$result.timeout"
    umask 077
    "$@" >"$result.output" 2>"$result.error" &
    command_pid=$!
    command_starttime="$(process_starttime "$command_pid" 2>/dev/null || true)"

    (
        local sleep_pid="" stopped="" current_starttime
        # run_command stops the watchdog with TERM once the command is done.
        # The sleep goes with KILL: a child that has not exec'd sleep yet
        # runs this handler, takes TERM as caught and would sleep to the
        # deadline. A TERM before its pid is known kills it right after.
        trap 'stopped=1; [ -z "$sleep_pid" ] || kill -KILL "$sleep_pid" 2>/dev/null' TERM INT
        sleep "$seconds" &
        sleep_pid=$!
        [ -z "$stopped" ] || kill -KILL "$sleep_pid" 2>/dev/null
        wait "$sleep_pid" || exit 0
        # The sleep is reaped and its pid may name another process: a TERM
        # from here on only ends the watchdog.
        trap 'exit 0' TERM INT
        [ -z "$stopped" ] || exit 0
        current_starttime="$(process_starttime "$command_pid" 2>/dev/null || true)"
        [ -n "$command_starttime" ] && [ "$current_starttime" = "$command_starttime" ] || exit 0
        : > "$result.timeout"
        kill_process_tree "$command_pid" "$command_starttime"
    ) >/dev/null 2>&1 &
    watchdog_pid=$!

    wait "$command_pid"
    status=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    [ ! -e "$result.timeout" ] || status=124
    printf '%s\n' "$status" > "$result.status"
    cat "$result.output"
    cat "$result.error" >&2
    return "$status"
}

case "${1:-}" in
    run)
        shift
        run_command "$@"
        ;;
    kill-tree)
        shift
        kill_process_tree "$1" "$2"
        ;;
    *)
        exit 2
        ;;
esac
EOF
        chmod 0700 "$deadline_helper_path" || return 1
    fi

    printf '%s\n' "$deadline_helper_path"
}

http_get() {
    case "$FETCHER" in
        wget)
            run_with_deadline "$METADATA_TIMEOUT_SECONDS" wget -T "$CONNECT_TIMEOUT_SECONDS" -qO- "$1"
            ;;
        curl)
            curl --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --max-time "$METADATA_TIMEOUT_SECONDS" -fsSL "$1"
            ;;
        *)
            return 1
            ;;
    esac
}

install_json_helper_path() {
    helper_path="$TMP_DIR/install-json.uc"

    if [ ! -s "$helper_path" ]; then
        cat > "$helper_path" <<'EOF'
#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    try {
        return json(read_stdin());
    }
    catch (e) {
        return null;
    }
}

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function ends_with(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

let uci_cursor_state = false;
// Packages loaded into the current cursor. cursor.load() reads a package
// again from flash and drops the changes not committed yet, so a package is
// loaded once per cursor (as core/uci.uc does); resetting uci_cursor_state
// reads everything again, after another process changed the configuration.
let uci_loaded_packages = {};

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function truthy(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function path_parts(path) {
    path = as_string(path);
    let first = index(path, ".");
    if (first < 0)
        return null;

    let package_name = substr(path, 0, first);
    let rest = substr(path, first + 1);
    let second = index(rest, ".");
    if (second < 0)
        return { package: package_name, section: rest, option: "" };

    return {
        package: package_name,
        section: substr(rest, 0, second),
        option: substr(rest, second + 1)
    };
}

function uci_cursor() {
    if (uci_cursor_state !== false)
        return uci_cursor_state;

    uci_loaded_packages = {};
    try {
        uci_cursor_state = require("uci").cursor();
    }
    catch (e) {
        uci_cursor_state = null;
    }

    return uci_cursor_state;
}

function uci_available() {
    return uci_cursor() != null;
}

function uci_load(package_name) {
    let c = uci_cursor();
    if (c == null)
        return false;

    package_name = as_string(package_name);
    if (uci_loaded_packages[package_name])
        return true;

    try {
        c.load(package_name);
        uci_loaded_packages[package_name] = true;
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_value_to_string(value) {
    if (value == null)
        return "";
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function uci_value_to_list(value) {
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    return words(value);
}

function uci_get(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return "";
    if (!uci_load(parts.package))
        return "";

    return uci_value_to_string(c.get(parts.package, parts.section, parts.option));
}

function uci_exists(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null)
        return false;
    if (!uci_load(parts.package))
        return false;

    if (parts.option == "")
        return c.get_all(parts.package, parts.section) != null;
    return c.get(parts.package, parts.section, parts.option) != null;
}

function uci_delete(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null)
        return false;

    try {
        if (parts.option == "")
            c.delete(parts.package, parts.section);
        else
            c.delete(parts.package, parts.section, parts.option);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_set(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    try {
        c.set(parts.package, parts.section, parts.option, type(value) == "array" ? value : as_string(value));
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_add_list(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    try {
        let values = uci_value_to_list(c.get(parts.package, parts.section, parts.option));
        push(values, as_string(value));
        c.set(parts.package, parts.section, parts.option, values);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_del_list(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    let values = [];
    let removed = false;
    for (let item in uci_value_to_list(c.get(parts.package, parts.section, parts.option))) {
        if (item == value) {
            removed = true;
            continue;
        }
        push(values, item);
    }

    if (!removed)
        return false;

    try {
        if (length(values) == 0)
            c.delete(parts.package, parts.section, parts.option);
        else
            c.set(parts.package, parts.section, parts.option, values);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_commit(package_name) {
    let c = uci_cursor();
    if (c == null)
        return false;

    try {
        return c.commit(package_name) != false;
    }
    catch (e) {
        return false;
    }
}

function run(command) {
    return system(command) == 0;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function run_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function command_output(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : data;
}

function read_text_file(path) {
    let handle = fs.open(as_string(path), "r");
    if (!handle)
        return "";

    let data = handle.read("all");
    handle.close();
    return data == null ? "" : data;
}

function unlink_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function env(name, fallback) {
    let value = getenv(name);
    if (value == null || value == "")
        return as_string(fallback);
    return as_string(value);
}

const INSTALLER_PROKOP_INIT = env("PROKOP_INSTALLER_INIT", "/etc/init.d/prokop");
const INSTALLER_PROKOP_BIN = env("PROKOP_INSTALLER_BIN", "/usr/bin/prokop");
const INSTALLER_PROKOP_LIB = env("PROKOP_INSTALLER_LIB", "/usr/lib/prokop");
const INSTALLER_PROKOP_PERSISTENT_DIR = env("PROKOP_INSTALLER_PERSISTENT_DIR", "/etc/prokop");
const INSTALLER_PROKOP_UCI_DEFAULTS = env("PROKOP_INSTALLER_UCI_DEFAULTS", "/etc/uci-defaults/50_luci-prokop");
const INSTALLER_PROKOP_LUCI_VIEW = env("PROKOP_INSTALLER_LUCI_VIEW", "/www/luci-static/resources/view/prokop");
const INSTALLER_MENU_JSON = env("PROKOP_INSTALLER_MENU_JSON", "/usr/share/luci/menu.d/luci-app-prokop.json");
const INSTALLER_ACL_JSON = env("PROKOP_INSTALLER_ACL_JSON", "/usr/share/rpcd/acl.d/luci-app-prokop.json");
const INSTALLER_RU_LMO = env("PROKOP_INSTALLER_RU_LMO", "/usr/lib/lua/luci/i18n/prokop.ru.lmo");
const INSTALLER_EN_LMO = env("PROKOP_INSTALLER_EN_LMO", "/usr/lib/lua/luci/i18n/prokop.en.lmo");
const INSTALLER_RU_LUA = env("PROKOP_INSTALLER_RU_LUA", "/usr/lib/lua/luci/i18n/prokop.ru.lua");
const INSTALLER_EN_LUA = env("PROKOP_INSTALLER_EN_LUA", "/usr/lib/lua/luci/i18n/prokop.en.lua");
const INSTALLER_RPCD_INIT = env("PROKOP_INSTALLER_RPCD_INIT", "/etc/init.d/rpcd");
const LEGACY_BRAND = env("PROKOP_INSTALLER_LEGACY_BRAND", "");
const LEGACY_BACKEND_PACKAGE = env("PROKOP_INSTALLER_LEGACY_BACKEND", LEGACY_BRAND + "-plus");
const LEGACY_CONFIG_PACKAGE_ALT = env("PROKOP_INSTALLER_LEGACY_CONFIG_ALT", LEGACY_BRAND + "_plus");
const INSTALLER_LEGACY_INIT = env("PROKOP_INSTALLER_LEGACY_INIT", "/etc/init.d/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_BASE_INIT = env("PROKOP_INSTALLER_LEGACY_BASE_INIT", "/etc/init.d/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_BIN = env("PROKOP_INSTALLER_LEGACY_BASE_BIN", "/usr/bin/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_LIB = env("PROKOP_INSTALLER_LEGACY_BASE_LIB", "/usr/lib/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_UCI_DEFAULTS = env("PROKOP_INSTALLER_LEGACY_BASE_UCI_DEFAULTS", "/etc/uci-defaults/50_luci-" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_LUCI_VIEW = env("PROKOP_INSTALLER_LEGACY_BASE_LUCI_VIEW", "/www/luci-static/resources/view/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_MENU_JSON = env("PROKOP_INSTALLER_LEGACY_BASE_MENU_JSON", "/usr/share/luci/menu.d/luci-app-" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_ACL_JSON = env("PROKOP_INSTALLER_LEGACY_BASE_ACL_JSON", "/usr/share/rpcd/acl.d/luci-app-" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_I18N = env("PROKOP_INSTALLER_LEGACY_BASE_I18N", "/usr/lib/lua/luci/i18n/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_CONFIG = env("PROKOP_INSTALLER_LEGACY_BASE_CONFIG", "/etc/config/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_PERSISTENT_DIR = env("PROKOP_INSTALLER_LEGACY_BASE_PERSISTENT_DIR", "/etc/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_RUNTIME_DIR = env("PROKOP_INSTALLER_LEGACY_BASE_RUNTIME_DIR", "/var/run/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_TMP_DIR = env("PROKOP_INSTALLER_LEGACY_BASE_TMP_DIR", "/tmp/" + LEGACY_BRAND);
const INSTALLER_LEGACY_TMP_PACKAGE_GLOB = env("PROKOP_INSTALLER_LEGACY_TMP_PACKAGE_GLOB", "/tmp/*" + LEGACY_BRAND + "*");
const INSTALLER_LEGACY_SCAN_ROOTS = env("PROKOP_INSTALLER_LEGACY_SCAN_ROOTS", "/tmp /var/run /etc /usr/lib /usr/share/luci /usr/share/rpcd /www/luci-static/resources/view");
const INSTALLER_LEGACY_BIN = env("PROKOP_INSTALLER_LEGACY_BIN", "/usr/bin/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_LIB = env("PROKOP_INSTALLER_LEGACY_LIB", "/usr/lib/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_UCI_DEFAULTS = env("PROKOP_INSTALLER_LEGACY_UCI_DEFAULTS", "/etc/uci-defaults/50_luci-" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_LUCI_VIEW = env("PROKOP_INSTALLER_LEGACY_LUCI_VIEW", "/www/luci-static/resources/view/" + LEGACY_CONFIG_PACKAGE_ALT);
const INSTALLER_LEGACY_MENU_JSON = env("PROKOP_INSTALLER_LEGACY_MENU_JSON", "/usr/share/luci/menu.d/luci-app-" + LEGACY_BACKEND_PACKAGE + ".json");
const INSTALLER_LEGACY_ACL_JSON = env("PROKOP_INSTALLER_LEGACY_ACL_JSON", "/usr/share/rpcd/acl.d/luci-app-" + LEGACY_BACKEND_PACKAGE + ".json");
const INSTALLER_LEGACY_CONFIG = env("PROKOP_INSTALLER_LEGACY_CONFIG", "/etc/config/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_CONFIG_ALT = env("PROKOP_INSTALLER_LEGACY_CONFIG_FILE_ALT", "/etc/config/" + LEGACY_CONFIG_PACKAGE_ALT);
const INSTALLER_LEGACY_PERSISTENT_DIR = env("PROKOP_INSTALLER_LEGACY_PERSISTENT_DIR", "/etc/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_RUNTIME_DIR = env("PROKOP_INSTALLER_LEGACY_RUNTIME_DIR", "/var/run/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_TMP_DIR = env("PROKOP_INSTALLER_LEGACY_TMP_DIR", "/tmp/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_TMP_ALT_DIR = env("PROKOP_INSTALLER_LEGACY_TMP_ALT_DIR", "/tmp/" + LEGACY_CONFIG_PACKAGE_ALT);
const INSTALLER_DEADLINE_HELPER = env("PROKOP_INSTALLER_DEADLINE_HELPER", "");
const INSTALLER_COMMAND_RESULT = env("PROKOP_INSTALLER_COMMAND_RESULT", "/tmp/prokop-installer-command");
const INSTALLER_RC_DIR = env("PROKOP_INSTALLER_RC_DIR", "/etc/rc.d");
const INSTALLER_START_RETRY_FILE = env("PROKOP_INSTALLER_START_RETRY_FILE", "/var/run/prokop/start.retry");
const INSTALLER_START_RETRY_PID_FILE = env("PROKOP_INSTALLER_START_RETRY_PID_FILE", "/var/run/prokop/start-retry.pid");
const INSTALLER_ORPHAN_PPID = env("PROKOP_INSTALLER_ORPHAN_PPID", "1");
const INSTALLER_SERVICE_PROBE_TIMEOUT = int(env("PROKOP_INSTALLER_SERVICE_PROBE_TIMEOUT", "6")) || 6;
const INSTALLER_SERVICE_ACTION_TIMEOUT = int(env("PROKOP_INSTALLER_SERVICE_ACTION_TIMEOUT", "60")) || 60;
const INSTALLER_DNSMASQ_INIT = env("PROKOP_INSTALLER_DNSMASQ_INIT", "/etc/init.d/dnsmasq");
// The installation Prokop was renamed from. The shell passes its names from
// the one block that holds them; empty names disable these steps.
const LEGACY_FORKOP_BRAND = env("PROKOP_INSTALLER_LEGACY_FORKOP_BRAND", "");
const LEGACY_FORKOP_CONFIG_NAME = env("PROKOP_INSTALLER_LEGACY_FORKOP_CONFIG_NAME", "");
const LEGACY_FORKOP_INIT = env("PROKOP_INSTALLER_LEGACY_FORKOP_INIT", "");
const LEGACY_FORKOP_KILLSWITCH_INIT = env("PROKOP_INSTALLER_LEGACY_FORKOP_KILLSWITCH_INIT", "");
const LEGACY_FORKOP_TORRSERVER_INIT = env("PROKOP_INSTALLER_LEGACY_FORKOP_TORRSERVER_INIT", "");
const LEGACY_FORKOP_SERVICES = env("PROKOP_INSTALLER_LEGACY_FORKOP_SERVICES", "");
const LEGACY_FORKOP_STOP_SOURCE = env("PROKOP_INSTALLER_LEGACY_FORKOP_STOP_SOURCE", "");
const LEGACY_FORKOP_BIN = env("PROKOP_INSTALLER_LEGACY_FORKOP_BIN", "");
const LEGACY_FORKOP_LIB = env("PROKOP_INSTALLER_LEGACY_FORKOP_LIB", "");
const LEGACY_FORKOP_NFT_MAIN_TABLE = env("PROKOP_INSTALLER_LEGACY_FORKOP_NFT_MAIN_TABLE", "");
const LEGACY_FORKOP_NFT_TABLES = env("PROKOP_INSTALLER_LEGACY_FORKOP_NFT_TABLES", "");
const LEGACY_FORKOP_KILLSWITCH_TABLE = env("PROKOP_INSTALLER_LEGACY_FORKOP_KILLSWITCH_TABLE", "");
const LEGACY_FORKOP_KILLSWITCH_DNS_CHAIN = env("PROKOP_INSTALLER_LEGACY_FORKOP_KILLSWITCH_DNS_CHAIN", "");
const LEGACY_FORKOP_DHCP_SECTION = env("PROKOP_INSTALLER_LEGACY_FORKOP_DHCP_SECTION", "");
const LEGACY_FORKOP_DHCP_OPTION_PREFIX = env("PROKOP_INSTALLER_LEGACY_FORKOP_DHCP_OPTION_PREFIX", "");
const LEGACY_FORKOP_ACL_GROUPS = env("PROKOP_INSTALLER_LEGACY_FORKOP_ACL_GROUPS", "");
const LEGACY_FORKOP_STOP_TIMEOUT = int(env("PROKOP_INSTALLER_LEGACY_FORKOP_STOP_TIMEOUT", "180")) || 180;
const PROKOP_ACL_GROUPS = env("PROKOP_INSTALLER_PROKOP_ACL_GROUPS", "luci-app-prokop luci-app-prokop-admin");

let installer_command_sequence = 0;

function installer_command_result(args, timeout_seconds) {
    installer_command_sequence++;
    let result = INSTALLER_COMMAND_RESULT + "." + installer_command_sequence;
    let helper_args = [
        INSTALLER_DEADLINE_HELPER,
        "run",
        as_string(timeout_seconds),
        result
    ];
    for (let arg in args)
        push(helper_args, arg);

    let shell_status = normalize_status(system(command_from_args(helper_args) + " >/dev/null 2>&1"));
    let status_text = trim(read_text_file(result + ".status"));
    let complete = match(status_text, /^[0-9]+$/) != null;
    let status = complete ? int(status_text) : shell_status;
    let output = read_text_file(result + ".output");
    for (let suffix in [ ".output", ".error", ".status", ".timeout" ])
        unlink_file(result + suffix);

    return {
        status,
        output,
        complete,
        timed_out: status == 124
    };
}

let dns_owner_config = "prokop";
let dns_owner_section = "prokop";
let dns_owner_option_prefix = "prokop_";

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function path_executable(path) {
    return run_args([ "test", "-x", path ]);
}

function remove_path(path) {
    if (as_string(path) == "" || !path_exists(path))
        return true;
    return run_args([ "rm", "-rf", path ]);
}

function remove_glob(pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return true;
    let removed = true;
    for (let path in fs.glob(pattern))
        if (!remove_path(path))
            removed = false;
    return removed;
}

function remove_globs(patterns) {
    let removed = true;
    for (let pattern in words(patterns))
        if (!remove_glob(pattern))
            removed = false;
    return removed;
}

function remove_legacy_named_children(root) {
    root = as_string(root);
    if (root == "" || LEGACY_BRAND == "")
        return true;

    let entries = fs.lsdir(root);
    if (type(entries) != "array")
        return true;

    let removed = true;
    let brand = lc(LEGACY_BRAND);
    for (let entry in entries) {
        entry = as_string(entry);
        let path = root + "/" + entry;
        if (index(lc(entry), brand) >= 0) {
            if (!remove_path(path))
                removed = false;
            continue;
        }

        let stat = fs.stat(path);
        if (stat != null && stat.type == "directory" && !remove_legacy_named_children(path))
            removed = false;
    }
    return removed;
}

function restart_dnsmasq() {
    let init_script = shell_quote(INSTALLER_DNSMASQ_INIT);
    return run("[ -x " + init_script + " ] && " + init_script + " restart");
}

function installer_package_manager() {
    return run_args([ "apk", "--version" ]) ? "apk" : "opkg";
}

function installer_installed_package_names() {
    let manager = installer_package_manager();
    let output = manager == "apk" ?
        command_output([ "apk", "info" ]) :
        command_output([ "opkg", "list-installed" ]);
    let names = [];

    for (let line in split(output, "\n")) {
        line = trim(as_string(line));
        if (line == "")
            continue;
        if (manager == "opkg") {
            let parts = split(line, /[ \t]+/);
            line = parts[0] || "";
        }
        if (line != "")
            push(names, line);
    }

    return names;
}

function installer_package_installed(name) {
    name = as_string(name);
    if (name == "")
        return false;

    if (installer_package_manager() == "apk")
        return run_args([ "apk", "info", "-e", name ]);

    for (let installed in installer_installed_package_names())
        if (installed == name)
            return true;
    return false;
}

function installer_remove_package(name) {
    name = as_string(name);
    if (name == "" || !installer_package_installed(name))
        return true;

    if (installer_package_manager() == "apk")
        return run_args([ "apk", "del", name ]);
    return run_args([ "opkg", "remove", "--force-depends", name ]);
}

function installer_remove_package_prefix(prefix) {
    prefix = as_string(prefix);
    if (prefix == "")
        return true;

    let removed = true;
    for (let name in installer_installed_package_names())
        if (starts_with(name, prefix) && !installer_remove_package(name))
            removed = false;
    return removed;
}

function installer_confirm_remove_https_dns_proxy() {
    if (!installer_package_installed("https-dns-proxy"))
        return true;

    warn("Detected conflicting package: https-dns-proxy\n");

    if (run("[ ! -t 0 ]")) {
        warn("Remove the conflicting https-dns-proxy package and continue?: 1 (yes, non-interactive)\n");
        return true;
    }

    while (true) {
        warn("\nRemove the conflicting https-dns-proxy package and continue?\n");
        warn("  1) yes\n");
        warn("  2) no\n");
        warn("Select [2]: ");

        let input = fs.open("/dev/stdin", "r");
        let answer = input ? trim(as_string(input.read("line"))) : "";
        if (input)
            input.close();

        if (answer == "1")
            return true;
        if (answer == "" || answer == "2")
            return false;
        warn("Invalid choice\n");
    }
}

function path_basename(path) {
    let parts = split(as_string(path), "/");
    return length(parts) > 0 ? parts[length(parts) - 1] : "";
}

function installer_process_starttime(pid) {
    let stat = read_text_file("/proc/" + as_string(pid) + "/stat");
    let matched = match(stat, /^[0-9]+ \(.*\) [^ ]+ (.*)$/);
    if (!matched)
        return "";

    let fields = words(matched[1]);
    return length(fields) > 18 ? as_string(fields[18]) : "";
}

function installer_process_ppid(pid) {
    let matched = match(read_text_file("/proc/" + as_string(pid) + "/status"), /(^|\n)PPid:[ \t]*([0-9]+)/);
    return matched ? as_string(matched[2]) : "";
}

function installer_process_args(pid) {
    let args = [];
    for (let arg in split(read_text_file("/proc/" + as_string(pid) + "/cmdline"), "\0"))
        if (arg != "")
            push(args, arg);
    return args;
}

function installer_args_have_exact(args, value) {
    for (let arg in args)
        if (arg == value)
            return true;
    return false;
}

function installer_args_contain(args, value) {
    for (let arg in args)
        if (index(arg, value) >= 0)
            return true;
    return false;
}

function installer_kill_process_tree(pid) {
    let starttime = installer_process_starttime(pid);
    if (starttime == "" || INSTALLER_DEADLINE_HELPER == "")
        return false;
    return normalize_status(system(command_from_args([
        INSTALLER_DEADLINE_HELPER,
        "kill-tree",
        as_string(pid),
        starttime
    ]) + " >/dev/null 2>&1")) == 0;
}

function installer_cancel_stale_start_retry() {
    // The pidfile is "<pid>\n<start ticks>\n" (core/process_identity.uc) or,
    // from releases before it, the bare pid.
    let record = split(trim(read_text_file(INSTALLER_START_RETRY_PID_FILE)), "\n");
    let pid = trim(record[0] || "");
    let ticks = trim(record[1] || "");
    if (match(pid, /^[0-9]+$/) && (ticks == "" || ticks == installer_process_starttime(pid))) {
        let args = installer_process_args(pid);
        if (installer_args_contain(args, INSTALLER_PROKOP_INIT) &&
            installer_args_contain(args, "retry_start_on_wan_up"))
            installer_kill_process_tree(pid);
    }
    unlink_file(INSTALLER_START_RETRY_PID_FILE);
    unlink_file(INSTALLER_START_RETRY_FILE);
}

function installer_recover_interrupted_cleanup(init_scripts) {
    installer_cancel_stale_start_retry();

    for (let status_path in fs.glob("/proc/[0-9]*/status")) {
        let parts = split(status_path, "/");
        let pid = length(parts) > 2 ? parts[2] : "";
        if (pid == "" || installer_process_ppid(pid) != INSTALLER_ORPHAN_PPID)
            continue;

        let args = installer_process_args(pid);
        if (length(args) == 0)
            continue;
        let action = args[length(args) - 1];
        let stale = false;

        if (action == "installer-cleanup-legacy") {
            for (let arg in args)
                if (ends_with(arg, "/install-json.uc") || arg == "install-json.uc")
                    stale = true;
        }
        else if (action == "enabled" || action == "status" || action == "running") {
            for (let init_script in init_scripts)
                if (init_script != "" && installer_args_have_exact(args, init_script))
                    stale = true;
        }

        if (stale)
            installer_kill_process_tree(pid);
    }
}

function installer_service_enabled_state(init_script) {
    if (!path_executable(init_script))
        return { known: true, value: false };

    let result = installer_command_result([ init_script, "enabled" ], INSTALLER_SERVICE_PROBE_TIMEOUT);
    if (result.complete && !result.timed_out)
        return { known: true, value: result.status == 0 };

    let service_name = path_basename(init_script);
    if (service_name != "" && length(fs.glob(INSTALLER_RC_DIR + "/S??" + service_name)) > 0)
        return { known: true, value: true };

    return { known: false, value: false };
}

function installer_service_running_state(init_script) {
    if (!path_executable(init_script))
        return { known: true, value: false };

    let status = installer_command_result([ init_script, "status" ], INSTALLER_SERVICE_PROBE_TIMEOUT);
    if (status.complete && !status.timed_out && trim(status.output) == "running")
        return { known: true, value: true };

    let running = installer_command_result([ init_script, "running" ], INSTALLER_SERVICE_PROBE_TIMEOUT);
    if (running.complete && !running.timed_out)
        return { known: true, value: running.status == 0 };

    return { known: false, value: false };
}

function installer_backend_status_running_state(bin_path) {
    if (!path_executable(bin_path))
        return { known: true, value: false };

    let result = installer_command_result([ bin_path, "get_status" ], INSTALLER_SERVICE_PROBE_TIMEOUT);
    if (!result.complete || result.timed_out)
        return { known: false, value: false };
    return { known: true, value: index(result.output, "\"running\":1") >= 0 };
}

function installer_service_action(init_script, action) {
    let result = installer_command_result([ init_script, action ], INSTALLER_SERVICE_ACTION_TIMEOUT);
    if (!result.complete || result.timed_out) {
        warn("Timed out while running " + init_script + " " + action + ".\n");
        return false;
    }
    return true;
}

function select_dns_owner(legacy) {
    if (legacy) {
        dns_owner_config = LEGACY_BACKEND_PACKAGE;
        dns_owner_section = LEGACY_CONFIG_PACKAGE_ALT;
        dns_owner_option_prefix = LEGACY_BRAND + "_";
    }
    else {
        dns_owner_config = "prokop";
        dns_owner_section = "prokop";
        dns_owner_option_prefix = "prokop_";
    }
}

let dnsmasq_failsafe_restore;

function installer_restore_dnsmasq(bin_path, legacy) {
    if (path_executable(bin_path) && run_args([ bin_path, "restore_dnsmasq" ]))
        return true;

    // The backend may have changed dhcp before it failed.
    uci_cursor_state = false;
    select_dns_owner(legacy);
    return dnsmasq_failsafe_restore();
}

function installer_deactivate_legacy_base() {
    if (!path_executable(INSTALLER_LEGACY_BASE_INIT))
        return true;

    let running = installer_service_running_state(INSTALLER_LEGACY_BASE_INIT);
    let enabled = installer_service_enabled_state(INSTALLER_LEGACY_BASE_INIT);
    if (!running.known || !enabled.known) {
        warn("Unable to determine the legacy service state before installation.\n");
        return false;
    }

    if (running.value) {
        warn("Detected a running legacy service. Stopping it before installing Prokop.\n");
        if (!installer_service_action(INSTALLER_LEGACY_BASE_INIT, "stop"))
            return false;
    }

    if (enabled.value) {
        warn("Detected an enabled legacy autostart. Disabling it before installing Prokop.\n");
        if (!installer_service_action(INSTALLER_LEGACY_BASE_INIT, "disable"))
            return false;
    }
    return true;
}

function installer_cleanup_legacy() {
    let prokop_installed = installer_package_installed("prokop");
    let legacy_installed = LEGACY_BRAND != "" && installer_package_installed(LEGACY_BACKEND_PACKAGE);
    let active_init = legacy_installed ? INSTALLER_LEGACY_INIT : INSTALLER_PROKOP_INIT;
    let active_bin = legacy_installed ? INSTALLER_LEGACY_BIN : INSTALLER_PROKOP_BIN;

    installer_recover_interrupted_cleanup([
        active_init,
        INSTALLER_PROKOP_INIT,
        INSTALLER_LEGACY_INIT,
        INSTALLER_LEGACY_BASE_INIT
    ]);

    let enabled = installer_service_enabled_state(active_init);
    let running = installer_service_running_state(active_init);
    let backend_running = running.known && running.value ?
        { known: true, value: false } :
        installer_backend_status_running_state(active_bin);
    if (!enabled.known || (!running.known && !backend_running.known)) {
        warn("Unable to determine the Prokop service state before installation.\n");
        return false;
    }
    let was_enabled = enabled.value;
    let was_running = running.value || backend_running.value;

    if (!installer_confirm_remove_https_dns_proxy())
        return false;

    if (legacy_installed && !installer_deactivate_legacy_base())
        return false;

    if (path_executable(active_init)) {
        if (!installer_service_action(active_init, "stop"))
            return false;
        installer_restore_dnsmasq(active_bin, legacy_installed);
        if (!installer_service_action(active_init, "disable"))
            return false;
    }

    let packages_removed = true;
    for (let package_name in [ "luci-app-https-dns-proxy", "https-dns-proxy" ])
        if (!installer_remove_package(package_name))
            packages_removed = false;
    if (!installer_remove_package_prefix("luci-i18n-https-dns-proxy"))
        packages_removed = false;

    if (legacy_installed) {
        if (!installer_remove_package_prefix("luci-i18n-" + LEGACY_BACKEND_PACKAGE))
            packages_removed = false;
        if (!installer_remove_package("luci-app-" + LEGACY_BACKEND_PACKAGE))
            packages_removed = false;
        if (!installer_remove_package(LEGACY_BACKEND_PACKAGE))
            packages_removed = false;
    }

    if (!prokop_installed) {
        if (!installer_remove_package_prefix("luci-i18n-prokop"))
            packages_removed = false;
        if (!installer_remove_package("luci-app-prokop"))
            packages_removed = false;
    }

    if (!packages_removed) {
        warn("Failed to remove one or more conflicting or legacy packages.\n");
        return false;
    }

    if (legacy_installed) {
        remove_path(INSTALLER_LEGACY_LIB);
        remove_path(INSTALLER_LEGACY_INIT);
        remove_path(INSTALLER_LEGACY_BIN);
        for (let path in [
            INSTALLER_LEGACY_LUCI_VIEW,
            INSTALLER_LEGACY_MENU_JSON,
            INSTALLER_LEGACY_ACL_JSON,
            INSTALLER_LEGACY_UCI_DEFAULTS
        ])
            remove_path(path);
    }

    if (!prokop_installed) {
        remove_path(INSTALLER_PROKOP_LIB);
        remove_path(INSTALLER_PROKOP_INIT);
        remove_path(INSTALLER_PROKOP_BIN);
        for (let path in [
            INSTALLER_PROKOP_LUCI_VIEW,
            INSTALLER_MENU_JSON,
            INSTALLER_ACL_JSON,
            INSTALLER_PROKOP_UCI_DEFAULTS,
            INSTALLER_RU_LMO,
            INSTALLER_EN_LMO,
            INSTALLER_RU_LUA,
            INSTALLER_EN_LUA
        ])
            remove_path(path);
    }

    print("PROKOP_WAS_ENABLED=", was_enabled ? "1" : "0", "\n");
    print("PROKOP_WAS_RUNNING=", was_running ? "1" : "0", "\n");
    print("PROKOP_LEGACY_DETECTED=", legacy_installed ? "1" : "0", "\n");
    return true;
}

function installer_finalize_legacy() {
    if (LEGACY_BRAND == "")
        return false;

    let legacy_tailscale_dir = INSTALLER_LEGACY_PERSISTENT_DIR + "/tailscale";
    if (path_exists(legacy_tailscale_dir)) {
        let entries = fs.lsdir(legacy_tailscale_dir);
        let prokop_tailscale_dir = INSTALLER_PROKOP_PERSISTENT_DIR + "/tailscale";
        if (type(entries) != "array" || !run_args([ "mkdir", "-p", prokop_tailscale_dir ])) {
            warn("Failed to prepare legacy Tailscale state migration; the legacy directory was preserved.\n");
            return false;
        }

        for (let entry in entries) {
            entry = as_string(entry);
            let source = legacy_tailscale_dir + "/" + entry;
            let target = prokop_tailscale_dir + "/" + entry;
            if (path_exists(target))
                continue;

            let temporary = prokop_tailscale_dir + "/." + entry + ".prokop-migrate";
            if (!remove_path(temporary) ||
                !run_args([ "cp", "-a", source, temporary ]) ||
                !run_args([ "mv", temporary, target ])) {
                remove_path(temporary);
                warn("Failed to migrate legacy Tailscale state; the legacy directory was preserved.\n");
                return false;
            }
        }
    }

    let cleaned = true;
    for (let path in [
        INSTALLER_LEGACY_CONFIG,
        INSTALLER_LEGACY_CONFIG_ALT,
        INSTALLER_LEGACY_PERSISTENT_DIR,
        INSTALLER_LEGACY_RUNTIME_DIR,
        INSTALLER_LEGACY_TMP_DIR,
        INSTALLER_LEGACY_TMP_ALT_DIR
    ])
        if (!remove_path(path))
            cleaned = false;

    for (let prefix in [
        INSTALLER_LEGACY_CONFIG,
        INSTALLER_LEGACY_CONFIG_ALT,
        INSTALLER_LEGACY_PERSISTENT_DIR,
        INSTALLER_LEGACY_RUNTIME_DIR,
        INSTALLER_LEGACY_TMP_DIR,
        INSTALLER_LEGACY_TMP_ALT_DIR,
        INSTALLER_LEGACY_INIT,
        INSTALLER_LEGACY_BIN,
        INSTALLER_LEGACY_LIB,
        INSTALLER_LEGACY_UCI_DEFAULTS,
        INSTALLER_LEGACY_LUCI_VIEW,
        INSTALLER_LEGACY_MENU_JSON,
        INSTALLER_LEGACY_ACL_JSON,
        INSTALLER_LEGACY_BASE_CONFIG,
        INSTALLER_LEGACY_BASE_PERSISTENT_DIR,
        INSTALLER_LEGACY_BASE_RUNTIME_DIR,
        INSTALLER_LEGACY_BASE_TMP_DIR,
        INSTALLER_LEGACY_BASE_INIT,
        INSTALLER_LEGACY_BASE_BIN,
        INSTALLER_LEGACY_BASE_LIB,
        INSTALLER_LEGACY_BASE_UCI_DEFAULTS,
        INSTALLER_LEGACY_BASE_LUCI_VIEW,
        INSTALLER_LEGACY_BASE_MENU_JSON,
        INSTALLER_LEGACY_BASE_ACL_JSON,
        INSTALLER_LEGACY_BASE_I18N
    ])
        if (!remove_glob(prefix + "*"))
            cleaned = false;

    if (!remove_glob(INSTALLER_LEGACY_TMP_PACKAGE_GLOB))
        cleaned = false;

    for (let root in words(INSTALLER_LEGACY_SCAN_ROOTS))
        if (!remove_legacy_named_children(root))
            cleaned = false;

    return cleaned;
}

function installer_post_install() {
    remove_globs(env("PROKOP_INSTALLER_LUCI_CACHE_GLOBS", "/var/luci-indexcache* /tmp/luci-indexcache*"));
    for (let path in [
        env("PROKOP_INSTALLER_LATEST_VERSION_CACHE", "/tmp/prokop.latest-version.cache"),
        env("PROKOP_INSTALLER_SYSTEM_INFO_CACHE", "/var/run/prokop/system-info.json"),
        env("PROKOP_INSTALLER_SERVER_COUNTRY_CACHE", "/var/run/prokop/server-country-cache.json"),
        env("PROKOP_INSTALLER_SING_BOX_VERSION_CACHE", "/var/run/prokop/ui-state/sing-box-version"),
        env("PROKOP_INSTALLER_TMP_SYSTEM_INFO_CACHE", "/tmp/prokop/system-info.json")
    ])
        remove_path(path);

    if (path_executable(INSTALLER_RPCD_INIT))
        run_args([ INSTALLER_RPCD_INIT, "reload" ]);

    let config_ready = env("PROKOP_CONFIG_READY", "1") == "1";

    if (config_ready && env("PROKOP_WAS_ENABLED", "0") == "1" && path_executable(INSTALLER_PROKOP_INIT))
        run_args([ INSTALLER_PROKOP_INIT, "enable" ]);

    if (config_ready && env("PROKOP_WAS_RUNNING", "0") == "1" && path_executable(INSTALLER_PROKOP_INIT)) {
        if (!run_args([ INSTALLER_PROKOP_INIT, "start" ]) &&
            !run_args([ INSTALLER_PROKOP_INIT, "restart" ]))
            warn("Failed to start Prokop after upgrade.\n");
    }

    return true;
}

function installer_restore_previous_service() {
    if (env("PROKOP_WAS_ENABLED", "0") == "1" && path_executable(INSTALLER_PROKOP_INIT))
        run_args([ INSTALLER_PROKOP_INIT, "enable" ]);

    if (env("PROKOP_WAS_RUNNING", "0") == "1" && path_executable(INSTALLER_PROKOP_INIT))
        return run_args([ INSTALLER_PROKOP_INIT, "start" ]) ||
            run_args([ INSTALLER_PROKOP_INIT, "restart" ]);

    return true;
}

// Saves a mirror the user opted in to. It runs after the package postinst so
// the one-shot configuration migrations cannot reset it.
function installer_persist_mirror(value) {
    value = as_string(value);
    if (match(value, /^https?:\/\/[^\/ \t\r\n]/) == null)
        return false;

    let c = uci_cursor();
    if (c == null || !uci_load("prokop") || c.get("prokop", "settings") != "settings")
        return false;

    try {
        if (!c.set("prokop", "settings", "mirror_base_url", value) || !c.commit("prokop"))
            return false;
    }
    catch (e) {
        return false;
    }

    uci_cursor_state = false;
    return uci_get("prokop.settings.mirror_base_url") == value;
}

function list_has(values, needle) {
    for (let value in words(values))
        if (value == needle)
            return true;
    return false;
}

function dnsmasq_managed_instance_exists() {
    return uci_exists("dhcp." + dns_owner_section);
}

function dnsmasq_default_servers() {
    return uci_get("dhcp.@dnsmasq[0].server");
}

function dnsmasq_default_has_managed_dns() {
    return list_has(dnsmasq_default_servers(), "127.0.0.42");
}

function dnsmasq_has_managed_dns() {
    return dnsmasq_default_has_managed_dns() || dnsmasq_managed_instance_exists();
}

function dnsmasq_has_managed_state() {
    return uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "server") != "" ||
        uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "noresolv") != "" ||
        uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "cachesize") != "" ||
        uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "notinterface") != "" ||
        dnsmasq_managed_instance_exists();
}

function dnsmasq_management_disabled() {
    return truthy(uci_get(dns_owner_config + ".settings.dont_touch_dhcp"));
}

function dnsmasq_managed_interfaces() {
    let interfaces = uci_get("dhcp." + dns_owner_section + ".interface");
    if (interfaces == "")
        interfaces = uci_get(dns_owner_config + ".settings.source_network_interfaces");
    if (interfaces == "")
        interfaces = "br-lan";

    return interfaces;
}

function dnsmasq_cleanup_managed_instance() {
    let managed_instance_present = dnsmasq_managed_instance_exists();
    let managed_interfaces = managed_instance_present ? dnsmasq_managed_interfaces() : "";

    uci_delete("dhcp." + dns_owner_section);

    let backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "notinterface";
    let backup_notinterfaces = uci_get(backup_option);
    if (backup_notinterfaces != "") {
        uci_delete("dhcp.@dnsmasq[0].notinterface");
        for (let value in words(backup_notinterfaces))
            uci_add_list("dhcp.@dnsmasq[0].notinterface", value);
        uci_delete(backup_option);
        return;
    }

    if (managed_instance_present) {
        for (let value in words(managed_interfaces))
            uci_del_list("dhcp.@dnsmasq[0].notinterface", value);
    }

    uci_delete(backup_option);
}

function dnsmasq_restore_default_instance() {
    let server_list = dnsmasq_default_servers();
    let server_backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "server";
    let backup_servers = uci_get(server_backup_option);
    let managed_global_dns = list_has(server_list, "127.0.0.42");

    uci_delete("dhcp.@dnsmasq[0].server");
    if (backup_servers != "") {
        for (let value in words(backup_servers))
            uci_add_list("dhcp.@dnsmasq[0].server", value);
        uci_delete(server_backup_option);
    }
    else {
        for (let value in words(server_list)) {
            if (value != "127.0.0.42")
                uci_add_list("dhcp.@dnsmasq[0].server", value);
        }
    }
    uci_delete(server_backup_option);

    let noresolv_backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "noresolv";
    let noresolv = uci_get(noresolv_backup_option);
    if (noresolv != "") {
        uci_set("dhcp.@dnsmasq[0].noresolv", noresolv);
        uci_delete(noresolv_backup_option);
    }
    else if (managed_global_dns) {
        uci_set("dhcp.@dnsmasq[0].noresolv", "0");
    }

    let cachesize_backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "cachesize";
    let cachesize = uci_get(cachesize_backup_option);
    if (cachesize != "") {
        uci_set("dhcp.@dnsmasq[0].cachesize", cachesize);
        uci_delete(cachesize_backup_option);
    }
    else if (managed_global_dns) {
        uci_set("dhcp.@dnsmasq[0].cachesize", "150");
    }
}

dnsmasq_failsafe_restore = function() {
    if (!uci_available())
        return true;

    if (dnsmasq_management_disabled() && !dnsmasq_has_managed_state())
        return true;

    if (!dnsmasq_has_managed_dns() && !dnsmasq_has_managed_state())
        return true;

    dnsmasq_cleanup_managed_instance();
    dnsmasq_restore_default_instance();
    uci_commit("dhcp");
    restart_dnsmasq();
    return true;
};

// The installation Prokop was renamed from. Its own code deactivates it: its
// init.d stop with the package stop source, as its package prerm did. These
// steps only cover what that code could not do, and never lift its
// kill-switch: that policy stays until Prokop arms its own.

const LEGACY_FORKOP_DNSMASQ_BACKUP_KEYS = [ "server", "noresolv", "cachesize", "notinterface" ];

function legacy_forkop_select_dns_owner() {
    dns_owner_config = LEGACY_FORKOP_CONFIG_NAME;
    dns_owner_section = LEGACY_FORKOP_DHCP_SECTION;
    dns_owner_option_prefix = LEGACY_FORKOP_DHCP_OPTION_PREFIX;
}

function legacy_forkop_nft_table_present(table) {
    table = as_string(table);
    return table != "" && run_args([ "nft", "list", "table", "inet", table ]);
}

function legacy_forkop_service_action(init_script, action, timeout_seconds, assignment) {
    let args = [];
    if (as_string(assignment) != "")
        push(args, "env", as_string(assignment));
    push(args, init_script, action);
    let result = installer_command_result(args, timeout_seconds);
    if (!result.complete || result.timed_out) {
        warn("Timed out while running " + init_script + " " + action + ".\n");
        return false;
    }
    return result.status == 0;
}

function legacy_forkop_service_state() {
    if (LEGACY_FORKOP_INIT == "")
        return false;

    let enabled = installer_service_enabled_state(LEGACY_FORKOP_INIT);
    let running = installer_service_running_state(LEGACY_FORKOP_INIT);
    let backend_running = running.known && running.value ?
        { known: true, value: false } :
        installer_backend_status_running_state(LEGACY_FORKOP_BIN);
    if (!enabled.known || (!running.known && !backend_running.known)) {
        warn("Unable to determine the " + LEGACY_FORKOP_BRAND + " service state.\n");
        return false;
    }

    print("LEGACY_FORKOP_WAS_ENABLED=", enabled.value ? "1" : "0", "\n");
    print("LEGACY_FORKOP_WAS_RUNNING=", running.value || backend_running.value ? "1" : "0", "\n");
    return true;
}

// dnsmasq forwarding to 127.0.0.42 is the old installation's only while it
// is installed (its init script or executable) or its runtime table exists;
// otherwise it can be Prokop's own.
function legacy_forkop_owns_dns() {
    return path_executable(LEGACY_FORKOP_INIT) || path_exists(LEGACY_FORKOP_BIN) ||
        legacy_forkop_nft_table_present(LEGACY_FORKOP_NFT_MAIN_TABLE);
}

// dnsmasq after the old stop: that stop restores it itself (its
// dnsmasq_restore, which also attaches the kill-switch servers file). When it
// could not, and the old installation owned that DNS (owns_dns: decided by
// legacy_forkop_owns_dns before its stop), its fail-safe restore runs, then
// the installer's own one with the old option names; dnsmasq is restarted
// only then. Backups the old code left are handed to Prokop under its option
// names in one commit, which dnsmasq does not read, so it is not restarted
// for them. The servers file is never touched here: Prokop's kill-switch
// moves it when it arms.
function legacy_forkop_dns_handover(owns_dns) {
    let result = { restored: false, converted: false, leftover: false };
    if (LEGACY_FORKOP_DHCP_OPTION_PREFIX == "" || LEGACY_FORKOP_DHCP_SECTION == "" || !uci_available())
        return result;

    legacy_forkop_select_dns_owner();
    if (owns_dns && dnsmasq_has_managed_dns()) {
        let dns_module = LEGACY_FORKOP_LIB + "/dns/apply.uc";
        if (LEGACY_FORKOP_LIB != "" && path_exists(dns_module))
            installer_command_result([ "ucode", "-L", LEGACY_FORKOP_LIB, dns_module, "failsafe-restore" ],
                INSTALLER_SERVICE_ACTION_TIMEOUT);
        uci_cursor_state = false;
        if (dnsmasq_has_managed_dns())
            dnsmasq_failsafe_restore();
        uci_cursor_state = false;
        result.restored = true;
    }

    let c = uci_cursor();
    if (c != null && uci_load("dhcp")) {
        let changed = false;
        for (let key in LEGACY_FORKOP_DNSMASQ_BACKUP_KEYS) {
            let legacy_value = c.get("dhcp", "@dnsmasq[0]", LEGACY_FORKOP_DHCP_OPTION_PREFIX + key);
            if (legacy_value == null)
                continue;
            if (c.get("dhcp", "@dnsmasq[0]", "prokop_" + key) == null)
                uci_set("dhcp.@dnsmasq[0].prokop_" + key, legacy_value);
            uci_delete("dhcp.@dnsmasq[0]." + LEGACY_FORKOP_DHCP_OPTION_PREFIX + key);
            changed = true;
        }
        if (changed && uci_commit("dhcp"))
            result.converted = true;
        uci_cursor_state = false;
    }

    result.leftover = dnsmasq_default_has_managed_dns();
    select_dns_owner(false);
    return result;
}

function legacy_forkop_print_dns(dns) {
    print("LEGACY_FORKOP_DNS_RESTORED=", dns.restored ? "1" : "0", "\n");
    print("LEGACY_FORKOP_DNS_CONVERTED=", dns.converted ? "1" : "0", "\n");
    print("LEGACY_FORKOP_DNS_LEFTOVER=", dns.leftover ? "1" : "0", "\n");
}

function legacy_forkop_deactivate() {
    if (LEGACY_FORKOP_INIT == "")
        return false;

    // Decided before the stop removes its runtime table.
    let owns_dns = legacy_forkop_owns_dns();

    // The kill-switch service first: its stop turns the client DNS redirect
    // to its standby resolver off, and procd ends the standby dnsmasq and the
    // watcher. Its nftables policy and fw4 include stay.
    for (let init_script in [ LEGACY_FORKOP_KILLSWITCH_INIT, LEGACY_FORKOP_TORRSERVER_INIT ]) {
        if (init_script == "" || !path_executable(init_script))
            continue;
        legacy_forkop_service_action(init_script, "stop", INSTALLER_SERVICE_ACTION_TIMEOUT);
        legacy_forkop_service_action(init_script, "disable", INSTALLER_SERVICE_ACTION_TIMEOUT);
    }

    if (path_executable(LEGACY_FORKOP_INIT)) {
        if (!legacy_forkop_service_action(LEGACY_FORKOP_INIT, "stop", LEGACY_FORKOP_STOP_TIMEOUT, LEGACY_FORKOP_STOP_SOURCE))
            warn(LEGACY_FORKOP_BRAND + " did not report a clean stop; removing what its stop left behind.\n");
        if (!legacy_forkop_service_action(LEGACY_FORKOP_INIT, "disable", INSTALLER_SERVICE_ACTION_TIMEOUT))
            warn("Unable to disable the " + LEGACY_FORKOP_BRAND + " autostart; its removal deletes it.\n");
    }

    // A service without its init script can still be registered with procd.
    for (let init_script in [ LEGACY_FORKOP_KILLSWITCH_INIT, LEGACY_FORKOP_TORRSERVER_INIT, LEGACY_FORKOP_INIT ]) {
        let name = path_basename(init_script);
        if (name != "" && !path_executable(init_script))
            run_args([ "ubus", "call", "service", "delete", sprintf("%J", { name }) ]);
    }

    // What the stop removes when it could not: the runtime tables, never the
    // kill-switch table.
    for (let table in words(LEGACY_FORKOP_NFT_TABLES))
        if (table != LEGACY_FORKOP_KILLSWITCH_TABLE && legacy_forkop_nft_table_present(table))
            run_args([ "nft", "delete", "table", "inet", table ]);

    // No client may stay redirected to the standby resolver that is gone.
    if (LEGACY_FORKOP_KILLSWITCH_DNS_CHAIN != "" && legacy_forkop_nft_table_present(LEGACY_FORKOP_KILLSWITCH_TABLE)) {
        run_args([ "nft", "flush", "chain", "inet", LEGACY_FORKOP_KILLSWITCH_TABLE, LEGACY_FORKOP_KILLSWITCH_DNS_CHAIN ]);
        run_args([ "conntrack", "-D", "-p", "udp", "--dport", "53" ]);
        run_args([ "conntrack", "-D", "-p", "tcp", "--dport", "53" ]);
    }

    legacy_forkop_print_dns(legacy_forkop_dns_handover(owns_dns));

    if (legacy_forkop_nft_table_present(LEGACY_FORKOP_NFT_MAIN_TABLE)) {
        warn("The " + LEGACY_FORKOP_BRAND + " runtime table " + LEGACY_FORKOP_NFT_MAIN_TABLE + " could not be removed.\n");
        return false;
    }
    if (path_executable(LEGACY_FORKOP_INIT)) {
        let running = installer_service_running_state(LEGACY_FORKOP_INIT);
        if (running.known && running.value) {
            warn(LEGACY_FORKOP_BRAND + " still reports a running service.\n");
            return false;
        }
    }
    return true;
}

// Rollback before the point of no return: the old service was never touched,
// but it is brought back to its recorded state if something else changed it.
function legacy_forkop_restore_service() {
    if (LEGACY_FORKOP_INIT == "" || !path_executable(LEGACY_FORKOP_INIT))
        return true;

    let restored = true;
    if (env("PROKOP_INSTALLER_LEGACY_FORKOP_WAS_ENABLED", "0") == "1") {
        let enabled = installer_service_enabled_state(LEGACY_FORKOP_INIT);
        if (enabled.known && !enabled.value &&
            !legacy_forkop_service_action(LEGACY_FORKOP_INIT, "enable", INSTALLER_SERVICE_ACTION_TIMEOUT))
            restored = false;
    }
    if (env("PROKOP_INSTALLER_LEGACY_FORKOP_WAS_RUNNING", "0") == "1") {
        let running = installer_service_running_state(LEGACY_FORKOP_INIT);
        if (running.known && !running.value &&
            !legacy_forkop_service_action(LEGACY_FORKOP_INIT, "start", LEGACY_FORKOP_STOP_TIMEOUT))
            restored = false;
    }
    return restored;
}

// LuCI users that were granted the old ACL groups keep their access.
function legacy_forkop_rewrite_rpcd_grants() {
    let legacy_groups = words(LEGACY_FORKOP_ACL_GROUPS);
    let prokop_groups = words(PROKOP_ACL_GROUPS);
    if (length(legacy_groups) == 0 || length(legacy_groups) != length(prokop_groups) || !uci_load("rpcd"))
        return false;

    let c = uci_cursor();
    let sections = c.get_all("rpcd");
    if (type(sections) != "object")
        return false;

    let changed = false;
    for (let name in keys(sections)) {
        let section = sections[name];
        if (type(section) != "object" || section[".type"] != "login")
            continue;

        for (let option_name in [ "read", "write" ]) {
            if (section[option_name] == null)
                continue;

            let original = uci_value_to_list(section[option_name]);
            let values = [];
            let option_changed = false;
            for (let value in original) {
                let position = index(legacy_groups, value);
                if (position < 0) {
                    push(values, value);
                    continue;
                }
                option_changed = true;
                let replacement = prokop_groups[position];
                if (index(original, replacement) < 0 && index(values, replacement) < 0)
                    push(values, replacement);
            }

            if (!option_changed)
                continue;
            try {
                c.set("rpcd", name, option_name, values);
                changed = true;
            }
            catch (e) {
                warn("Unable to update the rpcd login grants of " + name + ".\n");
            }
        }
    }

    if (changed && !uci_commit("rpcd")) {
        warn("Unable to save the rpcd login grants.\n");
        changed = false;
    }
    uci_cursor_state = false;
    return changed;
}

function legacy_forkop_cleanup_uci() {
    let rpcd_changed = legacy_forkop_rewrite_rpcd_grants();
    remove_globs(env("PROKOP_INSTALLER_LUCI_CACHE_GLOBS", "/var/luci-indexcache* /tmp/luci-indexcache*"));
    remove_globs(env("PROKOP_INSTALLER_LUCI_MODULE_CACHE_GLOBS", "/tmp/luci-modulecache"));
    if (path_executable(INSTALLER_RPCD_INIT))
        run_args([ INSTALLER_RPCD_INIT, "reload" ]);
    print("LEGACY_FORKOP_RPCD_CHANGED=", rpcd_changed ? "1" : "0", "\n");
    return true;
}

// A migration that stopped after the point of no return leaves Prokop
// installed but disabled until the installer completes it.
function installer_hold_prokop() {
    if (!path_executable(INSTALLER_PROKOP_INIT))
        return true;
    let enabled = installer_service_enabled_state(INSTALLER_PROKOP_INIT);
    if (enabled.known && !enabled.value)
        return true;
    return installer_service_action(INSTALLER_PROKOP_INIT, "disable");
}

function release_version_valid(value) {
    return match(as_string(value), /^[0-9]+[.][0-9]+[.][0-9]+$/) != null;
}

function asset_matches(name, kind, ext, version) {
    if (!release_version_valid(version))
        return false;

    if (kind == "backend")
        return name == "prokop_" + version + "." + ext;
    if (kind == "app")
        return name == "luci-app-prokop_" + version + "." + ext;
    if (kind == "i18n")
        return name == "luci-i18n-prokop-ru_" + version + "." + ext;
    return false;
}

function github_message() {
    let value = read_stdin_json();
    if (value == null)
        exit(2);
    if (type(value) == "object" && value.message != null)
        print(as_string(value.message), "\n");
}

function release_tag() {
    let release = read_stdin_json();
    if (type(release) == "object" && release.tag_name != null)
        print(as_string(release.tag_name), "\n");
}

function release_asset_url(kind, ext) {
    let release = read_stdin_json();
    if (type(release) != "object" || type(release.assets) != "array")
        return;
    let version = as_string(release.tag_name || "");
    if (!release_version_valid(version))
        return;
    for (let asset in release.assets) {
        if (type(asset) == "object" && asset_matches(asset.name, kind, ext, version)) {
            print(as_string(asset.browser_download_url || ""), "\n");
            return;
        }
    }
}

function release_asset_sha256(kind, ext) {
    let release = read_stdin_json();
    if (type(release) != "object" || type(release.assets) != "array")
        return;
    let version = as_string(release.tag_name || "");
    if (!release_version_valid(version))
        return;
    for (let asset in release.assets) {
        if (type(asset) != "object" || !asset_matches(asset.name, kind, ext, version))
            continue;
        let digest = lc(as_string(asset.sha256 || asset.digest || ""));
        if (substr(digest, 0, 7) == "sha256:")
            digest = substr(digest, 7);
        if (match(digest, /^[0-9a-f]{64}$/) != null)
            print(digest, "\n");
        return;
    }
}

let mode = ARGV[0] || "";

if (mode == "github-message")
    github_message();
else if (mode == "release-tag")
    release_tag();
else if (mode == "release-asset-url")
    release_asset_url(ARGV[1], ARGV[2]);
else if (mode == "release-asset-sha256")
    release_asset_sha256(ARGV[1], ARGV[2]);
else if (mode == "uci-get") {
    let value = uci_get(ARGV[1]);
    if (value != "")
        print(value, "\n");
}
else if (mode == "dnsmasq-failsafe-restore")
    exit(dnsmasq_failsafe_restore() ? 0 : 1);
else if (mode == "installer-cleanup-legacy")
    exit(installer_cleanup_legacy() ? 0 : 1);
else if (mode == "installer-finalize-legacy")
    exit(installer_finalize_legacy() ? 0 : 1);
else if (mode == "installer-post-install")
    exit(installer_post_install() ? 0 : 1);
else if (mode == "installer-restore-previous-service")
    exit(installer_restore_previous_service() ? 0 : 1);
else if (mode == "installer-persist-mirror")
    exit(installer_persist_mirror(ARGV[1]) ? 0 : 1);
else if (mode == "installer-legacy-forkop-state")
    exit(legacy_forkop_service_state() ? 0 : 1);
else if (mode == "installer-legacy-forkop-deactivate")
    exit(legacy_forkop_deactivate() ? 0 : 1);
else if (mode == "installer-legacy-forkop-dns-handover") {
    legacy_forkop_print_dns(legacy_forkop_dns_handover(legacy_forkop_owns_dns()));
    exit(0);
}
else if (mode == "installer-legacy-forkop-restore-service")
    exit(legacy_forkop_restore_service() ? 0 : 1);
else if (mode == "installer-legacy-forkop-cleanup-uci")
    exit(legacy_forkop_cleanup_uci() ? 0 : 1);
else if (mode == "installer-hold-prokop")
    exit(installer_hold_prokop() ? 0 : 1);
else
    exit(1);
EOF
    fi

    printf '%s\n' "$helper_path"
}


install_json_ucode() {
    PROKOP_INSTALLER_LEGACY_BRAND="$LEGACY_BRAND" \
    PROKOP_INSTALLER_LEGACY_BACKEND="$LEGACY_BACKEND_PACKAGE" \
    PROKOP_INSTALLER_LEGACY_CONFIG_ALT="$LEGACY_CONFIG_PACKAGE_ALT" \
    PROKOP_INSTALLER_DEADLINE_HELPER="$(install_deadline_helper_path)" \
    PROKOP_INSTALLER_COMMAND_RESULT="$TMP_DIR/installer-command" \
        ucode "$(install_json_helper_path)" "$@"
}

download_file_once() {
    case "$FETCHER" in
        wget)
            run_with_deadline "$DOWNLOAD_TIMEOUT_SECONDS" wget -T "$CONNECT_TIMEOUT_SECONDS" -q -O "$2" "$1"
            ;;
        curl)
            curl --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -fsSL "$1" -o "$2"
            ;;
        *)
            return 1
            ;;
    esac
}

download_with_retry() {
    url="$1"
    output_path="$2"
    label="$3"
    attempt=1
    max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        msg "Downloading $label ($attempt/$max_attempts)"

        if download_file_once "$url" "$output_path" && [ -s "$output_path" ]; then
            return 0
        fi

        rm -f "$output_path"
        warn "Retrying $label"
        attempt=$((attempt + 1))
    done

    return 1
}

verify_download_sha256() {
    file_path="$1"
    expected="$(printf '%s' "$2" | tr 'A-F' 'a-f')"
    label="$3"

    case "$expected" in
        *[!0-9a-f]*|'') fail "Release metadata has no valid SHA-256 for $label" ;;
    esac
    [ "${#expected}" -eq 64 ] || fail "Release metadata has no valid SHA-256 for $label"
    command_exists sha256sum || fail "sha256sum is required to verify $label"
    actual="$(sha256sum "$file_path" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || fail "SHA-256 verification failed for $label"
}

pkg_is_installed() {
    pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -e "$pkg_name" 2>/dev/null | grep -Fxq "$pkg_name"
    else
        opkg list-installed 2>/dev/null | awk -v pkg="$pkg_name" '$1 == pkg { found = 1 } END { exit(found ? 0 : 1) }'
    fi
}

# A deadline, and a package database lock held by another opkg or apk (LuCI
# Software, cron) waited out for up to 15 x 2 s instead of failing the
# install at once (A4).
pkg_list_update() {
    pkg_update_tries=0
    while :; do
        pkg_update_log="$TMP_DIR/pkg-update.$$"
        if [ "$PKG_IS_APK" -eq 1 ]; then
            run_with_deadline "${PKG_LIST_UPDATE_TIMEOUT_SECONDS:-180}" apk update </dev/null >"$pkg_update_log" 2>&1
        else
            run_with_deadline "${PKG_LIST_UPDATE_TIMEOUT_SECONDS:-180}" opkg update </dev/null >"$pkg_update_log" 2>&1
        fi
        pkg_update_status=$?
        cat "$pkg_update_log"
        if [ "$pkg_update_status" -ne 0 ] && [ "$pkg_update_tries" -lt "${PKG_LOCK_RETRIES:-15}" ] &&
            grep -Eq 'Could not lock|Unable to lock database|Resource temporarily unavailable' "$pkg_update_log"; then
            rm -f "$pkg_update_log"
            pkg_update_tries=$((pkg_update_tries + 1))
            echo "Package database is locked; retrying ($pkg_update_tries/${PKG_LOCK_RETRIES:-15})"
            sleep 2
            continue
        fi
        rm -f "$pkg_update_log"
        [ "$pkg_update_status" -ne 124 ] || echo "Package list update did not finish in ${PKG_LIST_UPDATE_TIMEOUT_SECONDS:-180} s" >&2
        return "$pkg_update_status"
    done
}

rollback_package_mirror() {
    [ "$MIRROR_TRANSACTION_ACTIVE" -eq 1 ] || return 0
    [ -n "$MIRROR_BACKUP_MANIFEST" ] && [ -f "$MIRROR_BACKUP_MANIFEST" ] || return 0

    while IFS='|' read -r repository_file backup_file original_state; do
        [ -n "$repository_file" ] || continue
        if [ "$original_state" = "absent" ]; then
            rm -f "$repository_file" 2>/dev/null || true
        elif [ -f "$backup_file" ]; then
            cp "$backup_file" "$repository_file" 2>/dev/null || true
        fi
    done < "$MIRROR_BACKUP_MANIFEST"
    MIRROR_TRANSACTION_ACTIVE=0
    warn "Package feed configuration was restored after an installation error"
}

backup_package_mirror_file() {
    repository_file="$1"
    backup_file="$TMP_DIR/repository.$MIRROR_BACKUP_COUNT.original"

    if [ -e "$repository_file" ]; then
        cp "$repository_file" "$backup_file" || fail "Failed to back up $repository_file"
        printf '%s|%s|present\n' "$repository_file" "$backup_file" >> "$MIRROR_BACKUP_MANIFEST"
    else
        printf '%s||absent\n' "$repository_file" >> "$MIRROR_BACKUP_MANIFEST"
    fi
    MIRROR_BACKUP_COUNT=$((MIRROR_BACKUP_COUNT + 1))
}

begin_package_mirror_transaction() {
    MIRROR_BACKUP_MANIFEST="$TMP_DIR/package-mirror-backups"
    : > "$MIRROR_BACKUP_MANIFEST"
    MIRROR_BACKUP_COUNT=0
    MIRROR_TRANSACTION_ACTIVE=1
}

rewrite_package_repository_file() {
    repository_file="$1"
    [ -e "$repository_file" ] || return 0

    rewritten="$TMP_DIR/repository.$MIRROR_BACKUP_COUNT.rewritten"
    sed -E \
        -e "s#https?://mirror\\.(51343|infotechtg)\\.ru/openwrt/releases/#${MIRROR_BASE_URL}/openwrt/releases/#" \
        -e "s#https?://(downloads|archive)\\.openwrt\\.org/releases/#${MIRROR_BASE_URL}/openwrt/releases/#" \
        -e "s#https?://[^/]+/pub/software/openwrt/releases/#${MIRROR_BASE_URL}/openwrt/releases/#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v?([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/?([[:space:]]|$)#${MIRROR_BASE_URL}/openwrt/releases/\\1/targets/\\2/\\3/packages\\4#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages/packages\\.adb#${MIRROR_BASE_URL}/openwrt/releases/\\1/targets/\\2/\\3/packages/packages.adb#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages\\.adb#${MIRROR_BASE_URL}/openwrt/releases/\\1/packages/\\2/\\3/packages.adb#" \
        "$repository_file" > "$rewritten" || fail "Failed to prepare $repository_file"

    if grep -E 'https?://(downloads|archive)\.openwrt\.org/releases/|https?://[^/]+/pub/software/openwrt/releases/' \
        "$rewritten" >/dev/null; then
        fail "Some OpenWrt feeds in $repository_file could not be redirected to $MIRROR_BASE_URL"
    fi

    if cmp -s "$repository_file" "$rewritten"; then
        return 0
    fi

    backup_package_mirror_file "$repository_file"
    persistent_backup="${repository_file}${LEGACY_FORKOP_FEED_BACKUP_SUFFIX}"
    [ -e "$persistent_backup" ] || cp "$repository_file" "$persistent_backup" ||
        fail "Failed to preserve the original $repository_file"
    cp "$rewritten" "$repository_file" || fail "Failed to update $repository_file"
}

# Moves the OpenWrt release feeds that an upstream installation left on a former
# upstream mirror back to downloads.openwrt.org, with the mapping of
# mirror-migration.sh: their vNN.x/vX.Y.Z/<target>/<subtarget> layout becomes
# the standard OpenWrt layout. Lines on any other host stay as they are.
restore_legacy_mirror_repository_file() {
    repository_file="$1"
    [ -f "$repository_file" ] || return 0
    grep -Eq "$LEGACY_MIRROR_REGEX" "$repository_file" || return 0

    restored="$TMP_DIR/repository.$MIRROR_BACKUP_COUNT.restored"
    sed -E \
        -e "\\#${LEGACY_MIRROR_REGEX}#{" \
        -e "s#${LEGACY_MIRROR_REGEX}openwrt/releases/#${OFFICIAL_RELEASES_URL}#" \
        -e "s#${OFFICIAL_RELEASES_REGEX}v[0-9]+\\.x/v?([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/?([[:space:]]|$)#${OFFICIAL_RELEASES_URL}\\1/targets/\\2/\\3/packages\\4#" \
        -e "s#${OFFICIAL_RELEASES_REGEX}v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages/packages\\.adb#${OFFICIAL_RELEASES_URL}\\1/targets/\\2/\\3/packages/packages.adb#" \
        -e "s#${OFFICIAL_RELEASES_REGEX}v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages\\.adb#${OFFICIAL_RELEASES_URL}\\1/packages/\\2/\\3/packages.adb#" \
        -e '}' \
        "$repository_file" > "$restored" || fail "Failed to prepare $repository_file"

    if grep -Eq "$LEGACY_MIRROR_REGEX" "$restored"; then
        warn "$repository_file still names a former upstream mirror outside its OpenWrt release feeds; those lines were left unchanged"
    fi
    if cmp -s "$repository_file" "$restored"; then
        return 0
    fi

    backup_package_mirror_file "$repository_file"
    cp "$restored" "$repository_file" || fail "Failed to update $repository_file"
}

# The file set of mirror-migration.sh and the full uninstall.
restore_legacy_mirror_feeds() {
    for repository_file in "$OPKG_DISTFEEDS_FILE" "${OPKG_DISTFEEDS_FILE%/*}/customfeeds.conf" \
        "$APK_REPOSITORIES_FILE" "${APK_DISTFEEDS_FILE%/*}"/*.list; do
        restore_legacy_mirror_repository_file "$repository_file"
    done
}

commit_package_mirror_transaction() {
    MIRROR_TRANSACTION_ACTIVE=0
}

remove_upstream_prokop_repository() {
    # The upstream feed would replace the fork's packages, and apk would trust
    # its key for every repository. Neither is ever installed by this installer.
    for upstream_file in "$UPSTREAM_APK_REPOSITORY_FILE" "$UPSTREAM_APK_KEY_FILE"; do
        [ -e "$upstream_file" ] || [ -L "$upstream_file" ] || continue
        backup_package_mirror_file "$upstream_file"
        rm -f "$upstream_file" || fail "Failed to remove $upstream_file"
        warn "Removed $upstream_file left by an upstream $LEGACY_FORKOP_BRAND installation"
    done
}

configure_apk_mirror() {
    distfeeds="$APK_DISTFEEDS_FILE"

    [ "$PKG_IS_APK" -eq 1 ] || return 0
    [ -s "$distfeeds" ] || fail "$distfeeds is missing or empty"

    for repository_file in "$APK_REPOSITORIES_FILE" "$distfeeds"; do
        rewrite_package_repository_file "$repository_file"
    done
    pkg_list_update || {
        rollback_package_mirror
        fail "Failed to update APK package lists from $MIRROR_BASE_URL; original feeds were restored"
    }
    commit_package_mirror_transaction
    msg "OpenWrt package feeds now use $MIRROR_BASE_URL"
}

configure_opkg_mirror() {
    distfeeds="$OPKG_DISTFEEDS_FILE"

    [ "$PKG_IS_APK" -eq 0 ] || return 0
    command_exists opkg || fail "OpenWrt opkg package manager is required"
    [ -s "$distfeeds" ] || fail "$distfeeds is missing or empty"

    backups_before_rewrite="$MIRROR_BACKUP_COUNT"
    rewrite_package_repository_file "$distfeeds"
    if [ "$MIRROR_BACKUP_COUNT" -eq "$backups_before_rewrite" ]; then
        msg "No official OpenWrt OPKG feeds were changed; vendor and custom feeds remain unchanged"
        return 0
    fi
    grep -Fq "$MIRROR_BASE_URL/openwrt/releases/" "$distfeeds" ||
        fail "No mirrored OpenWrt release feeds were written to $distfeeds"
    pkg_list_update || {
        rollback_package_mirror
        fail "Failed to update OPKG package lists from $MIRROR_BASE_URL; original feeds were restored"
    }
    commit_package_mirror_transaction
    msg "OpenWrt package feeds now use $MIRROR_BASE_URL"
}

configure_package_mirror() {
    # Feed changes stay revertible until the package lists were updated.
    begin_package_mirror_transaction
    remove_upstream_prokop_repository

    if [ -z "$MIRROR_BASE_URL" ]; then
        # Package lists, bootstrap and dependencies must not depend on the
        # former upstream mirror; a failed list update restores its feeds.
        backups_before_restore="$MIRROR_BACKUP_COUNT"
        restore_legacy_mirror_feeds
        if [ "$MIRROR_BACKUP_COUNT" -eq "$backups_before_restore" ]; then
            msg "No dependency mirror was requested; OpenWrt package feeds remain unchanged"
        else
            msg "No dependency mirror was requested; OpenWrt feeds left on the former upstream mirror now use downloads.openwrt.org"
        fi
        return 0
    fi

    if [ "$PKG_IS_APK" -eq 1 ]; then
        configure_apk_mirror
    else
        configure_opkg_mirror
    fi
}

pkg_install_name() {
    pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add "$pkg_name" </dev/null
    else
        opkg install "$pkg_name" </dev/null
    fi
}

pkg_install_files() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$@" </dev/null
    else
        opkg install --force-overwrite --force-downgrade "$@" </dev/null
    fi
}

opkg_installed_version() {
    opkg list-installed 2>/dev/null | awk -v pkg="$1" '$1 == pkg && $2 == "-" { print $3; exit }'
}

# apk lists an installed package as "<name>-<version> <arch> ...".
apk_installed_version() {
    apk list --installed "$1" 2>/dev/null | awk -v prefix="$1-" '{
        for (i = 1; i <= NF; i++)
            if (index($i, prefix) == 1 && length($i) > length(prefix)) {
                print substr($i, length(prefix) + 1)
                exit
            }
    }'
}

# The installed version of a package; empty when it is not installed or the
# version cannot be read.
pkg_installed_version() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk_installed_version "$1"
    else
        opkg_installed_version "$1"
    fi
}

# Installs a Prokop package file. opkg calls an installed package of the same
# version up to date and keeps it, even when it is another build of that version
# such as an upstream release: --force-reinstall replaces it. opkg runs that as
# a removal of the installed package (prerm "remove") before the installation,
# so it is used only when the versions match. apk pins a package file by its
# hash and replaces another build of the same version by itself.
pkg_install_prokop_file() {
    prokop_package_name="$1"
    prokop_package_file="$2"

    if [ "$PKG_IS_APK" -eq 0 ] && [ -n "$PROKOP_PACKAGE_VERSION" ] &&
        [ "$(opkg_installed_version "$prokop_package_name")" = "$PROKOP_PACKAGE_VERSION" ]; then
        msg "Reinstalling $prokop_package_name $PROKOP_PACKAGE_VERSION from the Prokop release"
        opkg install --force-reinstall --force-overwrite --force-downgrade "$prokop_package_file" </dev/null
    else
        pkg_install_files "$prokop_package_file"
    fi
}

ensure_bootstrap_tool() {
    tool_name="$1"
    package_name="$2"

    if command_exists "$tool_name"; then
        return 0
    fi

    msg "Installing bootstrap dependency: $package_name"
    pkg_install_name "$package_name" || fail "Failed to install $package_name"
}

ensure_bootstrap_package() {
    package_name="$1"

    if pkg_is_installed "$package_name"; then
        return 0
    fi

    msg "Installing bootstrap dependency: $package_name"
    pkg_install_name "$package_name" || fail "Failed to install $package_name"
}

ensure_bootstrap_ucode_runtime() {
    ensure_bootstrap_tool "ucode" "ucode"
    ensure_bootstrap_package "ucode-mod-fs"
    ensure_bootstrap_package "ucode-mod-uci"
}

sync_time() {
    current_year=""

    if ! command_exists ntpd; then
        return 0
    fi

    current_year="$(date +%Y 2>/dev/null || true)"
    case "$current_year" in
        ''|*[!0-9]*) current_year=0 ;;
    esac

    if [ "$current_year" -ge 2024 ]; then
        return 0
    fi

    # One bounded query: without an answer (WAN down, NTP blocked) `ntpd -q`
    # never returns, and the installer would hang here.
    ntpd -q \
        -p 194.190.168.1 \
        -p 216.239.35.0 \
        -p 216.239.35.4 \
        -p 162.159.200.1 \
        -p 162.159.200.123 >/dev/null 2>&1 &
    ntpd_pid=$!
    (sleep 15; kill -KILL "$ntpd_pid" 2>/dev/null) >/dev/null 2>&1 &
    ntpd_watchdog=$!
    wait "$ntpd_pid" 2>/dev/null || true
    kill "$ntpd_watchdog" 2>/dev/null || true
}

check_root() {
    if command_exists id && [ "$(id -u)" != "0" ]; then
        fail "Please run this installer as root"
    fi
}

mirror_host_name() {
    prokop_mirror_host="${MIRROR_BASE_URL#*://}"
    prokop_mirror_host="${prokop_mirror_host%%/*}"
    printf '%s\n' "${prokop_mirror_host%%:*}"
}

check_mirror_platform_support() {
    # Only an opted-in mirror publishes a platform index worth consulting.
    [ -n "$MIRROR_BASE_URL" ] || return 0

    platform_index="$TMP_DIR/prokop-platforms.tsv"
    platform_format="ipk"
    [ "$PKG_IS_APK" -eq 0 ] || platform_format="apk"

    platform_index_url="$MIRROR_BASE_URL$LEGACY_FORKOP_MIRROR_PLATFORM_INDEX"
    platform_index_error="$TMP_DIR/prokop-platforms.err"

    # A failed download says nothing about what the mirror holds, so report what
    # the downloader reported instead of guessing that synchronization is behind.
    if ! download_file_once "$platform_index_url" "$platform_index" 2>"$platform_index_error"; then
        rm -f "$platform_index"
        platform_index_reason="$(sed -n 's/^[[:space:]]*\([^[:space:]].*\)$/\1/p' "$platform_index_error" 2>/dev/null | tail -n 1)"
        rm -f "$platform_index_error"
        # The deadline helper kills a stalled fetch without a message of its own.
        [ -n "$platform_index_reason" ] || platform_index_reason="$FETCHER produced no output; the request timed out or was interrupted"

        # The package list update against the mirror decides; it restores the
        # original feeds when the mirror cannot serve this router.
        warn "Could not download $platform_index_url: $platform_index_reason; package feeds will be verified before installation
Check that this router resolves $(mirror_host_name) and can reach it over HTTPS. If your mirror answers with a private address, DNS rebind protection drops that answer: allow it with
    uci add_list dhcp.@dnsmasq[0].rebind_domain='$(mirror_host_name)' && uci commit dhcp && /etc/init.d/dnsmasq restart"
        return 0
    fi

    rm -f "$platform_index_error"

    if awk -v target="$OPENWRT_TARGET" -v architecture="$OPENWRT_ARCHITECTURE" \
        -v release="$OPENWRT_RELEASE" -v format="$platform_format" '
            /^[[:space:]]*(#|$)/ { next }
            $1 == target && $2 == architecture && $3 == release && $4 == format { found = 1 }
            END { exit(found ? 0 : 1) }
        ' "$platform_index"; then
        return 0
    fi

    fail "The dependency mirror $MIRROR_BASE_URL does not yet contain $OPENWRT_TARGET / $OPENWRT_ARCHITECTURE for OpenWrt $OPENWRT_RELEASE ($platform_format). Run the installer without --mirror or PROKOP_MIRROR_BASE_URL to use the official OpenWrt feeds."
}

check_system() {
    release=""
    major=""
    model=""
    target=""
    architecture=""

    [ -f /etc/openwrt_release ] || fail "This installer supports OpenWrt only"

    model="$(cat /tmp/sysinfo/model 2>/dev/null || true)"
    [ -n "$model" ] && msg "Router model: $model"

    release="$(read_openwrt_release_value "DISTRIB_RELEASE")"
    target="$(read_openwrt_release_value "DISTRIB_TARGET")"
    architecture="$(read_openwrt_release_value "DISTRIB_ARCH")"
    major="$(printf '%s' "$release" | sed 's/[^0-9].*$//' | cut -d. -f1)"

    [ -n "$release" ] || fail "Unable to detect the OpenWrt release"
    if [ -n "$major" ] && [ "$major" -lt 24 ]; then
        fail "Prokop requires OpenWrt 24.10 or newer"
    fi
    case "$release" in
        24.10.*)
            [ "$PKG_IS_APK" -eq 0 ] || fail "OpenWrt $release must use opkg/IPK packages"
            ;;
        24.*)
            fail "Prokop supports OpenWrt 24.10.x, but not $release"
            ;;
        *)
            [ "$PKG_IS_APK" -eq 1 ] || fail "OpenWrt $release is expected to use apk packages"
            ;;
    esac
    [ -n "$target" ] || fail "Unable to detect the OpenWrt target"
    [ -n "$architecture" ] || fail "Unable to detect the OpenWrt package architecture"

    OPENWRT_RELEASE="$release"
    OPENWRT_TARGET="$target"
    OPENWRT_ARCHITECTURE="$architecture"
    check_mirror_platform_support

    msg "OpenWrt $release, target $target, architecture $architecture"

}

available_flash_space_kb() {
    available_space="$(df /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -n "$available_space" ] || available_space="$(df / 2>/dev/null | awk 'NR==2 {print $4}')"

    case "$available_space" in
        ''|*[!0-9]*) return 1 ;;
    esac

    printf '%s\n' "$available_space"
}

file_size_kb() {
    file_size_bytes="$(wc -c <"$1" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$file_size_bytes" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$(((file_size_bytes + 1023) / 1024))"
}

prokop_install_required_space_kb() {
    archive_kb=0
    for package_file in "$PROKOP_BACKEND_FILE" "$PROKOP_APP_FILE" "$PROKOP_I18N_FILE"; do
        [ -n "$package_file" ] && [ -s "$package_file" ] || continue
        package_kb="$(file_size_kb "$package_file")" || return 1
        archive_kb=$((archive_kb + package_kb))
    done

    [ "$archive_kb" -gt 0 ] || return 1

    missing_dependency_count=0
    for dependency in \
        ca-bundle kmod-inet-diag kmod-tun curl ucode \
        ucode-mod-fs ucode-mod-uci kmod-nft-tproxy coreutils-base64 \
        bind-dig nftables-json kmod-nft-nat ip-full luci-base; do
        pkg_is_installed "$dependency" ||
            missing_dependency_count=$((missing_dependency_count + 1))
    done

    # OpenWrt compresses the writable overlay, so package archive size is a
    # useful baseline. Doubling it covers unpacking variance; missing direct
    # dependencies get a separate conservative allowance.
    # A migration from the renamed installation copies its state next to it
    # until that installation is removed (LEGACY_FORKOP_COPY_KB).
    printf '%s\n' "$((
        archive_kb * PACKAGE_ARCHIVE_SPACE_FACTOR +
        missing_dependency_count * MISSING_DEPENDENCY_ALLOWANCE_KB +
        PACKAGE_INSTALL_OVERHEAD_KB + FLASH_RESERVE_KB + LEGACY_FORKOP_COPY_KB
    ))"
}

legacy_binary_managed_sing_box_present() {
    [ "$PROKOP_LEGACY_DETECTED" -eq 1 ] &&
        [ -r /etc/init.d/sing-box ] &&
        grep -Fq 'managed sing-box service for binary variants' /etc/init.d/sing-box &&
        [ -x /usr/bin/sing-box ]
}

sing_box_tiny_is_active() {
    pkg_is_installed "sing-box-tiny" &&
        ! pkg_is_installed "sing-box" &&
        ! pkg_is_installed "sing-box-extended" &&
        [ -x /usr/bin/sing-box ]
}

apk_world_requests_sing_box_tiny() {
    [ "$PKG_IS_APK" -eq 1 ] || return 1
    [ -r "$APK_WORLD_FILE" ] || return 1
    grep -Eq '^sing-box-tiny([<>=~].*)?$' "$APK_WORLD_FILE"
}

package_file_list() {
    package_name="$1"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -L "$package_name" 2>/dev/null
    else
        opkg files "$package_name" 2>/dev/null
    fi
}

package_owns_path() {
    package_name="$1"
    owned_path="$2"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -W "$owned_path" 2>/dev/null |
            grep -Fq "$owned_path is owned by ${package_name}-"
    else
        package_file_list "$package_name" |
            sed 's#^\([^/]\)#/\1#' |
            grep -Fxq "$owned_path"
    fi
}

installed_sing_box_package() {
    owner=""
    owner_count=0
    for candidate in sing-box-tiny sing-box sing-box-extended; do
        if pkg_is_installed "$candidate" && package_owns_path "$candidate" /usr/bin/sing-box; then
            owner="$candidate"
            owner_count=$((owner_count + 1))
        fi
    done
    [ "$owner_count" -eq 1 ] || return 1
    printf '%s\n' "$owner"
}

package_reclaimable_space_kb() {
    package_name="$1"
    archive_kb=""

    if [ "$PKG_IS_APK" -eq 1 ]; then
        current_package_dir="$TMP_DIR/current-sing-box-package"
        mkdir -p "$current_package_dir" || return 1
        apk fetch --output "$current_package_dir" "$package_name" </dev/null || return 1
        current_package_file="$(find "$current_package_dir" -maxdepth 1 -type f -name '*.apk' | head -n 1)"
        [ -n "$current_package_file" ] && [ -s "$current_package_file" ] || return 1
        archive_kb="$(file_size_kb "$current_package_file")" || return 1
    else
        archive_size_bytes="$(opkg info "$package_name" 2>/dev/null |
            awk '$1 == "Size:" && $2 ~ /^[0-9]+$/ { value = $2 } END { print value }')"
        case "$archive_size_bytes" in
            ''|*[!0-9]*) return 1 ;;
        esac
        archive_kb=$(((archive_size_bytes + 1023) / 1024))
    fi

    # Count only 90% of the current package archive as guaranteed reclaimable.
    # This leaves room for package metadata and preserved configuration files.
    printf '%s\n' "$((archive_kb * 9 / 10))"
}

download_sing_box_tiny_package() {
    [ -n "$SING_BOX_TINY_FILE" ] && [ -s "$SING_BOX_TINY_FILE" ] && return 0

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk fetch --output "$TMP_DIR" sing-box-tiny </dev/null || return 1
        SING_BOX_TINY_FILE="$(find "$TMP_DIR" -maxdepth 1 -type f -name 'sing-box-tiny-*.apk' | head -n 1)"
    else
        (cd "$TMP_DIR" && opkg download sing-box-tiny </dev/null) || return 1
        SING_BOX_TINY_FILE="$(find "$TMP_DIR" -maxdepth 1 -type f -name 'sing-box-tiny_*.ipk' | head -n 1)"
    fi
    [ -n "$SING_BOX_TINY_FILE" ] && [ -s "$SING_BOX_TINY_FILE" ]
}

pkg_remove_name() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del --force-broken-world "$1" </dev/null
    else
        opkg remove --force-depends "$1" </dev/null
    fi
}

switch_sing_box_to_downloaded_tiny() {
    previous_package="$1"
    [ -s "$SING_BOX_TINY_FILE" ] || return 1

    pkg_remove_name "$previous_package" || return 1
    SING_BOX_CHANGE_STARTED=1
    pkg_install_files "$SING_BOX_TINY_FILE" || return 1
    validate_sing_box_tiny_install || return 1
    SING_BOX_TINY_SWITCHED=1
}

repair_legacy_orphaned_sing_box_to_tiny() {
    # A legacy Prokop installation may leave its binary in the overlay after
    # its old package has been removed. There is then no package owner from
    # which the normal low-space path can calculate reclaimable space. This
    # recovery is deliberately restricted to a confirmed legacy migration and
    # only runs after tiny is downloaded. APK additionally needs a matching
    # world request; opkg has no equivalent world state.
    [ "$PROKOP_LEGACY_DETECTED" -eq 1 ] || return 1
    if [ "$PKG_IS_APK" -eq 1 ] && ! apk_world_requests_sing_box_tiny; then
        return 1
    fi
    [ -e /usr/bin/sing-box ] || return 1
    [ -s "$SING_BOX_TINY_FILE" ] || return 1

    warn "Removing the unowned legacy /usr/bin/sing-box binary before installing sing-box-tiny"
    for package_name in sing-box-tiny sing-box sing-box-extended; do
        if pkg_is_installed "$package_name" && ! pkg_remove_name "$package_name"; then
            warn "Failed to remove inconsistent $package_name package state before sing-box-tiny repair"
            return 1
        fi
    done
    rm -f /usr/bin/sing-box || return 1
    [ ! -e /usr/bin/sing-box ] || return 1
    SING_BOX_CHANGE_STARTED=1
    pkg_install_files "$SING_BOX_TINY_FILE" || return 1
    validate_sing_box_tiny_install || return 1
    SING_BOX_TINY_SWITCHED=1
}

validate_sing_box_tiny_install() {
    sing_box_tiny_is_active || return 1
    /usr/bin/sing-box version >/dev/null 2>&1 || return 1
    [ -x /etc/init.d/sing-box ] || return 1
}

restore_current_prokop_on_failure() {
    [ "$INSTALL_MODE" = "update" ] || return 0
    [ "$LEGACY_CLEANUP_DONE" -eq 1 ] || return 0

    if PROKOP_WAS_ENABLED="$PROKOP_WAS_ENABLED" PROKOP_WAS_RUNNING="$PROKOP_WAS_RUNNING" \
        install_json_ucode installer-restore-previous-service; then
        warn "The previous Prokop service state was restored after the installation failure"
    else
        warn "Failed to restore the previous Prokop service state automatically"
    fi
}

ensure_flash_space() {
    required_space="$(prokop_install_required_space_kb)" ||
        fail "Failed to calculate the Prokop package installation size"
    PROKOP_INSTALL_REQUIRED_KB="$required_space"
    available_space="$(available_flash_space_kb 2>/dev/null || true)"

    [ -n "$available_space" ] || fail "Unable to determine free flash space"
    pending_world_tiny=0
    if apk_world_requests_sing_box_tiny && ! sing_box_tiny_is_active; then
        pending_world_tiny=1
        warn "APK world requests sing-box-tiny, but the installed sing-box state does not satisfy it; repairing this before installing Prokop"
    fi

    if [ "$available_space" -ge "$required_space" ] && [ "$pending_world_tiny" -eq 0 ]; then
        msg "Flash preflight passed. Available: ${available_space} KB, installation plan: ${required_space} KB"
        return 0
    fi

    previous_package="$(installed_sing_box_package 2>/dev/null || true)"
    if [ -z "$previous_package" ]; then
        download_sing_box_tiny_package ||
            fail "Failed to download sing-box-tiny before repairing the unowned legacy binary"
        if repair_legacy_orphaned_sing_box_to_tiny; then
            SING_BOX_INSTALL_VARIANT=""
            available_space="$(available_flash_space_kb 2>/dev/null || true)"
            if [ -n "$available_space" ] && [ "$available_space" -ge "$required_space" ]; then
                msg "Flash preflight passed after repairing the legacy sing-box state. Available: ${available_space} KB, installation plan: ${required_space} KB"
                return 0
            fi
            fail "Free flash after repairing the legacy sing-box state is below the calculated Prokop plan. Available: ${available_space:-unknown} KB, installation plan: ${required_space} KB. sing-box-tiny remains installed."
        fi
        fail "Not enough free flash space. Available: ${available_space} KB, installation plan: ${required_space} KB. /usr/bin/sing-box is not owned by one supported package."
    fi
    if [ "$previous_package" = "sing-box-tiny" ] && [ "$pending_world_tiny" -eq 0 ]; then
        fail "Not enough free flash space after accounting for the already installed sing-box-tiny. Available: ${available_space} KB, installation plan: ${required_space} KB."
    fi

    download_sing_box_tiny_package ||
        fail "Failed to download sing-box-tiny before changing the installed sing-box package"
    tiny_archive_kb="$(file_size_kb "$SING_BOX_TINY_FILE")" ||
        fail "Failed to determine the downloaded sing-box-tiny package size"
    tiny_required_kb=$(((tiny_archive_kb * 5 + 3) / 4 + PACKAGE_INSTALL_OVERHEAD_KB))
    reclaimable_kb="$(package_reclaimable_space_kb "$previous_package" 2>/dev/null || true)"
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR/current-sing-box-package"
    case "$reclaimable_kb" in
        ''|*[!0-9]*) fail "Failed to calculate space reclaimable from $previous_package" ;;
    esac
    expected_after_kb=$((available_space + reclaimable_kb - tiny_required_kb))
    if [ "$expected_after_kb" -lt "$required_space" ]; then
        fail "Not enough free flash space even after replacing $previous_package with sing-box-tiny. Available now: ${available_space} KB, reclaimable: ${reclaimable_kb} KB, tiny allowance: ${tiny_required_kb} KB, Prokop plan: ${required_space} KB."
    fi

    msg "Low-space plan: ${available_space} KB free + ${reclaimable_kb} KB reclaimable - ${tiny_required_kb} KB for tiny = ${expected_after_kb} KB; Prokop plan: ${required_space} KB"
    warn "$(installer_text low_flash_space)"
    if interactive_terminal_available; then
        numbered_yes_no_prompt "$(installer_text tiny_recovery_prompt)" ||
            fail "Installation was cancelled before changing sing-box"
    elif [ "$ALLOW_LOW_SPACE_TINY" -eq 1 ]; then
        msg "Low-space sing-box-tiny replacement was explicitly authorized by --allow-low-space-tiny"
    else
        fail "Not enough free flash space. Replacing sing-box with sing-box-tiny requires an interactive terminal or --allow-low-space-tiny."
    fi

    warn "$(installer_text tiny_recovery_warning)"
    switch_sing_box_to_downloaded_tiny "$previous_package" ||
        fail "Failed to replace $previous_package with the already downloaded sing-box-tiny package"
    SING_BOX_INSTALL_VARIANT=""

    available_space="$(available_flash_space_kb 2>/dev/null || true)"
    if [ -n "$available_space" ] && [ "$available_space" -ge "$required_space" ]; then
        msg "Flash preflight passed after switching to sing-box-tiny. Available: ${available_space} KB, installation plan: ${required_space} KB"
        return 0
    fi

    fail "Free flash after installing sing-box-tiny is below the calculated Prokop plan. Available: ${available_space:-unknown} KB, installation plan: ${required_space} KB. sing-box-tiny remains installed."
}

installer_is_ru() {
    [ "$INSTALLER_LANG" = "ru" ]
}

installer_text() {
    key="$1"

    if installer_is_ru; then
        case "$key" in
            yes) printf '%s\n' "Да" ;;
            no) printf '%s\n' "Нет" ;;
            select) printf '%s\n' "Выберите номер" ;;
            invalid_choice) printf '%s\n' "Введите номер из списка." ;;
            language_prompt) printf '%s\n' "Выберите язык установщика:" ;;
            language_ru) printf '%s\n' "Русский" ;;
            language_en) printf '%s\n' "English" ;;
            i18n_installed) printf '%s\n' "Русский пакет интерфейса уже установлен и будет обновлен." ;;
            i18n_prompt) printf '%s\n' "Установить русский пакет интерфейса?" ;;
            i18n_skip) printf '%s\n' "Продолжаю без русского пакета интерфейса." ;;
            luci_ru) printf '%s\n' "Русский пакет интерфейса будет установлен автоматически." ;;
            sing_box_prompt) printf '%s\n' "Какую сборку singbox ставить?" ;;
            sing_box_tiny) printf '%s\n' "singbox tiny (по умолчанию)" ;;
            sing_box_stable) printf '%s\n' "singbox stable" ;;
            sing_box_extended) printf '%s\n' "singbox extended (если нужен xhttp)" ;;
            sing_box_skip_msg) printf '%s\n' "Пропускаю установку sing-box." ;;
            low_flash_space) printf '%s\n' "Для установки Prokop не хватает места, но предварительный расчет подтверждает, что переход на sing-box tiny освободит достаточно flash." ;;
            tiny_recovery_prompt) printf '%s\n' "Заменить установленный пакет sing-box на sing-box tiny? Это постоянное изменение; расширенные возможности, включая xhttp, станут недоступны" ;;
            tiny_recovery_warning) printf '%s\n' "Устанавливаю заранее скачанный sing-box tiny напрямую через системный пакетный менеджер." ;;
            legacy_migration_prompt) printf '%s\n' "Перейти с legacy-версии на Prokop? Ее пакеты будут удалены только после сохранения конфигурации и успешной предварительной проверки" ;;
            legacy_backup_ready) printf '%s\n' "Резервная копия legacy-конфигурации создана" ;;
            legacy_cleanup_start) printf '%s\n' "Удаляю legacy-пакеты и начинаю миграцию конфигурации" ;;
            legacy_forkop_detected) printf '%s\n' "Найдена установка $LEGACY_FORKOP_BRAND. Prokop — это переименованный $LEGACY_FORKOP_BRAND: его настройки и данные будут перенесены, после чего $LEGACY_FORKOP_BRAND будет удален." ;;
            legacy_forkop_prompt) printf '%s\n' "Перейти с $LEGACY_FORKOP_BRAND на Prokop? $LEGACY_FORKOP_BRAND будет удален только после установки Prokop и проверки перенесенной конфигурации" ;;
            legacy_forkop_cancelled) printf '%s\n' "Переход отменен; $LEGACY_FORKOP_BRAND не изменен" ;;
            legacy_forkop_confirmed) printf '%s\n' "Переход с $LEGACY_FORKOP_BRAND подтвержден параметром --confirm-legacy-migration" ;;
            legacy_forkop_needs_confirmation) printf '%s\n' "Для перехода с $LEGACY_FORKOP_BRAND на Prokop нужен интерактивный терминал или параметр --confirm-legacy-migration. Ничего не изменено. Запустите:
    wget -qO- $RELEASE_BASE_URL/install.sh | sh -s -- --confirm-legacy-migration" ;;
            legacy_forkop_backups) printf '%s\n' "Состояние $LEGACY_FORKOP_BRAND и резервные копии (доступ только для root) сохранены в" ;;
            legacy_forkop_stage_prepare) printf '%s\n' "Переход с $LEGACY_FORKOP_BRAND: загружаю Prokop" ;;
            legacy_forkop_stage_install) printf '%s\n' "Переход с $LEGACY_FORKOP_BRAND: устанавливаю Prokop рядом с ним и переношу настройки" ;;
            legacy_forkop_stage_deactivate) printf '%s\n' "Переход с $LEGACY_FORKOP_BRAND: останавливаю и отключаю его собственными командами" ;;
            legacy_forkop_stage_remove) printf '%s\n' "Переход с $LEGACY_FORKOP_BRAND: удаляю его пакеты" ;;
            legacy_forkop_stage_cleanup) printf '%s\n' "Переход с $LEGACY_FORKOP_BRAND: удаляю оставшиеся файлы" ;;
            legacy_forkop_stage_finish) printf '%s\n' "Переход с $LEGACY_FORKOP_BRAND: завершаю установку Prokop" ;;
            legacy_forkop_config_copied) printf '%s\n' "Конфигурация $LEGACY_FORKOP_BRAND перенесена в" ;;
            legacy_forkop_config_kept) printf '%s\n' "Измененная конфигурация Prokop сохранена как есть; конфигурация $LEGACY_FORKOP_BRAND осталась в резервной копии" ;;
            legacy_forkop_no_config) printf '%s\n' "У $LEGACY_FORKOP_BRAND нет конфигурации; Prokop использует настройки по умолчанию" ;;
            legacy_forkop_migration_failed) printf '%s\n' "Не удалось перенести конфигурацию $LEGACY_FORKOP_BRAND" ;;
            legacy_forkop_state_copied) printf '%s\n' "Данные $LEGACY_FORKOP_BRAND скопированы в" ;;
            legacy_forkop_validation_passed) printf '%s\n' "Перенесенная конфигурация прошла проверку Prokop" ;;
            legacy_forkop_validation_failed) printf '%s\n' "Перенесенная конфигурация не прошла проверку Prokop" ;;
            legacy_forkop_rolled_back) printf '%s\n' "Изменения отменены; $LEGACY_FORKOP_BRAND оставлен как был" ;;
            legacy_forkop_rollback_incomplete) printf '%s\n' "Откат выполнен не полностью; проверьте Prokop и $LEGACY_FORKOP_BRAND. Резервные копии остались в" ;;
            legacy_forkop_resume) printf '%s\n' "Продолжаю прерванный переход с $LEGACY_FORKOP_BRAND с этапа" ;;
            legacy_forkop_resume_rollback) printf '%s\n' "Прошлый переход с $LEGACY_FORKOP_BRAND прервался до его удаления; отменяю его и начинаю заново. Этап:" ;;
            legacy_forkop_resume_without_state) printf '%s\n' "Записанное состояние $LEGACY_FORKOP_BRAND не найдено; Prokop останется отключенным" ;;
            legacy_forkop_failed) printf '%s\n' "Переход с $LEGACY_FORKOP_BRAND остановлен на этапе" ;;
            legacy_forkop_failed_prokop) printf '%s\n' "Prokop оставлен отключенным; его конфигурация:" ;;
            legacy_forkop_failed_next) printf '%s\n' "Чтобы завершить переход, запустите установщик еще раз:" ;;
            legacy_forkop_dns_restored) printf '%s\n' "Остановка $LEGACY_FORKOP_BRAND не вернула настройки dnsmasq; они восстановлены" ;;
            legacy_forkop_dns_converted) printf '%s\n' "Резервные настройки dnsmasq, оставленные $LEGACY_FORKOP_BRAND, переданы Prokop" ;;
            legacy_forkop_dns_leftover) printf '%s\n' "dnsmasq все еще пересылает запросы на 127.0.0.42; проверьте /etc/config/dhcp" ;;
            legacy_forkop_deactivate_failed) printf '%s\n' "Не удалось остановить $LEGACY_FORKOP_BRAND" ;;
            legacy_forkop_prerm_failed) printf '%s\n' "Не удалось подготовить удаление $LEGACY_FORKOP_BRAND без снятия его kill-switch и без удаления sing-box" ;;
            legacy_forkop_remove_failed) printf '%s\n' "Не удалось удалить пакет" ;;
            legacy_forkop_sing_box_kept) printf '%s\n' "sing-box, которым управлял $LEGACY_FORKOP_BRAND, будет передан Prokop" ;;
            legacy_forkop_sing_box_handover) printf '%s\n' "sing-box, которым управлял $LEGACY_FORKOP_BRAND, теперь управляется Prokop" ;;
            legacy_forkop_sing_box_lost) printf '%s\n' "sing-box, которым управлял $LEGACY_FORKOP_BRAND, пропал; устанавливаю его заново через Prokop" ;;
            legacy_forkop_killswitch_kept) printf '%s\n' "Kill-switch $LEGACY_FORKOP_BRAND продолжает блокировать защищенный трафик, пока Prokop не включит свой. Снять его вручную: prokop killswitch_disable" ;;
            legacy_forkop_service_started) printf '%s\n' "Prokop включен и запущен, как был $LEGACY_FORKOP_BRAND" ;;
            legacy_forkop_service_enabled) printf '%s\n' "Автозапуск Prokop включен, как был у $LEGACY_FORKOP_BRAND" ;;
            legacy_forkop_service_stopped) printf '%s\n' "Prokop не запущен, как и $LEGACY_FORKOP_BRAND; включите его в LuCI" ;;
            legacy_forkop_not_ready) printf '%s\n' "Prokop не запущен: конфигурация требует внимания" ;;
            legacy_forkop_done) printf '%s\n' "Переход с $LEGACY_FORKOP_BRAND на Prokop завершен" ;;
            *) printf '%s\n' "$key" ;;
        esac
        return 0
    fi

    case "$key" in
        yes) printf '%s\n' "Yes" ;;
        no) printf '%s\n' "No" ;;
        select) printf '%s\n' "Select a number" ;;
        invalid_choice) printf '%s\n' "Enter a number from the list." ;;
        language_prompt) printf '%s\n' "Select the installer language:" ;;
        language_ru) printf '%s\n' "Russian" ;;
        language_en) printf '%s\n' "English" ;;
        i18n_installed) printf '%s\n' "The Russian interface package is already installed and will be updated." ;;
        i18n_prompt) printf '%s\n' "Install the Russian interface language package?" ;;
        i18n_skip) printf '%s\n' "Continuing without the Russian interface language package." ;;
        luci_ru) printf '%s\n' "The Russian interface package will be installed automatically." ;;
        sing_box_prompt) printf '%s\n' "Which singbox build should be installed?" ;;
        sing_box_tiny) printf '%s\n' "singbox tiny (default)" ;;
        sing_box_stable) printf '%s\n' "singbox stable" ;;
        sing_box_extended) printf '%s\n' "singbox extended (if xhttp is needed)" ;;
        sing_box_skip_msg) printf '%s\n' "Skipping sing-box installation." ;;
        low_flash_space) printf '%s\n' "The Prokop installation plan needs more space, but preflight confirms that switching to sing-box tiny will free enough flash." ;;
        tiny_recovery_prompt) printf '%s\n' "Replace the installed sing-box package with sing-box tiny? This is a permanent change; advanced features, including xhttp, will become unavailable" ;;
        tiny_recovery_warning) printf '%s\n' "Installing the already downloaded sing-box tiny directly through the system package manager." ;;
        legacy_migration_prompt) printf '%s\n' "Migrate the legacy installation to Prokop? Its packages will be removed only after configuration backup and successful preflight checks" ;;
        legacy_backup_ready) printf '%s\n' "Legacy configuration backup created" ;;
        legacy_cleanup_start) printf '%s\n' "Removing legacy packages and starting configuration migration" ;;
        legacy_forkop_detected) printf '%s\n' "A $LEGACY_FORKOP_BRAND installation was found. Prokop is the renamed $LEGACY_FORKOP_BRAND: its settings and data are moved over, then $LEGACY_FORKOP_BRAND is removed." ;;
        legacy_forkop_prompt) printf '%s\n' "Switch from $LEGACY_FORKOP_BRAND to Prokop? $LEGACY_FORKOP_BRAND is removed only after Prokop is installed and the migrated configuration has passed its checks" ;;
        legacy_forkop_cancelled) printf '%s\n' "The switch was cancelled; $LEGACY_FORKOP_BRAND was not changed" ;;
        legacy_forkop_confirmed) printf '%s\n' "The switch from $LEGACY_FORKOP_BRAND was confirmed by --confirm-legacy-migration" ;;
        legacy_forkop_needs_confirmation) printf '%s\n' "Switching from $LEGACY_FORKOP_BRAND to Prokop needs an interactive terminal or --confirm-legacy-migration. Nothing was changed. Run:
    wget -qO- $RELEASE_BASE_URL/install.sh | sh -s -- --confirm-legacy-migration" ;;
        legacy_forkop_backups) printf '%s\n' "The $LEGACY_FORKOP_BRAND state and backups (readable by root only) are in" ;;
        legacy_forkop_stage_prepare) printf '%s\n' "Switching from $LEGACY_FORKOP_BRAND: downloading Prokop" ;;
        legacy_forkop_stage_install) printf '%s\n' "Switching from $LEGACY_FORKOP_BRAND: installing Prokop next to it and moving the settings" ;;
        legacy_forkop_stage_deactivate) printf '%s\n' "Switching from $LEGACY_FORKOP_BRAND: stopping and disabling it with its own commands" ;;
        legacy_forkop_stage_remove) printf '%s\n' "Switching from $LEGACY_FORKOP_BRAND: removing its packages" ;;
        legacy_forkop_stage_cleanup) printf '%s\n' "Switching from $LEGACY_FORKOP_BRAND: removing its remaining files" ;;
        legacy_forkop_stage_finish) printf '%s\n' "Switching from $LEGACY_FORKOP_BRAND: completing the Prokop installation" ;;
        legacy_forkop_config_copied) printf '%s\n' "The $LEGACY_FORKOP_BRAND configuration was moved to" ;;
        legacy_forkop_config_kept) printf '%s\n' "The edited Prokop configuration was kept as it is; the $LEGACY_FORKOP_BRAND configuration stays in the backup" ;;
        legacy_forkop_no_config) printf '%s\n' "$LEGACY_FORKOP_BRAND has no configuration; Prokop uses its defaults" ;;
        legacy_forkop_migration_failed) printf '%s\n' "The $LEGACY_FORKOP_BRAND configuration could not be migrated" ;;
        legacy_forkop_state_copied) printf '%s\n' "The $LEGACY_FORKOP_BRAND data was copied to" ;;
        legacy_forkop_validation_passed) printf '%s\n' "The migrated configuration passed the Prokop checks" ;;
        legacy_forkop_validation_failed) printf '%s\n' "The migrated configuration failed the Prokop checks" ;;
        legacy_forkop_rolled_back) printf '%s\n' "The changes were rolled back; $LEGACY_FORKOP_BRAND was left as it was" ;;
        legacy_forkop_rollback_incomplete) printf '%s\n' "The rollback was incomplete; check Prokop and $LEGACY_FORKOP_BRAND. The backups remain in" ;;
        legacy_forkop_resume) printf '%s\n' "Resuming the interrupted switch from $LEGACY_FORKOP_BRAND at stage" ;;
        legacy_forkop_resume_rollback) printf '%s\n' "The previous switch from $LEGACY_FORKOP_BRAND stopped before its removal; rolling it back and starting again. Stage:" ;;
        legacy_forkop_resume_without_state) printf '%s\n' "The recorded $LEGACY_FORKOP_BRAND state is missing; Prokop stays disabled" ;;
        legacy_forkop_failed) printf '%s\n' "The switch from $LEGACY_FORKOP_BRAND stopped at stage" ;;
        legacy_forkop_failed_prokop) printf '%s\n' "Prokop was left disabled; its configuration:" ;;
        legacy_forkop_failed_next) printf '%s\n' "Run the installer again to complete the switch:" ;;
        legacy_forkop_dns_restored) printf '%s\n' "The $LEGACY_FORKOP_BRAND stop did not restore dnsmasq; its settings were restored" ;;
        legacy_forkop_dns_converted) printf '%s\n' "The dnsmasq backups left by $LEGACY_FORKOP_BRAND were handed to Prokop" ;;
        legacy_forkop_dns_leftover) printf '%s\n' "dnsmasq still forwards to 127.0.0.42; check /etc/config/dhcp" ;;
        legacy_forkop_deactivate_failed) printf '%s\n' "$LEGACY_FORKOP_BRAND could not be stopped" ;;
        legacy_forkop_prerm_failed) printf '%s\n' "The $LEGACY_FORKOP_BRAND removal could not be prepared to keep its kill-switch and its sing-box" ;;
        legacy_forkop_remove_failed) printf '%s\n' "Failed to remove the package" ;;
        legacy_forkop_sing_box_kept) printf '%s\n' "The sing-box managed by $LEGACY_FORKOP_BRAND will be handed over to Prokop" ;;
        legacy_forkop_sing_box_handover) printf '%s\n' "The sing-box managed by $LEGACY_FORKOP_BRAND is now managed by Prokop" ;;
        legacy_forkop_sing_box_lost) printf '%s\n' "The sing-box managed by $LEGACY_FORKOP_BRAND is gone; reinstalling it through Prokop" ;;
        legacy_forkop_killswitch_kept) printf '%s\n' "The $LEGACY_FORKOP_BRAND kill-switch keeps blocking protected traffic until Prokop arms its own. To lift it by hand: prokop killswitch_disable" ;;
        legacy_forkop_service_started) printf '%s\n' "Prokop was enabled and started, as $LEGACY_FORKOP_BRAND was" ;;
        legacy_forkop_service_enabled) printf '%s\n' "The Prokop autostart was enabled, as the $LEGACY_FORKOP_BRAND one was" ;;
        legacy_forkop_service_stopped) printf '%s\n' "Prokop was not started, as $LEGACY_FORKOP_BRAND was not; enable it in LuCI" ;;
        legacy_forkop_not_ready) printf '%s\n' "Prokop was not started: its configuration needs attention" ;;
        legacy_forkop_done) printf '%s\n' "The switch from $LEGACY_FORKOP_BRAND to Prokop is complete" ;;
        *) printf '%s\n' "$key" ;;
    esac
}

detect_installer_language() {
    INSTALLER_LANG_DETECTED=0
    if [ "$INSTALLER_LANG_EXPLICIT" -eq 1 ]; then
        return 0
    fi

    luci_lang="$(get_luci_main_lang)"
    if [ "$INSTALL_MODE" = "clean" ]; then
        INSTALLER_LANG="ru"
    else
        INSTALLER_LANG="en"
        INSTALLER_LANG_DETECTED=1
    fi
    if pkg_is_installed "luci-i18n-prokop-ru" || [ "$LEGACY_FORKOP_I18N_INSTALLED" -eq 1 ]; then
        INSTALLER_LANG="ru"
        INSTALLER_LANG_DETECTED=1
        return 0
    fi

    case "$luci_lang" in
        ru|ru_*|ru-*)
            INSTALLER_LANG="ru"
            INSTALLER_LANG_DETECTED=1
            ;;
    esac
}

select_installer_language() {
    answer=""
    default_choice=1

    if [ "$INSTALLER_LANG_EXPLICIT" -eq 1 ] ||
        { [ "$INSTALL_MODE" != "clean" ] && [ "$INSTALLER_LANG_DETECTED" -eq 1 ]; }; then
        return 0
    fi

    if ! interactive_terminal_available; then
        msg "$(installer_text language_prompt) $default_choice ($(installer_text language_$INSTALLER_LANG), non-interactive; use --lang to override)"
        return 0
    fi

    while :; do
        printf '\n%s\n' "$(installer_text language_prompt)"
        printf '  1) %s\n' "$(installer_text language_ru)"
        printf '  2) %s\n' "$(installer_text language_en)"
        printf '%s [%s]: ' "$(installer_text select)" "$default_choice"
        read_installer_answer answer || return 1
        [ -n "$answer" ] || answer="$default_choice"

        case "$answer" in
            1)
                INSTALLER_LANG="ru"
                return 0
                ;;
            2)
                INSTALLER_LANG="en"
                return 0
                ;;
            *)
                warn "$(installer_text invalid_choice)"
                ;;
        esac
    done
}

numbered_yes_no_prompt() {
    prompt_text="$1"
    answer=""

    if ! interactive_terminal_available; then
        msg "$prompt_text: 1 ($(installer_text yes), non-interactive)"
        return 0
    fi

    while :; do
        printf '\n%s\n' "$prompt_text"
        printf '  1) %s\n' "$(installer_text yes)"
        printf '  2) %s\n' "$(installer_text no)"
        printf '%s [2]: ' "$(installer_text select)"
        read_installer_answer answer || return 1

        case "$answer" in
            1)
                return 0
                ;;
            2|"")
                return 1
                ;;
            *)
                warn "$(installer_text invalid_choice)"
                ;;
        esac
    done
}

get_luci_main_lang() {
    command_exists ucode || return 0
    ucode -e 'require("fs"); require("uci");' >/dev/null 2>&1 || return 0
    install_json_ucode uci-get luci.main.lang 2>/dev/null || true
}

fetch_github_latest_release_json() {
    repo="$1"
    response=""
    message=""
    url="https://api.github.com/repos/${repo}/releases/latest"

    response="$(http_get "$url" 2>/dev/null || true)"
    [ -n "$response" ] || fail "Failed to query GitHub latest release metadata for ${repo}"

    message="$(printf '%s' "$response" | install_json_ucode github-message 2>/dev/null)" ||
        fail "GitHub returned an invalid latest release response for ${repo}"
    case "$message" in
        *"API rate limit"*|*"rate limit exceeded"*)
            fail "GitHub API rate limit reached. Try again later."
            ;;
        "Not Found")
            fail "No published latest release found for ${repo}"
            ;;
    esac

    printf '%s' "$response"
}

# Sets PROKOP_RELEASE_JSON and PROKOP_RELEASE_SOURCE: the release channel
# first, the GitHub Releases of RELEASE_REPO when the channel is unavailable.
fetch_prokop_latest_release_json() {
    release_url="${RELEASE_BASE_URL%/}/updates/latest.json"
    response="$(http_get "$release_url" 2>/dev/null || true)"
    if [ -n "$response" ] &&
        [ -n "$(printf '%s' "$response" | install_json_ucode release-tag 2>/dev/null)" ]; then
        PROKOP_RELEASE_JSON="$response"
        PROKOP_RELEASE_SOURCE="${RELEASE_BASE_URL%/}"
        return 0
    fi

    warn "The release channel $release_url is unavailable; using the GitHub Releases of $RELEASE_REPO"
    PROKOP_RELEASE_JSON="$(fetch_github_latest_release_json "$RELEASE_REPO")" ||
        fail "Failed to resolve the latest Prokop release"
    PROKOP_RELEASE_SOURCE="GitHub Releases of $RELEASE_REPO"
}

release_asset_url() {
    case "$1" in
        http://*|https://*) printf '%s\n' "$1" ;;
        /*) printf '%s%s\n' "${RELEASE_BASE_URL%/}" "$1" ;;
        *) printf '%s/%s\n' "${RELEASE_BASE_URL%/}" "$1" ;;
    esac
}

resolve_prokop_release() {
    asset_ext="ipk"

    [ "$PKG_IS_APK" -eq 1 ] && asset_ext="apk"

    fetch_prokop_latest_release_json
    PROKOP_RELEASE_TAG="$(printf '%s' "$PROKOP_RELEASE_JSON" | install_json_ucode release-tag 2>/dev/null)"
    [ -n "$PROKOP_RELEASE_TAG" ] || fail "Failed to detect the Prokop release tag"
    msg "Prokop release $PROKOP_RELEASE_TAG from $PROKOP_RELEASE_SOURCE"

    PROKOP_BACKEND_URL="$(printf '%s' "$PROKOP_RELEASE_JSON" | install_json_ucode release-asset-url backend "$asset_ext" 2>/dev/null)"
    [ -n "$PROKOP_BACKEND_URL" ] || fail "The Prokop release does not contain a prokop .$asset_ext package"
    PROKOP_BACKEND_URL="$(release_asset_url "$PROKOP_BACKEND_URL")"
    PROKOP_BACKEND_SHA256="$(printf '%s' "$PROKOP_RELEASE_JSON" | install_json_ucode release-asset-sha256 backend "$asset_ext" 2>/dev/null)"

    PROKOP_APP_URL="$(printf '%s' "$PROKOP_RELEASE_JSON" | install_json_ucode release-asset-url app "$asset_ext" 2>/dev/null)"
    [ -n "$PROKOP_APP_URL" ] || fail "The Prokop release does not contain a luci-app-prokop .$asset_ext package"
    PROKOP_APP_URL="$(release_asset_url "$PROKOP_APP_URL")"
    PROKOP_APP_SHA256="$(printf '%s' "$PROKOP_RELEASE_JSON" | install_json_ucode release-asset-sha256 app "$asset_ext" 2>/dev/null)"

    PROKOP_BACKEND_NAME="$(basename "$PROKOP_BACKEND_URL")"
    PROKOP_APP_NAME="$(basename "$PROKOP_APP_URL")"
    PROKOP_PACKAGE_VERSION="$(printf '%s\n' "$PROKOP_BACKEND_NAME" | sed 's/^prokop_//;s/\.ipk$//;s/\.apk$//')"

    PROKOP_I18N_URL=""
    PROKOP_I18N_NAME=""

    if [ "$PROKOP_I18N_REQUESTED" -eq 1 ]; then
        PROKOP_I18N_URL="$(printf '%s' "$PROKOP_RELEASE_JSON" | install_json_ucode release-asset-url i18n "$asset_ext" 2>/dev/null)"
        [ -n "$PROKOP_I18N_URL" ] || fail "The Prokop release does not contain a luci-i18n-prokop-ru .$asset_ext package"
        PROKOP_I18N_URL="$(release_asset_url "$PROKOP_I18N_URL")"
        PROKOP_I18N_SHA256="$(printf '%s' "$PROKOP_RELEASE_JSON" | install_json_ucode release-asset-sha256 i18n "$asset_ext" 2>/dev/null)"
        PROKOP_I18N_NAME="$(basename "$PROKOP_I18N_URL")"
    fi
}

sing_box_is_present() {
    command_exists sing-box ||
        pkg_is_installed "sing-box" ||
        pkg_is_installed "sing-box-tiny" ||
        pkg_is_installed "sing-box-extended"
}

select_sing_box_installation() {
    answer=""
    default_choice=1

    if legacy_binary_managed_sing_box_present; then
        SING_BOX_INSTALL_VARIANT="extended-compressed"
        msg "The legacy binary-managed sing-box variant will be reinstalled for Prokop"
        return 0
    fi

    # The binary sing-box that the renamed installation manages is handed
    # over as it is; it is reinstalled only if it is lost on the way.
    if legacy_forkop_mode && [ "$LEGACY_FORKOP_MANAGED_SING_BOX" -eq 1 ]; then
        SING_BOX_INSTALL_VARIANT=""
        msg "$(installer_text legacy_forkop_sing_box_kept)"
        return 0
    fi

    if sing_box_is_present; then
        SING_BOX_INSTALL_VARIANT=""
        return 0
    fi

    if [ "$SING_BOX_INSTALL_VARIANT_EXPLICIT" -eq 1 ]; then
        msg "$(installer_text sing_box_prompt): $(installer_text sing_box_$SING_BOX_INSTALL_VARIANT)"
        return 0
    fi

    if ! interactive_terminal_available; then
        SING_BOX_INSTALL_VARIANT="tiny"
        msg "$(installer_text sing_box_prompt): $default_choice ($(installer_text sing_box_tiny), non-interactive)"
        return 0
    fi

    while :; do
        printf '\n%s\n' "$(installer_text sing_box_prompt)"
        printf '  1) %s\n' "$(installer_text sing_box_tiny)"
        printf '  2) %s\n' "$(installer_text sing_box_stable)"
        printf '  3) %s\n' "$(installer_text sing_box_extended)"
        printf '%s [%s]: ' "$(installer_text select)" "$default_choice"
        read_installer_answer answer || return 1
        [ -n "$answer" ] || answer="$default_choice"

        case "$answer" in
            1)
                SING_BOX_INSTALL_VARIANT="tiny"
                return 0
                ;;
            2)
                SING_BOX_INSTALL_VARIANT="stable"
                return 0
                ;;
            3)
                SING_BOX_INSTALL_VARIANT="extended"
                return 0
                ;;
            *)
                warn "$(installer_text invalid_choice)"
                ;;
        esac
    done
}

install_selected_sing_box() {
    action=""
    output_file="$TMP_DIR/sing-box-component-action.json"

    case "$SING_BOX_INSTALL_VARIANT" in
        "")
            msg "$(installer_text sing_box_skip_msg)"
            return 0
            ;;
        stable)
            action="install_stable"
            ;;
        tiny)
            action="install_tiny"
            ;;
        extended)
            action="install_extended"
            ;;
        extended-compressed)
            action="install_extended_compressed"
            ;;
        *)
            fail "Unknown sing-box installation variant: $SING_BOX_INSTALL_VARIANT"
            ;;
    esac

    [ -x /usr/bin/prokop ] || fail "prokop backend must be installed before sing-box component action"
    msg "Installing selected sing-box variant through Prokop ucode backend"
    if ! /usr/bin/prokop component_action sing_box "$action" >"$output_file" 2>&1; then
        cat "$output_file" >&2 2>/dev/null || true
        fail "Failed to install selected sing-box variant"
    fi
}

cleanup_legacy_installation() {
    [ "$LEGACY_CLEANUP_DONE" -eq 0 ] || return 0

    state_file="$TMP_DIR/install-state.env"

    install_json_ucode installer-cleanup-legacy >"$state_file" ||
        fail "Failed to prepare the system before Prokop package installation"

    # shellcheck disable=SC1090
    . "$state_file"
    LEGACY_CLEANUP_DONE=1
}

detect_legacy_installation() {
    PROKOP_LEGACY_DETECTED=0
    LEGACY_CONFIG_BACKUP=""
    LEGACY_CONFIG_PATH=""
    # The renamed installation goes first; a later run migrates this one.
    [ "$LEGACY_FORKOP_DETECTED" -eq 0 ] || return 0

    if ! pkg_is_installed "$LEGACY_BACKEND_PACKAGE"; then
        legacy_config_present=0
        for legacy_config_path in \
            "/etc/config/$LEGACY_BACKEND_PACKAGE" \
            "/etc/config/$LEGACY_CONFIG_PACKAGE_ALT"; do
            if [ -r "$legacy_config_path" ]; then
                legacy_config_present=1
                break
            fi
        done
        [ "$legacy_config_present" -eq 1 ] || return 0
    fi

    PROKOP_LEGACY_DETECTED=1
    for legacy_config_path in \
        "/etc/config/$LEGACY_BACKEND_PACKAGE" \
        "/etc/config/$LEGACY_CONFIG_PACKAGE_ALT"; do
        if [ -r "$legacy_config_path" ]; then
            LEGACY_CONFIG_PATH="$legacy_config_path"
            break
        fi
    done

    msg "Legacy installation detected; its packages will be removed and its configuration will be upgraded"
}

detect_install_mode() {
    if [ -n "$LEGACY_FORKOP_RESUME_STAGE" ]; then
        INSTALL_MODE="legacy_forkop_resume"
    elif [ "$LEGACY_FORKOP_DETECTED" -eq 1 ]; then
        INSTALL_MODE="legacy_forkop"
    elif [ "$PROKOP_LEGACY_DETECTED" -eq 1 ]; then
        INSTALL_MODE="legacy"
    elif pkg_is_installed "prokop"; then
        INSTALL_MODE="update"
    else
        INSTALL_MODE="clean"
    fi
    msg "Installation mode: $INSTALL_MODE"
}

prepare_legacy_config_backup() {
    [ -n "$LEGACY_CONFIG_PATH" ] || return 0

    LEGACY_CONFIG_BACKUP="/etc/.prokop-legacy-config-backup.$$"
    cp "$LEGACY_CONFIG_PATH" "$LEGACY_CONFIG_BACKUP" ||
        fail "Failed to back up the legacy configuration"
    chmod 0600 "$LEGACY_CONFIG_BACKUP" ||
        fail "Failed to secure the legacy configuration backup"
    msg "$(installer_text legacy_backup_ready): $LEGACY_CONFIG_BACKUP"
}

rollback_legacy_config_on_failure() {
    [ -n "$LEGACY_CONFIG_BACKUP" ] && [ -r "$LEGACY_CONFIG_BACKUP" ] || return 0
    if [ "$LEGACY_CLEANUP_STARTED" -eq 0 ]; then
        if [ "$SING_BOX_CHANGE_STARTED" -eq 1 ]; then
            warn "The legacy configuration backup remains at $LEGACY_CONFIG_BACKUP after the sing-box package change"
            return 0
        fi
        rm -f "$LEGACY_CONFIG_BACKUP"
        LEGACY_CONFIG_BACKUP=""
        return 0
    fi
    [ -n "$LEGACY_CONFIG_PATH" ] || return 0

    cp "$LEGACY_CONFIG_BACKUP" "$LEGACY_CONFIG_PATH" 2>/dev/null || return 0
    chmod 0600 "$LEGACY_CONFIG_PATH" 2>/dev/null || true
    warn "Legacy configuration was restored after the failed migration. Its backup remains at $LEGACY_CONFIG_BACKUP"
}

confirm_legacy_migration() {
    [ "$PROKOP_LEGACY_DETECTED" -eq 1 ] || return 0

    if interactive_terminal_available; then
        numbered_yes_no_prompt "$(installer_text legacy_migration_prompt)" ||
            fail "Legacy migration was cancelled before changing installed packages"
    elif [ "$CONFIRM_LEGACY_MIGRATION" -eq 1 ]; then
        msg "Legacy migration was explicitly authorized by --confirm-legacy-migration"
    else
        fail "Legacy migration requires an interactive terminal or --confirm-legacy-migration"
    fi
    prepare_legacy_config_backup
}

begin_legacy_migration() {
    [ "$PROKOP_LEGACY_DETECTED" -eq 1 ] || return 0

    msg "$(installer_text legacy_cleanup_start)"
    LEGACY_CLEANUP_STARTED=1
    cleanup_legacy_installation
}

remove_legacy_backup() {
    [ -n "$LEGACY_CONFIG_BACKUP" ] || return 0
    rm -f "$LEGACY_CONFIG_BACKUP"
    LEGACY_CONFIG_BACKUP=""
}

# Migration from the installation Prokop was renamed from (its names are in
# the legacy block at the top). Prokop is installed next to it first. Only
# after the migrated configuration passed the Prokop checks (the point of no
# return) is the old installation deactivated with its own code and removed;
# a failure before that point rolls everything back. Each stage is recorded
# in a resume marker: the next run completes a migration that was interrupted
# after the point of no return and rolls back one interrupted before it.

LEGACY_FORKOP_MIGRATION_COMPLETE=0

legacy_forkop_mode() {
    case "$INSTALL_MODE" in
        legacy_forkop|legacy_forkop_resume) return 0 ;;
    esac
    return 1
}

legacy_forkop_ucode() {
    PROKOP_INSTALLER_LEGACY_FORKOP_BRAND="$LEGACY_FORKOP_BRAND" \
    PROKOP_INSTALLER_LEGACY_FORKOP_CONFIG_NAME="$LEGACY_FORKOP_CONFIG_NAME" \
    PROKOP_INSTALLER_LEGACY_FORKOP_INIT="$LEGACY_FORKOP_INIT" \
    PROKOP_INSTALLER_LEGACY_FORKOP_KILLSWITCH_INIT="$LEGACY_FORKOP_KILLSWITCH_INIT" \
    PROKOP_INSTALLER_LEGACY_FORKOP_TORRSERVER_INIT="$LEGACY_FORKOP_TORRSERVER_INIT" \
    PROKOP_INSTALLER_LEGACY_FORKOP_SERVICES="$LEGACY_FORKOP_SERVICES" \
    PROKOP_INSTALLER_LEGACY_FORKOP_STOP_SOURCE="$LEGACY_FORKOP_STOP_SOURCE" \
    PROKOP_INSTALLER_LEGACY_FORKOP_BIN="$LEGACY_FORKOP_BIN" \
    PROKOP_INSTALLER_LEGACY_FORKOP_LIB="$LEGACY_FORKOP_LIB" \
    PROKOP_INSTALLER_LEGACY_FORKOP_NFT_MAIN_TABLE="$LEGACY_FORKOP_NFT_MAIN_TABLE" \
    PROKOP_INSTALLER_LEGACY_FORKOP_NFT_TABLES="$LEGACY_FORKOP_NFT_TABLES" \
    PROKOP_INSTALLER_LEGACY_FORKOP_KILLSWITCH_TABLE="$LEGACY_FORKOP_KILLSWITCH_TABLE" \
    PROKOP_INSTALLER_LEGACY_FORKOP_KILLSWITCH_DNS_CHAIN="$LEGACY_FORKOP_KILLSWITCH_DNS_CHAIN" \
    PROKOP_INSTALLER_LEGACY_FORKOP_DHCP_SECTION="$LEGACY_FORKOP_DHCP_SECTION" \
    PROKOP_INSTALLER_LEGACY_FORKOP_DHCP_OPTION_PREFIX="$LEGACY_FORKOP_DHCP_OPTION_PREFIX" \
    PROKOP_INSTALLER_LEGACY_FORKOP_ACL_GROUPS="$LEGACY_FORKOP_ACL_GROUPS" \
    PROKOP_INSTALLER_PROKOP_ACL_GROUPS="$PROKOP_TARGET_ACL_GROUPS" \
    PROKOP_INSTALLER_LEGACY_FORKOP_WAS_ENABLED="$LEGACY_FORKOP_WAS_ENABLED" \
    PROKOP_INSTALLER_LEGACY_FORKOP_WAS_RUNNING="$LEGACY_FORKOP_WAS_RUNNING" \
        install_json_ucode "$@"
}

legacy_forkop_state_get() {
    [ -r "$LEGACY_FORKOP_MIGRATION_DIR/state" ] || return 0
    sed -n "s/^$1=//p" "$LEGACY_FORKOP_MIGRATION_DIR/state" | head -n 1
}

legacy_forkop_state_flag() {
    if [ "$(legacy_forkop_state_get "$1")" = 1 ]; then
        printf '1\n'
    else
        printf '0\n'
    fi
}

legacy_forkop_stage_rank() {
    case "$1" in
        prepare) printf '1\n' ;;
        install) printf '2\n' ;;
        deactivate) printf '3\n' ;;
        remove) printf '4\n' ;;
        cleanup) printf '5\n' ;;
        finish) printf '6\n' ;;
        *) printf '0\n' ;;
    esac
}

legacy_forkop_set_stage() {
    if ! mkdir -p "${LEGACY_FORKOP_MIGRATION_MARKER%/*}" ||
        ! printf '%s\n' "$1" >"$LEGACY_FORKOP_MIGRATION_MARKER.new" ||
        ! mv "$LEGACY_FORKOP_MIGRATION_MARKER.new" "$LEGACY_FORKOP_MIGRATION_MARKER"; then
        fail "Failed to record the migration stage in $LEGACY_FORKOP_MIGRATION_MARKER"
    fi
    LEGACY_FORKOP_STAGE="$1"
    msg "$(installer_text "legacy_forkop_stage_$1")"
}

legacy_forkop_nft_table_present() {
    command_exists nft && nft list table inet "$1" >/dev/null 2>&1
}

legacy_forkop_managed_sing_box_present() {
    [ -r "$SING_BOX_INIT_SCRIPT" ] && grep -Fq "$LEGACY_FORKOP_SING_BOX_MARKER" "$SING_BOX_INIT_SCRIPT"
}

# Any of its packages, its init script or executable, or its configuration
# while Prokop is not installed; or the resume marker of an interrupted
# migration. Nothing is changed here.
legacy_forkop_detect_installation() {
    LEGACY_FORKOP_DETECTED=0
    LEGACY_FORKOP_RESUME_STAGE=""
    LEGACY_FORKOP_I18N_INSTALLED=0
    LEGACY_FORKOP_MANAGED_SING_BOX=0

    if [ -f "$LEGACY_FORKOP_MIGRATION_MARKER" ]; then
        LEGACY_FORKOP_RESUME_STAGE="$(sed -n '1p' "$LEGACY_FORKOP_MIGRATION_MARKER" 2>/dev/null)"
        [ -n "$LEGACY_FORKOP_RESUME_STAGE" ] || LEGACY_FORKOP_RESUME_STAGE="unknown"
        LEGACY_FORKOP_DETECTED=1
        LEGACY_FORKOP_I18N_INSTALLED="$(legacy_forkop_state_flag i18n_installed)"
        LEGACY_FORKOP_MANAGED_SING_BOX="$(legacy_forkop_state_flag managed_sing_box)"
        if pkg_is_installed "$LEGACY_FORKOP_PACKAGE_I18N"; then
            LEGACY_FORKOP_I18N_INSTALLED=1
        fi
        msg "An interrupted switch from $LEGACY_FORKOP_BRAND to Prokop was found (stage $LEGACY_FORKOP_RESUME_STAGE)"
        return 0
    fi

    for legacy_forkop_package in "$LEGACY_FORKOP_PACKAGE_BACKEND" "$LEGACY_FORKOP_PACKAGE_APP" \
        "$LEGACY_FORKOP_PACKAGE_I18N"; do
        if pkg_is_installed "$legacy_forkop_package"; then
            LEGACY_FORKOP_DETECTED=1
        fi
    done
    for legacy_forkop_path in "$LEGACY_FORKOP_INIT" "$LEGACY_FORKOP_BIN"; do
        if [ -e "$legacy_forkop_path" ]; then
            LEGACY_FORKOP_DETECTED=1
        fi
    done
    if [ "$LEGACY_FORKOP_DETECTED" -eq 0 ]; then
        [ -e "$LEGACY_FORKOP_CONFIG" ] || return 0
        # Only its configuration is left. Next to an installed Prokop this is
        # a Prokop update: the dnsmasq forwarding to 127.0.0.42 and the
        # service state are Prokop's own, not the old installation's.
        if pkg_is_installed prokop; then
            warn "$LEGACY_FORKOP_CONFIG is left over from $LEGACY_FORKOP_BRAND, which is not installed; Prokop is installed, so it was neither imported nor removed"
            return 0
        fi
        LEGACY_FORKOP_DETECTED=1
    fi

    if pkg_is_installed "$LEGACY_FORKOP_PACKAGE_I18N"; then
        LEGACY_FORKOP_I18N_INSTALLED=1
    fi
    if legacy_forkop_managed_sing_box_present; then
        LEGACY_FORKOP_MANAGED_SING_BOX=1
    fi
    msg "$LEGACY_FORKOP_BRAND installation detected; it will be migrated to Prokop"
}

legacy_forkop_preflight() {
    command_exists ucode || fail "ucode is required to switch from $LEGACY_FORKOP_BRAND"
    if [ -e "$LEGACY_FORKOP_CONFIG" ] && [ ! -r "$LEGACY_FORKOP_CONFIG" ]; then
        fail "$LEGACY_FORKOP_CONFIG cannot be read; nothing was changed"
    fi

    # Its state is copied next to it until it is removed.
    LEGACY_FORKOP_COPY_KB="$(du -sk "$LEGACY_FORKOP_STATE_DIR" "$LEGACY_FORKOP_BACKUP_DIR" 2>/dev/null |
        awk '$1 ~ /^[0-9]+$/ { total += $1 } END { print total + 0 }')"
    case "$LEGACY_FORKOP_COPY_KB" in
        ''|*[!0-9]*) LEGACY_FORKOP_COPY_KB=0 ;;
    esac

    # Backups of an earlier run that left no marker: a failed rollback says
    # where they are, so they are kept aside instead of overwritten.
    if [ -e "$LEGACY_FORKOP_MIGRATION_DIR" ]; then
        warn "Keeping the files of an earlier unfinished switch in $LEGACY_FORKOP_MIGRATION_DIR.previous"
        rm -rf "$LEGACY_FORKOP_MIGRATION_DIR.previous"
        mv "$LEGACY_FORKOP_MIGRATION_DIR" "$LEGACY_FORKOP_MIGRATION_DIR.previous" ||
            fail "Failed to move $LEGACY_FORKOP_MIGRATION_DIR aside; nothing was changed"
    fi
}

legacy_forkop_backup_file() {
    [ -f "$1" ] || return 0
    if ! cp -p "$1" "$LEGACY_FORKOP_MIGRATION_DIR/$2" ||
        ! chmod 0600 "$LEGACY_FORKOP_MIGRATION_DIR/$2"; then
        fail "Failed to back up $1"
    fi
}

legacy_forkop_record_state() {
    legacy_forkop_service_state="$TMP_DIR/legacy-forkop-service.env"
    legacy_forkop_ucode installer-legacy-forkop-state >"$legacy_forkop_service_state" ||
        fail "Unable to determine the state of the $LEGACY_FORKOP_BRAND service; nothing was changed"
    LEGACY_FORKOP_WAS_ENABLED="$(sed -n 's/^LEGACY_FORKOP_WAS_ENABLED=\([01]\)$/\1/p' "$legacy_forkop_service_state")"
    LEGACY_FORKOP_WAS_RUNNING="$(sed -n 's/^LEGACY_FORKOP_WAS_RUNNING=\([01]\)$/\1/p' "$legacy_forkop_service_state")"
    if [ -z "$LEGACY_FORKOP_WAS_ENABLED" ] || [ -z "$LEGACY_FORKOP_WAS_RUNNING" ]; then
        fail "Unable to determine the state of the $LEGACY_FORKOP_BRAND service; nothing was changed"
    fi

    legacy_forkop_prokop_installed=0
    if pkg_is_installed prokop; then
        legacy_forkop_prokop_installed=1
    fi
    # The migrated configuration replaces only a packaged default, never one
    # that was edited.
    legacy_forkop_prokop_config=absent
    if [ -e "$PROKOP_TARGET_CONFIG" ]; then
        legacy_forkop_prokop_config=edited
        if [ -r "$PROKOP_TARGET_DEFAULT_CONFIG" ] && cmp -s "$PROKOP_TARGET_CONFIG" "$PROKOP_TARGET_DEFAULT_CONFIG"; then
            legacy_forkop_prokop_config=pristine
        fi
    fi
    legacy_forkop_state_dir_existed=0
    if [ -e "$PROKOP_TARGET_STATE_DIR" ]; then
        legacy_forkop_state_dir_existed=1
    fi
    legacy_forkop_backups_dir_existed=0
    if [ -e "$PROKOP_TARGET_BACKUPS_DIR" ]; then
        legacy_forkop_backups_dir_existed=1
    fi

    LEGACY_FORKOP_ACTIVE=1
    if ! (umask 077 && mkdir -p "$LEGACY_FORKOP_MIGRATION_DIR") ||
        ! chmod 0700 "$LEGACY_FORKOP_MIGRATION_DIR"; then
        fail "Failed to create $LEGACY_FORKOP_MIGRATION_DIR"
    fi
    if ! {
        printf 'was_enabled=%s\n' "$LEGACY_FORKOP_WAS_ENABLED"
        printf 'was_running=%s\n' "$LEGACY_FORKOP_WAS_RUNNING"
        printf 'i18n_installed=%s\n' "$LEGACY_FORKOP_I18N_INSTALLED"
        printf 'managed_sing_box=%s\n' "$LEGACY_FORKOP_MANAGED_SING_BOX"
        printf 'prokop_installed=%s\n' "$legacy_forkop_prokop_installed"
        printf 'prokop_config=%s\n' "$legacy_forkop_prokop_config"
        printf 'prokop_state_dir_existed=%s\n' "$legacy_forkop_state_dir_existed"
        printf 'prokop_backups_dir_existed=%s\n' "$legacy_forkop_backups_dir_existed"
    } >"$LEGACY_FORKOP_MIGRATION_DIR/state.new" ||
        ! chmod 0600 "$LEGACY_FORKOP_MIGRATION_DIR/state.new" ||
        ! mv "$LEGACY_FORKOP_MIGRATION_DIR/state.new" "$LEGACY_FORKOP_MIGRATION_DIR/state"; then
        fail "Failed to record the $LEGACY_FORKOP_BRAND state in $LEGACY_FORKOP_MIGRATION_DIR"
    fi

    legacy_forkop_backup_file "$LEGACY_FORKOP_CONFIG" legacy.config
    legacy_forkop_backup_file "$PROKOP_TARGET_CONFIG" prokop.config
    legacy_forkop_backup_file "$SYSTEM_DHCP_CONFIG" dhcp.config
    legacy_forkop_backup_file "$SYSTEM_RPCD_CONFIG" rpcd.config
    legacy_forkop_backup_file "$SYSTEM_CRONTAB" crontab
    legacy_forkop_backup_file "$SYSTEM_RT_TABLES" rt_tables
    legacy_forkop_backup_file "$SING_BOX_INIT_SCRIPT" sing-box.init
    legacy_forkop_backup_file "$LEGACY_FORKOP_KILLSWITCH_KEEP" killswitch.keep
    msg "$(installer_text legacy_forkop_backups) $LEGACY_FORKOP_MIGRATION_DIR"
}

legacy_forkop_confirm() {
    if interactive_terminal_available; then
        numbered_yes_no_prompt "$(installer_text legacy_forkop_prompt)" ||
            fail "$(installer_text legacy_forkop_cancelled)"
    elif [ "$CONFIRM_LEGACY_MIGRATION" -eq 1 ]; then
        msg "$(installer_text legacy_forkop_confirmed)"
    else
        fail "$(installer_text legacy_forkop_needs_confirmation)"
    fi
}

legacy_forkop_migrate_configuration() {
    PROKOP_CONFIG_NAME="prokop" PROKOP_LIB="$PROKOP_TARGET_LIB" \
        ucode -L "$PROKOP_TARGET_LIB" "$PROKOP_TARGET_LIB/config/migration.uc" migrate
}

legacy_forkop_install_configuration() {
    case "$(legacy_forkop_state_get prokop_config)" in
        absent|pristine)
            ;;
        *)
            LEGACY_FORKOP_KEEP_BACKUPS=1
            warn "$(installer_text legacy_forkop_config_kept): $LEGACY_FORKOP_MIGRATION_DIR/legacy.config"
            return 0
            ;;
    esac
    if [ ! -r "$LEGACY_FORKOP_CONFIG" ]; then
        warn "$(installer_text legacy_forkop_no_config)"
        return 0
    fi

    rm -f "$PROKOP_TARGET_CONFIG.migrating"
    if ! cp -p "$LEGACY_FORKOP_CONFIG" "$PROKOP_TARGET_CONFIG.migrating" ||
        ! mv "$PROKOP_TARGET_CONFIG.migrating" "$PROKOP_TARGET_CONFIG"; then
        rm -f "$PROKOP_TARGET_CONFIG.migrating"
        fail "$(installer_text legacy_forkop_migration_failed)"
    fi
    legacy_forkop_migrate_configuration ||
        fail "$(installer_text legacy_forkop_migration_failed)"
    msg "$(installer_text legacy_forkop_config_copied) $PROKOP_TARGET_CONFIG"
}

# Copies what the target lacks, recursively; nothing in the target is
# replaced. Every created path is listed for the rollback. $3: names skipped
# at this level.
legacy_forkop_copy_missing() {
    copy_source="$1"
    copy_target="$2"
    copy_skip="$3"
    [ -d "$copy_source" ] || return 0
    if [ ! -d "$copy_target" ]; then
        printf '%s\n' "$copy_target" >>"$LEGACY_FORKOP_MIGRATION_DIR/copied" || return 1
        mkdir -p "$copy_target" || return 1
    fi

    for copy_entry in "$copy_source"/* "$copy_source"/.[!.]* "$copy_source"/..?*; do
        [ -e "$copy_entry" ] || [ -L "$copy_entry" ] || continue
        copy_name="${copy_entry##*/}"
        case " $copy_skip " in
            *" $copy_name "*) continue ;;
        esac
        copy_destination="$copy_target/$copy_name"
        if [ -e "$copy_destination" ] || [ -L "$copy_destination" ]; then
            if [ -d "$copy_entry" ] && [ ! -L "$copy_entry" ] &&
                [ -d "$copy_destination" ] && [ ! -L "$copy_destination" ]; then
                (legacy_forkop_copy_missing "$copy_entry" "$copy_destination" "") || return 1
            fi
            continue
        fi
        copy_temporary="$copy_target/.$copy_name.prokop-copy"
        printf '%s\n' "$copy_destination" >>"$LEGACY_FORKOP_MIGRATION_DIR/copied" || return 1
        rm -rf "$copy_temporary"
        if ! cp -a "$copy_entry" "$copy_temporary" || ! mv "$copy_temporary" "$copy_destination"; then
            rm -rf "$copy_temporary"
            return 1
        fi
    done
    return 0
}

legacy_forkop_copy_state() {
    legacy_forkop_copy_missing "$LEGACY_FORKOP_STATE_DIR" "$PROKOP_TARGET_STATE_DIR" "$LEGACY_FORKOP_STATE_SKIP" ||
        fail "Failed to copy $LEGACY_FORKOP_STATE_DIR to $PROKOP_TARGET_STATE_DIR"
    legacy_forkop_copy_missing "$LEGACY_FORKOP_BACKUP_DIR" "$PROKOP_TARGET_BACKUPS_DIR" "" ||
        fail "Failed to copy $LEGACY_FORKOP_BACKUP_DIR to $PROKOP_TARGET_BACKUPS_DIR"
    msg "$(installer_text legacy_forkop_state_copied) $PROKOP_TARGET_STATE_DIR $PROKOP_TARGET_BACKUPS_DIR"
}

# The requirements check needs sing-box; when this run installs it only at
# the end, the configuration itself is still checked.
legacy_forkop_run_validator() {
    if [ -z "$SING_BOX_INSTALL_VARIANT" ]; then
        ucode -L "$PROKOP_TARGET_LIB" "$PROKOP_TARGET_LIB/config/validator.uc" check-requirements >"$1" 2>&1 ||
            return 1
    else
        : >"$1"
    fi
    ucode -L "$PROKOP_TARGET_LIB" "$PROKOP_TARGET_LIB/config/validator.uc" validate-runtime >>"$1" 2>&1
}

legacy_forkop_validate_configuration() {
    legacy_forkop_validation_log="$TMP_DIR/legacy-forkop-validation.log"
    if legacy_forkop_run_validator "$legacy_forkop_validation_log"; then
        msg "$(installer_text legacy_forkop_validation_passed)"
        return 0
    fi
    legacy_forkop_validation_reason="$(awk 'NF { line = $0 } END { print line }' "$legacy_forkop_validation_log" 2>/dev/null)"
    fail "$(installer_text legacy_forkop_validation_failed): ${legacy_forkop_validation_reason:-no details}"
}

legacy_forkop_report_dns() {
    if grep -Fxq 'LEGACY_FORKOP_DNS_RESTORED=1' "$1"; then
        warn "$(installer_text legacy_forkop_dns_restored)"
    fi
    if grep -Fxq 'LEGACY_FORKOP_DNS_CONVERTED=1' "$1"; then
        msg "$(installer_text legacy_forkop_dns_converted)"
    fi
    if grep -Fxq 'LEGACY_FORKOP_DNS_LEFTOVER=1' "$1"; then
        warn "$(installer_text legacy_forkop_dns_leftover)"
    fi
}

# Its own init.d stop and disable (with the stop source its prerm used), the
# kill-switch and TorrServer services first; then what that left behind.
legacy_forkop_deactivate() {
    legacy_forkop_deactivation="$TMP_DIR/legacy-forkop-deactivate.env"
    legacy_forkop_ucode installer-legacy-forkop-deactivate >"$legacy_forkop_deactivation" ||
        fail "$(installer_text legacy_forkop_deactivate_failed)"
    legacy_forkop_report_dns "$legacy_forkop_deactivation"
}

# Its package prerm (service/package.uc prerm_cleanup) lifts the kill-switch
# when killswitch/runtime.uc exists and deletes a sing-box whose init script
# carries its marker. Both are taken away from it before the removal: the
# kill-switch service was stopped already, and the sing-box now belongs to
# Prokop.
legacy_forkop_neutralise_package_scripts() {
    if legacy_forkop_managed_sing_box_present; then
        LEGACY_FORKOP_MANAGED_SING_BOX=1
        legacy_forkop_sing_box_init_new="$SING_BOX_INIT_SCRIPT.prokop-new"
        if ! sed "s/$LEGACY_FORKOP_SING_BOX_MARKER/$PROKOP_TARGET_SING_BOX_MARKER/g" \
                "$SING_BOX_INIT_SCRIPT" >"$legacy_forkop_sing_box_init_new" ||
            ! chmod 0755 "$legacy_forkop_sing_box_init_new" ||
            ! mv "$legacy_forkop_sing_box_init_new" "$SING_BOX_INIT_SCRIPT"; then
            rm -f "$legacy_forkop_sing_box_init_new"
            fail "$(installer_text legacy_forkop_prerm_failed)"
        fi
        if legacy_forkop_managed_sing_box_present; then
            fail "$(installer_text legacy_forkop_prerm_failed)"
        fi
        msg "$(installer_text legacy_forkop_sing_box_handover)"
    fi

    if [ -e "$LEGACY_FORKOP_KILLSWITCH_RUNTIME" ] || [ -L "$LEGACY_FORKOP_KILLSWITCH_RUNTIME" ]; then
        rm -f "$LEGACY_FORKOP_KILLSWITCH_RUNTIME"
        if [ -e "$LEGACY_FORKOP_KILLSWITCH_RUNTIME" ] || [ -L "$LEGACY_FORKOP_KILLSWITCH_RUNTIME" ]; then
            fail "$(installer_text legacy_forkop_prerm_failed)"
        fi
    fi
}

legacy_forkop_remove_package() {
    pkg_is_installed "$1" || return 0
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del "$1" </dev/null
    else
        opkg remove --force-depends "$1" </dev/null
    fi
    ! pkg_is_installed "$1"
}

legacy_forkop_remove_packages() {
    for legacy_forkop_package in "$LEGACY_FORKOP_PACKAGE_I18N" "$LEGACY_FORKOP_PACKAGE_APP" \
        "$LEGACY_FORKOP_PACKAGE_BACKEND"; do
        pkg_is_installed "$legacy_forkop_package" || continue
        msg "Removing $legacy_forkop_package"
        legacy_forkop_remove_package "$legacy_forkop_package" ||
            fail "$(installer_text legacy_forkop_remove_failed) $legacy_forkop_package"
    done

    # The package owned the sysupgrade keep list of the kill-switch policy
    # that stays: keep it until Prokop's kill-switch replaces that policy.
    if [ -e "$LEGACY_FORKOP_KILLSWITCH_INCLUDE" ] && [ ! -e "$LEGACY_FORKOP_KILLSWITCH_KEEP" ] &&
        [ -f "$LEGACY_FORKOP_MIGRATION_DIR/killswitch.keep" ]; then
        if ! mkdir -p "${LEGACY_FORKOP_KILLSWITCH_KEEP%/*}" ||
            ! cp "$LEGACY_FORKOP_MIGRATION_DIR/killswitch.keep" "$LEGACY_FORKOP_KILLSWITCH_KEEP" ||
            ! chmod 0644 "$LEGACY_FORKOP_KILLSWITCH_KEEP"; then
            warn "Failed to restore $LEGACY_FORKOP_KILLSWITCH_KEEP; a sysupgrade before Prokop arms its kill-switch drops the old one"
        fi
    fi
}

legacy_forkop_delete_nft_tables() {
    for legacy_forkop_table in $LEGACY_FORKOP_NFT_TABLES; do
        [ "$legacy_forkop_table" != "$LEGACY_FORKOP_KILLSWITCH_TABLE" ] || continue
        legacy_forkop_nft_table_present "$legacy_forkop_table" || continue
        nft delete table inet "$legacy_forkop_table" >/dev/null 2>&1 ||
            warn "Failed to delete the nftables table $legacy_forkop_table"
    done
}

legacy_forkop_delete_services() {
    command_exists ubus || return 0
    for legacy_forkop_service in $LEGACY_FORKOP_SERVICES; do
        ubus call service delete "{\"name\":\"$legacy_forkop_service\"}" >/dev/null 2>&1 || true
    done
}

# An rc.d link of one of its services: S or K, the START/STOP number and the
# service name, exactly.
legacy_forkop_rc_link() {
    legacy_forkop_rc_name="${1##*/}"
    legacy_forkop_rc_rest="${legacy_forkop_rc_name#[SK]}"
    [ "$legacy_forkop_rc_rest" != "$legacy_forkop_rc_name" ] || return 1
    legacy_forkop_rc_digits="${legacy_forkop_rc_rest%%[!0-9]*}"
    [ -n "$legacy_forkop_rc_digits" ] || return 1
    case " $LEGACY_FORKOP_SERVICES " in
        *" ${legacy_forkop_rc_rest#"$legacy_forkop_rc_digits"} "*) return 0 ;;
    esac
    return 1
}

# Explicit paths only, never a scan for the old name.
legacy_forkop_remove_files() {
    for legacy_forkop_path in "$SYSTEM_RC_DIR"/[SK]*; do
        legacy_forkop_rc_link "$legacy_forkop_path" || continue
        rm -f "$legacy_forkop_path" || warn "Failed to remove $legacy_forkop_path"
    done
    # shellcheck disable=SC2086 # the glob variables are expanded on purpose
    for legacy_forkop_path in $LEGACY_FORKOP_INIT_GLOB \
        "$LEGACY_FORKOP_BIN" "$LEGACY_FORKOP_LIBEXEC_RO" "$LEGACY_FORKOP_LIB" "$LEGACY_FORKOP_SHARE_DIR" \
        "$LEGACY_FORKOP_LUCI_VIEW_DIR" "$LEGACY_FORKOP_LUCI_MENU" "$LEGACY_FORKOP_LUCI_ACL" \
        "$LEGACY_FORKOP_LUCI_UCI_DEFAULTS" "$LEGACY_FORKOP_I18N_UCI_DEFAULTS" $LEGACY_FORKOP_LUCI_I18N_GLOB \
        $LEGACY_FORKOP_RUN_GLOB $LEGACY_FORKOP_TMP_GLOB; do
        [ -e "$legacy_forkop_path" ] || [ -L "$legacy_forkop_path" ] || continue
        rm -rf "$legacy_forkop_path" || warn "Failed to remove $legacy_forkop_path"
    done
}

legacy_forkop_remove_cron_jobs() {
    [ -f "$SYSTEM_CRONTAB" ] || return 0
    grep -Fq "$LEGACY_FORKOP_CRON_MARKER" "$SYSTEM_CRONTAB" || return 0

    legacy_forkop_crontab="$TMP_DIR/legacy-forkop-crontab"
    if ! awk -v marker="$LEGACY_FORKOP_CRON_MARKER" 'index($0, marker) == 0' \
            "$SYSTEM_CRONTAB" >"$legacy_forkop_crontab" ||
        ! cat "$legacy_forkop_crontab" >"$SYSTEM_CRONTAB"; then
        warn "Failed to remove the $LEGACY_FORKOP_BRAND jobs from $SYSTEM_CRONTAB"
        return 0
    fi
    # crond rereads a crontab changed in place only when it restarts.
    if [ -x "$SYSTEM_CRON_INIT" ]; then
        "$SYSTEM_CRON_INIT" restart >/dev/null 2>&1 || warn "Failed to restart cron"
    fi
}

legacy_forkop_remove_rt_table() {
    [ -f "$SYSTEM_RT_TABLES" ] || return 0
    legacy_forkop_rt_tables="$TMP_DIR/legacy-forkop-rt_tables"
    if ! awk -v id="$LEGACY_FORKOP_RT_TABLE_ID" -v name="$LEGACY_FORKOP_RT_TABLE_NAME" \
            '!($1 == id && $2 == name)' "$SYSTEM_RT_TABLES" >"$legacy_forkop_rt_tables"; then
        warn "Failed to remove the $LEGACY_FORKOP_BRAND routing table name from $SYSTEM_RT_TABLES"
        return 0
    fi
    cmp -s "$legacy_forkop_rt_tables" "$SYSTEM_RT_TABLES" && return 0
    cat "$legacy_forkop_rt_tables" >"$SYSTEM_RT_TABLES" ||
        warn "Failed to remove the $LEGACY_FORKOP_BRAND routing table name from $SYSTEM_RT_TABLES"
}

legacy_forkop_remove_configuration() {
    for legacy_forkop_suffix in "" -opkg .opkg-new .opkg-old .opkg-dist .apk-new .apk-old; do
        rm -f "$LEGACY_FORKOP_CONFIG$legacy_forkop_suffix" ||
            warn "Failed to remove $LEGACY_FORKOP_CONFIG$legacy_forkop_suffix"
    done
}

# The kill-switch state stays while its policy or dnsmasq still uses it:
# dnsmasq does not start with a servers file that is gone. Prokop's
# kill-switch removes it once it has taken over.
legacy_forkop_killswitch_state_referenced() {
    [ ! -e "$LEGACY_FORKOP_KILLSWITCH_INCLUDE" ] || return 0
    ! legacy_forkop_nft_table_present "$LEGACY_FORKOP_KILLSWITCH_TABLE" || return 0
    legacy_forkop_serversfile="$(install_json_ucode uci-get 'dhcp.@dnsmasq[0].serversfile' 2>/dev/null)" ||
        return 0
    case "$legacy_forkop_serversfile" in
        "$LEGACY_FORKOP_KILLSWITCH_STATE_DIR"|"$LEGACY_FORKOP_KILLSWITCH_STATE_DIR"/*) return 0 ;;
    esac
    return 1
}

legacy_forkop_remove_state() {
    legacy_forkop_keep_killswitch=0
    if [ -e "$LEGACY_FORKOP_KILLSWITCH_STATE_DIR" ] && legacy_forkop_killswitch_state_referenced; then
        legacy_forkop_keep_killswitch=1
    fi

    if [ -d "$LEGACY_FORKOP_STATE_DIR" ] && [ ! -L "$LEGACY_FORKOP_STATE_DIR" ]; then
        for legacy_forkop_entry in "$LEGACY_FORKOP_STATE_DIR"/* "$LEGACY_FORKOP_STATE_DIR"/.[!.]* \
            "$LEGACY_FORKOP_STATE_DIR"/..?*; do
            [ -e "$legacy_forkop_entry" ] || [ -L "$legacy_forkop_entry" ] || continue
            if [ "$legacy_forkop_keep_killswitch" -eq 1 ] &&
                [ "$legacy_forkop_entry" = "$LEGACY_FORKOP_KILLSWITCH_STATE_DIR" ]; then
                continue
            fi
            rm -rf "$legacy_forkop_entry" || warn "Failed to remove $legacy_forkop_entry"
        done
        rmdir "$LEGACY_FORKOP_STATE_DIR" 2>/dev/null || true
    elif [ -e "$LEGACY_FORKOP_STATE_DIR" ] || [ -L "$LEGACY_FORKOP_STATE_DIR" ]; then
        rm -f "$LEGACY_FORKOP_STATE_DIR" || warn "Failed to remove $LEGACY_FORKOP_STATE_DIR"
    fi
    rm -rf "$LEGACY_FORKOP_BACKUP_DIR" || warn "Failed to remove $LEGACY_FORKOP_BACKUP_DIR"
}

legacy_forkop_cleanup() {
    legacy_forkop_delete_nft_tables
    legacy_forkop_delete_services
    legacy_forkop_remove_files
    legacy_forkop_remove_cron_jobs
    legacy_forkop_remove_rt_table
    legacy_forkop_remove_configuration
    # Prokop's postinst skips its legacy cleanup while the old init script
    # exists; it is gone now, so run it once instead of waiting for an upgrade.
    # It restores the flow offload the old guard saved in its state, so it
    # runs before that state is removed.
    if [ -r "$PROKOP_TARGET_LIB/service/package.uc" ]; then
        ucode -L "$PROKOP_TARGET_LIB" "$PROKOP_TARGET_LIB/service/package.uc" legacy-cleanup >/dev/null 2>&1 ||
            warn "Failed to clean up what the old $LEGACY_FORKOP_BRAND guard left behind"
    fi
    legacy_forkop_remove_state
    legacy_forkop_ucode installer-legacy-forkop-cleanup-uci >"$TMP_DIR/legacy-forkop-cleanup.env" ||
        warn "Failed to update the rpcd login grants and the LuCI caches"
}

legacy_forkop_finish() {
    install_ui_packages
    persist_mirror_setting
    # Zapret-Manager launchers written by the old installation still point at
    # its mirror; regenerate them for the mirror setting saved above.
    if [ -r "$PROKOP_TARGET_LIB/components/action.uc" ]; then
        ucode -L "$PROKOP_TARGET_LIB" "$PROKOP_TARGET_LIB/components/action.uc" reconcile-zapret-manager-launchers >/dev/null 2>&1 ||
            warn "Failed to update the Zapret-Manager launchers"
    fi
    if [ "$LEGACY_FORKOP_MANAGED_SING_BOX" -eq 1 ] &&
        { [ ! -x "$SING_BOX_BINARY" ] || [ ! -x "$SING_BOX_INIT_SCRIPT" ]; }; then
        warn "$(installer_text legacy_forkop_sing_box_lost)"
        SING_BOX_INSTALL_VARIANT="extended-compressed"
    fi
    install_selected_sing_box
    validate_installed_configuration
    # Enabled and started as the old installation was.
    PROKOP_WAS_ENABLED="$LEGACY_FORKOP_WAS_ENABLED"
    PROKOP_WAS_RUNNING="$LEGACY_FORKOP_WAS_RUNNING"
    post_install

    rm -f "$LEGACY_FORKOP_MIGRATION_MARKER"
    if [ "$PROKOP_CONFIG_READY" -eq 1 ] && [ "$LEGACY_FORKOP_KEEP_BACKUPS" -eq 0 ]; then
        rm -rf "$LEGACY_FORKOP_MIGRATION_DIR"
    else
        LEGACY_FORKOP_KEEP_BACKUPS=1
    fi
    LEGACY_FORKOP_ACTIVE=0
    LEGACY_FORKOP_MIGRATION_COMPLETE=1
}

legacy_forkop_after_point_of_no_return() {
    legacy_forkop_from_rank="$1"
    if [ "$legacy_forkop_from_rank" -le 3 ]; then
        legacy_forkop_set_stage deactivate
        LEGACY_FORKOP_POINT_OF_NO_RETURN=1
        legacy_forkop_deactivate
    fi
    LEGACY_FORKOP_POINT_OF_NO_RETURN=1
    if [ "$legacy_forkop_from_rank" -le 4 ]; then
        legacy_forkop_set_stage remove
        legacy_forkop_neutralise_package_scripts
        legacy_forkop_remove_packages
    fi
    if [ "$legacy_forkop_from_rank" -le 5 ]; then
        legacy_forkop_set_stage cleanup
        legacy_forkop_cleanup
    fi
    legacy_forkop_set_stage finish
    legacy_forkop_finish
}

# Before the point of no return: the old installation was not touched. Prokop
# goes (unless it was installed before) with everything this run copied, its
# previous configuration comes back, and the old service is brought back to
# its recorded state. Without a recorded state nothing was changed yet.
legacy_forkop_rollback() {
    if [ ! -r "$LEGACY_FORKOP_MIGRATION_DIR/state" ]; then
        rm -rf "$LEGACY_FORKOP_MIGRATION_DIR"
        rm -f "$LEGACY_FORKOP_MIGRATION_MARKER"
        return 0
    fi

    legacy_forkop_rollback_ok=1
    if [ "$(legacy_forkop_state_get prokop_installed)" = 0 ]; then
        # The Prokop prerm restores dnsmasq, which the old installation
        # still uses: without its executable the prerm does nothing.
        if pkg_is_installed prokop; then
            rm -f "$PROKOP_TARGET_BIN"
        fi
        for legacy_forkop_package in luci-i18n-prokop-ru luci-app-prokop prokop; do
            legacy_forkop_remove_package "$legacy_forkop_package" || legacy_forkop_rollback_ok=0
        done
    fi

    case "$(legacy_forkop_state_get prokop_config)" in
        absent)
            rm -f "$PROKOP_TARGET_CONFIG" "$PROKOP_TARGET_CONFIG.migrating" || legacy_forkop_rollback_ok=0
            ;;
        *)
            if [ -f "$LEGACY_FORKOP_MIGRATION_DIR/prokop.config" ]; then
                if ! cp "$LEGACY_FORKOP_MIGRATION_DIR/prokop.config" "$PROKOP_TARGET_CONFIG" ||
                    ! chmod 0644 "$PROKOP_TARGET_CONFIG"; then
                    legacy_forkop_rollback_ok=0
                fi
            fi
            ;;
    esac

    if [ -f "$LEGACY_FORKOP_MIGRATION_DIR/copied" ]; then
        while IFS= read -r legacy_forkop_copied; do
            [ -n "$legacy_forkop_copied" ] || continue
            rm -rf "$legacy_forkop_copied" || legacy_forkop_rollback_ok=0
        done <"$LEGACY_FORKOP_MIGRATION_DIR/copied"
    fi
    if [ "$(legacy_forkop_state_get prokop_backups_dir_existed)" = 0 ]; then
        rm -rf "$PROKOP_TARGET_BACKUPS_DIR" || legacy_forkop_rollback_ok=0
    fi

    LEGACY_FORKOP_WAS_ENABLED="$(legacy_forkop_state_flag was_enabled)"
    LEGACY_FORKOP_WAS_RUNNING="$(legacy_forkop_state_flag was_running)"
    legacy_forkop_ucode installer-legacy-forkop-restore-service >/dev/null || legacy_forkop_rollback_ok=0

    if [ "$legacy_forkop_rollback_ok" -ne 1 ]; then
        # The marker stays, so the next run retries the rollback.
        warn "$(installer_text legacy_forkop_rollback_incomplete) $LEGACY_FORKOP_MIGRATION_DIR"
        return 1
    fi

    if [ "$(legacy_forkop_state_get prokop_state_dir_existed)" = 0 ]; then
        rm -rf "$PROKOP_TARGET_STATE_DIR"
    fi
    rm -f "$LEGACY_FORKOP_MIGRATION_MARKER"
    rm -rf "$LEGACY_FORKOP_MIGRATION_DIR"
    if [ "$LEGACY_FORKOP_CHANGES_STARTED" -eq 1 ]; then
        warn "$(installer_text legacy_forkop_rolled_back)"
    fi
    return 0
}

# After the point of no return: Prokop keeps its configuration and stays
# disabled; the marker and the backups stay for the next run.
legacy_forkop_hold() {
    legacy_forkop_ucode installer-hold-prokop >/dev/null 2>&1 ||
        warn "Failed to disable Prokop"
    warn "$(installer_text legacy_forkop_failed) $LEGACY_FORKOP_STAGE"
    warn "$(installer_text legacy_forkop_failed_prokop) $PROKOP_TARGET_CONFIG"
    warn "$(installer_text legacy_forkop_backups) $LEGACY_FORKOP_MIGRATION_DIR"
    warn "$(installer_text legacy_forkop_failed_next)
    wget -qO- $RELEASE_BASE_URL/install.sh | sh"
}

legacy_forkop_on_failure() {
    [ "$LEGACY_FORKOP_ACTIVE" -eq 1 ] || return 0
    [ "$LEGACY_FORKOP_FAILURE_HANDLED" -eq 0 ] || return 0
    LEGACY_FORKOP_FAILURE_HANDLED=1
    if [ "$LEGACY_FORKOP_POINT_OF_NO_RETURN" -eq 1 ]; then
        legacy_forkop_hold
    else
        legacy_forkop_rollback || true
    fi
}

legacy_forkop_resume_after_point_of_no_return() {
    LEGACY_FORKOP_ACTIVE=1
    LEGACY_FORKOP_CHANGES_STARTED=1
    LEGACY_FORKOP_POINT_OF_NO_RETURN=1
    LEGACY_FORKOP_STAGE="$LEGACY_FORKOP_RESUME_STAGE"
    msg "$(installer_text legacy_forkop_resume) $LEGACY_FORKOP_RESUME_STAGE"
    if [ -r "$LEGACY_FORKOP_MIGRATION_DIR/state" ]; then
        LEGACY_FORKOP_WAS_ENABLED="$(legacy_forkop_state_flag was_enabled)"
        LEGACY_FORKOP_WAS_RUNNING="$(legacy_forkop_state_flag was_running)"
        if [ "$(legacy_forkop_state_get prokop_config)" = edited ]; then
            LEGACY_FORKOP_KEEP_BACKUPS=1
        fi
    else
        warn "$(installer_text legacy_forkop_resume_without_state)"
        LEGACY_FORKOP_WAS_ENABLED=0
        LEGACY_FORKOP_WAS_RUNNING=0
        LEGACY_FORKOP_KEEP_BACKUPS=1
    fi

    resolve_prokop_release
    msg "Downloading Prokop packages"
    download_prokop_packages
    # The interface is installed from this release at the end; the backend
    # comes from it too unless it is installed at that version already (a
    # newer release may have appeared since the interrupted run).
    if [ "$(pkg_installed_version prokop)" != "$PROKOP_PACKAGE_VERSION" ]; then
        install_backend_package
    fi
    legacy_forkop_after_point_of_no_return "$(legacy_forkop_stage_rank "$LEGACY_FORKOP_RESUME_STAGE")"
}

legacy_forkop_migrate() {
    if [ -n "$LEGACY_FORKOP_RESUME_STAGE" ]; then
        legacy_forkop_resume_rank="$(legacy_forkop_stage_rank "$LEGACY_FORKOP_RESUME_STAGE")"
        if [ "$legacy_forkop_resume_rank" -eq 0 ]; then
            fail "$LEGACY_FORKOP_MIGRATION_MARKER names an unknown stage '$LEGACY_FORKOP_RESUME_STAGE'. Nothing was changed; check Prokop and $LEGACY_FORKOP_BRAND (backups: $LEGACY_FORKOP_MIGRATION_DIR), remove the marker and run the installer again"
        fi
        if [ "$legacy_forkop_resume_rank" -ge 3 ]; then
            legacy_forkop_resume_after_point_of_no_return
            return 0
        fi

        warn "$(installer_text legacy_forkop_resume_rollback) $LEGACY_FORKOP_RESUME_STAGE"
        LEGACY_FORKOP_CHANGES_STARTED=1
        legacy_forkop_rollback ||
            fail "$(installer_text legacy_forkop_rollback_incomplete) $LEGACY_FORKOP_MIGRATION_DIR"
        LEGACY_FORKOP_CHANGES_STARTED=0
        legacy_forkop_detect_installation
        [ "$LEGACY_FORKOP_DETECTED" -eq 1 ] ||
            fail "Nothing of $LEGACY_FORKOP_BRAND is left after the rollback; run the installer again"
    fi

    msg "$(installer_text legacy_forkop_detected)"
    legacy_forkop_preflight
    legacy_forkop_record_state
    legacy_forkop_confirm
    legacy_forkop_set_stage prepare
    resolve_prokop_release
    msg "Downloading Prokop packages before making system changes"
    download_prokop_packages
    ensure_flash_space

    LEGACY_FORKOP_CHANGES_STARTED=1
    legacy_forkop_set_stage install
    install_backend_package
    legacy_forkop_install_configuration
    legacy_forkop_copy_state
    legacy_forkop_validate_configuration

    legacy_forkop_after_point_of_no_return 3
}

legacy_forkop_print_result() {
    [ "$LEGACY_FORKOP_MIGRATION_COMPLETE" -eq 1 ] || return 0
    msg "$(installer_text legacy_forkop_done)"
    if [ "$PROKOP_CONFIG_READY" -ne 1 ]; then
        warn "$(installer_text legacy_forkop_not_ready): $PROKOP_CONFIG_VALIDATION_ERROR"
    elif [ "$LEGACY_FORKOP_WAS_RUNNING" -eq 1 ]; then
        msg "$(installer_text legacy_forkop_service_started)"
    elif [ "$LEGACY_FORKOP_WAS_ENABLED" -eq 1 ]; then
        msg "$(installer_text legacy_forkop_service_enabled)"
    else
        warn "$(installer_text legacy_forkop_service_stopped)"
    fi
    if [ "$LEGACY_FORKOP_KEEP_BACKUPS" -eq 1 ]; then
        warn "$(installer_text legacy_forkop_backups) $LEGACY_FORKOP_MIGRATION_DIR"
    fi
    if [ -e "$LEGACY_FORKOP_KILLSWITCH_INCLUDE" ] ||
        legacy_forkop_nft_table_present "$LEGACY_FORKOP_KILLSWITCH_TABLE"; then
        warn "$(installer_text legacy_forkop_killswitch_kept)"
    fi
}

decide_i18n_installation() {
    luci_lang="$(get_luci_main_lang)"

    detect_installer_language

    if pkg_is_installed "luci-i18n-prokop-ru"; then
        PROKOP_I18N_REQUESTED=1
        msg "$(installer_text i18n_installed)"
        return 0
    fi

    if [ "$PROKOP_LEGACY_DETECTED" -eq 1 ] &&
        pkg_is_installed "luci-i18n-${LEGACY_BACKEND_PACKAGE}-ru"; then
        PROKOP_I18N_REQUESTED=1
        msg "$(installer_text i18n_installed)"
        return 0
    fi

    # The renamed installation had its Russian interface package.
    if legacy_forkop_mode && [ "$LEGACY_FORKOP_I18N_INSTALLED" -eq 1 ]; then
        PROKOP_I18N_REQUESTED=1
        msg "$(installer_text i18n_installed)"
        return 0
    fi

    if [ "$INSTALL_MODE" != "clean" ] && [ "$INSTALLER_LANG_DETECTED" -eq 1 ]; then
        if [ "$INSTALLER_LANG" = "ru" ]; then
            PROKOP_I18N_REQUESTED=1
            msg "$(installer_text luci_ru)"
        else
            msg "$(installer_text i18n_skip)"
        fi
        return 0
    fi

    select_installer_language || fail "Installer language selection was cancelled"
    if [ "$INSTALLER_LANG" = "ru" ]; then
        PROKOP_I18N_REQUESTED=1
        msg "$(installer_text luci_ru)"
    else
        msg "$(installer_text i18n_skip)"
    fi
}

download_prokop_packages() {
    PROKOP_BACKEND_FILE="$TMP_DIR/$PROKOP_BACKEND_NAME"
    PROKOP_APP_FILE="$TMP_DIR/$PROKOP_APP_NAME"
    PROKOP_I18N_FILE=""

    download_with_retry "$PROKOP_BACKEND_URL" "$PROKOP_BACKEND_FILE" "$PROKOP_BACKEND_NAME" || fail "Failed to download $PROKOP_BACKEND_NAME"
    download_with_retry "$PROKOP_APP_URL" "$PROKOP_APP_FILE" "$PROKOP_APP_NAME" || fail "Failed to download $PROKOP_APP_NAME"
    verify_download_sha256 "$PROKOP_BACKEND_FILE" "$PROKOP_BACKEND_SHA256" "$PROKOP_BACKEND_NAME"
    verify_download_sha256 "$PROKOP_APP_FILE" "$PROKOP_APP_SHA256" "$PROKOP_APP_NAME"

    if [ -n "$PROKOP_I18N_URL" ]; then
        PROKOP_I18N_FILE="$TMP_DIR/$PROKOP_I18N_NAME"
        download_with_retry "$PROKOP_I18N_URL" "$PROKOP_I18N_FILE" "$PROKOP_I18N_NAME" || fail "Failed to download $PROKOP_I18N_NAME"
        verify_download_sha256 "$PROKOP_I18N_FILE" "$PROKOP_I18N_SHA256" "$PROKOP_I18N_NAME"
    fi
}

install_backend_package() {
    pkg_install_prokop_file prokop "$PROKOP_BACKEND_FILE" || fail "prokop installation failed"

    [ -x /usr/bin/prokop ] || fail "prokop executable is missing after package installation"
    /usr/bin/prokop package_postinst ||
        fail "Prokop configuration recovery or validation failed"
}

migrate_legacy_configuration() {
    [ "$PROKOP_LEGACY_DETECTED" -eq 1 ] || return 0

    if [ -n "$LEGACY_CONFIG_BACKUP" ]; then
        cp "$LEGACY_CONFIG_BACKUP" /etc/config/prokop ||
            fail "Failed to restore the legacy configuration for migration"
        # It holds secrets: only root reads it, as the package installs it.
        chmod 0600 /etc/config/prokop ||
            fail "Failed to set permissions on the Prokop configuration"

        msg "Migrating the legacy configuration to Prokop"
        if ! PROKOP_CONFIG_NAME="prokop" \
            PROKOP_LIB="/usr/lib/prokop" \
            ucode -L /usr/lib/prokop /usr/lib/prokop/config/migration.uc migrate-podkop; then
            cp "$LEGACY_CONFIG_BACKUP" /etc/config/prokop 2>/dev/null || true
            fail "Legacy configuration migration failed; the original configuration was restored"
        fi
    else
        warn "The legacy package had no readable configuration; Prokop defaults will be used"
    fi

    install_json_ucode installer-finalize-legacy ||
        fail "Failed to remove legacy configuration and cache files after migration"
}

validate_installed_configuration() {
    validation_output="$TMP_DIR/config-validation.log"
    PROKOP_CONFIG_READY=1
    PROKOP_CONFIG_VALIDATION_ERROR=""

    if ! ucode -L /usr/lib/prokop /usr/lib/prokop/config/validator.uc check-requirements >"$validation_output" 2>&1 ||
        ! ucode -L /usr/lib/prokop /usr/lib/prokop/config/validator.uc validate-runtime >>"$validation_output" 2>&1; then
        PROKOP_CONFIG_READY=0
    fi

    [ "$PROKOP_CONFIG_READY" -eq 0 ] || return 0
    PROKOP_CONFIG_VALIDATION_ERROR="$(sed -n '1p' "$validation_output" 2>/dev/null || true)"
    [ -n "$PROKOP_CONFIG_VALIDATION_ERROR" ] || PROKOP_CONFIG_VALIDATION_ERROR="Prokop configuration validation failed"

    warn "Prokop configuration requires attention: $PROKOP_CONFIG_VALIDATION_ERROR"
    warn "Prokop will remain disabled. The configuration was preserved; fix it in LuCI before starting the service."
}

install_ui_packages() {
    pkg_install_prokop_file luci-app-prokop "$PROKOP_APP_FILE" || fail "luci-app-prokop installation failed"

    if [ -n "$PROKOP_I18N_FILE" ]; then
        pkg_install_prokop_file luci-i18n-prokop-ru "$PROKOP_I18N_FILE" || fail "luci-i18n-prokop-ru installation failed"
    fi
}

persist_mirror_setting() {
    # Without an opt-in the configured prokop.settings.mirror_base_url stays as
    # it is; the package postinst already reconciled the feeds with it.
    [ -n "$MIRROR_BASE_URL" ] || return 0

    # The package postinst ran its one-shot configuration migrations already,
    # so the opted-in mirror is saved only now.
    if install_json_ucode installer-persist-mirror "$MIRROR_BASE_URL"; then
        MIRROR_SETTING_SAVED=1
        msg "Dependency mirror saved in prokop.settings.mirror_base_url: $MIRROR_BASE_URL"
    else
        warn "Failed to save the dependency mirror; set prokop.settings.mirror_base_url to $MIRROR_BASE_URL in LuCI or with uci"
    fi

    if [ ! -x "$MIRROR_MIGRATION_SCRIPT" ]; then
        warn "$MIRROR_MIGRATION_SCRIPT is missing; package feeds were not reconciled with the mirror setting"
        return 0
    fi
    "$MIRROR_MIGRATION_SCRIPT" </dev/null ||
        warn "Failed to reconcile package feeds with the mirror setting; run $MIRROR_MIGRATION_SCRIPT again later"
}

post_install() {
    PROKOP_WAS_ENABLED="$PROKOP_WAS_ENABLED" PROKOP_WAS_RUNNING="$PROKOP_WAS_RUNNING" \
    PROKOP_CONFIG_READY="$PROKOP_CONFIG_READY" \
        install_json_ucode installer-post-install ||
        fail "Failed to complete Prokop post-install actions"
}

print_installation_summary() {
    msg "Prokop $PROKOP_PACKAGE_VERSION has been installed successfully"
    msg "Prokop release source: $PROKOP_RELEASE_SOURCE ($PROKOP_RELEASE_TAG)"
    if [ -z "$MIRROR_BASE_URL" ]; then
        msg "Dependency mirror: not requested; prokop.settings.mirror_base_url was left unchanged (opt in with --mirror URL)"
    elif [ "$MIRROR_SETTING_SAVED" -eq 1 ]; then
        msg "Dependency mirror: $MIRROR_BASE_URL"
    else
        warn "Dependency mirror: $MIRROR_BASE_URL was used for this installation but is not saved in prokop.settings.mirror_base_url"
    fi
}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    parse_args "$@"
    validate_installer_settings
    check_root
    init_tmp_dir
    detect_fetcher
    sync_time
    check_system
    configure_package_mirror

    legacy_forkop_detect_installation
    detect_legacy_installation
    detect_install_mode
    decide_i18n_installation
    select_sing_box_installation || fail "sing-box selection was cancelled"

    pkg_list_update || fail "Failed to update package lists"
    commit_package_mirror_transaction
    ensure_bootstrap_ucode_runtime

    if legacy_forkop_mode; then
        legacy_forkop_migrate
        print_installation_summary
        legacy_forkop_print_result
        return 0
    fi

    resolve_prokop_release
    msg "Downloading Prokop packages before making system changes"
    download_prokop_packages

    confirm_legacy_migration
    ensure_flash_space

    if [ "$INSTALL_MODE" = "legacy" ]; then
        msg "Installing the Prokop backend before removing legacy packages"
        install_backend_package
        begin_legacy_migration
        migrate_legacy_configuration
    else
        cleanup_legacy_installation
        install_backend_package
    fi
    install_ui_packages
    persist_mirror_setting
    install_selected_sing_box
    validate_installed_configuration
    post_install
    remove_legacy_backup

    print_installation_summary
    if [ "$PROKOP_CONFIG_READY" -eq 1 ]; then
        warn "Open LuCI and review your rules before enabling Prokop"
    else
        warn "sing-box was installed, but Prokop was not enabled because its configuration is incomplete"
        warn "Reason: $PROKOP_CONFIG_VALIDATION_ERROR"
    fi
}

main "$@"
