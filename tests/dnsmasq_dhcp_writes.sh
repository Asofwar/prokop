#!/usr/bin/env bash
set -euo pipefail

# What a running Prokop writes to /etc/config/dhcp (UC-236).
#
# dnsmasq builds its configuration from UCI at every start, so forwarding to
# sing-box (server=127.0.0.42, noresolv, cachesize=0) has to be committed
# there. It is written only when something changes: a configure of a dnsmasq
# that already forwards to sing-box, a restore or failsafe without Prokop
# settings and a kill-switch refresh that changes nothing write nothing. A
# restore puts back exactly what the configure found, options that were not
# set included. The edit works on a private copy of the committed file, so
# what someone staged with `uci set` (in /tmp/.uci) is neither read nor
# committed. A commit the overlay refuses (read-only or full) leaves the
# file as it was and fails the operation. The edit holds no lock on the
# file: a dhcp commit someone else makes meanwhile is not blocked, and the
# operation starts over from it instead of overwriting it. A symlink stays
# one. Without a dnsmasq section there is nothing to forward: nothing is
# written and nothing fails.
#
# Part 1 runs the real dns/apply.uc on the UCI fixture; part 2 on a dhcp file
# through the OpenWrt uci CLI (skipped without one: the test shim takes no
# @type[n] references).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
APPLY="$LIB/dns/apply.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  for log in "$WORK/syslog" "$WORK/dnsmasq.log" "$WORK/uci.log" "$WORK/uci.argv"; do
    [ ! -s "$log" ] || sed "s|^|  $(basename "$log"): |" "$log" >&2
  done
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/killswitch"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK/syslog" >"$WORK/bin/logger"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK/dnsmasq.log" >"$WORK/bin/dnsmasq-init"
chmod 0755 "$WORK/bin/logger" "$WORK/bin/dnsmasq-init"
export PATH="$WORK/bin:$PATH"
export DNSMASQ_INIT="$WORK/bin/dnsmasq-init"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export KILLSWITCH_STATE_DIR="$WORK/killswitch"
export PROKOP_CONFIG_NAME=prokop
export SB_DNS_INBOUND_ADDRESS=127.0.0.42

# dns_apply <mode> [force]: the exit status in STATUS.
dns_apply() {
  : >"$WORK/syslog"
  : >"$WORK/dnsmasq.log"
  STATUS=0
  ucode -L "$LIB" "$APPLY" "$@" || STATUS=$?
}
restarted() { grep -Fxq restart "$WORK/dnsmasq.log"; }

# ---- 1. the UCI fixture --------------------------------------------------------

STATE="$WORK/uci.state"
export PROKOP_UCI_STATE_FILE="$STATE"
export PROKOP_UCI_LOG_FILE="$WORK/uci.log"
export PROKOP_DNSMASQ_CONFIG_FILE="$WORK/no-dhcp"

# fixture <line...>: the dhcp state, with Prokop's settings.
fixture() {
  printf '%s\n' "prokop.settings=settings" "$@" >"$STATE"
  : >"$WORK/uci.log"
}
committed() { grep -Fxq 'commit dhcp' "$WORK/uci.log"; }
dhcp_lines() { grep '^dhcp\.' "$STATE" | sort; }

complete=(
  'dhcp.@dnsmasq[0].server=127.0.0.42'
  'dhcp.@dnsmasq[0].noresolv=1'
  'dhcp.@dnsmasq[0].cachesize=0'
  'dhcp.@dnsmasq[0].prokop_server=1.1.1.1'
  'dhcp.@dnsmasq[0].prokop_unset=noresolv cachesize'
)

# a. Nothing changes, nothing is written.
fixture "${complete[@]}"
dns_apply configure force
[ "$STATUS" = 0 ] || fail "configure of a dnsmasq that forwards to sing-box failed"
committed && fail "configure committed dhcp settings that did not change"
restarted || fail "a forced configure did not restart dnsmasq"
fixture 'dhcp.@dnsmasq[0].server=1.1.1.1'
for mode in "restore force" failsafe-restore killswitch-refresh; do
  # shellcheck disable=SC2086
  dns_apply $mode
  [ "$STATUS" = 0 ] || fail "$mode without Prokop settings failed"
  committed && fail "$mode without Prokop settings committed dhcp"
