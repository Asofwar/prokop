#!/usr/bin/env ucode

// What a target's blocking looks like, from a few probes of the isolated
// direct path (autotune/isolation.uc tune, diagnosis slice). Pure.
//
// Probes (autotune/probe.uc records), at most four per target:
//   real     the target's own name (and large object, if it has one)
//   neutral  the same address with a neutral name (NEUTRAL_SNI): does the
//            address answer TLS at all?
//   tls12    the target's name with TLS 1.2 at most  } only when real failed
//   tls13    the target's name with TLS 1.3 only     } after TCP was up
//
// Types:
//   none           the target works without bypass
//   ip_block       no TCP connection to the address, with the target's name
//                  or the neutral one: a DPI strategy cannot help, the
//                  target needs a connection (proxy/VPN) rule
//   sni_block      TCP works, TLS with the target's name fails, TLS with the
//                  neutral name to the same address answers: blocking by
//                  name, what DPI strategies address
//   tls_block      TCP works, TLS fails with either name
//   tls12_only     only TLS 1.2 gets through    } the blocking depends on
//   tls13_only     only TLS 1.3 gets through    } the TLS version
//   transfer_cut   the transfer breaks after its first kilobytes (16-20 KB)
//   cert_mismatch  another certificate answered: a stub page or MITM
//   clock_problem  the certificate failed its time check: the router clock
//   dns_spoof      the resolver gave an address no public service has
//                  (set by the caller from the resolution, not from probes)
//   unclear        nothing above fits
// Ideas: DanielLavrushin/b4 detector (GPL-3, idea only),
// Runnin4ik/dpi-detector and bol-van/zapret blockcheck (MIT).

const TYPES = [ "none", "ip_block", "sni_block", "tls_block", "tls12_only", "tls13_only", "transfer_cut",
    "cert_mismatch", "clock_problem", "dns_spoof", "unclear" ];

function as_string(v) { return v == null ? "" : "" + v; }
function ok(p) { return type(p) == "object" && p.class == "success"; }
function connected(p) { return type(p) == "object" && p.connect == "ok"; }
function connect_failed(p) {
    return type(p) == "object" && index([ "timeout", "failed", "reset" ], as_string(p.connect)) >= 0;
}
// The address answered TLS for the neutral name: a handshake, a certificate
// for another name or an HTTP answer all prove the TLS path is open.
function tls_open(p) {
    return type(p) == "object" && (p.class == "success" || p.class == "cert_mismatch" || p.class == "clock_problem" ||
        p.tls == "ok");
}

// Whether the TLS version probes are worth taking after the first two.
function needs_versions(real) {
    return connected(real) && !ok(real) && index([ "clock_problem", "cert_mismatch", "transfer_cut" ], as_string(real.class)) < 0;
}

// { type, evidence } from the probes (null for a probe not taken).
function verdict(real, neutral, tls12, tls13) {
    let evidence = {};
    for (let k, p in { real, neutral, tls12, tls13 }) evidence[k] = type(p) == "object" ? as_string(p.class) : null;
    let result = (t) => ({ type: t, evidence });
    if (type(real) != "object") return result("unclear");
    if (real.class == "clock_problem") return result("clock_problem");
    if (real.class == "cert_mismatch") return result("cert_mismatch");
    if (real.class == "transfer_cut") return result("transfer_cut");
    if (ok(real)) return result("none");
    if (connect_failed(real) && connect_failed(neutral)) return result("ip_block");
    if (!connected(real)) return result("unclear");
    let v12 = ok(tls12), v13 = ok(tls13);
    if (v12 && type(tls13) == "object" && tls13.class != "local_unsupported" && !v13) return result("tls12_only");
    if (v13 && type(tls12) == "object" && !v12) return result("tls13_only");
    if (tls_open(neutral)) return result("sni_block");
    if (connected(neutral)) return result("tls_block");
    return result("unclear");
}

return { TYPES, verdict, needs_versions };
