#!/bin/sh
set -eu
# Optimization 10 of the 2026-10-04 audit: hourly and daily update checks of
# a router run at its own minute and hour, taken from the address of its LAN
# bridge, instead of every router asking the mirror at 00:00. The same router
# keeps the same schedule; one without the bridge keeps 00:00.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
sched() { PROKOP_CRON_SEED_FILE="$WORK/$1" ucode -L "$LIB" "$LIB/components/updates.uc" due-check-cron-schedule "$2"; }
printf '94:83:c4:12:34:56\n' >"$WORK/a"
printf '94:83:c4:ab:cd:ef\n' >"$WORK/b"

daily_a="$(sched a 86400)"
[ "$daily_a" = "$(sched a 86400)" ] || fail "the schedule of one router changes"
[ "$daily_a" != "$(sched b 86400)" ] || fail "two routers share the daily minute and hour"
[ "$daily_a" != "0 0 * * *" ] || fail "the daily check still runs at 00:00"
printf '%s\n' "$daily_a" | grep -Eq '^([0-9]|[1-5][0-9]) ([0-9]|1[0-9]|2[0-3]) \* \* \*$' || fail "bad daily schedule: $daily_a"
minute="${daily_a%% *}"
[ "$(sched a 3600)" = "$minute * * * *" ] || fail "hourly check not at the router's minute: $(sched a 3600)"
[ "$(sched a 21600)" = "$minute */6 * * *" ] || fail "6-hourly check not at the router's minute: $(sched a 21600)"
[ "$(sched a 300)" = "*/5 * * * *" ] || fail "a 5-minute check changed"
[ "$(sched missing 86400)" = "0 0 * * *" ] || fail "a router without a LAN bridge must keep 00:00"
echo "cron_spread: OK"
