# shellcheck shell=sh
# The in-app Prokop upgrade (components/action.uc `component-action prokop
# install`) run end to end against stand-ins for the router: apk or opkg, the
# release servers (curl), the init script, `prokop get_status`, df and the
# start-and-wait of service/initd.uc. The flow itself is the production code:
# the harness is components/action.uc with its dispatch replaced, and only
# the functions that would touch the host's /tmp, LuCI caches, rpcd, sing-box
# service or /etc, or scan the host's processes are overridden (other tests
# run sing-box doubles of their own). The action's PATH holds the stand-ins and the host's tools
# without a host apk or opkg: the router's package manager is the stand-in.
#
# Sourced by the tests that need it, after ROOT_DIR and WORK_DIR are set.
# POSIX sh and bash compatible.
#
#   upgrade_harness_setup                 build the stand-ins (once)
#   upgrade_harness_reset apk|opkg        Prokop 1.0.0 installed and running
#   upgrade_harness_flag NAME [VALUE]     inject a failure (see the stand-ins)
#   upgrade_harness_run [COMP ACTION [VERSION]]
#                                         the action (default: prokop install);
#                                         JSON response in $UPGRADE_OUT
#   upgrade_harness_exec SCRIPT [ARG...]  a variant of the harness ($UPGRADE_HARNESS
#                                         ends in its dispatch line), run alike
#   upgrade_harness_version PACKAGE       the installed version
#   upgrade_harness_running               Prokop runs
#
# Logs under $UPGRADE_STATE: init.log (init.d calls with PROKOP_STOP_SOURCE),
# initd.log (service/initd.uc calls), pm.log (apk/opkg calls), curl.log,
# luci-refresh.log (the LuCI refresh after a completed upgrade),
# sing-box-service.log (the standalone sing-box service kept disabled).

UPGRADE_LIB="$WORK_DIR/upgrade/lib"
UPGRADE_BIN="$WORK_DIR/upgrade/bin"
UPGRADE_STATE="$WORK_DIR/upgrade/state"
UPGRADE_HARNESS="$WORK_DIR/upgrade/action-harness.uc"
UPGRADE_INIT="$WORK_DIR/upgrade/init"
UPGRADE_PROKOP="$WORK_DIR/upgrade/prokop"
UPGRADE_RECOVERY_DIR="$WORK_DIR/upgrade/state/recovery"
UPGRADE_MARKER="$WORK_DIR/upgrade/state/managed-upgrade-sing-box"
UPGRADE_OUT="$WORK_DIR/upgrade/out.json"
UPGRADE_HOST_BIN="$WORK_DIR/upgrade/host-bin"

# The host's PATH, with every directory that holds an apk or opkg replaced by
# a copy of its links without them.
upgrade_harness_host_path() {
    upgrade_path=""
    upgrade_shadow_index=0
    upgrade_saved_ifs="$IFS"
    IFS=:
    set -f
    # shellcheck disable=SC2086 # split on ':' only
    set -- $PATH
    set +f
    IFS="$upgrade_saved_ifs"
    for upgrade_dir in "$@"; do
        [ -n "$upgrade_dir" ] || continue
        if [ -e "$upgrade_dir/apk" ] || [ -e "$upgrade_dir/opkg" ]; then
            upgrade_shadow_index=$((upgrade_shadow_index + 1))
            upgrade_shadow="$UPGRADE_HOST_BIN/$upgrade_shadow_index"
            mkdir -p "$upgrade_shadow"
            for upgrade_tool in "$upgrade_dir"/*; do
                case "${upgrade_tool##*/}" in
                    apk|opkg) ;;
                    *) [ ! -x "$upgrade_tool" ] || ln -s "$upgrade_tool" "$upgrade_shadow/" 2>/dev/null || true ;;
                esac
            done
            upgrade_dir="$upgrade_shadow"
        fi
        upgrade_path="${upgrade_path:+$upgrade_path:}$upgrade_dir"
    done
    printf '%s\n' "$upgrade_path"
}

