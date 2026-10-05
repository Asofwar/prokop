#!/usr/bin/env bash
set -euo pipefail

# DPI autotune stages 1-3: candidate catalog, probe classifier and the
# isolated probe path with its idempotent cleanup. nft, curl, dig and nfqws
# are stubs (tests/helpers/autotune_stubs.sh); process identity, pidfiles and
# the run lock are real.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
# shellcheck source=tests/helpers/autotune_stubs.sh
. "$ROOT/tests/helpers/autotune_stubs.sh"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/case_groups.sh
. "$ROOT/tests/helpers/case_groups.sh"
# A detached nfqws double is visible to the orphan scan only once it has
# exec'd; wait for that instead of a fixed delay.
nfqws_started() { pgrep -f "$1" >/dev/null; }

cases_1() {
# --- catalog -------------------------------------------------------------
reset_state
ucode -L "$LIB" "$LIB/autotune/catalog.uc" validate > "$WORK/catalog.json"
json '
const ids = r.map((e) => e.id);
a.deepEqual(ids, ["direct","multisplit","fake","multidisorder","fakedsplit","fake_multisplit","hostfakesplit","fake_multidisorder","udp_fake"]);
for (const e of r) {
  a.ok(e.id && e.protocol && typeof e.rank === "number" && typeof e.nfqws_opt === "string" && typeof e.enabled === "boolean");
  a.doesNotMatch(e.nfqws_opt, /--qnum|--hostlist|--ipset|--dpi-desync-fwmark|--daemon|<HOSTLIST/);
  if (e.protocol === "tcp") { a.equal(e.state, "supported", JSON.stringify(e)); a.equal(e.enabled, true); }
  if (e.nfqws_opt) a.match(e.nfqws_opt, e.protocol === "tcp" ? /^--filter-tcp=443 / : /^--filter-udp=443 /);
}
const udp = r.find((e) => e.id === "udp_fake");
a.equal(udp.state, "unsupported"); a.equal(udp.reason, "quic_probe_unavailable");
a.ok(r.find((e) => e.id === "direct").rank < r.find((e) => e.id === "fake_multidisorder").rank);
' "$WORK/catalog.json"
ok "catalog valid"

NFQWS_STUB_REJECT=hostfakesplit ucode -L "$LIB" "$LIB/autotune/catalog.uc" validate hostfakesplit > "$WORK/one.json"
json 'a.equal(r.state, "unsupported"); a.equal(r.reason, "nfqws_dry_run_rejected"); a.equal(r.enabled, false);' "$WORK/one.json"
ZAPRET_NFQWS_BIN="$WORK/missing" ucode -L "$LIB" "$LIB/autotune/catalog.uc" validate fake > "$WORK/one.json"
json 'a.equal(r.state, "unsupported"); a.equal(r.reason, "nfqws_unavailable");' "$WORK/one.json"
NFQWS_STUB_REJECT=hostfakesplit run_probe hostfakesplit
json 'a.equal(r.status, "unsupported"); a.equal(r.reason, "nfqws_dry_run_rejected"); a.equal(r.probes.length, 0);' "$WORK/out.json"
[ ! -e "$NFT_STATE/last.nft" ] || fail "unsupported candidate created nft state"
assert_clean "unsupported"
ok "unsupported strategy"
}

