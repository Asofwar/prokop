#!/usr/bin/env bash
# One writer for files on flash (core/durable.uc). Every file that Prokop
# replaces on flash is written to a temporary file next to it, read back
# (a full filesystem takes the write of a small file and keeps none of it,
# UC-241) and renamed over it; the rare, critical ones are flushed (sync)
# before and after the rename (UC-025).
#
# A symlink stays one, as with a libuci commit: the file it points to is
# replaced, through a temporary file next to that file, and a symlink that
# points to nothing is not replaced by a regular file.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
# A call the uci test shim refused fails the test, even one it tolerated.
cleanup() {
  local rc=$?
  uci_cli_report || [ "$rc" != 0 ] || rc=1
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# The UCI writers commit through the uci CLI.
# shellcheck source=tests/helpers/uci_cli/select.sh
source "$ROOT_DIR/tests/helpers/uci_cli/select.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/sync"
# sync: every call keeps a copy of the watched directories ($SYNC_WATCH) as
# they are at that moment in $SYNC_LOG/<n>/.
cat >"$WORK/bin/sync" <<'SH'
#!/bin/sh
n=$(( $(cat "$SYNC_LOG/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$SYNC_LOG/count"
for dir in $SYNC_WATCH; do
  mkdir -p "$SYNC_LOG/$n$dir"
  cp -a "$dir/." "$SYNC_LOG/$n$dir/" 2>/dev/null || true
done
exit 0
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod 0755 "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" SYNC_LOG="$WORK/sync" SYNC_WATCH=""
export LIB WORK
# Nothing of this test lands in the host's runtime directory.
export PROKOP_RUNTIME_STATE_DIR="$WORK/run" PROKOP_NFT_SUBNET_CACHE_DIR="$WORK/run/nft-subnet-cache"

durable_uc() { ucode -L "$LIB" -e "let durable = require('core.durable'); let fs = require('fs'); $1"; }
watch() { rm -rf "$WORK/sync"; mkdir -p "$WORK/sync"; SYNC_WATCH="$*"; }
sync_count() { cat "$WORK/sync/count" 2>/dev/null || echo 0; }
# leftovers DIR: the temporary files writers left in DIR.
leftovers() { find "$1" -mindepth 1 -maxdepth 1 -name '*prokop-*' -printf '%f ' 2>/dev/null; }

# ---- 1. a symlink stays one ----------------------------------------------------

mkdir -p "$WORK/link/etc" "$WORK/link/real"
REAL="$WORK/link/real/config"
LINK="$WORK/link/etc/config"
printf 'old\n' >"$REAL"
chmod 0640 "$REAL"
ln -s ../real/config "$LINK"
watch "$WORK/link/etc" "$WORK/link/real"
result="$(LINK="$LINK" durable_uc 'print(durable.durable_replace(getenv("LINK") + ".tmp", getenv("LINK"), "new\n", 0600));')"
[ "$result" = true ] || fail "a durable write through a symlink failed: $result"
[ -L "$LINK" ] || fail "a durable write replaced the symlink with a regular file"
[ "$(readlink "$LINK")" = ../real/config ] || fail "a durable write changed where the symlink points: $(readlink "$LINK")"
[ "$(cat "$REAL")" = new ] || fail "a durable write through a symlink did not reach the file it points to: $(cat "$REAL")"
[ "$(stat -c %a "$REAL")" = 600 ] || fail "a durable write through a symlink did not give the file its mode"
[ -z "$(leftovers "$WORK/link/etc")$(find "$WORK/link" -name '*.tmp' -printf '%f ')" ] ||
  fail "a durable write through a symlink left its temporary file"
# The temporary file was next to the file it replaced, flushed there before
# the rename, and the rename was flushed after it.
n=1 before="" after=""
while [ "$n" -le "$(sync_count)" ]; do
  snap="$WORK/sync/$n$WORK/link/real"
  if [ -z "$before" ] && [ -f "$snap/config.tmp" ] && [ "$(cat "$snap/config.tmp")" = new ] && [ "$(cat "$snap/config")" = old ]; then
    before=$n
  elif [ -n "$before" ] && [ "$(cat "$snap/config")" = new ] && [ ! -e "$snap/config.tmp" ]; then
    after=$n
  fi
  n=$((n + 1))
done
[ -n "$before" ] && [ -n "$after" ] || fail "a durable write through a symlink was not flushed next to its target before and after the rename"

# durable_rewrite keeps the mode of the file it replaces, through the
# symlink; checked_replace (no flush) keeps the symlink as well.
chmod 0640 "$REAL"
watch
result="$(LINK="$LINK" durable_uc 'print(durable.durable_rewrite(getenv("LINK"), "rewritten\n", 0644));')"
[ "$result" = true ] && [ -L "$LINK" ] && [ "$(cat "$REAL")" = rewritten ] && [ "$(stat -c %a "$REAL")" = 640 ] ||
  fail "a rewrite through a symlink: $result, $(stat -c '%F %a' "$LINK" "$REAL" | tr '\n' ' ')"
[ "$(sync_count)" -ge 2 ] || fail "a rewrite was not flushed"
[ -z "$(leftovers "$WORK/link/real")" ] || fail "a rewrite left its temporary file: $(leftovers "$WORK/link/real")"
watch
result="$(LINK="$LINK" durable_uc 'print(durable.checked_replace(getenv("LINK") + ".tmp", getenv("LINK"), "checked\n", 0600));')"
[ "$result" = true ] && [ -L "$LINK" ] && [ "$(cat "$REAL")" = checked ] ||
  fail "a checked write through a symlink: $result, $(stat -c '%F' "$LINK")"
[ "$(sync_count)" = 0 ] || fail "a checked write must not flush"

# A new file gets new_mode; an existing one keeps its own.
result="$(NEW="$WORK/link/real/new" durable_uc 'print(durable.durable_rewrite(getenv("NEW"), "x\n", 0604));')"
[ "$result" = true ] && [ "$(stat -c %a "$WORK/link/real/new")" = 604 ] || fail "a new file did not get its mode: $result"

# A symlink that points to nothing is left as it is: the write fails.
ln -s ../real/missing "$WORK/link/etc/dangling"
for fn in 'durable.durable_replace(getenv("P") + ".tmp", getenv("P"), "x\n", 0600)' \
  'durable.durable_rewrite(getenv("P"), "x\n", 0600)' 'durable.checked_replace(getenv("P") + ".tmp", getenv("P"), "x\n")'; do
  result="$(P="$WORK/link/etc/dangling" durable_uc "print($fn);")"
  [ "$result" = false ] || fail "a write through a symlink that points to nothing succeeded: $fn"
  [ -L "$WORK/link/etc/dangling" ] && [ ! -e "$WORK/link/real/missing" ] ||
    fail "a write through a symlink that points to nothing replaced it: $fn"
done
[ -z "$(find "$WORK/link" -name '*.tmp' -printf '%f ')$(leftovers "$WORK/link/etc")$(leftovers "$WORK/link/real")" ] ||
  fail "a refused write left a temporary file"
ok "a symlink stays one: the file it points to is replaced"

# ---- 2. the rename step --------------------------------------------------------

# swap() renames in place of a plain rename, between the two flushes; when
# it declines, nothing is replaced and no temporary file stays.
printf 'kept\n' >"$WORK/swap"
watch "$WORK"
result="$(F="$WORK/swap" durable_uc '
  let calls = [];
  let ok = durable.durable_replace(getenv("F") + ".tmp", getenv("F"), "new\n", null, function(tmp, target) {
      push(calls, fs.readfile(tmp) == "new\n" && target == getenv("F") && fs.readfile(getenv("SYNC_LOG") + "/count") == "1\n");
      return false;
  });
  print(ok, " ", calls, "\n");')"
[ "$result" = 'false [ true ]' ] || fail "a declined swap: $result"
[ "$(cat "$WORK/swap")" = kept ] && [ ! -e "$WORK/swap.tmp" ] || fail "a declined swap replaced the file or left its temporary file"
result="$(F="$WORK/swap" durable_uc '
  print(durable.durable_replace(getenv("F") + ".tmp", getenv("F"), "new\n", null, function(tmp, target) { return fs.rename(tmp, target); }));')"
[ "$result" = true ] && [ "$(cat "$WORK/swap")" = new ] || fail "a swap that renames: $result"
[ "$(sync_count)" -ge 3 ] || fail "the rename of a swap was not flushed after it"
ok "a swap renames between the two flushes or leaves the file"

# ---- 3. the rare, critical writers ---------------------------------------------

# flushed FILE LABEL: a flush saw the present content of FILE complete in
# another file next to it (its temporary copy) while FILE did not hold it
# yet, and the next flush saw FILE hold it and no copy of it left.
flushed() {
  local file=$1 label=$2 dir base n snap before="" after=""
  dir="$(dirname "$file")"
  base="$(basename "$file")"
  cp "$file" "$WORK/want"
  for ((n = 1; n <= $(sync_count); n++)); do
    snap="$WORK/sync/$n$dir"
    if [ -n "$before" ]; then
      if cmp -s "$snap/$base" "$WORK/want" && ! copy_in "$snap" "$base"; then after=$n; fi
      break
    fi
    cmp -s "$snap/$base" "$WORK/want" && continue
    if copy_in "$snap" "$base"; then before=$n; fi
  done
  [ -n "$before" ] || fail "$label: not flushed while complete in its temporary file, before the rename"
  [ -n "$after" ] || fail "$label: the rename was not flushed right after it"
}
# copy_in SNAP BASE: a file of SNAP other than BASE holds what $WORK/want holds.
copy_in() {
  local f
  for f in "$1"/* "$1"/.[!.]*; do
    [ -f "$f" ] && [ "${f##*/}" != "$2" ] && cmp -s "$f" "$WORK/want" && return 0
  done
  return 1
}

# The Clash API secret committed alone (core/uci.uc commit_option) and an
# edit of /etc/config/dhcp (core/uci.uc session) through the uci CLI.
mkdir -p "$WORK/etc/config"
CONFIG="$WORK/etc/config/prokop"
DHCP="$WORK/etc/config/dhcp"
printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n" >"$CONFIG"
printf "config dnsmasq 'main'\n\toption domainneeded '1'\n" >"$DHCP"
chmod 0600 "$CONFIG"
chmod 0644 "$DHCP"
watch "$WORK/etc/config"
result="$(F="$CONFIG" CLI="$UCI_CLI" ucode -L "$LIB" -e '
  print(require("core.uci").commit_option(getenv("F"), "prokop.settings.yacd_secret_key", "s3cret-durable", true, getenv("CLI")));')"
[ "$result" = written ] || fail "commit_option: $result"
grep -Fq "s3cret-durable" "$CONFIG" || fail "commit_option did not write the secret: $(cat "$CONFIG")"
flushed "$CONFIG" "the secret commit_option writes to /etc/config/prokop"
[ "$(stat -c %a "$CONFIG")" = 600 ] || fail "commit_option changed the mode of the configuration"
[ -z "$(leftovers "$WORK/etc/config")" ] || fail "commit_option left: $(leftovers "$WORK/etc/config")"
watch "$WORK/etc/config"
result="$(F="$DHCP" CLI="$UCI_CLI" ucode -L "$LIB" -e '
  let s = require("core.uci").session("dhcp", getenv("F"), getenv("CLI"));
  print(s.set("dhcp.main.server", [ "127.0.0.42" ]) && s.commit());')"
[ "$result" = true ] || fail "a dhcp session commit: $result"
grep -Fq "127.0.0.42" "$DHCP" || fail "the dhcp session did not commit: $(cat "$DHCP")"
flushed "$DHCP" "a dhcp session commit"
[ "$(stat -c %a "$DHCP")" = 644 ] || fail "a dhcp session commit changed the mode of /etc/config/dhcp"
[ -z "$(leftovers "$WORK/etc/config")" ] || fail "a dhcp session commit left: $(leftovers "$WORK/etc/config")"
ok "UCI writers flush before and after the rename"

# rt_tables: the start adds the table name, the package removal removes it.
cat >"$WORK/bin/ip" <<'IP'
#!/bin/sh
case "$*" in
  "route list table prokop") echo 'local default dev lo scope host' ;;
  "-6 route list table prokop") echo 'local default dev lo metric 1024 pref medium' ;;
  "-4 rule list"|"-6 rule list") echo '105: from all fwmark 0x100000/0x100000 lookup prokop' ;;
