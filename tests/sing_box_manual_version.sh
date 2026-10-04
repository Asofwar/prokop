#!/usr/bin/env bash
set -eo pipefail

# A sing-box package installed over the compressed sing-box-extended binary
# (A11). That binary is installed with every sing-box package removed, and
# its marker made Prokop report the version and features of the binary it
# had installed: after `apk add sing-box` the router showed the old
# extended version, Tailscale support and no Tiny limits for a binary that
# was gone. A package present means the marker is stale.
#
# singbox/runtime.uc and core/packages.uc run for real; apk and sing-box
# are stubs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/sing-box" <<'SH'
#!/bin/sh
[ "$1" = version ] || exit 1
printf 'sing-box version 1.12.9\n\nTags: with_gvisor,with_quic\n'
SH
# apk knows the packages listed in $INSTALLED.
cat >"$WORK_DIR/bin/apk" <<'SH'
#!/bin/sh
[ "$1 $2" = "info -e" ] || exit 1
grep -qx "$3" "$INSTALLED" 2>/dev/null
SH
chmod +x "$WORK_DIR/bin/"*

printf 'extended-compressed\n' >"$WORK_DIR/variant"
printf '1.14.1-extended-2.7.2\n' >"$WORK_DIR/version"
: >"$WORK_DIR/installed"

runtime() {
  PATH="$WORK_DIR/bin:$PATH" INSTALLED="$WORK_DIR/installed" PROKOP_LIB="$LIB" \
    SB_VARIANT_STATE_FILE="$WORK_DIR/variant" SB_VERSION_STATE_FILE="$WORK_DIR/version" \
    ucode -L "$LIB" "$LIB/singbox/runtime.uc" "$@"
}

# The compressed binary as Prokop installed it: no package owns sing-box.
[ "$(runtime variant)" = extended-compressed ] || fail "the compressed variant was not reported: $(runtime variant)"
[ "$(runtime version)" = 1.14.1-extended-2.7.2 ] || fail "the compressed binary's version was not taken from its state"
runtime marker-is extended-compressed || fail "the compressed marker must hold while no package owns sing-box"

# The stable package installed over it by hand.
printf 'sing-box\n' >"$WORK_DIR/installed"
[ "$(runtime variant)" = stable ] || fail "a sing-box package over the compressed binary must be reported as stable, got $(runtime variant)"
[ "$(runtime version)" = 1.12.9 ] || fail "the version must come from the installed binary, got $(runtime version)"
if runtime marker-is extended-compressed; then
  fail "a stale compressed marker must not hold once a package owns sing-box"
fi
if runtime is-extended ""; then
  fail "the package's binary must not be taken for sing-box-extended"
fi
[ "$(cat "$WORK_DIR/variant")" = extended-compressed ] || fail "reading the variant must not rewrite the marker"

printf 'sing-box manual version checks passed\n'
