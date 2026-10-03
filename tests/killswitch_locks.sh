#!/usr/bin/env bash
# Kill-switch locking (UC-210): killswitch.lock follows core/runtime_lock (the
# owner is a pid with its start time), a manual sync or removal takes
# reload.lock first (global order: service/state.uc), a removal for the
# package never stays behind a lock, and the watcher tells a planned restart
# from a stale reload.lock.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

HOLDERS=()
cleanup() {
  owned_kill TERM "${HOLDERS[@]}" || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$WORK_DIR/ks"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK_DIR/nft.log"
case "$1 $2" in
  "list table")
    [ "$4" = "ProkopTable" ] && { [ -e "$WORK_DIR/live-present" ]; exit $?; }
    [ "$4" = "ProkopKillswitch" ] && { [ -e "$WORK_DIR/ks-present" ]; exit $?; }
    exit 1 ;;
  "list chain")
    [ -e "$WORK_DIR/ks-present" ] || exit 1
    printf 'table inet ProkopKillswitch {\n\tchain ks_dns {\n'
    cat "$WORK_DIR/ks_dns" 2>/dev/null
    printf '\t}\n}\n'
    exit 0 ;;
  "list set")
    printf 'table inet ProkopTable {\n\tset %s {\n\t\ttype ipv4_addr\n\t}\n}\n' "$5"
    exit 0 ;;
  "-c -f") exit 0 ;;
  "delete table") rm -f "$WORK_DIR/ks-present"; exit 0 ;;
esac
if [ "$1" = "-f" ]; then
  if grep -q '^add table inet ProkopKillswitch' "$2"; then
    touch "$WORK_DIR/ks-present"
    : > "$WORK_DIR/ks_dns"
  else
    grep 'redirect to' "$2" > "$WORK_DIR/ks_dns" || : > "$WORK_DIR/ks_dns"
  fi
fi
exit 0
NFT
for name in logger dnsmasq-init killswitch-init conntrack prokop-init; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
[ -e "$WORK_DIR/sing-box-alive" ]
SH
chmod 0755 "$WORK_DIR/bin/"*

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/prokop-init"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/ruleset-post/90-prokop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"
# Test-only bound: two waits of 500 ms for a held lock instead of a minute.
export PROKOP_KILLSWITCH_LOCK_ATTEMPTS=2
export PROKOP_KILLSWITCH_WATCH_INTERVAL_MS=1

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

ks() { ucode -L "$PROKOP_LIB" "$KS_UC" "$@"; }
POLICY="$KILLSWITCH_STATE_DIR/policy.nft"
KS_LOCK="$PROKOP_RUNTIME_STATE_DIR/killswitch.lock"

# Field 22 of /proc/<pid>/stat (field 3 is the first after the name).
start_ticks() {
  awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat"
}

# A process that holds a lock the way core/runtime_lock records it.
hold_lock() {
  local dir="$1" pid
  sleep 300 &
  pid=$!
  HOLDERS+=("$pid")
  wait_until 5 test -r "/proc/$pid/stat" || fail "holder did not start"
  mkdir -p "$dir"
  printf '%s\n%s\n' "$pid" "$(start_ticks "$pid")" >"$dir/owner.$pid.$(start_ticks "$pid")"
  HOLDER="$pid"
}

touch "$WORK_DIR/live-present"
ks sync start reload-lock-held || fail "initial sync failed"
[ -s "$POLICY" ] || fail "initial sync must save the policy"

# 1. A record of a live process with another start time (a reused pid) is
#    stale: the next operation breaks it at once.
sleep 300 &
reused=$!
HOLDERS+=("$reused")
wait_until 5 test -r "/proc/$reused/stat" || fail "pid holder did not start"
mkdir -p "$KS_LOCK"
printf '%s\n1\n' "$reused" >"$KS_LOCK/owner.$reused.1"
ks sync reload reload-lock-held || fail "a reused pid must not hold killswitch.lock"
[ ! -e "$KS_LOCK" ] || fail "killswitch.lock must be released"

