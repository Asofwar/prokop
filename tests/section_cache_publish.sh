#!/usr/bin/env bash
set -euo pipefail

# The section caches of a generation are published as one set, together
# with its config.json (singbox/runtime.uc publish_section_cache).
#
# 1. A publish that failed on one file left the files before it new and the
#    rest old: a mixed set the dashboard, Priority and DNS failover read.
# 2. The caches of sections the new generation no longer has were never
#    removed: service/lifecycle.uc priority_group_selectors reads every
#    *.json and saw Priority groups of a removed rule.
# 3. A failed reload rolled back with restore-config-stage got the previous
#    config.json back but kept the rejected generation's section caches.
#
# singbox/runtime.uc runs for real; only the stage is made by hand.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; [ ! -s "$W/logger.log" ] || sed 's/^/  log: /' "$W/logger.log" >&2; exit 1; }

mkdir -p "$W/bin" "$W/run" "$W/tmp"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/logger.log"\n' "$W" >"$W/bin/logger"
chmod +x "$W/bin/"*
cat >"$W/uci.state" <<UCI
prokop.settings=settings
prokop.settings.config_path=$W/config.json
UCI
E() {
  env PATH="$W/bin:$PATH" PROKOP_LIB="$LIB" PROKOP_UCI_STATE_FILE="$W/uci.state" PROKOP_RUNTIME_STATE_DIR="$W/run" \
    TMP_SING_BOX_FOLDER="$W/tmp" TMPDIR="$W/tmp" "$@"
}
runtime() { E ucode -L "$LIB" "$LIB/singbox/runtime.uc" "$@"; }
live="$W/run/section-cache"

# The running generation: rules a, b and gone (gone has a Priority group).
old_generation() {
  rm -rf "$live" "$W"/run/section-cache.* "$W"/backup*
  mkdir -p "$live"
  printf '{"gen":"old","name":"a"}\n' >"$live/a.json"
  printf '{"gen":"old","name":"b"}\n' >"$live/b.json"
  printf '{"gen":"old","priorityGroups":{"gone-priority":{"probe_tag":"gone-probe"}}}\n' >"$live/gone.json"
  printf '{"config":"old"}\n' >"$W/config.json"
}
# The candidate: rules a and b only.
new_stage() {
  rm -rf "$1" "$1.section-cache"
  mkdir -p "$1.section-cache"
  printf '{"config":"new"}\n' >"$1"
  printf '{"gen":"new","name":"a"}\n' >"$1.section-cache/a.json"
  printf '{"gen":"new","name":"b"}\n' >"$1.section-cache/b.json"
}
set_of() {
  local dir="$1" out="" f
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    out="$out $(basename "$f"):$(ucode -e 'print(json(require("fs").readfile(ARGV[0])).gen)' -- "$f")"
  done
  printf '%s\n' "${out# }"
}

# 1. A publish that cannot write b.json leaves the whole old set (or, when
#    the new set does not go through the live directory file by file, the
#    whole new one), never a mix.
old_generation
new_stage "$W/stage.json"
mkdir "$live/b.json.tmp"
runtime commit-config-stage "$W/stage.json" "$W/backup.json" >/dev/null 2>&1 || true
set="$(set_of "$live")"
case "$set" in
  "a.json:old b.json:old gone.json:old"|"a.json:new b.json:new") ;;
  *) fail "a failed publish left a mixed section-cache set: $set" ;;
esac
# The injected failure of the new set's build or swap keeps the old set,
# and the stage stays for another try.
for phase in section-cache-build section-cache-swap; do
  old_generation
  new_stage "$W/stage.json"
  if PROKOP_SINGBOX_CONFIG_FAIL_PHASE="$phase" runtime commit-config-stage "$W/stage.json" "$W/backup.json" >/dev/null 2>&1; then
    fail "the injected $phase failure did not fail the commit"
  fi
  [ "$(set_of "$live")" = "a.json:old b.json:old gone.json:old" ] ||
    fail "a $phase failure changed the running set: $(set_of "$live")"
  [ -s "$W/stage.json.section-cache/a.json" ] || fail "a $phase failure consumed the stage's section caches"
  [ -z "$(find "$W/run" -maxdepth 1 -name 'section-cache.*' -print -quit)" ] ||
    fail "a $phase failure left a half-built set: $(ls -a "$W/run")"
  # What the caller does then: config.json is published already, the
  # rollback restores both.
  if [ -e "$W/backup.json" ]; then
    runtime restore-config-stage "$W/backup.json" || fail "the rollback after a $phase failure failed"
    grep -q old "$W/config.json" || fail "the rollback after a $phase failure did not restore config.json"
    [ "$(set_of "$live")" = "a.json:old b.json:old gone.json:old" ] ||
      fail "the rollback after a $phase failure changed the running set: $(set_of "$live")"
  fi
