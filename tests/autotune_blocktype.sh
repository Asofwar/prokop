#!/usr/bin/env bash
set -euo pipefail

# DPI autotune diagnosis: the probe classifier's certificate, transfer-cut
# and local-feature classes (autotune/probe.uc), the block type of a target
# (autotune/blocktype.uc) and the diagnosis slice of a tuning run
# (isolation.uc tune ... diag=1): an address-blocked target or a clock
# problem stops the run before any nfqws starts. Zapret2 candidates run
# through nfqws2 with the same isolation and identity-checked cleanup.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
# shellcheck source=tests/helpers/autotune_stubs.sh
. "$ROOT/tests/helpers/autotune_stubs.sh"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/case_groups.sh
. "$ROOT/tests/helpers/case_groups.sh"

tune() { ucode -L "$LIB" "$LIB/autotune/isolation.uc" tune example.com "$@" > "$WORK/out.json" || true; }
classify() { ucode -L "$LIB" "$LIB/autotune/probe.uc" classify "$@" > "$WORK/c.json"; }
no_nfqws_started() {
  json 'a.ok(!r.timeline.some((t) => t.step === "T2"), "nfqws started: " + JSON.stringify(r.timeline));' "$WORK/out.json"
  [ ! -s "$STUB_LOG/curl.seq" ] || ! grep -q '^46' "$STUB_LOG/curl.seq" || fail "$1: a candidate was probed"
}

cases_1() {
# --- classifier ----------------------------------------------------------
classify 60 0.012 0 0 "SSL certificate problem: certificate is not yet valid"
json 'a.equal(r.class, "clock_problem"); a.equal(r.connect, "ok");' "$WORK/c.json"
classify 60 0.012 0 0 "SSL certificate problem: certificate has expired"
json 'a.equal(r.class, "clock_problem");' "$WORK/c.json"
classify 60 0.012 0 0 "SSL: no alternative certificate subject name matches target host name"
json 'a.equal(r.class, "cert_mismatch");' "$WORK/c.json"
classify 60 0 0 0 "SSL certificate problem: certificate is not yet valid"
json 'a.notEqual(r.class, "clock_problem"); a.notEqual(r.class, "success");' "$WORK/c.json"
ok "certificate time errors are a clock problem, other certificate errors a mismatch"
classify 4 0 0 0 "A requested feature, protocol or option was not found built-in"
json 'a.equal(r.class, "local_unsupported");' "$WORK/c.json"
ok "a feature curl lacks is local, never a block"
# The 16-20 KB cut: handshake and status, then the transfer stalls.
classify 28 0.012 0.061 206 "Operation timed out after 10000 milliseconds with 16384 bytes received" 16384 32768
json 'a.equal(r.class, "transfer_cut"); a.equal(r.cut_check, "cut");' "$WORK/c.json"
classify 0 0.012 0.061 206 "" 65536 32768
json 'a.equal(r.class, "success"); a.equal(r.cut_check, "passed");' "$WORK/c.json"
classify 0 0.012 0.061 200 "" 1500 32768
json 'a.equal(r.class, "success"); a.equal(r.cut_check, "unverified");' "$WORK/c.json"
classify 28 0.012 0 0 "Operation timed out" 0 32768
json 'a.notEqual(r.class, "transfer_cut"); a.equal(r.cut_check, "not_reached");' "$WORK/c.json"
classify 0 0.012 0.061 200 ""
json 'a.equal(r.class, "success"); a.equal(r.cut_check, undefined);' "$WORK/c.json"
ok "transfer cut: a short body after the handshake is cut, a full one passes, a short success is unverified"

# --- block type (pure) ----------------------------------------------------
cat > "$WORK/bt.uc" <<'UC'
let bt = require("autotune.blocktype");
let P = {
    ok: { class: "success", connect: "ok", tls: "ok" },
    cto: { class: "connect_timeout", connect: "timeout", tls: "not_attempted" },
    rst: { class: "tcp_reset", connect: "ok", tls: "reset" },
    tlsf: { class: "tls_failure", connect: "ok", tls: "failed" },
    cut: { class: "transfer_cut", connect: "ok", tls: "ok" },
    mism: { class: "cert_mismatch", connect: "ok", tls: "failed" },
    clock: { class: "clock_problem", connect: "ok", tls: "failed" },
    unsup: { class: "local_unsupported", connect: "not_attempted", tls: "not_attempted" },
};
let cases = [
    [ "ok", null, null, null, "none" ],
    [ "cto", "cto", null, null, "ip_block" ],
    [ "cto", "ok", null, null, "unclear" ],
    [ "rst", "ok", "rst", "rst", "sni_block" ],
    [ "rst", "mism", "rst", "rst", "sni_block" ],
    [ "rst", "rst", "rst", "rst", "tls_block" ],
    [ "rst", "rst", "ok", "rst", "tls12_only" ],
    [ "rst", "rst", "rst", "ok", "tls13_only" ],
    [ "rst", "rst", "ok", "unsup", "tls_block" ],
    [ "cut", null, null, null, "transfer_cut" ],
    [ "mism", null, null, null, "cert_mismatch" ],
    [ "clock", null, null, null, "clock_problem" ],
    [ null, null, null, null, "unclear" ],
];
let out = [];
for (let c in cases) {
    let v = bt.verdict(P[c[0]], P[c[1]], P[c[2]], P[c[3]]);
    push(out, { want: c[4], got: v.type, has: index(bt.TYPES, v.type) >= 0 });
}
print(sprintf("%J\n", { out, versions: [ bt.needs_versions(P.rst), bt.needs_versions(P.cto), bt.needs_versions(P.cut), bt.needs_versions(P.ok) ] }));
UC
ucode -L "$LIB" "$WORK/bt.uc" > "$WORK/bt.json"
json 'for (const c of r.out) { a.equal(c.got, c.want); a.ok(c.has); } a.deepEqual(r.versions, [true, false, false, false]);' "$WORK/bt.json"
ok "block type verdicts: ip, sni, tls, version, cut, certificate, clock"
}

