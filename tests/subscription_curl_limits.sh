#!/usr/bin/env bash
set -eo pipefail

# Subscription downloads are bounded and keep their token off the command
# line (OBS-2, CFG-4). Before: no --max-time or --max-filesize (a provider
# sending 2 B/s held the update forever), redirects were not followed, and
# the URL with its token and the HWID were in curl's argv, readable by every
# user in /proc. A gzip body unpacked into memory whole.
#
# subscription/cache.uc and parser.uc run for real; curl is a stub.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
CACHE_UC="$PROKOP_LIB/subscription/cache.uc"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${CURL_LOG:?}"
out="" config=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -K) config="$2"; shift ;;
  esac
  shift
done
if [ -n "$config" ]; then
  stat -c '%a' "$config" >"$CURL_CONFIG_MODE"
  cat "$config" >"$CURL_CONFIG_COPY"
fi
head -c "${BODY_BYTES:-20}" /dev/zero | tr '\0' 'x' >"$out"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/"*

export PATH="$WORK_DIR/bin:$PATH"
export CURL_LOG="$WORK_DIR/curl.args"
export CURL_CONFIG_MODE="$WORK_DIR/curl.mode"
export CURL_CONFIG_COPY="$WORK_DIR/curl.config"
printf 'prokop.settings=settings\n' >"$WORK_DIR/uci.state"

download() {
  PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    ucode -L "$PROKOP_LIB" "$CACHE_UC" download-subscription-fixture "$1" "$WORK_DIR/result" "" "" "" "hwid-secret-42"
}

url='https://sub.example/api/sub?token=tok-secret-77'
download "$url" || fail "the download must succeed"
args="$(cat "$CURL_LOG")"
for secret in tok-secret-77 hwid-secret-42; do
  case "$args" in *"$secret"*) fail "curl's command line must not carry $secret: $args" ;; esac
done
for flag in '--max-time 120' '--max-filesize 16777216' '--proto-redir =https' '--max-redirs 5' ' -L ' ' -K '; do
  case " $args " in *"$flag"*) ;; *) fail "curl must get $flag: $args" ;; esac
done
[ "$(cat "$CURL_CONFIG_MODE")" = 600 ] || fail "the curl config must be 0600, got $(cat "$CURL_CONFIG_MODE")"
grep -Fxq "url = \"$url\"" "$CURL_CONFIG_COPY" || fail "the curl config must carry the URL: $(cat "$CURL_CONFIG_COPY")"
grep -Fxq 'header = "X-HWID: hwid-secret-42"' "$CURL_CONFIG_COPY" || fail "the curl config must carry the HWID"
if compgen -G "$WORK_DIR/*.curl" >/dev/null; then fail "the curl config must be removed after the request"; fi
[ -s "$WORK_DIR/result" ] || fail "the body must be saved"

# A quote in the URL cannot end the config value early.
download 'https://sub.example/a"b\c' || fail "a URL with a quote must still download"
grep -Fxq 'url = "https://sub.example/a\"b\\c"' "$CURL_CONFIG_COPY" ||
  fail "the URL must be quoted for the curl config: $(cat "$CURL_CONFIG_COPY")"

# A body over the limit (an old curl lets a chunked one through) is refused.
rm -f "$WORK_DIR/result"
if BODY_BYTES=2000 PROKOP_SUBSCRIPTION_MAX_BYTES=1000 download "$url"; then
  fail "an oversized response must fail the download"
fi
[ ! -e "$WORK_DIR/result" ] || fail "an oversized response must not be saved"

# gzip: unpacked with a cap, not into memory whole.
head -c 3000000 /dev/zero | gzip >"$WORK_DIR/bomb.gz"
cp "$WORK_DIR/bomb.gz" "$WORK_DIR/bomb.orig"
if PROKOP_SUBSCRIPTION_MAX_BYTES=1000000 \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/subscription/parser.uc" try-decode-gzip-content "$WORK_DIR/bomb.gz" 2>"$WORK_DIR/gzip.err"; then
  fail "a gzip body over the limit must not be unpacked"
fi
cmp -s "$WORK_DIR/bomb.gz" "$WORK_DIR/bomb.orig" || fail "a refused gzip body must stay as it was"
grep -Fq "unpacks to more than 1000000 bytes" "$WORK_DIR/gzip.err" || fail "a refused gzip body must be reported"
printf 'vless://x\n' | gzip >"$WORK_DIR/ok.gz"
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/subscription/parser.uc" try-decode-gzip-content "$WORK_DIR/ok.gz" ||
  fail "a small gzip body must be unpacked"
[ "$(cat "$WORK_DIR/ok.gz")" = 'vless://x' ] || fail "the gzip body must be unpacked in place"
printf 'plain\n' >"$WORK_DIR/plain.txt"
if ucode -L "$PROKOP_LIB" "$PROKOP_LIB/subscription/parser.uc" try-decode-gzip-content "$WORK_DIR/plain.txt"; then
  fail "a plain body is not gzip"
fi

printf 'subscription curl limit checks passed\n'
