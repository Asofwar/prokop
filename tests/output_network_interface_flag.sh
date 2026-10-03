#!/usr/bin/env bash
# D-20 (a), UC-095: enable_output_network_interface is the switch of the
# Output Network Interface, as the settings page has shown it since the
# field was added (podkop 4186292a, 42 minutes after the field itself:
# "Enable Output Network Interface — You can select Output Network
# Interface, by default autodetect"; the interface field depends on it and
# the shipped configuration has the switch off and no interface). The
# runtime read the interface whatever the switch said, relying on LuCI to
# drop it when the switch is off. The contract:
#   - switch on, interface set: sing-box egress is pinned to it
#     (route.default_interface, auto_detect_interface off);
#   - switch off or absent: autodetect, the interface is ignored;
#   - the reload signature follows the interface in effect;
#   - the migration keeps what an existing configuration did: one with an
#     interface but without the switch on (the CLI, a hand edit, podkop)
#     gets the switch on, so that the interface stays in effect; nothing
#     else changes.
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

# settings fixture: $1 name, $2 extra settings JSON members
fixture() {
  cat >"$WORK_DIR/$1.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.5",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"$2
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON
}

# The route of the configuration generated from fixture $1 (mwan3 $2).
route() {
  local out="$WORK_DIR/$1-$2.out.json"
  mkdir -p "$out.section-cache" "$out.rulesets"
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/$1.json" "$out" "127.0.0.1" "$2" "" "" "" >/dev/null
  node -e '
    const route = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).route;
    console.log(JSON.stringify({ auto: route.auto_detect_interface, iface: route.default_interface ?? null }));
  ' "$out"
}

expect_route() {
  local name="$1" mwan3="$2" expected="$3" actual
  actual="$(route "$name" "$mwan3")"
  [ "$actual" = "$expected" ] ||
    fail "$name (mwan3 $mwan3): route $actual, expected $expected"
}

fixture switch-on ', "enable_output_network_interface": "1", "output_network_interface": "wan2"'
fixture switch-off ', "enable_output_network_interface": "0", "output_network_interface": "wan2"'
fixture switch-absent ', "output_network_interface": "wan2"'
fixture switch-on-no-iface ', "enable_output_network_interface": "1"'
fixture none ''

expect_route switch-on 0 '{"auto":false,"iface":"wan2"}'
expect_route switch-on 1 '{"auto":false,"iface":"wan2"}'
expect_route switch-off 0 '{"auto":true,"iface":null}'
expect_route switch-off 1 '{"auto":false,"iface":null}'
expect_route switch-absent 0 '{"auto":true,"iface":null}'
expect_route switch-on-no-iface 0 '{"auto":true,"iface":null}'
expect_route none 0 '{"auto":true,"iface":null}'

# The reload signature: a change of the switch is a change of sing-box's
# configuration; an interface that is not in effect is none.
signature() {
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/service/state.uc" sing-box-signature-fixture "$WORK_DIR/$1.json"
}
[ "$(signature switch-on)" != "$(signature switch-off)" ] ||
  fail "switching the output interface off must change the sing-box signature"
[ "$(signature switch-off)" = "$(signature none)" ] ||
  fail "an interface behind a switched-off switch must not count in the sing-box signature"
[ "$(signature switch-absent)" = "$(signature none)" ] ||
  fail "an interface without the switch must not count in the sing-box signature"

# The migration keeps the effective behaviour of existing configurations.
migrate() {
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/migration.uc" \
    migrate-fixture "$WORK_DIR/$1.json" >"$WORK_DIR/$1.migrated.json"
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).config.settings;
    console.log(JSON.stringify({
      flag: s.enable_output_network_interface ?? null,
      iface: s.output_network_interface ?? null,
      recorded: (s.applied_migrations || []).includes("output_network_interface_switch_v1"),
    }));
  ' "$WORK_DIR/$1.migrated.json"
}

expect_migrated() {
  local name="$1" expected="$2" actual
  actual="$(migrate "$name")"
  [ "$actual" = "$expected" ] || fail "$name: migrated to $actual, expected $expected"
}

