#!/usr/bin/env bash
set -euo pipefail

# A '+' in the userinfo of a share link is part of the password (SB-1, SB-9).
# The userinfo went through form decoding, which turns '+' into a space:
# trojan://pa+ss@ became password "pa ss", an ss:// link in standard base64
# lost its '+' and could not be read, and Prokop's own ss:// links did not
# parse back to the same password. Nodes looked fine and never connected.
# The userinfo is percent-decoded only (RFC 3986), once, and ss:// links are
# written in URL-safe base64 (SIP002).
#
# subscription/parser.uc and share_link.uc run for real.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

field() { # field <link> <jq filter>
  local out
  out="$(ucode -L "$LIB" "$LIB/subscription/parser.uc" share-link-outbound "$1" t)" || fail "the link $1 was refused"
  jq -r "$2" <<<"$out"
}
expect() { # expect <link> <jq filter> <value>
  local got
  got="$(field "$1" "$2")"
  [ "$got" = "$3" ] || fail "$1: $2 is '$got', expected '$3'"
}

expect 'trojan://pa+ss@example.com:443' .password 'pa+ss'
expect 'hy2://pa+ss@example.com:443' .password 'pa+ss'
expect 'trojan://pa%2Bss%23x@example.com:443' .password 'pa+ss#x'
expect 'ss://2022-blake3-aes-128-gcm:AbC+dEf/gh==@example.com:443' .password 'AbC+dEf/gh=='
# Standard base64 of aes-256-gcm:p>> and aes-256-gcm:p~~~.
expect 'ss://YWVzLTI1Ni1nY206cD4+@example.com:443' .password 'p>>'
expect 'ss://YWVzLTI1Ni1nY206cH5+fg==@example.com:443' .password 'p~~~'
# SOCKS: split before decoding, decoded once.
expect 'socks5://us%3Aer:p+a%2525ss@example.com:1080' .username 'us:er'
expect 'socks5://us%3Aer:p+a%2525ss@example.com:1080' .password 'p+a%25ss'

# Prokop's own ss:// link parses back to the same password.
link="$(ucode -L "$LIB" -e '
  let sl = require("subscription.share_link");
  print(sl.serialize_outbound_link({ type: "shadowsocks", tag: "n", server: "example.com", server_port: 443,
    method: "aes-256-gcm", password: "p>>?~" }));')"
case "$link" in ss://*[+/]*@*) fail "the ss:// link is not URL-safe base64: $link" ;; esac
expect "$link" .password 'p>>?~'

printf 'share link userinfo checks passed\n'