esac
exit 0
IP
chmod 0755 "$WORK/bin/ip"
mkdir -p "$WORK/etc/iproute2"
RT="$WORK/etc/iproute2/rt_tables"
printf '%s\n' '255 local' '254 main' '200 vendor' >"$RT"
watch "$WORK/etc/iproute2"
ucode -L "$LIB" "$LIB/nft/apply.uc" ensure-tproxy-route-rule prokop 0x00100000 "$RT" || fail "the start could not name its table"
grep -Fxq '105 prokop' "$RT" || fail "the start did not name its table: $(cat "$RT")"
flushed "$RT" "rt_tables the start writes"
watch "$WORK/etc/iproute2"
PROKOP_RT_TABLES="$RT" ucode -L "$LIB" "$LIB/service/package.uc" remove-rt-tables-entry || fail "the package removal failed"
if grep -Fq prokop "$RT"; then fail "the package removal kept its table: $(cat "$RT")"; fi
flushed "$RT" "rt_tables the package removal writes"
[ -z "$(leftovers "$WORK/etc/iproute2")" ] || fail "rt_tables writers left: $(leftovers "$WORK/etc/iproute2")"
ok "rt_tables is flushed before and after the rename"

# The package feeds the mirror migration rewrites for a mirror the user opted
# in to (the dependency mirror is opt-in).
cat >"$WORK/bin/curl" <<'CURL'
#!/bin/sh
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; output="$1" ;;
    */openwrt/forkop-platforms.tsv) url=platforms ;;
  esac
  shift
