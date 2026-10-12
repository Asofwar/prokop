#!/usr/bin/env bash
set -euo pipefail
# settings.nfqws_first_packets (opt-in): the queue rules of a zapret/zapret2
# rule take only the first packets of a connection (`ct original packets
# 1-N`, after bol-van/zapret common/nft.sh), N derived from the rule's
# strategy (providers/nfqueue/queue_limit.uc); a strategy whose needs cannot
# be bounded keeps the unlimited queue. Off: the rules are exactly those of
# the releases before. The autotune side (probe table, verification) is in
# autotune_contract.sh and autotune_apply.sh.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok %s\n' "$1"; }

# ---- the limits a strategy needs --------------------------------------------
cat >"$WORK/limits.uc" <<'UC'
let q = require("providers.nfqueue.queue_limit");
let constants = require("core.constants");
let catalog = require("autotune.catalog");
let dpi_strategy = require("core.dpi_strategy");
let failed = 0;
function expect(label, kind, strategy, tcp, udp, keepalive) {
    let got = q.limits(kind, strategy);
    let want = { tcp, udp, keepalive_tcp_ports: keepalive || [] };
    if (sprintf("%J", got) != sprintf("%J", want)) {
        warn(label, ": expected ", want, ", got ", got, "\n");
        failed++;
    }
}
// Built-in strategies: the zapret defaults (9/9, 20/5); their HTTP profile
// keeps port 80 unlimited for keep-alive requests.
expect("zapret default", "nfqws", constants.ZAPRET_DEFAULT_NFQWS_OPT, 9, 9, [ "80" ]);
expect("zapret legacy default", "nfqws", constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT, 9, 9, [ "80" ]);
expect("zapret2 default", "nfqws2", constants.ZAPRET2_DEFAULT_NFQWS2_OPT, 20, 5, [ "80" ]);
// nfqws: cutoffs in packets raise N; what cannot be bounded keeps all.
expect("no filter, HTTP may be on any port", "nfqws", "--dpi-desync=fake,split2", null, null);
expect("TLS only", "nfqws", "--filter-tcp=443 --dpi-desync=fake", 9, 9);
expect("separate value form", "nfqws", "--filter-tcp 443 --dpi-desync fake --dpi-desync-cutoff n15", 14, 9);
expect("cutoff above the base", "nfqws", "--filter-tcp=443 --dpi-desync=fake --dpi-desync-cutoff=n30", 29, 9);
expect("cutoff below the base keeps the base", "nfqws", "--filter-tcp=443 --dpi-desync=fake --dpi-desync-cutoff=n2", 9, 9);
expect("bare cutoff number is packets", "nfqws", "--filter-tcp=443 --dpi-desync=fake --dpi-desync-cutoff=12", 11, 9);
expect("any protocol without cutoff", "nfqws", "--filter-tcp=443 --dpi-desync=fake --dpi-desync-any-protocol", null, 9);
expect("any protocol with d cutoff", "nfqws", "--filter-tcp=443 --dpi-desync=fake --dpi-desync-any-protocol=1 --dpi-desync-cutoff=d4", null, 9);
expect("any protocol with n cutoff", "nfqws", "--filter-udp=50000-50100 --dpi-desync=fake --dpi-desync-any-protocol --dpi-desync-cutoff=n3", 9, 9);
expect("conntrack off: no cutoff applies", "nfqws", "--filter-tcp=443 --ctrack-disable --dpi-desync=fake --dpi-desync-any-protocol --dpi-desync-cutoff=n3", null, 9);
expect("UDP other than QUIC repeats handshakes", "nfqws", "--filter-udp=50000-50100 --dpi-desync=fake", 9, null);
expect("QUIC by L7 filter", "nfqws", "--filter-udp=443,8443 --filter-l7=quic --dpi-desync=fake", 9, 9);
expect("dup without cutoff: every packet", "nfqws", "--filter-tcp=443 --dpi-desync=fake --dup=2", null, 9);
expect("dup with cutoff", "nfqws", "--filter-tcp=443 --dpi-desync=fake --dup=2 --dup-cutoff=n12", 11, 9);
expect("orig ttl without cutoff", "nfqws", "--filter-tcp=443 --orig-ttl=5", null, 9);
expect("orig ttl with cutoff", "nfqws", "--filter-tcp=443 --orig-ttl=5 --orig-mod-cutoff=n4", 9, 9);
expect("wssize without cutoff", "nfqws", "--filter-tcp=443 --wssize=1:6", null, 9);
expect("late start", "nfqws", "--filter-tcp=443 --dpi-desync=fake --dpi-desync-start=n12", 12, 9);
expect("HTTP ports", "nfqws", "--filter-tcp=80,443,8080-8090 --dpi-desync=fake", 9, 9, [ "80", "8080-8090" ]);
expect("HTTP host modification", "nfqws", "--filter-tcp=80 --hostcase", 9, 9, [ "80" ]);
expect("TLS L7 has no keep-alive", "nfqws", "--filter-tcp=80,443 --filter-l7=tls --dpi-desync=fake", 9, 9);
expect("skipped profile", "nfqws", "--skip --dpi-desync=fake --dpi-desync-any-protocol --new --filter-tcp=443 --dpi-desync=fake", 9, 9);
expect("the worst profile decides", "nfqws", "--filter-tcp=443 --dpi-desync=fake --new --filter-tcp=5222 --dpi-desync=fake --dpi-desync-any-protocol", null, 9);
// nfqws2: payload and out-range of every --lua-desync instance.
expect("payload all by default", "nfqws2", "--filter-tcp=443 --lua-desync=fake", null, 5);
expect("out-range in packets", "nfqws2", "--filter-tcp=443 --out-range=-n30 --lua-desync=fake", 30, 5);
expect("out-range exclusive", "nfqws2", "--filter-tcp=443 --out-range=<n30 --lua-desync=fake", 29, 5);
expect("handshake before data", "nfqws2", "--filter-tcp=443 --payload=empty --out-range=s1<d1 --lua-desync=pktmod:ip_ttl=1", 20, 5);
expect("out-range in data packets", "nfqws2", "--filter-tcp=443 --out-range=-d10 --lua-desync=fake", null, 5);
expect("out-range none", "nfqws2", "--filter-tcp=443 --out-range=x --lua-desync=fake", 20, 5);
expect("unknown payload", "nfqws2", "--filter-udp=3478 --payload=stun --lua-desync=fake", 20, null);
expect("import", "nfqws2", "--filter-tcp=443 --import=t --lua-desync=fake", null, null);
expect("unknown kind", "byedpi", "--split 1", null, null);