cases_2() {
# --- diagnosis slice of a tuning run --------------------------------------
# Blocked by address: no TCP with the target's name or the neutral one.
reset_state
CURL_STUB_PLAN="diag.real=connect_timeout,diag.neutral=connect_timeout,direct=reset,4600=success:120" \
  PROKOP_AUTOTUNE_PROGRESS="$WORK/progress.json" tune 3 192.0.2.53 multisplit "" "diag=1"
json '
a.equal(r.status, "inconclusive", JSON.stringify(r).slice(0, 600)); a.equal(r.reason, "ip_blocked");
a.equal(r.block.type, "ip_block"); a.equal(r.selected, null); a.equal(r.applied, false);
a.deepEqual(r.block.probes.map((p) => p.diagnosis), ["real", "neutral"]);
a.equal(r.block.neutral_sni, "ya.ru");
a.equal(r.isolation.port_slices.diag, "61060-61063");
a.equal(r.cleanup.status, "clean"); a.equal(r.production.unchanged, true);' "$WORK/out.json"
no_nfqws_started "ip block"
grep -q 'comment "direct:diag"' "$NFT_STATE/last.nft" || fail "no diagnosis rule: $(grep output "$NFT_STATE/last.nft")"
grep -q -- '61060-61063' "$NFT_STATE/last.nft" || fail "diagnosis slice not in the probe rules"
grep -q '^diag.neutral ' "$STUB_LOG/curl.seq" || fail "neutral probe without the neutral name: $(cat "$STUB_LOG/curl.args")"
assert_clean "ip block"
ok "an address-blocked target stops before any nfqws starts; nothing is iterated"

# Blocked by name: the neutral name gets TLS from the same address.
reset_state
CURL_STUB_PLAN="diag.real=reset,diag.neutral=success,diag.tls12=reset,diag.tls13=reset,direct=reset,4600=success:120" \
  tune 3 192.0.2.53 multisplit "" "diag=1"
json '
a.equal(r.status, "selected", JSON.stringify(r).slice(0, 600)); a.equal(r.selected, "multisplit");
a.equal(r.block.type, "sni_block");
a.deepEqual(r.block.probes.map((p) => p.diagnosis), ["real", "neutral", "tls12", "tls13"]);
a.equal(r.block.probes[2].tls_version, "1.2"); a.equal(r.block.probes[3].tls_version, "1.3");
a.ok(r.block.probes.every((p) => p.remote_ip === "93.184.216.34" || p.resolved_ip === "93.184.216.34"));
a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
[ "$(grep -c '^diag\.' "$STUB_LOG/curl.seq")" = 4 ] || fail "diagnosis probes: $(tr '\n' ' ' < "$STUB_LOG/curl.seq")"
[ "$(head -n 4 "$STUB_LOG/curl.seq" | cut -d' ' -f1 | tr '\n' ' ')" = "diag.real diag.neutral diag.tls12 diag.tls13 " ] || fail "diagnosis not first: $(tr '\n' ' ' < "$STUB_LOG/curl.seq")"
assert_clean "sni block"
ok "SNI block diagnosed with four probes before the candidates; the run goes on"

reset_state
CURL_STUB_PLAN="diag.real=reset,diag.neutral=reset,diag.tls12=success,diag.tls13=reset,direct=reset,4600=success:120" \
  tune 3 192.0.2.53 multisplit "" "diag=1"
json 'a.equal(r.block.type, "tls12_only"); a.equal(r.status, "selected");' "$WORK/out.json"
assert_clean "tls12 only"
ok "TLS 1.2 only"

# A clock problem: certificates fail their time check, nothing is measured.
reset_state
CURL_STUB_PLAN="diag.real=cert_time,direct=reset,4600=success:120" tune 3 192.0.2.53 multisplit "" "diag=1"
json 'a.equal(r.status, "inconclusive"); a.equal(r.reason, "clock_problem"); a.equal(r.block.type, "clock_problem");
  a.equal(r.selected, null); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
no_nfqws_started "clock problem"
assert_clean "clock problem"
ok "a certificate time error stops the run as a clock problem"
}

