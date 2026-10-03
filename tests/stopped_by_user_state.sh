#!/usr/bin/env bash
set -euo pipefail

# Prokop stopped by the user is told apart from Prokop that is down without a
# stop (a failed start, a crash) in the UI state, the service status and
# health (UC-056, D-15(a)).
#
# Before: both were "stopped but enabled" / running 0, and health reported
# the service as "error" either way, so the Overview could not say "stopped
# by the user" and a deliberate stop looked like a failure.
#
# Now service/ui.uc get-ui-state and diagnostics/runtime.uc get-status report
# stopped_by_user while the explicit stop holds the runtime down, and
# diagnostics/health.uc reports the service as "stopped" (not "error") then.
# A restore recorded as not started (the runtime was not started) is no
# failure either. A stop that Prokop made itself for a package or component
# change (its source is recorded with the stop) is not the user's.
#
# Prokop that nobody started since boot (no explicit start is recorded, no
# stop by the user) is reported as not_started and health calls it
# "not_started", not "error"; a runtime that is down after an explicit start
# is neither: it failed (D-15(a)).
#
# ui.uc, runtime.uc, state.uc and health.uc are real; nothing here runs a
# runtime, so it is down.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/tmp" "$WORK_DIR/ui"
printf 'prokop.settings=settings\n' >"$WORK_DIR/uci.state"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB="$LIB"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export PROKOP_START_IN_PROGRESS_FILE="$WORK_DIR/run/start.in-progress"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_UI_STATE_DIR="$WORK_DIR/ui"
export PROKOP_UI_SERVICE_ACTION_DIR="$WORK_DIR/ui/service-actions"
export PROKOP_UI_SERVICE_ACTION_LOCK_DIR="$WORK_DIR/ui/service-actions.lock"
export PROKOP_UI_LATENCY_ACTION_DIR="$WORK_DIR/ui/latency-actions"
export PROKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/ui/component-actions"
export PROKOP_UI_SUBSCRIPTION_ACTION_DIR="$WORK_DIR/ui/subscription-actions"
export PROKOP_UI_SING_BOX_VERSION_CACHE_FILE="$WORK_DIR/ui/sing-box-version"
export PROKOP_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/missing-variant"
export PROKOP_UI_SING_BOX_BIN_PATH="$WORK_DIR/missing-sing-box"
export ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws"
export ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2"
export BYEDPI_BIN="$WORK_DIR/missing-ciadpi"
unset PROKOP_UI_ACTION_TRACKED
STOP_MARKER="$WORK_DIR/run/stop.requested"
START_RECORD="$WORK_DIR/run/start.explicit"

# Nothing here may reach the host's syslog, nftables, procd or services.
for tool in logger nft ubus ip init prokop; do
  printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/$tool"
done
chmod +x "$WORK_DIR/bin/"*

