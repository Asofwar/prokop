#!/usr/bin/env bash
set -euo pipefail

# TorrServer Direct (torrserver/direct.uc) against a fake /proc and cgroup
# tree, an nft that records what it is asked, and a libuci stand-in with the
# binding's cache.
#
# UC-108: a re-apply deleted the table with one nft call and created it with
# another, from a fixed /tmp path written through symlinks. Between the two
# TorrServer's new connections went unmarked into Prokop's interception. Now
# one nft -f from a fresh temporary file replaces the table in a single
# transaction (add, delete, add), and no table is deleted on its own unless
# that transaction fails.
#
# UC-110: the worker read torrserver_direct_enabled through core.uci, which
# loads a package once per process; a snapshot restore or `uci set ...=0`
# never reached the long-running worker, and its rule stayed. Now every
# check reads the setting afresh: off removes the rule and on applies it
# again, and the worker keeps running (procd would respawn it if it ended).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
DIRECT_UC="$LIB/torrserver/direct.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
trap 'exit 1' HUP INT TERM
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/nft.log" ] || sed 's/^/  nft: /' "$WORK/nft.log" >&2
  exit 1
}

REAL_SLEEP="$(command -v sleep)"
mkdir -p "$WORK/bin" "$WORK/modules" "$WORK/tmp" "$WORK/proc/4242" "$WORK/cgroup/services/torrserver"
export PATH="$WORK/bin:$PATH" TMPDIR="$WORK/tmp" NFT_LOG="$WORK/nft.log" NFT_STATE="$WORK/nft.applied"
export PROKOP_PROC_DIR="$WORK/proc" PROKOP_CGROUP_DIR="$WORK/cgroup" STUB_STATE="$WORK/uci.json"
export SLEEP_COUNT="$WORK/sleep.count" POLL_LOG="$WORK/poll.log" POLL_DONE="$WORK/poll.done" REAL_SLEEP
unset PROKOP_UCI_STATE_FILE

# A TorrServer in a cgroup of its own.
printf '/usr/bin/torrserver\0--port\08090\0' >"$WORK/proc/4242/cmdline"
printf '0::/services/torrserver\n' >"$WORK/proc/4242/cgroup"
printf '4242\n' >"$WORK/cgroup/services/torrserver/cgroup.procs"

# nft: every call, and the text of a file it is given, is recorded. A table
# added by a file is listed until a delete of it.
cat >"$WORK/bin/nft" <<'SH'
#!/bin/sh
printf 'call:%s\n' "$*" >>"$NFT_LOG"
case "$1" in
  -f)
    printf 'path:%s\n' "$2" >>"$NFT_LOG"
    sed 's/^/file:/' "$2" >>"$NFT_LOG"
    [ -z "${NFT_FAIL_F:-}" ] || exit 1
    : >"$NFT_STATE"
    ;;
  delete) rm -f "$NFT_STATE" ;;
  list)
    [ -e "$NFT_STATE" ] || exit 1
    cat <<'OUT'
table inet ProkopTorrServerDirect {
	chain output {
		type route hook output priority mangle - 1; policy accept;
		ip daddr != 198.18.0.0/15 socket cgroupv2 level 2 "services/torrserver" meta mark set 0x08000000 counter packets 0 bytes 0 comment "Prokop TorrServer Direct"
		ip6 daddr != fc00::/18 socket cgroupv2 level 2 "services/torrserver" meta mark set 0x08000000 counter packets 0 bytes 0 comment "Prokop TorrServer Direct"
	}
}
OUT
    ;;
esac
exit 0
SH
# The worker's poll. After the first round the setting goes off, as a
# snapshot restore or `uci set` + commit by another process does; after the
# second it goes on again. Each round records whether the rule is there. The
# third round marks the end and waits for the test to stop the worker.
cat >"$WORK/bin/sleep" <<'SH'
#!/bin/sh
count=$(($(cat "$SLEEP_COUNT" 2>/dev/null || echo 0) + 1))
echo "$count" >"$SLEEP_COUNT"
if [ -e "$NFT_STATE" ]; then echo "$count:rule" >>"$POLL_LOG"; else echo "$count:none" >>"$POLL_LOG"; fi
case "$count" in
  1) value=0 ;;
  2) value=1 ;;
  *) echo $$ >"$POLL_DONE"; exec "$REAL_SLEEP" 60 ;;
esac
printf '{"prokop":{"settings":{".name":"settings",".type":"settings","torrserver_direct_enabled":"%s"}}}' "$value" >"$STUB_STATE"
SH
chmod +x "$WORK/bin/nft" "$WORK/bin/sleep"

# libuci as the ucode binding uses it: load reads the file, get answers from
# what was loaded until the package is unloaded or loaded again.
cat >"$WORK/modules/uci.uc" <<'UC'
let fs = require("fs");
function cursor() {
    let loaded = {};
    return {
        load: function(p) {
            let state = json(fs.readfile(getenv("STUB_STATE")) || "{}");
            if (state[p] == null) return null;
            loaded[p] = state[p];
            return true;
        },
        unload: function(p) { delete loaded[p]; return true; },
        get: function(p, s, o) {
            let sections = loaded[p];
            if (sections == null || sections[s] == null) return null;
            return o == null ? sections[s][".type"] : sections[s][o];
        },
        foreach: function(p, t, cb) { return true; }
    };
}
return { cursor };
UC

