#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
printf '192.0.2.1\n'
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
printf 'download\n' >>"$CASE_DIR/network.log"
[ "$FAIL_PHASE" != download ] || exit 1
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'new.example\n' >"$output"
SH
cat >"$WORK_DIR/bin/cp" <<'SH'
#!/bin/sh
if [ "$FAIL_PHASE" = ruleset ] && [ "$1" = -R ] && [ "$2" = -p ]; then
  printf 'snapshot refused\n' >>"$CASE_DIR/copy.log"
  exit 1
fi
exec /bin/cp "$@"
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CASE_DIR/nft.log"
if [ "$*" = '-j list table inet prokop' ]; then
  [ "$FAIL_PHASE" != nft ] || exit 1
  printf '{"nftables":[]}\n'
  exit 0
fi
# None of these aborted transactions is allowed to mutate nftables.
exit 1
SH
cat >"$WORK_DIR/bin/init-prokop" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CASE_DIR/reload.log"
SH
chmod +x "$WORK_DIR/bin/"*

for phase in download ruleset nft; do
  case_dir="$WORK_DIR/$phase"
  mkdir -p "$case_dir/rulesets" "$case_dir/run" "$case_dir/cache"
  printf '{"version":3,"rules":[{"domain_suffix":["old.example"]}]}\n' >"$case_dir/rulesets/alpha-remote-domains-ruleset.json"
  cp "$case_dir/rulesets/alpha-remote-domains-ruleset.json" "$case_dir/before.json"
  printf 'previous cache\n' >"$case_dir/cache/marker"
  printf '1\n' >"$case_dir/run/list-update.reload"
  printf 'force\n' >"$case_dir/run/ruleset-refresh-after-list"
  cat >"$case_dir/uci.state" <<'UCI'
prokop.settings=settings
prokop.settings.update_interval=1d
prokop.alpha=section
prokop.alpha.enabled=1
prokop.alpha.action=connection
prokop.alpha.remote_domain_lists=https://lists.test/domains.txt
UCI
  status=0
  generation_fail_phase=""
  [ "$phase" != nft ] || generation_fail_phase=nft-candidate-create
  env PATH="$WORK_DIR/bin:$PATH" \
    PROKOP_LIST_GENERATION_FAIL_PHASE="$generation_fail_phase" \
    PROKOP_RUNTIME_LIST_GENERATION_DIR="$case_dir/generation" \
    PROKOP_RULESET_CACHE_DIR="$case_dir/ruleset-cache" \
    CASE_DIR="$case_dir" FAIL_PHASE="$phase" \
    PROKOP_LIB="$PROKOP_LIB" \
    PROKOP_UCI_STATE_FILE="$case_dir/uci.state" \
    TMP_RULESET_FOLDER="$case_dir/rulesets" \
    PROKOP_RUNTIME_STATE_DIR="$case_dir/run" \
    PROKOP_RELOAD_LOCK_DIR="$case_dir/run/reload.lock" \
    PROKOP_LIST_UPDATE_PID_FILE="$case_dir/run/list.pid" \
    PROKOP_PERSISTENT_LIST_CACHE_DIR="$case_dir/cache" \
    PROKOP_SERVICE_INIT="$WORK_DIR/bin/init-prokop" \
    NFT_TABLE_NAME=prokop \
    ucode -L "$PROKOP_LIB" "$PROKOP_LIB/components/updates.uc" list-update >"$case_dir/output.log" 2>&1 || status="$?"
  [ "$status" -eq 1 ] || fail "$phase failure must abort the update"
  [ -s "$case_dir/network.log" ] || fail "$phase did not reach source download"
  cmp "$case_dir/before.json" "$case_dir/rulesets/alpha-remote-domains-ruleset.json" || fail "$phase changed active rules"
  [ "$(cat "$case_dir/cache/marker")" = 'previous cache' ] || fail "$phase replaced persistent cache"
  [ -s "$case_dir/run/list-update.reload" ] || fail "$phase lost deferred reload"
  [ -s "$case_dir/run/ruleset-refresh-after-list" ] || fail "$phase lost deferred rule-set refresh"
  [ ! -s "$case_dir/reload.log" ] || fail "$phase reloaded an incomplete generation"
  [ ! -e "$case_dir/run/list.pid" ] || fail "$phase leaked the worker PID file"
  if [ "$phase" = ruleset ]; then
    [ -s "$case_dir/copy.log" ] || fail "snapshot failure was not exercised"
  fi
  [ ! -s "$case_dir/nft.log" ] || fail "$phase preparation failure reached live nftables"
done

printf 'list transaction failure checks passed\n'
