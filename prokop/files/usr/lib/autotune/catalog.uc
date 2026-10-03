#!/usr/bin/env ucode

// Fixed candidate catalog for DPI autotune. Every candidate is a named
// template with a fixed nfqws option set; nothing is generated or combined at
// runtime. The option syntax follows the installed nfqws (zapret v72) and the
// TCP/443 part of Prokop's own default strategy (ZAPRET_DEFAULT_NFQWS_OPT).
let fs = require("fs");
let constants = require("core.constants");
let zapret_validator = require("providers.zapret.validator");

const QUEUE = getenv("PROKOP_AUTOTUNE_QUEUE") || "4600";
const NFQWS = getenv("ZAPRET_NFQWS_BIN") || constants.ZAPRET_NFQWS_BIN;
const DESYNC_MARK = getenv("ZAPRET_DESYNC_MARK") || constants.ZAPRET_DESYNC_MARK;
const TLS_FAKE_MOD = "--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com";

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
      probe_unavailable: "quic_probe_unavailable" }
];

function as_string(value) { return value == null ? "" : "" + value; }
function quote(value) { return "'" + replace(as_string(value), /'/g, "'\\''") + "'"; }
function words(value) {
    value = trim(replace(as_string(value), /[ \t\r\n]+/g, " "));
    return value == "" ? [] : split(value, " ");
}

function entries() {
    let result = [];
    for (let entry in ENTRIES) push(result, { ...entry });
    return result;
}

function find(id) {
    for (let entry in ENTRIES)
        if (entry.id == id)
            return { ...entry };
    return null;
}

function binary_available() {
    let stat = fs.stat(NFQWS);
    return stat != null && stat.type == "file" && (int(stat.mode) & 73) != 0;
}

// Syntax check by the installed binary. --dry-run parses the options and exits
// without binding a queue or touching packets.
function dry_run(opt) {
    let args = [ NFQWS, "--dry-run", "--qnum=" + QUEUE, "--dpi-desync-fwmark=" + DESYNC_MARK ];
    for (let word in words(opt)) push(args, word);
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return system(join(" ", parts) + " >/dev/null 2>&1") == 0;
}

function validate_entry(entry) {
    let result = {
        id: entry.id, family: entry.family, protocol: entry.protocol, port: entry.port,
        rank: entry.rank, nfqws_opt: entry.nfqws_opt, description: entry.description,
        enabled: false, state: "unsupported", reason: null
    };
    if (entry.nfqws_opt != "") {
        // IP fragments carry no TCP header after the first one, so the probe
        // tuple rules could not normalize or contain them.
        if (match(entry.nfqws_opt, /ipfrag/) != null) {
            result.reason = "ipfrag_unsupported_by_isolation";
            return result;
        }
        let checked = zapret_validator.validate_strategy("nfqws", entry.nfqws_opt,
            constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT);
        if (!checked.valid) {
            result.reason = "validator: " + as_string(checked.message);
            return result;
        }
        if (!binary_available()) {
            result.reason = "nfqws_unavailable";
            return result;
        }
        if (!dry_run(entry.nfqws_opt)) {
            result.reason = "nfqws_dry_run_rejected";
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
    return { entries, find, validate_entry, validate_all, words };

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
