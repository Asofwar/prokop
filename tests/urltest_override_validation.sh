#!/usr/bin/env bash
set -eo pipefail

# Dashboard URLTest overrides (config urltest_override: rule, tag, settings)
# replace the settings of a URLTest group of a rule in the generated config.
# The dashboard saved them before the validator read them, so the validator
# refuses only a value with which sing-box does not load the generated
# config and warns about the rest: an override that started before keeps
# starting and generates the same config (invariant 17). The dashboard took a
# tolerance up to 65535, which sing-box reads as uint16, and a testing URL
# without a host. An override that no rule uses (the rule was deleted before
# overrides went with it, is disabled or is no longer a Connection rule) is
# never applied and never refuses the configuration (UC-151).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
VALIDATOR="$PROKOP_LIB/config/validator.uc"
# The last commit before the validator read the overrides.
BASELINE_REF="${PROKOP_URLTEST_OVERRIDE_BASELINE_REF:-5eaa93491b4d4435a474708dc0670416305ebc8a}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The validator logs a warning with logger.
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$LOGGER_LOG"
SH
chmod 0755 "$WORK_DIR/bin/logger"
export LOGGER_LOG="$WORK_DIR/logger.log"

# fixture <name> <override JSON objects...>
fixture() {
  local name="$1"
  shift
  node - "$WORK_DIR/$name.json" "$@" <<'JS'
const fs = require('fs');
const [path, ...overrides] = process.argv.slice(2);
const rule = (name, values) => Object.assign({ '.name': name, '.type': 'section', enabled: '1',
  action: 'connection', selector_proxy_links: [ 'socks5://10.0.0.1:1080' ] }, values);
fs.writeFileSync(path, JSON.stringify({
  settings: { '.name': 'settings', '.type': 'settings', dns_server: [ '77.88.8.8' ],
    bootstrap_dns_server: [ '77.88.8.8' ], yacd_secret_key: 'test-clash-secret' },
  section: [
    rule('main'),
    rule('off', { enabled: '0' }),
    rule('blocked', { action: 'block', selector_proxy_links: undefined, community_lists: [ 'youtube' ] })
  ],
  urltest_override: overrides.map((value, index) => Object.assign({ '.name': 'cfg0' + index + '0000',
    '.type': 'urltest_override', testing_url: 'https://example.com/generate_204', check_interval: '70s',
    tolerance: '175', idle_timeout: '30m', interrupt_exist_connections: '1' }, JSON.parse(value)))
}));
JS
}

validate() {
  : >"$LOGGER_LOG"
  PATH="$WORK_DIR/bin:$PATH" ucode -L "$PROKOP_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/$1.json" '{}'
}

# accepts <fixture>: valid, and no warning about an override.
accepts() {
  local output
  output="$(validate "$1" 2>&1)" || fail "$1 must be accepted, got: $output"
  if grep -Fq 'URLTest override' "$LOGGER_LOG"; then
    fail "$1 must not warn, got: $(cat "$LOGGER_LOG")"
  fi
}

# warns <fixture> <message>: valid, with a warning containing the message.
warns() {
  local output
  output="$(validate "$1" 2>&1)" || fail "$1 must start with a warning, got: $output"
  grep -F '[warn]' "$LOGGER_LOG" | grep -Fq "$2" ||
    fail "$1: expected a warning containing '$2', got '$(cat "$LOGGER_LOG")'"
}

rejects() {
  local output
  if output="$(validate "$1" 2>&1)"; then
    fail "$1 must be rejected"
  fi
  printf '%s\n' "$output" | grep -Fq "$2" ||
    fail "$1: expected a message containing '$2', got '$output'"
}

fixture valid '{"rule":"main","tag":"Flint Auto"}' \
  '{"rule":"main","tag":"main-urltest-ut_1a2b3c4d-out","interrupt_exist_connections":"0","tolerance":"0"}' \
  '{"rule":"main","tag":"Flint Fallback","interrupt_exist_connections":"","tolerance":"10000"}'
accepts valid

