#!/usr/bin/env bash
set -euo pipefail

# Direct Proxy is switched on and off by the ordinary reload, not by a
# restart (components/action.uc set_direct_proxy, U2). That holds because
# the setting is read by the sing-box configuration only:
#
# 1. the generated configuration has the direct-proxy inbound, its route
#    rule and its outbound when the setting is on, and none of them when it
#    is off (singbox/generator.uc add_direct_proxy);
# 2. between the two states only the sing-box signature changes, so the
#    reload plan regenerates and replaces sing-box and leaves nft, dnsmasq,
#    the DPI providers, cron and the lists alone (service/reload.uc);
# 3. the reload reason answers "queued" and "stopped" to the action
#    (service/initd.uc QUEUE_ACK_REASONS, STOP_ACK_REASONS).
#
# The action's paths (applied, failed and rolled back, queued, overtaken by
# the user's stop, refused over another sing-box) are in
# component_restart_own_stop.sh, component_change_user_stop.sh and
# start_result_wait.sh.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
SING_BOX="${PROKOP_TEST_SING_BOX:-/home/user/sb/sing-box-1.14.2}"

fixture() {
  cat >"$W/f$1.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8",
    "direct_proxy_enabled": "$1", "direct_proxy_port": "$2" },
  "section": [ { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
    "outbound_jsons": ["{\"type\":\"direct\",\"tag\":\"node\"}"], "domain_suffix": ["a.example"] } ]
}
JSON
}
fixture 0 2080
fixture 1 2080

# 1. The configuration.
for on in 0 1; do
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$W/f$on.json" "$W/config$on.json" 192.0.2.1 0 1 '' 1.14.2 >/dev/null 2>"$W/gen$on.log" ||
    fail "the configuration with direct_proxy_enabled=$on was not generated: $(cat "$W/gen$on.log")"
  found="$(ucode -e '
    let c = json(require("fs").readfile(ARGV[0]));
    let n = 0;
    for (let i in c.inbounds || []) if (i.tag == "direct-proxy-in" && i.listen_port == 2080) n++;
    for (let o in c.outbounds || []) if (o.tag == "direct-proxy-out") n++;
    for (let r in c.route.rules || []) if (r.inbound == "direct-proxy-in") n++;
    print(n);' -- "$W/config$on.json")"
  if [ "$on" = 1 ]; then
    [ "$found" = 3 ] || fail "Direct Proxy on: the inbound, its outbound and its route rule are not all there ($found)"
  else
    [ "$found" = 0 ] || fail "Direct Proxy off: the configuration still has its inbound, outbound or route ($found)"
  fi
  if [ -x "$SING_BOX" ]; then
    "$SING_BOX" check -c "$W/config$on.json" >"$W/check$on.log" 2>&1 ||
      fail "sing-box check refused the configuration with direct_proxy_enabled=$on: $(cat "$W/check$on.log")"
  fi
done

# 2. The reload plan, both ways and for a changed port, with and without a
#    forced reload.
fixture 1 3128 && mv "$W/f1.json" "$W/fport.json" && fixture 1 2080
for name in 0 1 port; do
  ucode -L "$LIB" "$LIB/service/state.uc" reload-state-text-fixture "$W/f$name.json" >"$W/state$name" ||
    fail "no reload state for $name"
done
plan() {
  ucode -L "$LIB" "$LIB/service/reload.uc" plan-state-files "$W/state$1" "$W/state$2" "$3" 0 0 0 0 >"$W/plan" ||
    fail "no reload plan $1 -> $2"
  local expected actual
  expected="$(printf '%s\n' changed_sing_box=1 needs_sing_box_reload=1 has_work=1)"
  actual="$(awk -F'\t' '$1 ~ /^(changed|needs)_/ && $2 == 1 || $1 == "has_work" && $2 == 1 { print $1 "=" $2 }' "$W/plan")"
  [ "$actual" = "$expected" ] || fail "toggling Direct Proxy ($1 -> $2, force=$3) plans more than a sing-box reload: $actual"
}
for force in 0 1; do
  plan 0 1 "$force"
  plan 1 0 "$force"
  plan 1 port "$force"
done

# 3. The reload reason.
grep -Eq '^const QUEUE_ACK_REASONS = \[.*"direct-proxy"' "$LIB/service/initd.uc" ||
  fail "a queued Direct Proxy reload is not reported to the action"
grep -Eq '^const STOP_ACK_REASONS = \[.*"direct-proxy"' "$LIB/service/initd.uc" ||
  fail "a Direct Proxy reload skipped after the user's stop is not reported to the action"
grep -q 'const DIRECT_PROXY_RELOAD_REASON = "direct-proxy";' "$LIB/components/action.uc" ||
  fail "the action does not reload with the direct-proxy reason"
if awk '/^function set_direct_proxy\(/,/^}/' "$LIB/components/action.uc" | grep -q 'prokop_restart_and_wait'; then
  fail "set_direct_proxy still restarts Prokop"
fi

printf 'direct_proxy_reload: OK\n'
