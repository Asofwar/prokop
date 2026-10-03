// Route marks and NFQUEUE numbers of the per-rule DPI provider runtimes.
// The provider runtime (providers/nfqueue/runtime.uc) starts the queue
// workers and nft/apply.uc writes the rules that mark and queue their
// traffic: both take the numbers from here, so they cannot drift apart.

function as_string(value) {
    return value == null ? "" : "" + value;
}

function hex_digit_value(value) {
    let pos = index("0123456789abcdef", lc(as_string(value)));
    return pos >= 0 ? pos : null;
}

// A decimal or 0x-prefixed hexadecimal number; null when it is neither.
function parse_number(value) {
    value = lc(trim(as_string(value)));
    if (value == "")
        return null;

    if (substr(value, 0, 2) == "0x") {
        value = substr(value, 2);
        if (value == "")
            return null;

        let result = 0;
        for (let i = 0; i < length(value); i++) {
            let digit = hex_digit_value(substr(value, i, 1));
            if (digit == null)
                return null;
            result = result * 16 + digit;
        }
        return result;
    }

    return match(value, /^[0-9]+$/) == null ? null : int(value);
}

// The rule's route mark: the provider's base plus the 1-based index of the
// rule among the provider's enabled rules. Null for a base that is not a
// number or an index below 1.
function route_mark_value(route_mark_base, index_value) {
    let base = parse_number(route_mark_base);
    index_value = int(index_value || 0);
    if (base == null || index_value < 1)
        return null;
    return base + index_value;
}

function route_mark_hex(route_mark_base, index_value) {
    let value = route_mark_value(route_mark_base, index_value);
    return value == null ? "" : sprintf("0x%08x", value);
}

// The rule's queue: the first queue of the provider's range for the rule
// with index 1.
function queue_number(queue_base, index_value) {
    return int(queue_base || 0) + int(index_value || 0) - 1;
}

return {
    parse_number,
    route_mark_value,
    route_mark_hex,
    queue_number
};
