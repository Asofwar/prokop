#!/usr/bin/env bash
set -euo pipefail

# /etc/init.d/prokop-torrserver runs TorrServer as its own unprivileged user,
# never root (TS-1): the user is made on first use, TorrServer's database
# lives in data/ owned by that user, and a database from before (beside the
# binary, written by root) moves there once. The binary and its directory
# stay root's. Without the user or data/, nothing runs.
#
# The init script is sourced with procd, OpenWrt's user helpers
# (/lib/functions.sh), chown and logger replaced by stand-ins that work on
# the test's own files.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT="$ROOT_DIR/prokop/files/etc/init.d/prokop-torrserver"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'torrserver_init_user: FAIL: %s\n' "$1" >&2
  for log in procd chown logger; do
    [ ! -s "$WORK/$log" ] || sed "s|^|  $log: |" "$WORK/$log" >&2
  done
  exit 1
}

# OpenWrt's helpers (package/base-files/files/lib/functions.sh), on the
# test's passwd and group.
group_exists() { grep -qs "^${1}:" "$GROUP_FILE"; }
user_exists() { grep -qs "^${1}:" "$PASSWD_FILE"; }
group_add() { echo "${1}:x:${2}:" >>"$GROUP_FILE"; }
user_add() { echo "${1}:x:${2}:${3}:${4:-$1}:${5:-/var/run/$1}:${6:-/bin/false}" >>"$PASSWD_FILE"; }
procd_open_instance() { echo "open $*" >>"$WORK/procd"; }
procd_set_param() { echo "$*" >>"$WORK/procd"; }
procd_close_instance() { echo "close" >>"$WORK/procd"; }
procd_add_jail() { echo "jail $*" >>"$WORK/procd"; }
procd_add_jail_mount() { echo "jail_mount $*" >>"$WORK/procd"; }
procd_add_jail_mount_rw() { echo "jail_mount_rw $*" >>"$WORK/procd"; }
# The uci CLI on the test's settings, which the manager reads as well.
uci() {
  [ "$1" = -q ] && shift
  [ "$1" = get ] || return 1
  grep -s "^$2=" "$PROKOP_UCI_STATE_FILE" | tail -n 1 | cut -d= -f2- | grep '' || return 1
}
settings() { printf '%s\n' prokop.settings=settings "$@" >"$PROKOP_UCI_STATE_FILE"; }
export PROKOP_UCI_STATE_FILE="$WORK/uci.state" PROKOP_MEMINFO_PATH="$WORK/meminfo" PROKOP_PROC_DIR="$WORK/proc"
mkdir -p "$WORK/proc"
printf 'MemTotal:        1006668 kB\n' >"$WORK/meminfo"
settings
chown() { echo "$*" >>"$WORK/chown"; }
logger() { echo "$*" >>"$WORK/logger"; }

run_start() { # run_start: the script's start_service on the test's files
  : >"$WORK/procd"
  : >"$WORK/chown"
  : >"$WORK/logger"
  # shellcheck source=/dev/null
  . "$INIT"
  TORRSERVER_DIR="$WORK/opt/torrserver"
  TORRSERVER_DATA="$TORRSERVER_DIR/data"
  PASSWD_FILE="$WORK/passwd"
  GROUP_FILE="$WORK/group"
  PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
  UCODE="$(command -v ucode)"
  UJAIL="$WORK/ujail"
  OPTIONS_STAMP="$WORK/options"
  set +e
  start_service
  START_RC=$?
  set -e
}

reset_router() {
  rm -rf "$WORK/opt"
  mkdir -p "$WORK/opt/torrserver"
  printf '#!/bin/sh\n' >"$WORK/opt/torrserver/torrserver"
  chmod 0755 "$WORK/opt/torrserver/torrserver"
  printf '{}\n' >"$WORK/opt/torrserver/prokop-managed.json"
  printf 'root:x:0:0:root:/root:/bin/ash\nnobody:*:65534:65534:nobody:/var:/bin/false\n' >"$WORK/passwd"
  printf 'root:x:0:\nnogroup:x:65534:\n' >"$WORK/group"
}

# --- 1. A fresh install: the user is made, TorrServer runs as it from data/ ------
reset_router
run_start
[ "$START_RC" = 0 ] || fail "start must succeed: rc $START_RC"
grep -Fxq 'torrserver:x:65536:' "$WORK/group" || fail "the group must be made with id 65536: $(cat "$WORK/group")"
grep -q '^torrserver:x:65536:65536:' "$WORK/passwd" || fail "the user must be made with id 65536: $(cat "$WORK/passwd")"
grep -q '^torrserver:.*:/bin/false$' "$WORK/passwd" || fail "the user must have no shell"
grep -Fxq "user torrserver" "$WORK/procd" || fail "TorrServer must run as its own user: $(cat "$WORK/procd")"
grep -Fxq "no_new_privs 1" "$WORK/procd" || fail "TorrServer must not gain privileges"
grep -Fxq "command $WORK/opt/torrserver/torrserver -d $WORK/opt/torrserver/data -p 8090" "$WORK/procd" ||
  fail "TorrServer must keep its database in data/: $(cat "$WORK/procd")"
