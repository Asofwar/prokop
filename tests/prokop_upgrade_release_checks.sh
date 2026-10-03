#!/bin/sh
set -eu

# What the in-app Prokop upgrade checks in the release it downloads, before
# it stops Prokop (UC-080, UC-027).
#
# Before: only a version picked in the version picker had its packages
# checked against the SHA-256 the release catalog names. The default
# "install latest" took whatever the release server sent: a tampered or
# partially replaced package ran its maintainer scripts as root. Now the
# latest release is checked as well, against the sha256 (or the GitHub API's
# digest) of its metadata, and metadata without one refuses the upgrade, as
# install.sh does. A refusal comes while Prokop still runs.
#
# The previous release, staged as the rollback set and installed by the
# rollback, is checked alike wherever its GitHub metadata names a digest;
# older assets name none (digest null), and their set is staged unchecked.
#
# Also before: on a router without the Russian language pack the release
# plan ends in two empty fields, which trim() cut off, and every in-app
# upgrade failed with "Failed to resolve Prokop release packages" (UC-027).
#
# The upgrade runs end to end (tests/helpers/prokop_upgrade_harness.sh).

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/prokop_upgrade_harness.sh
. "$ROOT_DIR/tests/helpers/prokop_upgrade_harness.sh"

fail() {
    printf 'prokop_upgrade_release_checks: FAIL: %s\n' "$1" >&2
    upgrade_harness_dump
    exit 1
}

expect_message() {
    case "$(upgrade_harness_message)" in
        *"$2"*) ;;
        *) fail "$1: unexpected result: $(upgrade_harness_message)" ;;
    esac
}

packages_installed() {
    grep -Ev '^(apk add .*--simulate|opkg --noaction)' "$UPGRADE_STATE/pm.log" |
        grep -Eq '^(apk add|opkg install)'
}

# The upgrade refused while Prokop still ran, and changed nothing.
refused_untouched() {
    upgrade_harness_run && fail "$1: the refused upgrade was reported as installed"
    expect_message "$1" "$2"
    ! grep -q '^stop' "$UPGRADE_STATE/init.log" || fail "$1: Prokop was stopped before the upgrade refused"
    upgrade_harness_running || fail "$1: Prokop does not run after the refused upgrade"
    ! packages_installed || fail "$1: the refused upgrade installed packages"
    [ "$(upgrade_harness_version prokop)" = 1.0.0-r1 ] || fail "$1: the installed release changed"
    [ ! -e "$UPGRADE_RECOVERY_DIR" ] || fail "$1: the refused upgrade left its staging behind"
    [ ! -e "$UPGRADE_MARKER" ] || fail "$1: the refused upgrade left its managed upgrade marker behind"
}

upgrade_harness_setup

