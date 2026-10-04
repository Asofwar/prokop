#!/usr/bin/env bash
# The backend package of the OpenWrt SDK recipe (prokop/Makefile) is the
# package build.sh builds for the releases (D-21 (a), UC-082): the same
# files with the same modes and contents, the same conffiles, and package
# scripts that do the same.
#
# Before, the SDK package lacked /etc/init.d/prokop-torrserver-direct
# (TorrServer Direct could not be enabled), installed the configuration
# 0600 where build.sh installed it 0644 (both install it 0600 now: it holds
# secrets), copied the library with whatever modes the checkout had, refused an
# x.y.z-N release version (so did the LuCI app's recipe), never stopped
# Prokop before an apk upgrade (apk runs no pre-upgrade script of a package
# without Package/preinst), and OpenWrt's default package scripts, which
# the SDK wraps around a package's own, enabled Prokop on its first install
# and started it after every install and upgrade: also a Prokop the user
# had stopped (D-15) and, on apk, before its configuration was migrated.
# Their prerm disables Prokop on a removal: a reinstall (opkg install
# --force-reinstall, remove and install) must keep Prokop's autostart, as
# build.sh's packages do, once their postinst no longer enables it. Their
# prerm also stopped Prokop a second time on an opkg upgrade and on a
# removal (on apk before package_prerm), as the user, besides
# package_prerm's stops: after a removal and a new install Prokop showed as
# stopped by the user where build.sh's shows it not started; and the SDK
# prerm took an
# opkg prerm without an action (service/package.uc remember_upgrade_state)
# for a removal also on an upgrade (PKG_UPGRADE=1), where build.sh's let
# package_prerm decide by the service's state, while build.sh's took it for
# an upgrade also on a removal, which left the kill-switch, the explicit
# start and a restart for the next install behind.
#
# The SDK recipe runs through GNU make against a stand-in of the SDK's
# rules.mk and package.mk with OpenWrt's install commands and its way of
# writing a package script (shexport, echo); the default package scripts
# follow OpenWrt's lib/functions.sh and include/package-pack.mk (24.10
# ipk, 25.12 apk); the init script is the real one, with its rc.d moved
# into a scratch root, behind an rc.common stand-in.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT
trap 'exit 1' HUP INT TERM
# What a package manager or Prokop sets for a package script is each case's
# own.
unset PKG_ROOT PKG_UPGRADE APK_SCRIPT IPKG_INSTROOT PROKOP_START_REQUEST PROKOP_STOP_SOURCE
# shellcheck source=tests/helpers/build_recipe.sh
. "$ROOT_DIR/tests/helpers/build_recipe.sh"

EVENTS="$WORK_DIR/events"
export EVENTS WORK_DIR
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  exit 1
}

command -v make >/dev/null 2>&1 || fail "GNU make is required to read prokop/Makefile"

# ---- the SDK recipe through make -------------------------------------------

mkdir -p "$WORK_DIR/sdk/include"
cat >"$WORK_DIR/sdk/rules.mk" <<'MK'
# OpenWrt's rules.mk, as far as a package recipe uses it.
SHELL:=/usr/bin/env bash
INCLUDE_DIR:=$(TOPDIR)/include
CP:=cp -fpR
INSTALL_BIN:=install -m0755
INSTALL_DIR:=install -d -m0755
INSTALL_DATA:=install -m0644
INSTALL_CONF:=install -m0600
define shvar
V_$(subst .,_,$(subst -,_,$(subst /,_,$(1))))
endef
define shexport
export $(call shvar,$(1))=$$(call $(1))
endef
MK
cat >"$WORK_DIR/sdk/include/package.mk" <<'MK'
define BuildPackage
endef
MK
# What include/package-pack.mk does with a package: its files, and its
# scripts written as BuildPackVariable writes them.
cat >"$WORK_DIR/sdk/stage.mk" <<'MK'
include Makefile
$(eval $(call shexport,Package/prokop/conffiles))
$(eval $(call shexport,Package/prokop/preinst))
$(eval $(call shexport,Package/prokop/postinst))
$(eval $(call shexport,Package/prokop/prerm))
.PHONY: stage
stage:
	rm -rf $(STAGE)
	mkdir -p $(STAGE)/root $(STAGE)/control
	$(call Package/prokop/install,$(STAGE)/root)
	echo "$$V_Package_prokop_conffiles" > $(STAGE)/control/conffiles
	echo "$$V_Package_prokop_preinst" > $(STAGE)/control/preinst
	echo "$$V_Package_prokop_postinst" > $(STAGE)/control/postinst-pkg
	echo "$$V_Package_prokop_prerm" > $(STAGE)/control/prerm-pkg
	chmod 0755 $(STAGE)/control/preinst $(STAGE)/control/postinst-pkg $(STAGE)/control/prerm-pkg
	printf '%s|%s\n' '$(PKG_VERSION)' '$(PKG_RELEASE)' > $(STAGE)/version
