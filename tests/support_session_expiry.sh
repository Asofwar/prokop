#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
FOREIGN=""
export PROKOP_LIB="$LIB" PROKOP_SUPPORT_DIR="$WORK/support"
export PROKOP_TAILSCALED="$WORK/tailscaled" PROKOP_TAILSCALE="$WORK/bin/tailscale"
# shellcheck source=tests/helpers/owned_processes.sh
source "$ROOT/tests/helpers/owned_processes.sh"
cleanup() {
  ucode -L "$LIB" "$LIB/experiments/support.uc" stop >/dev/null 2>&1 || true
  if [ -n "$FOREIGN" ]; then owned_kill TERM "$FOREIGN" || true; wait "$FOREIGN" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
if ! command -v cc >/dev/null; then printf 'SKIP: support process ownership test requires cc\n'; exit 0; fi
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
case "$*" in *'list chain'*) printf '{"nftables":[]}\n' ;; esac
exit 0
NFT
cat >"$PROKOP_TAILSCALE" <<'TS'
#!/bin/sh
shift
case "$1" in
status) printf '{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.7"]}}\n' ;;
up)
  [ -f "$PROKOP_SUPPORT_DIR/authkey" ] || exit 1
  [ "$(cat "$PROKOP_SUPPORT_DIR/authkey")" = tskey-auth-fixture-0123456789 ] || exit 1
  case "$*" in *"--auth-key=file:$PROKOP_SUPPORT_DIR/authkey"*) exit 0 ;; *) exit 1 ;; esac
  ;;
serve) case "$*" in *'--tcp=22 tcp://127.0.0.1:22'*) exit 0 ;; *) exit 1 ;; esac ;;
*) exit 1 ;;
esac
TS
chmod +x "$WORK/bin/nft" "$PROKOP_TAILSCALE"
export PATH="$WORK/bin:$PATH"
"$PROKOP_TAILSCALED" "--socket=$WORK/foreign.sock" &
FOREIGN=$!
ucode -L "$LIB" "$LIB/experiments/support.uc" prepare >"$WORK/prepared.json"
printf '%s\n' tskey-auth-fixture-0123456789 >"$PROKOP_SUPPORT_DIR/authkey"
ucode -L "$LIB" "$LIB/experiments/support.uc" start 22 >"$WORK/started.json"
node - "$WORK/started.json" "$PROKOP_SUPPORT_DIR" <<'NODE'
const fs=require('fs'),assert=require('node:assert/strict');const data=JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(data.active,true);assert.ok(data.remaining_seconds<=1800 && data.remaining_seconds>=1760);
assert.equal(data.port,22);assert.equal(fs.existsSync(process.argv[3]+'/authkey'),false,'auth key must be consumed');
assert.equal(fs.statSync(process.argv[3]).mode&0o777,0o700);
assert.equal(fs.statSync(process.argv[3]+'/session.json').mode&0o777,0o600);
assert.equal(JSON.stringify(data).includes('fixture-0123456789'),false,'status must not expose key');
// Simulate the deadline being reached, without waiting 30 minutes.
const session=JSON.parse(fs.readFileSync(process.argv[3]+'/session.json'));session.expires_uptime=0;fs.writeFileSync(process.argv[3]+'/session.json',JSON.stringify(session));
NODE
ucode -L "$LIB" "$LIB/experiments/support.uc" expire 0
ucode -L "$LIB" "$LIB/experiments/support.uc" status >"$WORK/stopped.json"
node - "$WORK/stopped.json" <<'NODE'
const fs=require('fs'),assert=require('node:assert/strict'); assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).active,false);
NODE
kill -0 "$FOREIGN" || { printf 'Expiry killed an unrelated daemon\n' >&2; exit 1; }
[ ! -e "$PROKOP_SUPPORT_DIR/daemon.pid" ] && [ ! -e "$PROKOP_SUPPORT_DIR/session.json" ] && [ ! -e "$PROKOP_SUPPORT_DIR/authkey" ]
printf 'support expiry consumes key and stops only the owned daemon\n'
