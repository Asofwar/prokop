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

# Started again, the same user stays.
run_start
[ "$(grep -c '^torrserver:' "$WORK/passwd")" = 1 ] || fail "the user must be made once"

# --- 2. An install from before: its database moves into data/ once -------------
reset_router
printf 'db' >"$WORK/opt/torrserver/config.db"
printf 'rutor' >"$WORK/opt/torrserver/rutor.ls"
# An id taken by another user is skipped.
printf 'other:x:65536:100:other:/var:/bin/false\n' >>"$WORK/passwd"
run_start
[ "$START_RC" = 0 ] || fail "start of an older install must succeed"
grep -q '^torrserver:x:65537:65537:' "$WORK/passwd" || fail "a taken id must be skipped: $(cat "$WORK/passwd")"
[ "$(cat "$WORK/opt/torrserver/data/config.db")" = db ] && [ ! -e "$WORK/opt/torrserver/config.db" ] ||
  fail "the database must move into data/"
[ -e "$WORK/opt/torrserver/data/rutor.ls" ] || fail "the search database must move into data/"
grep -Fxq -- "-h torrserver:torrserver $WORK/opt/torrserver/data/config.db" "$WORK/chown" || fail "the moved database must be the user's"
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
grep -Fxq /opt/torrserver/data/config.db "$KEEP" || fail "a sysupgrade must keep TorrServer's database"
grep -q 'keep.d/prokop-torrserver' "$ROOT_DIR/prokop/Makefile" || fail "the package must install the keep list"

# --- 3. Fail closed --------------------------------------------------------------
# data/ as a link: never followed.
reset_router
ln -s "$WORK/elsewhere" "$WORK/opt/torrserver/data"
run_start
[ "$START_RC" != 0 ] || fail "a link at data/ must refuse the start"
grep -q '^open' "$WORK/procd" && fail "nothing may run when data/ is a link"
grep -Fq "was not started" "$WORK/logger" || fail "the refusal must be logged"
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

printf 'torrserver init user checks passed\n'
