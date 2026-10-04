#!/usr/bin/env bash
# While Prokop is stopped by the user or not started since boot (D-15), a
# reload never reaches start/reload, which refresh the kill-switch. A
# configuration change that leaves no protected section (unchecking the
# option, deleting the section, restoring a snapshot without it) must still
# lift the protection; one that keeps a protected section keeps the last
# applied protection until the next start (UC-208).
#
# Driven through service/initd.uc reload-begin, the entry point init.d runs
# for every reload: configuration change triggers, UI reloads and snapshot
# restores; and through service/lifecycle.uc reload, which checks again under
# the reload.lock init.d holds for it.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
INITD_UC="$PROKOP_LIB/service/initd.uc"
LIFECYCLE_UC="$PROKOP_LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'uci state:\n' >&2
  cat "$PROKOP_UCI_STATE_FILE" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/ks"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
case "$1 $2" in
  "list table")
    [ "$4" = "ProkopKillswitch" ] && { [ -e "$WORK_DIR/ks-present" ]; exit $?; }
    exit 1 ;;
  "delete table") [ "$4" = "ProkopKillswitch" ] && rm -f "$WORK_DIR/ks-present"; exit 0 ;;
esac
exit 0
NFT
for name in logger dnsmasq-init killswitch-init ip ubus; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
chmod 0755 "$WORK_DIR/bin/"*

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export PROKOP_CONFIG_FILE="$WORK_DIR/prokop.config"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/ruleset-post/90-prokop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export PROKOP_KILLSWITCH_LOCK_ATTEMPTS=2
: >"$PROKOP_CONFIG_FILE"

POLICY="$KILLSWITCH_STATE_DIR/policy.nft"
SERVERS="$KILLSWITCH_STATE_DIR/dnsmasq.servers"
BLOCKED="$KILLSWITCH_STATE_DIR/dns-blocked.servers"

uci_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2) }' "$PROKOP_UCI_STATE_FILE"
}

# Prokop stopped with the protection of section "main" in place.
arm() {
  cat >"$PROKOP_UCI_STATE_FILE" <<EOF
prokop.settings=settings
prokop.main=section
prokop.main.action=connection
prokop.main.kill_switch=1
prokop.other=section
prokop.other.action=connection
prokop.other.kill_switch=$1
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=1.1.1.1
dhcp.@dnsmasq[0].serversfile=$SERVERS
EOF
  printf 'add table inet ProkopKillswitch\n' >"$POLICY"
  printf 'server=/example.com/\n' >"$BLOCKED"
  cp "$BLOCKED" "$SERVERS"
  touch "$WORK_DIR/ks-present"
}

# What init.d runs for a reload of a runtime that is down.
reload() {
  local output
  output="$(ucode -L "$PROKOP_LIB" "$INITD_UC" reload-begin-fixture "$1" 0 0 1 "" 2>&1)" || true
  printf '%s\n' "$output" | grep -Fq "INITD_RELOAD_ACTION='skip'" ||
    fail "a reload of a stopped Prokop must be skipped (D-15): $output"
}

# init.d holds reload.lock while service/lifecycle.uc reloads, recorded the
# way core/runtime_lock records an owner. The owner is this shell, an
# ancestor of the lifecycle as init.d is (LC-3).
hold_reload_lock() {
  local ticks
  ticks="$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$$/stat")"
  mkdir -p "$PROKOP_RELOAD_LOCK_DIR"
  printf '%s\n%s\n' "$$" "$ticks" >"$PROKOP_RELOAD_LOCK_DIR/owner.$$.$ticks"
}

release_reload_lock() {
  rm -rf "$PROKOP_RELOAD_LOCK_DIR"
}

assert_kept() {
  [ -s "$POLICY" ] || fail "$1: the saved policy must stay"
  [ -e "$WORK_DIR/ks-present" ] || fail "$1: the live policy must stay"
  [ "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" = "$SERVERS" ] || fail "$1: the DNS block list must stay"
}

assert_lifted() {
  [ ! -e "$POLICY" ] || fail "$1: the saved policy must be removed"
  [ ! -e "$WORK_DIR/ks-present" ] || fail "$1: the live policy must be removed"
  [ -z "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" ] || fail "$1: dnsmasq must not read the block list any more"
}

# ---- stopped by the user ----------------------------------------------------

printf 'user\n' >"$PROKOP_RUNTIME_STATE_DIR/stop.requested"

arm 1
reload on_config_change
assert_kept "an unrelated change while stopped"

# Unchecking one of two protected sections keeps the protection: it cannot
# be rendered again without a runtime, and blocking is the safe side.
sed -i 's/^prokop.other.kill_switch=1$/prokop.other.kill_switch=0/' "$PROKOP_UCI_STATE_FILE"
reload on_config_change
assert_kept "one protected section left while stopped"

sed -i 's/^prokop.main.kill_switch=1$/prokop.main.kill_switch=0/' "$PROKOP_UCI_STATE_FILE"
reload on_config_change
assert_lifted "the option unchecked on the last protected section while stopped"

# A snapshot restore reloads with its own reason.
arm 0
sed -i '/^prokop.main/d' "$PROKOP_UCI_STATE_FILE"
reload config-restore
assert_lifted "a restored configuration without a protected section while stopped"

# A configuration libuci cannot load (a parse error after a hand edit, a
# file cut short) reads as no section at all. That proves nothing about the
# protected sections: the protection stays.
arm 1
sed -i '/^prokop\./d' "$PROKOP_UCI_STATE_FILE"
reload on_config_change
assert_kept "a configuration that could not be read while stopped"
grep -Fq 'could not be read' "$KILLSWITCH_STATE_DIR/state.json" ||
  fail "an unreadable configuration must be reported: $(cat "$KILLSWITCH_STATE_DIR/state.json" 2>/dev/null)"

# A stop that lands after init.d let the reload through is caught again by
# service/lifecycle.uc under the reload.lock init.d holds for it.
arm 1
sed -i 's/kill_switch=1$/kill_switch=0/' "$PROKOP_UCI_STATE_FILE"
hold_reload_lock
ucode -L "$PROKOP_LIB" "$LIFECYCLE_UC" reload on_config_change >"$WORK_DIR/lifecycle.out" 2>&1 ||
  fail "the reload of a stopped Prokop failed: $(cat "$WORK_DIR/lifecycle.out")"
assert_lifted "the option unchecked on every section, seen by the reload under reload.lock"
[ -d "$PROKOP_RELOAD_LOCK_DIR" ] || fail "the reload must leave init.d's reload.lock alone"
release_reload_lock

# ---- not started since boot -------------------------------------------------

rm -f "$PROKOP_RUNTIME_STATE_DIR/stop.requested" "$PROKOP_RUNTIME_STATE_DIR/start.explicit"
arm 0
sed -i 's/^prokop.main.action=connection$/prokop.main.action=bypass/' "$PROKOP_UCI_STATE_FILE"
reload on_config_change
assert_lifted "the protected section turned into a bypass while not started"

printf 'killswitch_stopped_reload: PASS\n'