# 2. A manual sync waits for reload.lock and refuses while a start, stop or
#    reload holds it: dnsmasq and the policy never change under them.
hold_lock "$PROKOP_RELOAD_LOCK_DIR"
cp "$POLICY" "$WORK_DIR/policy.before"
printf 'prokop.main.kill_switch=0\n' >>"$PROKOP_UCI_STATE_FILE"
if ks disable "manual" 2>"$WORK_DIR/manual.err"; then
  fail "a manual removal must not run while reload.lock is held"
fi
cmp -s "$POLICY" "$WORK_DIR/policy.before" || fail "a refused removal must leave the policy alone"
[ -e "$WORK_DIR/ks-present" ] || fail "a refused removal must leave the live policy alone"
grep -qi 'start' "$WORK_DIR/manual.err" || fail "the refusal must say why: $(cat "$WORK_DIR/manual.err")"
if ks sync manual; then
  fail "a manual sync must not run while reload.lock is held"
fi
[ -s "$POLICY" ] || fail "a refused sync must keep the policy"

# 3. Start and reload sync while they hold reload.lock themselves.
sed -i '/kill_switch=0/d' "$PROKOP_UCI_STATE_FILE"
ks sync reload reload-lock-held || fail "a sync inside the caller's reload.lock must run"
kill "$HOLDER"
wait "$HOLDER" 2>/dev/null || true

# 4. A manual sync takes reload.lock (in order), runs and hands it back,
#    then applies a reload queued behind it, as every holder does (UC-061).
printf 'reason=on_config_change\n' >"$PROKOP_PENDING_RELOAD_FILE"
ks sync manual || fail "manual sync with free locks failed"
[ ! -e "$PROKOP_RELOAD_LOCK_DIR" ] || fail "manual sync must release reload.lock"
[ ! -e "$KS_LOCK" ] || fail "manual sync must release killswitch.lock"
grep -Fqx 'reload pending' "$WORK_DIR/prokop-init.log" || fail "a reload queued behind the manual sync must run"
[ ! -e "$PROKOP_PENDING_RELOAD_FILE" ] || fail "the queued reload must be consumed"

# 5. The package's removal never stays behind a lock: it waits a bounded
#    time and then removes the protection anyway.
hold_lock "$KS_LOCK"
if ks disable "manual"; then
  fail "a manual removal must not pass a held killswitch.lock"
fi
[ -s "$POLICY" ] || fail "a refused removal keeps the policy"
printf 'reason=on_config_change\n' >"$PROKOP_PENDING_RELOAD_FILE"
: >"$WORK_DIR/prokop-init.log"
ks release "package removal" || fail "the package removal must lift the protection"
[ ! -s "$WORK_DIR/prokop-init.log" ] || fail "a removal for the package must not run queued reloads"
rm -f "$PROKOP_PENDING_RELOAD_FILE"
[ ! -e "$POLICY" ] || fail "the package removal must remove the saved policy despite the lock"
[ ! -e "$WORK_DIR/ks-present" ] || fail "the package removal must remove the live policy despite the lock"
kill "$HOLDER"
wait "$HOLDER" 2>/dev/null || true
rm -rf "$KS_LOCK"

# 6. The watcher fails over unless Prokop really restarts sing-box: a
#    reload.lock left behind by a dead owner does not suppress it.
touch "$WORK_DIR/live-present"
ks sync start reload-lock-held || fail "re-arm failed"
printf 'server=/example.com/\n' >"$KILLSWITCH_STATE_DIR/dns-blocked.servers"
mkdir -p "$PROKOP_RELOAD_LOCK_DIR"
printf '999999\n1\n' >"$PROKOP_RELOAD_LOCK_DIR/owner.999999.1"
touch -d '1 minute ago' "$PROKOP_RELOAD_LOCK_DIR"
rm -f "$WORK_DIR/sing-box-alive"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=4 ks watch
grep -Fq 'redirect to :18054' "$WORK_DIR/ks_dns" ||
  fail "a stale reload.lock must not keep client DNS on a dead sing-box"
rm -rf "$PROKOP_RELOAD_LOCK_DIR"
: > "$WORK_DIR/ks_dns"
hold_lock "$PROKOP_RELOAD_LOCK_DIR"
PROKOP_KILLSWITCH_WATCH_ITERATIONS=4 ks watch
[ ! -s "$WORK_DIR/ks_dns" ] || fail "a planned restart under a live reload.lock is not an outage"

printf 'killswitch_locks: PASS\n'
