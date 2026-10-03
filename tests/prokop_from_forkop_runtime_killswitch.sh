#!/usr/bin/env bash
# The kill-switch of the product before the rename (core/legacy_forkop.uc) is
# handed over strictly fail-closed: it stays while that package is installed,
# and the first successful sync after it is gone (armed, or definitively
# nothing to protect) removes its nft table, fw4 include and keep.d entry,
# switches dnsmasq's servers file in one dhcp commit and one dnsmasq restart,
# and only then deletes its state directory. disable and status cover it too.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in nft.log dnsmasq.log ubus.log legacy-service.log logger.log; do
    printf '%s:\n' "$log" >&2
    cat "$WORK_DIR/$log" >&2 2>/dev/null || true
  done
  printf 'uci state:\n' >&2
  cat "$UCI_STATE" >&2 2>/dev/null || true
  printf 'state.json:\n' >&2
  cat "$KILLSWITCH_STATE_DIR/state.json" >&2 2>/dev/null || true
  exit 1
}

LEGACY_ROOT="$WORK_DIR/legacy-root"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/tables"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK_DIR/nft.log"
case "$1 $2" in
  "list tables")
    for table in "$WORK_DIR"/tables/*; do
      [ -e "$table" ] && printf 'table inet %s\n' "${table##*/}"
    done
    exit 0 ;;
  "list table")
    [ -e "$WORK_DIR/tables/$4" ]; exit $? ;;
  "list set")
    printf 'table inet ProkopTable {\n\tset %s {\n\t\ttype ipv4_addr\n' "$5"
    [ "$5" = "prokop_rule_main_subnets" ] && printf '\t\telements = { 3.3.3.0/24 }\n'
    printf '\t}\n}\n'
    exit 0 ;;
  "list chain")
    exit 1 ;;
  "-c -f")
    grep -q 'add table inet ProkopKillswitch' "$3" || exit 1
    exit 0 ;;
  "-f "*)
    cp "$2" "$WORK_DIR/live.nft"; touch "$WORK_DIR/tables/ProkopKillswitch"; exit 0 ;;
  "delete table")
    rm -f "$WORK_DIR/tables/$4"; exit 0 ;;
  "-j list")
    printf '{"nftables":[]}\n'; exit 0 ;;
esac
exit 0
NFT
for tool in logger ubus conntrack; do
  cat >"$WORK_DIR/bin/$tool" <<SH
#!/bin/sh
printf '%s\n' "$tool \$*" >> "\$WORK_DIR/$tool.log"
SH
done
cat >"$WORK_DIR/bin/dnsmasq-init" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK_DIR/dnsmasq.log"
SH
cat >"$WORK_DIR/bin/killswitch-init" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK_DIR/service.log"
SH
chmod 0755 "$WORK_DIR/bin/"*

cat >"$WORK_DIR/config.json" <<'JSON'
{ "route": { "rules": [
  { "action": "route", "outbound": "main-out", "domain_suffix": [ "example.com" ] }
], "rule_set": [] } }
JSON

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB
export UCI_STATE="$WORK_DIR/uci.state"
export PROKOP_UCI_STATE_FILE="$UCI_STATE"
export PROKOP_UCI_LOG_FILE="$WORK_DIR/uci.log"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/nftables.d/ruleset-post/90-prokop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"
export PROKOP_LEGACY_FORKOP_ROOT="$LEGACY_ROOT"

SERVERS="$KILLSWITCH_STATE_DIR/dnsmasq.servers"
LEGACY_INIT="$LEGACY_ROOT/etc/init.d/forkop"
LEGACY_KS_INIT="$LEGACY_ROOT/etc/init.d/forkop-killswitch"
LEGACY_INCLUDE="$LEGACY_ROOT/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft"
LEGACY_KEEP="$LEGACY_ROOT/lib/upgrade/keep.d/forkop-killswitch"
LEGACY_DIR="$LEGACY_ROOT/etc/forkop/killswitch"
LEGACY_SERVERS="$LEGACY_DIR/dnsmasq.servers"
LEGACY_CACHE="$LEGACY_ROOT/tmp/forkop-killswitch"

# write_config KILL_SWITCH CONFIG_JSON: the migrated configuration, with
# dnsmasq still reading the old kill-switch's servers file.
write_config() {
  cat >"$UCI_STATE" <<EOF
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan
prokop.settings.config_path=${2:-$WORK_DIR/config.json}
prokop.main=section
prokop.main.action=connection
prokop.main.kill_switch=$1
prokop.main.ip_cidr=3.3.3.0/24
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].serversfile=$LEGACY_SERVERS
EOF
}

# The old kill-switch as the old package's removal leaves it: table, include,
# keep.d entry and the state directory with the attached servers file.
legacy_policy() {
  mkdir -p "$(dirname "$LEGACY_INCLUDE")" "$(dirname "$LEGACY_KEEP")" "$LEGACY_DIR" "$LEGACY_CACHE"
  printf 'add table inet ForkopKillswitch\n' > "$LEGACY_INCLUDE"
  printf '/etc/forkop/killswitch/\n' > "$LEGACY_KEEP"
  printf 'server=/example.com/\n' > "$LEGACY_SERVERS"
  printf 'server=/example.com/\n' > "$LEGACY_DIR/dns-blocked.servers"
  printf 'conf\n' > "$LEGACY_CACHE/standby.conf"
  touch "$WORK_DIR/tables/ForkopKillswitch"
}

