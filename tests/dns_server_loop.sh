#!/usr/bin/env bash
set -euo pipefail

# A DNS server on the router itself is refused while dnsmasq forwards to
# sing-box (NET-5). With 192.168.1.1 or 127.0.0.1 as Prokop's DNS server
# the queries went dnsmasq -> sing-box -> dnsmasq -> ... (dnsmasq keeps no
# cache for them), and all DNS of the router and the LAN stopped; the list
# and subscription downloads with it. Accepted when dnsmasq keeps its own
# servers (dont_touch_dhcp); sing-box's own DNS listener is always refused.
#
# config/validator.uc runs for real; netifd's `ubus` is a double.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/out" ] || sed 's/^/  validator: /' "$WORK/out" >&2
  exit 1
}

mkdir -p "$WORK/bin"
export PATH="$WORK/bin:$PATH"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
cat >"$WORK/bin/ubus" <<'SH'
#!/bin/sh
[ "$*" = 'call network.interface dump' ] || exit 1
cat <<'JSON'
{ "interface": [
  { "interface": "lan", "ipv4-address": [ { "address": "192.168.1.1", "mask": 24 } ],
    "ipv6-prefix-assignment": [ { "address": "2001:db8:5::", "mask": 64, "local-address": { "address": "2001:db8:5::1", "mask": 64 } } ] },
  { "interface": "wan", "ipv4-address": [ { "address": "81.2.3.4", "mask": 22 } ], "ipv6-address": [ { "address": "2001:db8:ff::7", "mask": 64 } ] }
] }
JSON
SH
chmod 0755 "$WORK/bin/"*

# validate <settings JSON fields> [<DNS rule server>]
validate() {
  local settings="$1" rule="${2:-}" sections='[]'
  [ -z "$rule" ] || sections="[ { \".name\": \"dns\", \".type\": \"section\", \"enabled\": \"1\", \"action\": \"dns\", \"dns_server\": \"$rule\", \"domain_suffix\": [ \"corp.example\" ] } ]"
  printf '{ "settings": { ".name": "settings", ".type": "settings", "yacd_secret_key": "s", %s }, "section": %s }\n' \
    "$settings" "$sections" >"$WORK/fixture.json"
  PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/fixture.json" '{}' >"$WORK/out" 2>&1
}
servers() { printf '"dns_server": [ "%s" ], "bootstrap_dns_server": [ "%s" ]' "$1" "$2"; }
refused() { # refused <label> <settings> [<rule server>]
  ! validate "$2" "${3:-}" || fail "$1 was accepted"
  grep -q 'would loop' "$WORK/out" || fail "$1 was refused without saying why"
}
accepted() { validate "$2" "${3:-}" || fail "$1 was refused"; }

accepted "an external DNS server" "$(servers 1.1.1.1 77.88.8.8)"
for server in 192.168.1.1 127.0.0.1 '[::1]:53' tls://81.2.3.4 https://127.0.0.1/dns-query 2001:db8:5::1 2001:db8:ff::7; do
  refused "the router's own address $server as main DNS server" "$(servers "$server" 77.88.8.8)"
done
refused "the router as bootstrap DNS server" "$(servers 1.1.1.1 192.168.1.1)"
refused "the router as a DNS rule's server" "$(servers 1.1.1.1 77.88.8.8)" 127.0.0.1
accepted "an external DNS rule server" "$(servers 1.1.1.1 77.88.8.8)" 10.0.0.53

# dnsmasq keeps its own servers: the router is a valid upstream.
accepted "the router with dont_touch_dhcp" "$(servers 192.168.1.1 127.0.0.1), \"dont_touch_dhcp\": \"1\""
refused "sing-box's own DNS listener" "$(servers 127.0.0.42 77.88.8.8), \"dont_touch_dhcp\": \"1\""

printf 'dns server loop checks passed\n'
