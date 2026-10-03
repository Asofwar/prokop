#!/usr/bin/env bash
set -euo pipefail

# br_netfilter's iptables hooks around Forkop's start and stop (D-19 (a),
# UC-109).
#
# Before: start wrote net.bridge.bridge-nf-call-iptables=0 and -ip6tables=0
# for the whole system and nothing put them back; iptables filtering of
# bridged traffic stayed off after a stop or a removal until a reboot.
#
# Now start records the value of each hook it turns off, once per boot, and
# stop puts it back where the hook still holds Forkop's 0. A hook that
# another program set since is left as it is, and so is everything when the
# record cannot be read. Health reports a loaded br_netfilter.
#
# The real nft/apply.uc and diagnostics/health.uc run against a fake
# /proc/sys (FORKOP_PROC_SYS_DIR); the host's is never read or written.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/syslog" ] || sed 's/^/  syslog: /' "$WORK/syslog" >&2
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

SYS="$WORK/proc-sys"
BRIDGE="$SYS/net/bridge"
RUN="$WORK/run"
RECORD="$RUN/bridge-netfilter.saved"
mkdir -p "$WORK/bin" "$RUN"
export PATH="$WORK/bin:$PATH" TMPDIR="$WORK" SYSLOG="$WORK/syslog"
export FORKOP_PROC_SYS_DIR="$SYS" FORKOP_RUNTIME_STATE_DIR="$RUN"
export FORKOP_NFT_SUBNET_CACHE_DIR="$WORK/subnet-cache"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$SYSLOG"\n' >"$WORK/bin/logger"
# Nothing may reach the host's sysctl or nftables.
printf '#!/bin/sh\necho "unexpected sysctl $*" >>"$SYSLOG"\nexit 1\n' >"$WORK/bin/sysctl"
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/nft"
chmod +x "$WORK/bin/"*

nft_uc() { ucode -L "$LIB" "$LIB/nft/apply.uc" "$@"; }
start() { nft_uc ensure-bridge-netfilter-disabled || fail "start: turning off the hooks failed"; }
stop() { nft_uc restore-bridge-netfilter || fail "stop: restoring the hooks failed"; }
# hooks <iptables> <ip6tables>: br_netfilter loaded with these values.
hooks() {
  rm -rf "$SYS" "$RECORD"
  : >"$SYSLOG"
  mkdir -p "$BRIDGE"
  printf '%s\n' "$1" >"$BRIDGE/bridge-nf-call-iptables"
  printf '%s\n' "$2" >"$BRIDGE/bridge-nf-call-ip6tables"
}
value() { cat "$BRIDGE/bridge-nf-call-$1"; }
expect() { # expect <iptables> <ip6tables> <what>
  [ "$(value iptables) $(value ip6tables)" = "$1 $2" ] ||
    fail "$3: hooks are '$(value iptables) $(value ip6tables)', expected '$1 $2'"
}

# 1. Start turns the hooks off; stop puts them back.
hooks 1 1
start
expect 0 0 "after start"
[ -s "$RECORD" ] || fail "start did not record the hooks it turned off"
grep -q 'disabling it for transparent proxy routing' "$SYSLOG" || fail "start did not log turning the hooks off"
stop
expect 1 1 "after stop"
[ ! -e "$RECORD" ] || fail "stop left the record behind"
ok "start turns the hooks off and stop puts them back"

# 2. A second start (reload, restart, crash) keeps the values from before
#    Forkop; only a hook that was on is recorded and put back.
hooks 1 0
start
start
expect 0 0 "after two starts"
stop
expect 1 0 "after two starts and a stop"
ok "the values from before Forkop survive a second start; a hook that was off stays off"

# 3. Another program has set a hook since Forkop's start: stop leaves it.
hooks 1 1
start
printf '1\n' >"$BRIDGE/bridge-nf-call-ip6tables"
touch -d '@1000000000' "$BRIDGE/bridge-nf-call-ip6tables"
stop
expect 1 1 "after a foreign change and a stop"
[ "$(stat -c %Y "$BRIDGE/bridge-nf-call-ip6tables")" = 1000000000 ] ||
  fail "stop wrote a hook that another program had set"
grep -q 'bridge-nf-call-ip6tables was changed by another program' "$SYSLOG" ||
  fail "stop did not log the hook it left to another program"
ok "a hook another program set since the start is left alone"

# 4. An unreadable record changes nothing and goes.
hooks 0 0
printf 'not json' >"$RECORD"
touch -d '@1000000000' "$BRIDGE/bridge-nf-call-iptables" "$BRIDGE/bridge-nf-call-ip6tables"
stop
expect 0 0 "after a stop with an unreadable record"
[ "$(stat -c %Y "$BRIDGE/bridge-nf-call-iptables")" = 1000000000 ] || fail "an unreadable record changed a hook"
[ ! -e "$RECORD" ] || fail "an unreadable record was kept"
ok "an unreadable record changes nothing"

# 5. Without br_netfilter, or with its hooks already off, nothing is recorded
#    or written.
rm -rf "$SYS" "$RECORD"
start
stop
[ ! -e "$RECORD" ] || fail "a start without br_netfilter recorded hooks"
hooks 0 0
start
[ ! -e "$RECORD" ] || fail "a start with the hooks already off recorded them"
stop
expect 0 0 "hooks that were off"
! grep -q 'unexpected sysctl' "$SYSLOG" || fail "the hooks were changed through the sysctl command"
ok "nothing is recorded without br_netfilter or with its hooks off"

# 6. Health reports a loaded br_netfilter as a warning, and whether Forkop
#    holds its hooks off.
# The UI state that health reads comes from a stand-in.
mkdir -p "$WORK/fake-lib/service"
printf 'print("{}\\n");\n' >"$WORK/fake-lib/service/ui.uc"
health_bridge() {
  FORKOP_LIB="$WORK/fake-lib" FORKOP_HISTORY_FILE="$WORK/history.jsonl" FORKOP_OPKG_RECOVERY_DIR="$WORK/recovery" \
    FORKOP_SNAPSHOT_LOCK_DIR="$WORK/snapshot.lock" FORKOP_RELOAD_LOCK_DIR="$WORK/reload.lock" \
    ucode -L "$LIB" "$LIB/diagnostics/health.uc" get 2>/dev/null |
    node -e 'const h = JSON.parse(require("fs").readFileSync(0, "utf8")); process.stdout.write(JSON.stringify(h.bridge_netfilter))'
}
hooks 1 1
start
[ "$(health_bridge)" = '{"status":"warning","loaded":true,"disabled_by_forkop":true}' ] ||
  fail "health with br_netfilter whose hooks Forkop holds off: $(health_bridge)"
# Another program has turned them on again: Forkop holds nothing off.
printf '1\n' >"$BRIDGE/bridge-nf-call-iptables"
printf '1\n' >"$BRIDGE/bridge-nf-call-ip6tables"
[ "$(health_bridge)" = '{"status":"warning","loaded":true,"disabled_by_forkop":false}' ] ||
  fail "health with hooks another program turned on again: $(health_bridge)"
hooks 1 1
start
stop
[ "$(health_bridge)" = '{"status":"warning","loaded":true,"disabled_by_forkop":false}' ] ||
  fail "health with br_netfilter after the stop: $(health_bridge)"
rm -rf "$SYS"
[ "$(health_bridge)" = '{"status":"ok","loaded":false,"disabled_by_forkop":false}' ] ||
  fail "health without br_netfilter: $(health_bridge)"
ok "health warns about a loaded br_netfilter"

printf 'bridge netfilter checks passed\n'
