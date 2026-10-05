#!/usr/bin/env bash
set -euo pipefail
# NET-6: intercept_client_dns decides whether client DNS to foreign servers
# goes to the router's dnsmasq: "1" always, "auto" while a section has the
# kill-switch, "0" never (the default since NET-12). A change of the decision changes the
# nft signatures, so a reload rebuilds the table (nft/apply.uc and
# service/state.uc agree). The packets are checked in nft_dataplane_real.sh.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$WORK/t.uc" <<'UC'
let c = require("config.connections");
let ks = { ".name": "a", action: "vpn", kill_switch: "1" };
let plain = { ".name": "b", action: "connection" };
let off_ks = { ".name": "c", action: "vpn", kill_switch: "1", enabled: "0" };
let dns = { ".name": "d", action: "dns", kill_switch: "1" };
let cases = [
    [ {}, [ ks ], false ], [ {}, [ plain ], false ],
    [ { intercept_client_dns: "auto" }, [ ks ], true ], [ { intercept_client_dns: "auto" }, [ plain ], false ],
    [ { intercept_client_dns: "auto" }, [ off_ks ], false ], [ { intercept_client_dns: "auto" }, [ dns ], false ],
    [ { intercept_client_dns: "auto" }, [ plain, ks ], true ],
    [ { intercept_client_dns: "1" }, [ plain ], true ], [ { intercept_client_dns: "0" }, [ ks ], false ],
    [ { intercept_client_dns: "bogus" }, [ ks ], false ]
];
for (let i = 0; i < length(cases); i++)
    if (c.client_dns_intercept_enabled(cases[i][0], cases[i][1]) !== cases[i][2]) {
        warn("case ", i, " gave ", c.client_dns_intercept_enabled(cases[i][0], cases[i][1]), "\n");
        exit(1);
    }
// NET-12: the excluded addresses by family; what is no address is ignored.
let ex = c.client_dns_intercept_exclusions({ intercept_client_dns_exclude: [ "185.10.20.30", "10.0.0.0/8", "2001:DB8::/32", "junk", "1.2.3.4/33" ] });
if (sprintf("%J", ex) != sprintf("%J", { v4: [ "185.10.20.30", "10.0.0.0/8" ], v6: [ "2001:db8::/32" ] })) {
    warn("exclusions ", ex, "\n");
    exit(1);
}
ex = c.client_dns_intercept_exclusions({ intercept_client_dns_exclude: "192.168.1.5 fd00::1" });
if (sprintf("%J", ex) != sprintf("%J", { v4: [ "192.168.1.5" ], v6: [ "fd00::1" ] })) {
    warn("exclusions from a string ", ex, "\n");
    exit(1);
}
UC
ucode -L "$LIB" "$WORK/t.uc" || fail "intercept_client_dns decision"

fixture() { # fixture <intercept value> <kill_switch>
  printf '{ "settings": { ".name": "settings", "source_network_interfaces": "br-lan", "intercept_client_dns": "%s" }, "sections": [ { ".name": "web", ".type": "section", "action": "vpn", "domain": [ "example.com" ], "kill_switch": "%s" } ] }\n' "$1" "$2"
}
sig() { # sig <module> <mode> <fixture>
  ucode -L "$LIB" "$LIB/$1" "$2" "$3"
}
fixture auto 1 >"$WORK/on.json"
fixture 0 1 >"$WORK/never.json"
sed 's/"intercept_client_dns": "auto"/"intercept_client_dns": "auto", "intercept_client_dns_exclude": [ "185.10.20.30" ]/' \
  "$WORK/on.json" >"$WORK/excluded.json"
for pair in apply.uc:nft-runtime-signature-fixture state.uc:nft-signature-fixture; do
  module="${pair%%:*}"
  if [ "$module" = apply.uc ]; then module="nft/$module"; else module="service/$module"; fi
  on="$(sig "$module" "${pair#*:}" "$WORK/on.json")" || fail "$module signature failed"
  never="$(sig "$module" "${pair#*:}" "$WORK/never.json")" || fail "$module signature failed"
  [ -n "$on" ] || fail "$module: empty signature"
  [ "$on" != "$never" ] || fail "$module: switching the intercept off must change the nft signature"
  excluded="$(sig "$module" "${pair#*:}" "$WORK/excluded.json")" || fail "$module signature failed"
  [ "$on" != "$excluded" ] || fail "$module: a new exclusion must change the nft signature"
done
# The validator refuses an exclusion that is no address or subnet.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod +x "$WORK/bin/logger"
validate() { # validate <exclusions JSON array>
  printf '{ "settings": { ".name": "settings", ".type": "settings", "config_path": "/tmp/sing-box/config.json", "dns_server": "1.1.1.1", "bootstrap_dns_server": "77.88.8.8", "service_listen_address": "127.0.0.1", "yacd_secret_key": "test-secret", "intercept_client_dns": "1", "intercept_client_dns_exclude": %s }, "section": [] }\n' "$1" >"$WORK/validate.json"
  PATH="$WORK/bin:$PATH" ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/validate.json" '{}' >"$WORK/validate.out" 2>&1
}
validate '[ "185.10.20.30", "192.168.1.0/24", "2001:db8::1" ]' || fail "valid exclusions refused: $(cat "$WORK/validate.out")"
for bad in '"8.8.8"' '"example.com"' '"1.2.3.4/33"'; do
  if validate "[ $bad ]"; then fail "exclusion $bad must be refused"; fi
  grep -q 'excluded from client DNS interception' "$WORK/validate.out" || fail "exclusion $bad: $(cat "$WORK/validate.out")"
done
echo "client_dns_intercept: OK"
