#!/usr/bin/env bash
set -euo pipefail

# DPI autotune stage 4: measurement aggregation, deterministic scoring and
# selection (autotune/select.uc), and the interleaved tuning run through the
# isolated path (isolation.uc tune). Nothing is ever applied to Prokop.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
# shellcheck source=tests/helpers/autotune_stubs.sh
. "$ROOT/tests/helpers/autotune_stubs.sh"
# shellcheck source=tests/helpers/case_groups.sh
. "$ROOT/tests/helpers/case_groups.sh"

cases_1() {
# --- scoring and selection (pure) --------------------------------------------
cat > "$WORK/cases.js" <<'JS'
const fs = require('fs');
const assert = require('node:assert/strict');
const { execFileSync } = require('child_process');
const [LIB, WORK] = process.argv.slice(2);
let checks = 0;
const ok = (name) => { checks++; console.log(`ok ${name}`); };
const RANK = { direct: 0, multisplit: 1, fake: 2, multidisorder: 2, fakedsplit: 3, fake_multisplit: 3, hostfakesplit: 3, fake_multidisorder: 4 };
// outcome: a TLS time in ms (success) or a failure class
function probe(outcome, i) {
  if (typeof outcome === 'number')
    return { class: 'success', connect: 'ok', tls: 'ok', http: 'ok', http_status: 404, time_connect_ms: 30 + i,
      time_appconnect_ms: outcome, time_starttransfer_ms: outcome + 40, time_total_ms: outcome + 41 };
  return { class: outcome, connect: outcome === 'connect_timeout' ? 'timeout' : 'ok', tls: 'failed', http: 'not_attempted',
    http_status: 0, time_connect_ms: outcome === 'connect_timeout' ? 0 : 28, time_appconnect_ms: 0, time_starttransfer_ms: 0, time_total_ms: 5000 };
}
function measured(spec) {
  return Object.entries(spec).map(([id, outcomes]) => ({ candidate: { id, rank: RANK[id] }, probes: outcomes.map(probe) }));
}
function evaluate(list) {
  fs.writeFileSync(`${WORK}/measured.json`, JSON.stringify(list));
  return JSON.parse(execFileSync('ucode', ['-L', LIB, `${LIB}/autotune/select.uc`, 'evaluate', `${WORK}/measured.json`], { encoding: 'utf8' }));
}
const cand = (r, id) => r.candidates.find((c) => c.id === id);
const S3 = (t) => [t, t, t];

// 1. direct stable, DPI stable, similar latency -> direct
let r = evaluate(measured({ direct: S3(100), multisplit: S3(95), fake: S3(90) }));
assert.deepEqual([r.status, r.selected, r.reason, r.confidence], ['selected', 'direct', 'direct_stable', 'high']);
ok('1 direct and DPI stable with similar latency -> direct');
// 2. direct fails, multisplit 3/3 -> multisplit
r = evaluate(measured({ direct: ['tcp_reset', 'tcp_reset', 'tcp_reset'], multisplit: S3(120) }));
assert.deepEqual([r.status, r.selected, r.reason, r.confidence], ['selected', 'multisplit', 'direct_failed_candidate_stable', 'high']);
ok('2 direct fails, multisplit stable -> multisplit');
// 3. two stable candidates, same performance -> lower complexity
r = evaluate(measured({ direct: S3('tls_failure'), fake: S3(110), multisplit: S3(110) }));
assert.equal(r.selected, 'multisplit');
ok('3 equal performance -> lower complexity');
// 4. simpler slightly slower within tolerance -> simpler
r = evaluate(measured({ direct: S3('tcp_reset'), multisplit: S3(130), fakedsplit: S3(110) }));
assert.equal(r.selected, 'multisplit'); assert.equal(r.confidence, 'high');
r = evaluate(measured({ direct: S3('tcp_reset'), multisplit: S3(620), fakedsplit: S3(500) }));
assert.equal(r.selected, 'multisplit', 'a 20% relative tolerance keeps the simpler candidate');
ok('4 simpler candidate slightly slower (within max(25 ms, 20%)) -> simpler');
// 5. simpler materially slower -> faster
r = evaluate(measured({ direct: S3('tcp_reset'), multisplit: S3(300), fakedsplit: S3(150) }));
assert.deepEqual([r.selected, r.reason, r.confidence], ['fakedsplit', 'direct_failed_candidate_stable', 'medium']);
r = evaluate(measured({ direct: S3(400), multisplit: S3(120) }));
assert.deepEqual([r.selected, r.reason, r.confidence], ['multisplit', 'materially_faster_than_direct', 'medium']);
ok('5 simpler candidate materially slower -> faster candidate (medium confidence)');
// 6. stable vs unstable -> stable
r = evaluate(measured({ direct: S3('tcp_reset'), multisplit: [100, 'tcp_reset', 100], fake: S3(140) }));
assert.equal(r.selected, 'fake'); assert.equal(cand(r, 'multisplit').stability, 'unstable');
r = evaluate(measured({ direct: [100, 'tcp_reset', 100], multisplit: S3(100) }));
assert.deepEqual([r.selected, r.reason, r.confidence], ['multisplit', 'direct_unstable_candidate_stable', 'medium']);
ok('6 stable beats unstable; unstable control lowers confidence');
// 7. all failed -> inconclusive
r = evaluate(measured({ direct: S3('connect_timeout'), multisplit: S3('tls_failure'), fake: ['tcp_reset', 100, 'tcp_reset'] }));
assert.deepEqual([r.status, r.selected, r.reason, r.confidence], ['inconclusive', null, 'all_failed', 'low']);
ok('7 all failed -> inconclusive');
// 8. all unstable -> inconclusive, low confidence, leading candidate reported
r = evaluate(measured({ direct: [100, 'tcp_reset', 100], multisplit: [90, 90, 'tls_failure'], fake: S3('tls_failure') }));
assert.deepEqual([r.status, r.selected, r.reason, r.confidence], ['inconclusive', null, 'no_stable_candidate', 'low']);
assert.equal(r.leading, 'direct');
ok('8 only unstable candidates -> inconclusive (no winner from weak evidence)');
// 10. mixed failure classes preserved; latency only from successes
r = evaluate(measured({ direct: ['tcp_reset', 'connect_timeout', 'tls_failure', 'tcp_reset', 90], multisplit: [100, 104, 99, 'http_transport_failure', 101] }));
assert.deepEqual(cand(r, 'direct').failure_classes, [{ class: 'connect_timeout', count: 1 }, { class: 'tcp_reset', count: 2 }, { class: 'tls_failure', count: 1 }]);
assert.equal(cand(r, 'direct').failure_count, 4); assert.equal(cand(r, 'direct').median_tls_ms, 90);
assert.deepEqual([cand(r, 'multisplit').success, cand(r, 'multisplit').stability, cand(r, 'multisplit').median_tls_ms], [4, 'stable', 101]);
r = evaluate(measured({ direct: S3('tcp_reset'), multisplit: S3(100) }));
assert.equal(cand(r, 'direct').median_tls_ms, null, 'failed probes never become fake latency');
ok('10 failure classes preserved; medians over successful probes only');
// Ratio thresholds for longer samples.
r = evaluate(measured({ direct: [1, 2, 3, 4, 'tcp_reset'].map((x) => typeof x === 'number' ? 100 : x), multisplit: [100, 100, 100, 'tcp_reset', 'tcp_reset'] }));
assert.deepEqual([cand(r, 'direct').stability, cand(r, 'multisplit').stability], ['stable', 'unstable']);
r = evaluate(measured({ direct: [100, 100, 'tcp_reset', 'tcp_reset', 'tcp_reset', 'tcp_reset', 'tcp_reset'], multisplit: S3(100) }));
assert.equal(cand(r, 'direct').stability, 'failed');
ok('ratio thresholds: >= 0.8 stable, >= 0.5 unstable, below failed');
// 11. candidate order permutations -> same selection and ranking
const base = measured({ direct: S3('tcp_reset'), fake: S3(112), multisplit: S3(118), fakedsplit: S3(80), multidisorder: [100, 'tls_failure', 100] });
const expected = evaluate(base);
const perms = (a) => a.length <= 1 ? [a] : a.flatMap((x, i) => perms([...a.slice(0, i), ...a.slice(i + 1)]).map((p) => [x, ...p]));
let n = 0;
for (const order of perms(base)) {
  const got = evaluate(order);
  assert.deepEqual([got.selected, got.reason, got.confidence, got.ranking], [expected.selected, expected.reason, expected.confidence, expected.ranking]);
  n++;
}
assert.equal(n, 120);
ok(`11 all ${n} input orders give the same selection and ranking`);
// 12. deterministic tie -> lexical id
r = evaluate(measured({ direct: S3('tcp_reset'), multidisorder: S3(100), fake: S3(100) }));
assert.equal(r.selected, 'fake');
assert.deepEqual(r.ranking.slice(0, 2), ['fake', 'multidisorder']);
ok('12 equal rank and latency -> lexical candidate id');
// Materially faster chain stays deterministic (champion from the simplest).
r = evaluate(measured({ direct: S3('tcp_reset'), multisplit: S3(400), fake: S3(300), fakedsplit: S3(290) }));
assert.equal(r.selected, 'fake', 'fakedsplit is within tolerance of fake, so the simpler fake stays');
ok('latency tolerance applies against the current choice, not a global minimum');
// AT-1: a probe that never reached the server is not the strategy's failure.
r = evaluate(measured({ direct: [...S3('tls_failure'), 'tls_failure', 'tls_failure'], multisplit: [100, 100, 100, 100, 'connect_timeout'],
  fake: [100, 100, 100, 100, 100], fake_multidisorder: [100, 100, 100, 100, 100] }));
assert.deepEqual([r.selected, r.reason, r.confidence], ['multisplit', 'direct_failed_candidate_stable', 'high']);
assert.deepEqual([cand(r, 'multisplit').attempted, cand(r, 'multisplit').network_failures, cand(r, 'multisplit').failure_count], [4, 1, 1]);
r = evaluate(measured({ direct: ['connect_timeout', 'connect_timeout', 'tls_failure'], multisplit: S3(100) }));
assert.deepEqual([r.selected, r.reason, r.confidence], ['multisplit', 'direct_failed_candidate_stable', 'medium'],
  'a control that reached the server once is not enough for high confidence');
ok('AT-1 connect-stage failures do not count against a candidate or the control');
fs.writeFileSync(`${WORK}/pure.count`, String(checks));
JS
node "$WORK/cases.js" "$LIB" "$WORK"
pass=$((pass + $(cat "$WORK/pure.count")))

# Schedule: interleaved rounds, rotated, reproducible.
ucode -L "$LIB" "$LIB/autotune/select.uc" schedule direct,multisplit,fake,fakedsplit 3 > "$WORK/sched.json"
json 'a.deepEqual(r, [["direct","multisplit","fake","fakedsplit"],["multisplit","fake","fakedsplit","direct"],["fake","fakedsplit","direct","multisplit"]]);' "$WORK/sched.json"
ok "schedule rotates the base order each round"
}

