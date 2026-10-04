#!/usr/bin/env bash
set -euo pipefail

# Prokop's TPROXY rule is found whatever name iproute2 shows for table 105
# (NET-3). iproute2 names a table id by the LAST rt_tables entry for it,
# not the first: with Podkop (which also registers table 105) or the
# package before the rename still listed after Prokop's entry, `ip rule`
# showed Prokop's rule as `lookup podkop` or `lookup forkop`. Prokop did not
# find its rule: stop left it in place and the next start failed on
# `ip rule add` with "File exists". Stop also flushed table 105 under
# Podkop's rule.
#
# nft/apply.uc runs for real; `ip` is a double with the kernel's answers.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export IP_LOG="$WORK/ip.log" RULES="$WORK/rules" PROKOP_RT_TABLES="$WORK/rt_tables"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$IP_LOG" ] || sed 's/^/  ip: /' "$IP_LOG" >&2
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/ipv6"
export PATH="$WORK/bin:$PATH" PROKOP_IPV6_SYSCTL_DIR="$WORK/ipv6"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run" PROKOP_LEGACY_FORKOP_ROOT="$WORK/legacy"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
# The kernel's rules are lines "<mark> <table id>" in $RULES; `ip rule list`
# prints them under the name iproute2 picks: the last rt_tables entry.
cat >"$WORK/bin/ip" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$IP_LOG"
name() { awk -v id="$1" '$1 == id { n = $2 } END { print (n == "" ? id : n) }' "$PROKOP_RT_TABLES"; }
id() { awk -v n="$1" '$2 == n { print $1; exit }' "$PROKOP_RT_TABLES"; }
[ "$1" = -4 ] || [ "$1" = -6 ] && shift
case "$*" in
  'route list table '*) echo 'local default dev lo scope host' ;;
  'rule list')
    [ -s "$RULES" ] || exit 0
    while read -r mark table; do echo "105:	from all fwmark $mark/$mark lookup $(name "$table")"; done <"$RULES" ;;
  'rule add fwmark '*)
    set -- $*
    mark="${4%/*}" table="$(id "$6")"
    if grep -qx "$mark $table" "$RULES" 2>/dev/null; then echo 'RTNETLINK answers: File exists' >&2; exit 2; fi
    echo "$mark $table" >>"$RULES" ;;
  'rule del fwmark '*)
    set -- $*
    grep -vx "${4%/*} $(id "$6")" "$RULES" >"$RULES.new" || true
    mv "$RULES.new" "$RULES" ;;
esac
exit 0
SH
chmod 0755 "$WORK/bin/"*

nft() { ucode -L "$LIB" "$LIB/nft/apply.uc" "$@"; }
MARK=0x00100000

# 1. Podkop's entry for table 105 comes after Prokop's: the running rule is
#    found, not added a second time.
printf '%s\n' '105 prokop' '105 podkop' >"$PROKOP_RT_TABLES"
printf '0x00100000 105\n' >"$RULES"
nft tproxy-marking-rule4-present prokop "$MARK" ||
  fail "Prokop's rule shown as 'lookup podkop' was not found"
nft ensure-tproxy-route-rule prokop "$MARK" "$PROKOP_RT_TABLES" ||
  fail "a start failed with Prokop's rule shown as 'lookup podkop'"
! grep -q 'rule add' "$IP_LOG" || fail "Prokop's running rule was added a second time"
[ "$(grep -c '^105 ' "$PROKOP_RT_TABLES")" = 2 ] || fail "Podkop's rt_tables entry was touched"

# 2. Stop removes Prokop's rule, and keeps table 105 for Podkop's own rule.
printf '0x00100000 105\n0x00000105 105\n' >"$RULES"
: >"$IP_LOG"
nft remove-tproxy-route-rule prokop "$MARK" || fail "removing Prokop's route and rule failed"
! grep -qx '0x00100000 105' "$RULES" || fail "stop left Prokop's rule in place"
grep -qx '0x00000105 105' "$RULES" || fail "stop removed Podkop's rule"
! grep -q 'route flush' "$IP_LOG" || fail "stop flushed table 105 under Podkop's rule"

# 3. Without another rule on table 105 the table is flushed.
printf '0x00100000 105\n' >"$RULES"
: >"$IP_LOG"
nft remove-tproxy-route-rule prokop "$MARK" || fail "removing Prokop's route and rule failed"
[ ! -s "$RULES" ] || fail "stop left Prokop's rule in place"
grep -q '^route flush table prokop' "$IP_LOG" || fail "stop did not flush Prokop's table"

# 4. The package before the rename still listed after Prokop's entry: the
#    rule shown as 'lookup forkop' is Prokop's.
mkdir -p "$WORK/legacy/etc/init.d" && printf '#!/bin/sh\n' >"$WORK/legacy/etc/init.d/forkop"
printf '%s\n' '105 prokop' '105 forkop' >"$PROKOP_RT_TABLES"
printf '0x00100000 105\n' >"$RULES"
: >"$IP_LOG"
nft ensure-tproxy-route-rule prokop "$MARK" "$PROKOP_RT_TABLES" ||
  fail "a start failed with Prokop's rule shown as 'lookup forkop'"
! grep -q 'rule add' "$IP_LOG" || fail "Prokop's running rule was added again next to the old package"

printf 'tproxy rule shared table checks passed\n'
