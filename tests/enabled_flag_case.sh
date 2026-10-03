#!/usr/bin/env bash
set -euo pipefail

# One reading of a rule's enabled flag (UC-105, the enabled part of UC-172):
# 1/true/yes/on in any letter case is on, everything else set is off, unset
# is on. The sing-box generator and nft (core/common.bool_option) read 'On'
# as off while the nfqws runtime and the resolver read it as on, so the
# position of a Zapret rule among the enabled ones differed: rule b got the
# route mark and queue of index 1 from sing-box and nft, while nfqws ran
# rule a's strategy on that queue. Every reader must count the same rules.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# ---- the helper -------------------------------------------------------------

ucode -L "$LIB" -e '
let common = require("core.common");
let on = [ "1", "on", "On", "ON", "true", "True", "TRUE", "yes", "Yes", "YES", "oN" ];
let off = [ "0", "off", "Off", "false", "FALSE", "no", "No", "", "2", "enabled" ];
let bad = [];
for (let v in on) if (!common.bool_option({ enabled: v }, "enabled", false)) push(bad, "on:" + v);
for (let v in off) if (common.bool_option({ enabled: v }, "enabled", true)) push(bad, "off:" + v);
if (!common.bool_option({}, "enabled", true) || common.bool_option({}, "enabled", false)) push(bad, "unset");
if (!common.section_enabled({}) || !common.section_enabled({ enabled: "On" }) || common.section_enabled({ enabled: "OFF" }))
    push(bad, "section_enabled");
if (length(bad)) { warn(join(" ", bad), "\n"); exit(1); }
' || fail "core/common.bool_option reads 1/true/yes/on in any letter case as on, unset as the fallback"

# ---- generator, nft, resolver and nfqws runtime count the same rules --------

cat >"$WORK/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn",
    "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret" },
  "section": [
    { ".name": "a", ".type": "section", "enabled": "On", "action": "zapret", "domain_suffix": [ "a.example" ],
      "nfqws_opt": "--filter-tcp=443 --dpi-desync=fake" },
    { ".name": "b", ".type": "section", "enabled": "1", "action": "zapret", "domain_suffix": [ "b.example" ],
      "nfqws_opt": "--filter-tcp=443 --dpi-desync=multisplit" },
    { ".name": "c", ".type": "section", "enabled": "FALSE", "action": "zapret", "domain_suffix": [ "c.example" ],
      "nfqws_opt": "--filter-tcp=443 --dpi-desync=fakedsplit" },
    { ".name": "d", ".type": "section", "enabled": "Yes", "action": "zapret", "domain_suffix": [ "d.example" ],
      "nfqws_opt": "--filter-tcp=443 --dpi-desync=split2" }
  ]
}
JSON

mkdir -p "$WORK/generated.section-cache"
TMP_SUBSCRIPTION_FOLDER="$WORK/subs" ucode -L "$LIB" "$LIB/singbox/generator.uc" \
  generate-config-fixture "$WORK/fixture.json" "$WORK/generated" 127.0.0.1 0 >/dev/null 2>"$WORK/generator.err" ||
  fail "the generator refused the fixture: $(cat "$WORK/generator.err")"

provider_bin="$WORK/provider"
printf '#!/bin/sh\nexit 0\n' >"$provider_bin"
chmod 0755 "$provider_bin"
: >"$WORK/nft.batch"
PROKOP_NFT_BATCH_FILE="$WORK/nft.batch" PROKOP_NFT_SUBNET_CACHE_DIR="$WORK/nft-cache" \
  ucode -L "$LIB" "$LIB/nft/apply.uc" nft-create-provider-output-rules-fixture "$WORK/fixture.json" ProkopTable zapret \
  "$provider_bin" 0x01000000 4000 0x40000000 0x20000000 >/dev/null 2>"$WORK/nft.err" ||
  fail "nft provider rules refused: $(cat "$WORK/nft.err")"

# The resolver reads the same rules from the UCI text.
{
  for s in a:On b:1 c:FALSE d:Yes; do
    printf "config section '%s'\n\toption action 'zapret'\n\toption enabled '%s'\n" "${s%%:*}" "${s#*:}"
  done
} >"$WORK/prokop.uci"
ucode -L "$LIB" -e '
let r = require("routing.resolve"), fs = require("fs");
let s = r.parse_config(fs.readfile(ARGV[0]));
print(join(" ", map(r.zapret_sections(s), (x) => x.name)), "\n");
' -- "$WORK/prokop.uci" >"$WORK/resolver.out" 2>&1 || fail "resolver: $(cat "$WORK/resolver.out")"

node - "$WORK/generated" "$WORK/nft.batch" "$WORK/resolver.out" <<'NODE' || failures=$((failures + 1))
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [configFile, batchFile, resolverFile] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(configFile, 'utf8'));
const base = 0x01000000;
const expected = { a: 1, b: 2, d: 3 };

const marks = {};
for (const o of config.outbounds) {
  const m = /^([a-d])-out(-1)?$/.exec(o.tag);
  if (m && o.routing_mark != null) marks[m[1]] = o.routing_mark - base;
}
assert.deepEqual(marks, expected, 'sing-box: enabled Zapret rules a(On), b(1), d(Yes) by position, c(FALSE) off');

const batch = fs.readFileSync(batchFile, 'utf8');
for (const [name, index] of Object.entries(expected)) {
  const mark = `0x${(base + index).toString(16).padStart(8, '0')}`;
  assert.match(batch, new RegExp(`meta mark & 0xff0000ff == ${mark} meta l4proto tcp counter queue num ${4000 + index - 1} bypass`),
    `nft: rule ${name} has mark ${mark} and queue ${4000 + index - 1}`);
}
assert.doesNotMatch(batch, /0x01000004/, 'nft: no fourth Zapret rule');

assert.equal(fs.readFileSync(resolverFile, 'utf8').trim(), 'a b d', 'resolver: the same enabled Zapret rules in order');
NODE

# The nfqws runtime starts one strategy per enabled rule in the same order:
# its section filter is the shared helper.
grep -Eq 'common\.(bool_option|section_enabled)' "$LIB/providers/nfqueue/runtime.uc" ||
  fail "providers/nfqueue/runtime.uc reads the enabled flag with core/common"

if [ "$failures" -ne 0 ]; then
  printf 'enabled_flag_case: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'enabled_flag_case: PASS\n'
