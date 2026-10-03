#!/bin/sh
# Install Forkop on a router that should take its OpenWrt packages, lists and
# sing-box-extended from a self-hosted dependency mirror.
#
# The mirror is opt-in and has no default: pass its URL explicitly. Forkop
# itself still comes from the fork's release channel; the installer rewrites
# the OpenWrt feeds only after the mirror's platform index confirms this
# router's release and architecture, and stores the mirror in
# forkop.settings.mirror_base_url. No mirror APK key and no forkop.list feed
# are ever installed.
#
# Usage: router-bootstrap.sh MIRROR_URL [installer options]
set -eu

MIRROR_BASE="${1:-${FORKOP_MIRROR_BASE:-}}"
RELEASE_BASE="${FORKOP_RELEASE_BASE_URL:-https://asofwar.github.io/forkop}"
RELEASE_REPO="${FORKOP_RELEASE_REPO:-Asofwar/forkop}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[ -n "$MIRROR_BASE" ] ||
    fail "Usage: $0 MIRROR_URL [installer options] (there is no default mirror)"
[ "$#" -gt 0 ] && shift

case "$MIRROR_BASE" in
    http://*|https://*) ;;
    *) fail "Mirror URL must start with http:// or https://" ;;
esac
while [ "${MIRROR_BASE%/}" != "$MIRROR_BASE" ]; do
    MIRROR_BASE="${MIRROR_BASE%/}"
done
RELEASE_BASE="${RELEASE_BASE%/}"

installer="$(mktemp /tmp/forkop-install.XXXXXX)"
trap 'rm -f "$installer"' EXIT INT TERM

if ! wget -q -O "$installer" "$RELEASE_BASE/install.sh" || [ ! -s "$installer" ]; then
    echo "Release channel $RELEASE_BASE is unavailable, using GitHub Releases" >&2
    wget -q -O "$installer" \
        "https://github.com/$RELEASE_REPO/releases/latest/download/install.sh" ||
        fail "Unable to download the Forkop installer"
fi
[ -s "$installer" ] || fail "The downloaded Forkop installer is empty"

sh "$installer" --mirror "$MIRROR_BASE" "$@"