done
[ "$url" = platforms ] || exit 22
printf '%s\n' 'mediatek/filogic aarch64_cortex-a53 24.10.5 ipk' >"$output"
CURL
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/opkg"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/uci-stub"
chmod 0755 "$WORK/bin/curl" "$WORK/bin/opkg" "$WORK/bin/uci-stub"
OPKG_ROOT="$WORK/opkg-root"
mkdir -p "$OPKG_ROOT/etc/opkg"
printf '%s\n' "DISTRIB_RELEASE='24.10.5'" "DISTRIB_TARGET='mediatek/filogic'" "DISTRIB_ARCH='aarch64_cortex-a53'" \
  >"$OPKG_ROOT/etc/openwrt_release"
FEEDS="$OPKG_ROOT/etc/opkg/distfeeds.conf"
printf '%s\n' 'src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/packages' >"$FEEDS"
watch "$OPKG_ROOT/etc/opkg"
PROKOP_MIGRATION_ROOT="$OPKG_ROOT" PROKOP_MIGRATION_APK_BIN="$WORK/bin/missing-apk" \
  PROKOP_MIGRATION_OPKG_BIN="$WORK/bin/opkg" PROKOP_MIGRATION_CURL_BIN="$WORK/bin/curl" \
  PROKOP_MIGRATION_UCI_BIN="$WORK/bin/uci-stub" PROKOP_MIRROR_BASE_URL="https://mirror.example.test" \
  sh "$ROOT_DIR/prokop/files/usr/share/prokop/mirror-migration.sh" ||
  fail "the mirror migration failed"
