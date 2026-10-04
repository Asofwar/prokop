#!/usr/bin/env bash
set -euo pipefail

# The UI state poll (service/ui.uc get-ui-state, every second while a Prokop
# page is open) and the Clash API requests (diagnostics/runtime.uc
# clash-api, every few seconds from the Priority worker and the dashboard)
# keep their answers byte for byte, at a bounded cost (UC-146..UC-149):
#
# - the sing-box ownership scan reads /proc/<pid>/exe in-process, not with
#   one forked readlink per process (UC-146);
# - the installed sing-box package is read from the package manager only
#   when the package database or the binary changed, and the nft table
#   existence checks do not list set contents (UC-147);
# - a Clash API request encodes the tag in-process and asks for the listen
#   address once (UC-148);
# - the read-only listen-address query does not write to syslog, even with
#   service_listen_address set (UC-149).
#
# ui.uc, state.uc, diagnostics/runtime.uc and singbox/runtime.uc are real; a
# copied sleep plays the procd-owned sing-box, and ubus, nft, ip, netstat,
# curl, apk, opkg and logger are stubs that log their calls. ucode, readlink
# and mktemp are logged and run for real.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"

# The scan counts every sing-box executable in /proc, and other tests run
# sing-box doubles of their own: run in a private PID namespace where one is
# available (as tests/runtime_state_predicates.sh does).
if [ -z "${PROKOP_TEST_UI_POLL_ISOLATED:-}" ]; then
  if unshare --pid --fork --mount-proc true 2>/dev/null; then
    exec env PROKOP_TEST_UI_POLL_ISOLATED=1 unshare --pid --fork --mount-proc bash "$0" "$@"
  elif unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
    exec env PROKOP_TEST_UI_POLL_ISOLATED=1 unshare --user --map-root-user --pid --fork --mount-proc bash "$0" "$@"
  fi
fi

# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
UCODE_BIN="$(command -v ucode)"
READLINK_BIN="$(command -v readlink)"
MKTEMP_BIN="$(command -v mktemp)"
WORK_DIR="$("$MKTEMP_BIN" -d)"
SING_BOX_PID=""
cleanup() {
  [ -z "$SING_BOX_PID" ] || owned_kill KILL "$SING_BOX_PID" || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for exe in /proc/[0-9]*/exe; do
  case "$("$READLINK_BIN" "$exe" 2>/dev/null)" in
    */sing-box | */'sing-box (deleted)') fail "precondition: a sing-box process (${exe%/exe}) runs outside a private PID namespace" ;;
  esac
done

BIN="$WORK_DIR/bin"
CALLS="$WORK_DIR/calls.log"
mkdir -p "$BIN" "$WORK_DIR/sbin" "$WORK_DIR/run" "$WORK_DIR/tmp" "$WORK_DIR/ui" "$WORK_DIR/pkg"
: >"$CALLS"

logged_stub() { # logged_stub <name> <body>
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >>"%s"\n%s\n' "$1" "$CALLS" "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}
logged_stub ucode "exec '$UCODE_BIN' \"\$@\""
logged_stub readlink "exec '$READLINK_BIN' \"\$@\""
logged_stub mktemp "exec '$MKTEMP_BIN' \"\$@\""
logged_stub ubus '[ "$1 $2 $3" = "call service list" ] || exit 1
printf "{\"sing-box\":{\"instances\":{\"instance1\":{\"running\":true,\"pid\":%s}}}}\n" "$(cat "$PROKOP_TEST_SING_BOX_PID_FILE")"'
logged_stub nft 'exit 0'
logged_stub ip 'case "$*" in
  "route list table prokop") echo "local default dev lo scope host" ;;
  "-6 route list table prokop") echo "local default dev lo metric 1024 pref medium" ;;
  "-4 rule list"|"-6 rule list") echo "105: from all fwmark 0x100000/0x100000 lookup prokop" ;;
  *) exit 1 ;;
esac'
logged_stub netstat 'printf "%s\n" "udp 0 0 127.0.0.42:53 0.0.0.0:* " "tcp 0 0 0.0.0.0:1602 0.0.0.0:* LISTEN" "tcp 0 0 :::1602 :::* LISTEN"'
logged_stub curl 'for arg in "$@"; do last="$arg"; done
case "$last" in
  */version) printf "%s\n" "{\"version\":\"sing-box 1.12.0\"}" ;;
  */proxies) printf "%s\n" "{\"proxies\":{\"direct\":{\"type\":\"Direct\"},\"main-out\":{\"type\":\"VLESS\"}}}" ;;
  */connections) printf "%s\n" "{\"downloadTotal\":1,\"uploadTotal\":2,\"connections\":[]}" ;;
  *) printf "%s\n" "{\"delay\":42}" ;;