# --- probe classifier through the full isolated path ---------------------
expect_class() {
  reset_state; export CURL_STUB_MODE="$1"; run_probe multisplit 1
  json "a.equal(r.status, 'completed', JSON.stringify(r)); const p = r.probes[0];
    a.equal(p.class, '$2'); a.equal(p.connect, '$3'); a.equal(p.tls, '$4'); a.equal(p.http, '$5');
    a.equal(p.resolved_ip, '93.184.216.34'); a.equal(typeof p.curl_exit_code, 'number');
    for (const k of ['time_connect_ms','time_appconnect_ms','time_starttransfer_ms','time_total_ms']) a.equal(typeof p[k], 'number');
    a.equal(r.cleanup.status, 'clean'); a.equal(r.production.unchanged, true);" "$WORK/out.json"
  assert_clean "$1"
  ok "classify $1 -> $2"
}
cases_2() {
expect_class success success ok ok ok
expect_class moved success ok ok ok
expect_class forbidden success ok ok ok
expect_class refused tcp_reset reset not_attempted not_attempted
expect_class unreachable connect_failure failed not_attempted not_attempted
expect_class connect_timeout connect_timeout timeout not_attempted not_attempted
# curl 8.19 reports a blackholed ClientHello exactly like a connect timeout;
# the SYN-ACK the target sent to the probe's port shows TCP was up.
expect_class tls_stall tls_failure ok timeout not_attempted
json 'const p = r.probes[0]; a.equal(p.syn_acks, 1); a.equal(p.connect_evidence, "syn_ack"); a.equal(p.curl_exit_code, 28);' "$WORK/out.json"
reset_state; export CURL_STUB_MODE=connect_timeout; run_probe multisplit 1
json 'const p = r.probes[0]; a.equal(p.syn_acks, 0); a.equal(p.connect_evidence, undefined);' "$WORK/out.json"
grep -qxF 'add rule inet ProkopAutotuneProbe replies ip saddr 93.184.216.34 tcp sport 443 tcp dport 61000-61063 tcp flags & (syn | ack) == syn | ack ct direction reply ct original ip saddr 203.0.113.10 counter comment "synack"' "$NFT_STATE/last.nft" ||
  fail "SYN-ACK counter of the probe rule missing: $(grep replies "$NFT_STATE/last.nft")"
assert_clean "connect timeout without SYN-ACK"
ok "a timeout with a SYN-ACK is a TLS timeout, without one a connect timeout"
# The control runs of an apply (AT-14): TCP handshakes only, through the same
# isolated direct path; an established connection is a success.
reset_state; export CURL_STUB_MODE=tls_timeout; iso run direct example.com 2 192.0.2.53 93.184.216.34 handshake
json 'a.equal(r.status, "completed", JSON.stringify(r)); a.equal(r.handshake, true); const p = r.probes[0];
  a.equal(p.class, "success"); a.equal(p.connect, "ok"); a.equal(p.handshake, true); a.equal(p.syn_acks, 1);' "$WORK/out.json"
args="$(cat "$STUB_LOG/curl.args")"
grep -qx -- 'ftp://example.com:443/' <<<"$args" || fail "handshake probe URL: $args"
grep -qx -- '=ftp' <<<"$args" || fail "handshake probe protocol: $args"
! grep -q -- 'https://' <<<"$args" || fail "a handshake probe sends a request"
grep -qx -- '61000-61063' <<<"$args" || fail "handshake probe without the dedicated source ports"
assert_clean "handshake"
reset_state; export CURL_STUB_MODE=connect_timeout; iso run direct example.com 1 192.0.2.53 93.184.216.34 handshake
json 'const p = r.probes[0]; a.equal(p.class, "connect_timeout"); a.equal(p.syn_acks, 0);' "$WORK/out.json"
reset_state; iso run multisplit example.com 1 192.0.2.53 93.184.216.34 handshake
json 'a.equal(r.status, "refused"); a.equal(r.reason, "invalid_mode");' "$WORK/out.json"
ok "handshake-only direct run for the apply's control"
}
cases_3() {
expect_class tls tls_failure ok failed not_attempted
expect_class tls_timeout tls_failure ok timeout not_attempted
expect_class reset tcp_reset ok reset not_attempted
expect_class http_transport http_transport_failure ok ok reset
expect_class empty_reply http_transport_failure ok ok failed
json 'a.equal(r.probes[0].http_status, 0); a.equal(r.probes[0].curl_exit_code, 52);' "$WORK/out.json"
ucode -L "$LIB" "$LIB/autotune/probe.uc" classify 6 0 0 0 "Could not resolve host" > "$WORK/c.json"
json 'a.equal(r.class, "dns_failure");' "$WORK/c.json"
# The probe stops reading after 64 KiB (--max-filesize): curl's 63 after a
# handshake and an HTTP status is a working transport; before them it is not.
ucode -L "$LIB" "$LIB/autotune/probe.uc" classify 63 0.03 0.06 200 "Exceeded the maximum allowed file size" > "$WORK/c.json"
json 'a.equal(r.class, "success"); a.equal(r.http, "ok");' "$WORK/c.json"
ucode -L "$LIB" "$LIB/autotune/probe.uc" classify 63 0.03 0 0 "Exceeded the maximum allowed file size" > "$WORK/c.json"
json 'a.notEqual(r.class, "success");' "$WORK/c.json"

# Success details and HTTP status as information only.
reset_state; export CURL_STUB_MODE=forbidden; run_probe multisplit 3
json '
a.equal(r.summary.successes, 3); a.equal(r.summary.success_rate, 1);
const p = r.probes[0]; a.equal(p.http_status, 403); a.equal(p.local_port, 61002); a.equal(p.time_appconnect_ms, 61);
a.equal(r.counters.probe_mark.packets, 15); a.equal(r.counters.probe.packets, 15); a.equal(r.counters.reinjected.packets, 9); a.equal(r.counters.unexpected.packets, 0);
a.ok(r.cleanup.actions.includes("probe_rule:released")); a.ok(r.teardown.quiet_before_creation.quiet); a.ok(r.teardown.quiet_before_removal.quiet);
a.equal(r.counters.queue.packets_queued, 21);
const steps = r.timeline.map((t) => t.step); a.deepEqual(steps, ["T0","T1","T2","T3","T4","T5","T6","T7","T8"]);
a.ok(!JSON.stringify(r).match(/cookie|authorization|set-cookie/i));
' "$WORK/out.json"
args="$(cat "$STUB_LOG/curl.args")"
grep -qx -- '--local-port' <<<"$args" || fail "curl without dedicated source ports"
grep -qx -- '61000-61063' <<<"$args" || fail "curl without the dedicated source-port range"
grep -qx -- 'example.com:443:93.184.216.34' <<<"$args" || fail "curl without pinned address"
grep -qx -- '/dev/null' <<<"$args" || fail "curl keeps the body"
grep -A1 -x -- '--max-filesize' <<<"$args" | grep -qx 65536 || fail "curl reads the whole answer"
! grep -qxE -- '-b|-c|-D|-H|-u|--cookie|--cookie-jar|--dump-header|-i|-v' <<<"$args" || fail "curl records headers or cookies"
grep -qx -- '@192.0.2.53' "$STUB_LOG/dig.args" || fail "dig not pinned to the upstream resolver"
batch="$(cat "$NFT_STATE/last.nft")"
grep -qx 'create table inet ProkopAutotuneProbe' <<<"$batch" || fail "table not created atomically"
grep -q 'type route hook output priority -151; policy accept;' <<<"$batch" || fail "wrong hook/priority"
[ "$(grep -c '^add rule' <<<"$batch")" = 6 ] || fail "unexpected rule count"
T='ip daddr 93.184.216.34 tcp dport 443 tcp sport 61000-61063'
expect_line() { sed -n "$1p" "$NFT_STATE/last.nft" | grep -qxF -- "$2" || fail "batch line $1: $(sed -n "$1p" "$NFT_STATE/last.nft")"; }
expect_line 2 'add chain inet ProkopAutotuneProbe premark { type route hook output priority -152; policy accept; }'
expect_line 3 "add rule inet ProkopAutotuneProbe premark $T meta mark 0x00000000 meta mark set 0x08000000 counter accept comment \"probe_mark\""
expect_line 4 'add chain inet ProkopAutotuneProbe output { type route hook output priority -151; policy accept; }'
expect_line 5 "add rule inet ProkopAutotuneProbe output $T meta mark 0x48000000 meta mark set 0x08000000 counter return comment \"reinjected\""
expect_line 6 "add rule inet ProkopAutotuneProbe output $T meta mark 0x40000000 meta mark set 0x08000000 counter return comment \"reinjected_bare\""
expect_line 7 "add rule inet ProkopAutotuneProbe output $T meta mark 0x08000000 counter queue num 4600 comment \"probe\""
expect_line 8 "add rule inet ProkopAutotuneProbe output $T counter drop comment \"unexpected\""
! grep -q '0x48000000 counter return\|& 0x40000000' <<<"$batch" || fail "an injected packet may leave the probe chain unnormalized"
grep -qxF "replace rule inet ProkopAutotuneProbe output handle 5 $T meta mark 0x08000000 counter accept comment \"released\"" "$NFT_STATE/release.nft" ||
  fail "the candidate queue is not released to the bypass before nfqws stops"
grep -qx 'ip -j route get 93.184.216.34 mark 0x08000000 ipproto tcp sport 61000 dport 443 uid 0' "$STUB_LOG/ip.log" || fail "route not resolved with the probe mark and tuple"
grep -qx 'ip -j route get 93.184.216.34 mark 0 ipproto tcp sport 61000 dport 443 uid 0' "$STUB_LOG/ip.log" || fail "socket route not compared"
! grep -q 'bypass' <<<"$batch" || fail "probe queue must fail closed (no bypass)"
ok "success record, counters, timeline and request hygiene"

# Control candidate: marked direct path, no nfqws.
reset_state; run_probe direct 1
json 'a.equal(r.status, "completed"); a.equal(r.counters.queue, undefined); a.ok(!r.timeline.some((t) => t.step === "T2"));' "$WORK/out.json"
sed -n '7p' "$NFT_STATE/last.nft" | grep -q 'meta mark 0x08000000 counter accept comment "probe"' || fail "control rule must not queue"
grep -q 'meta mark 0x08000000 counter accept comment "released"' "$NFT_STATE/release.nft" || fail "control candidate not released"
assert_clean "direct"
ok "direct control candidate"

# --- DNS -------------------------------------------------------------------
reset_state; export DIG_STUB_ANSWER='198.18.6.193\n10.0.0.1\n'; run_probe multisplit
json 'a.equal(r.status, "completed"); a.equal(r.reason, "dns_failure"); a.equal(r.probes[0].class, "dns_failure"); a.equal(r.probes[0].detail, "non_public_answer");' "$WORK/out.json"
[ ! -e "$NFT_STATE/last.nft" ] || fail "dns failure created nft state"
reset_state; export DIG_STUB_ANSWER=''; run_probe multisplit
json 'a.equal(r.probes[0].detail, "no_address");' "$WORK/out.json"
assert_clean "dns"
ok "dns failure"
}

