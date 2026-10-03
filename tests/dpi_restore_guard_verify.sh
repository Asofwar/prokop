#!/bin/sh
set -eu

# ensure/state semantics of the DPI transition guard: create when absent,
# reuse only a structurally verified guard, fail closed on anything else.
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
NFT_UC="$ROOT_DIR/prokop/files/usr/lib/nft/apply.uc"
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

# `nft -j list table inet ProkopConfigRestoreDpiGuard` as printed by nft 1.1.6 on
# OpenWrt 25.12 for the guard nft_dpi_transition_guard() creates.
cat > "$STATE_DIR/valid.json" <<'JSON'
{"nftables": [{"metainfo": {"version": "1.1.6", "release_name": "Commodore Bullmoose #7", "json_schema_version": 1}}, {"table": {"family": "inet", "name": "ProkopConfigRestoreDpiGuard", "handle": 1}}, {"chain": {"family": "inet", "table": "ProkopConfigRestoreDpiGuard", "name": "output", "handle": 1, "type": "filter", "hook": "output", "prio": -149, "policy": "accept"}}, {"rule": {"family": "inet", "table": "ProkopConfigRestoreDpiGuard", "chain": "output", "handle": 2, "expr": [{"match": {"op": "==", "left": {"&": [{"meta": {"key": "mark"}}, 4278190080]}, "right": 16777216}}, {"drop": null}]}}, {"rule": {"family": "inet", "table": "ProkopConfigRestoreDpiGuard", "chain": "output", "handle": 3, "expr": [{"match": {"op": "==", "left": {"&": [{"meta": {"key": "mark"}}, 4278190080]}, "right": 33554432}}, {"drop": null}]}}]}
JSON

cat > "$STATE_DIR/guard.uc" <<'UCODE'
let fs = require("fs");
let present = false;
let applied = "";
let listing = "";
let valid_listing = fs.readfile(ARGV[0] + "/valid.json");
// What `nft -j` shows for the table the next `nft -f` creates.
let created_listing = valid_listing;
function as_string(value) { return value == null ? "" : "" + value; }
function command_output_from_args(args) {
    return args[1] == "-j" ? listing : ARGV[0] + "/batch";
}
function run_args_quiet(args) { return present; }
function run_args(args) {
    let data = fs.readfile(args[length(args) - 1]);
    if (data == null)
        return false;
    if (args[1] == "-f") {
        applied = data;
        present = index(data, "add table") >= 0;
        listing = present ? created_listing : "";
    }
    return true;
}
UCODE

guard_source="$(source_between "$NFT_UC" '^function nft_dpi_transition_guard\(' '^function nft_rebuild_runtime_from_uci\(')" || exit 1
printf '%s\n' "$guard_source" >> "$STATE_DIR/guard.uc"

cat >> "$STATE_DIR/guard.uc" <<'UCODE'
function fail(code, message) { warn(message, "\n"); exit(code); }
function mutated(change) {
    let parsed = json(valid_listing);
    change(parsed.nftables);
    return sprintf("%J", parsed);
}

// 1. Absent: ensure creates the guard and verifies what it created.
if (nft_dpi_transition_guard_state("ProkopConfigRestore") != "absent") fail(1, "not absent");
if (!nft_dpi_transition_guard_ensure("ProkopConfigRestore")) fail(2, "ensure failed on absent guard");
if (!present || index(applied, "add table inet ProkopConfigRestoreDpiGuard") < 0) fail(3, "guard not created");
if (nft_dpi_transition_guard_state("ProkopConfigRestore") != "valid") fail(4, "created guard not valid");

// 2. Valid guard already active: reused as is, nothing re-applied.
applied = "";
if (!nft_dpi_transition_guard_ensure("ProkopConfigRestore")) fail(5, "valid guard not reused");
if (applied != "") fail(6, "valid guard was re-applied");
// The legacy install keeps its create-only contract for the lifecycle guard.
if (nft_dpi_transition_guard("ProkopConfigRestore", false)) fail(7, "install changed semantics");

// 3. A table with the guard's name that is not the expected protection.
let bad = {
    "extra rule": (n) => push(n, n[3]),
    "missing rule": (n) => splice(n, 4, 1),
    "wrong priority": (n) => (n[2].chain.prio = 0),
    "policy drop": (n) => (n[2].chain.policy = "drop"),
    "wrong hook": (n) => (n[2].chain.hook = "input"),
    "extra chain": (n) => push(n, { chain: { family: "inet", table: "ProkopConfigRestoreDpiGuard", name: "x", handle: 9 } }),
    "extra set": (n) => push(n, { set: { family: "inet", table: "ProkopConfigRestoreDpiGuard", name: "s" } }),
    "wrong mark": (n) => (n[4].rule.expr[0].match.right = 50331648),
    "wrong mask": (n) => (n[3].rule.expr[0].match.left["&"][1] = 255),
    "accept instead of drop": (n) => (n[3].rule.expr[1] = { accept: null }),
    "other table name": (n) => (n[1].table.name = "Other"),
};
for (let name, change in bad) {
    present = true;
    listing = mutated(change);
    applied = "";
    if (nft_dpi_transition_guard_state("ProkopConfigRestore") != "invalid") fail(10, "accepted: " + name);
    if (nft_dpi_transition_guard_ensure("ProkopConfigRestore")) fail(11, "ensure accepted: " + name);
    if (applied != "") fail(12, "ensure touched an invalid guard: " + name);
}
present = true;
listing = "{broken";
if (nft_dpi_transition_guard_ensure("ProkopConfigRestore")) fail(13, "accepted malformed JSON");
listing = "";
if (nft_dpi_transition_guard_ensure("ProkopConfigRestore")) fail(14, "accepted empty listing");
if (nft_dpi_transition_guard_state("Bad;Name") != "invalid") fail(15, "accepted bad table name");

// 4. nft < 1.1.0 lists `meta mark & 0xff000000 == V` as a prefix of the mark
// (UC-106): the same guard, valid in either rendering.
let prefixed = mutated((n) => {
    for (let i in [ 3, 4 ]) {
        let m = n[i].rule.expr[0].match;
        n[i].rule.expr[0].match = { op: "==", left: m.left["&"][0], right: { prefix: { addr: m.right, len: 8 } } };
    }
});
present = true;
listing = prefixed;
if (nft_dpi_transition_guard_state("ProkopConfigRestore") != "valid") fail(16, "prefix rendering not recognised");
let wrong_len = json(prefixed);
wrong_len.nftables[3].rule.expr[0].match.right.prefix.len = 7;
listing = sprintf("%J", wrong_len);
if (nft_dpi_transition_guard_state("ProkopConfigRestore") != "invalid") fail(17, "accepted a prefix of another length");
present = false;
listing = "";
created_listing = prefixed;
if (!nft_dpi_transition_guard_ensure("ProkopConfigRestore")) fail(18, "ensure failed on the prefix rendering");

// 5. A guard ensure created itself but cannot verify is removed again: it
// must not stay behind dropping DPI traffic while ensure reports failure.
present = false;
listing = "";
created_listing = mutated((n) => (n[3].rule.expr[1] = { accept: null }));
if (nft_dpi_transition_guard_ensure("ProkopConfigRestore")) fail(19, "ensure accepted an unverifiable guard it created");
if (present || index(applied, "delete table inet ProkopConfigRestoreDpiGuard") < 0)
    fail(20, "ensure left the unverifiable guard it created");
UCODE

ucode "$STATE_DIR/guard.uc" "$STATE_DIR"
printf 'dpi_restore_guard_verify: PASS\n'
