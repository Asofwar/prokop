# shellcheck shell=bash
# Shared stand-ins for the DPI autotune suites (sourced after ROOT and LIB are
# set): nft, curl, dig, ip and a real nfqws binary, plus production stand-ins
# that every scenario must leave untouched. Process identity, pidfiles and
# the run lock stay real.
# shellcheck source=tests/helpers/owned_processes.sh
. "$(dirname "${BASH_SOURCE[0]}")/owned_processes.sh"
WORK="$(mktemp -d)"
FOREIGN_PIDS=()
cleanup_test() {
  local deadline=$((SECONDS + 10))
  owned_kill KILL "${FOREIGN_PIDS[@]}" || true
  pkill -9 -f "$WORK/bin/nfqws" 2>/dev/null || true
  # The queue watchers of the killed stand-ins still rewrite the queue file
  # under its lock file: removing $WORK under them fails, or leaves the lock
  # file they recreate behind in a stray directory.
  while pgrep -f "$WORK/nfnetlink_queue" >/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
  rm -rf "$WORK"
}
trap cleanup_test EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/nft/tables" "$WORK/nft/counters" "$WORK/proc_net" "$WORK/child-pid" "$WORK/log"
export PROKOP_LIB="$LIB"
export PROKOP_AUTOTUNE_STATE_DIR="$WORK/run/autotune"
export PROKOP_AUTOTUNE_PROC_QUEUE="$WORK/nfnetlink_queue"
export PROKOP_AUTOTUNE_PORT_RANGE_FILE="$WORK/ip_local_port_range"
export PROKOP_AUTOTUNE_PROC_NET="$WORK/proc_net"
export PROKOP_AUTOTUNE_CURL="$WORK/bin/curl"
export PROKOP_AUTOTUNE_DIG="$WORK/bin/dig"
export PROKOP_AUTOTUNE_LISTENER_WAIT=2
export PROKOP_AUTOTUNE_DRAIN_TIMEOUT=1 PROKOP_AUTOTUNE_HOLD_TIMEOUT=2
FIXTURES="$ROOT/tests/fixtures/autotune"
export PROKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export ZAPRET_NFQWS_BIN="$WORK/bin/nfqws"
export ZAPRET_CHILD_PID_DIR="$WORK/child-pid"
export NFT_STATE="$WORK/nft" STUB_LOG="$WORK/log"
export PATH="$WORK/bin:$PATH"
PROD_QUEUE_LINE=" 4000  29676     0 2 65531     0     0       51  1"
export NFQWS_STUB_QUEUE_FILE="$PROKOP_AUTOTUNE_PROC_QUEUE"

# nfqws stand-in: a real binary named nfqws so /proc identity checks apply.
# It binds the queue of its --qnum (a line in the queue file) and a watcher
# releases that line when it dies, as the kernel would. The watcher learns of
# the death from the end of a pipe that only the stand-in holds open (the
# kernel closes it when the process exits, a zombie included) instead of
# polling for it: the stand-ins of a case live for seconds, and a watcher that
# polled every 50 ms with two forks per round took more CPU than the case.
cat > "$WORK/nfqws.c" <<'C'
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  const char *reject = getenv("NFQWS_STUB_REJECT");
  for (int i = 1; i < argc; i++)
    if (!strcmp(argv[i], "--dry-run")) {
      for (int j = 1; j < argc; j++) if (reject && *reject && strstr(argv[j], reject)) return 1;
      return 0;
    }
  if (getenv("NFQWS_STUB_EXIT")) return 1;
  const char *qfile = getenv("NFQWS_STUB_QUEUE_FILE");
  int queue = 4600;
  for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "--qnum=", 7)) queue = atoi(argv[i] + 7);
  if (getenv("NFQWS_STUB_IGNORE_TERM")) signal(SIGTERM, SIG_IGN);
  if (qfile && !getenv("NFQWS_STUB_NO_LISTENER")) {
    /* The kernel binds and releases a queue atomically: a signal between
       adding the queue line and starting its watcher would leave the line
       behind, so signals wait until both are done. */
    sigset_t all, old;
    sigfillset(&all);
    sigprocmask(SIG_BLOCK, &all, &old);
    /* Queue-file edits are serialized: stand-ins and the curl stub rewrite it. */
    char add[1024];
    snprintf(add, sizeof add, "flock '%s.lock' sh -c 'printf \" %%d %%8d     0 2 65531     0     0 %%8d  1\\n\" %d %d 0 >> \"%s\"'", qfile, queue, getpid(), qfile);
    if (system(add) != 0) return 1;
    char script[1024];
    snprintf(script, sizeof script, "cat >/dev/null; flock '%s.lock' sed -i '/^ %d  *%d /d' '%s'", qfile, queue, getpid(), qfile);
    int alive[2];
    if (pipe(alive) != 0) return 1;
    if (fork() == 0) {
      /* The watcher reads until the stand-in, the only writer, has exited. */
      close(alive[1]); dup2(alive[0], 0); close(alive[0]);
      sigprocmask(SIG_SETMASK, &old, NULL); setsid(); execl("/bin/sh", "sh", "-c", script, (char *)0); _exit(1);
    }
    close(alive[0]);
    fcntl(alive[1], F_SETFD, FD_CLOEXEC);
    sigprocmask(SIG_SETMASK, &old, NULL);
  }
  for (;;) pause();
}
C
cc -O0 -o "$WORK/bin/nfqws" "$WORK/nfqws.c"

