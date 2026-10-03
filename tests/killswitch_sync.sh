#!/usr/bin/env bash
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
  printf 'nft log:\n' >&2
  cat "$WORK_DIR/nft.log" >&2 2>/dev/null || true
  printf 'uci state:\n' >&2
  cat "$UCI_STATE" >&2 2>/dev/null || true
  printf 'state.json:\n' >&2
  cat "$KILLSWITCH_STATE_DIR/state.json" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK_DIR/nft.log"
case "$1 $2" in
  "list table")
    [ "$4" = "ProkopTable" ] && { [ -e "$WORK_DIR/live-present" ]; exit $?; }
    [ "$4" = "ProkopKillswitch" ] && { [ -e "$WORK_DIR/ks-present" ]; exit $?; }
    [ "$4" = "ForkopVpnGuard" ] && { [ -e "$WORK_DIR/legacy-present" ]; exit $?; }
    exit 1 ;;
  "list set")
    printf 'table inet ProkopTable {\n\tset %s {\n\t\ttype ipv4_addr\n' "$5"
    [ "$5" = "prokop_rule_main_subnets" ] && printf '\t\telements = { 3.3.3.0/24 }\n'
    printf '\t}\n}\n'
    exit 0 ;;
  "-c -f")
    [ "${NFT_CHECK_FAIL:-0}" = "1" ] && exit 1
    grep -q 'add table inet ProkopKillswitch' "$3" || exit 1
    exit 0 ;;
  "-f "*)
    cp "$2" "$WORK_DIR/live.nft"; touch "$WORK_DIR/ks-present"; exit 0 ;;
  "delete table")
    [ "$4" = "ForkopVpnGuard" ] && { rm -f "$WORK_DIR/legacy-present"; exit 0; }
    rm -f "$WORK_DIR/ks-present"; exit 0 ;;
  "-j list")
    printf '{"nftables":[{"metainfo":{}},{"counter":{"family":"inet","name":"ks_main","table":"ProkopKillswitch","packets":7,"bytes":420}},{"counter":{"family":"inet","name":"ks_fakeip","table":"ProkopKillswitch","packets":2,"bytes":120}}]}\n'
    exit 0 ;;
esac
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
cat >"$WORK_DIR/bin/killswitch-init" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK_DIR/service.log"
SH
chmod 0755 "$WORK_DIR/bin/"*

cat >"$WORK_DIR/config.json" <<'JSON'
{ "route": { "rules": [
  { "action": "route", "outbound": "bypass-out", "domain_suffix": [ "drive.example.com" ] },
  { "action": "route", "outbound": "main-out", "domain_suffix": [ "example.com", "claude.ai" ] }
], "rule_set": [] } }
JSON

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB
export UCI_STATE="$WORK_DIR/uci.state"
export PROKOP_UCI_STATE_FILE="$UCI_STATE"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
# A manual sync takes reload.lock first (UC-210); never the host's.
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/nftables.d/ruleset-post/90-prokop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"

write_config() {
  cat >"$UCI_STATE" <<EOF
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan
prokop.settings.config_path=$WORK_DIR/config.json
prokop.zap=section
prokop.zap.action=zapret
prokop.zap.ip_cidr=1.1.1.0/24
prokop.main=section
prokop.main.action=connection
prokop.main.kill_switch=$1
prokop.main.ip_cidr=3.3.3.0/24
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=127.0.0.42
EOF
}

ks() {
  ucode -L "$PROKOP_LIB" "$KS_UC" "$@"
}

uci_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2) }' "$UCI_STATE"
}

# Saved under the state directory; only the package's fw4 loader loads it
# (UC-191). The first build's unguarded fw4 include is only ever removed.
POLICY="$KILLSWITCH_STATE_DIR/policy.nft"
LEGACY_INCLUDE="$KILLSWITCH_NFT_INCLUDE"
SERVERS="$KILLSWITCH_STATE_DIR/dnsmasq.servers"
BLOCKED="$KILLSWITCH_STATE_DIR/dns-blocked.servers"