upgrade_harness_setup() {
    upgrade_action_uc="$ROOT_DIR/prokop/files/usr/lib/components/action.uc"
    mkdir -p "$UPGRADE_LIB/service" "$UPGRADE_BIN" "$UPGRADE_STATE"
    ln -s "$ROOT_DIR/prokop/files/usr/lib/core" "$UPGRADE_LIB/core"
    ln -s "$ROOT_DIR/prokop/files/usr/lib/components" "$UPGRADE_LIB/components"

    awk '
        $0 == "let mode = ARGV[0] || \"\";" { found = 1; exit }
        { print }
        END { if (!found) exit 1 }
    ' "$upgrade_action_uc" >"$UPGRADE_HARNESS" ||
        { printf 'FAIL: the dispatch of %s was not found\n' "$upgrade_action_uc" >&2; exit 1; }
    cat >>"$UPGRADE_HARNESS" <<'UCODE'

// Test overrides: the temporary directory and the version caches stay in the
// test's directory, and the host's sing-box processes are not the router's.
const HARNESS_STATE = getenv("UPGRADE_STATE");
function cleanup_stale_tmp_files() {}
function init_tmp_dir() {
    if (tmp_dir != "")
        return true;
    tmp_dir = trim(command_output_from_args([ "mktemp", "-d", HARNESS_STATE + "/updates.XXXXXX" ]));
    return tmp_dir != "";
}
function write_prokop_latest_version_cache(value, timestamp) {}
function clear_version_caches() {}
function refresh_luci_after_prokop_upgrade() {
    let log = fs.open(HARNESS_STATE + "/luci-refresh.log", "a");
    log.write("refresh\n");
    log.close();
}
function upgrade_sing_box_processes() {
    return file_exists(HARNESS_STATE + "/flags/sing_box_ambiguous") ? null : {};
}
// The router's sing-box service and configuration archive are not the
// host's.
function prepare_sing_box_service_disabled() {
    let log = fs.open(HARNESS_STATE + "/sing-box-service.log", "a");
    log.write("disable\n");
    log.close();
}
function save_prokop_configuration_backup(config_dir, backup_dir) {
    let backup = HARNESS_STATE + "/configuration.tar.gz";
    return write_file(backup, "backup\n") ? backup : "";
}

component_action(ARGV[0], ARGV[1], ARGV[2]);
UCODE

    # service/initd.uc start-and-wait: the init script's start, then the
    # runtime is checked. deferred-start-pending: the init script keeps a
    # start deferred for reload.lock ($UPGRADE_STATE/deferred-start).
    cat >"$UPGRADE_LIB/service/initd.uc" <<'UCODE'
let fs = require("fs");
let state = getenv("UPGRADE_STATE");
let log = fs.open(state + "/initd.log", "a");
log.write(join(" ", ARGV) + "\n");
log.close();
if (ARGV[0] == "start-and-wait") {
    let status = system([ getenv("PROKOP_SERVICE_INIT"), ARGV[1] ]);
    exit(status == 0 && fs.stat(state + "/running") != null ? 0 : 1);
}
if (ARGV[0] == "deferred-start-pending")
    exit(fs.stat(state + "/deferred-start") != null ? 0 : 1);
exit(1);
UCODE

    # service/state.uc: the upgrade marker, and whether a stop is requested.
    cat >"$UPGRADE_LIB/service/state.uc" <<'UCODE'
let fs = require("fs");
if (ARGV[0] == "write-managed-upgrade-sing-box-marker") {
    fs.writefile(ARGV[1], "format=1\n");
    exit(0);
}
if (ARGV[0] == "stop-requested")
    exit(fs.stat(getenv("PROKOP_RUNTIME_STATE_DIR") + "/stop.requested") != null ? 0 : 1);
exit(1);
UCODE

    # The optional providers: installed while the package database holds
    # their package.
    for upgrade_provider in zapret zapret2 byedpi; do
        mkdir -p "$UPGRADE_LIB/providers/$upgrade_provider"
        cat >"$UPGRADE_LIB/providers/$upgrade_provider/runtime.uc" <<UCODE
let fs = require("fs");
let version = fs.readfile(getenv("UPGRADE_STATE") + "/pkg/$upgrade_provider");
if (ARGV[0] == "installed")
    exit(version != null && trim(version) != "" ? 0 : 1);
if (ARGV[0] == "package-version" && version != null)
    print(trim(version), "\n");
exit(0);
UCODE
    done

    # The init script records every call with the source of a stop. A stop
    # records its request as service/initd.uc does (by=<source>; a stop made
    # while the user's stop is in effect stays the user's; a refused stop
    # records none), a start removes it. The user's start deferred for
    # reload.lock ($UPGRADE_STATE/deferred-start) is pending until a stop
    # cancels it or a start serves it; the user's stop that it followed is
    # no longer in effect. A restart is rc.common's: its stop
    # (the user's unless the caller names a source), then the start, only
    # once that stop succeeded. A start refuses, as service/lifecycle.uc
    # start_inner does, while the upgrade marker is stale, and consumes it.
    # Flags: stop_status (exit status of a stop: 2 is a refusal), start_fail,
    # start_deferred (the start waits for reload.lock past every wait: it
    # neither runs nor removes the stop request), marker_stale (the package
    # manager ran longer than the marker's age), user_stop_on_start (the
    # user's stop overtakes the next start: it is skipped, as
    # service/initd.uc skips a start when a stop was requested after it).
    cat >"$UPGRADE_INIT" <<'SH'
#!/bin/sh
state="$UPGRADE_STATE"
request="$PROKOP_RUNTIME_STATE_DIR/stop.requested"
printf '%s source=%s\n' "$*" "${PROKOP_STOP_SOURCE:-}" >>"$state/init.log"
case "$1" in
    stop)
        status="$(cat "$state/flags/stop_status" 2>/dev/null || echo 0)"
        [ "$status" -ne 2 ] || exit 2
        case "${PROKOP_STOP_SOURCE:-}" in
            package|component) source="$PROKOP_STOP_SOURCE" ;;
            *) source=user ;;
        esac
        [ ! -e "$request" ] || grep -Eq '^by=(package|component)$' "$request" ||
            [ -e "$state/deferred-start" ] || source=user
        rm -f "$state/deferred-start"
        mkdir -p "$PROKOP_RUNTIME_STATE_DIR"
        printf 'requested\nby=%s\n' "$source" >"$request"
        [ "$status" -ne 0 ] || rm -f "$state/running"
        exit "$status"
        ;;
    restart)
        "$0" stop || exit
        exec "$0" start
        ;;
    start)
        if [ -e "$state/flags/marker_stale" ] && [ -e "$PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER" ]; then
            rm -f "$PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER"
            printf 'start refused: stale managed upgrade marker\n' >>"$state/init.log"
            exit 1
        fi
        [ ! -e "$state/flags/start_fail" ] || exit 1
        if [ -e "$state/flags/start_deferred" ]; then
            printf 'start deferred\n' >>"$state/init.log"
            exit 0
        fi
        if [ -e "$state/flags/user_stop_on_start" ]; then
            rm -f "$state/flags/user_stop_on_start" "$state/running"
            mkdir -p "$PROKOP_RUNTIME_STATE_DIR"
            printf 'requested\nby=user\n' >"$request"
            printf 'start skipped: the user stopped Prokop\n' >>"$state/init.log"
            exit 0
        fi
        rm -f "$request" "$state/deferred-start"
        : >"$state/running"
        ;;
