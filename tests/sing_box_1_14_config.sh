#!/usr/bin/env bash
set -euo pipefail

# sing-box 1.14 deprecates fields that 1.16.0 removes; a configuration that
# still has one then fails to start. For sing-box 1.14 and newer the main
# and the list bootstrap configuration must carry none of them:
# - remote rule sets download through a top-level http_clients entry
#   (http_client: the download proxy's client, whose detour is that rule's
#   outbound, as download_detour was), never download_detour;
# - route.default_http_client names an explicit client (no implicit default
#   HTTP client); it has no detour, so it dials like direct-out;
# - no dns.independent_cache, no cache_file.store_rdrc, no strategy in a DNS
#   rule, no rule_set_ip_cidr_accept_empty, and an address filter
#   (ip_cidr / ip_is_private) in a DNS rule only with match_response.
# The low memory mode caps UDP NAT sessions of the tproxy inbounds
# (udp_nat_max) on 1.14 and newer only.
# Older cores (1.12, 1.13, unknown version) keep the old output.
#
# With $PROKOP_TEST_SING_BOX (1.14 or newer): "sing-box check" accepts every
# 1.14 configuration and prints no warning (deprecations are written to
# stderr). Most deprecations are only reported when sing-box starts, so the
# configuration is also started (inbounds moved to free loopback ports, the
# rule sets served by a local HTTP server, the download proxy a second
# sing-box) until "sing-box started", and must report nothing deprecated.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

pids=()
cleanup() {
  owned_kill KILL "${pids[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
  [ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$WORK/proxied.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings",
    "dns_type": "dot", "dns_server": ["1.1.1.1", "8.8.8.8"], "bootstrap_dns_server": ["77.88.8.8", "9.9.9.9"],
    "yacd_secret_key": "test-clash-secret", "service_listen_address": "127.0.0.1",
    "download_lists_via_proxy": "1", "download_lists_via_proxy_section": "proxy",
    "tproxy_low_memory": "1", "dns_client_subnet": "203.0.113.0/24"
  },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":1080}",
      "domain_suffix": ["example.org"], "community_lists": ["discord"],
      "rule_set": ["https://example.com/geoip-test.srs", "https://example.com/domains-test.json"],
      "excluded_source_ip_cidr": ["192.168.1.50/32"] },
    { ".name": "dnsrule", ".type": "section", "enabled": "1", "action": "dns", "dns_type": "doh",
      "dns_server": "1.1.1.1/dns-query", "domain_suffix": ["internal.example"] },
    { ".name": "bypass", ".type": "section", "enabled": "1", "action": "bypass",
      "fully_routed_ips": ["192.168.1.20/32"], "source_ip_cidr": ["192.168.1.30/32"],
      "domain_suffix": ["direct.example"] }
  ]
}
JSON
cat >"$WORK/direct.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"],
    "yacd_secret_key": "test-clash-secret", "service_listen_address": "127.0.0.1"
  },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":1080}",
      "community_lists": ["discord"], "rule_set": ["https://example.com/geoip-test.srs"] }
  ]
}
JSON

generator() { ucode -L "$LIB" "$LIB/singbox/generator.uc" "$@"; }
generate() { # fixture version output
  mkdir -p "$3.section-cache" "$3.rulesets"
  generator generate-config-fixture "$1" "$3" 127.0.0.1 0 1 '' "$2" >"$3.err" 2>&1 ||
    fail "generation of $(basename "$1") for '$2' failed: $(cat "$3.err")"
}
bootstrap() { # fixture version output
  SB_SERVICE_MIXED_INBOUND_PORT=45399 generator generate-list-bootstrap-config-fixture "$1" "$3" \
    127.0.0.1 0 1 '' "$2" "$3.scratch" >"$3.err" 2>&1 ||
    fail "list bootstrap generation for '$2' failed: $(cat "$3.err")"
}

cat >"$WORK/audit.uc" <<'UC'
let fs = require("fs");
let path = ARGV[0], modern = ARGV[1] == "1", low_memory = ARGV[2] == "1";
let c = json(fs.readfile(path));
let errors = [];
function err(m) { push(errors, m); }

