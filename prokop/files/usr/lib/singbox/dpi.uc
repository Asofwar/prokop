#!/usr/bin/env ucode

// DPI bypass by sing-box itself: the action "singbox_dpi" of a rule. Its
// traffic leaves through a direct outbound of its own, and the rule's route
// rules carry the TLS options of sing-box route actions
// (docs/configuration/route/rule_action.md, route-options fields):
//   tls_fragment / tls_record_fragment / tls_fragment_fallback_delay since
//   1.12.0, tls_spoof / tls_spoof_method since 1.14.0.
// sing-box applies them to the TCP connections the rule routes, on the
// direct dial only; nothing outside the rule changes.
//
// UCI options of the rule (all optional, absent is off):
//   singbox_dpi_fragment                 off | tcp | record | both
//   singbox_dpi_fragment_fallback_delay  <n>ms | <n>s (tcp and both only)
//   singbox_dpi_spoof_sni                a host name the censor lets pass
//   singbox_dpi_spoof_method             wrong-sequence (default) | ...
//
// "both" is written on a route action: sing-box refuses tls_fragment with
// tls_record_fragment on a route-options action, not on a route action.

let common = require("core.common");

let option = common.option;

const ACTION = "singbox_dpi";
const FRAGMENT_MODES = [ "off", "tcp", "record", "both" ];
const SPOOF_METHODS = [ "wrong-sequence", "wrong-checksum", "wrong-ack", "wrong-md5", "wrong-timestamp" ];
const DEFAULT_SPOOF_METHOD = "wrong-sequence";
const FRAGMENT_MIN_VERSION = [ 1, 12 ];
const SPOOF_MIN_VERSION = [ 1, 14 ];
const FALLBACK_DELAY_MAX_MS = 10000;
// The route action options this module writes: routing/resolve.uc ignores
// them when it simulates which rule takes a connection.
const ROUTE_OPTION_KEYS = [ "tls_fragment", "tls_record_fragment", "tls_fragment_fallback_delay", "tls_spoof", "tls_spoof_method" ];

function as_string(value) {
    return value == null ? "" : "" + value;
}

function is_action(action) {
    return as_string(action) == ACTION;
}

// [ major, minor ] of a sing-box version string ("1.14.2",
// "v1.12.0-beta.24", "1.13.1-extended-2.0.0"), or null when unknown.
function version_parts(version) {
    let m = match(as_string(version), /^v?([0-9]+)\.([0-9]+)\./);
    return m == null ? null : [ int(m[1]), int(m[2]) ];
}

function version_at_least(version, min) {
    let parts = version_parts(version);
    if (parts == null)
        return null;
    return parts[0] > min[0] || (parts[0] == min[0] && parts[1] >= min[1]);
}

function fragment_mode(section) {
    let value = trim(option(section, "singbox_dpi_fragment", ""));
    return value == "" ? "off" : value;
}

function spoof_sni(section) {
    return trim(option(section, "singbox_dpi_spoof_sni", ""));
}

function spoof_method(section) {
    let value = trim(option(section, "singbox_dpi_spoof_method", ""));
    return value == "" ? DEFAULT_SPOOF_METHOD : value;
}

function fallback_delay(section) {
    return trim(option(section, "singbox_dpi_fragment_fallback_delay", ""));
}

// A host name: letters, digits and hyphens in dot-separated labels, at least
// two labels, a letter in the last one (not an IP address), at most 253
// characters. It goes into a forged ClientHello as written.
function valid_sni(value) {
    value = as_string(value);
    if (length(value) < 3 || length(value) > 253)
        return false;
    if (match(value, /^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$/) == null)
        return false;
    return true;
}

// Milliseconds of "<n>ms" or "<n>s", or null.
function fallback_delay_ms(value) {
    let m = match(as_string(value), /^([0-9]{1,5})(ms|s)$/);
    if (m == null)
        return null;
    let ms = int(m[1]) * (m[2] == "s" ? 1000 : 1);
    return ms >= 1 && ms <= FALLBACK_DELAY_MAX_MS ? ms : null;
}

function version_text(min) {
    return join(".", min) + ".0";
}

