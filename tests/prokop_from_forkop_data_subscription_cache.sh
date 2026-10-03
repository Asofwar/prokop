#!/usr/bin/env bash
# Subscription caches Forkop wrote carry its internal outbound keys
# (__forkop_hidden, __forkop_description ...), which Prokop's generator does
# not strip: a sing-box configuration built from them would fail. The
# migrating installer copies /etc/forkop/subscription-cache to
# /etc/prokop/subscription-cache, and Forkop's parsed subscriptions may still
# sit in /tmp/sing-box/subscriptions. The cache formats moved past every
# format Forkop used (runtime 10, persistent 9), so both are discarded and
# rebuilt, never loaded.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
CACHE_UC="$PROKOP_LIB/subscription/cache.uc"
GENERATOR_UC="$PROKOP_LIB/singbox/generator.uc"
MIGRATION_UC="$PROKOP_LIB/config/migration.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# A router right after the installer copied Forkop's state: no Prokop runtime
# state yet, Forkop's caches in both places.
RUN="$WORK_DIR/var/run/prokop"
PERSISTENT="$WORK_DIR/etc/prokop/subscription-cache"
TMP_SUBSCRIPTIONS="$WORK_DIR/tmp/sing-box/subscriptions"
mkdir -p "$PERSISTENT" "$TMP_SUBSCRIPTIONS"
printf '9\n' >"$PERSISTENT/cache-format"
cat >"$WORK_DIR/forkop-subscription.json" <<'JSON'
{
  "version": 1,
  "format": "sing-box-json",
  "outbounds": [
    {
      "type": "vless",
      "tag": "forkop-node",
      "server": "forkop.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000003",
      "__forkop_description": "cached by Forkop",
      "__forkop_hidden": true,
      "__forkop_filter_names": [ "forkop-node" ]
    }
  ]
}
JSON
cp "$WORK_DIR/forkop-subscription.json" "$PERSISTENT/main-subscription-1.json"
printf 'https://provider.example/sub\n' >"$PERSISTENT/main-subscription-1.url"
cp "$WORK_DIR/forkop-subscription.json" "$TMP_SUBSCRIPTIONS/main-subscription-1.json"

TMP_SING_BOX_FOLDER="$WORK_DIR/tmp/sing-box" \
TMP_RULESET_FOLDER="$WORK_DIR/tmp/sing-box/rulesets" \
TMP_SUBSCRIPTION_FOLDER="$TMP_SUBSCRIPTIONS" \
PROKOP_RUNTIME_STATE_DIR="$RUN" \
PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$PERSISTENT" \
  ucode -L "$PROKOP_LIB" "$CACHE_UC" ensure-runtime-cache-format ||
  fail "ensure-runtime-cache-format failed"

[ "$(sed -n '1p' "$RUN/cache-format")" = "11" ] || fail "the runtime cache format was not recorded"
[ "$(sed -n '1p' "$PERSISTENT/cache-format")" = "10" ] ||
  fail "the persistent subscription cache was not rebuilt in the current format"
[ ! -e "$PERSISTENT/main-subscription-1.json" ] && [ ! -e "$PERSISTENT/main-subscription-1.url" ] ||
  fail "the subscription cache Forkop wrote was kept"
[ ! -e "$TMP_SUBSCRIPTIONS/main-subscription-1.json" ] ||
  fail "the parsed subscription Forkop left in the runtime folder was kept"
if grep -rqs '__forkop_' "$PERSISTENT" "$TMP_SUBSCRIPTIONS" "$RUN"; then
  fail "a cache entry with Forkop's keys survived"
fi
[ "$(stat -c %a "$PERSISTENT")" = "700" ] || fail "the rebuilt persistent cache is not private"

# Should such an outbound still reach the generator, Forkop's keys never
# reach sing-box, which refuses unknown fields.
python3 - "$GENERATOR_UC" "$WORK_DIR/generator-probe.uc" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding='utf-8').read()
parts = []
match = re.search(r'^const LEGACY_SUBSCRIPTION_KEY_PREFIX = [^\n]*;$', source, re.M)
if match is None:
    raise SystemExit('missing production constant: LEGACY_SUBSCRIPTION_KEY_PREFIX')