cases_3() {
# The 16-20 KB cut through a large object of the target.
reset_state
CURL_STUB_PLAN="diag.real=cut,direct=cut,4600=big:120" tune 3 192.0.2.53 multisplit "" "diag=1,path=/static/app.js,min_bytes=32768"
json '
a.equal(r.status, "selected", JSON.stringify(r).slice(0, 600)); a.equal(r.selected, "multisplit");
a.equal(r.block.type, "transfer_cut"); a.deepEqual(r.large_object, { path: "/static/app.js", min_bytes: 32768 });
const direct = r.probes.filter((p) => p.candidate === "direct");
a.ok(direct.every((p) => p.class === "transfer_cut" && p.cut_check === "cut"));
const ms = r.probes.filter((p) => p.candidate === "multisplit");
a.ok(ms.every((p) => p.class === "success" && p.cut_check === "passed" && p.size_download === 65536));
a.ok(!JSON.stringify(r).includes("body"));' "$WORK/out.json"
grep -q -- '/static/app.js' "$STUB_LOG/curl.args" || fail "large object not fetched: $(cat "$STUB_LOG/curl.args")"
{ grep -qx -- '--range' "$STUB_LOG/curl.args" && grep -qx -- '0-65535' "$STUB_LOG/curl.args"; } || fail "large object without a bounded range"
assert_clean "transfer cut"
ok "a transfer cut after 16 KB fails direct; a candidate that delivers 64 KB passes"

# A short success on the large object is not counted as passing the cut check.
reset_state
CURL_STUB_PLAN="direct=success:100,4600=success:100" tune 3 192.0.2.53 multisplit "" "path=/static/app.js,min_bytes=32768"
json 'a.ok(r.probes.every((p) => p.cut_check === "unverified"), JSON.stringify(r.probes.map((p) => p.cut_check)));' "$WORK/out.json"
assert_clean "unverified"
ok "a short body on the large object stays unverified"

# The resolver's answer replaced by an address no public service has.
reset_state; export DIG_STUB_ANSWER='10.10.34.35\n'
tune 3 192.0.2.53 multisplit "" "diag=1"
json 'a.equal(r.status, "inconclusive"); a.equal(r.reason, "dns_spoofed"); a.equal(r.block.type, "dns_spoof");' "$WORK/out.json"
[ ! -e "$NFT_STATE/last.nft" ] || fail "dns spoof: probe path created"
assert_clean "dns spoof"
ok "a spoofed resolver answer is reported as such"

# The clock gate: no measurement while the clock is not synchronized.
reset_state
PROKOP_CLOCK_MARKER="$WORK/no-marker" PROKOP_CLOCK_NOW=1700000000 CURL_STUB_PLAN="direct=reset,4600=success:120" \
  tune 3 192.0.2.53 multisplit "" "diag=1"
json 'a.equal(r.status, "refused"); a.equal(r.reason, "clock_unsynced"); a.equal(r.clock.state, "unsynced");
  a.equal(r.clock.reason, "clock_before_release");' "$WORK/out.json"
[ ! -e "$STUB_LOG/curl.seq" ] || fail "probes taken on an unsynchronized clock"
assert_clean "clock unsynced"
tune 3 192.0.2.53 multisplit "" "diag=1"
json 'a.equal(r.clock.state, "synced"); a.equal(r.clock.source, "ntp_hotplug");' "$WORK/out.json"
ok "a tune refuses on an unsynchronized clock and records the clock state"

# Options are checked before anything else.
for bad in "diag=1,bogus=2" "path=/x.js" "path=/x.js,min_bytes=100" "path=x.js,min_bytes=32768" "provider=byedpi" "tier=0"; do
  reset_state; tune 3 192.0.2.53 multisplit "" "$bad"
  json 'a.equal(r.status, "refused"); a.equal(r.reason, "invalid_options");' "$WORK/out.json"
  [ ! -e "$STUB_LOG/curl.seq" ] || fail "invalid options probed: $bad"
done
assert_clean "invalid options"
ok "invalid tune options are refused"
}

