#!/usr/bin/env bash
set -euo pipefail

# Whether "sing-box rule-set match" can answer for a list depends on its
# shape (UC-218): only rules made of plain destination-address matchers.
# Learning the shape of a binary list takes a "rule-set decompile", which for
# a large list costs far more time and memory than the questions it guards.
# So it is learned once, where the list is stored: singbox/ruleset_cache.uc
# already decompiles every binary list it stores and records the check in
# "<list>.validated"; it records the shape there as well. routing/resolve.uc
# (route_trace, autotune groups and apply, every poll) reads that record and
# never decompiles; a binary list without a record of the file as it is now
# is undecidable.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
RULESET_CACHE_UC="$LIB/singbox/ruleset_cache.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/served" "$WORK/cache" "$WORK/runtime"
cat >"$WORK/bin/sing-box" <<EOF
#!/bin/sh
exec ucode -- "$ROOT_DIR/tests/helpers/sing_box_rule_set_stub.uc" "\$@"
EOF
# Serves https://lists.test/<name> from $WORK/served/<name>.
cat >"$WORK/bin/curl" <<'EOF'
#!/bin/sh
output=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --proxy|--connect-timeout|--max-time|--resolve) shift 2 ;;
    --fail|--location|--silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
cp "$SERVED_DIR/${url##*/}" "$output"
EOF
chmod +x "$WORK/bin/sing-box" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export SERVED_DIR="$WORK/served"
export RULESET_STUB_CALLS="$WORK/calls"
export PROKOP_RULESET_MATCH_BIN="$WORK/bin/sing-box"
export PROKOP_RULESET_CACHE_DIR="$WORK/cache"
export PROKOP_RULESET_CACHE_MANIFEST="$WORK/cache/manifest.json"
export PROKOP_RULESET_RUNTIME_CACHE_DIR="$WORK/runtime"
export PROKOP_RULESET_RUNTIME_MANIFEST="$WORK/runtime-manifest.json"
export PROKOP_PERSISTENT_LIST_CACHE_DIR="$WORK/list-cache"
export PROKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432
export PROKOP_LIST_DOWNLOAD_MIN_FREE_BYTES=0
: >"$WORK/calls"

# A "binary" list of the stand-in is "SRS" + source JSON.
serve() { printf 'SRS\n%s\n' "$2" >"$WORK/served/$1"; }
PLAIN='{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ] }, { "ip_cidr": [ "203.0.113.0/24" ] } ] }'
PORT='{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ], "port": [ 443 ] } ] }'
serve plain.srs "$PLAIN"
serve port.srs "$PORT"

cat >"$WORK/declared.json" <<'EOF'
{ "route": { "rule_set": [
  { "type": "remote", "tag": "plain", "format": "binary", "url": "https://lists.test/plain.srs" },
  { "type": "remote", "tag": "port", "format": "binary", "url": "https://lists.test/port.srs" } ] } }
EOF
materialize() { # [cache-only]
    cp "$WORK/declared.json" "$WORK/config.json"
    ucode -L "$LIB" "$RULESET_CACHE_UC" materialize-config "$WORK/config.json" "$@" || fail "materialize-config failed"
}
refresh() { ucode -L "$LIB" "$RULESET_CACHE_UC" refresh >/dev/null 2>&1 || true; }
path_of() { ucode -e 'let c = json(require("fs").readfile(ARGV[0])); for (let s in c.route.rule_set) if (s.tag == ARGV[1]) print(s.path);' "$WORK/config.json" "$1"; }
record() { cat "$(path_of "$1").validated"; }
signature() { stat -c '%i:%s:%Y:%Z' "$1"; }

cat >"$WORK/prokop" <<'EOF'
config settings 'settings'
config section 'youtube'
	option action 'zapret'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=multisplit'
config section 'main'
	option action 'connection'
EOF

# The materialized config with one rule per tag, in order; prints the result.
cat >"$WORK/resolve.uc" <<'EOF'
let fs = require("fs"), r = require("routing.resolve");
let sections = r.parse_config(fs.readfile(ARGV[0]));
let config = json(fs.readfile(ARGV[1]));
let extra = json(ARGV[4]);
config.route.final = "direct-out";
for (let s in extra) push(config.route.rule_set, s);
config.route.rules = map(split(ARGV[3], ","), (tag) => ({ action: "route", inbound: [ "tproxy-in" ], rule_set: [ tag ],
    outbound: tag == "plain" ? "youtube-out" : "main-out" }));
config.outbounds = [ { type: "direct", tag: "direct-out" }, { type: "vless", tag: "main-out" },
    { type: "direct", tag: "youtube-out", routing_mark: 16777217 } ];
