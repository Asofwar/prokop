#!/usr/bin/env bash
set -euo pipefail
# NET-6: intercept_client_dns decides whether client DNS to foreign servers
# goes to the router's dnsmasq: "auto" (default) while a section has the
# kill-switch, "1" always, "0" never. A change of the decision changes the
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
    [ {}, [ ks ], true ], [ {}, [ plain ], false ], [ {}, [ off_ks ], false ], [ {}, [ dns ], false ],
    [ { intercept_client_dns: "auto" }, [ plain, ks ], true ],
    [ { intercept_client_dns: "1" }, [ plain ], true ], [ { intercept_client_dns: "0" }, [ ks ], false ],
    [ { intercept_client_dns: "bogus" }, [ ks ], false ]
];
for (let i = 0; i < length(cases); i++)
    if (c.client_dns_intercept_enabled(cases[i][0], cases[i][1]) !== cases[i][2]) {
        warn("case ", i, " gave ", c.client_dns_intercept_enabled(cases[i][0], cases[i][1]), "\n");
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
for pair in apply.uc:nft-runtime-signature-fixture state.uc:nft-signature-fixture; do
  module="${pair%%:*}"
  if [ "$module" = apply.uc ]; then module="nft/$module"; else module="service/$module"; fi
  on="$(sig "$module" "${pair#*:}" "$WORK/on.json")" || fail "$module signature failed"
  never="$(sig "$module" "${pair#*:}" "$WORK/never.json")" || fail "$module signature failed"
  [ -n "$on" ] || fail "$module: empty signature"
  [ "$on" != "$never" ] || fail "$module: switching the intercept off must change the nft signature"
done
echo "client_dns_intercept: OK"
