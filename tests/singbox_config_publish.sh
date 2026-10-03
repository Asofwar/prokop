#!/usr/bin/env bash
set -euo pipefail

# How sing-box config.json is published (UC-070).
#
# The new configuration is generated in /tmp (tmpfs), config.json lives on
# the overlay (/etc/sing-box). `mv` across filesystems is no rename: it
# removes or truncates config.json first and then copies, so a crash or a
# full overlay in between left config.json missing or cut short. Now the
# content is written to a private file next to config.json, read back, and
# renamed over it: config.json is either the previous file or the new one,
# whole. A publish that cannot complete fails, logs why, and leaves the
# previous file and no stray copy, on the overlay or in /tmp. A restore of a
# backup that holds what config.json already holds, and a DNS-failover patch
# that changes nothing, write nothing; each DNS-failover switch rewrites the
# file once.
#
# Here /tmp and the config directory share one filesystem, where even mv is
# a rename: section 1 tells the two apart only by the reader of the previous
# file. The full-overlay checks, the ones that fail on the old mv, need user
# and mount namespaces (unshare -rm) and are skipped without them.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
RUNTIME="$LIB/singbox/runtime.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

DIR="$WORK/etc/sing-box"
CONFIG="$DIR/config.json"
mkdir -p "$WORK/bin" "$WORK/tmp" "$DIR"
# logger keeps what Prokop logs.
cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$WORK/log"
SH
# `sing-box check` accepts every candidate.
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/sing-box"
chmod 0755 "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
export TMPDIR="$WORK/tmp"
export PROKOP_UCI_STATE_FILE="$WORK/uci.state"
export PROKOP_UCI_LOG_FILE="$WORK/uci.log"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_DNS_FAILOVER_STATE_FILE="$WORK/run/dns-failover.json"
export LIB RUNTIME WORK
cat >"$WORK/uci.state" <<EOF
prokop.settings=settings
prokop.settings.config_path=$CONFIG
prokop.settings.dns_server=1.1.1.1 8.8.8.8
prokop.settings.bootstrap_dns_server=77.88.8.8 9.9.9.9
EOF

runtime() { ucode -L "$LIB" "$RUNTIME" "$@"; }
# The file config.json is now: inode and modification time.
stamp() { stat -c '%i %y' "$CONFIG"; }
mode_of() { stat -c '%a' "$1"; }
no_leftovers() {
  local extra
  extra="$(find "$DIR" -mindepth 1 ! -name config.json ! -name fill -printf '%f ' 2>/dev/null)"
  [ -z "$extra" ] || fail "$1: left behind in the config directory: $extra"
}
# bytes <count>: that many bytes of text.
bytes() { head -c "$1" /dev/zero | tr '\0' x; }

# ---- 1. a publish is a rename within the config directory --------------------

printf 'old config\n' >"$CONFIG"
chmod 0600 "$CONFIG"
printf 'new config\n' >"$WORK/tmp/new.json"
chmod 0600 "$WORK/tmp/new.json"
exec 3<"$CONFIG"
runtime save-config-file-fixture "$WORK/tmp/new.json" "$CONFIG" || fail "the publish of a new config failed"
[ "$(cat "$CONFIG")" = 'new config' ] || fail "the new config was not published"
[ "$(cat <&3)" = 'old config' ] || fail "config.json was rewritten in place: a reader of the previous file saw it change"
exec 3<&-
[ "$(mode_of "$CONFIG")" = 600 ] || fail "the published config is not private: $(mode_of "$CONFIG")"
[ ! -e "$WORK/tmp/new.json" ] || fail "the publish did not consume the staged config"
no_leftovers "a publish"
ok "a new config replaces config.json by a rename, private and whole"

# ---- 2. a full overlay keeps the previous config ------------------------------