// The autotune catalog: every DPI candidate is bounded, and splicing a
// TCP/443 candidate into the default strategy (autotune/apply.uc) keeps the
// TCP limit the isolated probe measured with.
for (let e in catalog.entries()) {
    if (e.nfqws_opt == "") continue;
    let kind = q.kind_of(e.provider || "zapret");
    let got = q.limits(kind, e.nfqws_opt);
    if (got.tcp == null || got.udp == null) { warn("catalog ", e.id, " unbounded: ", got, "\n"); failed++; }
    if (kind == "nfqws" && e.protocol == "tcp") {
        let spliced = dpi_strategy.tcp443_splice(constants.ZAPRET_DEFAULT_NFQWS_OPT, e.nfqws_opt);
        if (spliced.opt == null || q.limits(kind, spliced.opt).tcp != got.tcp) {
            warn("catalog ", e.id, ": production limit differs from the probe's\n");
            failed++;
        }
    }
}
// Rule options: the strategy option, else the provider default.
let s = q.section_limits("zapret", {});
if (s.tcp != 9 || s.udp != 9) { warn("zapret rule without option: ", s, "\n"); failed++; }
s = q.section_limits("zapret", { nfqws_opt: "--dpi-desync=fake" });
if (s.tcp != null) { warn("zapret rule with option: ", s, "\n"); failed++; }
s = q.section_limits("zapret2", {});
if (s.tcp != 20 || s.udp != 5) { warn("zapret2 rule without option: ", s, "\n"); failed++; }
if (join(" ", q.match_words(9)) != "ct original packets 1-9" || join(" ", q.match_words(1)) != "ct original packets 1") { warn("match words\n"); failed++; }
for (let v in [ "1", "true", "on", "yes" ]) if (!q.enabled_value(v)) { warn("enabled ", v, "\n"); failed++; }
for (let v in [ "0", "", null, "false", "no" ]) if (q.enabled_value(v)) { warn("disabled ", v, "\n"); failed++; }
exit(failed > 0 ? 1 : 0);
UC
ucode -L "$LIB" "$WORK/limits.uc" || fail "strategy limits"
ok "limits: built-in defaults, autotune catalog (bounded, splice keeps the probe's limit), custom strategies fail safe"