# --- tuning runs through the isolated path ------------------------------------
tune() { ucode -L "$LIB" "$LIB/autotune/isolation.uc" tune example.com "$@" > "$WORK/out.json" || true; }

cases_2() {
# 13. one resolution, one pinned IP for every candidate; interleaving; selection
reset_state
CURL_STUB_PLAN="direct=reset,4600=success:120,4601=success:118" PROKOP_AUTOTUNE_PROGRESS="$WORK/progress.json" tune 3 192.0.2.53 multisplit,fake
# The last phase reported is the cleanup, after all 9 probes.
node -e 'const p=require(process.argv[1]); if (p.phase !== "cleaning" || p.done !== 9 || p.total !== 9) process.exit(1)' "$WORK/progress.json" ||
  fail "tune progress: $(cat "$WORK/progress.json" 2>/dev/null)"
json '
a.equal(r.status, "selected", JSON.stringify(r).slice(0, 400)); a.equal(r.selected, "multisplit");
a.equal(r.reason, "direct_failed_candidate_stable"); a.equal(r.confidence, "high"); a.equal(r.applied, false);
a.deepEqual(r.isolation.queues, [4600, 4601]);
a.deepEqual(r.schedule, [["direct","multisplit","fake"],["multisplit","fake","direct"],["fake","direct","multisplit"]]);
a.deepEqual(r.probes.map((p) => p.candidate), r.schedule.flat());
a.ok(r.probes.every((p) => p.resolved_ip === "93.184.216.34" && p.remote_ip === "93.184.216.34"));
a.equal(r.target.ip, "93.184.216.34");
const byId = Object.fromEntries(r.candidates.map((c) => [c.id, c]));
a.deepEqual([byId.direct.stability, byId.multisplit.stability, byId.fake.stability], ["failed", "stable", "stable"]);
a.equal(byId.multisplit.median_tls_ms, 120); a.equal(byId.multisplit.complexity, 1);
a.ok(r.probes.filter((p) => p.candidate !== "direct").every((p) => p.queued >= p.rule_packets));
a.equal(r.cleanup.status, "clean"); a.equal(r.production.unchanged, true);
' "$WORK/out.json"
[ "$(wc -l < "$STUB_LOG/dig.log")" = 1 ] || fail "target resolved more than once"
[ "$(cut -d' ' -f2 "$STUB_LOG/curl.seq" | sort -u)" = 93.184.216.34 ] || fail "probes against more than one address"
[ "$(cut -d' ' -f1 "$STUB_LOG/curl.seq" | tr '\n' ' ')" = "direct 4600 4601 4600 4601 direct 4601 direct 4600 " ] || fail "probes not interleaved: $(tr '\n' ' ' < "$STUB_LOG/curl.seq")"
assert_clean "tune selected"
ok "13 one resolution pinned for every candidate, rotated interleaving, multisplit selected"

# Every candidate has a fixed slice of the source ports and a probe rule of
# its own for it, created with the table: nothing is switched between
# probes, and each probe leaves from its candidate's slice.
json '
a.deepEqual(r.isolation.port_slices, { direct: "61000-61020", multisplit: "61021-61041", fake: "61042-61062" });
for (const p of r.probes) a.equal(p.port_range, r.isolation.port_slices[p.candidate], p.candidate);
' "$WORK/out.json"
T='ip daddr 93.184.216.34 tcp dport 443'
for rule in "tcp sport 61000-61020 meta mark 0x08000000 counter accept comment \"direct:direct\"" \
  "tcp sport 61021-61041 meta mark 0x08000000 counter queue num 4600 comment \"probe:multisplit\"" \
  "tcp sport 61042-61062 meta mark 0x08000000 counter queue num 4601 comment \"probe:fake\""; do
  grep -qxF "add rule inet ProkopAutotuneProbe output $T $rule" "$NFT_STATE/last.nft" || fail "missing slice rule: $rule"
done
grep -qxF "add rule inet ProkopAutotuneProbe output $T tcp sport 61000-61063 counter drop comment \"unexpected\"" "$NFT_STATE/last.nft" ||
  fail "the drop of anything else of the probe tuple is not after the slices"
[ "$(paste -sd' ' "$STUB_LOG/curl.ports")" = "61000-61020 61021-61041 61042-61062 61021-61041 61042-61062 61000-61020 61042-61062 61000-61020 61021-61041" ] ||
  fail "probes did not leave from their candidate's slice: $(paste -sd' ' "$STUB_LOG/curl.ports")"
[ "$(sort -u "$STUB_LOG/switch.log" | paste -sd' ')" = "released:direct - released:fake - released:multisplit -" ] ||
  fail "probe rules were switched during the run: $(paste -sd' ' "$STUB_LOG/switch.log")"
[ "$(grep -c '^replace rule' "$NFT_STATE/release.nft")" = 3 ] || fail "the slices are not released in one batch"
R='ip saddr 93.184.216.34 tcp sport 443'
for rule in "tcp dport 61000-61020 tcp flags & (syn | ack) == syn | ack ct direction reply ct original ip saddr 203.0.113.10 counter comment \"synack:direct\"" \
  "tcp dport 61021-61041 tcp flags & (syn | ack) == syn | ack ct direction reply ct original ip saddr 203.0.113.10 counter comment \"synack:multisplit\"" \
  "tcp dport 61042-61062 tcp flags & (syn | ack) == syn | ack ct direction reply ct original ip saddr 203.0.113.10 counter comment \"synack:fake\""; do
  grep -qxF "add rule inet ProkopAutotuneProbe replies $R $rule" "$NFT_STATE/last.nft" || fail "missing SYN-ACK counter: $rule"
done
grep -qxF "add chain inet ProkopAutotuneProbe replies { type filter hook prerouting priority -175; policy accept; }" "$NFT_STATE/last.nft" ||
  fail "reply chain is not a counting filter chain after conntrack"
ok "fixed port slices: one rule per candidate, no switching, released together"

# A control and a candidate whose ClientHello is blackholed after the TCP
# handshake: curl says "Connection timed out" with time_connect 0, the
# SYN-ACK counters of their slices say the server answered. That is DPI
# evidence against them, not an unreachable target (hardware, 2.18.0).
reset_state; CURL_STUB_PLAN="direct=tls_stall,4600=success:120,4601=tls_stall" tune 3 192.0.2.53 multisplit,fake
json '
a.equal(r.status, "selected", JSON.stringify(r).slice(0, 400)); a.equal(r.selected, "multisplit");
a.equal(r.reason, "direct_failed_candidate_stable"); a.equal(r.confidence, "high");
const byId = Object.fromEntries(r.candidates.map((c) => [c.id, c]));
a.deepEqual([byId.direct.attempted, byId.direct.network_failures, byId.direct.stability], [3, 0, "failed"]);
a.deepEqual(byId.direct.failure_classes, [{ class: "tls_failure", count: 3 }]);
for (const p of r.probes.filter((x) => x.candidate !== "multisplit"))
  a.deepEqual([p.class, p.connect, p.tls, p.syn_acks, p.connect_evidence], ["tls_failure", "ok", "timeout", 1, "syn_ack"]);
a.ok(r.probes.filter((x) => x.candidate === "multisplit").every((p) => p.syn_acks === 1 && p.connect_evidence === undefined));
' "$WORK/out.json"
assert_clean "tune tls stall"
ok "a ClientHello blackholed after the TCP handshake counts against the candidate and the control"

# 1 (end to end). direct stable -> direct, no DPI needed
reset_state; CURL_STUB_PLAN="direct=success:100,4600=success:95,4601=success:90" tune 3 192.0.2.53 multisplit,fake
json 'a.equal(r.status, "selected"); a.equal(r.selected, "direct"); a.equal(r.reason, "direct_stable"); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "tune direct"
ok "direct stable end to end -> direct"
}