for pm in apk opkg; do
    ext=ipk
    [ "$pm" = opkg ] || ext=apk

    # --- the latest release is installed once its packages check out -------
    upgrade_harness_reset "$pm"
    case="$pm latest"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    [ "$(upgrade_harness_version prokop)" = 1.1.0-r1 ] || fail "$case: the new release is not installed"
    upgrade_harness_running || fail "$case: Prokop does not run after the upgrade"

    # --- a package that is not what the metadata names ---------------------
    for package in prokop luci-app-prokop luci-i18n-prokop-ru; do
        upgrade_harness_reset "$pm"
        upgrade_harness_flag "tamper_$package"
        refused_untouched "$pm latest tampered $package" "checksum mismatch"
        expect_message "$pm latest tampered $package" "${package}_1.1.0.$ext"
    done

    # --- metadata without a checksum: fail closed ---------------------------
    upgrade_harness_reset "$pm"
    upgrade_harness_release_json 1.1.0 "$ext" none >"$UPGRADE_STATE/latest.json"
    refused_untouched "$pm latest without checksums" "has no SHA-256"

    # A malformed checksum is none.
    upgrade_harness_reset "$pm"
    sed 's/"sha256":"[0-9a-f]*"/"sha256":"not-a-digest"/g; s/"digest":"sha256:[0-9a-f]*"/"digest":"md5:0123"/g' \
        "$UPGRADE_STATE/latest.json" >"$UPGRADE_STATE/latest.json.new"
    mv "$UPGRADE_STATE/latest.json.new" "$UPGRADE_STATE/latest.json"
    refused_untouched "$pm latest with malformed checksums" "has no SHA-256"

    # --- GitHub's release metadata names the digest as "sha256:<hex>" -------
    upgrade_harness_reset "$pm"
    upgrade_harness_release_json 1.1.0 "$ext" github >"$UPGRADE_STATE/latest.json"
    case="$pm latest with GitHub digests"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    [ "$(upgrade_harness_version prokop)" = 1.1.0-r1 ] || fail "$case: the new release is not installed"
    upgrade_harness_reset "$pm"
    upgrade_harness_release_json 1.1.0 "$ext" github >"$UPGRADE_STATE/latest.json"
    upgrade_harness_flag tamper_prokop
    refused_untouched "$pm latest tampered with GitHub digests" "checksum mismatch"

    # --- the previous release, staged for the rollback ----------------------
    for package in prokop luci-app-prokop luci-i18n-prokop-ru; do
        upgrade_harness_reset "$pm"
        upgrade_harness_flag "tamper_${package}_1.0.0"
        refused_untouched "$pm previous release tampered $package" "Previous Prokop release package checksum mismatch"
        expect_message "$pm previous release tampered $package" "${package}_1.0.0.$ext"
    done
    # GitHub names no digest for older assets: the set is staged unchecked.
    upgrade_harness_reset "$pm"
    upgrade_harness_release_json 1.0.0 "$ext" none >"$UPGRADE_STATE/previous.json"
    case="$pm previous release without digests"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    [ "$(upgrade_harness_version prokop)" = 1.1.0-r1 ] || fail "$case: the new release is not installed"

    # --- a version picked in the version picker -----------------------------
    upgrade_harness_reset "$pm"
    case="$pm selected"
    upgrade_harness_run prokop install 1.1.0 || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    [ "$(upgrade_harness_version prokop)" = 1.1.0-r1 ] || fail "$case: the selected release is not installed"
    upgrade_harness_reset "$pm"
    upgrade_harness_flag tamper_luci-app-prokop
    case="$pm selected tampered"
    upgrade_harness_run prokop install 1.1.0 && fail "$case: the tampered release was reported as installed"
    expect_message "$case" "checksum mismatch"
    ! grep -q '^stop' "$UPGRADE_STATE/init.log" || fail "$case: Prokop was stopped before the upgrade refused"
    upgrade_harness_running || fail "$case: Prokop does not run after the refused upgrade"
    ! packages_installed || fail "$case: the refused upgrade installed packages"

    # --- a router without the Russian language pack -------------------------
    # The release plan has no i18n package; the upgrade installs the backend
    # and the LuCI app, and stages and checks the previous release without
    # the language pack.
    upgrade_harness_reset "$pm"
    rm -f "$UPGRADE_STATE/pkg/luci-i18n-prokop-ru"
    case="$pm without the language pack"
    upgrade_harness_run || fail "$case: the upgrade failed: $(upgrade_harness_message)"
    if [ "$(upgrade_harness_version prokop)" != 1.1.0-r1 ] ||
        [ "$(upgrade_harness_version luci-app-prokop)" != 1.1.0-r1 ]; then
        fail "$case: the new release is not installed"
    fi
    [ -z "$(upgrade_harness_version luci-i18n-prokop-ru)" ] || fail "$case: the language pack was installed"
    ! grep -q 'luci-i18n-prokop-ru' "$UPGRADE_STATE/curl.log" || fail "$case: the language pack was downloaded"
    upgrade_harness_running || fail "$case: Prokop does not run after the upgrade"
    upgrade_harness_reset "$pm"
    rm -f "$UPGRADE_STATE/pkg/luci-i18n-prokop-ru"
    upgrade_harness_flag tamper_luci-app-prokop
    refused_untouched "$pm without the language pack, tampered" "checksum mismatch"
done

printf 'prokop_upgrade_release_checks: PASS\n'
