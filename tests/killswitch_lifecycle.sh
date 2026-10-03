#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
LIFECYCLE="$PROKOP_LIB/service/lifecycle.uc"
VALIDATOR_UC="$PROKOP_LIB/config/validator.uc"
PROKOP_BIN="$ROOT_DIR/prokop/files/usr/bin/prokop"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

function_body() {
  awk -v name="$2" '
    $0 ~ "^function " name "\\(" { copy = 1 }
    copy { print }
    copy && /^}/ { exit }
  ' "$1"
}

start_impl="$(function_body "$LIFECYCLE" start_impl)"
reload_body="$(function_body "$LIFECYCLE" reload)"

# Only a fully applied runtime refreshes the protection.
printf '%s\n' "$start_impl" | grep -Fq 'killswitch_sync("start");' ||
  fail "a successful start must refresh the kill-switch"
printf '%s\n' "$start_impl" | grep -B1 'killswitch_sync("start");' | grep -Fq 'if (start_lists_complete)' ||
  fail "a start without its list generation must not refresh the kill-switch"
start_main_body="$(function_body "$LIFECYCLE" start_main)"
printf '%s\n' "$start_main_body" | grep -Fq 'start_lists_complete = true;' ||
  fail "start_main must record an applied list generation"
printf '%s\n' "$start_impl" | awk '/dnsmasq_configure\(false\)/ { dns = NR } /killswitch_sync\("start"\)/ { ks = NR } END { exit !(dns && ks && dns < ks) }' ||
  fail "the kill-switch must be refreshed after dnsmasq points to sing-box"
[ "$(printf '%s\n' "$reload_body" | grep -c 'killswitch_sync(')" -eq 2 ] ||
  fail "reload must refresh the kill-switch on both success paths"
printf '%s\n' "$reload_body" | awk '/discard_dnsmasq_reload_config\(\);/ { d = NR } /killswitch_sync\(reason/ { k = NR } END { exit !(d && k && d < k) }' ||
  fail "reload must refresh the kill-switch only after the reload state is committed"
printf '%s\n' "$reload_body" | grep -B3 'killswitch_sync("reload")' | grep -Fq 'if (status == 0) {' ||
  fail "an unchanged reload refreshes the kill-switch only when it succeeded"

# Stop and every failure path keep the previous protection.
for name in stop_main stop_impl cleanup_failed_runtime abort_reload abort_guarded_transition start_main restart_runtime_for_reload; do
  body="$(function_body "$LIFECYCLE" "$name")"
  [ -n "$body" ] || fail "$name not found"
  if printf '%s\n' "$body" | grep -qi 'killswitch'; then
    fail "$name must not touch the kill-switch"
  fi
done

# The helper never fails the caller.
cat >"$WORK_DIR/sync.uc" <<'UCODE'
const KILLSWITCH_UC = "killswitch";
let warned = 0;
let calls = [];
function module_status(path, args) { push(calls, path + ":" + join(",", args)); return 1; }
function log_message(message, level) { if (level == "warn") warned++; }
UCODE
function_body "$LIFECYCLE" killswitch_sync >> "$WORK_DIR/sync.uc"
cat >> "$WORK_DIR/sync.uc" <<'UCODE'
killswitch_sync("start");
if (warned != 1 || calls[0] != "killswitch:sync,start,reload-lock-held")
    exit(1);
UCODE
ucode "$WORK_DIR/sync.uc" || fail "kill-switch sync failure must only warn"

# Package removal, upgrades, downgrades and full uninstall (also reached as
# `prokop uninstall`) lift or keep the protection; they run behaviourally in
# tests/killswitch_owner_package.sh.
for command in killswitch_status killswitch_sync killswitch_disable; do
  grep -Fq "$command: [ \"killswitch/runtime.uc\"" "$PROKOP_BIN" || fail "CLI must dispatch $command"
done

# A direct priority level contradicts the kill-switch.
cat >"$WORK_DIR/direct.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": [ "77.88.8.8" ], "bootstrap_dns_server": [ "77.88.8.8" ], "yacd_secret_key": "killswitch-test-secret" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy", "kill_switch": "1",
      "selector_proxy_links": [ "vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha" ] }
  ],
  "priority_group": [
    { ".name": "pg", ".type": "priority_group", "section": "proxy", "name": "Main",
      "health_url": "https://health.example/generate_204", "active_check_interval": "5s",
      "check_timeout": "2s", "recovery_check_interval": "15s" }
  ],
  "priority_level": [
    { ".name": "vpn", ".type": "priority_level", "group": "pg", "name": "VPN", "order": "0", "regex": [ "Alpha" ] },
    { ".name": "fallback", ".type": "priority_level", "group": "pg", "name": "Direct", "order": "10", "direct": "1" }
  ]
}
JSON
if output="$(PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/direct.json" "{}" 2>&1)"; then
  fail "kill-switch with a direct priority level must be rejected"
fi
printf '%s' "$output" | grep -Fq 'enables the VPN kill-switch' || fail "unexpected validator message: $output"

sed 's/"kill_switch": "1",//' "$WORK_DIR/direct.json" > "$WORK_DIR/direct-off.json"
output="$(PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$WORK_DIR/direct-off.json" "{}" 2>&1)" ||
  fail "a direct priority level stays valid without the kill-switch: $output"

printf 'killswitch_lifecycle: PASS\n'