[ -d "$WORK/opt/torrserver/data" ] || fail "data/ must be made"
grep -Fxq -- "-h torrserver:torrserver $WORK/opt/torrserver/data" "$WORK/chown" || fail "data/ must be the user's: $(cat "$WORK/chown")"
grep -q -- "-R\|torrserver:torrserver $WORK/opt/torrserver\$\|/torrserver/torrserver\$\|prokop-managed" "$WORK/chown" &&
  fail "nothing but data/ may change owner, and nothing recursively: $(cat "$WORK/chown")"

# A directory a release before TS-1 made is 0700 (umask 077): TorrServer's
# user must pass through it, or the binary cannot run (exit 127).
reset_router
chmod 0700 "$WORK/opt/torrserver"
run_start
[ "$START_RC" = 0 ] || fail "start with a 0700 directory must succeed"
[ "$(stat -c %a "$WORK/opt/torrserver")" = 755 ] || fail "the directory must be 0755: $(stat -c %a "$WORK/opt/torrserver")"

# Started again, the same user stays.
run_start
[ "$(grep -c '^torrserver:' "$WORK/passwd")" = 1 ] || fail "the user must be made once"

# --- 2. An install from before: its database moves into data/ once -------------
reset_router
printf 'db' >"$WORK/opt/torrserver/config.db"
printf 'rutor' >"$WORK/opt/torrserver/rutor.ls"
printf '{}' >"$WORK/opt/torrserver/settings.json"
printf '[]' >"$WORK/opt/torrserver/viewed.json"
# An id taken by another user is skipped.
printf 'other:x:65536:100:other:/var:/bin/false\n' >>"$WORK/passwd"
run_start
[ "$START_RC" = 0 ] || fail "start of an older install must succeed"
grep -q '^torrserver:x:65537:65537:' "$WORK/passwd" || fail "a taken id must be skipped: $(cat "$WORK/passwd")"
[ "$(cat "$WORK/opt/torrserver/data/config.db")" = db ] && [ ! -e "$WORK/opt/torrserver/config.db" ] ||
  fail "the database must move into data/"
[ -e "$WORK/opt/torrserver/data/rutor.ls" ] || fail "the search database must move into data/"
grep -Fxq -- "-h torrserver:torrserver $WORK/opt/torrserver/data/config.db" "$WORK/chown" || fail "the moved database must be the user's"
for name in settings.json viewed.json; do
  [ -e "$WORK/opt/torrserver/data/$name" ] && [ ! -e "$WORK/opt/torrserver/$name" ] || fail "$name must move into data/"
  grep -Fxq -- "-h torrserver:torrserver $WORK/opt/torrserver/data/$name" "$WORK/chown" || fail "the moved $name must be the user's"
done
# A database already in data/ is never overwritten by one beside the binary,
# and is the user's on every start (one a sysupgrade restored may carry an
# old owner): the file itself, never what a link names.
printf 'stale' >"$WORK/opt/torrserver/config.db"
run_start
[ "$(cat "$WORK/opt/torrserver/data/config.db")" = db ] || fail "the database in data/ must stay"
grep -Fxq -- "-h torrserver:torrserver $WORK/opt/torrserver/data/config.db" "$WORK/chown" || fail "the database must be the user's on every start"
rm -f "$WORK/opt/torrserver/data/rutor.ls"
ln -s /etc/shadow "$WORK/opt/torrserver/data/rutor.ls"
run_start
grep -q "rutor.ls" "$WORK/chown" && fail "a link in data/ must never change owner: $(cat "$WORK/chown")"

# --- 2b. A sysupgrade keeps the database (TS-7) ------------------------------------
KEEP="$ROOT_DIR/prokop/files/lib/upgrade/keep.d/prokop-torrserver"
for name in config.db settings.json viewed.json; do
  grep -Fxq "/opt/torrserver/data/$name" "$KEEP" || fail "a sysupgrade must keep TorrServer's $name"
done
grep -q 'keep.d/prokop-torrserver' "$ROOT_DIR/prokop/Makefile" || fail "the package must install the keep list"

