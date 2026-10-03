#!/usr/bin/env bash
set -euo pipefail

# UC-007, UC-038, D-1 (b): the Clash API stays reachable from the LAN, but a
# secret is mandatory. A new install and every upgraded configuration get a
# strong random secret from the migration (only when none is set; a user
# secret is never replaced), and the validator rejects a configuration
# without one, so an upgrade never fails closed on this check.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
MIGRATION="$PROKOP_LIB/config/migration.uc"
VALIDATOR="$PROKOP_LIB/config/validator.uc"
DEFAULT_CONFIG="$ROOT_DIR/prokop/files/etc/config/prokop"
SETTINGS_JS="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/settings.js"
WORK_DIR="$(mktemp -d)"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

UCODE_BIN="$(command -v ucode)" || fail "ucode is required"

# --- Migration -------------------------------------------------------------------

migrate() {
  local name="$1" settings="$2"
  cat >"$WORK_DIR/$name.json" <<JSON
{ "settings": { ".name": "settings", ".type": "settings", "config_version": "1.0.5"$settings } }
JSON
  "$UCODE_BIN" -L "$PROKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/$name.json" >"$WORK_DIR/$name.out" ||
    fail "migration failed for $name"
}

field() {
  node -e '
    const out = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const value = out.config.settings[process.argv[2]];
    process.stdout.write(value === undefined ? "<none>" : Array.isArray(value) ? value.join(" ") : String(value));
  ' "$WORK_DIR/$1.out" "$2"
}

# A configuration without a secret (upgrade from an older release, or a new
# install whose shipped config has none) gets a random 64-digit hex secret.
migrate absent ''
secret_a="$(field absent yacd_secret_key)"
printf '%s' "$secret_a" | grep -Eq '^[0-9a-f]{64}$' ||
  fail "the migration must generate a 256-bit hex secret, got '$secret_a'"
field absent applied_migrations | grep -qw clash_api_secret_v1 ||
  fail "the secret migration must be recorded"

migrate absent-again ''
[ "$(field absent-again yacd_secret_key)" != "$secret_a" ] ||
  fail "every configuration must get its own random secret"

migrate empty ', "yacd_secret_key": "  "'
field empty yacd_secret_key | grep -Eq '^[0-9a-f]{64}$' ||
  fail "an empty secret must be replaced by a generated one"

# A user secret is never overwritten, with or without YACD and WAN access.
migrate user ', "enable_yacd": "1", "enable_yacd_wan_access": "1", "yacd_secret_key": "my own secret"'
[ "$(field user yacd_secret_key)" = "my own secret" ] || fail "the migration must keep an existing user secret"
node -e '
  const out = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  if (out.operations.some((op) => op.option === "yacd_secret_key"))
    throw new Error("the migration must not touch an existing secret");
' "$WORK_DIR/user.out" || fail "the migration rewrote an existing secret"

# Already applied: a later empty secret is the user's choice and is left to
# the validator, which rejects it with a clear message.
migrate applied ', "applied_migrations": [ "clash_api_secret_v1" ]'
[ "$(field applied yacd_secret_key)" = "<none>" ] || fail "an applied migration must not run again"

# Without a random source nothing is generated and the migration is not
# recorded, so the next run retries it.
cat >"$WORK_DIR/no-random.json" <<'JSON'
{ "settings": { ".name": "settings", ".type": "settings", "config_version": "1.0.5" } }
JSON
PROKOP_SECRET_RANDOM_SOURCE="$WORK_DIR/missing-random" \
  "$UCODE_BIN" -L "$PROKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/no-random.json" >"$WORK_DIR/no-random.out" ||
  fail "migration failed without a random source"
[ "$(field no-random yacd_secret_key)" = "<none>" ] || fail "no secret can be generated without a random source"
field no-random applied_migrations | grep -qw clash_api_secret_v1 &&
  fail "a secret migration that generated nothing must not be recorded"
field no-random applied_migrations | grep -qw own_dependency_mirror_v1 ||
  fail "the other migrations must still be recorded"

# Podkop configurations go through the same migrations.
cat >"$WORK_DIR/podkop.json" <<'JSON'
{ "settings": { ".name": "settings", ".type": "settings", "yacd_secret_key": "podkop-secret" } }
JSON
"$UCODE_BIN" -L "$PROKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/podkop.json" podkop >"$WORK_DIR/podkop.out" ||
  fail "podkop migration failed"