grep -Fq 'mirror.example.test' "$FEEDS" || fail "the mirror migration did not rewrite the feeds: $(cat "$FEEDS")"
flushed "$FEEDS" "the feeds the mirror migration rewrites"
ok "the mirror migration flushes the feeds before and after the rename"

# The managed sing-box init script, the kill-switch servers file dnsmasq
# reads at boot: in a mount namespace (/etc/init.d, a full overlay).
if ! unshare -rm true 2>/dev/null; then
  printf 'NOTE: no user and mount namespaces; the init script and full overlay checks are skipped\n'
else
  mkdir -p "$WORK/initd" "$WORK/run"
  printf 'extended-compressed\n' >"$WORK/variant"
  {
    printf '%s\n' 'prokop.settings=settings' "prokop.settings.config_path=$WORK/config.json"
    printf '%s\n' 'sing-box.main=sing-box' 'sing-box.main.enabled=1' 'sing-box.main.user=root'
    printf '%s\n' "sing-box.main.conffile=$WORK/config.json"
  } >"$WORK/uci.state"
  cat >"$WORK/initd.sh" <<'INITD'
set -e
mount --bind "$WORK/initd" /etc/init.d
PROKOP_UCI_STATE_FILE="$WORK/uci.state" PROKOP_UCI_LOG_FILE="$WORK/uci.log" PROKOP_RUNTIME_STATE_DIR="$WORK/run" \
  SB_VARIANT_STATE_FILE="$WORK/variant" ucode -L "$LIB" "$LIB/singbox/runtime.uc" configure-service
