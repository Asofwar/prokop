#!/bin/sh
set -eu

# A restore of a snapshot saved by an older release runs this release's
# migrations on a copy (D-16, config/snapshots.uc restore_content). Those
# migrations can remove retired b4geoip rule sets (D-13 (b), UC-093), raise
# an automatic update interval under 1h (D-18 (a), UC-091) and drop
# subscription options the runtime ignores (D-17 (a), UC-090). A package
# upgrade reports what they changed as a config_migration history event
# (config/migration.uc report_notices); the restore dropped the notices
# that migrate_sections returned, so the History page never named them.
#
# Now a restore whose migrated copy is in place when the transaction ends
# (success, or restored_not_started while Prokop is stopped) records the
# same config_migration event, before its restore event. A restore that put
# the previous configuration back, or a snapshot that needed no migration,
# records none.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
MIGRATION="$LIB/config/migration.uc"
WORK="$(mktemp -d)"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "${WORK:?}"' EXIT HUP INT TERM
REAL_UCODE="$(command -v ucode)"
export REAL_UCODE
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/result.json" ] || printf '  result: %s\n' "$(cat "$WORK/result.json")" >&2
  [ ! -s "$WORK/history.jsonl" ] || printf '  history: %s\n' "$(cat "$WORK/history.jsonl")" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/state" "$WORK/etc" "$WORK/uci-save" "$WORK/snapshots"
chmod 700 "$WORK/snapshots"
export PROKOP_CONFIG_FILE="$WORK/etc/prokop"
export PROKOP_SNAPSHOT_DIR="$WORK/snapshots"
export PROKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export PROKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export PROKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json"
export PROKOP_LIB="$LIB"
export PROKOP_BIN="$WORK/bin/prokop"
export PROKOP_RELOAD_COMMAND="$WORK/reload"
export PROKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export PROKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
export PROKOP_HISTORY_FILE="$WORK/history.jsonl"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_UCI_SAVEDIR="$WORK/uci-save"
export STATE="$WORK/state"

# The restore guard and the validator are modelled; snapshots.uc, the
# migrations and the history journal (diagnostics/health.uc) are the real
# code.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    [ "${4:-}" != dpi-transition-guard-state ] || echo absent
    exit 0 ;;
  */config/validator.uc) [ ! -e "$STATE/invalid" ] ;;
  */diagnostics/health.uc) exec "$REAL_UCODE" "$@" ;;
  *) exit 0 ;;
esac
STUB
# No runtime guard of a failed transition.
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/nft"
# init.d answers "stopped" for a restore while Prokop is stopped (D-15).
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
[ ! -e "$STATE/stopped" ] || echo stopped
exit 0
STUB
cat > "$WORK/bin/prokop" <<'STUB'
#!/bin/sh
[ "$1" = show_version ] && echo 1.0.33-test
exit 0
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/nft" "$WORK/reload" "$WORK/bin/prokop"

json() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],r);console.log(v===undefined||v===null?"":typeof v==="object"?JSON.stringify(v):v)' "$WORK/result.json" "$1"; }
restore() {
  rm -f "$WORK/result.json" "$WORK/history.jsonl"
  PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$1" > "$WORK/result.json" || true
}
# The kinds of the recorded events, oldest first, and the notices of the
# config_migration events.
history_kinds() {
  [ -s "$WORK/history.jsonl" ] || return 0
  node -e '
    const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    console.log(lines.map((l) => { const e = JSON.parse(l); return e.kind + ":" + e.status; }).join(" "));
  ' "$WORK/history.jsonl"
}
put_snapshot() {
  node -e '
    const fs = require("fs"), crypto = require("crypto");
    const [dir, id, version, file] = process.argv.slice(1);
    const content = fs.readFileSync(file, "utf8");
    const snapshot = { id, created_at: 1700000000, kind: "manual", reason: "manual",
      config_hash: crypto.createHash("sha256").update(content).digest("hex"),
      prokop_version: version, content };
    fs.writeFileSync(`${dir}/${id}.json`, JSON.stringify(snapshot) + "\n", { mode: 0o600 });
  ' "$PROKOP_SNAPSHOT_DIR" "$1" "$2" "$3"
}

# Every migration of this release, as config/migration.uc records them.
printf '{ "settings": { ".name": "settings", ".type": "settings", "yacd_secret_key": "x" } }\n' > "$WORK/ids.json"
IDS="$("$REAL_UCODE" -L "$LIB" "$MIGRATION" migrate-fixture "$WORK/ids.json" |
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).config.settings.applied_migrations.join("\n")))')"
printf '%s\n' "$IDS" | grep -qx update_interval_minimum_v1 || fail "fixture: migration ids: $IDS"