# on_full_overlay <mode> <args...>: runs runtime.uc with the config directory
# on its own small filesystem (as /etc on the overlay is, apart from /tmp),
# filled up after config.json was written. STATUS is the exit status;
# $WORK/after.json what config.json then holds.
on_full_overlay() {
  STATUS=0
  rm -f "$WORK/after.json" "$WORK/after.list"
  # shellcheck disable=SC2016 # expanded by the sh that runs it
  unshare -rm sh -c '
    dir="$1"
    shift
    mount -t tmpfs -o size=16k tmpfs "$dir" || exit 90
    cp "$WORK/old.json" "$dir/config.json"
    chmod 0600 "$dir/config.json"
    dd if=/dev/zero of="$dir/fill" bs=1k 2>/dev/null || true
    status=0
    ucode -L "$LIB" "$RUNTIME" "$@" || status=$?
    [ ! -e "$dir/config.json" ] || cp "$dir/config.json" "$WORK/after.json"
    find "$dir" -mindepth 1 ! -name config.json ! -name fill -printf "%f " >"$WORK/after.list"
    exit "$status"
  ' sh "$DIR" "$@" >/dev/null 2>&1 || STATUS=$?
  [ "$STATUS" != 90 ] || fail "could not mount the test filesystem"
}
if ! unshare -rm true 2>/dev/null; then
  printf 'NOTE: no user and mount namespaces; the full-overlay checks are skipped\n'
