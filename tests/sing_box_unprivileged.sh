#!/usr/bin/env bash
set -euo pipefail

# sing-box without root (singbox/unprivileged.uc), opt-in.
#
# 1. Off (the default): no decision, sing-box runs as root as before.
# 2. On, every precondition that does not hold leaves sing-box on root and
#    names why: the sing-box package's own service script, no ujail, a tun
#    inbound, a file the configuration names that the user cannot read.
# 3. On and possible: the user is created (OpenWrt's functions, stubbed),
#    the capabilities file holds NET_ADMIN, NET_RAW and NET_BIND_SERVICE
#    in every set, config.json and the cache file become the user's and
#    stay 0600, the working directory too, Prokop's cached rule sets are
#    given to the user's group (g+r) and their directory g+x.
# 4. Every publish of config.json decides again (singbox/runtime.uc).
# 5. The managed service script passes user, group, capabilities and
#    no_new_privs to procd only with Prokop's decision, the user and the
#    capabilities file in place.
# 6. procd reports ujail as the instance when it hands capabilities over
#    through it: every check of the runtime is made on its one sing-box
#    child (service/state.uc jailed_sing_box_child); a ujail with two
#    sing-box children is no sing-box.
# 7. The UI shows the state and the reason (service/ui.uc).
#
# Hardware NOT TESTED: procd and ujail are stand-ins here.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
W="$(mktemp -d)"
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$W"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; [ ! -s "$W/logger.log" ] || sed 's/^/  log: /' "$W/logger.log" >&2; exit 1; }

mkdir -p "$W/bin" "$W/run" "$W/etc" "$W/rscache/sub" "$W/tmp" "$W/work"
# As /etc and /tmp: the user passes through.
chmod 0755 "$W" "$W/etc" "$W/tmp" "$W/work"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/logger.log"\n' "$W" >"$W/bin/logger"
chmod +x "$W/bin/logger"
printf 'root:x:0:0:root:/root:/bin/ash\n' >"$W/etc/passwd"
printf 'root:x:0:\n' >"$W/etc/group"
# OpenWrt's /lib/functions.sh, as far as the user is concerned.
cat >"$W/functions.sh" <<SH
group_add() { printf '%s:x:%s:\n' "\$1" "\$2" >>"$W/etc/group"; }
user_add() { printf '%s:x:%s:%s:%s:%s:%s\n' "\$1" "\$2" "\$3" "\$4" "\$5" "\$6" >>"$W/etc/passwd"; }
SH
: >"$W/ujail"; chmod +x "$W/ujail"
ucode -L "$LIB" -e 'print(require("singbox.managed_service").text())' >"$W/sing-box.init"
printf '#!/bin/sh /etc/rc.common\n# a package script\n' >"$W/package.init"

uci() {
  cat >"$W/uci.state" <<UCI
prokop.settings=settings
prokop.settings.config_path=$W/etc/config.json
prokop.settings.sing_box_unprivileged=$1
sing-box.main=sing-box
sing-box.main.workdir=$W/work/sing-box
UCI
}
E() {
  env PATH="$W/bin:$PATH" PROKOP_LIB="$LIB" PROKOP_UCI_STATE_FILE="$W/uci.state" PROKOP_RUNTIME_STATE_DIR="$W/run" \
    PROKOP_SING_BOX_USER_DECISION_FILE="$W/run/sing-box-user" PROKOP_SING_BOX_CAPABILITIES_FILE="$W/etc/capabilities/prokop-sing-box.json" \
    PROKOP_PASSWD_FILE="$W/etc/passwd" PROKOP_GROUP_FILE="$W/etc/group" PROKOP_FUNCTIONS_SH="$W/functions.sh" \
    PROKOP_UJAIL_BIN="$W/ujail" PROKOP_SING_BOX_INIT_SCRIPT="${INIT:-$W/sing-box.init}" \
    PROKOP_RULESET_CACHE_DIR="$W/rscache" PROKOP_SING_BOX_USER_TEST_CHOWN_LOG="$W/chown.log" \
    TMP_SING_BOX_FOLDER="$W/tmp" TMPDIR="$W/tmp" "$@"
}
prepare() { E ucode -L "$LIB" -e 'exit(require("singbox.unprivileged").prepare(ARGV[0]) ? 0 : 1)' -- "$W/etc/config.json"; }
status() { ucode -e 'let s = json(require("fs").readfile(ARGV[0])); print(s.requested, " ", s.active, " ", s.reason)' -- "$W/run/sing-box-user.json"; }
mode() { printf '%o' "$(( $(stat -c '0%a' "$1") ))"; }