function walk(value, visit) {
    visit(value);
    if (type(value) == "object")
        for (let k, v in value) walk(v, visit);
    else if (type(value) == "array")
        for (let v in value) walk(v, visit);
}
let has_download_detour = false;
walk(c, v => { if (type(v) == "object" && "download_detour" in v) has_download_detour = true; });
let remote = filter(c.route?.rule_set ?? [], r => r.type == "remote");
let tproxy = filter(c.inbounds ?? [], i => i.type == "tproxy");

if (modern) {
    if (has_download_detour) err("download_detour on 1.14");
    if (type(c.http_clients) != "array" || length(c.http_clients) == 0) err("no http_clients on 1.14");
    let clients = {};
    for (let h in c.http_clients ?? []) clients[h.tag] = h;
    let def = c.route?.default_http_client;
    if (!def || !clients[def]) err("route.default_http_client does not name an http client: " + def);
    else if (clients[def].detour != null) err("the default http client has a detour");
    let outbounds = {};
    for (let o in c.outbounds ?? []) outbounds[o.tag] = o;
    for (let h in c.http_clients ?? [])
        if (h.detour != null && !outbounds[h.detour]) err("http client " + h.tag + " detours to a missing outbound");
    for (let r in remote)
        if (r.http_client != null && !clients[r.http_client]) err("rule set " + r.tag + " names a missing http client");
    if ("independent_cache" in (c.dns ?? {})) err("dns.independent_cache on 1.14");
    walk(c.experimental ?? {}, v => { if (type(v) == "object" && "store_rdrc" in v) err("store_rdrc on 1.14"); });
    function dns_rule(rule, top) {
        if ("strategy" in rule) err("strategy in a DNS rule");
        if ("rule_set_ip_cidr_accept_empty" in rule) err("rule_set_ip_cidr_accept_empty in a DNS rule");
        if (("ip_cidr" in rule || "ip_is_private" in rule) && rule.match_response !== true)
            err("address filter without match_response in a DNS rule: " + sprintf("%J", rule));
        for (let sub in rule.rules ?? []) dns_rule(sub, false);
    }
    for (let rule in c.dns?.rules ?? []) dns_rule(rule, true);
    for (let i in tproxy) {
        let want = low_memory ? 2048 : null;
        if (i.udp_nat_max != want) err("tproxy " + i.tag + " udp_nat_max " + i.udp_nat_max + ", want " + want);
    }
}
else {
    if ("http_clients" in c) err("http_clients before 1.14");
    if ("default_http_client" in (c.route ?? {})) err("route.default_http_client before 1.14");
    for (let r in remote)
        if ("http_client" in r) err("http_client on rule set " + r.tag + " before 1.14");
    for (let i in tproxy)
        if ("udp_nat_max" in i) err("udp_nat_max before 1.14");
}
if (length(errors) > 0) { warn(join("\n", errors), "\n"); exit(1); }
// What the case checks print: the clients of the remote rule sets.
print(join(" ", map(remote, r => r.tag + "=" + (r.http_client ?? r.download_detour ?? "-"))), "\n");
UC
audit() { ucode "$WORK/audit.uc" "$@"; }

# ---- 1.14 and newer -------------------------------------------------------
for version in 1.14.2 1.14.0-beta.3 1.15.1 1.14.2-extended-2.7.2; do
  generate "$WORK/proxied.json" "$version" "$WORK/proxied-$version.config"
  out="$(audit "$WORK/proxied-$version.config" 1 1)" || fail "$version: the proxied configuration has deprecated fields"
  expected="proxy-discord-community-ruleset=proxy-out-http inline-custom-$(ucode -L "$LIB" -e 'print(require("singbox.rulesets").hash12("https://example.com/geoip-test.srs"))')-ruleset=proxy-out-http inline-custom-$(ucode -L "$LIB" -e 'print(require("singbox.rulesets").hash12("https://example.com/domains-test.json"))')-ruleset=proxy-out-http"
  [ "$out" = "$expected" ] || fail "$version: rule sets do not download through the proxy client:
