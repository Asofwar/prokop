#!/usr/bin/env bash
# D-18 (a), UC-091: automatic list updates and component update checks run
# at most once an hour. A shorter interval (`1m`, `1s`; `100ms`, which the
# validator read as 0 s) is
#   - kept as it is when it is read, and still accepted by the validator,
#     which warns that it runs hourly (an existing configuration stays valid);
#   - never what the scheduler uses: the cron job, the due checks and the
#     sing-box remote rule sets run hourly;
#   - raised to 1h by the migration of a package upgrade, with a warning and
#     a config_migration history event (the settings page raises it on Save;
#     tests/luci_update_interval_minimum.sh).
# An interval of an hour or more is untouched everywhere; an update started
# by hand always runs (components/updates.uc list-update has no due check).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
export PROKOP_LIB
UPDATES="$PROKOP_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# settings fixture with a list rule: $1 name, $2 update_interval,
# $3 component_update_check_interval
fixture() {
  cat >"$WORK_DIR/$1.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.5",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "77.88.8.8",
    "service_listen_address": "127.0.0.1",
    "yacd_secret_key": "test-secret",
    "list_update_enabled": "1",
    "update_interval": "$2",
    "component_update_check_enabled": "1",
    "component_update_check_interval": "$3"
  },
  "section": [
    {
      ".name": "lists",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "remote_domain_lists": [ "https://lists.example/one.lst" ],
      "rule_set": [ "https://lists.example/rules.srs" ]
    }
  ]
}
JSON
}

plan() {
  ucode -L "$PROKOP_LIB" "$UPDATES" cron-refresh-plan-fixture "$WORK_DIR/$1.json" /usr/bin/prokop '# list' '# sub' '# comp'
}

fixture minute 1m 1m
fixture second 1s 10m
fixture subsecond 100ms 100ms
fixture hours 2h 1d
fixture hour 1h 90m

[ "$(plan minute)" = $'list\t0 * * * * /usr/bin/prokop list_update_if_due # list\ncomponent\t0 * * * * /usr/bin/prokop component_updates_if_due # comp' ] ||
  fail "1m must be scheduled hourly: $(plan minute)"
[ "$(plan second)" = $'list\t0 * * * * /usr/bin/prokop list_update_if_due # list\ncomponent\t0 * * * * /usr/bin/prokop component_updates_if_due # comp' ] ||
  fail "1s/10m must be scheduled hourly: $(plan second)"
[ "$(plan subsecond)" = $'list\t0 * * * * /usr/bin/prokop list_update_if_due # list\ncomponent\t0 * * * * /usr/bin/prokop component_updates_if_due # comp' ] ||
  fail "100ms must be scheduled hourly, not as 0 s: $(plan subsecond)"
[ "$(plan hours)" = $'list\t0 */2 * * * /usr/bin/prokop list_update_if_due # list\ncomponent\t0 0 * * * /usr/bin/prokop component_updates_if_due # comp' ] ||
  fail "intervals of an hour or more are kept: $(plan hours)"
[ "$(plan hour)" = $'list\t0 * * * * /usr/bin/prokop list_update_if_due # list\ncomponent\t*/30 * * * * /usr/bin/prokop component_updates_if_due # comp' ] ||
  fail "1h and 90m are kept as they are, 90m checked every 30 minutes: $(plan hour)"

# An interval of an hour or more that is no whole number of hours is not
# checked every minute: at the largest step that divides both it and the
# hour, at least every 5 minutes (the update itself still runs once per
# interval).
schedule() {
  ucode -L "$PROKOP_LIB" "$UPDATES" due-check-cron-schedule "$1"
}
[ "$(schedule 5400)" = '*/30 * * * *' ] || fail "90m: $(schedule 5400)"
[ "$(schedule 8100)" = '*/15 * * * *' ] || fail "2h15m: $(schedule 8100)"
[ "$(schedule 90000)" = '0 * * * *' ] || fail "25h: $(schedule 90000)"
[ "$(schedule 129600)" = '0 * * * *' ] || fail "36h: $(schedule 129600)"
[ "$(schedule 3660)" = '*/5 * * * *' ] || fail "61m: $(schedule 3660)"
[ "$(schedule 3630)" = '0 * * * *' ] || fail "1h30s: $(schedule 3630)"
# Shorter intervals (subscriptions) and whole hours or days keep theirs.
[ "$(schedule 1800)" = '*/30 * * * *' ] || fail "30m: $(schedule 1800)"
[ "$(schedule 60)" = '* * * * *' ] || fail "1m: $(schedule 60)"
[ "$(schedule 7200)" = '0 */2 * * *' ] || fail "2h: $(schedule 7200)"
[ "$(schedule 172800)" = '0 0 * * *' ] || fail "2d: $(schedule 172800)"

# The due check: with a 1m interval a list updated two minutes ago is not
# due, one updated an hour ago is.
due() {
  local status=0
  printf '%s\n' "$2" >"$WORK_DIR/last"
  ucode -L "$PROKOP_LIB" "$UPDATES" list-update-due-status-fixture "$WORK_DIR/$1.json" "$WORK_DIR/last" 100000 >/dev/null || status=$?
  printf '%s' "$status"
}
[ "$(due minute $((100000 - 120)))" = 1 ] || fail "a 1m interval must not make the list due after two minutes"
[ "$(due subsecond $((100000 - 120)))" = 1 ] || fail "a 100ms interval must not make the list due after two minutes"
[ "$(due minute $((100000 - 3600)))" = 0 ] || fail "a 1m interval makes the list due after an hour"
[ "$(due hours $((100000 - 3600)))" = 1 ] || fail "a 2h interval is not due after an hour"

