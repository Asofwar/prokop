#!/bin/sh
set -eu
# The read-only section view names a DPI rule's strategy (provider, known
# strategy id or "default", custom flag) without ever returning the raw
# nfqws_opt / nfqws2_opt / byedpi_cmd_opts text.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

cat >"$WORK_DIR/prokop" <<'CONF'
config settings 'settings'
config section 'youtube'
config section 'spaces'
config section 'plain'
config section 'custom'
config section 'z2'
config section 'bye'
config section 'vpn'
CONF
cat >"$WORK_DIR/state" <<'STATE'
prokop.settings=settings
prokop.youtube=section
prokop.youtube.action=zapret
prokop.youtube.nfqws_opt=--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld
prokop.spaces=section
prokop.spaces.action=zapret
prokop.spaces.nfqws_opt=  --filter-tcp=443   --dpi-desync=multidisorder --dpi-desync-split-pos=1,midsld  
prokop.plain=section
prokop.plain.action=zapret
prokop.custom=section
prokop.custom.action=zapret
prokop.custom.nfqws_opt=--filter-tcp=443 --dpi-desync=fake --hostlist=/etc/private-secret-list.txt
prokop.z2=section
prokop.z2.action=zapret2
prokop.z2.nfqws2_opt=--lua-desync=private-z2-secret
prokop.bye=section
prokop.bye.action=byedpi
prokop.vpn=section
prokop.vpn.action=vpn
STATE

PROKOP_CONFIG="$WORK_DIR/prokop" PROKOP_UCI_STATE_FILE="$WORK_DIR/state" \
  ucode -L "$LIB" "$LIB/diagnostics/runtime.uc" get-readonly-config-sections >"$WORK_DIR/sections.json"

node - "$WORK_DIR/sections.json" <<'NODE'
const assert = require('node:assert/strict');
const text = require('node:fs').readFileSync(process.argv[2], 'utf8');
const byName = Object.fromEntries(JSON.parse(text).map((s) => [s['.name'], s]));
const view = (name) => [byName[name].dpi_provider, byName[name].dpi_strategy, byName[name].dpi_strategy_custom];
assert.deepEqual(view('youtube'), ['zapret', 'multisplit', false]);
assert.deepEqual(view('spaces'), ['zapret', 'multidisorder', false]);
assert.deepEqual(view('plain'), ['zapret', 'default', false]);
assert.deepEqual(view('custom'), ['zapret', '', true]);
assert.deepEqual(view('z2'), ['zapret2', '', true]);
assert.deepEqual(view('bye'), ['byedpi', 'default', false]);
assert.equal(byName.vpn.dpi_provider, undefined, 'non-DPI rules carry no strategy view');
assert.doesNotMatch(text, /nfqws|byedpi_cmd_opts|dpi-desync|lua-desync|secret/,
  'raw strategy text must stay admin-only');
NODE

echo "read-only DPI strategy checks passed"
