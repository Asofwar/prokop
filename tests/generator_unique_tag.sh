#!/usr/bin/env bash
set -euo pipefail
# Optimization 19 of the 2026-10-04 audit: unique_tag (singbox/generator.uc)
# remembers where its suffix search stopped, so 5 000 outbounds with one name
# no longer cost a quadratic scan. The tags stay exactly those of the plain
# search: the smallest free "<base>-<n>".
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$ROOT_DIR/prokop/files/usr/lib/singbox/generator.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
{
  echo 'function as_string(v) { return v == null ? "" : "" + v; }'
  sed -n '/^let unique_tag_memo/p;/^function unique_tag(/,/^}/p' "$GEN"
  cat <<'UC'
function plain(base, taken) {
    if (base == "") base = "server";
    if (!taken[base]) return base;
    for (let i = 1; i < 100000; i++) if (!taken[base + "-" + i]) return base + "-" + i;
    return base + "-overflow";
}
// The same sequence of names, with tags taken in between, gives the same tags.
let a = {}, b = {}, names = [ "x", "x", "y", "x-1", "x", "", "", "y", "x", "x-2", "x" ];
for (let i = 0; i < 300; i++) push(names, i % 3 ? "node" : "node-" + (i % 7));
for (let n in names) {
    let t1 = unique_tag(n, a), t2 = plain(n, b);
    if (t1 != t2) die("differs for " + n + ": " + t1 + " != " + t2);
    a[t1] = true; b[t2] = true;
}
let start = clock(true), taken = {};
for (let i = 0; i < 5000; i++) taken[unique_tag("Same name", taken)] = true;
let took = (clock(true)[0] - start[0]) + (clock(true)[1] - start[1]) / 1e9;
if (!taken["Same name-4999"]) die("wrong last tag");
if (took > 3) die(sprintf("5000 equal names took %.1f s", took));
print("ok\n");
UC
} >"$WORK/t.uc"
[ "$(ucode "$WORK/t.uc")" = ok ] || { echo "FAIL: unique_tag" >&2; exit 1; }
echo "generator_unique_tag: OK"
