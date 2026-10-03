#!/bin/sh
set -eu

# A History snapshot saved by an older release is migrated before it is
# restored (UC-065, D-16 (a)+(b)). Before, do_restore wrote the snapshot
# verbatim: retired mirror and rule-set URLs came back, applied_migrations
# and config_version went back to the older release's, and the validator
# passed it, so it was reported as a successful restore.
#
# Now the restore runs this release's migrations (config/migration.uc) on a
# copy of the snapshot inside its transaction, as a package upgrade migrates
# the live configuration: the migrated copy is what is validated, reloaded
# and checked, last-known-working names a snapshot of it, and the source
# snapshot file is never written. A snapshot that cannot be migrated is
# refused before anything changes. A snapshot saved before the Clash API
# secret existed (D-1) keeps the secret clients use now instead of a new
# random one; a secret it holds is never replaced. The global VPN guard of a
# snapshot from before the kill-switch becomes the per-section kill-switch,
# and a stopped Forkop X (D-15) still gets restored_not_started.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
MIGRATION="$LIB/config/migration.uc"
WORK="$(mktemp -d)"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"' EXIT HUP INT TERM
REAL_UCODE="$(command -v ucode)"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/result.json" ] || printf '  result: %s\n' "$(cat "$WORK/result.json")" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/state" "$WORK/etc" "$WORK/uci-save" "$WORK/snapshots"
chmod 700 "$WORK/snapshots"
export FORKOP_CONFIG_FILE="$WORK/etc/forkop"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export FORKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json"
export FORKOP_LIB="$LIB"
export FORKOP_BIN="$WORK/bin/forkop"
export FORKOP_RELOAD_COMMAND="$WORK/reload"
export FORKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export FORKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
export FORKOP_HISTORY_FILE="$WORK/history.jsonl"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
export FORKOP_UCI_SAVEDIR="$WORK/uci-save"
export STATE="$WORK/state"

# The restore guard, the validator and health are modelled; snapshots.uc and
# the migrations are the real code.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    echo "$4" >> "$STATE/events"
    case "$4" in
      dpi-transition-guard-state) echo absent ;;
      # A UCI commit (LuCI, a URLTest override) that lands after the reload
      # was checked, while the restore releases its guard: nothing proved it.
      remove-dpi-transition-guard)
        if [ -e "$STATE/edit-on-release" ]; then
          rm -f "$STATE/edit-on-release"
          printf "\nconfig section 'unverified'\n\toption marker 'UNVERIFIED-EDIT'\n" >> "$FORKOP_CONFIG_FILE"
        fi ;;
    esac
    exit 0 ;;
  */config/validator.uc) echo validate >> "$STATE/events"; exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
esac
exit 0
STUB
# init.d answers "stopped" for a restore while Forkop X is stopped (D-15).
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
echo "reload:$*" >> "$STATE/events"
[ ! -e "$STATE/stopped" ] || echo stopped
exit 0
STUB
cat > "$WORK/bin/forkop" <<'STUB'
#!/bin/sh
[ "$1" = show_version ] && echo 1.0.33-test
exit 0
STUB
chmod +x "$WORK/bin/ucode" "$WORK/reload" "$WORK/bin/forkop"

json() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],r);console.log(v===undefined||v===null?"":typeof v==="object"?JSON.stringify(v):v)' "$WORK/result.json" "$1"; }
has_line() { grep -Fxq "$1" "$FORKOP_CONFIG_FILE"; }
digest() { sha256sum "$1" | cut -d' ' -f1; }
count() { find "$FORKOP_SNAPSHOT_DIR" -name '*.json' | wc -l; }
lkg() { cat "$FORKOP_SNAPSHOT_DIR/last-known-working" 2>/dev/null || true; }
restore() {
  : > "$STATE/events"
  rm -f "$WORK/result.json"
  PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$1" > "$WORK/result.json" || true
}
# A snapshot file as an older release wrote it: no schema metadata.
put_snapshot() {
  node -e '
    const fs = require("fs"), crypto = require("crypto");
    const [dir, id, version, file] = process.argv.slice(1);
    const content = fs.readFileSync(file, "utf8");
    const snapshot = { id, created_at: 1700000000, kind: "manual", reason: "manual",
      config_hash: crypto.createHash("sha256").update(content).digest("hex"),
      forkop_version: version, content };
    fs.writeFileSync(`${dir}/${id}.json`, JSON.stringify(snapshot) + "\n", { mode: 0o600 });
  ' "$FORKOP_SNAPSHOT_DIR" "$1" "$2" "$3"
}