cases_3() {
# 9. supported + unsupported: unsupported excluded, not counted as failure
reset_state; export NFQWS_STUB_REJECT=fakedsplit
CURL_STUB_PLAN="direct=reset,4600=success:120" tune 3 192.0.2.53 multisplit,fakedsplit,udp_fake,nosuch
json '
a.equal(r.status, "selected"); a.equal(r.selected, "multisplit");
a.deepEqual(r.excluded.map((e) => [e.id, e.reason]), [["fakedsplit","nfqws_dry_run_rejected"],["udp_fake","quic_probe_unavailable"],["nosuch","unknown_candidate"]]);
a.deepEqual(r.candidates.map((c) => c.id), ["direct", "multisplit"]);
a.ok(!r.probes.some((p) => ["fakedsplit","udp_fake","nosuch"].includes(p.candidate)));
' "$WORK/out.json"
assert_clean "tune unsupported"
ok "9 unsupported candidates excluded with their reason, never probed or failed"

# AT-8: a port of the probe range in TIME_WAIT (an apply verification just
# before) cannot be bound again: the tune waits for it to expire instead of
# losing probes of the control to curl exit 45; a probe that still finds
# no free port fails the run, never the candidate.
reset_state
printf '   0: 0A00000A:EE4D 01010101:01BB 06\n' >> "$PROKOP_AUTOTUNE_PROC_NET/tcp"
( sleep 2; sed -i '/0A00000A:EE4D/d' "$PROKOP_AUTOTUNE_PROC_NET/tcp" ) >/dev/null 2>&1 &
CURL_STUB_BUSY_MARK=0A00000A:EE4D CURL_STUB_PLAN="direct=reset,4600=success:120" tune 3 192.0.2.53 multisplit
json 'a.equal(r.status, "selected", JSON.stringify(r).slice(0, 400)); a.equal(r.selected, "multisplit");
  a.ok(r.probes.every((p) => p.class !== "connect_failure" && p.class !== "local_port_unavailable"), JSON.stringify(r.probes.map((p) => p.class)));' "$WORK/out.json"
assert_clean "tune after TIME_WAIT"
reset_state; CURL_STUB_PLAN="direct=reset|local_port,4600=success:120" tune 3 192.0.2.53 multisplit
json 'a.equal(r.status, "failed"); a.equal(r.reason, "local_port_unavailable"); a.equal(r.selected, null); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
ok "AT-8 a tune waits for TIME_WAIT probe ports; an unbindable source port fails the run, not the candidate"

# AT-9: a candidate nfqws that dies after its last probe (while the control
# is probed) is named as such, not as a candidate that bypassed its queue.
reset_state; CURL_STUB_KILL_AT=8 CURL_STUB_PLAN="direct=reset,4600=success:120" tune 4 192.0.2.53 multisplit
json 'a.equal(r.status, "failed", JSON.stringify(r).slice(0, 300)); a.equal(r.reason, "nfqws_died");
  a.equal(r.probes.length, 8); a.equal(r.probes[7].candidate, "direct");' "$WORK/out.json"
assert_clean "tune nfqws died"
ok "AT-9 an nfqws that died after its last probe -> nfqws_died"

# Inconclusive runs.
reset_state; CURL_STUB_PLAN="direct=reset,4600=tls,4601=reset" tune 3 192.0.2.53 multisplit,fake
json 'a.equal(r.status, "inconclusive"); a.equal(r.reason, "all_failed"); a.equal(r.selected, null); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
ok "all candidates failed -> inconclusive"

# A candidate failed whatever its remaining probes give is not probed
# further; the control is always measured in full, and the outcome is the
# full run's (select.uc settled_failed).
reset_state; CURL_STUB_PLAN="direct=reset,4600=success:120,4601=reset" PROKOP_AUTOTUNE_PROGRESS="$WORK/progress.json" tune 3 192.0.2.53 multisplit,fake
json '
a.equal(r.status, "selected"); a.equal(r.selected, "multisplit"); a.equal(r.confidence, "high");
a.deepEqual(r.pruned, ["fake"]);
const count = (id) => r.probes.filter((p) => p.candidate === id).length;
a.deepEqual([count("direct"), count("multisplit"), count("fake")], [3, 3, 2]);
a.equal(r.candidates.find((c) => c.id === "fake").stability, "failed");
' "$WORK/out.json"
node -e 'const p=require(process.argv[1]); if (p.done !== 8 || p.total !== 8) process.exit(1)' "$WORK/progress.json" ||
  fail "pruned progress: $(cat "$WORK/progress.json" 2>/dev/null)"
assert_clean "tune pruned"
cat >"$WORK/settled.uc" <<'UC'
let s = require("autotune.select");
let f = { class: "tcp_reset", connect: "ok" }, ok = { class: "success", connect: "ok" }, net = { class: "connect_timeout", connect: "timeout" };
print(join(",", [ s.settled_failed([ f ], 2), s.settled_failed([ f, f ], 1), s.settled_failed([ net, net ], 1),
    s.settled_failed([ ok, f, f, f ], 3), s.settled_failed([ ok, f, f, f, f ], 2) ]));
UC
[ "$(ucode -L "$LIB" "$WORK/settled.uc")" = "false,true,false,false,true" ] || fail "settled_failed bounds"
ok "a candidate that can only fail is not probed further; the control is measured in full"
}
cases_4() {
reset_state; CURL_STUB_PLAN="direct=connect_timeout,4600=connect_timeout,4601=connect_timeout" tune 3 192.0.2.53 multisplit,fake
json 'a.equal(r.status, "inconclusive"); a.equal(r.reason, "target_unreachable"); a.equal(r.unreachable_round, 1); a.equal(r.probes.length, 3); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
[ "$(wc -l < "$STUB_LOG/dig.log")" = 1 ] || fail "unreachable target was re-resolved"
assert_clean "unreachable"
ok "target unusable (every candidate fails before TCP) -> inconclusive, no re-resolution"
reset_state; CURL_STUB_PLAN="direct=reset,4600=success|otherip|success,4601=success" tune 3 192.0.2.53 multisplit,fake
json 'a.equal(r.status, "inconclusive"); a.equal(r.reason, "target_ip_mismatch"); a.equal(r.selected, null);' "$WORK/out.json"
ok "a probe answered by another address -> inconclusive"
reset_state; export DIG_STUB_ANSWER=''; tune 3 192.0.2.53 multisplit
json 'a.equal(r.status, "inconclusive"); a.equal(r.reason, "target_unresolved"); a.equal(r.probes.length, 0);' "$WORK/out.json"
[ ! -e "$NFT_STATE/last.nft" ] || fail "unresolved target created nft state"
ok "unresolved target -> inconclusive before anything is created"

# 15. isolation unavailable -> no probes, no selection
reset_state; mutate_ruleset "$NFT_STATE/ruleset.json" remove-bypass; tune 3 192.0.2.53 multisplit,fake
json 'a.equal(r.status, "unsupported"); a.equal(r.reason, "isolation_unavailable"); a.equal(r.selected, null); a.equal(r.probes.length, 0);' "$WORK/out.json"
[ ! -e "$NFT_STATE/last.nft" ] || fail "isolation unavailable created nft state"
[ ! -e "$STUB_LOG/curl.seq" ] || fail "isolation unavailable still probed"
assert_clean "isolation unavailable"
ok "15 isolation unavailable -> no probes and no selection"

# Input validation.
reset_state; tune 2 192.0.2.53 multisplit; json 'a.equal(r.status, "refused"); a.equal(r.reason, "invalid_probe_count");' "$WORK/out.json"
tune 8 192.0.2.53 multisplit; json 'a.equal(r.status, "refused"); a.equal(r.reason, "invalid_probe_count");' "$WORK/out.json"
tune max:2 192.0.2.53 multisplit; json 'a.equal(r.status, "refused"); a.equal(r.reason, "invalid_probe_count");' "$WORK/out.json"
tune 3 192.0.2.53 udp_fake; json 'a.equal(r.status, "refused"); a.equal(r.reason, "no_supported_dpi_candidate");' "$WORK/out.json"
[ ! -e "$NFT_STATE/last.nft" ] || fail "refused run created nft state"
ok "probe count 3..7, at least one DPI candidate"
}

