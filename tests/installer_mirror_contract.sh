#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
CONFIG="$ROOT_DIR/prokop/files/etc/config/prokop"

# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

sh -n "$INSTALLER"

# The dependency mirror is opt-in: no default host, empty means disabled.
grep -Fq 'MIRROR_BASE_URL="${PROKOP_MIRROR_BASE_URL:-}"' "$INSTALLER" || {
    echo "installer must leave the dependency mirror disabled unless it is requested" >&2
    exit 1
}
source_refute "installer must not name a default dependency mirror" -E \
    'DEFAULT_MIRROR_BASE_URL|MIRROR_BASE_URL=.*https?://' "$INSTALLER"
grep -Fq -- '--mirror)' "$INSTALLER" && grep -Fq -- '--mirror=*)' "$INSTALLER" || {
    echo "installer does not accept --mirror URL" >&2
    exit 1
}
grep -Fq -- '  --mirror URL ' "$INSTALLER" || {
    echo "installer usage does not document --mirror URL" >&2
    exit 1
}
grep -Fq '  PROKOP_MIRROR_BASE_URL ' "$INSTALLER" || {
    echo "installer usage does not document PROKOP_MIRROR_BASE_URL" >&2
    exit 1
}

# The upstream Forkop feed and its key are only ever removed, never installed.
source_refute "installer must not download the upstream mirror APK key" -F \
    'forkop-apk.pem' "$INSTALLER"
source_refute "installer must not configure the upstream Forkop APK feed" -F \
    '/forkop/mirror/current/packages.adb' "$INSTALLER"
[ "$(grep -c -F 'forkop.list' "$INSTALLER")" -eq 1 ] &&
    grep -Fxq 'UPSTREAM_APK_REPOSITORY_FILE="/etc/apk/repositories.d/forkop.list"' "$INSTALLER" || {
    echo "installer may name forkop.list only as the upstream feed it removes" >&2
    exit 1
}
[ "$(grep -c -F 'forkop-mirror.pem' "$INSTALLER")" -eq 1 ] &&
    grep -Fxq 'UPSTREAM_APK_KEY_FILE="/etc/apk/keys/forkop-mirror.pem"' "$INSTALLER" || {
    echo "installer may name forkop-mirror.pem only as the upstream key it removes" >&2
    exit 1
}
source_refute "installer must not write the upstream feed or key" -E \
    '>>? *"?\$(UPSTREAM_APK_REPOSITORY_FILE|UPSTREAM_APK_KEY_FILE)' "$INSTALLER"
grep -Fq 'remove_upstream_prokop_repository' "$INSTALLER" || {
    echo "installer does not remove the upstream Forkop feed and key" >&2
    exit 1
}

grep -Fq 'configure_apk_mirror' "$INSTALLER" || {
    echo "installer does not configure mirrored OpenWrt feeds" >&2
    exit 1
}
grep -Fq 'configure_opkg_mirror' "$INSTALLER" || {
    echo "installer does not configure OpenWrt 24 OPKG feeds" >&2
    exit 1
}
grep -Fq 'vendor and custom feeds remain unchanged' "$INSTALLER" || {
    echo "installer does not preserve vendor and custom OPKG feeds" >&2
    exit 1
}
grep -Fq 'MIRROR_TRANSACTION_ACTIVE=1' "$INSTALLER" || {
    echo "installer feed changes are not transactional" >&2
    exit 1
}
grep -Fq 'rollback_package_mirror' "$INSTALLER" || {
    echo "installer cannot restore feeds after a failed mirror update" >&2
    exit 1
}
grep -Fq '/openwrt/forkop-platforms.tsv' "$INSTALLER" || {
    echo "installer does not consult the mirror platform index" >&2
    exit 1
}
grep -Fq '[ -n "$MIRROR_BASE_URL" ] || return 0' "$INSTALLER" || {
    echo "installer must skip mirror-only steps when no mirror was requested" >&2
    exit 1
}
grep -Fq 'verify_download_sha256' "$INSTALLER" || {
    echo "installer does not verify downloaded release package hashes" >&2
    exit 1
}
grep -Fq 'release-asset-sha256' "$INSTALLER" || {
    echo "installer does not read release package hashes" >&2
    exit 1
}
grep -Fq 'for repository_file in "$APK_REPOSITORIES_FILE" "$distfeeds"' "$INSTALLER" || {
    echo "installer does not redirect both APK repository locations" >&2
    exit 1
}
grep -Fq 'SING_BOX_INSTALL_VARIANT="tiny"' "$INSTALLER" || {
    echo "installer does not default to sing-box-tiny" >&2
    exit 1
}
grep -Eq "^[[:space:]]*option mirror_base_url ''[[:space:]]*$" "$CONFIG" || {
    echo "packaged Prokop config must ship the dependency mirror disabled: option mirror_base_url ''" >&2
    exit 1
}
grep -Fq 'platform_index_reason' "$INSTALLER" || {
    echo "installer does not report why the platform index download failed" >&2
    exit 1
}
grep -Eq 'download_file_once "\$platform_index_url" "\$platform_index" 2>"\$platform_index_error"' "$INSTALLER" || {
    echo "installer does not capture the downloader error for the platform index" >&2
    exit 1
}
grep -Fq 'Could not download $platform_index_url: $platform_index_reason' "$INSTALLER" || {
    echo "installer does not surface the downloader error to the user" >&2
    exit 1
}
grep -Fq 'rebind_domain' "$INSTALLER" || {
    echo "installer does not hint at DNS rebind protection for private mirrors" >&2
    exit 1
}

# An opted-in mirror is saved only after the packages ran their postinst and
# their one-shot migrations, then the feeds are reconciled once more.
grep -Fq 'install_json_ucode installer-persist-mirror "$MIRROR_BASE_URL"' "$INSTALLER" || {
    echo "installer does not save an opted-in mirror through the embedded ucode helper" >&2
    exit 1
}
grep -Fq 'MIRROR_MIGRATION_SCRIPT="/usr/share/prokop/mirror-migration.sh"' "$INSTALLER" || {
    echo "installer does not reconcile feeds through the packaged mirror migration" >&2
    exit 1
}

echo "installer mirror contract tests passed"
