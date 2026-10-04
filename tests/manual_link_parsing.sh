#!/usr/bin/env bash
set -euo pipefail

# A manual proxy link becomes the same outbound as the same link in a
# subscription (SB-2, SB-3). The generator had a second parser that decoded
# the whole link before reading it: an encoded '#' cut the link and the
# whole configuration was refused, an encoded '+' became a space, an
# encoded '&' cut a path. It refused Hysteria2 port ranges, wrote
# obfs "none" as an obfs type and non-numeric speeds as NaN, all of which
# the UI accepts. Manual links now go through the subscription parser.
#
# singbox/generator.uc runs for real on a fixture.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/err" ] || sed 's/^/  generator: /' "$WORK/err" >&2
  exit 1
}

# outbound <link>: the outbound the generator writes for a manual link.
outbound() {
  jq -n --arg link "$1" '{
    settings: { ".name": "settings", ".type": "settings", dns_server: "77.88.8.8", bootstrap_dns_server: "77.88.8.8" },
    section: [ { ".name": "main", ".type": "section", enabled: "1", action: "connection",
      selector_proxy_links: $link, domain_suffix: [ "example.com" ] } ]
  }' >"$WORK/fixture.json"
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/config.json" \
    192.0.2.1 0 1 '' 1.12.0 2>"$WORK/err" || fail "the configuration with $1 was refused"
  jq -c '[.outbounds[] | select(.tag | startswith("main-1"))][0]' "$WORK/config.json"
}
expect() { # expect <link> <jq filter> <value>
  local got
  got="$(outbound "$1" | jq -r "$2")"
  [ "$got" = "$3" ] || fail "$1: $2 is '$got', expected '$3'"
}

expect 'trojan://pa%23ss@example.com:443#node' .password 'pa#ss'
expect 'trojan://pa%2Bss@example.com:443' .password 'pa+ss'
expect 'vless://11111111-2222-3333-4444-555555555555@example.com:443?type=ws&path=%2Fa%26b%3Fed%3D2048&security=tls' \
  .transport.path '/a&b?ed=2048'
expect 'hy2://pw@example.com:20000-30000' '.server_ports | join(",")' '20000:30000'
expect 'hy2://pw@example.com:443?mport=20000-30000' '.server_ports | join(",")' '20000:30000'
expect 'hy2://pw@example.com:443?obfs=none' '.obfs == null' 'true'
expect 'hy2://pw@example.com:443?upmbps=abc' '.up_mbps == null' 'true'

printf 'manual link parsing checks passed\n'
