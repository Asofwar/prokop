#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export PROKOP_LIB="$LIB" WORK
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_PROFILES_DIR="$WORK/profiles"
export PROKOP_SMART_DETECT_DIR="$WORK/detect"
export PROKOP_SUPPORT_DIR="$WORK/support"
export PROKOP_SIDECAR_DIR="$WORK/providers"
mkdir -p "$PROKOP_RUNTIME_STATE_DIR" "$PROKOP_PROFILES_DIR" "$WORK/bin"
cat >"$WORK/contracts.uc" <<'UC'
let fs = require("fs");
let c = require("experiments.common");
let alice = require("config.alice");
let providers = require("experiments.sidecar_config");
let dns = require("singbox.dns");
function check(ok, message) { if (!ok) { warn(message, "\n"); exit(1); } }
let active = { ".name": "settings", dns_type: "doq", dns_server: [ "dns.adguard-dns.com" ], bootstrap_dns_server: [ "77.88.8.8" ] };
let quic = filter(dns.config(active, {}).servers, (server) => server.type == "quic")[0];
check(quic.type == "quic" && quic.server_port == 853 && quic.server == "dns.adguard-dns.com", "DoQ hostname must produce QUIC with bootstrap");
check(dns.server_from_options("custom", "doq", "dns.example.com:8853", "").server_port == 8853, "DoQ custom port lost");
let disabled = alice.config({});
check(!disabled.enabled, "Device bypass enabled by default");
check(alice.interface_matches("wg*", "wg12") && !alice.interface_matches("wg*", "br-lan"), "Interface wildcard must stay prefix scoped");
let key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
let data = providers.plan([
    { ".name": "native", enabled: "1", kind: "xray", port: "1083", connection_secret: '{"protocol":"vless","settings":{"vnext":[{"address":"server.example","port":443,"users":[{"id":"example-id"}]}]}}' },
    { ".name": "turn", enabled: "1", kind: "wdtt", port: "1084", connection_secret: "qwdtt://config?peer=example.com:56000&hashes=abc,def&pass=testpass" },
    { ".name": "rtc", enabled: "1", kind: "olcrtc", port: "1085", connection_secret: "olcrtc://jitsi?datachannel@https://meet.example.org/room#" + key }
]);
check(data.success && length(data.providers) == 3, "Valid provider plans rejected");
check(data.providers[0].config.inbounds[0].listen == "127.0.0.1" && data.providers[0].config.inbounds[0].port == 1083, "Xray listener exposed to LAN");
check(data.providers[0].config.outbounds[0].streamSettings.sockopt.mark == null, "Unprivileged Xray must not require SO_MARK capability");
check(data.providers[1].config.mode == "socks" && data.providers[1].config.password == "testpass", "WDTT must stay in SOCKS mode");
check(data.providers[2].config.socks.host == "127.0.0.1" && data.providers[2].config.crypto.key == key, "OlcRTC key or loopback listener lost");
check(!providers.plan([{ ".name":"bad", enabled:"1", kind:"xray",port:"1604",connection_secret:'{"protocol":"socks"}' }]).success, "Internal DNS port collision accepted");
let duplicate = json(sprintf("%J", data));
let rows = [{ ".name":"one", enabled:"1", kind:"xray",port:"1083",connection_secret:'{"protocol":"socks"}' },{ ".name":"two", enabled:"1", kind:"xray",port:"1083",connection_secret:'{"protocol":"socks"}' }];
check(!providers.plan(rows).success, "Duplicate provider ports accepted");
check(!providers.plan([{ ".name":"bad",enabled:"1",kind:"olcrtc",port:"1085",connection_secret:"olcrtc://jitsi?datachannel@room#bad" }]).success, "Malformed RTC encryption key accepted");
print("provider and DNS contracts passed\n");
UC
ucode -L "$LIB" "$WORK/contracts.uc" >"$WORK/contracts.out" 2>"$WORK/contracts.err" || { cat "$WORK/contracts.err" >&2; exit 1; }
grep -q '^provider and DNS contracts passed' "$WORK/contracts.out" || { cat "$WORK/contracts.err" >&2; exit 1; }
cat >"$WORK/probe-source.json" <<'JSON'
{"outbounds":[{"type":"selector","tag":"main-out","outbounds":["node"]},{"type":"socks","tag":"node","server":"example.com","server_port":1080,"domain_resolver":"production-dns"},{"type":"direct","tag":"direct-out"},{"type":"socks","tag":"unrelated","server":"unrelated.example","server_port":1080}]}
JSON
ucode -L "$LIB" "$LIB/experiments/smart_detect.uc" fixture-config "$WORK/probe-source.json" main-out >"$WORK/probe.json"
for codes in '28 0 candidate' '0 0 direct_works' '6 0 dns_failed' '60 0 inconclusive' '28 7 proxy_failed'; do
  read -r direct proxy verdict <<<"$codes"
  ucode -L "$LIB" "$LIB/experiments/smart_detect.uc" fixture example.com "$direct" "$proxy" >"$WORK/verdict.json"
  node - "$WORK/verdict.json" "$verdict" <<'NODE'
