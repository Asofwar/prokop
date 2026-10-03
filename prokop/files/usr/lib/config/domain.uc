#!/usr/bin/env ucode

const PUNYCODE_BASE = 36;
const PUNYCODE_TMIN = 1;
const PUNYCODE_TMAX = 26;
const PUNYCODE_SKEW = 38;
const PUNYCODE_DAMP = 700;
const PUNYCODE_INITIAL_BIAS = 72;
const PUNYCODE_INITIAL_N = 128;
const PUNYCODE_DELIMITER = "-";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function byte_at(value, offset) {
    return ord(substr(value, offset, 1));
}

function valid_continuation(value, offset) {
    if (offset >= length(value))
        return -1;

    let byte = byte_at(value, offset);
    return (byte & 0xc0) == 0x80 ? byte : -1;
}

// Case folding before punycode, as UTS46 folds a domain (browsers, the LuCI
// form's new URL()): every code point that changes under case mapping or
// case folding and that UTS46 17.0.0 maps to one other code point (UC-087).
// [first, last, delta, step]: every step-th code point from first to last
// maps to itself plus delta. Generated from IdnaMappingTable.txt and
// DerivedCoreProperties.txt of Unicode 17.0.0 by
// `node tests/helpers/property/domain.js --generate`, which also writes the
// mappings tests/property_domain_normalization.sh checks this table against
// (tests/fixtures/uts46_case_mappings.json). ASCII is folded before the
// table is searched. UTS46 maps other cased code points to several
// (ligatures, digraphs, Roman numerals, Greek iota subscript): those are
// compatibility mappings, not case, and are not folded here. ß and ς stay:
// nontransitional processing keeps them, and ẞ maps to ß.
const UNICODE_FOLD_RANGES = [
    [ 0xb5, 0xb5, 775, 1 ], [ 0xc0, 0xd6, 32, 1 ], [ 0xd8, 0xde, 32, 1 ], [ 0x100, 0x12e, 1, 2 ],
    [ 0x134, 0x136, 1, 2 ], [ 0x139, 0x13d, 1, 2 ], [ 0x141, 0x147, 1, 2 ], [ 0x14a, 0x176, 1, 2 ],
    [ 0x178, 0x178, -121, 1 ], [ 0x179, 0x17d, 1, 2 ], [ 0x17f, 0x17f, -268, 1 ],
    [ 0x181, 0x181, 210, 1 ], [ 0x182, 0x184, 1, 2 ], [ 0x186, 0x186, 206, 1 ],
    [ 0x187, 0x187, 1, 1 ], [ 0x189, 0x18a, 205, 1 ], [ 0x18b, 0x18b, 1, 1 ],
    [ 0x18e, 0x18e, 79, 1 ], [ 0x18f, 0x18f, 202, 1 ], [ 0x190, 0x190, 203, 1 ],
    [ 0x191, 0x191, 1, 1 ], [ 0x193, 0x193, 205, 1 ], [ 0x194, 0x194, 207, 1 ],
    [ 0x196, 0x196, 211, 1 ], [ 0x197, 0x197, 209, 1 ], [ 0x198, 0x198, 1, 1 ],
    [ 0x19c, 0x19c, 211, 1 ], [ 0x19d, 0x19d, 213, 1 ], [ 0x19f, 0x19f, 214, 1 ],
    [ 0x1a0, 0x1a4, 1, 2 ], [ 0x1a6, 0x1a6, 218, 1 ], [ 0x1a7, 0x1a7, 1, 1 ],
    [ 0x1a9, 0x1a9, 218, 1 ], [ 0x1ac, 0x1ac, 1, 1 ], [ 0x1ae, 0x1ae, 218, 1 ],
    [ 0x1af, 0x1af, 1, 1 ], [ 0x1b1, 0x1b2, 217, 1 ], [ 0x1b3, 0x1b5, 1, 2 ],
    [ 0x1b7, 0x1b7, 219, 1 ], [ 0x1b8, 0x1b8, 1, 1 ], [ 0x1bc, 0x1bc, 1, 1 ],
    [ 0x1cd, 0x1db, 1, 2 ], [ 0x1de, 0x1ee, 1, 2 ], [ 0x1f4, 0x1f4, 1, 1 ],
    [ 0x1f6, 0x1f6, -97, 1 ], [ 0x1f7, 0x1f7, -56, 1 ], [ 0x1f8, 0x21e, 1, 2 ],
    [ 0x220, 0x220, -130, 1 ], [ 0x222, 0x232, 1, 2 ], [ 0x23a, 0x23a, 10795, 1 ],
    [ 0x23b, 0x23b, 1, 1 ], [ 0x23d, 0x23d, -163, 1 ], [ 0x23e, 0x23e, 10792, 1 ],
    [ 0x241, 0x241, 1, 1 ], [ 0x243, 0x243, -195, 1 ], [ 0x244, 0x244, 69, 1 ],
    [ 0x245, 0x245, 71, 1 ], [ 0x246, 0x24e, 1, 2 ], [ 0x345, 0x345, 116, 1 ],
    [ 0x370, 0x372, 1, 2 ], [ 0x376, 0x376, 1, 1 ], [ 0x37f, 0x37f, 116, 1 ],
    [ 0x386, 0x386, 38, 1 ], [ 0x388, 0x38a, 37, 1 ], [ 0x38c, 0x38c, 64, 1 ],
    [ 0x38e, 0x38f, 63, 1 ], [ 0x391, 0x3a1, 32, 1 ], [ 0x3a3, 0x3ab, 32, 1 ],
    [ 0x3cf, 0x3cf, 8, 1 ], [ 0x3d0, 0x3d0, -30, 1 ], [ 0x3d1, 0x3d1, -25, 1 ],
    [ 0x3d5, 0x3d5, -15, 1 ], [ 0x3d6, 0x3d6, -22, 1 ], [ 0x3d8, 0x3ee, 1, 2 ],
    [ 0x3f0, 0x3f0, -54, 1 ], [ 0x3f1, 0x3f1, -48, 1 ], [ 0x3f2, 0x3f2, -47, 1 ],
    [ 0x3f4, 0x3f4, -60, 1 ], [ 0x3f5, 0x3f5, -64, 1 ], [ 0x3f7, 0x3f7, 1, 1 ],
    [ 0x3f9, 0x3f9, -54, 1 ], [ 0x3fa, 0x3fa, 1, 1 ], [ 0x3fd, 0x3ff, -130, 1 ],
    [ 0x400, 0x40f, 80, 1 ], [ 0x410, 0x42f, 32, 1 ], [ 0x460, 0x480, 1, 2 ],
    [ 0x48a, 0x4be, 1, 2 ], [ 0x4c0, 0x4c0, 15, 1 ], [ 0x4c1, 0x4cd, 1, 2 ], [ 0x4d0, 0x52e, 1, 2 ],
    [ 0x531, 0x556, 48, 1 ], [ 0x10a0, 0x10c5, 7264, 1 ], [ 0x10c7, 0x10c7, 7264, 1 ],
    [ 0x10cd, 0x10cd, 7264, 1 ], [ 0x13f8, 0x13fd, -8, 1 ], [ 0x1c80, 0x1c80, -6222, 1 ],
    [ 0x1c81, 0x1c81, -6221, 1 ], [ 0x1c82, 0x1c82, -6212, 1 ], [ 0x1c83, 0x1c84, -6210, 1 ],
    [ 0x1c85, 0x1c85, -6211, 1 ], [ 0x1c86, 0x1c86, -6204, 1 ], [ 0x1c87, 0x1c87, -6180, 1 ],
    [ 0x1c88, 0x1c88, 35267, 1 ], [ 0x1c89, 0x1c89, 1, 1 ], [ 0x1c90, 0x1cba, -3008, 1 ],
    [ 0x1cbd, 0x1cbf, -3008, 1 ], [ 0x1e00, 0x1e94, 1, 2 ], [ 0x1e9b, 0x1e9b, -58, 1 ],
    [ 0x1e9e, 0x1e9e, -7615, 1 ], [ 0x1ea0, 0x1efe, 1, 2 ], [ 0x1f08, 0x1f0f, -8, 1 ],
    [ 0x1f18, 0x1f1d, -8, 1 ], [ 0x1f28, 0x1f2f, -8, 1 ], [ 0x1f38, 0x1f3f, -8, 1 ],
    [ 0x1f48, 0x1f4d, -8, 1 ], [ 0x1f59, 0x1f5f, -8, 2 ], [ 0x1f68, 0x1f6f, -8, 1 ],
    [ 0x1f71, 0x1f71, -7109, 1 ], [ 0x1f73, 0x1f73, -7110, 1 ], [ 0x1f75, 0x1f75, -7111, 1 ],
    [ 0x1f77, 0x1f77, -7112, 1 ], [ 0x1f79, 0x1f79, -7085, 1 ], [ 0x1f7b, 0x1f7b, -7086, 1 ],
    [ 0x1f7d, 0x1f7d, -7087, 1 ], [ 0x1fb8, 0x1fb9, -8, 1 ], [ 0x1fba, 0x1fba, -74, 1 ],
    [ 0x1fbb, 0x1fbb, -7183, 1 ], [ 0x1fbe, 0x1fbe, -7173, 1 ], [ 0x1fc8, 0x1fc8, -86, 1 ],
    [ 0x1fc9, 0x1fc9, -7196, 1 ], [ 0x1fca, 0x1fca, -86, 1 ], [ 0x1fcb, 0x1fcb, -7197, 1 ],
    [ 0x1fd3, 0x1fd3, -7235, 1 ], [ 0x1fd8, 0x1fd9, -8, 1 ], [ 0x1fda, 0x1fda, -100, 1 ],
    [ 0x1fdb, 0x1fdb, -7212, 1 ], [ 0x1fe3, 0x1fe3, -7219, 1 ], [ 0x1fe8, 0x1fe9, -8, 1 ],
    [ 0x1fea, 0x1fea, -112, 1 ], [ 0x1feb, 0x1feb, -7198, 1 ], [ 0x1fec, 0x1fec, -7, 1 ],
    [ 0x1ff8, 0x1ff8, -128, 1 ], [ 0x1ff9, 0x1ff9, -7213, 1 ], [ 0x1ffa, 0x1ffa, -126, 1 ],
    [ 0x1ffb, 0x1ffb, -7213, 1 ], [ 0x2126, 0x2126, -7517, 1 ], [ 0x212a, 0x212a, -8383, 1 ],
    [ 0x212b, 0x212b, -8262, 1 ], [ 0x2132, 0x2132, 28, 1 ], [ 0x2160, 0x2160, -8439, 1 ],
    [ 0x2164, 0x2164, -8430, 1 ], [ 0x2169, 0x2169, -8433, 1 ], [ 0x216c, 0x216c, -8448, 1 ],
    [ 0x216d, 0x216e, -8458, 1 ], [ 0x216f, 0x216f, -8450, 1 ], [ 0x2170, 0x2170, -8455, 1 ],
    [ 0x2174, 0x2174, -8446, 1 ], [ 0x2179, 0x2179, -8449, 1 ], [ 0x217c, 0x217c, -8464, 1 ],
    [ 0x217d, 0x217e, -8474, 1 ], [ 0x217f, 0x217f, -8466, 1 ], [ 0x2183, 0x2183, 1, 1 ],
    [ 0x24b6, 0x24cf, -9301, 1 ], [ 0x24d0, 0x24e9, -9327, 1 ], [ 0x2c00, 0x2c2f, 48, 1 ],
    [ 0x2c60, 0x2c60, 1, 1 ], [ 0x2c62, 0x2c62, -10743, 1 ], [ 0x2c63, 0x2c63, -3814, 1 ],
    [ 0x2c64, 0x2c64, -10727, 1 ], [ 0x2c67, 0x2c6b, 1, 2 ], [ 0x2c6d, 0x2c6d, -10780, 1 ],
    [ 0x2c6e, 0x2c6e, -10749, 1 ], [ 0x2c6f, 0x2c6f, -10783, 1 ], [ 0x2c70, 0x2c70, -10782, 1 ],
    [ 0x2c72, 0x2c72, 1, 1 ], [ 0x2c75, 0x2c75, 1, 1 ], [ 0x2c7e, 0x2c7f, -10815, 1 ],
    [ 0x2c80, 0x2ce2, 1, 2 ], [ 0x2ceb, 0x2ced, 1, 2 ], [ 0x2cf2, 0x2cf2, 1, 1 ],
    [ 0xa640, 0xa66c, 1, 2 ], [ 0xa680, 0xa69a, 1, 2 ], [ 0xa722, 0xa72e, 1, 2 ],
    [ 0xa732, 0xa76e, 1, 2 ], [ 0xa779, 0xa77b, 1, 2 ], [ 0xa77d, 0xa77d, -35332, 1 ],
    [ 0xa77e, 0xa786, 1, 2 ], [ 0xa78b, 0xa78b, 1, 1 ], [ 0xa78d, 0xa78d, -42280, 1 ],
    [ 0xa790, 0xa792, 1, 2 ], [ 0xa796, 0xa7a8, 1, 2 ], [ 0xa7aa, 0xa7aa, -42308, 1 ],
    [ 0xa7ab, 0xa7ab, -42319, 1 ], [ 0xa7ac, 0xa7ac, -42315, 1 ], [ 0xa7ad, 0xa7ad, -42305, 1 ],
    [ 0xa7ae, 0xa7ae, -42308, 1 ], [ 0xa7b0, 0xa7b0, -42258, 1 ], [ 0xa7b1, 0xa7b1, -42282, 1 ],
    [ 0xa7b2, 0xa7b2, -42261, 1 ], [ 0xa7b3, 0xa7b3, 928, 1 ], [ 0xa7b4, 0xa7c2, 1, 2 ],
    [ 0xa7c4, 0xa7c4, -48, 1 ], [ 0xa7c5, 0xa7c5, -42307, 1 ], [ 0xa7c6, 0xa7c6, -35384, 1 ],
    [ 0xa7c7, 0xa7c9, 1, 2 ], [ 0xa7cb, 0xa7cb, -42343, 1 ], [ 0xa7cc, 0xa7da, 1, 2 ],
    [ 0xa7dc, 0xa7dc, -42561, 1 ], [ 0xa7f5, 0xa7f5, 1, 1 ], [ 0xab70, 0xabbf, -38864, 1 ],
    [ 0xff21, 0xff3a, -65216, 1 ], [ 0xff41, 0xff5a, -65248, 1 ], [ 0x10400, 0x10427, 40, 1 ],
    [ 0x104b0, 0x104d3, 40, 1 ], [ 0x10570, 0x1057a, 39, 1 ], [ 0x1057c, 0x1058a, 39, 1 ],
    [ 0x1058c, 0x10592, 39, 1 ], [ 0x10594, 0x10595, 39, 1 ], [ 0x10c80, 0x10cb2, 64, 1 ],
    [ 0x10d50, 0x10d65, 32, 1 ], [ 0x118a0, 0x118bf, 32, 1 ], [ 0x16e40, 0x16e5f, 32, 1 ],
    [ 0x16ea0, 0x16eb8, 27, 1 ], [ 0x1e900, 0x1e921, 34, 1 ]
];