esac
exit 0
SH

    cat >"$UPGRADE_PROKOP" <<'SH'
#!/bin/sh
case "$1" in
    get_status)
        if [ -e "$UPGRADE_STATE/running" ]; then echo '{"running": 1}'; else echo '{"running": 0}'; fi
        ;;
esac
exit 0
SH

    # Release servers: fold8 serves the release to install and the catalog
    # of the version picker, GitHub the metadata of the installed one. A
    # package file names the package and version it holds, whatever the file
    # is called. Flags: github_down, download_fail_<version>,
    # tamper_<package> and tamper_<package>_<version> (the server holds
    # other bytes than the metadata names, for every release or for that
    # one); while the upgrade asks GitHub (before Prokop is stopped for it),
    # user_stop_on_github has the user stop Prokop, crash_on_github takes it
    # down without a stop and start_on_github has the user start it.
    cat >"$UPGRADE_BIN/curl" <<'SH'
#!/bin/sh
state="$UPGRADE_STATE"
out=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --connect-timeout|-m|-x) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\n' "$url" >>"$state/curl.log"
case "$url" in
    https://releases.invalid/updates/latest.json)
        cat "$state/latest.json" >"$out"
        ;;
    https://releases.invalid/updates/releases.json)
        [ -e "$state/releases.json" ] || exit 22
        cat "$state/releases.json" >"$out"
        ;;
    https://api.github.com/repos/*/releases/tags/1.0.0)
        [ ! -e "$state/flags/user_stop_on_github" ] || env -u PROKOP_STOP_SOURCE "$PROKOP_SERVICE_INIT" stop
        [ ! -e "$state/flags/crash_on_github" ] || rm -f "$state/running"
        [ ! -e "$state/flags/start_on_github" ] || env -u PROKOP_STOP_SOURCE "$PROKOP_SERVICE_INIT" start
        [ ! -e "$state/flags/github_down" ] || exit 22
        cat "$state/previous.json" >"$out"
        ;;
    https://releases.invalid/releases/*)
        file="${url##*/}"
        name="${file%%_*}"
        version="${file#*_}"
        version="${version%.*}"
        [ ! -e "$state/flags/download_fail_$version" ] || exit 22
        printf 'name=%s\nversion=%s-r1\n' "$name" "$version" >"$out"
        if [ -e "$state/flags/tamper_$name" ] || [ -e "$state/flags/tamper_${name}_$version" ]; then
            printf 'tampered\n' >>"$out"
        fi
        ;;
    *)
        exit 6
        ;;
