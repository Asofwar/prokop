#!/usr/bin/env bash
set -euo pipefail

# Interface Monitoring Delay (settings.badwan_reload_delay) is a number of
# milliseconds procd waits before the reload an interface coming up asks for
# (UC-089).
# - init.d sets PROCD_RELOAD_DELAY from the trigger plan (service/initd.uc
#   trigger-plan), and procd.sh reads it for each trigger it adds: the delay
#   used to apply to the config.change reload as well. The config.change
#   reload keeps the default 2000 ms; the option delays only the interface
#   reloads it is named after.
# - A value that is not a whole number ("2s", the duration style of the rest
#   of the page) failed procd.sh's numeric test, so the reloads had no delay
#   at all. The plan falls back to the default 2000 ms for it, the validator
#   reports it in the system log without refusing a configuration that
#   started before (invariant 17), and the Settings page refuses it, as any
#   value outside 0..60000 ms, when it is entered. A value saved before is
#   left as it is: it does not refuse the save of the rest of the page.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
INITD="$ROOT_DIR/prokop/files/etc/init.d/prokop"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

mkdir -p "$WORK/bin"
cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
SH
chmod 0755 "$WORK/bin/logger"

# The triggers init.d registers for a configuration, each with the delay
# procd.sh gives it (_procd_add_timeout reads PROCD_RELOAD_DELAY when the
# trigger is added and adds no timeout unless it is a number above 0).
cat >"$WORK/triggers.sh" <<'SH'
#!/usr/bin/env bash
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
PROKOP_LIB="$TEST_LIB"
PROKOP_INITD_UC="$TEST_LIB/service/initd.uc"
timeout_of() {
  if [ "$PROCD_RELOAD_DELAY" -gt 0 ] 2>/dev/null; then printf '%s' "$PROCD_RELOAD_DELAY"; else printf none; fi
}
procd_open_trigger() { :; }
procd_close_trigger() { :; }
procd_add_config_trigger() { printf 'config %s %s\n' "$2" "$(timeout_of)"; }
procd_add_interface_trigger() { printf 'interface %s %s\n' "$2" "$(timeout_of)"; }
PROCD_RELOAD_DELAY=""
service_triggers
SH

# triggers <name> [state lines]: the registered triggers for these settings.
triggers() {
  local name="$1"
  shift
  {
    printf 'prokop.settings=settings\n'
    printf 'prokop.settings.%s\n' "$@"
  } >"$WORK/$name.state"
  REAL_INITD="$INITD" TEST_LIB="$LIB" PROKOP_UCI_STATE_FILE="$WORK/$name.state" \
    bash "$WORK/triggers.sh" >"$WORK/$name.triggers" 2>"$WORK/$name.err"
}

# expect_triggers <name> <expected triggers, one per line>
expect_triggers() {
  local name="$1" expected="$2"
  [ "$(cat "$WORK/$name.triggers")" = "$expected" ] ||
    fail "$name: triggers differ: got
$(cat "$WORK/$name.triggers")
want
$expected"
}

monitored=(enable_badwan_interface_monitoring=1 'badwan_monitored_interfaces=wan vpn0')

triggers default "${monitored[@]}"
expect_triggers default "config prokop 2000
interface wan 2000
interface vpn0 2000"

triggers custom "${monitored[@]}" badwan_reload_delay=3500
expect_triggers custom "config prokop 2000
interface wan 3500
interface vpn0 3500"

triggers duration_text "${monitored[@]}" badwan_reload_delay=2s
expect_triggers duration_text "config prokop 2000
interface wan 2000
interface vpn0 2000"

triggers no_delay "${monitored[@]}" badwan_reload_delay=0
expect_triggers no_delay "config prokop 2000
interface wan none
interface vpn0 none"

# Above 60000 ms the Settings page refuses a new value; one saved before keeps
# working as it did.
triggers large "${monitored[@]}" badwan_reload_delay=120000
expect_triggers large "config prokop 2000
interface wan 120000
interface vpn0 120000"

# More than procd takes as a 32-bit timeout.
triggers overflow "${monitored[@]}" badwan_reload_delay=99999999999
expect_triggers overflow "config prokop 2000
interface wan 2000
interface vpn0 2000"

