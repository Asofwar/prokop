#!/usr/bin/env bash
set -euo pipefail

# C7: a rule's mixed proxy listens on the router's LAN address. A port that
# the router's own services, Prokop's listeners on every address, the direct
# proxy or another enabled rule's mixed proxy already hold made sing-box fail
# to start ("address already in use"). The validator now refuses it with the
# holder named; a disabled rule or a rule with its mixed proxy off holds no
# port. The LuCI field refuses the same ports when the value is entered.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod +x "$WORK/bin/logger"

# rule NAME ENABLED MIXED PORT
rule() {
  printf '{ ".name": "%s", ".type": "section", "enabled": "%s", "action": "connection", "outbound_jsons": ["{\\"type\\":\\"http\\",\\"tag\\":\\"t\\",\\"server\\":\\"proxy.example\\",\\"server_port\\":8080}"], "domain_suffix": ["%s.example"], "mixed_proxy_enabled": "%s", "mixed_proxy_port": "%s" }' "$1" "$2" "$1" "$3" "$4"
}
# check NAME SETTINGS RULES...
check() {
  local name="$1" settings="$2"
  shift 2
  local rules
  rules="$(IFS=,; printf '%s' "$*")"
  printf '{ "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret"%s }, "section": [ %s ] }\n' \
    "${settings:+, $settings}" "$rules" >"$WORK/$name.json"
  PATH="$WORK/bin:$PATH" PROKOP_LIB="$LIB" \
    ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/$name.json" '{}' >"$WORK/$name.out" 2>&1
}
accepted() { check "$@" || fail "$1 was refused: $(cat "$WORK/$1.out")"; }
refused() {
  local name="$1" holder="$2"
  shift 2
  if check "$name" "$@"; then fail "$name was accepted"; fi
  grep -q "already used by $holder" "$WORK/$name.out" || fail "$name: the holder '$holder' is not named: $(cat "$WORK/$name.out")"
}

accepted distinct "" "$(rule a 1 1 7890)" "$(rule b 1 1 7891)"
accepted disabled_rule "" "$(rule a 1 1 7890)" "$(rule b 0 1 7890)"
accepted mixed_off "" "$(rule a 1 1 7890)" "$(rule b 1 0 7890)"
accepted direct_off '"direct_proxy_enabled": "0", "direct_proxy_port": "7890"' "$(rule a 1 1 7890)"

refused duplicate "the mixed proxy of rule 'a'" "" "$(rule a 1 1 7890)" "$(rule b 1 1 7890)"
refused direct "the direct proxy" '"direct_proxy_enabled": "1", "direct_proxy_port": "7890"' "$(rule a 1 1 7890)"
refused direct_default "the direct proxy" '"direct_proxy_enabled": "1"' "$(rule a 1 1 2080)"
for port_holder in "22:SSH" "53:DNS" "80:LuCI (HTTP)" "443:LuCI (HTTPS)" "1602:the Prokop transparent proxy" \
  "1603:the Prokop DNS of devices" "9090:the Clash API"; do
  port="${port_holder%%:*}"
  refused "reserved_$port" "${port_holder#*:}" "" "$(rule a 1 1 "$port")"
done

# The LuCI field refuses the same reserved ports.
SECTION_JS="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js"
for port in 22 53 80 443 1602 1603 9090; do
  grep -Eq "^ +$port: " "$SECTION_JS" || fail "the LuCI mixed proxy port field does not refuse $port"
done
echo "mixed_proxy_port_conflicts: OK"
