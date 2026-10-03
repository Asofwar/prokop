#!/usr/bin/env bash
set -euo pipefail

# Writes to flash that change nothing, temporary files left behind, and the
# crontab erase path (UC-159).
#
# Every start rewrote the managed sing-box init script with the same text,
# every start and stop handed the same crontab to `crontab` (a rewrite of
# /etc/crontabs/root and a crond signal), and every unchanged rule-set
# refresh rewrote the .validated record next to the cached list. Now each is
# written only when it changes. A crontab that exists but cannot be read was
# taken as empty and written back with only Prokop's jobs, erasing the
# user's; now the refresh fails and writes nothing. A copy of the init
# script that a crash left between its write and its rename, and the
# partial copy a failed write leaves of the persistent subscription cache or
# of a generated section cache, are removed. A full /tmp or overlay, which
# takes the write of a small file and keeps none of it, fails the write
# instead of replacing the crontab or a cache with an empty file.
#
# The init script checks and the full /tmp and full overlay checks need user
# and mount namespaces (unshare -rm) and are skipped without them.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }
stamp() { stat -c '%i %y %s' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod 0755 "$WORK/bin/logger"
export PATH="$WORK/bin:$PATH"
export LIB WORK
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export PROKOP_UCI_STATE_FILE="$WORK/uci.state"
export PROKOP_UCI_LOG_FILE="$WORK/uci.log"
cat >"$WORK/uci.state" <<EOF
prokop.settings=settings
prokop.settings.config_path=$WORK/config.json
sing-box.main=sing-box
sing-box.main.enabled=1
sing-box.main.user=root
sing-box.main.conffile=$WORK/config.json
EOF

# ---- 1. the managed sing-box init script --------------------------------------

if ! unshare -rm true 2>/dev/null; then
  printf 'NOTE: no user and mount namespaces; the init script checks are skipped\n'
else
  mkdir -p "$WORK/initd"
  printf 'extended-compressed\n' >"$WORK/variant"
  # /etc/init.d is $WORK/initd in a mount namespace of its own.
  cat >"$WORK/initd-check.sh" <<'SH'
set -e
mount --bind "$WORK/initd" /etc/init.d
configure() { SB_VARIANT_STATE_FILE="$WORK/variant" ucode -L "$LIB" "$LIB/singbox/runtime.uc" configure-service; }
configure
stat -c '%i %y %s' /etc/init.d/sing-box >"$WORK/initd.first"
configure
stat -c '%i %y %s' /etc/init.d/sing-box >"$WORK/initd.second"
# Copies of the script a crash left behind: one of a writer that is gone,
# one of a writer still at work (this shell).
sh -c 'exit 0' &
dead=$!
wait "$dead" || true
printf 'stale\n' >"/etc/init.d/sing-box.prokop.$dead"
printf 'in progress\n' >"/etc/init.d/sing-box.prokop.$$"
printf '#!/bin/sh\n# an older managed script\n' >/etc/init.d/sing-box
# The copy being installed is named after its writer, which lives until the
# rename: another start must find that writer alive and keep the copy. The
# flush before the rename (core/durable.uc) records in $OWNER whether the
# pid in the name of the copy is the writer (its command line names
# $WRITER).
mkdir -p "$WORK/sync-bin"
cat >"$WORK/sync-bin/sync" <<'SYNC'
#!/bin/sh
for copy in /etc/init.d/sing-box.prokop.*; do
  [ -f "$copy" ] && [ "$copy" != "/etc/init.d/sing-box.prokop.$LIVE" ] || continue
  pid="${copy##*.}"
  if grep -q "$WRITER" "/proc/$pid/cmdline" 2>/dev/null; then echo writer; else echo "not the writer: $pid"; fi >>"$OWNER"
done
SYNC
chmod 0755 "$WORK/sync-bin/sync"
(PATH="$WORK/sync-bin:$PATH" LIVE=$$ WRITER='runtime\.uc' OWNER="$WORK/initd.copy-owner" configure)
printf '%s\n' "$dead" >"$WORK/initd.dead"
printf '%s\n' "$$" >"$WORK/initd.live"
# A copy a crash left while the script itself is current (another writer
# installed it since) goes too.
sh -c 'exit 0' &
dead=$!
wait "$dead" || true
printf 'stale\n' >"/etc/init.d/sing-box.prokop.$dead"
configure
printf '%s\n' "$dead" >"$WORK/initd.dead2"
# The copy a component install (components/action.uc) writes is named after
# its writer as well. It writes the script a start writes (UC-085), which it
# leaves alone: the script in place is an older one again.
printf '#!/bin/sh\n# an older managed script\n' >/etc/init.d/sing-box
(PATH="$WORK/sync-bin:$PATH" LIVE=$$ WRITER='action\.uc' OWNER="$WORK/initd.action-owner" \
  ucode -L "$LIB" "$LIB/components/action.uc" install-managed-sing-box-service-fixture)
SH
  unshare -rm sh "$WORK/initd-check.sh" >"$WORK/initd.out" 2>&1 ||
    fail "configure-service failed: $(cat "$WORK/initd.out")"
  grep -q 'Prokop managed sing-box service' "$WORK/initd/sing-box" || fail "the managed init script was not installed"
  [ -x "$WORK/initd/sing-box" ] || fail "the managed init script is not executable"
  cmp -s "$WORK/initd.first" "$WORK/initd.second" ||
    fail "a second start rewrote the unchanged init script: $(cat "$WORK/initd.first") -> $(cat "$WORK/initd.second")"
  grep -q 'an older managed script' "$WORK/initd/sing-box" && fail "a start kept an init script that differs from the managed one"
  [ ! -e "$WORK/initd/sing-box.prokop.$(cat "$WORK/initd.dead")" ] || fail "a copy of a writer that is gone was left in /etc/init.d"
  [ ! -e "$WORK/initd/sing-box.prokop.$(cat "$WORK/initd.dead2")" ] ||
    fail "a copy of a writer that is gone was left in /etc/init.d next to a current script"
  [ -e "$WORK/initd/sing-box.prokop.$(cat "$WORK/initd.live")" ] || fail "a copy of a writer still at work was removed"
  [ "$(cat "$WORK/initd.copy-owner" 2>/dev/null)" = writer ] ||
    fail "the copy of the init script is not named after its writer: $(cat "$WORK/initd.copy-owner" 2>/dev/null)"
  [ "$(cat "$WORK/initd.action-owner" 2>/dev/null)" = writer ] ||
    fail "the copy a component install writes is not named after its writer: $(cat "$WORK/initd.action-owner" 2>/dev/null)"
  ok "the managed init script is written only when it changes, stale copies are removed"
fi

# ---- 2. the crontab ------------------------------------------------------------

CRONTAB="$WORK/crontabs/root"
mkdir -p "$WORK/crontabs"
export PROKOP_CRONTAB_FILE="$CRONTAB"
export PROKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK/run/component-update-checks"
export PROKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK/run/component-update-check.timestamp"
# BusyBox crontab <file>: installs the file and signals crond.
cat >"$WORK/bin/crontab" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$WORK/crontab.calls"
cp "$1" "$PROKOP_CRONTAB_FILE"
SH
chmod 0755 "$WORK/bin/crontab"
markers=('# prokop-list-update' '# prokop-subscription-update' '# prokop-component-update-check')
updates() { ucode -L "$LIB" "$LIB/components/updates.uc" "$@"; }
cron_calls() { [ -e "$WORK/crontab.calls" ] && wc -l <"$WORK/crontab.calls" || echo 0; }
printf '%s\n' 'prokop.settings.component_update_check_enabled=1' 'prokop.settings.component_update_check_interval=1d' >>"$WORK/uci.state"
printf '%s\n' '0 4 * * * /usr/local/bin/backup.sh' >"$CRONTAB"

updates refresh-cron-from-uci /usr/bin/prokop "${markers[@]}" || fail "the first cron refresh failed"
[ "$(cron_calls)" = 1 ] || fail "the first cron refresh did not install the crontab"
grep -Fq backup.sh "$CRONTAB" || fail "the cron refresh dropped a foreign job"
before="$(stamp "$CRONTAB")"
updates refresh-cron-from-uci /usr/bin/prokop "${markers[@]}" || fail "the second cron refresh failed"
[ "$(cron_calls)" = 1 ] || fail "a cron refresh that changes nothing installed the crontab again"
[ "$(stamp "$CRONTAB")" = "$before" ] || fail "a cron refresh that changes nothing rewrote the crontab"
updates remove-cron-jobs "${markers[@]}" || fail "the removal of the cron jobs failed"
[ "$(cron_calls)" = 2 ] || fail "the removal of the cron jobs did not install the crontab"
[ "$(cat "$CRONTAB")" = '0 4 * * * /usr/local/bin/backup.sh' ] || fail "the removal left other than the foreign job: $(cat "$CRONTAB")"
updates remove-cron-jobs "${markers[@]}" || fail "a second removal of the cron jobs failed"
[ "$(cron_calls)" = 2 ] || fail "a removal that changes nothing installed the crontab again"
ok "the crontab is installed only when Prokop's jobs change"

# A crontab that exists but cannot be read is not taken as empty.
mv "$CRONTAB" "$WORK/crontab.saved"
mkdir "$CRONTAB"
status=0
updates refresh-cron-from-uci /usr/bin/prokop "${markers[@]}" || status=$?
[ "$status" != 0 ] || fail "a cron refresh of an unreadable crontab reported success"
status=0
updates remove-cron-jobs "${markers[@]}" || status=$?
[ "$status" != 0 ] || fail "a removal of the cron jobs from an unreadable crontab reported success"
[ "$(cron_calls)" = 2 ] || fail "an unreadable crontab was replaced: $(tail -n 1 "$WORK/crontab.calls")"
rmdir "$CRONTAB"
mv "$WORK/crontab.saved" "$CRONTAB"
# A router without a crontab yet gets one.
rm -f "$CRONTAB"
updates refresh-cron-from-uci /usr/bin/prokop "${markers[@]}" || fail "a cron refresh without a crontab failed"
[ -s "$CRONTAB" ] || fail "a cron refresh without a crontab did not create it"
ok "an unreadable crontab fails the refresh and is never rewritten"

# A full /tmp takes the write of the new crontab and keeps none of it:
# handed to `crontab`, that empty file would erase every job on the router.
if ! unshare -rm true 2>/dev/null; then
  printf 'NOTE: no user and mount namespaces; the full /tmp crontab checks are skipped\n'
else
  mkdir -p "$WORK/full-tmp"
  printf '%s\n' '0 4 * * * /usr/local/bin/backup.sh' '0 5 * * * /usr/bin/prokop list_update # prokop-list-update' >"$CRONTAB"
  printf '%s\n' '0 4 * * * /usr/local/bin/backup.sh' '0 3 * * * /usr/bin/prokop autotune_if_due # prokop-autotune' >"$WORK/autotune-crontab"
  cp "$CRONTAB" "$WORK/crontab.before"
  cp "$WORK/autotune-crontab" "$WORK/autotune-crontab.before"
  # BusyBox crontab <file> for the autotune manager.
  cat >"$WORK/bin/autotune-crontab" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$WORK/autotune-crontab.calls"
cp "$1" "$WORK/autotune-crontab"
SH
  chmod 0755 "$WORK/bin/autotune-crontab"
  cat >"$WORK/full-tmp.sh" <<'SH'
mount -t tmpfs -o size=16k tmpfs "$WORK/full-tmp" || exit 90
dd if=/dev/zero of="$WORK/full-tmp/fill" bs=1k 2>/dev/null
export TMPDIR="$WORK/full-tmp"
updates() { ucode -L "$LIB" "$LIB/components/updates.uc" "$@"; }
updates remove-cron-jobs '# prokop-list-update' '# prokop-subscription-update' '# prokop-component-update-check'
printf '%s\n' "$?" >"$WORK/full-tmp.remove"
updates refresh-cron-from-uci /usr/bin/prokop '# prokop-list-update' '# prokop-subscription-update' '# prokop-component-update-check'
printf '%s\n' "$?" >"$WORK/full-tmp.refresh"
PROKOP_CRONTAB_FILE="$WORK/autotune-crontab" PROKOP_AUTOTUNE_CRONTAB="$WORK/bin/autotune-crontab" \
  PROKOP_AUTOTUNE_TMPDIR="$WORK/full-tmp" PROKOP_LIB="$LIB" \
  ucode -L "$LIB" "$LIB/autotune/manager.uc" cron-remove >"$WORK/full-tmp.autotune"
exit 0
SH
  unshare -rm sh "$WORK/full-tmp.sh" >"$WORK/full-tmp.out" 2>&1 || fail "the full /tmp crontab run failed: $(cat "$WORK/full-tmp.out")"
  [ "$(cat "$WORK/full-tmp.remove")" != 0 ] || fail "a removal of the cron jobs with a full /tmp reported success"
  [ "$(cat "$WORK/full-tmp.refresh")" != 0 ] || fail "a cron refresh with a full /tmp reported success"
  cmp -s "$CRONTAB" "$WORK/crontab.before" ||
    fail "a full /tmp changed the crontab: $(wc -c <"$CRONTAB") bytes: $(cat "$CRONTAB")"
  grep -q '"status": *"failed"' "$WORK/full-tmp.autotune" ||
    fail "an autotune cron removal with a full /tmp reported: $(cat "$WORK/full-tmp.autotune")"
  cmp -s "$WORK/autotune-crontab" "$WORK/autotune-crontab.before" ||
    fail "a full /tmp changed the crontab through autotune: $(wc -c <"$WORK/autotune-crontab") bytes"
  ok "a full /tmp fails the crontab rewrite and leaves the crontab whole"
fi

# ---- 3. the rule-set validation record ------------------------------------------

mkdir -p "$WORK/rs-bin" "$WORK/rs-cache"
printf '{"version":1,"rules":[{"domain_suffix":["example.test"]}]}\n' >"$WORK/rs-source.json"
printf 'mock-srs\n' >"$WORK/rs-source.srs"
cat >"$WORK/rs-bin/curl" <<'SH'
#!/bin/sh
output=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --proxy|--connect-timeout|--max-time) shift 2 ;;
    --fail|--location|--silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
