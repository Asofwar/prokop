#!/usr/bin/env bash
# The kill-switch is lifted whenever the package that can lift it goes away
# (UC-191): package removal, an upgrade or downgrade to a release without the
# kill-switch (in-app version picker or the package manager), full uninstall,
# and, when none of those ran, the watcher noticing that its package is gone.
# An upgrade to a release that manages the kill-switch keeps it.
#
# The package scripts are the ones build.sh and prokop/Makefile ship, run
# through the real CLI and service/package.uc; only nft, the init scripts and
# the package managers are stubs.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
PROKOP_CLI="$ROOT_DIR/prokop/files/usr/bin/prokop"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
PROKOP_MAKEFILE="$ROOT_DIR/prokop/Makefile"
FULL_UNINSTALL="$PROKOP_LIB/full-uninstall.sh"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

WATCHER=""
cleanup() {
  [ -z "$WATCHER" ] || owned_kill TERM "$WATCHER" || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'uci state:\n' >&2
  cat "$PROKOP_UCI_STATE_FILE" >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/apk-bin" "$WORK_DIR/run" "$WORK_DIR/ks" "$WORK_DIR/ruleset-post"
cat >"$WORK_DIR/bin/nft" <<'NFT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK_DIR/nft.log"
[ "$1" != -t ] || shift
case "$1 $2" in
  "list table")
    [ "$4" = "ProkopKillswitch" ] && { [ -e "$WORK_DIR/ks-present" ]; exit $?; }
    exit 1 ;;
  "list chain") exit 1 ;;
  "delete table") [ "$4" = "ProkopKillswitch" ] && rm -f "$WORK_DIR/ks-present"; exit 0 ;;
esac
exit 0
NFT
for name in logger dnsmasq-init killswitch-init ubus conntrack; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
[ -e "$WORK_DIR/sing-box-alive" ]
SH
# Prokop's own init script: running, and a stop does to dnsmasq what
# `prokop stop` does on a Prokop that is already down (service/lifecycle.uc
# stop_impl): the DNS block list goes back while the kill-switch is armed.
cat >"$WORK_DIR/bin/prokop-init" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"\$WORK_DIR/prokop-init.log"
[ "\$1" != stop ] || ucode -L "$PROKOP_LIB" "$PROKOP_LIB/dns/apply.uc" restore >/dev/null 2>&1
exit 0
SH
# The installed /usr/bin/prokop the package scripts call: the real CLI.
cat >"$WORK_DIR/bin/prokop" <<SH
#!/bin/sh
printf '%s\\n' "\$*" >>"$WORK_DIR/cli.log"
exec ucode "$PROKOP_CLI" "\$@"
SH
# apk is present only where a test puts this directory on PATH.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/apk-bin/apk"
chmod 0755 "$WORK_DIR/bin/"* "$WORK_DIR/apk-bin/apk"

export WORK_DIR
export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export PROKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export PROKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
export PROKOP_RT_TABLES="$WORK_DIR/rt_tables"
export PROKOP_INIT="$WORK_DIR/bin/prokop-init"
export PROKOP_BIN="$WORK_DIR/missing-prokop-bin"
export PROKOP_DNS_APPLY_UC="$PROKOP_LIB/dns/apply.uc"
export PROKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init"
export PROKOP_KILLSWITCH_UC="$KS_UC"
export KILLSWITCH_STATE_DIR="$WORK_DIR/ks"
export KILLSWITCH_NFT_INCLUDE="$WORK_DIR/ruleset-post/90-prokop-killswitch.nft"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"
export PROKOP_KILLSWITCH_LOCK_ATTEMPTS=2

POLICY="$KILLSWITCH_STATE_DIR/policy.nft"
SERVERS="$KILLSWITCH_STATE_DIR/dnsmasq.servers"
BLOCKED="$KILLSWITCH_STATE_DIR/dns-blocked.servers"
# The resolvers of excluded devices that their sections exempt (D-23).
EXEMPT="$KILLSWITCH_STATE_DIR/dns-exempt.json"
EXEMPT_CONF="$KILLSWITCH_CACHE_DIR/exempt-0.conf"

uci_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length($1) + 2) }' "$PROKOP_UCI_STATE_FILE"
}

