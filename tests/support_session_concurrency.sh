#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
export PROKOP_LIB="$LIB" PROKOP_SUPPORT_DIR="$WORK/support"
export PROKOP_TAILSCALED="$WORK/tailscaled" PROKOP_TAILSCALE="$WORK/bin/tailscale"
# shellcheck source=tests/helpers/owned_processes.sh
source "$ROOT/tests/helpers/owned_processes.sh"
PIDS=()
cleanup() {
  touch "$WORK/release"
  for record in daemon.pid expiry.pid; do
    if [ -f "$PROKOP_SUPPORT_DIR/$record" ]; then
      IFS= read -r pid <"$PROKOP_SUPPORT_DIR/$record"
      owned_kill TERM "$pid" || true
    fi
  done
  for pid in "${PIDS[@]}"; do
    owned_kill_children TERM "$pid"
    owned_kill TERM "$pid" || true
    wait "$pid" 2>/dev/null || true
  done
  ucode -L "$LIB" "$LIB/experiments/support.uc" stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/bin"
cat >"$WORK/daemon.c" <<'C'
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
int main(int argc,char **argv){
  struct sockaddr_un a={.sun_family=AF_UNIX};
  for(int i=1;i<argc;i++)if(!strncmp(argv[i],"--socket=",9))strncpy(a.sun_path,argv[i]+9,sizeof(a.sun_path)-1);
  int s=socket(AF_UNIX,SOCK_STREAM,0);
  if(!a.sun_path[0]||s<0||bind(s,(struct sockaddr*)&a,sizeof(a))||listen(s,1))return 1;
  for(;;)pause();
}
C
cc -Wall -Werror -o "$PROKOP_TAILSCALED" "$WORK/daemon.c"
cat >"$WORK/bin/nft" <<'NFT'
#!/bin/sh
case "$*" in
*'list chain'*) printf '{"nftables":[]}\n' ;;
*'insert rule'*)
  if [ "$PAUSE_AT" = nft ]; then
    touch "$PROKOP_SUPPORT_DIR/../entered"
    while [ ! -e "$PROKOP_SUPPORT_DIR/../release" ]; do sleep 0.02; done
  fi ;;
esac
NFT
cat >"$PROKOP_TAILSCALE" <<'TS'
#!/bin/sh
shift
case "$1" in
status) printf '{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.7"]}}\n' ;;
up)
  if [ "$PAUSE_AT" = up ]; then
    touch "$PROKOP_SUPPORT_DIR/../entered"
    while [ ! -e "$PROKOP_SUPPORT_DIR/../release" ]; do sleep 0.02; done
  fi ;;
serve) ;;
*) exit 1 ;;
esac
TS
chmod +x "$WORK/bin/nft" "$PROKOP_TAILSCALE"
export PATH="$WORK/bin:$PATH"
run() { ucode -L "$LIB" "$LIB/experiments/support.uc" "$@"; }
await_file() {
  for ((i=0;i<250;i++)); do [ ! -e "$1" ] || return 0; sleep 0.02; done
  printf 'FAIL: barrier not reached: %s\n' "$1" >&2; return 1
}
begin() {
  rm -f "$WORK/entered" "$WORK/release"
  run prepare >/dev/null
  printf '%s\n' tskey-auth-fixture-0123456789 >"$PROKOP_SUPPORT_DIR/authkey"
  run start 22 >"$WORK/start.json" & START=$!; PIDS+=("$START")
  await_file "$WORK/entered"
}
check() { node - "$@"; }
export PAUSE_AT=nft
begin
run stop >"$WORK/stop.json" || true
check "$WORK/stop.json" "$PROKOP_SUPPORT_DIR" <<'NODE'
const fs=require('fs'),assert=require('node:assert/strict');
const stop=JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(stop.success,false,'stop must not claim success while start owns the lock');
assert.equal(stop.reason,'support_busy');
assert.ok(fs.existsSync(process.argv[3]+'/session.json'),'busy stop must preserve the deadline');
NODE
touch "$WORK/release"
wait "$START"
run stop >/dev/null
printf 'PASS: stop cannot remove the deadline during start\n'

# Expiry must kill the daemon even when login holds the session lock.
export PAUSE_AT=up
begin
node - "$PROKOP_SUPPORT_DIR/session.json" <<'NODE'
const fs=require('fs');const p=process.argv[2],s=JSON.parse(fs.readFileSync(p));s.expires_uptime=0;fs.writeFileSync(p,JSON.stringify(s));
NODE
IFS= read -r DAEMON_PID <"$PROKOP_SUPPORT_DIR/daemon.pid"
run expire 0 >"$WORK/expire.json" & EXPIRE=$!; PIDS+=("$EXPIRE")
for ((i=0;i<250;i++)); do [ -e "/proc/$DAEMON_PID/exe" ] || break; sleep 0.02; done
[ ! -e "/proc/$DAEMON_PID/exe" ] || { printf 'FAIL: expiry waited on blocked login before killing daemon\n' >&2; exit 1; }
[ -e "$PROKOP_SUPPORT_DIR/session.json" ] || { printf 'FAIL: expiry mutated shared session files without the lock\n' >&2; exit 1; }
touch "$WORK/release"
wait "$START" && { printf 'FAIL: start accepted an expired session\n' >&2; exit 1; }
wait "$EXPIRE"
[ ! -e "$PROKOP_SUPPORT_DIR/session.json" ]
printf 'PASS: expiry enforces deadline while start is blocked; start fails closed\n'

export PAUSE_AT=nft
begin
IFS= read -r WATCHDOG <"$PROKOP_SUPPORT_DIR/expiry.pid"
owned_kill KILL "$WATCHDOG"
for ((i=0;i<250;i++)); do [ -e "/proc/$WATCHDOG/exe" ] || break; sleep 0.02; done
touch "$WORK/release"
if wait "$START"; then printf 'FAIL: start accepted a dead watchdog\n' >&2; exit 1; fi
[ ! -e "$PROKOP_SUPPORT_DIR/daemon.pid" ]
[ ! -e "$PROKOP_SUPPORT_DIR/session.json" ]
printf 'PASS: start requires a live identity-checked watchdog\n'

# Reusing the same uptime deadline must not give an old watchdog authority.
printf '%s\n' '{"expires_uptime":0,"token":"replacement","port":22}' >"$PROKOP_SUPPORT_DIR/session.json"
run expire 0 old-session
[ -e "$PROKOP_SUPPORT_DIR/session.json" ] || { printf 'FAIL: stale watchdog removed a replacement session\n' >&2; exit 1; }
run expire 0 replacement
[ ! -e "$PROKOP_SUPPORT_DIR/session.json" ]
printf 'PASS: stale watchdog cannot clean up a replacement at the same deadline\n'

export PAUSE_AT=up
begin
IFS= read -r DAEMON_PID <"$PROKOP_SUPPORT_DIR/daemon.pid"
owned_kill KILL "$DAEMON_PID"
for ((i=0;i<250;i++)); do [ -e "/proc/$DAEMON_PID/exe" ] || break; sleep 0.02; done
touch "$WORK/release"
if wait "$START"; then printf 'FAIL: start reported success after daemon died during login\n' >&2; exit 1; fi
[ ! -e "$PROKOP_SUPPORT_DIR/session.json" ]
printf 'PASS: start reads back daemon identity after login\n'