expected: $expected
actual:   $out"
  detour="$(ucode -e 'let c = json(require("fs").readfile(ARGV[0])); for (let h in c.http_clients) if (h.tag == "proxy-out-http") print(h.detour);' "$WORK/proxied-$version.config")"
  [ "$detour" = proxy-out ] || fail "$version: the proxy client goes through '$detour', not proxy-out"

  generate "$WORK/direct.json" "$version" "$WORK/direct-$version.config"
  out="$(audit "$WORK/direct-$version.config" 1 0)" || fail "$version: the direct configuration has deprecated fields"
  case "$out" in *"=-"*) ;; *) fail "$version: a rule set without a download proxy named a client: $out" ;; esac
  case "$out" in *"=proxy"*|*"-http"*) fail "$version: a rule set without a download proxy named a client: $out" ;; esac

  bootstrap "$WORK/proxied.json" "$version" "$WORK/bootstrap-$version.config"
  audit "$WORK/bootstrap-$version.config" 1 0 >/dev/null || fail "$version: the list bootstrap configuration has deprecated fields"
done

# ---- older cores keep their output -------------------------------------------
for version in 1.12.0 1.13.5 ""; do
  generate "$WORK/proxied.json" "$version" "$WORK/proxied-old$version.config"
  out="$(audit "$WORK/proxied-old$version.config" 0 1)" || fail "'$version': the old output changed"
  case "$out" in *"=proxy-out "*"=proxy-out "*"=proxy-out") ;; *) fail "'$version': download_detour lost: $out" ;; esac
  bootstrap "$WORK/proxied.json" "$version" "$WORK/bootstrap-old$version.config"
  audit "$WORK/bootstrap-old$version.config" 0 0 >/dev/null || fail "'$version': the old bootstrap output changed"
done
# Below 1.14 only download_detour, independent_cache and the old DNS rules
# differ from the 1.14 output: no 1.14 field leaks into the old one.
grep -q '"independent_cache": true' "$WORK/proxied-old1.13.5.config" || fail "1.13 lost dns.independent_cache"

# ---- the real sing-box ----------------------------------------------------
SING_BOX="${PROKOP_TEST_SING_BOX:-$(command -v sing-box 2>/dev/null || true)}"
if [ -z "$SING_BOX" ] || [ ! -x "$SING_BOX" ]; then
  printf 'SKIP: sing_box_1_14_config: real sing-box not checked (set PROKOP_TEST_SING_BOX)\n'
  printf 'sing_box_1_14_config: PASS\n'
  exit 0
fi
version="$("$SING_BOX" version 2>/dev/null | sed -n '1s/.* version //p')"
case "$version" in
  1.1[4-9].*|1.[2-9][0-9].*|[2-9].*) ;;
  *) printf 'SKIP: sing-box %s predates 1.14\n' "$version"; printf 'sing_box_1_14_config: PASS\n'; exit 0 ;;
esac

configs=("$WORK/proxied-1.14.2.config" "$WORK/direct-1.14.2.config" "$WORK/bootstrap-1.14.2.config")
for config in "${configs[@]}"; do
  "$SING_BOX" check -c "$config" >"$WORK/check.out" 2>&1 ||
    fail "sing-box $version refuses $(basename "$config"): $(cat "$WORK/check.out")"
  if grep -Eiq 'deprecated|WARN|ERROR|FATAL' "$WORK/check.out"; then
    fail "sing-box $version warns about $(basename "$config"): $(cat "$WORK/check.out")"
  fi
done

if ! command -v python3 >/dev/null 2>&1; then
  printf 'SKIP: sing_box_1_14_config: no python3 to serve the rule sets; start not checked\n'
  printf 'sing_box_1_14_config: PASS\n'
  exit 0
fi

# Rule sets of the kind each one stands for: domains, addresses or both.
mkdir -p "$WORK/www"
printf '{"version":3,"rules":[{"domain_suffix":["example.org"]}]}' >"$WORK/www/domains.json"
printf '{"version":3,"rules":[{"ip_cidr":["203.0.113.0/24"]}]}' >"$WORK/www/ips.json"
printf '{"version":3,"rules":[{"domain_suffix":["example.org"]},{"ip_cidr":["203.0.113.0/24"]}]}' >"$WORK/www/mixed.json"
for kind in domains ips mixed; do
  "$SING_BOX" rule-set compile -o "$WORK/www/$kind.srs" "$WORK/www/$kind.json" ||
    fail "sing-box could not compile the $kind rule set"