# ---- the nft rules ------------------------------------------------------------
printf '#!/bin/sh\nexit 0\n' >"$WORK/provider"
chmod 0755 "$WORK/provider"
rules() { # rules <setting> <action> <mark base> <queue base> -> batch lines
  cat >"$WORK/sections.json" <<JSON
{ "settings": { "nfqws_first_packets": "$1" },
  "section": [
    { ".name": "def", "action": "zapret" },
    { ".name": "custom", "action": "zapret", "nfqws_opt": "--dpi-desync=fake --dpi-desync-any-protocol" },
    { ".name": "tls", "action": "zapret", "nfqws_opt": "--filter-tcp=443 --dpi-desync=fake --dpi-desync-cutoff=n30" },
    { ".name": "z2", "action": "zapret2" }
  ] }
JSON
  : >"$WORK/batch.nft"
  PROKOP_NFT_BATCH_FILE="$WORK/batch.nft" ucode -L "$LIB" "$LIB/nft/apply.uc" nft-create-provider-output-rules-fixture \
    "$WORK/sections.json" ProkopTable "$2" "$WORK/provider" "$3" "$4" 0x40000000 0x20000000 || fail "rules $*"
  grep ' queue num ' "$WORK/batch.nft"
}
M='add rule inet ProkopTable mangle_output meta mark & 0xff0000ff =='
expected_off="$M 0x01000001 meta l4proto tcp counter queue num 4000 bypass
$M 0x01000001 meta l4proto udp counter queue num 4000 bypass
$M 0x01000002 meta l4proto tcp counter queue num 4001 bypass
$M 0x01000002 meta l4proto udp counter queue num 4001 bypass
$M 0x01000003 meta l4proto tcp counter queue num 4002 bypass
$M 0x01000003 meta l4proto udp counter queue num 4002 bypass"
for off in 0 ""; do
  [ "$(rules "$off" zapret 0x01000000 4000)" = "$expected_off" ] || fail "setting '$off': rules changed: $(cat "$WORK/batch.nft")"
done
ok "off (and absent): the queue rules of the releases before"