MK
# Both recipes build from a checkout whose modes are not the package's (a
# umask of 077, a checkout that marks files executable): an executable and
# a private file in the library, a private library directory, a private
# configuration.
SRC="$WORK_DIR/src"
mkdir -p "$SRC"
cp -R "$BUILD_SCRIPT" "$ROOT_DIR/prokop" "$SRC/"
chmod 0755 "$SRC/prokop/files/usr/lib/core/constants.uc"
chmod 0600 "$SRC/prokop/files/usr/lib/service/package.uc"
chmod 0700 "$SRC/prokop/files/usr/lib/core" "$SRC/prokop/files/usr/lib"
chmod 0600 "$SRC/prokop/files/etc/config/prokop"
sdk_stage() {
  local version="$1" out="$2"
  (umask 077 && make -s -C "$SRC/prokop" -f "$WORK_DIR/sdk/stage.mk" TOPDIR="$WORK_DIR/sdk" \
    STAGE="$out" PROKOP_PACKAGE_VERSION="$version" stage) >"$WORK_DIR/make.log" 2>&1
}
sdk_stage 1.2.3 "$WORK_DIR/sdk-stage" || fail "make could not build the SDK recipe: $(cat "$WORK_DIR/make.log")"
(umask 077 && build_recipe_root "$SRC/build.sh" 1.2.3 "$WORK_DIR/build-root") ||
  fail "could not build build.sh's backend root"
build_recipe_scripts "$BUILD_SCRIPT" "$WORK_DIR/build-scripts" || fail "could not write build.sh's package scripts"
SDK="$WORK_DIR/sdk-stage"
BUILD="$WORK_DIR/build-scripts"

# ---- files, modes, contents ------------------------------------------------

listing() {
  (cd "$1" && find . -mindepth 1 -printf '%y %m %p\n' | LC_ALL=C sort)
}
listing "$WORK_DIR/build-root" >"$WORK_DIR/build.list"
listing "$SDK/root" >"$WORK_DIR/sdk.list"
diff -u "$WORK_DIR/build.list" "$WORK_DIR/sdk.list" >"$WORK_DIR/list.diff" ||
  fail "the SDK package's files or modes differ from build.sh's: $(cat "$WORK_DIR/list.diff")"
diff -r "$WORK_DIR/build-root" "$SDK/root" >"$WORK_DIR/content.diff" ||
  fail "the SDK package's file contents differ from build.sh's: $(head -n 20 "$WORK_DIR/content.diff")"
# The configuration holds secrets (the Clash API secret, subscription URLs,
# WAN credentials): only root reads it. Its packaged defaults hold none.
grep -Fxq 'f 600 ./etc/config/prokop' "$WORK_DIR/build.list" ||
  fail "the packages install /etc/config/prokop $(grep -F ' ./etc/config/prokop' "$WORK_DIR/build.list"), not 0600"
grep -Fxq 'f 644 ./usr/share/prokop/defaults/prokop' "$WORK_DIR/build.list" ||
  fail "the packages install the default configuration $(grep -F ' ./usr/share/prokop/defaults/prokop' "$WORK_DIR/build.list"), not 0644"
grep -Fq '1.2.3' "$SDK/root/usr/lib/prokop/core/constants.uc" ||
  fail "the SDK package does not carry its version in core/constants.uc"
cmp -s "$BUILD/ipk/conffiles" "$SDK/control/conffiles" ||
  fail "the SDK package's conffiles differ: $(cat "$SDK/control/conffiles")"

# x.y.z only, as build.sh, the updater and the installer (UPD-8).
for version in 1.2 1.2.3-4 1.2.3-r4 1.2.3-; do
  if sdk_stage "$version" "$WORK_DIR/sdk-invalid"; then
    fail "the SDK recipe must refuse the release version $version"
  fi
done
# The LuCI app of the same SDK build takes the same versions.
mkdir -p "$WORK_DIR/sdk/feeds/luci"
: >"$WORK_DIR/sdk/feeds/luci/luci.mk"
cat >"$WORK_DIR/sdk/version.mk" <<'MK'
include Makefile
.PHONY: version
version:
	printf '%s|%s|%s\n' '$(PKG_VERSION)' '$(PKG_RELEASE)' '$(PROKOP_COMPILED_VERSION)'
