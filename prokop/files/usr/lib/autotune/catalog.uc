#!/usr/bin/env ucode

// Fixed candidate catalog for DPI autotune. Every candidate is a named
// template with a fixed nfqws (Zapret) or nfqws2 (Zapret2) option set;
// nothing is generated or combined at runtime. The option syntax follows the
// installed nfqws (zapret v72) / nfqws2 (zapret2 v1) and the TCP/443 part of
// Prokop's own default strategy (ZAPRET_DEFAULT_NFQWS_OPT).
//
// Tiers: a run measures one tier of one provider (at most eight DPI
// candidates, the temporary queues of one isolated run). Tier 1 is measured
// first; tier 2 only when tier 1 found no stable strategy for the target
// (autotune/manager.uc).
//
// Zapret tier 2: strategy set derived from bol-van/zapret blockcheck.sh
// (MIT, (c) bol-van): fake with md5sig, badseq and ts fooling, a fixed low
// TTL fake, seqovl splits, syndata and fakedsplit altorder. Not included:
// --dpi-desync-autottl and --wssize, which act on the incoming SYN,ACK:
// Prokop queues only outgoing packets (production and the isolated probe
// alike), so they would measure as their plain variants.
// ttl_based: the fake dies on its way by TTL, which breaks near servers
// (a CDN node a few hops away, Re:HomeProxy wiki/ByeDPI-ru.md): such a
// candidate never reaches high confidence on a single target
// (autotune/groups.uc).
//
// Zapret2 candidates: the TCP/443 (TLS ClientHello) profiles of the nfqws2
// candidate list of Re:HomeProxy (1andrevich/homeproxy-hiddify,
// root/etc/homeproxy/zapret_candidates.json at a9e3596, GPL-2.0), ported as
// data; their tester, which edits the live fw4 chains, is not used: the
// candidates run through Prokop's own isolated path.
let fs = require("fs");
let constants = require("core.constants");
let zapret_validator = require("providers.zapret.validator");
let zapret2_validator = require("providers.zapret2.validator");
let dpi_strategy = require("core.dpi_strategy");

const QUEUE = getenv("PROKOP_AUTOTUNE_QUEUE") || "4600";
const NFQWS = getenv("ZAPRET_NFQWS_BIN") || constants.ZAPRET_NFQWS_BIN;
const DESYNC_MARK = getenv("ZAPRET_DESYNC_MARK") || constants.ZAPRET_DESYNC_MARK;
const TLS_FAKE_MOD = "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com";
const NFQWS2 = getenv("ZAPRET2_NFQWS2_BIN") || constants.ZAPRET2_NFQWS2_BIN;
const Z2_LUA = getenv("ZAPRET2_PROVIDER_LUA_DIR") || constants.ZAPRET2_PROVIDER_LUA_DIR;
const Z2_FILES = getenv("ZAPRET2_PROVIDER_FILES_DIR") || constants.ZAPRET2_PROVIDER_FILES_DIR;
const Z2_TLS = "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello";
const PROVIDERS = [ "zapret", "zapret2" ];

