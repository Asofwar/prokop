#!/usr/bin/env bash
# Per-device traffic accounting (diagnostics/traffic.uc, Monitoring >
# Devices).
#
# With an nft stub: the table follows Prokop's own table and the setting
# (sync builds it only while ProkopTable exists and device_traffic is not
# "0", keeps it and its counters when nothing changed, rebuilds it when the
# interfaces changed or it is gone, removes it otherwise), the read-only
# reader reports why there are no counters, merges the sent and received
# counters of an address, leaves out what is not a device (broadcast,
# multicast, loopback), and tells when fw4 flow offloading hides traffic.
#
# With the real nft, in a private user+net namespace (skipped when one cannot
# be created): the batch loads, a second sync keeps it, and traffic sent
# through the counted interface shows up in the reader's output.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
TRAFFIC_UC="$LIB/diagnostics/traffic.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "${NFT_LOG:-/nonexistent}" ] || sed 's/^/  nft: /' "$NFT_LOG" >&2
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }
traffic() { ucode -L "$LIB" "$TRAFFIC_UC" "$@"; }
field() { node -e 'const v=JSON.parse(require("fs").readFileSync(0,"utf8"));const r=new Function("v","return "+process.argv[1])(v);process.stdout.write(typeof r==="string"?r:JSON.stringify(r))' "$1"; }

if [ "${1:-}" = "--in-namespace" ]; then
  # Never touch the caller's ruleset: only a user namespace that maps
  # nothing but root, as `unshare --map-root-user` creates it.
  mapfile -t uid_map </proc/self/uid_map
  read -r map_inside _ map_count <<<"${uid_map[0]:-}"
  if [ "${#uid_map[@]}" != 1 ] || [ "$map_inside" != 0 ] || [ "$map_count" != 1 ]; then
    fail "--in-namespace is only for the private namespace this test creates"
  fi
  [ -z "$(nft list ruleset)" ] || fail 'the namespace does not start with an empty ruleset'
  WORK="$(mktemp -d)"
  trap 'rm -rf "${WORK:?}"' EXIT
  mkdir -p "$WORK/bin" "$WORK/tmp"
  printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
  chmod 0755 "$WORK/bin/logger"
  export PATH="$WORK/bin:$PATH" TMPDIR="$WORK/tmp"
  export PROKOP_UCI_STATE_FILE="$WORK/uci" PROKOP_RUNTIME_STATE_DIR="$WORK/run"
  printf 'prokop.settings.source_network_interfaces=lo\n' >"$PROKOP_UCI_STATE_FILE"

  nft add table inet ProkopTable
  traffic sync || fail 'real nft: sync failed'
  nft list table inet ProkopTraffic >/dev/null || fail 'real nft: the table was not created'
  since="$(field v.since <"$WORK/run/traffic.json")"
  # lo gets a host address the reader counts (127/8 is not a device), and
  # one datagram goes out and comes back in through it.
  python3 - <<'PY' || fail 'real nft: could not send test traffic'
import fcntl, socket, struct
s = socket.socket()
fcntl.ioctl(s, 0x8914, struct.pack('16sH', b'lo', 0x1 | 0x40))  # SIOCSIFFLAGS: up, running
addr = struct.pack('16sH2s4s8s', b'lo', socket.AF_INET, b'\0\0', socket.inet_aton('10.200.0.1'), b'\0' * 8)
fcntl.ioctl(s, 0x8916, addr)  # SIOCSIFADDR
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u.bind(('10.200.0.1', 0))
for _ in range(3):
    u.sendto(b'x' * 1000, ('10.200.0.1', 9))
