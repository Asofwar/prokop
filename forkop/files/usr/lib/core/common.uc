#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    let data = read_stdin();
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_compact_string_array(values) {
    print("[");
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(sprintf("%J", as_string(values[i])));
    }
    print("]\n");
}

function csv_to_json_array(value) {
    value = as_string(value);
    write_compact_string_array(value == "" ? [] : split(value, ","));
}

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J\n", value));
}

// The generated sing-box config and its copies carry every outbound secret
// (UC-037): the file is created 0600, and an existing file is narrowed to
// 0600 before any content is written, whatever the process umask.
function write_private_json_file(path, value) {
    let fh = fs.open(path, "w", 0600);
    if (fh == null)
        return null;
    if (!fs.chmod(path, 0600)) {
        fh.close();
        return null;
    }
    let written = fh.write(sprintf("%J\n", value));
    fh.close();
    return written;
}

function strip_internal_fields(value) {
    if (type(value) == "array") {
        for (let i = 0; i < length(value); i++)
            value[i] = strip_internal_fields(value[i]);
        return value;
    }

    if (type(value) == "object") {
        for (let key in keys(value)) {
            if (substr(key, 0, 2) == "__") {
                delete value[key];
                continue;
            }
            value[key] = strip_internal_fields(value[key]);
        }
    }

    return value;
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function object_key_count(value) {
    return type(value) == "object" ? length(keys(value)) : 0;
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";
    let value = object_or_empty(section)[key];
    if (value == null)
        return fallback;
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    let text = trim(as_string(value));
    return text == "" ? [] : split(text, " ");
}

// The one reading of a UCI boolean: 1, true, yes or on in any letter case
// is on, any other value is off (UC-105). Every reader of a rule's enabled
// flag uses it (section_enabled): the generator, nft, the nfqws and ByeDPI
// runtimes and the resolver count the same enabled rules, so a rule's
// position (route mark, queue, strategy) is the same everywhere.
function bool_value(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function bool_option(section, key, fallback) {
    if (fallback == null)
        fallback = false;
    return bool_value(option(section, key, fallback ? "1" : "0"));
}

// A rule (or any section) is enabled unless its enabled option says off.
function section_enabled(section) {
    return bool_option(section, "enabled", true);
}

// Clash API authentication (UC-035): the one predicate shared by the config
// generator (controller secret), every backend request to the controller, the
// validator and the reload signature. A secret is in effect exactly when this
// value is not empty; YACD and WAN access only change where the controller
// listens.
function clash_api_secret(section) {
    return trim(option(section, "yacd_secret_key", ""));
}

// A strong Clash API secret (D-1 (b)): 256 random bits as hex, or null when
// the random source is unavailable. The source is only overridden by tests.
function random_hex_secret() {
    let fh = fs.open(getenv("FORKOP_SECRET_RANDOM_SOURCE") || "/dev/urandom", "r");
    if (fh == null)
        return null;
    let bytes = fh.read(32);
    fh.close();
    return type(bytes) == "string" && length(bytes) == 32 ? hexenc(bytes) : null;
}

// D-20 (a), UC-095: the Output Network Interface, as the settings page
// shows it: in effect only while enable_output_network_interface is on;
// switched off, sing-box detects the egress interface itself. "" when none
// is in effect.
function output_network_interface(settings) {
    return bool_option(settings, "enable_output_network_interface", false)
        ? option(settings, "output_network_interface", "")
        : "";
}

// D-18 (a), UC-091: automatic list updates and component update checks run
// at most once an hour, whatever interval the configuration holds; an
// update started by hand always runs. A shorter interval stays valid where
// it is stored (the migration and the settings page raise it to 1h).
const AUTOMATIC_UPDATE_MIN_SECONDS = 3600;

// The seconds of a sing-box duration (1d, 12h, 1h30m, 100ms), not rounded;
// null when the value is none.
function duration_seconds(value) {
    let rest = trim(as_string(value));
    if (rest == "")
        return null;
    let units = { ns: 0.000000001, us: 0.000001, ms: 0.001, s: 1, m: 60, h: 3600, d: 86400 };
    let total = 0.0;
    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return null;
        total += matched[1] * units[matched[3]];
        rest = substr(rest, length(matched[0]));
    }
    return total > 0 ? total : null;
}

// The period, in seconds, of an automatic update configured with an interval
// of `seconds` (null stays null: no valid interval).
function automatic_update_seconds(seconds) {
    if (seconds == null)
        return null;
    return seconds < AUTOMATIC_UPDATE_MIN_SECONDS ? AUTOMATIC_UPDATE_MIN_SECONDS : seconds;
}

// The interval an automatic update runs at, as a duration: `value`, or 1h
// in place of a shorter one. What is not a duration is returned as it is.
function automatic_update_interval(value) {
    let seconds = duration_seconds(value);
    return seconds != null && seconds < AUTOMATIC_UPDATE_MIN_SECONDS ? "1h" : value;
}

function int_option(section, key, fallback) {
    let value = option(section, key, fallback);
    if (match(value, /[^0-9]/))
        return int(fallback, 10);
    return int(value, 10);
}

// One shell word holding exactly the value: single quotes, each embedded
// quote closed, escaped and reopened. In a ucode string literal "'\''" is
// just three quotes, so the backslash itself must be written twice (UC-219).
function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

// A command line that runs args[0] with exactly these arguments.
function shell_command(args) {
    return join(" ", map(args, shell_quote));
}

return {
    as_string,
    read_json_file,
    read_stdin,
    read_stdin_json,
    write_json,
    write_compact_string_array,
    csv_to_json_array,
    write_json_file,
    write_private_json_file,
    strip_internal_fields,
    array_or_empty,
    object_or_empty,
    object_key_count,
    option,
    list_option,
    bool_value,
    bool_option,
    section_enabled,
    int_option,
    duration_seconds,
    automatic_update_seconds,
    automatic_update_interval,
    output_network_interface,
    clash_api_secret,
    random_hex_secret,
    shell_quote,
    shell_command
};
