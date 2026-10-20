#!/usr/bin/env bash
set -eo pipefail

# A scheduled subscription update whose servers changed only their names
# (panels write traffic or days left into every name) keeps the applied
# list: no sing-box reload drops the proxied connections for that. A manual
# update applies the names, and a scheduled one any real change.
#
# subscription/cache.uc runs for real; curl is a stub that answers with one
# VLESS link whose name and port come from files.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
CACHE_UC="$PROKOP_LIB/subscription/cache.uc"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { out="$2"; shift; }
  shift
done
printf 'vless://11111111-1111-1111-1111-111111111111@192.0.2.10:%s?security=none&type=tcp#%s\n' \
  "$(cat "$NODE_PORT_FILE")" "$(cat "$NODE_NAME_FILE")" >"$out"
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/"*

export PATH="$WORK_DIR/bin:$PATH"
export NODE_NAME_FILE="$WORK_DIR/name" NODE_PORT_FILE="$WORK_DIR/port"
export TMP_SING_BOX_FOLDER="$WORK_DIR/sing-box"
export TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/sing-box/subscriptions"
export PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_SUBSCRIPTION_METADATA_DIR="$WORK_DIR/run/subscription-metadata"
export PROKOP_OUTBOUND_METADATA_DIR="$WORK_DIR/run/outbound-metadata"
export PROKOP_SECTION_CACHE_DIR="$WORK_DIR/run/section-cache"
export PROKOP_SUBSCRIPTION_LINKS_DIR="$WORK_DIR/run/subscription-links"
export PROKOP_SUBSCRIPTION_UPDATE_STATE_DIR="$WORK_DIR/run/subscription-update"
export PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export PROKOP_LIB

{
  printf 'prokop.settings=settings\n'
  printf 'prokop.vpn=section\nprokop.vpn.enabled=1\nprokop.vpn.action=connection\nprokop.vpn.proxy_config_type=subscription\n'
  printf 'prokop.s1=subscription_url\nprokop.s1.section=vpn\nprokop.s1.url=https://sub.example/api/sub\n'
  printf 'prokop.s1.subscription_update_interval=1m\n'
} >"$WORK_DIR/uci.state"

cache() { ucode -L "$PROKOP_LIB" "$CACHE_UC" "$@"; }
# request FORCE: "updated failed unchanged superseded" of an update request;
# a scheduled one (0) is made due by forgetting its last run.
request() {
  rm -f "$PROKOP_SUBSCRIPTION_UPDATE_STATE_DIR/vpn.timestamp"
  cache update-request "$1" 2>"$WORK_DIR/request.err" | tail -n 1 | tr "\t" " "
}
applied_name() {
  node -e '
    const fs = require("fs"), path = require("path");
    const dir = process.argv[1];
    const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json") && !f.includes("metadata"));
    for (const f of files) {
      const v = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
      if (Array.isArray(v.outbounds) && v.outbounds.length) { process.stdout.write(v.outbounds[0].tag); process.exit(0); }
    }
    process.exit(1);' "$TMP_SUBSCRIPTION_FOLDER"
}

printf 'Node 10 GB left' >"$NODE_NAME_FILE"
printf 443 >"$NODE_PORT_FILE"
cache update-source vpn 1 https://sub.example/api/sub >"$WORK_DIR/first.log" 2>&1 ||
  fail "the first update failed: $(cat "$WORK_DIR/first.log")"
[ "$(applied_name)" = "Node 10 GB left" ] || fail "the first update applied '$(applied_name)'"

# 1. Scheduled, names only: unchanged, the applied name stays.
printf 'Node 9 GB left' >"$NODE_NAME_FILE"
result="$(request 0)"
[ "${result%% *}" = 0 ] || fail "a scheduled update of new names only counted as updated: '$result' $(cat "$WORK_DIR/request.err")"
[ "$(applied_name)" = "Node 10 GB left" ] || fail "a scheduled update applied new names only: $(applied_name)"

# 2. Manual: the names are applied.
result="$(request 1)"
[ "${result%% *}" = 1 ] || fail "a manual update of new names was not applied: '$result'"
[ "$(applied_name)" = "Node 9 GB left" ] || fail "a manual update did not apply the name: $(applied_name)"

# 3. Scheduled, a real change: applied with its names.
printf 'Node 8 GB left' >"$NODE_NAME_FILE"
printf 8443 >"$NODE_PORT_FILE"
result="$(request 0)"
[ "${result%% *}" = 1 ] || fail "a scheduled update of a changed server was not applied: '$result' $(cat "$WORK_DIR/request.err")"
[ "$(applied_name)" = "Node 8 GB left" ] || fail "a scheduled real change did not bring its names: $(applied_name)"

printf 'subscription_names_only_update: PASS\n'
