#!/usr/bin/env bash
set -euo pipefail
# Optimization 25 of the 2026-10-04 audit: main.js is minified (uhttpd serves
# it uncompressed and LuCI parses it on every Prokop page), keeps LuCI's
# "require" directives one per line and returns its exports through
# baseclass.extend, renames included.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_JS="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/main.js"
node - "$MAIN_JS" <<'NODE'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");
const fail = (message) => { console.error(`FAIL: ${message}`); process.exit(1); };
if (source.length > 500000) fail(`main.js is not minified: ${source.length} bytes`);
const lines = source.split("\n");
for (const dep of ["baseclass", "fs", "uci", "ui"])
  if (!lines.includes(`"require ${dep}";`)) fail(`"require ${dep}" is not on a line of its own`);
if (!source.includes("__COMPILED_VERSION_VARIABLE__")) fail("the version placeholder the package build replaces is gone");
const tail = source.slice(source.lastIndexOf("return baseclass.extend({"));
if (/\bas\b/.test(tail)) fail("an `as` rename reached baseclass.extend");
// Parsed, not run: the body needs LuCI's globals.
new Function("baseclass", "fs", "uci", "ui", source);
for (const name of ["validateDomain", "validateIP", "store", "coreService", "PROKOP_UCI_PACKAGE"])
  if (!new RegExp(`[{,]${name}(?::[\\w$]+)?[,}]`).test(tail)) fail(`export ${name} missing`);
NODE
echo "luci_bundle_minified: OK"