cases_4() {
# --- failures during setup ---------------------------------------------
reset_state; export NFQWS_STUB_EXIT=1; run_probe multisplit
json 'a.equal(r.status, "failed"); a.equal(r.reason, "nfqws_start_failed"); a.equal(r.cleanup.status, "clean"); a.equal(r.probes.length, 0);' "$WORK/out.json"
assert_clean "nfqws failure"
ok "cleanup after nfqws failure"

reset_state; export NFQWS_STUB_NO_LISTENER=1; run_probe multisplit
json 'a.equal(r.reason, "nfqws_listener_missing"); a.equal(r.cleanup.status, "clean"); a.ok(r.cleanup.actions.includes("pidfile:stopped"));' "$WORK/out.json"
assert_clean "listener missing"
ok "cleanup after nfqws without queue listener"

reset_state; export NFT_STUB_FAIL_SETUP=1; run_probe multisplit
json 'a.equal(r.reason, "nft_setup_failed"); a.equal(r.cleanup.status, "clean"); a.ok(!r.cleanup.actions.some((x) => x.startsWith("pidfile")));' "$WORK/out.json"
assert_clean "nft setup failure"
ok "cleanup after nft setup failure"

reset_state; export CURL_STUB_MODE=connect_timeout; run_probe multisplit 3
json 'a.equal(r.status, "completed"); a.equal(r.summary.successes, 0); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "curl failure"
ok "cleanup after curl failure"

reset_state; export NFQWS_STUB_IGNORE_TERM=1; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.ok(r.cleanup.actions.includes("pidfile:killed"), r.cleanup.actions);' "$WORK/out.json"
assert_clean "term ignored"
ok "cleanup escalates to KILL for an identified nfqws"
}

