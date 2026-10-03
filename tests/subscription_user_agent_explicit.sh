#!/usr/bin/env bash
# D-17 (a), UC-090: a User-Agent the configuration names for a subscription
# source is sent as it is; the options the runtime ignores are not kept.
#   - user_agent of a subscription_url item (or of the legacy
#     subscription_url_settings map) is the User-Agent of its requests,
#     unless auto_user_agent turns the automatic profiles on; one with
#     control characters is never sent (a line break would add headers);
#   - the podkop 'url | UA' entry keeps its User-Agent through the migration
#     and the request uses it (it was migrated but ignored);
#   - the migration removes auto_user_agent, auto_hwid, hwid,
#     hide_urltest_group_outbounds and hide_detour_outbounds, which the
#     runtime ignores; a value that asked for something else than what the
#     runtime does is named in a config_migration notice;
#   - the podkop migration does not write them any more.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
export PROKOP_LIB
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The User-Agent each subscription source of the fixture's rules sends, one
# "rule url user_agent" line per source ("" for the automatic profiles).
cat >"$WORK_DIR/agents.uc" <<'UC'
let fs = require("fs");
let connections = require("config.connections");
let data = json(fs.readfile(ARGV[0]));
connections.set_item_sections_from_data(data);
let result = {};
for (let section in data.section || [])
    for (let entry in connections.subscription_urls(section))
        result[section[".name"] + " " + entry] = connections.subscription_user_agent(section, entry);
print(sprintf("%J\n", result));
UC
agents() {
  ucode -L "$PROKOP_LIB" "$WORK_DIR/agents.uc" "$1"
}

cat >"$WORK_DIR/prokop.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "config_version": "1.0.5", "yacd_secret_key": "s" },
  "section": [
    { ".name": "vpn", ".type": "section", "enabled": "1", "action": "connection" },
    { ".name": "legacy", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": [ "https://legacy.example/sub" ],
      "subscription_url_settings": "{\"https://legacy.example/sub\":{\"user_agent\":\"Legacy/1.0\",\"auto_hwid\":\"0\",\"hwid\":\"abc\"}}" }
  ],
  "subscription_url": [
    { ".name": "s1", ".type": "subscription_url", "section": "vpn", "url": "https://one.example/sub",
      "user_agent": "Clash/1.0" },
    { ".name": "s2", ".type": "subscription_url", "section": "vpn", "url": "https://two.example/sub",
      "auto_user_agent": "0", "user_agent": "Clash.Meta", "auto_hwid": "1",
      "hide_urltest_group_outbounds": "1", "hide_detour_outbounds": "1" },
    { ".name": "s3", ".type": "subscription_url", "section": "vpn", "url": "https://three.example/sub",
      "auto_user_agent": "1", "user_agent": "Ignored/1.0", "auto_hwid": "0", "hwid": "custom-hwid",
      "hide_detour_outbounds": "0" },
    { ".name": "s4", ".type": "subscription_url", "section": "vpn", "url": "https://four.example/sub",
      "auto_user_agent": "0" },
    { ".name": "s5", ".type": "subscription_url", "section": "vpn", "url": "https://five.example/sub",
      "user_agent": "Bad\nX-Injected: 1" }
  ]
}
JSON

node - "$(agents "$WORK_DIR/prokop.json")" <<'NODE'
const assert = require('node:assert/strict');
assert.deepEqual(JSON.parse(process.argv[2]), {
  'vpn https://one.example/sub': 'Clash/1.0',
  'vpn https://two.example/sub': 'Clash.Meta',
  'vpn https://three.example/sub': '',
  'vpn https://four.example/sub': '',
  'vpn https://five.example/sub': '',
  'legacy https://legacy.example/sub': 'Legacy/1.0',
});
NODE