MK
luci_version() {
  make -s -C "$ROOT_DIR/luci-app-prokop" -f "$WORK_DIR/sdk/version.mk" TOPDIR="$WORK_DIR/sdk" \
    PROKOP_PACKAGE_VERSION="$1" version 2>"$WORK_DIR/make.log"
}
actual="$(luci_version 1.2.3)" || fail "the LuCI app's recipe refused 1.2.3: $(cat "$WORK_DIR/make.log")"
[ "$actual" = "1.2.3||1.2.3" ] || fail "the LuCI app's recipe reads 1.2.3 as $actual, not 1.2.3||1.2.3"
for version in 1.2.3-4 1.2.3-r4; do
  if luci_version "$version" >/dev/null; then
    fail "the LuCI app's recipe must refuse the release version $version"
  fi
done

# ---- package scripts --------------------------------------------------------

# The install and upgrade script is build.sh's own text.
cmp -s "$BUILD/ipk/postinst" "$SDK/control/postinst-pkg" ||
  fail "the SDK postinst differs from build.sh's: $(diff "$BUILD/ipk/postinst" "$SDK/control/postinst-pkg" | tr '\n' ' ')"

# The installed /usr/bin/prokop records what the package scripts ask; the
# rest of the package is not there.
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/prokop" <<'SH'
#!/bin/sh
printf 'prokop %s\n' "$*" >>"$EVENTS"
exit "${PROKOP_PRERM_STATUS:-0}"
SH
cat >"$WORK_DIR/bin/mirror-migration" <<'SH'
#!/bin/sh
printf 'mirror-migration\n' >>"$EVENTS"
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf 'logger %s\n' "$*" >>"$EVENTS"
SH
chmod 0755 "$WORK_DIR/bin/"*
local_paths() {
  sed -e "s#/usr/share/prokop/mirror-migration.sh#$WORK_DIR/bin/mirror-migration#g" \
    -e "s#/usr/bin/prokop#$WORK_DIR/bin/prokop#g" \
    -e "s#/usr/lib/prokop#$WORK_DIR/no-lib#g" "$1" >"$2"
  chmod 0755 "$2"
}
local_paths "$BUILD/ipk/prerm" "$WORK_DIR/ipk-prerm"
local_paths "$BUILD/apk/backend-pre-upgrade.sh" "$WORK_DIR/apk-pre-upgrade"
local_paths "$BUILD/apk/backend-pre-deinstall.sh" "$WORK_DIR/apk-pre-deinstall"
local_paths "$SDK/control/prerm-pkg" "$WORK_DIR/sdk-prerm-pkg"
local_paths "$SDK/control/preinst" "$WORK_DIR/sdk-preinst"
# package-pack.mk (25.12): an apk's pre-upgrade is "export PKG_UPGRADE=1"
# and Package/preinst without its #! lines; its pre-install is preinst;
# its pre-deinstall runs default_prerm and then Package/prerm.
{
  printf '#!/bin/sh\nexport PKG_UPGRADE=1\n'
  sed '/^\s*#!/d' "$WORK_DIR/sdk-preinst"
} >"$WORK_DIR/sdk-pre-upgrade"
chmod 0755 "$WORK_DIR/sdk-pre-upgrade"

called() {
  : >"$EVENTS"
  local status=0
  PATH="$WORK_DIR/bin:$PATH" "$@" >/dev/null 2>&1 || status=$?
  printf '%s|%s\n' "$status" "$(tr '\n' ';' <"$EVENTS")"
}
# opkg runs the installed "prerm upgrade <new>" with PKG_UPGRADE=1 or
# "prerm remove" with PKG_UPGRADE=0, and sets PKG_ROOT (libopkg
# pkg_run_script); the ipk's prerm sources prerm-pkg from default_prerm
# with its own $0 first. A prerm without an action (service/package.uc
# remember_upgrade_state) is an upgrade under PKG_UPGRADE=1, as
# default_prerm takes it: both recipes pass no action on, and
# package_prerm decides by the service's state; a removal would leave a
# Prokop that ran before the upgrade down and lift its kill-switch. Under
# PKG_UPGRADE=0 it is a removal: package_prerm must lift the kill-switch,
# whose watcher default_prerm stops right after, end the explicit start and
# hand no restart to a later install. opkg runs the incoming "preinst
# upgrade <old>" with PKG_UPGRADE=1, which must not stop Prokop a second
# time.
for run in "1|upgrade 1.2.4|upgrade 1.2.4" "0|remove|remove" "1||" "0||remove"; do
  IFS='|' read -r pkg_upgrade args action <<<"$run"
  # shellcheck disable=SC2086 # the package manager's arguments
  expected="$(called env PKG_ROOT=/ PKG_UPGRADE="$pkg_upgrade" ucode "$WORK_DIR/ipk-prerm" $args)"
  [ "$expected" = "0|prokop package_prerm${action:+ $action};" ] ||
    fail "build.sh's prerm ${args:-without an action} (PKG_UPGRADE=$pkg_upgrade): $expected"
  # shellcheck disable=SC2016,SC2086 # expanded by sh; the package manager's arguments
  sdk="$(called env PKG_ROOT=/ PKG_UPGRADE="$pkg_upgrade" sh -c '. "$1"' /usr/lib/opkg/info/prokop.prerm "$WORK_DIR/sdk-prerm-pkg" $args)"
  [ "$sdk" = "$expected" ] ||
    fail "the SDK prerm ${args:-without an action} (PKG_UPGRADE=$pkg_upgrade) does not do what build.sh's does: $sdk (build.sh: $expected)"
