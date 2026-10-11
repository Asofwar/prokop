#!/usr/bin/env ucode

function as_string(value) {
    return value == null ? "" : "" + value;
}

function decimal_text(value, strict) {
    value = as_string(value);
    if (value == "" || match(value, /^[0-9]+$/) == null)
        return false;
    return !strict || length(value) == 1 || substr(value, 0, 1) != "0";
}

function valid_ipv4(value, allow_trailing_dot, strict_decimal) {
    value = as_string(value);
    if (allow_trailing_dot && length(value) > 0 && substr(value, length(value) - 1, 1) == ".")
        value = substr(value, 0, length(value) - 1);

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts) {
        if (!decimal_text(part, strict_decimal))
            return false;

        let octet = int(part);
        if (octet < 0 || octet > 255)
            return false;
    }

    return true;
}

function valid_ipv4_cidr(value, strict_decimal) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    if (!decimal_text(prefix, strict_decimal))
        return false;

    let prefix_number = int(prefix);
    return valid_ipv4(substr(value, 0, slash), false, strict_decimal) && prefix_number >= 0 && prefix_number <= 32;
}

function valid_ipv6_hextet(value) {
    value = as_string(value);
    return value != "" && length(value) <= 4 && match(value, /^[0-9A-Fa-f]+$/) != null;
}

function ipv6_parts_count(parts) {
    let count = 0;

    for (let i = 0; i < length(parts); i++) {
        let part = parts[i];
        if (part == "")
            return -1;

        if (index(part, ".") >= 0) {
            if (i != length(parts) - 1 || !valid_ipv4(part, false, false))
                return -1;
            count += 2;
            continue;
        }

        if (!valid_ipv6_hextet(part))
            return -1;
        count++;
    }

    return count;
}

function valid_ipv6(value) {
    value = as_string(value);
    if (value == "" || index(value, "/") >= 0 || index(value, "%") >= 0)
        return false;

    let marker = index(value, "::");
    if (marker >= 0) {
        if (index(substr(value, marker + 2), "::") >= 0)
            return false;

        let left = substr(value, 0, marker);
        let right = substr(value, marker + 2);
        let left_count = left == "" ? 0 : ipv6_parts_count(split(left, ":"));
        let right_count = right == "" ? 0 : ipv6_parts_count(split(right, ":"));

        return left_count >= 0 && right_count >= 0 && left_count + right_count < 8;
    }

    let count = ipv6_parts_count(split(value, ":"));
    return count == 8;
}

function valid_ipv6_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    if (!decimal_text(prefix, false))
        return false;

    let prefix_number = int(prefix);
    return valid_ipv6(substr(value, 0, slash)) && prefix_number >= 0 && prefix_number <= 128;
}

function valid_ip(value) {
    return valid_ipv4(value, false, false) || valid_ipv6(value);
}

function valid_ip_cidr(value) {
    return valid_ipv4_cidr(value, false) || valid_ipv6_cidr(value);
}

function valid_ip_or_cidr(value) {
    return valid_ip(value) || valid_ip_cidr(value);
}

// What Go's netip.ParseAddr or ParsePrefix accepts (sing-box options such as
// dns.client_subnet): no leading zeros in an IPv4 octet or in the prefix
// length.
function valid_netip_addr_or_prefix(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash < 0)
        return valid_ipv4(value, false, true) || valid_ipv6(value);
    let prefix = substr(value, slash + 1);
    if (!decimal_text(prefix, true))
        return false;
    return valid_ipv4_cidr(value, true) || valid_ipv6_cidr(value);
}

function nft_ip_or_cidr(value) {
    return valid_ipv4(value, true, true) || valid_ipv4_cidr(value, true) || valid_ipv6(value) || valid_ipv6_cidr(value);
}

function ip_family(value) {
    return valid_ipv4(value, false, false) || valid_ipv4_cidr(value, false) ? 4 :
        (valid_ipv6(value) || valid_ipv6_cidr(value) ? 6 : 0);
}

function format_ipv6_tproxy_target(address, port) {
    address = as_string(address);
    if (substr(address, 0, 1) == "[" && substr(address, length(address) - 1, 1) == "]")
        return address + ":" + as_string(port);
    return "[" + address + "]:" + as_string(port);
}