# --- 3. Fail closed --------------------------------------------------------------
# data/ as a link: never followed.
reset_router
ln -s "$WORK/elsewhere" "$WORK/opt/torrserver/data"
run_start
[ "$START_RC" != 0 ] || fail "a link at data/ must refuse the start"
grep -q '^open' "$WORK/procd" && fail "nothing may run when data/ is a link"
grep -Fq "was not started" "$WORK/logger" || fail "the refusal must be logged"
# The directory itself as a link: never followed.
rm -rf "$WORK/opt"
mkdir -p "$WORK/real"
ln -s "$WORK/real" "$WORK/opt"
mkdir -p "$WORK/real/torrserver"
printf '#!/bin/sh\n' >"$WORK/real/torrserver/torrserver"
chmod 0755 "$WORK/real/torrserver/torrserver"
printf '{}\n' >"$WORK/real/torrserver/prokop-managed.json"
rm "$WORK/opt"
mkdir -p "$WORK/opt"
ln -s "$WORK/real/torrserver" "$WORK/opt/torrserver"
run_start
[ "$START_RC" != 0 ] || fail "a link at the TorrServer directory must refuse the start"
grep -q '^open' "$WORK/procd" && fail "nothing may run when the directory is a link"
rm -rf "$WORK/real"
# A group whose id another user has: no user is made, nothing runs.
reset_router
printf 'torrserver:x:65540:\n' >>"$WORK/group"
printf 'other:x:65540:100:other:/var:/bin/false\n' >>"$WORK/passwd"
run_start
[ "$START_RC" != 0 ] || fail "a user that cannot be made must refuse the start"
grep -q '^open' "$WORK/procd" && fail "TorrServer must never run as root"
grep -q '^torrserver:' "$WORK/passwd" && fail "no user may share another user's id"

# Without the binary or its marker nothing changes.
reset_router
rm -f "$WORK/opt/torrserver/prokop-managed.json"
run_start
[ "$START_RC" = 0 ] && [ ! -s "$WORK/procd" ] && ! grep -q '^torrserver:' "$WORK/passwd" ||
  fail "a TorrServer without Prokop's marker is not this service's"

# --- 4. The API password (TS-1): --httpauth with data/accs.db ---------------------
reset_router
run_start
grep -q -- '--httpauth' "$WORK/procd" && fail "the password must be off by default"
[ ! -e "$WORK/opt/torrserver/data/accs.db" ] || fail "no accounts file by default"
settings prokop.settings.torrserver_auth_enabled=1 prokop.settings.torrserver_auth_user=admin \
  prokop.settings.torrserver_auth_password=secret
run_start
[ "$START_RC" = 0 ] || fail "start with a password must succeed: $(cat "$WORK/logger")"
grep -Fxq "command $WORK/opt/torrserver/torrserver -d $WORK/opt/torrserver/data -p 8090 --httpauth" "$WORK/procd" ||
  fail "TorrServer must start with --httpauth: $(cat "$WORK/procd")"
[ "$(cat "$WORK/opt/torrserver/data/accs.db")" = '{ "admin": "secret" }' ] || fail "accs.db: $(cat "$WORK/opt/torrserver/data/accs.db")"
grep -Fxq -- "-h torrserver:torrserver $WORK/opt/torrserver/data/accs.db" "$WORK/chown" || fail "accs.db must be TorrServer's user's"
! grep -q secret "$WORK/procd" "$WORK/logger" || fail "the password reached procd or the log"
# Asked for but unusable: TorrServer does not start at all (procd then
# stops a running one), never with an open API.
settings prokop.settings.torrserver_auth_enabled=1 prokop.settings.torrserver_auth_user=admin
run_start
[ "$START_RC" != 0 ] || fail "a password without a value must refuse the start"
grep -q '^open' "$WORK/procd" && fail "TorrServer must not run with an open API when a password is asked for"
grep -Fq "its password is on, but the user name or password is missing or unusable" "$WORK/logger" || fail "the refusal must be logged"
settings
run_start
grep -q -- '--httpauth' "$WORK/procd" && fail "turned off, the password must go"
[ ! -e "$WORK/opt/torrserver/data/accs.db" ] || fail "turned off, accs.db must go"

# --- 5. GOMEMLIMIT: the cache and some room, a soft limit -------------------------
reset_router
run_start
grep -Fxq "env GODEBUG=madvdontneed=1 HOME=$WORK/opt/torrserver/data GOMEMLIMIT=192MiB" "$WORK/procd" ||
  fail "GOMEMLIMIT must be the recommended cache and 64 MiB: $(grep '^env' "$WORK/procd")"