# Every migration of this release, as config/migration.uc records them.
printf '{ "settings": { ".name": "settings", ".type": "settings", "yacd_secret_key": "x" } }\n' > "$WORK/ids.json"
IDS="$("$REAL_UCODE" -L "$LIB" "$MIGRATION" migrate-fixture "$WORK/ids.json" |
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).config.settings.applied_migrations.join("\n")))')"
[ "$(printf '%s\n' "$IDS" | grep -c .)" -ge 11 ] || fail "fixture: migration ids: $IDS"

# The configuration of the running release: postinst migrated it.
live_config() {
  {
    printf "config settings 'settings'\n\toption config_version '1.0.5'\n"
    printf '%s\n' "$IDS" | sed "s/.*/\tlist applied_migrations '&'/"
    printf "\tlist applied_migrations 'mirror_infotechtg_ru_v1'\n"
    printf "\toption yacd_secret_key '%s'\n" "${1-live-secret-0123456789}"
    printf "\toption mirror_base_url 'https://mirror.infotechtg.ru'\n\toption marker 'live'\n"
    printf "\nconfig section 'main'\n\toption action 'connection'\n\toption enabled '1'\n"
  } > "$FORKOP_CONFIG_FILE"
}

# A snapshot of an older release: before the own mirror, the retired rule
# sets, the Clash API secret, stable URLTest names and the kill-switch.
cat > "$WORK/older.uci" <<'UCI'
config settings 'settings'
	option config_version '1.0.5'
	list applied_migrations 'interface_sections'
	list applied_migrations 'enable_component_checks'
	list applied_migrations 'http_connection_urls'
	list applied_migrations 'flintnet_urltest_default'
	# Forkop releases and maintained lists are downloaded from this mirror.
	option mirror_base_url 'https://mirror.51343.ru'
	option vpn_fail_closed '1'
	option marker 'older'

config section 'main'
	option action 'connection'
	option enabled '1'
	list selector_proxy_links 'socks5://10.0.0.1:1080'
	list rule_set_with_subnets 'https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs/hetzner.srs'
	list rule_set_with_subnets 'https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs/google.srs'
	list remote_domain_lists 'https://mirror.51343.ru/forkop/lists/allow-domains/Russia/inside-raw.lst'

config urltest
	option section 'main'
	option name 'Fastest'

config urltest_override
	option rule 'main'
	option tag 'main-urltest-cfg032898-out'
	option testing_url 'https://example.com/check'

config section 'zap'
	option action 'zapret'
	option enabled '1'
UCI
put_snapshot older 1.0.23 "$WORK/older.uci"
older_digest="$(digest "$FORKOP_SNAPSHOT_DIR/older.json")"

# libuci names the anonymous URLTest group cfg032898 (its third section): the
# dashboard override of the fixture holds the tag it had.
if command -v uci >/dev/null 2>&1; then
  mkdir -p "$WORK/uci-check/save"
  cp "$WORK/older.uci" "$WORK/uci-check/forkop"
  uci -c "$WORK/uci-check" -t "$WORK/uci-check/save" -X show forkop | grep -Fxq 'forkop.cfg032898=urltest' ||
    fail "fixture: libuci does not name the URLTest group cfg032898"
fi