done

# 2. A committed generation is exactly the stage's set: the removed rule's
#    cache is gone, and with it its Priority group.
old_generation
new_stage "$W/stage.json"
runtime commit-config-stage "$W/stage.json" "$W/backup.json" || fail "the stage was not committed"
grep -q new "$W/config.json" || fail "the commit did not publish config.json"
[ "$(set_of "$live")" = "a.json:new b.json:new" ] || fail "the committed set is not the stage's: $(set_of "$live")"
[ "$(stat -c %a "$live")" = 700 ] || fail "the section-cache directory is not private: $(stat -c %a "$live")"
[ "$(stat -c %a "$live/a.json")" = 600 ] || fail "a section cache is not private: $(stat -c %a "$live/a.json")"
[ ! -e "$W/stage.json.section-cache" ] || fail "the published section caches stayed next to the stage"
selectors="$(E PROKOP_SECTION_CACHE_DIR="$live" ucode -e '
  let fs = require("fs"); let tags = {};
  for (let p in (fs.glob(ARGV[0] + "/*.json") || []))
    for (let t, g in (json(fs.readfile(p)).priorityGroups || {})) tags[t] = true;
  print(join(" ", sort(keys(tags))));' -- "$live")"
[ -z "$selectors" ] || fail "the removed rule's Priority group is still read: $selectors"

# 3. The rollback of that commit brings back config.json and its set; the
#    backup is consumed.
runtime restore-config-stage "$W/backup.json" || fail "restore-config-stage failed"
grep -q old "$W/config.json" || fail "the rollback did not restore config.json"
[ "$(set_of "$live")" = "a.json:old b.json:old gone.json:old" ] ||
  fail "the rollback kept the rejected generation's section caches: $(set_of "$live")"
[ ! -e "$W/backup.json.section-cache" ] || fail "the restored section-cache backup stayed"

# 4. A successful transaction drops the backup and its set.
old_generation
new_stage "$W/stage.json"
runtime commit-config-stage "$W/stage.json" "$W/backup.json" || fail "the second stage was not committed"
runtime discard-config-backup "$W/backup.json" || fail "discard-config-backup failed"
[ ! -e "$W/backup.json" ] && [ ! -e "$W/backup.json.section-cache" ] || fail "the discarded backup stayed"
[ "$(set_of "$live")" = "a.json:new b.json:new" ] || fail "discarding the backup changed the running set"

# 5. The first start (no running set yet) and a generation with no section
#    caches at all: the rollback of the first leaves no set, the second
#    empties the running set.
rm -rf "$live" "$W"/backup*
printf '{"config":"old"}\n' >"$W/config.json"
new_stage "$W/stage.json"
runtime commit-config-stage "$W/stage.json" "$W/backup.json" || fail "the first set was not committed"
[ "$(set_of "$live")" = "a.json:new b.json:new" ] || fail "the first set was not published: $(set_of "$live")"
runtime restore-config-stage "$W/backup.json" || fail "the rollback of the first set failed"
[ -z "$(set_of "$live")" ] || fail "the rollback of the first set kept it: $(set_of "$live")"
old_generation
printf '{"config":"new"}\n' >"$W/stage.json"
rm -rf "$W/stage.json.section-cache"
runtime commit-config-stage "$W/stage.json" "$W/backup.json" || fail "a stage without section caches was not committed"
[ -z "$(set_of "$live")" ] || fail "a generation without section caches kept the old ones: $(set_of "$live")"
runtime discard-config-backup "$W/backup.json"

# 6. The start path (init_config publishes without a backup): exactly the
#    new set, no backup left anywhere.
old_generation
new_stage "$W/gen.json"
# A publish killed half-way left its directories (pid 999999 is gone).
mkdir -p "$live.new.999999" "$live.old.999999"
runtime publish-section-cache-fixture "$W/gen.json" || fail "the start publish failed"
[ "$(set_of "$live")" = "a.json:new b.json:new" ] || fail "the start publish kept stale caches: $(set_of "$live")"
[ -z "$(find "$W/run" -maxdepth 1 -name 'section-cache.*' -print -quit)" ] ||
  fail "the start publish left a previous set: $(ls -a "$W/run")"

printf 'section_cache_publish: OK\n'
