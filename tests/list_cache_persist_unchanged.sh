#!/usr/bin/env bash
# The persistent list cache lives on flash (/etc/prokop/list-cache, up to
# 8 MiB). A successful list update whose lists did not change must not copy
# it again: the cached files, their manifest and the directory stay as they
# are, only the success time moves on (UC-072). Changed lists still replace
# the whole generation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
UPDATES_UC="$LIB/components/updates.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export TMP_SING_BOX_FOLDER="$WORK/tmp-sing-box"
CACHE="$WORK/cache"
mkdir -p "$WORK/runtime-rulesets" "$WORK/bin"
cat >"$WORK/uci.state" <<'EOF_UCI'
prokop.settings=settings
prokop.settings.update_interval=1d
prokop.alpha=section
prokop.alpha.enabled=1
prokop.alpha.action=connection
prokop.alpha.remote_domain_lists=https://lists.test/domains.txt
EOF_UCI
printf '{"version":3,"rules":[{"domain_suffix":["first.example"]}]}\n' >"$WORK/runtime-rulesets/alpha-lists-ruleset.json"
cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$LIST_CACHE_LOG"
SH
export LIST_CACHE_LOG="$WORK/cache.log"
chmod +x "$WORK/bin/logger"

cache_cmd() {
  PATH="$WORK/bin:$PATH" \
  PROKOP_UCI_STATE_FILE="$WORK/uci.state" \
  PROKOP_PERSISTENT_LIST_CACHE_DIR="$CACHE" \
  PROKOP_PERSISTENT_LIST_CACHE_MANIFEST="$CACHE/manifest.json" \
  PROKOP_LIST_UPDATE_STATE_FILE="$CACHE/last-success.timestamp" \
  PROKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 \
  PROKOP_RULESET_CACHE_DIR="$WORK/ruleset-cache" \
  PROKOP_RUNTIME_LIST_GENERATION_DIR="$WORK/runtime-generation" \
  PROKOP_RUNTIME_STATE_DIR="$WORK/run" \
  PROKOP_LIST_UPDATE_RUNTIME_STATE_FILE="$WORK/run/list-update-last-success.timestamp" \
  PROKOP_LIST_UPDATE_RUNTIME_SIGNATURE_FILE="$WORK/run/list-update-signature" \
  PROKOP_LIST_CACHE_LOG_STATE_FILE="$WORK/run/list-cache-restore.log-state" \
  TMP_RULESET_FOLDER="$WORK/runtime-rulesets" \
  PROKOP_LIB="$LIB" \
    ucode -L "$LIB" "$UPDATES_UC" "$@"
}
# identity PATH...: inode, change and modification time of each path. The
# directory itself only keeps its inode: the new success time is a new entry.
identity() { stat -c '%n %i %z %y' "$@"; }

cache_cmd commit-runtime-list-generation || fail "the runtime generation was not committed"
cache_cmd persist-list-cache 100 || fail "the first persistent cache was not written"
cache_cmd list-cache-valid || fail "the first persistent cache is not valid"
[ "$(cat "$CACHE/last-success.timestamp")" = 100 ] || fail "the first success time was not stored"
before="$(stat -c %i "$CACHE") $(identity "$CACHE/manifest.json" "$CACHE/alpha-lists-ruleset.json")"
manifest_before="$(cat "$CACHE/manifest.json")"

# The same lists again: the list update commits the unchanged runtime
# generation and persists it.
sleep 1.1
cache_cmd commit-runtime-list-generation || fail "the unchanged runtime generation was rejected"
cache_cmd persist-list-cache 200 || fail "persisting unchanged lists failed"
after="$(stat -c %i "$CACHE") $(identity "$CACHE/manifest.json" "$CACHE/alpha-lists-ruleset.json")"
[ "$before" = "$after" ] || fail "unchanged lists were written to flash again:
before: $before
after:  $after"
[ "$manifest_before" = "$(cat "$CACHE/manifest.json")" ] || fail "unchanged lists got a new manifest"
[ "$(cat "$CACHE/last-success.timestamp")" = 200 ] || fail "the success time of unchanged lists was not updated"
for leftover in "$CACHE.stage" "$CACHE.previous" "$CACHE"/*.tmp; do
  [ ! -e "$leftover" ] || fail "persisting unchanged lists left ${leftover##*/}"
done
cache_cmd list-cache-valid || fail "the persistent cache is not valid after the success time update"
cache_cmd restore-list-cache || fail "the persistent cache is not restorable after the success time update"

# The runtime generation of this boot holds the same lists under another
# generation identity (it was published again): the persistent cache is not
# older, so a reload does not report the lists as RAM-only.
mkdir -p "$WORK/run"
printf '200\n' >"$WORK/run/list-update-last-success.timestamp"
PROKOP_UCI_STATE_FILE="$WORK/uci.state" ucode -L "$LIB" "$LIB/service/state.uc" list-update-signature \
  >"$WORK/run/list-update-signature"
sed -i 's/"generation": *"[^"]*"/"generation":"gen-republished"/' "$WORK/runtime-generation/manifest.json"
grep -q gen-republished "$WORK/runtime-generation/manifest.json" || fail "the fixture did not rename the runtime generation"
: >"$LIST_CACHE_LOG"
cache_cmd restore-list-cache || fail "the runtime generation was not kept"
! grep -q 'RAM-only' "$LIST_CACHE_LOG" || fail "unchanged lists were reported as RAM-only: $(cat "$LIST_CACHE_LOG")"

# A damaged cache with the same manifest is not "unchanged": it is replaced.
printf '{"version":3,"rules":[{"domain_suffix":["damaged.example"]}]}\n' >"$CACHE/alpha-lists-ruleset.json"
cache_cmd persist-list-cache 300 || fail "a damaged persistent cache was not replaced"
cache_cmd list-cache-valid || fail "the replaced persistent cache is not valid"
grep -q 'first.example' "$CACHE/alpha-lists-ruleset.json" || fail "the damaged list stayed in the persistent cache"

# Changed lists replace the generation.
before="$(identity "$CACHE/alpha-lists-ruleset.json")"
printf '{"version":3,"rules":[{"domain_suffix":["second.example"]}]}\n' >"$WORK/runtime-rulesets/alpha-lists-ruleset.json"
cache_cmd commit-runtime-list-generation || fail "the changed runtime generation was not committed"
cache_cmd persist-list-cache 400 || fail "changed lists were not persisted"
grep -q 'second.example' "$CACHE/alpha-lists-ruleset.json" || fail "changed lists did not reach the persistent cache"
[ "$before" != "$(identity "$CACHE/alpha-lists-ruleset.json")" ] || fail "changed lists kept the old file"
[ "$(cat "$CACHE/last-success.timestamp")" = 400 ] || fail "the success time of changed lists was not stored"
cache_cmd list-cache-valid || fail "the changed persistent cache is not valid"

printf 'list_cache_persist_unchanged: PASS\n'