set_enabled() {
  printf '{"prokop":{"settings":{".name":"settings",".type":"settings","torrserver_direct_enabled":"%s"}}}' "$1" >"$STUB_STATE"
}
direct() { ucode -L "$WORK/modules" -L "$LIB" "$DIRECT_UC" "$@"; }
reset() { : >"$NFT_LOG"; rm -f "$NFT_STATE" "$SLEEP_COUNT" "$POLL_LOG" "$POLL_DONE"; }

# ---- UC-108: one transaction --------------------------------------------------
set_enabled 1
for round in first re-apply; do
  [ "$round" = first ] && rm -f "$NFT_STATE"
  : >"$NFT_LOG"
  direct reconcile || fail "reconcile ($round) failed"
  ! grep -q '^call:delete' "$NFT_LOG" || fail "the $round apply deleted the table outside its transaction"
  [ "$(grep -c '^call:-f' "$NFT_LOG")" = 1 ] || fail "the $round apply did not use exactly one nft -f"
  grep -v '^file:' "$NFT_LOG" | grep -q '^call:\(add\|insert\|flush\)' &&
    fail "the $round apply changed the ruleset outside its transaction"
  batch="$(sed -n 's/^file://p' "$NFT_LOG")"
  expected='add table inet ProkopTorrServerDirect
delete table inet ProkopTorrServerDirect
add table inet ProkopTorrServerDirect'
  [ "$(printf '%s\n' "$batch" | head -n 3)" = "$expected" ] ||
    fail "the $round batch does not replace the table in one transaction: $batch"
  # Connections to sing-box's FakeIP range stay unmarked, so they reach
  # sing-box (TS-9).
  printf '%s\n' "$batch" | grep -q '^add rule inet ProkopTorrServerDirect output ip daddr != 198.18.0.0/15 socket cgroupv2 level 2 "services/torrserver" meta mark set' ||
    fail "the $round batch lacks the IPv4 rule that leaves FakeIP alone: $batch"
  printf '%s\n' "$batch" | grep -q '^add rule inet ProkopTorrServerDirect output ip6 daddr != fc00::/18 socket cgroupv2 level 2 "services/torrserver" meta mark set' ||
    fail "the $round batch lacks the IPv6 rule that leaves FakeIP alone: $batch"
  [ "$(printf '%s\n' "$batch" | grep -c '^add rule')" = 2 ] || fail "the $round batch must mark only through those two rules: $batch"
  path="$(sed -n 's/^path://p' "$NFT_LOG")"
  case "$path" in
    "$WORK/tmp/"*) ;;
    *) fail "the $round batch was not written to a fresh temporary file: $path" ;;
  esac
  [ ! -e "$path" ] || fail "the $round batch file was left behind"
  [ -z "$(ls -A "$WORK/tmp")" ] || fail "the $round apply left temporary files: $(ls -A "$WORK/tmp")"
done

# A refused transaction changed nothing; what is left of an older rule goes.
: >"$NFT_LOG"
if NFT_FAIL_F=1 direct reconcile; then fail "a refused nft -f was reported as applied"; fi
grep -q '^call:delete table inet ProkopTorrServerDirect' "$NFT_LOG" ||
  fail "a refused transaction did not remove the older rule"
[ -z "$(ls -A "$WORK/tmp")" ] || fail "a refused apply left temporary files: $(ls -A "$WORK/tmp")"
printf 'ok - a re-apply is one nft transaction from a fresh temporary file\n'

# ---- UC-110: the worker sees the setting change ----------------------------------
reset
set_enabled 1
# In a process group of its own, which the test stops as a whole.
setsid ucode -L "$WORK/modules" -L "$LIB" "$DIRECT_UC" worker &
worker_pid=$!
for _ in $(seq 200); do
  [ -s "$POLL_DONE" ] && break
  kill -0 "$worker_pid" 2>/dev/null || break
  "$REAL_SLEEP" 0.1
done
worker_alive=0
kill -0 "$worker_pid" 2>/dev/null && worker_alive=1
{ owned_kill TERM "$worker_pid"; wait "$worker_pid"; } 2>/dev/null || true
polls="$(tr '\n' ' ' <"$POLL_LOG" 2>/dev/null || true)"
[ -s "$POLL_DONE" ] || fail "the worker did not reach its third poll (polls: $polls)"
[ "$worker_alive" = 1 ] || fail "the worker exited, which procd would respawn into a crash loop (polls: $polls)"
[ "$polls" = "1:rule 2:none 3:rule " ] ||
  fail "the worker did not follow the setting off and on again (polls: $polls)"
printf 'ok - the worker reads the setting afresh: off removes the rule, on applies it again, it keeps running\n'

printf 'TorrServer Direct re-apply checks passed\n'