# 1. The older snapshot is migrated on a copy, then restored.
live_config
echo stale > "$FORKOP_SNAPSHOT_DIR/last-known-working"
before_count="$(count)"
restore older
[ "$(json status)" = success ] || fail "older snapshot: not restored"
has_line "	option marker 'older'" || fail "older snapshot: the snapshot configuration was not restored"
# The dependency mirror is opt-in (fork_mirror_opt_in_v1): the migrated
# snapshot names no former upstream mirror.
! grep -Eq "mirror_base_url '.*(infotechtg|51343)" "$FORKOP_CONFIG_FILE" || fail "the retired mirror came back"
! grep -q 'mirror\.51343\.ru' "$FORKOP_CONFIG_FILE" || fail "a URL of the retired mirror came back"
! grep -q 'hetzner\.srs' "$FORKOP_CONFIG_FILE" || fail "a retired rule set came back"
# D-13 (b): the rule keeps the id for the rule editor's notice.
has_line "	list retired_rule_sets 'hetzner'" || fail "the rule lost the notice of its retired rule set"
has_line "	list rule_set_with_subnets 'https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs/google.srs'" ||
  fail "a current rule set was not moved to its direct source"
has_line "	list remote_domain_lists 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst'" ||
  fail "a list of the retired mirror was not moved to its direct source"
has_line "	option config_version '1.0.5'" || fail "config_version was not kept"
for id in $IDS; do
  has_line "	list applied_migrations '$id'" || fail "applied_migrations lost $id"
done
# The global VPN guard became the per-section kill-switch: only the enabled
# connection section is protected, and the retired option is gone.
! grep -q 'vpn_fail_closed' "$FORKOP_CONFIG_FILE" || fail "the retired VPN guard option came back"
node - "$FORKOP_CONFIG_FILE" <<'JS' || fail "the VPN guard did not become the kill-switch of the connection section"
const text = require('fs').readFileSync(process.argv[2], 'utf8');
const sections = text.split(/\n(?=config )/);
const main = sections.find((s) => s.startsWith("config section 'main'"));
const zap = sections.find((s) => s.startsWith("config section 'zap'"));
if (!main.includes("\toption kill_switch '1'\n") || zap.includes('kill_switch')) process.exit(1);
JS
# The anonymous URLTest group got its stable name, its override followed.
has_line "config urltest 'ut_032898'" || fail "the URLTest group was not named"
has_line "	option tag 'main-urltest-ut_032898-out'" || fail "the dashboard override did not follow the group"
# D-1: the snapshot had no secret: it keeps the one in use, not a new one.
has_line "	option yacd_secret_key 'live-secret-0123456789'" || fail "the Clash API secret in use was not kept"
[ "$(grep -c 'yacd_secret_key' "$FORKOP_CONFIG_FILE")" = 1 ] || fail "more than one secret"
# The source snapshot was not written, not even its layout.
[ "$(digest "$FORKOP_SNAPSHOT_DIR/older.json")" = "$older_digest" ] || fail "the source snapshot was rewritten"
# The result names the migration and the change of the migrated copy.
[ "$(json migration.from)" = 1.0.23 ] && [ "$(json migration.to)" = 1.0.33-test ] || fail "migration versions"
json migration.migrations | grep -q clash_api_secret_v1 || fail "the migration does not list what it ran"
json migration.migrations | grep -q vpn_guard_kill_switch_v1 || fail "the migration does not list what it ran"
node -e '
  const rows = JSON.parse(process.argv[1]);
  const has = (option) => rows.some((row) => row.option === option);
  if (has("vpn_fail_closed") || !has("kill_switch")) process.exit(1);
' "$(json changes)" || fail "the changes are not those of the migrated copy"
# Validation, reload and verification ran on the migrated copy, then the
# history recorded a success.
grep -qx validate "$STATE/events" && grep -q '^reload:reload config-restore$' "$STATE/events" ||
  fail "the restore did not validate and reload: $(tr '\n' ' ' < "$STATE/events")"