# nft stand-in. The probe rules (handles from 5 on: one for a probe run, one
# per port slice for a tuning run) are kept in $S/rules as "handle comment
# queue first-port last-port"; replaces update them and reset their counter,
# as a new rule.
cat > "$WORK/bin/nft" <<'SH'
#!/usr/bin/env bash
S="$NFT_STATE"; T="$S/tables"
echo "nft $*" >> "$STUB_LOG/nft.log"
# probe_rule LINE: "comment queue first last" of an output probe rule.
probe_rule() {
  local comment queue sport
  comment="$(sed -n 's/.* comment "\([a-z_:]*\)".*/\1/p' <<<"$1")"
  queue="$(sed -n 's/.* queue num \([0-9]*\) .*/\1/p' <<<"$1")"
  sport="$(sed -n 's/.* tcp sport \([0-9]*\)-\([0-9]*\) .*/\1 \2/p' <<<"$1")"
  echo "$comment ${queue:--} $sport"
}
# The SYN-ACK counter of a probe rule: "synack" or "synack:<id>".
synack_of() { case "$1" in *:*) echo "synack:${1#*:}" ;; *) echo synack ;; esac; }
case "$*" in
  "list tables") for t in "$T"/*; do [ -e "$t" ] && echo "table inet ${t##*/}"; done; exit 0 ;;
  "list table inet "*) [ -e "$T/$4" ]; exit ;;
  # A chain of a table: $S/chains/<table>.<chain>.
  "list chain inet "*) [ -e "$S/chains/$4.$5" ]; exit ;;
  "-j list table inet "*)
    [ -e "$T/$5" ] || exit 1
    if [ "$5" = ProkopAutotuneProbe ]; then
      [ -z "${NFT_STUB_FAIL_PROBE_LISTING:-}" ] || exit 1
      target="$(cat "$S/probe.target" 2>/dev/null)"
      # A table a test left without a batch: one probe rule, as a run creates.
      [ -e "$S/rules" ] || echo "5 probe - 61000 61063" > "$S/rules"
      rule() {
        local p b sport=""
        [ -e "$S/counters/$2" ] || echo "0 0" > "$S/counters/$2"
        read -r p b < "$S/counters/$2"
        [ -z "${4:-}" ] || sport="$(printf ',{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"sport"}},"right":{"range":[%s,%s]}}}' "$4" "$5")"
        printf '{"rule":{"family":"inet","table":"ProkopAutotuneProbe","chain":"%s","handle":%s,"comment":"%s","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":"%s"}}%s,{"counter":{"packets":%s,"bytes":%s}}]}}' "$1" "$3" "$2" "$target" "$sport" "$p" "$b"
      }
      out="$(rule premark probe_mark 2),$(rule output reinjected 3),$(rule output reinjected_bare 4)"
      last=4
      while read -r handle comment _ first lastport; do
        out="$out,$(rule output "$comment" "$handle" "$first" "$lastport")"; last="$handle"
      done < "$S/rules"
      out="$out,$(rule output unexpected $((last + 1)))"
      # The SYN-ACK counters of the reply chain, one per probe rule.
      handle=$((last + 2))
      while read -r _ comment _; do
        out="$out,$(rule replies "$(synack_of "$comment")" "$handle")"; handle=$((handle + 1))
      done < "$S/rules"
      printf '{"nftables":[{"table":{"family":"inet","name":"ProkopAutotuneProbe","handle":90}},%s]}\n' "$out"
    else cat "$T/$5"; fi
    exit 0 ;;
  "list ruleset") cat "$S/ruleset"; [ -e "$T/ProkopAutotuneProbe" ] && echo "queue to 4600"; exit 0 ;;
  "-j -t list ruleset") [ -z "${NFT_STUB_FAIL_RULESET:-}" ] || exit 1; cat "$S/ruleset.json"; exit 0 ;;
  "-j list set inet ProkopTable prokop_interfaces")
    printf '{"nftables":[{"set":{"family":"inet","name":"prokop_interfaces","table":"ProkopTable","type":"ifname","elem":%s}}]}\n' "${NFT_STUB_INTERFACES:-[\"br-lan\"]}"; exit 0 ;;
  "-f "*)
    if grep -q '^replace rule inet ProkopAutotuneProbe output handle ' "$2"; then
      [ -z "${NFT_STUB_FAIL_REPLACE:-}" ] || exit 1
      file="$2"
      while read -r line; do
        handle="$(sed -n 's/^replace rule inet ProkopAutotuneProbe output handle \([0-9]*\) .*/\1/p' <<<"$line")"
        grep -q "^$handle " "$S/rules" || exit 1
        rule="$(probe_rule "$line")"
        sed -i "s/^$handle .*/$handle $rule/" "$S/rules"
        read -r comment queue _ <<<"$rule"
        echo "$comment $queue" >> "$STUB_LOG/switch.log"
        echo "0 0" > "$S/counters/$comment"
        case "$comment" in released*) cp "$file" "$S/release.nft"; touch "$S/released" ;; esac
      done < "$file"
      exit 0
    fi
    [ -z "${NFT_STUB_FAIL_SETUP:-}" ] || exit 1
    grep -q '^create table inet ProkopAutotuneProbe$' "$2" && [ -e "$T/ProkopAutotuneProbe" ] && exit 1
    cp "$2" "$S/last.nft"; touch "$T/ProkopAutotuneProbe"; rm -f "$S/released"
    sed -n 's/.* ip daddr \([0-9.]*\) .*/\1/p' "$2" | head -n 1 > "$S/probe.target"
    : > "$S/rules"; handle=5
    while read -r line; do
      echo "$handle $(probe_rule "$line")" >> "$S/rules"; handle=$((handle + 1))
    done < <(grep ' output .*meta mark 0x08000000 counter .*comment ' "$2")
    rm -f "$S/counters/"*
    for c in probe_mark reinjected reinjected_bare unexpected; do echo "0 0" > "$S/counters/$c"; done
    while read -r _ comment _; do echo "0 0" > "$S/counters/$comment"; done < "$S/rules"
    exit 0 ;;
  "delete table inet "*) [ -z "${NFT_STUB_FAIL_DELETE:-}" ] || exit 1; rm -f "$T/$4" "$S/rules"; exit 0 ;;