INITD
  watch "$WORK/initd"
  unshare -rm sh "$WORK/initd.sh" >"$WORK/initd.out" 2>&1 || fail "configure-service failed: $(cat "$WORK/initd.out")"
  grep -q 'Prokop managed sing-box service' "$WORK/initd/sing-box" || fail "the managed init script was not installed"
  [ "$(stat -c %a "$WORK/initd/sing-box")" = 755 ] || fail "the managed init script is not executable"
  flushed "$WORK/initd/sing-box" "the managed sing-box init script"
  ok "the managed init script is flushed before and after the rename"

  # A full overlay takes the small write of the servers file and keeps none
  # of it: the block list dnsmasq reads at boot must not become empty.
  mkdir -p "$WORK/ks"
  printf '%s\n' 'dhcp.@dnsmasq[0]=dnsmasq' 'dhcp.@dnsmasq[0].server=1.1.1.1' >"$WORK/ks-uci.state"
  printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/dnsmasq-init"
  chmod 0755 "$WORK/bin/dnsmasq-init"
  cat >"$WORK/ks-full.sh" <<'KSFULL'
mount -t tmpfs -o size=16k tmpfs "$WORK/ks" || exit 90
printf 'server=/old.example/\n' >"$WORK/ks/dnsmasq.servers"
printf 'server=/example.com/\nserver=/example.net/\n' >"$WORK/ks/dns-blocked.servers"
dd if=/dev/zero of="$WORK/ks/fill" bs=1k 2>/dev/null
PROKOP_UCI_STATE_FILE="$WORK/ks-uci.state" KILLSWITCH_STATE_DIR="$WORK/ks" DNSMASQ_INIT="$WORK/bin/dnsmasq-init" \
  ucode -L "$LIB" "$LIB/dns/apply.uc" killswitch-refresh
cp "$WORK/ks/dnsmasq.servers" "$WORK/ks-full.after"
ls -A "$WORK/ks" >"$WORK/ks-full.list"
exit 0
KSFULL
  unshare -rm sh "$WORK/ks-full.sh" >"$WORK/ks-full.out" 2>&1 || fail "the full overlay run failed: $(cat "$WORK/ks-full.out")"
  [ "$(cat "$WORK/ks-full.after")" = 'server=/old.example/' ] ||
    fail "a full overlay replaced the kill-switch servers file with: '$(cat "$WORK/ks-full.after")'"
  [ "$(sort "$WORK/ks-full.list" | tr '\n' ' ')" = 'dns-blocked.servers dnsmasq.servers fill ' ] ||
    fail "a full overlay left a copy of the servers file: $(cat "$WORK/ks-full.list")"
  ok "a full overlay fails the servers file write and keeps the old one"
fi

# ---- 4. the other rare, critical writers ----------------------------------------

# The variant marker and the version of a binary sing-box variant, read on
# every start.
mkdir -p "$WORK/etc/prokop"
printf 'extended\n' >"$WORK/etc/prokop/sing-box-variant"
printf '1.11.0\n' >"$WORK/etc/prokop/sing-box-version"
watch "$WORK/etc/prokop"
SB_VARIANT_STATE_FILE="$WORK/etc/prokop/sing-box-variant" ucode -L "$LIB" "$LIB/singbox/runtime.uc" write-variant-marker extended-compressed ||
  fail "the variant marker could not be written"
[ "$(cat "$WORK/etc/prokop/sing-box-variant")" = extended-compressed ] || fail "the variant marker was not written"
flushed "$WORK/etc/prokop/sing-box-variant" "the sing-box variant marker"
watch "$WORK/etc/prokop"
SB_VERSION_STATE_FILE="$WORK/etc/prokop/sing-box-version" ucode -L "$LIB" "$LIB/singbox/runtime.uc" write-version-state 1.12.0 ||
  fail "the version state could not be written"
[ "$(cat "$WORK/etc/prokop/sing-box-version")" = 1.12.0 ] || fail "the version state was not written"
flushed "$WORK/etc/prokop/sing-box-version" "the sing-box version state"
[ -z "$(find "$WORK/etc/prokop" -name '*.tmp*' -printf '%f ')" ] || fail "the marker writers left a temporary file"
ok "the sing-box variant marker and version state are flushed before and after the rename"

