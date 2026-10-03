#!/usr/bin/env bash
# Kill-switch files on flash (UC-212): the saved policy, the block list and
# the servers file dnsmasq reads are flushed to flash before and after they
# replace the old file, so a power cut leaves the old or the new one, never
# an empty one; and nothing is rewritten when it did not change: a sync that
# renders the same protection only updates its times in RAM.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
DNS_UC="$PROKOP_LIB/dns/apply.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'sync calls:\n' >&2
  cat "$WORK_DIR/sync.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/ks"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
case "$1 $2" in
  "list table")
    [ "$4" = "ProkopTable" ] && exit 0
    [ "$4" = "ProkopKillswitch" ] && { [ -e "$WORK_DIR/ks-present" ]; exit $?; }
    exit 1 ;;
  "list set")
    printf 'table inet ProkopTable {\n\tset %s {\n\t\ttype ipv4_addr\n' "$5"
    [ "$5" = "prokop_rule_main_subnets" ] && printf '\t\telements = { %s }\n' "$(cat "$WORK_DIR/elements")"
    printf '\t}\n}\n'
    exit 0 ;;
  "-c -f") exit 0 ;;
  "-f "*) touch "$WORK_DIR/ks-present"; exit 0 ;;
esac
exit 0
NFT
# Every flush records which kill-switch files exist at that moment.
cat >"$WORK_DIR/bin/sync" <<'SH'
#!/bin/sh
printf '%s\n' "$(cd "$KILLSWITCH_STATE_DIR" && ls -1 | tr '\n' ' ')" >>"$WORK_DIR/sync.log"
SH
for name in logger dnsmasq-init killswitch-init; do
  printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/$name"
done
chmod 0755 "$WORK_DIR/bin/"*

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/ruleset-post/90-prokop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"

cat >"$WORK_DIR/config.json" <<'JSON'
{ "route": { "rules": [ { "action": "route", "outbound": "main-out", "domain_suffix": [ "example.com" ] } ], "rule_set": [] } }
JSON
cat >"$PROKOP_UCI_STATE_FILE" <<EOF
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan
prokop.settings.config_path=$WORK_DIR/config.json
prokop.main=section
prokop.main.action=connection
prokop.main.kill_switch=1
prokop.main.ip_cidr=3.3.3.0/24
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=127.0.0.42
EOF
printf '3.3.3.0/24' >"$WORK_DIR/elements"

ks() { ucode -L "$PROKOP_LIB" "$KS_UC" "$@"; }
POLICY="$KILLSWITCH_STATE_DIR/policy.nft"
STATE="$KILLSWITCH_STATE_DIR/state.json"
SERVERS="$KILLSWITCH_STATE_DIR/dnsmasq.servers"
inode() { stat -c %i "$1"; }

# A first sync saves every file durably: flushed while the new file still
# has its temporary name and again after the rename.
ks sync start || fail "first sync failed"
for file in policy.nft dns-blocked.servers state.json; do
  grep -Eq "(^| )$file\\.tmp\\.[0-9]+ " "$WORK_DIR/sync.log" ||
    fail "$file must be flushed before it replaces the old file"
done
tail -n 1 "$WORK_DIR/sync.log" | grep -Fq 'policy.nft ' || fail "the last flush must follow the renames"
if tail -n 1 "$WORK_DIR/sync.log" | grep -q '\.tmp\.'; then fail "the last flush must follow the renames"; fi

# The same protection again: no file on flash is written or flushed, only
# the time of the sync changes (in RAM).
first_update="$(ks status | grep -o '"updated_at": [0-9]*' | head -n 1)"
policy_inode="$(inode "$POLICY")"
state_inode="$(inode "$STATE")"
: >"$WORK_DIR/sync.log"
sleep 1.1
ks sync reload || fail "second sync failed"
[ "$(inode "$POLICY")" = "$policy_inode" ] || fail "an unchanged policy must not be rewritten"
[ "$(inode "$STATE")" = "$state_inode" ] || fail "state.json must not be rewritten when only its times change"
[ ! -s "$WORK_DIR/sync.log" ] || fail "nothing unchanged may be flushed"
second_update="$(ks status | grep -o '"updated_at": [0-9]*' | head -n 1)"
[ -n "$second_update" ] || fail "status must report the time of the last sync"
[ "$second_update" != "$first_update" ] || fail "status must report the time of the last sync ($first_update / $second_update)"

# A changed list rewrites the policy (and its state) durably.
printf '3.3.3.0/24, 4.4.4.0/24' >"$WORK_DIR/elements"
ks sync reload || fail "sync with a changed list failed"
[ "$(inode "$POLICY")" != "$policy_inode" ] || fail "a changed policy must be saved"
grep -Eq '(^| )policy\.nft\.tmp\.[0-9]+ ' "$WORK_DIR/sync.log" || fail "a changed policy must be flushed before the rename"

# The servers file dnsmasq reads: flushed when it changes, untouched otherwise.
: >"$WORK_DIR/sync.log"
sed -i 's/^dhcp.@dnsmasq\[0\].server=.*/dhcp.@dnsmasq[0].server=1.1.1.1/' "$PROKOP_UCI_STATE_FILE"
ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
grep -Fqx 'server=/example.com/' "$SERVERS" || fail "a stopped Prokop must block protected names"
grep -Eq '(^| )dnsmasq\.servers\.tmp\.[0-9]+ ' "$WORK_DIR/sync.log" || fail "the servers file must be flushed before the rename"
servers_inode="$(inode "$SERVERS")"
: >"$WORK_DIR/sync.log"
ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "second DNS refresh failed"
[ "$(inode "$SERVERS")" = "$servers_inode" ] || fail "an unchanged servers file must not be rewritten"
[ ! -s "$WORK_DIR/sync.log" ] || fail "an unchanged servers file must not be flushed"

printf 'killswitch_durable: PASS\n'
