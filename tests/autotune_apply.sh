#!/usr/bin/env bash
set -euo pipefail

# DPI autotune stage 5: controlled application of a selected strategy with
# production verification and automatic rollback (autotune/apply.uc).
# The real config/snapshots.uc transaction, snapshots, LKG and process
# identity are used; guard, validator, health, reload, uci, curl and nft are
# stand-ins at the edges.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
REAL_UCODE="$(command -v ucode)"
# shellcheck source=tests/helpers/autotune_stubs.sh
. "$ROOT/tests/helpers/autotune_stubs.sh"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT/tests/helpers/wait.sh"
# An interrupt must land while apply runs its (slowed) DNS checks, not before
# the runner even started: wait for its first dig call instead of a fixed delay.
checks_started() { grep -q '^dig' "$STUB_LOG/dig.log" 2>/dev/null; }

export REAL_UCODE STATE="$WORK/state" WAIT_HELPER="$ROOT/tests/helpers/wait.sh"
export PROKOP_CONFIG_FILE="$WORK/config/prokop"
export PROKOP_SNAPSHOT_DIR="$WORK/snapshots" PROKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export PROKOP_RELOAD_COMMAND="$WORK/reload" PROKOP_BIN="$WORK/bin/prokop"
export PROKOP_AUTOTUNE_APPLY_STATE="$WORK/etc/autotune-apply.json"
export PROKOP_AUTOTUNE_UCI="$WORK/bin/uci"
export PROKOP_AUTOTUNE_ZAPRET_RUNTIME="$WORK/zapret-status.uc"
export PROKOP_AUTOTUNE_SINGBOX_CONFIG="$WORK/sing-box.json"
export PROKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock" PROKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export PROKOP_STOP_REQUESTED_FILE="$WORK/run/stop.requested"
export PROKOP_EXPLICIT_START_FILE="$WORK/run/start.explicit"
export PROKOP_AUTOTUNE_TMPDIR="$WORK/tmp" PROKOP_AUTOTUNE_UCI_SAVEDIR="$WORK/uci-save" PROKOP_UCI_SAVEDIR="$WORK/uci-save"
SECRET='SECRET-TOKEN-7f3a'
mkdir -p "$STATE" "$WORK/config" "$WORK/etc" "$WORK/run" "$WORK/tmp" "$WORK/uci-save"

# ucode wrapper: restore guard, runtime validator and health are modelled;
# everything else (apply.uc, snapshots.uc, catalog, ...) is the real code.
cat > "$WORK/bin/ucode" <<'SH'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    case "$4" in
      ensure-dpi-transition-guard) echo "$$" > "$STATE/guard.pid"; [ -z "${GUARD_FAIL:-}" ] || exit 1; [ -z "${GUARD_SLEEP:-}" ] || sleep "$GUARD_SLEEP"; touch "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard"; [ -z "${GUARD_HOLD:-}" ] || sleep "$GUARD_HOLD"; exit 0 ;;
      remove-dpi-transition-guard) rm -f "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard"; exit 0 ;;
    esac; exit 0 ;;
  */config/validator.uc) [ -z "${VALIDATE_SLEEP:-}" ] || sleep "$VALIDATE_SLEEP"; [ -z "${VALIDATE_FAIL:-}" ]; exit ;;
  */diagnostics/health.uc) echo "health $4 $5 $6" >> "$STUB_LOG/health.log"; exit 0 ;;
  */config/snapshots.uc)
    [ "${4:-}" != confirm-working ] || [ -z "${CONFIRM_FAIL:-}" ] || { echo '{"status":"failed","reason":"stub"}'; exit 1; }
    # EDIT_BEFORE_RESTORE: an edit (LuCI Save & Apply, another tab) lands right before a restore reads the file.
    [ "${4:-}" != restore ] || [ -z "${EDIT_BEFORE_RESTORE:-}" ] || sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '31'/" "$PROKOP_CONFIG_FILE"
    # STAGE_BEFORE_RESTORE: `uci set` without a commit right before a restore.
    [ "${4:-}" != restore ] || [ -z "${STAGE_BEFORE_RESTORE:-}" ] || echo "prokop.settings.dns_server='9.9.9.9'" > "$PROKOP_UCI_SAVEDIR/prokop" ;;
esac
exec "$REAL_UCODE" "$@"
SH
printf '#!/bin/sh\necho 1.0.26-test\n' > "$WORK/bin/prokop"

# nft: tables and the production queue rule of the Dpi rule (mark 0x01000001, queue 4000).
cat > "$WORK/bin/nft" <<'SH'
#!/usr/bin/env bash
echo "nft $*" >> "$STUB_LOG/nft.log"
case "$*" in
  "list tables") for t in "$NFT_STATE/tables"/*; do [ -e "$t" ] && echo "table inet ${t##*/}"; done; exit 0 ;;
  # The guards a failed lifecycle transition keeps (UC-019): the DPI guard
  # table and the transition guard chain ("<table>.<chain>" in chains).
  "list table inet ProkopTableDpiGuard") [ -e "$NFT_STATE/tables/ProkopTableDpiGuard" ]; exit $? ;;
  "list chain inet "*) [ -e "$NFT_STATE/chains/$4.$5" ]; exit $? ;;
  "list ruleset") echo "table inet ProkopTable {"; echo "}"; exit 0 ;;
  # The marked verification of a device-limited rule (autotune/apply.uc).
  "-f -") cat > "$STATE/verify.nft"
    [ -z "${VERIFY_CREATE_FAIL:-}" ] || exit 1
    grep -q '^create table inet ProkopAutotuneVerify$' "$STATE/verify.nft" || exit 1
    touch "$NFT_STATE/tables/ProkopAutotuneVerify"; echo 0 > "$STATE/verify.counter"; exit 0 ;;
  "delete table inet ProkopAutotuneVerify") rm -f "$NFT_STATE/tables/ProkopAutotuneVerify"; exit 0 ;;
  "-j list table inet ProkopAutotuneVerify")
    [ -e "$NFT_STATE/tables/ProkopAutotuneVerify" ] || exit 1
    read -r p < "$STATE/verify.counter"
    printf '{"nftables":[{"rule":{"family":"inet","table":"ProkopAutotuneVerify","chain":"premark","handle":2,"comment":"rule_mark","expr":[{"counter":{"packets":%s,"bytes":0}},{"accept":null}]}}]}\n' "$p"; exit 0 ;;
  "-j list chain inet ProkopTable mangle_output")
    read -r p < "$STATE/prod.counter"
    printf '{"nftables":[{"rule":{"family":"inet","table":"ProkopTable","chain":"mangle_output","handle":119,"expr":[{"match":{"op":"==","left":{"meta":{"key":"mark"}},"right":16777217}},{"match":{"op":"==","left":{"meta":{"key":"l4proto"}},"right":"tcp"}},{"counter":{"packets":%s,"bytes":0}},{"queue":{"num":4000,"flags":["bypass"]}}]}}]}\n' "$p"; exit 0 ;;
esac
exit 1
SH
# curl: production requests (no --resolve) through the Dpi rule's queue.
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  ftp://*)
    # Held production connection: the tracker lists it while it is open.
    port=""; prev=""; for a in "$@"; do [ "$prev" = --local-port ] && port="$a"; prev="$a"; done
    host="${url#ftp://}"; host="${host%%:*}"
    echo "curl hold $port $host" >> "$STUB_LOG/curl.log"
    printf '%s %s\n' "$port" "$host" > "$STATE/hold"
    sleep "${HOLD_SLEEP:-2}"; exit 28 ;;
  */connections)
    echo "curl tracker" >> "$STUB_LOG/curl.log"
    [ -z "${CLASH_DOWN:-}" ] || exit 7
    if read -r port host < "$STATE/hold" 2>/dev/null; then
      printf '{"connections":[{"id":"x","chains":%s,"rule":"domain_suffix=[example.com] => route(Dpi-out)","metadata":{"network":"tcp","type":"tproxy/tproxy-in","sourceIP":"203.0.113.1","sourcePort":"%s","destinationIP":"","destinationPort":"443","host":"%s"}}]}\n' "${PROD_CHAINS:-[\"Dpi-out\"]}" "$port" "$host"
    else echo '{"connections":[]}'; fi
    exit 0 ;;
esac
printf '%s\n' "$@" > "$STUB_LOG/curl.args"
if printf '%s\n' "$@" | grep -q -- '--resolve'; then echo "curl isolated" >> "$STUB_LOG/curl.log"; else echo "curl production" >> "$STUB_LOG/curl.log"; fi
[ -z "${PROD_SLEEP:-}" ] || sleep "$PROD_SLEEP"
n=$(( $(cat "$STATE/prod.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/prod.calls"
# A pinned request reaches the Dpi queue only through the marking rule of the
# verification table; VERIFY_NO_MARK: the mark never takes it there.
marked=""
if printf '%s\n' "$@" | grep -q -- '--resolve' && [ -e "$NFT_STATE/tables/ProkopAutotuneVerify" ]; then
  marked=1
  [ -z "${VERIFY_NO_MARK:-}" ] || PROD_QUEUE_BUMP=0
fi
plan="${PROD_PLAN:-success}"; steps=$(tr '|' '\n' <<<"$plan" | wc -l)
mode="$(tr '|' '\n' <<<"$plan" | sed -n "$(( (n - 1) % steps + 1 ))p")"
bump="${PROD_QUEUE_BUMP:-6}"
(
  flock 9
  awk -v n="$bump" '$1 == 4000 { printf " %d %8d %5d %d %5d %5d %5d %8d  %d\n", $1, $2, $3, $4, $5, $6, $7, $8 + n, $9; next } { print }' \
    "$PROKOP_AUTOTUNE_PROC_QUEUE" > "$PROKOP_AUTOTUNE_PROC_QUEUE.tmp" && mv "$PROKOP_AUTOTUNE_PROC_QUEUE.tmp" "$PROKOP_AUTOTUNE_PROC_QUEUE"
) 9>"$PROKOP_AUTOTUNE_PROC_QUEUE.lock"
read -r p < "$STATE/prod.counter"; echo "$((p + bump))" > "$STATE/prod.counter"
if [ -n "$marked" ]; then read -r v < "$STATE/verify.counter"; echo "$((v + bump))" > "$STATE/verify.counter"; fi
remote="${PROD_REMOTE:-198.18.0.5}"
case "$mode" in
  success) echo "0|51000|$remote|404|0.020|0.110|0.150|0.151|" ;;
  reset) echo "35|51000|$remote|000|0.020|0.000000|0.000000|0.050|Recv failure: Connection reset by peer"; exit 35 ;;
esac
SH
cat > "$WORK/bin/dig" <<'SH'
#!/usr/bin/env bash
echo "dig $*" >> "$STUB_LOG/dig.log"
[ -z "${DIG_SLEEP:-}" ] || sleep "$DIG_SLEEP"
case "$*" in
  *@*) printf '%b' "${DIG_STUB_ANSWER-93.184.216.34\n}" ;;
  *) printf '%b' "${LOCAL_DIG_ANSWER-198.18.0.5\n}" ;;
esac
SH
# uci on a private copy: -c DIR -t SAVE set/commit/get <package>.<section>.<option>.
cat > "$WORK/bin/uci" <<'SH'
#!/usr/bin/env bash
dir=""
while [ $# -gt 0 ]; do case "$1" in -c) dir="$2"; shift 2 ;; -t) shift 2 ;; *) break ;; esac; done
echo "uci $dir $*" >> "$STUB_LOG/uci.log"
case "$dir" in /etc/config|"") echo "uci touched the live config" >&2; exit 9 ;; esac
cmd="$1"; arg="${2:-}"
path="${arg%%=*}"; pkg="$(cut -d. -f1 <<<"$path")"; sec="$(cut -d. -f2 <<<"$path")"; opt="$(cut -d. -f3 <<<"$path")"
f="$dir/$pkg"; [ -e "$f" ] || { echo "uci: package $pkg missing" >&2; exit 1; }
case "$cmd" in
  set)
    [ -z "${UCI_FAIL:-}" ] || exit 1
    [ -z "${UCI_SLEEP:-}" ] || sleep "$UCI_SLEEP"
    value="${arg#*=}"
    awk -v s="$sec" -v o="$opt" -v v="$value" '
      function flush() { if (in_s && !done) { print "\toption " o " '"'"'" v "'"'"'"; done = 1 } }
      /^config / { flush(); in_s = ($0 ~ "^config section .?" s ".?$") }
      in_s && $1 == "option" && $2 == o { print "\toption " o " '"'"'" v "'"'"'"; done = 1; next }
      { print }
      END { flush() }' "$f" > "$f.new" && mv "$f.new" "$f"
    [ -z "${UCI_EXTRA_CHANGE:-}" ] || sed -i "s/option dns_server '1.1.1.1'/option dns_server '9.9.9.9'/" "$f" ;;
  commit) exit 0 ;;
  get) awk -v s="$sec" -v o="$opt" '/^config / { in_s = ($0 ~ "^config section .?" s ".?$") } in_s && $1 == "option" && $2 == o { sub(/^[ \t]*option [^ \t]+[ \t]+/, ""); gsub(/^'"'"'|'"'"'$/, ""); print }' "$f" ;;
esac
SH
# Prokop reload: outcomes from $STATE/reload.plan ("0", "1 0", ...); a
# successful reload restarts the Dpi rule's nfqws with the configured strategy.
# q is init.d behind a busy reload.lock: status 0, "queued" on stdout and
# reload.pending from the production writer; m leaves only that marker; t
# only the token (the lock holder already consumed the marker).
cat > "$WORK/reload" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG/reload.args"
set -- $(cat "$STATE/reload.plan" 2>/dev/null)
rc="${1:-0}"; shift || true; echo "$*" > "$STATE/reload.plan"
echo "reload $rc" >> "$STUB_LOG/reload.log"
# EDIT_ON_RELOAD=<n>: an edit (another writer) is committed during the n-th reload.
[ -z "${EDIT_ON_RELOAD:-}" ] || [ "$(grep -c '^reload' "$STUB_LOG/reload.log")" != "$EDIT_ON_RELOAD" ] ||
  sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '31'/" "$PROKOP_CONFIG_FILE"
if [ "$rc" = q ] || [ "$rc" = m ]; then
  "$REAL_UCODE" -L "$PROKOP_LIB" "$PROKOP_LIB/service/state.uc" mark-pending-reload "$PROKOP_PENDING_RELOAD_FILE" reload_busy
  [ "$rc" = m ] || echo queued
  exit 0