esac
exit 1
SH

# curl stand-in: prints the -w record for the requested scenario and emulates
# the probe traffic in the stub counters and queue statistics of the rule the
# probe currently goes through. CURL_STUB_PLAN selects outcomes per candidate
# key ("direct" or the queue number): "direct=reset,4600=success:180" or a
# per-call sequence "4601=success|reset|success"; ":<ms>" sets the TLS time.
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_LOG/curl.args"
ip="$(printf '%s\n' "$@" | sed -n 's/^[^:]*:443:\(.*\)$/\1/p')"
bump() { local p b; read -r p b < "$NFT_STATE/counters/$1" 2>/dev/null || { p=0; b=0; }; echo "$((p + $2)) $((b + $2 * 80))" > "$NFT_STATE/counters/$1"; }
key=none
if [ -e "$NFT_STATE/tables/ProkopAutotuneProbe" ]; then
  # The probe rule of the source ports curl leaves from.
  ports="$(printf '%s\n' "$@" | sed -n '/^--local-port$/{n;p;}')"
  comment=probe; queue=-
  while read -r _ c q first last; do
    [ "$first-$last" = "$ports" ] || [ "$(wc -l < "$NFT_STATE/rules")" = 1 ] || continue
    comment="$c"; queue="$q"; break
  done < "$NFT_STATE/rules"
  key="${comment%%:*}"; [ "$queue" = - ] || key="$queue"
  printf '%s\n' "$ports" >> "$STUB_LOG/curl.ports"
  bump probe_mark 5; bump "$comment" 5
  [ "$queue" = - ] || bump reinjected 3
  [ -z "${CURL_STUB_UNEXPECTED:-}" ] || bump unexpected 1
  if [ "$queue" != - ]; then
    (
      flock 9
      awk -v q="$queue" -v n="${CURL_STUB_QUEUED:-7}" '$1 == q { printf " %d %8d %5d %d %5d %5d %5d %8d  %d\n", $1, $2, $3, $4, $5, $6, $7, $8 + n, $9; next } { print }' \
        "$PROKOP_AUTOTUNE_PROC_QUEUE" > "$PROKOP_AUTOTUNE_PROC_QUEUE.tmp" && mv "$PROKOP_AUTOTUNE_PROC_QUEUE.tmp" "$PROKOP_AUTOTUNE_PROC_QUEUE"
    ) 9>"$PROKOP_AUTOTUNE_PROC_QUEUE.lock"
  fi
  [ -z "${CURL_STUB_ROUTE_CHANGE:-}" ] || touch "$NFT_STATE/route.changed"
  if [ -n "${CURL_STUB_PENDING:-}" ]; then
    sed -i "s/^\( 4600 *[0-9]* *\)0 /\11 /" "$PROKOP_AUTOTUNE_PROC_QUEUE"
    # Only the subshell is backgrounded; it must not hold curl's stdout open.
    if [ "$CURL_STUB_PENDING" != forever ]; then
      ( sleep "$CURL_STUB_PENDING"; sed -i "s/^\( 4600 *[0-9]* *\)1 /\10 /" "$PROKOP_AUTOTUNE_PROC_QUEUE" ) >/dev/null 2>&1 &
    fi
  fi