# The recovery marker of an in-app Prokop upgrade, which the recovery after a
# power cut mid-install reads (tests/helpers/prokop_upgrade_harness.sh).
WORK_DIR="$WORK"
# shellcheck source=tests/helpers/prokop_upgrade_harness.sh
. "$ROOT_DIR/tests/helpers/prokop_upgrade_harness.sh"
upgrade_harness_setup
cp "$WORK/bin/sync" "$UPGRADE_BIN/sync"
upgrade_harness_reset opkg
mkdir -p "$UPGRADE_RECOVERY_DIR"
watch "$UPGRADE_RECOVERY_DIR"
upgrade_harness_run || fail "the in-app upgrade failed: $(cat "$UPGRADE_OUT")"
[ "$(upgrade_harness_version prokop)" = 1.1.0-r1 ] || fail "the in-app upgrade did not install the new release"
n=1 before="" after=""
while [ "$n" -le "$(sync_count)" ]; do
  snap="$WORK/sync/$n$UPGRADE_RECOVERY_DIR"
  if [ -n "$before" ]; then
    [ -f "$snap/pending" ] && cmp -s "$snap/pending" "$WORK/want" && [ ! -e "$snap/pending.new" ] && after=$n
    break
  fi
  if [ ! -e "$snap/pending" ] && [ -f "$snap/pending.new" ] && grep -q "^1\.0\.0	1\.1\.0	" "$snap/pending.new"; then
    cp "$snap/pending.new" "$WORK/want"
    before=$n
  fi
  n=$((n + 1))
done
[ -n "$before" ] || fail "the upgrade recovery marker was not flushed complete before its rename"
[ -n "$after" ] || fail "the rename of the upgrade recovery marker was not flushed right after it"
ok "the upgrade recovery marker is flushed before and after the rename"

# The managed sing-box init script that a component install
# (components/action.uc) and the requirements check (config/validator.uc)
# install: in a mount namespace with /etc/init.d of its own.
if unshare -rm true 2>/dev/null; then
  printf 'extended-compressed\n' >"$WORK/variant"
  for writer in action validator; do
    rm -rf "$WORK/initd-$writer"
    mkdir -p "$WORK/initd-$writer"
    cat >"$WORK/install-$writer.sh" <<'INSTALL'
set -e
mount --bind "$WORK/initd-$WRITER" /etc/init.d
if [ "$WRITER" = action ]; then
  ucode -L "$LIB" "$LIB/components/action.uc" install-managed-sing-box-service-fixture
else
  printf '#!/bin/sh\necho "sing-box version 1.12.0"\n' >"$WORK/bin/sing-box"
  printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/nft"
  chmod 0755 "$WORK/bin/sing-box" "$WORK/bin/nft"
  : >"$WORK/validator-uci.state"
  PROKOP_UCI_STATE_FILE="$WORK/validator-uci.state" SB_VARIANT_STATE_FILE="$WORK/variant" \
    SB_VERSION_STATE_FILE="$WORK/etc/prokop/sing-box-version" TMPDIR="$WORK" \
    ucode -L "$LIB" "$LIB/config/validator.uc" check-requirements || true
fi
INSTALL
    watch "$WORK/initd-$writer"
    WRITER="$writer" unshare -rm sh "$WORK/install-$writer.sh" >"$WORK/install-$writer.out" 2>&1 ||
      fail "the $writer install of the init script failed: $(cat "$WORK/install-$writer.out")"
    grep -q 'Prokop managed sing-box service' "$WORK/initd-$writer/sing-box" ||
      fail "the $writer install did not write the managed init script: $(cat "$WORK/install-$writer.out")"
    [ "$(stat -c %a "$WORK/initd-$writer/sing-box")" = 755 ] || fail "the init script the $writer install writes is not executable"
    flushed "$WORK/initd-$writer/sing-box" "the init script the $writer install writes"
    [ -z "$(find "$WORK/initd-$writer" -name 'sing-box.*' -printf '%f ')" ] || fail "the $writer install left a copy of the init script"
  done
  ok "the init script of a component install and of the requirements check is flushed before and after the rename"
fi

printf 'durable_writers: PASS\n'