// Why the rule's DPI options cannot be used, or null. version: the installed
// sing-box version ("" when unknown). Fragmentation needs 1.12, the minimum
// Prokop runs on: an unknown version passes it. TLS spoof needs 1.14: an
// unknown version fails closed.
function validation_error(section, version) {
    let name = as_string(section[".name"]);
    let mode = fragment_mode(section);
    let sni = spoof_sni(section);
    let method_set = trim(option(section, "singbox_dpi_spoof_method", "")) != "";

    if (index(FRAGMENT_MODES, mode) < 0)
        return "Rule '" + name + "': unknown sing-box TLS fragmentation mode '" + mode + "'. Use off, tcp, record or both. Aborted.";
    if (mode == "off" && sni == "")
        return "Rule '" + name + "' (DPI bypass by sing-box) has neither TLS fragmentation nor TLS spoof turned on. Choose at least one or another action. Aborted.";

    let delay = fallback_delay(section);
    if (delay != "") {
        if (mode != "tcp" && mode != "both")
            return "Rule '" + name + "': the TLS fragmentation fallback delay applies to TCP segment fragmentation only. Clear it or choose TCP segments. Aborted.";
        if (fallback_delay_ms(delay) == null)
            return "Rule '" + name + "': TLS fragmentation fallback delay '" + delay + "' is invalid. Use a whole number of ms or s from 1ms to 10s, e.g. 500ms. Aborted.";
    }

    if (mode != "off" && version_at_least(version, FRAGMENT_MIN_VERSION) === false)
        return "Rule '" + name + "': TLS fragmentation by sing-box needs sing-box " + version_text(FRAGMENT_MIN_VERSION) + " or newer, the installed sing-box is " + version + ". Update sing-box or choose another action. Aborted.";

    if (sni == "") {
        if (method_set)
            return "Rule '" + name + "': a TLS spoof method is set without a TLS spoof domain. Enter the domain or clear the method. Aborted.";
        return null;
    }
    if (!valid_sni(sni))
        return "Rule '" + name + "': TLS spoof domain '" + sni + "' is not a valid host name. Enter a domain in lower case such as example.com, without a scheme, port or path. Aborted.";
    if (index(SPOOF_METHODS, spoof_method(section)) < 0)
        return "Rule '" + name + "': unknown TLS spoof method '" + spoof_method(section) + "'. Use one of " + join(", ", SPOOF_METHODS) + ". Aborted.";
    let spoof_ok = version_at_least(version, SPOOF_MIN_VERSION);
    if (spoof_ok == null)
        return "Rule '" + name + "': TLS spoof needs sing-box " + version_text(SPOOF_MIN_VERSION) + " or newer and the installed sing-box version is unknown. Clear the TLS spoof domain or check the sing-box installation. Aborted.";
    if (!spoof_ok)
        return "Rule '" + name + "': TLS spoof needs sing-box " + version_text(SPOOF_MIN_VERSION) + " or newer, the installed sing-box is " + version + ". Update sing-box or clear the TLS spoof domain. Aborted.";
    return null;
}

// The route action options of the rule for this sing-box version:
// { options: {...}, warnings: [...] }. An option the version does not read
// is left out with a warning (the validator refuses it before generation),
// so a rule never makes sing-box refuse the whole configuration.
function route_options(section, version) {
    let name = as_string(section[".name"]);
    let options = {}, warnings = [];
    let mode = fragment_mode(section);

    if (mode != "off" && index(FRAGMENT_MODES, mode) >= 0) {
        if (version_at_least(version, FRAGMENT_MIN_VERSION) === false)
            push(warnings, "rule '" + name + "': TLS fragmentation needs sing-box " + version_text(FRAGMENT_MIN_VERSION) + " or newer; not applied");
        else {
            if (mode == "tcp" || mode == "both")
                options.tls_fragment = true;
            if (mode == "record" || mode == "both")
                options.tls_record_fragment = true;
            let delay = fallback_delay(section);
            if (options.tls_fragment && delay != "" && fallback_delay_ms(delay) != null)
                options.tls_fragment_fallback_delay = delay;
        }
    }

    let sni = spoof_sni(section);
    if (sni != "") {
        if (version_at_least(version, SPOOF_MIN_VERSION) !== true)
            push(warnings, "rule '" + name + "': TLS spoof needs sing-box " + version_text(SPOOF_MIN_VERSION) + " or newer; not applied");
        else if (!valid_sni(sni) || index(SPOOF_METHODS, spoof_method(section)) < 0)
            push(warnings, "rule '" + name + "': TLS spoof domain or method is invalid; not applied");
        else {
            options.tls_spoof = sni;
            options.tls_spoof_method = spoof_method(section);
        }
    }

    return { options, warnings };
}

// A short read-only description for diagnostics: "record", "tcp+spoof", ...
// The spoof domain is not secret but stays out of it: the settings show it.
function strategy_label(section) {
    let parts = [];
    let mode = fragment_mode(section);
    if (mode != "off")
        push(parts, mode);
    if (spoof_sni(section) != "")
        push(parts, "spoof:" + spoof_method(section));
    return join("+", parts);
}

return {
    ACTION,
    FRAGMENT_MODES,
    SPOOF_METHODS,
    DEFAULT_SPOOF_METHOD,
    FRAGMENT_MIN_VERSION,
    SPOOF_MIN_VERSION,
    ROUTE_OPTION_KEYS,
    is_action,
    version_at_least,
    valid_sni,
    fallback_delay_ms,
    validation_error,
    route_options,
    strategy_label
};
