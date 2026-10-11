#!/usr/bin/env bash
set -euo pipefail

# U4: a subscription body holds passwords and UUIDs. The parser never copies
# it to the shared /tmp: a Clash YAML body is parsed in memory, an unpacked
# gzip body and the metadata go next to their own file (in the 0700
# subscription directory), and every file it writes is created 0600 whatever
# the umask. No temporary file is left behind, on success or failure.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
PARSER="$LIB/subscription/parser.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mode_of() { stat -c '%a' "$1"; }

umask 000
SUB="$WORK/subscriptions"
mkdir -p "$SUB"
chmod 700 "$SUB"
cat >"$WORK/clash.yaml" <<'YAML'
proxies:
  - { name: A, type: trojan, server: example.com, port: 443, password: very-secret }
YAML
gzip -c "$WORK/clash.yaml" >"$SUB/s.download"
before="$(ls -A /tmp | sort)"

ucode -L "$LIB" "$PARSER" try-decode-gzip-content "$SUB/s.download" || fail "the gzip body was not unpacked"
[ "$(mode_of "$SUB/s.download")" = 600 ] || fail "the unpacked body is $(mode_of "$SUB/s.download"), not 600"
gzip -c "$WORK/clash.yaml" >"$SUB/s2.download"
ucode -L "$LIB" "$PARSER" normalize-content-validated "$SUB/s2.download" "$SUB/s.normalized" ||
  fail "the gzip Clash body was not normalized"
[ "$(mode_of "$SUB/s.normalized")" = 600 ] || fail "the normalized file is $(mode_of "$SUB/s.normalized")"
grep -q very-secret "$SUB/s.normalized" || fail "the normalized file lost the node"
ucode -L "$LIB" "$PARSER" normalize-content "$WORK/clash.yaml" "$SUB/plain.json" || fail "the Clash body was not normalized"
[ "$(mode_of "$SUB/plain.json")" = 600 ] || fail "the Clash output is $(mode_of "$SUB/plain.json")"
printf 'vless://00000000-0000-4000-8000-000000000001@example.com:443?security=tls#V\n' >"$WORK/list.txt"
ucode -L "$LIB" "$PARSER" normalize-content "$WORK/list.txt" "$SUB/list.json" || fail "the link list was not normalized"
[ "$(mode_of "$SUB/list.json")" = 600 ] || fail "the link list output is $(mode_of "$SUB/list.json")"

# A failure leaves nothing behind either.
printf 'garbage' | gzip -c >"$SUB/bad.download"
if ucode -L "$LIB" "$PARSER" normalize-content-validated "$SUB/bad.download" "$SUB/bad.normalized"; then
  fail "a body without nodes was accepted"
fi
printf 'title: x\n' >"$WORK/headers"
ucode -L "$LIB" "$PARSER" metadata-extract-ui-file "$WORK/headers" "$SUB/s.download" "$SUB/meta.json" || true
[ ! -e "$SUB/meta.json" ] || [ "$(mode_of "$SUB/meta.json")" = 600 ] || fail "the metadata file is not 600"

leftover="$(ls -A "$SUB" | grep -E '\.(gunzip|tmp)\.' || true)"
[ -z "$leftover" ] || fail "temporary files were left: $leftover"
after="$(ls -A /tmp | sort)"
new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep prokop-subscription || true)"
[ -z "$new" ] || fail "the parser wrote to /tmp: $new"
grep -q '"/tmp/' "$PARSER" && fail "the parser still names /tmp"

# The share link cache is rewritten 0600 too.
printf '{"outbounds":[{"type":"trojan","tag":"t","server":"example.com","server_port":443,"password":"p"}]}\n' >"$SUB/links.json"
ucode -L "$LIB" -e 'require("subscription.share_link").populate_subscription_file(ARGV[0]) || exit(1);' "$SUB/links.json" ||
  fail "share links were not added"
[ "$(mode_of "$SUB/links.json")" = 600 ] || fail "the share link cache is $(mode_of "$SUB/links.json")"
grep -q 'trojan://' "$SUB/links.json" || fail "the share link was not written"

printf 'subscription private temp file checks passed\n'