grep -qx 'health:restore:success' "$STATE/events" || fail "the restore was not recorded"
# Last-known-working names a snapshot of the configuration the reload
# proved, never the unmigrated source.
working="$(lkg)"
[ -n "$working" ] && [ "$working" != older ] && [ "$working" != stale ] || fail "last-known-working: '$working'"
node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (s.content !== fs.readFileSync(process.argv[2], "utf8") || s.reason !== "last-known-working") process.exit(1);
' "$FORKOP_SNAPSHOT_DIR/$working.json" "$FORKOP_CONFIG_FILE" || fail "last-known-working does not hold the migrated configuration"
[ "$(count)" -eq $((before_count + 2)) ] || fail "expected a pre-restore and a last-known-working snapshot"
# libuci loads the restored file as it was written (its own export form).
if command -v uci >/dev/null 2>&1; then
  rm -rf "$WORK/uci-check"; mkdir -p "$WORK/uci-check/save"
  cp "$FORKOP_CONFIG_FILE" "$WORK/uci-check/forkop"
  uci -c "$WORK/uci-check" -t "$WORK/uci-check/save" export forkop | sed '1{/^package forkop$/d}' > "$WORK/exported"
  cmp -s "$WORK/exported" "$FORKOP_CONFIG_FILE" || fail "libuci does not write the restored file the same way"
fi
ok "older snapshot -> migrated copy restored, source snapshot unchanged, LKG holds the migrated configuration"

# 2. A snapshot of the current schema is restored byte for byte.
live_config
sed -i "s/option marker 'live'/option marker 'current'/" "$FORKOP_CONFIG_FILE"
printf '\t# a comment the restore keeps\n' >> "$FORKOP_CONFIG_FILE"
cp "$FORKOP_CONFIG_FILE" "$WORK/current.uci"
current_id="$("$REAL_UCODE" -L "$LIB" "$SCRIPT" create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
live_config
restore "$current_id"
[ "$(json status)" = success ] && [ -z "$(json migration)" ] || fail "current snapshot"
cmp -s "$FORKOP_CONFIG_FILE" "$WORK/current.uci" || fail "a current snapshot was not restored byte for byte"
[ "$(lkg)" = "$current_id" ] || fail "current snapshot: last-known-working"
ok "current snapshot -> restored byte for byte, no migration"

# 3. A snapshot with its own secret keeps it (D-1: never replaced).
sed "s/option marker 'older'/option yacd_secret_key 'snapshot-own-secret'/" "$WORK/older.uci" > "$WORK/own-secret.uci"
put_snapshot own-key 1.0.23 "$WORK/own-secret.uci"
live_config
restore own-key
[ "$(json status)" = success ] || fail "snapshot with a secret"
has_line "	option yacd_secret_key 'snapshot-own-secret'" || fail "the secret of the snapshot was replaced"
[ "$(grep -c 'yacd_secret_key' "$FORKOP_CONFIG_FILE")" = 1 ] || fail "more than one secret"
ok "pre-D-1 snapshot with its own secret -> kept"