PY
  out="$(traffic get)"
  [ "$(field v.state <<<"$out")" = ok ] || fail "real nft: state is not ok: $out"
  [ "$(field 'v.devices.filter(d=>d.address==="10.200.0.1").length' <<<"$out")" = 1 ] ||
    fail "real nft: 10.200.0.1 was not counted: $out"
  [ "$(field 'v.devices[0].tx_packets>=3&&v.devices[0].rx_packets>=3&&v.devices[0].tx_bytes>=3000' <<<"$out")" = true ] ||
    fail "real nft: the counters do not hold the test traffic: $out"
  [ "$(field 'v.devices.some(d=>d.address.startsWith("127."))' <<<"$out")" = false ] ||
    fail "real nft: a loopback address was reported as a device: $out"
  ok 'real nft: traffic through the counted interface is reported per address'

  before="$(field 'v.devices[0].tx_packets' <<<"$out")"
  traffic sync || fail 'real nft: second sync failed'
  out="$(traffic get)"
  [ "$(field 'v.devices[0].tx_packets' <<<"$out")" = "$before" ] || fail "real nft: a second sync reset the counters: $out"
  [ "$(field v.since <<<"$out")" = "$since" ] || fail 'real nft: a second sync changed the start time'
  ok 'real nft: a sync without changes keeps the table and its counters'

  nft delete table inet ProkopTable
  traffic sync || fail 'real nft: sync after the stop failed'
  ! nft list table inet ProkopTraffic >/dev/null 2>&1 || fail 'real nft: the table outlived ProkopTable'
  ok 'real nft: no counting without ProkopTable'
  exit 0
fi

# ---- nft stub ---------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
mkdir -p "$WORK/bin" "$WORK/tmp" "$WORK/nft"
export NFT_LOG="$WORK/nft.log" NFT_DIR="$WORK/nft" PATH="$WORK/bin:$PATH" TMPDIR="$WORK/tmp"
export PROKOP_UCI_STATE_FILE="$WORK/uci" PROKOP_RUNTIME_STATE_DIR="$WORK/run"

# Tables are files in $NFT_DIR. A batch file creates ProkopTraffic and is
# kept as its listing; -j listings come from fixture files.
cat >"$WORK/bin/nft" <<'SH'
#!/bin/sh
printf 'call:%s\n' "$*" >>"$NFT_LOG"
case "$1 $2" in
  "-f "*)
    [ -z "${NFT_FAIL_F:-}" ] || exit 1
    cp "$2" "$NFT_DIR/ProkopTraffic"
    ;;
  "list table") [ -e "$NFT_DIR/$4" ] ;;
  "delete table") rm -f "$NFT_DIR/$4" ;;
  "-j list")
    case "$3" in
      flowtables) [ -e "$NFT_DIR/flowtables.json" ] && cat "$NFT_DIR/flowtables.json" || echo '{"nftables":[{"metainfo":{}}]}' ;;
      table) [ -e "$NFT_DIR/$5" ] || exit 1; cat "$NFT_DIR/counters.json" ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$NFT_LOG.logger"\n' >"$WORK/bin/logger"
chmod 0755 "$WORK/bin/nft" "$WORK/bin/logger"

uci_settings() { printf '%s\n' "$@" >"$PROKOP_UCI_STATE_FILE"; }
uci_settings 'prokop.settings.source_network_interfaces=br-lan wg0'

# Prokop not running: nothing is set up, the reader says why.
traffic sync || fail 'sync without ProkopTable failed'
[ ! -e "$NFT_DIR/ProkopTraffic" ] || fail 'the table was created while Prokop does not run'
[ "$(traffic get | field v.state)" = stopped ] || fail 'a stopped Prokop is not reported as stopped'
ok 'no table and state "stopped" while ProkopTable is absent'

# Running: one transaction, counting on both interfaces in both directions.
touch "$NFT_DIR/ProkopTable"
traffic sync || fail 'sync failed'
batch="$NFT_DIR/ProkopTraffic"
[ -e "$batch" ] || fail 'the table was not created'
head -3 "$batch" | tr '\n' '|' | grep -qx 'add table inet ProkopTraffic|delete table inet ProkopTraffic|add table inet ProkopTraffic|' ||
  fail 'the batch does not replace the table in one transaction'
