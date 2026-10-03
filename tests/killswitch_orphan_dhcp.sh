#!/usr/bin/env bash
# The kill-switch watcher that finds its package gone detaches the DNS block
# list from dnsmasq through the edit core/uci.uc gives every dhcp writer
# (S5 integration, UC-236): /etc/config/dhcp is replaced only while it holds
# what the edit read, and what someone staged for dhcp with `uci set` (an
# unsaved LuCI change) is neither committed nor lost. It committed through
# the libuci binding, whose commit also commits those staged changes (and
# without the binding, which some ucode builds lack, it detached nothing).
#
# A detach that fails is said in the system log, and the block list that
# dhcp still names is emptied, not removed: dnsmasq does not start with a
# servers file that is gone, and its blocks are lifted all the same (S5
# integration review).
#
# The real watcher (killswitch/runtime.uc watch) on a dhcp file through the
# OpenWrt uci CLI; skipped without one (the test shim does not resolve
# @dnsmasq[0]). What someone staged sits in the CLI's staging directory
# here, which a libuci cursor of the watcher would not read: that the
# watcher edits dhcp through the session is checked by its calls of the uci
# CLI on a private copy.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

WATCHER=""
cleanup() {
  [ -z "$WATCHER" ] || owned_kill TERM "$WATCHER" || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'dhcp:\n' >&2
  cat "$WORK_DIR/etc/config/dhcp" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

UCI_REAL="$(command -v uci 2>/dev/null || true)"
if [ -z "$UCI_REAL" ]; then
  printf 'NOTE: no OpenWrt uci CLI on PATH; the dhcp checks of the orphaned watcher are skipped\n'
  printf 'killswitch_orphan_dhcp: PASS\n'
  exit 0
fi

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/ks" "$WORK_DIR/cache" "$WORK_DIR/etc/config" \
  "$WORK_DIR/foreign-save" "$WORK_DIR/package/killswitch"
# nft: no kill-switch table. The watcher lists its DNS chain first thing,
# once its module is loaded: the log says it runs.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/nft.log"\nexit 1\n' "$WORK_DIR" >"$WORK_DIR/bin/nft"
for name in logger dnsmasq-init ubus; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/dig"
# The uci CLI: the router's default configuration directory and staging
# directory (/etc/config, /tmp/.uci) are the ones under $WORK_DIR. Its calls
# are logged; with $WORK_DIR/uci-delete-fails present, a delete fails.
cat >"$WORK_DIR/bin/uci" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK_DIR/uci.calls"
case " \$* " in
  *" -c "*" delete "*) [ ! -e "$WORK_DIR/uci-delete-fails" ] || exit 1; exec "$UCI_REAL" "\$@" ;;
  *" -c "*) exec "$UCI_REAL" "\$@" ;;
esac
exec "$UCI_REAL" -c "$WORK_DIR/etc/config" -t "$WORK_DIR/foreign-save" "\$@"
SH
chmod 0755 "$WORK_DIR/bin/"*

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
unset PROKOP_UCI_STATE_FILE PROKOP_UCI_LOG_FILE
export PROKOP_LIB
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export PROKOP_DNSMASQ_CONFIG_FILE="$WORK_DIR/etc/config/dhcp"
export PROKOP_UCI_CLI="$WORK_DIR/bin/uci"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/ruleset-post/90-prokop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"

SERVERS="$KILLSWITCH_STATE_DIR/dnsmasq.servers"
uci_get() { "$UCI_REAL" -q -c "$WORK_DIR/etc/config" -t "$WORK_DIR/empty-save" get "$1" || true; }
watcher_running() { [ -s "$WORK_DIR/nft.log" ]; }

