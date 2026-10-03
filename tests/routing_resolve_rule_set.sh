#!/usr/bin/env bash
set -euo pipefail

# routing/resolve.uc decides a rule_set matcher by asking sing-box itself
# ("sing-box rule-set match") about the local list file the generated config
# names. A list it cannot ask about (remote, missing file, failing command,
# a target that is not a plain host/address) stays undecidable: never guessed.
#
# The stand-in for sing-box (helpers/sing_box_rule_set_stub.uc) answers the
# way the real binary does: a hit is printed on stderr ("match rules.[i]:"),
# stdout stays empty and the exit status is 0 with or without a hit (UC-198).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$WORK/sing-box" <<EOF
#!/bin/sh
exec ucode -- "$ROOT_DIR/tests/helpers/sing_box_rule_set_stub.uc" "\$@"
EOF
chmod +x "$WORK/sing-box"
export FORKOP_RULESET_MATCH_BIN="$WORK/sing-box"
export RULESET_STUB_CALLS="$WORK/calls"

# A "binary" list of the stand-in is "SRS" + source JSON, stored the way
# singbox/ruleset_cache.uc leaves it: with the record of its check and shape.
binary_list() {
    printf 'SRS\n%s\n' "$2" >"$WORK/$1"
    ucode -L "$LIB" "$ROOT_DIR/tests/helpers/rule_set_record.uc" "$WORK/$1"
}
binary_list youtube.srs '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ] } ] }'
binary_list other.srs '{ "version": 3, "rules": [ { "domain": [ "example.org" ] } ] }'
printf '%s\n' '{ "version": 3, "rules": [ { "ip_cidr": [ "203.0.113.7/32", "2001:db8::/32" ] } ] }' >"$WORK/addresses.json"
printf 'not a rule-set\n' >"$WORK/broken.srs"

cat >"$WORK/forkop" <<'EOF'
config settings 'settings'
config section 'youtube'
	option action 'zapret'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=multisplit'
config section 'main'
	option action 'connection'
EOF

cat >"$WORK/resolve.uc" <<'EOF'
let fs = require("fs"), r = require("routing.resolve");
let sections = r.parse_config(fs.readfile(ARGV[0]));
let c = json(fs.readfile(ARGV[1]));
let t = r.target(c.host, c.ip || "198.18.0.9", { fakeip: c.fakeip != false });
let config = { route: { final: "direct-out", rule_set: c.rule_set, rules: c.rules },
    outbounds: [ { type: "direct", tag: "direct-out" }, { type: "vless", tag: "main-out" },
        { type: "direct", tag: "youtube-out", routing_mark: 16777217 } ] };
let got = r.resolve(config, sections, t);
print(sprintf("%J\n", { status: got.status, reason: got.reason, rule: got.route_rule, section: got.section, kind: got.kind }));
EOF

# case <name> <json> -> prints the compact result
resolve() {
    printf '%s' "$2" >"$WORK/$1.json"
    : >"$WORK/calls"
    FORKOP_LIB="$LIB" ucode -L "$LIB" "$WORK/resolve.uc" "$WORK/forkop" "$WORK/$1.json"
}
expect() { # name json want
    local got
    got="$(resolve "$1" "$2")"
    [ "$got" = "$3" ] || fail "$1: got $got, want $3"
}