cases_5() {
# The source ports of one run (61000-61063, D-4a) hold the whole catalog at
# the policy's highest probe count: neither a plain count nor the manager's
# "max:<n>" is refused or lowered (UC-031).
reset_state; tune 7 192.0.2.53
json 'a.notEqual(r.reason, "too_many_probes", r.reason); a.equal(r.probes_requested, 7);
const n = r.candidates.length; a.ok(n >= 8, "the fixture is the whole catalog: " + n); a.ok(n * 7 <= 64);
a.equal(r.probes_per_candidate, 7); a.equal(r.probes.length, n * 7);
for (const c of r.candidates) a.equal(c.attempted, 7, c.id);' "$WORK/out.json"
assert_clean "max probes"
reset_state; tune max:5 192.0.2.53 multisplit,fake
json 'a.equal(r.probes_per_candidate, 5, "nothing is lowered when the run fits"); a.equal(r.probes.length, 15);' "$WORK/out.json"
ok "the whole catalog at 7 probes fits the source ports of one run"
}

cases_6() {
# 14. interruption -> cleanup, no selection
reset_state; export CURL_STUB_SLEEP=1
ucode -L "$LIB" "$LIB/autotune/isolation.uc" tune example.com 3 192.0.2.53 multisplit,fake > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 100); do [ -e "$STUB_LOG/curl.seq" ] && break; sleep 0.1; done
kill -TERM "$runner"; wait "$runner" || true
json 'a.equal(r.status, "interrupted"); a.equal(r.selected, null); a.ok(r.probes.length < 9); a.equal(r.cleanup.status, "clean"); a.equal(r.production.unchanged, true);' "$WORK/out.json"
assert_clean "tune interrupted"
ok "14 interrupted tuning run cleans up and selects nothing"

