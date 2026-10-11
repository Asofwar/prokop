#!/usr/bin/env bash
set -euo pipefail

# core/clock.uc status(): the NTP hotplug marker makes the clock "synced";
# a clock earlier than the release date is "unsynced"; busybox ntpd with its
# event hook and no marker yet is "unsynced"; no NTP client (or one that
# reports nothing) is "unknown". The hotplug script writes the marker only
# for a stratum below 16 on stratum/periodic/step events.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
HOOK="$ROOT_DIR/prokop/files/etc/hotplug.d/ntp/60-prokop-time"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export PROKOP_CLOCK_MARKER="$WORK/run/prokop/time-synced"
export PROKOP_CLOCK_PROC="$WORK/proc"
export PROKOP_CLOCK_SYSTEM_CONFIG="$WORK/system"
export PROKOP_CLOCK_NOW=1800000000
mkdir -p "$WORK/proc"
: > "$WORK/system"

status() { ucode -L "$LIB" "$LIB/core/clock.uc"; }
expect() {
  local got
  got="$(status)"
  node -e 'const a=require("node:assert/strict");const r=JSON.parse(process.argv[1]);const e=JSON.parse(process.argv[2]);
a.deepEqual(Object.keys(r).sort(), ["observed_at","reason","source","state","stratum"]);
for (const k of Object.keys(e)) a.deepEqual(r[k], e[k], k);' "$got" "$1" || fail "$2: $got"
}
proc() { # proc <pid> <argv...>
  local pid="$1"; shift
  mkdir -p "$WORK/proc/$pid"
  printf '%s\0' "$@" > "$WORK/proc/$pid/cmdline"
}
hook() { # hook <action> <stratum>
  env -i PATH="$PATH" PROKOP_CLOCK_MARKER="$PROKOP_CLOCK_MARKER" ACTION="$1" stratum="$2" sh -c ". '$HOOK'"
}

# No client, nothing configured.
expect '{"state":"unknown","source":"none","stratum":null,"observed_at":null,"reason":"ntp_not_running"}' "no ntp client"
printf "config timeserver 'ntp'\n\toption enabled '0'\n" > "$WORK/system"
expect '{"state":"unknown","reason":"ntp_disabled"}' "ntp disabled in system config"

# busybox ntpd with its hook, nothing reported yet: unsynced.
proc 812 /usr/sbin/ntpd -n -N -S /usr/sbin/ntpd-hotplug -p 0.openwrt.pool.ntp.org
expect '{"state":"unsynced","source":"ntpd","reason":"ntp_not_confirmed"}' "ntpd hooked, no marker"

# An unsynchronized stratum and other events write nothing.
hook stratum 16; hook unsync 3; hook periodic ""; hook periodic abc
[ ! -e "$PROKOP_CLOCK_MARKER" ] || fail "an unsynchronized event wrote the marker"
expect '{"state":"unsynced"}' "still unsynced"

# A synchronized stratum marks the clock.
hook stratum 2
[ -s "$PROKOP_CLOCK_MARKER" ] || fail "stratum 2 did not write the marker"
expect '{"state":"synced","source":"ntp_hotplug","stratum":2,"reason":"ntp_synced"}' "synced by hotplug"
hook periodic 3
expect '{"state":"synced","stratum":3}' "periodic refreshes the stratum"
# unsync keeps it (the clock was right this boot).
hook unsync 16
expect '{"state":"synced"}' "unsync keeps the marker"
ls "$WORK/run/prokop" | grep -q tmp && fail "a temporary marker was left behind"

# A malformed marker counts as none.
printf 'stratum=16\nat=1\n' > "$PROKOP_CLOCK_MARKER"
expect '{"state":"unsynced","reason":"ntp_not_confirmed"}' "stratum 16 marker ignored"
printf 'garbage\n' > "$PROKOP_CLOCK_MARKER"
expect '{"state":"unsynced"}' "garbage marker ignored"
rm -f "$PROKOP_CLOCK_MARKER"

# Before the release date: unsynced whatever runs.
PROKOP_CLOCK_NOW=1000000000 expect '{"state":"unsynced","source":"release_date","reason":"clock_before_release"}' "clock before release"

# ntpd without its hook, or another client: unknown.
rm -rf "$WORK/proc"/*
proc 900 /usr/sbin/ntpd -n -p pool.ntp.org
expect '{"state":"unknown","reason":"ntp_client_unobserved"}' "ntpd without hook"
rm -rf "$WORK/proc"/*
proc 901 /usr/sbin/chronyd -n
expect '{"state":"unknown","reason":"ntp_client_unobserved"}' "chronyd"

# The marker wins over the heuristic only while it exists (tmpfs, per boot).
hook step 1
PROKOP_CLOCK_NOW=1000000000 expect '{"state":"synced","stratum":1}' "marker present"

# A directory the hook cannot create is no error for hotplug.
PROKOP_CLOCK_MARKER=/proc/nonexistent/x env -i PATH="$PATH" ACTION=stratum stratum=2 sh -c ". '$HOOK'" ||
  fail "the hook failed on an unwritable marker directory"

printf 'clock status checks passed\n'