[ "$(field podkop yacd_secret_key)" = "podkop-secret" ] || fail "a migrated Podkop secret must be kept"

# The shipped configuration carries no static secret and leaves the
# migration pending, so the package postinst generates one on a new install.
grep -q 'yacd_secret_key' "$DEFAULT_CONFIG" && fail "the shipped config must not carry a static secret"
grep -q 'clash_api_secret_v1' "$DEFAULT_CONFIG" && fail "the shipped config must leave the secret migration pending"
grep -v '^[[:space:]]*#' "$DEFAULT_CONFIG" | sed -e "s/^[[:space:]]*//" >"$WORK_DIR/default.uci"
node - "$WORK_DIR/default.uci" >"$WORK_DIR/default.json" <<'NODE'
const fs = require('fs');
const settings = { '.name': 'settings', '.type': 'settings' };
let inSettings = false;
for (const line of fs.readFileSync(process.argv[2], 'utf8').split('\n')) {
  const words = line.match(/'[^']*'|\S+/g) || [];
  if (words[0] === 'config') { inSettings = words[2] === "'settings'"; continue; }
  if (!inSettings || words.length < 3) continue;
  const key = words[1];
  const value = words[2].replace(/^'|'$/g, '');
  if (words[0] === 'list') (settings[key] ||= []).push(value);
  else settings[key] = value;
}
process.stdout.write(JSON.stringify({ settings }));
NODE
"$UCODE_BIN" -L "$PROKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/default.json" >"$WORK_DIR/default.out" ||
  fail "migration of the shipped config failed"
field default yacd_secret_key | grep -Eq '^[0-9a-f]{64}$' ||
  fail "a new install must get a generated secret"

# --- Validator ---------------------------------------------------------------------

validate() {
  local name="$1" settings="$2"
  cat >"$WORK_DIR/validate-$name.json" <<JSON
{ "settings": { ".name": "settings", ".type": "settings", "dns_server": [ "77.88.8.8" ],
  "bootstrap_dns_server": [ "77.88.8.8" ]$settings } }
JSON
  PROKOP_LIB="$PROKOP_LIB" "$UCODE_BIN" -L "$PROKOP_LIB" "$VALIDATOR" validate-runtime-fixture \
    "$WORK_DIR/validate-$name.json" '{}'
}

out="$(validate wan-empty ', "enable_yacd": "1", "enable_yacd_wan_access": "1", "yacd_secret_key": ""' 2>&1)" &&
  fail "WAN access to the Clash API without a secret must be rejected"
printf '%s' "$out" | grep -Fq 'Clash API secret' || fail "the rejection must name the Clash API secret: $out"

out="$(validate lan-missing '' 2>&1)" && fail "a LAN controller without a secret must be rejected"
printf '%s' "$out" | grep -Fq 'Clash API secret' || fail "the rejection must name the Clash API secret: $out"

validate lan-blank ', "yacd_secret_key": "   "' >/dev/null 2>&1 && fail "a blank secret is no secret"

out="$(validate newline ', "yacd_secret_key": "abc\ndef"' 2>&1)" &&
  fail "a secret with control characters would break the Authorization header"
printf '%s' "$out" | grep -Fq 'Clash API secret' || fail "the control-character rejection must be clear: $out"

validate lan-ok ', "yacd_secret_key": "0123456789abcdef"' >/dev/null ||
  fail "a configuration with a secret must pass"
validate wan-ok ', "enable_yacd": "1", "enable_yacd_wan_access": "1", "yacd_secret_key": "wan secret"' >/dev/null ||
  fail "WAN access with a secret must pass"

# The rejection never quotes the secret.
out="$(validate quoted ', "yacd_secret_key": "SECRET_MARKER\u0001"' 2>&1)" && fail "control characters must be rejected"
printf '%s' "$out" | grep -q SECRET_MARKER && fail "the validator message must not quote the secret"

# --- LuCI ----------------------------------------------------------------------------

node - "$SETTINGS_JS" <<'NODE' || fail "LuCI must refuse an empty secret"
const fs = require('fs');
const settings = fs.readFileSync(process.argv[2], 'utf8');
const start = settings.indexOf('"yacd_secret_key"');
const field = settings.slice(start, settings.indexOf('sections.', start));
if (!/o\.validate = function/.test(field)) throw new Error('the secret field has no validator');
NODE

printf 'Clash API secret is generated once, kept, and required\n'