esac'
logged_stub apk '[ "$1 $2 $3" = "list --installed --manifest" ] || exit 1
printf "%s\n" "sing-box-extended 1.12.0-r1" "ca-bundle 20240203-r1"'
logged_stub opkg 'exit 1'
logged_stub logger 'exit 0'
for tool in init prokop; do
  logged_stub "$tool" 'exit 1'
done

cp "$(command -v sleep)" "$WORK_DIR/sbin/sing-box"
"$WORK_DIR/sbin/sing-box" 300 &
SING_BOX_PID=$!
printf '%s\n' "$SING_BOX_PID" >"$WORK_DIR/sing-box.pid"
printf 'C:Q1\nP:sing-box-extended\nV:1.12.0-r1\n' >"$WORK_DIR/pkg/installed"

cat >"$WORK_DIR/uci.state" <<'UCI'
prokop.settings=settings
prokop.settings.service_listen_address=192.168.7.1
UCI

export TMPDIR="$WORK_DIR/tmp"
export PATH="$BIN:$PATH"
export PROKOP_TEST_SING_BOX_PID_FILE="$WORK_DIR/sing-box.pid"
export PROKOP_LIB="$LIB"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export PROKOP_START_IN_PROGRESS_FILE="$WORK_DIR/run/start.in-progress"
export PROKOP_SERVICE_INIT="$BIN/init"
export PROKOP_BIN="$BIN/prokop"
export PROKOP_SING_BOX_BIN="$WORK_DIR/sbin/sing-box"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/managed-upgrade"
export PROKOP_UI_STATE_DIR="$WORK_DIR/ui"
export PROKOP_UI_SERVICE_ACTION_DIR="$WORK_DIR/ui/service-actions"
export PROKOP_UI_SERVICE_ACTION_LOCK_DIR="$WORK_DIR/ui/service-actions.lock"
export PROKOP_UI_LATENCY_ACTION_DIR="$WORK_DIR/ui/latency-actions"
export PROKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/ui/component-actions"
export PROKOP_UI_SUBSCRIPTION_ACTION_DIR="$WORK_DIR/ui/subscription-actions"
export PROKOP_UI_SING_BOX_VERSION_CACHE_FILE="$WORK_DIR/ui/sing-box-version"
export PROKOP_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/missing-variant"
export PROKOP_UI_SING_BOX_BIN_PATH="$WORK_DIR/sbin/sing-box"
export PROKOP_UI_APK_DB_FILE="$WORK_DIR/pkg/installed"
export PROKOP_UI_OPKG_STATUS_FILE="$WORK_DIR/pkg/missing-status"
export ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/missing-nfqws"
export ZAPRET2_PROVIDER_NFQWS2_BIN="$WORK_DIR/missing-nfqws2"
export BYEDPI_BIN="$WORK_DIR/missing-ciadpi"
export NFT_FAKEIP_MARK=0x100000
unset PROKOP_UI_ACTION_TRACKED

calls() { # calls <tool>: how many times the tool ran since the log was cleared
  grep -c "^$1 " "$CALLS" || true
}

ui_state() {
  : >"$CALLS"
  "$UCODE_BIN" -L "$LIB" "$LIB/service/ui.uc" get-ui-state
}

# The runtime counts as stably running once sing-box is 2 seconds old.
for _ in $(seq 1 50); do
  age="$(ps -o etimes= -p "$SING_BOX_PID" 2>/dev/null | tr -d ' ')"
  [ "${age:-0}" -ge 3 ] && break
  sleep 0.2
done