esac
SH

    # apk and opkg over one package database ($UPGRADE_STATE/pkg/<name>).
    # Installing the backend runs its maintainer scripts: prerm stops a
    # running Prokop for the package, postinst starts it again. Flags:
    # preflight_fail, fail_new_<package> and fail_old_<package> (installing
    # 1.1.0 or 1.0.0 of that package fails; apk keeps the packages of the
    # transaction installed before it), postinst_starts (postinst always
    # starts Prokop), user_stop_on_install and user_stop_on_remove (the user
    # stops Prokop while a package is installed or removed), remove_fail.
    cat >"$UPGRADE_BIN/package-manager" <<'SH'
#!/bin/sh
state="$UPGRADE_STATE"
pm="$(basename "$0")"
printf '%s %s\n' "$pm" "$*" >>"$state/pm.log"

user_stop() {
    if [ -e "$state/flags/$1" ]; then
        rm -f "$state/flags/$1"
        env -u PROKOP_STOP_SOURCE "$PROKOP_SERVICE_INIT" stop || true
    fi
}

install_file() {
    [ -r "$1" ] || { echo "$1: no such file" >&2; return 1; }
    name="$(sed -n 's/^name=//p' "$1")"
    version="$(sed -n 's/^version=//p' "$1")"
    user_stop user_stop_on_install
    case "$version" in
        1.1.0-*) age=new ;;
        *) age=old ;;
    esac
    if [ "$name" = prokop ]; then
        if [ -e "$state/running" ]; then
            PROKOP_STOP_SOURCE=package "$PROKOP_SERVICE_INIT" stop || true
            : >"$state/package-was-running"
        fi
    fi
    [ ! -e "$state/flags/fail_${age}_$name" ] || { echo "installing $name $version failed" >&2; return 1; }
    printf '%s\n' "$version" >"$state/pkg/$name"
    if [ "$name" = prokop ] &&
        { [ -e "$state/package-was-running" ] || [ -e "$state/flags/postinst_starts" ]; }; then
        rm -f "$state/package-was-running"
        "$PROKOP_SERVICE_INIT" start || true
    fi
}

install_files() {
    simulate="$1"
    shift
    for file in "$@"; do
        [ -r "$file" ] || { echo "$file: no such file" >&2; exit 1; }
    done
    if [ "$simulate" = 1 ]; then
        [ ! -e "$state/flags/preflight_fail" ] || exit 1
        exit 0
    fi
    for file in "$@"; do
        install_file "$file" || exit 1
    done
    exit 0
}

package_argument() {
    for argument in "$@"; do
        case "$argument" in
            -*) ;;
            *) printf '%s\n' "$argument" ;;
        esac
    done
}

remove_packages() {
    for name in "$@"; do
        [ -s "$state/pkg/$name" ] || { echo "$name: not installed" >&2; exit 1; }
        user_stop user_stop_on_remove
        [ ! -e "$state/flags/remove_fail" ] || { echo "removing $name failed" >&2; exit 1; }
        rm -f "$state/pkg/$name"
    done
    exit 0
}