cases_5() {
# --- preconditions -------------------------------------------------------
refused() {
  run_probe multisplit
  json "a.equal(r.status, 'refused'); a.equal(r.reason, '$1');" "$WORK/out.json"
  [ ! -e "$NFT_STATE/last.nft" ] || fail "$1 created nft state"
  pgrep -f "$WORK/bin/nfqws --qnum" >/dev/null && fail "$1 started nfqws"
  ok "refused: $1"
}
reset_state; queue_reset "$PROD_QUEUE_LINE" ' 4600  31337     0 2 65531     0     0        0  1'; refused queue_in_use
grep -q ' 4600  31337' "$PROKOP_AUTOTUNE_PROC_QUEUE" || fail "foreign queue listener was touched"
reset_state; printf 'table inet other {\n\tqueue to 4590-4610\n}\n' >> "$NFT_STATE/ruleset"; refused queue_referenced
reset_state; export PROKOP_AUTOTUNE_QUEUE=4001; refused queue_overlaps_prokop_range
reset_state; printf '32768\t61010\n' > "$PROKOP_AUTOTUNE_PORT_RANGE_FILE"; refused port_range_overlaps_ephemeral
reset_state; printf '   0: 0100007F:EE4D 01010101:01BB 01\n' >> "$WORK/proc_net/tcp"; refused port_range_in_use
reset_state; printf '   0: 0100007F:EE4D 01010101:01BB 06\n' >> "$WORK/proc_net/tcp"; run_probe multisplit 1
json 'a.equal(r.status, "completed");' "$WORK/out.json"; ok "TIME_WAIT leftovers accepted"
reset_state; touch "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard"; refused guard_active
[ -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] || fail "guard was removed"
reset_state; touch "$NFT_STATE/tables/ProkopTableDpiGuard"; refused guard_active
# The transition guard chain a failed sing-box transition keeps (UC-019).
reset_state; mkdir -p "$NFT_STATE/chains"; touch "$NFT_STATE/chains/ProkopTable.prokop_transition_guard"
refused guard_active
rm -f "$NFT_STATE/chains/ProkopTable.prokop_transition_guard"
reset_state; mkdir -p "$PROKOP_SNAPSHOT_LOCK_DIR"; refused snapshot_operation_in_progress

# --- stale state -----------------------------------------------------------
reset_state; touch "$NFT_STATE/tables/ProkopAutotuneProbe"; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.ok(r.recovered.includes("table:removed"));' "$WORK/out.json"
assert_clean "stale table"
ok "temporary table already exists"
reset_state; touch "$NFT_STATE/tables/ProkopAutotuneProbe"; export NFT_STUB_FAIL_DELETE=1; run_probe multisplit 1
json 'a.equal(r.status, "refused"); a.equal(r.reason, "stale_probe_state");' "$WORK/out.json"
unset NFT_STUB_FAIL_DELETE; iso cleanup
json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("table:removed"));' "$WORK/out.json"
assert_clean "stale table undeletable"
ok "undeletable stale table blocks the run"

stale_pid() {
  reset_state; mkdir -p "$PROKOP_AUTOTUNE_STATE_DIR"
  sleep 600 & local victim=$!; FOREIGN_PIDS+=("$victim")
  local ticks; ticks="$(ucode -L "$LIB" -e 'print(require("core.process_identity").start_ticks(ARGV[0]))' "$victim")"
  printf '%s\n%s\n' "$victim" "${1:-$ticks}" > "$PROKOP_AUTOTUNE_STATE_DIR/nfqws-4600.pid"
  printf '{"nfqws":[{"queue":4600,"argv":["%s","--qnum=4600","--dpi-desync-fwmark=0x40000000"]}]}\n' "$ZAPRET_NFQWS_BIN" > "$PROKOP_AUTOTUNE_STATE_DIR/active.json"
  iso cleanup
  json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("pidfile:stale"), r.actions);' "$WORK/out.json"
  kill -0 "$victim" || fail "cleanup killed an unrelated process ($2)"
  assert_clean "$2"
  ok "stale pid protection: $2"
}
stale_pid "" "PID reused by an unrelated process"
stale_pid 1 "start time mismatch"
reset_state; mkdir -p "$PROKOP_AUTOTUNE_STATE_DIR"; printf '999999\n1\n' > "$PROKOP_AUTOTUNE_STATE_DIR/nfqws-4600.pid"; iso cleanup
json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("pidfile:stale"));' "$WORK/out.json"
assert_clean "dead pid"; ok "stale pidfile of a dead process"
reset_state; iso cleanup; json 'a.equal(r.status, "clean"); a.deepEqual(r.actions, []);' "$WORK/out.json"
iso cleanup; json 'a.equal(r.status, "clean");' "$WORK/out.json"; ok "cleanup idempotent when nothing exists"

