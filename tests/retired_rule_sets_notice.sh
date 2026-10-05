#!/usr/bin/env bash
# D-13 (b), UC-093: the migration of retired b4geoip rule sets removes them
# (their downloads fail with 404) and says so, instead of dropping IP
# matches silently:
#   - the rule keeps a marker, list retired_rule_sets, with the removed ids,
#     which the rule editor shows with the built-in rule sets of the same
#     services; adding those is an explicit action of the user there;
#   - the migration adds no match: community_lists stays as it was;
#   - a config_migration history event names the rule, the removed ids and
#     the possible replacement (ids with a built-in rule set of the same
#     service that the rule does not use yet);
#   - the history keeps only the fields it knows, of the expected shape;
#   - the marker changes neither the validator's verdict nor the generated
#     sing-box configuration.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
export PROKOP_LIB
MIGRATION="$PROKOP_LIB/config/migration.uc"
HEALTH="$PROKOP_LIB/diagnostics/health.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

RAW=https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs
CDN=https://cdn.jsdelivr.net/gh/Greeg0ry/b4geoip-forkop@main/srs
MIRROR=https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs

cat >"$WORK_DIR/fixture.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.5",
    "yacd_secret_key": "test-secret",
    "applied_migrations": [ "interface_sections", "enable_component_checks", "http_connection_urls",
      "flintnet_urltest_default" ]
  },
  "section": [
    {
      ".name": "games",
      ".type": "section",
      "action": "bypass",
      "community_lists": [ "hetzner" ],
      "rule_set_with_subnets": [ "$RAW/cloudflare.srs", "$CDN/amazon.srs", "$MIRROR/hetzner.srs",
        "$RAW/valve.srs", "https://example.com/own.srs" ]
    },
    {
      ".name": "plain",
      ".type": "section",
      "action": "bypass",
      "rule_set_with_subnets": [ "$MIRROR/valve.srs" ]
    }
  ]
}
JSON

ucode -L "$PROKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/fixture.json" >"$WORK_DIR/out.json"

# The dependency mirror is opt-in (fork_mirror_opt_in_v1): a kept rule set
# that named the former mirror is read from its direct source.
node - "$WORK_DIR/out.json" "$RAW" <<'NODE'
const assert = require('node:assert/strict');
const out = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const raw = process.argv[3];
const [games, plain] = out.config.section;
assert.deepEqual(games.rule_set_with_subnets, [`${raw}/valve.srs`, 'https://example.com/own.srs'],
  'retired rule sets are removed, the others kept');
assert.deepEqual(games.community_lists, ['hetzner'], 'the migration must not add matches');
assert.deepEqual(games.retired_rule_sets, ['cloudflare', 'amazon', 'hetzner'],
  'the rule keeps the ids it lost for the editor');
assert.equal(plain.retired_rule_sets, undefined, 'a rule that lost nothing gets no marker');
assert.deepEqual(out.notices.filter((notice) => notice.code === 'retired_rule_sets'), [{
  code: 'retired_rule_sets',
  section: 'games',
  values: ['cloudflare', 'amazon', 'hetzner'],
  replacements: ['cloudflare'],
}], 'the notice names the rule, the removed ids and the replacement not in use yet');
NODE

# The runtime migration (the package's postinst) records the event and says
# what it removed.
cat >"$WORK_DIR/uci.state" <<EOF_UCI
prokop.settings=settings
prokop.settings.config_version=1.0.5
prokop.settings.yacd_secret_key=test-secret
prokop.settings.applied_migrations=interface_sections enable_component_checks http_connection_urls flintnet_urltest_default
prokop.games=section
prokop.games.action=bypass
prokop.games.rule_set_with_subnets=$RAW/cloudflare.srs $RAW/valve.srs
EOF_UCI
run_migrate() {
  PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  PROKOP_UCI_LOG_FILE="$WORK_DIR/uci.log" \
  PROKOP_CONFIG_NAME="prokop" \
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
  PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/subscription-cache" \
  PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" \
    ucode -L "$PROKOP_LIB" "$MIGRATION" migrate
}
run_migrate 2>"$WORK_DIR/migrate.err" || fail "runtime migration failed: $(cat "$WORK_DIR/migrate.err")"
grep -Fxq "prokop.games.retired_rule_sets=cloudflare" "$WORK_DIR/uci.state" ||
  fail "runtime migration must keep the marker in UCI: $(grep games "$WORK_DIR/uci.state")"
grep -q "games.*cloudflare" "$WORK_DIR/migrate.err" ||
  fail "the migration must say what it removed: $(cat "$WORK_DIR/migrate.err")"
[ "$(grep -c '"config_migration"' "$WORK_DIR/history.jsonl")" = 1 ] ||
  fail "one config_migration event expected: $(cat "$WORK_DIR/history.jsonl" 2>/dev/null)"

PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  ucode -L "$PROKOP_LIB" "$HEALTH" history >"$WORK_DIR/history.json"
node - "$WORK_DIR/history.json" <<'NODE'
const assert = require('node:assert/strict');
const history = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const events = history.events.filter((event) => event.kind === 'config_migration');
assert.equal(events.length, 1);
assert.equal(events[0].status, 'success');
// Other migrations (client_dns_intercept_off) may add their own notices.
assert.deepEqual(events[0].notices.filter((notice) => notice.code === 'retired_rule_sets'), [{
  code: 'retired_rule_sets', section: 'games', values: ['cloudflare'], replacements: ['cloudflare'],
}]);
NODE

# Nothing left to migrate: no second event.
run_migrate 2>/dev/null || fail "second runtime migration failed"
[ "$(grep -c '"config_migration"' "$WORK_DIR/history.jsonl")" = 1 ] ||
  fail "a migration without changes must not record an event"

# The history keeps only known notices of the expected shape.
PROKOP_HISTORY_FILE="$WORK_DIR/bogus.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime-bogus" \
  ucode -L "$PROKOP_LIB" "$HEALTH" record config_migration success "" "" \
  '{"notices":[{"code":"retired_rule_sets","section":"a b","values":["x"]},{"code":"nope","section":"r"},{"code":"retired_rule_sets","section":"r1","values":["ok_1","<b>","UPPER"],"replacements":["ok_1"],"extra":"x"}]}'
PROKOP_HISTORY_FILE="$WORK_DIR/bogus.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime-bogus" \
  ucode -L "$PROKOP_LIB" "$HEALTH" history >"$WORK_DIR/bogus.json"
node - "$WORK_DIR/bogus.json" <<'NODE'
const assert = require('node:assert/strict');
const history = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
assert.deepEqual(history.events.map((event) => event.notices), [[
  { code: 'retired_rule_sets', section: 'r1', values: ['ok_1'], replacements: ['ok_1'] },
]]);
NODE

# The marker is informational: same verdict and same sing-box configuration
# with and without it.
node - "$ROOT_DIR/tests/helpers" <<'NODE'
const assert = require('node:assert/strict');
const backend = require(`${process.argv[2]}/uci_backend.js`);
const rule = {
  '.name': 'games', '.type': 'section', '.anonymous': false, enabled: '1', action: 'bypass',
  community_lists: ['hetzner'],
};
const marked = { ...rule, retired_rule_sets: ['cloudflare', 'amazon'] };
assert.deepEqual(backend.validate({ games: marked }), backend.validate({ games: rule }));
assert.deepEqual(backend.generate({ games: marked }), backend.generate({ games: rule }));
NODE

printf 'retired_rule_sets_notice: ok\n'
