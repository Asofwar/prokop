#!/usr/bin/env ucode

// How many packets of a connection a DPI rule hands to nfqws/nfqws2: the
// kernel-side limit `ct original packets 1-N` on the queue rules, after
// bol-van/zapret common/nft.sh nft_first_packets and config.default
// NFQWS_TCP_PKT_OUT/NFQWS_UDP_PKT_OUT (MIT, (c) bol-van), and the zapret2
// config.default NFQWS2_TCP_PKT_OUT/NFQWS2_UDP_PKT_OUT. It is the kernel
// form of `--dpi-desync-cutoff=nN`: the packets after N leave without the
// userspace round trip, which nfqws would have passed unchanged anyway.
//
// Opt-in (settings.nfqws_first_packets, off by default): a strategy that
// changes packets later in a connection must keep getting them, so N is
// derived from the strategy itself, per rule and per protocol, and whatever
// cannot be bounded from the options keeps the unlimited queue (null):
//
// nfqws (zapret): desync without --dpi-desync-any-protocol acts on the
// recognized protocol start (TLS ClientHello, QUIC Initial, HTTP request):
// the zapret default of 9 packets covers it, a multi-packet ClientHello and
// its retransmissions included. Later HTTP requests of a keep-alive
// connection are recognized again, so the plain HTTP ports of such a profile
// keep an unlimited queue rule of their own (NFQWS_PORTS_TCP_KEEPALIVE).
// Other UDP protocols (STUN, WireGuard, DHT, Discord) repeat their
// handshakes in one flow: unlimited unless the profile is QUIC-only.
// Anything that applies to every packet (--dpi-desync-any-protocol, --dup,
// --orig-*, --wssize) is bounded only by its own cutoff in packets (nX).
//
// nfqws2 (zapret2): every --lua-desync instance runs on the packets its
// --out-range and --payload let through (default: all of them). Bounded are
// an out-range ending in packets (nX), the handshake before the first data
// packet (d1, s1), and payloads that only start a connection
// (tls_client_hello, quic_initial; http_req as above). Anything else, or
// --import/--template/--ctrack-disable, keeps the unlimited queue.
//
// ct original packets counts the original direction only, the packet being
// classified included (conntrack runs at priority -200, before the
// mangle_output chain at -150), so the SYN is packet 1.

const BASE = {
    nfqws: { tcp: 9, udp: 9 },
    nfqws2: { tcp: 20, udp: 5 }
};
const START_PAYLOADS = [ "tls_client_hello", "quic_initial", "http_req" ];
const INF = -1;

function as_string(v) { return v == null ? "" : "" + v; }

function words(value) {
    value = trim(replace(as_string(value), /[ \t\r\n]+/g, " "));
    return value == "" ? [] : split(value, " ");
}

// [ { name, value } ] per profile ("--new" separated). A value is attached
// (--name=value) or the next word when that is not an option (the separate
// form the validator accepts for options that require a value).
function profiles(strategy) {
    let tokens = words(strategy), result = [ [] ];
    for (let i = 0; i < length(tokens); i++) {
        let t = tokens[i];
        if (substr(t, 0, 2) != "--") continue;          // <HOSTLIST> of the legacy default
        if (t == "--new") { push(result, []); continue; }
        let eq = index(t, "="), name = t, value = null;
        if (eq >= 0) { name = substr(t, 0, eq); value = substr(t, eq + 1); }
        else if (i + 1 < length(tokens) && substr(tokens[i + 1], 0, 2) != "--" && substr(tokens[i + 1], 0, 1) != "<") {
            value = tokens[i + 1];
            i++;
        }
        push(result[length(result) - 1], { name, value });
    }
    return result;
}

function list_values(value) {
    let result = [];
    for (let v in split(as_string(value), ","))
        if (trim(v) != "") push(result, trim(v));
    return result;
}

function contains(list, value) { return index(list, value) >= 0; }

// An optional on/off flag: present without value or with anything but 0.
function flag_on(entry) { return entry != null && entry.value != "0"; }

// The packets a "less than"/"up to" bound covers: nX (or X) in packets, d1
// and s1 the handshake before the first data packet (covered by the base);
// null when it cannot be expressed in packets.
function bound_packets(value, inclusive) {
    let m = match(as_string(value), /^(n?)([0-9]+)$/);
    if (m != null) {
        let n = int(m[2]);
        return inclusive ? n : (n > 0 ? n - 1 : 0);
    }
    m = match(as_string(value), /^([ds])([0-9]+)$/);
    if (m != null && int(m[2]) <= 1)
        return 0;
    return null;
}

