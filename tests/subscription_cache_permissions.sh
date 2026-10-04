#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mode_of() {
  stat -c '%a' "$1"
}

# A permissive umask, as on a router where nothing sets one.
umask 022

state="$WORK_DIR/run"
mkdir -p "$WORK_DIR/sing-box/subscriptions" "$state/section-cache"
chmod 755 "$WORK_DIR/sing-box/subscriptions" "$state/section-cache"
TMP_SING_BOX_FOLDER="$WORK_DIR/sing-box" \
  TMP_RULESET_FOLDER="$WORK_DIR/sing-box/rulesets" \
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/sing-box/subscriptions" \
  PROKOP_RUNTIME_STATE_DIR="$state" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/subscription/cache.uc" ensure-runtime-dirs

for dir in "$WORK_DIR/sing-box/subscriptions" "$state/subscription-update" \
  "$state/subscription-metadata" \
  "$state/outbound-metadata" "$state/section-cache"; do
  [ "$(mode_of "$dir")" = 700 ] ||
    fail "$(basename "$dir") must be 0700, got $(mode_of "$dir")"
done

# The generator stages section caches next to the config; runtime publishes them.
stage="$WORK_DIR/stage/config.json"
mkdir -p "$stage.section-cache"
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000040@secret.example:443?security=tls&sni=secret.example&type=tcp#Secret"
      ]
    }
  ]
}
JSON
mkdir -p "$stage.rulesets"
ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$stage" "127.0.0.1" "0" "1"
staged="$stage.section-cache/proxy.json"
[ -f "$staged" ] || fail "the generator must stage a section cache"
[ "$(mode_of "$staged")" = 600 ] ||
  fail "the staged section cache must be 0600, got $(mode_of "$staged")"

published="$WORK_DIR/published"
mkdir -p "$published"
chmod 755 "$published"
PROKOP_SECTION_CACHE_DIR="$published" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/runtime.uc" publish-section-cache-fixture "$stage"
[ "$(mode_of "$published")" = 700 ] ||
  fail "the published section cache directory must be 0700, got $(mode_of "$published")"
[ "$(mode_of "$published/proxy.json")" = 600 ] ||
  fail "a published section cache must be 0600, got $(mode_of "$published/proxy.json")"

printf 'subscription cache permission checks passed\n'