live_config() {
  {
    printf "config settings 'settings'\n\toption config_version '1.0.5'\n"
    printf '%s\n' "$IDS" | sed "s/.*/\tlist applied_migrations '&'/"
    printf "\toption yacd_secret_key 'live-secret-0123456789'\n"
    printf "\toption mirror_base_url 'https://mirror.infotechtg.ru'\n\toption marker 'live'\n"
    printf "\nconfig section 'main'\n\toption action 'connection'\n\toption enabled '1'\n"
  } > "$PROKOP_CONFIG_FILE"
}

# A snapshot of a release before the retired rule sets were removed and
# before the 1h minimum of automatic updates.
cat > "$WORK/older.uci" <<'UCI'
config settings 'settings'
	option config_version '1.0.5'
	list applied_migrations 'interface_sections'
	list applied_migrations 'enable_component_checks'
	list applied_migrations 'http_connection_urls'
	list applied_migrations 'flintnet_urltest_default'
	option yacd_secret_key 'older-secret-0123456789'
	option mirror_base_url 'https://mirror.infotechtg.ru'
	option update_interval '30m'
	option marker 'older'

config section 'main'
	option action 'connection'
	option enabled '1'
	list selector_proxy_links 'socks5://10.0.0.1:1080'
	list rule_set_with_subnets 'https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs/hetzner.srs'
	list rule_set_with_subnets 'https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs/google.srs'
UCI
put_snapshot older 1.0.23 "$WORK/older.uci"

# 1. The migrated copy is restored: the history names what the migrations
# changed, as after a package upgrade, then the restore.
live_config
restore older
[ "$(json status)" = success ] || fail "older snapshot: not restored"
grep -Fxq "	option marker 'older'" "$PROKOP_CONFIG_FILE" || fail "older snapshot: the snapshot configuration was not restored"
grep -Fxq "	option update_interval '1h'" "$PROKOP_CONFIG_FILE" || fail "the short interval was not raised"
[ "$(history_kinds)" = "config_migration:success restore:success" ] ||
  fail "history after a migrated restore: '$(history_kinds)'"
node - "$WORK/history.jsonl" <<'JS' || fail "the config_migration event does not name what the migrations changed"
const assert = require('node:assert/strict');
const event = require('fs').readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean).map(JSON.parse)[0];
assert.deepEqual(event.notices, [
  { code: 'retired_rule_sets', section: 'main', values: ['hetzner'], replacements: ['hetzner'] },
  { code: 'update_interval_raised', section: 'settings', values: ['update_interval'], replacements: [], from: '30m', to: '1h' },
  // NET-12: a snapshot older than the intercept had it on by default.
  { code: 'client_dns_intercept_off', section: 'settings', values: ['intercept_client_dns'], replacements: [], from: '1', to: '0' },
]);
JS
ok "migrated restore -> config_migration event with the notices, then the restore"

# 2. Prokop stopped (D-15): the migrated copy stays for the next start.
live_config
: > "$STATE/stopped"
restore older
rm -f "$STATE/stopped"
[ "$(json status)" = restored_not_started ] || fail "stopped: status"
grep -Fxq "	option marker 'older'" "$PROKOP_CONFIG_FILE" || fail "stopped: the migrated copy is not in place"
[ "$(history_kinds)" = "config_migration:success restore:not_started" ] ||
  fail "history after a migrated restore while stopped: '$(history_kinds)'"
ok "migrated restore while stopped -> config_migration event"

# 3. The migrated copy fails validation: the previous configuration is put
# back, so nothing the migrations did is in place.
live_config
cp "$PROKOP_CONFIG_FILE" "$WORK/live.uci"
: > "$STATE/invalid"
restore older
rm -f "$STATE/invalid"
[ "$(json status)" = recovered ] || fail "invalid copy: status"
cmp -s "$PROKOP_CONFIG_FILE" "$WORK/live.uci" || fail "invalid copy: the previous configuration was not put back"
[ "$(history_kinds)" = "restore:recovered" ] || fail "history after a restore that was put back: '$(history_kinds)'"
ok "restore put back -> no config_migration event"

# 4. A snapshot of this release needs no migration: no notice.
live_config
current_id="$("$REAL_UCODE" -L "$LIB" "$SCRIPT" create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
restore "$current_id"
[ "$(json status)" = success ] && [ -z "$(json migration)" ] || fail "current snapshot"
[ "$(history_kinds)" = "restore:success" ] || fail "history after a restore without migration: '$(history_kinds)'"
ok "restore without migration -> no config_migration event"

printf 'restore_migration_notices: PASS\n'
