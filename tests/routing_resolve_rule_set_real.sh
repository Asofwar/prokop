#!/usr/bin/env bash
set -euo pipefail

# routing/resolve.uc against a real "sing-box rule-set match" (UC-198): the
# binary is $FORKOP_TEST_SING_BOX, else sing-box on PATH; without one the
# test is skipped. It also checks that the stand-in the other resolver tests
# use (helpers/sing_box_rule_set_stub.uc) answers exactly as the real binary:
# the same matching rule lines on stderr, nothing on stdout, the same exit
# status (UC-052: a stub must not diverge from what it stands for).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
STUB="$ROOT_DIR/tests/helpers/sing_box_rule_set_stub.uc"

SING_BOX="${FORKOP_TEST_SING_BOX:-$(command -v sing-box 2>/dev/null || true)}"
if [ -z "$SING_BOX" ] || [ ! -x "$SING_BOX" ]; then
    printf 'SKIP: routing_resolve_rule_set_real: no sing-box binary (set FORKOP_TEST_SING_BOX); the resolver is checked against the stand-in only\n'
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ---- the stand-in answers as the real binary does -------------------------

list() { printf '%s\n' "$2" >"$WORK/$1.json"; }
list plain '{ "version": 3, "rules": [ { "domain_suffix": [ "youtube.com" ] }, { "ip_cidr": [ "203.0.113.0/24", "2001:db8::/32" ] } ] }'
list port_first '{ "version": 3, "rules": [ { "domain_suffix": [ "a.test" ], "port": [ 443 ] }, { "ip_cidr": [ "203.0.113.0/24" ] } ] }'
list address_first '{ "version": 3, "rules": [ { "ip_cidr": [ "203.0.113.0/24" ] }, { "domain_suffix": [ "a.test" ] } ] }'
list logical '{ "version": 3, "rules": [ { "type": "logical", "mode": "and", "rules": [ { "domain_suffix": [ "x.test" ] }, { "port": [ 443 ] } ] }, { "domain": [ "inv.test" ], "invert": true }, { "type": "default", "domain": [ "d.test" ], "invert": false } ] }'
list mixed '{ "version": 3, "rules": [ { "domain_suffix": [ "p.test" ], "network": "tcp" }, { "port": [ 443 ], "invert": true }, { "domain_keyword": [ "kw" ] }, { "domain_regex": [ "^re[0-9]+\\.test$" ] }, { "type": "logical", "mode": "or", "rules": [ { "domain": [ "or1.test" ] }, { "ip_cidr": [ "198.51.100.0/24" ] } ] }, { "source_ip_cidr": [ "10.0.0.0/8" ], "domain": [ "src.test" ] }, { "domain": [ ".dot.test" ] }, { "domain_suffix": [ ".sub.test" ] } ] }'
list keyword '{ "version": 3, "rules": [ { "domain_keyword": [ "tube" ] }, { "domain": [ "exact.test" ] }, { "domain_suffix": [ ".only-sub.test" ] } ] }'

# rule lines (up to the colon) and exit status, stderr only; stdout must be empty
answer() { # binary list value
    local out
    out="$("$1" rule-set match -f source "$WORK/$2.json" "$3" 2>/dev/null)" || true
    [ -z "$out" ] || fail "$1 printed on stdout for $2/$3: $out"
    { "$1" rule-set match -f source "$WORK/$2.json" "$3" 2>&1 >/dev/null && echo "rc=0" || echo "rc=$?"; } | sed 's/: .*//'
}
cat >"$WORK/stub" <<EOF
#!/bin/sh
exec ucode -- "$STUB" "\$@"
EOF
chmod +x "$WORK/stub"

compared=0
for name in plain port_first address_first logical mixed keyword; do
    for value in youtube.com www.youtube.com a.test www.a.test x.test inv.test d.test p.test kw.test re12.test \
        or1.test src.test sub.test a.sub.test .dot.test exact.test www.exact.test only-sub.test a.only-sub.test \
        nothing.test 203.0.113.5 198.51.100.7 192.0.2.1 2001:db8::5 2001:db8:ffff::1 2001:dead::5 ::1; do
        real="$(answer "$SING_BOX" "$name" "$value")"
        stub="$(answer "$WORK/stub" "$name" "$value")"
        [ "$real" = "$stub" ] || fail "stand-in diverges on $name/$value: real [$real], stand-in [$stub]"
        compared=$((compared + 1))
    done
done
# A hit really is on stderr, and a missing file is an error.
"$SING_BOX" rule-set match -f source "$WORK/plain.json" youtube.com 2>&1 >/dev/null | grep -q '^match rules\.\[0\]: ' ||
    fail "real sing-box printed no hit on stderr"
if "$SING_BOX" rule-set match -f source "$WORK/absent.json" youtube.com >/dev/null 2>&1; then
    fail "real sing-box answered for a missing list"
fi

# ---- the resolver with the real binary ------------------------------------

# A binary list as singbox/ruleset_cache.uc stores it: decompiled once, by
# the real binary, and the shape of what it printed recorded next to it
# (the resolver itself never decompiles).
record() { # srs
    "$SING_BOX" rule-set decompile "$1" -o "$WORK/decompiled.json"
    ucode -L "$LIB" "$ROOT_DIR/tests/helpers/rule_set_record.uc" "$1" "$WORK/decompiled.json"
}
"$SING_BOX" rule-set compile "$WORK/plain.json" -o "$WORK/youtube.srs"
record "$WORK/youtube.srs"
list other '{ "version": 3, "rules": [ { "domain": [ "example.org" ] } ] }'

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