done
# The SDK text is also apk's pre-deinstall, which only ever removes: also
# from an apk that sets no APK_SCRIPT, and whatever PKG_UPGRADE or PKG_ROOT
# it inherits. Only opkg's upgrade passes no action on.
for env_run in "PKG_UPGRADE=1" "APK_SCRIPT=pre-deinstall PKG_ROOT=/ PKG_UPGRADE=1"; do
  # shellcheck disable=SC2016,SC2086 # expanded by sh; the environment of the case
  sdk="$(called env $env_run sh -c '. "$1"' /usr/lib/apk/scripts/prokop.pre-deinstall "$WORK_DIR/sdk-prerm-pkg")"
  [ "$sdk" = "0|prokop package_prerm remove;" ] ||
    fail "the SDK prerm without an action outside opkg ($env_run) must remove the package: $sdk"
done
sdk="$(called env PKG_UPGRADE=1 sh "$WORK_DIR/sdk-preinst" upgrade 1.2.3)"
[ "$sdk" = "0|" ] || fail "the SDK preinst of an opkg upgrade must leave the stop to prerm: $sdk"
sdk="$(called sh "$WORK_DIR/sdk-preinst" install)"
[ "$sdk" = "0|" ] || fail "the SDK preinst of an install must do nothing: $sdk"
# apk runs the incoming "pre-upgrade <new> <old>", whose failure keeps the
# installed release (UC-197), and "pre-deinstall <old>" for a removal.
for status in 0 3; do
  expected="$(PROKOP_PRERM_STATUS=$status called ucode "$WORK_DIR/apk-pre-upgrade" 1.2.4 1.2.3)"
  [ "$expected" = "$status|prokop package_prerm upgrade 1.2.4;" ] || fail "build.sh's pre-upgrade: $expected"
  sdk="$(PROKOP_PRERM_STATUS=$status called env APK_SCRIPT=pre-upgrade sh "$WORK_DIR/sdk-pre-upgrade" 1.2.4 1.2.3)"
  [ "$sdk" = "$expected" ] || fail "the SDK apk pre-upgrade does not do what build.sh's does: $sdk"
done
sdk="$(called env APK_SCRIPT=pre-install sh "$WORK_DIR/sdk-preinst" 1.2.4)"
[ "$sdk" = "0|" ] || fail "the SDK apk pre-install must do nothing: $sdk"
expected="$(called ucode "$WORK_DIR/apk-pre-deinstall" 1.2.3)"
[ "$expected" = "0|prokop package_prerm remove;" ] || fail "build.sh's pre-deinstall: $expected"
sdk="$(called env APK_SCRIPT=pre-deinstall sh "$WORK_DIR/sdk-prerm-pkg" 1.2.3)"
[ "$sdk" = "$expected" ] || fail "the SDK apk pre-deinstall does not do what build.sh's does: $sdk"

# ---- OpenWrt's default package scripts around them ---------------------------

