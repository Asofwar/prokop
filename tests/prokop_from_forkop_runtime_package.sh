#!/usr/bin/env bash
# Package hooks and the policy routing table after a migration from the
# product before the rename (core/legacy_forkop.uc). Its "105 forkop"
# rt_tables entry names the table id Prokop uses, so `ip rule` would show
# Prokop's rule under the old name and Prokop would never find it: it goes
# once the old package is gone, and Prokop's entry comes first while it is
# installed. Prokop's removal strips it as well, but never while the old
# package is installed (a rolled-back migration). A managed sing-box service
# with the old marker is Prokop's only once the old package is gone, and the
# retired VPN guard is cleaned up only then.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
PACKAGE_UC="$LIB/service/package.uc"
NFT_UC="$LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
LEGACY_ROOT="$WORK_DIR/legacy-root"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'rt_tables:\n' >&2
  cat "$WORK_DIR/rt_tables" >&2 2>/dev/null || true
  printf 'commands:\n' >&2
  cat "$WORK_DIR/commands.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run"
for tool in nft ubus conntrack logger; do
  cat >"$WORK_DIR/bin/$tool" <<SH
#!/bin/sh
printf '%s %s\n' "$tool" "\$*" >> "$WORK_DIR/commands.log"
if [ "$tool" = nft ] && { [ "\$1 \$2" = "list table" ] || [ "\$1 \$2 \$3" = "-t list table" ]; }; then [ -e "$WORK_DIR/guard-table" ]; exit \$?; fi
exit 0
SH
done
# ip: Prokop's route and rule are in place, listed under the name iproute2
# gives table 105: the last rt_tables entry for it (NET-3).
cat >"$WORK_DIR/bin/ip" <<'SH'
#!/bin/sh
name="$(awk '$1 == "105" { n = $2 } END { print n }' "$RT_TABLES")"
case "$*" in
  "route list table prokop") echo 'local default dev lo scope host' ;;
  "-6 route list table prokop") echo 'local default dev lo metric 1024 pref medium' ;;
  "-4 rule list"|"-6 rule list") echo "105: from all fwmark 0x100000/0x100000 lookup $name" ;;
esac
exit 0
SH
chmod 0755 "$WORK_DIR/bin/"*

export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LEGACY_FORKOP_ROOT="$LEGACY_ROOT"
export RT_TABLES="$WORK_DIR/rt_tables"
export PROKOP_RT_TABLES="$RT_TABLES"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"

legacy_installed() {
  mkdir -p "$LEGACY_ROOT/etc/init.d"
  printf '#!/bin/sh\nexit 1\n' >"$LEGACY_ROOT/etc/init.d/forkop"
  chmod 0755 "$LEGACY_ROOT/etc/init.d/forkop"
}

legacy_removed() {
  rm -rf "$LEGACY_ROOT"
}

rt_tables() {
  printf '%s\n' '100 main' "$@" '200 custom' >"$RT_TABLES"
}

route_rule() {
  ucode -L "$LIB" "$NFT_UC" ensure-tproxy-route-rule prokop 0x00100000 "$RT_TABLES" >/dev/null 2>&1
}

# 1. A Prokop start next to the stopped, still installed old package: Prokop's
#    entry is added, the old one stays, and Prokop's rule is found under
#    either name.
legacy_installed
rt_tables '105 forkop'
route_rule || fail "route rule setup failed next to the installed old package"
grep -Fxq '105 prokop' "$RT_TABLES" || fail "Prokop's entry must be added"
grep -Fxq '105 forkop' "$RT_TABLES" || fail "the old package's entry must stay while it is installed"
rt_tables '105 prokop' '105 forkop'
: >"$WORK_DIR/commands.log"
route_rule || fail "route rule setup failed with the old entry last"
[ "$(grep -c '^105 ' "$RT_TABLES")" = 2 ] || fail "the entries must not be rewritten"
grep -Fxq '200 custom' "$RT_TABLES" || fail "unrelated entries must stay"
: >"$WORK_DIR/commands.log"
route_rule || fail "a second route rule setup failed"
[ "$(grep -c '^105 ' "$RT_TABLES")" = 2 ] || fail "the entries must not be duplicated"

# 2. Once the old package is gone, its entry goes at the next start.
legacy_removed
rt_tables '105 forkop'
route_rule || fail "route rule setup failed after the old package was removed"
grep -Fxq '105 prokop' "$RT_TABLES" || fail "Prokop's entry must be added"
if grep -q 'forkop' "$RT_TABLES"; then fail "the old entry must go once its package is gone"; fi
[ "$(sed -n '1p' "$RT_TABLES")" = '100 main' ] && grep -Fxq '200 custom' "$RT_TABLES" || fail "unrelated entries must stay"
rt_tables '105 prokop' '105 forkop'
route_rule || fail "route rule setup over both entries failed"
[ "$(grep -c '^105 ' "$RT_TABLES")" = 1 ] && grep -Fxq '105 prokop' "$RT_TABLES" || fail "only Prokop's entry may stay"