for rule in 'ingress iifname "br-lan" update @tx4 { ip saddr }' 'ingress iifname "wg0" update @tx6 { ip6 saddr }' \
  'egress oifname "br-lan" update @rx4 { ip daddr }' 'egress oifname "wg0" update @rx6 { ip6 daddr }'; do
  grep -qF "add rule inet ProkopTraffic $rule" "$batch" || fail "missing rule: $rule"
done
# Counting only: no verdict, mark, queue or NAT anywhere in the table.
! grep -Eq '\b(drop|reject|accept|mark|queue|tproxy|dnat|snat|masquerade|jump|goto)\b' <(grep '^add rule' "$batch") ||
  fail 'the accounting table does more than count'
grep -q 'policy accept' "$batch" || fail 'the chains do not accept by policy'
since="$(field v.since <"$PROKOP_RUNTIME_STATE_DIR/traffic.json")"
[ -n "$since" ] && [ "$since" -gt 0 ] || fail 'the start time was not recorded'
ok 'sync builds a counting-only table in one transaction and records when it started'

: >"$NFT_LOG"
traffic sync || fail 'second sync failed'
! grep -q '^call:-f' "$NFT_LOG" || fail 'an unchanged configuration rebuilt the table (counters lost)'
ok 'an unchanged configuration keeps the table'

rm -f "$NFT_DIR/ProkopTraffic"
traffic sync || fail 'sync after a flush failed'
[ -e "$NFT_DIR/ProkopTraffic" ] || fail 'a table that fw4 flushed was not rebuilt'
ok 'a missing table is rebuilt'

uci_settings 'prokop.settings.source_network_interfaces=br-lan'
: >"$NFT_LOG"
traffic sync || fail 'sync after an interface change failed'
grep -q '^call:-f' "$NFT_LOG" || fail 'changed interfaces did not rebuild the table'
! grep -q 'wg0' "$NFT_DIR/ProkopTraffic" || fail 'a removed interface is still counted'
ok 'changed interfaces rebuild the table'

uci_settings 'prokop.settings.source_network_interfaces=br-lan "; flush ruleset'
rules="$(traffic batch | grep '^add rule')"
grep -q '"br-lan"' <<<"$rules" || fail 'a valid interface was dropped with an invalid one'
! grep -q '";' <<<"$rules" || fail 'an interface name with nft syntax was rendered'
! grep -Ev '^add rule inet ProkopTraffic (ingress iifname|egress oifname) "[A-Za-z0-9_.@-]+[*]?" update @(tx|rx)[46] \{ ip6? [sd]addr \}$' <<<"$rules" ||
  fail 'a rule outside the expected shape was rendered'
ok 'interface names nft could misread are left out'

# The reader: tx and rx of an address merged, non-devices left out.
uci_settings 'prokop.settings.source_network_interfaces=br-lan'
cat >"$NFT_DIR/counters.json" <<'JSON'
{"nftables":[{"metainfo":{}},{"table":{"family":"inet","name":"ProkopTraffic"}},
{"set":{"family":"inet","name":"tx4","table":"ProkopTraffic","elem":[
  {"elem":{"val":"192.168.1.10","expires":600,"counter":{"packets":10,"bytes":1000}}},
  {"elem":{"val":"0.0.0.0","counter":{"packets":1,"bytes":328}}},
  {"elem":{"val":"192.168.1.20","counter":{"packets":2,"bytes":200}}}]}},
{"set":{"family":"inet","name":"rx4","table":"ProkopTraffic","elem":[
  {"elem":{"val":"192.168.1.10","counter":{"packets":30,"bytes":45000}}},
  {"elem":{"val":"255.255.255.255","counter":{"packets":5,"bytes":500}}},
  {"elem":{"val":"224.0.0.251","counter":{"packets":5,"bytes":500}}}]}},
{"set":{"family":"inet","name":"tx6","table":"ProkopTraffic","elem":[
  {"elem":{"val":"fd00::10","counter":{"packets":3,"bytes":300}}}]}},
{"set":{"family":"inet","name":"rx6","table":"ProkopTraffic","elem":[
  {"elem":{"val":"ff02::1","counter":{"packets":9,"bytes":900}}},
  {"elem":{"val":"fd00::10","counter":{"packets":4,"bytes":4000}}}]}},
{"set":{"family":"inet","name":"tx4","table":"OtherTable","elem":[
  {"elem":{"val":"10.0.0.1","counter":{"packets":1,"bytes":1}}}]}}]}
