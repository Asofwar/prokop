#!/usr/bin/env bash
set -euo pipefail

# The persistent rule-set cache manifest (/etc/prokop/ruleset-cache, flash)
# is written by every sing-box config materialization: each start and each
# reload. It used to be replaced even when it already held the same text, a
# flash write per start and reload with nothing changed (the S5 flash-write
# audit: an unchanged reload rewrote it every time, also with no remote rule
# set at all). Now an identical manifest stays as it is, a changed one is
# still replaced, and the replacement is read back before the rename, so a
# full overlay that keeps none of a small write cannot leave an empty
# manifest in its place (UC-241).
#
# The full-overlay check needs user and mount namespaces (unshare -rm) and
# is skipped without them.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
RULESET_CACHE_UC="$LIB/singbox/ruleset_cache.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }
stamp() { stat -c '%i %Y.%y %s' "$1"; }

CACHE="$WORK/cache"
MANIFEST="$CACHE/manifest.json"
mkdir -p "$WORK/bin" "$CACHE"
export LIB RULESET_CACHE_UC WORK
export PROKOP_RULESET_CACHE_DIR="$CACHE"
export PROKOP_RULESET_CACHE_MANIFEST="$MANIFEST"
export PROKOP_RULESET_RUNTIME_CACHE_DIR="$WORK/runtime-cache"
export PROKOP_RULESET_RUNTIME_MANIFEST="$WORK/runtime-manifest.json"
export PROKOP_PERSISTENT_LIST_CACHE_DIR="$WORK/list-cache"
export PROKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=0

printf '{"version":1,"rules":[{"domain_suffix":["example.test"]}]}\n' >"$WORK/source.json"
# A download writes the source list; nothing else is fetched here.
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --proxy|--connect-timeout|--max-time) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output" ] && cp "$WORK/source.json" "$output"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod 0755 "$WORK/bin/curl" "$WORK/bin/logger"
export PATH="$WORK/bin:$PATH"

remote_config() {
  cat >"$WORK/config.json" <<'EOF'
{"route":{"rule_set":[
  {"type":"remote","tag":"source","format":"source","url":"https://example.test/rules.json","update_interval":"1d"}
]}}
EOF
}
plain_config() {
  printf '{"route":{"rule_set":[]}}\n' >"$WORK/config.json"
}
materialize() {
  ucode -L "$LIB" "$RULESET_CACHE_UC" materialize-config "$WORK/config.json" "$@" >/dev/null 2>&1
}

# ---- 1. no remote rule set: the empty manifest is written once -----------------

plain_config
materialize || fail "the first materialization failed"
[ -f "$MANIFEST" ] || fail "the first materialization wrote no manifest"
first="$(stamp "$MANIFEST")"
sleep 1.1
plain_config
materialize || fail "the second materialization failed"
[ "$(stamp "$MANIFEST")" = "$first" ] ||
  fail "an unchanged materialization without remote rule sets rewrote the manifest ($first -> $(stamp "$MANIFEST"))"
ok "an unchanged empty manifest is not rewritten"

# ---- 2. a remote rule set: unchanged stays, a new entry replaces ------------------

remote_config
materialize || fail "the materialization with a remote rule set failed"
grep -q 'example.test/rules.json' "$MANIFEST" || fail "the remote rule set is missing from the manifest"
second="$(stamp "$MANIFEST")"
[ "$second" != "$first" ] || fail "a changed manifest was not replaced"
sleep 1.1
remote_config
materialize || fail "the repeated materialization failed"
[ "$(stamp "$MANIFEST")" = "$second" ] ||
  fail "an unchanged materialization rewrote the manifest of a cached remote rule set"
remote_config
materialize cache-only || fail "the cache-only materialization failed"
[ "$(stamp "$MANIFEST")" = "$second" ] ||
  fail "an unchanged cache-only materialization (a reload) rewrote the manifest"
ok "an unchanged manifest of a remote rule set is not rewritten; a changed one is"
find "$CACHE" -name 'manifest.json.*.tmp' | grep -q . && fail "a temporary manifest was left behind"

# ---- 3. full overlay: the manifest is not replaced by an empty file ----------------

if ! unshare -rm true 2>/dev/null; then
  printf 'NOTE: no user and mount namespaces; the full-overlay check is skipped\n'
else
  before="$(cat "$MANIFEST")"
  plain_config
  status=0
  # An 8 KiB tmpfs holds the directory and the manifest, then a filler takes
  # the last block: a small write is then "written" and lost. The free-space
  # check is told there is room, as when another writer fills the overlay
  # between that check and the write.
  # shellcheck disable=SC2016 # expanded by the inner shell
  PROKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=100000000 unshare -rm sh -c '
    set -e
    mkdir -p "$WORK/full"
    mount -t tmpfs -o size=8k tmpfs "$WORK/full"
    cp -a "$PROKOP_RULESET_CACHE_DIR/." "$WORK/full/"
    mount --bind "$WORK/full" "$PROKOP_RULESET_CACHE_DIR"
    dd if=/dev/zero of="$PROKOP_RULESET_CACHE_DIR/filler" bs=1k count=64 2>/dev/null || true
    ucode -L "$LIB" "$RULESET_CACHE_UC" materialize-config "$WORK/config.json" cache-only >/dev/null 2>&1 || exit 3
    cat "$PROKOP_RULESET_CACHE_MANIFEST" >"$WORK/after"
    ls -a "$PROKOP_RULESET_CACHE_DIR" >"$WORK/listing"
  ' || status=$?
  [ "$status" = 0 ] || [ "$status" = 3 ] || fail "the full-overlay fixture failed ($status)"
  [ -s "$WORK/after" ] || fail "a full overlay left an empty manifest in place of the previous one"
  [ "$(cat "$WORK/after")" = "$before" ] || [ "$(cat "$WORK/after")" = '{ }' ] ||
    fail "a full overlay left a manifest that is neither the previous one nor the new one"
  if grep -q 'manifest.json\..*\.tmp' "$WORK/listing"; then
    fail "a full overlay left a temporary manifest behind"
  fi
  ok "a full overlay keeps a whole manifest"
fi

printf 'rule-set manifest flash write checks passed\n'