done
ok "dhcp settings that do not change are not written"

# b. A restore puts back what the configure found.
round_trip() {
  fixture "$@"
  dhcp_lines >"$WORK/before"
  dns_apply configure force
  [ "$STATUS" = 0 ] && committed || fail "configure did not save the dnsmasq settings"
  grep -Fxq 'dhcp.@dnsmasq[0].server=127.0.0.42' "$STATE" || fail "configure did not forward dnsmasq to sing-box"
  : >"$WORK/uci.log"
  dns_apply configure force
  committed && fail "a second configure wrote the same dhcp settings again"
  dns_apply restore force
  [ "$STATUS" = 0 ] && committed || fail "restore did not save the dnsmasq settings"
  dhcp_lines >"$WORK/after"
  cmp -s "$WORK/before" "$WORK/after" ||
    fail "restore did not put back the dnsmasq settings: $(diff "$WORK/before" "$WORK/after" | tr '\n' ' ')"
}
round_trip 'dhcp.@dnsmasq[0].server=1.1.1.1 8.8.8.8' 'dhcp.@dnsmasq[0].domain=lan'
round_trip 'dhcp.@dnsmasq[0].domain=lan'
round_trip 'dhcp.@dnsmasq[0].server=9.9.9.9' 'dhcp.@dnsmasq[0].noresolv=0' 'dhcp.@dnsmasq[0].cachesize=1000'
round_trip 'dhcp.@dnsmasq[0].noresolv=1' 'dhcp.@dnsmasq[0].cachesize=0'
ok "a restore puts back the dnsmasq settings as the configure found them, unset options included"

# c. Releases before UC-236 kept no record of an unset option: the dnsmasq
# defaults undo the Prokop values.
fixture 'dhcp.@dnsmasq[0].server=127.0.0.42' 'dhcp.@dnsmasq[0].noresolv=1' 'dhcp.@dnsmasq[0].cachesize=0' \
  'dhcp.@dnsmasq[0].prokop_server=1.1.1.1'
dns_apply restore force
grep -Fxq 'dhcp.@dnsmasq[0].noresolv=0' "$STATE" && grep -Fxq 'dhcp.@dnsmasq[0].cachesize=150' "$STATE" &&
  grep -Fxq 'dhcp.@dnsmasq[0].server=1.1.1.1' "$STATE" ||
  fail "a configuration of an older release was not restored: $(dhcp_lines | tr '\n' ' ')"
ok "a configuration of an older release is still restored"

# d. A commit that fails saves nothing.
fixture 'dhcp.@dnsmasq[0].server=1.1.1.1'
dhcp_lines >"$WORK/before"
rm -f "$WORK/uci.log"
mkdir "$WORK/uci.log"
dns_apply configure force
rmdir "$WORK/uci.log"
[ "$STATUS" != 0 ] || fail "a configure whose commit failed reported success"
restarted && fail "a configure whose commit failed restarted dnsmasq"
dhcp_lines | cmp -s "$WORK/before" - || fail "a configure whose commit failed left changes behind: $(dhcp_lines | tr '\n' ' ')"
ok "a configure whose commit fails saves nothing"

# e. Without a dnsmasq section dnsmasq starts no instance and there is
# nothing to forward: configure, an armed kill-switch and a restore warn and
# change nothing, as before UC-236, instead of failing the start or stop.
fixture 'dhcp.lan=dhcp' 'dhcp.lan.interface=lan'
dhcp_lines >"$WORK/before"
touch "$WORK/killswitch/dns-blocked.servers"
for mode in configure "configure force" killswitch-refresh "restore force"; do
  : >"$WORK/uci.log"
  # shellcheck disable=SC2086
  dns_apply $mode
  [ "$STATUS" = 0 ] || fail "$mode without a dnsmasq section failed"
  committed && fail "$mode without a dnsmasq section committed dhcp"
  dhcp_lines | cmp -s "$WORK/before" - || fail "$mode without a dnsmasq section changed dhcp: $(dhcp_lines | tr '\n' ' ')"
