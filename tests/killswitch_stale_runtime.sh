#!/usr/bin/env bash
# The kill-switch is rendered from the configuration in UCI (rules and their
# order) and the set contents of the live ProkopTable. Both must describe
# the same runtime (UC-209): while committed changes wait for a reload, or a
# reload left the rebuild of the table to the list worker's list-content
# reload, a refresh would put the new rule order on top of the old sets and
# could reject traffic the running Prokop deliberately sends directly. Such a
# refresh keeps the previous protection instead.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
STATE_UC="$PROKOP_LIB/service/state.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'policy:\n' >&2
  cat "$POLICY" >&2 2>/dev/null || true
  printf 'state.json:\n' >&2
  cat "$KILLSWITCH_STATE_DIR/state.json" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
case "$1 $2" in
  "list table")
    [ "$4" = "ProkopTable" ] && exit 0
    [ "$4" = "ProkopKillswitch" ] && { [ -e "$WORK_DIR/ks-present" ]; exit $?; }
    exit 1 ;;
  "list set")
    printf 'table inet ProkopTable {\n\tset %s {\n\t\ttype ipv4_addr\n' "$5"
    case "$5" in
      prokop_rule_byp_subnets|prokop_rule_vpn_subnets) printf '\t\telements = { 93.184.216.0/24 }\n' ;;
    esac
    printf '\t}\n}\n'
    exit 0 ;;
  "-c -f") exit 0 ;;
  "-f "*) cp "$2" "$WORK_DIR/live.nft"; touch "$WORK_DIR/ks-present"; exit 0 ;;
esac
exit 0
NFT
for name in logger dnsmasq-init killswitch-init; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
chmod 0755 "$WORK_DIR/bin/"*

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export PROKOP_RELOAD_STATE_FILE="$WORK_DIR/run/reload-state"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/nftables.d/90-prokop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"

POLICY="$KILLSWITCH_STATE_DIR/policy.nft"
LISTS_PENDING="$PROKOP_RUNTIME_STATE_DIR/runtime-lists.pending"

cat >"$WORK_DIR/sing-box.json" <<'JSON'
{ "outbounds": [ { "type": "direct", "tag": "vpn-out" } ],
  "route": { "rules": [ { "action": "route", "outbound": "vpn-out", "domain_suffix": [ "vpn.example" ] } ], "rule_set": [] } }
JSON
# The bypass section sends 93.184.216.0/24 directly while it comes first.
write_config() {
  local first="$1" second="$2"
  {
    printf 'prokop.settings=settings\n'
    printf 'prokop.settings.source_network_interfaces=br-lan\n'
    printf 'prokop.settings.config_path=%s\n' "$WORK_DIR/sing-box.json"
    for name in "$first" "$second"; do
      printf 'prokop.%s=section\n' "$name"
      if [ "$name" = byp ]; then
        printf 'prokop.byp.action=bypass\n'
      else
        printf 'prokop.vpn.action=connection\nprokop.vpn.kill_switch=1\n'
      fi
      printf 'prokop.%s.ip_cidr=93.184.216.0/24\n' "$name"
    done
    printf 'dhcp.@dnsmasq[0]=dnsmasq\ndhcp.@dnsmasq[0].server=127.0.0.42\n'
  } >"$PROKOP_UCI_STATE_FILE"
}
# What a successful start or reload records for the configuration it applied.
applied() {
  ucode -L "$PROKOP_LIB" "$STATE_UC" capture-reload-state "$PROKOP_RELOAD_STATE_FILE" 1 ||
    fail "the reload state could not be captured"
}
ks() { ucode -L "$PROKOP_LIB" "$KS_UC" "$@"; }
bypass_first() {
  awk '/prokop_rule_byp_subnets return/ { b = NR } /ks_vpn jump ks_reject/ { v = NR } END { exit !(b && v && b < v) }' "$POLICY"
}

# The running Prokop applied: bypass first.
write_config byp vpn
applied
ks sync manual || fail "a manual refresh of the applied configuration failed"
bypass_first || fail "the policy must keep the bypass verdict first"
cp "$POLICY" "$WORK_DIR/policy.applied"

# Committed, not reloaded yet: the protected section moved first.
write_config vpn byp
if ks sync manual 2>"$WORK_DIR/sync.err"; then
  fail "a manual refresh must not render a configuration the running Prokop has not applied"
fi
cmp -s "$POLICY" "$WORK_DIR/policy.applied" || fail "the previous protection must stay while the configuration waits for a reload"
grep -Fq 'reload' "$KILLSWITCH_STATE_DIR/state.json" || fail "the kept protection must say that a reload is needed"
grep -Fq 'reload Prokop first' "$WORK_DIR/sync.err" || fail "a manual refresh must tell why it kept the protection"
# FE-10: the page translates the error by its code; the detail is kept.
node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1])); const c = s.last_error_code || {};
  if (c.code !== "runtime_behind" || !String(c.detail).includes("reload")) process.exit(1)' "$KILLSWITCH_STATE_DIR/state.json" ||
  fail "the kept protection has no error code for the page: $(cat "$KILLSWITCH_STATE_DIR/state.json")"
printf 'ok - a manual refresh waits for the reload of a committed change\n'

# The reload applied it.
applied
ks sync manual || fail "a manual refresh after the reload failed"
bypass_first && fail "the refreshed policy must follow the applied order"
grep -Fq '"last_error": ""' "$KILLSWITCH_STATE_DIR/state.json" || fail "a successful refresh must clear the error"
grep -Fq '"last_error_code": null' "$KILLSWITCH_STATE_DIR/state.json" || fail "a successful refresh must clear the error code"
printf 'ok - a manual refresh follows the applied configuration\n'

# A reload whose list source changed leaves the rebuild of the table to the
# list worker (service/lifecycle.uc records it). No refresh, manual or from
# a reload that rebuilds nothing, may run before the list-content reload.
write_config byp vpn
applied
cp "$POLICY" "$WORK_DIR/policy.applied"
printf 'reload\n' >"$LISTS_PENDING"
if ks sync manual 2>"$WORK_DIR/sync.err"; then
  fail "a manual refresh must wait for the list generation of the table"
fi
if ks sync reload reload-lock-held; then
  fail "a reload that rebuilt nothing must not refresh before the list generation is applied"
fi
cmp -s "$POLICY" "$WORK_DIR/policy.applied" || fail "the previous protection must stay until the list generation is applied"
grep -Fq 'list generation' "$KILLSWITCH_STATE_DIR/state.json" || fail "the kept protection must name the pending list generation"
rm -f "$LISTS_PENDING"
ks sync "reload list-content" reload-lock-held || fail "the refresh of the list-content reload failed"
bypass_first || fail "the policy must follow the configuration the table was rebuilt from"
printf 'ok - no refresh runs before the list generation is applied\n'

# Without a protected section the protection is lifted whatever the runtime.
write_config byp vpn
sed -i '/kill_switch/d' "$PROKOP_UCI_STATE_FILE"
printf 'reload\n' >"$LISTS_PENDING"
ks sync manual || fail "lifting the protection must not wait for the runtime"
[ ! -e "$POLICY" ] || fail "the protection must be lifted"
printf 'ok - lifting the protection never waits\n'

printf 'killswitch_stale_runtime: PASS\n'
