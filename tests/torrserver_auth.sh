#!/usr/bin/env bash
set -euo pipefail

# TorrServer's API password, memory limit and jail as torrserver/manager.uc
# prepares them (TS-1; the init script's side is torrserver_init_user).
#
# - prepare-auth writes data/accs.db ({"user":"password"}, 0600) only while
#   the password is on and usable, never through a link planted in data/
#   (TorrServer's user owns it), and removes it when the password is off;
# - every request of Prokop to TorrServer's API sends the password from a
#   private curl config file (-K), never on a command line, and without
#   curl no request that needs it is made;
# - memlimit-mib: TorrServer's cache from its settings (settings.json, or
#   the largest value in a raw config.db) plus 64 MiB, none past half the
#   router's memory;
# - disk-cache-dirs: the disk cache directories for the jail;
# - procd's jail (ujail, TorrServer's parent) is neither Prokop's
#   TorrServer nor a foreign one.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
MANAGER="$LIB/torrserver/manager.uc"
WORK="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] || rm -rf "${WORK:?}"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'torrserver_auth: FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

TS_DIR="$WORK/opt/torrserver"
DATA="$TS_DIR/data"
mkdir -p "$DATA" "$WORK/bin" "$WORK/tmp" "$WORK/proc"
export PATH="$WORK/bin:$PATH" TMPDIR="$WORK/tmp" TEST_WORK="$WORK"
export PROKOP_TORRSERVER_DIR="$TS_DIR" PROKOP_UCI_STATE_FILE="$WORK/uci.state"
export PROKOP_MEMINFO_PATH="$WORK/meminfo" PROKOP_PROC_DIR="$WORK/proc"
export PROKOP_TORRSERVER_API_URL="http://127.0.0.1:8090" PROKOP_UJAIL_BIN="/sbin/ujail"
printf 'MemTotal:        1006668 kB\n' >"$WORK/meminfo"
manager() { ucode -L "$LIB" "$MANAGER" "$@"; }
settings() { printf '%s\n' prokop.settings=settings "$@" >"$PROKOP_UCI_STATE_FILE"; }

# --- 1. accs.db ----------------------------------------------------------------
settings
[ "$(manager prepare-auth)" = off ] || fail "the password must be off by default"
[ ! -e "$DATA/accs.db" ] || fail "no accounts file without a password"

settings prokop.settings.torrserver_auth_enabled=1 prokop.settings.torrserver_auth_user=admin \
  'prokop.settings.torrserver_auth_password=p"w:\x'
[ "$(manager prepare-auth)" = on ] || fail "a usable password must turn the API password on"
[ "$(node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))))' "$DATA/accs.db")" = \
  '{"admin":"p\"w:\\x"}' ] || fail "accs.db must hold the user and the password as JSON: $(cat "$DATA/accs.db")"
[ "$(stat -c %a "$DATA/accs.db")" = 600 ] || fail "accs.db must be 0600"
before="$(stat -c %Y.%i "$DATA/accs.db")"
sleep 1
manager prepare-auth >/dev/null
[ "$(stat -c %Y.%i "$DATA/accs.db")" = "$before" ] || fail "an unchanged password must not rewrite accs.db (flash)"

# TorrServer's user owns data/: a link it plants is replaced, never written
# through, at the file and at the staged name.
printf 'keep' >"$WORK/victim"
rm -f "$DATA/accs.db"
ln -s "$WORK/victim" "$DATA/accs.db"
ln -s "$WORK/victim" "$DATA/accs.db.prokop-new"
[ "$(manager prepare-auth)" = on ] || fail "a planted link must not stop the password"
[ "$(cat "$WORK/victim")" = keep ] || fail "a link in data/ was written through"
[ -f "$DATA/accs.db" ] && [ ! -L "$DATA/accs.db" ] || fail "accs.db must be a file of its own"
[ ! -e "$DATA/accs.db.prokop-new" ] || fail "the staged file must not stay"

# On without a usable user or password: refused (the init script then does
# not start TorrServer).
for bad in ':secret' 'ad:min:secret' 'admin:' 'admin:se	cret'; do
  settings prokop.settings.torrserver_auth_enabled=1 "prokop.settings.torrserver_auth_user=${bad%%:*}" \
    "prokop.settings.torrserver_auth_password=${bad#*:}"
  [ "$bad" != 'ad:min:secret' ] ||
    settings prokop.settings.torrserver_auth_enabled=1 prokop.settings.torrserver_auth_user=ad:min prokop.settings.torrserver_auth_password=secret
  manager prepare-auth >/dev/null 2>&1 && fail "an unusable password must be refused: $bad"