parts.append(match.group())
match = re.search(r'^function copy_subscription_outbound\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
if match is None:
    raise SystemExit('missing production function: copy_subscription_outbound')
parts.append(match.group())
prefix = r"""
let fs = require("fs");
let legacy_forkop = require("core.legacy_forkop");
function as_string(value) { return value == null ? "" : "" + value; }
"""
suffix = r"""
let outbound = json(fs.readfile(getenv("WORK_DIR") + "/forkop-subscription.json")).outbounds[0];
outbound.__prokop_hidden = true;
let copy = copy_subscription_outbound(outbound, "main-1");
let leaked = filter(keys(copy), (key) => index(key, "__") == 0);
print(length(leaked) == 0 && copy.tag == "main-1" && copy.server == "forkop.example" ?
    "probe: PASS" : "probe: leaked " + join(",", leaked), "\n");
"""
open(sys.argv[2], 'w', encoding='utf-8').write(prefix + '\n\n'.join(parts) + suffix)
PY
result="$(WORK_DIR="$WORK_DIR" ucode -L "$PROKOP_LIB" "$WORK_DIR/generator-probe.uc" 2>&1)" ||
  fail "the generator probe failed: $result"
[ "$result" = "probe: PASS" ] || fail "the generator passed internal keys on to sing-box: $result"

# The installer runs "migration.uc migrate" while Forkop's package is still
# installed and its runtime may still use /tmp/sing-box: that runtime is left
# alone, Prokop's own persistent copy is rebuilt. Once Forkop's package is
# gone, the same step resets the runtime cache too.
FORKOP_ROOT="$WORK_DIR/forkop-root"
mkdir -p "$FORKOP_ROOT/etc/init.d" "$WORK_DIR/m/etc/prokop/subscription-cache" "$WORK_DIR/m/tmp/sing-box/subscriptions"
printf '#!/bin/sh /etc/rc.common\n' >"$FORKOP_ROOT/etc/init.d/forkop"
printf '9\n' >"$WORK_DIR/m/etc/prokop/subscription-cache/cache-format"
cp "$WORK_DIR/forkop-subscription.json" "$WORK_DIR/m/etc/prokop/subscription-cache/main-subscription-1.json"
cp "$WORK_DIR/forkop-subscription.json" "$WORK_DIR/m/tmp/sing-box/subscriptions/main-subscription-1.json"
printf 'prokop.settings=settings\nprokop.settings.config_version=1.0.5\n' >"$WORK_DIR/m/uci.state"
migrate() {
  PROKOP_LEGACY_FORKOP_ROOT="$FORKOP_ROOT" \
  PROKOP_UCI_STATE_FILE="$WORK_DIR/m/uci.state" \
  PROKOP_UCI_LOG_FILE="$WORK_DIR/m/uci.log" \
  PROKOP_CONFIG_NAME="prokop" \
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/m/tmp/sing-box/subscriptions" \
  PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/m/var/run/prokop" \
  PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/m/etc/prokop/subscription-cache" \
  PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/m/internal-config-change" \
    ucode -L "$PROKOP_LIB" "$MIGRATION_UC" migrate
}
migrate || fail "migrate next to an installed Forkop failed"
[ -f "$WORK_DIR/m/tmp/sing-box/subscriptions/main-subscription-1.json" ] ||
  fail "migrate removed the runtime subscriptions of an installed Forkop"
[ ! -e "$WORK_DIR/m/var/run/prokop/cache-format" ] ||
  fail "migrate recorded a runtime cache format it did not establish"
[ ! -e "$WORK_DIR/m/etc/prokop/subscription-cache/main-subscription-1.json" ] &&
  [ "$(sed -n '1p' "$WORK_DIR/m/etc/prokop/subscription-cache/cache-format")" = "10" ] ||
  fail "migrate kept the copy of Forkop's persistent subscription cache"
rm -f "$FORKOP_ROOT/etc/init.d/forkop"
migrate || fail "migrate after Forkop's removal failed"
[ ! -e "$WORK_DIR/m/tmp/sing-box/subscriptions/main-subscription-1.json" ] ||
  fail "migrate after Forkop's removal kept Forkop's runtime subscriptions"
[ "$(sed -n '1p' "$WORK_DIR/m/var/run/prokop/cache-format")" = "11" ] ||
  fail "migrate after Forkop's removal did not record the runtime cache format"

# Every module states the same defaults; service/lifecycle.uc hands its own
# down to the modules it runs, so one stale copy keeps Forkop's caches alive.
runtime_formats="$(grep -rhoE 'getenv\("PROKOP_RUNTIME_CACHE_FORMAT"\) \|\| "[0-9]+"' "$PROKOP_LIB" |
  sed -E 's/.*"([0-9]+)"$/\1/' | sort -u | tr '\n' ' ')"
persistent_formats="$(grep -rhoE 'getenv\("PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT"\) \|\| "[0-9]+"' "$PROKOP_LIB" |
  sed -E 's/.*"([0-9]+)"$/\1/' | sort -u | tr '\n' ' ')"
[ "$runtime_formats" = "11 " ] ||
  fail "every module must default the runtime subscription cache format to 11, found: $runtime_formats$(
    grep -rlE 'getenv\("PROKOP_RUNTIME_CACHE_FORMAT"\) \|\| "(10|[0-9])"' "$PROKOP_LIB" | tr '\n' ' ')"
[ "$persistent_formats" = "10 " ] ||
  fail "every module must default the persistent subscription cache format to 10, found: $persistent_formats$(
    grep -rlE 'getenv\("PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT"\) \|\| "[0-9]"' "$PROKOP_LIB" | tr '\n' ' ')"

printf 'prokop from forkop data subscription cache: PASS\n'