JSON
out="$(traffic get)"
[ "$(field v.state <<<"$out")" = ok ] || fail "state is not ok: $out"
[ "$(field 'v.devices.map(d=>d.address).sort().join(",")' <<<"$out")" = '192.168.1.10,192.168.1.20,fd00::10' ] ||
  fail "unexpected addresses: $out"
[ "$(field 'JSON.stringify(v.devices.find(d=>d.address==="192.168.1.10"))' <<<"$out")" = \
  '{"address":"192.168.1.10","family":4,"tx_bytes":1000,"tx_packets":10,"rx_bytes":45000,"rx_packets":30}' ] ||
  fail "sent and received counters were not merged: $out"
[ "$(field 'v.devices.find(d=>d.address==="fd00::10").family' <<<"$out")" = 6 ] || fail "IPv6 family lost: $out"
[ "$(field v.since <<<"$out")" -gt 0 ] || fail "the start time is not reported: $out"
[ "$(field v.offload <<<"$out")" = none ] || fail "no flowtable must read as no offload: $out"
ok 'the reader merges the counters of an address and leaves out what is not a device'

printf '{"nftables":[{"metainfo":{}},{"flowtable":{"family":"inet","table":"fw4","name":"ft","hook":"ingress"}}]}' \
  >"$NFT_DIR/flowtables.json"
[ "$(traffic get | field v.offload)" = software ] || fail 'software flow offloading is not reported'
printf '{"nftables":[{"metainfo":{}},{"flowtable":{"family":"inet","table":"fw4","name":"ft","flags":["offload"]}}]}' \
  >"$NFT_DIR/flowtables.json"
[ "$(traffic get | field v.offload)" = hardware ] || fail 'hardware flow offloading is not reported'
rm -f "$NFT_DIR/flowtables.json"
ok 'flow offloading, which hides traffic from the counters, is reported'

# Off in the settings: removed, and the reader says it is off.
uci_settings 'prokop.settings.source_network_interfaces=br-lan' 'prokop.settings.device_traffic=0'
traffic sync || fail 'sync with the setting off failed'
[ ! -e "$NFT_DIR/ProkopTraffic" ] || fail 'the table stayed with the setting off'
[ ! -e "$PROKOP_RUNTIME_STATE_DIR/traffic.json" ] || fail 'the start time stayed with the setting off'
[ "$(traffic get | field v.state)" = disabled ] || fail 'the setting off is not reported as disabled'
ok 'device_traffic=0 removes the table'

# A batch nft refuses leaves nothing half set up and is logged.
uci_settings 'prokop.settings.source_network_interfaces=br-lan'
NFT_FAIL_F=1 traffic sync && fail 'a refused batch reported success'
[ ! -e "$NFT_DIR/ProkopTraffic" ] || fail 'a refused batch left a table'
grep -q 'Device traffic accounting could not be set up' "$NFT_LOG.logger" || fail 'a refused batch was not logged'
traffic sync || fail 'sync after a refused batch failed'
traffic remove
[ ! -e "$NFT_DIR/ProkopTraffic" ] || fail 'remove left the table'
ok 'a refused batch leaves nothing behind; remove deletes the table'

# ---- real nft ---------------------------------------------------------------

NAMESPACE=(unshare --user --map-root-user --net --mount)
PATH="${PATH#"$WORK/bin:"}"
if ! command -v nft >/dev/null 2>&1 || ! command -v unshare >/dev/null 2>&1 ||
  ! "${NAMESPACE[@]}" nft list ruleset >/dev/null 2>&1; then
  printf 'SKIP: real nft part: no private user+net namespace with nftables here\n'
  exit 0
fi
"${NAMESPACE[@]}" bash "$0" --in-namespace