printf '{"BitTorr":{"CacheSize":268435456}}' >"$WORK/opt/torrserver/data/settings.json"
run_start
grep -q 'GOMEMLIMIT=320MiB$' "$WORK/procd" || fail "GOMEMLIMIT must follow TorrServer's cache: $(grep '^env' "$WORK/procd")"
printf 'MemTotal:        262144 kB\n' >"$WORK/meminfo"
run_start
[ "$START_RC" = 0 ] || fail "a limit that cannot be set must not stop the start"
grep -q 'GOMEMLIMIT' "$WORK/procd" && fail "no GOMEMLIMIT past half the router's memory"
printf 'MemTotal:        1006668 kB\n' >"$WORK/meminfo"

# --- 6. procd's jail, opt-in and fail closed ------------------------------------------
reset_router
run_start
grep -q '^jail' "$WORK/procd" && fail "the jail must be off by default"
settings prokop.settings.torrserver_jail=1
rm -f "$WORK/ujail"
run_start
[ "$START_RC" != 0 ] || fail "the jail asked for without ujail must refuse the start"
grep -q '^open' "$WORK/procd" && fail "TorrServer must not run unjailed when the jail is asked for"
grep -Fq "its jail is on, but this firmware has no $WORK/ujail" "$WORK/logger" || fail "the refusal must be logged"
printf '#!/bin/sh\n' >"$WORK/ujail"
chmod 0755 "$WORK/ujail"
mkdir -p "$WORK/mnt/cache"
printf '{"BitTorr":{"UseDisk":true,"TorrentsSavePath":"%s"}}' "$WORK/mnt/cache" >"$WORK/opt/torrserver/data/settings.json"
run_start
[ "$START_RC" = 0 ] || fail "start in the jail must succeed: $(cat "$WORK/logger")"
grep -Fxq "jail torrserver procfs requirejail" "$WORK/procd" || fail "procd must refuse to run it unjailed: $(cat "$WORK/procd")"
grep -q "^jail_mount $WORK/opt/torrserver/torrserver /dev/null /dev/urandom" "$WORK/procd" ||
  fail "the binary must be in the jail, read-only: $(grep jail_mount "$WORK/procd")"
grep -Fxq "jail_mount_rw $WORK/opt/torrserver/data $WORK/mnt/cache" "$WORK/procd" ||
  fail "data/ and the disk cache must be writable in the jail: $(grep jail_mount_rw "$WORK/procd")"
[ "$(sed -n '/^jail /,$p' "$WORK/procd" | tail -n 1)" = close ] || fail "the jail must belong to the instance"
grep -Fxq "user torrserver" "$WORK/procd" || fail "the jail must keep TorrServer's user"
rm -f "$WORK/opt/torrserver/data/settings.json"

# --- 7. A change of Prokop's settings restarts TorrServer only for its own ---------
stop() { echo stop >>"$WORK/procd"; }
start() { echo start >>"$WORK/procd"; }
reload_now() {
  : >"$WORK/procd"
  set +e
  reload_service
  set -e
}
grep -Fxq 'procd_add_reload_trigger prokop' <(sed -n '/^service_triggers()/,/^}/p' "$INIT" | tr -d '\t') ||
  fail "a change of Prokop's settings must reach TorrServer"
settings
rm -f "$WORK/options"
reload_now
[ ! -s "$WORK/procd" ] || fail "a TorrServer started before these settings must not restart for nothing"
reset_router
run_start
reload_now
[ ! -s "$WORK/procd" ] || fail "unchanged settings must not restart TorrServer"
settings prokop.settings.torrserver_auth_enabled=0 prokop.settings.torrserver_auth_user=admin prokop.settings.dns_type=doh
reload_now
[ ! -s "$WORK/procd" ] || fail "other settings must not restart TorrServer: $(cat "$WORK/procd")"
settings prokop.settings.torrserver_auth_enabled=1 prokop.settings.torrserver_auth_user=admin prokop.settings.torrserver_auth_password=a
run_start
reload_now
[ ! -s "$WORK/procd" ] || fail "the same password must not restart TorrServer"
settings prokop.settings.torrserver_auth_enabled=1 prokop.settings.torrserver_auth_user=admin prokop.settings.torrserver_auth_password=b
reload_now
[ "$(tr '\n' ' ' <"$WORK/procd")" = 'stop start ' ] || fail "a new password must restart TorrServer: $(cat "$WORK/procd")"
settings prokop.settings.torrserver_jail=1
reload_now
[ "$(tr '\n' ' ' <"$WORK/procd")" = 'stop start ' ] || fail "the jail must restart TorrServer"
[ "$(stat -c %a "$WORK/options")" = 600 ] || fail "the digest of the password must be the root's alone"

printf 'torrserver init user checks passed\n'
