#!/usr/bin/env bash
set -euo pipefail

# A reload that fails after it changed dnsmasq takes back only its own change
# (UC-071).
#
# The reload copied the whole of /etc/config/dhcp aside before its dnsmasq
# step and, when a later step failed (recording the reload state; before
# the S5 integration also the cron refresh), copied it back with cp: in
# place, around the UCI commit lock, and over whatever someone committed to
# dhcp meanwhile (a static lease added in LuCI). Now the rollback goes through the operations that own Prokop's
# dnsmasq settings (dns/apply.uc): it restores the forwarding the reload
# found, through the same edit as start and stop (only Prokop's options, a
# commit that starts over from a file someone else changed). Other dhcp
# changes stay.
#
# The reload is the real service/lifecycle.uc and dns/apply.uc; the other
# modules are modelled. Part 1 uses the UCI fixture; part 2 a dhcp file
# through the OpenWrt uci CLI (skipped without one).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in "$EVENTS" "$WORK_DIR/syslog" "$WORK_DIR/reload.out"; do
    [ ! -s "$log" ] || sed "s|^|  $(basename "$log"): |" "$log" >&2
  done
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

FAKE_LIB="$WORK_DIR/fake-lib"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/prokop" "$WORK_DIR/tmp" "$WORK_DIR/etc" \
  "$FAKE_LIB/service" "$FAKE_LIB/subscription" "$FAKE_LIB/config" "$FAKE_LIB/singbox" "$FAKE_LIB/nft" \
  "$FAKE_LIB/dns" "$FAKE_LIB/components" "$FAKE_LIB/autotune" "$FAKE_LIB/diagnostics" \
  "$FAKE_LIB/providers/zapret" "$FAKE_LIB/providers/zapret2" "$FAKE_LIB/providers/byedpi"
: >"$WORK_DIR/prokop.config"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS REAL_LIB FAKE_LIB WORK_DIR
export RELOAD_LOCK="$WORK_DIR/run/prokop.reload.lock"
export PROKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK"
export PROKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK_DIR/run/prokop/subscription-update.lock"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/prokop"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/prokop/reload.pending"
export PROKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export PROKOP_CONFIG_FILE="$WORK_DIR/prokop.config"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export KILLSWITCH_STATE_DIR="$WORK_DIR/killswitch"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export PROKOP_UI_ACTION_TRACKED=1
export SB_DNS_INBOUND_ADDRESS=127.0.0.42

# Nothing here may reach the host's syslog, firewall or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK_DIR/syslog" >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/no-init"
printf '#!/bin/sh\nprintf "dnsmasq %%s\\n" "$*" >>"%s"\n' "$EVENTS" >"$WORK_DIR/bin/dnsmasq-init"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
# Only the production table: no guard of a failed transition.
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$1" != -t ] || shift
[ "$1 $2 $3 $4" = "list table inet ProkopTable" ] && exit 0
[ "$1 $2" != "list chain" ] && [ "$1 $2" != "list table" ]
SH

# The reload under reload.lock, as init.d runs it.
cat >"$WORK_DIR/reload" <<'SH'
#!/bin/sh
state() { ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" "$@"; }
state acquire-runtime-dir-lock "$PROKOP_RELOAD_LOCK_DIR" "$$" || exit 99
env PROKOP_LIB="$FAKE_LIB" ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" reload ""
status=$?
state release-runtime-dir-lock "$PROKOP_RELOAD_LOCK_DIR" "$$"
exit "$status"
SH

# shellcheck disable=SC1003 # ucode source, quoted for the shell
fake_header='let fs = require("fs");
function q(value) { return "'"'"'" + replace("" + value, /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'"; }
function ev(line) { system("printf '"'"'%s\\n'"'"' " + q(line) + " >> " + q(getenv("EVENTS"))); }
let mode = "" + (ARGV[0] ?? "");
'

cat >"$FAKE_LIB/service/state.uc" <<UC
$fake_header
if (index(mode, "runtime-dir-lock") >= 0 || mode == "runtime-apply-allowed" || mode == "stop-requested") {
    let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    exit(system(command));
}
if (mode == "sing-box-process-conflict" || mode == "has-list-update-sources" || mode == "has-nft-list-update-sources")
    exit(1);
if (mode == "sing-box-service-runtime-pid") {
    print("4242\n");
    exit(0);
}
// The last step of the reload, after dnsmasq (the record of the applied
// state, not the one the plan is computed from): someone else commits a
// dhcp change meanwhile (\$WORK_DIR/foreign, a shell command), then the
// record fails when STATE_FAILS is set.
if (mode == "write-captured-reload-state" && ARGV[5] == "1") {
    if (fs.stat(getenv("WORK_DIR") + "/foreign") != null)
        system("sh " + q(getenv("WORK_DIR") + "/foreign"));
    ev("reload state" + (getenv("STATE_FAILS") == "1" ? " failed" : ""));
    exit(getenv("STATE_FAILS") == "1" ? 1 : 0);
}
exit(0);
UC

# The reload plan comes from the test (PLAN: "key=value ...").
cat >"$FAKE_LIB/service/reload.uc" <<UC
$fake_header
if (mode != "plan-state-files")
    exit(0);
for (let item in split(trim(getenv("PLAN") ?? ""), " "))
    if (item != "")
        print(replace(item, "=", "\t"), "\n");
exit(0);
UC

# The cron refresh, a step after dnsmasq. A failed one no longer rolls the
# reload back (tests/cron_refresh_failure.sh).
cat >"$FAKE_LIB/components/updates.uc" <<UC
$fake_header
if (mode == "refresh-cron-from-uci")
    ev("cron refresh");
exit(0);
UC

# The real dns/apply.uc. With DHCP_CLI set it edits the dhcp file through the
# uci CLI instead of the UCI fixture the rest of the reload reads.
cat >"$FAKE_LIB/dns/apply.uc" <<UC
$fake_header
ev("dns " + join(" ", ARGV));
let command = (getenv("DHCP_CLI") == "1" ? "env -u PROKOP_UCI_STATE_FILE -u PROKOP_UCI_LOG_FILE " : "") +
    "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/dns/apply.uc");
