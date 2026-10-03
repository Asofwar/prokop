#!/usr/bin/env bash
# Full uninstall detaches the kill-switch block list from dnsmasq without
# committing, dropping or staging twice what someone else staged for dhcp
# (S5 remainder).
#
# Before: when killswitch_disable had not detached the block list, the
# removal ran `uci delete dhcp.@dnsmasq[0].serversfile` and `uci commit
# dhcp`. libuci reads the changes staged in /tmp/.uci (LuCI before Save &
# Apply) whatever save directory -t names, so that commit also wrote
# someone else's staged change into /etc/config/dhcp. With a save directory
# of its own it left the change staged as well: a later Save & Apply applied
# it a second time (a list entry twice), and Revert no longer undid it.
#
# Now the option is deleted on a copy of dhcp under a package name nobody
# stages for, and the copy replaces dhcp under the lock a uci commit takes,
# only while dhcp still holds what was copied. The staged change stays
# staged, and only staged.
#
# The changes are staged in uci's real default directory /tmp/.uci, so the
# test runs in a user and mount namespace of its own with a private /tmp,
# never the host's. It needs the OpenWrt uci CLI (the test shim does not
# resolve @dnsmasq[0]); tests/killswitch_owner_package.sh checks the calls
# without it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/prokop/files/usr/lib/full-uninstall.sh"
NAMESPACE=(unshare --user --map-root-user --mount --propagation private)

namespaces() { printf '%s %s' "$(readlink /proc/self/ns/user)" "$(readlink /proc/self/ns/mnt)"; }

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: full_uninstall_dhcp_detach: %s\n' "$1"
    exit 0
  }
  command -v uci >/dev/null 2>&1 || skip 'the OpenWrt uci CLI is not on PATH'
  command -v unshare >/dev/null 2>&1 || skip 'unshare is not installed'
  probe_status=0
  probe="$("${NAMESPACE[@]}" sh -c 'mount -t tmpfs tmpfs /tmp' 2>&1)" || probe_status=$?
  [ "$probe_status" = 0 ] || skip "a private user+mount namespace with its own /tmp is unavailable: $probe"
  PROKOP_DETACH_HOST_NAMESPACES="$(namespaces)" exec "${NAMESPACE[@]}" bash "$0" --in-namespace
fi

# ---- inside the namespace ---------------------------------------------------

refuse() {
  printf 'FAIL: --in-namespace is only for the private namespace this test creates (%s)\n' "$1" >&2
  exit 1
}
# Never mount over the caller's /tmp: only a new user namespace that maps
# nothing but root, with a new mount namespace, is accepted.
mapfile -t uid_map </proc/self/uid_map
read -r map_inside _ map_count <<<"${uid_map[0]:-}"
if [ "${#uid_map[@]}" != 1 ] || [ "$map_inside" != 0 ] || [ "$map_count" != 1 ]; then
  refuse "not a user namespace mapping only root: ${uid_map[*]:-}"
fi
read -r host_user host_mnt <<<"${PROKOP_DETACH_HOST_NAMESPACES:-}"
read -r own_user own_mnt <<<"$(namespaces)"
if [ -z "${host_user:-}" ] || [ "$own_user" = "$host_user" ] || [ "$own_mnt" = "${host_mnt:-}" ]; then
  refuse "the user or mount namespace is not new"
fi
# The checkout may itself be under /tmp, which the private /tmp hides: the
# script and the wait helper are read before and copied into it.
exec 3<"$SCRIPT" 4<"$ROOT_DIR/tests/helpers/wait.sh"
mount -t tmpfs -o mode=1777 tmpfs /tmp || refuse "cannot mount a private /tmp"

export TMPDIR=/tmp
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
trap 'exit 1' HUP INT TERM
SCRIPT="$WORK/full-uninstall.sh"
cat <&3 >"$SCRIPT"
cat <&4 >"$WORK/wait.sh"
exec 3<&- 4<&-
# shellcheck source=tests/helpers/wait.sh
. "$WORK/wait.sh"
UCI="$(command -v uci)"
REAL_SLEEP="$(command -v sleep)"
SERVERS=/etc/prokop/killswitch/dnsmasq.servers