// The letter whose case mapping itself is two code points: U+0130 to "i̇".
const DOTTED_CAPITAL_I = 0x130;
const DOTTED_CAPITAL_I_FOLDED = [ 0x69, 0x307 ];

function unicode_lower_codepoint(cp) {
    if (cp < 0x80)
        return cp >= 0x41 && cp <= 0x5a ? cp + 0x20 : cp;

    // The ranges are sorted and do not overlap: the one that can hold cp is
    // the last one that starts at or before it.
    let low = 0;
    let high = length(UNICODE_FOLD_RANGES) - 1;
    let found = -1;
    while (low <= high) {
        let middle = int((low + high) / 2);
        if (UNICODE_FOLD_RANGES[middle][0] <= cp) {
            found = middle;
            low = middle + 1;
        }
        else
            high = middle - 1;
    }

    if (found < 0)
        return cp;

    let range = UNICODE_FOLD_RANGES[found];
    return cp <= range[1] && (cp - range[0]) % range[3] == 0 ? cp + range[2] : cp;
}

// A non-ASCII code point, folded: cp is the folded code point, cps the
// folded code points when there are several, raw the code point as written.
function folded_codepoint(raw, next) {
    if (raw == DOTTED_CAPITAL_I)
        return { cp: raw, cps: DOTTED_CAPITAL_I_FOLDED, raw, next };
    return { cp: unicode_lower_codepoint(raw), raw, next };
}