# 1. Prokop runtime is missing: nothing is installed and the failure is recorded.
write_config 1
if ks sync start; then
  fail "sync without the live ProkopTable must fail"
fi
[ ! -e "$POLICY" ] || fail "no policy may be saved without the live table"
grep -Fq 'is not present' "$KILLSWITCH_STATE_DIR/state.json" || fail "missing runtime must be recorded"

[ -e "$WORK_DIR/legacy-present" ] || true

# 2. Successful sync while Prokop DNS is active. The retired global guard
#    left by an upgrade is dropped only now that its replacement is live.
touch "$WORK_DIR/live-present" "$WORK_DIR/legacy-present"
mkdir -p "$(dirname "$LEGACY_INCLUDE")"
printf 'add table inet ProkopKillswitch\n' > "$LEGACY_INCLUDE"
if NFT_CHECK_FAIL=1 ks sync start; then fail "invalid policy must fail"; fi
[ -e "$WORK_DIR/legacy-present" ] || fail "the old guard must stay while the kill-switch could not be applied"
ks sync start || fail "sync failed"
[ ! -e "$WORK_DIR/legacy-present" ] || fail "the old guard must be removed once the kill-switch is live"
[ -s "$POLICY" ] || fail "the policy must be saved for the boot"
cmp -s "$POLICY" "$WORK_DIR/live.nft" || fail "the saved policy must be exactly the policy applied live"
[ ! -e "$LEGACY_INCLUDE" ] || fail "the unguarded include of the first kill-switch build must be removed"
grep -Fq 'counter name ks_main jump ks_reject' "$POLICY" || fail "protected section must reject"
grep -Fq 'prokop_rule_zap_subnets return' "$POLICY" || fail "earlier zapret section must return"
grep -Fq -- '-c -f' "$WORK_DIR/nft.log" || fail "policy must be validated before apply"
grep -Fqx 'server=/example.com/' "$BLOCKED" || fail "protected domain must be prepared for dnsmasq"
grep -Fqx 'server=/drive.example.com/#' "$BLOCKED" || fail "earlier bypass below a protected domain must be an exception"
[ "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" = "$SERVERS" ] || fail "dnsmasq must use the kill-switch servers file"
[ -e "$SERVERS" ] && [ ! -s "$SERVERS" ] || fail "servers file must be empty while dnsmasq forwards to sing-box"
grep -Fq '"active": true' "$KILLSWITCH_STATE_DIR/state.json" || fail "state must be active"
[ "$(cat "$WORK_DIR/service.log")" = "$(printf 'enable\nstart')" ] || fail "applied protection must enable and start the standby service"
: > "$WORK_DIR/service.log"

# 3. Prokop stops: dnsmasq leaves sing-box and the block list becomes active.
sed -i '/^dhcp.@dnsmasq\[0\].server=/d' "$UCI_STATE"
printf 'dhcp.@dnsmasq[0].server=1.1.1.1\n' >> "$UCI_STATE"
: > "$WORK_DIR/dnsmasq.log"
ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "dns refresh failed"
cmp -s "$BLOCKED" "$SERVERS" || fail "stopped Prokop must activate the DNS block list"
grep -Fqx restart "$WORK_DIR/dnsmasq.log" || fail "dnsmasq must be restarted for a new block list"
: > "$WORK_DIR/dnsmasq.log"
ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "second dns refresh failed"
[ ! -s "$WORK_DIR/dnsmasq.log" ] || fail "an unchanged block list must not restart dnsmasq"

# 4. Status reports the live state and counters.
status="$(ks status)" || fail "status failed"
printf '%s' "$status" | grep -Fq '"active": true' || fail "status must report the table: $status"
printf '%s' "$status" | grep -Fq '"main": { "packets": 7' || fail "status must report section counters: $status"
printf '%s' "$status" | grep -Fq '"blocking": true' || fail "status must report active DNS blocking: $status"

# 5. A policy that fails nft validation never replaces the installed one.
cp "$POLICY" "$WORK_DIR/include.before"
if NFT_CHECK_FAIL=1 ks sync reload; then
  fail "invalid policy must fail the sync"