# The SDK package's init scripts in an installed root. /etc/init.d/prokop
# is the real one, its rc.d moved into that root, behind an rc.common
# stand-in that records what reaches service/initd.uc; the others record
# their actions.
INSTALLED="$WORK_DIR/installed"
RC_D="$INSTALLED/etc/rc.d"
mkdir -p "$INSTALLED/etc/init.d" "$INSTALLED/real" "$INSTALLED/opkg-info" "$RC_D"
sed "s#/etc/rc\\.d#$RC_D#g" "$SDK/root/etc/init.d/prokop" >"$INSTALLED/real/prokop"
grep -Fq "$RC_D" "$INSTALLED/real/prokop" || fail "could not move the init script's rc.d into the installed root"
cat >"$WORK_DIR/rc.common" <<'SH'
#!/bin/sh
# OpenWrt's /etc/rc.common as far as enable, disable and a procd script's
# start and stop go, with rc.d in the installed root ($RC_D); procd's
# service registration is left out.
initscript=$1
action=${2:-help}
shift 2
enable() {
	err=1
	name="$(basename "${initscript}")"
	[ "$START" ] && ln -sf "../init.d/$name" "$IPKG_INSTROOT$RC_D/S${START}${name##S[0-9][0-9]}" && err=0
	[ "$STOP" ] && ln -sf "../init.d/$name" "$IPKG_INSTROOT$RC_D/K${STOP}${name##K[0-9][0-9]}" && err=0
	return $err
}
disable() {
	name="$(basename "${initscript}")"
	rm -f "$IPKG_INSTROOT$RC_D"/S??$name
	rm -f "$IPKG_INSTROOT$RC_D"/K??$name
}
. "$initscript"
initd_ucode() {
	printf 'initd %s\n' "$*" >>"$EVENTS"
	# No sing-box of another program blocks a restart.
	[ "$1" != restart-blocked ]
}
start() {
	start_service "$@"
	service_started "$@"
}
stop() {
	stop_service "$@"
}
"$action" "$@"
SH
cat >"$INSTALLED/etc/init.d/prokop" <<SH
#!/bin/sh
exec sh "$WORK_DIR/rc.common" "$INSTALLED/real/prokop" "\$@"
SH
for name in prokop-killswitch prokop-torrserver-direct; do
  # shellcheck disable=SC2016 # expanded by the stub when it runs
  printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"$EVENTS"\n' "$name" >"$INSTALLED/etc/init.d/$name"
done
chmod 0755 "$INSTALLED/etc/init.d/"*
# The package's init scripts, as the package manager lists its files.
(cd "$SDK/root" && find . -path './etc/init.d/*' | sed 's#^\.##' | LC_ALL=C sort) >"$INSTALLED/files.list"
grep -Fxq /etc/init.d/prokop-torrserver-direct "$INSTALLED/files.list" ||
  fail "the SDK package must ship /etc/init.d/prokop-torrserver-direct"
local_paths "$SDK/control/postinst-pkg" "$INSTALLED/postinst-pkg"

# lib/functions.sh default_postinst and default_prerm for an installed
# root: an ipk's own script (opkg's info directory) runs first, in a
# subshell with the package manager's arguments; then every init script
# of the package is enabled on a first install and started, or disabled
# unless the package is upgraded and stopped.
cat >"$WORK_DIR/functions.sh" <<'SH'
default_postinst() {
	local ret=0
	if [ -f "$OPKG_INFO/prokop.postinst-pkg" ]; then
		( . "$OPKG_INFO/prokop.postinst-pkg" )
		ret=$?
	fi
	for i in $(grep -s "^/etc/init.d/" "$INSTALLED/files.list"); do
		if [ "$PKG_UPGRADE" != "1" ]; then
			"$INSTALLED$i" enable
		fi
		"$INSTALLED$i" start
	done
	return $ret
}
default_prerm() {
	local ret=0
	if [ -f "$OPKG_INFO/prokop.prerm-pkg" ]; then
		( . "$OPKG_INFO/prokop.prerm-pkg" )
		ret=$?
	fi
	for i in $(grep -s "^/etc/init.d/" "$INSTALLED/files.list"); do
		if [ "$PKG_UPGRADE" != "1" ]; then
			"$INSTALLED$i" disable
		fi
		"$INSTALLED$i" stop
	done
	return $ret
}
add_group_and_user() {
	return 0
}
SH
cp "$INSTALLED/postinst-pkg" "$INSTALLED/opkg-info/prokop.postinst-pkg"
cp "$WORK_DIR/sdk-prerm-pkg" "$INSTALLED/opkg-info/prokop.prerm-pkg"
export INSTALLED RC_D
# The ipk's postinst and prerm (package-pack.mk); the apk's post-install,
# whose own script follows default_postinst (25.12), its post-upgrade,
# which exports PKG_UPGRADE=1 first, and its pre-deinstall, whose own
# script follows default_prerm.
cat >"$WORK_DIR/ipk-postinst" <<SH
#!/bin/sh
. "$WORK_DIR/functions.sh"
default_postinst \$0 \$@
SH
cat >"$WORK_DIR/ipk-prerm-sdk" <<SH
#!/bin/sh
. "$WORK_DIR/functions.sh"
default_prerm \$0 \$@
SH
{
  printf '#!/bin/sh\n. "%s/functions.sh"\nexport root=""\nexport pkgname="prokop"\n' "$WORK_DIR"
  printf 'add_group_and_user\ndefault_postinst\n'
  sed '/^\s*#!/d' "$INSTALLED/postinst-pkg"
} >"$WORK_DIR/apk-post-install"
{
  printf '#!/bin/sh\n. "%s/functions.sh"\nexport root=""\nexport pkgname="prokop"\n' "$WORK_DIR"
  printf 'default_prerm\n'
  sed '/^\s*#!/d' "$WORK_DIR/sdk-prerm-pkg"
} >"$WORK_DIR/apk-pre-deinstall-sdk"
chmod 0755 "$WORK_DIR/ipk-postinst" "$WORK_DIR/ipk-prerm-sdk" "$WORK_DIR/apk-post-install" \
  "$WORK_DIR/apk-pre-deinstall-sdk"