# An nfqws with the run signature that no run recorded (an admin's own nfqws
# on a run queue, say) is not ours: neither a run nor a cleanup signals it,
# and a run refuses while it exists (UC-053). Both name it, so the operator
# knows what to stop.
queue_released() { ! grep -q "^ $1 " "$PROKOP_AUTOTUNE_PROC_QUEUE"; }
foreign_on_run_queue() {
  local foreign
  reset_state
  [ "$1" = bound ] || export NFQWS_STUB_NO_LISTENER=1
  ( "$ZAPRET_NFQWS_BIN" --qnum=4600 --dpi-desync-fwmark=0x40000000 --filter-tcp=443 --dpi-desync=fake >/dev/null 2>&1 & )
  wait_until 30 nfqws_started "$WORK/bin/nfqws --qnum=4600" || fail "foreign nfqws double did not start"
  foreign="$(pgrep -f "$WORK/bin/nfqws --qnum=4600")"
  FOREIGN_PIDS+=("$foreign")
  unset NFQWS_STUB_NO_LISTENER
  run_probe multisplit 1
  json "a.equal(r.status, 'refused'); a.equal(r.reason, 'queue_in_use');
    a.deepEqual(r.blocking_nfqws, [{ pid: $foreign, queue: 4600 }]);" "$WORK/out.json"
  process_running "$foreign" || fail "a run signalled a foreign nfqws on its queue ($1)"
  [ ! -e "$NFT_STATE/tables/ProkopAutotuneProbe" ] || fail "a refused run created its table ($1)"
  iso cleanup
  json "a.equal(r.status, 'failed'); a.equal(r.verified.process_absent, false);
    a.deepEqual(r.verified.blocking_nfqws, [{ pid: $foreign, queue: 4600 }]);" "$WORK/out.json"
  process_running "$foreign" || fail "cleanup signalled a foreign nfqws on a run queue ($1)"
  kill "$foreign"
  wait_until 10 process_gone "$foreign" || fail "the foreign nfqws double did not exit"
  wait_until 10 queue_released 4600 || fail "the foreign nfqws double kept its queue"
  iso cleanup; json 'a.equal(r.status, "clean"); a.equal(r.verified.blocking_nfqws, undefined);' "$WORK/out.json"
  assert_clean "foreign nfqws ($1)"
  ok "foreign nfqws on a run queue ($1): refused, never signalled"
}
foreign_on_run_queue bound
foreign_on_run_queue unbound
# The run's own nfqws is found by its record even without active.json.
reset_state; mkdir -p "$PROKOP_AUTOTUNE_STATE_DIR"
( "$ZAPRET_NFQWS_BIN" --qnum=4600 --dpi-desync-fwmark=0x40000000 --filter-tcp=443 >/dev/null 2>&1 & )
wait_until 30 nfqws_started "$WORK/bin/nfqws --qnum=4600" || fail "recorded nfqws double did not start"
ucode -L "$LIB" "$LIB/core/pidfile_cli.uc" record "$(pgrep -f "$WORK/bin/nfqws --qnum=4600")" \
  "$PROKOP_AUTOTUNE_STATE_DIR/nfqws-4600.pid"
iso cleanup
json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("pidfile:stopped"), r.actions);' "$WORK/out.json"
assert_clean "recorded nfqws, active.json lost"; ok "recorded nfqws stopped without active.json"
# A candidate whose pidfile cannot be written is stopped at once: unrecorded,
# nothing would stop it later.
reset_state; mkdir -p "$PROKOP_AUTOTUNE_STATE_DIR/nfqws-4600.pid"
run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "nfqws_start_failed");' "$WORK/out.json"
! pgrep -f "$WORK/bin/nfqws --qnum" >/dev/null || fail "an unrecorded candidate nfqws was left running"
wait_until 10 queue_released 4600 || fail "the unrecorded candidate kept its queue"
rmdir "$PROKOP_AUTOTUNE_STATE_DIR/nfqws-4600.pid"; iso cleanup
assert_clean "unrecorded candidate"; ok "a candidate that could not be recorded is stopped"
# A production-like nfqws on another queue is never an orphan.
( "$ZAPRET_NFQWS_BIN" --qnum=4000 --dpi-desync-fwmark=0x40000000 >/dev/null 2>&1 & )
wait_until 30 nfqws_started "$WORK/bin/nfqws --qnum=4000" || fail "production-queue nfqws double did not start"
iso cleanup
pgrep -f "$WORK/bin/nfqws --qnum=4000" >/dev/null || fail "production-queue nfqws was killed"
pkill -f "$WORK/bin/nfqws --qnum=4000"; ok "production-queue nfqws ignored by orphan scan"

# --- interruption ----------------------------------------------------------
wait_active() {
  for _ in $(seq 1 50); do
    [ -e "$NFT_STATE/tables/ProkopAutotuneProbe" ] && pgrep -f "$WORK/bin/nfqws --qnum" >/dev/null && return 0
    sleep 0.1
  done
  fail "probe run did not become active"
}
reset_state; export CURL_STUB_SLEEP=1
ucode -L "$LIB" "$LIB/autotune/isolation.uc" run multisplit example.com 2 192.0.2.53 > "$WORK/first.json" &
runner=$!; wait_active
iso run multisplit example.com 1 192.0.2.53
json 'a.equal(r.status, "busy"); a.equal(r.reason, "autotune_in_progress");' "$WORK/out.json"
wait "$runner" || true
json 'a.equal(r.status, "completed"); a.equal(r.cleanup.status, "clean");' "$WORK/first.json"
assert_clean "concurrent run"
ok "second run refused while a run is active"