# Prokop stopped with an armed kill-switch: the policy is live and saved,
# dnsmasq answers protected names with the block list.
arm() {
  cat >"$PROKOP_UCI_STATE_FILE" <<EOF
prokop.settings=settings
prokop.settings.shutdown_correctly=1
prokop.main=section
prokop.main.action=connection
prokop.main.kill_switch=1
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=1.1.1.1
dhcp.@dnsmasq[0].serversfile=$SERVERS
EOF
  printf '105 prokop\n' >"$PROKOP_RT_TABLES"
  printf 'add table inet ProkopKillswitch\n' >"$POLICY"
  printf 'server=/example.com/\n' >"$BLOCKED"
  cp "$BLOCKED" "$SERVERS"
  printf '{"format":1,"groups":[{"sources":["192.168.1.50/32"],"removed":["server=/example.com/"],"added":[]}]}\n' >"$EXEMPT"
  mkdir -p "$KILLSWITCH_CACHE_DIR"
  printf 'port=18055\n' >"$EXEMPT_CONF"
  touch "$WORK_DIR/ks-present"
}

assert_kept() {
  [ -s "$POLICY" ] || fail "$1: the saved policy must stay"
  [ -e "$WORK_DIR/ks-present" ] || fail "$1: the live policy must stay"
  [ "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" = "$SERVERS" ] || fail "$1: the DNS block list must stay attached"
  [ -s "$EXEMPT" ] || fail "$1: the groups of excluded devices must stay with the block list"
}

assert_lifted() {
  [ ! -e "$POLICY" ] || fail "$1: the saved policy must be removed"
  [ ! -e "$WORK_DIR/ks-present" ] || fail "$1: the live policy must be removed"
  [ -z "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" ] || fail "$1: dnsmasq must not read the block list any more"
  [ ! -e "$SERVERS" ] || fail "$1: the DNS servers file must be removed"
  [ ! -e "$BLOCKED" ] || fail "$1: the saved block list must be removed"
  [ ! -e "$EXEMPT" ] || fail "$1: the groups of excluded devices must be removed"
  [ ! -e "$EXEMPT_CONF" ] || fail "$1: the configuration of their resolvers must be removed"
}

# The text of a package script as shipped, its /usr/bin/prokop being the
# real CLI above.
heredoc_script() {
  awk -v start="$2" 'index($0, start) == 1 { copy = 1; next } copy && $0 == "EOF" { exit } copy { print }' "$1" |
    sed "s#/usr/bin/prokop#$WORK_DIR/bin/prokop#g" >"$3"
}
# make expands $$ to $ in a define.
make_script() {
  awk -v start="$2" '$0 == start { copy = 1; next } copy && $0 == "endef" { exit } copy { print }' "$1" |
    sed -e 's/[$][$]/$/g' -e "s#/usr/bin/prokop#$WORK_DIR/bin/prokop#g" >"$3"
}
heredoc_script "$BUILD_SCRIPT" "  cat > \"\$control_dir/prerm\" <<'EOF'" "$WORK_DIR/ipk-prerm"
heredoc_script "$BUILD_SCRIPT" "  cat > \"\$scripts_dir/backend-pre-upgrade.sh\" <<'EOF'" "$WORK_DIR/apk-pre-upgrade"
heredoc_script "$BUILD_SCRIPT" "  cat > \"\$scripts_dir/backend-pre-deinstall.sh\" <<'EOF'" "$WORK_DIR/apk-pre-deinstall"
make_script "$PROKOP_MAKEFILE" "define Package/prokop/prerm" "$WORK_DIR/sdk-prerm"
for script in ipk-prerm apk-pre-upgrade apk-pre-deinstall sdk-prerm; do
  grep -Fq "$WORK_DIR/bin/prokop package_prerm" "$WORK_DIR/$script" || fail "could not read the $script package script"
done

# An SDK package never runs Package/prokop/prerm itself
# (include/package-pack.mk): the ipk's prerm is "default_prerm $0 $@", which
# sources it as prerm-pkg in a subshell (package/base-files/files/lib/
# functions.sh), and the apk's pre-deinstall runs default_prerm and then the
# same text without its #! line. Both run under /bin/sh. default_prerm then
# stops every init script of the package, and disables it unless opkg
# upgrades it (PKG_UPGRADE): the kill-switch watcher is gone after that, so
# nothing lifts a protection left behind. Here the init scripts are the
# stubs under $INIT_ROOT.
mkdir -p "$WORK_DIR/opkg-info" "$WORK_DIR/initroot/etc/init.d"
cp "$WORK_DIR/sdk-prerm" "$WORK_DIR/opkg-info/prokop.prerm-pkg"
grep -o "\$(1)/etc/init\.d/[A-Za-z0-9_.-]*" "$PROKOP_MAKEFILE" | sed "s/^\$(1)//" >"$WORK_DIR/opkg-info/prokop.list"
grep -Fqx /etc/init.d/prokop-killswitch "$WORK_DIR/opkg-info/prokop.list" ||
  fail "the SDK package must ship the kill-switch init script: $(cat "$WORK_DIR/opkg-info/prokop.list")"
