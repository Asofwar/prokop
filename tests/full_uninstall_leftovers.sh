#!/bin/sh
# Full uninstall removes every command the prokop package installs, even when
# the package manager left it behind (UC-001 added /usr/libexec/prokop-ro).
set -eu
REPO="$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$REPO/prokop/files/usr/lib/full-uninstall.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# shellcheck disable=SC2016 # Makefile variables are matched literally
commands="$(sed -n 's|^[[:space:]]*\$(INSTALL_BIN) [^ ]* \$(1)\(/usr/s\{0,1\}bin/[^ ]*\)$|\1|p; s|^[[:space:]]*\$(INSTALL_BIN) [^ ]* \$(1)\(/usr/libexec/[^ ]*\)$|\1|p' \
    "$REPO/prokop/Makefile")"
printf '%s\n' "$commands" | grep -qx /usr/bin/prokop || fail "could not read package commands"
printf '%s\n' "$commands" | grep -qx /usr/libexec/prokop-ro || fail "package does not ship the read-only wrapper"

mkdir -p "$ROOT/etc/opkg" "$ROOT/bin" "$ROOT/packages"
printf 'original vendor repositories\n' > "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
printf 'https://mirror.51343.ru/openwrt/releases/test\n' > "$ROOT/etc/opkg/distfeeds.conf"
touch "$ROOT/packages/prokop"
for command in $commands; do
    mkdir -p "$ROOT$(dirname "$command")"
    printf '#!/bin/sh\nexit 0\n' > "$ROOT$command"
    chmod +x "$ROOT$command"
done
cat > "$ROOT/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
 status) [ -e "$PROKOP_UNINSTALL_ROOT/packages/$2" ] && echo 'Status: install ok installed';;
 remove) shift; for p in "$@"; do rm -f "$PROKOP_UNINSTALL_ROOT/packages/$p"; done;;
 *) exit 1;;
esac
SH
# Nothing of Prokop's runtime is in place: never the host's nft and ip.
printf '#!/bin/sh\nexit 1\n' > "$ROOT/bin/nft"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/ip"
chmod +x "$ROOT/bin/opkg" "$ROOT/bin/nft" "$ROOT/bin/ip"

PROKOP_UNINSTALL_ROOT="$ROOT" PATH="$ROOT/bin:$PATH" sh "$SCRIPT" start > "$ROOT/response"
count=0
while :; do
    status="$(cat "$ROOT"/www/prokop-uninstall.*.json)"
    case "$status" in *'"state":"complete"'*|*'"state":"failed"'*) break;; esac
    count=$((count+1))
    [ "$count" -lt 20 ] || fail 'worker timed out'
    sleep 1
done
printf '%s\n' "$status" | grep -q '"state":"complete"' || fail "uninstall failed: $status"
for command in $commands; do
    [ ! -e "$ROOT$command" ] || fail "full uninstall left $command behind"
done
printf 'full uninstall removes every packaged command\n'