// The Discord community subnet list also carries shared Cloudflare Anycast
// ranges. Those host unrelated services, so routing them as ordinary Discord
// networks captures large amounts of unrelated traffic, torrents included.
const CLOUDFLARE_SHARED_CIDRS = [
    "104.16.0.0/12", "104.24.0.0/14", "172.64.0.0/13", "162.158.0.0/15",
    "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22",
    "198.41.128.0/17", "162.159.0.0/16", "173.245.48.0/20", "103.21.244.0/22",
    "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
    "2606:4700::/32", "2400:cb00::/32", "2405:b500::/32", "2803:f800::/32",
    "2a06:98c0::/29", "2c0f:f248::/32"
];

function is_cloudflare_shared_cidr(value) {
    value = lc(trim(as_string(value)));
    for (let cidr in CLOUDFLARE_SHARED_CIDRS)
        if (value == lc(cidr))
            return true;
    return false;
}

// Discord voice and video. Shared Cloudflare ranges are routed only for
// these, by nft and by sing-box alike (C1). Not UDP 443: on those ranges it
// is the QUIC of every site behind Cloudflare, which a Discord rule would
// send to its VPN or block (NET-15); discord.com over QUIC is caught by its
// domains through FakeIP.
const DISCORD_VOICE_PORTS_NFT = "5000-5020,3478,19294-19344,50000-65535";

// The same ports as sing-box route rule matchers.
function discord_voice_port_matchers() {
    let port = [];
    let port_range = [];
    for (let item in split(DISCORD_VOICE_PORTS_NFT, ",")) {
        if (index(item, "-") < 0)
            push(port, int(item));
        else
            push(port_range, replace(item, "-", ":"));
    }
    return { port, port_range };
}

// A device MAC address as the device filters accept it (Device filter,
// Forced device routing, Exclude devices): six hex pairs separated by one
// kind of ':' or '-', any case. The canonical form is lower case with ':',
// as nft and sing-box print it. A multicast or all-zero address is never a
// source and is refused (null).
function normalize_mac(value) {
    value = lc(trim(as_string(value)));
    let m = match(value, /^([0-9a-f]{2})([:-])([0-9a-f]{2})([:-])([0-9a-f]{2})([:-])([0-9a-f]{2})([:-])([0-9a-f]{2})([:-])([0-9a-f]{2})$/);
    if (m == null)
        return null;
    for (let i = 4; i <= 10; i += 2)
        if (m[i] != m[2])
            return null;
    let octets = [ m[1], m[3], m[5], m[7], m[9], m[11] ];
    if ((hex(octets[0]) & 1) == 1 || join("", octets) == "000000000000")
        return null;
    return join(":", octets);
}

// Whether a value is written like a MAC address at all (valid or not).
function looks_like_mac(value) {
    return match(lc(trim(as_string(value))), /^[0-9a-f]{2}([:-][0-9a-f]{2}){5}$/) != null;
}

// The values of a device option split by kind: MAC addresses (canonical,
// unique), values written like a MAC that are not a usable one, and every
// other value unchanged (addresses and networks, read as before).
function split_device_values(values) {
    let result = { ips: [], macs: [], invalid_macs: [] };
    let seen = {};
    for (let value in (type(values) == "array" ? values : [])) {
        value = trim(as_string(value));
        if (value == "")
            continue;
        if (!looks_like_mac(value)) {
            push(result.ips, value);
            continue;
        }
        let mac = normalize_mac(value);
        if (mac == null)
            push(result.invalid_macs, value);
        else if (!seen[mac]) {
            seen[mac] = true;
            push(result.macs, mac);
        }
    }
    return result;
}

return {
    valid_ipv4,
    valid_ipv4_cidr,
    valid_ipv6,
    valid_ipv6_cidr,
    valid_ip,
    valid_ip_cidr,
    valid_ip_or_cidr,
    nft_ip_or_cidr,
    valid_netip_addr_or_prefix,
    ip_family,
    format_ipv6_tproxy_target,
    CLOUDFLARE_SHARED_CIDRS,
    is_cloudflare_shared_cidr,
    DISCORD_VOICE_PORTS_NFT,
    discord_voice_port_matchers,
    normalize_mac,
    looks_like_mac,
    split_device_values
};