# legacy_package [running]: the old package is installed, its runtime stopped
# (or running: its runtime table exists).
legacy_package() {
  mkdir -p "$LEGACY_ROOT/etc/init.d"
  printf '#!/bin/sh\n[ "$1" != status ] || exit 1\n' > "$LEGACY_INIT"
  cat > "$LEGACY_KS_INIT" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK_DIR/legacy-service.log"
SH
  chmod 0755 "$LEGACY_INIT" "$LEGACY_KS_INIT"
  if [ "${1:-}" = running ]; then touch "$WORK_DIR/tables/ForkopTable"; else rm -f "$WORK_DIR/tables/ForkopTable"; fi
}

legacy_removed() {
  rm -f "$LEGACY_INIT" "$LEGACY_KS_INIT" "$WORK_DIR/tables/ForkopTable"
}

reset_logs() {
  : > "$WORK_DIR/nft.log"; : > "$WORK_DIR/dnsmasq.log"; : > "$WORK_DIR/ubus.log"
  : > "$WORK_DIR/legacy-service.log"; : > "$WORK_DIR/logger.log"; : > "$WORK_DIR/service.log"
  : > "$WORK_DIR/uci.log"
}

ks() {
  ucode -L "$PROKOP_LIB" "$KS_UC" "$@"
}

uci_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2) }' "$UCI_STATE"
}

legacy_kept() {
  [ -e "$WORK_DIR/tables/ForkopKillswitch" ] || fail "$1: the old kill-switch table was removed"
  [ -e "$LEGACY_INCLUDE" ] && [ -e "$LEGACY_KEEP" ] || fail "$1: the old include or keep.d entry was removed"
  [ "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" = "$LEGACY_SERVERS" ] || fail "$1: dnsmasq left the old servers file"
  grep -Fqx 'server=/example.com/' "$LEGACY_SERVERS" || fail "$1: the old DNS block list was changed"
}

touch "$WORK_DIR/tables/ProkopTable"

# 1. The old package is still installed (a migration not finished, or rolled
#    back): an armed sync leaves the old kill-switch entirely alone.
write_config 1
legacy_policy
legacy_package
reset_logs
ks sync start || fail "sync next to the installed old package failed"
[ -e "$WORK_DIR/tables/ProkopKillswitch" ] || fail "this kill-switch must still be armed"
legacy_kept "installed old package"
[ ! -s "$WORK_DIR/dnsmasq.log" ] && ! grep -q 'commit dhcp' "$WORK_DIR/uci.log" ||
  fail "dhcp must not change while the old servers file stays"
[ ! -s "$WORK_DIR/legacy-service.log" ] || fail "the old standby service must be left alone"
grep -Fq 'kill-switch servers file' "$KILLSWITCH_STATE_DIR/state.json" ||
  fail "the unattached DNS protection must be reported"
status="$(ks status)" || fail "status failed"
printf '%s' "$status" | grep -Fq '"legacy_attached": true' || fail "status must report the old servers file: $status"
printf '%s' "$status" | grep -Eq '"legacy": \{[^}]*"installed": true' || fail "status must report the old package: $status"

# 2. The old package is gone: the first armed sync hands over.
legacy_removed
mkdir -p "$LEGACY_ROOT/etc/init.d"
cat > "$LEGACY_KS_INIT" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK_DIR/legacy-service.log"
SH
chmod 0755 "$LEGACY_KS_INIT"
reset_logs
ks sync reload || fail "hand-over sync failed"
[ -e "$WORK_DIR/tables/ProkopKillswitch" ] || fail "this kill-switch must be armed"
[ ! -e "$WORK_DIR/tables/ForkopKillswitch" ] || fail "the old kill-switch table must be removed"
[ ! -e "$LEGACY_INCLUDE" ] && [ ! -e "$LEGACY_KEEP" ] || fail "the old include and keep.d entry must be removed"
awk '/flush chain inet ForkopKillswitch ks_dns/ { f = NR } /delete table inet ForkopKillswitch/ { d = NR } END { exit !(f && d && f < d) }' \
  "$WORK_DIR/nft.log" || fail "the old client DNS redirect must be flushed before its table goes"
[ "$(cat "$WORK_DIR/legacy-service.log")" = "$(printf 'stop\ndisable')" ] ||
  fail "a leftover old standby service must be stopped and disabled"
