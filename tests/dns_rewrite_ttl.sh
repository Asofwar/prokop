#!/usr/bin/env bash
set -euo pipefail
# FE-9: the DNS Rewrite TTL is whole seconds, at most 2^31 - 1.
#   - The page refuses "1.5" and "60s" (parseInt read them as 1 and 60, and
#     the router silently used 60) and a value sing-box cannot take.
#   - The router refuses a TTL too large for sing-box with a clear message
#     instead of a failed start, and warns about one that is not a whole
#     number, which it keeps replacing by 60 as before (a configuration that
#     ran keeps running).
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The page: the validate function of the dns_rewrite_ttl option.
source="$(sed -n '/"dns_rewrite_ttl",/,/^  };/p' "$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/settings.js" |
  sed -n '/o.validate = function/,/^  };/p')"
[ -n "$source" ] || fail "fixture: the TTL validator was not found"
TTL_SOURCE="$source" node <<'NODE'
const _ = (s) => s;
const o = {};
eval(process.env.TTL_SOURCE);
for (const v of ['60', '0', '2147483647', ' 300 '])
  if (o.validate('s', v) !== true) throw new Error(`valid TTL refused: ${v}`);
for (const v of ['1.5', '60s', '-1', '2147483648', '99999999999', 'abc'])
  if (o.validate('s', v) === true) throw new Error(`invalid TTL accepted: ${v}`);
NODE

# The router.
validate() {
  printf '{"settings":{".name":"settings",".type":"settings","dns_server":["77.88.8.8"],"bootstrap_dns_server":["77.88.8.8"],"yacd_secret_key":"test-clash-secret","dns_rewrite_ttl":"%s"}}' "$1" >"$WORK/fixture.json"
  mkdir -p "$WORK/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/syslog"\n' "$WORK" >"$WORK/bin/logger"
  chmod +x "$WORK/bin/logger"
  : >"$WORK/syslog"
  PATH="$WORK/bin:$PATH" PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/fixture.json" '{}' >"$WORK/out" 2>&1
}
validate 300 || fail "a valid TTL was refused: $(cat "$WORK/out")"
! validate 99999999999 || fail "a TTL sing-box cannot take was accepted"
grep -q 'too large' "$WORK/out" || fail "the refusal does not say why: $(cat "$WORK/out")"
validate 1.5 || fail "a TTL that ran before is refused now: $(cat "$WORK/out")"
grep -q 'not a whole number' "$WORK/syslog" "$WORK/out" || fail "no warning for a TTL replaced by 60"

echo "dns_rewrite_ttl: OK"