# sing-box refetches remote rule sets at the same period (the remote rule
# set of the rule; its downloaded domain list is not materialized here).
remote_interval() {
  local out="$WORK_DIR/$1.config.json"
  mkdir -p "$out.section-cache" "$out.rulesets"
  node -e '
    const fs = require("fs");
    const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    delete data.section[0].remote_domain_lists;
    fs.writeFileSync(process.argv[2], JSON.stringify(data));
  ' "$WORK_DIR/$1.json" "$WORK_DIR/$1.generator.json"
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subs" \
    ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/$1.generator.json" "$out" "127.0.0.1" 0 "" "" "" >/dev/null
  node -e '
    const config = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const remote = (config.route.rule_set || []).filter((item) => item.type === "remote");
    console.log([...new Set(remote.map((item) => item.update_interval))].join(","));
  ' "$out"
}
[ "$(remote_interval minute)" = 1h ] || fail "remote rule sets with 1m: $(remote_interval minute)"
[ "$(remote_interval subsecond)" = 1h ] || fail "remote rule sets with 100ms: $(remote_interval subsecond)"
[ "$(remote_interval hours)" = 2h ] || fail "remote rule sets with 2h: $(remote_interval hours)"

# The validator keeps accepting an existing short interval and says that it
# runs hourly; 1h raises nothing.
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
SH
chmod +x "$WORK_DIR/bin/logger"
validate() {
  : >"$WORK_DIR/$1.log"
  PATH="$WORK_DIR/bin:$PATH" LOGGER_LOG="$WORK_DIR/$1.log" \
    ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/validator.uc" validate-runtime-fixture "$WORK_DIR/$1.json" '{}' \
    >/dev/null 2>&1
}
for name in minute subsecond; do
  validate "$name" || fail "$name: an existing short interval must stay valid: $(cat "$WORK_DIR/$name.log")"
  grep -q 'settings.update_interval .* shorter than 1h' "$WORK_DIR/$name.log" ||
    fail "$name: the validator must warn about the list interval: $(cat "$WORK_DIR/$name.log")"
  grep -q 'settings.component_update_check_interval .* shorter than 1h' "$WORK_DIR/$name.log" ||
    fail "$name: the validator must warn about the component interval: $(cat "$WORK_DIR/$name.log")"
done
validate hours || fail "2h must be valid"
! grep -q 'shorter than 1h' "$WORK_DIR/hours.log" || fail "2h must not warn"

# The migration raises a short interval to 1h and says so.
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/migration.uc" migrate-fixture "$WORK_DIR/minute.json" >"$WORK_DIR/minute.out.json"
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/migration.uc" migrate-fixture "$WORK_DIR/hour.json" >"$WORK_DIR/hour.out.json"
fixture invalid bad 1.5h
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/migration.uc" migrate-fixture "$WORK_DIR/invalid.json" >"$WORK_DIR/invalid.out.json"
node - "$WORK_DIR/minute.out.json" "$WORK_DIR/hour.out.json" "$WORK_DIR/invalid.out.json" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('fs');
const [minute, hour, invalid] = process.argv.slice(2).map((path) => JSON.parse(fs.readFileSync(path, 'utf8')));
assert.equal(minute.config.settings.update_interval, '1h');
assert.equal(minute.config.settings.component_update_check_interval, '1h');
assert.deepEqual(minute.notices.filter((notice) => notice.code === 'update_interval_raised'), [
  { code: 'update_interval_raised', section: 'settings', values: ['update_interval'], from: '1m', to: '1h' },
  { code: 'update_interval_raised', section: 'settings', values: ['component_update_check_interval'], from: '1m', to: '1h' },
]);
assert(minute.config.settings.applied_migrations.includes('update_interval_minimum_v1'));
assert.equal(hour.config.settings.update_interval, '1h');
assert.equal(hour.config.settings.component_update_check_interval, '90m');
assert.deepEqual(hour.notices.filter((notice) => notice.code === 'update_interval_raised'), []);
// Not a duration: left for the validator to refuse, as before.
assert.equal(invalid.config.settings.update_interval, 'bad');
assert.equal(invalid.config.settings.component_update_check_interval, '1.5h');
NODE

# The history keeps the notice with its durations.
PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/diagnostics/health.uc" record config_migration success "" "" \
  '{"notices":[{"code":"update_interval_raised","section":"settings","values":["update_interval"],"from":"1m","to":"1h"},{"code":"update_interval_raised","section":"settings","values":["update_interval"],"from":"1m; rm","to":"1h"}]}'
PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/diagnostics/health.uc" history >"$WORK_DIR/history.json"
node - "$WORK_DIR/history.json" <<'NODE'
const assert = require('node:assert/strict');
const history = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
assert.deepEqual(history.events[0].notices, [
  { code: 'update_interval_raised', section: 'settings', values: ['update_interval'], replacements: [], from: '1m', to: '1h' },
]);
NODE

printf 'update_interval_minimum: ok\n'
