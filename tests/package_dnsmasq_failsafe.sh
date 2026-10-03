#!/usr/bin/env bash
# The second-line dnsmasq restore of the package scripts runs (UC-078).
#
# service/package.uc prerm gives dnsmasq back its own DNS: first through
# `prokop restore_dnsmasq`, then, whatever that did, through the failsafe
# restore of dns/apply.uc. That module loads Prokop's own modules (core.uci,
# core.durable): ucode finds them only on the library path -L names. The
# failsafe was run without it and always ended with "No module named
# 'core.uci'", so when the first restore failed dnsmasq kept forwarding to
# the DNS of a Prokop the package removal had just taken away.
#
# The real service/package.uc runs the real dns/apply.uc from a directory
# that holds no module, against an init.d, nft, ip and logger that record
# what they are asked to do and a dnsmasq configuration in a UCI state file.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
PACKAGE_UC="$LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  [ ! -s "$WORK_DIR/stderr" ] || sed 's/^/  stderr: /' "$WORK_DIR/stderr" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/cwd"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS
export PROKOP_LIB="$LIB"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_INIT="$WORK_DIR/prokop-init"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_DNS_APPLY_UC="$LIB/dns/apply.uc"
export PROKOP_KILLSWITCH_UC="$WORK_DIR/missing-killswitch.uc"
export PROKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init"
export PROKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box"
export PROKOP_SING_BOX_CRONET="$WORK_DIR/missing-libcronet.so"
export PROKOP_RT_TABLES="$WORK_DIR/rt_tables"
export PROKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export KILLSWITCH_STATE_DIR="$WORK_DIR/killswitch"

# Prokop stops for its removal and leaves no interception behind.
cat >"$PROKOP_INIT" <<'SH'
#!/bin/sh
printf 'prokop %s\n' "$*" >>"$EVENTS"
SH
# The first-line restore fails without touching dnsmasq.
cat >"$PROKOP_BIN" <<'SH'
#!/bin/sh
printf 'cli %s\n' "$*" >>"$EVENTS"
[ "$1" != restore_dnsmasq ] || exit 1
SH
for name in dnsmasq-init logger; do
  # shellcheck disable=SC2016 # expanded by the stub when it runs
  printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"$EVENTS"\n' "$name" >"$WORK_DIR/bin/$name"
done
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
chmod 0755 "$PROKOP_INIT" "$WORK_DIR/bin/"*

uci_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2) }' "$PROKOP_UCI_STATE_FILE"
}

# dnsmasq forwards to Prokop's DNS and keeps its own servers aside.
cat >"$PROKOP_UCI_STATE_FILE" <<'EOF'
prokop.settings=settings
prokop.settings.dont_touch_dhcp=0
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].noresolv=1
dhcp.@dnsmasq[0].cachesize=0
dhcp.@dnsmasq[0].prokop_server=1.1.1.1 8.8.8.8
dhcp.@dnsmasq[0].prokop_noresolv=0
dhcp.@dnsmasq[0].prokop_cachesize=150
EOF
printf '100 main\n105 prokop\n' >"$PROKOP_RT_TABLES"

# From a directory without Prokop's modules, as opkg and apk run prerm.
status=0
(cd "$WORK_DIR/cwd" && ucode -L "$LIB" "$PACKAGE_UC" prerm remove) 2>"$WORK_DIR/stderr" || status=$?
[ "$status" -eq 0 ] || fail "package prerm remove exited $status"
grep -Fxq 'cli restore_dnsmasq' "$EVENTS" || fail "prerm did not try the first-line dnsmasq restore"
if grep -Fq "No module named" "$WORK_DIR/stderr"; then
  fail "the dnsmasq failsafe could not load Prokop's modules"
fi
[ "$(uci_value 'dhcp.@dnsmasq[0].server')" = '1.1.1.1 8.8.8.8' ] ||
  fail "the dnsmasq failsafe did not give dnsmasq back its servers: $(uci_value 'dhcp.@dnsmasq[0].server')"
[ "$(uci_value 'dhcp.@dnsmasq[0].noresolv')" = 0 ] || fail "the dnsmasq failsafe did not restore noresolv"
[ -z "$(uci_value 'dhcp.@dnsmasq[0].prokop_server')" ] || fail "the dnsmasq failsafe left Prokop's saved servers behind"
grep -Fxq 'dnsmasq-init restart' "$EVENTS" || fail "the dnsmasq failsafe did not restart dnsmasq"

# Every ucode module package.uc runs needs Prokop's library path.
while IFS= read -r line; do
  case "$line" in
    *'"ucode", "-L", LIB_DIR,'*) ;;
    *) fail "service/package.uc runs a ucode module without -L: $line" ;;
  esac
done < <(grep -n '"ucode",' "$PACKAGE_UC")

printf 'package dnsmasq failsafe checks passed\n'
