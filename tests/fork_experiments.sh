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
mkdir -p "$PROKOP_RUNTIME_STATE_DIR" "$PROKOP_PROFILES_DIR" "$WORK/bin"
cat >"$WORK/contracts.uc" <<'UC'
let fs = require("fs");
let c = require("experiments.common");
let alice = require("config.alice");
let dns = require("singbox.dns");
function check(ok, message) { if (!ok) { warn(message, "\n"); exit(1); } }
let active = { ".name": "settings", dns_type: "doq", dns_server: [ "dns.adguard-dns.com" ], bootstrap_dns_server: [ "77.88.8.8" ] };
let quic = filter(dns.config(active, {}).servers, (server) => server.type == "quic")[0];
check(quic.type == "quic" && quic.server_port == 853 && quic.server == "dns.adguard-dns.com", "DoQ hostname must produce QUIC with bootstrap");
check(dns.server_from_options("custom", "doq", "dns.example.com:8853", "").server_port == 8853, "DoQ custom port lost");
let disabled = alice.config({});
check(!disabled.enabled, "Device bypass enabled by default");
check(alice.interface_matches("wg*", "wg12") && !alice.interface_matches("wg*", "br-lan"), "Interface wildcard must stay prefix scoped");
print("DNS and device contracts passed\n");
UC
ucode -L "$LIB" "$WORK/contracts.uc" >"$WORK/contracts.out" 2>"$WORK/contracts.err" || { cat "$WORK/contracts.err" >&2; exit 1; }
grep -q '^DNS and device contracts passed' "$WORK/contracts.out" || { cat "$WORK/contracts.err" >&2; exit 1; }
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
assert.deepEqual(probe.dns.servers, [{type:'udp',tag:'probe-dns',server:'77.88.8.8',server_port:53}]);
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
# Smart Detect reads the probe ports from /proc/net/tcp{,6}: no `ss` needed,
# a TIME_WAIT leftover is no listener, and readiness needs both listeners on
# 127.0.0.1 owned by the probe process itself.
PROC="$WORK/proc"
mkdir -p "$PROC/net" "$PROC/4242/fd"
ln -s 'socket:[111]' "$PROC/4242/fd/3"; ln -s 'socket:[112]' "$PROC/4242/fd/4"; ln -s /dev/null "$PROC/4242/fd/0"
TCP_HEAD='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
ports() { PROKOP_SMART_DETECT_PROC="$PROC" ucode -L "$LIB" "$LIB/experiments/smart_detect.uc" fixture-ports 4242 | tr -d '\n '; }
expect_ports() { local got; got="$(ports)"; [[ "$got" == "$1" ]] || { printf 'smart detect ports: want %s, got %s (%s)\n' "$1" "$got" "$2" >&2; exit 1; }; }
printf '%s\n   0: 0100007F:11EE 0100007F:A000 06 00000000:00000000 03:00000123 00000000     0        0 0 3 0000000000000000\n   1: 0100007F:0035 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 99 1 0000000000000000 100 0 0 10 0\n' "$TCP_HEAD" >"$PROC/net/tcp"
printf '%s\n' "$TCP_HEAD" >"$PROC/net/tcp6"
expect_ports '{"readable":true,"free":true,"owned":false}' 'TIME_WAIT and other listeners do not hold the probe ports'
printf '%s\n   0: 0100007F:11EE 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 111 1 0000000000000000 100 0 0 10 0\n   1: 0100007F:11EF 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 112 1 0000000000000000 100 0 0 10 0\n' "$TCP_HEAD" >"$PROC/net/tcp"
expect_ports '{"readable":true,"free":false,"owned":true}' 'both listeners belong to the probe'
printf '%s\n   0: 00000000000000000000000000000000:11EF 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 555 1 0000000000000000 100 0 0 10 0\n' "$TCP_HEAD" >"$PROC/net/tcp6"
expect_ports '{"readable":true,"free":false,"owned":false}' 'a foreign [::]:4591 listener is not the probe'
rm "$PROC/net/tcp"
expect_ports '{"readable":false,"free":false,"owned":false}' 'an unreadable socket table fails closed'
# Smart Detect's resolver: the running sing-box's bootstrap DNS, else the
# active entry of the configured list (several servers, a port).
export PROKOP_DNS_FAILOVER_STATE_FILE="$WORK/dns-failover.json"
resolver() { printf '%s' "$1" >"$WORK/rs.json"; printf '%s' "$2" >"$WORK/rset.json"; ucode -L "$LIB" "$LIB/experiments/smart_detect.uc" fixture-resolver "$WORK/rs.json" "$WORK/rset.json" | tr -d '\n '; }
expect_resolver() { local got; got="$(resolver "$1" "$2")"; [[ "$got" == "$3" ]] || { printf 'smart detect resolver: want %s, got %s (%s)\n' "$3" "$got" "$4" >&2; exit 1; }; }
expect_resolver '{"dns":{"servers":[{"type":"udp","tag":"bootstrap-dns-server","server":"1.1.1.1","server_port":53}]}}' '{"bootstrap_dns_server":["77.88.8.8","8.8.8.8"]}' '{"resolver":{"server":"1.1.1.1","server_port":53}}' 'running bootstrap DNS wins'
expect_resolver '{}' '{"bootstrap_dns_server":["77.88.8.8","8.8.8.8"]}' '{"resolver":{"server":"77.88.8.8","server_port":53}}' 'two configured servers are not one address'
expect_resolver '{}' '{"bootstrap_dns_server":"8.8.8.8:5353"}' '{"resolver":{"server":"8.8.8.8","server_port":5353}}' 'a port is kept'
expect_resolver '{}' '{}' '{"resolver":{"server":"77.88.8.8","server_port":53}}' 'default bootstrap DNS'
expect_resolver '{"dns":{"servers":[{"type":"udp","tag":"bootstrap-dns-server","server":"dns.example","server_port":53}]}}' '{}' '{"resolver":null}' 'a hostname is refused'
printf 'fork experiments contracts passed\n'