done
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
HTTP_PORT="$(free_port)"
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK/www" >"$WORK/http.log" 2>&1 &
pids+=("$!")
SOCKS_PORT="$(free_port)"
printf '{"log":{"level":"info"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":%s}],"outbounds":[{"type":"direct"}]}\n' \
  "$SOCKS_PORT" >"$WORK/socks.json"
"$SING_BOX" run -c "$WORK/socks.json" >"$WORK/socks.log" 2>&1 &
pids+=("$!")
# A test namespace whose loopback is down (no `ip` to bring it up) cannot
# connect even to 127.0.0.1: the start is then not checked.
loopback_ok() {
  python3 - "$HTTP_PORT" <<'PY'
import socket, sys, time
for _ in range(50):
    try:
        socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()
        sys.exit(0)
    except OSError as e:
        if getattr(e, "errno", None) == 101:
            sys.exit(2)
        time.sleep(0.1)
sys.exit(1)
PY
}
rc=0
loopback_ok || rc=$?
if [ "$rc" = 2 ]; then
  printf 'SKIP: sing_box_1_14_config: loopback is down in this namespace; start not checked\n'
  printf 'sing_box_1_14_config: PASS\n'
  exit 0
fi
[ "$rc" = 0 ] || fail "the local rule set server did not start: $(cat "$WORK/http.log")"

# The probe copy: inbounds on free loopback ports (a tproxy inbound becomes
# a mixed one of the same tag), no marks or interfaces (no privileges), the
# download proxy and the rule sets local. Every other field stays.
cat >"$WORK/probe.py" <<'PY'
import json, socket, sys
src, dst, work, http_port, socks_port = sys.argv[1:6]
c = json.load(open(src))
# "sing-box started" is an info line.
c["log"] = {"disabled": False, "level": "info", "timestamp": False}
def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p
for i in c.get("inbounds", []):
    if i["type"] == "tproxy":
        for k in list(i):
            if k not in ("type", "tag"):
                del i[k]
        i["type"] = "mixed"
    i["listen"] = "127.0.0.1"
    i["listen_port"] = free_port()
for o in c.get("outbounds", []):
    o.pop("routing_mark", None); o.pop("bind_interface", None)
    if o.get("type") in ("socks", "http"):
        o["server"] = "127.0.0.1"; o["server_port"] = int(socks_port)
route = c.get("route", {})
for k in ("auto_detect_interface", "default_mark", "default_interface"):
    route.pop(k, None)
for r in route.get("rule_set", []):
    if r.get("type") != "remote":
        continue
    url = r["url"]
    kind = "mixed" if "discord" in url else "ips" if "geoip" in url else "domains"
    r["url"] = "http://127.0.0.1:%s/%s.%s" % (http_port, kind, "json" if r.get("format") == "source" else "srs")
exp = c.get("experimental", {})
if "cache_file" in exp:
    exp["cache_file"]["path"] = work + "/cache-" + str(free_port()) + ".db"
if "clash_api" in exp:
    exp["clash_api"]["external_controller"] = "127.0.0.1:%d" % free_port()
json.dump(c, open(dst, "w"), indent=1)
PY

for config in "${configs[@]}"; do
  name="$(basename "$config")"
  python3 "$WORK/probe.py" "$config" "$WORK/$name.run" "$WORK" "$HTTP_PORT" "$SOCKS_PORT"
  "$SING_BOX" run -c "$WORK/$name.run" >"$WORK/$name.log" 2>&1 &
  pid=$!
  pids+=("$pid")
  started=0
  for _ in $(seq 1 100); do
    if grep -q 'sing-box started' "$WORK/$name.log"; then started=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  owned_kill TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$started" = 1 ] || fail "sing-box $version did not start from $name: $(cat "$WORK/$name.log")"
  if grep -Eiq 'deprecated|FATAL' "$WORK/$name.log"; then
    fail "sing-box $version reports a deprecated feature for $name: $(grep -Ei 'deprecated|FATAL' "$WORK/$name.log")"
  fi
done
# The rule sets were really downloaded through the HTTP clients.
grep -q 'GET /mixed.srs' "$WORK/http.log" || fail "no rule set was downloaded: $(cat "$WORK/http.log")"

printf 'sing_box_1_14_config: PASS\n'