done
grep -q 'no dnsmasq section' "$WORK/syslog" || fail "a restore without a dnsmasq section did not say why the kill-switch is off"
dns_apply configure
grep -q 'no dnsmasq section.*not forwarded' "$WORK/syslog" || fail "configure without a dnsmasq section did not say why"
rm -f "$WORK/killswitch/dns-blocked.servers" "$WORK/killswitch/dnsmasq.servers"
ok "without a dnsmasq section nothing is written and nothing fails"

unset PROKOP_UCI_STATE_FILE PROKOP_UCI_LOG_FILE

# ---- 2. a dhcp file through the uci CLI ---------------------------------------

UCI_REAL="$(command -v uci 2>/dev/null || true)"
if [ -z "$UCI_REAL" ]; then
  printf 'NOTE: no OpenWrt uci CLI on PATH; the dhcp file checks are skipped\n'
  printf 'dnsmasq dhcp write checks passed\n'
  exit 0
fi

mkdir -p "$WORK/etc" "$WORK/host-uci"
DHCP="$WORK/etc/dhcp"
export PROKOP_DNSMASQ_CONFIG_FILE="$DHCP"
# The CLI as Prokop runs it: every call is logged, and $WORK/host-uci stands
# in for /tmp/.uci, which the real CLI merges into any commit of a package.
# A read runs $WORK/foreign-hook first when it exists, with the directory of
# the private copy (-c) the read is in.
cat >"$WORK/bin/uci" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK/uci.argv"
if [ -x "$WORK/foreign-hook" ]; then
  case " \$* " in *" get "*) "$WORK/foreign-hook" "\$3" ;; esac
fi
exec "$UCI_REAL" -p "$WORK/host-uci" "\$@"
SH
chmod 0755 "$WORK/bin/uci"
export PROKOP_UCI_CLI="$WORK/bin/uci"
host_uci() { "$UCI_REAL" -q -c "$WORK/etc" -t "$WORK/host-uci" "$@"; }
options() { "$UCI_REAL" -q -c "$(dirname "$1")" show "$(basename "$1")" | sort; }

cat >"$WORK/dhcp.orig" <<'EOF'
config dnsmasq
	option domainneeded '1'
	option localise_queries '1'
	option local '/lan/'
	option domain 'lan'
	list server '1.1.1.1'
	list server '8.8.8.8'
	option cachesize '1000'
	option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'

config dhcp 'lan'
	option interface 'lan'
	option start '100'
	option limit '150'
	option leasetime '12h'
EOF
cp "$WORK/dhcp.orig" "$DHCP"
chmod 0644 "$DHCP"
options "$DHCP" >"$WORK/options.orig"

# Changes staged with `uci set` and never committed: one of an option Prokop
# reads, one elsewhere.
host_uci set dhcp.@dnsmasq[0].cachesize=5000
host_uci set dhcp.lan.leasetime=1h
cp "$WORK/host-uci/dhcp" "$WORK/staged.orig"

: >"$WORK/uci.argv"
dns_apply configure force
[ "$STATUS" = 0 ] || fail "configure through the uci CLI failed"
restarted || fail "configure did not restart dnsmasq"
[ "$(host_uci get dhcp.@dnsmasq[0].server)" = 127.0.0.42 ] && [ "$(host_uci get dhcp.@dnsmasq[0].noresolv)" = 1 ] ||
  fail "configure did not forward dnsmasq to sing-box: $(cat "$DHCP")"