fi
[ "$rc" != t ] || { echo queued; exit 0; }
[ -z "${RELOAD_SLEEP:-}" ] || sleep "$RELOAD_SLEEP"
[ "$rc" = 0 ] || exit "$rc"
# BREAK_FIRST_RELOAD: the candidate reload leaves an incoherent runtime; the next reload repairs it.
if [ -n "${BREAK_FIRST_RELOAD:-}" ] && [ ! -e "$STATE/broke-once" ]; then touch "$STATE/broke-once" "$STATE/zapret-broken"; else rm -f "$STATE/zapret-broken"; fi
"$STATE/start-dpi"
SH
cat > "$STATE/start-dpi" <<'SH'
#!/usr/bin/env bash
# shellcheck source=tests/helpers/wait.sh
. "$WAIT_HELPER"
# A runtime that does not reach its state fails the test here, instead of
# leaving the verification of apply to judge a half-started one.
fixture_fail() { echo "start-dpi: $1" | tee -a "$STATE/fixture.error" >&2; exit 1; }
bound() { grep -q "^ 4000  *$1 " "$PROKOP_AUTOTUNE_PROC_QUEUE"; }
released() { ! bound "$1"; }
opt="$(awk '/^config / { in_s = ($0 ~ /^config section .?Dpi.?$/) } in_s && $1 == "option" && $2 == "nfqws_opt" { sub(/^[ \t]*option nfqws_opt[ \t]+/, ""); gsub(/^'"'"'|'"'"'$/, ""); print }' "$PROKOP_CONFIG_FILE")"
# An empty option runs the provider default, as the real runtime does.
[ -n "$opt" ] || opt="$ZAPRET_DEFAULT_NFQWS_OPT"
old="$(head -n 1 "$ZAPRET_CHILD_PID_DIR/Dpi.pid" 2>/dev/null || true)"
if [ -n "$old" ]; then
  kill "$old" 2>/dev/null || true
  wait_until 10 released "$old" || fixture_fail "the old nfqws $old still holds queue 4000"
fi
# shellcheck disable=SC2086
"$ZAPRET_NFQWS_BIN" --qnum=4000 --dpi-desync-fwmark=0x40000000 $opt >/dev/null 2>&1 &
pid=$!
wait_until 10 bound "$pid" || fixture_fail "nfqws $pid did not bind queue 4000"
"$REAL_UCODE" -L "$PROKOP_LIB" "$PROKOP_LIB/core/pidfile_cli.uc" record "$pid" "$ZAPRET_CHILD_PID_DIR/Dpi.pid"
SH
cat > "$WORK/zapret-status.uc" <<'UC'
let broken = require("fs").stat(getenv("STATE") + "/zapret-broken") != null;
print(sprintf("%J\n", { ready: !broken, conflict: false, expected_process_count: 2, running_process_count: broken ? 1 : 2,
    supervisor_process_count: 2 }));
UC
chmod +x "$WORK/bin/ucode" "$WORK/bin/prokop" "$WORK/bin/nft" "$WORK/bin/curl" "$WORK/bin/dig" "$WORK/bin/uci" "$WORK/reload" "$STATE/start-dpi"