function nft_ports(entries) {
    let result = [];
    for (let e in entries) {
        if (match(e, /^[0-9]+(-[0-9]+)?$/) == null) return null;
        push(result, e);
    }
    return result;
}

// The L4 protocols a profile matches, its port filters and L7 filter.
function scope(profile) {
    let s = { tcp_filter: null, udp_filter: null, other_l4: false, l7: null };
    for (let o in profile) {
        if (o.name == "--filter-tcp") s.tcp_filter = as_string(o.value);
        else if (o.name == "--filter-udp") s.udp_filter = as_string(o.value);
        else if (o.name == "--filter-icmp" || o.name == "--filter-ipp") s.other_l4 = true;
        else if (o.name == "--filter-l7") s.l7 = list_values(o.value);
    }
    let any = s.tcp_filter != null || s.udp_filter != null || s.other_l4;
    s.tcp = any ? s.tcp_filter != null : true;
    s.udp = any ? s.udp_filter != null : true;
    return s;
}

function l7_only(s, allowed) {
    if (s.l7 == null || length(s.l7) == 0) return false;
    for (let p in s.l7) if (!contains(allowed, p)) return false;
    return true;
}

function l7_may(s, proto) {
    return s.l7 == null || contains(s.l7, proto) || contains(s.l7, "unknown");
}

function raise(need, proto, value) {
    if (need[proto] == INF || value == INF) need[proto] = INF;
    else if (value > need[proto]) need[proto] = value;
}

// HTTP keep-alive: the profile's TCP ports apart from 443 get an unlimited
// rule; a profile without TCP port filter cannot name them.
function keepalive(need, s) {
    if (!s.tcp || !l7_may(s, "http")) return;
    if (s.tcp_filter == null) { raise(need, "tcp", INF); return; }
    let ports = nft_ports(filter(list_values(s.tcp_filter), (p) => p != "443"));
    if (ports == null) { raise(need, "tcp", INF); return; }
    for (let p in ports) if (!contains(need.keepalive, p)) push(need.keepalive, p);
}

function last(profile, name) {
    let found = null;
    for (let o in profile) if (o.name == name) found = o;
    return found;
}

// A feature that applies to every packet unless its own cutoff stops it.
function every_packet(cutoff, ctrack) {
    if (!ctrack || cutoff == null) return INF;
    let n = bound_packets(cutoff.value, false);
    return n == null ? INF : n;
}

function nfqws_profile(profile, need, base) {
    let s = scope(profile);
    if (last(profile, "--skip") != null) return;
    let ctrack = !flag_on(last(profile, "--ctrack-disable"));
    let desync = last(profile, "--dpi-desync");
    let cutoff = last(profile, "--dpi-desync-cutoff"), start = last(profile, "--dpi-desync-start");
    let cut = ctrack && cutoff != null ? bound_packets(cutoff.value, false) : null;
    let values = [];

    if (desync != null && as_string(desync.value) != "" && as_string(desync.value) != "none") {
        if (flag_on(last(profile, "--dpi-desync-any-protocol")))
            push(values, cut == null ? INF : cut);
        else if (cut != null)
            push(values, cut);
        else {
            let first = start != null ? bound_packets(start.value, true) : 0;
            push(values, first == null || first < base ? 0 : first);
            if (s.udp && !(l7_only(s, [ "quic" ]) || s.udp_filter == "443")) raise(need, "udp", INF);
            keepalive(need, s);
        }
    }
    // HTTP header modifications: every request.
    for (let name in [ "--hostcase", "--hostspell", "--hostnospace", "--domcase", "--methodeol" ])
        if (last(profile, name) != null) keepalive(need, s);
    let dup = last(profile, "--dup");
    if (dup != null && int(dup.value) > 0)
        push(values, every_packet(last(profile, "--dup-cutoff"), ctrack));
    for (let o in profile)
        if (substr(o.name, 0, 7) == "--orig-" && o.name != "--orig-mod-start" && o.name != "--orig-mod-cutoff") {
            push(values, every_packet(last(profile, "--orig-mod-cutoff"), ctrack));
            break;
        }
    if (last(profile, "--wssize") != null)
        push(values, every_packet(last(profile, "--wssize-cutoff"), ctrack));

    for (let v in values) {
        if (s.tcp) raise(need, "tcp", v);
        if (s.udp) raise(need, "udp", v);
    }
}