if [ "$pm" = apk ]; then
    case "$1" in
        info)
            [ "$2" = -e ] && [ -s "$state/pkg/$3" ]
            exit
            ;;
        list)
            shift
            for name in $(package_argument "$@"); do
                [ ! -s "$state/pkg/$name" ] ||
                    printf '%s-%s noarch {%s} (GPL-2.0) [installed]\n' "$name" "$(cat "$state/pkg/$name")" "$name"
            done
            exit 0
            ;;
        add)
            shift
            simulate=0
            case " $* " in *" --simulate "*) simulate=1 ;; esac
            # shellcheck disable=SC2046 # one package file per line
            install_files "$simulate" $(package_argument "$@")
            ;;
        del)
            shift
            # shellcheck disable=SC2046 # one package name per line
            remove_packages $(package_argument "$@")
            ;;
    esac
    exit 1
fi

simulate=0
[ "$1" != --noaction ] || { simulate=1; shift; }
case "$1" in
    list-installed)
        for path in "$state"/pkg/*; do
            [ ! -s "$path" ] || printf '%s - %s\n' "$(basename "$path")" "$(cat "$path")"
        done
        exit 0
        ;;
    install)
        shift
        # shellcheck disable=SC2046 # one package file per line
        install_files "$simulate" $(package_argument "$@")
        ;;
    remove)
        shift
        # shellcheck disable=SC2046 # one package name per line
        remove_packages $(package_argument "$@")
        ;;
esac
exit 1
SH
    chmod +x "$UPGRADE_INIT" "$UPGRADE_PROKOP" "$UPGRADE_BIN/curl" "$UPGRADE_BIN/package-manager"

    # Free space: flag df_avail (KiB, plenty by default).
    cat >"$UPGRADE_BIN/df" <<'SH'
#!/bin/sh
available="$(cat "$UPGRADE_STATE/flags/df_avail" 2>/dev/null || echo 1048576)"
printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\nfake 2097152 0 %s 0%% /\n' "$available"
SH
    cat >"$UPGRADE_BIN/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$UPGRADE_STATE/logger.log"
SH
    printf '#!/bin/sh\nexit 0\n' >"$UPGRADE_BIN/killall"
    printf '#!/bin/sh\nexit 0\n' >"$UPGRADE_BIN/sync"
    printf '#!/bin/sh\necho "{}"\n' >"$UPGRADE_BIN/ubus"
    chmod +x "$UPGRADE_BIN/df" "$UPGRADE_BIN/logger" "$UPGRADE_BIN/killall" "$UPGRADE_BIN/sync" "$UPGRADE_BIN/ubus"

    upgrade_host_path="$(upgrade_harness_host_path)"
    if PATH="$upgrade_host_path" command -v apk >/dev/null 2>&1 ||
        PATH="$upgrade_host_path" command -v opkg >/dev/null 2>&1; then
        printf 'FAIL: the host package manager is still on the harness PATH\n' >&2
        exit 1
    fi
    UPGRADE_PATH="$UPGRADE_BIN:$upgrade_host_path"
}

# The SHA-256 of the package file the release server holds for PACKAGE at
# VERSION.
upgrade_harness_package_sha256() {
    printf 'name=%s\nversion=%s-r1\n' "$1" "$2" | sha256sum | cut -d' ' -f1
}

# release_json VERSION EXT [DIGESTS]: the release metadata. DIGESTS names
# the checksums of the assets as the server publishes them: "mirror" (the
# default; fold8's latest.json and catalog carry sha256 and digest),
# "github" (the GitHub API's digest "sha256:<hex>" only) or "none".
upgrade_harness_release_json() {
    printf '{"tag_name":"%s","html_url":"https://releases.invalid/%s","assets":[' "$1" "$1"
    upgrade_separator=""
    for upgrade_asset in prokop luci-app-prokop luci-i18n-prokop-ru; do
        upgrade_sum="$(upgrade_harness_package_sha256 "$upgrade_asset" "$1")"
        case "${3:-mirror}" in
            mirror) upgrade_digest="$(printf '"sha256":"%s","digest":"sha256:%s",' "$upgrade_sum" "$upgrade_sum")" ;;
            github) upgrade_digest="$(printf '"digest":"sha256:%s",' "$upgrade_sum")" ;;
            *) upgrade_digest="" ;;
        esac
        printf '%s{"name":"%s_%s.%s",%s"browser_download_url":"https://releases.invalid/releases/%s/%s_%s.%s"}' \
            "$upgrade_separator" "$upgrade_asset" "$1" "$2" "$upgrade_digest" "$1" "$upgrade_asset" "$1" "$2"
        upgrade_separator=","
    done
    printf ']}\n'
}

upgrade_harness_reset() {
    rm -rf "$UPGRADE_STATE" "$UPGRADE_BIN/apk" "$UPGRADE_BIN/opkg"
    mkdir -p "$UPGRADE_STATE/pkg" "$UPGRADE_STATE/flags"
    : >"$UPGRADE_STATE/init.log"
    : >"$UPGRADE_STATE/initd.log"
    : >"$UPGRADE_STATE/pm.log"
    : >"$UPGRADE_STATE/curl.log"
    ln -s package-manager "$UPGRADE_BIN/$1"
    case "$1" in
        apk) upgrade_extension=apk ;;
        *) upgrade_extension=ipk ;;
    esac
    upgrade_harness_release_json 1.1.0 "$upgrade_extension" >"$UPGRADE_STATE/latest.json"
    upgrade_harness_release_json 1.0.0 "$upgrade_extension" github >"$UPGRADE_STATE/previous.json"
    {
        printf '{"format":1,"releases":['
        upgrade_harness_release_json 1.1.0 "$upgrade_extension"
        printf ']}\n'
    } >"$UPGRADE_STATE/releases.json"
    for upgrade_package in prokop luci-app-prokop luci-i18n-prokop-ru; do
        printf '1.0.0-r1\n' >"$UPGRADE_STATE/pkg/$upgrade_package"
    done
    : >"$UPGRADE_STATE/running"
}

upgrade_harness_flag() {
    printf '%s\n' "${2:-1}" >"$UPGRADE_STATE/flags/$1"
}

upgrade_harness_unflag() {
    rm -f "$UPGRADE_STATE/flags/$1"
}

# upgrade_harness_run [COMPONENT ACTION [VERSION]]: the component action,
# the in-app Prokop upgrade by default.
upgrade_harness_run() {
    [ "$#" -gt 0 ] || set -- prokop install
    upgrade_harness_exec "$UPGRADE_HARNESS" "$@"
}

# upgrade_harness_exec SCRIPT [ARG...]: a ucode script (the harness or a
# variant of it) run as the action runs.
upgrade_harness_exec() {
    upgrade_status=0
    upgrade_script="$1"
    shift
    env UPGRADE_STATE="$UPGRADE_STATE" \
        PATH="$UPGRADE_PATH" \
        PROKOP_LIB="$UPGRADE_LIB" \
        PROKOP_BIN="$UPGRADE_PROKOP" \
        PROKOP_SERVICE_INIT="$UPGRADE_INIT" \
        PROKOP_VERSION=1.0.0 \
        PROKOP_RELEASE_REPO=slayer326/forkop \
        PROKOP_RELEASE_BASE_URL=https://releases.invalid \
        PROKOP_MIRROR_BASE_URL= \
        PROKOP_RUNTIME_STATE_DIR="$UPGRADE_STATE/run" \
        PROKOP_OPKG_RECOVERY_DIR="$UPGRADE_RECOVERY_DIR" \
        PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$UPGRADE_MARKER" \
        PROKOP_SYSTEM_INFO_CACHE_FILE="$UPGRADE_STATE/system-info.json" \
        PROKOP_UPGRADE_STOP_TIMEOUT_SECONDS=20 \
        ucode -L "$UPGRADE_LIB" "$upgrade_script" "$@" >"$UPGRADE_OUT" 2>"$UPGRADE_STATE/stderr" ||
        upgrade_status=$?
    return "$upgrade_status"
}

upgrade_harness_version() {
    cat "$UPGRADE_STATE/pkg/$1" 2>/dev/null || true
}

upgrade_harness_running() {
    [ -e "$UPGRADE_STATE/running" ]
}

# upgrade_harness_message: the message of the action's response.
upgrade_harness_message() {
    sed -n 's/.*"message": *"\([^"]*\)".*/\1/p' "$UPGRADE_OUT"
}

upgrade_harness_succeeded() {
    grep -Eq '"success": *true' "$UPGRADE_OUT"
}

upgrade_harness_dump() {
    for upgrade_log in out.json state/init.log state/initd.log state/pm.log state/curl.log state/stderr; do
        [ ! -s "$WORK_DIR/upgrade/$upgrade_log" ] || sed "s|^|  $upgrade_log: |" "$WORK_DIR/upgrade/$upgrade_log" >&2
    done
}
