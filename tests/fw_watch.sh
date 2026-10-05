#!/usr/bin/env bash
set -euo pipefail
# NET-4: `fw4 flush` (firewall stop, restart) deletes ProkopTable. The
# firewall watcher reloads Prokop when fw4's state file changed and the table
# is gone while Prokop should run, and never otherwise. An idle pass runs no
# process: nft is asked only after a firewall change or on the periodic
# check.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/run"
cat >"$WORK/bin/nft" <<SH
#!/bin/sh
echo "nft \$*" >>"$WORK/calls"
[ -e "$WORK/table" ]
SH
cat >"$WORK/bin/logger" <<SH
#!/bin/sh
echo "logger \$*" >>"$WORK/calls"
SH
cat >"$WORK/bin/ubus" <<SH
#!/bin/sh
echo "ubus \$*" >>"$WORK/calls"
SH
# Prokop's reload brings the table back unless told not to.
cat >"$WORK/init" <<SH
#!/bin/sh
echo "init \$*" >>"$WORK/calls"
[ -e "$WORK/reload-fails" ] || : >"$WORK/table"
SH
chmod +x "$WORK/bin/"* "$WORK/init"

export PROKOP_FW4_STATE_FILE="$WORK/fw4.state" PROKOP_RUNTIME_STATE_DIR="$WORK/run" \
  PROKOP_RELOAD_LOCK_DIR="$WORK/reload.lock" PROKOP_SERVICE_INIT="$WORK/init" \
  PROKOP_FW_WATCH_INTERVAL_MS=50 PROKOP_FW_WATCH_SWEEP_PASSES=1000 PROKOP_FW_WATCH_BACKOFF_PASSES=1000
unset PROKOP_STOP_REQUESTED_FILE

# reset: Prokop started and its table in place, fw4 state written once.
reset() {
  : >"$WORK/calls"
  rm -rf "$WORK/reload.lock" "$WORK/reload-fails" "$WORK/run/stop.requested"
  printf '0\n' >"$WORK/run/shutdown_correctly"
  : >"$WORK/table"
  printf 'first\n' >"$WORK/fw4.state"
}
# fw4_restart: fw4 flush took every table, fw4 start wrote its state again.
fw4_restart() {
  rm -f "$WORK/table"
  printf 'restarted %s\n' "$RANDOM" >"$WORK/fw4.state.new"
  mv "$WORK/fw4.state.new" "$WORK/fw4.state"
}
# watch PASSES [ACTION]: runs the watcher for PASSES passes, ACTION after the
# first few.
watch() {
  PATH="$WORK/bin:$PATH" PROKOP_FW_WATCH_ITERATIONS="$1" \
    ucode -L "$LIB" "$LIB/service/fw_watch.uc" watch &
  local pid=$!
  if [ -n "${2:-}" ]; then
    sleep 0.3
    "$2"
  fi
  wait "$pid" || fail "the watcher exited with an error"
}
count() { grep -c "$1" "$WORK/calls" || :; }

# 1. Idle passes run nothing.
reset
watch 20
[ ! -s "$WORK/calls" ] || fail "idle passes ran processes: $(cat "$WORK/calls")"

# 2. A firewall restart that took the table: one reload.
reset
watch 30 fw4_restart
[ "$(count '^init reload firewall$')" = 1 ] || fail "no single reload after the firewall restart: $(cat "$WORK/calls")"
[ -e "$WORK/table" ] || fail "the table is not back"

# 3. A firewall reload that kept the table: nft asked once, no reload.
keep_table_restart() {
  printf 'reloaded\n' >"$WORK/fw4.state.new"
  mv "$WORK/fw4.state.new" "$WORK/fw4.state"
}
reset
watch 30 keep_table_restart
[ "$(count '^nft ')" = 1 ] || fail "the table was not checked once after the firewall reload: $(cat "$WORK/calls")"
[ "$(count '^init ')" = 0 ] || fail "a reload ran although the table was there"

# 4. Prokop stopped (cleanly or by the user) or in a lifecycle action: no reload.
for state in stopped requested locked; do
  reset
  case "$state" in
    stopped) printf '1\n' >"$WORK/run/shutdown_correctly" ;;
    requested) : >"$WORK/run/stop.requested" ;;
    locked)
      mkdir "$WORK/reload.lock"
      printf '%s\n' "$$" >"$WORK/reload.lock/pid"
      ;;
  esac
  watch 30 fw4_restart
  [ "$(count '^init ')" = 0 ] || fail "$state: Prokop was reloaded: $(cat "$WORK/calls")"
done

# 5. Without a firewall change the table is checked on the periodic pass.
reset
rm -f "$WORK/table"
PROKOP_FW_WATCH_SWEEP_PASSES=10 watch 15
[ "$(count '^init reload firewall$')" = 1 ] || fail "the periodic check did not reload: $(cat "$WORK/calls")"

# 6. A reload that does not bring the table back is not repeated in a loop.
reset
: >"$WORK/reload-fails"
PROKOP_FW_WATCH_SWEEP_PASSES=2 PROKOP_FW_WATCH_BACKOFF_PASSES=20 watch 20 fw4_restart
[ "$(count '^init reload firewall$')" = 1 ] || fail "the reload ran in a loop: $(count '^init ') times"

# 7. With the package gone the watcher ends itself and its procd service.
reset
mv "$WORK/init" "$WORK/init.gone"
PATH="$WORK/bin:$PATH" PROKOP_FW_WATCH_ITERATIONS=0 timeout 10 \
  ucode -L "$LIB" "$LIB/service/fw_watch.uc" watch || fail "an orphaned watcher did not end"
grep -q '^ubus call service delete .*"prokop-fw-watch"' "$WORK/calls" || fail "the orphaned watcher left its service: $(cat "$WORK/calls")"
mv "$WORK/init.gone" "$WORK/init"

# 9. Once an hour (here every 5 passes) the traffic accounting drops the
# addresses idle for a week, only while it is set up (its state file).
mkdir -p "$WORK/lib/diagnostics"
printf 'system("echo traffic " + join(" ", ARGV) + " >>%s/calls");\n' "$WORK" >"$WORK/lib/diagnostics/traffic.uc"
reset
PROKOP_LIB="$WORK/lib" PROKOP_FW_WATCH_TRAFFIC_PASSES=5 watch 12
[ "$(count '^traffic ')" = 0 ] || fail "the traffic expiry ran without the accounting: $(cat "$WORK/calls")"
reset
printf '{}\n' >"$WORK/run/traffic.json"
PROKOP_LIB="$WORK/lib" PROKOP_FW_WATCH_TRAFFIC_PASSES=5 watch 12
[ "$(count '^traffic expire$')" = 2 ] || fail "the traffic expiry did not run every 5 passes: $(cat "$WORK/calls")"
rm -f "$WORK/run/traffic.json"

# 8. The service script runs the watcher and is enabled with the package.
# shellcheck disable=SC2016
if ! grep -q '^FW_WATCH_UC="$PROKOP_LIB/service/fw_watch.uc"$' "$ROOT_DIR/prokop/files/etc/init.d/prokop-fw-watch" ||
  ! grep -q '"$FW_WATCH_UC" watch$' "$ROOT_DIR/prokop/files/etc/init.d/prokop-fw-watch"; then
  fail "prokop-fw-watch does not run the watcher"
fi
grep -q 'fw_watch_postinst();' "$LIB/service/package.uc" || fail "postinst does not enable the watcher"

echo "fw_watch: OK"