prokop_field() { # prokop_field <json file> <field>
  ucode -e 'let v = json(require("fs").readfile(ARGV[0])); v = v.service ? v.service.prokop : v; print(v[ARGV[1]], "\n");' \
    "$1" "$2"
}
ui_state() { ucode -L "$LIB" "$LIB/service/ui.uc" get-ui-state >"$WORK_DIR/ui.json"; }
get_status() { ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" get-status >"$WORK_DIR/status.json"; }
health() { # health <prokop object> [events]
  printf '{"ui":{"service":{"prokop":%s,"sing_box":{"running":0}}},"guard":false,"package_pending":false,"events":%s}\n' \
    "$1" "${2:-[]}" >"$WORK_DIR/fixture.json"
  ucode -L "$LIB" "$LIB/diagnostics/health.uc" fixture "$WORK_DIR/fixture.json" >"$WORK_DIR/health.json"
}
health_field() {
  ucode -e 'let v = json(require("fs").readfile(ARGV[0])); for (let k in split(ARGV[1], ".")) v = v[k]; print(v, "\n");' \
    "$WORK_DIR/health.json" "$1"
}

# 1. Down after an explicit stop: stopped by the user.
printf 'stop\n' >"$STOP_MARKER"
ui_state
[ "$(prokop_field "$WORK_DIR/ui.json" running)" = 0 ] || fail "fixture: the runtime is running: $(cat "$WORK_DIR/ui.json")"
[ "$(prokop_field "$WORK_DIR/ui.json" stopped_by_user)" = 1 ] ||
  fail "the UI state does not say Prokop was stopped by the user: $(cat "$WORK_DIR/ui.json")"
get_status
[ "$(prokop_field "$WORK_DIR/status.json" stopped_by_user)" = 1 ] ||
  fail "get_status does not say Prokop was stopped by the user: $(cat "$WORK_DIR/status.json")"

[ "$(prokop_field "$WORK_DIR/ui.json" not_started)" = 0 ] ||
  fail "the UI state calls Prokop stopped by the user not started: $(cat "$WORK_DIR/ui.json")"
[ "$(prokop_field "$WORK_DIR/status.json" not_started)" = 0 ] ||
  fail "get_status calls Prokop stopped by the user not started: $(cat "$WORK_DIR/status.json")"

# 2. Down without a stop after an explicit start (a failed start, a crash):
#    neither stopped by the user nor not started.
rm -f "$STOP_MARKER"
: >"$START_RECORD"
ui_state
[ "$(prokop_field "$WORK_DIR/ui.json" stopped_by_user)" = 0 ] ||
  fail "the UI state calls a runtime down without a stop stopped by the user: $(cat "$WORK_DIR/ui.json")"
[ "$(prokop_field "$WORK_DIR/ui.json" not_started)" = 0 ] ||
  fail "the UI state calls a runtime down after an explicit start not started: $(cat "$WORK_DIR/ui.json")"
get_status
[ "$(prokop_field "$WORK_DIR/status.json" stopped_by_user)" = 0 ] ||
  fail "get_status calls a runtime down without a stop stopped by the user: $(cat "$WORK_DIR/status.json")"
[ "$(prokop_field "$WORK_DIR/status.json" not_started)" = 0 ] ||
  fail "get_status calls a runtime down after an explicit start not started: $(cat "$WORK_DIR/status.json")"

# 2a. Nobody started it since boot (no start record, no stop): not started,
#     not stopped by the user.
rm -f "$START_RECORD"
ui_state
[ "$(prokop_field "$WORK_DIR/ui.json" not_started)" = 1 ] ||
  fail "the UI state does not say Prokop was not started since boot: $(cat "$WORK_DIR/ui.json")"
[ "$(prokop_field "$WORK_DIR/ui.json" stopped_by_user)" = 0 ] ||
  fail "the UI state calls Prokop not started since boot stopped by the user: $(cat "$WORK_DIR/ui.json")"
get_status
[ "$(prokop_field "$WORK_DIR/status.json" not_started)" = 1 ] ||
  fail "get_status does not say Prokop was not started since boot: $(cat "$WORK_DIR/status.json")"
[ "$(prokop_field "$WORK_DIR/status.json" stopped_by_user)" = 0 ] ||
  fail "get_status calls Prokop not started since boot stopped by the user: $(cat "$WORK_DIR/status.json")"

# 2b. A stop that Prokop made itself for a package or component change, whose
#     start never came (a failed upgrade restart), is no stop by the user:
#     the start failed. The user's stop, recorded as such, still is one.
#     Prokop's own stop of a Prokop that nobody started since boot leaves it
#     not started.
for source in package component user; do
  for started in 1 0; do
    printf '1.000000001.42\nby=%s\n' "$source" >"$STOP_MARKER"
    rm -f "$START_RECORD"
    [ "$started" = 0 ] || [ "$source" = user ] || : >"$START_RECORD"
    want=0
    [ "$source" != user ] || want=1
    want_not_started=0
    [ "$source" = user ] || [ "$started" = 1 ] || want_not_started=1
    ui_state
    [ "$(prokop_field "$WORK_DIR/ui.json" stopped_by_user)" = "$want" ] ||
      fail "the UI state after a stop by '$source': $(cat "$WORK_DIR/ui.json")"
    [ "$(prokop_field "$WORK_DIR/ui.json" not_started)" = "$want_not_started" ] ||
      fail "the UI state after a stop by '$source' (started: $started): $(cat "$WORK_DIR/ui.json")"
    get_status
    [ "$(prokop_field "$WORK_DIR/status.json" stopped_by_user)" = "$want" ] ||
      fail "get_status after a stop by '$source': $(cat "$WORK_DIR/status.json")"
    [ "$(prokop_field "$WORK_DIR/status.json" not_started)" = "$want_not_started" ] ||
      fail "get_status after a stop by '$source' (started: $started): $(cat "$WORK_DIR/status.json")"
  done
done
rm -f "$STOP_MARKER" "$START_RECORD"

# 2c. Prokop's own stop for a component change (or a package upgrade that a
#     component action runs) while that component action is still at work:
#     its start is still to come (components/action.uc restarts Prokop when
#     the change ends). The UI state says so ("restarting"), not a failure
#     and not a plain stop; health calls it transitioning. Once the action
#     ended without the start, it is a failure again. The user's stop during
#     a component action stays the user's.
sleep 300 &
component_worker=$!
trap 'owned_kill TERM "$component_worker" || true; rm -rf "$WORK_DIR"' EXIT
mkdir -p "$PROKOP_UI_COMPONENT_ACTION_DIR"
component_job="$PROKOP_UI_COMPONENT_ACTION_DIR/1700000000-4242.json"
for source in component package user; do
  printf '1.000000001.42\nby=%s\n' "$source" >"$STOP_MARKER"
  rm -f "$START_RECORD"
  [ "$source" = user ] || : >"$START_RECORD"
  printf '{"running":true,"kind":"component","action":"install","component":"sing-box","pid":"%s","started_at":%s}\n' \
    "$component_worker" "$(date +%s)" >"$component_job"
  ui_state
  status="$(prokop_field "$WORK_DIR/ui.json" status)"
  if [ "$source" = user ]; then
    [ "$status" != restarting ] || fail "the user's stop during a component action is shown as a restart: $(cat "$WORK_DIR/ui.json")"
    [ "$(prokop_field "$WORK_DIR/ui.json" stopped_by_user)" = 1 ] ||
      fail "the user's stop during a component action: $(cat "$WORK_DIR/ui.json")"
    continue
  fi
  [ "$status" = restarting ] ||
    fail "Prokop stopped by '$source' while the component action runs is not shown as restarting: $(cat "$WORK_DIR/ui.json")"
  [ "$(prokop_field "$WORK_DIR/ui.json" stopped_by_user)" = 0 ] || fail "a stop by '$source' is shown as the user's"
  printf '{"running":0,"stopped_by_user":0,"not_started":0,"status":"%s"}' "$status" >"$WORK_DIR/prokop.json"
  health "$(cat "$WORK_DIR/prokop.json")"
  [ "$(health_field service.prokop)" = transitioning ] ||
    fail "health of Prokop stopped by '$source' for a running component action: $(cat "$WORK_DIR/health.json")"
  # The component action ended; its start never came.
  printf '{"running":false,"kind":"component","action":"install","component":"sing-box","success":false}\n' >"$component_job"
  ui_state
  [ "$(prokop_field "$WORK_DIR/ui.json" status)" != restarting ] ||
    fail "Prokop stopped by '$source' is shown as restarting after the component action ended: $(cat "$WORK_DIR/ui.json")"
  [ "$(prokop_field "$WORK_DIR/ui.json" not_started)" = 0 ] || fail "a stop by '$source' whose start never came is not a failure"
done
owned_kill TERM "$component_worker" || true
wait "$component_worker" 2>/dev/null || true
rm -f "$STOP_MARKER" "$START_RECORD" "$component_job"

# 3. Health: stopped by the user is "stopped", not a failure; down without a
#    stop stays an error; a failed change still is one.
health '{"running":0,"stopped_by_user":1}'
[ "$(health_field service.prokop)" = stopped ] || fail "health: $(cat "$WORK_DIR/health.json")"
[ "$(health_field overall)" = stopped ] || fail "health overall while stopped by the user: $(cat "$WORK_DIR/health.json")"
[ "$(health_field recovery.pending)" = false ] || fail "health: a stop is no pending recovery"
health '{"running":0,"stopped_by_user":0}'
[ "$(health_field service.prokop)" = error ] || fail "health of a runtime down without a stop: $(cat "$WORK_DIR/health.json")"
[ "$(health_field overall)" = error ] || fail "health overall of a runtime down without a stop"
health '{"running":0,"stopped_by_user":0,"not_started":0}'
[ "$(health_field service.prokop)" = error ] || fail "health of a runtime down after an explicit start: $(cat "$WORK_DIR/health.json")"
# Not started since boot is no failure either.
health '{"running":0,"stopped_by_user":0,"not_started":1}'
[ "$(health_field service.prokop)" = not_started ] || fail "health of Prokop not started: $(cat "$WORK_DIR/health.json")"
[ "$(health_field overall)" = not_started ] || fail "health overall of Prokop not started: $(cat "$WORK_DIR/health.json")"
[ "$(health_field recovery.pending)" = false ] || fail "health: not started is no pending recovery"
health '{"running":0,"stopped_by_user":1}' '[{"kind":"reload","status":"failure","timestamp":42}]'
[ "$(health_field overall)" = error ] || fail "a failed change while stopped by the user is not an error"
# A restore that left the runtime stopped is recorded and is no failure.
health '{"running":0,"stopped_by_user":1}' '[{"kind":"restore","status":"not_started","timestamp":42}]'
[ "$(health_field recovery.last_event.status)" = not_started ] || fail "a not-started restore is not kept: $(cat "$WORK_DIR/health.json")"
[ "$(health_field overall)" = stopped ] || fail "a not-started restore made health an error"
ucode -L "$LIB" "$LIB/diagnostics/health.uc" record restore not_started || fail "a not-started restore cannot be recorded"
grep -Eq '"status": *"not_started"' "$PROKOP_HISTORY_FILE" || fail "a not-started restore is not in the history"

printf 'stopped by user state checks passed\n'