# 4. A snapshot that cannot be migrated is refused before anything changes.
refused() {
  [ "$(json status)" = failed ] && [ "$(json reason)" = snapshot_migration_failed ] || fail "$1: not refused"
  [ "$(digest "$FORKOP_CONFIG_FILE")" = "$2" ] || fail "$1: the configuration was replaced"
  [ ! -s "$STATE/events" ] || fail "$1: the transaction started: $(tr '\n' ' ' < "$STATE/events")"
  [ "$(count)" = "$3" ] || fail "$1: a snapshot was written"
  [ "$(lkg)" = "$4" ] || fail "$1: last-known-working moved"
}
# The copy cannot be read as libuci would load it (an open quote).
printf "config settings 'settings'\n\toption marker 'open\n" > "$WORK/unreadable.uci"
put_snapshot unreadable 1.0.23 "$WORK/unreadable.uci"
unreadable_digest="$(digest "$FORKOP_SNAPSHOT_DIR/unreadable.json")"
# Without a settings section nothing records a migration.
printf "config section 'main'\n\toption action 'connection'\n" > "$WORK/no-settings.uci"
put_snapshot no-settings 1.0.23 "$WORK/no-settings.uci"
live_config
live_digest="$(digest "$FORKOP_CONFIG_FILE")"; n="$(count)"; w="$(lkg)"
restore unreadable
refused "unreadable snapshot" "$live_digest" "$n" "$w"
[ "$(json detail)" = unreadable ] || fail "unreadable snapshot: detail"
[ "$(digest "$FORKOP_SNAPSHOT_DIR/unreadable.json")" = "$unreadable_digest" ] || fail "unreadable snapshot: rewritten"
restore no-settings
refused "snapshot without settings" "$live_digest" "$n" "$w"
[ "$(json detail)" = no_settings ] || fail "snapshot without settings: detail"
# A migration that cannot run: the secret of a pre-D-1 snapshot, when the
# configuration in use has none and no random source exists.
live_config ''
live_digest="$(digest "$FORKOP_CONFIG_FILE")"
export FORKOP_SECRET_RANDOM_SOURCE="$WORK/no-random"
restore older
unset FORKOP_SECRET_RANDOM_SOURCE
refused "migration without a secret" "$live_digest" "$n" "$w"
[ "$(json detail)" = incomplete ] || fail "migration without a secret: detail"
[ "$(digest "$FORKOP_SNAPSHOT_DIR/older.json")" = "$older_digest" ] || fail "the source snapshot was rewritten"
ok "unmigratable snapshots -> refused, nothing changed, no history event"

# 5. Forkop X stopped by the user (D-15): the migrated copy is kept for the
# next start, nothing is started or confirmed.
live_config
echo stale > "$FORKOP_SNAPSHOT_DIR/last-known-working"
: > "$STATE/stopped"
restore older
rm -f "$STATE/stopped"
[ "$(json status)" = restored_not_started ] && [ "$(json runtime)" = "" ] || fail "stopped: status"
[ "$(json migration.from)" = 1.0.23 ] || fail "stopped: migration not reported"
has_line "	option marker 'older'" &&
  has_line "	list remote_domain_lists 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst'" ||
  fail "stopped: the migrated copy was not kept"
[ "$(lkg)" = stale ] || fail "stopped: last-known-working moved"
grep -qx 'health:restore:not_started' "$STATE/events" || fail "stopped: history"
[ "$(digest "$FORKOP_SNAPSHOT_DIR/older.json")" = "$older_digest" ] || fail "the source snapshot was rewritten"
ok "user stopped -> migrated copy restored_not_started, LKG unchanged"

# 6. A snapshot of a newer release (after a downgrade) records more than
# this release knows: nothing can migrate it back, it is restored as it is.
live_config
{ cat "$FORKOP_CONFIG_FILE"; } | sed "s/option marker 'live'/option marker 'newer'/" > "$WORK/newer.uci"
sed -i "s/^\(\tlist applied_migrations 'mirror_infotechtg_ru_v1'\)$/\1\n\tlist applied_migrations 'future_release_v9'/" "$WORK/newer.uci"
put_snapshot newer 9.9.9 "$WORK/newer.uci"
restore newer
[ "$(json status)" = success ] && [ -z "$(json migration)" ] || fail "newer snapshot"
cmp -s "$FORKOP_CONFIG_FILE" "$WORK/newer.uci" || fail "a newer snapshot was changed"
ok "newer snapshot -> restored as it is"

# 7. Last-known-working holds the migrated copy that the reload proved, not
# an edit committed after the check, while the guard is released.
live_config
: > "$STATE/edit-on-release"
restore older
[ ! -e "$STATE/edit-on-release" ] || fail "edit during guard release: the guard was not released"
[ "$(json status)" = success ] || fail "edit during guard release: status"
grep -q 'UNVERIFIED-EDIT' "$FORKOP_CONFIG_FILE" || fail "edit during guard release: the edit was not left in place"
working="$(lkg)"
node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  if (s.content.includes("UNVERIFIED-EDIT") || !s.content.includes("option marker \x27older\x27") ||
    !s.content.includes("raw.githubusercontent.com/itdoginfo") || s.content.includes("mirror.51343.ru")) process.exit(1);