fi
cmp -s "$POLICY" "$WORK_DIR/include.before" || fail "saved policy must survive a failed sync"
[ -e "$WORK_DIR/ks-present" ] || fail "live policy must survive a failed sync"

# 6. A stopped Prokop (no live table) keeps the protection on sync.
rm -f "$WORK_DIR/live-present"
if ks sync reload; then
  fail "sync without runtime must report failure"
fi
[ -e "$POLICY" ] && [ -e "$WORK_DIR/ks-present" ] && [ -e "$BLOCKED" ] || fail "protection must survive a sync without runtime"

# 7. A sync without protected sections lifts everything, even without a
#    runtime. Reloads of a stopped Prokop reach it through service/initd.uc:
#    tests/killswitch_stopped_reload.sh (UC-208).
write_config 0
sed -i '/^dhcp.@dnsmasq\[0\].server=/d' "$UCI_STATE"
printf 'dhcp.@dnsmasq[0].server=1.1.1.1\ndhcp.@dnsmasq[0].serversfile=%s\n' "$SERVERS" >> "$UCI_STATE"
printf 'add table inet ProkopKillswitch\n' > "$LEGACY_INCLUDE"
ks sync reload || fail "teardown sync failed"
[ ! -e "$POLICY" ] || fail "saved policy must be removed"
[ ! -e "$LEGACY_INCLUDE" ] || fail "an unguarded include of the first build must be removed"
[ ! -e "$WORK_DIR/ks-present" ] || fail "live table must be deleted"
[ ! -e "$BLOCKED" ] && [ ! -e "$SERVERS" ] || fail "DNS block files must be removed"
[ -z "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" ] || fail "dnsmasq servers file option must be removed"
grep -Fq '"active": false' "$KILLSWITCH_STATE_DIR/state.json" || fail "state must be inactive"
grep -Fqx stop "$WORK_DIR/service.log" && grep -Fqx disable "$WORK_DIR/service.log" ||
  fail "lifted protection must stop and disable the standby service"

# 7b. Without protected sections and nothing left, a sync changes nothing.
: > "$WORK_DIR/service.log"
ks sync reload || fail "idle sync failed"
[ ! -s "$WORK_DIR/service.log" ] || fail "an idle sync must not tear down again"

# 8. Explicit disable with the option still checked.
write_config 1
touch "$WORK_DIR/live-present"
ks sync start || fail "re-enable sync failed"
ks disable test || fail "disable failed"
[ ! -e "$POLICY" ] && [ ! -e "$WORK_DIR/ks-present" ] || fail "disable must remove the nft policy"
status="$(ks status)"
printf '%s' "$status" | grep -Fq '"pending": true' || fail "status must show configured-but-inactive protection: $status"

# 9. dont_touch_dhcp: nft only, dnsmasq untouched.
printf 'prokop.settings.dont_touch_dhcp=1\n' >> "$UCI_STATE"
ks sync start || fail "sync with dont_touch_dhcp failed"
[ -e "$POLICY" ] || fail "nft protection must still be installed"
[ ! -e "$BLOCKED" ] || fail "DNS block list must not be prepared when dnsmasq is not managed"
[ -z "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" ] || fail "dnsmasq must not be touched with dont_touch_dhcp"
grep -Fq 'dont_touch_dhcp' "$KILLSWITCH_STATE_DIR/state.json" || fail "unmanaged DNS must be reported"

# 10. A foreign servers file is never replaced.
sed -i '/dont_touch_dhcp/d' "$UCI_STATE"
printf 'dhcp.@dnsmasq[0].serversfile=/etc/adblock.servers\n' >> "$UCI_STATE"
ks sync start || fail "sync with a foreign servers file failed"
[ "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" = "/etc/adblock.servers" ] || fail "foreign servers file must be kept"
grep -Fq 'DNS protection is not attached' "$KILLSWITCH_STATE_DIR/state.json" || fail "servers file conflict must be reported"