ROOT=""
fail() {
  printf 'FAIL: %s: %s\n' "$CASE" "$1" >&2
  if [ -n "$ROOT" ]; then
    cat "$ROOT"/tmp/prokop-uninstall.*/output.log 2>/dev/null | sed 's/^/  log: /' >&2 || true
    sed 's/^/  dhcp: /' "$ROOT/etc/config/dhcp" >&2 || true
  fi
  exit 1
}

# sleep: the status cleanup (sleep 300) lasts as long as this test, at most
# a minute.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/sleep" <<SH
#!/bin/sh
case "\$1" in
  300) n=0; while [ -d "$WORK" ] && [ "\$n" -lt 600 ]; do "$REAL_SLEEP" 0.1; n=\$((n + 1)); done; exit 0 ;;
esac
exec "$REAL_SLEEP" "\$@"
SH
chmod +x "$WORK/bin/sleep"
export PATH="$WORK/bin:$PATH"

# fixture NAME: a router whose kill-switch block list is still attached to
# dnsmasq after killswitch_disable (a stub that does nothing).
fixture() {
  CASE="$1"
  ROOT="$WORK/$1"
  mkdir -p "$ROOT/etc/opkg" "$ROOT/usr/bin" "$ROOT/bin" "$ROOT/packages" "$ROOT/etc/config" \
    "$ROOT/etc/init.d" "$ROOT/etc/prokop/killswitch"
  printf 'original vendor repositories\n' >"$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
  printf 'https://mirror.51343.ru/openwrt/releases/test\n' >"$ROOT/etc/opkg/distfeeds.conf"
  touch "$ROOT/packages/prokop"
  printf '#!/bin/sh\nexit 0\n' >"$ROOT/usr/bin/prokop"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$PROKOP_UNINSTALL_ROOT/dnsmasq-calls"\n' >"$ROOT/etc/init.d/dnsmasq"
  cat >"$ROOT/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
  status) [ -e "$PROKOP_UNINSTALL_ROOT/packages/$2" ] && echo 'Status: install ok installed' ;;
  remove) shift; for p in "$@"; do rm -f "$PROKOP_UNINSTALL_ROOT/packages/$p"; done ;;
  *) exit 1 ;;
esac
SH
  # Nothing of Prokop's runtime is in place: never the host's nft and ip.
  printf '#!/bin/sh\nexit 1\n' >"$ROOT/bin/nft"
  printf '#!/bin/sh\nexit 0\n' >"$ROOT/bin/ip"
  chmod +x "$ROOT/usr/bin/prokop" "$ROOT/etc/init.d/dnsmasq" "$ROOT/bin/opkg" "$ROOT/bin/nft" "$ROOT/bin/ip"
  : >"$ROOT/dnsmasq-calls"
  printf 'server=/example.com/\n' >"$ROOT$SERVERS"
  DHCP="$ROOT/etc/config/dhcp"
  cat >"$DHCP" <<EOF
config dnsmasq
	option domain 'lan'
	option serversfile '$SERVERS'

config dhcp 'lan'
	option interface 'lan'
EOF
  chmod 644 "$DHCP"
}

remove_prokop() {
  PROKOP_UNINSTALL_ROOT="$ROOT" PROKOP_MIRROR_BASE_URL=https://mirror.51343.ru PATH="$ROOT/bin:$PATH" \
    sh "$SCRIPT" start >"$ROOT/response" || fail "the removal did not start: $(cat "$ROOT/response")"
  wait_until 60 settled || fail "the removal did not finish"
  printf '%s\n' "$status" | grep -q '"state":"complete"' || fail "the removal failed: $status"
}
settled() {
  status="$(cat "$ROOT"/www/prokop-uninstall.*.json 2>/dev/null)"
  case "$status" in *'"state":"complete"'* | *'"state":"failed"'*) return 0 ;; esac
  return 1
}
has() { grep -Fqx -- "$1" "${2:-$DHCP}"; }
detached() {
  ! grep -Fq "$SERVERS" "$DHCP" || fail "dnsmasq still reads the kill-switch block list"
  grep -Fqx restart "$ROOT/dnsmasq-calls" || fail "dnsmasq was not restarted without the block list"
  has "	option domain 'lan'" && has "config dhcp 'lan'" && has "	option interface 'lan'" ||
    fail "the rest of dhcp was not kept"
}

