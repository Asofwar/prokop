#!/usr/bin/env bash
set -euo pipefail

# C9: EDNS Client Subnet (settings.dns_client_subnet). Empty by default: the
# generated DNS block has no client_subnet. An address or subnet goes into
# dns.client_subnet as written. The validator refuses what sing-box's netip
# parsing would refuse (leading zeros, a prefix out of range, a name), so a
# bad value is reported on save instead of sing-box not starting. With
# $PROKOP_TEST_SING_BOX (or sing-box on PATH), the real binary agrees with
# the validator on every sample.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod +x "$WORK/bin/logger"

fixture() {
  local name="$1" members="$2"
  printf '{ "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret"%s }, "section": [ { ".name": "main", ".type": "section", "enabled": "1", "action": "connection", "outbound_jsons": ["{\\"type\\":\\"http\\",\\"tag\\":\\"test\\",\\"server\\":\\"proxy.example\\",\\"server_port\\":8080}"], "domain_suffix": ["example.com"] } ] }\n' \
    "${members:+, $members}" >"$WORK/$name.json"
}
generate() {
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/$1.json" "$WORK/$1.config.json" 192.0.2.1 0 1 '' 1.12.0 >/dev/null 2>&1 ||
    fail "generator failed for $1"
}
client_subnet() {
  ucode -e 'let c = json(require("fs").readfile(ARGV[0])); print(c.dns.client_subnet ?? "<none>");' "$WORK/$1.config.json"
}
validates() {
  PATH="$WORK/bin:$PATH" PROKOP_LIB="$LIB" \
    ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/$1.json" '{}' >"$WORK/$1.out" 2>&1
}

fixture default ""
generate default
[ "$(client_subnet default)" = "<none>" ] || fail "client_subnet is set by default"
validates default || fail "the default configuration was refused: $(cat "$WORK/default.out")"

accepted=("203.0.113.0/24" "203.0.113.7" "2001:db8::/56" "2001:db8::1" " 198.51.100.0/24 ")
refused=("203.0.113.0/33" "203.000.113.0/24" "203.0.113.0/024" "2001:db8::/129" "example.com" "203.0.113.0/" "1.2.3")
i=0
for value in "${accepted[@]}"; do
  i=$((i + 1))
  fixture "ok$i" "\"dns_client_subnet\": \"$value\""
  validates "ok$i" || fail "'$value' was refused: $(cat "$WORK/ok$i.out")"
  generate "ok$i"
  trimmed="$(printf '%s' "$value" | sed 's/^ *//;s/ *$//')"
  [ "$(client_subnet "ok$i")" = "$trimmed" ] || fail "'$value' became '$(client_subnet "ok$i")'"
done
i=0
for value in "${refused[@]}"; do
  i=$((i + 1))
  fixture "bad$i" "\"dns_client_subnet\": \"$value\""
  if validates "bad$i"; then fail "'$value' was accepted"; fi
  grep -q 'EDNS Client Subnet' "$WORK/bad$i.out" || fail "'$value': the refusal does not name the setting: $(cat "$WORK/bad$i.out")"
done

SING_BOX="${PROKOP_TEST_SING_BOX:-$(command -v sing-box 2>/dev/null || true)}"
if [ -z "$SING_BOX" ] || [ ! -x "$SING_BOX" ]; then
  printf 'dns_client_subnet: OK (real sing-box not checked: set PROKOP_TEST_SING_BOX)\n'
  exit 0
fi
sing_box_accepts() {
  printf '{ "dns": { "servers": [ { "type": "udp", "tag": "d", "server": "192.0.2.53" } ], "client_subnet": "%s" } }\n' "$1" >"$WORK/sb.json"
  "$SING_BOX" check -c "$WORK/sb.json" >/dev/null 2>&1
}
for value in "${accepted[@]}"; do
  trimmed="$(printf '%s' "$value" | sed 's/^ *//;s/ *$//')"
  sing_box_accepts "$trimmed" || fail "real sing-box refused '$trimmed', which the validator accepts"
done
for value in "${refused[@]}"; do
  if sing_box_accepts "$value"; then fail "real sing-box accepts '$value', which the validator refuses"; fi
done
echo "dns_client_subnet: OK"