# 11. Package upgrade from the first kill-switch build: its unguarded fw4
#     include becomes the saved policy only the package's loader loads.
rm -f "$POLICY"
printf 'add table inet ProkopKillswitch\n# first build\n' > "$LEGACY_INCLUDE"
ks postinst || fail "postinst adoption failed"
[ ! -e "$LEGACY_INCLUDE" ] || fail "postinst must remove the unguarded include"
grep -Fqx '# first build' "$POLICY" || fail "postinst must keep the protection of the first build as the saved policy"

# 12. Back from the first kill-switch build after a change to it kept the
#     saved policy: that build never loads policy.nft and this one always
#     removes the unguarded include, so whatever the first build did last is
#     newer than the saved policy.
printf 'add table inet ProkopKillswitch\n# saved before the change\n' > "$POLICY"
printf 'add table inet ProkopKillswitch\n# written by the first build\n' > "$LEGACY_INCLUDE"
printf '{ "active": true, "format": 1 }\n' > "$KILLSWITCH_STATE_DIR/state.json"
ks postinst || fail "postinst after the first build failed"
[ ! -e "$LEGACY_INCLUDE" ] || fail "postinst must remove the unguarded include"
grep -Fqx '# written by the first build' "$POLICY" ||
  fail "the include of the first build is newer than the saved policy and must replace it"

# The first build removed its protection: the policy saved before it is
# stale.
printf 'add table inet ProkopKillswitch\n# saved before the change\n' > "$POLICY"
printf '{ "active": false, "reason": "disabled on request", "format": 1 }\n' > "$KILLSWITCH_STATE_DIR/state.json"
ks postinst || fail "postinst after the first build removed the protection failed"
[ ! -e "$POLICY" ] || fail "the first build removed the protection; the policy saved before it must not come back"

# A failed sync of the first build kept the previous protection.
printf 'add table inet ProkopKillswitch\n# saved before the change\n' > "$POLICY"
printf '{ "active": true, "last_error": "nft render failed; keeping the previous protection", "format": 1 }\n' > "$KILLSWITCH_STATE_DIR/state.json"
ks postinst || fail "postinst after a failed sync of the first build failed"
grep -Fqx '# saved before the change' "$POLICY" || fail "a protection the first build kept must stay"

# This build's own record never drops the saved policy.
ks sync start || fail "sync after the postinst checks failed"
grep -Fq '"format": 2' "$KILLSWITCH_STATE_DIR/state.json" || fail "state.json must name the loader layout"
cp "$POLICY" "$WORK_DIR/policy.saved"
ks postinst || fail "postinst of an upgrade between loader builds failed"
cmp -s "$POLICY" "$WORK_DIR/policy.saved" || fail "an upgrade between loader builds must keep the saved policy"

# 13. Reinstall after a sysupgrade to an image without Prokop: the sysupgrade
#     kept the saved policy and block list (lib/upgrade/keep.d), never the
#     service's rc.d link. The reinstalled loader makes fw4 load the policy
#     again, so the service must be enabled for its boot() to attach the DNS
#     block list again.
: > "$WORK_DIR/service.log"
ks postinst || fail "postinst of a reinstall with a saved policy failed"
grep -Fqx enable "$WORK_DIR/service.log" ||
  fail "postinst must enable the kill-switch service while a policy is saved: $(cat "$WORK_DIR/service.log")"
# Without a saved policy there is nothing for boot() to attach.
ks disable || fail "disable before the reinstall without a policy failed"
: > "$WORK_DIR/service.log"
ks postinst || fail "postinst of a reinstall without a saved policy failed"
! grep -Fqx enable "$WORK_DIR/service.log" || fail "postinst must not enable the kill-switch service without a saved policy"

[ ! -e "$PROKOP_RUNTIME_STATE_DIR/killswitch.lock" ] || fail "lock must be released"
[ ! -e "$PROKOP_RELOAD_LOCK_DIR" ] || fail "reload.lock must be released"

printf 'killswitch_sync: PASS\n'
