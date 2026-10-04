#!/usr/bin/env bash
# Subscription metadata (profile-title, announce, Xray meta) is provider
# controlled text. The parser must never hand angle brackets to the UI.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
PARSER_UC="$PROKOP_LIB/subscription/parser.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

announce_b64="$(printf '<script>alert(2)</script> News' | base64 | tr -d '\n')"
cat >"$WORK_DIR/headers" <<EOF2
profile-title: <img src=x onerror=alert(1)>Provider
announce: base64:$announce_b64
profile-web-page-url: https://provider.example/
EOF2
printf '{"outbounds":[],"meta":{"serverDescription":"<b>Tube</b>"}}\n' >"$WORK_DIR/body.json"

ucode -L "$PROKOP_LIB" "$PARSER_UC" metadata-extract-ui-file \
  "$WORK_DIR/headers" "$WORK_DIR/body.json" "$WORK_DIR/out.json" ||
  fail "metadata extraction failed"

ucode -e '
let fs = require("fs");
let m = json(fs.readfile(ARGV[0]));
for (let key in [ "title", "announce", "serverDescription" ]) {
    let value = m[key];
    if (type(value) != "string")
        die(sprintf("missing %s in %s\n", key, fs.readfile(ARGV[0])));
    if (index(value, "<") >= 0 || index(value, ">") >= 0)
        die(sprintf("%s keeps markup: %s\n", key, value));
}
if (index(m.title, "Provider") < 0)
    die("title lost its text: " + m.title + "\n");
if (index(m.announce, "News") < 0)
    die("announce lost its text: " + m.announce + "\n");
' "$WORK_DIR/out.json" || fail "metadata must not carry angle brackets"

printf 'PASS: subscription metadata markup\n'
