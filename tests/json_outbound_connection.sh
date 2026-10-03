#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
GENERATOR_UC="$PROKOP_LIB/singbox/generator.uc"
SECTION_JS="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The JSON outbound editor is only reachable when it depends on the Connection
# action.  A hidden dependency silently removes the feature from the UI while
# the backend keeps generating the outbounds.
grep -q 'o.depends("action", "connection");' "$SECTION_JS" ||
  fail 'section.js does not expose the JSON outbound list for Connection sections'

cat >"$WORK_DIR/input.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"type\":\"direct\",\"tag\":\"proxy-out\"}",
        "{\"type\":\"direct\",\"tag\":\"second\"}"
      ],
      "urltest_enabled": "1",
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

runtime_config="$WORK_DIR/output.json"
mkdir -p "$runtime_config.section-cache" "$runtime_config.rulesets"
ucode -L "$PROKOP_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/input.json" "$runtime_config" "127.0.0.1" "0"

ucode -e '
let config = json(require("fs").readfile(ARGV[0]));
let by_tag = {};
for (let outbound in config.outbounds || [])
    by_tag[outbound.tag] = outbound;

// The first JSON outbound claims the tag the Connection selector needs, so it
// must be renamed rather than dropped or silently overwriting the selector.
if (by_tag["proxy-out-1"]?.type != "direct" || by_tag.second?.type != "direct")
    die("multiple JSON outbounds or conflicting tag rewrite failed\n");
if (by_tag["proxy-out"]?.type != "selector")
    die("Connection selector missing\n");
if (index(by_tag["proxy-out"].outbounds, "proxy-out-1") < 0 || index(by_tag["proxy-out"].outbounds, "second") < 0)
    die("JSON outbounds absent from Connection selector\n");
if (index(by_tag["proxy-urltest-out"].outbounds, "proxy-out-1") < 0 || index(by_tag["proxy-urltest-out"].outbounds, "second") < 0)
    die("JSON outbounds absent from URLTest\n");
' "$runtime_config"

printf 'JSON outbound Connection: PASS\n'
