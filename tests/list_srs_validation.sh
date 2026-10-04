#!/usr/bin/env bash
set -euo pipefail
# B2: a downloaded binary list (SRS) is validated with "sing-box rule-set
# match", which parses the whole list, and never decompiled to JSON: the
# decompile took about twice the peak memory on a large list and was the
# first thing to run a 256 MB router out of memory on a list update. A
# damaged list still fails, and the update keeps the previous one.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
UPDATES_UC="$LIB/components/updates.uc"
STUB="$ROOT_DIR/tests/helpers/sing_box_rule_set_stub.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/lists"
cat >"$WORK/bin/sing-box" <<SH
#!/bin/sh
exec ucode -- "$STUB" "\$@"
SH
chmod +x "$WORK/bin/sing-box"
export RULESET_STUB_CALLS="$WORK/calls"

validate() {
  PATH="$WORK/bin:$PATH" ucode -L "$LIB" "$UPDATES_UC" validate-list-download "$1" "$2"
}

# The stand-in's binary format: "SRS\n" followed by the source JSON.
printf 'SRS\n{"version":3,"rules":[{"domain_suffix":["example.com"]}]}\n' >"$WORK/lists/good.srs"
printf 'garbage\n' >"$WORK/lists/bad.srs"
: >"$WORK/lists/empty.srs"

: >"$WORK/calls"
validate "$WORK/lists/good.srs" srs || fail "a valid binary list was refused"
grep -q '^rule-set match -f binary .*/good\.srs ' "$WORK/calls" || fail "the list was not checked with a match query: $(cat "$WORK/calls")"
if grep -q decompile "$WORK/calls"; then
  fail "the list was decompiled: $(cat "$WORK/calls")"
fi
[ "$(find "$WORK/lists" -name '*.json' | wc -l)" = 0 ] || fail "validation left a file behind"

if validate "$WORK/lists/bad.srs" srs; then fail "a damaged binary list was accepted"; fi
if validate "$WORK/lists/empty.srs" srs; then fail "an empty binary list was accepted"; fi

# Source lists are still checked as JSON, without sing-box.
: >"$WORK/calls"
printf '{"version":3,"rules":[]}\n' >"$WORK/lists/good.json"
printf '{"version":3}\n' >"$WORK/lists/norules.json"
validate "$WORK/lists/good.json" json || fail "a valid source list was refused"
if validate "$WORK/lists/norules.json" json; then fail "a source list without rules was accepted"; fi
[ ! -s "$WORK/calls" ] || fail "a source list ran sing-box"

# Against the real binary, when there is one: a compiled list passes, a
# truncated or corrupted one fails.
SING_BOX="${PROKOP_TEST_SING_BOX:-$(command -v sing-box 2>/dev/null || true)}"
if [ -z "$SING_BOX" ] || [ ! -x "$SING_BOX" ]; then
  printf 'list_srs_validation: OK (real sing-box not checked: set PROKOP_TEST_SING_BOX)\n'
  exit 0
fi
mkdir -p "$WORK/real"
ln -s "$SING_BOX" "$WORK/real/sing-box"
printf '{"version":2,"rules":[{"domain_suffix":["example.com"],"ip_cidr":["192.0.2.0/24"]}]}\n' >"$WORK/real/list.json"
"$SING_BOX" rule-set compile "$WORK/real/list.json" -o "$WORK/real/list.srs"
head -c 20 "$WORK/real/list.srs" >"$WORK/real/truncated.srs"
cp "$WORK/real/list.srs" "$WORK/real/corrupt.srs"
printf '\377\377\377' | dd of="$WORK/real/corrupt.srs" bs=1 seek=10 conv=notrunc 2>/dev/null
real_validate() {
  PATH="$WORK/real:$PATH" ucode -L "$LIB" "$UPDATES_UC" validate-list-download "$1" srs
}
real_validate "$WORK/real/list.srs" || fail "real sing-box: a compiled list was refused"
if real_validate "$WORK/real/truncated.srs"; then fail "real sing-box: a truncated list was accepted"; fi
if real_validate "$WORK/real/corrupt.srs"; then fail "real sing-box: a corrupted list was accepted"; fi
if real_validate "$WORK/real/list.json"; then fail "real sing-box: a source list passed as binary"; fi

echo "list_srs_validation: OK"