grep -q "leasetime '1h'" "$DHCP" && fail "configure committed a change someone else staged"
grep -q "5000" "$DHCP" && fail "configure saved a value someone else staged"
[ "$(host_uci get dhcp.@dnsmasq[0].prokop_cachesize)" = 1000 ] || fail "configure did not keep the committed cache size"
cmp -s "$WORK/staged.orig" "$WORK/host-uci/dhcp" || fail "configure changed what someone else staged"
grep -q 'commit dhcp\| dhcp\.' "$WORK/uci.argv" && fail "configure went through the live dhcp package"
[ "$(stat -c %a "$DHCP")" = 644 ] || fail "configure changed the mode of the dhcp file"
ok "configure saves only its own changes and reads the committed settings"

stamp() { stat -c '%i %Y %s' "$DHCP"; }
before="$(stamp)"
sleep 1
: >"$WORK/uci.argv"
dns_apply configure force
[ "$STATUS" = 0 ] || fail "a second configure failed"
[ "$(stamp)" = "$before" ] || fail "a second configure rewrote the dhcp file"
grep -q ' commit ' "$WORK/uci.argv" && fail "a second configure committed"
ok "a configure that changes nothing leaves the dhcp file alone"

dns_apply restore force
[ "$STATUS" = 0 ] || fail "restore through the uci CLI failed"
options "$DHCP" | cmp -s "$WORK/options.orig" - ||
  fail "restore did not put back the dhcp settings: $(options "$DHCP" | diff "$WORK/options.orig" - | tr '\n' ' ')"
cmp -s "$WORK/staged.orig" "$WORK/host-uci/dhcp" || fail "restore changed what someone else staged"
ok "restore puts back the dhcp settings exactly and leaves staged changes staged"

# A read-only or full overlay refuses the write: the file stays as it was,
# dnsmasq is not restarted and the operation fails.
overlay() {
  local kind="$1" mode="$2"
  cp "$WORK/dhcp.orig" "$WORK/dhcp.copy"
  unshare -rm sh -c '
    set -e
    etc="$1"; kind="$2"; shift 2
    if [ "$kind" = read-only ]; then
      mount --bind "$etc" "$etc"
      mount -o remount,bind,ro "$etc"
    else
      mount -t tmpfs -o size=16k tmpfs "$etc"
      cp "$WORK/dhcp.copy" "$etc/dhcp"
      dd if=/dev/zero of="$etc/fill" bs=1k 2>/dev/null || true
    fi
    status=0
    ucode -L "$LIB" "$APPLY" "$@" || status=$?
    cp "$etc/dhcp" "$WORK/dhcp.after"
    exit "$status"
  ' sh "$WORK/etc" "$kind" "$mode" force >/dev/null 2>&1 && STATUS=0 || STATUS=$?
}
export WORK LIB APPLY
cp "$WORK/dhcp.orig" "$DHCP"
if ! unshare -rm true 2>/dev/null; then
  printf 'NOTE: no user and mount namespaces; the overlay checks are skipped\n'