let got = r.resolve(config, sections, r.target(ARGV[2], "198.18.0.9", { fakeip: true }));
print(join(" ", map([ got.status, got.route_rule, got.section ], (v) => v == null ? "null" : "" + v)), "\n");
EOF
resolve() { # host tags [extra rule_set entries]
    : >"$WORK/calls"
    ucode -L "$LIB" "$WORK/resolve.uc" "$WORK/prokop" "$WORK/config.json" "$1" "$2" "${3:-[]}"
}
expect() { # name host tags want [extra]
    local got
    got="$(resolve "$2" "$3" "${5:-[]}")"
    [ "$got" = "$4" ] || fail "$1: got [$got], want [$4]"
    if grep -q '^rule-set decompile' "$WORK/calls"; then fail "$1: the resolver decompiled a list"; fi
}

# ---- the shape is recorded where the list is stored -------------------------
materialize
[ "$(record plain)" = "$(signature "$(path_of plain)")
plain" ] || fail "the record of a plain list is not [signature, plain]: $(record plain)"
[ "$(record port)" = "$(signature "$(path_of port)")
other" ] || fail "the record of a list with a port is not [signature, other]: $(record port)"

# ---- the resolver reads it and never decompiles -----------------------------
expect plain_hit youtube.com plain "decided 0 youtube"
grep -q '^rule-set match -f binary ' "$WORK/calls" || fail "plain_hit: the list was not asked"
expect plain_miss nothing.test plain "decided null null"
expect port_list youtube.com port,plain "undecidable 0 null"
if grep -q '^rule-set match ' "$WORK/calls"; then fail "port_list: a list sing-box cannot answer for was asked"; fi

# A binary list the cache did not store (a local .srs of the user) has no
# record: undecidable, never decompiled.
cp "$WORK/served/plain.srs" "$WORK/user.srs"
user="[ { \"type\": \"local\", \"tag\": \"user\", \"format\": \"binary\", \"path\": \"$WORK/user.srs\" } ]"
expect user_list youtube.com user,plain "undecidable 0 null" "$user"

# A record of an older file says nothing about the file as it is now.
plain_path="$(path_of plain)"
cp "$plain_path" "$WORK/plain.keep"
printf 'SRS\n%s\n' "$PORT" >"$plain_path"
expect stale_record youtube.com plain "undecidable 0 null"
cp "$WORK/plain.keep" "$plain_path"

# A record written before the shape was kept (signature only) is checked
# again by the cache the next time it reads the list, once.
printf '%s\n' "$(signature "$plain_path")" >"$plain_path.validated"
expect legacy_record youtube.com plain "undecidable 0 null"
: >"$WORK/calls"
materialize cache-only
grep -q "^rule-set decompile $plain_path " "$WORK/calls" || fail "legacy_record: the cache did not check the list again"
[ "$(record plain)" = "$(signature "$plain_path")
plain" ] || fail "legacy_record: the shape was not recorded: $(record plain)"
: >"$WORK/calls"
materialize cache-only
if grep -q '^rule-set decompile' "$WORK/calls"; then fail "legacy_record: a recorded list was decompiled again"; fi
expect legacy_record_checked youtube.com plain "decided 0 youtube"

# ---- refreshes keep the record right ---------------------------------------
# The same bytes: no decompile, the shape stays.
: >"$WORK/calls"
refresh
if grep -q '^rule-set decompile' "$WORK/calls"; then fail "identical refresh: decompiled"; fi
[ "$(record plain)" = "$(signature "$plain_path")
plain" ] || fail "identical refresh: the record changed: $(record plain)"
expect identical_refresh youtube.com plain "decided 0 youtube"
# New bytes of another shape: checked, and the new shape recorded.
serve plain.srs "$PORT"
refresh
[ "$(record plain)" = "$(signature "$plain_path")
other" ] || fail "changed refresh: the new shape was not recorded: $(record plain)"
expect changed_refresh youtube.com plain "undecidable 0 null"
# Flash too full to keep it: the list goes to tmpfs with its record.
serve plain.srs "$PLAIN"
PROKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=8390000 refresh
materialize cache-only
runtime_path="$(path_of plain)"
case "$runtime_path" in "$WORK/runtime"/*) ;; *) fail "low flash: the list was not served from tmpfs ($runtime_path)" ;; esac
[ "$(record plain)" = "$(signature "$runtime_path")
plain" ] || fail "low flash: the record of the tmpfs list is wrong: $(record plain)"
expect runtime_list youtube.com plain "decided 0 youtube"
# Space again: promoted to flash with its record.
refresh
materialize cache-only
[ "$(path_of plain)" = "$plain_path" ] || fail "promotion: the list was not moved back to flash"
[ "$(record plain)" = "$(signature "$plain_path")
plain" ] || fail "promotion: the record of the promoted list is wrong: $(record plain)"
expect promoted_list youtube.com plain "decided 0 youtube"

echo "routing_resolve_rule_set_shape: ok"
