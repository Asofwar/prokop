#!/usr/bin/env bash
set -euo pipefail

# The sing-box part of the reload signature (service/state.uc) must read each
# DNS setting the way the runtime does, or a change the runtime would see is
# not applied by reload:
# - an absent dns_type is plain UDP for the runtime (singbox/dns.uc
#   state_template, the validator, LuCI and the shipped config) and was DoH
#   for the signature: setting DoH on a config without dns_type left the
#   signature unchanged, the reload skipped sing-box and the runtime kept
#   UDP until a restart (UC-088);
# - dns_failover_failure_threshold, read by the DNS failover worker
#   (singbox/dns_failover.uc), was not in the signature: a changed threshold
#   was not applied by reload (UC-095). The worker is restarted with
#   sing-box, so the threshold belongs to the sing-box signature.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# signature <name> <settings JSON members>: the sing-box signature of a config
# with one Connection rule and these settings.
signature() {
  local name="$1" members="$2"
  printf '{ "settings": { ".name": "settings", ".type": "settings"%s }, "section": [ { ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection", "selector_proxy_links": "vless://id@example.com:443", "domain_suffix": [ "example.org" ] } ] }\n' \
    "${members:+, $members}" >"$WORK/$name.json"
  ucode -L "$LIB" "$LIB/service/state.uc" sing-box-signature-fixture "$WORK/$name.json"
}

absent="$(signature absent '')"
udp="$(signature udp '"dns_type": "udp"')"
doh="$(signature doh '"dns_type": "doh"')"
dot="$(signature dot '"dns_type": "dot"')"

{ [ -n "$absent" ] && [ -n "$udp" ]; } || fail "precondition: the signature is computed"
[ "$absent" = "$udp" ] ||
  fail "an absent dns_type must sign like udp, the runtime default (absent=$absent udp=$udp)"
[ "$absent" != "$doh" ] ||
  fail "setting dns_type doh on a config without dns_type must change the sing-box signature"
{ [ "$udp" != "$dot" ] && [ "$doh" != "$dot" ]; } ||
  fail "each DNS protocol must sign differently"

runtime_default="$(ucode -L "$LIB" -e 'print(require("singbox.dns").state_template({}).dns_type, "\n");')"
[ "$runtime_default" = udp ] ||
  fail "precondition: the runtime reads an absent dns_type as udp, got '$runtime_default'"

threshold_absent="$(signature threshold_absent '')"
threshold_default="$(signature threshold_default '"dns_failover_failure_threshold": "3"')"
threshold_changed="$(signature threshold_changed '"dns_failover_failure_threshold": "5"')"
[ "$threshold_absent" = "$threshold_default" ] ||
  fail "an absent dns_failover_failure_threshold must sign like its default 3"
[ "$threshold_default" != "$threshold_changed" ] ||
  fail "a changed dns_failover_failure_threshold must change the sing-box signature, or reload does not restart the DNS failover worker with it"

if [ "$failures" -ne 0 ]; then
  printf '%d reload signature check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'sing-box reload signature reads dns_type and the failover threshold like the runtime\n'
