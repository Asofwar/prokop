#!/usr/bin/env bash
set -euo pipefail

# A priority level's include filters are country, server_name and regex, the
# names the Settings page writes (UC-175). The backend used to prefer
# include_countries, include_outbounds and include_regex, which nothing
# writes for a priority level: one left in a hand-edited configuration
# shadowed what the page wrote. It is still read when the page's name is
# not set.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"

ucode -L "$LIB" -e '
let connections = require("config.connections");
let level = (name, values) => ({ ".name": name, ".type": "priority_level", group: "pg_main", ...values });
connections.set_item_sections_from_data({ priority_level: [
    level("both", { country: [ "NL" ], include_countries: [ "US" ], server_name: [ "Alpha" ],
        include_outbounds: [ "Beta" ], regex: [ "^a" ], include_regex: [ "^b" ] }),
    level("page", { country: [ "NL" ], server_name: [ "Alpha" ], regex: [ "^a" ] }),
    level("legacy", { include_countries: [ "US" ], include_outbounds: [ "Beta" ], include_regex: [ "^b" ] }),
    level("none", {})
] });
let got = {};
for (let name in [ "both", "page", "legacy", "none" ])
    got[name] = [ connections.priority_level_include_countries("pg_main", name),
        connections.priority_level_include_outbounds("pg_main", name),
        connections.priority_level_include_regex("pg_main", name) ];
let want = {
    both: [ [ "NL" ], [ "Alpha" ], [ "^a" ] ],
    page: [ [ "NL" ], [ "Alpha" ], [ "^a" ] ],
    legacy: [ [ "US" ], [ "Beta" ], [ "^b" ] ],
    none: [ [], [], [] ]
};
if (sprintf("%J", got) != sprintf("%J", want)) {
    warn(sprintf("FAIL: priority level include filters: got %J, want %J\n", got, want));
    exit(1);
}
' || exit 1

printf 'priority level include names checks passed\n'