done
settings prokop.settings.torrserver_auth_enabled=0 prokop.settings.torrserver_auth_user=admin \
  prokop.settings.torrserver_auth_password=secret
[ "$(manager prepare-auth)" = off ] && [ ! -e "$DATA/accs.db" ] || fail "turned off, accs.db must go"
ok 'accs.db holds the password only while it is on, and never through a link'

# --- 2. Requests to the API carry the password from a curl config ------------------
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_WORK/curl-argv"
data=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -K) cat "$2" >>"$TEST_WORK/curl-config"; printf '%s\n' "$2" >>"$TEST_WORK/curl-config-paths"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -m|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */settings)
    exec node -e '
      const fs = require("fs");
      const [body, store] = process.argv.slice(1);
      const req = JSON.parse(fs.readFileSync(body, "utf8"));
      if (req.action === "get") process.stdout.write(fs.readFileSync(store, "utf8"));
      else fs.writeFileSync(store, JSON.stringify(req.sets));' "$data" "$TEST_WORK/ts-settings.json" ;;
esac
exit 22
SH
chmod 0755 "$WORK/bin/curl"
printf '{"CacheSize":67108864}' >"$WORK/ts-settings.json"
settings prokop.settings.torrserver_auth_enabled=1 prokop.settings.torrserver_auth_user=admin \
  'prokop.settings.torrserver_auth_password=s3cr"et\'
manager apply-recommended >/dev/null || fail "the recommended settings must go through with the password"
[ "$(grep -c . "$WORK/curl-argv")" = 3 ] || fail "get, set and get again were expected: $(cat "$WORK/curl-argv")"
! grep -q 's3cr' "$WORK/curl-argv" || fail "the password reached curl's command line"
[ "$(grep -c -- '-K ' "$WORK/curl-argv")" = 3 ] || fail "each request must read the password from -K"
[ "$(sort -u "$WORK/curl-config")" = 'user = "admin:s3cr\"et\\"' ] ||
  fail "curl's config must hold the escaped user and password: $(cat "$WORK/curl-config")"
while read -r path; do
  [ ! -e "$path" ] || fail "curl's config must be removed after the request: $path"
done <"$WORK/curl-config-paths"
# Without the password nothing extra is sent.
: >"$WORK/curl-argv"
settings
manager apply-recommended >/dev/null || fail "the recommended settings must go through without a password"
! grep -q -- '-K' "$WORK/curl-argv" || fail "no config file without a password"
# Without curl (uclient-fetch takes a password only as an argument): a
# request that needs the password is not made.
rm -f "$WORK/bin/curl"
cat >"$WORK/bin/sh" <<SH
#!/bin/bash
[ "\$1 \$2" = "-c command -v curl" ] && exit 1
exec /bin/sh "\$@"
SH
cat >"$WORK/bin/wget" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_WORK/wget-argv"
exit 0
SH
chmod 0755 "$WORK/bin/sh" "$WORK/bin/wget"
settings prokop.settings.torrserver_auth_enabled=1 prokop.settings.torrserver_auth_user=admin \
  prokop.settings.torrserver_auth_password=s3cret
manager apply-recommended >/dev/null 2>&1 && fail "without curl the password must not be sent another way"
[ ! -e "$WORK/wget-argv" ] || fail "wget was asked although the password cannot be passed to it: $(cat "$WORK/wget-argv")"
rm -f "$WORK/bin/sh" "$WORK/bin/wget"
ok 'requests to the API send the password from a private curl config, never on a command line'

# --- 3. GOMEMLIMIT ------------------------------------------------------------------
settings
rm -f "$DATA/settings.json" "$DATA/config.db"
# 1 GiB: without settings the recommended 128 MiB cache, + 64.
[ "$(manager memlimit-mib)" = 192 ] || fail "the limit without settings: $(manager memlimit-mib || true)"
printf '{"BitTorr":{"CacheSize":268435456,"TorrentsSavePath":""}}' >"$DATA/settings.json"
[ "$(manager memlimit-mib)" = 320 ] || fail "the limit must follow settings.json"
printf '{"BitTorr":{"CacheSize":0}}' >"$DATA/settings.json"
[ "$(manager memlimit-mib)" = 128 ] || fail "a cache of 0 is TorrServer's default 64 MiB"
rm -f "$DATA/settings.json"
# A raw bbolt config.db: binary pages, the settings as JSON, an older copy.
printf 'BOLT\0\0\0{"CacheSize":33554432,"PreloadCache":50}\0\0\x01{"CacheSize":100663296}\0' >"$DATA/config.db"
[ "$(manager memlimit-mib)" = 160 ] || fail "the largest cache in config.db must count: $(manager memlimit-mib || true)"
# Past half the router's memory (256 MiB): no limit at all.
printf 'MemTotal:        262144 kB\n' >"$WORK/meminfo"
manager memlimit-mib >/dev/null && fail "a limit past half the memory must not be set"
: >"$WORK/meminfo"
manager memlimit-mib >/dev/null && fail "without the memory size no limit may be set"
printf 'MemTotal:        1006668 kB\n' >"$WORK/meminfo"
ok 'GOMEMLIMIT follows the cache TorrServer keeps, and is left out when it cannot help'