# Monitoring off: wan still reloads after the delay.
triggers unmonitored badwan_reload_delay=4000
expect_triggers unmonitored "config prokop 2000
interface wan 4000"

# The validator reports a value the plan ignores and accepts the
# configuration; a whole number is not reported.
validate() {
  local name="$1" members="$2"
  printf '{ "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret"%s }, "section": [ { ".name": "b", ".type": "section", "enabled": "1", "action": "block", "domain": "example.com" } ] }\n' \
    "${members:+, $members}" >"$WORK/$name.json"
  : >"$WORK/$name.log"
  PATH="$WORK/bin:$PATH" LOGGER_LOG="$WORK/$name.log" PROKOP_LIB="$LIB" \
    ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/$name.json" '{}' >"$WORK/$name.out" 2>&1
}

if validate invalid_delay '"enable_badwan_interface_monitoring": "1", "badwan_reload_delay": "2s"'; then
  grep -q "\[warn\].*badwan_reload_delay.*'2s'.*2000" "$WORK/invalid_delay.log" ||
    fail "the validator should report the ignored delay '2s' ($(cat "$WORK/invalid_delay.log"))"
else
  fail "a configuration with the delay '2s' started before and must still be accepted ($(cat "$WORK/invalid_delay.out"))"
fi
if validate valid_delay '"enable_badwan_interface_monitoring": "1", "badwan_reload_delay": "3500"'; then
  [ ! -s "$WORK/valid_delay.log" ] ||
    fail "a whole number of milliseconds must not be reported ($(cat "$WORK/valid_delay.log"))"
else
  fail "the delay 3500 must be accepted ($(cat "$WORK/valid_delay.out"))"
fi

if [ "$failures" -ne 0 ]; then
  printf '%d interface monitoring delay check(s) failed\n' "$failures" >&2
  exit 1
fi

# The Settings page refuses an entered value the plan would ignore, and one
# above a minute. A value saved before, which the backend keeps using (a
# number) or replaces with the default and reports (anything else), does not
# refuse the save of the rest of the page while it is left unchanged.
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

function config(delay) {
  return {
    settings: { '.name': 'settings', '.type': 'settings', '.anonymous': false,
      yacd_secret_key: 'secret-0123456789', enable_badwan_interface_monitoring: '1',
      badwan_monitored_interfaces: ['wan'], badwan_reload_delay: delay },
  };
}
const capabilities = { loaded: true, zapretInstalled: true, zapret2Installed: true, byedpiInstalled: true };

(async () => {
  for (const version of ['24.10', '25.12']) {
    const env = createEnvironment({ version, config: config('2000') });
    const settings = await env.openSettings(capabilities);
    const delay = settings.option('badwan_reload_delay');
    for (const value of ['0', '2000', '60000'])
      assert.equal(delay.validate('settings', value), true, `${version}: ${value} ms must be accepted`);
    for (const value of ['', '2s', '1.5', '-1', '60001', '2000 ', 'abc'])
      assert.notEqual(delay.validate('settings', value), true, `${version}: '${value}' must be refused`);

    for (const stored of ['2s', '120000']) {
      const stale = createEnvironment({ version, config: config(stored) });
      const page = await stale.openSettings(capabilities);
      const field = page.option('badwan_reload_delay');
      assert.equal(field.validate('settings', stored), true,
        `${version}: the saved '${stored}' left unchanged must be accepted`);
      page.option('dns_rewrite_ttl').getUIElement('settings').setValue('30');
      await page.save();
      assert.equal(stale.uci.data.settings.dns_rewrite_ttl, '30', `${version}: the rest of the page saves next to '${stored}'`);
      assert.equal(stale.uci.data.settings.badwan_reload_delay, stored, `${version}: '${stored}' is kept as it was`);

      // Edited, it is checked as any new value.
      field.getUIElement('settings').setValue(`${stored}0`);
      await assert.rejects(page.save(), undefined, `${version}: '${stored}0' must be refused`);
      field.getUIElement('settings').setValue('2000');
      await page.save();
      assert.equal(stale.uci.data.settings.badwan_reload_delay, '2000');
    }
  }
})().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
NODE

printf 'interface monitoring delay is a validated number of milliseconds for interface reloads only\n'
