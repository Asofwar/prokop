#!/usr/bin/env bash
# dnsmasq after a migration from the product before the rename
# (core/legacy_forkop.uc): its backups of the original options (forkop_*) and
# its old dnsmasq section are taken over once its package is gone, sing-box's
# own address is never kept as an original upstream, and while that product
# runs with its package installed Prokop neither configures nor restores
# dnsmasq.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
APPLY="$LIB/dns/apply.uc"
KS_UC="$LIB/killswitch/runtime.uc"
WORK_DIR="$(mktemp -d)"
STATE="$WORK_DIR/uci.state"
LEGACY_ROOT="$WORK_DIR/legacy-root"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'UCI state:\n' >&2
  cat "$STATE" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/tables"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/bin/sh
if [ "$1 $2" = "list tables" ]; then
  for table in "$WORK_DIR"/tables/*; do
    [ -e "$table" ] && printf 'table inet %s\n' "${table##*/}"
  done
fi
exit 0
NFT
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK_DIR/logger.log"
SH
cat >"$WORK_DIR/bin/dnsmasq-init" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK_DIR/dnsmasq.log"
SH
chmod 0755 "$WORK_DIR/bin/"*
cat >"$WORK_DIR/uci-get.uc" <<'UCODE'
let uci = require("core.uci");
if (!uci.exists(ARGV[0]))
    exit(1);
print(uci.get(ARGV[0]), "\n");
UCODE

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_UCI_STATE_FILE="$STATE"
export PROKOP_UCI_LOG_FILE="$WORK_DIR/uci.log"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_CONFIG_NAME=prokop
export SB_DNS_INBOUND_ADDRESS=127.0.0.42
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export PROKOP_LEGACY_FORKOP_ROOT="$LEGACY_ROOT"

dns() {
  ucode -L "$LIB" "$APPLY" "$@"
}

value() {
  ucode -L "$LIB" "$WORK_DIR/uci-get.uc" "$1" 2>/dev/null || true
}

assert_value() {
  [ "$(value "$1")" = "$2" ] || fail "$1: expected '$2', got '$(value "$1")'"
}

assert_absent() {
  if ucode -L "$LIB" "$WORK_DIR/uci-get.uc" "$1" >/dev/null 2>&1; then
    fail "$1 must be absent"
  fi
}

legacy_package() {
  mkdir -p "$LEGACY_ROOT/etc/init.d"
  printf '#!/bin/sh\n[ "$1" != status ] || exit 1\n' > "$LEGACY_ROOT/etc/init.d/forkop"
  chmod 0755 "$LEGACY_ROOT/etc/init.d/forkop"
}

# What the old product left in dhcp when its stop did not restore dnsmasq:
# sing-box as the only server and its backups of the original options.
leftovers() {
  cat >"$STATE" <<'EOF'
prokop.settings=settings
prokop.settings.shutdown_correctly=1
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].noresolv=1
dhcp.@dnsmasq[0].cachesize=0
dhcp.@dnsmasq[0].notinterface=wan br-guest
dhcp.@dnsmasq[0].forkop_server=9.9.9.9 127.0.0.42#53 1.0.0.1
dhcp.@dnsmasq[0].forkop_noresolv=0
dhcp.@dnsmasq[0].forkop_cachesize=1000
dhcp.@dnsmasq[0].forkop_notinterface=wan
dhcp.forkop=dnsmasq
dhcp.forkop.interface=br-guest
EOF
  : > "$WORK_DIR/dnsmasq.log"
}

# 1. Once the old package is gone its backups are Prokop's: a start points
#    dnsmasq at sing-box and keeps the originals the old product saved, and a
#    stop brings exactly those back.
leftovers
dns has-managed-state || fail "old backups must count as managed dnsmasq state"
dns configure force || fail "configure failed"
assert_value 'dhcp.@dnsmasq[0].prokop_server' '9.9.9.9 1.0.0.1'
assert_value 'dhcp.@dnsmasq[0].prokop_noresolv' '0'
assert_value 'dhcp.@dnsmasq[0].prokop_cachesize' '1000'
for key in server noresolv cachesize notinterface; do
  assert_absent "dhcp.@dnsmasq[0].forkop_$key"
done
assert_absent 'dhcp.forkop'
assert_value 'dhcp.@dnsmasq[0].notinterface' 'wan'
assert_value 'dhcp.@dnsmasq[0].server' '127.0.0.42'
grep -Fxq restart "$WORK_DIR/dnsmasq.log" || fail "configure must restart dnsmasq"
dns restore force || fail "restore failed"
assert_value 'dhcp.@dnsmasq[0].server' '9.9.9.9 1.0.0.1'
assert_value 'dhcp.@dnsmasq[0].noresolv' '0'
assert_value 'dhcp.@dnsmasq[0].cachesize' '1000'
assert_absent 'dhcp.@dnsmasq[0].prokop_server'