reset_state; export CURL_STUB_SLEEP=2
ucode -L "$LIB" "$LIB/autotune/isolation.uc" run multisplit example.com 3 192.0.2.53 > "$WORK/out.json" &
runner=$!
wait_active
kill -TERM "$runner"; wait "$runner" || true
json 'a.equal(r.status, "interrupted"); a.equal(r.reason, "interrupted"); a.equal(r.cleanup.status, "clean"); a.ok(r.probes.length < 3);' "$WORK/out.json"
assert_clean "SIGTERM"
ok "interrupted probe (SIGTERM) tears down"

reset_state; export CURL_STUB_SLEEP=2
ucode -L "$LIB" "$LIB/autotune/isolation.uc" run multisplit example.com 3 192.0.2.53 > "$WORK/out.json" &
runner=$!
wait_active
kill -KILL "$runner"; wait "$runner" 2>/dev/null || true
[ -e "$NFT_STATE/tables/ProkopAutotuneProbe" ] || fail "SIGKILL scenario did not leave state"
pkill -f "$WORK/bin/curl" 2>/dev/null || true
unset CURL_STUB_SLEEP; iso cleanup
json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("pidfile:stopped")); a.ok(r.actions.includes("table:removed"));' "$WORK/out.json"
assert_clean "SIGKILL"
ok "killed run recovered by cleanup (stale lock reclaimed)"
}

# --- production bypass contract (checked before any probe path exists) -----
no_probe_path() {
  [ ! -e "$NFT_STATE/last.nft" ] || fail "$1: probe path created"
  ! pgrep -f "$WORK/bin/nfqws --qnum" >/dev/null || fail "$1: nfqws started"
  assert_clean "$1"
}
cases_6() {
reset_state; mutate_ruleset "$NFT_STATE/ruleset.json" remove-bypass; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.equal(r.reason, "isolation_unavailable"); a.equal(r.isolation.unavailable, "bypass_contract");
  a.ok(r.contract.violations.some((v) => v.code === "bypass_rule_missing")); a.equal(r.probes.length, 0); a.equal(r.timeline.length, 0);' "$WORK/out.json"
no_probe_path "bypass missing"
ok "missing production bypass: refused before creating the probe path"
reset_state; mutate_ruleset "$NFT_STATE/tables/ProkopTable" remove-bypass; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.equal(r.isolation.unavailable, "bypass_contract_changed");' "$WORK/out.json"
no_probe_path "snapshot contract"
ok "production table changed after the contract check: refused"
reset_state; export IP_STUB_ROUTE_LOCAL=1; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.equal(r.isolation.unavailable, "probe_route_local"); a.equal(r.target.route.dev, "lo");' "$WORK/out.json"
no_probe_path "local route"
ok "probe mark routed locally: refused"
reset_state; export IP_STUB_RULE_FAIL=1; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.ok(r.contract.violations.some((v) => v.code === "ip_rules_unavailable"));' "$WORK/out.json"
no_probe_path "ip rules unavailable"
ok "policy rules unavailable: refused"
reset_state; export NFT_STUB_FAIL_RULESET=1; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.ok(r.contract.violations.some((v) => v.code === "production_table_absent"));' "$WORK/out.json"
no_probe_path "ruleset unavailable"
ok "ruleset unavailable: refused"
reset_state; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.equal(r.contract.ok, true); a.equal(r.contract.bypass.length, 1);
  a.equal(r.contract.bypass[0].chain, "ProkopTable/mangle_output"); a.equal(r.target.route.dev, "pppoe-wan");
  a.deepEqual(r.isolation.rules.map((x) => x.chain + "/" + x.comment), ["premark/probe_mark", "output/reinjected", "output/reinjected_bare", "output/probe", "output/unexpected", "replies/synack"]);
  a.equal(r.target.route.unmarked.dev, "pppoe-wan"); a.deepEqual(r.contract.sets, { prokop_interfaces: ["br-lan"] });' "$WORK/out.json"
ok "contract and route recorded for a completed run"

# --- teardown: drain and hold ---------------------------------------------
reset_state; export CURL_STUB_UNEXPECTED=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "unexpected_probe_packets"); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "unexpected"
ok "packets outside the modelled paths fail the run"
reset_state; export CURL_STUB_PENDING=2 PROKOP_AUTOTUNE_DRAIN_TIMEOUT=6; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.equal(r.teardown.drain.settled, true); a.ok(r.teardown.drain.waited_s >= 1);' "$WORK/out.json"
assert_clean "pending"
ok "drain waits for queued verdicts before stopping nfqws"
reset_state; export CURL_STUB_PENDING=forever; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.equal(r.teardown.drain.settled, false); a.equal(r.teardown.drain.queue_pending, 1); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "pending timeout"
ok "drain timeout proceeds to the release and teardown"
# TIME_WAIT outlasts the drain and the nfqws stop by seconds, so a slow runner
# still finds a socket when the hold starts.
reset_state; export CURL_STUB_SOCKET=6 CURL_STUB_CLOSING=2 PROKOP_AUTOTUNE_DRAIN_TIMEOUT=6 PROKOP_AUTOTUNE_HOLD_TIMEOUT=12; run_probe multisplit 1
json '
a.equal(r.status, "completed");
a.equal(r.teardown.drain.settled, true); a.ok(r.teardown.drain.waited_s >= 1, "drain waited for the closing socket");
a.equal(r.teardown.hold.settled, true); a.ok(r.teardown.hold.waited_s >= 1, "table held while TIME_WAIT sockets exist");
const t6 = r.timeline.find((t) => t.step === "T6"), t7 = r.timeline.find((t) => t.step === "T7");
a.ok(r.timeline.indexOf(t6) < r.timeline.indexOf(t7), "nfqws stopped before the table is removed");
a.ok(r.cleanup.actions.indexOf("pidfile:stopped") < r.cleanup.actions.indexOf("hold:settled"));
a.ok(r.cleanup.actions.indexOf("hold:settled") < r.cleanup.actions.indexOf("table:removed"));
a.equal(typeof r.teardown.counters_at_stop.probe.packets, "number"); a.equal(typeof r.teardown.counters_at_removal.released.packets, "number"); a.equal(r.teardown.counters_at_removal.probe, undefined);
' "$WORK/out.json"
assert_clean "hold"
ok "table kept (drop-only) until the probe sockets are gone, then removed"
}
cases_7() {
reset_state; export CURL_STUB_SOCKET=30 PROKOP_AUTOTUNE_HOLD_TIMEOUT=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "isolation_hold_timeout"); a.equal(r.teardown.hold.settled, false);
  a.ok(r.cleanup.actions.includes("hold:timeout")); a.ok(r.cleanup.actions.includes("table:kept")); a.equal(r.cleanup.status, "failed");' "$WORK/out.json"