else
  for kind in read-only full; do
    : >"$WORK/syslog"
    : >"$WORK/dnsmasq.log"
    overlay "$kind" configure
    [ "$STATUS" != 0 ] || fail "configure on a $kind overlay reported success"
    restarted && fail "configure on a $kind overlay restarted dnsmasq"
    cmp -s "$WORK/dhcp.orig" "$WORK/dhcp.after" || fail "configure on a $kind overlay changed the dhcp file: $(cat "$WORK/dhcp.after")"
    grep -q 'Could not save the dnsmasq settings' "$WORK/syslog" || fail "configure on a $kind overlay logged no error"
  done
  ok "a read-only or full overlay fails the configure and keeps the dhcp file"

  # A full /tmp takes the write of the private copy the edit works on and
  # keeps none of it: read as an empty dhcp package, it had no dnsmasq
  # section, so configure did nothing and restore left the forwarding, both
  # reporting success. Now the copy is read back and the operation fails.
  mkdir -p "$WORK/full-tmp"
  full_tmp() {
    # shellcheck disable=SC2016 # expanded by the sh that runs it
    unshare -rm sh -c '
      mount -t tmpfs -o size=16k tmpfs "$WORK/full-tmp" || exit 90
      dd if=/dev/zero of="$WORK/full-tmp/fill" bs=1k 2>/dev/null
      TMPDIR="$WORK/full-tmp" ucode -L "$LIB" "$APPLY" "$1" force
    ' sh "$1" >/dev/null 2>&1 && STATUS=0 || STATUS=$?
    [ "$STATUS" != 90 ] || fail "could not mount the test filesystem"
  }
  cp "$WORK/dhcp.orig" "$DHCP"
  : >"$WORK/dnsmasq.log"
  full_tmp configure
  [ "$STATUS" != 0 ] || fail "configure with a full /tmp reported success"
  cmp -s "$WORK/dhcp.orig" "$DHCP" || fail "configure with a full /tmp changed the dhcp file: $(cat "$DHCP")"
  restarted && fail "configure with a full /tmp restarted dnsmasq"
  dns_apply configure force
  [ "$STATUS" = 0 ] || fail "configure through the uci CLI failed"
  cp "$DHCP" "$WORK/dhcp.forwarding"
  : >"$WORK/dnsmasq.log"
  full_tmp restore
  [ "$STATUS" != 0 ] || fail "restore with a full /tmp reported success"
  cmp -s "$WORK/dhcp.forwarding" "$DHCP" || fail "restore with a full /tmp changed the dhcp file: $(cat "$DHCP")"
  dns_apply restore force
  [ "$STATUS" = 0 ] || fail "restore through the uci CLI failed"
  ok "a full /tmp fails configure and restore instead of reading an empty dhcp"
fi

no_leftovers() {
  local dir file
  for dir in "$@"; do
    for file in "$dir"/.dhcp.*; do
      [ ! -e "$file" ] || fail "temporary file $file left behind"
    done
  done
}

# Without a dnsmasq section configure warns and leaves the file alone.
printf "config dhcp 'lan'\n\toption interface 'lan'\n" >"$DHCP"
cp "$DHCP" "$WORK/dhcp.nosection"
dns_apply configure force
[ "$STATUS" = 0 ] || fail "configure of a dhcp file without a dnsmasq section failed: $(cat "$WORK/syslog")"
cmp -s "$WORK/dhcp.nosection" "$DHCP" || fail "configure changed a dhcp file without a dnsmasq section: $(cat "$DHCP")"
grep -q 'no dnsmasq section' "$WORK/syslog" || fail "configure without a dnsmasq section did not say why"
ok "configure of a dhcp file without a dnsmasq section changes nothing and does not fail"

# /etc/config/dhcp as a symlink: the file it points to is written, as a
# libuci commit does, and the link stays.
mkdir -p "$WORK/store"
cp "$WORK/dhcp.orig" "$WORK/store/dhcp"
chmod 0644 "$WORK/store/dhcp"
rm -f "$DHCP"
ln -s ../store/dhcp "$DHCP"
dns_apply configure force
[ "$STATUS" = 0 ] || fail "configure through a dhcp symlink failed"
[ -L "$DHCP" ] || fail "configure replaced the dhcp symlink with a file"
grep -q "127.0.0.42" "$WORK/store/dhcp" || fail "configure did not save the file the dhcp symlink points to"
dns_apply restore force
[ "$STATUS" = 0 ] && [ -L "$DHCP" ] || fail "restore through a dhcp symlink failed or replaced the link"
options "$DHCP" | cmp -s "$WORK/options.orig" - || fail "restore through a dhcp symlink did not put back the settings"
no_leftovers "$WORK/etc" "$WORK/store"
rm -f "$DHCP"
cp "$WORK/dhcp.orig" "$DHCP"
ok "a dhcp symlink stays a symlink and its target holds the settings"