cat >"$WORK_DIR/initroot/etc/init.d/prokop" <<SH
#!/bin/sh
exec "$WORK_DIR/bin/prokop-init" "\$@"
SH
cat >"$WORK_DIR/initroot/etc/init.d/prokop-killswitch" <<SH
#!/bin/sh
exec "$WORK_DIR/bin/killswitch-init" "\$@"
SH
# The package's other init scripts (prokop-torrserver-direct) do nothing.
for name in $(sed -n 's#^/etc/init\.d/##p' "$WORK_DIR/opkg-info/prokop.list"); do
  [ -e "$WORK_DIR/initroot/etc/init.d/$name" ] ||
    printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/initroot/etc/init.d/$name"
done
chmod 0755 "$WORK_DIR/initroot/etc/init.d/"*
export INIT_ROOT="$WORK_DIR/initroot"
cat >"$WORK_DIR/functions.sh" <<'SH'
default_prerm() {
	[ -z "$pkgname" ] && local pkgname="$(basename ${1%.*})"
	local ret=0
	if [ -f "$OPKG_INFO/${pkgname}.prerm-pkg" ]; then
		( . "$OPKG_INFO/${pkgname}.prerm-pkg" )
		ret=$?
	fi
	for i in $(grep -s "^/etc/init.d/" "$OPKG_INFO/${pkgname}.list"); do
		if [ "$PKG_UPGRADE" != "1" ]; then
			"$INIT_ROOT$i" disable
		fi
		"$INIT_ROOT$i" stop
	done
	return $ret
}
SH
cat >"$WORK_DIR/opkg-info/prokop.prerm" <<'SH'
#!/bin/sh
. "$WORK_DIR/functions.sh"
default_prerm $0 $@
SH
{
  cat <<'SH'
#!/bin/sh
. "$WORK_DIR/functions.sh"
export pkgname="prokop"
default_prerm
SH
  sed '/^\s*#!/d' "$WORK_DIR/sdk-prerm"
} >"$WORK_DIR/sdk-pre-deinstall"
export OPKG_INFO="$WORK_DIR/opkg-info"

# opkg runs the installed prerm as "prerm upgrade <new version>"; apk runs
# the incoming package's pre-upgrade as "pre-upgrade <new> <old>".
run_script() {
  local script="$1"
  shift
  : >"$WORK_DIR/cli.log"
  ucode "$WORK_DIR/$script" "$@" || fail "$script $* failed"
}

run_sh_script() {
  local script="$1"
  shift
  : >"$WORK_DIR/cli.log"
  sh "$script" "$@" || fail "$script $* failed"
}

# ---- opkg ----------------------------------------------------------------------

arm
run_script ipk-prerm upgrade 1.0.40
grep -Fqx 'package_prerm upgrade 1.0.40' "$WORK_DIR/cli.log" || fail "prerm must pass the new version on: $(cat "$WORK_DIR/cli.log")"
assert_kept "upgrade to a release with the kill-switch (opkg)"

run_script ipk-prerm upgrade 1.0.31
assert_lifted "downgrade to a release without the kill-switch (opkg)"

arm
: >"$WORK_DIR/killswitch-init.log"
PKG_UPGRADE=1 run_sh_script "$WORK_DIR/opkg-info/prokop.prerm" upgrade 1.0.40
grep -Fqx 'package_prerm upgrade 1.0.40' "$WORK_DIR/cli.log" ||
  fail "the SDK prerm must pass the new version on: $(cat "$WORK_DIR/cli.log")"
grep -Fqx stop "$WORK_DIR/killswitch-init.log" || fail "default_prerm must stop the kill-switch service"
assert_kept "upgrade to a release with the kill-switch (SDK package, opkg)"

# An SDK build without a release version is 0.0.0 (prokop/Makefile
# PKG_VERSION), whatever its tree, so also a build that predates the
# kill-switch: it can neither lift the protection nor detach the block list
# from dnsmasq, and default_prerm has just stopped the watcher. The
# protection is lifted, and no stop that follows the prerm attaches the
# block list again.
PKG_UPGRADE=1 run_sh_script "$WORK_DIR/opkg-info/prokop.prerm" upgrade 0.0.0
grep -Fqx 'package_prerm upgrade 0.0.0' "$WORK_DIR/cli.log" ||
  fail "the SDK prerm must pass the development version on: $(cat "$WORK_DIR/cli.log")"