expect() { # name json want
    local got
    printf '%s' "$2" >"$WORK/case-$1.json"
    got="$(FORKOP_RULESET_MATCH_BIN="$SING_BOX" FORKOP_LIB="$LIB" ucode -L "$LIB" "$WORK/resolve.uc" "$WORK/forkop" "$WORK/case-$1.json")"
    [ "$got" = "$3" ] || fail "$1: got $got, want $3"
}

sets="[ { \"type\": \"local\", \"tag\": \"yt\", \"format\": \"binary\", \"path\": \"$WORK/youtube.srs\" },
  { \"type\": \"local\", \"tag\": \"other\", \"format\": \"source\", \"path\": \"$WORK/other.json\" } ]"
yt='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": "yt", "outbound": "youtube-out" }'
other='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": [ "other" ], "outbound": "main-out" }'
zapret='{ "status": "decided", "reason": null, "rule": 0, "section": "youtube", "kind": "rule" }'

# A list that holds the host owns it (it was "no" for every list: UC-198).
expect list_hit "{ \"host\": \"www.youtube.com\", \"rule_set\": $sets, \"rules\": [ $yt ] }" "$zapret"
# The real address as well (ip_cidr in the same list): sing-box takes it,
# but nft captures a list's addresses only with subnet extraction, so a rule
# with ip_cidr has to prove the capture (UC-100). IPv6 is outside the
# resolver's model (UC-096).
capture='{ "action": "route", "inbound": [ "tproxy-in" ], "ip_cidr": [ "203.0.113.0/24" ], "outbound": "main-out" }'
expect address_hit "{ \"host\": \"\", \"ip\": \"203.0.113.9\", \"fakeip\": false, \"rule_set\": $sets, \"rules\": [ $yt, $capture ] }" "$zapret"
expect address_uncaptured "{ \"host\": \"\", \"ip\": \"203.0.113.9\", \"fakeip\": false, \"rule_set\": $sets, \"rules\": [ $yt ] }" \
    '{ "status": "undecidable", "reason": "real_address_interception_unknown", "rule": 0, "section": null, "kind": null }'
expect address6_hit "{ \"host\": \"\", \"ip\": \"2001:db8::5\", \"fakeip\": false, \"rule_set\": $sets, \"rules\": [ $yt ] }" \
    '{ "status": "undecidable", "reason": "ipv6_not_modelled", "rule": null, "section": null, "kind": null }'
# A list above that does not hold the host passes it on; one that does wins.
expect list_miss_above "{ \"host\": \"www.youtube.com\", \"rule_set\": $sets, \"rules\": [ $other, $yt ] }" \
    '{ "status": "decided", "reason": null, "rule": 1, "section": "youtube", "kind": "rule" }'
expect list_hit_above "{ \"host\": \"example.org\", \"rule_set\": $sets, \"rules\": [ $other, $yt ] }" \
    '{ "status": "decided", "reason": null, "rule": 0, "section": "main", "kind": "rule" }'
expect list_miss_all "{ \"host\": \"nothing.test\", \"rule_set\": $sets, \"rules\": [ $other, $yt ] }" \
    '{ "status": "decided", "reason": null, "rule": null, "section": null, "kind": "direct" }'

# A list sing-box cannot answer for with the value alone (port, network,
# source, invert, logical rules) is undecidable, as source and as binary
# (its shape recorded from the real binary's decompile); a plain one is
# decided (UC-218).
for name in port_first logical mixed keyword; do
    "$SING_BOX" rule-set compile "$WORK/$name.json" -o "$WORK/$name.srs"
    record "$WORK/$name.srs"
    for format in source binary; do
        file="$WORK/$name.json"
        [ "$format" = binary ] && file="$WORK/$name.srs"
        shaped="[ { \"type\": \"local\", \"tag\": \"shaped\", \"format\": \"$format\", \"path\": \"$file\" } ]"
        rule='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": [ "shaped" ], "outbound": "youtube-out" }'
        want='{ "status": "undecidable", "reason": "undecidable_matcher", "rule": 0, "section": null, "kind": null }'
        [ "$name" = keyword ] && want="$zapret"
        expect "shape_${name}_$format" "{ \"host\": \"www.youtube.com\", \"rule_set\": $shaped, \"rules\": [ $rule ] }" "$want"
    done
done

# A quote in a list path reaches sing-box as part of one argument (UC-219).
mkdir "$WORK/hostile"
hostile_path="$WORK/hostile/a';touch\${IFS}PWNED;'.srs"
cp "$WORK/youtube.srs" "$hostile_path"
record "$hostile_path"
hostile="[ { \"type\": \"local\", \"tag\": \"yt\", \"format\": \"binary\", \"path\": \"$hostile_path\" } ]"
(cd "$WORK/hostile" && expect hostile_path "{ \"host\": \"www.youtube.com\", \"rule_set\": $hostile, \"rules\": [ $yt ] }" "$zapret")
[ ! -e "$WORK/hostile/PWNED" ] || fail "hostile_path: a command in the list path was run"

echo "routing_resolve_rule_set_real: ok ($compared answers compared with $SING_BOX)"