# Candidate nfqws failure mid-run: no selection from partial evidence.
reset_state; CURL_STUB_PLAN="direct=reset,4600=success,4601=success" CURL_STUB_QUEUED=2 tune 3 192.0.2.53 multisplit,fake
json 'a.equal(r.status, "failed"); a.equal(r.reason, "candidate_bypassed"); a.equal(r.selected, null); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "bypassed"
ok "a candidate queue that did not take every probe packet invalidates the run"

# 16. no production mutation
reset_state; CURL_STUB_PLAN="direct=reset,4600=success:120,4601=success:118" tune 3 192.0.2.53 multisplit,fake
json 'a.equal(r.status, "selected"); a.equal(r.production.unchanged, true); a.equal(r.applied, false);
  a.deepEqual(r.production.before, r.production.after);' "$WORK/out.json"
! grep -vE '^nft (list tables|list table inet [A-Za-z]+|list chain inet ProkopTable prokop_transition_guard|-j list table inet [A-Za-z]+|list ruleset|-j -t list ruleset|-j list set inet ProkopTable prokop_interfaces|-f .*/(probe|release)\.nft|delete table inet ProkopAutotuneProbe)$' "$STUB_LOG/nft.log" ||
  fail "unexpected nft command: $(grep -vE '^nft (list|-j|-f|delete table inet ProkopAutotuneProbe)' "$STUB_LOG/nft.log" | head -3)"
kill -0 "$PROD_NFQWS" || fail "production nfqws stand-in signalled"
assert_clean "no mutation"
ok "16 production untouched: only the temporary table is created, released and deleted"
}

# The groups of cases run at once, each on stand-ins of its own (a fresh
# $WORK from autotune_stubs.sh): a tuning run waits whole seconds at its
# steps, so one after another they took a minute.
GROUP_DIR="$WORK/case-groups"
case_group() {
  # shellcheck source=tests/helpers/autotune_stubs.sh
  . "$ROOT/tests/helpers/autotune_stubs.sh"
  "cases_$1"
  printf '%s\n' "$pass" >"$GROUP_DIR/$1.count"
}
run_case_groups "$GROUP_DIR" case_group 1 2 3 4 5 6
for group in 1 2 3 4 5 6; do
  pass=$((pass + $(cat "$GROUP_DIR/$group.count")))
done

printf 'autotune_select: PASS (%d checks)\n' "$pass"