else
  bytes 1000 >"$WORK/old.json"
  # A config larger than the write buffer fails at the write; a smaller one
  # is taken by the write and lost at the close, unreported: only reading
  # the copy back finds that out.
  for size in 9000 2000; do
    for mode in save-config-file-fixture restore-config-stage restore-dns-config; do
      bytes "$size" >"$WORK/tmp/big.json"
      chmod 0600 "$WORK/tmp/big.json"
      : >"$WORK/log"
      if [ "$mode" = save-config-file-fixture ]; then
        on_full_overlay "$mode" "$WORK/tmp/big.json" "$CONFIG"
      else
        on_full_overlay "$mode" "$WORK/tmp/big.json"
      fi
      [ "$STATUS" != 0 ] || fail "$mode on a full overlay reported success ($size bytes)"
      [ -e "$WORK/after.json" ] || fail "$mode on a full overlay left no config.json ($size bytes)"
      cmp -s "$WORK/old.json" "$WORK/after.json" ||
        fail "$mode on a full overlay damaged config.json ($size bytes; $(wc -c <"$WORK/after.json") bytes left)"
      [ ! -s "$WORK/after.list" ] || fail "$mode on a full overlay left behind: $(cat "$WORK/after.list")"
      [ -e "$WORK/tmp/big.json" ] || fail "$mode on a full overlay discarded its source"
      grep -F '[error]' "$WORK/log" | grep -Fq "$CONFIG" ||
        fail "$mode on a full overlay logged no error naming $CONFIG: $(cat "$WORK/log")"
    done
  done
  rm -f "$WORK/tmp/big.json"
  ok "a publish or restore that a full overlay refuses keeps the previous config.json, and says so"

  # A DNS failover switch and a start that a full overlay refuses leave no
  # copy of the new config in /tmp: the failover worker tries again every
  # few seconds, and each copy would stay in RAM.
  cat >"$WORK/old.json" <<'JSON'
{"dns":{"servers":[{"type":"udp","tag":"dns-server","server":"1.1.1.1","server_port":53},{"type":"udp","tag":"bootstrap-dns-server","server":"77.88.8.8","server_port":53}]}}
JSON
  printf '{"version":1,"dns_type":"udp","dns_detour":"","main_servers":["1.1.1.1","8.8.8.8"],"bootstrap_servers":["77.88.8.8","9.9.9.9"],"main_index":1,"bootstrap_index":0}\n' \
    >"$WORK/candidate.json"
  [ -z "$(ls -A "$WORK/tmp")" ] || fail "the test /tmp is not empty: $(ls -A "$WORK/tmp")"
  for attempt in 1 2; do
    : >"$WORK/log"
    on_full_overlay patch-dns-config "$WORK/candidate.json"
    [ "$STATUS" != 0 ] || fail "a DNS failover switch on a full overlay reported success (attempt $attempt)"
    cmp -s "$WORK/old.json" "$WORK/after.json" || fail "a DNS failover switch on a full overlay changed config.json"
    [ -z "$(ls -A "$WORK/tmp")" ] ||
      fail "a DNS failover switch on a full overlay left in /tmp: $(ls -A "$WORK/tmp") (attempt $attempt)"
    grep -F '[error]' "$WORK/log" | grep -Fq "$CONFIG" ||
      fail "a DNS failover switch on a full overlay logged no error naming $CONFIG: $(cat "$WORK/log")"
  done

  # init-config, with the generator and the rule-set cache replaced: the
  # generated config stays in /tmp only until published.
  STUB_LIB="$WORK/stub-lib"
  mkdir -p "$STUB_LIB/singbox" "$STUB_LIB/config"
  for entry in "$LIB"/*; do
    case "${entry##*/}" in singbox | config) ;; *) ln -s "$entry" "$STUB_LIB/${entry##*/}" ;; esac
  done
  for entry in "$LIB"/singbox/* "$LIB"/config/*; do
    rel="${entry#"$LIB"/}"
    ln -s "$entry" "$STUB_LIB/$rel"
  done
  rm -f "$STUB_LIB/singbox/generator.uc" "$STUB_LIB/singbox/ruleset_cache.uc" "$STUB_LIB/config/validator.uc"
  cat >"$STUB_LIB/singbox/generator.uc" <<'UC'
let fs = require("fs");
let path = ARGV[1];
exit(fs.writefile(path, fs.readfile(getenv("WORK") + "/generated.json")) == null ? 1 : 0);
UC
  printf 'exit(0);\n' >"$STUB_LIB/singbox/ruleset_cache.uc"
  printf 'exit(1);\n' >"$STUB_LIB/config/validator.uc"
  printf '{"generated":"%s"}\n' "$(bytes 2000)" >"$WORK/generated.json"
  printf 'prokop.settings.service_listen_address=192.0.2.1\n' >>"$WORK/uci.state"
  : >"$WORK/log"
  PROKOP_LIB="$STUB_LIB" SB_VARIANT_STATE_FILE="$WORK/variant" on_full_overlay init-config 0 1 1 main
  [ "$STATUS" != 0 ] || fail "a start on a full overlay reported success"
  cmp -s "$WORK/old.json" "$WORK/after.json" || fail "a start on a full overlay changed config.json"
  [ -z "$(ls -A "$WORK/tmp")" ] || fail "a start on a full overlay left in /tmp: $(ls -A "$WORK/tmp")"
  grep -F '[error]' "$WORK/log" | grep -Fq "$CONFIG" ||
    fail "a start on a full overlay logged no error naming $CONFIG: $(cat "$WORK/log")"
  ok "a DNS failover switch or a start that a full overlay refuses leaves nothing in /tmp"
fi

# ---- 3. restores write only what changes ---------------------------------------

printf '{"previous":true}\n' >"$CONFIG"
chmod 0600 "$CONFIG"
for mode in restore-config-stage restore-dns-config; do
  cp "$CONFIG" "$WORK/tmp/backup.json"
  before="$(stamp)"
  runtime "$mode" "$WORK/tmp/backup.json" || fail "$mode of an identical backup failed"
  [ "$(stamp)" = "$before" ] || fail "$mode rewrote config.json with what it already held"
  [ ! -e "$WORK/tmp/backup.json" ] || fail "$mode did not consume an identical backup"

  printf '{"restored":"%s"}\n' "$mode" >"$WORK/tmp/backup.json"
  chmod 0644 "$WORK/tmp/backup.json"
  exec 3<"$CONFIG"
  runtime "$mode" "$WORK/tmp/backup.json" || fail "$mode of a different backup failed"
  grep -Fq "\"restored\":\"$mode\"" "$CONFIG" || fail "$mode did not put the backup back"
  [ "$(cat <&3)" = '{"previous":true}' ] || fail "$mode rewrote config.json in place"
  exec 3<&-
  [ "$(mode_of "$CONFIG")" = 600 ] || fail "$mode published a config that is not private"
  [ ! -e "$WORK/tmp/backup.json" ] || fail "$mode did not consume the backup"
  no_leftovers "$mode"
  printf '{"previous":true}\n' >"$CONFIG"
done
ok "a restore writes config.json only when the backup differs, and then by a rename"

# ---- 4. DNS failover writes once per switch --------------------------------------

cat >"$CONFIG" <<'JSON'
{"dns":{"servers":[{"type":"udp","tag":"dns-server","server":"1.1.1.1","server_port":53},{"type":"udp","tag":"bootstrap-dns-server","server":"77.88.8.8","server_port":53}]}}
JSON
chmod 0600 "$CONFIG"
writes=0
backups=()
# switch <main index>: patches config.json for that main DNS server; counts
# the patches that wrote config.json.
switch() {
  printf '{"version":1,"dns_type":"udp","dns_detour":"","main_servers":["1.1.1.1","8.8.8.8"],"bootstrap_servers":["77.88.8.8","9.9.9.9"],"main_index":%s,"bootstrap_index":0}\n' \
    "$1" >"$WORK/candidate.json"
  local before output
  before="$(stamp)"
  output="$(runtime patch-dns-config "$WORK/candidate.json")" || fail "the DNS failover patch to server $1 failed"
  if [ "$(stamp)" != "$before" ]; then
    writes=$((writes + 1))
    case "$output" in "1"$'\t'*) backups+=("${output#*$'\t'}") ;; *) fail "a patch that wrote config.json reported no change: $output" ;; esac
  else
    [ "$output" = 0 ] || fail "a patch that wrote nothing reported a change: $output"
  fi
}
switch 1
switch 1
switch 0
switch 0
switch 0
switch 1
[ "$writes" = 3 ] || fail "6 failover decisions with 3 switches wrote config.json $writes times"
grep -Eq '"server": ?"8\.8\.8\.8"' "$CONFIG" || fail "the last switch did not reach config.json"
cp "${backups[2]}" "$WORK/expected.json"
runtime restore-dns-config "${backups[2]}" || fail "the DNS failover backup could not be restored"
cmp -s "$WORK/expected.json" "$CONFIG" || fail "the DNS failover backup was not restored"
grep -Eq '"server": ?"1\.1\.1\.1"' "$CONFIG" || fail "the restored config does not use the previous DNS server"
rm -f "${backups[@]}"
no_leftovers "DNS failover"
ok "each DNS failover switch rewrites config.json once, a decision without a switch not at all"

# ---- a symlink that points to nothing -----------------------------------------

# config.json as a symlink into a directory that a reboot cleared: the
# publish keeps the symlink and fails (core/durable.uc), and the log says
# why, not that the overlay may be full (S5 integration review).
rm -f "$CONFIG"
ln -s "$WORK/cleared/config.json" "$CONFIG"
printf 'new config\n' >"$WORK/tmp/new.json"
: >"$WORK/log"
status=0
runtime save-config-file-fixture "$WORK/tmp/new.json" "$CONFIG" || status=$?
[ "$status" != 0 ] || fail "a publish over a symlink that points to nothing succeeded"
[ -L "$CONFIG" ] || fail "the publish replaced the symlink that points to nothing"
grep -F '[error]' "$WORK/log" | grep -F "$CONFIG" | grep -Fq 'points to nothing' ||
  fail "the failed publish did not say that config.json points to nothing: $(cat "$WORK/log")"
grep -Fq 'overlay full' "$WORK/log" && fail "the failed publish blamed a full overlay: $(cat "$WORK/log")"
rm -f "$CONFIG" "$WORK/tmp/new.json"
ok "a publish over a symlink that points to nothing fails and says so"

printf 'sing-box config publish checks passed\n'