# 2. A plain restore takes the old backups over as well.
leftovers
dns failsafe-restore || fail "failsafe restore failed"
assert_value 'dhcp.@dnsmasq[0].server' '9.9.9.9 1.0.0.1'
assert_value 'dhcp.@dnsmasq[0].noresolv' '0'
assert_value 'dhcp.@dnsmasq[0].cachesize' '1000'
assert_value 'dhcp.@dnsmasq[0].notinterface' 'wan'
assert_absent 'dhcp.@dnsmasq[0].forkop_server'
assert_absent 'dhcp.forkop'

# 3. sing-box is never kept as the original upstream, with or without a port.
cat >"$STATE" <<'EOF'
prokop.settings=settings
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=127.0.0.42#53 8.8.4.4
dhcp.@dnsmasq[0].prokop_server=127.0.0.42
EOF
dns configure force || fail "configure over a stale backup failed"
assert_value 'dhcp.@dnsmasq[0].prokop_server' '8.8.4.4'
cat >"$STATE" <<'EOF'
prokop.settings=settings
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].prokop_server=127.0.0.42#53
EOF
dns restore force || fail "restore over a stale backup failed"
assert_absent 'dhcp.@dnsmasq[0].server'
assert_value 'dhcp.@dnsmasq[0].noresolv' '0'

# 4. While the old package is installed its backups stay its own.
leftovers
legacy_package
if dns has-managed-state && [ "$(value 'dhcp.@dnsmasq[0].prokop_server')" = "" ] &&
  ! ucode -L "$LIB" "$WORK_DIR/uci-get.uc" dhcp.forkop >/dev/null 2>&1; then
  fail "old backups of an installed old package are not Prokop's state"
fi
dns configure force || fail "configure next to the stopped old package failed"
assert_value 'dhcp.@dnsmasq[0].forkop_server' '9.9.9.9 127.0.0.42#53 1.0.0.1'
assert_value 'dhcp.@dnsmasq[0].forkop_noresolv' '0'
assert_absent 'dhcp.@dnsmasq[0].prokop_server'

# 5. The old product runs with its package installed: dnsmasq is its own.
leftovers
legacy_package
touch "$WORK_DIR/tables/ForkopTable"
cp "$STATE" "$WORK_DIR/state.before"
: > "$WORK_DIR/uci.log"
if dns configure force; then
  fail "configure next to the running old product must fail"
fi
dns restore force || fail "restore next to the running old product must succeed without change"
dns failsafe-restore || fail "failsafe restore next to the running old product must succeed without change"
dns killswitch-refresh release-legacy || fail "kill-switch refresh next to the running old product must succeed"
cmp -s "$STATE" "$WORK_DIR/state.before" || fail "dhcp must not change while the old product runs"
[ ! -s "$WORK_DIR/dnsmasq.log" ] && [ ! -s "$WORK_DIR/uci.log" ] || fail "dnsmasq must not be touched while the old product runs"
grep -Fq 'belongs to the running Forkop' "$WORK_DIR/logger.log" || fail "the skipped DNS change must be logged"
rm -f "$WORK_DIR/tables/ForkopTable" "$LEGACY_ROOT/etc/init.d/forkop"

# 6. The standby resolver of the kill-switch forwards to the original
#    upstream the old product saved, never to sing-box.
leftovers
mkdir -p "$KILLSWITCH_STATE_DIR"
ucode -L "$LIB" "$KS_UC" standby-config "$WORK_DIR/standby.conf" || fail "standby config failed"
grep -Fxq 'server=9.9.9.9' "$WORK_DIR/standby.conf" && grep -Fxq 'server=1.0.0.1' "$WORK_DIR/standby.conf" ||
  fail "the standby resolver must use the old backup of the upstream: $(cat "$WORK_DIR/standby.conf")"
if grep -q '127.0.0.42' "$WORK_DIR/standby.conf"; then fail "the standby resolver must not forward to sing-box"; fi
grep -Fxq 'resolv-file=/tmp/resolv.conf.d/resolv.conf.auto' "$WORK_DIR/standby.conf" ||
  fail "the old noresolv=0 backup must keep the resolv file"

printf 'prokop_from_forkop_runtime_dns: PASS\n'