expected_on="$M 0x01000001 meta l4proto tcp ct original packets 1-9 counter queue num 4000 bypass
$M 0x01000001 tcp dport { 80 } counter queue num 4000 bypass
$M 0x01000001 meta l4proto udp ct original packets 1-9 counter queue num 4000 bypass
$M 0x01000002 meta l4proto tcp counter queue num 4001 bypass
$M 0x01000002 meta l4proto udp counter queue num 4001 bypass
$M 0x01000003 meta l4proto tcp ct original packets 1-29 counter queue num 4002 bypass
$M 0x01000003 meta l4proto udp ct original packets 1-9 counter queue num 4002 bypass"
[ "$(rules 1 zapret 0x01000000 4000)" = "$expected_on" ] || fail "zapret limited rules: $(cat "$WORK/batch.nft")"
expected_z2="$M 0x02000001 meta l4proto tcp ct original packets 1-20 counter queue num 4100 bypass
$M 0x02000001 tcp dport { 80 } counter queue num 4100 bypass
$M 0x02000001 meta l4proto udp ct original packets 1-5 counter queue num 4100 bypass"
[ "$(rules 1 zapret2 0x02000000 4100)" = "$expected_z2" ] || fail "zapret2 limited rules: $(cat "$WORK/batch.nft")"
ok "on: limited per rule from its strategy, keep-alive port after the limited TCP rule, unbounded custom strategy unlimited"

# The rules as nft parses them (a private namespace; this kernel may lack
# nft_queue, then the queue statement alone is left out).
if command -v nft >/dev/null 2>&1 && command -v unshare >/dev/null 2>&1 &&
  unshare --user --map-root-user --net nft list ruleset >/dev/null 2>&1; then
  rules 1 zapret 0x01000000 4000 >/dev/null
  { printf 'add table inet ProkopTable\nadd chain inet ProkopTable mangle_output { type route hook output priority mangle; policy accept; }\n'
    cat "$WORK/batch.nft"; } >"$WORK/check.nft"
  if ! unshare --user --map-root-user --net nft -c -f "$WORK/check.nft" 2>"$WORK/check.err"; then
    grep -q 'Could not process rule: No such file or directory' "$WORK/check.err" || fail "nft -c: $(cat "$WORK/check.err")"
    sed -E 's/ queue num [0-9]+ bypass/ accept/' "$WORK/check.nft" >"$WORK/check-noqueue.nft"
    unshare --user --map-root-user --net nft -c -f "$WORK/check-noqueue.nft" 2>"$WORK/check.err" ||
      fail "nft -c without queue: $(cat "$WORK/check.err")"
  fi
  unshare --user --map-root-user --net sh -c "nft -f '$WORK/check.nft' 2>/dev/null || nft -f '$WORK/check-noqueue.nft'; nft -j list chain inet ProkopTable mangle_output" >"$WORK/listing.json" ||
    fail "nft -f of the limited rules"
  node -e '
  const l = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).nftables.filter((x) => x.rule);
  const ct = l.filter((x) => x.rule.expr.some((e) => e.match && e.match.left.ct));
  const ranges = ct.map((x) => JSON.stringify(x.rule.expr.find((e) => e.match && e.match.left.ct).match));
  const want = [[1, 9], [1, 9], [1, 29], [1, 9]].map((r) => JSON.stringify({ op: "==", left: { ct: { key: "packets", dir: "original" } }, right: { range: r } }));
  if (JSON.stringify(ranges) !== JSON.stringify(want)) throw new Error(ranges.join("\n"));
  ' "$WORK/listing.json" || fail "the kernel listing of the limited rules"
  ok "nft -c and -f accept the limited rules; the listing shows ct original packets 1-N"
  # The kernel semantics the limit relies on: the packet being classified
  # counts (the SYN is packet 1), and loading the rule turns conntrack
  # accounting on even where net.netfilter.nf_conntrack_acct was 0.
  if command -v python3 >/dev/null 2>&1; then
    cat >"$WORK/kernel.sh" <<SH
set -e
python3 '$ROOT_DIR/tests/helpers/nft_packets.py' address lo 127.0.0.1/8
cat /proc/sys/net/netfilter/nf_conntrack_acct 2>/dev/null || echo unknown
nft add table inet t
nft add chain inet t c '{ type route hook output priority -150; policy accept; }'
nft add rule inet t c tcp dport 5555 tcp flags syn ct original packets 1 counter comment '"syn"'
nft add rule inet t c tcp dport 5555 ct original packets 1-3 counter comment '"first"'
nft add rule inet t c tcp dport 5555 counter comment '"all"'
cat /proc/sys/net/netfilter/nf_conntrack_acct 2>/dev/null || echo unknown
python3 - <<'PY'
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 5555)); s.listen(4)
for i in range(2):
    c = socket.create_connection(("127.0.0.1", 5555)); a, _ = s.accept()
    for j in range(5):
        c.send(b"x" * 10); a.recv(100); a.send(b"y"); c.recv(10)
    c.close(); a.close()