expect_migrated switch-absent '{"flag":"1","iface":"wan2","recorded":true}'
expect_migrated switch-off '{"flag":"1","iface":"wan2","recorded":true}'
expect_migrated switch-on '{"flag":"1","iface":"wan2","recorded":true}'
expect_migrated switch-on-no-iface '{"flag":"1","iface":null,"recorded":true}'
expect_migrated none '{"flag":null,"iface":null,"recorded":true}'

# After the migration the generated route is the one before the change of
# the runtime: the interface the old runtime used.
cp "$WORK_DIR/switch-absent.json" "$WORK_DIR/legacy.json"
node -e '
  const fs = require("fs");
  const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).config;
  out.section = [ JSON.parse(fs.readFileSync(process.argv[2], "utf8")).section[0] ];
  fs.writeFileSync(process.argv[3], JSON.stringify(out));
' "$WORK_DIR/switch-absent.migrated.json" "$WORK_DIR/switch-absent.json" "$WORK_DIR/legacy-migrated.json"
expect_route legacy-migrated 0 '{"auto":false,"iface":"wan2"}'

# Once recorded, the migration does not run again: a switch the user turns
# off afterwards stays off.
node -e '
  const fs = require("fs");
  const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).config;
  out.settings.enable_output_network_interface = "0";
  fs.writeFileSync(process.argv[2], JSON.stringify(out));
' "$WORK_DIR/switch-absent.migrated.json" "$WORK_DIR/turned-off.json"
expect_migrated turned-off '{"flag":"0","iface":"wan2","recorded":true}'

# The warning a start logs under mwan3 (singbox/runtime.uc init-config)
# names the interface only while it is in effect. The settings come from
# the core/uci.uc state fixture; mwan3 is reported active, and the
# subscription caches step fails, so init-config stops right after the
# warning (nothing else runs; all paths stay in the work directory).
REAL_UCODE="$(command -v ucode)"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/tmp"
cat >"$WORK_DIR/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */config/validator.uc) [ "${4:-}" = mwan3-is-active ] && exit 0 ;;
esac
exit 1
STUB
cat >"$WORK_DIR/bin/logger" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
STUB
chmod +x "$WORK_DIR/bin/ucode" "$WORK_DIR/bin/logger"
runtime_warning() { # runtime_warning <enable flag or ''>
  {
    printf 'prokop.settings=settings\n'
    printf 'prokop.settings.config_path=%s\n' "$WORK_DIR/run/config.json"
    printf 'prokop.settings.output_network_interface=wan2\n'
    [ -z "$1" ] || printf 'prokop.settings.enable_output_network_interface=%s\n' "$1"
  } >"$WORK_DIR/uci.state"
  : >"$WORK_DIR/logger.log"
  PATH="$WORK_DIR/bin:$PATH" TMPDIR="$WORK_DIR/tmp" LOGGER_LOG="$WORK_DIR/logger.log" \
    PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" PROKOP_UCI_LOG_FILE="$WORK_DIR/uci.log" \
    PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" TMP_SING_BOX_FOLDER="$WORK_DIR/run/sing-box" \
    "$REAL_UCODE" -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/runtime.uc" init-config 0 0 0 >/dev/null 2>&1 || true
  grep 'mwan3 is active' "$WORK_DIR/logger.log" || true
}
case "$(runtime_warning 1)" in
  *"Output Network Interface is set to 'wan2'"*"pinned"*) ;;
  *) fail "switch on: the mwan3 warning must name the pinned interface: $(cat "$WORK_DIR/logger.log")" ;;
esac
for flag in 0 ''; do
  warning="$(runtime_warning "$flag")"
  case "$warning" in
    *pinned*|*wan2*) fail "switch '$flag': the mwan3 warning names an interface that is not in effect: $warning" ;;
    *"auto_detect_interface"*) ;;
    *) fail "switch '$flag': no mwan3 warning: $(cat "$WORK_DIR/logger.log")" ;;
  esac
done

printf 'output_network_interface_flag: ok\n'