const assert = require('node:assert/strict');
const data = JSON.parse(require('fs').readFileSync(process.argv[2]));
assert.equal(data.valid, true); assert.equal(data.verdict, process.argv[3]);
NODE
done
ucode -L "$LIB" "$LIB/experiments/smart_detect.uc" fixture router.lan 28 0 >"$WORK/invalid.json"
node - "$WORK/probe.json" "$WORK/invalid.json" <<'NODE'
const assert = require('node:assert/strict'); const fs = require('fs');
const probe = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(probe.outbounds.some(x => x.tag === 'unrelated'), false);
assert.equal(probe.outbounds.find(x => x.tag === 'node').domain_resolver, 'probe-dns');
assert.equal(probe.route.default_mark, 0x08000000);
assert.deepEqual(probe.inbounds.map(x => x.listen), ['127.0.0.1','127.0.0.1']);
assert.equal(JSON.parse(fs.readFileSync(process.argv[3])).valid, false);
NODE
# Stale/missing snapshots and invalid profile names refuse before restore.
ucode -L "$LIB" "$LIB/experiments/profiles.uc" list >"$WORK/list.json"
if ucode -L "$LIB" "$LIB/experiments/profiles.uc" activate Missing >"$WORK/missing.json"; then exit 1; fi
node - "$WORK/list.json" "$WORK/missing.json" <<'NODE'
const fs = require('fs'); const assert = require('node:assert/strict');
assert.deepEqual(JSON.parse(fs.readFileSync(process.argv[2])).profiles, []);
assert.equal(JSON.parse(fs.readFileSync(process.argv[3])).reason, 'profile_not_found');
NODE
# A named profile must point to a private manual snapshot; unlinking its
# name must keep the snapshot available for recovery.
export PROKOP_CONFIG_FILE="$WORK/prokop" PROKOP_SNAPSHOT_DIR="$WORK/snapshots"
export PROKOP_SNAPSHOT_HASH_DIR="$WORK/hash" PROKOP_SNAPSHOT_LOCK_DIR="$WORK/run/snapshot.lock"
export PROKOP_UCI_SAVEDIR="$WORK/uci-save" PROKOP_HISTORY_FILE="$WORK/history.jsonl"
cat >"$PROKOP_CONFIG_FILE" <<'UCI'
config settings 'settings'
 option dns_server '1.1.1.1'
 option password 'private-fixture'
UCI
ucode -L "$LIB" "$LIB/experiments/profiles.uc" save Office >"$WORK/saved.json"
ucode -L "$LIB" "$LIB/experiments/profiles.uc" list >"$WORK/named.json"
ucode -L "$LIB" "$LIB/experiments/profiles.uc" remove Office >"$WORK/removed.json"
node - "$WORK/saved.json" "$WORK/named.json" "$PROKOP_SNAPSHOT_DIR" <<'NODE'
const fs=require('fs'),assert=require('node:assert/strict'); const saved=JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(saved.success,true);assert.deepEqual(JSON.parse(fs.readFileSync(process.argv[3])).profiles,[{name:'Office',snapshot:saved.snapshot}]);
assert.equal(fs.statSync(process.argv[4]+'/'+saved.snapshot+'.json').mode&0o777,0o600);
NODE
# An absent optional Tailscale installation must not start a session or persist a key.
export PROKOP_TAILSCALED="$WORK/missing-daemon" PROKOP_TAILSCALE="$WORK/missing-client"
if ucode -L "$LIB" "$LIB/experiments/support.uc" prepare >"$WORK/support.json"; then exit 1; fi
node - "$WORK/support.json" <<'NODE'
const fs = require('fs'); const assert = require('node:assert/strict');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).reason, 'install_tailscale_first');
NODE
[ ! -e "$WORK/support/authkey" ]
# Installing the optional init script with no providers configured must be
# inert even when ss, native binaries and a provider account are absent.
ucode -L "$LIB" "$LIB/experiments/sidecars.uc" prepare >"$WORK/empty-providers.json"
node - "$WORK/empty-providers.json" <<'NODE'
const assert = require('node:assert/strict'); const fs = require('fs');
assert.deepEqual(JSON.parse(fs.readFileSync(process.argv[2])), {success:true,providers:[]});
NODE
[ ! -e "$PROKOP_SIDECAR_DIR" ]
printf 'fork experiments contracts passed\n'