fi
echo "$key $ip" >> "$STUB_LOG/curl.seq"
# Sockets of the probe tuple (target 93.184.216.34:443 from port 61000):
# optionally closing first, then TIME_WAIT until they expire.
if [ -n "${CURL_STUB_SOCKET:-}" ]; then
  state=06; [ -z "${CURL_STUB_CLOSING:-}" ] || state=04
  printf '   9: 0A00000A:EE48 22D8B85D:01BB %s 00000000:00000000\n' "$state" >> "$PROKOP_AUTOTUNE_PROC_NET/tcp"
  (
    [ -z "${CURL_STUB_CLOSING:-}" ] || { sleep "$CURL_STUB_CLOSING"; sed -i 's/22D8B85D:01BB 04/22D8B85D:01BB 06/' "$PROKOP_AUTOTUNE_PROC_NET/tcp"; }
    sleep "$CURL_STUB_SOCKET"; sed -i '/22D8B85D:01BB/d' "$PROKOP_AUTOTUNE_PROC_NET/tcp"
  ) >/dev/null 2>&1 &
fi
# Live production traffic moves counters but not the table structure.
sed -i 's/"packets": *[0-9]*/"packets": 999/' "$NFT_STATE/tables/ProkopTable"
[ -z "${CURL_STUB_TOUCH_PROD:-}" ] || sed -i 's/"handle": 48/"handle": 49/' "$NFT_STATE/tables/ProkopTable"
[ -z "${CURL_STUB_SLEEP:-}" ] || sleep "$CURL_STUB_SLEEP"
mode="${CURL_STUB_MODE:-success}"
if [ "$mode" = alternate ]; then
  n=$(( $(cat "$STUB_LOG/curl.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_LOG/curl.count"
  mode=success; [ $((n % 3)) -ne 0 ] || mode=reset
fi
tls=61
if [ -n "${CURL_STUB_PLAN:-}" ]; then
  spec="$(tr ',' '\n' <<<"$CURL_STUB_PLAN" | sed -n "s/^$key=//p" | head -n 1)"
  if [ -n "$spec" ]; then
    n=$(( $(cat "$STUB_LOG/plan.$key" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_LOG/plan.$key"
    steps=$(tr '|' '\n' <<<"$spec" | wc -l)
    spec="$(tr '|' '\n' <<<"$spec" | sed -n "$(( (n - 1) % steps + 1 ))p")"
    mode="${spec%%:*}"; [ "$spec" = "$mode" ] || tls="${spec#*:}"
  fi
fi
# CURL_STUB_KILL_AT=<n>: the n-th call kills the temporary nfqws of queue
# 4600 (it dies while another candidate is probed).
if [ -n "${CURL_STUB_KILL_AT:-}" ]; then
  k=$(( $(cat "$STUB_LOG/kill.count" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$STUB_LOG/kill.count"
  [ "$k" != "$CURL_STUB_KILL_AT" ] || kill -9 "$(head -n 1 "$PROKOP_AUTOTUNE_STATE_DIR/nfqws-4600.pid")" 2>/dev/null || true
fi
# CURL_STUB_BUSY_MARK: while /proc/net/tcp holds that text (a TIME_WAIT
# socket of the probe ports), no source port can be bound (curl exit 45).
[ -z "${CURL_STUB_BUSY_MARK:-}" ] || ! grep -q "$CURL_STUB_BUSY_MARK" "$PROKOP_AUTOTUNE_PROC_NET/tcp" || mode=local_port
ms() { printf '0.%03d' "$1"; }
# The target answers the SYN of every probe that got past the TCP stage
# (tls_stall included: curl hides that connection, the counter does not).
if [ "$key" != none ]; then
  case "$mode" in
    success|moved|forbidden|otherip|tls|tls_timeout|tls_stall|reset|http_transport|empty_reply)
      case "$comment" in *:*) bump "synack:${comment#*:}" 1 ;; *) bump synack 1 ;; esac ;;
  esac
fi
case "$mode" in
  success) echo "0|61000|$ip|204|0.012|$(ms "$tls")|$(ms $((tls + 29)))|$(ms $((tls + 30)))|" ;;
  moved) echo "0|61001|$ip|301|0.012|0.061|0.090|0.091|" ;;
  forbidden) echo "0|61002|$ip|403|0.012|0.061|0.090|0.091|" ;;
  otherip) echo "0|61000|198.51.100.7|204|0.012|0.061|0.090|0.091|" ;;
  refused) echo "7|0||000|0.000000|0.000000|0.000000|0.004|Failed to connect to x port 443 after 4 ms: Connection refused"; exit 7 ;;
  unreachable) echo "7|0||000|0.000000|0.000000|0.000000|0.004|Failed to connect to x port 443 after 4 ms: No route to host"; exit 7 ;;
  connect_timeout) echo "28|0||000|0.000000|0.000000|0.000000|5.001|Connection timed out after 5001 milliseconds"; exit 28 ;;
  local_port) echo "45|0||000|0.000000|0.000000|0.000000|0.001|Failed binding local connection end"; exit 45 ;;
  # curl 8.19 on a blackholed ClientHello: the same record as connect_timeout.
  tls_stall) echo "28|0||000|0.000000|0.000000|0.000000|5.001|Connection timed out after 5001 milliseconds"; exit 28 ;;
  tls) echo "35|61003|$ip|000|0.012|0.000000|0.000000|0.070|mbedTLS: (-0x7780) SSL - A fatal alert message was received from our peer"; exit 35 ;;
  tls_timeout) echo "28|61003|$ip|000|0.012|0.000000|0.000000|10.0|Operation timed out after 10000 milliseconds with 0 bytes received"; exit 28 ;;
  reset) echo "35|61004|$ip|000|0.012|0.000000|0.000000|0.050|Recv failure: Connection reset by peer"; exit 35 ;;
  http_transport) echo "56|61005|$ip|000|0.012|0.061|0.000000|0.100|Recv failure: Connection reset by peer"; exit 56 ;;
  empty_reply) echo "52|61006|$ip|000|0.012|0.061|0.000000|0.100|Empty reply from server"; exit 52 ;;
