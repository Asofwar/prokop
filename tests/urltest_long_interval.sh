#!/usr/bin/env bash
set -euo pipefail
# A2: sing-box refuses a URLTest group whose interval is longer than its
# idle_timeout (30m unless set). A group with a longer interval and no
# idle_timeout of its own gets the interval as idle_timeout, whatever its id;
# a shorter idle_timeout of its own, in a rule or a dashboard override, is
# refused by the validator.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod +x "$WORK/bin/logger"

# fixture <file> <urltest JSON objects...>: rule "proxy" with these groups.
fixture() {
  local path="$1"
  shift
  node - "$path" "$@" <<'JS'
const fs = require('fs');
const [path, ...groups] = process.argv.slice(2);
fs.writeFileSync(path, JSON.stringify({
  settings: { '.name': 'settings', '.type': 'settings', log_level: 'warn', dns_server: [ '77.88.8.8' ],
    bootstrap_dns_server: [ '77.88.8.8' ], yacd_secret_key: 'test-clash-secret' },
  section: [ { '.name': 'proxy', '.type': 'section', enabled: '1', action: 'proxy',
    selector_proxy_links: [
      'vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#first',
      'vless://00000000-0000-4000-8000-000000000002@example.org:443?encryption=none&security=tls&sni=example.org#second' ] } ],
  urltest: groups.map((value, index) => Object.assign({ '.name': 'cfg01000' + index, '.type': 'urltest',
    section: 'proxy', name: 'Group ' + index, tolerance: '50', testing_url: 'https://example.com/204' }, JSON.parse(value)))
}));
JS
}

fixture "$WORK/long.json" '{"check_interval":"1h30m"}' '{"check_interval":"45m"}' '{"check_interval":"5m"}' \
  '{"check_interval":"2h","idle_timeout":"3h"}'
mkdir -p "$WORK/out.json.section-cache"
ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/long.json" "$WORK/out.json" "127.0.0.1" ||
  fail "the generator failed"
node - "$WORK/out.json" <<'JS' || fail "idle_timeout of long URLTest intervals"
const assert = require('assert');
const cfg = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const group = (n) => cfg.outbounds.find((o) => o.tag === `proxy-urltest-cfg01000${n}-out`);
assert.equal(group(0).idle_timeout, '1h30m', 'an interval of 1h30m gets it as idle_timeout');
assert.equal(group(1).idle_timeout, '45m', 'an interval of 45m gets it as idle_timeout');
assert.equal(group(2).idle_timeout, undefined, 'a short interval keeps sing-box default');
assert.equal(group(3).idle_timeout, '3h', 'an idle_timeout of its own stays');
JS

validate() {
  PATH="$WORK/bin:$PATH" ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$1" '{}'
}
validate "$WORK/long.json" >/dev/null 2>&1 || fail "long intervals without an idle_timeout must be accepted"
fixture "$WORK/short-idle.json" '{"check_interval":"1h","idle_timeout":"10m"}'
if out="$(validate "$WORK/short-idle.json" 2>&1)"; then
  fail "an idle_timeout shorter than the interval must be refused"
fi
grep -Fq "is shorter than its check interval 1h" <<<"$out" || fail "unexpected refusal: $out"

# A dashboard override writes both values: the same rule applies.
node - "$WORK/long.json" "$WORK/override.json" <<'JS'
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
cfg.urltest_override = [ { '.name': 'cfg090000', '.type': 'urltest_override', rule: 'proxy', tag: 'Group 0',
  testing_url: 'https://example.com/204', check_interval: '2h', tolerance: '50', idle_timeout: '30m',
  interrupt_exist_connections: '1' } ];
fs.writeFileSync(process.argv[3], JSON.stringify(cfg));
JS
if out="$(validate "$WORK/override.json" 2>&1)"; then
  fail "an override with an idle_timeout shorter than its interval must be refused"
fi
grep -Fq "URLTest override 'Group 0' of rule 'proxy' is shorter than its check interval 2h" <<<"$out" ||
  fail "unexpected override refusal: $out"

echo "urltest_long_interval: OK"