write_config() {
  cat >"$W/etc/config.json" <<JSON
{ "inbounds": [ { "type": "tproxy", "tag": "tproxy-in", "listen_port": 1602 } $1 ],
  "route": { "rule_set": [ { "type": "local", "tag": "a", "format": "binary", "path": "$W/rscache/sub/a.srs" } $2 ] },
  "experimental": { "cache_file": { "enabled": true, "path": "$W/tmp/cache.db", "store_fakeip": true } } }
JSON
  chmod 0600 "$W/etc/config.json"
}
printf 'rules' >"$W/rscache/sub/a.srs"; chmod 0600 "$W/rscache/sub/a.srs"; chmod 0700 "$W/rscache" "$W/rscache/sub"

# 1. Off.
uci 0; write_config "" ""
prepare && fail "the option off decided for a user"
[ ! -e "$W/run/sing-box-user" ] || fail "the option off left a decision"
[ "$(status)" = "false false " ] || fail "status of the option off: $(status)"

# 2. On, and not possible.
uci 1
INIT="$W/package.init" prepare && fail "the package's service script was given a user"
[ "$(status)" = "true false service_script" ] || fail "package script: $(status)"
grep -q 'runs as root although Settings ask' "$W/logger.log" || fail "the reason was not logged"
mv "$W/ujail" "$W/ujail.off"
prepare && fail "a firmware without ujail was given a user"
[ "$(status)" = "true false no_ujail" ] || fail "no ujail: $(status)"
mv "$W/ujail.off" "$W/ujail"
write_config ', { "type": "tun", "tag": "tun-in" }' ""
prepare && fail "a tun inbound was given a user"
[ "$(status)" = "true false unsupported_config" ] || fail "tun: $(status)"
[ ! -e "$W/run/sing-box-user" ] || fail "a refused case left a decision"
# A certificate outside Prokop's caches that only root reads.
printf 'key' >"$W/etc/key.pem"; chmod 0600 "$W/etc/key.pem"
write_config "" ", { \"type\": \"local\", \"tag\": \"k\", \"format\": \"binary\", \"path\": \"$W/etc/key.pem\" }"
: >"$W/chown.log"
prepare && fail "a file the user cannot read was named and sing-box was given a user"
[ "$(status)" = "true false path_unreadable" ] || fail "unreadable path: $(status)"
[ "$(mode "$W/etc/key.pem")" = 600 ] || fail "a file outside Prokop's caches was opened up"
! grep -q "^$W/etc/key.pem " "$W/chown.log" || fail "a file outside Prokop's caches was handed over"

# 3. On and possible.
write_config "" ""
: >"$W/chown.log"
prepare || fail "sing-box was not given its user: $(status)"
[ "$(status)" = "true true " ] || fail "status: $(status)"
[ "$(cat "$W/run/sing-box-user")" = prokop-sb ] || fail "the decision does not name prokop-sb"
grep -q '^prokop-sb:x:65536:65536:' "$W/etc/passwd" || fail "the user was not created with a free id: $(cat "$W/etc/passwd")"
grep -q '^prokop-sb:x:65536:' "$W/etc/group" || fail "the group was not created"
ucode -e '
  let c = json(require("fs").readfile(ARGV[0]));
  let want = [ "CAP_NET_ADMIN", "CAP_NET_BIND_SERVICE", "CAP_NET_RAW" ];
  for (let set in [ "bounding", "effective", "ambient", "permitted", "inheritable" ])
    if (sprintf("%J", sort(c[set] || [])) != sprintf("%J", want)) die(set + "\n");
  if (length(keys(c)) != 5) die("sets\n");' -- "$W/etc/capabilities/prokop-sing-box.json" ||
  fail "the capabilities file is wrong: $(cat "$W/etc/capabilities/prokop-sing-box.json")"
