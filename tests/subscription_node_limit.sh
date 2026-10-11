#!/usr/bin/env bash
set -euo pipefail

# R6 (cergo666/netshift 7b51b92e): each subscription source puts at most
# max_nodes servers into the configuration (default 500 for a new source,
# 0 = no limit): the first ones in the subscription's order after the
# incompatible ones are left out, deterministically. Groups lose the members
# left out; a group without any and a node chained through one go too. The
# cut is logged and the section cache tells the dashboard (no secret). The
# sources that existed before the limit get 0 on upgrade, so nothing is cut
# silently; a large unlimited source gets an advisory notice.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/subs"
node - "$WORK/subs/proxy-subscription-1.json" <<'NODE'
const o = [];
// An incompatible node first: it does not use up the limit.
o.push({ type: 'wireguard', tag: 'wg', server: 'w.example.com', server_port: 51820 });
for (let i = 1; i <= 600; i++) o.push({ type: 'trojan', tag: `n${i}`, server: `s${i}.example.com`, server_port: 443, password: 'p' });
o.push({ type: 'urltest', tag: 'Auto', outbounds: ['n1', 'n599'], __prokop_allow_group: true });
o.push({ type: 'urltest', tag: 'Late', outbounds: ['n550', 'n600'], __prokop_allow_group: true });
o.push({ type: 'trojan', tag: 'chained', server: 'c.example.com', server_port: 443, password: 'p', detour: 'n590' });
require('fs').writeFileSync(process.argv[2], JSON.stringify({ version: 1, format: 'sing-box-json', placeholders: 2, outbounds: o }));
NODE
printf 'https://example.com/sub' >"$WORK/subs/proxy-subscription-1.url"
printf 'Happ' >"$WORK/subs/proxy-subscription-1.user_agent"

fixture() { # fixture MAX_NODES_JSON_FRAGMENT
  cat >"$WORK/fixture.json" <<JSON
{ "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [ { ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection" } ],
  "subscription_url": [ { ".name": "s1", ".type": "subscription_url", "section": "proxy", "url": "https://example.com/sub"$1 } ] }
JSON
}
generate() {
  rm -rf "$WORK/gen.json.section-cache"
  TMP_SUBSCRIPTION_FOLDER="$WORK/subs" PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/persistent" \
    ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/gen.json" 127.0.0.1 0 1 '' 1.14.2 \
    2>"$WORK/gen.err" || fail "not generated: $(cat "$WORK/gen.err")"
}
trojans() { jq -r '[.outbounds[] | select(.type == "trojan") | .server] | "\(length) \(.[0]) \(.[-1])"' "$WORK/gen.json"; }
notices() { jq -c '[.subscriptionNotices[] | del(.sourceSection)]' "$WORK/gen.json.section-cache/proxy.json"; }

# No option: the default 500, the first 500 in order.
fixture ''
generate
[ "$(trojans)" = "500 s1.example.com s500.example.com" ] || fail "default limit: $(trojans)"
[ "$(notices)" = '[{"sourceIndex":1,"kind":"placeholders","count":2},{"sourceIndex":1,"kind":"node_limit","limit":500,"total":601,"dropped":101}]' ] ||
  fail "default notices: $(notices)"
grep -Fq "subscription source 1 of rule 'proxy' has 601 servers; only the first 500 are used" "$WORK/gen.err" || fail "the cut was not logged"
[ "$(jq -c '[.outbounds[] | select(.tag == "Auto" or .tag == "Late") | {tag, outbounds}]' "$WORK/gen.json")" = '[{"tag":"Auto","outbounds":["n1"]}]' ] ||
  fail "groups: $(jq -c '[.outbounds[] | select(.type == "urltest")]' "$WORK/gen.json")"
cp "$WORK/gen.json" "$WORK/first.json"
generate
cmp -s "$WORK/gen.json" "$WORK/first.json" || fail "the limit is not deterministic"

# An explicit limit; a chained node whose detour was cut goes too.
fixture ', "max_nodes": "595"'
generate
[ "$(trojans)" = "595 s1.example.com s595.example.com" ] || fail "limit 595: $(trojans)"
jq -e '[.outbounds[] | select(.tag == "chained")] | length == 0' "$WORK/gen.json" >/dev/null || fail "the chained node survived its detour"

