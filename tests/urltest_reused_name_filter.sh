#!/usr/bin/env bash
# A name filter of URLTest/Priority: a previous name of a renamed server
# selects it only while no candidate carries that name now (D1).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR_UC="$ROOT_DIR/prokop/files/usr/lib/singbox/generator.uc"

{
    cat <<'UCODE'
function array_or_empty(v) { return type(v) == "array" ? v : []; }
function object_or_empty(v) { return type(v) == "object" ? v : {}; }
function as_string(v) { return v == null ? "" : "" + v; }
UCODE
    for name in array_contains tag_display_name tag_name_filter_matches; do
        sed -n "/^function $name(/,/^}/p" "$GENERATOR_UC"
    done
    cat <<'UCODE'
function check(ok, message) { if (!ok) die("FAIL: " + message + "\n"); }
let names = { fresh: "Berlin #1", renamed: "Berlin #2" };
let metadata = { filterNames: { renamed: [ "Berlin #1" ] } };
let current = { "Berlin #1": true, "Berlin #2": true };
check(tag_name_filter_matches("fresh", names, [ "Berlin #1" ], {}, metadata, current), "the current owner of a name matches");
check(!tag_name_filter_matches("renamed", names, [ "Berlin #1" ], {}, metadata, current), "a reused previous name does not select the renamed server");
check(tag_name_filter_matches("renamed", names, [ "Berlin #2" ], {}, metadata, current), "the renamed server matches its new name");
delete current["Berlin #1"];
check(tag_name_filter_matches("renamed", names, [ "Berlin #1" ], {}, metadata, current), "a plain rename keeps the filter on the server");
current["Berlin #1"] = true;
check(tag_name_filter_matches("renamed", names, [], { renamed: true }, metadata, current), "a regex match does not depend on names");
check(!tag_name_filter_matches("renamed", names, [ "Other" ], {}, metadata, current), "an unrelated name does not match");
check(tag_name_filter_matches("renamed", names, [ "Berlin #1" ], {}, metadata), "without the candidate names the history still applies");
print("urltest reused name filter checks passed\n");
UCODE
} | ucode -