grep -qx "$W/etc/config.json 65536:65536" "$W/chown.log" || fail "config.json was not handed to the user"
[ "$(mode "$W/etc/config.json")" = 600 ] || fail "config.json is not private"
grep -qx "$W/tmp/cache.db 65536:65536" "$W/chown.log" || fail "the cache file was not handed to the user"
[ -f "$W/tmp/cache.db" ] && [ "$(mode "$W/tmp/cache.db")" = 600 ] || fail "the cache file is missing or not private"
grep -qx "$W/work/sing-box 65536:65536" "$W/chown.log" || fail "the working directory was not handed to the user"
grep -qx "$W/rscache/sub/a.srs 0:65536" "$W/chown.log" || fail "the cached rule set was not given to the user's group"
[ "$(mode "$W/rscache/sub/a.srs")" = 640 ] || fail "the cached rule set is not group-readable: $(mode "$W/rscache/sub/a.srs")"
[ "$(mode "$W/rscache")" = 710 ] && [ "$(mode "$W/rscache/sub")" = 710 ] ||
  fail "the rule set directories are not searchable for the group only: $(mode "$W/rscache") $(mode "$W/rscache/sub")"
grep -q 'sing-box runs as the user prokop-sb' "$W/logger.log" || fail "the change to the user was not logged"
# A second decision creates no second user.
prepare || fail "the second decision failed"
[ "$(grep -c '^prokop-sb:' "$W/etc/passwd")" = 1 ] || fail "the user was created twice"

# 4. Every publish of config.json decides again: a tun inbound in the next
#    generation puts sing-box back on root.
mkdir -p "$W/tmp/stage"
printf '{ "inbounds": [ { "type": "tun", "tag": "tun-in" } ] }\n' >"$W/tmp/stage/next.json"
E ucode -L "$LIB" "$LIB/singbox/runtime.uc" commit-config-stage "$W/tmp/stage/next.json" "$W/tmp/backup.json" ||
  fail "the next generation was not committed"
[ "$(status)" = "true false unsupported_config" ] || fail "the publish did not decide again: $(status)"
[ ! -e "$W/run/sing-box-user" ] || fail "the publish kept the user for a configuration that needs root"
E ucode -L "$LIB" "$LIB/singbox/runtime.uc" restore-config-stage "$W/tmp/backup.json" || fail "the rollback failed"
[ "$(status)" = "true true " ] || fail "the rollback did not decide again: $(status)"

