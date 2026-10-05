#!/usr/bin/env bash
set -euo pipefail

# The prokop package ships two init scripts besides the kill-switch:
# prokop and prokop-torrserver-direct. A package change handles both (UC-083).
#
# Before: the package's prerm stopped only Prokop. A removal left the
# TorrServer Direct worker running from the loaded script, with its nft table
# that marks TorrServer's traffic, and the rc.d links of both services behind
# (S99prokop, S100prokop-torrserver-direct, K9prokop-torrserver-direct). An
# upgrade kept the worker of the previous release running until a reboot.
#
# Now a removal stops TorrServer Direct, which removes its nft table. It
# keeps the rc.d links of both services: opkg's install --force-reinstall
# (the in-app rollback of a failed upgrade, the usual manual repair) runs the
# installed package's "prerm remove" before the package goes back on, and the
# postinst of no release enables Prokop again. Full uninstall removes the
# links (tests/full_uninstall_runtime_leftovers.sh). An upgrade or a reinstall
# restarts TorrServer Direct on the new code when it is switched on and
# enabled. The links of releases with START=100 and STOP=9 (UC-161), which
# rc.common's disable never removed and enabled no longer sees, are replaced
# with the current ones, or only removed when TorrServer Direct is switched
# off.
#
# The real service/package.uc runs against init scripts that record what they
# are asked to do and keep their rc.d links as rc.common does.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
PACKAGE_UC="$LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  printf '  rc.d: %s\n' "$(find "$RC_D" -mindepth 1 -printf '%f ')" >&2
  exit 1
}

RC_D="$WORK_DIR/rc.d"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$RC_D" "$WORK_DIR/component-update-checks"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS RC_D
export PROKOP_LIB="$LIB"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_CONFIG_PATH="$WORK_DIR/config-prokop"
export PROKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-prokop"
export PROKOP_INIT="$WORK_DIR/prokop-init"
export PROKOP_TORRSERVER_DIRECT_INIT="$WORK_DIR/torrserver-init"
export PROKOP_RC_D_DIR="$RC_D"
export PROKOP_BIN="$WORK_DIR/bin/prokop"
export PROKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc"
export PROKOP_KILLSWITCH_UC="$WORK_DIR/missing-killswitch.uc"
export PROKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init"
export PROKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box"
export PROKOP_SING_BOX_CRONET="$WORK_DIR/missing-libcronet.so"
export PROKOP_RT_TABLES="$WORK_DIR/rt_tables"
export PROKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
export PROKOP_LEGACY_GUARD_ROOT="$WORK_DIR/legacy-guard"
export PROKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK_DIR/component-update-checks"
export PROKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK_DIR/component-update-check.timestamp"
export PROKOP_CRONTAB_FILE="$WORK_DIR/crontab"
export KILLSWITCH_NFT_POLICY="$WORK_DIR/killswitch-policy.nft"
printf "config settings 'settings'\n" >"$PROKOP_CONFIG_PATH"
cp "$PROKOP_CONFIG_PATH" "$PROKOP_DEFAULT_CONFIG_PATH"

# An init script as rc.common runs it: enable and disable keep the links of
# its START and STOP (rc.common's disable removes only S?? and K??), and
# enabled looks for exactly those. Every call is recorded.
init_script() { # init_script <path> <name> <START> [STOP]
  cat >"$1" <<SH
#!/bin/sh
name=$2
START=$3
STOP=${4:-}
SH
  cat >>"$1" <<'SH'
printf '%s %s\n' "$name" "$1" >>"$EVENTS"
case "$1" in
  status) exit 1 ;;
  enable)
    ln -sf "../init.d/$name" "$RC_D/S$START$name"
    [ -z "$STOP" ] || ln -sf "../init.d/$name" "$RC_D/K$STOP$name"
    ;;
  disable) rm -f "$RC_D"/S??"$name" "$RC_D"/K??"$name" ;;
  enabled)
    [ -L "$RC_D/S$START$name" ] || exit 1
    [ -z "$STOP" ] || [ -L "$RC_D/K$STOP$name" ]
    ;;
esac
exit 0
SH
  chmod +x "$1"
}
init_script "$PROKOP_INIT" prokop 99
init_script "$PROKOP_TORRSERVER_DIRECT_INIT" prokop-torrserver-direct 99 10
printf '#!/bin/sh\nexit 0\n' >"$PROKOP_BIN"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
# Nothing is left of Prokop's interception after its stop.
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
chmod +x "$PROKOP_BIN" "$WORK_DIR/bin/"*

