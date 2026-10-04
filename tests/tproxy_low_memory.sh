#!/usr/bin/env bash
set -euo pipefail

# B9: the opt-in low memory mode (settings.tproxy_low_memory) gives the
# tproxy inbounds TCP keep-alive and a 60 s UDP timeout, and turns TCP Fast
# Open off, so half-open client connections and idle UDP sessions do not pile
# up in sing-box on a small router. Off by default, the inbounds stay as they
# were. With $PROKOP_TEST_SING_BOX (or sing-box on PATH), the real binary
# accepts the generated inbounds.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
GENERATOR="$PROKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

generate() {
  local name="$1" settings="$2"
  cat >"$WORK_DIR/$name.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8"$settings },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": ["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain_suffix": ["example.com"] }
  ]
}
JSON
  ucode -L "$PROKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/$name.json" "$WORK_DIR/$name.config.json" 192.0.2.1 0 1 '' 1.12.0 ||
    fail "generator failed for $name"
}

# Each tproxy inbound as "tag fast_open keep_alive interval udp_timeout".
tproxy_inbounds() {
  ucode -e '
    let c = json(require("fs").readfile(ARGV[0]));
    function f(v) { return v == null ? "-" : "" + v; }
    for (let i in c.inbounds)
      if (i.type == "tproxy")
        print(join(" ", [ i.tag, f(i.tcp_fast_open), f(i.tcp_keep_alive), f(i.tcp_keep_alive_interval), f(i.udp_timeout) ]), "\n");
  ' "$WORK_DIR/$1.config.json"
}

generate default ""
generate off ', "tproxy_low_memory": "0"'
generate on ', "tproxy_low_memory": "1"'

[ -n "$(tproxy_inbounds default)" ] || fail "no tproxy inbound generated"
while read -r tag fast keep interval udp; do
  [ "$fast $keep $interval $udp" = "true - - -" ] || fail "default: $tag has '$fast $keep $interval $udp'"
done < <(tproxy_inbounds default)
[ "$(tproxy_inbounds off)" = "$(tproxy_inbounds default)" ] || fail "an explicit 0 differs from the default"
while read -r tag fast keep interval udp; do
  [ "$fast $keep $interval $udp" = "false 30s 15s 60s" ] || fail "low memory: $tag has '$fast $keep $interval $udp'"
done < <(tproxy_inbounds on)
[ "$(tproxy_inbounds on | wc -l)" = "$(tproxy_inbounds default | wc -l)" ] || fail "low memory changed the set of inbounds"

grep -q "^ *option tproxy_low_memory '0'$" "$ROOT_DIR/prokop/files/etc/config/prokop" ||
  fail "the default config does not carry tproxy_low_memory 0"

SING_BOX="${PROKOP_TEST_SING_BOX:-$(command -v sing-box 2>/dev/null || true)}"
if [ -z "$SING_BOX" ] || [ ! -x "$SING_BOX" ]; then
  printf 'tproxy_low_memory: OK (real sing-box not checked: set PROKOP_TEST_SING_BOX)\n'
  exit 0
fi
# The real binary decodes the inbounds strictly: an unknown field fails.
ucode -e '
  let c = json(require("fs").readfile(ARGV[0]));
  let out = [];
  for (let i in c.inbounds) if (i.type == "tproxy") push(out, i);
  print(sprintf("%J", { inbounds: out }), "\n");
' "$WORK_DIR/on.config.json" >"$WORK_DIR/inbounds.json"
"$SING_BOX" check -c "$WORK_DIR/inbounds.json" || fail "real sing-box refused the low memory inbounds"
echo "tproxy_low_memory: OK"