# The dashboard saved a tolerance up to 65535; sing-box takes it.
fixture dashboard_tolerance '{"rule":"main","tag":"Flint Auto","tolerance":"10001"}' \
  '{"rule":"main","tag":"Flint Fallback","tolerance":"20000"}' \
  '{"rule":"main","tag":"main-urltest-out","tolerance":"65535"}'
accepts dashboard_tolerance

# Nothing applies these: they never refuse the configuration.
fixture orphans \
  '{"rule":"gone","tag":"Flint Auto","testing_url":"","check_interval":"soon","tolerance":"-1"}' \
  '{"rule":"off","tag":"Flint Auto","testing_url":"ftp://example.com","idle_timeout":""}' \
  '{"rule":"blocked","tag":"Flint Auto","interrupt_exist_connections":"yes"}' \
  '{"tag":"Flint Auto","check_interval":""}' \
  '{"rule":"main","tag":"","testing_url":"not a url"}'
accepts orphans

# sing-box loads any testing URL: the dashboard saved one without a host.
fixture no_host '{"rule":"main","tag":"Flint Auto","testing_url":"http:///generate_204"}'
warns no_host "URL value for URLTest override 'Flint Auto' of rule 'main' (testing_url) is not an http:// or https:// URL with a host: http:///generate_204"
fixture bad_url '{"rule":"main","tag":"Flint Auto","testing_url":"ftp://example.com/check"}'
warns bad_url "URLTest override 'Flint Auto' of rule 'main' (testing_url) is not an http:// or https:// URL with a host: ftp://example.com/check"
fixture no_url '{"rule":"main","tag":"Flint Auto","testing_url":""}'
warns no_url "URLTest override 'Flint Auto' of rule 'main' (testing_url)"
# Written as int(): sing-box gets 1.
fixture exponent_tolerance '{"rule":"main","tag":"Flint Auto","tolerance":"1e3"}'
warns exponent_tolerance "Tolerance '1e3' for URLTest override 'Flint Auto' of rule 'main' is not a plain number; sing-box uses 1"
# Anything but 1 does not interrupt connections.
fixture bad_interrupt '{"rule":"main","tag":"Flint Auto","interrupt_exist_connections":"yes"}'
warns bad_interrupt "Invalid interrupt_exist_connections 'yes' for URLTest override 'Flint Auto' of rule 'main'; existing connections are not interrupted"

# sing-box does not load these.
fixture bad_interval '{"rule":"main","tag":"Flint Auto","check_interval":"soon"}'
rejects bad_interval "Invalid duration value for URLTest override 'Flint Auto' of rule 'main' (check_interval)"
fixture no_idle '{"rule":"main","tag":"Flint Auto","idle_timeout":""}'
rejects no_idle "Missing duration value for URLTest override 'Flint Auto' of rule 'main' (idle_timeout)"
fixture bad_tolerance '{"rule":"main","tag":"Flint Auto","tolerance":"65536"}'
rejects bad_tolerance "Invalid tolerance '65536' for URLTest override 'Flint Auto' of rule 'main'. Use a number from 0 to 65535. Aborted."
fixture negative_tolerance '{"rule":"main","tag":"Flint Auto","tolerance":"-1"}'
rejects negative_tolerance "Invalid tolerance '-1' for URLTest override 'Flint Auto' of rule 'main'. Use a number from 0 to 65535."
fixture text_tolerance '{"rule":"main","tag":"Flint Auto","tolerance":"fast"}'
rejects text_tolerance "Invalid tolerance 'fast' for URLTest override 'Flint Auto' of rule 'main'"
fixture no_tolerance '{"rule":"main","tag":"Flint Auto","tolerance":""}'
rejects no_tolerance "Invalid tolerance '' for URLTest override 'Flint Auto' of rule 'main'"