# A short provider default with the three profiles of the real one (HTTP, TLS, QUIC).
export ZAPRET_DEFAULT_NFQWS_OPT='--filter-tcp=80 --dpi-desync=fake --new --filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=badsum --new --filter-udp=443 --dpi-desync=fake'
FAKE='--filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com'
MULTISPLIT='--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld'
write_config() {
  cat > "$PROKOP_CONFIG_FILE" <<EOF
config settings 'settings'
	option dns_server '1.1.1.1'
	option dns_rewrite_ttl '60'

config section 'Blocklist'
	option action 'block'
	option enabled '1'
	list domain 'ads.example'

config section 'Dpi'
	option action 'zapret'
	option enabled '1'
	list domain_suffix 'example.com'
	option nfqws_opt '${1:-$FAKE}'

config section 'main'
	option action 'connection'
	option enabled '1'
	list community_lists 'russia_inside'
	list selector_proxy_links 'vless://$SECRET@proxy.example:443?security=reality'

config section 'Game'
	option action 'zapret'
	option enabled '1'
	list ip_cidr '54.115.0.0/16'
	list source_ip_cidr '192.168.1.222'
	option nfqws_opt '--filter-udp=1024-65535 --dpi-desync=fake --dpi-desync-repeats=6'
EOF
}
write_singbox() {
  cat > "$PROKOP_AUTOTUNE_SINGBOX_CONFIG" <<'EOF'
{"route":{"final":"direct-out","rules":[
 {"action":"sniff"},{"protocol":"dns","action":"hijack-dns"},
 {"action":"reject","inbound":"tproxy-in","protocol":"quic"},
 {"inbound":"tproxy-in","domain":["ads.example"],"action":"reject"},
 {"inbound":"tproxy-in","domain_suffix":["example.com"],"action":"route","outbound":"Dpi-out"},
 {"inbound":"tproxy-in","rule_set":["main-russia_inside"],"action":"route","outbound":"main-out"},
 {"inbound":"tproxy-in","ip_cidr":["54.115.0.0/16"],"source_ip_cidr":["192.168.1.222"],"action":"route","outbound":"Game-out"}]},
 "outbounds":[{"type":"direct","tag":"direct-out"},{"type":"direct","tag":"Dpi-out","routing_mark":16777217},
  {"type":"direct","tag":"Game-out","routing_mark":16777218},{"type":"vless","tag":"main-out"}],
 "experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}}}
EOF
}
selection() { # selection <candidate> [host] [confidence]
  printf '{"status":"selected","selected":"%s","reason":"direct_failed_candidate_stable","confidence":"%s","target":{"host":"%s","ip":"93.184.216.34","resolver":"192.0.2.53"},"probes":[{},{},{}]}\n' \
    "$1" "${3:-high}" "${2:-example.com}" > "$WORK/selection.json"
}
at() {
  ucode -L "$LIB" "$LIB/autotune/apply.uc" "$@" > "$WORK/out.json" || true
  [ ! -s "$STATE/fixture.error" ] || fail "fixture: $(cat "$STATE/fixture.error")"
}
snaps() { find "$PROKOP_SNAPSHOT_DIR" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l; }
chash() { sha256sum "$PROKOP_CONFIG_FILE" | cut -d' ' -f1; }
lkg() { cat "$PROKOP_SNAPSHOT_DIR/last-known-working" 2>/dev/null || true; }
reloads() { grep -c '^reload' "$STUB_LOG/reload.log" 2>/dev/null || true; }
dpi_args() { tr '\0' ' ' < "/proc/$(head -n 1 "$ZAPRET_CHILD_PID_DIR/Dpi.pid")/cmdline"; }
reset_apply() {
  reset_state
  unset PROD_PLAN PROD_SLEEP PROD_QUEUE_BUMP PROD_REMOTE DIG_SLEEP GUARD_SLEEP VALIDATE_SLEEP VALIDATE_FAIL RELOAD_SLEEP UCI_FAIL UCI_EXTRA_CHANGE BREAK_FIRST_RELOAD CONFIRM_FAIL EDIT_BEFORE_RESTORE EDIT_ON_RELOAD STAGE_BEFORE_RESTORE NFQWS_STUB_REJECT DIG_STUB_ANSWER \
    LOCAL_DIG_ANSWER PROD_CHAINS CLASH_DOWN HOLD_SLEEP GUARD_FAIL GUARD_HOLD UCI_SLEEP
  pkill -f "$WORK/bin/nfqws --qnum=40" 2>/dev/null || true
  rm -rf "$PROKOP_SNAPSHOT_DIR" "$PROKOP_SNAPSHOT_HASH_DIR" "$PROKOP_AUTOTUNE_APPLY_STATE" "$STATE"/prod.* "$STATE/reload.plan" "$STATE/zapret-broken" "$STATE/broke-once"\
    "$ZAPRET_CHILD_PID_DIR"/*.pid "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" "$PROKOP_SNAPSHOT_LOCK_DIR" "$WORK/run"/* \
    "$STATE/hold" "$STATE/guard.pid" "$WORK/uci-save"/*
  echo 0 > "$STATE/prod.counter"
  queue_reset
  touch "$NFT_STATE/tables/ProkopTable"
  write_config "${1:-$FAKE}"; write_singbox
  # Production runtime: Dpi and Game nfqws on queues 4000/4001.
  "$STATE/start-dpi"
  "$ZAPRET_NFQWS_BIN" --qnum=4001 --dpi-desync-fwmark=0x40000000 --filter-udp=1024-65535 --dpi-desync=fake --dpi-desync-repeats=6 >/dev/null 2>&1 &
  game=$!
  wait_until 10 grep -q "^ 4001  *$game " "$PROKOP_AUTOTUNE_PROC_QUEUE" || fail "fixture: the Game nfqws did not bind queue 4001"
  "$REAL_UCODE" -L "$LIB" "$LIB/core/pidfile_cli.uc" record "$game" "$ZAPRET_CHILD_PID_DIR/Game.pid"
  ucode -L "$LIB" "$LIB/config/snapshots.uc" confirm-working > /dev/null
  PRE_LKG="$(lkg)"; PRE_HASH="$(chash)"; : > "$STUB_LOG/reload.log"
}
no_secret() { ! grep -rq "$SECRET" "$WORK/out.json" "$PROKOP_AUTOTUNE_APPLY_STATE" "$STUB_LOG" 2>/dev/null || fail "$1: secret leaked"; }
# What a start or reload of the lifecycle asks for once it succeeded.
confirm() { ucode -L "$LIB" "$LIB/config/snapshots.uc" confirm-working > "$WORK/confirm.json" || true; }
# A measuring run of the autotune manager (no targets): it only asks the real
# apply.uc whether anything blocks it.
manager_env() { PROKOP_AUTOTUNE_STATE_FILE="$WORK/etc/autotune-state.json" PROKOP_AUTOTUNE_LAST_DIR="$WORK/run/autotune-last" "$@"; }
manager_run() { manager_env ucode -L "$LIB" "$LIB/autotune/manager.uc" run all > "$WORK/run.json" || true; }
manager_status() { manager_env ucode -L "$LIB" "$LIB/autotune/manager.uc" status > "$WORK/mstatus.json" || true; }
# SIGKILL of the apply (power loss, OOM) while it verifies the candidate.
crash_in_verification() {
  reset_apply; plan_ready; export PROD_SLEEP=1
  ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
  local runner=$!
  for _ in $(seq 1 200); do grep -q 'curl production' "$STUB_LOG/curl.log" 2>/dev/null && break; sleep 0.05; done
  kill -9 "$runner"; pkill -9 -f "$WORK/bin/curl" || true; wait "$runner" 2>/dev/null || true; unset PROD_SLEEP
  json 'a.equal(r.phase, "verifying");' "$PROKOP_AUTOTUNE_APPLY_STATE"
}
plan_ready() { selection multisplit; at plan "$WORK/selection.json"; cp "$WORK/out.json" "$WORK/plan.json"; }

# 1. plan is read-only
reset_apply; plan_ready
json '
a.equal(r.status, "ready", JSON.stringify(r)); a.equal(r.selected, "multisplit");
a.equal(r.owner.section, "Dpi"); a.equal(r.owner.queue, 4000); a.equal(r.owner.mark, "0x01000001");
a.deepEqual(r.changes, [{ section: "Dpi", option: "nfqws_opt",
  from: "--filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com",
  to: "--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld" }]);
a.match(r.config_hash, /^[0-9a-f]{64}$/); a.match(r.candidate_hash, /^[0-9a-f]{64}$/); a.match(r.selection.fingerprint, /^[0-9a-f]{64}$/);
a.deepEqual(r.scope, { rule: "Dpi", matchers: { domain_suffix: 1 } }); a.equal(r.applied, false);
' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(snaps)" = 1 ] && [ "$(reloads)" = 0 ] && [ ! -e "$PROKOP_AUTOTUNE_APPLY_STATE" ]; } || fail "plan mutated state"
[ ! -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] || fail "plan installed a guard"
! grep -q ' set \| commit ' <(grep -v "/tmp/prokop-autotune-uci" "$STUB_LOG/uci.log") || fail "uci used outside the private copy"
no_secret "plan"; ok "1 plan is read-only (config, snapshots, reload, guard, state untouched)"

# 2 / 23. stale config hash -> no mutation
reset_apply; plan_ready
sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '30'/" "$PROKOP_CONFIG_FILE"; changed="$(chash)"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "config_changed"); a.equal(r.applied, false);' "$WORK/out.json"
{ [ "$(chash)" = "$changed" ] && [ "$(snaps)" = 1 ] && [ "$(reloads)" = 0 ]; } || fail "stale apply mutated"
ok "2 stale config hash -> stale, no mutation"
reset_apply; plan_ready
printf 'config settings x\n' > "$WORK/candidate"
at_snap() { ucode -L "$LIB" "$LIB/config/snapshots.uc" "$@" > "$WORK/out.json" || true; }
at_snap apply "$WORK/candidate" 0000000000000000000000000000000000000000000000000000000000000000
json 'a.equal(r.status, "stale");' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(snaps)" = 1 ]; } || fail "transaction ignored the expected hash"
ok "23 TOCTOU: the transaction itself re-checks the planned config hash"
reset_apply; plan_ready; export DIG_STUB_ANSWER='203.0.113.9\n'; at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "target_resolution_changed");' "$WORK/out.json"
[ "$(reloads)" = 0 ] || fail "resolution change applied"
ok "stale target resolution -> no mutation"
reset_apply; plan_ready
RELOAD_SLEEP=2 ucode -L "$LIB" "$LIB/config/snapshots.uc" restore "$PRE_LKG" > /dev/null &
restorer=$!
for _ in $(seq 1 100); do ls "$PROKOP_SNAPSHOT_LOCK_DIR"/owner.* >/dev/null 2>&1 && break; sleep 0.05; done
at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.ok(["snapshot_operation_in_progress", "restore_guard_active"].includes(r.reason), r.reason);' "$WORK/out.json"
wait "$restorer" || true
[ "$(reloads)" = 1 ] || fail "apply reloaded during a snapshot operation"
reset_apply; plan_ready; mkdir -p "$PROKOP_SNAPSHOT_LOCK_DIR"; touch "$PROKOP_SNAPSHOT_LOCK_DIR/owner.999999.1"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "applied");' "$WORK/out.json"
ok "a stale snapshot lock (dead owner) does not block; a live snapshot operation does"
reset_apply; plan_ready; touch "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "restore_guard_active");' "$WORK/out.json"
[ -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] || fail "guard removed"
ok "restore guard or snapshot operation active -> no mutation"

# 3 / 4. invalid or unsupported candidate
reset_apply; plan_ready; export NFQWS_STUB_REJECT=multisplit; at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "candidate_invalid");' "$WORK/out.json"
{ [ "$(reloads)" = 0 ] && [ "$(snaps)" = 1 ]; } || fail "invalid candidate applied"
selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "candidate_unsupported"); a.equal(r.candidate_reason, "nfqws_dry_run_rejected");' "$WORK/out.json"
ok "3 candidate failing validation at apply time -> no mutation"
reset_apply; selection udp_fake; at plan "$WORK/selection.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "candidate_unsupported");' "$WORK/out.json"
selection multisplit example.com low; at plan "$WORK/selection.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "selection_confidence_too_low");' "$WORK/out.json"
ok "4 unsupported candidate or weak selection -> no plan"

# 5. snapshot failure -> no mutation (manual snapshots fill the retention)
reset_apply; plan_ready
for _ in $(seq 1 10); do ucode -L "$LIB" "$LIB/config/snapshots.uc" create manual > /dev/null || true; done
before_snaps="$(snaps)"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "apply_failed:snapshot_retention_full"); a.equal(r.applied, false);' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ] && [ "$(snaps)" = "$before_snaps" ]; } || fail "applied without a snapshot"
ok "5 no room for the pre-apply snapshot -> no mutation"

# 6. already-active candidate -> no_change_required
reset_apply; selection fake; at plan "$WORK/selection.json"
json 'a.equal(r.status, "no_change_required"); a.equal(r.reason, "candidate_already_active");' "$WORK/out.json"
{ [ "$(snaps)" = 1 ] && [ "$(reloads)" = 0 ]; } || fail "no-change plan mutated"
ok "6 already-active candidate -> no_change_required"

# 7 / 8 / 14 / 15. apply: exact mutation, reload, verification, LKG confirmed
reset_apply; plan_ready; at apply "$WORK/plan.json"
json '
a.equal(r.status, "applied", JSON.stringify(r).slice(0, 600)); a.equal(r.applied, true); a.equal(r.phase, "applied");
a.equal(r.reload.status, "success"); a.match(r.pre_snapshot, /^[0-9]+_[0-9]+$/); a.equal(r.lkg, "confirmed");
a.ok(r.verification.ok); a.deepEqual(r.verification.checks.map((c) => c.name), ["rule_strategy","rule_owns_target","zapret_runtime_ready","nfqws_arguments","queue_owner","no_guard","no_snapshot_operation","no_service_action","no_probe_table","traffic_transport","traffic_sing_box_path","traffic_dpi_queue","traffic_rule_path"]);
a.deepEqual(r.verification.traffic.path.chains, ["Dpi-out"]);
a.equal(r.verification.traffic.stability, "stable"); a.ok(r.verification.traffic.queue_packets >= 3); a.ok(r.verification.traffic.queue_rule_packets >= 3);
' "$WORK/out.json"
pre_id="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pre_snapshot)' "$WORK/out.json")"
node -e 'const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));fs.writeFileSync(process.argv[2],s.content)' "$PROKOP_SNAPSHOT_DIR/$pre_id.json" "$WORK/pre.conf"
ucode -L "$LIB" "$LIB/config/snapshots.uc" fixture-diff "$WORK/pre.conf" "$PROKOP_CONFIG_FILE" > "$WORK/diff.json"
json 'a.deepEqual(r.map((c) => c.section + "." + c.option), ["Dpi.nfqws_opt"]);' "$WORK/diff.json"
# Real `uci commit` re-exports the whole package in canonical form (layout,
# quoting, comments), so equality is semantic: exactly Dpi.nfqws_opt differs.
grep -q "vless://$SECRET" "$PROKOP_CONFIG_FILE" || fail "unrelated secret option lost"
[ "$(dpi_args)" = "$ZAPRET_NFQWS_BIN --qnum=4000 --dpi-desync-fwmark=0x40000000 $MULTISPLIT " ] || fail "runtime not on candidate: $(dpi_args)"
[ "$(lkg)" != "$PRE_LKG" ] || fail "LKG not confirmed after verified apply"
[ "$(reloads)" = 1 ] || fail "expected exactly one reload"
[ ! -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] || fail "guard left after apply"
{ grep -q 'curl production' "$STUB_LOG/curl.log" && ! grep -q 'curl isolated' "$STUB_LOG/curl.log"; } || fail "verification did not use the production path"
json 'a.equal(r.phase, "applied"); a.equal(r.status, "applied");' "$PROKOP_AUTOTUNE_APPLY_STATE"
no_secret "apply"
ok "7/8/14/15 exact planned mutation, one reload, production verified, LKG confirmed, unrelated options and secrets intact"

# 21. same candidate again -> no_change_required, no reload
selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "no_change_required"); a.equal(r.reason, "candidate_already_active");' "$WORK/out.json"
[ "$(reloads)" = 1 ] || fail "repeat triggered a reload"
ok "21 repeating the applied candidate -> no_change_required"

# 9. reload failure recovered by the transaction -> not applied
reset_apply; plan_ready; echo "1 0" > "$STATE/reload.plan"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "reload_failed_recovered"); a.equal(r.applied, false); a.equal(r.config_restored, true); a.equal(r.verification, null);' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "config not restored"
[ "$(dpi_args)" = "$ZAPRET_NFQWS_BIN --qnum=4000 --dpi-desync-fwmark=0x40000000 $FAKE " ] || fail "runtime not restored"
ok "9 reload failure + built-in recovery -> failed, candidate not applied"

# 10. reload needs_attention -> stop
reset_apply; plan_ready; echo "1 1" > "$STATE/reload.plan"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "needs_attention"); a.equal(r.reload.status, "needs_attention"); a.equal(r.verification, null);' "$WORK/out.json"
[ -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] || fail "guard removed on needs_attention"
! grep -q 'curl production' "$STUB_LOG/curl.log" 2>/dev/null || fail "verified after needs_attention"
ok "10 reload needs_attention -> stop, guard kept, no verification"

# 11 / 12 / 24. verification failure -> restore -> rolled_back
reset_apply; plan_ready; export PROD_PLAN=reset; at apply "$WORK/plan.json"
json '
a.equal(r.status, "rolled_back", JSON.stringify(r).slice(0, 500)); a.equal(r.reason, "verification_failed"); a.equal(r.applied, false);
a.equal(r.rollback.status, "success"); a.equal(r.rollback.config_hash_restored, true); a.equal(r.rollback.lkg_is_pre_snapshot, true);
a.ok(r.rollback.runtime.ok); a.ok(!r.verification.ok);
' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "rollback config hash"
[ "$(dpi_args)" = "$ZAPRET_NFQWS_BIN --qnum=4000 --dpi-desync-fwmark=0x40000000 $FAKE " ] || fail "old runtime not restored"
{ [ ! -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] && [ ! -e "$PROKOP_SNAPSHOT_LOCK_DIR" ]; } || fail "guard or lock left after rollback"
ok "11/12 verification failure -> standard restore of the pre-apply snapshot -> rolled_back"
reset_apply; plan_ready; export PROD_QUEUE_BUMP=0; at apply "$WORK/plan.json"
json 'a.equal(r.status, "rolled_back"); const c = r.verification.checks.find((x) => x.name === "traffic_dpi_queue"); a.equal(c.ok, false);
  a.equal(r.verification.checks.find((x) => x.name === "traffic_transport").ok, true);' "$WORK/out.json"
reset_apply; plan_ready; export PROD_REMOTE=93.184.216.34; at apply "$WORK/plan.json"
json 'a.equal(r.status, "rolled_back"); a.equal(r.verification.checks.find((x) => x.name === "traffic_sing_box_path").ok, false);' "$WORK/out.json"
reset_apply; plan_ready; export BREAK_FIRST_RELOAD=1; at apply "$WORK/plan.json"
json 'a.equal(r.status, "rolled_back"); a.equal(r.verification.checks.find((x) => x.name === "zapret_runtime_ready").ok, false); a.equal(r.verification.traffic, null);' "$WORK/out.json"
ok "24 verification proves the rule path (queue counters, FakeIP, runtime), not only HTTP success"

# 13. verification failure + restore needs_attention -> needs_attention
reset_apply; plan_ready; export PROD_PLAN=reset; echo "0 1 1" > "$STATE/reload.plan"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "needs_attention"); a.equal(r.rollback.status, "needs_attention"); a.equal(r.applied, false);' "$WORK/out.json"
ok "13 rollback reaching needs_attention -> needs_attention, no further mutation"

# 13a. A lifecycle action (list update) takes reload.lock right after the
#      candidate reload and holds it through verification: verification fails
#      (no_service_action) and the rollback restore is refused busy. The
#      rollback waits for the action to end instead of leaving the unverified
#      candidate in place, then restores the pre-apply snapshot.
cat > "$WORK/reload-then-lock" <<'SH'
#!/usr/bin/env bash
"$WORK_RELOAD" "$@"; rc=$?
if [ ! -e "$STATE/lock-taken" ]; then
  touch "$STATE/lock-taken"
  mkdir -p "$PROKOP_RELOAD_LOCK_DIR"
  sleep 300 >/dev/null 2>&1 </dev/null &
  echo "$!" > "$PROKOP_RELOAD_LOCK_DIR/pid"
fi
exit $rc
SH
chmod +x "$WORK/reload-then-lock"
holder() { cat "$PROKOP_RELOAD_LOCK_DIR/pid" 2>/dev/null || true; }
reset_apply; plan_ready; rm -f "$STATE/lock-taken"
# The action ends a moment after the rollback started.
( for _ in $(seq 1 300); do grep -q '"phase": "rolling_back"' "$PROKOP_AUTOTUNE_APPLY_STATE" 2>/dev/null && break; sleep 0.1; done
  sleep 1; kill "$(holder)" 2>/dev/null || true ) &
watcher=$!
WORK_RELOAD="$WORK/reload" PROKOP_RELOAD_COMMAND="$WORK/reload-then-lock" at apply "$WORK/plan.json"
kill "$watcher" "$(holder)" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true
json '
a.equal(r.status, "rolled_back", JSON.stringify(r).slice(0, 600)); a.equal(r.reason, "verification_failed");
a.ok(r.verification.checks.some((c) => c.name === "no_service_action" && !c.ok));
a.equal(r.rollback.status, "success"); a.equal(r.rollback.lkg_is_pre_snapshot, true); a.ok(r.rollback.runtime.ok);
' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ ! -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ]; } || fail "busy rollback did not restore the pre-apply state"
[ "$(dpi_args)" = "$ZAPRET_NFQWS_BIN --qnum=4000 --dpi-desync-fwmark=0x40000000 $FAKE " ] || fail "busy rollback left the candidate runtime"
# The wait is bounded: an action that outlasts it leaves needs_attention.
reset_apply; plan_ready; rm -f "$STATE/lock-taken"
WORK_RELOAD="$WORK/reload" PROKOP_RELOAD_COMMAND="$WORK/reload-then-lock" PROKOP_AUTOTUNE_ROLLBACK_WAIT_SECONDS=1 at apply "$WORK/plan.json"
kill "$(holder)" 2>/dev/null || true
json 'a.equal(r.status, "needs_attention"); a.equal(r.reason, "verification_failed:rollback_busy"); a.equal(r.rollback.reason, "service_action_in_progress");' "$WORK/out.json"
ok "13a verification failed under a lifecycle action -> rollback waits for it (bounded) and restores the pre-apply snapshot"

# 13b. The restore of the rollback does not reload (fails, or is only
#      queued) and the transaction puts the candidate back: that candidate
#      has just failed verification, so last-known-working stays on the
#      pre-apply snapshot (UC-059).
for plan in "0 1 0" "0 q 0"; do
  reset_apply; plan_ready; export PROD_PLAN=reset; echo "$plan" > "$STATE/reload.plan"; at apply "$WORK/plan.json"
  json 'a.equal(r.status, "needs_attention"); a.equal(r.reason, "verification_failed:rollback_recovered"); a.equal(r.rollback.status, "recovered");' "$WORK/out.json"
  [ "$(chash)" != "$PRE_HASH" ] || fail "$plan: fixture: the candidate was not put back"
  [ "$(lkg)" = "$PRE_LKG" ] || fail "$plan: last-known-working moved to the candidate that failed verification"
  # Nor does the next start or reload confirm it (lifecycle confirm-working).
  confirm; json 'a.equal(r.status, "not_confirmed"); a.equal(r.reason, "autotune_apply_unresolved");' "$WORK/confirm.json"
  [ "$(lkg)" = "$PRE_LKG" ] || fail "$plan: a later start or reload confirmed the rejected candidate"
  unset PROD_PLAN
done
ok "13b rollback restore failed or queued, candidate put back -> needs_attention, last-known-working stays pre-apply"

# 13c. While the rollback waits for a lifecycle action, that action (a reload
#      of the unchanged candidate) ends and confirms the working configuration
#      (service/lifecycle.uc finish_reload_status): the record is still being
#      rolled back, so the candidate is not confirmed (UC-020).
reset_apply; plan_ready; rm -f "$STATE/lock-taken" "$WORK/confirm.json"
( for _ in $(seq 1 300); do grep -q '"phase": "rolling_back"' "$PROKOP_AUTOTUNE_APPLY_STATE" 2>/dev/null && break; sleep 0.1; done
  confirm ) &
watcher=$!
WORK_RELOAD="$WORK/reload" PROKOP_RELOAD_COMMAND="$WORK/reload-then-lock" PROKOP_AUTOTUNE_ROLLBACK_WAIT_SECONDS=4 at apply "$WORK/plan.json"
wait "$watcher" 2>/dev/null || true; kill "$(holder)" 2>/dev/null || true
json 'a.equal(r.status, "needs_attention"); a.equal(r.reason, "verification_failed:rollback_busy");' "$WORK/out.json"
json 'a.notEqual(r.status, "confirmed");' "$WORK/confirm.json"
[ "$(lkg)" = "$PRE_LKG" ] || fail "a reload during the rollback wait confirmed the rejected candidate"
ok "13c reload ending while the rollback waits for it -> the rejected candidate is not confirmed"

# 22. direct never mutates production
reset_apply; selection direct; at plan "$WORK/selection.json"
json 'a.equal(r.status, "direct_not_applicable"); a.equal(r.changes, undefined);' "$WORK/out.json"
cp "$WORK/out.json" "$WORK/plan.json"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "invalid_plan");' "$WORK/out.json"
selection direct ads.example; at plan "$WORK/selection.json"
json 'a.equal(r.status, "no_change_required"); a.equal(r.reason, "target_not_handled_by_dpi_rule");' "$WORK/out.json"
selection direct other.org; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.match(r.reason, /^rule_owner_undecidable/);' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ] && [ "$(snaps)" = 1 ]; } || fail "direct mutated production"
ok "22 direct: never a production mutation (direct_not_applicable / no_change_required / not_applicable)"

# Mapping limits: only a dedicated, decidable TCP/443 DPI rule is changed.
reset_apply; selection multisplit other.org; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.equal(r.reason, "rule_owner_undecidable:undecidable_matcher");' "$WORK/out.json"
selection multisplit ads.example; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.equal(r.reason, "target_not_handled_by_dpi_rule");' "$WORK/out.json"
# Several profiles: only the TCP/443 profile is replaced, the others stay.
reset_apply "--filter-tcp=443 --hostlist=/opt/zapret/ipset/yt.txt --dpi-desync=fake --new --filter-udp=443 --dpi-desync=fake"; selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "ready", r.reason); a.equal(r.profile.index, 0);
  a.equal(r.changes[0].to, "--filter-tcp=443 --hostlist=/opt/zapret/ipset/yt.txt --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld --new --filter-udp=443 --dpi-desync=fake");' "$WORK/out.json"
# A profile that takes TCP/443 together with other traffic is not split.
reset_apply "--filter-tcp=80,443 --dpi-desync=fake"; selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.equal(r.reason, "tcp443_profile_shared");' "$WORK/out.json"
reset_apply "--filter-udp=443 --dpi-desync=fake"; selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.equal(r.reason, "no_tcp443_profile");' "$WORK/out.json"
reset_apply; node -e 'const fs=require("fs");const f=process.argv[1];const c=JSON.parse(fs.readFileSync(f,"utf8"));const r=c.route.rules;const m=r.splice(5,1)[0];r.splice(3,0,m);fs.writeFileSync(f,JSON.stringify(c))' "$PROKOP_AUTOTUNE_SINGBOX_CONFIG"
selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.match(r.reason, /undecidable_matcher/);' "$WORK/out.json"
reset_apply; export UCI_EXTRA_CHANGE=1; selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "mutation_not_exact");' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "plan changed the config"
ok "mapping limits: undecidable owner, non-DPI owner, mixed/default strategy, list rule above, inexact mutation -> no plan"

# 16. concurrent apply -> busy
reset_apply; plan_ready; export RELOAD_SLEEP=2
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/first.json" &
first=$!
for _ in $(seq 1 100); do [ -e "$PROKOP_AUTOTUNE_STATE_DIR/lock" ] && break; sleep 0.05; done
at apply "$WORK/plan.json"
json 'a.equal(r.status, "busy"); a.equal(r.reason, "autotune_in_progress");' "$WORK/out.json"
wait "$first" || true
json 'a.equal(r.status, "applied");' "$WORK/first.json"
ok "16 concurrent apply -> busy"

# 17. probe/tune run holds the autotune lock -> apply refused
reset_apply; plan_ready; export DIG_SLEEP=3
ucode -L "$LIB" "$LIB/autotune/isolation.uc" tune example.com 3 192.0.2.53 multisplit > "$WORK/tune.json" &
tuner=$!
for _ in $(seq 1 100); do [ -e "$PROKOP_AUTOTUNE_STATE_DIR/lock" ] && break; sleep 0.05; done
unset DIG_SLEEP; at apply "$WORK/plan.json"
json 'a.equal(r.status, "busy");' "$WORK/out.json"
wait "$tuner" || true
[ "$(reloads)" = 0 ] || fail "apply ran during a tuning run"
ok "17 apply refused while a probe/tune run holds the autotune lock"

# 18. interruption before mutation -> no change
reset_apply; plan_ready; export DIG_SLEEP=2; : > "$STUB_LOG/dig.log"
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!; wait_until 30 checks_started || fail "apply did not reach its checks"
kill -TERM "$runner"; wait "$runner" || true
json 'a.equal(r.status, "failed"); a.equal(r.reason, "interrupted_before_mutation");' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(snaps)" = 1 ] && [ "$(reloads)" = 0 ]; } || fail "interrupted apply mutated"
ok "18 interruption before mutation -> no change"

# 19. crash after the pre-apply snapshot, before the config write
reset_apply; plan_ready; export GUARD_SLEEP=3
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 100); do [ "$(snaps)" = 2 ] && break; sleep 0.05; done
sleep 0.3; kill -9 "$runner"; pkill -9 -f "$WORK/tmp/prokop-autotune-candidate" || true
kill -9 "$(cat "$STATE/guard.pid")" 2>/dev/null || true
wait "$runner" 2>/dev/null || true; unset GUARD_SLEEP; sleep 0.5
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ]; } || fail "crash after snapshot changed production"
at status
json 'a.equal(r.resolved, true); a.equal(r.diagnosis, "not_applied"); a.equal(r.config_is, "pre_apply"); a.equal(r.pre_snapshot_present, true); a.equal(r.state.phase, "applying");' "$WORK/out.json"
rm -rf "$PROKOP_SNAPSHOT_LOCK_DIR"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "applied");' "$WORK/out.json"
ok "19 crash after snapshot -> production unchanged, diagnosed not_applied (resolved), a new apply may supersede it"

# 3 (crash list). crash after the config write, before the reload -> diagnosable, never guessed
reset_apply; plan_ready; export VALIDATE_SLEEP=3
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 100); do [ -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] && [ "$(chash)" != "$PRE_HASH" ] && break; sleep 0.05; done
kill -9 "$runner"; pkill -9 -f "$WORK/tmp/prokop-autotune-candidate" || true; wait "$runner" 2>/dev/null || true; unset VALIDATE_SLEEP; sleep 3.2
at status
json 'a.equal(r.resolved, false); a.equal(r.diagnosis, "in_transaction"); a.equal(r.config_is, "candidate");' "$WORK/out.json"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "previous_apply_unresolved"); a.equal(r.diagnosis, "in_transaction");' "$WORK/out.json"
at rollback
json 'a.equal(r.status, "failed"); a.equal(r.reason, "rollback_needs_candidate_config");' "$WORK/out.json"
[ -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] || fail "guard removed automatically"
ok "crash after config write, before reload -> in_transaction, no automatic guess or mutation"

# 20. interruption after a successful reload -> diagnosable, explicit rollback
reset_apply; plan_ready; export PROD_SLEEP=1
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do grep -q 'curl production' "$STUB_LOG/curl.log" 2>/dev/null && break; sleep 0.05; done
kill -TERM "$runner"; wait "$runner" || true; unset PROD_SLEEP
json 'a.equal(r.status, "failed"); a.equal(r.reason, "interrupted_after_apply"); a.equal(r.rollback_available, true); a.equal(r.applied, false);' "$WORK/out.json"
[ "$(lkg)" = "$PRE_LKG" ] || fail "LKG moved without a verdict"
at status; json 'a.equal(r.config_is, "candidate"); a.equal(r.resolved, false); a.equal(r.diagnosis, "candidate_active");' "$WORK/out.json"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "previous_apply_unresolved"); a.equal(r.diagnosis, "candidate_active");' "$WORK/out.json"
at rollback
json 'a.equal(r.status, "rolled_back"); a.equal(r.rollback.config_hash_restored, true); a.ok(r.rollback.runtime.ok);' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "explicit rollback"
ok "20 interruption after reload -> recorded (LKG unchanged), explicit rollback restores"

# 20a. SIGKILL (power loss, OOM) during the verification: the record stays in
#      phase verifying while the unverified candidate runs. The start or
#      reload after it does not make the candidate last-known-working
#      (UC-020); nor does it while an interrupted record (SIGTERM) names it.
reset_apply; plan_ready; export PROD_SLEEP=1
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do grep -q 'curl production' "$STUB_LOG/curl.log" 2>/dev/null && break; sleep 0.05; done
kill -9 "$runner"; pkill -9 -f "$WORK/bin/curl" || true; wait "$runner" 2>/dev/null || true; unset PROD_SLEEP
json 'a.equal(r.phase, "verifying");' "$PROKOP_AUTOTUNE_APPLY_STATE"
[ "$(chash)" != "$PRE_HASH" ] || fail "fixture: the candidate is not active"
confirm; json 'a.equal(r.status, "not_confirmed"); a.equal(r.reason, "autotune_apply_unresolved");' "$WORK/confirm.json"
[ "$(lkg)" = "$PRE_LKG" ] || fail "the start after a crash during verification confirmed the unverified candidate"
reset_apply; plan_ready; export PROD_SLEEP=1
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do grep -q 'curl production' "$STUB_LOG/curl.log" 2>/dev/null && break; sleep 0.05; done
kill -TERM "$runner"; wait "$runner" || true; unset PROD_SLEEP
json 'a.equal(r.reason, "interrupted_after_apply");' "$WORK/out.json"
confirm; json 'a.equal(r.status, "not_confirmed");' "$WORK/confirm.json"
[ "$(lkg)" = "$PRE_LKG" ] || fail "the start after an interrupted verification confirmed the unverified candidate"
at rollback; json 'a.equal(r.status, "rolled_back");' "$WORK/out.json"
confirm; json 'a.equal(r.status, "confirmed");' "$WORK/confirm.json"
ok "20a crash or interruption during verification -> a later start/reload does not confirm the candidate; after the rollback it confirms"

# 20b. An apply record that exists but cannot be read (empty after a power
#      cut, garbage) may hide an unresolved apply: nothing is confirmed.
for content in '' 'garbage{' '[]' '"x"'; do
  reset_apply; printf '%s' "$content" > "$PROKOP_AUTOTUNE_APPLY_STATE"
  sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '20'/" "$PROKOP_CONFIG_FILE"
  confirm; json 'a.equal(r.status, "not_confirmed"); a.equal(r.reason, "autotune_apply_unreadable");' "$WORK/confirm.json"
  [ "$(lkg)" = "$PRE_LKG" ] || fail "'$content': confirmed although the apply record is unreadable"
done
ok "20b unreadable or empty apply record -> last-known-working is not confirmed"

# 20c. A crash during verification leaves the record in phase verifying for
#      good. While the candidate is active it blocks autotune (the operator
#      rolls back); once the configuration is no longer the candidate (a
#      snapshot was restored, or the configuration edited) it no longer does,
#      and the next run and apply go ahead (UC-020).
crash_in_verification
at status; json 'a.equal(r.resolved, false); a.equal(r.diagnosis, "candidate_active");' "$WORK/out.json"
manager_run; json 'a.equal(r.result, "skipped"); a.equal(r.reason, "apply_unresolved");' "$WORK/run.json"
pre_id="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pre_snapshot)' "$PROKOP_AUTOTUNE_APPLY_STATE")"
ucode -L "$LIB" "$LIB/config/snapshots.uc" restore "$pre_id" > "$WORK/restore.json" || true
json 'a.equal(r.status, "success");' "$WORK/restore.json"
at status; json 'a.equal(r.resolved, true); a.equal(r.diagnosis, "not_applied");' "$WORK/out.json"
manager_run; json 'a.equal(r.result, "completed", JSON.stringify(r));' "$WORK/run.json"
at apply "$WORK/plan.json"; json 'a.equal(r.status, "applied");' "$WORK/out.json"
crash_in_verification
sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '40'/" "$PROKOP_CONFIG_FILE"
at status; json 'a.equal(r.resolved, true); a.equal(r.diagnosis, "superseded"); a.equal(r.unverified_strategy, true);' "$WORK/out.json"
crash_in_verification
at rollback; json 'a.equal(r.status, "rolled_back"); a.equal(r.reason, "operator_rollback");' "$WORK/out.json"
at status; json 'a.equal(r.resolved, true); a.equal(r.unverified_strategy, false);' "$WORK/out.json"
# A rolled back record is decided: the strategy chosen again by hand is the
# operator's, and nothing objects to it.
sed -i "s|option nfqws_opt '$FAKE'|option nfqws_opt '$MULTISPLIT'|" "$PROKOP_CONFIG_FILE"
at status; json 'a.equal(r.unverified_strategy, false);' "$WORK/out.json"
confirm; json 'a.equal(r.status, "confirmed", JSON.stringify(r));' "$WORK/confirm.json"
sed -i "s|option nfqws_opt '$MULTISPLIT'|option nfqws_opt '$FAKE'|" "$PROKOP_CONFIG_FILE"
manager_run; json 'a.equal(r.result, "completed");' "$WORK/run.json"
ok "20c crash during verification -> blocks while the candidate is active; restore, edit or rollback unblocks the next run"

# 20e. A failed lifecycle transition kept its fail-closed guard (the DPI
#      guard table, or the transition guard chain): only a restart removes
#      it, and the snapshot restore refuses before any change. The operator's
#      rollback says so and leaves the record as it was; runs, probes and
#      applies wait for the restart with that reason, not as an outdated
#      recommendation (UC-019).
mkdir -p "$NFT_STATE/chains"
for kept in tables/ProkopTableDpiGuard chains/ProkopTable.prokop_transition_guard; do
  crash_in_verification
  touch "$NFT_STATE/$kept"
  candidate_hash="$(chash)"
  at rollback
  json 'a.equal(r.status, "failed", JSON.stringify(r)); a.match(r.reason, /runtime_guard_active$/);' "$WORK/out.json"
  json 'a.equal(r.phase, "verifying"); a.notEqual(r.status, "needs_attention");' "$PROKOP_AUTOTUNE_APPLY_STATE"
  [ "$(chash)" = "$candidate_hash" ] || fail "$kept: the refused rollback changed the configuration"
  at status; json 'a.equal(r.runtime_guard, true); a.ok(r.guards.length > 0);' "$WORK/out.json"
  manager_run; json 'a.equal(r.result, "skipped"); a.equal(r.reason, "runtime_guard_active");' "$WORK/run.json"
  rm -f "$NFT_STATE/$kept"
  at rollback; json 'a.equal(r.status, "rolled_back");' "$WORK/out.json"
  reset_apply; plan_ready; touch "$NFT_STATE/$kept"; at apply "$WORK/plan.json"
  json 'a.equal(r.status, "stale"); a.equal(r.reason, "runtime_guard_active");' "$WORK/out.json"
  { [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ]; } || fail "$kept: applied over a kept runtime guard"
  rm -f "$NFT_STATE/$kept"
done
ok "20e runtime guard kept by a failed transition -> rollback refused without touching the record, runs and applies wait for a restart"

# 20d. An unreadable or empty apply record is needs_attention, never "no
#      record" (UC-069): runs and applies wait, the rollback path stays. The
#      operator's rollback brings back the last-known-working configuration
#      (nothing confirmed the candidate it may hide) and sets the record aside.
for content in '' 'garbage{'; do
  reset_apply; plan_ready; printf '%s' "$content" > "$PROKOP_AUTOTUNE_APPLY_STATE"
  at status
  json 'a.equal(r.resolved, false); a.equal(r.diagnosis, "state_unreadable"); a.equal(r.state.phase, "needs_attention"); a.equal(r.state.reason, "apply_state_unreadable");' "$WORK/out.json"
  manager_run; json 'a.equal(r.result, "skipped"); a.equal(r.reason, "apply_unresolved");' "$WORK/run.json"
  at apply "$WORK/plan.json"
  json 'a.equal(r.status, "failed"); a.equal(r.reason, "previous_apply_unresolved"); a.equal(r.diagnosis, "state_unreadable");' "$WORK/out.json"
  { [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ]; } || fail "'$content': applied over an unreadable record"
  at rollback
  json 'a.equal(r.status, "rolled_back"); a.equal(r.reason, "apply_state_unreadable"); a.equal(r.rollback.status, "not_needed");' "$WORK/out.json"
  [ "$(reloads)" = 0 ] || fail "'$content': the last-known-working configuration was reloaded although active"
  [ "$(cat "$PROKOP_AUTOTUNE_APPLY_STATE.corrupt")" = "$content" ] || fail "'$content': the unreadable record was not kept aside"
  at status; json 'a.equal(r.resolved, true);' "$WORK/out.json"
  at apply "$WORK/plan.json"; json 'a.equal(r.status, "applied");' "$WORK/out.json"
done
reset_apply; printf 'garbage{' > "$PROKOP_AUTOTUNE_APPLY_STATE"
sed -i "s|option nfqws_opt '$FAKE'|option nfqws_opt '$MULTISPLIT'|" "$PROKOP_CONFIG_FILE"
at rollback
json 'a.equal(r.status, "rolled_back"); a.equal(r.rollback.status, "success");' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 1 ] && [ "$(lkg)" = "$PRE_LKG" ]; } || fail "the rollback of an unreadable record did not restore the last-known-working configuration"
ok "20d unreadable apply record -> needs_attention: runs and applies wait; the rollback restores last-known-working and sets it aside"

# 20e. The operator's rollback from the page (prokop autotune_rollback, the
#      admin CLI) after a crash during verification: the page names the
#      unresolved apply and offers the rollback; afterwards the pre-apply
#      configuration runs, the record is settled and nothing is offered.
crash_in_verification
manager_status
json 'a.equal(r.apply.resolved, false); a.equal(r.apply.diagnosis, "candidate_active"); a.equal(r.apply.rollback, true);
  a.equal(r.apply.group, "Dpi"); a.equal(r.apply.candidate, "multisplit"); a.equal(r.apply.phase, "verifying");' "$WORK/mstatus.json"
! grep -q "$SECRET" "$WORK/mstatus.json" || fail "the autotune status leaks the configuration"
manager_env ucode "$ROOT/prokop/files/usr/bin/prokop" autotune_rollback > "$WORK/rb.json" || true
json 'a.equal(r.status, "ok"); a.equal(r.result, "rolled_back"); a.equal(r.group, "Dpi"); a.equal(r.candidate, "multisplit"); a.equal(r.restored, true);' "$WORK/rb.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "the operator rollback did not restore the pre-apply configuration"
[ "$(dpi_args)" = "$ZAPRET_NFQWS_BIN --qnum=4000 --dpi-desync-fwmark=0x40000000 $FAKE " ] || fail "the operator rollback left the candidate runtime"
manager_status
json 'a.equal(r.apply.resolved, true); a.equal(r.apply.rollback, false); a.equal(r.apply.phase, "rolled_back");
  a.equal(r.groups.Dpi.last_apply.status, "rolled_back"); a.ok(r.groups.Dpi.cooldowns.multisplit > Date.now() / 1000);' "$WORK/mstatus.json"
ok "20e operator rollback through prokop autotune_rollback -> pre-apply configuration, record settled, candidate paused"

# 20f. The configuration is edited while an apply still verifies its
#      candidate: the reload of that edit ends while the apply runs. The file
#      is no longer the candidate, yet nothing is confirmed until the apply
#      has settled (autotune_apply_in_progress, UC-020).
reset_apply; plan_ready; export PROD_SLEEP=1
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do grep -q 'curl production' "$STUB_LOG/curl.log" 2>/dev/null && break; sleep 0.05; done
json 'a.equal(r.phase, "verifying");' "$PROKOP_AUTOTUNE_APPLY_STATE"
sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '50'/" "$PROKOP_CONFIG_FILE"
confirm
kill -0 "$runner" 2>/dev/null || fail "fixture: the apply ended before the confirmation was asked for"
json 'a.equal(r.status, "not_confirmed"); a.equal(r.reason, "autotune_apply_in_progress");' "$WORK/confirm.json"
[ "$(lkg)" = "$PRE_LKG" ] || fail "an edit confirmed while an apply was still verifying"
wait "$runner" || true; unset PROD_SLEEP
json 'a.equal(r.status, "needs_attention"); a.equal(r.reason, "config_changed_during_verification");' "$WORK/out.json"
confirm; json 'a.equal(r.status, "confirmed");' "$WORK/confirm.json"
ok "20f edit while an apply verifies -> not confirmed until the apply settles, then the edit is confirmed"

# 20g. A rollback is offered only while there is a snapshot to return to: the
#      recorded before-autotune snapshot, else the last-known-working one
#      while it still holds the pre-apply configuration; for an unreadable
#      record the last-known-working one. Without it the page offers no
#      rollback that can only fail. An unreadable record whose
#      last-known-working snapshot is gone too is no dead end: a snapshot
#      restored in History becomes last-known-working, and the rollback then
#      sets the record aside.
crash_in_verification
pre_id="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pre_snapshot)' "$PROKOP_AUTOTUNE_APPLY_STATE")"
at status; json 'a.equal(r.rollback_source_present, true);' "$WORK/out.json"
rm -f "$PROKOP_SNAPSHOT_DIR/$pre_id.json"
at status; json 'a.equal(r.pre_snapshot_present, false); a.equal(r.rollback_source_present, true);' "$WORK/out.json"
manager_status; json 'a.equal(r.apply.rollback, true);' "$WORK/mstatus.json"
rm -f "$PROKOP_SNAPSHOT_DIR/$PRE_LKG.json"
at status; json 'a.equal(r.resolved, false); a.equal(r.diagnosis, "candidate_active"); a.equal(r.rollback_source_present, false);' "$WORK/out.json"
manager_status; json 'a.equal(r.apply.resolved, false); a.equal(r.apply.rollback, false);' "$WORK/mstatus.json"
at rollback; json 'a.equal(r.status, "failed"); a.equal(r.reason, "pre_apply_snapshot_missing");' "$WORK/out.json"
reset_apply; rm -f "$PROKOP_AUTOTUNE_APPLY_STATE.corrupt"
printf 'garbage{' > "$PROKOP_AUTOTUNE_APPLY_STATE"; rm -f "$PROKOP_SNAPSHOT_DIR/last-known-working"
at status; json 'a.equal(r.diagnosis, "state_unreadable"); a.equal(r.rollback_source_present, false);' "$WORK/out.json"
manager_status; json 'a.equal(r.apply.resolved, false); a.equal(r.apply.rollback, false);' "$WORK/mstatus.json"
at rollback; json 'a.equal(r.status, "failed"); a.equal(r.reason, "last_known_working_missing");' "$WORK/out.json"
[ ! -e "$PROKOP_AUTOTUNE_APPLY_STATE.corrupt" ] || fail "a refused rollback set the unreadable record aside"
ucode -L "$LIB" "$LIB/config/snapshots.uc" restore "$PRE_LKG" > "$WORK/restore.json" || true
json 'a.equal(r.status, "success");' "$WORK/restore.json"
[ "$(lkg)" = "$PRE_LKG" ] || fail "the restored snapshot did not become last-known-working"
at status; json 'a.equal(r.rollback_source_present, true);' "$WORK/out.json"
manager_status; json 'a.equal(r.apply.rollback, true);' "$WORK/mstatus.json"
at rollback; json 'a.equal(r.status, "rolled_back"); a.equal(r.rollback.status, "not_needed");' "$WORK/out.json"
at status; json 'a.equal(r.resolved, true);' "$WORK/out.json"
ok "20g rollback offered only with a snapshot to return to; an unreadable record without last-known-working is settled after a restore in History"

# Review hardening -------------------------------------------------------------

# Sing-box semantics: disable_quic reject rule (fixture) is skipped for TCP;
# any other protocol matcher is undecidable; ".suffix" matches subdomains only.
reset_apply; node -e 'const fs=require("fs");const f=process.argv[1];const c=JSON.parse(fs.readFileSync(f,"utf8"));c.route.rules.splice(3,0,{inbound:"tproxy-in",protocol:["tls"],action:"route",outbound:"main-out"});fs.writeFileSync(f,JSON.stringify(c))' "$PROKOP_AUTOTUNE_SINGBOX_CONFIG"
selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.equal(r.reason, "rule_owner_undecidable:protocol_matcher");' "$WORK/out.json"
reset_apply; sed -i 's/"domain_suffix":\["example.com"\]/"domain_suffix":[".example.com"]/' "$PROKOP_AUTOTUNE_SINGBOX_CONFIG"
selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.equal(r.reason, "rule_owner_undecidable:undecidable_matcher");' "$WORK/out.json"
selection multisplit www.example.com; at plan "$WORK/selection.json"
json 'a.equal(r.status, "ready"); a.equal(r.owner.section, "Dpi");' "$WORK/out.json"
ok "sing-box semantics: quic reject skipped for TCP, other protocol matcher undecidable, leading-dot suffix = subdomains only"

# Candidate generation: private package name, never the prokop package.
reset_apply; plan_ready
{ grep -q 'set prokop_autotune.Dpi.nfqws_opt=' "$STUB_LOG/uci.log" && grep -q 'commit prokop_autotune' "$STUB_LOG/uci.log" &&
  ! grep -q ' prokop\.' "$STUB_LOG/uci.log"; } || fail "candidate not generated under the private package"
ok "candidate generated under a private uci package (pending /tmp/.uci/prokop changes cannot join)"

# Baseline: the file must be the last-known-working configuration.
reset_apply; sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '30'/" "$PROKOP_CONFIG_FILE"; edited="$(chash)"
plan_ready; json 'a.equal(r.status, "ready");' "$WORK/plan.json"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "config_not_last_known_good");' "$WORK/out.json"
{ [ "$(chash)" = "$edited" ] && [ "$(reloads)" = 0 ] && [ "$(snaps)" = 1 ]; } || fail "unreloaded edit rode along"
reset_apply; printf "\toption shutdown_correctly '1'\n" > "$WORK/sc"; sed -i "/option dns_server/r $WORK/sc" "$PROKOP_CONFIG_FILE"
plan_ready; at apply "$WORK/plan.json"
json 'a.equal(r.status, "applied", JSON.stringify(r).slice(0, 300));' "$WORK/out.json"
ok "committed-but-unreloaded config -> stale; lifecycle shutdown_correctly bookkeeping is not a user change"

# Baseline: the rule's runtime must be on the planned strategy.
reset_apply; plan_ready
sed "s|option nfqws_opt '$FAKE'|option nfqws_opt '$MULTISPLIT'|" "$PROKOP_CONFIG_FILE" > "$WORK/other.conf"
PROKOP_CONFIG_FILE="$WORK/other.conf" "$STATE/start-dpi"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "runtime_not_on_planned_strategy");' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ] && [ "$(snaps)" = 1 ]; } || fail "incoherent runtime applied"
ok "runtime not on the planned strategy -> stale, no mutation"

# Lifecycle actions: a live reload lock blocks; its owner drains the queue.
reset_apply; plan_ready; mkdir -p "$PROKOP_RELOAD_LOCK_DIR"; sleep 30 & holder=$!; echo "$holder" > "$PROKOP_RELOAD_LOCK_DIR/pid"
touch "$PROKOP_PENDING_RELOAD_FILE"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "service_action_in_progress");' "$WORK/out.json"
[ "$(reloads)" = 0 ] || fail "applied during a lifecycle action"
kill "$holder"; wait "$holder" 2>/dev/null || true
# A queued reload that no live action owns (reload.pending left behind, the
# lock free) is no refusal: the apply's own reload takes the lock and, as
# init.d does at the end of every reload, drains the queue while the guard
# still stands; nothing confirms last-known-working meanwhile. The operator's
# rollback, a recovery, is not refused by it either.
cat > "$WORK/reload-drain" <<'SH'
#!/usr/bin/env bash
"$WORK_RELOAD" "$@" || exit
[ -e "$PROKOP_PENDING_RELOAD_FILE" ] || exit 0
rm -f "$PROKOP_PENDING_RELOAD_FILE"; echo "drained $*" >> "$STUB_LOG/drain.log"
"$WORK_RELOAD" pending
SH
chmod +x "$WORK/reload-drain"
touch "$PROKOP_PENDING_RELOAD_FILE"
WORK_RELOAD="$WORK/reload" PROKOP_RELOAD_COMMAND="$WORK/reload-drain" at apply "$WORK/plan.json"
json 'a.equal(r.status, "applied", JSON.stringify(r).slice(0, 300));' "$WORK/out.json"
grep -q '^drained reload autotune$' "$STUB_LOG/drain.log" || fail "the apply's reload did not drain the queued reload"
touch "$PROKOP_PENDING_RELOAD_FILE"; WORK_RELOAD="$WORK/reload" PROKOP_RELOAD_COMMAND="$WORK/reload-drain" at rollback
json 'a.equal(r.status, "rolled_back", JSON.stringify(r).slice(0, 300));' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ ! -e "$PROKOP_PENDING_RELOAD_FILE" ]; } || fail "the rollback did not restore and drain"
touch "$PROKOP_PENDING_RELOAD_FILE"; at status
json 'a.equal(r.service_action, null);' "$WORK/out.json"
rm -f "$PROKOP_PENDING_RELOAD_FILE"
ok "live reload lock -> stale; a queued reload without a live owner is drained by the apply's own reload, never refused"

# An explicit stop holds the runtime down until an explicit start (D-15,
# UC-056): an apply and an operator rollback are refused before any change.
reset_apply; plan_ready; : > "$PROKOP_STOP_REQUESTED_FILE"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "service_stopped");' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ] && [ "$(snaps)" = 1 ]; } || fail "applied while stopped by the user"
at status
json 'a.equal(r.service_stopped, true);' "$WORK/out.json"
rm -f "$PROKOP_STOP_REQUESTED_FILE"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "applied");' "$WORK/out.json"
applied_hash="$(chash)"; : > "$PROKOP_STOP_REQUESTED_FILE"; at rollback
json 'a.equal(r.status, "failed"); a.equal(r.reason, "service_stopped");' "$WORK/out.json"
{ [ "$(chash)" = "$applied_hash" ] && [ "$(reloads)" = 1 ]; } || fail "rolled back while stopped by the user"
rm -f "$PROKOP_STOP_REQUESTED_FILE"
ok "stopped by the user -> apply and rollback refused, no mutation"

# Prokop not started since boot (no explicit start is recorded) and down (no
# production table) is held down the same way (D-15(a)). A runtime that went
# down after an explicit start is not "stopped".
reset_apply; plan_ready; rm -f "$NFT_STATE/tables/ProkopTable"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "service_stopped");' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ] && [ "$(snaps)" = 1 ]; } || fail "applied to a Prokop not started since boot"
at status
json 'a.equal(r.service_stopped, true);' "$WORK/out.json"
: > "$PROKOP_EXPLICIT_START_FILE"; at status
json 'a.equal(r.service_stopped, false);' "$WORK/out.json"
touch "$NFT_STATE/tables/ProkopTable"; rm -f "$PROKOP_EXPLICIT_START_FILE"
ok "not started since boot and down -> apply refused as stopped, no mutation"

# The plan file is untrusted input.
reset_apply; plan_ready
craft() { node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));(new Function("p",process.argv[3]))(p);fs.writeFileSync(process.argv[2],JSON.stringify(p))' "$WORK/plan.json" "$WORK/crafted.json" "$1"; }
for edit in 'p.selected="direct";p.changes[0].to=""' 'p.changes[0].section="Game"' 'p.config_hash=""' 'p.candidate_hash=""' 'p.selection.confidence="low"' 'p.changes[0].option="enabled"'; do
  craft "$edit"; at apply "$WORK/crafted.json"
  json 'a.equal(r.status, "failed", JSON.stringify(r)); a.equal(r.reason, "invalid_plan");' "$WORK/out.json"
done
craft 'p.selected="udp_fake"'; at apply "$WORK/crafted.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "candidate_invalid");' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ] && [ "$(snaps)" = 1 ]; } || fail "crafted plan mutated production"
ok "crafted plans (direct, other rule, empty hashes, weak confidence, other option, UDP candidate) -> no mutation"

# A refusal never erases the record of an earlier apply.
reset_apply; plan_ready; at apply "$WORK/plan.json"; json 'a.equal(r.status, "applied");' "$WORK/out.json"
at apply "$WORK/plan.json"; json 'a.equal(r.status, "stale"); a.equal(r.reason, "config_changed");' "$WORK/out.json"
json 'a.equal(r.phase, "applied"); a.equal(r.last_attempt.status, "stale"); a.equal(r.last_attempt.reason, "config_changed");' "$PROKOP_AUTOTUNE_APPLY_STATE"
at rollback
json 'a.equal(r.status, "rolled_back"); a.equal(r.reason, "operator_rollback"); a.equal(r.rollback.config_hash_restored, true);' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "operator rollback after a refused attempt"
ok "refused attempt keeps the applied record (last_attempt); operator rollback still restores"

# Exit codes: 0 only for the requested outcome.
reset_apply; plan_ready; rc=0; ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" || rc=$?
json 'a.equal(r.status, "applied");' "$WORK/out.json"
[ "$rc" = 0 ] || fail "applied exit code $rc"
reset_apply; plan_ready; export PROD_PLAN=reset; rc=0; ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" || rc=$?
json 'a.equal(r.status, "rolled_back");' "$WORK/out.json"
[ "$rc" = 1 ] || fail "rolled_back exit code $rc"
ok "exit code 0 only for applied/no_change_required (rolled_back exits 1)"

# LKG confirmation failure after a verified apply -> needs_attention, rollback possible.
reset_apply; plan_ready; export CONFIRM_FAIL=1; at apply "$WORK/plan.json"; unset CONFIRM_FAIL
json 'a.equal(r.status, "needs_attention"); a.equal(r.reason, "lkg_confirm_failed"); a.equal(r.applied, true); a.equal(r.lkg, "failed");' "$WORK/out.json"
[ "$(lkg)" = "$PRE_LKG" ] || fail "LKG moved although confirmation failed"
at apply "$WORK/plan.json"; json 'a.equal(r.status, "failed"); a.equal(r.reason, "previous_apply_unresolved");' "$WORK/out.json"
at rollback; json 'a.equal(r.status, "rolled_back");' "$WORK/out.json"
ok "LKG confirmation failure -> needs_attention (LKG unchanged), blocks new applies, explicit rollback restores"

# A config edit during verification is never confirmed as last-known-working.
reset_apply; plan_ready; export PROD_SLEEP=1
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do grep -q 'curl production' "$STUB_LOG/curl.log" 2>/dev/null && break; sleep 0.05; done
sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '31'/" "$PROKOP_CONFIG_FILE"
wait "$runner" || true; unset PROD_SLEEP
json 'a.equal(r.status, "needs_attention"); a.equal(r.reason, "config_changed_during_verification"); a.equal(r.lkg, "not_confirmed");' "$WORK/out.json"
[ "$(lkg)" = "$PRE_LKG" ] || fail "an unverified edit was confirmed"
ok "config edited during verification -> needs_attention, LKG not confirmed"

# UC-017: the candidate fails its verification, and the configuration was
# edited meanwhile (here right before the rollback reads it). The automatic
# rollback only ever replaces the candidate it wrote: the edit stays, saved
# as a snapshot, nothing is restored, last-known-working stays; the record no
# longer owns the configuration (superseded) and blocks nothing.
reset_apply; plan_ready; export PROD_PLAN=reset EDIT_BEFORE_RESTORE=1; : > "$STUB_LOG/health.log"
at apply "$WORK/plan.json"; unset PROD_PLAN EDIT_BEFORE_RESTORE
json 'a.equal(r.status, "needs_attention", JSON.stringify(r).slice(0, 500)); a.equal(r.reason, "verification_failed:config_changed_during_transaction");
  a.equal(r.applied, false); a.ok(!r.verification.ok); a.equal(r.rollback.status, "needs_attention"); a.equal(r.rollback.reason, "config_changed_during_transaction");
  a.match(r.rollback.saved_snapshot, /^[0-9]+_[0-9]+$/);' "$WORK/out.json"
grep -q "option dns_rewrite_ttl '31'" "$PROKOP_CONFIG_FILE" || fail "the automatic rollback overwrote an edit made during verification"
[ "$(reloads)" = 1 ] || fail "a rollback reload ran over the edit"
[ "$(lkg)" = "$PRE_LKG" ] || fail "last-known-working moved"
saved="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).rollback.saved_snapshot)' "$WORK/out.json")"
node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(s.reason!=="concurrent-change"||!s.content.includes("dns_rewrite_ttl '"'"'31'"'"'"))process.exit(1)' "$PROKOP_SNAPSHOT_DIR/$saved.json" ||
  fail "the edit is not saved as a snapshot"
! grep -q 'restore success' "$STUB_LOG/health.log" || fail "a restore was recorded as a success"
# The edit was made on top of the candidate, so the rule still runs the
# strategy that has just failed its production check: the next start or
# reload does not make that configuration last-known-working, and the status
# says so (the record itself no longer blocks autotune, UC-020). A disabled
# rule runs no strategy; once the rule's strategy is changed, nothing objects
# any more.
at status; json 'a.equal(r.diagnosis, "superseded"); a.equal(r.resolved, true); a.equal(r.unverified_strategy, true);' "$WORK/out.json"
grep -qF "option nfqws_opt '$MULTISPLIT'" "$PROKOP_CONFIG_FILE" || fail "fixture: the failed strategy is not in the edited configuration"
confirm; json 'a.equal(r.status, "not_confirmed"); a.equal(r.reason, "autotune_apply_unresolved");' "$WORK/confirm.json"
[ "$(lkg)" = "$PRE_LKG" ] || fail "a start or reload confirmed a configuration that still runs the strategy that failed verification"
dpi_enabled() { sed -i "/^config section 'Dpi'/,/^\$/ s/option enabled '[01]'/option enabled '$1'/" "$PROKOP_CONFIG_FILE"; }
dpi_enabled 0
at status; json 'a.equal(r.resolved, true); a.equal(r.unverified_strategy, false);' "$WORK/out.json"
confirm; json 'a.equal(r.status, "confirmed", JSON.stringify(r));' "$WORK/confirm.json"
dpi_enabled 1
at status; json 'a.equal(r.unverified_strategy, true);' "$WORK/out.json"
confirm; json 'a.equal(r.status, "not_confirmed"); a.equal(r.reason, "autotune_apply_unresolved");' "$WORK/confirm.json"
sed -i "s|option nfqws_opt '$MULTISPLIT'|option nfqws_opt '$FAKE'|" "$PROKOP_CONFIG_FILE"
at status; json 'a.equal(r.resolved, true); a.equal(r.unverified_strategy, false);' "$WORK/out.json"
confirm; json 'a.equal(r.status, "confirmed", JSON.stringify(r));' "$WORK/confirm.json"
ok "UC-017 verification failed + configuration edited -> no automatic rollback over the edit, needs_attention, edit saved, the failed strategy never confirmed"

# The same for the operator's rollback: between its check that the
# configuration is the candidate and the restore, an edit lands. The restore
# refuses before any change; the record stays as it was.
reset_apply; plan_ready; at apply "$WORK/plan.json"; json 'a.equal(r.status, "applied");' "$WORK/out.json"
: > "$STUB_LOG/reload.log"
EDIT_BEFORE_RESTORE=1 at rollback
json 'a.equal(r.status, "failed", JSON.stringify(r)); a.equal(r.reason, "rollback_not_started:config_changed_during_transaction");' "$WORK/out.json"
grep -q "option dns_rewrite_ttl '31'" "$PROKOP_CONFIG_FILE" || fail "the operator rollback overwrote an edit"
[ "$(reloads)" = 0 ] || fail "the operator rollback reloaded over an edit"
json 'a.equal(r.phase, "applied"); a.equal(r.last_attempt.reason, "rollback_config_changed_during_transaction");' "$PROKOP_AUTOTUNE_APPLY_STATE"
ok "UC-017 operator rollback racing an edit -> refused before any change, edit kept, record unchanged"

# The edit is committed while the rollback's own reload runs: the rollback
# wrote the pre-apply configuration and reloaded it, but cannot tell whether
# the runtime loaded that or the edit. The record says the rollback started
# (config_changed_during_rollback), the edit is kept and saved, LKG stays.
reset_apply; plan_ready; export PROD_PLAN=reset EDIT_ON_RELOAD=2
at apply "$WORK/plan.json"; unset PROD_PLAN EDIT_ON_RELOAD
json 'a.equal(r.status, "needs_attention", JSON.stringify(r).slice(0, 500)); a.equal(r.reason, "verification_failed:config_changed_during_rollback");
  a.equal(r.rollback.reason, "config_changed_during_transaction"); a.equal(r.rollback.guard, "inactive");
  a.match(r.rollback.saved_snapshot, /^[0-9]+_[0-9]+$/);' "$WORK/out.json"
grep -q "option dns_rewrite_ttl '31'" "$PROKOP_CONFIG_FILE" && grep -qF "option nfqws_opt '$FAKE'" "$PROKOP_CONFIG_FILE" ||
  fail "an edit during the rollback's reload: not kept on the pre-apply configuration"
[ "$(reloads)" = 2 ] && [ "$(lkg)" = "$PRE_LKG" ] || fail "an edit during the rollback's reload: $(reloads) reloads, LKG moved"
at status; json 'a.equal(r.diagnosis, "superseded"); a.equal(r.resolved, true); a.equal(r.unverified_strategy, false);' "$WORK/out.json"
# The same during the operator's rollback of an applied candidate.
reset_apply; plan_ready; at apply "$WORK/plan.json"; json 'a.equal(r.status, "applied");' "$WORK/out.json"
: > "$STUB_LOG/reload.log"
EDIT_ON_RELOAD=1 at rollback
json 'a.equal(r.status, "needs_attention", JSON.stringify(r).slice(0, 500)); a.equal(r.reason, "operator_rollback:config_changed_during_rollback");' "$WORK/out.json"
grep -q "option dns_rewrite_ttl '31'" "$PROKOP_CONFIG_FILE" && [ "$(reloads)" = 1 ] || fail "an edit during the operator rollback's reload was overwritten"
ok "edit committed during the rollback's own reload -> kept, the record names a rollback that started (automatic and operator)"

# UC-068: changes staged with uci (no commit) would ride along any reload.
# The rollback's restore refuses while they exist: the candidate stays, the
# record stays unresolved (it blocks), and once the staged changes are
# committed or reverted the operator's rollback completes.
reset_apply; plan_ready; export PROD_PLAN=reset STAGE_BEFORE_RESTORE=1
at apply "$WORK/plan.json"; unset PROD_PLAN STAGE_BEFORE_RESTORE
json 'a.equal(r.status, "needs_attention", JSON.stringify(r).slice(0, 500)); a.equal(r.reason, "verification_failed:rollback_failed");
  a.equal(r.rollback.reason, "uncommitted_uci_changes");' "$WORK/out.json"
[ "$(reloads)" = 1 ] || fail "a restore reloaded with staged uci changes"
[ "$(lkg)" = "$PRE_LKG" ] || fail "last-known-working moved"
at status; json 'a.equal(r.diagnosis, "candidate_active"); a.equal(r.resolved, false);' "$WORK/out.json"
at rollback; json 'a.equal(r.status, "failed"); a.equal(r.reason, "rollback_not_started:uncommitted_uci_changes");' "$WORK/out.json"
rm -f "$WORK/uci-save/prokop"
at rollback; json 'a.equal(r.status, "rolled_back", JSON.stringify(r).slice(0, 400));' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "the rollback after the staged changes were reverted did not restore the pre-apply configuration"
ok "UC-068 staged uci changes -> no restore under them; rollback completes once they are gone"

# Ctrl-C / SSH hangup reach the whole process group: the transaction runs in
# its own session and completes; only the verdict is missing.
reset_apply; plan_ready; export RELOAD_SLEEP=2
setsid ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do grep -q '^reload' "$STUB_LOG/reload.log" 2>/dev/null && break; sleep 0.05; done
kill -HUP -- "-$runner" 2>/dev/null || true; kill -INT -- "-$runner" 2>/dev/null || true
wait "$runner" || true; unset RELOAD_SLEEP
json 'a.equal(r.status, "failed", JSON.stringify(r).slice(0, 400)); a.equal(r.reason, "interrupted_after_apply"); a.equal(r.reload.status, "success"); a.equal(r.rollback_available, true);' "$WORK/out.json"
{ [ ! -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] && [ "$(reloads)" = 1 ] && [ "$(lkg)" = "$PRE_LKG" ]; } || fail "group signal broke the transaction"
[ "$(dpi_args)" = "$ZAPRET_NFQWS_BIN --qnum=4000 --dpi-desync-fwmark=0x40000000 $MULTISPLIT " ] || fail "reload did not complete"
at rollback; json 'a.equal(r.status, "rolled_back");' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "rollback after group signal"
ok "SIGHUP/SIGINT to the process group during reload -> transaction completes, verdict missing, explicit rollback"

# Second review ----------------------------------------------------------------

sbrule() { # sbrule <index> <json rule>: insert a route rule into the generated config
  node -e 'const fs=require("fs");const f=process.argv[1];const c=JSON.parse(fs.readFileSync(f,"utf8"));c.route.rules.splice(+process.argv[2],0,JSON.parse(process.argv[3]));fs.writeFileSync(f,JSON.stringify(c))' "$PROKOP_AUTOTUNE_SINGBOX_CONFIG" "$1" "$2"
}

# FakeIP: a connection reaches sing-box as the domain, so an ip_cidr rule
# above never takes it; real-address targets are not applied at all.
reset_apply; sbrule 3 '{"inbound":"tproxy-in","ip_cidr":["93.184.0.0/16"],"action":"route","outbound":"Game-out"}'
plan_ready; json 'a.equal(r.status, "ready"); a.equal(r.owner.section, "Dpi"); a.equal(r.production_dns, "fakeip");' "$WORK/plan.json"
export LOCAL_DIG_ANSWER='93.184.216.34\n'
selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.equal(r.reason, "target_not_fakeip_routed"); a.equal(r.production_dns, "real_address");' "$WORK/out.json"
selection direct; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.equal(r.reason, "target_not_fakeip_routed");' "$WORK/out.json"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "target_not_fakeip_routed");' "$WORK/out.json"
unset LOCAL_DIG_ANSWER
reset_apply; sbrule 3 '{"inbound":"tproxy-in","action":"resolve","domain_suffix":["example.com"]}'
selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.equal(r.reason, "rule_owner_undecidable:resolve_rule");' "$WORK/out.json"
[ "$(reloads)" = 0 ] || fail "FakeIP ownership cases mutated"
ok "FakeIP ownership: ip_cidr above never owns a FakeIP target, resolve rule undecidable, real-address target (direct too) not judged"

# The rule path is proven by the sing-box tracker, not by queue counters.
reset_apply; plan_ready; export PROD_CHAINS='["main-out"]'; at apply "$WORK/plan.json"
json 'a.equal(r.status, "rolled_back"); const c = r.verification.checks.find((x) => x.name === "traffic_rule_path"); a.equal(c.ok, false); a.equal(c.detail, "main-out");
  a.equal(r.verification.checks.find((x) => x.name === "traffic_dpi_queue").ok, true);' "$WORK/out.json"
grep -q "curl hold 4[0-9]* example.com" "$STUB_LOG/curl.log" || fail "no held production connection"
! grep 'curl hold' "$STUB_LOG/curl.log" | grep -q ' 610[0-3][0-9] ' || fail "held connection used the isolation ports"
reset_apply; plan_ready; export CLASH_DOWN=1; at apply "$WORK/plan.json"
json 'a.equal(r.status, "rolled_back"); a.equal(r.verification.checks.find((x) => x.name === "traffic_rule_path").detail, "clash_api_unreachable");' "$WORK/out.json"
ok "rule path proven by the tracker: other outbound or no tracker -> rolled_back even with queue counters satisfied"

# A reload that was only queued never counts as applied (UC-005, UC-047).
reset_apply; plan_ready; : > "$STUB_LOG/reload.args"; echo "q 0" > "$STATE/reload.plan"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "reload_queued_recovered"); a.equal(r.reload.reason, "target_reload_queued"); a.equal(r.config_restored, true); a.equal(r.verification, null);' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ ! -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ]; } || fail "queued reload left the candidate"
[ "$(dpi_args)" = "$ZAPRET_NFQWS_BIN --qnum=4000 --dpi-desync-fwmark=0x40000000 $FAKE " ] || fail "runtime changed by a queued reload"
[ "$(sort -u "$STUB_LOG/reload.args")" = "reload autotune" ] || fail "apply did not pass its reason to init.d: $(cat "$STUB_LOG/reload.args")"
reset_apply; plan_ready; echo "t 0" > "$STATE/reload.plan"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "reload_queued_recovered"); a.equal(r.reload.reason, "target_reload_queued");' "$WORK/out.json"
[ "$(dpi_args)" = "$ZAPRET_NFQWS_BIN --qnum=4000 --dpi-desync-fwmark=0x40000000 $FAKE " ] || fail "runtime changed by a token-only queued reload"
for plan in "q q" "m m" "1 q" "t t"; do
  reset_apply; plan_ready; : > "$STUB_LOG/health.log"; echo "$plan" > "$STATE/reload.plan"; at apply "$WORK/plan.json"
  json 'a.equal(r.status, "needs_attention"); a.equal(r.reload.reason, "rollback_reload_queued"); a.equal(r.applied, false);' "$WORK/out.json"
  grep -q 'autotune_apply failure' "$STUB_LOG/health.log" || fail "$plan: queued reload not recorded as a failure"
  [ -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] || fail "$plan: guard released after an unconfirmed reload"
  [ "$(lkg)" = "$PRE_LKG" ] || fail "$plan: last-known-working moved by a queued reload"
  ! grep -q 'autotune_apply success' "$STUB_LOG/health.log" 2>/dev/null || fail "$plan: queued reload recorded as success"
done
ok "queued reload -> config put back and recovered; queued twice (token, same-second marker or token alone) -> needs_attention with the guard kept"

# Retention: room for the rollback's pre-restore snapshot is reserved.
reset_apply; plan_ready
for _ in $(seq 1 8); do ucode -L "$LIB" "$LIB/config/snapshots.uc" create manual > /dev/null || true; done
at apply "$WORK/plan.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "apply_failed:snapshot_retention_full");' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ]; } || fail "applied without rollback room"
reset_apply; plan_ready
for _ in $(seq 1 7); do ucode -L "$LIB" "$LIB/config/snapshots.uc" create manual > /dev/null || true; done
export PROD_PLAN=reset; at apply "$WORK/plan.json"
json 'a.equal(r.status, "rolled_back"); a.equal(r.rollback.lkg_is_pre_snapshot, true);' "$WORK/out.json"
[ -e "$PROKOP_SNAPSHOT_DIR/$(lkg).json" ] || fail "LKG names a removed snapshot"
reset_apply
sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '30'/" "$PROKOP_CONFIG_FILE"
target_id="$(ucode -L "$LIB" "$LIB/config/snapshots.uc" create automatic | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot.id)')"
write_config
for _ in $(seq 1 8); do ucode -L "$LIB" "$LIB/config/snapshots.uc" create manual > /dev/null || true; done
ucode -L "$LIB" "$LIB/config/snapshots.uc" restore "$target_id" > "$WORK/out.json" || true
json 'a.equal(r.status, "failed"); a.equal(r.reason, "pre_restore_snapshot_failed");' "$WORK/out.json"
{ [ -e "$PROKOP_SNAPSHOT_DIR/$target_id.json" ] && [ "$(lkg)" = "$PRE_LKG" ] && [ "$(chash)" = "$PRE_HASH" ]; } || fail "restore removed its own target"
ok "retention: no apply without rollback room; rollback LKG snapshot kept; a restore never deletes its target"

# Refusals of the transaction itself keep an earlier apply record.
reset_apply; plan_ready; at apply "$WORK/plan.json"; json 'a.equal(r.status, "applied");' "$WORK/out.json"
selection fake; at plan "$WORK/selection.json"; cp "$WORK/out.json" "$WORK/plan2.json"
json 'a.equal(r.status, "ready");' "$WORK/plan2.json"
export GUARD_FAIL=1; : > "$STUB_LOG/health.log"; at apply "$WORK/plan2.json"; unset GUARD_FAIL
json 'a.equal(r.status, "failed"); a.equal(r.reason, "apply_failed:guard_unavailable");' "$WORK/out.json"
json 'a.equal(r.phase, "applied"); a.equal(r.last_attempt.reason, "apply_failed:guard_unavailable");' "$PROKOP_AUTOTUNE_APPLY_STATE"
[ "$(reloads)" = 1 ] || fail "refused transaction reloaded"
[ ! -s "$STUB_LOG/health.log" ] || fail "health recorded a transaction that never wrote"
at rollback; json 'a.equal(r.status, "rolled_back");' "$WORK/out.json"
ok "transaction refusal before any write keeps the applied record (rollback still possible)"

# A configuration changed outside the apply supersedes its record.
reset_apply; plan_ready; export PROD_SLEEP=1
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do grep -q 'curl production' "$STUB_LOG/curl.log" 2>/dev/null && break; sleep 0.05; done
kill -TERM "$runner"; wait "$runner" || true; unset PROD_SLEEP
json 'a.equal(r.reason, "interrupted_after_apply");' "$WORK/out.json"
sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '45'/" "$PROKOP_CONFIG_FILE"
at status; json 'a.equal(r.config_is, "other"); a.equal(r.resolved, true);' "$WORK/out.json"
at apply "$WORK/plan.json"; json 'a.equal(r.status, "stale"); a.equal(r.reason, "config_changed");' "$WORK/out.json"
at rollback; json 'a.equal(r.status, "failed"); a.equal(r.reason, "rollback_needs_candidate_config");' "$WORK/out.json"
ok "config changed outside the apply -> record superseded (no dead end), no automatic rollback"

# Operator rollback without its snapshot changes nothing and blocks nothing.
reset_apply; plan_ready; at apply "$WORK/plan.json"; json 'a.equal(r.status, "applied");' "$WORK/out.json"
rm -f "$PROKOP_SNAPSHOT_DIR/$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pre_snapshot)' "$WORK/out.json").json"
at rollback; json 'a.equal(r.status, "failed"); a.equal(r.reason, "pre_apply_snapshot_missing");' "$WORK/out.json"
json 'a.equal(r.phase, "applied");' "$PROKOP_AUTOTUNE_APPLY_STATE"
at status; json 'a.equal(r.resolved, true);' "$WORK/out.json"
ok "operator rollback without the pre-apply snapshot -> refused, record stays applied"

# A hangup of the whole group during the checks -> interruption, not a stale
# reason. (Background jobs of a non-interactive shell start with SIGINT
# ignored, which apply.uc keeps; SIGHUP models the dropped SSH session.)
reset_apply; plan_ready; export DIG_SLEEP=2; : > "$STUB_LOG/dig.log"
setsid ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!; wait_until 30 checks_started || fail "apply did not reach its checks"
kill -HUP -- "-$runner" 2>/dev/null || true; wait "$runner" || true; unset DIG_SLEEP
json 'a.equal(r.status, "failed"); a.equal(r.reason, "interrupted_before_mutation");' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ]; } || fail "group interrupt mutated"
# An inherited "ignore" (nohup, trap '' HUP) is kept: a hangup does not abort.
reset_apply; plan_ready; export PROD_SLEEP=1
( trap '' HUP; exec ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" ) &
runner=$!
for _ in $(seq 1 200); do grep -q 'curl production' "$STUB_LOG/curl.log" 2>/dev/null && break; sleep 0.05; done
kill -HUP "$runner" 2>/dev/null || true; wait "$runner" || true; unset PROD_SLEEP
json 'a.equal(r.status, "applied");' "$WORK/out.json"
ok "group SIGHUP during checks -> interrupted_before_mutation; inherited SIG_IGN for HUP respected"

# Plan inputs: separate-value filter forms, uncommitted uci changes, resolver.
reset_apply "--filter-tcp=443 --dpi-desync=fake --filter-udp 443"; selection multisplit; at plan "$WORK/selection.json"
json 'a.equal(r.status, "not_applicable"); a.equal(r.reason, "strategy_unparsed");' "$WORK/out.json"
reset_apply; plan_ready; echo "prokop.Dpi.enabled='0'" > "$PROKOP_AUTOTUNE_UCI_SAVEDIR/prokop"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "stale"); a.equal(r.reason, "uncommitted_uci_changes");' "$WORK/out.json"
[ "$(reloads)" = 0 ] || fail "applied with uncommitted uci changes"
rm -f "$PROKOP_AUTOTUNE_UCI_SAVEDIR/prokop"
printf '{"status":"selected","selected":"multisplit","reason":"x","confidence":"high","target":{"host":"example.com","ip":"93.184.216.34"},"probes":[]}\n' > "$WORK/noresolver.json"
at plan "$WORK/noresolver.json"; json 'a.equal(r.status, "failed"); a.equal(r.reason, "resolver_missing");' "$WORK/out.json"
at plan "$WORK/noresolver.json" 192.0.2.53; json 'a.equal(r.status, "ready"); a.equal(r.target.resolver, "192.0.2.53");' "$WORK/out.json"
ok "plan inputs: '--filter-udp 443' form, uncommitted uci changes, missing resolver"

# Lost update: an edit made while the guard is being installed is never overwritten.
reset_apply; plan_ready; export GUARD_SLEEP=2; : > "$STUB_LOG/health.log"
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do [ -e "$STATE/guard.pid" ] && break; sleep 0.05; done
sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '15'/" "$PROKOP_CONFIG_FILE"; edited="$(chash)"
wait "$runner" || true; unset GUARD_SLEEP
json 'a.equal(r.status, "stale"); a.equal(r.reason, "config_changed");' "$WORK/out.json"
{ [ "$(chash)" = "$edited" ] && [ "$(reloads)" = 0 ] && [ ! -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ]; } || fail "concurrent edit overwritten"
! grep -q 'health restore' "$STUB_LOG/health.log" 2>/dev/null || fail "health recorded a transaction that never wrote"
ok "edit during guard installation -> stale, edit kept, guard released, no health event"

# Third review -----------------------------------------------------------------

# A hangup while the candidate is generated -> interruption, not uci_failed.
reset_apply; plan_ready; : > "$STUB_LOG/uci.log"; export UCI_SLEEP=3
setsid ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do grep -q 'set prokop_autotune' "$STUB_LOG/uci.log" 2>/dev/null && break; sleep 0.05; done
kill -HUP -- "-$runner" 2>/dev/null || true; wait "$runner" || true; unset UCI_SLEEP
json 'a.equal(r.status, "failed"); a.equal(r.reason, "interrupted_before_mutation");' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(reloads)" = 0 ] && [ "$(snaps)" = 1 ]; } || fail "interrupted candidate generation mutated"
ok "hangup during candidate generation -> interrupted_before_mutation"

# A manual LKG stays protected after confirmation: its slot is reserved too.
reset_apply; plan_ready
manual_id="$(ucode -L "$LIB" "$LIB/config/snapshots.uc" create manual | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot.id)')"
echo "$manual_id" > "$PROKOP_SNAPSHOT_DIR/last-known-working"
for _ in $(seq 1 7); do ucode -L "$LIB" "$LIB/config/snapshots.uc" create manual > /dev/null || true; done
at apply "$WORK/plan.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "apply_failed:snapshot_retention_full");' "$WORK/out.json"
reset_apply; plan_ready
manual_id="$(ucode -L "$LIB" "$LIB/config/snapshots.uc" create manual | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot.id)')"
echo "$manual_id" > "$PROKOP_SNAPSHOT_DIR/last-known-working"
for _ in $(seq 1 6); do ucode -L "$LIB" "$LIB/config/snapshots.uc" create manual > /dev/null || true; done
at apply "$WORK/plan.json"; json 'a.equal(r.status, "applied");' "$WORK/out.json"
at rollback; json 'a.equal(r.status, "rolled_back");' "$WORK/out.json"
ok "manual LKG: apply refused without room for the later operator rollback; with room, rollback works"

# A refused apply never evicts the earlier apply's pre-apply snapshot.
reset_apply; plan_ready; first_lkg="$PRE_LKG"
at apply "$WORK/plan.json"; json 'a.equal(r.status, "applied");' "$WORK/out.json"
ba1="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pre_snapshot)' "$WORK/out.json")"
selection fake; at plan "$WORK/selection.json"; cp "$WORK/out.json" "$WORK/plan2.json"
rm -f "$PROKOP_SNAPSHOT_DIR/$first_lkg.json"
sed -i "s/option dns_rewrite_ttl '60'/option dns_rewrite_ttl '33'/" "$PROKOP_CONFIG_FILE"
ucode -L "$LIB" "$LIB/config/snapshots.uc" create automatic > /dev/null
sed -i "s/option dns_rewrite_ttl '33'/option dns_rewrite_ttl '60'/" "$PROKOP_CONFIG_FILE"
for _ in $(seq 1 7); do ucode -L "$LIB" "$LIB/config/snapshots.uc" create manual > /dev/null || true; done
at apply "$WORK/plan2.json"
json 'a.equal(r.status, "failed"); a.equal(r.reason, "apply_failed:snapshot_retention_full");' "$WORK/out.json"
[ -e "$PROKOP_SNAPSHOT_DIR/$ba1.json" ] || fail "refused apply evicted the earlier pre-apply snapshot"
at rollback; json 'a.equal(r.status, "rolled_back");' "$WORK/out.json"
ok "earlier pre-apply snapshot kept through a refused apply; its rollback still works"

# Unresolved record whose before-autotune snapshot is gone -> LKG is the source.
reset_apply; plan_ready; export PROD_SLEEP=1
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do grep -q 'curl production' "$STUB_LOG/curl.log" 2>/dev/null && break; sleep 0.05; done
kill -TERM "$runner"; wait "$runner" || true; unset PROD_SLEEP
json 'a.equal(r.reason, "interrupted_after_apply");' "$WORK/out.json"
rm -f "$PROKOP_SNAPSHOT_DIR/$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pre_snapshot)' "$WORK/out.json").json"
at rollback
json 'a.equal(r.status, "rolled_back"); a.equal(r.rollback.config_hash_restored, true); a.equal(r.rollback.lkg_is_pre_snapshot, true);' "$WORK/out.json"
{ [ "$(chash)" = "$PRE_HASH" ] && [ "$(lkg)" = "$PRE_LKG" ]; } || fail "LKG fallback rollback"
ok "unresolved record without its pre-apply snapshot -> rolled back from the unchanged LKG snapshot"

# The transaction dies with its guard installed -> needs_attention, never "failed".
reset_apply; plan_ready; export GUARD_HOLD=3
ucode -L "$LIB" "$LIB/autotune/apply.uc" apply "$WORK/plan.json" > "$WORK/out.json" &
runner=$!
for _ in $(seq 1 200); do [ -e "$NFT_STATE/tables/ProkopConfigRestoreDpiGuard" ] && break; sleep 0.05; done
pkill -9 -f "$WORK/tmp/prokop-autotune-candidate" || true
wait "$runner" || true; unset GUARD_HOLD; sleep 3
json 'a.equal(r.status, "needs_attention"); a.equal(r.reason, "apply_failed:snapshot_tool_failed"); a.deepEqual(r.guards, ["ProkopConfigRestoreDpiGuard"]);' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "config changed"
at status; json 'a.equal(r.resolved, false); a.equal(r.diagnosis, "in_transaction");' "$WORK/out.json"
ok "transaction killed with the guard installed -> needs_attention (in_transaction), not a resolved failure"

# A rule limited to devices (source_ip_cidr) owns the target for those devices.
# sing-box sends nothing of the router into it, so the verification marks the
# router's own requests with the route mark of the rule (a temporary table)
# and proves they passed its production queue.
scope_dpi_rule() {
  sed -i "/list domain_suffix 'example.com'/a\\	list source_ip_cidr '192.168.1.50'" "$PROKOP_CONFIG_FILE"
  node -e 'const fs=require("fs");const f=process.argv[1];const c=JSON.parse(fs.readFileSync(f,"utf8"));
    c.route.rules.find((r)=>r.outbound==="Dpi-out").source_ip_cidr=["192.168.1.50"];fs.writeFileSync(f,JSON.stringify(c))' "$PROKOP_AUTOTUNE_SINGBOX_CONFIG"
  ucode -L "$LIB" "$LIB/config/snapshots.uc" confirm-working > /dev/null
  PRE_LKG="$(lkg)"; PRE_HASH="$(chash)"
  rm -f "$STATE/verify.nft"
}
no_verify_table() { [ ! -e "$NFT_STATE/tables/ProkopAutotuneVerify" ] || fail "$1: the verification table was left behind"; }

reset_apply; scope_dpi_rule; plan_ready
json 'a.equal(r.status, "ready"); a.equal(r.owner.kind, "zapret"); a.equal(r.owner.section, "Dpi"); a.equal(r.owner.source_scoped, true);' "$WORK/plan.json"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "applied"); a.equal(r.applied, true); a.equal(r.verification.ok, true);
  const t = r.verification.traffic; a.equal(t.mode, "rule_mark"); a.equal(t.stability, "stable"); a.equal(t.probes.length, 3);
  a.ok(t.marked_packets >= 3); a.ok(t.queue_packets >= t.marked_packets); a.ok(t.queue_rule_packets >= t.marked_packets);
  const names = r.verification.checks.map((c) => c.name);
  for (const n of ["verify_path_available", "verify_path_created", "traffic_transport", "traffic_rule_mark", "traffic_dpi_queue", "verify_path_removed"])
    a.ok(r.verification.checks.find((c) => c.name === n).ok, n);
  a.ok(!names.includes("traffic_rule_path") && !names.includes("traffic_sing_box_path"), "no sing-box path claim for a device-limited rule");' "$WORK/out.json"
grep -qx 'add rule inet ProkopAutotuneVerify premark ip daddr 93.184.216.34 tcp dport 443 tcp sport 61000-61031 meta mark 0x00000000 meta mark set 0x01000001 counter accept comment "rule_mark"' "$STATE/verify.nft" ||
  fail "the marking rule is not confined to the probe tuple: $(cat "$STATE/verify.nft")"
grep -q -- '--resolve' "$STUB_LOG/curl.args" && grep -qx -- '61000-61031' "$STUB_LOG/curl.args" || fail "marked probes must pin the address and the source ports"
case "$(dpi_args)" in *multisplit*) ;; *) fail "the candidate was not started for the device-limited rule";; esac
[ "$(lkg)" != "$PRE_LKG" ] || fail "the verified candidate of a device-limited rule was not confirmed"
no_verify_table "applied"
ok "device-limited rule: applied and verified with marked requests through its production queue"

# The mark does not reach the queue (the rule lost its queue rule, say): rolled back.
reset_apply; scope_dpi_rule; plan_ready; export VERIFY_NO_MARK=1; at apply "$WORK/plan.json"; unset VERIFY_NO_MARK
json 'a.equal(r.status, "rolled_back"); a.equal(r.applied, false);
  a.equal(r.verification.checks.find((c) => c.name === "traffic_rule_mark").ok, false);' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "a failed marked verification did not restore the configuration"
no_verify_table "rolled back"
ok "device-limited rule: marked requests that miss the queue -> rolled back"

# The strategy does not work for the target: rolled back, as for any rule.
reset_apply; scope_dpi_rule; plan_ready; export PROD_PLAN=reset; at apply "$WORK/plan.json"; unset PROD_PLAN
json 'a.equal(r.status, "rolled_back"); a.equal(r.verification.checks.find((c) => c.name === "traffic_transport").ok, false);' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "a failing strategy stayed on a device-limited rule"
no_verify_table "transport failure"
ok "device-limited rule: a strategy that fails for the target -> rolled back"

# The temporary table cannot be created: nothing is proven, rolled back.
reset_apply; scope_dpi_rule; plan_ready; export VERIFY_CREATE_FAIL=1; at apply "$WORK/plan.json"; unset VERIFY_CREATE_FAIL
json 'a.equal(r.status, "rolled_back"); a.equal(r.verification.checks.find((c) => c.name === "verify_path_created").ok, false);' "$WORK/out.json"
[ "$(chash)" = "$PRE_HASH" ] || fail "an unverifiable candidate stayed on a device-limited rule"
ok "device-limited rule: no marked path -> rolled back"

# A table left by a killed verification is removed before anything else.
reset_apply; scope_dpi_rule; plan_ready; touch "$NFT_STATE/tables/ProkopAutotuneVerify"; at apply "$WORK/plan.json"
json 'a.equal(r.status, "applied");' "$WORK/out.json"
no_verify_table "leftover"
ok "device-limited rule: a leftover verification table is removed"

reset_apply; rm -f "$STATE/verify.nft"; plan_ready; at apply "$WORK/plan.json"
json 'a.equal(r.status, "applied"); a.equal(r.verification.traffic.mode, undefined); a.ok(r.verification.checks.find((c) => c.name === "traffic_rule_path").ok);' "$WORK/out.json"
[ ! -e "$STATE/verify.nft" ] || fail "an unscoped rule used the marked path"
ok "unscoped rule: still verified with production requests through sing-box"

# The default strategy (an empty option): made explicit, only its TCP/443
# profile replaced; the rule then runs the result and is known as the candidate.
reset_apply; sed -i "/option nfqws_opt '--filter-tcp/d" "$PROKOP_CONFIG_FILE"; "$STATE/start-dpi"
ucode -L "$LIB" "$LIB/config/snapshots.uc" confirm-working > /dev/null; PRE_HASH="$(chash)"
plan_ready
json 'a.equal(r.status, "ready", r.reason); a.equal(r.changes[0].from, ""); a.equal(r.profile.index, 1);
  a.equal(r.changes[0].to, process.env.ZAPRET_DEFAULT_NFQWS_OPT.split(" --new ").map((p, i) => i === 1
    ? "--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld" : p).join(" --new "));' "$WORK/plan.json"
at apply "$WORK/plan.json"
json 'a.equal(r.status, "applied", JSON.stringify(r).slice(0, 400)); a.ok(r.verification.checks.find((c) => c.name === "nfqws_arguments").ok);' "$WORK/out.json"
case "$(dpi_args)" in *"--filter-tcp=80 --dpi-desync=fake --new --filter-tcp=443 --dpi-desync=multisplit"*"--new --filter-udp=443 --dpi-desync=fake"*) ;;
  *) fail "default strategy: the other profiles did not survive: $(dpi_args)";; esac
cat > "$WORK/view.uc" <<'UC'
let d = require("core.dpi_strategy");
let opt = trim(split(require("fs").readfile(ARGV[0]), "option nfqws_opt '")[1]);
print(d.view({ action: "zapret", nfqws_opt: substr(opt, 0, index(opt, "'")) }).dpi_strategy, "\n");
UC
[ "$(ucode -L "$LIB" "$WORK/view.uc" "$PROKOP_CONFIG_FILE")" = multisplit ] || fail "the spliced default is not known as the candidate"
ok "default strategy: only its TCP/443 profile replaced, applied, known as the candidate"

printf 'autotune_apply: PASS (%d checks)\n' "$pass"