# Runs a package script of the SDK package as the package manager does.
package_script() {
  case "$1" in
    "ipk install") set -- env OPKG_INFO="$INSTALLED/opkg-info" PKG_ROOT=/ PKG_UPGRADE=0 sh "$WORK_DIR/ipk-postinst" configure ;;
    "ipk upgrade") set -- env OPKG_INFO="$INSTALLED/opkg-info" PKG_ROOT=/ PKG_UPGRADE=1 sh "$WORK_DIR/ipk-postinst" configure ;;
    "ipk remove") set -- env OPKG_INFO="$INSTALLED/opkg-info" PKG_ROOT=/ PKG_UPGRADE=0 sh "$WORK_DIR/ipk-prerm-sdk" remove ;;
    "ipk remove without an action") set -- env OPKG_INFO="$INSTALLED/opkg-info" PKG_ROOT=/ PKG_UPGRADE=0 sh "$WORK_DIR/ipk-prerm-sdk" ;;
    "ipk prerm upgrade") set -- env OPKG_INFO="$INSTALLED/opkg-info" PKG_ROOT=/ PKG_UPGRADE=1 sh "$WORK_DIR/ipk-prerm-sdk" upgrade 1.2.4 ;;
    "ipk prerm without an action") set -- env OPKG_INFO="$INSTALLED/opkg-info" PKG_ROOT=/ PKG_UPGRADE=1 sh "$WORK_DIR/ipk-prerm-sdk" ;;
    "apk install") set -- env OPKG_INFO="$INSTALLED/none" APK_SCRIPT=post-install sh "$WORK_DIR/apk-post-install" 1.2.4 ;;
    "apk upgrade") set -- env OPKG_INFO="$INSTALLED/none" APK_SCRIPT=post-upgrade PKG_UPGRADE=1 sh "$WORK_DIR/apk-post-install" 1.2.4 1.2.3 ;;
    "apk remove") set -- env OPKG_INFO="$INSTALLED/none" APK_SCRIPT=pre-deinstall sh "$WORK_DIR/apk-pre-deinstall-sdk" 1.2.3 ;;
    *) fail "unknown package script $1" ;;
  esac
  PATH="$WORK_DIR/bin:$PATH" "$@" >/dev/null 2>&1 || true
}
# Prokop's autostart as the user left it: enabled from the UI or the
# command line, outside any package manager, or not.
set_autostart() {
  rm -f "${RC_D:?}"/*
  if [ "$1" = enabled ]; then
    PATH="$WORK_DIR/bin:$PATH" "$INSTALLED/etc/init.d/prokop" enable >/dev/null 2>&1 || true
    [ -L "$RC_D/S99prokop" ] || fail "could not enable Prokop for the test"
  fi
}
autostart_enabled() {
  [ -L "$RC_D/S99prokop" ]
}

for label in "ipk install" "ipk upgrade" "apk install" "apk upgrade"; do
  set_autostart disabled
  : >"$EVENTS"
  package_script "$label"
  grep -Fxq "prokop package_postinst" "$EVENTS" || fail "$label: the package's own script did not run"
  if grep -q '^initd start-service' "$EVENTS"; then
    fail "$label: OpenWrt's default package script started Prokop; only package_postinst decides that"
  fi
  if autostart_enabled; then
    fail "$label: OpenWrt's default package script enabled Prokop's autostart"
  fi
  grep -q '^prokop-killswitch start' "$EVENTS" || fail "$label: the default script did not reach the other init scripts"
done

# A removal and a new install of the package keep Prokop's autostart as it
# was: opkg install --force-reinstall (the in-app rollback of a failed
# upgrade, the usual manual repair) runs "prerm remove" and then installs
# the package again, as opkg remove and opkg install, or apk del and apk
# add, do. The default prerm disables every init script of the package,
# and no postinst enables Prokop again; build.sh's packages, which run no
# default script, keep the link.
for manager in ipk apk; do
  for autostart in enabled disabled; do
    set_autostart "$autostart"
    : >"$EVENTS"
    package_script "$manager remove"
    package_script "$manager install"
    grep -Fxq "prokop package_prerm remove" "$EVENTS" || fail "$manager reinstall: the package's own prerm did not run"
    grep -Fxq "prokop package_postinst" "$EVENTS" || fail "$manager reinstall: the package's own postinst did not run"
    grep -q '^prokop-killswitch disable' "$EVENTS" ||
      fail "$manager reinstall: the default prerm did not reach the other init scripts"
    if [ "$autostart" = enabled ] && ! autostart_enabled; then
      fail "$manager reinstall: OpenWrt's default package script disabled Prokop's autostart, and nothing enables it again"
    fi
    if [ "$autostart" = disabled ] && autostart_enabled; then
      fail "$manager reinstall: OpenWrt's default package script enabled Prokop's autostart"
    fi
    # package_prerm stops Prokop for the removal, as build.sh's prerm does,
    # and takes down what that stop left with an explicit stop of its own
    # (PROKOP_STOP_SOURCE=user). The default prerm's plain stop, after it on
    # opkg and before it on apk, would stop Prokop once more, as the user:
    # after the new install Prokop would show as stopped by the user where
    # build.sh's shows it not started.
    if grep -q '^initd stop-service' "$EVENTS"; then
      fail "$manager remove: OpenWrt's default prerm stopped Prokop, as the user"
    fi
  done
done
# An opkg removal whose prerm comes without an action (PKG_UPGRADE=0) is a
# removal, as default_prerm, which disables and stops every init script of
# the package around it, takes it.
set_autostart enabled
: >"$EVENTS"
package_script "ipk remove without an action"
grep -Fxq "prokop package_prerm remove" "$EVENTS" ||
  fail "ipk remove without an action: the package's own prerm must remove the package, as default_prerm does"
grep -q '^prokop-killswitch disable' "$EVENTS" ||
  fail "ipk remove without an action: the default prerm did not reach the other init scripts"
if grep -q '^initd stop-service' "$EVENTS"; then
  fail "ipk remove without an action: OpenWrt's default prerm stopped Prokop, as the user"
fi
autostart_enabled || fail "ipk remove without an action: OpenWrt's default package script disabled Prokop's autostart"

# An opkg upgrade stops Prokop once, as build.sh's packages do: package_prerm
# stops it for the upgrade (PROKOP_STOP_SOURCE=package), and the default
# prerm's plain stop that follows must not stop it again. That second stop
# would be the user's (service/initd.uc stop_request_source): it would end
# the explicit start and show a Prokop that package_postinst did not start
# again as stopped by the user, not as failed or not started, and its
# explicit stop would take down the interception that a refused stop for
# the upgrade keeps (UC-197).
for label in "ipk prerm upgrade" "ipk prerm without an action"; do
  set_autostart enabled
  : >"$EVENTS"
  package_script "$label"
  grep -Eq '^prokop package_prerm( upgrade 1\.2\.4)?$' "$EVENTS" || fail "$label: the package's own prerm did not run"
  grep -q '^prokop-killswitch stop' "$EVENTS" || fail "$label: the default prerm did not reach the other init scripts"
  if grep -q '^initd stop-service' "$EVENTS"; then
    fail "$label: OpenWrt's default prerm stopped Prokop a second time, as the user"
  fi
  autostart_enabled || fail "$label: OpenWrt's default prerm disabled Prokop's autostart on an upgrade"
done
# Every other stop goes through: package_prerm's own for an upgrade or a
# removal, its explicit stop after a failed or refused stop for a removal
# (UC-028), a component change's, and any stop outside a package manager.
initd_stopped() {
  : >"$EVENTS"
  PATH="$WORK_DIR/bin:$PATH" "$@" >/dev/null 2>&1 || true
  grep -q '^initd stop-service' "$EVENTS"
}
initd_stopped env PKG_ROOT=/ PKG_UPGRADE=1 PROKOP_STOP_SOURCE=package "$INSTALLED/etc/init.d/prokop" stop ||
  fail "package_prerm's stop for an opkg upgrade must stop Prokop"
initd_stopped env APK_SCRIPT=pre-upgrade PKG_UPGRADE=1 PROKOP_STOP_SOURCE=package "$INSTALLED/etc/init.d/prokop" stop ||
  fail "package_prerm's stop for an apk upgrade must stop Prokop"
initd_stopped env PKG_ROOT=/ PKG_UPGRADE=0 PROKOP_STOP_SOURCE=package "$INSTALLED/etc/init.d/prokop" stop ||
  fail "package_prerm's stop for an opkg removal must stop Prokop"
initd_stopped env APK_SCRIPT=pre-deinstall PROKOP_STOP_SOURCE=package "$INSTALLED/etc/init.d/prokop" stop ||
  fail "package_prerm's stop for an apk removal must stop Prokop"
initd_stopped env PKG_ROOT=/ PKG_UPGRADE=0 PROKOP_STOP_SOURCE=user "$INSTALLED/etc/init.d/prokop" stop ||
  fail "package_prerm's explicit stop for an opkg removal must stop Prokop"
initd_stopped env APK_SCRIPT=pre-deinstall PROKOP_STOP_SOURCE=user "$INSTALLED/etc/init.d/prokop" stop ||
  fail "package_prerm's explicit stop for an apk removal must stop Prokop"
# The plain stop of the default prerm of a removal stops nothing (above).
for env_run in "PKG_ROOT=/ PKG_UPGRADE=0" "PKG_ROOT=/" "APK_SCRIPT=pre-deinstall"; do
  # shellcheck disable=SC2086 # the environment of the case
  if initd_stopped env $env_run "$INSTALLED/etc/init.d/prokop" stop; then
    fail "the plain stop of OpenWrt's default prerm ($env_run) stopped Prokop"
  fi
done
initd_stopped env PKG_ROOT=/ PKG_UPGRADE=1 PROKOP_STOP_SOURCE=component "$INSTALLED/etc/init.d/prokop" stop ||
  fail "a component change's stop must stop Prokop"
initd_stopped "$INSTALLED/etc/init.d/prokop" stop ||
  fail "a stop outside a package manager must stop Prokop"
initd_stopped env PKG_UPGRADE=1 "$INSTALLED/etc/init.d/prokop" stop ||
  fail "a stop outside a package manager must stop Prokop, whatever PKG_UPGRADE says"
# A restart is never the default prerm's: its stop goes through also inside
# a package script of an upgrade.
for env_run in "PKG_ROOT=/ PKG_UPGRADE=1" "APK_SCRIPT=post-upgrade PKG_UPGRADE=1"; do
  # shellcheck disable=SC2086 # the environment of the case
  initd_stopped env $env_run "$INSTALLED/etc/init.d/prokop" restart ||
    fail "a restart inside a package script ($env_run) must stop Prokop before it starts it again"
  grep -q '^initd start-service' "$EVENTS" ||
    fail "a restart inside a package script ($env_run) must start Prokop again"
done

# Every other start, enable and disable stays as it was: Prokop's own start
# inside a package script (start-and-wait passes its request), a start with
# a reason (deferred, triggered), any start, enable or disable outside a
# package manager, and the enable and disable of an image build.
initd_started() {
  : >"$EVENTS"
  PATH="$WORK_DIR/bin:$PATH" "$@" >/dev/null 2>&1 || true
  grep -q '^initd start-service' "$EVENTS"
}
initd_started env PKG_ROOT=/ PROKOP_START_REQUEST=1.2.3 "$INSTALLED/etc/init.d/prokop" start ||
  fail "Prokop's own start inside a package script must start it"
initd_started env APK_SCRIPT=post-upgrade "$INSTALLED/etc/init.d/prokop" start deferred ||
  fail "a deferred start inside a package script must start Prokop"
initd_started "$INSTALLED/etc/init.d/prokop" start ||
  fail "a start outside a package manager must start Prokop"
set_autostart disabled
PATH="$WORK_DIR/bin:$PATH" "$INSTALLED/etc/init.d/prokop" enable >/dev/null 2>&1 || true
autostart_enabled || fail "an enable outside a package manager must enable Prokop"
: >"$EVENTS"
PATH="$WORK_DIR/bin:$PATH" "$INSTALLED/etc/init.d/prokop" disable >/dev/null 2>&1 || true
! autostart_enabled || fail "a disable outside a package manager must disable Prokop"
grep -Fxq 'initd cancel-scheduled-start-retry' "$EVENTS" ||
  fail "a disable outside a package manager must cancel the retry of a failed start"
IMAGE_RC_D="$WORK_DIR/image$RC_D"
mkdir -p "$IMAGE_RC_D"
PATH="$WORK_DIR/bin:$PATH" env PKG_ROOT="$WORK_DIR/image" IPKG_INSTROOT="$WORK_DIR/image" \
  "$INSTALLED/etc/init.d/prokop" enable >/dev/null 2>&1 || true
[ -L "$IMAGE_RC_D/S99prokop" ] || fail "an image build must enable Prokop as every init script"
PATH="$WORK_DIR/bin:$PATH" env PKG_ROOT="$WORK_DIR/image" IPKG_INSTROOT="$WORK_DIR/image" \
  "$INSTALLED/etc/init.d/prokop" disable >/dev/null 2>&1 || true
[ ! -L "$IMAGE_RC_D/S99prokop" ] || fail "an image build must disable Prokop as every init script"

printf 'package recipe parity checks passed\n'