// rank: number and aggressiveness of the transformations. At a comparable
// result the candidate with the lower rank is preferred.
const ENTRIES = [
    { id: "direct", family: "control", protocol: "tcp", port: 443, rank: 0, nfqws_opt: "",
      description: "No transformation: plain direct connection (control)" },
    { id: "multisplit", family: "split", protocol: "tcp", port: 443, rank: 1,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld",
      description: "Split the TLS ClientHello into ordered segments; no fake packets" },
    { id: "fake", family: "fake", protocol: "tcp", port: 443, rank: 2,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=badsum " + TLS_FAKE_MOD,
      description: "One fake ClientHello with a bad checksum before the real one" },
    { id: "multidisorder", family: "split", protocol: "tcp", port: 443, rank: 2,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=multidisorder --dpi-desync-split-pos=1,midsld",
      description: "Split the ClientHello and send the segments in reverse order" },
    { id: "fakedsplit", family: "fake_split", protocol: "tcp", port: 443, rank: 3,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=fakedsplit --dpi-desync-split-pos=midsld --dpi-desync-fooling=badsum",
      description: "Split at the SLD middle with fake segments interleaved" },
    { id: "fake_multisplit", family: "fake_split", protocol: "tcp", port: 443, rank: 3,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=fake,multisplit --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badsum " + TLS_FAKE_MOD,
      description: "Fake ClientHello followed by an ordered split" },
    { id: "hostfakesplit", family: "fake_split", protocol: "tcp", port: 443, rank: 3,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=hostfakesplit --dpi-desync-fooling=badsum",
      description: "Split around the hostname with fake hostname segments" },
    { id: "fake_multidisorder", family: "fake_split", protocol: "tcp", port: 443, rank: 4,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum " + TLS_FAKE_MOD,
      description: "TCP/443 part of the Prokop default strategy" },
    { id: "udp_fake", family: "fake", protocol: "udp", port: 443, rank: 2,
      nfqws_opt: "--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin",
      description: "Fake QUIC Initial (UDP/443 part of the Prokop default strategy)",
      probe_unavailable: "quic_probe_unavailable" },
    // ---- Zapret tier 2 (blockcheck.sh) ----
    { id: "fake_md5sig", family: "fake", protocol: "tcp", port: 443, rank: 2, tier: 2,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=md5sig " + TLS_FAKE_MOD,
      description: "Fake ClientHello with a TCP MD5 signature option" },
    { id: "fake_badseq", family: "fake", protocol: "tcp", port: 443, rank: 2, tier: 2,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=badseq " + TLS_FAKE_MOD,
      description: "Fake ClientHello with a wrong sequence number" },
    { id: "fake_ts", family: "fake", protocol: "tcp", port: 443, rank: 2, tier: 2,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=ts " + TLS_FAKE_MOD,
      description: "Fake ClientHello with an old TCP timestamp" },
    { id: "fake_ttl", family: "fake", protocol: "tcp", port: 443, rank: 3, tier: 2, ttl_based: true,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=fake --dpi-desync-ttl=4 " + TLS_FAKE_MOD,
      description: "Fake ClientHello that expires after a few hops (TTL)" },
    { id: "multisplit_seqovl", family: "split", protocol: "tcp", port: 443, rank: 2, tier: 2,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=10,midsld --dpi-desync-split-seqovl=1",
      description: "Ordered split with a one-byte sequence overlap" },
    { id: "multidisorder_seqovl", family: "split", protocol: "tcp", port: 443, rank: 3, tier: 2,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=multidisorder --dpi-desync-split-pos=midsld --dpi-desync-split-seqovl=midsld-1",
      description: "Reverse-order split with a sequence overlap up to the SLD middle" },
    { id: "syndata_multisplit", family: "syndata", protocol: "tcp", port: 443, rank: 3, tier: 2,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=syndata,multisplit --dpi-desync-split-pos=1,midsld",
      description: "Data in the SYN packet, then an ordered split" },
    { id: "fakedsplit_altorder", family: "fake_split", protocol: "tcp", port: 443, rank: 3, tier: 2,
      nfqws_opt: "--filter-tcp=443 --dpi-desync=fakedsplit --dpi-desync-split-pos=midsld --dpi-desync-fakedsplit-mod=altorder=1 --dpi-desync-fooling=badsum",
      description: "Faked split with the alternative segment order" },
    // ---- Zapret2 tier 1 (Re:HomeProxy "recommended") ----
    { id: "z2_default", provider: "zapret2", family: "fake_split", protocol: "tcp", port: 443, rank: 4,
      nfqws_opt: Z2_TLS + " --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld",
      description: "Zapret2 default TCP/443 profile: fake and reverse-order split" },
    { id: "z2_fake_multisplit", provider: "zapret2", family: "fake_split", protocol: "tcp", port: 443, rank: 3,
      nfqws_opt: Z2_TLS + " --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multisplit:pos=1,midsld",
      description: "Fake ClientHello and an ordered split" },
    { id: "z2_fake", provider: "zapret2", family: "fake", protocol: "tcp", port: 443, rank: 2,
      nfqws_opt: Z2_TLS + " --lua-desync=fake:blob=fake_default_tls:tcp_md5",
      description: "One fake ClientHello with a TCP MD5 signature" },
    { id: "z2_fake_rnd", provider: "zapret2", family: "fake_split", protocol: "tcp", port: 443, rank: 4,
      nfqws_opt: Z2_TLS + " --lua-desync=fake:blob=fake_default_tls:tcp_seq=-10000:tls_mod=rnd,dupsid:repeats=11 --lua-desync=multidisorder:pos=1,midsld",
      description: "Repeated randomized fakes and a reverse-order split" },
    { id: "z2_fake_seqovl", provider: "zapret2", family: "fake_split", protocol: "tcp", port: 443, rank: 4,
      nfqws_opt: Z2_TLS + " --lua-desync=fake:blob=fake_default_tls:tcp_seq=-10000:repeats=8 --lua-desync=multisplit:pos=1:seqovl=679:seqovl_pattern=fake_default_tls",
      description: "Fakes and a split overlapped by a fake pattern" },
    { id: "z2_google_seqovl", provider: "zapret2", family: "split", protocol: "tcp", port: 443, rank: 3,
      nfqws_opt: "--blob=tls_google:@" + Z2_FILES + "/fake/tls_clienthello_www_google_com.bin " + Z2_TLS +
        " --lua-desync=multisplit:pos=2,sniext+1:seqovl=679:seqovl_pattern=tls_google",
      description: "Split overlapped by a Google ClientHello (YouTube profile)" },
    { id: "z2_hostfakesplit", provider: "zapret2", family: "fake_split", protocol: "tcp", port: 443, rank: 3,
      nfqws_opt: Z2_TLS + " --lua-desync=hostfakesplit:host=www.google.com:tcp_ts=-1000:repeats=4",
      description: "Split around the hostname with fake hostname segments" },
    { id: "z2_syndata_disorder", provider: "zapret2", family: "syndata", protocol: "tcp", port: 443, rank: 3,
      nfqws_opt: Z2_TLS + " --lua-desync=syndata --lua-desync=multidisorder:pos=1,midsld",
      description: "Data in the SYN packet, then a reverse-order split" },
    // ---- Zapret2 tier 2 (Re:HomeProxy "auto") ----
    { id: "z2_split2", provider: "zapret2", family: "split", protocol: "tcp", port: 443, rank: 1, tier: 2,
      nfqws_opt: Z2_TLS + " --lua-desync=multisplit:pos=2", description: "Ordered split after the second byte" },
    { id: "z2_split_sniext", provider: "zapret2", family: "split", protocol: "tcp", port: 443, rank: 1, tier: 2,
      nfqws_opt: Z2_TLS + " --lua-desync=multisplit:pos=sniext+1", description: "Ordered split inside the SNI extension" },
    { id: "z2_disorder1", provider: "zapret2", family: "split", protocol: "tcp", port: 443, rank: 2, tier: 2,
      nfqws_opt: Z2_TLS + " --lua-desync=multidisorder:pos=1", description: "Reverse-order split after the first byte" },
    { id: "z2_seqovl_split", provider: "zapret2", family: "split", protocol: "tcp", port: 443, rank: 2, tier: 2,
      nfqws_opt: Z2_TLS + " --lua-desync=multisplit:pos=10,sniext+1:seqovl=1", description: "Ordered split with a one-byte overlap" },
    { id: "z2_seqovl_disorder", provider: "zapret2", family: "split", protocol: "tcp", port: 443, rank: 3, tier: 2,
      nfqws_opt: Z2_TLS + " --lua-desync=multidisorder:pos=2:seqovl=1", description: "Reverse-order split with a one-byte overlap" },
    { id: "z2_fake_badsum", provider: "zapret2", family: "fake", protocol: "tcp", port: 443, rank: 2, tier: 2,
      nfqws_opt: Z2_TLS + " --lua-desync=fake:blob=fake_default_tls:badsum", description: "Fake ClientHello with a bad checksum" },
    { id: "z2_fake_badseq", provider: "zapret2", family: "fake", protocol: "tcp", port: 443, rank: 2, tier: 2,
      nfqws_opt: Z2_TLS + " --lua-desync=fake:blob=fake_default_tls:tcp_seq=-3000", description: "Fake ClientHello with a wrong sequence number" },
    { id: "z2_fake_ts", provider: "zapret2", family: "fake", protocol: "tcp", port: 443, rank: 2, tier: 2,
      nfqws_opt: Z2_TLS + " --lua-desync=fake:blob=fake_default_tls:tcp_ts=-1000", description: "Fake ClientHello with an old TCP timestamp" }
];