[ -e "$NFT_STATE/tables/ProkopAutotuneProbe" ] || fail "table removed while probe sockets are alive"
[ -e "$NFT_STATE/released" ] || fail "kept table still queues to the stopped candidate"
[ -e "$PROKOP_AUTOTUNE_STATE_DIR/active.json" ] || fail "recovery data dropped with the table kept"
iso cleanup; json 'a.equal(r.status, "failed"); a.ok(r.actions.includes("table:kept"));' "$WORK/out.json"
sed -i '/22D8B85D:01BB/d' "$WORK/proc_net/tcp"
iso cleanup; json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("probe_rule:already_released")); a.ok(r.actions.includes("table:removed"));' "$WORK/out.json"
assert_clean "hold timeout"
ok "hold timeout keeps the released table until a later cleanup finds no probe socket"

# --- review follow-ups ------------------------------------------------------
reset_state; export IP_STUB_ROUTE_DIFFERS=1; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.equal(r.isolation.unavailable, "probe_route_differs_from_socket_route");' "$WORK/out.json"
no_probe_path "route differs"
ok "probe-mark route differing from the socket route: refused"
reset_state; printf 'mangle\n' > "$WORK/proc_net/ip_tables_names"; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.ok(r.contract.violations.some((v) => v.code === "legacy_iptables_present"));' "$WORK/out.json"
no_probe_path "legacy iptables"
ok "legacy iptables tables loaded: refused"
reset_state; export NFT_STUB_INTERFACES='["br-lan","pppoe-wan"]'; run_probe multisplit 1
json 'a.equal(r.status, "unsupported"); a.ok(r.contract.violations.some((v) => v.code === "reply_path_unsafe"));' "$WORK/out.json"
no_probe_path "reply path"
ok "replies classified by production (WAN in prokop_interfaces): refused"
reset_state; export CURL_STUB_MODE=alternate; run_probe multisplit 3
json 'a.equal(r.status, "completed"); a.equal(r.summary.successes, 2); a.ok(Math.abs(r.summary.success_rate - 2 / 3) < 1e-9, String(r.summary.success_rate));' "$WORK/out.json"
ok "partial success rate is fractional"
reset_state; export NFT_STUB_FAIL_PROBE_LISTING=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "counters_unavailable");' "$WORK/out.json"
unset NFT_STUB_FAIL_PROBE_LISTING; iso cleanup; assert_clean "counters unavailable"
ok "unreadable counters fail the run"
reset_state; export NFT_STUB_FAIL_REPLACE=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.ok(r.cleanup.actions.includes("probe_rule:failed")); a.equal(r.cleanup.status, "failed");' "$WORK/out.json"
unset NFT_STUB_FAIL_REPLACE; iso cleanup; assert_clean "release failure"
ok "failed release of the candidate queue is reported, cleanup recovers"
}
cases_8() {
reset_state; export CURL_STUB_SOCKET=4 PROKOP_AUTOTUNE_HOLD_TIMEOUT=10
ucode -L "$LIB" "$LIB/autotune/isolation.uc" run multisplit example.com 1 192.0.2.53 > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 100); do [ -e "$NFT_STATE/released" ] && break; sleep 0.1; done
sleep 1.5
kill -TERM "$runner"; wait "$runner" || true
json 'a.equal(r.status, "interrupted"); a.equal(r.teardown.hold.settled, true); a.ok(r.teardown.hold.waited_s >= 1, "hold continued after the signal"); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "SIGTERM during hold"
ok "a signal during teardown does not cut the hold short"
reset_state; mkdir -p "$PROKOP_AUTOTUNE_STATE_DIR"; touch "$NFT_STATE/tables/ProkopAutotuneProbe"
echo 93.184.216.34 > "$NFT_STATE/probe.target"; for c in probe_mark reinjected reinjected_bare probe unexpected; do echo "0 0" > "$NFT_STATE/counters/$c"; done
printf '{broken' > "$PROKOP_AUTOTUNE_STATE_DIR/active.json"; iso cleanup
json 'a.equal(r.status, "clean"); a.ok(r.actions.includes("hold:settled"), r.actions); a.ok(r.actions.includes("table:removed"));' "$WORK/out.json"
assert_clean "malformed active"
ok "malformed active.json: target recovered from the table itself"
reset_state; cp "$ZAPRET_NFQWS_BIN" "$WORK/nfqws-other"
( "$WORK/nfqws-other" --qnum=4600 --dpi-desync-fwmark=0x40000000 >/dev/null 2>&1 & )
wait_until 30 nfqws_started "$WORK/nfqws-other" || fail "nfqws double with another binary path did not start"
iso cleanup
pgrep -f "$WORK/nfqws-other" >/dev/null || fail "an nfqws with another binary path was treated as an orphan"
pkill -f "$WORK/nfqws-other"; ok "orphan scan requires the exact binary path"
reset_state; export PROKOP_AUTOTUNE_QUEUE=4001
for m in cleanup status; do
  iso "$m"; json 'a.equal(r.status, "refused"); a.equal(r.reason, "queue_overlaps_prokop_range");' "$WORK/out.json"
