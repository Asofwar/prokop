#!/bin/sh
set -eu

# Prokop never runs the `base64` program: subscriptions, share links and
# certificate pins are decoded and encoded in ucode (b64dec/b64enc in
# subscription/parser.uc and subscription/share_link.uc). The requirements
# check still asked `base64 --version` on every start and aborted the start
# when coreutils-base64 was missing, and the packages depended on it. The
# check is gone and nothing requires the package; one that is already
# installed is left alone.
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

# 1. The requirements check does not run base64 and does not ask for it.
mkdir -p "$WORK/bin" "$WORK/run" "$WORK/tmp"
cat > "$WORK/bin/base64" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$BASE64_LOG"
exit 127
STUB
cat > "$WORK/bin/sing-box" <<'STUB'
#!/bin/sh
[ "${1:-}" = version ] || exit 1
echo "sing-box version 1.14.2"
echo "Tags: with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api"
STUB
cat > "$WORK/bin/logger" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LOGGER_LOG"
STUB
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/nft"
chmod 0755 "$WORK/bin/base64" "$WORK/bin/sing-box" "$WORK/bin/logger" "$WORK/bin/nft"
: > "$WORK/uci.state"
: > "$WORK/base64.log"
: > "$WORK/logger.log"

PATH="$WORK/bin:$PATH" BASE64_LOG="$WORK/base64.log" LOGGER_LOG="$WORK/logger.log" \
  PROKOP_UCI_STATE_FILE="$WORK/uci.state" PROKOP_UCI_LOG_FILE="$WORK/uci.log" \
  PROKOP_RUNTIME_STATE_DIR="$WORK/run" TMPDIR="$WORK/tmp" \
  ucode -L "$LIB" "$LIB/config/validator.uc" check-requirements > "$WORK/out" 2>&1 || true
grep -Fq 'Checking required packages' "$WORK/logger.log" ||
  fail "the requirements check did not run: $(cat "$WORK/out" "$WORK/logger.log")"
[ ! -s "$WORK/base64.log" ] || fail "the requirements check ran base64: $(cat "$WORK/base64.log")"
! grep -Fq 'coreutils-base64' "$WORK/logger.log" "$WORK/out" ||
  fail "the requirements check still names coreutils-base64: $(cat "$WORK/logger.log")"
ok "the requirements check neither runs base64 nor asks for coreutils-base64"

# 2. No code path runs the base64 program: backend, init scripts, LuCI
# (rpcd, ACL, views), the installer and the build. A command is the word
# base64 at a shell command position or inside a command string.
hits="$(grep -RInE "(^|[;&|(\`\"'[:space:]])base64([[:space:]]+-|[[:space:]]*(\\||\$|\"|'|<|>))" \
  "$ROOT/prokop/files" "$ROOT/luci-app-prokop/root" \
  "$ROOT/luci-app-prokop/htdocs/luci-static/resources/view/prokop" \
  "$ROOT/install.sh" "$ROOT/build.sh" "$ROOT/prokop/Makefile" "$ROOT/luci-app-prokop/Makefile" 2>/dev/null |
  grep -v '/main\.js:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|#|\*)' || true)"
[ -z "$hits" ] || fail "something runs the base64 program: $hits"
ok "no backend, LuCI, installer or build code runs base64"

# 3. Neither package nor the installer requires coreutils-base64.
for file in "$ROOT/prokop/Makefile" "$ROOT/build.sh" "$ROOT/install.sh" \
  "$ROOT/prokop/files/usr/lib/core/constants.uc"; do
  ! grep -Eq 'coreutils-base64|COREUTILS_BASE64' "$file" ||
    fail "$(basename "$file") still requires coreutils-base64"
done
ok "no package dependency or installer check on coreutils-base64"

printf 'base64_not_required: PASS\n'