// The outgoing packets an --out-range lets through, in packets: 0 for "x"
// (none), the bound for an end in packets, null when unbounded.
function out_range_packets(value) {
    value = as_string(value);
    if (value == "x") return 0;
    if (value == "" || value == "a") return null;
    let m = match(value, /^(([nadsp])([0-9]+))?([-<])(([nadsp])([0-9]+))?$/);
    if (m == null || m[5] == null) return null;
    let inclusive = m[4] == "-";
    if (m[6] == "n") return inclusive ? int(m[7]) : (int(m[7]) > 0 ? int(m[7]) - 1 : 0);
    if ((m[6] == "d" || m[6] == "s") && !inclusive && int(m[7]) <= 1) return 0;
    return null;
}

function nfqws2_profile(profile, need) {
    let s = scope(profile);
    if (last(profile, "--skip") != null) return;
    if (last(profile, "--import") != null || last(profile, "--template") != null || flag_on(last(profile, "--ctrack-disable"))) {
        raise(need, "tcp", INF);
        raise(need, "udp", INF);
        return;
    }
    let payload = [ "all" ], range = null, values = [];
    for (let o in profile) {
        if (o.name == "--payload") payload = list_values(o.value);
        else if (o.name == "--out-range") range = o.value;
        else if (o.name == "--lua-desync") {
            let bounded = out_range_packets(range);
            if (bounded != null) { push(values, bounded); continue; }
            let starts = length(payload) > 0;
            for (let p in payload) if (!contains(START_PAYLOADS, p)) starts = false;
            if (!starts) { push(values, INF); continue; }
            push(values, 0);
            if (contains(payload, "http_req")) keepalive(need, s);
        }
    }
    for (let v in values) {
        if (s.tcp) raise(need, "tcp", v);
        if (s.udp) raise(need, "udp", v);
    }
}

// kind: "nfqws" or "nfqws2"; strategy: the effective option text of the
// rule. { tcp, udp, keepalive_tcp_ports }: tcp/udp the packet count N of the
// queue rule, null for unlimited.
function limits(kind, strategy) {
    let base = BASE[kind];
    if (base == null) return { tcp: null, udp: null, keepalive_tcp_ports: [] };
    let need = { tcp: 0, udp: 0, keepalive: [] };
    for (let profile in profiles(strategy)) {
        if (kind == "nfqws2") nfqws2_profile(profile, need);
        else nfqws_profile(profile, need, base.tcp);
    }
    let tcp = need.tcp == INF ? null : (need.tcp > base.tcp ? need.tcp : base.tcp);
    let udp = need.udp == INF ? null : (need.udp > base.udp ? need.udp : base.udp);
    return { tcp, udp, keepalive_tcp_ports: tcp == null ? [] : need.keepalive };
}

// The provider action of a rule ("zapret", "zapret2") to its kind.
function kind_of(action) {
    return action == "zapret2" ? "nfqws2" : action == "zapret" ? "nfqws" : null;
}

function enabled_value(value) {
    value = lc(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

// The limits of a provider rule (UCI section object) with its action
// ("zapret", "zapret2"): from the strategy it runs, its option or the
// provider default (providers/nfqueue/runtime.uc raw_strategy). Unlimited
// for any other action.
function section_limits(action, section) {
    let kind = kind_of(action);
    if (kind == null) return { tcp: null, udp: null, keepalive_tcp_ports: [] };
    let cfg = require("providers." + action + ".common").config({ constants: require("core.constants") });
    let value = type(section) == "object" ? section[cfg.strategy_option] : null;
    if (type(value) == "array") value = join(" ", value);
    return limits(kind, cfg.validator().strategy_or_default(as_string(value), cfg.default_strategy));
}

// One line of the limits, for the reload signature (service/state.uc).
function describe(l) {
    return "tcp=" + (l.tcp == null ? "all" : l.tcp) + ";udp=" + (l.udp == null ? "all" : l.udp) +
        ";keepalive=" + join(",", l.keepalive_tcp_ports);
}

// The nft words of the limit.
function match_words(n) {
    return [ "ct", "original", "packets", int(n) == 1 ? "1" : "1-" + int(n) ];
}

return { BASE, profiles, limits, section_limits, describe, kind_of, enabled_value, match_words, out_range_packets, bound_packets };