for (let arg in ARGV)
    command += " " + q(arg);
exit(system(command));
UC

for module in service/ui config/validator config/snapshots diagnostics/health subscription/cache \
  singbox/runtime singbox/priority singbox/dns_failover nft/apply autotune/manager \
  providers/zapret/runtime providers/zapret2/runtime providers/byedpi/runtime; do
  cat >"$FAKE_LIB/$module.uc" <<UC
$fake_header
exit(mode == "runtime-cache-needs-rebuild" ? 1 : 0);
UC
done
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/reload"

PLAN_CONFIGURE="has_work=1 changed_dnsmasq=1 needs_dnsmasq_configure=1 needs_cron_refresh=1"
PLAN_RESTORE="has_work=1 changed_dnsmasq=1 needs_dnsmasq_restore=1 needs_cron_refresh=1"

# run_reload <plan>: STATUS is the exit status of the reload.
run_reload() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  STATUS=0
  env PLAN="$1" "$WORK_DIR/reload" >"$WORK_DIR/reload.out" 2>&1 || STATUS=$?
  [ ! -e "$RELOAD_LOCK" ] || fail "reload.lock was left behind"
}
has_event() { grep -q "$1" "$EVENTS"; }
restarts() { grep -c '^dnsmasq restart$' "$EVENTS" || true; }

# ---- 1. the UCI fixture --------------------------------------------------------

STATE="$WORK_DIR/uci.state"
export PROKOP_UCI_STATE_FILE="$STATE"
export PROKOP_UCI_LOG_FILE="$WORK_DIR/uci.log"
# The file the reload copied aside before UC-071.
export PROKOP_DNSMASQ_CONFIG_FILE="$WORK_DIR/dhcp.fixture"
printf 'config dnsmasq\n' >"$PROKOP_DNSMASQ_CONFIG_FILE"

prokop_settings() {
  printf '%s\n' prokop.settings=settings prokop.settings.yacd_secret_key=0123456789abcdef \
    "prokop.settings.dont_touch_dhcp=$1"
}
dhcp_lines() { grep '^dhcp\.' "$STATE" | sort; }
printf '%s\n' "printf '%s\\n' dhcp.lan.leasetime=1h >>'$STATE'" >"$WORK_DIR/foreign"

not_forwarding=(
  'dhcp.@dnsmasq[0].server=1.1.1.1 8.8.8.8'
  'dhcp.@dnsmasq[0].domain=lan'
  'dhcp.lan.interface=lan'
)
forwarding=(
  'dhcp.@dnsmasq[0].server=127.0.0.42'
  'dhcp.@dnsmasq[0].noresolv=1'
  'dhcp.@dnsmasq[0].cachesize=0'
  'dhcp.@dnsmasq[0].prokop_server=1.1.1.1 8.8.8.8'
  'dhcp.@dnsmasq[0].prokop_unset=noresolv cachesize'
  'dhcp.@dnsmasq[0].domain=lan'
  'dhcp.lan.interface=lan'
)

# a. Control: a reload that completes keeps its dnsmasq change.
{ prokop_settings 0; printf '%s\n' "${not_forwarding[@]}"; } >"$STATE"
STATE_FAILS=0 run_reload "$PLAN_CONFIGURE"
[ "$STATUS" = 0 ] || fail "a reload that configures dnsmasq failed"
grep -Fxq 'dhcp.@dnsmasq[0].server=127.0.0.42' "$STATE" || fail "the reload did not forward dnsmasq to sing-box"

# b. The reload forwarded dnsmasq to sing-box, someone added a dhcp option,
# recording the reload state failed: the forwarding is taken back, the option stays.
{ prokop_settings 0; printf '%s\n' "${not_forwarding[@]}"; } >"$STATE"
dhcp_lines >"$WORK_DIR/before"
STATE_FAILS=1 run_reload "$PLAN_CONFIGURE"
[ "$STATUS" != 0 ] || fail "a reload whose last step failed reported success"
has_event '^reload state failed$' || fail "the reload did not reach recording its state"
printf '%s\n' dhcp.lan.leasetime=1h >>"$WORK_DIR/before"
sort -o "$WORK_DIR/before" "$WORK_DIR/before"
dhcp_lines | cmp -s "$WORK_DIR/before" - ||
  fail "the failed reload did not take back exactly its dnsmasq change: $(dhcp_lines | diff "$WORK_DIR/before" - | tr '\n' ' ')"