# --- 4. The disk cache in the jail ----------------------------------------------------
mkdir -p "$WORK/mnt/cache" "$WORK/mnt/old"
printf '{"BitTorr":{"UseDisk":true,"TorrentsSavePath":"%s/"}}' "$WORK/mnt/cache" >"$DATA/settings.json"
printf 'x\0{"TorrentsSavePath":"%s"}\0{"TorrentsSavePath":"/etc"}\0{"TorrentsSavePath":"%s/../x"}\0{"TorrentsSavePath":"%s/missing"}' \
  "$WORK/mnt/old" "$WORK/mnt" "$WORK/mnt" >"$DATA/config.db"
[ "$(manager disk-cache-dirs | tr '\n' ' ')" = "$WORK/mnt/cache $WORK/mnt/old " ] ||
  fail "the disk cache directories: $(manager disk-cache-dirs | tr '\n' ' ')"
ok 'the jail gets the disk cache directories, not system ones or missing ones'

# --- 5. ujail is TorrServer's parent, not another TorrServer ------------------------
printf '#!/bin/sh\n' >"$TS_DIR/torrserver"
printf '{"version":"MatriX.1","sha256":"%064d","size":%s}\n' 0 "$(stat -c %s "$TS_DIR/torrserver")" >"$TS_DIR/prokop-managed.json"
proc() { # proc <pid> <exe> <cmdline...>
  local pid="$1" exe="$2"
  shift 2
  mkdir -p "$WORK/proc/$pid"
  ln -sfn "$exe" "$WORK/proc/$pid/exe"
  printf '%s\0' "$@" >"$WORK/proc/$pid/cmdline"
}
proc 100 /sbin/ujail /sbin/ujail -t 5 -n torrserver -U torrserver -- "$TS_DIR/torrserver" -d "$DATA" -p 8090
proc 101 "$TS_DIR/torrserver" "$TS_DIR/torrserver" -d "$DATA" -p 8090
field() { node -e 'const v=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(String(new Function("v","return "+process.argv[1])(v)))' "$1"; }
[ "$(manager status | field 'v.running+":"+v.foreign')" = 1:0 ] ||
  fail "procd's jail around Prokop's TorrServer was taken for a foreign one: $(manager status)"
# TorrServer Direct marks the instance's cgroup only while TorrServer is
# all that runs in it: ujail around it may, anything else may not.
mkdir -p "$WORK/cgroup/services/prokop-torrserver/torrserver"
export PROKOP_CGROUP_DIR="$WORK/cgroup"
for pid in 100 101; do printf '0::/services/prokop-torrserver/torrserver\n' >"$WORK/proc/$pid/cgroup"; done
printf '100\n101\n' >"$WORK/cgroup/services/prokop-torrserver/torrserver/cgroup.procs"
[ "$(manager card-status | field v.direct.available)" = 1 ] ||
  fail "the jail must not cost TorrServer Direct its cgroup: $(manager card-status)"
proc 102 /bin/busybox /bin/sh -c sleep
printf '100\n101\n102\n' >"$WORK/cgroup/services/prokop-torrserver/torrserver/cgroup.procs"
[ "$(manager card-status | field v.direct.available)" = 0 ] || fail "a shared cgroup must stay unavailable to Direct"
proc 102 /sbin/ujail /sbin/ujail -n other -- /bin/sh
[ "$(manager card-status | field v.direct.available)" = 0 ] || fail "a jail around something else must not count as TorrServer's"
# A TorrServer from elsewhere in a jail of its own is still foreign.
rm -rf "$WORK/proc/102"
proc 103 /usr/bin/torrserver /usr/bin/torrserver
[ "$(manager status | field v.foreign)" = 1 ] || fail "another TorrServer must stay foreign"
ok "procd's jail is neither Prokop's TorrServer nor a foreign one, and keeps Direct's cgroup"

printf 'torrserver auth checks passed\n'