# dhcp with the block list attached, the block list, and an unsaved LuCI
# change to dhcp, staged with `uci set`.
protected() {
  cat >"$WORK_DIR/etc/config/dhcp" <<EOF
config dnsmasq
	option domain 'lan'
	list server '1.1.1.1'
	option serversfile '$SERVERS'

config dhcp 'lan'
	option interface 'lan'
	option leasetime '12h'
EOF
  printf 'server=/example.com/\n' >"$SERVERS"
  cp "$SERVERS" "$KILLSWITCH_STATE_DIR/dns-blocked.servers"
  rm -rf "$WORK_DIR/foreign-save"
  mkdir -p "$WORK_DIR/foreign-save"
  uci set dhcp.lan.leasetime=1h
  [ -s "$WORK_DIR/foreign-save/dhcp" ] || fail "the foreign change was not staged"
  : >"$WORK_DIR/uci.calls"
  : >"$WORK_DIR/nft.log"
  : >"$WORK_DIR/logger.log"
  : >"$WORK_DIR/dnsmasq-init.log"
}

# A copy of the watcher's module stands for the package's file: removing it,
# once the watcher has loaded it, is what a removal or a downgrade without
# its scripts does.
orphaned_watcher() {
  cp "$KS_UC" "$WORK_DIR/package/killswitch/runtime.uc"
  PROKOP_KILLSWITCH_WATCH_ITERATIONS=20000 PROKOP_KILLSWITCH_WATCH_INTERVAL_MS=1 \
    ucode -L "$PROKOP_LIB" "$WORK_DIR/package/killswitch/runtime.uc" watch &
  WATCHER=$!
  wait_until 15 watcher_running || fail "the watcher did not start"
  rm -f "$WORK_DIR/package/killswitch/runtime.uc"
  wait_until 15 sh -c "! kill -0 $WATCHER 2>/dev/null" || fail "the watcher did not stop once its package was gone"
  wait "$WATCHER" 2>/dev/null || true
  WATCHER=""
}

protected
orphaned_watcher

[ -z "$(uci_get 'dhcp.@dnsmasq[0].serversfile')" ] || fail "the watcher did not detach the block list from dnsmasq"
grep -E -- ' -c [^ ]+ -t [^ ]+ delete ' "$WORK_DIR/uci.calls" | grep -Fqv -- "-c $WORK_DIR/etc/config " ||
  fail "the watcher did not edit dhcp through the uci CLI on a private copy: $(cat "$WORK_DIR/uci.calls")"
[ "$(uci_get 'dhcp.@dnsmasq[0].domain')" = lan ] || fail "the watcher changed more of dhcp than the block list"
[ "$(uci_get 'dhcp.lan.leasetime')" = 12h ] ||
  fail "the watcher committed a change someone else had staged for dhcp: leasetime $(uci_get 'dhcp.lan.leasetime')"
grep -q "leasetime" "$WORK_DIR/foreign-save/dhcp" 2>/dev/null || fail "the change someone else had staged for dhcp was lost"
grep -Fqx restart "$WORK_DIR/dnsmasq-init.log" || fail "dnsmasq was not restarted without the block list"
for file in "$WORK_DIR"/etc/config/.dhcp.* "$WORK_DIR"/etc/config/dhcp.*; do
  [ ! -e "$file" ] || fail "a temporary file was left next to dhcp: ${file##*/}"
done
[ ! -e "$SERVERS" ] || fail "the detached block list was left behind"
printf 'ok - the orphaned watcher detaches the block list through the session\n'

# The detach fails: dhcp keeps naming the block list.
protected
: >"$WORK_DIR/uci-delete-fails"
orphaned_watcher
rm -f "$WORK_DIR/uci-delete-fails"
[ "$(uci_get 'dhcp.@dnsmasq[0].serversfile')" = "$SERVERS" ] || fail "the failing uci CLI still detached the block list"
grep -F '[error]' "$WORK_DIR/logger.log" | grep -F "$SERVERS" | grep -Fq serversfile ||
  fail "a failed detach was not logged as an error naming the block list and the option"
[ -e "$SERVERS" ] || fail "the block list that dhcp still names was removed"
[ ! -s "$SERVERS" ] || fail "the block list that dhcp still names still blocks: $(cat "$SERVERS")"
grep -Fqx restart "$WORK_DIR/dnsmasq-init.log" || fail "dnsmasq was not restarted with the emptied block list"
[ "$(uci_get 'dhcp.lan.leasetime')" = 12h ] || fail "the failed detach committed a change someone else had staged"
printf 'ok - a failed detach is logged and leaves an empty block list for dnsmasq\n'
printf 'killswitch_orphan_dhcp: PASS\n'