' "$FORKOP_SNAPSHOT_DIR/$working.json" || fail "edit during guard release: last-known-working holds an unverified edit"
ok "edit during the guard release -> last-known-working holds the migrated copy the reload proved"

# 8. A snapshot of this release needs no migration and is restored byte for
# byte, also one that libuci loads but the full reader does not follow (a
# hand-edited ';' between statements): only a migration needs that reader.
live_config
sed "s/option marker 'live'/option marker 'semi'; option other 'x'/" "$FORKOP_CONFIG_FILE" > "$WORK/semi.uci"
put_snapshot semi 1.0.33-test "$WORK/semi.uci"
restore semi
[ "$(json status)" = success ] && [ -z "$(json migration)" ] || fail "snapshot with ';': not restored as it is"
cmp -s "$FORKOP_CONFIG_FILE" "$WORK/semi.uci" || fail "snapshot with ';': not restored byte for byte"
[ "$(lkg)" = semi ] || fail "snapshot with ';': last-known-working"
ok "same-schema snapshot the full reader cannot follow -> restored byte for byte"

# 9. After a downgrade the configuration keeps the config_version a newer
# release wrote; no migration of this release reaches it, so a snapshot of
# this release (one it can raise to nothing) needs none.
live_config
sed -i "s/option config_version '1.0.5'/option config_version '1.0.6'/" "$FORKOP_CONFIG_FILE"
sed "s/option marker 'live'/option marker 'downgraded'/" "$FORKOP_CONFIG_FILE" |
  sed "s/option config_version '1.0.6'/option config_version '1.0.5'/" > "$WORK/downgraded.uci"
put_snapshot downgraded 1.0.33-test "$WORK/downgraded.uci"
PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" list > "$WORK/list.json"
node -e '
  const item = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).find((i) => i.id === "downgraded");
  if (!item || item.migration !== undefined) process.exit(1);
' "$WORK/list.json" || fail "after a downgrade: the list announces a migration"
restore downgraded
[ "$(json status)" = success ] && [ -z "$(json migration)" ] || fail "after a downgrade: not restored as it is"
cmp -s "$FORKOP_CONFIG_FILE" "$WORK/downgraded.uci" || fail "after a downgrade: not restored byte for byte"
ok "newer config_version after a downgrade -> snapshot of this release restored as it is"

# 10. The list says which snapshots a restore migrates, from which version to
# which; new snapshots record their schema; nothing secret is listed.
live_config
PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" list > "$WORK/list.json"
node - "$WORK/list.json" "$FORKOP_SNAPSHOT_DIR/$current_id.json" "$current_id" <<'JS' || fail "snapshot list"
const fs = require('fs');
const assert = require('assert/strict');
const [listFile, currentFile, currentId] = process.argv.slice(2);
const text = fs.readFileSync(listFile, 'utf8');
const list = JSON.parse(text);
const byId = Object.fromEntries(list.map((item) => [item.id, item]));
assert.deepEqual(byId.older.migration, { from: '1.0.23', to: '1.0.33-test' });
assert.equal(byId[currentId].migration, undefined);
assert.equal(byId.newer.migration, undefined);
assert.equal(byId.semi.migration, undefined);
assert.ok(!text.includes('secret') && !text.includes('schema') && !text.includes('config_hash'));
const current = JSON.parse(fs.readFileSync(currentFile, 'utf8'));
assert.equal(current.schema.config_version, '1.0.5');
assert.ok(current.schema.applied_migrations.includes('clash_api_secret_v1'));
JS
ok "list names the snapshots a restore migrates; new snapshots record their schema"

printf 'config_restore_migration: PASS\n'