# 5. The managed service script.
run_script() {
  sed -e "s#/var/run/prokop/sing-box-user#$W/run/sing-box-user#g" \
      -e "s#/etc/capabilities/prokop-sing-box.json#$W/etc/capabilities/prokop-sing-box.json#g" \
      -e "s#/etc/passwd#$W/etc/passwd#g" -e "s#/sbin/ujail#$W/ujail#g" "$W/sing-box.init" >"$W/script.sh"
  sh -c '
    config_load() { :; }
    config_get() { eval "$1=\$4"; }
    config_get_bool() { eval "$1=1"; }
    procd_open_instance() { :; }
    procd_close_instance() { :; }
    procd_set_param() { echo "$*"; }
    . "$1"
    start_service' sh "$W/script.sh"
}
sh -n "$W/sing-box.init" || fail "the managed service script does not parse"
out="$(run_script)"
printf '%s\n' "$out" | grep -qx 'user prokop-sb' || fail "the script does not pass the user: $out"
printf '%s\n' "$out" | grep -qx 'group prokop-sb' || fail "the script does not pass the group"
printf '%s\n' "$out" | grep -qx "capabilities $W/etc/capabilities/prokop-sing-box.json" || fail "the script does not pass the capabilities"
printf '%s\n' "$out" | grep -qx 'no_new_privs 1' || fail "the script does not set no_new_privs"
rm -f "$W/run/sing-box-user"
out="$(run_script)"
! printf '%s\n' "$out" | grep -Eq '^(user|group|capabilities|no_new_privs) ' || fail "the script ran sing-box as a user without Prokop's decision"
printf 'prokop-sb\n' >"$W/run/sing-box-user"; mv "$W/etc/capabilities/prokop-sing-box.json" "$W/caps.off"
out="$(run_script)"
! printf '%s\n' "$out" | grep -q '^user ' || fail "the script ran sing-box as a user without its capabilities file"
mv "$W/caps.off" "$W/etc/capabilities/prokop-sing-box.json"
printf 'root\n' >"$W/run/sing-box-user"
out="$(run_script)"
! printf '%s\n' "$out" | grep -q '^user ' || fail "the script passed root as the user"

# 6. ujail between procd and sing-box.
cp "$(command -v bash)" "$W/bin/ujail"
cp "$(command -v sleep)" "$W/bin/sing-box"
"$W/bin/ujail" -c '"$1" 300 & wait' -- "$W/bin/sing-box" run -c "$W/etc/config.json" &
JAIL=$!; PIDS+=("$JAIL"); disown "$JAIL"
for _ in $(seq 100); do CHILD="$(pgrep -P "$JAIL" -x sing-box || true)"; [ -n "$CHILD" ] && break; sleep 0.05; done
[ -n "$CHILD" ] || fail "the stand-in sing-box did not start"
PIDS+=("$CHILD")
printf '#!/bin/sh\necho %s\n' "'{\"sing-box\":{\"instances\":{\"sing-box\":{\"running\":true,\"pid\":$JAIL}}}}'" >"$W/bin/ubus"
chmod +x "$W/bin/ubus"
state() { E ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }
[ "$(state sing-box-service-runtime-pid)" = "$CHILD" ] || fail "the jailed sing-box was not found behind ujail: $(state sing-box-service-runtime-pid)"
state sing-box-service-running || fail "the jailed sing-box is not seen running"
# A second sing-box child: no single sing-box, fail closed.
"$W/bin/ujail" -c '"$1" 300 & "$1" 300 & wait' -- "$W/bin/sing-box" run -c "$W/etc/config.json" &
JAIL2=$!; PIDS+=("$JAIL2"); disown "$JAIL2"
for _ in $(seq 100); do [ "$(pgrep -P "$JAIL2" -x sing-box | wc -l)" = 2 ] && break; sleep 0.05; done
for p in $(pgrep -P "$JAIL2"); do PIDS+=("$p"); done
printf '#!/bin/sh\necho %s\n' "'{\"sing-box\":{\"instances\":{\"sing-box\":{\"running\":true,\"pid\":$JAIL2}}}}'" >"$W/bin/ubus"
[ "$(state sing-box-service-runtime-pid)" = "$JAIL2" ] || fail "a ujail with two sing-box children was resolved to one"
! state sing-box-service-running || fail "a ujail with two sing-box children was taken for sing-box"

# 7. The UI.
ui_caps() { E PROKOP_SING_BOX_USER_STATUS_FILE="$W/run/sing-box-user.json" ucode -L "$LIB" "$LIB/service/ui.uc" get-ui-capabilities; }
ui_caps | grep -q '"sing_box_user": "active"' || fail "the UI does not show the user: $(ui_caps)"
write_config ', { "type": "tun", "tag": "tun-in" }' ""
prepare || true
ui_caps | grep -q '"sing_box_user": "root", "sing_box_user_reason": "unsupported_config"' || fail "the UI does not show the reason: $(ui_caps)"

printf 'sing_box_unprivileged: OK\n'