reset_case() { # reset_case <torrserver_direct_enabled>
  : >"$EVENTS"
  rm -f "$RC_D"/* "$PROKOP_PACKAGE_UPGRADE_STATE"
  printf '100 main\n105 prokop\n' >"$PROKOP_RT_TABLES"
  printf 'prokop.settings=settings\nprokop.settings.dont_touch_dhcp=1\nprokop.settings.torrserver_direct_enabled=%s\n' \
    "$1" >"$PROKOP_UCI_STATE_FILE"
}
link() { ln -sf "../init.d/${1#[SK][0-9][0-9]}" "$RC_D/$1"; }
legacy_links() {
  ln -sf ../init.d/prokop-torrserver-direct "$RC_D/S100prokop-torrserver-direct"
  ln -sf ../init.d/prokop-torrserver-direct "$RC_D/K9prokop-torrserver-direct"
}
links_of() { find "$RC_D" -mindepth 1 -name "[SK]*$1" -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }
called() { grep -Fqx "$1" "$EVENTS"; }
prerm() { ucode -L "$LIB" "$PACKAGE_UC" prerm "$@" >>"$EVENTS" 2>&1 || true; }
postinst() { ucode -L "$LIB" "$PACKAGE_UC" postinst >>"$EVENTS" 2>&1 || fail "postinst failed"; }

# 1. A removal stops TorrServer Direct and keeps the rc.d links of both
#    services, as a reinstall needs them.
reset_case 1
link S99prokop
link S99prokop-torrserver-direct
link K10prokop-torrserver-direct
prerm remove
called 'prokop-torrserver-direct stop' || fail "a removal did not stop TorrServer Direct"
! grep -Eq '^(prokop|prokop-torrserver-direct) disable$' "$EVENTS" ||
  fail "a removal disabled a service, which a reinstall does not enable again"
if [ "$(links_of prokop)" != 'S99prokop ' ] ||
  [ "$(links_of prokop-torrserver-direct)" != 'K10prokop-torrserver-direct S99prokop-torrserver-direct ' ]; then
  fail "a removal changed the rc.d links: $(links_of prokop)$(links_of prokop-torrserver-direct)"
fi

# 1b. opkg install --force-reinstall: the installed package's "prerm remove",
#     then the postinst of the package that goes back on. Prokop stays
#     enabled at boot, and TorrServer Direct, switched on, stays enabled and
#     runs again on the code that went on.
: >"$EVENTS"
postinst
# An autostart of an older release gets its shutdown hook (LC-9).
[ "$(links_of prokop)" = 'K01prokop S99prokop ' ] || fail "a reinstall lost Prokop's autostart: $(links_of prokop)"
[ "$(links_of prokop-torrserver-direct)" = 'K10prokop-torrserver-direct S99prokop-torrserver-direct ' ] ||
  fail "a reinstall lost the rc.d links of TorrServer Direct: $(links_of prokop-torrserver-direct)"
grep -Eq '^prokop-torrserver-direct (restart|start)$' "$EVENTS" ||
  fail "a reinstall left TorrServer Direct stopped although it is switched on"

# 2. An upgrade keeps both services enabled and TorrServer Direct running
#    until postinst.
reset_case 1
link S99prokop
link S99prokop-torrserver-direct
link K10prokop-torrserver-direct
prerm upgrade 1.0.40
! grep -Eq '^(prokop-torrserver-direct (disable|stop)|prokop disable)$' "$EVENTS" ||
  fail "an upgrade stopped TorrServer Direct or disabled a service before postinst"
[ "$(links_of prokop-torrserver-direct)" = 'K10prokop-torrserver-direct S99prokop-torrserver-direct ' ] ||
  fail "an upgrade changed the rc.d links of TorrServer Direct: $(links_of prokop-torrserver-direct)"

# 3. postinst restarts TorrServer Direct on the new code when it is on.
: >"$EVENTS"
postinst
called 'prokop-torrserver-direct restart' || fail "postinst did not restart TorrServer Direct after the upgrade"
! called 'prokop-torrserver-direct enable' || fail "postinst made the links of an enabled TorrServer Direct again"

# 4. Switched off, or not enabled at boot: postinst leaves it alone.
reset_case 0
link S99prokop-torrserver-direct
link K10prokop-torrserver-direct
postinst
! grep -Eq '^prokop-torrserver-direct (restart|start|enable)$' "$EVENTS" ||
  fail "postinst started TorrServer Direct although it is switched off"
reset_case 1
postinst
! grep -Eq '^prokop-torrserver-direct (restart|start|enable)$' "$EVENTS" ||
  fail "postinst started TorrServer Direct although it is not enabled at boot"
[ -z "$(links_of prokop)" ] || fail "postinst made links for a Prokop without autostart: $(links_of prokop)"

# 5. Links of a release with START=100 and STOP=9 become the current ones
#    (UC-161), and TorrServer Direct restarts on the new code.
reset_case 1
legacy_links
postinst
[ "$(links_of prokop-torrserver-direct)" = 'K10prokop-torrserver-direct S99prokop-torrserver-direct ' ] ||
  fail "postinst did not replace the links of an older release: $(links_of prokop-torrserver-direct)"
called 'prokop-torrserver-direct restart' || fail "postinst did not restart TorrServer Direct enabled by an older release"

# 6. ... and only go when TorrServer Direct is switched off: the disable of an
#    older release never removed them.
reset_case 0
legacy_links
postinst
[ -z "$(links_of prokop-torrserver-direct)" ] ||
  fail "postinst kept or remade the links of a switched-off TorrServer Direct: $(links_of prokop-torrserver-direct)"
! grep -Eq '^prokop-torrserver-direct (restart|start|enable)$' "$EVENTS" ||
  fail "postinst started a switched-off TorrServer Direct"

printf 'package TorrServer Direct checks passed\n'
