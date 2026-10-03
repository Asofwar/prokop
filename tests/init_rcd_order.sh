#!/usr/bin/env bash
set -euo pipefail

# The init scripts of the prokop package start and stop where their START and
# STOP values mean them to (UC-161).
#
# OpenWrt names the links in /etc/rc.d after the values (S<START><name>,
# K<STOP><name>) and runs them in the order of the names: rcS loops over
# /etc/rc.d/S* at boot and /etc/rc.d/K* at shutdown, so the values compare
# as text, and rc.common's disable removes only S??<name> and K??<name>.
# prokop-torrserver-direct had START=100 and STOP=9: its S100 link sorted
# before S10boot, it started first at boot instead of after Prokop, its K9
# link sorted after K90umount, and disable never removed either link.
#
# The init scripts run behind a copy of OpenWrt 24.10's rc.common enable,
# disable and enabled, against an rc.d with the links of an ordinary system.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_DIR="$ROOT_DIR/prokop/files/etc/init.d"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

INSTROOT="$WORK_DIR/root"
RC_D="$INSTROOT/etc/rc.d"
mkdir -p "$RC_D" "$INSTROOT/etc/init.d"

# rc.common as far as the links go: enable, disable and enabled as in
# OpenWrt 24.10 (package/base-files/files/etc/rc.common).
cat >"$WORK_DIR/rc.common" <<'SH'
initscript=$1
action=${2:-help}
shift 2

disable() {
	name="$(basename "${initscript}")"
	rm -f "$IPKG_INSTROOT"/etc/rc.d/S??$name
	rm -f "$IPKG_INSTROOT"/etc/rc.d/K??$name
}

enable() {
	err=1
	name="$(basename "${initscript}")"
	[ "$START" ] && \
		ln -sf "../init.d/$name" "$IPKG_INSTROOT/etc/rc.d/S${START}${name##S[0-9][0-9]}" && \
		err=0
	[ "$STOP" ] && \
		ln -sf "../init.d/$name" "$IPKG_INSTROOT/etc/rc.d/K${STOP}${name##K[0-9][0-9]}" && \
		err=0
	return $err
}

enabled() {
	name="$(basename "${initscript}")"
	name="${name##[SK][0-9][0-9]}"
	{
		[ -z "${START:-}" ] || [ -L "$IPKG_INSTROOT/etc/rc.d/S${START}$name" ]
	} && {
		[ -z "${STOP:-}" ] || [ -L "$IPKG_INSTROOT/etc/rc.d/K${STOP}$name" ]
	}
}

. "$initscript"
$action "$@"
SH

rc() { # rc <init script name> <action>
  IPKG_INSTROOT="$INSTROOT" sh "$WORK_DIR/rc.common" "$INSTROOT/etc/init.d/$1" "$2"
}

# 1. Every value is two digits: rc.d compares them as text.
scripts=0
for script in "$INIT_DIR"/*; do
  name="${script##*/}"
  scripts=$((scripts + 1))
  for key in START STOP; do
    value="$(sed -n "s/^$key=//p" "$script")"
    [ -z "$value" ] || printf '%s\n' "$value" | grep -Eqx '[0-9]{2}' ||
      fail "$name: $key=$value is not two digits; rc.d orders the links by their names"
  done
  cp "$script" "$INSTROOT/etc/init.d/$name"
done
[ "$scripts" -ge 3 ] || fail "could not read the init scripts of the prokop package"

# The links of an ordinary OpenWrt system.
for link in S00sysfixtime S10boot S11sysctl S12log S19dnsmasq S19firewall S20network \
  S50cron S95done S99urandom_seed K10gpio_switch K50dropbear K85odhcpd K89log \
  K90network K90umount K98boot; do
  ln -s "../init.d/${link#???}" "$RC_D/$link"
done

for name in prokop prokop-killswitch prokop-torrserver-direct; do
  rc "$name" enable || fail "$name: enable failed"
  rc "$name" enabled || fail "$name: enabled does not see the links enable made"
done

# rcS: for i in /etc/rc.d/S*; ... and the same with K* at shutdown.
order() {
  local link
  for link in "$RC_D"/"$1"*; do printf '%s\n' "${link##*/}"; done
}
position() { # position <S|K> <name>: the line of the link of <name>
  order "$1" | grep -nE "^$1[0-9]+$2\$" | cut -d: -f1
}
boot="$(order S)"
shutdown="$(order K)"

# 2. TorrServer Direct starts after Prokop, at the end of the boot.
torrserver_start="$(position S prokop-torrserver-direct)"
[ -n "$torrserver_start" ] || fail "no start link for prokop-torrserver-direct: $boot"
[ "$torrserver_start" -gt "$(position S prokop)" ] ||
  fail "prokop-torrserver-direct starts before Prokop:
$boot"
if [ "$torrserver_start" -lt "$(position S boot)" ] || [ "$torrserver_start" -lt "$(position S network)" ]; then
  fail "prokop-torrserver-direct starts before the system is up:
$boot"
fi

# 3. It stops early at shutdown, while the network is still up.
torrserver_stop="$(position K prokop-torrserver-direct)"
[ -n "$torrserver_stop" ] || fail "no stop link for prokop-torrserver-direct: $shutdown"
if [ "$torrserver_stop" -gt "$(position K network)" ] || [ "$torrserver_stop" -gt "$(position K umount)" ]; then
  fail "prokop-torrserver-direct stops after the network or the filesystems:
$shutdown"
fi

# 4. disable takes away every link that enable made.
for name in prokop prokop-killswitch prokop-torrserver-direct; do
  rc "$name" disable
  ! rc "$name" enabled || fail "$name: still enabled after disable"
  if order S | grep -qE "^S[0-9]+$name\$" || order K | grep -qE "^K[0-9]+$name\$"; then
    fail "$name: disable left links in rc.d:
$(ls "$RC_D")"
  fi
done

printf 'init script rc.d order checks passed\n'