PY
nft -j list chain inet t c
SH
    unshare --user --map-root-user --net bash "$WORK/kernel.sh" >"$WORK/kernel.out" 2>"$WORK/kernel.err" ||
      fail "kernel check: $(cat "$WORK/kernel.err")"
    node -e '
    const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
    const after = lines[1];
    if (after !== "1" && after !== "unknown") throw new Error("accounting not turned on: " + lines.slice(0, 2));
    const rules = JSON.parse(lines[2]).nftables.filter((x) => x.rule);
    const n = Object.fromEntries(rules.map((x) => [x.rule.comment, x.rule.expr.find((e) => e.counter).counter.packets]));
    // Two connections from the router itself: one SYN each, three first
    // packets each, and more than three packets each in all.
    if (n.syn !== 2 || n.first !== 6 || !(n.all > 6)) throw new Error(JSON.stringify(n));
    ' "$WORK/kernel.out" || fail "kernel semantics of ct original packets: $(cat "$WORK/kernel.out")"
    ok "kernel: the SYN is packet 1, 1-3 takes three packets per connection, the rule turns conntrack accounting on"
  fi
else
  printf 'SKIP: nft check (no unprivileged nft namespace)\n'
fi

# ---- reload: a strategy change rebuilds the limited rules ---------------------
sig() { # sig <module> <mode> <setting> <nfqws_opt>
  cat >"$WORK/sig.json" <<JSON
{ "settings": { "nfqws_first_packets": "$3" }, "section": [ { ".name": "def", "action": "zapret", "nfqws_opt": "$4" } ] }
JSON
  ucode -L "$LIB" "$LIB/$1" "$2" "$WORK/sig.json"
}
for pair in nft/apply.uc:nft-runtime-signature-fixture service/state.uc:nft-signature-fixture; do
  module="${pair%%:*}" mode="${pair#*:}"
  cat >"$WORK/sig.json" <<'JSON'
{ "section": [ { ".name": "def", "action": "zapret", "nfqws_opt": "--filter-tcp=443 --dpi-desync=fake" } ] }
JSON
  absent="$(ucode -L "$LIB" "$LIB/$module" "$mode" "$WORK/sig.json")"
  [ "$(sig "$module" "$mode" 0 '--filter-tcp=443 --dpi-desync=fake')" = "$absent" ] ||
    fail "$module: the option off must keep the signature of the releases before"
  [ "$(sig "$module" "$mode" 0 '--filter-tcp=443 --dpi-desync=fake --dpi-desync-cutoff=n30')" = "$absent" ] ||
    fail "$module: off, a strategy change is no nft change"
  on="$(sig "$module" "$mode" 1 '--filter-tcp=443 --dpi-desync=fake')"
  [ "$on" != "$absent" ] || fail "$module: switching the option on must rebuild nft"
  [ "$(sig "$module" "$mode" 1 '--filter-tcp=443 --dpi-desync=fake --dpi-desync-cutoff=n30')" != "$on" ] ||
    fail "$module: on, a strategy that changes the limit must rebuild nft"
  [ "$(sig "$module" "$mode" 1 '--filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=badsum')" = "$on" ] ||
    fail "$module: on, a strategy with the same limit is no nft change"
done
ok "nft signatures (apply.uc, state.uc): unchanged while off; on, follow the limits of each rule's strategy"

printf 'nfqws_first_packets: PASS\n'
