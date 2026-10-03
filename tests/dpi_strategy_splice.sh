#!/usr/bin/env bash
set -euo pipefail

# core/dpi_strategy.uc tcp443_splice: autotune replaces only the TCP/443
# profile of a zapret strategy. nfqws uses the first profile whose filters
# match, so the profile replaced must be the first that takes TCP/443 and must
# take nothing else; every other profile stays word for word, and the replaced
# profile keeps its own selection (filters, host lists).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cat >"$WORK/cases.uc" <<'EOF'
let d = require("core.dpi_strategy");
let c = "--filter-tcp=443 --dpi-desync=multidisorder --dpi-desync-split-pos=1,midsld";
let s = (current, candidate) => d.tcp443_splice(current, candidate || c);
print(sprintf("%J\n", {
    single: s("--filter-tcp=443 --dpi-desync=fake"),
    second: s("--filter-tcp=80 --dpi-desync=fake --new --filter-tcp=443 --hostlist=/x.txt --dpi-desync=fake --new --filter-udp=443 --dpi-desync=fake"),
    udp_first: s("--filter-udp=443 --dpi-desync=fake --new --filter-tcp=443 --dpi-desync=fake"),
    shared_list: s("--filter-tcp=80,443 --dpi-desync=fake"),
    shared_range: s("--filter-tcp=1-65535 --dpi-desync=fake --new --filter-tcp=443 --dpi-desync=fake"),
    unfiltered_first: s("--dpi-desync=fake --new --filter-tcp=443 --dpi-desync=fake"),
    l7: s("--filter-tcp=443 --filter-l7=tls --dpi-desync=fake"),
    two_words: s("--filter-tcp 443 --dpi-desync=fake"),
    none: s("--filter-tcp=80 --dpi-desync=fake"),
    empty: s(""),
    bad_candidate: s("--filter-tcp=443 --dpi-desync=fake", "--filter-tcp=443 --dpi-desync=fake --new --filter-udp=443 --dpi-desync=fake"),
    other_port_skipped: s("--filter-tcp=8443 --dpi-desync=fake --new --filter-tcp=443 --dpi-desync=fake")
}));
EOF
PROKOP_LIB="$LIB" ucode -L "$LIB" "$WORK/cases.uc" >"$WORK/out.json"

node - "$WORK/out.json" <<'NODE'
const a = require('node:assert/strict');
const r = require(process.argv[2]);
const md = '--dpi-desync=multidisorder --dpi-desync-split-pos=1,midsld';
a.deepEqual(r.single, { opt: `--filter-tcp=443 ${md}`, profile: 0, before: '--filter-tcp=443 --dpi-desync=fake', after: `--filter-tcp=443 ${md}` });
a.equal(r.second.opt, `--filter-tcp=80 --dpi-desync=fake --new --filter-tcp=443 --hostlist=/x.txt ${md} --new --filter-udp=443 --dpi-desync=fake`,
  'only the TCP/443 profile changes, and it keeps its host list');
a.equal(r.second.profile, 1);
a.equal(r.udp_first.profile, 1, 'a UDP-only profile does not take TCP/443');
a.equal(r.shared_list.error, 'tcp443_profile_shared');
a.equal(r.shared_range.error, 'tcp443_profile_shared', 'an earlier profile covering 443 wins in nfqws');
a.equal(r.unfiltered_first.error, 'tcp443_profile_shared', 'a profile without filters takes TCP/443 too');
a.equal(r.l7.error, 'tcp443_profile_shared', 'an L7-filtered profile is not the whole TCP/443 traffic');
a.equal(r.two_words.error, 'strategy_unparsed');
a.equal(r.none.error, 'no_tcp443_profile');
a.equal(r.empty.error, 'strategy_empty');
a.equal(r.bad_candidate.error, 'candidate_not_tcp443');
a.equal(r.other_port_skipped.profile, 1, 'a profile for another TCP port is skipped');
console.log('dpi_strategy_splice: ok');
NODE
