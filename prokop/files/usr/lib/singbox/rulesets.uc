#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");

const SRS_MAIN_URL = constants.SRS_MAIN_URL;
const SRS_ADS_HAGEZI_PRO_URL = constants.SRS_ADS_HAGEZI_PRO_URL;
const SRS_SUPERCELL_URL = constants.SRS_SUPERCELL_URL;
const SRS_GITHUB_URL = constants.SRS_GITHUB_URL;

const COMMUNITY_SERVICES = {
    russia_inside: true,
    russia_outside: true,
    ukraine_inside: true,
    geoblock: true,
    block: true,
    porn: true,
    news: true,
    anime: true,
    youtube: true,
    hdrezka: true,
    tiktok: true,
    google_ai: true,
    google_play: true,
    hodca: true,
    discord: true,
    meta: true,
    twitter: true,
    cloudflare: true,
    cloudfront: true,
    digitalocean: true,
    hetzner: true,
    ovh: true,
    telegram: true,
    roblox: true,
    ads_hagezi_pro: true,
    supercell: true,
    github: true
};

// These community rule-sets carry address matchers next to their domains.
// sing-box 1.14 refuses to use an address rule-set as a DNS query filter: it
// has to be evaluated against the DNS response instead.
const COMMUNITY_MIXED_SERVICES = {
    discord: true,
    meta: true,
    twitter: true,
    cloudflare: true,
    cloudfront: true,
    digitalocean: true,
    hetzner: true,
    ovh: true,
    telegram: true,
    roblox: true
};

function as_string(value) {
    return value == null ? "" : "" + value;
}

function is_community(name) {
    return COMMUNITY_SERVICES[as_string(name)] === true;
}

function community_url(name) {
    name = as_string(name);
    if (name == "ads_hagezi_pro")
        return SRS_ADS_HAGEZI_PRO_URL;
    if (name == "supercell")
        return SRS_SUPERCELL_URL;
    if (name == "github")
        return SRS_GITHUB_URL;
    return SRS_MAIN_URL + "/" + name + ".srs";
}

function community_kind(name) {
    name = as_string(name);
    if (!is_community(name))
        return "unknown";
    return COMMUNITY_MIXED_SERVICES[name] === true ? "mixed" : "domains";
}

function hash12(value) {
    value = as_string(value);
    let first = 2166136261;
    let second = 16777619;

    for (let i = 0; i < length(value); i++) {
        let code = ord(substr(value, i, 1));
        first = (first * 33 + code) % 4294967296;
        second = (second * 131 + code) % 4294967296;
    }

    return sprintf("%06x%06x", first % 16777216, second % 16777216);
}

function file_extension(value) {
    let basename = as_string(value);
    let slash = rindex(basename, "/");
    if (slash >= 0)
        basename = substr(basename, slash + 1);

    let query = index(basename, "?");
    if (query >= 0)
        basename = substr(basename, 0, query);

    let fragment = index(basename, "#");
    if (fragment >= 0)
        basename = substr(basename, 0, fragment);

    let dot = rindex(basename, ".");
    return dot >= 0 ? lc(substr(basename, dot + 1)) : "";
}

function kind_from_reference_hint(reference) {
    reference = lc(as_string(reference));
    if (index(reference, "geosite") >= 0 || index(reference, "domain") >= 0 ||
        index(reference, "domains") >= 0 || index(reference, "adguard") >= 0 ||
        index(reference, "filter") >= 0)
        return "domains";
    if (index(reference, "geoip") >= 0 || index(reference, "subnet") >= 0 ||
        index(reference, "subnets") >= 0 || index(reference, "cidr") >= 0)
        return "subnets";
    return "unknown";
}

function remote_format(reference) {
    return file_extension(reference) == "json" ? "source" : "binary";
}

// The shape of a list (its source JSON) for "sing-box rule-set match"
// (routing/resolve.uc, UC-218). The command asks with the value alone (the
// domain, or the address with port 0: no network, port or source) and
// carries the "address matched" state from one rule of the list to the
// next, so its answer holds only for "plain": every rule a default rule of
// destination-address matchers only. Anything else (port, network, source,
// process, invert, a logical rule) is "other".
const PLAIN_LIST_KEYS = [ "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr" ];
function list_shape(value) {
    if (type(value) != "object" || type(value.rules) != "array")
        return "other";
    for (let rule in value.rules) {
        if (type(rule) != "object")
            return "other";
        for (let key, v in rule) {
            if (key == "type" ? v == "default" : key == "invert" ? v === false : index(PLAIN_LIST_KEYS, key) >= 0)
                continue;
            return "other";
        }
    }
    return "plain";
}

// The record singbox/ruleset_cache.uc keeps next to a binary list it stored,
// written when it decompiled the list to check it:
// "<inode>:<size>:<mtime>:<ctime>\n<shape>\n" of the file as it was then.
// It spares both the cache and routing/resolve.uc another decompile, which
// for a large list takes seconds and far more memory than a match.
function binary_validation_path(path) {
    return as_string(path) + ".validated";
}

function stat_signature(path) {
    let stat = fs.stat(path);
    return stat == null ? "" : join(":", [ stat.inode, stat.size, stat.mtime, stat.ctime ]);
}

// The shape recorded for the binary list as the file is now, or null: no
// record, a record of an older file, or one without the shape (written
// before the shape was kept).
function recorded_binary_shape(path) {
    let signature = stat_signature(path);
    let lines = split(as_string(fs.readfile(binary_validation_path(path))), "\n");
    return signature != "" && lines[0] == signature && (lines[1] == "plain" || lines[1] == "other") ? lines[1] : null;
}

function module_exports() {
    return {
        is_community,
        community_kind,
        community_url,
        hash12,
        file_extension,
        kind_from_reference_hint,
        remote_format,
        list_shape,
        binary_validation_path,
        stat_signature,
        recorded_binary_shape
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";

if (mode == "file-extension")
    print(file_extension(ARGV[1]), "\n");
else if (mode == "is-community")
    exit(is_community(ARGV[1]) ? 0 : 1);
else if (mode == "community-kind")
    print(community_kind(ARGV[1]), "
");
else if (mode == "kind-from-reference-hint")
    print(kind_from_reference_hint(ARGV[1]), "\n");
else if (mode == "remote-format")
    print(remote_format(ARGV[1]), "\n");
else if (mode == "community-url")
    print(community_url(ARGV[1]), "\n");
else {
    warn("Usage: singbox/rulesets.uc <file-extension|is-community|community-kind|kind-from-reference-hint|remote-format|community-url> ...\n");
    exit(1);
}