# 1. The UI state of a running Prokop, byte for byte.
expected='{ "service": { "prokop": { "running": 1, "enabled": 0, "status": "running but disabled", "dns_configured": 0, "dhcp_user_managed": 0, "stopped_by_user": 0, "not_started": 0, "restart_blocked": 0, "stop_available": 1 }, "sing_box": { "running": 1, "enabled": 0, "status": "running but disabled" } }, "capabilities": { "sing_box_extended": 1, "sing_box_tiny": 0, "sing_box_compressed": 0, "sing_box_tailscale": 1, "sing_box_package": "sing-box-extended", "zapret_installed": 0, "zapret2_installed": 0, "byedpi_installed": 0 }, "actions": { "service": [ ], "latency": [ ], "component": [ ], "subscription": [ ] } }'
first="$(ui_state)"
[ "$first" = "$expected" ] || fail "get-ui-state of a running Prokop changed:
expected: $expected
actual:   $first
calls:
$(cat "$CALLS")"
cp "$CALLS" "$WORK_DIR/first-calls.log"

# 2. No readlink process per /proc entry (UC-146), and the nft table checks
#    leave the set contents out (UC-147).
[ "$(calls readlink)" = 0 ] || fail "the UI state poll forked readlink: $(grep '^readlink ' "$CALLS" | head -5)"
if grep '^nft ' "$CALLS" | grep -v '^nft -t ' | grep -q 'list table'; then
  fail "an nft table check lists set contents: $(grep '^nft ' "$CALLS")"
fi

# 3. The package database is read once while it and sing-box stay the same
#    (UC-147); a changed database is read again.
[ "$(calls apk)" = 1 ] || fail "the first poll did not read the package database once: $(calls apk)"
second="$(ui_state)"
[ "$second" = "$expected" ] || fail "the second poll answered differently: $second"
[ "$(calls apk)" = 0 ] || fail "an unchanged package database was read again"
[ "$(calls opkg)" = 0 ] || fail "an unchanged package database was read again with opkg"
sed -i 's/sing-box-extended 1.12.0-r1/sing-box-tiny 1.12.0-r1/' "$BIN/apk"
printf 'C:Q2\nP:sing-box-tiny\nV:1.12.0-r1\n' >"$WORK_DIR/pkg/installed.new"
mv "$WORK_DIR/pkg/installed.new" "$WORK_DIR/pkg/installed"
third="$(ui_state)"
[ "$(calls apk)" = 1 ] || fail "a changed package database was not read again"
case "$third" in
  *'"sing_box_tiny": 1, "sing_box_compressed": 0, "sing_box_tailscale": 0, "sing_box_package": "sing-box-tiny"'*) ;;
  *) fail "the poll after a package change kept the old package: $third" ;;
esac

# 4. The read-only listen-address query keeps syslog quiet (UC-149); only
#    the configuration generation tells about service_listen_address.
[ "$(calls logger)" = 0 ] || fail "the UI state poll wrote to syslog: $(grep '^logger ' "$CALLS")"
: >"$CALLS"
[ "$("$UCODE_BIN" -L "$LIB" "$LIB/singbox/runtime.uc" service-listen-address)" = 192.168.7.1 ] ||
  fail "service-listen-address does not answer the configured address"
[ "$(calls logger)" = 0 ] || fail "service-listen-address wrote to syslog: $(grep '^logger ' "$CALLS")"

# 5. A Clash API request starts no further ucode interpreter (UC-148) and
#    answers as before.
clash() {
  : >"$CALLS"
  "$UCODE_BIN" -L "$LIB" "$LIB/diagnostics/runtime.uc" clash-api "$@"
}
answer="$(clash get_proxy_latency 'main out/ü' 2000 http://cp.example/generate_204)"
[ "$answer" = '{ "delay": 42 }' ] || fail "get_proxy_latency answer: $answer"
grep -q '^curl .* -G 192\.168\.7\.1:9090/proxies/main%20out%2F%C3%BC/delay ' "$CALLS" ||
  fail "get_proxy_latency did not request the encoded tag: $(grep '^curl ' "$CALLS")"
[ "$(calls ucode)" = 0 ] || fail "get_proxy_latency started ucode: $(grep '^ucode ' "$CALLS")"
[ "$(calls logger)" = 0 ] || fail "get_proxy_latency wrote to syslog: $(grep '^logger ' "$CALLS")"
answer="$(clash get_connections)"
[ "$answer" = '{ "downloadTotal": 1, "uploadTotal": 2, "connections": [ ] }' ] || fail "get_connections answer: $answer"
[ "$(calls ucode)" = 0 ] || fail "get_connections started ucode: $(grep '^ucode ' "$CALLS")"

printf 'UI state poll cost checks passed\n'
