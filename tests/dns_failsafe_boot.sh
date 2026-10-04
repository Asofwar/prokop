#!/usr/bin/env bash
# LC-1: while Prokop runs, dnsmasq forwards to sing-box (127.0.0.42) and
# that is kept in /etc/config/dhcp. With autostart off, nothing started
# sing-box after a reboot and the LAN had no DNS. prokop-dns-failsafe runs at
# boot before dnsmasq and restores dnsmasq's own servers unless Prokop
# autostarts.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UCODE_LIB="$ROOT_DIR/prokop/files/usr/lib"
APPLY="$UCODE_LIB/dns/apply.uc"
INIT="$ROOT_DIR/prokop/files/etc/init.d/prokop-dns-failsafe"
WORK_DIR="$(mktemp -d)"
STATE="$WORK_DIR/uci.state"
LOG="$WORK_DIR/uci.log"
DNSMASQ_LOG="$WORK_DIR/dnsmasq.log"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  cat "$STATE" >&2 2>/dev/null || true
  exit 1
}

cat >"$WORK_DIR/uci-get.uc" <<'UCODE'
let uci = require("core.uci");
if (!uci.exists(ARGV[0]))
    exit(1);
print(uci.get(ARGV[0]), "\n");
UCODE

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/init.d"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK_DIR/syslog" >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$DNSMASQ_LOG" >"$WORK_DIR/dnsmasq-init"
# /etc/init.d/prokop as far as `enabled` goes: the S99 link of rc.common.
cat >"$WORK_DIR/init.d/prokop" <<SH
#!/bin/sh
[ "\$1" = enabled ] && [ -e "$WORK_DIR/S99prokop" ]
SH
chmod 0755 "$WORK_DIR/bin/logger" "$WORK_DIR/dnsmasq-init" "$WORK_DIR/init.d/prokop"
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_UCI_STATE_FILE="$STATE"
export PROKOP_UCI_LOG_FILE="$LOG"
export DNSMASQ_INIT="$WORK_DIR/dnsmasq-init"
export PROKOP_CONFIG_NAME="prokop"
export SB_DNS_INBOUND_ADDRESS="127.0.0.42"

# The init script with its paths pointed at the checkout, run as rcS runs
# it at boot (rc.common: source the script, call boot).
sed -e "s#^PROKOP_LIB=.*#PROKOP_LIB=\"$UCODE_LIB\"#" \
  -e "s#^PROKOP_INIT=.*#PROKOP_INIT=\"$WORK_DIR/init.d/prokop\"#" \
  "$INIT" >"$WORK_DIR/prokop-dns-failsafe"
grep -q "^START=18$" "$INIT" || fail "the hook must run before dnsmasq (S19)"
boot_hook() {
  : >"$LOG"
  : >"$DNSMASQ_LOG"
  sh -c '. "$1"; boot' sh "$WORK_DIR/prokop-dns-failsafe" || fail "boot() failed"
}

uci_get() {
  ucode -L "$UCODE_LIB" "$WORK_DIR/uci-get.uc" "$1" 2>/dev/null || true
}

# Prokop configured dnsmasq, then the router rebooted: the runtime record of
# the stop (shutdown_correctly in /var/run) is gone with the tmpfs.
prokop_ran_then_reboot() {
  cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=1.1.1.1 8.8.8.8
dhcp.@dnsmasq[0].noresolv=0
dhcp.@dnsmasq[0].cachesize=150
EOF_STATE
  ucode -L "$UCODE_LIB" "$APPLY" configure force >/dev/null 2>&1 || fail "configure failed"
  [ "$(uci_get 'dhcp.@dnsmasq[0].server')" = 127.0.0.42 ] || fail "the fixture did not forward to sing-box"
  rm -rf "$WORK_DIR/run" && mkdir -p "$WORK_DIR/run"
}

# 1. Autostart off: dnsmasq gets its own servers back before it starts.
rm -f "$WORK_DIR/S99prokop"
prokop_ran_then_reboot
boot_hook
[ "$(uci_get 'dhcp.@dnsmasq[0].server')" = '1.1.1.1 8.8.8.8' ] ||
  fail "autostart off: dnsmasq still forwards to sing-box after the boot"
[ "$(uci_get 'dhcp.@dnsmasq[0].noresolv')" = 0 ] || fail "autostart off: noresolv was not restored"
[ "$(uci_get 'dhcp.@dnsmasq[0].cachesize')" = 150 ] || fail "autostart off: cachesize was not restored"
grep -Fxq 'commit dhcp' "$LOG" || fail "autostart off: the restore was not committed"

# 2. A second boot finds nothing to do: no write, no dnsmasq restart.
boot_hook
! grep -q 'commit' "$LOG" || fail "a boot with dnsmasq already restored wrote /etc/config/dhcp"
[ ! -s "$DNSMASQ_LOG" ] || fail "a boot with dnsmasq already restored restarted dnsmasq"

# 3. Autostart on: Prokop's own start configures dnsmasq; the hook leaves it.
: >"$WORK_DIR/S99prokop"
prokop_ran_then_reboot
boot_hook
[ "$(uci_get 'dhcp.@dnsmasq[0].server')" = 127.0.0.42 ] ||
  fail "autostart on: the hook changed dnsmasq before Prokop's own start"
! grep -q 'commit' "$LOG" || fail "autostart on: the hook wrote /etc/config/dhcp"

printf 'PASS: DNS failsafe at boot\n'