[ -z "$(uci_value 'dhcp.@dnsmasq[0].serversfile')" ] ||
  fail "downgrade to an SDK build that may predate the kill-switch: no DNS block list may stay attached to dnsmasq"
assert_lifted "downgrade to an SDK build without a release version (opkg)"

arm
PKG_UPGRADE=1 run_sh_script "$WORK_DIR/opkg-info/prokop.prerm" upgrade 1.0.30
assert_lifted "downgrade to a release without the kill-switch (SDK package, opkg)"

arm
run_sh_script "$WORK_DIR/opkg-info/prokop.prerm" remove
grep -Fqx 'package_prerm remove' "$WORK_DIR/cli.log" || fail "the SDK prerm must reach package_prerm: $(cat "$WORK_DIR/cli.log")"
assert_lifted "package removal (SDK package, opkg)"

# apk passes the removed version; a pre-deinstall only ever removes.
arm
run_sh_script "$WORK_DIR/sdk-pre-deinstall" 1.0.40
grep -Fqx 'package_prerm remove' "$WORK_DIR/cli.log" || fail "the SDK pre-deinstall must reach package_prerm: $(cat "$WORK_DIR/cli.log")"
assert_lifted "package removal (SDK package, apk)"

# opkg sets PKG_ROOT and PKG_UPGRADE for every script it runs (libopkg
# pkg_run_script). A prerm without an action (service/package.uc
# remember_upgrade_state) is a removal unless PKG_UPGRADE=1, as
# default_prerm takes it: it disables and stops the kill-switch watcher
# right after the SDK prerm, so only the prerm can lift the protection, and
# no restart may be handed to a later install.
for recipe in sdk ipk; do
  arm
  printf '1\n' >"$PROKOP_PACKAGE_UPGRADE_STATE"
  : >"$WORK_DIR/killswitch-init.log"
  if [ "$recipe" = sdk ]; then
    PKG_ROOT=/ PKG_UPGRADE=0 run_sh_script "$WORK_DIR/opkg-info/prokop.prerm"
    grep -Fqx disable "$WORK_DIR/killswitch-init.log" || fail "default_prerm must disable the kill-switch service on a removal"
  else
    PKG_ROOT=/ PKG_UPGRADE=0 run_script ipk-prerm
  fi
  grep -Fqx 'package_prerm remove' "$WORK_DIR/cli.log" ||
    fail "the $recipe prerm without an action must remove the package under PKG_UPGRADE=0: $(cat "$WORK_DIR/cli.log")"
  [ ! -e "$PROKOP_PACKAGE_UPGRADE_STATE" ] ||
    fail "the $recipe prerm without an action must not hand a restart to the next install of a removed package"
  assert_lifted "package removal without an action ($recipe package, opkg)"

  arm
  if [ "$recipe" = sdk ]; then
    PKG_ROOT=/ PKG_UPGRADE=1 run_sh_script "$WORK_DIR/opkg-info/prokop.prerm"
  else
    PKG_ROOT=/ PKG_UPGRADE=1 run_script ipk-prerm
  fi
  grep -Fqx 'package_prerm' "$WORK_DIR/cli.log" ||
    fail "the $recipe prerm without an action must leave an upgrade to the service's state: $(cat "$WORK_DIR/cli.log")"
  assert_kept "upgrade without an action ($recipe package, opkg)"
done

arm
run_script ipk-prerm upgrade
assert_kept "upgrade without a version (opkg)"

arm
run_script ipk-prerm remove
assert_lifted "package removal (opkg)"

# ---- apk -----------------------------------------------------------------------

PATH="$WORK_DIR/apk-bin:$PATH"
arm
run_script apk-pre-upgrade 1.0.40 1.0.32
grep -Fqx 'package_prerm upgrade 1.0.40' "$WORK_DIR/cli.log" || fail "pre-upgrade must pass the new version on: $(cat "$WORK_DIR/cli.log")"
assert_kept "upgrade to a release with the kill-switch (apk)"

# Every release up to 1.0.31 ships a pre-upgrade script that passes no
# version: such an incoming package knows nothing of the kill-switch.
printf '#!/usr/bin/ucode\nexit(system("%s package_prerm upgrade >/dev/null 2>&1"));\n' "$WORK_DIR/bin/prokop" >"$WORK_DIR/old-pre-upgrade"
run_script old-pre-upgrade 1.0.31 1.0.32
assert_lifted "downgrade through the pre-upgrade script of an old release (apk)"