cases_4() {
# --- Zapret2 candidates through nfqws2 ------------------------------------
cp "$WORK/bin/nfqws" "$WORK/bin/nfqws2"
export ZAPRET2_NFQWS2_BIN="$WORK/bin/nfqws2"
reset_state
CURL_STUB_PLAN="direct=reset,4600=success:120,4601=reset" tune 3 192.0.2.53 z2_fake,z2_default "" "provider=zapret2"
json '
a.equal(r.status, "selected", JSON.stringify(r).slice(0, 600)); a.equal(r.selected, "z2_fake"); a.equal(r.provider, "zapret2");
a.deepEqual(r.isolation.queues, [4600, 4601]); a.equal(r.cleanup.status, "clean"); a.equal(r.production.unchanged, true);' "$WORK/out.json"
assert_clean "zapret2 tune"
ok "Zapret2 candidates are measured through nfqws2 on the run queues"

# A zapret candidate in a Zapret2 run (and the other way round) is excluded.
reset_state; tune 3 192.0.2.53 multisplit "" "provider=zapret2"
json 'a.equal(r.status, "refused"); a.equal(r.reason, "no_supported_dpi_candidate");
  a.deepEqual(r.excluded.map((e) => [e.id, e.reason]), [["multisplit", "provider_mismatch"]]);' "$WORK/out.json"
reset_state; tune 3 192.0.2.53 z2_fake
json 'a.equal(r.status, "refused"); a.deepEqual(r.excluded.map((e) => e.reason), ["provider_mismatch"]);' "$WORK/out.json"
ok "candidates of another provider are excluded"

# Tier 1 of Zapret2 by default when no list is given.
reset_state; CURL_STUB_PLAN="direct=success:100" tune 3 192.0.2.53 "" "" "provider=zapret2"
json 'a.equal(r.tier, 1); a.ok(r.candidates.length >= 2); a.ok(r.candidates.every((c) => c.id === "direct" || c.id.startsWith("z2_")));
  a.ok(r.isolation.queues.length <= 8);' "$WORK/out.json"
assert_clean "zapret2 tier 1"
ok "the default Zapret2 list is its tier 1, within eight queues"

# Stress: a tuner killed while its nfqws2 runs; the cleanup stops exactly the
# recorded process (pid + start time + command line), again and again.
for round in 1 2 3; do
  reset_state; export CURL_STUB_SLEEP=2
  ucode -L "$LIB" "$LIB/autotune/isolation.uc" tune example.com 3 192.0.2.53 z2_fake "" "provider=zapret2" > "$WORK/out.json" &
  runner=$!
  wait_until 30 nfqws_running || fail "nfqws2 did not start (round $round)"
  kill -KILL "$runner"; wait "$runner" 2>/dev/null || true
  pkill -f "$WORK/bin/curl" 2>/dev/null || true
  unset CURL_STUB_SLEEP
  pgrep -f "$WORK/bin/nfqws2 --qnum=4600" >/dev/null || fail "nfqws2 gone before the cleanup (round $round)"
  # Round 2: the run's own record of the command line is lost; the pidfile
  # and the run signature of nfqws2 still identify it.
  [ "$round" != 2 ] || rm -f "$PROKOP_AUTOTUNE_STATE_DIR/active.json"
  ucode -L "$LIB" "$LIB/autotune/isolation.uc" cleanup > "$WORK/out.json" || true
  json 'a.equal(r.status, "clean", JSON.stringify(r)); a.ok(r.actions.some((x) => /^pidfile:(stopped|killed)$/.test(x)), r.actions);' "$WORK/out.json"
  kill -0 "$PROD_NFQWS" || fail "production stand-in signalled (round $round)"
  assert_clean "killed zapret2 tune round $round"
done
ok "a killed Zapret2 tune is recovered by the identity-checked cleanup (3 rounds, one without active.json)"

# PID reuse: the pidfile of queue 4600 names an unrelated process with an
# nfqws2 run record; the cleanup leaves it alone.
for ticks in "" 1; do
  reset_state; mkdir -p "$PROKOP_AUTOTUNE_STATE_DIR"
  sleep 600 & victim=$!; FOREIGN_PIDS+=("$victim")
  real_ticks="$(ucode -L "$LIB" -e 'print(require("core.process_identity").start_ticks(ARGV[0]))' "$victim")"
  printf '%s\n%s\n' "$victim" "${ticks:-$real_ticks}" > "$PROKOP_AUTOTUNE_STATE_DIR/nfqws-4600.pid"
  printf '{"nfqws":[{"queue":4600,"argv":["%s","--qnum=4600","--fwmark=0x40000000"]}]}\n' "$ZAPRET2_NFQWS2_BIN" > "$PROKOP_AUTOTUNE_STATE_DIR/active.json"
  ucode -L "$LIB" "$LIB/autotune/isolation.uc" cleanup > "$WORK/out.json" || true
  json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("pidfile:stale"), r.actions);' "$WORK/out.json"
  kill -0 "$victim" || fail "cleanup killed an unrelated process recorded as nfqws2"
  kill "$victim"
  assert_clean "nfqws2 pid reuse"