done
ok "a production queue number is refused by every mode"
unset PROKOP_AUTOTUNE_QUEUE
cat > "$WORK/ipfrag.uc" <<'UC'
let c = require("autotune.catalog");
print(sprintf("%J
", c.validate_entry({ id: "x", family: "f", protocol: "tcp", port: 443, rank: 9,
    nfqws_opt: "--filter-tcp=443 --dpi-desync=fake,ipfrag2" })));
UC
ucode -L "$LIB" "$WORK/ipfrag.uc" > "$WORK/c.json"
json 'a.equal(r.state, "unsupported"); a.equal(r.reason, "ipfrag_unsupported_by_isolation");' "$WORK/c.json"
ok "ipfrag candidates are unsupported by the isolation"
reset_state; export PROKOP_AUTOTUNE_QUIET_TIMEOUT=0
printf '%s\n 4300  777     2 2 65531     0     0       10  1\n' "$PROD_QUEUE_LINE" > "$PROKOP_AUTOTUNE_PROC_QUEUE"; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "production_queue_busy"); a.equal(r.teardown.quiet_before_creation.pending, 2);' "$WORK/out.json"
[ ! -e "$NFT_STATE/last.nft" ] || fail "hooks registered while production packets were queued"
ok "production packets waiting in an NFQUEUE: no hook registration"
reset_state; export CURL_STUB_QUEUED=3; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "candidate_bypassed"); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "fail-open"
ok "queue fail-open (probe packets not queued) invalidates the run"
reset_state; export CURL_STUB_ROUTE_CHANGE=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "production_changed"); a.notDeepEqual(r.production.before.route, r.production.after.route);' "$WORK/out.json"
assert_clean "route change"
ok "a routing change during the run is detected"

# --- production integrity ---------------------------------------------------
reset_state; export CURL_STUB_TOUCH_PROD=1; run_probe multisplit 1
json 'a.equal(r.status, "failed"); a.equal(r.reason, "production_changed"); a.equal(r.production.unchanged, false);
  a.notEqual(r.production.before.prokop_table_hash, r.production.after.prokop_table_hash); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "prod mismatch"
ok "production nft hash mismatch detected"
reset_state; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.equal(r.production.unchanged, true); a.match(r.production.before.prokop_table_hash, /^[0-9a-f]{64}$/);
  a.deepEqual(r.production.before.queues, ["4000:29676"]); a.equal(r.production.before.zapret_children.length, 1);' "$WORK/out.json"
ok "live counter changes are not a production change"
# The pid of a candidate is the shell's fork until it execs nfqws; a start
# seen before the exec waits for it instead of failing the run.
mkdir -p "$WORK/real" && mv "$WORK/bin/nfqws" "$WORK/real/nfqws"
printf '#!/bin/bash\nsleep 1.5\nexec -a "%s" "%s" "$@"\n' "$WORK/bin/nfqws" "$WORK/real/nfqws" >"$WORK/bin/nfqws"
chmod +x "$WORK/bin/nfqws"
reset_state; run_probe multisplit 1
json 'a.equal(r.status, "completed"); a.equal(r.cleanup.status, "clean");' "$WORK/out.json"
assert_clean "slow exec"
mv "$WORK/real/nfqws" "$WORK/bin/nfqws"
ok "a candidate still in its shell before the exec is waited for"
}

# The groups of cases run at once, each on stand-ins of its own (a fresh
# $WORK from autotune_stubs.sh): a probe run waits whole seconds at its
# steps, so one after another they took minutes.
GROUP_DIR="$WORK/case-groups"
case_group() {
  # shellcheck source=tests/helpers/autotune_stubs.sh
  . "$ROOT/tests/helpers/autotune_stubs.sh"
  "cases_$1"
  printf '%s\n' "$pass" >"$GROUP_DIR/$1.count"
}
run_case_groups "$GROUP_DIR" case_group 1 2 3 4 5 6 7 8
for group in 1 2 3 4 5 6 7 8; do
  pass=$((pass + $(cat "$GROUP_DIR/$group.count")))
done

printf 'autotune_isolation: PASS (%d checks)\n' "$pass"