cp "$WORK/rs-source.srs" "$output"
SH
cat >"$WORK/rs-bin/sing-box" <<'SH'
#!/bin/sh
[ "$1" = rule-set ] && [ "$2" = decompile ] && [ -f "$3" ] || exit 1
cp "$WORK/rs-source.json" "$5"
SH
chmod 0755 "$WORK/rs-bin/"*
cat >"$WORK/rs-config.json" <<'JSON'
{"route":{"rule_set":[{"type":"remote","tag":"binary","format":"binary","url":"https://example.test/rules.srs","update_interval":"1d"}]}}
JSON
ruleset_cache() {
  PATH="$WORK/rs-bin:$PATH" \
    PROKOP_RULESET_CACHE_DIR="$WORK/rs-cache" \
    PROKOP_RULESET_CACHE_MANIFEST="$WORK/rs-cache/manifest.json" \
    PROKOP_RULESET_RUNTIME_CACHE_DIR="$WORK/rs-runtime" \
    PROKOP_RULESET_RUNTIME_MANIFEST="$WORK/rs-runtime.json" \
    PROKOP_PERSISTENT_LIST_CACHE_DIR="$WORK/rs-lists" \
    ucode -L "$LIB" "$LIB/singbox/ruleset_cache.uc" "$@"
}
ruleset_cache materialize-config "$WORK/rs-config.json" >/dev/null 2>&1 || fail "the rule set was not materialized"
records=("$WORK"/rs-cache/*.validated)
[ -e "${records[0]}" ] || fail "the binary rule set has no validation record"
before="$(stamp "${records[0]}")"
ruleset_cache refresh >/dev/null 2>&1 || true
[ "$(stamp "${records[0]}")" = "$before" ] || fail "an unchanged rule-set refresh rewrote its validation record"
ok "an unchanged rule-set refresh leaves its validation record alone"

# ---- 4. a partial copy of the persistent subscription cache ----------------------

if ! unshare -rm true 2>/dev/null; then
  printf 'NOTE: no user and mount namespaces; the full-overlay subscription check is skipped\n'
else
  mkdir -p "$WORK/sub-persistent" "$WORK/sub-run"
  {
    printf '{"outbounds":['
    for i in $(seq 1 3000); do
      [ "$i" = 1 ] || printf ','
      printf '{"type":"direct","tag":"node-%s"}' "$i"
    done
    printf ']}\n'
  } >"$WORK/sub.json"
  # shellcheck disable=SC2016 # expanded by the sh that runs it
  unshare -rm sh -c '
    mount -t tmpfs -o size=16k tmpfs "$WORK/sub-persistent" || exit 90
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/sub-persistent" \
      PROKOP_RUNTIME_STATE_DIR="$WORK/sub-run" \
      TMP_SING_BOX_FOLDER="$WORK/sub-run/tmp-sing-box" \
      ucode -L "$LIB" "$LIB/subscription/cache.uc" persist-source-cache \
      proxy-1 "$WORK/sub.json" https://example.com/sub v2rayN "" >/dev/null 2>&1
    status=$?
    ls -A "$WORK/sub-persistent" >"$WORK/sub.list"
    exit "$status"
  ' && fail "persisting a subscription on a full overlay reported success" || status=$?
  [ "$status" != 90 ] || fail "could not mount the test filesystem"
  grep -q '\.tmp$' "$WORK/sub.list" && fail "a failed write left a partial copy in the persistent subscription cache: $(cat "$WORK/sub.list")"

  # A small subscription is taken by the write and lost at the close,
  # unreported: the cached copy an offline start falls back on must not be
  # replaced by an empty file.
  mkdir -p "$WORK/sub-small"
  printf '{"outbounds":[{"type":"direct","tag":"node-a"}]}\n' >"$WORK/sub-a.json"
  printf '{"outbounds":[{"type":"direct","tag":"node-b"}]}\n' >"$WORK/sub-b.json"
  # shellcheck disable=SC2016 # expanded by the sh that runs it
  unshare -rm sh -c '
    mount -t tmpfs -o size=64k tmpfs "$WORK/sub-small" || exit 90
    persist() {
      PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/sub-small" \
        PROKOP_RUNTIME_STATE_DIR="$WORK/sub-run" \
        TMP_SING_BOX_FOLDER="$WORK/sub-run/tmp-sing-box" \
        ucode -L "$LIB" "$LIB/subscription/cache.uc" persist-source-cache \
        proxy-1 "$1" https://example.com/sub v2rayN "" >/dev/null 2>&1
    }
    persist "$WORK/sub-a.json" || exit 91
    cp "$WORK/sub-small/proxy-1.json" "$WORK/sub-small.before" || exit 92
    dd if=/dev/zero of="$WORK/sub-small/fill" bs=1k 2>/dev/null
    persist "$WORK/sub-b.json"
    status=$?
    cp "$WORK/sub-small/proxy-1.json" "$WORK/sub-small.after"
    ls -A "$WORK/sub-small" >"$WORK/sub-small.list"
    exit "$status"
  ' && fail "persisting a small subscription on a full overlay reported success" || status=$?
  [ "$status" != 90 ] || fail "could not mount the test filesystem"
  [ "$status" != 91 ] || fail "could not persist a subscription before the overlay filled up"
  [ "$status" != 92 ] || fail "the persistent subscription cache has no proxy-1.json: $(cat "$WORK/sub-small.list" 2>/dev/null)"
  cmp -s "$WORK/sub-small.before" "$WORK/sub-small.after" ||
    fail "a full overlay replaced the cached subscription ($(wc -c <"$WORK/sub-small.after") bytes left)"
  grep -q '\.tmp$' "$WORK/sub-small.list" && fail "a failed write left a partial copy in the persistent subscription cache: $(cat "$WORK/sub-small.list")"
  ok "a failed write leaves no partial copy in the persistent subscription cache, and keeps the cached one"
fi

# ---- 5. a partial copy of a generated section cache ------------------------------

if unshare -rm true 2>/dev/null; then
  # A section cache larger than the write buffer fails at the write; a
  # smaller one is taken by the write and lost at the close, unreported.
  for count in 300 2; do
    python3 - "$WORK/gen-fixture.json" "$count" <<'PY2'
import json
import sys
outbounds = [json.dumps({"type": "http", "tag": "node%d" % i, "server": "proxy%d.example" % i, "server_port": 8080})
             for i in range(int(sys.argv[2]))]
fixture = {"settings": {".name": "settings", ".type": "settings", "dns_server": "77.88.8.8"},
           "section": [{".name": "main", ".type": "section", "enabled": "1", "action": "connection",
                        "outbound_jsons": outbounds, "domain_suffix": ["example.com"]}]}
open(sys.argv[1], "w").write(json.dumps(fixture))
PY2
    rm -rf "$WORK/gen.json" "$WORK/gen.json.section-cache" "$WORK/gen.json.rulesets"
    mkdir -p "$WORK/gen.json.section-cache" "$WORK/gen.json.rulesets"
    # shellcheck disable=SC2016 # expanded by the sh that runs it
    unshare -rm sh -c '
      mount -t tmpfs -o size=16k tmpfs "$WORK/gen.json.section-cache" || exit 90
      dd if=/dev/zero of="$WORK/gen.json.section-cache/fill" bs=1k 2>/dev/null || true
      ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
        "$WORK/gen-fixture.json" "$WORK/gen.json" 192.0.2.1 0 1 "" 1.12.0 >/dev/null 2>&1
      status=$?
      ls -A "$WORK/gen.json.section-cache" >"$WORK/gen.list"
      exit "$status"
    ' && fail "generating with a full section cache reported success ($count outbounds)" || status=$?
    [ "$status" != 90 ] || fail "could not mount the test filesystem"
    grep -q '\.tmp$' "$WORK/gen.list" && fail "a failed write left a partial section cache: $(cat "$WORK/gen.list")"
  done
  ok "a failed write leaves no partial generated section cache"
fi

printf 'flash write hygiene checks passed\n'