# Someone else commits dhcp (LuCI, another uci CLI) while an edit runs: the
# commit is not blocked, and the edit starts over from the file as it is
# then, so neither change is lost. foreign-hook commits dhcp.lan.foreign at
# the first read of an edit, for $WORK/foreign.limit edits.
mkdir -p "$WORK/foreign-uci"
cat >"$WORK/foreign-hook" <<SH
#!/bin/sh
[ "\$(cat "$WORK/foreign.last" 2>/dev/null)" != "\$1" ] || exit 0
printf '%s' "\$1" >"$WORK/foreign.last"
n=\$((\$(cat "$WORK/foreign.count") + 1))
[ "\$n" -le "\$(cat "$WORK/foreign.limit")" ] || exit 0
printf '%s' "\$n" >"$WORK/foreign.count"
timeout 3 sh -c '"\$1" -q -c "\$2" -t "\$3" set "dhcp.lan.foreign=\$4" && "\$1" -q -c "\$2" -t "\$3" commit dhcp' sh \
  "$UCI_REAL" "$WORK/etc" "$WORK/foreign-uci" "\$(cat "$WORK/foreign.tag")\$n" ||
  printf '%s\n' "\$n" >>"$WORK/foreign.blocked"
SH
chmod 0755 "$WORK/foreign-hook"
foreign() {
  printf '%s' "$1" >"$WORK/foreign.tag"
  printf '%s' "$2" >"$WORK/foreign.limit"
  printf 0 >"$WORK/foreign.count"
  rm -f "$WORK/foreign.last" "$WORK/foreign.blocked"
}
foreign_value() { "$UCI_REAL" -q -c "$WORK/etc" get dhcp.lan.foreign || true; }

foreign c 1
dns_apply configure force
[ ! -e "$WORK/foreign.blocked" ] || fail "a dhcp commit made during a configure was blocked until it timed out"
[ "$STATUS" = 0 ] || fail "a configure during which dhcp was committed failed: $(cat "$WORK/syslog")"
[ "$(foreign_value)" = c1 ] || fail "a configure lost a dhcp change committed during it: $(cat "$DHCP")"
[ "$(host_uci get dhcp.@dnsmasq[0].server)" = 127.0.0.42 ] || fail "a configure during which dhcp was committed did not save its own settings"
restarted || fail "a configure during which dhcp was committed did not restart dnsmasq"
grep -q 'changed while Prokop edited' "$WORK/syslog" || fail "a configure that started over did not say why"
foreign r 1
dns_apply restore force
[ "$STATUS" = 0 ] && [ ! -e "$WORK/foreign.blocked" ] || fail "a restore during which dhcp was committed failed or blocked the commit"
[ "$(foreign_value)" = r1 ] || fail "a restore lost a dhcp change committed during it: $(cat "$DHCP")"
options "$DHCP" | grep -v '^dhcp\.lan\.foreign=' | cmp -s "$WORK/options.orig" - ||
  fail "a restore during which dhcp was committed did not put back the settings: $(cat "$DHCP")"
no_leftovers "$WORK/etc"
ok "a dhcp commit made during an edit is neither blocked nor lost"

# A file that keeps changing is not overwritten: after a few attempts the
# operation fails, says why, and dnsmasq is not restarted.
foreign k 1000
dns_apply configure force
[ "$STATUS" != 0 ] || fail "a configure whose dhcp file kept changing reported success"
restarted && fail "a configure whose dhcp file kept changing restarted dnsmasq"
grep -q "127.0.0.42" "$DHCP" && fail "a configure whose dhcp file kept changing overwrote it"
[ "$(foreign_value)" = "k$(cat "$WORK/foreign.count")" ] || fail "a configure overwrote a dhcp change committed during it"
grep -q 'kept changing' "$WORK/syslog" || fail "a configure whose dhcp file kept changing did not say why"
rm -f "$WORK/foreign-hook"
no_leftovers "$WORK/etc"
ok "an edit of a dhcp file that keeps changing fails without overwriting it"

printf 'dnsmasq dhcp write checks passed\n'