# 0: no limit (what config/migration.uc gives existing sources), with an
# advisory notice for a large source.
fixture ', "max_nodes": "0"'
generate
[ "$(trojans)" = "601 s1.example.com c.example.com" ] || fail "no limit: $(trojans)"
[ "$(notices)" = '[{"sourceIndex":1,"kind":"placeholders","count":2},{"sourceIndex":1,"kind":"large_source","total":601,"suggested":500}]' ] ||
  fail "no limit notices: $(notices)"
grep -Fq "only the first" "$WORK/gen.err" && fail "an unlimited source was cut"

# A small source under the limit gets no notice.
fixture ', "max_nodes": "1000"'
generate
[ "$(trojans)" = "601 s1.example.com c.example.com" ] || fail "limit 1000: $(trojans)"
[ "$(notices)" = '[{"sourceIndex":1,"kind":"placeholders","count":2}]' ] || fail "limit 1000 notices: $(notices)"

# The value check, the migration and the UI.
cat >"$WORK/values.uc" <<'UC'
let c = require("config.connections");
let out = [];
for (let v in [ "", "0", "10", "100000", "100001", "-1", "abc", " 7 " ])
    push(out, c.subscription_max_nodes_value(v));
print(sprintf("%J", out), "\n");
UC
[ "$(ucode -L "$LIB" "$WORK/values.uc")" = '[ 500, 0, 10, 100000, null, null, null, 7 ]' ] ||
  fail "values: $(ucode -L "$LIB" "$WORK/values.uc")"
cat >"$WORK/bad.json" <<'JSON'
{ "settings": { ".name": "settings", ".type": "settings", "dns_server": [ "77.88.8.8" ], "bootstrap_dns_server": [ "77.88.8.8" ], "yacd_secret_key": "s" },
  "section": [ { ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection" } ],
  "subscription_url": [ { ".name": "s1", ".type": "subscription_url", "section": "proxy", "url": "https://example.com/sub", "max_nodes": "lots" } ] }
JSON
if out="$(PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/bad.json" '{}' 2>/dev/null)"; then
  fail "the validator accepted max_nodes 'lots'"
fi
grep -Fq "Invalid server limit 'lots'" <<<"$out" || fail "validator message: $out"
# An upgrade keeps every server of the existing sources (0); an explicit
# value stays; a configuration that ran the migration is not touched again.
cat >"$WORK/upgrade.json" <<'JSON'
{ "settings": { ".name": "settings", ".type": "settings", "config_version": "1.0.5",
    "applied_migrations": [ "interface_sections", "enable_component_checks", "http_connection_urls" ] },
  "section": [ { ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection" } ],
  "subscription_url": [
    { ".name": "old", ".type": "subscription_url", "section": "proxy", "url": "https://example.com/a" },
    { ".name": "set", ".type": "subscription_url", "section": "proxy", "url": "https://example.com/b", "max_nodes": "50" } ] }
JSON
PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/upgrade.json" >"$WORK/upgrade-out.json" ||
  fail "the migration failed"
[ "$(jq -c '[.config.subscription_url[] | .max_nodes]' "$WORK/upgrade-out.json")" = '["0","50"]' ] ||
  fail "migration: $(jq -c '.config.subscription_url' "$WORK/upgrade-out.json")"
jq -e '.config.settings.applied_migrations | index("subscription_max_nodes_v1")' "$WORK/upgrade-out.json" >/dev/null ||
  fail "the migration was not recorded"
jq '.config | .subscription_url[0] |= del(.max_nodes)' "$WORK/upgrade-out.json" >"$WORK/again.json"
PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/migration.uc" migrate-fixture "$WORK/again.json" >"$WORK/again-out.json" ||
  fail "the second migration failed"
[ "$(jq -c '.config.subscription_url[0].max_nodes' "$WORK/again-out.json")" = null ] ||
  fail "a source added after the upgrade was given no limit"
grep -Fq "list applied_migrations 'subscription_max_nodes_v1'" "$ROOT_DIR/prokop/files/etc/config/prokop" ||
  fail "the shipped configuration must mark subscription_max_nodes_v1 as applied"
SECTION_JS="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js"
grep -q '"max_nodes",' "$SECTION_JS" || fail "the subscription settings have no server limit"
grep -q 'max_nodes: true' "$LIB/diagnostics/status.uc" || fail "max_nodes is not in the diagnostics allowlist"

printf 'subscription node limit checks passed\n'