esac
SH
# ip stand-in: policy rules from the router fixture and the probe route.
cat > "$WORK/bin/ip" <<'SH'
#!/usr/bin/env bash
echo "ip $*" >> "$STUB_LOG/ip.log"
case "$*" in
  "-j rule") [ -z "${IP_STUB_RULE_FAIL:-}" ] || exit 1; cat "$NFT_STATE/iprule.json" ;;
  "-j route get "*" ipproto tcp sport 61000 dport 443 uid 0")
    if [ -n "${IP_STUB_ROUTE_LOCAL:-}" ]; then printf '[{"type":"local","dst":"%s","dev":"lo","prefsrc":"203.0.113.10","uid":0,"flags":[],"cache":["local"]}]\n' "$4"
    elif [ -e "$NFT_STATE/route.changed" ]; then printf '[{"dst":"%s","gateway":"100.64.0.99","dev":"pppoe-wan","prefsrc":"203.0.113.10","uid":0,"flags":[],"cache":[]}]\n' "$4"
    elif [ -n "${IP_STUB_ROUTE_DIFFERS:-}" ] && [ "$6" = 0 ]; then printf '[{"dst":"%s","dev":"vpn1","prefsrc":"10.8.0.2","uid":0,"flags":[],"cache":[]}]\n' "$4"
    else printf '[{"dst":"%s","gateway":"100.64.0.1","dev":"pppoe-wan","prefsrc":"203.0.113.10","uid":0,"flags":[],"cache":[]}]\n' "$4"; fi ;;
  *) exit 1 ;;
