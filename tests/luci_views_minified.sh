#!/usr/bin/env bash
set -euo pipefail
# Optimization 16 of the 2026-10-04 audit: the package ships the
# hand-written LuCI views minified (uhttpd serves them uncompressed, LuCI
# parses them on every page). LuCI's jsmin (LUCI_MINIFY_JS) breaks
# section.js, so build.sh minifies them with the esbuild fe-app-prokop pins,
# whitespace and syntax only, and keeps a view as it is when the result does
# not check out. The minified views must pass the LuCI form tests.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/build_recipe.sh
. "$ROOT_DIR/tests/helpers/build_recipe.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
VIEWS="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop"

fail() { printf 'FAIL: luci_views_minified: %s\n' "$1" >&2; exit 1; }

load_build_functions() {
  local name
  for name in esbuild_lock_entry ensure_esbuild luci_view_minify minify_luci_views; do
    eval "$(build_recipe_function "$ROOT_DIR/build.sh" "$name")"
    declare -F "$name" >/dev/null || fail "build.sh has no $name"
  done
}
load_build_functions

# 1. The feed Makefile keeps jsmin off; build.sh minifies the views of the
#    package it builds.
grep -qx 'LUCI_MINIFY_JS:=0' "$ROOT_DIR/luci-app-prokop/Makefile" ||
  fail "luci-app-prokop/Makefile must keep LuCI's jsmin off"
build_recipe_function "$ROOT_DIR/build.sh" build_app_root | grep -q 'minify_luci_views "$esbuild_bin"' ||
  fail "build_app_root does not minify the views"

# 2. The esbuild build.sh fetches is the one yarn.lock pins for fe-app-prokop.
pinned="$(awk '/^esbuild@/ { found = 1; next } found && $1 == "version" { gsub(/"/, "", $2); print $2; exit }' "$ROOT_DIR/fe-app-prokop/yarn.lock")"
for platform in linux-x64 linux-arm64; do
  entry="$(esbuild_lock_entry "$platform")"
  [[ "$entry" == "$pinned sha512-"* ]] || fail "no pinned @esbuild/$platform $pinned in yarn.lock: '$entry'"
done

# 3. A download that does not match the lock is not run.
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) platform=linux-x64 ;;
  Linux-aarch64) platform=linux-arm64 ;;
  *) platform="" ;;
esac
if [[ -n "$platform" ]]; then
  mkdir -p "$WORK/registry/@esbuild/$platform/-" "$WORK/pkg/package/bin" "$WORK/root/fe-app-prokop"
  printf '#!/bin/sh\necho fake esbuild\n' >"$WORK/pkg/package/bin/esbuild"
  chmod 0755 "$WORK/pkg/package/bin/esbuild"
  tar -czf "$WORK/registry/@esbuild/$platform/-/$platform-9.9.9.tgz" -C "$WORK/pkg" package
  sum="$(perl -MDigest::SHA=sha512_base64 -e 'open(my $f, "<", $ARGV[0]) or die; binmode $f; local $/; print sha512_base64(<$f>)' "$WORK/registry/@esbuild/$platform/-/$platform-9.9.9.tgz")"
  write_lock() {
    printf '"@esbuild/%s@9.9.9":\n  version "9.9.9"\n  resolved "x"\n  integrity sha512-%s==\n\n' "$platform" "$1" >"$WORK/root/fe-app-prokop/yarn.lock"
  }
  (
    # shellcheck disable=SC2034 # read by build.sh's ensure_esbuild
    ROOT_DIR="$WORK/root" SDK_CACHE_BASE="$WORK/cache-bad" ESBUILD_REGISTRY="file://$WORK/registry"
    unset ESBUILD
    if [[ "$sum" == A* ]]; then write_lock "B${sum#?}"; else write_lock "A${sum#?}"; fi
    if ensure_esbuild >"$WORK/bad.out" 2>"$WORK/bad.err"; then fail "a download that does not match yarn.lock was accepted"; fi
    grep -q 'does not match' "$WORK/bad.err" || fail "no mismatch message: $(cat "$WORK/bad.err")"
    [[ ! -e "$WORK/cache-bad/prokop/esbuild/9.9.9-$platform/esbuild" ]] || fail "the mismatching binary was installed"
    write_lock "$sum"
    bin="$(ROOT_DIR="$WORK/root" SDK_CACHE_BASE="$WORK/cache-good" ESBUILD_REGISTRY="file://$WORK/registry" ensure_esbuild)" ||
      fail "the matching download was refused"
    [[ "$("$bin")" == "fake esbuild" ]] || fail "ensure_esbuild did not install the downloaded esbuild"
  )
