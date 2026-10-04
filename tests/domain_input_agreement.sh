#!/bin/sh
set -eu
# FE-4 and A10: the router and the page give a domain the same verdict.
#   - A domain copied with an invisible character (zero-width space, soft
#     hyphen, BOM) is refused: kept as it is it would never match, and the
#     traffic it should route would go direct.
#   - A top-level label may hold digits with a letter (.i2p), as on the page;
#     an all-digit one is an address, never a domain. Punycode top-level
#     labels (xn--p1ai) are domains too.
# validateDomain.ts holds the page's side (vitest).
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$WORK/domain.uc" <<'UC'
let d = require("config.domain");
let out = [];
for (let v in [ "​youtube.com", "exam­ple.com", "example.com﻿", "you⁠tube.com",
    "сайт.рф", "example.i2p", "youtube.com" ])
    push(out, d.suffix_to_ascii(v) ?? "null");
print(join(",", out), "\n");
UC
[ "$(ucode -L "$LIB" "$WORK/domain.uc")" = "null,null,null,null,xn--80aswg.xn--p1ai,example.i2p,youtube.com" ] ||
  fail "domain normalization: $(ucode -L "$LIB" "$WORK/domain.uc")"

trace() { PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/diagnostics/route_trace.uc" fixture "$1" '' TCP 443 '' '' >/dev/null 2>&1; }
trace example.i2p || fail "route trace refuses a digit in the top-level label"
trace xn--80aswg.xn--p1ai || fail "route trace refuses a punycode top-level label"
! trace example.123 || fail "route trace takes an all-digit top-level label for a domain"

cat >"$WORK/probe.uc" <<'UC'
let p = require("autotune.probe");
print(join(",", map([ "example.i2p", "xn--80aswg.xn--p1ai", "example.123", "example.c" ], (v) => p.valid_host(v))), "\n");
UC
[ "$(ucode -L "$LIB" "$WORK/probe.uc")" = "true,true,false,false" ] || fail "autotune target: $(ucode -L "$LIB" "$WORK/probe.uc")"

echo "domain_input_agreement: OK"