# An existing configuration the dashboard wrote before the validator read the
# overrides: a tolerance of 65535 for the group of a rule without its own
# URLTest section, 20000 and a testing URL without a host for a group of a
# subscription. It starts, and the config generated has what it had.
cat >"$WORK_DIR/subscription.json" <<'JSON'
{
  "outbounds": [
    { "type": "urltest", "tag": "Native Group", "outbounds": [ "Native A", "Native B", "Native C" ],
      "url": "https://native.example/ping", "interval": "1m", "tolerance": 80 },
    { "type": "vless", "tag": "Native A", "server": "native-a.example", "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000003", "tls": { "enabled": true, "server_name": "native-a.example" } },
    { "type": "vless", "tag": "Native B", "server": "native-b.example", "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000004", "tls": { "enabled": true, "server_name": "native-b.example" } },
    { "type": "vless", "tag": "Native C", "server": "native-c.example", "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000005", "tls": { "enabled": true, "server_name": "native-c.example" } }
  ]
}
JSON
cat >"$WORK_DIR/existing.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn",
    "dns_server": [ "77.88.8.8" ], "bootstrap_dns_server": [ "77.88.8.8" ], "yacd_secret_key": "test-clash-secret" },
  "section": [
    { ".name": "legacy", ".type": "section", "enabled": "1", "action": "connection",
      "community_lists": [ "youtube" ], "urltest_enabled": "1", "urltest_check_interval": "3m",
      "urltest_tolerance": "50", "urltest_testing_url": "https://www.gstatic.com/generate_204",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls&sni=example.com#first",
        "vless://00000000-0000-4000-8000-000000000002@example.org:443?encryption=none&security=tls&sni=example.org#second" ] },
    { ".name": "subs", ".type": "section", "enabled": "1", "action": "connection",
      "community_lists": [ "telegram" ], "subscription_urls": [ "https://singbox.example/sub" ] }
  ],
  "urltest_override": [
    { ".name": "cfg01a2b3", ".type": "urltest_override", "rule": "legacy", "tag": "legacy-urltest-out",
      "testing_url": "https://example.com/generate_204", "check_interval": "70s", "tolerance": "65535",
      "idle_timeout": "30m", "interrupt_exist_connections": "0" },
    { ".name": "cfg02a2b3", ".type": "urltest_override", "rule": "subs", "tag": "Native Group",
      "testing_url": "http:///generate_204", "check_interval": "2m", "tolerance": "20000",
      "idle_timeout": "45m", "interrupt_exist_connections": "1" }
  ]
}
JSON
warns existing "URL value for URLTest override 'Native Group' of rule 'subs' (testing_url)"
if grep -Fq "legacy-urltest-out" "$LOGGER_LOG"; then
  fail "a tolerance of 65535 must not warn: $(cat "$LOGGER_LOG")"
fi

# The generator reads the rules from the fixture and the overrides through
# core.uci, as on a router both come from /etc/config/prokop.
node - "$WORK_DIR/existing.json" "$WORK_DIR/existing.state" <<'JS'
const fs = require('fs');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const lines = [];
for (const section of config.urltest_override) {
  lines.push(`prokop.${section['.name']}=urltest_override`);
  for (const [key, value] of Object.entries(section))
    if (!key.startsWith('.')) lines.push(`prokop.${section['.name']}.${key}=${value}`);
}
fs.writeFileSync(process.argv[3], lines.join('\n') + '\n');
JS

# generate <lib> <name>: the URLTest outbounds of the config generated by <lib>.
# Since 1.0.28 a URLTest group of a subscription starts at a node drawn once
# per generated config, and the baseline does not rotate it. The seed is
# pinned so that a run is reproducible, and such a group is written from its
# least rotation: it compares equal with the same nodes in the same cyclic
# order, whichever node it starts at. Its three nodes keep that order
# meaningful; with two, every order is a rotation.
# The baseline reads the same sections from the pre-rename config name.
sed 's/^prokop\./forkop./' "$WORK_DIR/existing.state" >"$WORK_DIR/existing-forkop.state"