fi

# 4. An esbuild whose output does not check out leaves every view as it is.
mkdir -p "$WORK/broken"
cp -a "$VIEWS/." "$WORK/broken/"
printf '#!/bin/sh\ncat >/dev/null\necho "function __prokop_luci_view(){return 1}"\n' >"$WORK/fake-esbuild"
chmod 0755 "$WORK/fake-esbuild"
minify_luci_views "$WORK/fake-esbuild" "$WORK/broken" 2>"$WORK/broken.err"
diff -r "$VIEWS" "$WORK/broken" >/dev/null || fail "views changed although their minified copies did not check out"
grep -q 'section.js is shipped unminified' "$WORK/broken.err" || fail "no warning for a view left as it is"

# 5. The real esbuild: every hand-written view minified, the tsup bundles
#    untouched, LuCI reads the same directives, the form tests pass.
esbuild_bin="${ESBUILD:-}"
if [[ -z "$esbuild_bin" && -n "$platform" ]]; then
  esbuild_bin="$ROOT_DIR/fe-app-prokop/node_modules/@esbuild/$platform/bin/esbuild"
fi
if [[ -z "$esbuild_bin" || ! -x "$esbuild_bin" ]]; then
  printf 'SKIP: luci_views_minified: no esbuild binary (yarn install in fe-app-prokop, or ESBUILD=) for the minified views\n'
  exit 0
fi
mkdir -p "$WORK/min"
cp -a "$VIEWS/." "$WORK/min/"
minify_luci_views "$esbuild_bin" "$WORK/min" 2>"$WORK/min.err"
grep -q '(0 left as they are)' "$WORK/min.err" || fail "views left unminified: $(cat "$WORK/min.err")"

node - "$ROOT_DIR" "$VIEWS" "$WORK/min" <<'NODE'
const fs = require("fs");
const path = require("path");
const assert = require("assert/strict");
const [root, original, minified] = process.argv.slice(2);
const { scanRequires } = require(path.join(root, "tests/helpers/luci_class_loader.js"));
let before = 0;
let after = 0;
for (const file of fs.readdirSync(original, { recursive: true }).filter((name) => name.endsWith(".js"))) {
  const a = fs.readFileSync(path.join(original, file), "utf8");
  const b = fs.readFileSync(path.join(minified, file), "utf8");
  if (a.startsWith("// This file is autogenerated")) {
    assert.equal(b, a, `${file}: a tsup bundle was changed`);
    continue;
  }
  assert.ok(b.length < a.length, `${file} was not minified`);
  assert.deepEqual(scanRequires(b), scanRequires(a), `${file}: LuCI reads other require directives`);
  assert.deepEqual(
    b.split("\n").filter((line) => /^"require /.test(line)),
    a.split("\n").filter((line) => /^"require /.test(line)),
    `${file}: the require directives are not one per line`,
  );
  // LuCI runs the file as a function body.
  new Function("window", "document", "L", b);
  before += a.length;
  after += b.length;
}
console.log(`hand-written views: ${before} -> ${after} bytes`);
NODE

failed=""
for test in "$ROOT_DIR"/tests/*.sh; do
  [[ "$test" != "${BASH_SOURCE[0]}" && "$(basename "$test")" != luci_views_minified.sh ]] || continue
  grep -q 'helpers/luci_form_harness' "$test" || continue
  if ! PROKOP_LUCI_VIEW_DIR="$WORK/min" bash "$test" >"$WORK/test.log" 2>&1; then
    failed="$failed $(basename "$test")"
    tail -n 20 "$WORK/test.log" >&2
  fi
done
[[ -z "$failed" ]] || fail "LuCI form tests fail on the minified views:$failed"
echo "luci_views_minified: OK"
