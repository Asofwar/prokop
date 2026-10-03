#!/usr/bin/env bash
set -euo pipefail

# UC-037: the generated sing-box config carries every outbound secret and the
# Clash API secret. It and its copies (staging file, backup, check_proxy copy
# in /tmp, rule-set materialization) are private (0600) whatever the umask,
# and an existing world-readable file is narrowed before content is written.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

UCODE_BIN="$(command -v ucode)" || fail "ucode is required"
umask 022

mode_of() {
  stat -c %a "$1"
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "77.88.8.8", "yacd_secret_key": "clash-secret" },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": ["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080,\"password\":\"pw\"}"],
      "domain_suffix": ["example.com"] }
  ]
}
JSON

generate() {
  "$UCODE_BIN" -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$1" 192.0.2.1 0 1 '' 1.12.0 || fail "generator failed"
}

# A new file.
generate "$WORK_DIR/new.json"
[ "$(mode_of "$WORK_DIR/new.json")" = 600 ] || fail "a new generated config must be 0600, got $(mode_of "$WORK_DIR/new.json")"

# An existing world-readable file (the staging path is reused).
printf '{}\n' >"$WORK_DIR/existing.json"
chmod 0644 "$WORK_DIR/existing.json"
generate "$WORK_DIR/existing.json"
[ "$(mode_of "$WORK_DIR/existing.json")" = 600 ] || fail "an existing generated config must be narrowed to 0600"
grep -q '"clash-secret"' "$WORK_DIR/existing.json" || fail "the generated config lost its content"

# The check_proxy copy of the full config in /tmp.
cp "$WORK_DIR/new.json" "$WORK_DIR/live.json"
"$UCODE_BIN" -L "$PROKOP_LIB" "$PROKOP_LIB/diagnostics/status.uc" prepare-check-proxy-config \
  "$WORK_DIR/live.json" "$WORK_DIR/check-proxy.json" "$WORK_DIR/check-proxy.db" || fail "check_proxy copy failed"
[ "$(mode_of "$WORK_DIR/check-proxy.json")" = 600 ] || fail "the check_proxy copy must be 0600"

# Rule-set materialization rewrites the staged config in place.
cp "$WORK_DIR/new.json" "$WORK_DIR/materialize.json"
chmod 0644 "$WORK_DIR/materialize.json"
PROKOP_RULESET_CACHE_DIR="$WORK_DIR/ruleset-cache" \
  PROKOP_RULESET_RUNTIME_CACHE_DIR="$WORK_DIR/ruleset-runtime" \
  PROKOP_RULESET_RUNTIME_MANIFEST="$WORK_DIR/ruleset-runtime.json" \
  PROKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/list-cache" \
  "$UCODE_BIN" -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/ruleset_cache.uc" materialize-config \
  "$WORK_DIR/materialize.json" cache-only || fail "rule-set materialization failed"
[ "$(mode_of "$WORK_DIR/materialize.json")" = 600 ] || fail "materialization must keep the staged config 0600"

# Commit of a staged config: the live config of an older release was
# world-readable; it and its backup become private even when unchanged.
cp "$WORK_DIR/new.json" "$WORK_DIR/etc-config.json"
chmod 0644 "$WORK_DIR/etc-config.json"
cp "$WORK_DIR/new.json" "$WORK_DIR/stage.json"
printf '%s\n' 'prokop.settings=settings' "prokop.settings.config_path=$WORK_DIR/etc-config.json" >"$WORK_DIR/uci-state"
mkdir -p "$WORK_DIR/run" "$WORK_DIR/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod 0755 "$WORK_DIR/bin/logger"
PATH="$WORK_DIR/bin:$PATH" \
  PROKOP_LIB="$PROKOP_LIB" \
  PROKOP_UCI_STATE_FILE="$WORK_DIR/uci-state" \
  PROKOP_UCI_LOG_FILE="$WORK_DIR/uci-log" \
  PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
  PROKOP_SECTION_CACHE_DIR="$WORK_DIR/run/section-cache" \
  "$UCODE_BIN" -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/runtime.uc" commit-config-stage \
  "$WORK_DIR/stage.json" "$WORK_DIR/backup.json" >/dev/null 2>&1 || fail "commit-config-stage failed"
[ "$(mode_of "$WORK_DIR/etc-config.json")" = 600 ] || fail "the live config must be narrowed to 0600"
[ "$(mode_of "$WORK_DIR/backup.json")" = 600 ] || fail "the config backup must be 0600"

# The mode is narrowed before any content is written, not after: a reader
# must never see the new secrets in a file that is still world-readable.
awk '/^function write_private_json_file\(/ { copy=1 } copy { print } copy && /^}/ { exit }' \
  "$PROKOP_LIB/core/common.uc" >"$WORK_DIR/write_private.uc"
chmod_line="$(grep -n 'fs.chmod(path, 0600)' "$WORK_DIR/write_private.uc" | head -n1 | cut -d: -f1)"
write_line="$(grep -n 'fh.write(' "$WORK_DIR/write_private.uc" | head -n1 | cut -d: -f1)"
[ -n "$chmod_line" ] && [ -n "$write_line" ] && [ "$chmod_line" -lt "$write_line" ] ||
  fail "write_private_json_file must narrow the mode before writing the content"
grep -Fq 'fs.open(path, "w", 0600)' "$WORK_DIR/write_private.uc" ||
  fail "write_private_json_file must create the file 0600"

printf 'Generated sing-box configs and their copies are private\n'
