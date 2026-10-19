#!/usr/bin/env bash
set -euo pipefail

# Diagnostics «Окружение» (diagnostics/environment.uc check): flow offloading
# from the firewall defaults, a global IPv6 address while Prokop runs IPv4
# only, and the clock row from core/clock.uc when that module exists. It is
# read-only and in the read ACL, so its output must not carry addresses.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A copy of the library without core/clock.uc: the clock row is checked
# against the stub modules below, never against the host clock.
LIB="$WORK/lib"
cp -a "$ROOT/prokop/files/usr/lib" "$LIB"
rm -f "$LIB/core/clock.uc"

mkdir -p "$WORK/sysctl/conf/all" "$WORK/sysctl/conf/lo" "$WORK/clocklib/core"
echo 0 >"$WORK/sysctl/conf/all/disable_ipv6"
echo 0 >"$WORK/sysctl/conf/lo/disable_ipv6"
cat >"$WORK/if_inet6" <<'IF'
00000000000000000000000000000001 01 80 10 80       lo
fe800000000000000000000000000001 03 40 20 80   br-lan
fd123456789a00000000000000000001 03 40 00 80   br-lan
IF

run() {
  PROKOP_UCI_STATE_FILE="$WORK/state" PROKOP_IF_INET6_FILE="$WORK/if_inet6" \
    PROKOP_IPV6_SYSCTL_DIR="$WORK/sysctl" ucode -L "$LIB" "$@" "$LIB/diagnostics/environment.uc" check
}
field() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const v = process.argv[1].split(".").reduce((o, k) => o == null ? o : o[k], d);
    console.log(typeof v === "object" ? JSON.stringify(v) : String(v));' "$1"
}
expect() {
  local got
  got="$(printf '%s' "$OUT" | field "$1")"
  [ "$got" = "$2" ] || { echo "FAIL: $CASE: $1 = $got, expected $2" >&2; echo "$OUT" >&2; exit 1; }
}

CASE="offloading off, no global IPv6, no clock module"
cat >"$WORK/state" <<'ST'
firewall.cfg01=defaults
firewall.cfg01.input=REJECT
ST
OUT="$(run)"
expect flow_offloading.state ok
expect flow_offloading.software false
expect flow_offloading.provenance configured
expect ipv6.state ok
expect ipv6.global_interfaces '[]'
expect ipv6.provenance observed
expect clock.state unavailable
expect clock.reason clock_module_missing

CASE="software offloading"
cat >"$WORK/state" <<'ST'
firewall.cfg01=defaults
firewall.cfg01.flow_offloading=1
ST
OUT="$(run)"
expect flow_offloading.state warning
expect flow_offloading.software true
expect flow_offloading.hardware false

CASE="hardware offloading needs the software flag"
cat >"$WORK/state" <<'ST'
firewall.cfg01=defaults
firewall.cfg01.flow_offloading_hw=1
ST
OUT="$(run)"
expect flow_offloading.state ok
expect flow_offloading.hardware false
cat >"$WORK/state" <<'ST'
firewall.cfg01=defaults
firewall.cfg01.flow_offloading=1
firewall.cfg01.flow_offloading_hw=1
ST
OUT="$(run)"
expect flow_offloading.hardware true

CASE="global IPv6 while Prokop handles IPv6"
cat >>"$WORK/if_inet6" <<'IF'
20010db8000100000000000000000001 04 40 00 00 pppoe-wan
2a001234000000000000000000000001 03 40 00 00   br-lan
IF
OUT="$(run)"
expect ipv6.state ok
expect ipv6.prokop_ipv6 true
expect ipv6.global_interfaces '["br-lan","pppoe-wan"]'
# No address leaves the check, only interface names.
if printf '%s' "$OUT" | grep -Eiq '2a00|2001|fd12|fe80'; then
  echo "FAIL: an address is in the output: $OUT" >&2; exit 1
fi

CASE="global IPv6 while Prokop runs IPv4 only"
echo 1 >"$WORK/sysctl/conf/lo/disable_ipv6"
OUT="$(run)"
expect ipv6.state warning
expect ipv6.prokop_ipv6 false

CASE="no IPv6 in the kernel"
rm "$WORK/if_inet6"
OUT="$(run)"
expect ipv6.state ok

CASE="clock module present"
cat >"$WORK/clocklib/core/clock.uc" <<'UC'
let calls = 0;
function status() {
    let s = getenv("CLOCK_STATE");
    if (s == "throw") die("broken");
    return { state: s, source: "ntp", stratum: 2, observed_at: 1760000000, reason: s == "synced" ? null : "no_peer" };
}
return { status };
UC
OUT="$(CLOCK_STATE=synced run -L "$WORK/clocklib")"
expect clock.state ok
expect clock.clock_state synced
expect clock.stratum 2
expect clock.provenance observed
OUT="$(CLOCK_STATE=unsynced run -L "$WORK/clocklib")"
expect clock.state warning
expect clock.reason no_peer
OUT="$(CLOCK_STATE=unknown run -L "$WORK/clocklib")"
expect clock.state not_checked
OUT="$(CLOCK_STATE=throw run -L "$WORK/clocklib")"
expect clock.state unavailable
expect clock.reason clock_status_failed
# The other rows do not depend on the clock module.
expect flow_offloading.state warning

CASE="sing-box open files"
PROC="$WORK/proc"
mkdir -p "$PROC/4242/fd"
for i in $(seq 1 10); do : >"$PROC/4242/fd/$i"; done
cat >"$PROC/4242/limits" <<'LIM'
Limit                     Soft Limit           Hard Limit           Units
Max processes             3640                 3640                 processes
Max open files            100                  4096                 files
LIM
OUT="$(PROKOP_PROC_DIR="$PROC" PROKOP_ENV_SING_BOX_PID=4242 run)"
expect sing_box_files.state ok
expect sing_box_files.provenance observed
expect sing_box_files.open 10
expect sing_box_files.soft_limit 100
expect sing_box_files.hard_limit 4096
for i in $(seq 11 80); do : >"$PROC/4242/fd/$i"; done
OUT="$(PROKOP_PROC_DIR="$PROC" PROKOP_ENV_SING_BOX_PID=4242 run)"
expect sing_box_files.state warning
expect sing_box_files.open 80
sed -i 's/^Max open files .*/Max open files            unlimited            unlimited            files/' "$PROC/4242/limits"
OUT="$(PROKOP_PROC_DIR="$PROC" PROKOP_ENV_SING_BOX_PID=4242 run)"
expect sing_box_files.state ok
expect sing_box_files.soft_limit -1
OUT="$(PROKOP_PROC_DIR="$PROC" PROKOP_ENV_SING_BOX_PID=0 run)"
expect sing_box_files.state not_checked
expect sing_box_files.reason sing_box_not_running
OUT="$(PROKOP_PROC_DIR="$PROC" PROKOP_ENV_SING_BOX_PID=4343 run)"
expect sing_box_files.state unavailable
expect sing_box_files.reason process_unreadable

CASE="through the CLI dispatcher"
grep -q 'check_environment: \[ "diagnostics/environment.uc", "check", 0 \]' "$ROOT/prokop/files/usr/bin/prokop"
echo "PASS: environment diagnostics"
