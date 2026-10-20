#!/usr/bin/env bash
set -euo pipefail

# sing-box-extended 2.7.3 refuses the whole configuration for an xHTTP
# session ID table without a length or with room for fewer than 2^31 IDs,
# and for xmux max_connections together with max_concurrency (D4). The
# generator leaves such a setting out of the one outbound, with a warning;
# an older core used a table without a length as no table at all. With
# $PROKOP_TEST_SING_BOX_EXTENDED every result passes "sing-box check".

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# generate NAME EXTRA_JSON: the transport of the generated xHTTP outbound
# of a share link with that "extra", in $WORK/NAME.transport.json.
generate() {
  local extra
  extra="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$2")"
  cat >"$WORK/$1.fixture.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [ { ".name": "xh", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": [ "vless://00000000-0000-4000-8000-000000000003@x.example:443?security=tls&sni=x.example&type=xhttp&mode=packet-up&path=%2Fp&extra=$extra#XH" ] } ]
}
JSON
  mkdir -p "$WORK/$1.subscriptions" "$WORK/$1.persistent"
  TMP_SUBSCRIPTION_FOLDER="$WORK/$1.subscriptions" PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/$1.persistent" \
    ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/$1.fixture.json" "$WORK/$1.json" 127.0.0.1 0 1 '' 1.14.3-extended-2.7.3 2>"$WORK/$1.stderr" ||
    fail "the configuration of $1 was not generated: $(cat "$WORK/$1.stderr")"
  node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const t = c.outbounds.find((o) => o.transport && o.transport.type === "xhttp").transport;
    require("fs").writeFileSync(process.argv[2], JSON.stringify(t));' "$WORK/$1.json" "$WORK/$1.transport.json"
}
# has NAME KEY: whether the transport of NAME has KEY (a.b for nested keys).
has() {
  node -e '
    let v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    for (const k of process.argv[2].split(".")) v = v == null ? undefined : v[k];
    process.exit(v === undefined ? 1 : 0);' "$WORK/$1.transport.json" "$2"
}
refused() { grep -Fq "sing-box refuses for the whole configuration were left out: $2" "$WORK/$1.stderr"; }

generate nolength '{"sessionIDTable":"hex"}'
! has nolength session_id_table || fail "a table without a length was kept"
refused nolength session_id_table || fail "the left-out table was not reported: $(cat "$WORK/nolength.stderr")"

generate short '{"sessionIDTable":"hex","sessionIDLength":"4-4"}'
! has short session_id_table && ! has short session_id_length || fail "a table with room for 16^4 IDs was kept"

generate small '{"sessionIDTable":"number","sessionIDLength":"1-9"}'
! has small session_id_table || fail "a table with room for fewer than 2^31 IDs was kept"

generate enough '{"sessionIDTable":"number","sessionIDLength":"1-10"}'
has enough session_id_table && has enough session_id_length || fail "a table with room for 2^31 IDs was left out"
[ ! -s "$WORK/enough.stderr" ] || ! grep -Fq "refuses" "$WORK/enough.stderr" || fail "a valid table was reported"

generate custom '{"sessionIDTable":"abcdef","sessionIDLength":"8-16"}'
has custom session_id_table || fail "a custom table with enough room was left out"

generate xmux '{"xmux":{"maxConcurrency":"16-32","maxConnections":"4"}}'
has xmux xmux.max_concurrency && ! has xmux xmux.max_connections || fail "xmux kept max_connections with max_concurrency"
refused xmux xmux.max_connections || fail "the left-out xmux setting was not reported"

generate xmuxone '{"xmux":{"maxConnections":"4"}}'
has xmuxone xmux.max_connections || fail "xmux lost max_connections alone"

SBX="${PROKOP_TEST_SING_BOX_EXTENDED:-}"
if [ -z "$SBX" ] || [ ! -x "$SBX" ]; then
  printf 'xhttp_core_refused_settings: OK (real sing-box-extended not checked: set PROKOP_TEST_SING_BOX_EXTENDED)\n'
  exit 0
fi
for name in nolength short small enough custom xmux xmuxone; do
  node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const o = c.outbounds.find((x) => x.transport && x.transport.type === "xhttp");
    process.stdout.write(JSON.stringify({ outbounds: [o] }));' "$WORK/$name.json" >"$WORK/check-$name.json"
  "$SBX" check -c "$WORK/check-$name.json" >"$WORK/check.log" 2>&1 ||
    fail "sing-box-extended refused the $name outbound: $(cat "$WORK/check.log")"
done
echo "xhttp_core_refused_settings: OK"