[ "$(restarts)" -ge 2 ] || fail "dnsmasq was not restarted with the restored settings"
ok "a failed reload takes back the dnsmasq forwarding it set, and only that"

# c. The reload took the forwarding back (dont_touch_dhcp was set),
# recording the reload state failed: the forwarding is set again, as it was.
{ prokop_settings 1; printf '%s\n' "${forwarding[@]}"; } >"$STATE"
dhcp_lines >"$WORK_DIR/before"
STATE_FAILS=1 run_reload "$PLAN_RESTORE"
[ "$STATUS" != 0 ] || fail "a reload whose last step failed reported success"
has_event '^dns restore force$' || fail "the reload did not restore dnsmasq"
printf '%s\n' dhcp.lan.leasetime=1h >>"$WORK_DIR/before"
sort -o "$WORK_DIR/before" "$WORK_DIR/before"
dhcp_lines | cmp -s "$WORK_DIR/before" - ||
  fail "the failed reload did not put the dnsmasq forwarding back: $(dhcp_lines | diff "$WORK_DIR/before" - | tr '\n' ' ')"
ok "a failed reload sets the dnsmasq forwarding it took back again"

# d. A reload that configures a dnsmasq which already forwards to sing-box
# and fails keeps the forwarding.
{ prokop_settings 0; printf '%s\n' "${forwarding[@]}"; } >"$STATE"
dhcp_lines >"$WORK_DIR/before"
rm -f "$WORK_DIR/foreign"
STATE_FAILS=1 run_reload "$PLAN_CONFIGURE"
[ "$STATUS" != 0 ] || fail "a reload whose last step failed reported success"
dhcp_lines | cmp -s "$WORK_DIR/before" - ||
  fail "a failed reload changed a dnsmasq that already forwarded to sing-box: $(dhcp_lines | diff "$WORK_DIR/before" - | tr '\n' ' ')"
ok "a failed reload keeps a forwarding that was there before it"

unset PROKOP_UCI_LOG_FILE

# ---- 2. a dhcp file through the uci CLI ---------------------------------------

UCI_REAL="$(command -v uci 2>/dev/null || true)"
if [ -z "$UCI_REAL" ]; then
  printf 'NOTE: no OpenWrt uci CLI on PATH; the dhcp file checks are skipped\n'
  printf 'dnsmasq reload rollback checks passed\n'
  exit 0
fi

DHCP="$WORK_DIR/etc/dhcp"
export PROKOP_DNSMASQ_CONFIG_FILE="$DHCP"
export PROKOP_UCI_CLI="$UCI_REAL"
export DHCP_CLI=1
options() { "$UCI_REAL" -q -c "$WORK_DIR/etc" show dhcp | sort; }
cat >"$DHCP" <<'EOF'
config dnsmasq
	option domain 'lan'
	list server '1.1.1.1'
	option cachesize '1000'

config dhcp 'lan'
	option interface 'lan'
	option leasetime '12h'
EOF
{ prokop_settings 0; } >"$STATE"
# LuCI (another uci CLI) adds a static lease while the reload runs.
mkdir -p "$WORK_DIR/foreign-uci"
cat >"$WORK_DIR/foreign" <<SH
"$UCI_REAL" -q -c "$WORK_DIR/etc" -t "$WORK_DIR/foreign-uci" set dhcp.printer=host &&
"$UCI_REAL" -q -c "$WORK_DIR/etc" -t "$WORK_DIR/foreign-uci" set dhcp.printer.mac=00:11:22:33:44:55 &&
"$UCI_REAL" -q -c "$WORK_DIR/etc" -t "$WORK_DIR/foreign-uci" commit dhcp
SH
options >"$WORK_DIR/options.before"
STATE_FAILS=1 run_reload "$PLAN_CONFIGURE"
[ "$STATUS" != 0 ] || fail "a reload whose last step failed reported success"
has_event '^dns configure force$' || fail "the reload did not configure dnsmasq"
[ "$("$UCI_REAL" -q -c "$WORK_DIR/etc" get dhcp.printer.mac || true)" = 00:11:22:33:44:55 ] ||
  fail "the failed reload lost the static lease committed during it: $(cat "$DHCP")"
options | grep -v '^dhcp\.printer' | cmp -s "$WORK_DIR/options.before" - ||
  fail "the failed reload did not put back the dnsmasq settings: $(options | diff "$WORK_DIR/options.before" - | tr '\n' ' ')"
for file in "$WORK_DIR"/etc/.dhcp.* "$WORK_DIR"/etc/dhcp.*; do
  [ ! -e "$file" ] || fail "temporary file $file left behind"
done
ok "a dhcp commit made during a failed reload survives its rollback"

printf 'dnsmasq reload rollback checks passed\n'
