#!/usr/bin/env bash
set -euo pipefail
# FE-5: domain_regex is matched by sing-box with Go RE2, so the page
# (section.js validateRegex) and the router (config/validator.uc
# regex_valid) both check RE2 syntax and agree: RE2 groups the browser or
# POSIX lack are accepted, what RE2 refuses (backreferences, lookaround) is
# refused before apply instead of failing sing-box.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
SECTION="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

valid=( '^(?:www\.)?example\.com$' '(?i)youtube' '(?i:you)tube' '(?P<n>a)b' '[(?]x' '\(\?=' 'ex\.com$' )
invalid=( '(a)\1' 'a(?=b)' 'a(?!b)' '(?<=a)b' '(?<!a)b' '(a' )

for p in "${valid[@]}"; do
  PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/validator.uc" regex-valid "$p" || fail "router refuses RE2 pattern $p"
done
for p in "${invalid[@]}"; do
  ! PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/config/validator.uc" regex-valid "$p" || fail "router accepts non-RE2 pattern $p"
done

source="$(sed -n '/^function re2Pattern(/,/^}/p;/^function validateRegex(/,/^}/p' "$SECTION")"
[ -n "$source" ] || fail "fixture: validateRegex not found"
VALID="$(printf '%s\n' "${valid[@]}")" INVALID="$(printf '%s\n' "${invalid[@]}")" SOURCE="$source" node <<'NODE'
const _ = (s) => s;
const validateRegex = Function('_', `${process.env.SOURCE}; return validateRegex`)(_);
for (const p of process.env.VALID.split('\n'))
  if (validateRegex('s', p) !== true) throw new Error(`page refuses RE2 pattern ${p}`);
for (const p of process.env.INVALID.split('\n'))
  if (validateRegex('s', p) === true) throw new Error(`page accepts non-RE2 pattern ${p}`);
NODE
echo "regex_re2_dialect: OK"