esac
SH
cat > "$WORK/bin/dig" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_LOG/dig.args"
echo "dig $*" >> "$STUB_LOG/dig.log"
printf '%b' "${DIG_STUB_ANSWER-93.184.216.34\n}"
SH
chmod +x "$WORK/bin/nft" "$WORK/bin/curl" "$WORK/bin/dig" "$WORK/bin/ip"

# json <assertions> <file>: a failed assertion also names the result's status
# and reason, so the cause of an unexpected result shows up in the log.
json() { node -e 'const a=require("node:assert/strict");const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
try {'"$1"'} catch (e) { console.error("result: status=%s reason=%s", r && r.status, r && r.reason); throw e; }' "$2"; }

# Production stand-ins that must survive every scenario untouched.
sleep 600 & PROD_NFQWS=$!; disown; FOREIGN_PIDS+=("$PROD_NFQWS")
ucode -L "$LIB" "$LIB/core/pidfile_cli.uc" record "$PROD_NFQWS" "$WORK/child-pid/WardogsGame.pid"
# The ProkopTable listing (hashed and contract-checked by the run) as the
# production part of the current terse ruleset.
production_from_ruleset() {
  node -e '
const fs = require("fs");
const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).nftables;
const own = (x) => x.metainfo || (x.table && x.table.name === "ProkopTable") ||
  ["chain", "rule", "set"].some((k) => x[k] && x[k].table === "ProkopTable");
fs.writeFileSync(process.argv[2], JSON.stringify({ nftables: r.filter(own) }, null, 1) + "\n");' "$NFT_STATE/ruleset.json" "$NFT_STATE/tables/ProkopTable"
}
# Surgery on the production output path by meaning (never by handle).
mutate_ruleset() {
  node -e '
const fs = require("fs");
const file = process.argv[1];
const r = JSON.parse(fs.readFileSync(file, "utf8"));
const PROBE = 0x08000000;
const bypass = (x) => x.rule && x.rule.table === "ProkopTable" && x.rule.chain === "mangle_output" &&
  x.rule.expr.some((e) => e.match && e.match.left.meta && e.match.left.meta.key === "mark" && e.match.right === PROBE);
if (process.argv[2] === "remove-bypass") r.nftables = r.nftables.filter((x) => !bypass(x));
fs.writeFileSync(file, JSON.stringify(r, null, 1) + "\n");' "$1" "$2"
}
# queue_reset [LINE...]: rewrite the queue file under its lock, as every other
# writer does (stand-ins, their watchers, curl). A watcher whose sed -i read
# the file before an unlocked rewrite renames the old lines back over it.
queue_reset() {
  local line
  (
    flock 9
    : > "$PROKOP_AUTOTUNE_PROC_QUEUE"
    for line in "$@"; do printf '%s\n' "$line" >> "$PROKOP_AUTOTUNE_PROC_QUEUE"; done
  ) 9>"$PROKOP_AUTOTUNE_PROC_QUEUE.lock"
}
reset_state() {
  unset CURL_STUB_MODE CURL_STUB_TOUCH_PROD CURL_STUB_SLEEP NFT_STUB_FAIL_SETUP NFT_STUB_FAIL_DELETE \
    CURL_STUB_KILL_AT CURL_STUB_BUSY_MARK NFQWS_STUB_EXIT NFQWS_STUB_NO_LISTENER NFQWS_STUB_REJECT NFQWS_STUB_IGNORE_TERM DIG_STUB_ANSWER PROKOP_AUTOTUNE_QUEUE \
    CURL_STUB_UNEXPECTED CURL_STUB_PENDING CURL_STUB_SOCKET CURL_STUB_CLOSING NFT_STUB_FAIL_RULESET \
    IP_STUB_RULE_FAIL IP_STUB_ROUTE_LOCAL IP_STUB_ROUTE_DIFFERS NFT_STUB_INTERFACES NFT_STUB_FAIL_REPLACE \
    CURL_STUB_QUEUED CURL_STUB_ROUTE_CHANGE PROKOP_AUTOTUNE_QUIET_TIMEOUT \
    NFT_STUB_FAIL_PROBE_LISTING CURL_STUB_PLAN
  rm -f "$WORK/proc_net/ip_tables_names" "$WORK/proc_net/ip6_tables_names" "$STUB_LOG"/* \
    "$NFT_STATE/released" "$NFT_STATE/release.nft" "$NFT_STATE/route.changed" "$NFT_STATE/rules"
  export PROKOP_AUTOTUNE_DRAIN_TIMEOUT=1 PROKOP_AUTOTUNE_HOLD_TIMEOUT=2
  rm -rf "$PROKOP_AUTOTUNE_STATE_DIR" "$PROKOP_SNAPSHOT_LOCK_DIR" "$NFT_STATE/tables"/* "$NFT_STATE/last.nft"
  queue_reset "$PROD_QUEUE_LINE"
  printf '32768\t60999\n' > "$PROKOP_AUTOTUNE_PORT_RANGE_FILE"
  printf '  sl  local_address rem_address   st\n' > "$WORK/proc_net/tcp"
  printf '  sl  local_address rem_address   st\n' > "$WORK/proc_net/tcp6"
  printf 'table inet ProkopTable {\n\tqueue flags bypass to 4000\n}\n' > "$NFT_STATE/ruleset"
  cp "$FIXTURES/ruleset.json" "$NFT_STATE/ruleset.json"
  cp "$FIXTURES/iprule.json" "$NFT_STATE/iprule.json"
  production_from_ruleset
}
iso() { ucode -L "$LIB" "$LIB/autotune/isolation.uc" "$@" > "$WORK/out.json" || true; }
run_probe() { iso run "$1" example.com "${2:-3}" 192.0.2.53; }
assert_clean() {
  [ ! -e "$NFT_STATE/tables/ProkopAutotuneProbe" ] || fail "$1: temporary table left behind"
  ! grep -qE '^ 46(0[0-7]) ' "$PROKOP_AUTOTUNE_PROC_QUEUE" || fail "$1: a run queue left behind"
  ! pgrep -f "$WORK/bin/nfqws --qnum" >/dev/null || fail "$1: temporary nfqws left behind"
  for leftover in active.json work; do
    [ ! -e "$PROKOP_AUTOTUNE_STATE_DIR/$leftover" ] || fail "$1: temporary state $leftover left behind"
  done
  ! ls "$PROKOP_AUTOTUNE_STATE_DIR"/nfqws-*.pid >/dev/null 2>&1 || fail "$1: pidfile left behind"
  [ ! -e "$PROKOP_AUTOTUNE_STATE_DIR/lock" ] || fail "$1: run lock left behind"
  [ ! -e "$PROKOP_AUTOTUNE_STATE_DIR" ] || fail "$1: runtime directory left behind: $(ls -A "$PROKOP_AUTOTUNE_STATE_DIR")"
  kill -0 "$PROD_NFQWS" || fail "$1: production nfqws stand-in was signalled"
  grep -q '^ 4000 ' "$PROKOP_AUTOTUNE_PROC_QUEUE" || fail "$1: production queue line lost"
}
pass=0
ok() { pass=$((pass + 1)); printf 'ok %s\n' "$1"; }