done
# An argv[0] outside nfqws/nfqws2 is never signalled, whatever the record says.
reset_state; mkdir -p "$PROKOP_AUTOTUNE_STATE_DIR"
sleep 600 & victim=$!; FOREIGN_PIDS+=("$victim")
real_ticks="$(ucode -L "$LIB" -e 'print(require("core.process_identity").start_ticks(ARGV[0]))' "$victim")"
printf '%s\n%s\n' "$victim" "$real_ticks" > "$PROKOP_AUTOTUNE_STATE_DIR/nfqws-4600.pid"
printf '{"nfqws":[{"queue":4600,"argv":["%s","600"]}]}\n' "$(command -v sleep)" > "$PROKOP_AUTOTUNE_STATE_DIR/active.json"
ucode -L "$LIB" "$LIB/autotune/isolation.uc" cleanup > "$WORK/out.json" || true
kill -0 "$victim" || fail "cleanup signalled a process recorded with a foreign binary"
kill "$victim"
assert_clean "foreign binary record"
ok "stale nfqws2 pidfiles (reused PID, other start time, foreign binary) never signal"
}
nfqws_running() { pgrep -f "$WORK/bin/nfqws2 --qnum=4600" >/dev/null; }

GROUP_DIR="$WORK/case-groups"
case_group() {
  # shellcheck source=tests/helpers/autotune_stubs.sh
  . "$ROOT/tests/helpers/autotune_stubs.sh"
  "cases_$1"
  printf '%s\n' "$pass" >"$GROUP_DIR/$1.count"
}
run_case_groups "$GROUP_DIR" case_group 1 2 3 4
for group in 1 2 3 4; do
  pass=$((pass + $(cat "$GROUP_DIR/$group.count")))
done

printf 'autotune_blocktype: PASS (%d checks)\n' "$pass"
