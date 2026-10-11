#!/bin/sh
set -eu

# DoQ needs a core built with QUIC and the DoH client certificate needs
# sing-box 1.13.0; on any other core sing-box refuses the field and the whole
# configuration fails. The requirements check (run by every start and reload)
# names the reason instead.
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/tmp"
cat > "$WORK/bin/sing-box" <<'STUB'
#!/bin/sh
[ "${1:-}" = version ] || exit 1
printf 'sing-box version %s\n\nEnvironment: go1.25 linux/arm64\nTags: %s\n' "$SB_VERSION" "$SB_TAGS"
STUB
cat > "$WORK/bin/logger" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LOGGER_LOG"
STUB
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/nft"
chmod 0755 "$WORK/bin/sing-box" "$WORK/bin/logger" "$WORK/bin/nft"

# check <version> <tags> <uci lines...>: the logger output of one check.
check() {
  version="$1" tags="$2"
  shift 2
  printf '%s\n' 'prokop.settings=settings' "$@" > "$WORK/uci.state"
  rm -f "$WORK/logger.log"
  PATH="$WORK/bin:$PATH" SB_VERSION="$version" SB_TAGS="$tags" LOGGER_LOG="$WORK/logger.log" \
    PROKOP_UCI_STATE_FILE="$WORK/uci.state" PROKOP_UCI_LOG_FILE="$WORK/uci.log" \
    PROKOP_RUNTIME_STATE_DIR="$WORK/run" TMPDIR="$WORK/tmp" \
    ucode -L "$LIB" "$LIB/config/validator.uc" check-requirements > /dev/null 2>&1 || true
  cat "$WORK/logger.log" 2>/dev/null || true
}

out="$(check 1.13.0 with_gvisor,with_utls 'prokop.settings.dns_type=doq')"
printf '%s' "$out" | grep -Fq 'DNS over QUIC (DoQ) needs a sing-box build with QUIC support' ||
  fail "DoQ on a core without with_quic was not refused: $out"
ok "DoQ is refused on a core built without QUIC"

out="$(check 1.13.0 with_gvisor,with_utls 'prokop.dns1=section' 'prokop.dns1.action=dns' 'prokop.dns1.dns_type=doq')"
printf '%s' "$out" | grep -Fq 'DNS over QUIC (DoQ) needs' || fail "a DoQ DNS rule on a core without with_quic was not refused: $out"
ok "a DoQ DNS rule is refused on a core built without QUIC"

out="$(check 1.13.0 with_gvisor,with_quic,with_utls 'prokop.settings.dns_type=doq')"
printf '%s' "$out" | grep -Fq 'DoQ' && fail "DoQ was refused on a core with QUIC: $out"
out="$(check 1.13.0-extended-1.4.0 with_gvisor 'prokop.settings.dns_type=doq')"
printf '%s' "$out" | grep -Fq 'DoQ' && fail "DoQ was refused on sing-box-extended: $out"
out="$(check 1.13.0 with_gvisor 'prokop.settings.dns_type=doh')"
printf '%s' "$out" | grep -Fq 'DoQ' && fail "DoH was refused for a missing QUIC tag: $out"
ok "DoQ passes on a QUIC-capable or extended core; other protocols ignore the tag"

mkdir -p "$WORK/pki"
: > "$WORK/pki/client.crt"
printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'fixture-secret' > "$WORK/pki/client.key"
chmod 0600 "$WORK/pki/client.key"
CERT="prokop.settings.dns_mtls_client_certificate=$WORK/pki/client.crt"
KEY="prokop.settings.dns_mtls_client_key=$WORK/pki/client.key"
out="$(check 1.12.9 with_quic 'prokop.settings.dns_type=doh' 'prokop.settings.dns_mtls_enabled=1' "$CERT" "$KEY")"
printf '%s' "$out" | grep -Fq 'DoH client certificate needs sing-box 1.13.0 or newer (installed: 1.12.9)' ||
  fail "a DoH client certificate on sing-box 1.12 was not refused: $out"
out="$(check 1.13.0 with_quic 'prokop.settings.dns_type=doh' 'prokop.settings.dns_mtls_enabled=1' "$CERT" "$KEY")"
printf '%s' "$out" | grep -Fq 'DoH client' && fail "a DoH client certificate was refused on 1.13.0: $out"
out="$(check 1.12.9 with_quic 'prokop.settings.dns_type=doh' 'prokop.settings.dns_mtls_enabled=0')"
printf '%s' "$out" | grep -Fq 'client certificate' && fail "a disabled client certificate was refused: $out"
ok "the DoH client certificate needs sing-box 1.13.0"

out="$(check 1.13.0 with_quic 'prokop.settings.dns_type=doh' 'prokop.settings.dns_mtls_enabled=1' "$CERT" "prokop.settings.dns_mtls_client_key=$WORK/pki/missing.key")"
printf '%s' "$out" | grep -Fq "DoH client private key file $WORK/pki/missing.key was not found" ||
  fail "a missing client key was not refused: $out"
out="$(check 1.13.0 with_quic 'prokop.settings.dns_type=doh' 'prokop.settings.dns_mtls_enabled=1' "prokop.settings.dns_mtls_client_certificate=$WORK/pki" "$KEY")"
printf '%s' "$out" | grep -Fq "DoH client certificate file $WORK/pki was not found" ||
  fail "a directory was taken for the client certificate: $out"
ok "missing client certificate files are refused before sing-box starts"

chmod 0644 "$WORK/pki/client.key"
out="$(check 1.13.0 with_quic 'prokop.settings.dns_type=doh' 'prokop.settings.dns_mtls_enabled=1' "$CERT" "$KEY")"
printf '%s' "$out" | grep -Fq 'is readable by every user of the router' ||
  fail "a world-readable client key was not reported: $out"
printf '%s' "$out" | grep -F 'DoH client' | grep -Fq 'Aborted' &&
  fail "a world-readable client key must warn, not refuse: $out"
printf '%s' "$out" | grep -Fq 'fixture-secret' && fail "key contents reached the log: $out"
ok "a world-readable client key is reported without its contents"