# 1. Someone staged changes of dhcp in /tmp/.uci (LuCI before Save & Apply):
#    the removal neither commits them nor drops them, and a later Save &
#    Apply applies them once.
fixture staged
"$UCI" -c "$ROOT/etc/config" add_list 'dhcp.@dnsmasq[0].server=1.1.1.1'
"$UCI" -c "$ROOT/etc/config" set 'dhcp.@dnsmasq[0].domain=staged'
[ -s /tmp/.uci/dhcp ] || fail "uci did not stage the changes in /tmp/.uci"
cp /tmp/.uci/dhcp "$WORK/staged-dhcp"
remove_prokop
detached
! grep -Fq 1.1.1.1 "$DHCP" || fail "the removal committed a server someone had only staged"
! grep -Fq staged "$DHCP" || fail "the removal committed a domain someone had only staged"
cmp -s /tmp/.uci/dhcp "$WORK/staged-dhcp" ||
  fail "the changes someone staged for dhcp were not kept as they were: $(cat /tmp/.uci/dhcp 2>&1)"
[ "$(stat -c %a "$DHCP")" = 644 ] || fail "dhcp lost its mode: $(stat -c %a "$DHCP")"
"$UCI" -c "$ROOT/etc/config" commit dhcp
[ "$(grep -Fcx "	list server '1.1.1.1'" "$DHCP")" = 1 ] || fail "Save & Apply after the removal did not add the staged server once"
has "	option domain 'staged'" || fail "Save & Apply after the removal did not apply the staged domain"
! grep -Fq "$SERVERS" "$DHCP" || fail "Save & Apply after the removal attached the block list again"
rm -rf /tmp/.uci

# 2. A dhcp that is a symbolic link stays one; the file it points to changes.
fixture symlink
mv "$DHCP" "$ROOT/etc/dhcp.real"
ln -s ../dhcp.real "$DHCP"
remove_prokop
[ -L "$DHCP" ] || fail "the symbolic link dhcp was replaced by a file"
DHCP="$ROOT/etc/dhcp.real"
detached

# 3. Someone commits dhcp while the removal edits its copy: that change is
#    kept, and the block list is detached all the same.
fixture concurrent
cat >"$ROOT/bin/uci" <<SH
#!/bin/sh
case " \$* " in
  *" commit prokop_detach "*)
    if [ ! -e "$ROOT/committed-meanwhile" ]; then
      : >"$ROOT/committed-meanwhile"
      sed "s/option domain 'lan'/option domain 'lan'\n\toption localuse '1'/" "$DHCP" >"$DHCP.someone"
      mv "$DHCP.someone" "$DHCP"
    fi ;;
esac
exec "$UCI" "\$@"
SH
chmod +x "$ROOT/bin/uci"
remove_prokop
[ -e "$ROOT/committed-meanwhile" ] || fail "the removal did not edit a copy of dhcp"
detached
has "	option localuse '1'" || fail "the removal overwrote what someone committed meanwhile"

# 4. A servers file that is not the kill-switch's is the user's own: dhcp is
#    left exactly as it is, and dnsmasq is not restarted.
fixture foreign
sed -i "s|$SERVERS|/etc/dnsmasq.servers|" "$DHCP"
cp -p "$DHCP" "$WORK/foreign-dhcp"
remove_prokop
cmp -s "$DHCP" "$WORK/foreign-dhcp" || fail "dhcp without the kill-switch block list was changed"
[ ! -s "$ROOT/dnsmasq-calls" ] || fail "dnsmasq was restarted for nothing"

printf 'full_uninstall_dhcp_detach: ok\n'