arm
run_script apk-pre-upgrade 1.0.29 1.0.32
assert_lifted "downgrade to a release without the kill-switch (apk)"

arm
mkdir -p "$PROKOP_RUNTIME_STATE_DIR/killswitch.lock"
sleep 300 &
holder=$!
printf '%s\n' "$holder" >"$PROKOP_RUNTIME_STATE_DIR/killswitch.lock/pid"
run_script apk-pre-deinstall 1.0.32
owned_kill TERM "$holder" || true
wait "$holder" 2>/dev/null || true
assert_lifted "package removal with killswitch.lock held (apk)"
rm -rf "$PROKOP_RUNTIME_STATE_DIR/killswitch.lock"
PATH="${PATH#"$WORK_DIR/apk-bin:"}"

# ---- full uninstall ------------------------------------------------------------

ROOT="$WORK_DIR/root"
mkdir -p "$ROOT/etc/opkg" "$ROOT/bin" "$ROOT/usr/bin" "$ROOT/etc/config" "$ROOT/etc/init.d" \
  "$ROOT/etc/prokop/killswitch" "$ROOT/usr/share/nftables.d/ruleset-post" "$ROOT/packages"
printf 'original vendor repositories\n' >"$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
printf 'https://mirror.51343.ru/openwrt/releases/test\n' >"$ROOT/etc/opkg/distfeeds.conf"
touch "$ROOT/packages/prokop"
cat >"$ROOT/usr/bin/prokop" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PROKOP_UNINSTALL_ROOT/service-calls"
exit 0
SH
cat >"$ROOT/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
 status) [ -e "$PROKOP_UNINSTALL_ROOT/packages/$2" ] && echo 'Status: install ok installed';;
 remove) shift; for p in "$@"; do rm -f "$PROKOP_UNINSTALL_ROOT/packages/$p"; done;;
 *) exit 1;;
esac
SH
cat >"$ROOT/etc/init.d/dnsmasq" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PROKOP_UNINSTALL_ROOT/dnsmasq-calls"
SH
# The full uninstall detaches the block list from dnsmasq through the
# OpenWrt uci CLI; every call it makes is recorded.
UCI_BIN="$(command -v uci 2>/dev/null || true)"
if [ -n "$UCI_BIN" ]; then
  # Run by the real uci.
  cat >"$ROOT/bin/uci" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "\$PROKOP_UNINSTALL_ROOT/uci-calls"
exec "$UCI_BIN" "\$@"
SH
else
  # Backend CI has none, and the test shim does not resolve the @dnsmasq[0]
  # the full uninstall uses. A stub answers the one read the detach depends
  # on as uci would for the dhcp below, until the option is deleted; the
  # dhcp the calls leave behind is checked only with the real uci.
  printf 'NOTE: no uci CLI on PATH, the full uninstall is checked for its uci calls, not for the dhcp they leave\n' >&2
  cat >"$ROOT/bin/uci" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PROKOP_UNINSTALL_ROOT/uci-calls"
case "$*" in
  *" get prokop_detach.@dnsmasq[0].serversfile")
    grep -Fq " delete prokop_detach.@dnsmasq[0].serversfile" "$PROKOP_UNINSTALL_ROOT/uci-calls" ||
      printf '/etc/prokop/killswitch/dnsmasq.servers\n' ;;
esac
exit 0
SH
fi
chmod +x "$ROOT/bin/uci"
chmod +x "$ROOT/usr/bin/prokop" "$ROOT/bin/opkg" "$ROOT/etc/init.d/dnsmasq"
: >"$ROOT/uci-calls"
: >"$ROOT/dnsmasq-calls"
cat >"$ROOT/etc/config/dhcp" <<'EOF'
config dnsmasq
	option domain 'lan'
	option serversfile '/etc/prokop/killswitch/dnsmasq.servers'
EOF
printf 'server=/example.com/\n' >"$ROOT/etc/prokop/killswitch/dnsmasq.servers"
printf 'add table inet ProkopKillswitch\n' >"$ROOT/etc/prokop/killswitch/policy.nft"
printf '{"format":1}\n' >"$ROOT/etc/prokop/killswitch/dns-exempt.json"
printf '# loader\n' >"$ROOT/usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft"
printf 'add table inet ProkopKillswitch\n' >"$ROOT/usr/share/nftables.d/ruleset-post/90-prokop-killswitch.nft"