# 3. Prokop's removal strips the old entry only once the old package is gone.
legacy_installed
rt_tables '105 prokop' '105 forkop'
PROKOP_PACKAGE_TEST_MODE=1 ucode -L "$LIB" "$PACKAGE_UC" prerm remove || fail "prerm next to the old package failed"
grep -Fxq '105 forkop' "$RT_TABLES" || fail "a rolled-back migration must keep the old package's entry"
if grep -Fq '105 prokop' "$RT_TABLES"; then fail "prerm must remove Prokop's entry"; fi
legacy_removed
rt_tables '105 prokop' '105 forkop'
PROKOP_PACKAGE_TEST_MODE=1 ucode -L "$LIB" "$PACKAGE_UC" prerm remove || fail "prerm failed"
if grep -q '^105 ' "$RT_TABLES"; then fail "prerm must strip the leftover old entry"; fi
grep -Fxq '200 custom' "$RT_TABLES" || fail "prerm must keep unrelated entries"

# 4. The managed sing-box service script with the old marker: kept while the
#    old package is installed, removed with Prokop once it is gone. Prokop's
#    own marker is always Prokop's.
managed_sing_box() {
  mkdir -p "$WORK_DIR/sb"
  cat >"$WORK_DIR/sb/init" <<SH
#!/bin/sh
# $1
printf 'sing-box %s\n' "\$*" >> "$WORK_DIR/commands.log"
SH
  chmod 0755 "$WORK_DIR/sb/init"
  : >"$WORK_DIR/sb/sing-box"; : >"$WORK_DIR/sb/libcronet.so"
}
prerm_sing_box() {
  printf 'prokop.settings=settings\nprokop.settings.dont_touch_dhcp=1\n' >"$PROKOP_UCI_STATE_FILE"
  rt_tables
  PROKOP_INIT="$WORK_DIR/missing-init" PROKOP_BIN="$WORK_DIR/missing-bin" \
  PROKOP_KILLSWITCH_UC="$WORK_DIR/missing-killswitch.uc" PROKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns.uc" \
  PROKOP_SING_BOX_INIT="$WORK_DIR/sb/init" PROKOP_SING_BOX_BIN="$WORK_DIR/sb/sing-box" \
  PROKOP_SING_BOX_CRONET="$WORK_DIR/sb/libcronet.so" \
    ucode -L "$LIB" "$PACKAGE_UC" prerm "${1:-remove}" || fail "prerm with a managed sing-box failed"
}
legacy_installed
managed_sing_box 'Forkop managed sing-box service for binary variants'
prerm_sing_box
[ -e "$WORK_DIR/sb/init" ] && [ -e "$WORK_DIR/sb/sing-box" ] && [ -e "$WORK_DIR/sb/libcronet.so" ] ||
  fail "the old package's managed sing-box must stay while it is installed"
legacy_removed
# An upgrade keeps it: no package brings it back (A7).
prerm_sing_box upgrade
[ -e "$WORK_DIR/sb/init" ] && [ -e "$WORK_DIR/sb/sing-box" ] && [ -e "$WORK_DIR/sb/libcronet.so" ] ||
  fail "an upgrade removed the managed sing-box"
prerm_sing_box
[ ! -e "$WORK_DIR/sb/init" ] && [ ! -e "$WORK_DIR/sb/sing-box" ] && [ ! -e "$WORK_DIR/sb/libcronet.so" ] ||
  fail "a managed sing-box with the old marker is Prokop's once the old package is gone"
managed_sing_box 'Prokop managed sing-box service for binary variants'
legacy_installed
prerm_sing_box
[ ! -e "$WORK_DIR/sb/init" ] || fail "Prokop's managed sing-box must be removed with it"

# 5. The retired VPN guard and the old rt_tables entry: left alone while the
#    old package is installed (its rollback must find it untouched), cleaned
#    once it is gone. postinst runs the same cleanup.
guard_leftovers() {
  mkdir -p "$WORK_DIR/guard/etc/forkop/vpn-guard" "$WORK_DIR/guard/etc/init.d"
  printf '{}\n' >"$WORK_DIR/guard/etc/forkop/vpn-guard/policy.json"
  : >"$WORK_DIR/guard/etc/init.d/forkop-guard"
  touch "$WORK_DIR/guard-table"
  rt_tables '105 forkop'
  printf 'firewall.@defaults[0]=defaults\n' >"$PROKOP_UCI_STATE_FILE"
  : >"$WORK_DIR/commands.log"
}
legacy_cleanup() {
  PROKOP_LEGACY_GUARD_ROOT="$WORK_DIR/guard" ucode -L "$LIB" "$PACKAGE_UC" legacy-cleanup || fail "legacy cleanup failed"
}
legacy_installed
guard_leftovers
legacy_cleanup
[ -e "$WORK_DIR/guard/etc/init.d/forkop-guard" ] && [ -e "$WORK_DIR/guard/etc/forkop/vpn-guard/policy.json" ] ||
  fail "the guard of an installed old package must stay"
grep -Fxq '105 forkop' "$RT_TABLES" || fail "the entry of an installed old package must stay"
[ ! -s "$WORK_DIR/commands.log" ] || fail "nothing may be changed while the old package is installed"
legacy_removed
guard_leftovers
legacy_cleanup
[ ! -e "$WORK_DIR/guard/etc/init.d/forkop-guard" ] && [ ! -e "$WORK_DIR/guard/etc/forkop/vpn-guard" ] ||
  fail "the guard leftovers must be cleaned once the old package is gone"
grep -Fq 'ubus call service delete { "name": "forkop-guard" }' "$WORK_DIR/commands.log" || fail "the guard service must be deleted"
if grep -q 'forkop' "$RT_TABLES"; then fail "the old entry must go once its package is gone"; fi
grep -Fq 'legacy_cleanup();' "$PACKAGE_UC" || fail "postinst must run the legacy cleanup"

printf 'prokop_from_forkop_runtime_package: PASS\n'