[ "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" = "$SERVERS" ] || fail "dnsmasq must switch to this kill-switch's servers file"
[ "$(grep -c '^restart$' "$WORK_DIR/dnsmasq.log")" = 1 ] || fail "the switch must restart dnsmasq exactly once"
[ "$(grep -c '^commit dhcp$' "$WORK_DIR/uci.log")" = 1 ] || fail "the switch must be one dhcp commit"
[ ! -e "$LEGACY_DIR" ] && [ ! -e "$LEGACY_CACHE" ] || fail "the old state directory must go once dnsmasq left it"
[ ! -e "$LEGACY_ROOT/etc/forkop" ] || fail "the emptied old state directory must go"
grep -Fq 'conntrack -D -p udp --dport 53' "$WORK_DIR/conntrack.log" || fail "redirected DNS flows must be flushed"
status="$(ks status)"
printf '%s' "$status" | grep -Eq '"legacy": \{ "installed": false, "active": false, "persistent": false, "keep": false, "dns_attached": false, "state_dir": false \}' ||
  fail "status must show nothing of the old kill-switch left: $status"

# 3. A later sync with nothing left changes nothing of the old product.
reset_logs
ks sync reload || fail "repeated sync failed"
if grep -Eq 'ForkopKillswitch' "$WORK_DIR/nft.log" || [ -s "$WORK_DIR/legacy-service.log" ] || [ -s "$WORK_DIR/ubus.log" ]; then
  fail "a sync without old leftovers must not touch them"
fi

# 4. Definitively nothing to protect: the old kill-switch goes too, and the
#    servers file option with it, in one restart. Without its init script the
#    old standby service is deleted from procd.
ks disable test >/dev/null 2>&1 || fail "reset disable failed"
rm -f "$LEGACY_KS_INIT"
write_config 0
legacy_policy
reset_logs
ks sync reload || fail "teardown sync failed"
[ ! -e "$WORK_DIR/tables/ForkopKillswitch" ] && [ ! -e "$LEGACY_INCLUDE" ] && [ ! -e "$LEGACY_KEEP" ] ||
  fail "nothing to protect must remove the old policy"
grep -Fq 'ubus call service delete { "name": "forkop-killswitch" }' "$WORK_DIR/ubus.log" ||
  fail "the old standby service must be deleted from procd"
[ -z "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" ] || fail "dnsmasq must leave the old servers file"
[ "$(grep -c '^restart$' "$WORK_DIR/dnsmasq.log")" = 1 ] || fail "the release must restart dnsmasq exactly once"
[ "$(grep -c '^commit dhcp$' "$WORK_DIR/uci.log")" = 1 ] || fail "the release must be one dhcp commit"
[ ! -e "$LEGACY_DIR" ] || fail "the old state directory must go once dnsmasq left it"

# 5. Never delete the old state directory while dnsmasq still reads it: the
#    DNS hand-over failed (unreadable sing-box config), the nft part did not.
write_config 1 "$WORK_DIR/missing.json"
legacy_policy
reset_logs
ks sync reload || fail "sync with an unreadable sing-box config failed"
[ ! -e "$WORK_DIR/tables/ForkopKillswitch" ] || fail "the armed nft policy replaces the old table"
[ "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" = "$LEGACY_SERVERS" ] || fail "dnsmasq must keep the old servers file"
[ -e "$LEGACY_SERVERS" ] || fail "the old servers file must stay while dnsmasq reads it"
grep -Fq "keeping $LEGACY_DIR" "$WORK_DIR/logger.log" || fail "the kept directory must be logged"
write_config 1
reset_logs
ks sync reload || fail "recovered sync failed"
[ "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" = "$SERVERS" ] && [ ! -e "$LEGACY_DIR" ] ||
  fail "the next good sync must complete the DNS hand-over"

# 6. An explicit disable lifts the old kill-switch whenever the old product is
#    not active, also with its package installed; never while it runs; and
#    Prokop's own removal never while its package is installed.
ks disable test >/dev/null 2>&1 || fail "reset disable failed"
write_config 1
legacy_policy
legacy_package running
reset_logs
ks disable || fail "disable next to the running old product failed"
legacy_kept "running old product"
grep -Fq 'stays in place: Forkop is still active' "$WORK_DIR/logger.log" || fail "the kept old kill-switch must be logged"

legacy_package
reset_logs
ks disable "package removal" || fail "package removal disable failed"
legacy_kept "removal of Prokop next to the installed old package"
grep -Fq 'stays in place: Forkop is still installed' "$WORK_DIR/logger.log" || fail "the strict refusal must be logged"

reset_logs
ks disable || fail "explicit disable failed"
[ ! -e "$WORK_DIR/tables/ForkopKillswitch" ] && [ ! -e "$LEGACY_INCLUDE" ] && [ ! -e "$LEGACY_DIR" ] ||
  fail "an explicit disable must lift the old kill-switch of a stopped old product"
[ -z "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" ] || fail "an explicit disable must detach the old servers file"
[ "$(cat "$WORK_DIR/legacy-service.log")" = "$(printf 'stop\ndisable')" ] ||
  fail "the installed old standby service must be stopped and disabled"

[ ! -e "$PROKOP_RUNTIME_STATE_DIR/killswitch.lock" ] || fail "lock must be released"
printf 'prokop_from_forkop_runtime_killswitch: PASS\n'