PROKOP_UNINSTALL_ROOT="$ROOT" PROKOP_MIRROR_BASE_URL="http://mirror.test" PATH="$ROOT/bin:$PATH" \
  sh "$FULL_UNINSTALL" start >"$ROOT/response"
uninstall_done() {
  status="$(cat "$ROOT"/www/prokop-uninstall.*.json 2>/dev/null)"
  case "$status" in *'"state":"complete"'* | *'"state":"failed"'*) return 0 ;; esac
  return 1
}
wait_until 60 uninstall_done || fail "full uninstall timed out"
printf '%s\n' "$status" | grep -q '"state":"complete"' || fail "full uninstall failed: $status"
grep -Fqx killswitch_disable "$ROOT/service-calls" || fail "full uninstall must lift the kill-switch first"
for path in /usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft \
  /usr/share/nftables.d/ruleset-post/90-prokop-killswitch.nft /etc/prokop; do
  [ ! -e "$ROOT$path" ] || fail "full uninstall left $path behind"
done
# It edits a copy of dhcp in its job under the fixture root, under a package
# name of its own (tests/full_uninstall_dhcp_detach.sh: what someone staged
# for dhcp in /tmp/.uci is neither committed nor dropped), never dhcp in the
# host's or the root's /etc/config through uci.
own_copy_call() { # own_copy_call <uci arguments>
  local line
  while IFS= read -r line; do
    case "$line" in
      "-q -c $ROOT/tmp/prokop-uninstall."*"/dhcp -t $ROOT/tmp/prokop-uninstall."*"/dhcp/save $1") return 0 ;;
    esac
  done <"$ROOT/uci-calls"
  return 1
}
own_copy_call 'delete prokop_detach.@dnsmasq[0].serversfile' ||
  fail "full uninstall must detach the kill-switch servers file from dnsmasq: $(cat "$ROOT/uci-calls")"
own_copy_call 'commit prokop_detach' || fail "full uninstall must commit its copy of dhcp through uci: $(cat "$ROOT/uci-calls")"
while IFS= read -r line; do
  case "$line" in
    "-q -c $ROOT/tmp/prokop-uninstall."*"/dhcp -t $ROOT/tmp/prokop-uninstall."*"/dhcp/save "*" prokop_detach"*) ;;
    *) fail "full uninstall must edit only its own copy of dhcp through uci: $line" ;;
  esac
done <"$ROOT/uci-calls"
grep -Fqx restart "$ROOT/dnsmasq-calls" || fail "dnsmasq must be restarted without the block list"
if [ -n "$UCI_BIN" ]; then
  ! grep -Fq /etc/prokop/killswitch/dnsmasq.servers "$ROOT/etc/config/dhcp" ||
    fail "full uninstall must detach the kill-switch servers file from dnsmasq"
  grep -Fqx "	option domain 'lan'" "$ROOT/etc/config/dhcp" ||
    fail "full uninstall must keep the rest of dhcp: $(cat "$ROOT/etc/config/dhcp")"
fi

# ---- the package went away and nothing lifted the protection -------------------

# A copy of the watcher's module stands for the package's file: removing
# it is what a removal or a downgrade without its scripts does.
mkdir -p "$WORK_DIR/package/killswitch"
cp "$KS_UC" "$WORK_DIR/package/killswitch/runtime.uc"
arm
PROKOP_KILLSWITCH_WATCH_ITERATIONS=20000 PROKOP_KILLSWITCH_WATCH_INTERVAL_MS=1 \
  ucode -L "$PROKOP_LIB" "$WORK_DIR/package/killswitch/runtime.uc" watch &
WATCHER=$!
sleep 0.5
process_running "$WATCHER" || fail "the watcher must keep running while its package is installed"
assert_kept "watcher with its package installed"
rm -f "$WORK_DIR/package/killswitch/runtime.uc"
wait_until 15 sh -c "! kill -0 $WATCHER 2>/dev/null" || fail "the watcher must stop once its package is gone"
wait "$WATCHER" 2>/dev/null || true
WATCHER=""
assert_lifted "watcher whose package is gone"
grep -Fqx restart "$WORK_DIR/dnsmasq-init.log" || fail "dnsmasq must be restarted without the block list"
grep -Fq 'service delete' "$WORK_DIR/ubus.log" || fail "the orphaned kill-switch service must be removed from procd"

printf 'killswitch_owner_package: PASS\n'