generate() {
  local lib="$1" dir="$WORK_DIR/$2"
  mkdir -p "$dir/subscriptions" "$dir/config.json.section-cache"
  ucode -L "$lib" "$lib/subscription/parser.uc" normalize-content \
    "$WORK_DIR/subscription.json" "$dir/subscriptions/subs-subscription-1.json"
  printf '%s\n' 'https://singbox.example/sub' >"$dir/subscriptions/subs-subscription-1.url"
  : >"$dir/subscriptions/subs-subscription-1.user_agent"
  PROKOP_URLTEST_START_SEED=urltest-override-validation \
    # The baseline predates the Forkop -> Prokop rename and reads FORKOP_*.
  PROKOP_UCI_STATE_FILE="$WORK_DIR/existing.state" \
    FORKOP_UCI_STATE_FILE="$WORK_DIR/existing-forkop.state" \
    TMP_SUBSCRIPTION_FOLDER="$dir/subscriptions" \
    PROKOP_SUBSCRIPTION_METADATA_DIR="$dir/metadata" \
    FORKOP_SUBSCRIPTION_METADATA_DIR="$dir/metadata" \
    ucode -L "$lib" "$lib/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/existing.json" "$dir/config.json" 127.0.0.1 ||
    fail "$2: the config must be generated"
  node -e '
const fs = require("fs");
const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const provided = new Set(JSON.parse(fs.readFileSync(process.argv[2], "utf8")).outbounds
  .filter((outbound) => outbound.type === "urltest").map((outbound) => outbound.tag));
const least_rotation = (values) => values.map((_, start) => values.slice(start).concat(values.slice(0, start)))
  .reduce((least, rotation) => JSON.stringify(rotation) < JSON.stringify(least) ? rotation : least, values);
const groups = config.outbounds.filter((outbound) => outbound.type === "urltest")
  .map((outbound) => provided.has(outbound.tag) ? { ...outbound, outbounds: least_rotation(outbound.outbounds) } : outbound)
  .map((outbound) => Object.fromEntries(Object.keys(outbound).sort().map((key) => [key, outbound[key]])));
process.stdout.write(JSON.stringify(groups) + "\n");
' "$dir/config.json" "$WORK_DIR/subscription.json" >"$dir/urltest.json"
}

generate "$PROKOP_LIB" current
node - "$WORK_DIR/current/urltest.json" <<'JS' || fail "the generated URLTest groups must keep the override values"
const assert = require('assert/strict');
const groups = Object.fromEntries(JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'))
  .map((group) => [group.tag, group]));
const pick = ({ url, interval, tolerance, idle_timeout, interrupt_exist_connections }) =>
  ({ url, interval, tolerance, idle_timeout, interrupt_exist_connections });
assert.deepEqual(pick(groups['legacy-urltest-out']), { url: 'https://example.com/generate_204',
  interval: '70s', tolerance: 65535, idle_timeout: '30m', interrupt_exist_connections: false });
assert.deepEqual(pick(groups['Native Group']), { url: 'http:///generate_204',
  interval: '2m', tolerance: 20000, idle_timeout: '45m', interrupt_exist_connections: true });
JS

if git -C "$ROOT_DIR" rev-parse --verify --quiet "$BASELINE_REF^{commit}" >/dev/null; then
  mkdir -p "$WORK_DIR/baseline-tree"
  baseline_package=prokop
  git -C "$ROOT_DIR" cat-file -e "$BASELINE_REF:prokop/files/usr/lib" 2>/dev/null || baseline_package=forkop
  git -C "$ROOT_DIR" archive "$BASELINE_REF" "$baseline_package/files/usr/lib" | tar -x -C "$WORK_DIR/baseline-tree" ||
    fail "failed to materialize $BASELINE_REF"
  generate "$WORK_DIR/baseline-tree/$baseline_package/files/usr/lib" baseline
  cmp -s "$WORK_DIR/baseline/urltest.json" "$WORK_DIR/current/urltest.json" || {
    printf 'baseline: %s\ncurrent:  %s\n' "$(cat "$WORK_DIR/baseline/urltest.json")" \
      "$(cat "$WORK_DIR/current/urltest.json")" >&2
    fail "the URLTest groups must be generated as by $BASELINE_REF"
  }
else
  printf 'SKIP: %s is not in this clone; the URLTest groups are checked against fixed values only\n' "$BASELINE_REF"
fi

printf 'URLTest override validation checks passed\n'