# The migration removes what the runtime ignores and keeps what it does.
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/migration.uc" migrate-fixture "$WORK_DIR/prokop.json" >"$WORK_DIR/prokop.out.json"
node - "$WORK_DIR/prokop.out.json" <<'NODE'
const assert = require('node:assert/strict');
const out = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const items = Object.fromEntries(out.config.subscription_url.map((item) => [item['.name'], item]));
const IGNORED = ['auto_user_agent', 'auto_hwid', 'hwid', 'hide_urltest_group_outbounds', 'hide_detour_outbounds'];
for (const item of Object.values(items))
  for (const key of IGNORED) assert.equal(item[key], undefined, `${item['.name']} keeps ${key}`);
assert.equal(items.s1.user_agent, 'Clash/1.0');
assert.equal(items.s2.user_agent, 'Clash.Meta');
assert.equal(items.s3.user_agent, undefined, 'a User-Agent behind automatic selection is not kept');
const legacy = out.config.section.find((section) => section['.name'] === 'legacy');
assert.deepEqual(JSON.parse(legacy.subscription_url_settings), { 'https://legacy.example/sub': { user_agent: 'Legacy/1.0' } });
assert(out.config.settings.applied_migrations.includes('subscription_ignored_options_v1'));
assert.deepEqual(out.notices.filter((notice) => notice.code === 'subscription_options_removed'), [
  { code: 'subscription_options_removed', section: 'legacy', values: ['auto_hwid', 'hwid'] },
  { code: 'subscription_options_removed', section: 'vpn', values: ['auto_hwid', 'hwid', 'hide_detour_outbounds'] },
], 'only values that asked for something else are named, never a URL or a value');
// Earlier versions never sent a stored User-Agent (they chose one
// automatically); now it is sent, so the rules whose sources keep one that
// will be sent are named (never the User-Agent or the URL). s3 turned it off,
// s5 has control characters and is not sent: no change for them.
assert.deepEqual(out.notices.filter((notice) => notice.code === 'subscription_user_agent_in_effect'), [
  { code: 'subscription_user_agent_in_effect', section: 'legacy', values: ['user_agent'] },
  { code: 'subscription_user_agent_in_effect', section: 'vpn', values: ['user_agent'] },
]);
assert(!/Clash|Legacy|example/.test(JSON.stringify(out.notices)), 'a notice must not carry a User-Agent or a URL');
NODE
# Only an automatic or unsendable User-Agent: nothing changes, no notice.
cat >"$WORK_DIR/automatic.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "config_version": "1.0.5", "yacd_secret_key": "s" },
  "section": [ { ".name": "vpn", ".type": "section", "enabled": "1", "action": "connection" } ],
  "subscription_url": [
    { ".name": "s3", ".type": "subscription_url", "section": "vpn", "url": "https://three.example/sub",
      "auto_user_agent": "1", "user_agent": "Ignored/1.0" },
    { ".name": "s5", ".type": "subscription_url", "section": "vpn", "url": "https://five.example/sub",
      "user_agent": "Bad\nX-Injected: 1" },
    { ".name": "s6", ".type": "subscription_url", "section": "vpn", "url": "https://six.example/sub",
      "auto_user_agent": "0", "user_agent": "  " }
  ]
}
JSON
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/migration.uc" migrate-fixture "$WORK_DIR/automatic.json" >"$WORK_DIR/automatic.out.json"
node -e '
  const out = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  if (out.notices.some((notice) => notice.code === "subscription_user_agent_in_effect")) process.exit(1);
' "$WORK_DIR/automatic.out.json" || fail "a User-Agent that is not sent was named: $(cat "$WORK_DIR/automatic.out.json")"
# The User-Agents after the migration are the same.
node -e '
  const fs = require("fs");
  const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).config;
  fs.writeFileSync(process.argv[2], JSON.stringify(out));
' "$WORK_DIR/prokop.out.json" "$WORK_DIR/prokop.migrated.json"
[ "$(agents "$WORK_DIR/prokop.json")" = "$(agents "$WORK_DIR/prokop.migrated.json")" ] ||
  fail "the migration changed a User-Agent: $(agents "$WORK_DIR/prokop.migrated.json")"