function utf8_next_codepoint(value, offset) {
    let b1 = byte_at(value, offset);
    if (b1 < 0x80)
        return { cp: b1 >= 0x41 && b1 <= 0x5a ? b1 + 0x20 : b1, next: offset + 1 };

    if (b1 >= 0xc2 && b1 <= 0xdf) {
        let b2 = valid_continuation(value, offset + 1);
        if (b2 < 0)
            return null;
        return folded_codepoint(((b1 & 0x1f) << 6) | (b2 & 0x3f), offset + 2);
    }

    if (b1 >= 0xe0 && b1 <= 0xef) {
        let b2 = valid_continuation(value, offset + 1);
        let b3 = valid_continuation(value, offset + 2);
        if (b2 < 0 || b3 < 0)
            return null;

        let cp = ((b1 & 0x0f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f);
        if (cp < 0x800 || (cp >= 0xd800 && cp <= 0xdfff))
            return null;

        return folded_codepoint(cp, offset + 3);
    }

    if (b1 >= 0xf0 && b1 <= 0xf4) {
        let b2 = valid_continuation(value, offset + 1);
        let b3 = valid_continuation(value, offset + 2);
        let b4 = valid_continuation(value, offset + 3);
        if (b2 < 0 || b3 < 0 || b4 < 0)
            return null;

        let cp = ((b1 & 0x07) << 18) | ((b2 & 0x3f) << 12) | ((b3 & 0x3f) << 6) | (b4 & 0x3f);
        if (cp < 0x10000 || cp > 0x10ffff)
            return null;

        return folded_codepoint(cp, offset + 4);
    }

    return null;
}

function utf8_codepoints(value) {
    value = as_string(value);
    let result = [];

    for (let i = 0; i < length(value); ) {
        let next = utf8_next_codepoint(value, i);
        if (next == null)
            return null;

        if (next.cps != null)
            for (let cp in next.cps)
                push(result, cp);
        else
            push(result, next.cp);
        i = next.next;
    }

    return result;
}

function ascii_label_char(cp) {
    return (cp >= 0x30 && cp <= 0x39) ||
        (cp >= 0x61 && cp <= 0x7a) ||
        cp == 0x2d;
}

function valid_ascii_label(value) {
    value = ascii_lower(value);
    return length(value) >= 1 &&
        length(value) <= 63 &&
        match(value, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) != null;
}

function codepoints_to_ascii_label(codepoints) {
    let result = "";
    for (let cp in codepoints) {
        if (!ascii_label_char(cp))
            return null;
        result += chr(cp);
    }
    return valid_ascii_label(result) ? result : null;
}

function punycode_digit(value) {
    return chr(value < 26 ? 0x61 + value : 0x30 + value - 26);
}

function punycode_adapt(delta, numpoints, first_time) {
    delta = first_time ? int(delta / PUNYCODE_DAMP) : int(delta / 2);
    delta += int(delta / numpoints);

    let k = 0;
    while (delta > int(((PUNYCODE_BASE - PUNYCODE_TMIN) * PUNYCODE_TMAX) / 2)) {
        delta = int(delta / (PUNYCODE_BASE - PUNYCODE_TMIN));
        k += PUNYCODE_BASE;
    }

    return k + int(((PUNYCODE_BASE - PUNYCODE_TMIN + 1) * delta) / (delta + PUNYCODE_SKEW));
}

function punycode_encode(codepoints) {
    let output = "";
    let basic_count = 0;

    for (let cp in codepoints) {
        if (cp < 0x80) {
            if (!ascii_label_char(cp))
                return null;
            output += chr(cp);
            basic_count++;
        }
    }

    let handled = basic_count;
    if (basic_count > 0 && basic_count < length(codepoints))
        output += PUNYCODE_DELIMITER;

    let n = PUNYCODE_INITIAL_N;
    let delta = 0;
    let bias = PUNYCODE_INITIAL_BIAS;

    while (handled < length(codepoints)) {
        let m = 0x10ffff;
        for (let cp in codepoints)
            if (cp >= n && cp < m)
                m = cp;

        delta += (m - n) * (handled + 1);
        n = m;

        for (let cp in codepoints) {
            if (cp < n) {
                delta++;
                continue;
            }
            if (cp != n)
                continue;

            let q = delta;
            for (let k = PUNYCODE_BASE; ; k += PUNYCODE_BASE) {
                let t = k <= bias
                    ? PUNYCODE_TMIN
                    : (k >= bias + PUNYCODE_TMAX ? PUNYCODE_TMAX : k - bias);
                if (q < t)
                    break;

                output += punycode_digit(t + ((q - t) % (PUNYCODE_BASE - t)));
                q = int((q - t) / (PUNYCODE_BASE - t));
            }

            output += punycode_digit(q);
            bias = punycode_adapt(delta, handled + 1, handled == basic_count);
            delta = 0;
            handled++;
        }

        delta++;
        n++;
    }

    return "xn--" + output;
}

function label_to_ascii(value) {
    value = as_string(value);
    if (value == "")
        return null;

    let codepoints = utf8_codepoints(value);
    if (codepoints == null)
        return null;

    let ascii = codepoints_to_ascii_label(codepoints);
    if (ascii != null)
        return ascii;

    let encoded = punycode_encode(codepoints);
    return encoded != null && valid_ascii_label(encoded) ? encoded : null;
}

function domain_to_ascii(value, allow_leading_dot) {
    value = trim(as_string(value));
    if (value == "")
        return null;

    let leading_dot = false;
    if (allow_leading_dot && substr(value, 0, 1) == ".") {
        leading_dot = true;
        value = substr(value, 1);
    }

    if (value == "" || substr(value, length(value) - 1, 1) == ".")
        return null;

    let labels = split(value, ".");
    let result = [];
    for (let label in labels) {
        let normalized = label_to_ascii(label);
        if (normalized == null)
            return null;
        push(result, normalized);
    }

    let domain = join(".", result);
    if (length(domain) > 253)
        return null;

    return leading_dot ? "." + domain : domain;
}

function suffix_to_ascii(value) {
    return domain_to_ascii(value, true);
}

function keyword_to_ascii(value) {
    value = trim(as_string(value));
    if (value == "" || match(value, /[,[:space:]]/) != null)
        return null;

    let has_non_ascii = false;
    for (let i = 0; i < length(value); i++) {
        if (byte_at(value, i) >= 0x80) {
            has_non_ascii = true;
            break;
        }
    }

    // sing-box looks for the keyword in the lower-case domain (its
    // domain_keyword item, as routing/resolve.uc): an upper-case letter
    // never matched.
    if (!has_non_ascii)
        return ascii_lower(value);

    return domain_to_ascii(value, false);
}

// The non-ASCII labels of a regular expression, folded and punycoded. Its
// ASCII letters stay as written: a class name (\p{Greek}), a group name or
// a flag ((?U)) is case sensitive.
function regex_to_ascii(value) {
    value = as_string(value);
    if (match(value, /[,[:space:]]/) != null)
        return null;

    let result = "";
    let label = "";
    let label_has_non_ascii = false;
    let escaped = false;
    let in_class = false;

    function flush_label() {
        if (label == "")
            return true;

        let normalized = label_has_non_ascii ? label_to_ascii(label) : label;
        if (normalized == null)
            return false;

        result += normalized;
        label = "";
        label_has_non_ascii = false;
        return true;
    }

    for (let i = 0; i < length(value); ) {
        let next = utf8_next_codepoint(value, i);
        if (next == null)
            return null;

        let raw = substr(value, i, next.next - i);
        // A non-ASCII letter belongs to a label even when it folds to ASCII
        // (KELVIN SIGN to k): label_to_ascii() folds the whole label.
        let cp = next.raw >= 0x80 ? next.raw : next.cp;

        if (escaped) {
            if (!flush_label())
                return null;
            result += raw;
            escaped = false;
        }
        else if (cp == 0x5c) {
            if (!flush_label())
                return null;
            result += raw;
            escaped = true;
        }
        else if (in_class) {
            result += raw;
            if (cp == 0x5d)
                in_class = false;
        }
        else if (cp == 0x5b) {
            if (!flush_label())
                return null;
            result += raw;
            in_class = true;
        }
        else if (ascii_label_char(cp) || cp >= 0x80) {
            label += raw;
            if (cp >= 0x80)
                label_has_non_ascii = true;
        }
        else {
            if (!flush_label())
                return null;
            result += raw;
        }

        i = next.next;
    }

    return flush_label() ? result : null;
}

function valid_suffix(value) {
    return suffix_to_ascii(value) != null;
}

return {
    ascii_lower,
    label_to_ascii,
    suffix_to_ascii,
    keyword_to_ascii,
    regex_to_ascii,
    valid_suffix
};