sets="[ { \"type\": \"local\", \"tag\": \"yt\", \"format\": \"binary\", \"path\": \"$WORK/youtube.srs\" },
  { \"type\": \"local\", \"tag\": \"other\", \"format\": \"binary\", \"path\": \"$WORK/other.srs\" },
  { \"type\": \"local\", \"tag\": \"addresses\", \"format\": \"source\", \"path\": \"$WORK/addresses.json\" },
  { \"type\": \"local\", \"tag\": \"broken\", \"format\": \"binary\", \"path\": \"$WORK/broken.srs\" },
  { \"type\": \"local\", \"tag\": \"absent\", \"format\": \"binary\", \"path\": \"$WORK/absent.srs\" },
  { \"type\": \"remote\", \"tag\": \"remote\", \"format\": \"binary\", \"url\": \"https://lists.invalid/x.srs\" } ]"
yt='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": "yt", "outbound": "youtube-out" }'
other='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": [ "other" ], "outbound": "main-out" }'
zapret='{ "status": "decided", "reason": null, "rule": 0, "section": "youtube", "kind": "rule" }'

# A list that holds the host decides the rule.
expect list_hit "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $yt ] }" "$zapret"
grep -qx "rule-set match -f binary $WORK/youtube.srs youtube.com" "$WORK/calls" || fail "list_hit: sing-box was not asked"

# A list above the owner that does not hold the host no longer hides it.
expect list_miss_above "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $other, $yt ] }" \
    '{ "status": "decided", "reason": null, "rule": 1, "section": "youtube", "kind": "rule" }'

# First match still wins: the list above holds the host.
expect list_hit_above "{ \"host\": \"example.org\", \"rule_set\": $sets, \"rules\": [ $other, $yt ] }" \
    '{ "status": "decided", "reason": null, "rule": 0, "section": "main", "kind": "rule" }'

# No list holds it: the final outbound.
expect list_miss_all "{ \"host\": \"nothing.test\", \"rule_set\": $sets, \"rules\": [ $other, $yt ] }" \
    '{ "status": "decided", "reason": null, "rule": null, "section": null, "kind": "direct" }'

# One rule, several lists: any of them matches; asking stops at the first hit.
many='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": [ "yt", "broken" ], "outbound": "youtube-out" }'
expect list_any "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $many ] }" "$zapret"
[ "$(grep -c '^rule-set match ' "$WORK/calls")" = 1 ] || fail "list_any: lists after the hit were asked"

# A static matcher hit needs no list at all.
mixed='{ "action": "route", "inbound": [ "tproxy-in" ], "domain_suffix": [ "youtube.com" ], "rule_set": [ "broken" ], "outbound": "youtube-out" }'
expect static_hit "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $mixed ] }" "$zapret"
[ ! -s "$WORK/calls" ] || fail "static_hit: a list was asked although a static matcher decided"

# A real-address connection is matched by the address as well as the host.
# Whether it reaches sing-box at all depends on nft, which holds a list's
# addresses only with subnet extraction (not shown in the sing-box config):
# undecidable unless a rule's ip_cidr proves the capture (UC-100).
addr='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": "addresses", "outbound": "youtube-out" }'
capture='{ "action": "route", "inbound": [ "tproxy-in" ], "ip_cidr": [ "203.0.113.0/24" ], "outbound": "main-out" }'
expect address_hit "{ \"host\": \"plain.test\", \"ip\": \"203.0.113.7\", \"fakeip\": false, \"rule_set\": $sets, \"rules\": [ $addr ] }" \
    '{ "status": "undecidable", "reason": "real_address_interception_unknown", "rule": 0, "section": null, "kind": null }'
grep -qx "rule-set match -f source $WORK/addresses.json 203.0.113.7" "$WORK/calls" || fail "address_hit: the address was not asked"
expect address_hit_captured "{ \"host\": \"plain.test\", \"ip\": \"203.0.113.7\", \"fakeip\": false, \"rule_set\": $sets, \"rules\": [ $addr, $capture ] }" "$zapret"
# An IPv6 address is outside the resolver's model (UC-096); the stand-in
# still matches IPv6 prefixes as the real binary does
# (routing_resolve_rule_set_real.sh).
expect address6_hit "{ \"host\": \"plain.test\", \"ip\": \"2001:db8::7\", \"fakeip\": false, \"rule_set\": $sets, \"rules\": [ $addr ] }" \
    '{ "status": "undecidable", "reason": "ipv6_not_modelled", "rule": null, "section": null, "kind": null }'
# A FakeIP connection reaches sing-box as the name: its address is not asked.
expect fakeip_address "{ \"host\": \"plain.test\", \"ip\": \"198.18.0.9\", \"rule_set\": $sets, \"rules\": [ $addr ] }" \
    '{ "status": "decided", "reason": null, "rule": null, "section": null, "kind": "direct" }'
! grep -q '198\.18\.0\.9' "$WORK/calls" || fail "fakeip_address: the FakeIP address was asked"

# Undecidable, never guessed.
undecided='{ "status": "undecidable", "reason": "undecidable_matcher", "rule": 0, "section": null, "kind": null }'
for tag in broken absent remote undeclared; do
    rule="{ \"action\": \"route\", \"inbound\": [ \"tproxy-in\" ], \"rule_set\": \"$tag\", \"outbound\": \"youtube-out\" }"
    expect "unknown_$tag" "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $rule ] }" "$undecided"
done
# A host that is not a plain name is never handed to a shell command.
expect unsafe_host "{ \"host\": \"you\$(id)tube.com\", \"rule_set\": $sets, \"rules\": [ $yt ] }" "$undecided"
[ ! -s "$WORK/calls" ] || fail "unsafe_host: sing-box was called"
# No list declaration at all (older callers): as before.
expect no_declaration "{ \"host\": \"youtube.com\", \"rules\": [ $yt ] }" "$undecided"

# The stand-in keeps the real output contract: the hit on stderr only.
[ -z "$("$WORK/sing-box" rule-set match -f binary "$WORK/youtube.srs" youtube.com 2>/dev/null)" ] ||
    fail "stub: a hit was printed on stdout"
"$WORK/sing-box" rule-set match -f binary "$WORK/youtube.srs" youtube.com 2>&1 >/dev/null |
    grep -q '^match rules\.\[0\]: ' || fail "stub: the hit was not printed on stderr"
# Anything else sing-box prints is not an answer it is known to give:
# undecidable, with or without a hit.
export RULESET_STUB_NOISE='WARN[0000] an unexpected message'
expect noise_with_hit "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $yt ] }" "$undecided"
expect noise_without_hit "{ \"host\": \"nothing.test\", \"rule_set\": $sets, \"rules\": [ $yt ] }" "$undecided"
unset RULESET_STUB_NOISE

# "rule-set match" asks with the value alone: the domain, or the address
# with port 0, no network and no source; and it carries the "address
# matched" state from one rule of the list to the next. A list rule with any
# other item (port, network, source, ...), invert or a logical rule is
# therefore answered wrongly, and such a list is undecidable (UC-218). A
# source list is read as it is; a binary one is known by the shape recorded
# where it was stored (routing_resolve_rule_set_shape.sh), never decompiled.
shape() { # name json -> a source list <name>.json and a binary <name>.srs
    printf '%s\n' "$2" >"$WORK/$1.json"
    binary_list "$1.srs" "$2"
}
shape tcp_only '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ], "network": "tcp" } ] }'
shape port_443 '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ], "port": [ 443 ] } ] }'
shape not_443 '{ "version": 3, "rules": [ { "port": [ 443 ], "invert": true } ] }'
shape inverted '{ "version": 3, "rules": [ { "domain": [ "example.org" ], "invert": true } ] }'
shape logical '{ "version": 3, "rules": [ { "type": "logical", "mode": "or", "rules": [ { "domain_suffix": [ "youtube.com" ] } ] } ] }'
shape source_ip '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ], "source_ip_cidr": [ "192.168.1.0/24" ] } ] }'
shape port_then_address '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ], "port": [ 80 ] }, { "ip_cidr": [ "198.51.100.0/24" ] } ] }'
shape plain '{ "version": 2, "rules": [ { "type": "default", "domain_suffix": [ "youtube.com" ], "invert": false }, { "domain_keyword": [ "tube" ], "domain_regex": [ "^x$" ], "ip_cidr": [ "198.51.100.0/24" ], "domain": [ "a.test" ] } ] }'
for name in tcp_only port_443 not_443 inverted logical source_ip port_then_address plain; do
    for format in source binary; do
        file="$WORK/$name.json"
        [ "$format" = binary ] && file="$WORK/$name.srs"
        shaped="[ { \"type\": \"local\", \"tag\": \"shaped\", \"format\": \"$format\", \"path\": \"$file\" } ]"
        list_rule='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": [ "shaped" ], "outbound": "main-out" }'
        want="$undecided"
        [ "$name" = plain ] && want='{ "status": "decided", "reason": null, "rule": 0, "section": "main", "kind": "rule" }'
        expect "shape_${name}_$format" "{ \"host\": \"youtube.com\", \"rule_set\": $shaped, \"rules\": [ $list_rule, $yt ] }" "$want"
        if [ "$name" != plain ] && grep -q '^rule-set match ' "$WORK/calls"; then
            fail "shape_${name}_$format: a list sing-box cannot answer for was asked"
        fi
    done
done
# A binary list without a record of the file as it is now: undecidable,
# and the resolver does not decompile it to find out.
cp "$WORK/plain.srs" "$WORK/unrecorded.srs"
unrecorded="[ { \"type\": \"local\", \"tag\": \"shaped\", \"format\": \"binary\", \"path\": \"$WORK/unrecorded.srs\" } ]"
list_rule='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": [ "shaped" ], "outbound": "main-out" }'
expect unrecorded_binary "{ \"host\": \"youtube.com\", \"rule_set\": $unrecorded, \"rules\": [ $list_rule, $yt ] }" "$undecided"
if grep -q '^rule-set decompile ' "$WORK/calls"; then fail "unrecorded_binary: the resolver decompiled a list"; fi

# A list path reaches sing-box as one argument, whatever it holds (UC-219):
# quotes, blanks, $(...), backticks and ";" never run anything. The
# validator accepts such a local rule_set path and the generator copies it.
mkdir "$WORK/hostile"
# shellcheck disable=SC2016 # the names are meant to hold unexpanded $(...)
for name in "a';touch\${IFS}PWNED;'.srs" 'b $(touch PWNED) `touch PWNED` ; touch PWNED.srs' "c'\\''; touch PWNED; '.srs"; do
    binary_list "hostile/$name" '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ] } ] }'
    path="$WORK/hostile/$name"
    hostile="[ { \"type\": \"local\", \"tag\": \"yt\", \"format\": \"binary\", \"path\": \"${path//\\/\\\\}\" } ]"
    got="$(cd "$WORK/hostile" && resolve hostile "{ \"host\": \"youtube.com\", \"rule_set\": $hostile, \"rules\": [ $yt ] }")"
    if [ -e "$WORK/hostile/PWNED" ] || [ -e "$WORK/PWNED" ]; then fail "hostile path $name: a command in the path was run"; fi
    [ "$got" = "$zapret" ] || fail "hostile path $name: got $got, want $zapret"
    grep -qxF "rule-set match -f binary $path youtube.com" "$WORK/calls" || fail "hostile path $name: sing-box was not asked about the file"
done

echo "routing_resolve_rule_set: ok"