# podkop: 'url | UA' keeps its User-Agent, which the request now sends.
cat >"$WORK_DIR/podkop.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "main", ".type": "section", "connection_type": "proxy", "proxy_config_type": "subscription",
      "subscription_urls": [ "https://sub.example/x | Clash/1.0", "https://sub.example/y" ] }
  ]
}
JSON
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/migration.uc" migrate-fixture "$WORK_DIR/podkop.json" podkop >"$WORK_DIR/podkop.out.json"
node - "$WORK_DIR/podkop.out.json" "$WORK_DIR/podkop.migrated.json" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const items = out.config.subscription_url;
assert.equal(items.length, 2);
const [x, y] = items;
assert.equal(x.url, 'https://sub.example/x');
assert.equal(x.user_agent, 'Clash/1.0');
assert.equal(y.user_agent, undefined);
for (const item of items)
  for (const key of ['auto_user_agent', 'auto_hwid', 'hide_urltest_group_outbounds', 'hide_detour_outbounds'])
    assert.equal(item[key], undefined, `podkop migration writes ${key}`);
assert.deepEqual(out.notices.filter((notice) => notice.code === 'subscription_options_removed'), []);
// podkop sent the User-Agent of a 'url | UA' entry: nothing to tell.
assert.deepEqual(out.notices.filter((notice) => notice.code === 'subscription_user_agent_in_effect'), []);
fs.writeFileSync(process.argv[3], JSON.stringify(out.config));
NODE
node - "$(agents "$WORK_DIR/podkop.migrated.json")" <<'NODE'
const assert = require('node:assert/strict');
assert.deepEqual(JSON.parse(process.argv[2]), {
  'main https://sub.example/x': 'Clash/1.0',
  'main https://sub.example/y': '',
});
NODE

# A User-Agent with control characters that an earlier version stored keeps
# the configuration valid; the validator says why it is not sent.
cat >"$WORK_DIR/control.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "yacd_secret_key": "s", "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "77.88.8.8" },
  "section": [
    { ".name": "vpn", ".type": "section", "enabled": "1", "action": "connection",
      "selector_proxy_links": [ "socks5://10.0.0.1:1080" ] }
  ],
  "subscription_url": [
    { ".name": "s5", ".type": "subscription_url", "section": "vpn", "url": "https://five.example/sub",
      "user_agent": "Bad\nX-Injected: 1" }
  ]
}
JSON
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
SH
chmod +x "$WORK_DIR/bin/logger"
: >"$WORK_DIR/logger.log"
PATH="$WORK_DIR/bin:$PATH" LOGGER_LOG="$WORK_DIR/logger.log" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/validator.uc" validate-runtime-fixture "$WORK_DIR/control.json" '{}' \
  >"$WORK_DIR/control.out" 2>&1 || fail "a stored User-Agent with control characters must stay valid: $(cat "$WORK_DIR/control.out")"
grep -q "User-Agent of a subscription source in rule 'vpn' contains control characters" "$WORK_DIR/logger.log" ||
  fail "the validator must say why the User-Agent is not sent: $(cat "$WORK_DIR/logger.log")"

# The history keeps the notice.
PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/diagnostics/health.uc" record config_migration success "" "" \
  '{"notices":[{"code":"subscription_options_removed","section":"vpn","values":["hwid","hide_detour_outbounds"]},{"code":"subscription_user_agent_in_effect","section":"vpn","values":["user_agent"]}]}'
PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/diagnostics/health.uc" history | grep -q '"subscription_options_removed"' ||
  fail "the history must keep the subscription notice"
PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/diagnostics/health.uc" history | grep -q '"subscription_user_agent_in_effect"' ||
  fail "the history must keep the User-Agent notice"

printf 'subscription_user_agent_explicit: ok\n'