function as_string(value) { return value == null ? "" : "" + value; }
function quote(value) { return "'" + replace(as_string(value), /'/g, "'\\''") + "'"; }

// Every entry with its defaults: provider "zapret", tier 1.
function full(entry) {
    return { provider: "zapret", tier: 1, ttl_based: false, ...entry };
}

function entries() {
    let result = [];
    for (let entry in ENTRIES) push(result, full(entry));
    return result;
}

function find(id) {
    for (let entry in ENTRIES)
        if (entry.id == id)
            return full(entry);
    return null;
}

// The ids of one tier of one provider, in catalog order.
function tier_ids(provider, tier) {
    let result = [];
    for (let e in entries()) if (e.provider == (provider || "zapret") && e.tier == int(tier || 1)) push(result, e.id);
    return result;
}
function tiers(provider) {
    let result = [];
    for (let e in entries()) if (e.provider == (provider || "zapret") && index(result, e.tier) < 0) push(result, e.tier);
    return sort(result);
}

function binary_of(provider) { return provider == "zapret2" ? NFQWS2 : NFQWS; }

// The process a candidate runs as: the binary, its queue, the desync mark of
// the isolated path and (nfqws2) the provider's Lua libraries, then the
// candidate's own options. The isolated path normalizes exactly this mark
// (autotune/isolation.uc), so nfqws2 gets it too, not production's.
function argv_prefix(provider, queue) {
    if (provider == "zapret2")
        return [ NFQWS2, "--qnum=" + queue, "--fwmark=" + DESYNC_MARK,
            "--lua-init=@" + Z2_LUA + "/zapret-lib.lua", "--lua-init=@" + Z2_LUA + "/zapret-antidpi.lua" ];
    return [ NFQWS, "--qnum=" + queue, "--dpi-desync-fwmark=" + DESYNC_MARK ];
}

function binary_available(provider) {
    let stat = fs.stat(binary_of(provider));
    return stat != null && stat.type == "file" && (int(stat.mode) & 73) != 0;
}

// Syntax check by the installed binary. --dry-run parses the options and exits
// without binding a queue or touching packets.
function dry_run(opt, provider) {
    let prefix = argv_prefix(provider, QUEUE);
    let args = [ prefix[0], "--dry-run", ...slice(prefix, 1) ];
    for (let word in dpi_strategy.words(opt)) push(args, word);
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return system(join(" ", parts) + " >/dev/null 2>&1") == 0;
}

function validate_entry(entry) {
    entry = full(entry);
    let result = {
        id: entry.id, provider: entry.provider, tier: entry.tier, ttl_based: entry.ttl_based,
        family: entry.family, protocol: entry.protocol, port: entry.port,
        rank: entry.rank, nfqws_opt: entry.nfqws_opt, description: entry.description,
        enabled: false, state: "unsupported", reason: null
    };
    let z2 = entry.provider == "zapret2";
    if (entry.nfqws_opt != "") {
        // IP fragments carry no TCP header after the first one, so the probe
        // tuple rules could not normalize or contain them.
        if (match(entry.nfqws_opt, /ipfrag/) != null) {
            result.reason = "ipfrag_unsupported_by_isolation";
            return result;
        }
        let checked = z2 ? zapret2_validator.validate_strategy("nfqws2", entry.nfqws_opt)
            : zapret_validator.validate_strategy("nfqws", entry.nfqws_opt, constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT);
        if (!checked.valid) {
            result.reason = "validator: " + as_string(checked.message);
            return result;
        }
        if (!binary_available(entry.provider)) {
            result.reason = z2 ? "nfqws2_unavailable" : "nfqws_unavailable";
            return result;
        }
        if (!dry_run(entry.nfqws_opt, entry.provider)) {
            result.reason = z2 ? "nfqws2_dry_run_rejected" : "nfqws_dry_run_rejected";
            return result;
        }
    }
    if (entry.probe_unavailable) {
        result.reason = entry.probe_unavailable;
        return result;
    }
    result.enabled = true;
    result.state = "supported";
    return result;
}

function validate_all() {
    let result = [];
    for (let entry in ENTRIES) push(result, validate_entry(entry));
    return result;
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return { entries, find, validate_entry, validate_all, tier_ids, tiers, argv_prefix, binary_of, PROVIDERS,
        words: dpi_strategy.words };

let mode = ARGV[0] || "";
if (mode == "list")
    print(sprintf("%J\n", entries()));
else if (mode == "validate") {
    if (ARGV[1]) {
        let entry = find(ARGV[1]);
        if (entry == null) {
            print(sprintf("%J\n", { id: ARGV[1], state: "unsupported", reason: "unknown_candidate" }));
            exit(1);
        }
        print(sprintf("%J\n", validate_entry(entry)));
    }
    else
        print(sprintf("%J\n", validate_all()));
}
else {
    warn("Usage: autotune/catalog.uc <list|validate [id]>\n");
    exit(1);
}
