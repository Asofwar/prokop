#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let durable = require("core.durable");
let core_ip = require("core.ip");
let ipv6 = require("core.ipv6");
let uci_core = require("core.uci");
let rule_config = require("config.rule");
let connections = require("config.connections");
let routing_rulesets = require("routing.rulesets");
let runtime_constants = require("singbox.constants");
let provider_marks = require("providers.marks");
let legacy = require("core.legacy_forkop");
const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || "prokop";
const DNS_SOURCE_SET = "prokop_dns_sources";
const DNS_SOURCE6_SET = "prokop_dns_sources6";
const NFT_BATCH_FILE = getenv("PROKOP_NFT_BATCH_FILE") || "";
// Prepared elements of rule-set subnet imports (tmpfs), by the rule set's
// content and the rule's port filter: a reload, and the final apply of a list
// update, import the same rule sets again, and preparing thousands of subnets
// is most of an import on the router. The version changes with the format.
const SUBNET_CACHE_DIR = getenv("PROKOP_NFT_SUBNET_CACHE_DIR") || "/var/run/prokop/nft-subnet-cache";
const SUBNET_CACHE_VERSION = "3";
// Bounded by entries and by size: the tmpfs is RAM and holds the candidate
// batch, config.json and the list downloads too (UC-222). An entry is about
// the size of its rule set's JSON (100k subnets: 1.7 MB).
const SUBNET_CACHE_MAX = 32;
const SUBNET_CACHE_MAX_BYTES = int(getenv("PROKOP_NFT_SUBNET_CACHE_MAX_BYTES") || "4194304");
// An entry used this recently belongs to the current reload or list update
// and is never evicted for another entry.
const SUBNET_CACHE_IN_USE_SECONDS = 600;
// Test-only candidate failure injection. Empty in production.
const NFT_CANDIDATE_FAIL_PHASE = getenv("PROKOP_NFT_CANDIDATE_FAIL_PHASE") || "";
// Route table registry; the same override service/package.uc honours. Tests
// point it into their work directory.
const RT_TABLES_FILE = getenv("PROKOP_RT_TABLES") || "/etc/iproute2/rt_tables";
const NFT_TRANSITION_GUARD_CHAIN = "prokop_transition_guard";
const KILLSWITCH_INTERFACE_SET = "ks_interfaces";
const KILLSWITCH_POLICY_CHAIN = "priority_rules";
const KILLSWITCH_FORWARD_CHAIN = "ks_forward";
const KILLSWITCH_REJECT_CHAIN = "ks_reject";
const KILLSWITCH_FAKEIP_COUNTER = "ks_fakeip";
const KILLSWITCH_DNS_CHAIN = "ks_dns";

// Kill-switch rendering reuses the priority-rule builders below, but records
// their mutations as text for a separate persistent table instead of running
// nft. Both stay null for every other operation.
let nft_render_lines = null;
let nft_priority_verdict_override = null;

let common_read_json_file = common.read_json_file;
let list_option = common.list_option;
let bool_option = common.bool_option;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
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

function uci_section(section_name) {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, section_name));
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, type_name);
}

function uci_settings() {
    return uci_section("settings");
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

// On a full tmpfs writefile reports success and the file stays short or
// empty (stdio writes on close and that error is lost): a regular file
// must hold all of text (UC-223).
function write_text_file(path, text) {
    text = as_string(text);
    let result = fs.writefile(path, text);
    if (result == null)
        return false;
    if (type(result) == "boolean" && !result)
        return false;
    let stat = fs.stat(path);
    return stat != null && (stat.type != "file" || stat.size == length(text));
}

function file_executable(path) {
    let stat = fs.stat(as_string(path));
    if (stat == null || stat.mode == null)
        return false;

    return (int(stat.mode) & 73) != 0;
}

function unlink_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];

    for (let arg in args)
        push(parts, shell_quote(arg));

    return join(" ", parts);
}

function run_args(args) {
    if (nft_render_lines != null && length(args) > 2 && args[0] == "nft" &&
        (args[1] == "add" || args[1] == "insert" || args[1] == "delete" || args[1] == "flush")) {
        push(nft_render_lines, join(" ", slice(args, 1)));
        return true;
    }
    // nft -f submits a complete file as one netlink transaction. Candidate
    // preparation records mutations instead of exposing partial live state.
    if (NFT_BATCH_FILE != "" && length(args) > 2 && args[0] == "nft" &&
        (args[1] == "add" || args[1] == "insert" || args[1] == "delete" || args[1] == "flush")) {
        if (NFT_CANDIDATE_FAIL_PHASE == "prepare")
            return false;
        let words = [];
        for (let i = 1; i < length(args); i++)
            push(words, args[i]);
        // Appended, never rewritten: element lines of large sets are long,
        // and rewriting the whole file per command grew quadratically.
        // On a full tmpfs write() and close() report success while the
        // line is lost, and a batch cut at a line boundary still passes
        // `nft -c`: the batch must have grown by exactly the line (UC-223).
        let line = join(" ", words) + "\n";
        let before = fs.stat(NFT_BATCH_FILE);
        let batch = fs.open(NFT_BATCH_FILE, "a");
        if (!batch)
            return false;
        let written = batch.write(line) != null;
        batch.close();
        let after = fs.stat(NFT_BATCH_FILE);
        return written && after != null && after.size == (before != null ? before.size : 0) + length(line);
    }
    return system(command_from_args(args)) == 0;
}

function run_args_quiet(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output_from_args(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return as_string(data);
}

function command_output_quiet_from_args(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return as_string(data);
}

function log_debug(message) {
    run_args([ "logger", "-t", "prokop", "[debug] " + as_string(message) ]);
}

function log_warning(message) {
    run_args([ "logger", "-t", "prokop", "[warn] " + as_string(message) ]);
}

function log_fatal(message) {
    run_args([ "logger", "-t", "prokop", "[fatal] " + as_string(message) ]);
}

function print_csv(values) {
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(as_string(values[i]));
    }
    if (length(values) > 0)
        print("\n");
}

function text_list_to_csv(value, separator_mode) {
    print_csv(rule_config.text_list_values(value, separator_mode));
}

function csv_to_json_array(value) {
    value = as_string(value);
    if (value == "") {
        print("[]\n");
        return;
    }

    write_compact_string_array(split(value, ","));
}

function csv_list_contains(value, needle) {
    needle = as_string(needle);
    if (needle == "")
        return false;

    for (let item in split(as_string(value), ",")) {
        if (item == needle)
            return true;
    }

    return false;
}

function cache_key_is_safe(value) {
    value = as_string(value);
    return value != "" && match(value, /^[A-Za-z0-9_]+$/) != null;
}

function cache_path(enabled, cache_dir, namespace, section, key, kind) {
    if (as_string(enabled) != "1")
        exit(1);

    cache_dir = as_string(cache_dir);
    if (cache_dir == "")
        exit(1);

    if (!cache_key_is_safe(namespace) || !cache_key_is_safe(section) ||
        !cache_key_is_safe(key) || !cache_key_is_safe(kind))
        exit(1);

    print(cache_dir, "/", namespace, "_", section, "_", key, "_", kind, "\n");
}

function valid_ipv4(value) {
    return core_ip.valid_ipv4(value, false, false);
}

function valid_ipv4_cidr(value) {
    return core_ip.valid_ipv4_cidr(value, false);
}

function nft_ip_or_cidr(value) {
    return core_ip.nft_ip_or_cidr(value);
}

function domain_subnet_line_values(data) {
    let result = [];

    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(rule_config.strip_list_comment(line), /\r/g, ""));
        if (line != "")
            push(result, line);
    }

    return result;
}

function combined_domain_text_csv(value, requested_kind) {
    let result = rule_config.combined_domain_text_csv_value(value, requested_kind);
    if (result != "")
        print(result, "\n");
}

function combined_domain_csv(value, requested_kind) {
    let result = rule_config.combined_domain_csv_value(value, requested_kind);
    if (result != "")
        print(result, "\n");
}

function list_value_csv(value) {
    value = as_string(value);
    if (value != "")
        print(replace(value, / /g, ","), "\n");
}

function legacy_condition_csv_value(kind, text_mode, conditions_text_mode, text_value, list_value) {
    return rule_config.legacy_condition_csv_value(kind, text_mode, conditions_text_mode, text_value, list_value);
}

function rule_condition_csv_value(key, kind, text_mode, conditions_text_mode, text_value, list_value, combined_text_value, combined_list_value) {
    return rule_config.rule_condition_csv_value(key, kind, text_mode, conditions_text_mode, text_value, list_value, combined_text_value, combined_list_value);
}

function rule_condition_csv(key, kind, text_mode, conditions_text_mode, text_value, list_value, combined_text_value, combined_list_value) {
    let value = rule_condition_csv_value(key, kind, text_mode, conditions_text_mode, text_value, list_value, combined_text_value, combined_list_value);

    if (value != "")
        print(value, "\n");
}

function legacy_condition_csv(kind, text_mode, conditions_text_mode, text_value, list_value) {
    let value = legacy_condition_csv_value(kind, text_mode, conditions_text_mode, text_value, list_value);
    if (value != "")
        print(value, "\n");
}

function domain_subnet_text_csv(value, kind) {
    print_csv(rule_config.filter_domain_subnet_values(rule_config.text_list_values(value, "comma-space"), kind));
}

function domain_subnet_file_csv(path, kind) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    print_csv(rule_config.filter_domain_subnet_values(domain_subnet_line_values(data), kind));
}

function split_domain_subnet_file(path, domains_path, subnets_path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let domains = [];
    let subnets = [];

    for (let value in domain_subnet_line_values(data)) {
        let domain = rule_config.normalize_domain_subnet_value(value, "domains");
        if (domain != null)
            push(domains, domain);
        else if (core_ip.valid_ip_or_cidr(value))
            push(subnets, value);
    }

    if (!write_text_file(domains_path, length(domains) > 0 ? join("\n", domains) + "\n" : ""))
        exit(1);
    if (!write_text_file(subnets_path, length(subnets) > 0 ? join("\n", subnets) + "\n" : ""))
        exit(1);
}

function normalize_port_number_value(value) {
    return rule_config.normalize_port_number_value(value);
}

function normalize_port_condition_value(value) {
    return rule_config.normalize_port_condition_value(value);
}

function normalize_port_condition_for_nft(value) {
    let normalized = normalize_port_condition_value(value);
    if (normalized == null)
        exit(1);
    print(normalized, "\n");
}

function normalize_port_range_value(value) {
    return rule_config.normalize_port_range_value(value);
}

function rule_ports_csv_value(list_values, text_value) {
    return rule_config.rule_ports_csv_value(list_values, text_value);
}

function rule_ports_csv(list_values, text_value) {
    let value = rule_ports_csv_value(list_values, text_value);
    if (value != "")
        print(value, "\n");
}

function rule_port_values(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        if (index(item, "-") >= 0)
            continue;

        let port = normalize_port_number_value(item);
        if (port != null)
            push(result, port);
    }

    return result;
}

function rule_port_ranges(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        if (index(item, "-") < 0)
            continue;

        let range = normalize_port_range_value(item);
        if (range != null)
            push(result, range);
    }

    return result;
}

function csv_to_lines_file(csv, path) {
    if (!fs.writefile(path, replace(as_string(csv) + "\n", /,/g, "\n")))
        exit(1);
}

function nft_create_table(name) {
    return run_args([ "nft", "add", "table", "inet", name ]);
}

function nft_create_set(table, name, definition) {
    return run_args([ "nft", "add", "set", "inet", table, name, definition ]);
}

function nft_create_ipv4_set(table, name) {
    return nft_create_set(table, name, "{ type ipv4_addr; flags interval; auto-merge; }");
}

function nft_create_ipv6_set(table, name) {
    return nft_create_set(table, name, "{ type ipv6_addr; flags interval; auto-merge; }");
}

function nft_create_inet_service_set(table, name) {
    return nft_create_set(table, name, "{ type inet_service; flags interval; auto-merge; }");
}

function nft_create_ipv4_port_set(table, name) {
    return nft_create_set(table, name, "{ type ipv4_addr . inet_service; flags interval; auto-merge; }");
}

function nft_create_ipv6_port_set(table, name) {
    return nft_create_set(table, name, "{ type ipv6_addr . inet_service; flags interval; auto-merge; }");
}

function nft_create_ifname_set(table, name) {
    // auto-merge: overlapping names (br-lan with br-*) are no error (NET-14).
    return nft_create_set(table, name, "{ type ifname; flags interval; auto-merge; }");
}

function nft_add_set_elements(table, set_name, elements) {
    return run_args([ "nft", "add", "element", "inet", table, set_name, "{ " + as_string(elements) + " }" ]);
}

function whitespace_values(value) {
    let result = [];

    for (let item in split(replace(as_string(value), /[[:space:]]+/g, " "), " ")) {
        item = trim(item);
        if (item != "")
            push(result, item);
    }

    return result;
}

function nft_create_chain(table, name, definition) {
    return run_args([ "nft", "add", "chain", "inet", table, name, definition ]);
}

function nft_add_rule(table, chain, args) {
    let command = [ "nft", "add", "rule", "inet", table, chain ];
    for (let arg in args)
        push(command, arg);
    return run_args(command);
}

function nft_insert_rule(table, chain, args) {
    let command = [ "nft", "insert", "rule", "inet", table, chain ];
    for (let arg in args)
        push(command, arg);
    return run_args(command);
}

let LOCALV4_RANGES = [
    "0.0.0.0/8",
    "10.0.0.0/8",
    // Carrier-grade NAT and Tailscale (NET-2).
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.88.99.0/24",
    "192.168.0.0/16",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0-255.255.255.255"
];

let LOCALV6_RANGES = [
    "::/128",
    "::1/128",
    "64:ff9b::/96",
    "100::/64",
    "2001:db8::/32",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8"
];

function default_arg(value, fallback) {
    value = as_string(value);
    return value == "" ? fallback : value;
}

function combined_domain_condition_text(section) {
    if (type(object_or_empty(section)["domain"]) != "array") {
        let value = option(section, "domain", "");
        if (value != "")
            return value;
    }

    return option(section, "domain_suffix_text", "");
}

function section_rule_condition_csv(section, key, kind) {
    return rule_condition_csv_value(
        key,
        kind,
        option(section, key + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, key + "_text", ""),
        option(section, key, ""),
        combined_domain_condition_text(section),
        option(section, "domain_suffix", "")
    );
}

function section_rule_ports_csv(section) {
    return rule_ports_csv_value(option(section, "ports", ""), option(section, "ports_text", ""));
}

function section_option_nonempty(section, key) {
    return option(section, key, "") != "";
}

function section_has_destination_matchers(section) {
    return section_rule_condition_csv(section, "domain", "domains") != "" ||
        section_rule_condition_csv(section, "domain_suffix", "domains") != "" ||
        section_rule_condition_csv(section, "domain_keyword", "generic") != "" ||
        section_rule_condition_csv(section, "domain_regex", "generic") != "" ||
        section_rule_condition_csv(section, "ip_cidr", "subnets") != "" ||
        length(connections.community_lists(section)) > 0 ||
        length(connections.rule_sets(section)) > 0 ||
        length(connections.rule_sets_with_subnets(section)) > 0 ||
        section_option_nonempty(section, "domain_ip_lists");
}

function section_action(section) {
    return option(section, "action", "");
}

function action_captures_traffic(action) {
    return action == "connection" || action == "proxy" || action == "outbound" || action == "vpn" ||
        action == "block" || action == "zapret" || action == "zapret2" || action == "byedpi";
}

function section_priority_action(section) {
    let action = section_action(section);
    if (action == "bypass")
        return "bypass";
    if (action_captures_traffic(action))
        return "capture";
    return "";
}

function section_priority_prefix(section) {
    return "prokop_rule_" + as_string(section[".name"]);
}

function section_priority_sets(section) {
    let prefix = section_priority_prefix(section);
    return {
        subnets: prefix + "_subnets",
        subnets6: prefix + "_subnets6",
        ports: prefix + "_ports",
        ip_ports: prefix + "_ip_ports",
        ip6_ports: prefix + "_ip6_ports",
        // A section's own ports over its subnets: two plain sets of N + P
        // elements instead of N x P address . port pairs (optimization 22
        // of the 2026-10-04 audit). Rule sets with their own ports keep the
        // pair sets above.
        port_subnets: prefix + "_port_subnets",
        port_subnets6: prefix + "_port_subnets6",
        subnet_ports: prefix + "_subnet_ports",
        udp_port_subnets: prefix + "_udp_port_subnets",
        udp_port_subnets6: prefix + "_udp_port_subnets6",
        udp_subnet_ports: prefix + "_udp_subnet_ports",
        sources: prefix + "_sources",
        sources6: prefix + "_sources6",
        excluded_sources: prefix + "_excluded_sources",
        excluded_sources6: prefix + "_excluded_sources6",
        fully_sources: prefix + "_fully_sources",
        fully_sources6: prefix + "_fully_sources6"
    };
}

function section_source_ip_values(section) {
    return section_rule_condition_csv(section, "source_ip_cidr", "subnets");
}

function section_has_source_ip_matchers(section) {
    return section_source_ip_values(section) != "";
}

function section_excluded_source_ip_values(section) {
    return section_rule_condition_csv(section, "excluded_source_ip_cidr", "subnets");
}

function section_has_excluded_source_ip_matchers(section) {
    return section_excluded_source_ip_values(section) != "";
}

function section_has_fully_routed_ips(section) {
    return length(list_option(section, "fully_routed_ips")) > 0;
}

function section_has_subnet_update_sources(section) {
    return rule_config.has_community_subnet_list(connections.community_lists_value(section)) ||
        option(section, "remote_subnet_lists", "") != "" ||
        length(connections.rule_sets_with_subnets(section)) > 0 ||
        option(section, "domain_ip_lists", "") != "";
}

function section_has_nft_ip_matchers(section) {
    return section_rule_condition_csv(section, "ip_cidr", "subnets") != "" ||
        section_has_subnet_update_sources(section);
}

function section_has_nft_port_only_matchers(section) {
    return section_rule_ports_csv(section) != "" && !section_has_destination_matchers(section);
}

function section_priority_needs_plain_ip_rules(section) {
    return section_has_nft_ip_matchers(section) && section_rule_ports_csv(section) == "";
}

function section_priority_needs_ip_port_rules(section) {
    return section_has_nft_ip_matchers(section) && length(connections.rule_sets_with_subnets(section)) > 0;
}

function section_priority_needs_port_subnet_rules(section) {
    return section_has_nft_ip_matchers(section) && section_rule_ports_csv(section) != "";
}

// Shared Cloudflare ranges from the Discord list are routed for Discord's own
// UDP media ports only, never as ordinary destination subnets.
function section_priority_needs_udp_ip_port_rules(section) {
    for (let community in connections.community_lists(section))
        if (as_string(community) == "discord")
            return true;
    return false;
}

function section_needs_priority_sets(section) {
    return section_priority_action(section) != "" &&
        (section_has_fully_routed_ips(section) || section_has_nft_ip_matchers(section) || section_has_nft_port_only_matchers(section));
}

// Router-originated capture skips every marked packet, not only Prokop's
// marks: a socket marked by another daemon (WireGuard, Tailscale, another
// proxy) uses its mark to stay out of policy routing, and capturing it
// would loop a tunnel's own traffic through sing-box. A foreign output hook
// of the same priority that marks an unmarked packet before this chain still
// makes it skip capture (UC-104 remaining risk).
function nft_create_priority_chains(table) {
    return nft_create_chain(table, "priority_rules", "{ }") &&
        nft_create_chain(table, "priority_output_rules", "{ }") &&
        nft_add_rule(table, "priority_output_rules", [ "meta", "mark", "!=", "0", "return" ]);
}

function nft_create_priority_sets(table, sets) {
    return nft_create_ipv4_set(table, sets.subnets) &&
        nft_create_ipv6_set(table, sets.subnets6) &&
        nft_create_inet_service_set(table, sets.ports) &&
        nft_create_ipv4_port_set(table, sets.ip_ports) &&
        nft_create_ipv6_port_set(table, sets.ip6_ports) &&
        nft_create_ipv4_set(table, sets.port_subnets) &&
        nft_create_ipv6_set(table, sets.port_subnets6) &&
        nft_create_inet_service_set(table, sets.subnet_ports) &&
        nft_create_ipv4_set(table, sets.udp_port_subnets) &&
        nft_create_ipv6_set(table, sets.udp_port_subnets6) &&
        nft_create_inet_service_set(table, sets.udp_subnet_ports) &&
        nft_create_ipv4_set(table, sets.sources) &&
        nft_create_ipv6_set(table, sets.sources6) &&
        nft_create_ipv4_set(table, sets.excluded_sources) &&
        nft_create_ipv6_set(table, sets.excluded_sources6) &&
        nft_create_ipv4_set(table, sets.fully_sources) &&
        nft_create_ipv6_set(table, sets.fully_sources6);
}

function nft_priority_verdict_args(priority_action, mark) {
    if (nft_priority_verdict_override != null)
        return nft_priority_verdict_override;
    if (priority_action == "bypass")
        return [ "counter", "accept" ];
    return [ "meta", "mark", "set", mark, "counter", "accept" ];
}

function append_array(target, additions) {
    for (let item in additions)
        push(target, item);
    return target;
}

function nft_source_match_args(section, family, sets) {
    let args = [];
    if (section_has_source_ip_matchers(section))
        append_array(args, family == 6
            ? [ "ip6", "saddr", "@" + as_string(sets.sources6) ]
            : [ "ip", "saddr", "@" + as_string(sets.sources) ]);
    if (section_has_excluded_source_ip_matchers(section))
        append_array(args, family == 6
            ? [ "ip6", "saddr", "!=", "@" + as_string(sets.excluded_sources6) ]
            : [ "ip", "saddr", "!=", "@" + as_string(sets.excluded_sources) ]);
    return args;
}

function nft_priority_rule_args(section, family, local_set, match_args, mark) {
    let sets = section_priority_sets(section);
    let args = [];
    if (family == 4)
        append_array(args, nft_source_match_args(section, 4, sets));
    else
        append_array(args, nft_source_match_args(section, 6, sets));
    append_array(args, [ family == 6 ? "ip6" : "ip", "daddr", "!=", "@" + as_string(local_set) ]);
    append_array(args, match_args);
    append_array(args, nft_priority_verdict_args(section_priority_action(section), mark));
    return args;
}

function nft_priority_prerouting_args(section, family, interface_set, local_set, match_args, mark) {
    let args = [ "iifname", "@" + as_string(interface_set) ];
    append_array(args, nft_priority_rule_args(section, family, local_set, match_args, mark));
    return args;
}

function nft_add_priority_rule_pair(table, chain, section, interface_set, localv4_set, localv6_set, match4, match6, mark) {
    if (chain == "priority_rules") {
        return nft_add_rule(table, chain, nft_priority_prerouting_args(section, 4, interface_set, localv4_set, match4, mark)) &&
            nft_add_rule(table, chain, nft_priority_prerouting_args(section, 6, interface_set, localv6_set, match6, mark));
    }

    return nft_add_rule(table, chain, nft_priority_rule_args(section, 4, localv4_set, match4, mark)) &&
        nft_add_rule(table, chain, nft_priority_rule_args(section, 6, localv6_set, match6, mark));
}

function nft_fully_routed_priority_args(section, family, interface_set, local_set, fakeip_range, protocol, mark) {
    let sets = section_priority_sets(section);
    let ip_key = family == 6 ? "ip6" : "ip";
    let source_set = family == 6 ? sets.fully_sources6 : sets.fully_sources;
    let args = [
        "iifname", "@" + as_string(interface_set),
        ip_key, "saddr", "@" + as_string(source_set),
        ip_key, "daddr", "!=", "@" + as_string(local_set)
    ];

    if (section_has_excluded_source_ip_matchers(section))
        append_array(args, [ ip_key, "saddr", "!=", "@" + as_string(family == 6 ? sets.excluded_sources6 : sets.excluded_sources) ]);

    if (section_priority_action(section) == "bypass")
        append_array(args, [ ip_key, "daddr", "!=", fakeip_range ]);
    if (as_string(protocol) != "")
        append_array(args, [ "meta", "l4proto", protocol ]);
    append_array(args, nft_priority_verdict_args(section_priority_action(section), mark));
    return args;
}

function nft_add_fully_routed_priority_rules(table, section, interface_set, localv4_set, localv6_set, mark, fakeip_range, fakeip6_range) {
    if (!section_has_fully_routed_ips(section))
        return true;

    if (section_priority_action(section) == "bypass") {
        return nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 4, interface_set, localv4_set, fakeip_range, "", mark)) &&
            nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 6, interface_set, localv6_set, fakeip6_range, "", mark));
    }

    return nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 4, interface_set, localv4_set, fakeip_range, "tcp", mark)) &&
        nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 4, interface_set, localv4_set, fakeip_range, "udp", mark)) &&
        nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 6, interface_set, localv6_set, fakeip6_range, "tcp", mark)) &&
        nft_add_rule(table, "priority_rules", nft_fully_routed_priority_args(section, 6, interface_set, localv6_set, fakeip6_range, "udp", mark));
}

// The ports of a section for its port_subnets, valid ones only, as the
// address . port pairs took them (the validator refuses invalid ones).
function nft_add_subnet_ports(table, port_set, ports_csv) {
    let ports = [];
    for (let port in split(as_string(ports_csv), ",")) {
        let normalized = normalize_port_condition_value(trim(port));
        if (normalized != null && index(ports, normalized) < 0)
            push(ports, normalized);
    }
    return length(ports) == 0 || nft_add_set_elements(table, port_set, join(",", ports));
}

function nft_add_section_priority_rules(table, section, interface_set, localv4_set, localv6_set, mark, fakeip_range, fakeip6_range) {
    if (!section_needs_priority_sets(section))
        return true;

    fakeip_range = default_arg(fakeip_range, "198.18.0.0/15");
    fakeip6_range = default_arg(fakeip6_range, "fc00::/18");

    let sets = section_priority_sets(section);
    if (!nft_create_priority_sets(table, sets))
        return false;

    if (!nft_add_fully_routed_priority_rules(table, section, interface_set, localv4_set, localv6_set, mark, fakeip_range, fakeip6_range))
        return false;

    // ciadpi opens its upstream connections from the router itself, without
    // a mark (providers/byedpi/runtime.uc). Router-local capture by the
    // section's own sets would send them back to sing-box and the same
    // ByeDPI rule: router traffic to ByeDPI destinations goes direct instead
    // (D-8(a), UC-030). Capture by other sections stays (UC-185).
    let output_chain = section_action(section) == "byedpi" ? null : "priority_output_rules";
    let add_output_pair = (match4, match6) => output_chain == null ||
        nft_add_priority_rule_pair(table, output_chain, section, interface_set, localv4_set, localv6_set, match4, match6, mark);

    let needs_plain_ip_rules = section_priority_needs_plain_ip_rules(section);
    let needs_ip_port_rules = section_priority_needs_ip_port_rules(section);
    let needs_udp_ip_port_rules = section_priority_needs_udp_ip_port_rules(section);
    let needs_port_subnet_rules = section_priority_needs_port_subnet_rules(section);
    if (needs_port_subnet_rules && !nft_add_subnet_ports(table, sets.subnet_ports, section_rule_ports_csv(section)))
        return false;
    if (needs_udp_ip_port_rules && !nft_add_subnet_ports(table, sets.udp_subnet_ports, core_ip.DISCORD_VOICE_PORTS_NFT))
        return false;
    let has_port_only_matchers = section_has_nft_port_only_matchers(section);
    let match_ip4 = [ "ip", "daddr", "@" + as_string(sets.subnets) ];
    let match_ip6 = [ "ip6", "daddr", "@" + as_string(sets.subnets6) ];
    let match_ip_port4_tcp = [ "ip", "daddr", ".", "tcp", "dport", "@" + as_string(sets.ip_ports) ];
    let match_ip_port4_udp = [ "ip", "daddr", ".", "udp", "dport", "@" + as_string(sets.ip_ports) ];
    let match_ip_port6_tcp = [ "ip6", "daddr", ".", "tcp", "dport", "@" + as_string(sets.ip6_ports) ];
    let match_ip_port6_udp = [ "ip6", "daddr", ".", "udp", "dport", "@" + as_string(sets.ip6_ports) ];
    let match_port_subnet4_tcp = [ "ip", "daddr", "@" + as_string(sets.port_subnets), "tcp", "dport", "@" + as_string(sets.subnet_ports) ];
    let match_port_subnet4_udp = [ "ip", "daddr", "@" + as_string(sets.port_subnets), "udp", "dport", "@" + as_string(sets.subnet_ports) ];
    let match_port_subnet6_tcp = [ "ip6", "daddr", "@" + as_string(sets.port_subnets6), "tcp", "dport", "@" + as_string(sets.subnet_ports) ];
    let match_port_subnet6_udp = [ "ip6", "daddr", "@" + as_string(sets.port_subnets6), "udp", "dport", "@" + as_string(sets.subnet_ports) ];
    let match_udp_port_subnet4 = [ "ip", "daddr", "@" + as_string(sets.udp_port_subnets), "udp", "dport", "@" + as_string(sets.udp_subnet_ports) ];
    let match_udp_port_subnet6 = [ "ip6", "daddr", "@" + as_string(sets.udp_port_subnets6), "udp", "dport", "@" + as_string(sets.udp_subnet_ports) ];
    let match_port4_tcp = [ "tcp", "dport", "@" + as_string(sets.ports) ];
    let match_port4_udp = [ "udp", "dport", "@" + as_string(sets.ports) ];
    let match_port6_tcp = [ "tcp", "dport", "@" + as_string(sets.ports) ];
    let match_port6_udp = [ "udp", "dport", "@" + as_string(sets.ports) ];

    // A FakeIP address only means something to sing-box: a bypass rule
    // never fast-paths it, sing-box applies the rule to the real address in
    // UCI order (UC-029), as for fully routed devices above.
    if (section_priority_action(section) == "bypass") {
        for (let match4 in [ match_ip4, match_ip_port4_tcp, match_ip_port4_udp, match_port4_tcp, match_port4_udp,
                match_port_subnet4_tcp, match_port_subnet4_udp, match_udp_port_subnet4 ])
            splice(match4, 0, 0, "ip", "daddr", "!=", fakeip_range);
        for (let match6 in [ match_ip6, match_ip_port6_tcp, match_ip_port6_udp, match_port6_tcp, match_port6_udp,
                match_port_subnet6_tcp, match_port_subnet6_udp, match_udp_port_subnet6 ])
            splice(match6, 0, 0, "ip6", "daddr", "!=", fakeip6_range);
    }

    if (needs_plain_ip_rules &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip4, match_ip6, mark) ||
            !add_output_pair(match_ip4, match_ip6)))
        return false;

    if (needs_ip_port_rules &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip_port4_tcp, match_ip_port6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip_port4_udp, match_ip_port6_udp, mark) ||
            !add_output_pair(match_ip_port4_tcp, match_ip_port6_tcp) ||
            !add_output_pair(match_ip_port4_udp, match_ip_port6_udp)))
        return false;

    if (needs_port_subnet_rules &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_port_subnet4_tcp, match_port_subnet6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_port_subnet4_udp, match_port_subnet6_udp, mark) ||
            !add_output_pair(match_port_subnet4_tcp, match_port_subnet6_tcp) ||
            !add_output_pair(match_port_subnet4_udp, match_port_subnet6_udp)))
        return false;

    if (needs_udp_ip_port_rules &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_udp_port_subnet4, match_udp_port_subnet6, mark) ||
            !add_output_pair(match_udp_port_subnet4, match_udp_port_subnet6)))
        return false;

    if (has_port_only_matchers &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_port4_tcp, match_port6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_port4_udp, match_port6_udp, mark) ||
            !add_output_pair(match_port4_tcp, match_port6_tcp) ||
            !add_output_pair(match_port4_udp, match_port6_udp)))
        return false;

    return true;
}

function nft_add_section_priority_rules_from_sections(sections, table, interface_set, localv4_set, localv6_set, mark, fakeip_range, fakeip6_range) {
    localv6_set = default_arg(localv6_set, "localv6");
    for (let section in sections) {
        section = object_or_empty(section);
        if (!bool_option(section, "enabled", true))
            continue;
        if (!nft_add_section_priority_rules(table, section, interface_set, localv4_set, localv6_set, mark, fakeip_range, fakeip6_range))
            return false;
    }
    return true;
}

// Prokop's own mark bits: the top byte (outbound, FakeIP, provider route
// marks) and the low byte of the provider index. Other output hooks of the
// same priority (fw4, pbr, mwan3, Tailscale) set bits in between; registered
// after Prokop, they run first, so an exact mark match would miss a packet
// they touched (UC-104). The mask is never contiguous from the top bit, so
// every nft version lists it in the same `&` form: nft before 1.1.0 lists
// `& 0xff000000` as the prefix `meta mark 0x08000000/8`, which the autotune
// contract's mark matcher does not read. The low byte is kept in the mask
// for that reason even where the mark has no low-byte bits.
const PROKOP_MARK_BITS = 0xff0000ff;

function nft_prokop_mark_match_args(mark) {
    let value = provider_marks.parse_number(mark);
    if (value == null)
        return null;
    return [ "meta", "mark", "&", sprintf("0x%08x", PROKOP_MARK_BITS | value), "==", sprintf("0x%08x", value) ];
}

// common_set, port_set, ip_port_set, common6_set and ip_port6_set name the
// shared capture sets of the releases before the per-rule sets: nothing
// filled them, and the rules matching them never matched (UC-170). The
// arguments stay so the callers' argument positions do not change.
function nft_create_runtime_base(table, localv4_set, common_set, port_set, ip_port_set, interface_set, source_interfaces, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, exclude_ntp, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    localv6_set = default_arg(localv6_set, "localv6");
    fakeip6_range = default_arg(fakeip6_range, "fc00::/18");
    tproxy6_address = default_arg(tproxy6_address, "::1");

    if (!nft_create_table(table) ||
        !nft_create_ipv4_set(table, localv4_set) ||
        !nft_add_set_elements(table, localv4_set, join(",", LOCALV4_RANGES)) ||
        !nft_create_ipv6_set(table, localv6_set) ||
        !nft_add_set_elements(table, localv6_set, join(",", LOCALV6_RANGES)) ||
        !nft_create_ipv4_set(table, DNS_SOURCE_SET) ||
        !nft_create_ipv6_set(table, DNS_SOURCE6_SET) ||
        !nft_create_ifname_set(table, interface_set))
        return false;

    // Quoted: 'lan@1' or '10g' unquoted are a syntax error for nft (NET-9).
    for (let interface in whitespace_values(source_interfaces))
        if (!nft_add_set_elements(table, interface_set, sprintf("%J", interface)))
            return false;

    if (!nft_create_chain(table, "dns_redirect", "{ type nat hook prerouting priority -101; policy accept; }") ||
        !nft_create_chain(table, "mangle", "{ type filter hook prerouting priority -149; policy accept; }") ||
        !nft_create_chain(table, "mangle_output", "{ type route hook output priority -150; policy accept; }") ||
        !nft_create_priority_chains(table) ||
        !nft_create_chain(table, "proxy", "{ type filter hook prerouting priority -100; policy accept; }"))
        return false;

    if (!nft_add_rule(table, "dns_redirect", [ "iifname", "@" + as_string(interface_set), "ip", "saddr", "@" + DNS_SOURCE_SET, "tcp", "dport", "53", "counter", "redirect", "to", ":" + as_string(runtime_constants.SOURCE_DNS_INBOUND_PORT) ]) ||
        !nft_add_rule(table, "dns_redirect", [ "iifname", "@" + as_string(interface_set), "ip", "saddr", "@" + DNS_SOURCE_SET, "udp", "dport", "53", "counter", "redirect", "to", ":" + as_string(runtime_constants.SOURCE_DNS_INBOUND_PORT) ]) ||
        !nft_add_rule(table, "dns_redirect", [ "iifname", "@" + as_string(interface_set), "ip6", "saddr", "@" + DNS_SOURCE6_SET, "tcp", "dport", "53", "counter", "redirect", "to", ":" + as_string(runtime_constants.SOURCE_DNS_INBOUND_PORT) ]) ||
        !nft_add_rule(table, "dns_redirect", [ "iifname", "@" + as_string(interface_set), "ip6", "saddr", "@" + DNS_SOURCE6_SET, "udp", "dport", "53", "counter", "redirect", "to", ":" + as_string(runtime_constants.SOURCE_DNS_INBOUND_PORT) ]) ||
        // Every capture rule below matches the source interfaces only: WAN
        // and other traffic leaves at the first rule instead of passing
        // every rule of every section (audit optimization 21).
        !nft_add_rule(table, "mangle", [ "iifname", "!=", "@" + as_string(interface_set), "return" ]) ||
        // Answers are never captured (NET-1): capture goes by destination,
        // and the answer of a connection that a host in a captured list
        // opened to the router or to a LAN server went to sing-box too.
        !nft_add_rule(table, "mangle", [ "ct", "direction", "reply", "return" ]) ||
        !nft_add_rule(table, "mangle", [ "ct", "status", "dnat", "return" ]) ||
        // The router's own addresses (its WAN address, the global IPv6
        // address of router.lan) go direct (NET-2); FakeIP is never local.
        !nft_add_rule(table, "mangle", [ "fib", "daddr", "type", "local", "return" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "@" + as_string(localv4_set), "return" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", "@" + as_string(localv6_set), "ip6", "daddr", "!=", fakeip6_range, "return" ]) ||
        !nft_add_rule(table, "mangle", [ "jump", "priority_rules" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", fakeip_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", fakeip_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", fakeip6_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", fakeip6_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", fakeip_mark, "==", fakeip_mark, "meta", "l4proto", "tcp", "tproxy", "ip", "to", ":" + as_string(tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", fakeip_mark, "==", fakeip_mark, "meta", "l4proto", "udp", "tproxy", "ip", "to", ":" + as_string(tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", fakeip_mark, "==", fakeip_mark, "meta", "l4proto", "tcp", "tproxy", "ip6", "to", core_ip.format_ipv6_tproxy_target(tproxy6_address, tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", fakeip_mark, "==", fakeip_mark, "meta", "l4proto", "udp", "tproxy", "ip6", "to", core_ip.format_ipv6_tproxy_target(tproxy6_address, tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "mangle_output", [ "ct", "direction", "reply", "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "fib", "daddr", "type", "local", "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "ip", "daddr", "@" + as_string(localv4_set), "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "ip6", "daddr", "@" + as_string(localv6_set), "ip6", "daddr", "!=", fakeip6_range, "return" ]) ||
        nft_prokop_mark_match_args(outbound_mark) == null ||
        !nft_add_rule(table, "mangle_output", [ ...nft_prokop_mark_match_args(outbound_mark), "counter", "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "jump", "priority_output_rules" ]))
        return false;

    if (arg_bool(exclude_ntp) && !nft_insert_rule(table, "mangle", [ "udp", "dport", "123", "return" ]))
        return false;

    return true;
}

function nft_create_runtime_base_from_uci(table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    let settings = uci_settings();

    return nft_create_runtime_base(
        table,
        localv4_set,
        common_set,
        port_set,
        ip_port_set,
        interface_set,
        option(settings, "source_network_interfaces", "br-lan"),
        fakeip_mark,
        outbound_mark,
        fakeip_range,
        tproxy_port,
        option(settings, "exclude_ntp", "0"),
        localv6_set,
        common6_set,
        ip_port6_set,
        fakeip6_range,
        tproxy6_address
    );
}

// The shared capture set arguments are ignored, as in
// nft_create_runtime_base().
function nft_create_runtime_output_rules(table, localv4_set, common_set, port_set, ip_port_set, fakeip_mark, fakeip_range, localv6_set, common6_set, ip_port6_set, fakeip6_range) {
    localv6_set = default_arg(localv6_set, "localv6");
    fakeip6_range = default_arg(fakeip6_range, "fc00::/18");

    return (
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", fakeip_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", fakeip_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip6", "daddr", fakeip6_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip6", "daddr", fakeip6_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ])
    );
}

function nft_create_provider_output_rules_from_sections(sections, table, action, provider_bin, route_mark_base, queue_base, desync_mark, desync_mark_postnat) {
    if (!file_executable(provider_bin))
        return true;

    let index = 0;
    let added = false;

    for (let section in sections) {
        section = object_or_empty(section);
        if (!bool_option(section, "enabled", true) || option(section, "action", "") != action)
            continue;

        index++;
        let mark_hex = provider_marks.route_mark_hex(route_mark_base, index);
        let queue_number = provider_marks.queue_number(queue_base, index);
        if (mark_hex == "" || queue_number < 0)
            return false;

        if (!added) {
            if (!nft_add_rule(table, "mangle_output", [ "meta", "mark", "&", desync_mark, "==", desync_mark, "return" ]) ||
                !nft_add_rule(table, "mangle_output", [ "meta", "mark", "&", desync_mark_postnat, "==", desync_mark_postnat, "return" ]))
                return false;
            added = true;
        }

        let mark_match = nft_prokop_mark_match_args(mark_hex);
        if (!nft_add_rule(table, "mangle_output", [ ...mark_match, "meta", "l4proto", "tcp", "counter", "queue", "num", queue_number, "bypass" ]) ||
            !nft_add_rule(table, "mangle_output", [ ...mark_match, "meta", "l4proto", "udp", "counter", "queue", "num", queue_number, "bypass" ]))
            return false;
    }

    return true;
}

function nft_write_chunk(chunks, chunk) {
    if (length(chunk) > 0)
        push(chunks, "" + length(chunk) + "\t" + join(",", chunk));
}

function nft_push_chunk_value(chunks, chunk, value, chunk_size) {
    push(chunk, value);
    if (length(chunk) < chunk_size)
        return chunk;

    nft_write_chunk(chunks, chunk);
    return [];
}

function nft_invalid(invalid, value, message) {
    push(invalid, as_string(value) + "\t" + message);
}

function nft_trimmed_lines(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let result = [];
    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        if (line != "")
            push(result, line);
    }

    return result;
}

function nft_chunk_size(value) {
    value = int(value || 5000);
    return value > 0 ? value : 5000;
}

function nft_csv_values(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        item = trim(replace(as_string(item), /\r/g, ""));
        if (item != "")
            push(result, item);
    }

    return result;
}

function nft_build_chunks_from_values(values, kind, ports_csv, chunk_size_text, family_filter) {
    let chunk_size = nft_chunk_size(chunk_size_text);
    let chunks = [];
    let invalid = [];
    let chunk = [];
    let ports = split(as_string(ports_csv), ",");
    family_filter = int(family_filter || 0);

    for (let line in values) {
        if (kind == "ports") {
            let port = normalize_port_condition_value(line);
            if (port == null) {
                nft_invalid(invalid, line, "is not a valid port or port range");
                continue;
            }
            chunk = nft_push_chunk_value(chunks, chunk, port, chunk_size);
            continue;
        }

        if (kind == "ip-ports") {
            let separator = index(line, " . ");
            let last_separator = rindex(line, " . ");
            if (separator < 0 || last_separator < 0) {
                nft_invalid(invalid, line, "is not an IP/CIDR and port nft tuple");
                continue;
            }

            let ip = substr(line, 0, separator);
            let port = substr(line, last_separator + 3);
            let original_port = port;
            if (!nft_ip_or_cidr(ip)) {
                nft_invalid(invalid, ip, "is not IP or CIDR");
                continue;
            }

            if (family_filter != 0 && core_ip.ip_family(ip) != family_filter)
                continue;

            port = normalize_port_condition_value(port);
            if (port == null) {
                nft_invalid(invalid, original_port, "is not a valid port or port range");
                continue;
            }

            chunk = nft_push_chunk_value(chunks, chunk, ip + " . " + port, chunk_size);
            continue;
        }

        if (!nft_ip_or_cidr(line)) {
            nft_invalid(invalid, line, "is not IP or CIDR");
            continue;
        }

        if (family_filter != 0 && core_ip.ip_family(line) != family_filter)
            continue;

        if (kind == "ip-port-from-ip") {
            for (let port in ports) {
                if (port == "")
                    continue;

                let normalized = normalize_port_condition_value(port);
                if (normalized == null) {
                    nft_invalid(invalid, port, "is not a valid port or port range");
                    continue;
                }

                chunk = nft_push_chunk_value(chunks, chunk, line + " . " + normalized, chunk_size);
            }
        }
        else if (kind == "ips") {
            chunk = nft_push_chunk_value(chunks, chunk, line, chunk_size);
        }
        else {
            exit(1);
        }
    }

    nft_write_chunk(chunks, chunk);

    return {
        chunks: chunks,
        invalid: invalid
    };
}

function nft_build_chunks(path, kind, ports_csv, chunk_size_text) {
    return nft_build_chunks_from_values(nft_trimmed_lines(path), kind, ports_csv, chunk_size_text, 0);
}

function nft_prepare_chunks(path, kind, ports_csv, chunk_size_text, chunks_path, invalid_path) {
    let prepared = nft_build_chunks(path, kind, ports_csv, chunk_size_text);

    if (!write_text_file(chunks_path, length(prepared.chunks) > 0 ? join("\n", prepared.chunks) + "\n" : ""))
        exit(1);
    if (!write_text_file(invalid_path, length(prepared.invalid) > 0 ? join("\n", prepared.invalid) + "\n" : ""))
        exit(1);
}

// A few invalid entries by name, the rest counted on one line: each log
// line is a logger process, and a broken list has thousands of them
// (audit optimization 24).
const INVALID_ELEMENTS_LOGGED = 5;

function nft_log_invalid_elements(invalid) {
    let logged = 0;
    let skipped = 0;
    for (let item in invalid) {
        let separator = index(item, "\t");
        if (separator < 0)
            continue;

        let value = substr(item, 0, separator);
        let message = substr(item, separator + 1);
        if (value == "")
            continue;
        if (logged < INVALID_ELEMENTS_LOGGED) {
            log_debug("'" + value + "' " + message);
            logged++;
        }
        else
            skipped++;
    }
    if (skipped > 0)
        log_debug("... and " + skipped + " more invalid entries skipped");
}

function nft_add_chunks_to_set(table, set_name, chunks, invalid) {
    nft_log_invalid_elements(invalid);

    for (let item in chunks) {
        let separator = index(item, "\t");
        if (separator < 0)
            continue;

        let count = substr(item, 0, separator);
        let elements = substr(item, separator + 1);
        if (elements == "")
            continue;

        log_debug("Adding " + count + " elements to nft set " + set_name);
        if (!nft_add_set_elements(table, set_name, elements))
            return false;
    }

    return true;
}

function nft_add_file_chunks_to_set(path, table, set_name, kind, ports_csv, chunk_size_text, family_filter) {
    let prepared = nft_build_chunks_from_values(nft_trimmed_lines(path), kind, ports_csv, chunk_size_text, family_filter);
    return nft_add_chunks_to_set(table, set_name, prepared.chunks, prepared.invalid);
}

function nft_add_csv_chunks_to_set(csv, table, set_name, kind, ports_csv, chunk_size_text, family_filter) {
    let prepared = nft_build_chunks_from_values(nft_csv_values(csv), kind, ports_csv, chunk_size_text, family_filter);
    return nft_add_chunks_to_set(table, set_name, prepared.chunks, prepared.invalid);
}

// The values of each address family, in their order; "other" holds what is
// neither (invalid values, and valid ones of no family, which the family
// sets skip). Every value is classified once: a large list (thousands of
// subnets of one rule set) is no longer validated in full for each family.
function nft_values_by_family(values, kind) {
    let result = { v4: [], v6: [], other: [] };
    for (let line in values) {
        let ip = line;
        if (kind == "ip-ports") {
            let separator = index(line, " . ");
            if (separator < 0) {
                push(result.other, line);
                continue;
            }
            ip = substr(line, 0, separator);
        }
        let family = core_ip.ip_family(ip);
        push(family == 4 ? result.v4 : family == 6 ? result.v6 : result.other, line);
    }
    return result;
}

// The elements of both family sets from one list: { v4, v6 }, each
// { chunks, invalid }. The builder still validates each value for nft;
// "other" goes through the IPv4 pass only, so an invalid value is reported
// once and a value of no family is skipped as before.
function nft_prepare_family_chunks(values, kind, ports_csv, chunk_size_text) {
    let split_values = nft_values_by_family(values, kind);
    let v4 = nft_build_chunks_from_values(split_values.v4, kind, ports_csv, chunk_size_text, 0);
    let other = nft_build_chunks_from_values(split_values.other, kind, ports_csv, chunk_size_text, 4);
    let v6 = nft_build_chunks_from_values(split_values.v6, kind, ports_csv, chunk_size_text, 0);
    return {
        v4: { chunks: [ ...v4.chunks, ...other.chunks ], invalid: [ ...v4.invalid, ...other.invalid ] },
        v6: { chunks: v6.chunks, invalid: v6.invalid }
    };
}

function nft_apply_family_chunks(table, ipv4_set, ipv6_set, prepared) {
    return nft_add_chunks_to_set(table, ipv4_set, prepared.v4.chunks, prepared.v4.invalid) &&
        nft_add_chunks_to_set(table, ipv6_set, prepared.v6.chunks, prepared.v6.invalid);
}

function nft_add_values_to_family_sets_once(values, table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text) {
    return nft_apply_family_chunks(table, ipv4_set, ipv6_set, nft_prepare_family_chunks(values, kind, ports_csv, chunk_size_text));
}

function nft_add_file_chunks_to_family_sets(path, table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text) {
    return nft_add_values_to_family_sets_once(nft_trimmed_lines(path), table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text);
}

function nft_add_csv_chunks_to_family_sets(csv, table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text) {
    return nft_add_values_to_family_sets_once(nft_csv_values(csv), table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text);
}

// Subnets limited to the section's ports: the ports are added once with
// the section's rules (nft_add_section_priority_rules); a second add of an
// interval in the same batch is refused by the kernel.
function nft_add_values_to_port_subnets(values, table, ipv4_set, ipv6_set, chunk_size_text) {
    return nft_add_values_to_family_sets_once(values, table, ipv4_set, ipv6_set, "ips", "", chunk_size_text);
}

function nft_add_inline_ip_cidr_matchers(csv, ports_csv, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    if (as_string(csv) == "")
        return true;

    if (as_string(ports_csv) != "")
        return nft_add_values_to_port_subnets(nft_csv_values(csv), table, ip_port_set, ip_port6_set, chunk_size_text);

    return nft_add_csv_chunks_to_family_sets(csv, table, common_set, default_arg(common6_set, "prokop_subnets6"), "ips", "", chunk_size_text);
}

// ensure_tproxy_route_rule(): `ip rule add fwmark M/M table <name> priority
// 105`, <name> registered as table 105 in rt_tables.
const TPROXY_RULE_PRIORITY = "105";
const TPROXY_RULE_TABLE_ID = "105";

function normalized_fields(line) {
    line = trim(replace(as_string(line), /\r/g, ""));
    line = replace(line, /[[:space:]]+/g, " ");
    return line == "" ? [] : split(line, " ");
}

// The rt_tables file the TPROXY table is registered in (ensure-tproxy-
// route-rule may name another one).
let rt_tables_path_in_use = RT_TABLES_FILE;

// Every name rt_tables gives table_id. iproute2 names an id by the LAST
// entry for it (NET-3): with Podkop's `105 podkop`, or the entry of the
// package before the rename, after Prokop's, `ip rule` shows Prokop's rule
// under that name.
function rt_table_names(table_id) {
    let names = [];
    let files = [ rt_tables_path_in_use ];
    for (let conf in ((fs.glob ? fs.glob(rt_tables_path_in_use + ".d/*.conf") : null) ?? []))
        push(files, conf);
    for (let file in files)
        for (let line in split(as_string(fs.readfile(file) ?? ""), "\n")) {
            let fields = normalized_fields(line);
            if (length(fields) >= 2 && fields[0] == as_string(table_id) && index(names, fields[1]) < 0)
                push(names, fields[1]);
        }
    return names;
}

// The names `ip rule` may show for the table: any rt_tables name of its id,
// or the numeric id `ip` prints while rt_tables lacks a name (UC-163). Read
// once per listing, not once per line of it (optimization 15).
function lookup_table_names(table, table_id) {
    return [ as_string(table), as_string(table_id), ...rt_table_names(table_id) ];
}

// `lookup <table>` by one of `names` (lookup_table_names).
function rule_line_has_lookup_table(fields, names) {
    for (let i = 0; i + 1 < length(fields); i++)
        if (fields[i] == "lookup" && index(names, fields[i + 1]) >= 0)
            return true;

    return false;
}

function rule_line_has_fwmark(fields, expected_mark) {
    for (let i = 0; i + 1 < length(fields); i++) {
        if (fields[i] != "fwmark")
            continue;

        let parts = split(fields[i + 1], "/");
        if (length(parts) != 2)
            continue;

        if (provider_marks.parse_number(parts[0]) == expected_mark && provider_marks.parse_number(parts[1]) == expected_mark)
            return true;
    }

    return false;
}

// One line of `ip rule list` is one rule: Prokop's marking rule is a line
// with its priority, from all, the fwmark/mask and the lookup of its table
// (UC-163). A lookup and a fwmark on two different lines are two other rules.
function has_tproxy_marking_rule_text(rule_list, table, mark) {
    let expected_mark = provider_marks.parse_number(mark);

    if (expected_mark == null)
        return false;

    let names = lookup_table_names(table, TPROXY_RULE_TABLE_ID);
    for (let line in split(rule_list, "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) < 3 || fields[0] != TPROXY_RULE_PRIORITY + ":" || fields[1] != "from" || fields[2] != "all")
            continue;

        if (rule_line_has_lookup_table(fields, names) && rule_line_has_fwmark(fields, expected_mark))
            return true;
    }

    return false;
}

// Another program's rule on Prokop's table id (Podkop uses table 105 too):
// the table's route is then not Prokop's alone to flush.
function has_foreign_table_rule_text(rule_list, table, mark) {
    let expected_mark = provider_marks.parse_number(mark);

    let names = lookup_table_names(table, TPROXY_RULE_TABLE_ID);
    for (let line in split(rule_list, "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) < 2 || !rule_line_has_lookup_table(fields, names))
            continue;
        if (fields[0] == TPROXY_RULE_PRIORITY + ":" && expected_mark != null && rule_line_has_fwmark(fields, expected_mark))
            continue;
        return true;
    }

    return false;
}

function has_local_default_route_text(route_list, family) {
    family = int(family || 4);

    for (let line in split(as_string(route_list), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        line = replace(line, /[[:space:]]+/g, " ");
        if (family == 4 && index(line, "local default dev lo scope host") >= 0)
            return true;
        if (family == 6 && (index(line, "local ::") >= 0 || index(line, "local default") >= 0) && index(line, " dev lo") >= 0)
            return true;
    }

    return false;
}

function rt_table_has_entry(text, table_id, table_name) {
    table_id = as_string(table_id);
    table_name = as_string(table_name);

    for (let line in split(as_string(text), "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) >= 2 && fields[0] == table_id && fields[1] == table_name)
            return true;
    }

    return false;
}

function legacy_rt_table_line(fields, table_id) {
    return length(fields) >= 2 && fields[0] == as_string(table_id) &&
        fields[0] == legacy.RT_TABLE_ID && fields[1] == legacy.RT_TABLE_NAME;
}

// rt_tables names the tables of other packages too: written to a copy next
// to it, read back, flushed and renamed over it, never truncated and
// rewritten in place, where a crash or a full overlay lost every entry
// (UC-076): core/durable.uc, as the package removal does
// (service/package.uc). Written only when it changes. The mode stays; a
// symlink stays one.
function write_rt_tables(path, data) {
    return durable.durable_rewrite(as_string(path), data, 0644);
}

// The entry the package before the rename left for the same id
// (core/legacy_forkop.uc) goes once that package is gone. Which entry
// comes first does not matter: Prokop's rule is found under any name of
// its id (rt_table_names).
function ensure_rt_table_entry(path, table_id, table_name) {
    let data = fs.readfile(path);
    data = data == null ? "" : as_string(data);
    let lines = split(data, "\n");
    if (length(lines) > 0 && lines[length(lines) - 1] == "")
        pop(lines);

    let strip_legacy = !legacy.installed();
    let result = [];
    let own = false;
    for (let line in lines) {
        let fields = normalized_fields(line);
        if (strip_legacy && legacy_rt_table_line(fields, table_id))
            continue;
        if (length(fields) >= 2 && fields[0] == as_string(table_id) && fields[1] == as_string(table_name)) {
            if (own)
                continue;
            own = true;
        }
        push(result, line);
    }
    if (!own)
        push(result, as_string(table_id) + " " + as_string(table_name));
    if (length(result) == length(lines) && own)
        return true;
    return write_rt_tables(path, join("\n", result) + "\n");
}

function tproxy_route4_present(table) {
    return has_local_default_route_text(command_output_quiet_from_args([ "ip", "route", "list", "table", table ]), 4);
}

function tproxy_route6_present(table) {
    return has_local_default_route_text(command_output_quiet_from_args([ "ip", "-6", "route", "list", "table", table ]), 6);
}

function tproxy_route_present(table) {
    return tproxy_route4_present(table) && (!ipv6.available() || tproxy_route6_present(table));
}

function tproxy_marking_rule4_present(table, mark) {
    return has_tproxy_marking_rule_text(command_output_from_args([ "ip", "-4", "rule", "list" ]), table, mark);
}

function tproxy_marking_rule6_present(table, mark) {
    return has_tproxy_marking_rule_text(command_output_from_args([ "ip", "-6", "rule", "list" ]), table, mark);
}

function tproxy_marking_rule_present(table, mark) {
    return tproxy_marking_rule4_present(table, mark) && (!ipv6.available() || tproxy_marking_rule6_present(table, mark));
}

function tproxy_route_rule_present(table, mark) {
    return tproxy_route_present(table) && tproxy_marking_rule_present(table, mark);
}

function ensure_tproxy_route_rule(table, mark, rt_tables_path) {
    rt_tables_path = as_string(rt_tables_path || RT_TABLES_FILE);
    rt_tables_path_in_use = rt_tables_path;

    if (!ensure_rt_table_entry(rt_tables_path, TPROXY_RULE_TABLE_ID, table)) {
        log_fatal("Failed to update route table registry. Aborted.");
        return false;
    }

    if (!tproxy_route4_present(table)) {
        log_debug("Added IPv4 TPROXY route");
        if (!run_args([ "ip", "route", "add", "local", "0.0.0.0/0", "dev", "lo", "table", table ]) && !tproxy_route4_present(table)) {
            log_fatal("Failed to add IPv4 route for tproxy. Aborted.");
            return false;
        }
    }
    else {
        log_debug("IPv4 TPROXY route already exists");
    }

    // IPv6 is disabled on this router (core/ipv6.uc): IPv4 only.
    let with_ipv6 = ipv6.available();
    if (!with_ipv6)
        log_debug("IPv6 is disabled: no IPv6 TPROXY route and rule");
    else if (!tproxy_route6_present(table)) {
        log_debug("Added IPv6 TPROXY route");
        if (!run_args([ "ip", "-6", "route", "add", "local", "::/0", "dev", "lo", "table", table ]) && !tproxy_route6_present(table)) {
            log_fatal("Failed to add IPv6 route for tproxy. Aborted.");
            return false;
        }
    }
    else {
        log_debug("IPv6 TPROXY route already exists");
    }

    if (!tproxy_marking_rule4_present(table, mark)) {
        log_debug("Creating IPv4 TPROXY marking rule");
        if (!run_args([ "ip", "-4", "rule", "add", "fwmark", as_string(mark) + "/" + as_string(mark), "table", table, "priority", TPROXY_RULE_PRIORITY ]) && !tproxy_marking_rule4_present(table, mark)) {
            log_fatal("Failed to create IPv4 marking rule. Aborted.");
            return false;
        }
    }
    else {
        log_debug("IPv4 TPROXY marking rule already exists");
    }

    if (with_ipv6 && !tproxy_marking_rule6_present(table, mark)) {
        log_debug("Creating IPv6 TPROXY marking rule");
        if (!run_args([ "ip", "-6", "rule", "add", "fwmark", as_string(mark) + "/" + as_string(mark), "table", table, "priority", TPROXY_RULE_PRIORITY ]) && !tproxy_marking_rule6_present(table, mark)) {
            log_fatal("Failed to create IPv6 marking rule. Aborted.");
            return false;
        }
    }
    else if (with_ipv6) {
        log_debug("IPv6 TPROXY marking rule already exists");
    }

    return true;
}

// Stop: Prokop's marking rules go; the table's route is flushed only when
// no other program's rule looks it up (Podkop's table 105, NET-3).
function remove_tproxy_route_rule(table, mark) {
    let ok = true;
    for (let family in [ "4", "6" ]) {
        let rule_present = family == "4" ? tproxy_marking_rule4_present : tproxy_marking_rule6_present;
        if (rule_present(table, mark) &&
            !run_args([ "ip", "-" + family, "rule", "del", "fwmark", as_string(mark) + "/" + as_string(mark), "table", table, "priority", TPROXY_RULE_PRIORITY ]))
            ok = false;

        let route_present = family == "4" ? tproxy_route4_present : tproxy_route6_present;
        if (!route_present(table))
            continue;
        if (has_foreign_table_rule_text(command_output_quiet_from_args([ "ip", "-" + family, "rule", "list" ]), table, mark)) {
            log_debug("IPv" + family + " TPROXY table " + TPROXY_RULE_TABLE_ID + " is used by another program's rule; its route stays");
            continue;
        }
        if (!run_args(family == "4" ? [ "ip", "route", "flush", "table", table ] : [ "ip", "-6", "route", "flush", "table", table ]))
            ok = false;
    }
    return ok;
}

// br_netfilter's iptables hooks: off while Prokop runs, put back at stop
// (nft/bridge_netfilter.uc; D-19, UC-109).
function bridge_netfilter_log(message, level) {
    run_args([ "logger", "-t", "prokop", "[" + as_string(level) + "] " + as_string(message) ]);
}

function ensure_bridge_netfilter_disabled() {
    return require("nft.bridge_netfilter").turn_off(bridge_netfilter_log);
}

function restore_bridge_netfilter() {
    return require("nft.bridge_netfilter").restore(bridge_netfilter_log);
}

function community_service_has_subnet_list(value) {
    return rule_config.community_service_has_subnet_list(value);
}

function filter_community_subnet_lists_value(value) {
    return rule_config.filter_community_subnet_lists_value(value);
}

function signature_add_value(body, key, value) {
    return body + "[" + as_string(key) + "]\n" + as_string(value) + "\n";
}

function signature_hash(body) {
    let path = trim(command_output_from_args([ "mktemp" ]));
    if (path == "")
        return "";

    if (!write_text_file(path, body)) {
        unlink_file(path);
        return "";
    }

    let hash_line = command_output_from_args([ "md5sum", path ]);
    unlink_file(path);
    hash_line = trim(hash_line);

    return length(hash_line) >= 32 ? substr(hash_line, 0, 32) : "";
}

function nft_rule_signature_body(body, section) {
    let section_name = as_string(section[".name"]);

    if (section_name == "" || !bool_option(section, "enabled", true))
        return body;

    let action = option(section, "action", "");
    body = signature_add_value(body, "rule." + section_name + ".action", action);
    if (action == "dns") {
        body = signature_add_value(body, "rule." + section_name + ".source_ip_cidr", section_rule_condition_csv(section, "source_ip_cidr", "subnets"));
        let excluded_sources = section_rule_condition_csv(section, "excluded_source_ip_cidr", "subnets");
        if (excluded_sources != "")
            body = signature_add_value(body, "rule." + section_name + ".excluded_source_ip_cidr", excluded_sources);
        body = signature_add_value(body, "rule." + section_name + ".source_aware_dns", connections.has_dns_matchers(section) ? "1" : "0");
        body = signature_add_value(body, "rule." + section_name + ".fully_routed_ips", option(section, "fully_routed_ips", ""));
        return body;
    }
    body = signature_add_value(body, "rule." + section_name + ".ip_cidr", section_rule_condition_csv(section, "ip_cidr", "subnets"));
    body = signature_add_value(body, "rule." + section_name + ".source_ip_cidr", section_rule_condition_csv(section, "source_ip_cidr", "subnets"));
    let excluded_sources = section_rule_condition_csv(section, "excluded_source_ip_cidr", "subnets");
    if (excluded_sources != "")
        body = signature_add_value(body, "rule." + section_name + ".excluded_source_ip_cidr", excluded_sources);
    body = signature_add_value(body, "rule." + section_name + ".source_aware_dns", connections.has_dns_matchers(section) ? "1" : "0");
    body = signature_add_value(body, "rule." + section_name + ".ports", section_rule_ports_csv(section));
    body = signature_add_value(body, "rule." + section_name + ".fully_routed_ips", option(section, "fully_routed_ips", ""));
    body = signature_add_value(body, "rule." + section_name + ".community_subnet_lists", filter_community_subnet_lists_value(connections.community_lists_value(section)));
    body = signature_add_value(body, "rule." + section_name + ".remote_subnet_lists", option(section, "remote_subnet_lists", ""));
    body = signature_add_value(body, "rule." + section_name + ".rule_set_with_subnets", connections.rule_sets_with_subnets_value(section));
    body = signature_add_value(body, "rule." + section_name + ".domain_ip_lists", option(section, "domain_ip_lists", ""));

    return body;
}

function client_dns_intercept_exclusions_value(settings) {
    let excluded = connections.client_dns_intercept_exclusions(settings);
    return join(",", [ ...excluded.v4, ...excluded.v6 ]);
}

function nft_runtime_signature_from_settings_and_sections(settings, sections) {
    let body = "";

    body = signature_add_value(body, "settings.source_network_interfaces", option(settings, "source_network_interfaces", "br-lan"));
    body = signature_add_value(body, "settings.exclude_ntp", bool_option(settings, "exclude_ntp", false) ? "1" : "0");
    body = signature_add_value(body, "settings.intercept_client_dns", connections.client_dns_intercept_enabled(settings, sections) ? "1" : "0");
    body = signature_add_value(body, "settings.intercept_client_dns_exclude", client_dns_intercept_exclusions_value(settings));

    for (let section in sections)
        body = nft_rule_signature_body(body, object_or_empty(section));

    return signature_hash(body);
}

function print_nft_runtime_signature_from_settings_and_sections(settings, sections) {
    let hash = nft_runtime_signature_from_settings_and_sections(settings, sections);
    if (hash == "")
        return false;

    print(hash, "\n");
    return true;
}

function word_set(value) {
    let result = {};
    for (let item in whitespace_values(value))
        result[item] = true;
    return result;
}

function fixture_section_list(data, type_name) {
    let value = object_or_empty(data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function section_by_name(sections, section_name) {
    section_name = as_string(section_name);
    for (let section in sections)
        if (as_string(section[".name"]) == section_name)
            return section;
    return null;
}

function nft_create_provider_output_rules_from_uci(table, action, provider_bin, route_mark_base, queue_base, desync_mark, desync_mark_postnat) {
    return nft_create_provider_output_rules_from_sections(
        uci_sections("section"),
        table,
        action,
        provider_bin,
        route_mark_base,
        queue_base,
        desync_mark,
        desync_mark_postnat
    );
}

// NET-12: the sets of the client DNS intercept, in each table that has it:
// the excluded addresses (intercept_client_dns_exclude) by family, and the
// router's delegated IPv6 prefixes, which are the LAN as much as localv6 is.
const CLIENT_DNS_SKIP4_SET = "dns_intercept_skip4";
const CLIENT_DNS_SKIP6_SET = "dns_intercept_skip6";
const CLIENT_DNS_LAN6_SET = "dns_intercept_lan6";

function network_interface_dump() {
    let output = command_output_quiet_from_args([ "ubus", "call", "network.interface", "dump" ]);
    try {
        let data = json(output || "{}");
        return type(data?.interface) == "array" ? data.interface : [];
    }
    catch (e) {
        return [];
    }
}

// The prefixes delegated to the router (ipv6-prefix on the uplink) and the
// parts assigned to its networks (ipv6-prefix-assignment), as the network
// daemon has them when the table is built.
function delegated_ipv6_prefixes(dump) {
    let result = [];
    for (let entry in dump)
        for (let key in [ "ipv6-prefix", "ipv6-prefix-assignment" ])
            for (let prefix in (type(entry?.[key]) == "array" ? entry[key] : [])) {
                let text = lc(as_string(prefix?.address) + "/" + as_string(prefix?.mask));
                if (core_ip.valid_ipv6_cidr(text) && index(result, text) < 0)
                    push(result, text);
            }
    return result;
}

function dnsmasq_settings() {
    let found = uci_core.section_objects("dhcp", "dnsmasq");
    return length(found) > 0 ? object_or_empty(found[0]) : null;
}

// The port dnsmasq answers DNS on: 53 by default, 0 when its DNS is off.
function dnsmasq_dns_port(dnsmasq) {
    let value = trim(option(dnsmasq, "port", "53"));
    return match(value, /^[0-9]+$/) != null ? +value : 53;
}

// The source interfaces (exact names only) on which dnsmasq does not answer:
// those of its notinterface networks and, when it lists the networks it
// serves (interface), those of no listed network. A network the network
// daemon does not report makes the listed ones unknown: nothing is
// left out then.
function dnsmasq_unserved_interfaces(dnsmasq, dump, source_names) {
    let devices = {};
    for (let entry in dump) {
        let name = as_string(entry?.interface);
        let names = [];
        for (let key in [ "l3_device", "device" ])
            if (as_string(entry?.[key]) != "")
                push(names, as_string(entry[key]));
        if (name != "")
            devices[name] = names;
    }
    let served = null;
    let listed = whitespace_values(option(dnsmasq, "interface", ""));
    if (length(listed) > 0) {
        served = {};
        for (let name in listed) {
            if (devices[name] == null)
                return [];
            for (let device in devices[name])
                served[device] = true;
        }
    }
    let excluded = {};
    for (let name in whitespace_values(option(dnsmasq, "notinterface", "")))
        for (let device in (devices[name] ?? []))
            excluded[device] = true;
    let result = [];
    for (let name in source_names)
        if (index(name, "*") < 0 && (excluded[name] || (served != null && !served[name])) && index(result, name) < 0)
            push(result, name);
    return result;
}

// What the intercept does with this configuration, or null when it is off
// (intercept_client_dns) or would only break DNS: dnsmasq answers no DNS
// (port 0), or on none of the source interfaces.
function client_dns_intercept_plan(settings, sections) {
    if (!connections.client_dns_intercept_enabled(settings, sections))
        return null;
    let dnsmasq = dnsmasq_settings();
    if (dnsmasq != null && dnsmasq_dns_port(dnsmasq) == 0) {
        log_warning("Client DNS is not intercepted: dnsmasq answers no DNS (port 0)");
        return null;
    }
    let dump = network_interface_dump();
    let source_names = whitespace_values(option(settings, "source_network_interfaces", "br-lan"));
    let unserved = dnsmasq != null ? dnsmasq_unserved_interfaces(dnsmasq, dump, source_names) : [];
    if (length(unserved) > 0 && length(unserved) == length(source_names)) {
        log_warning("Client DNS is not intercepted: dnsmasq answers DNS on none of the source interfaces");
        return null;
    }
    let excluded = connections.client_dns_intercept_exclusions(settings);
    return { skip4: excluded.v4, skip6: excluded.v6, lan6: delegated_ipv6_prefixes(dump), unserved };
}

// NET-6 (config/connections.uc client_dns_intercept_enabled): plain DNS of
// clients to foreign servers goes to the router's dnsmasq. DNS to the LAN
// (a Pi-hole, a delegated IPv6 prefix), to the router itself and DoT (853)
// is left alone, and so is DNS from or to an excluded address and on an
// interface dnsmasq does not answer on (NET-12). The rules of one table,
// after its source-aware DNS redirect.
function client_dns_intercept_rules(interface_set, localv4_set, localv6_set, plan) {
    let unserved = [];
    for (let name in plan?.unserved ?? [])
        push(unserved, sprintf("%J", name));
    let rules = [];
    for (let family in [ [ "ip", localv4_set, CLIENT_DNS_SKIP4_SET ], [ "ip6", localv6_set, CLIENT_DNS_SKIP6_SET ] ])
        for (let proto in [ "udp", "tcp" ]) {
            let rule = [ "iifname", "@" + as_string(interface_set) ];
            if (length(unserved) > 0)
                push(rule, "iifname", "!=", "{ " + join(", ", unserved) + " }");
            push(rule, family[0], "saddr", "!=", "@" + family[2],
                family[0], "daddr", "!=", "@" + as_string(family[1]), family[0], "daddr", "!=", "@" + family[2]);
            if (family[0] == "ip6")
                push(rule, "ip6", "daddr", "!=", "@" + CLIENT_DNS_LAN6_SET);
            push(rules, [ ...rule, "fib", "daddr", "type", "!=", "local", proto, "dport", "53", "counter", "redirect", "to", ":53" ]);
        }
    return rules;
}

// The sets of the intercept as lines of the kill-switch table `t`
// ("inet <name>"); elements only with a plan.
function client_dns_intercept_set_lines(t, plan) {
    let lines = [];
    for (let set in [ [ CLIENT_DNS_SKIP4_SET, "ipv4_addr", plan?.skip4 ], [ CLIENT_DNS_SKIP6_SET, "ipv6_addr", plan?.skip6 ],
            [ CLIENT_DNS_LAN6_SET, "ipv6_addr", plan?.lan6 ] ]) {
        push(lines, "add set " + t + " " + set[0] + " { type " + set[1] + "; flags interval; auto-merge; }");
        if (length(set[2] ?? []) > 0)
            push(lines, "add element " + t + " " + set[0] + " { " + join(", ", set[2]) + " }");
    }
    return lines;
}

function nft_add_client_dns_intercept_from_uci(table, interface_set, localv4_set, localv6_set) {
    let plan = client_dns_intercept_plan(uci_settings(), uci_sections("section"));
    if (plan == null)
        return true;
    for (let set in [ [ CLIENT_DNS_SKIP4_SET, nft_create_ipv4_set, plan.skip4 ], [ CLIENT_DNS_SKIP6_SET, nft_create_ipv6_set, plan.skip6 ],
            [ CLIENT_DNS_LAN6_SET, nft_create_ipv6_set, plan.lan6 ] ])
        if (!set[1](table, set[0]) || (length(set[2]) > 0 && !nft_add_set_elements(table, set[0], join(",", set[2]))))
            return false;
    for (let rule in client_dns_intercept_rules(interface_set, localv4_set, default_arg(localv6_set, "localv6"), plan))
        if (!nft_add_rule(table, "dns_redirect", rule))
            return false;
    return true;
}

function nft_create_full_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat, zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    log_debug("Building nftables runtime model");

    return ensure_tproxy_route_rule(rt_table, fakeip_mark) &&
        nft_create_runtime_base_from_uci(table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) &&
        nft_add_client_dns_intercept_from_uci(table, interface_set, localv4_set, localv6_set) &&
        nft_add_section_priority_rules_from_sections(uci_sections("section"), table, interface_set, localv4_set, localv6_set, fakeip_mark, fakeip_range, fakeip6_range) &&
        nft_create_provider_output_rules_from_uci(table, "zapret", zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat) &&
        nft_create_provider_output_rules_from_uci(table, "zapret2", zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat) &&
        nft_create_runtime_output_rules(table, localv4_set, common_set, port_set, ip_port_set, fakeip_mark, fakeip_range, localv6_set, common6_set, ip_port6_set, fakeip6_range);
}

function nft_table_present(table) {
    return run_args_quiet([ "nft", "list", "table", "inet", table ]);
}

function nft_delete_table(table) {
    return run_args([ "nft", "delete", "table", "inet", table ]);
}

function nft_validate_candidate_batch(path) {
    path = as_string(path);
    let stat = fs.stat(path);
    if (path == "" || stat == null || int(stat.size || 0) <= 0)
        return false;
    if (NFT_CANDIDATE_FAIL_PHASE == "check")
        return false;
    return run_args([ "nft", "-c", "-f", path ]);
}

function nft_commit_candidate_batch(path) {
    path = as_string(path);
    let stat = fs.stat(path);
    if (path == "" || stat == null || int(stat.size || 0) <= 0)
        return false;
    if (NFT_CANDIDATE_FAIL_PHASE == "apply")
        return false;
    return run_args([ "nft", "-f", path ]);
}

function nft_apply_candidate_batch(path) {
    // Backward-compatible one-shot candidate application for paths which do
    // not also transition sing-box. Cross-component transitions validate via
    // nft_validate_candidate_batch() before any live state changes, then call
    // nft_commit_candidate_batch() only after sing-box is ready.
    return nft_validate_candidate_batch(path) && nft_commit_candidate_batch(path);
}

function nft_transition_guard_batch(table, mark, remove) {
    let path = trim(command_output_from_args([ "mktemp" ]));
    if (path == "")
        return false;

    let data = remove
        ? "delete chain inet " + as_string(table) + " " + NFT_TRANSITION_GUARD_CHAIN + "\n"
        : "add chain inet " + as_string(table) + " " + NFT_TRANSITION_GUARD_CHAIN +
            " { type filter hook prerouting priority -101; policy accept; }\n" +
            "add rule inet " + as_string(table) + " " + NFT_TRANSITION_GUARD_CHAIN +
            " meta mark & " + as_string(mark) + " == " + as_string(mark) + " counter drop\n";
    // On a full tmpfs writefile reports success and leaves the file empty,
    // and an empty batch passes `nft -c` and `nft -f` while it changes
    // nothing: the batch is read back first (UC-223).
    let ok = fs.writefile(path, data) != null && fs.readfile(path) === data &&
        run_args([ "nft", "-c", "-f", path ]) && run_args([ "nft", "-f", path ]);
    fs.unlink(path);
    return ok;
}

function nft_install_transition_guard(table, mark) {
    // This hook is after mangle marking (-149) but before TPROXY (-100).
    // During a cross-component transition it drops only traffic Prokop has
    // classified as protected, preventing a new config/table mismatch from
    // reaching route.final/direct.
    if (run_args_quiet([ "nft", "list", "chain", "inet", table, NFT_TRANSITION_GUARD_CHAIN ]))
        return false;
    return nft_transition_guard_batch(table, mark, false);
}

function nft_remove_transition_guard(table, mark) {
    if (!run_args_quiet([ "nft", "list", "chain", "inet", table, NFT_TRANSITION_GUARD_CHAIN ]))
        return true;
    return nft_transition_guard_batch(table, mark, true);
}

function nft_dpi_transition_guard(table, remove) {
    // This output hook runs after Prokop's route hook (-150), including its
    // NFQUEUE bypass rules, and drops provider-marked packets until the old
    // or new DPI processes and nft table are a coherent pair.
    let guard_table = as_string(table) + "DpiGuard";
    if (match(guard_table, /^[A-Za-z][A-Za-z0-9_]*$/) == null)
        return false;
    let path = trim(command_output_from_args([ "mktemp" ]));
    if (path == "")
        return false;
    let present = run_args_quiet([ "nft", "list", "table", "inet", guard_table ]);
    if ((!remove && present) || (remove && !present)) {
        fs.unlink(path);
        return remove && !present;
    }
    let data = remove
        ? "delete table inet " + guard_table + "\n"
        : "add table inet " + guard_table + "\n" +
            "add chain inet " + guard_table + " output { type filter hook output priority -149; policy accept; }\n" +
            "add rule inet " + guard_table + " output meta mark & 0xff000000 == 0x01000000 drop\n" +
            "add rule inet " + guard_table + " output meta mark & 0xff000000 == 0x02000000 drop\n";
    // On a full tmpfs writefile reports success and leaves the file empty,
    // and an empty batch passes `nft -c` and `nft -f` while it changes
    // nothing: the batch is read back first (UC-223).
    let ok = fs.writefile(path, data) != null && fs.readfile(path) === data &&
        run_args([ "nft", "-c", "-f", path ]) && run_args([ "nft", "-f", path ]);
    fs.unlink(path);
    return ok;
}

// A table carrying the guard's name is only trusted when `nft -j` shows exactly
// the structure nft_dpi_transition_guard() creates: one output base chain
// (filter, priority -149, policy accept) with the two provider-mark drops.
const DPI_GUARD_MARK_MASK = 4278190080;          // 0xff000000
const DPI_GUARD_PROVIDER_MARKS = [ 16777216, 33554432 ];   // 0x01000000, 0x02000000

function dpi_guard_rule_mark(rule) {
    let expr = rule.expr;
    if (type(expr) != "array" || length(expr) != 2 ||
        type(expr[1]) != "object" || length(keys(expr[1])) != 1 || !("drop" in expr[1]))
        return null;
    let test = type(expr[0]) == "object" && length(keys(expr[0])) == 1 ? expr[0].match : null;
    if (type(test) != "object" || test.op != "==" || type(test.left) != "object")
        return null;
    // nft < 1.1.0 lists the mask contiguous from the top bit as a prefix of
    // the mark: `meta mark 0x01000000/8` is the same rule (UC-106).
    let prefix = type(test.right) == "object" ? test.right.prefix : null;
    if (type(prefix) == "object") {
        if (length(keys(test.right)) != 1 || type(test.left.meta) != "object" || length(keys(test.left)) != 1 ||
            test.left.meta.key != "mark" || prefix.len !== 8)
            return null;
        return index(DPI_GUARD_PROVIDER_MARKS, prefix.addr) >= 0 ? prefix.addr : null;
    }
    let masked = test.left["&"];
    if (type(masked) != "array" || length(masked) != 2 || type(masked[0]) != "object" ||
        type(masked[0].meta) != "object" || masked[0].meta.key != "mark" ||
        masked[1] != DPI_GUARD_MARK_MASK)
        return null;
    return index(DPI_GUARD_PROVIDER_MARKS, test.right) >= 0 ? test.right : null;
}

function dpi_guard_json_valid(parsed, guard_table) {
    if (type(parsed) != "object" || type(parsed.nftables) != "array")
        return false;
    let tables = 0, chains = 0, marks = [];
    for (let item in parsed.nftables) {
        if (type(item) != "object" || length(keys(item)) != 1)
            return false;
        let kind = keys(item)[0], object = item[kind];
        if (kind == "metainfo")
            continue;
        if (type(object) != "object" || object.family != "inet")
            return false;
        if (kind == "table") {
            if (object.name != guard_table)
                return false;
            tables++;
        }
        else if (kind == "chain") {
            if (object.table != guard_table || object.name != "output" || object.type != "filter" ||
                object.hook != "output" || object.prio != -149 || object.policy != "accept")
                return false;
            chains++;
        }
        else if (kind == "rule") {
            if (object.table != guard_table || object.chain != "output")
                return false;
            let mark = dpi_guard_rule_mark(object);
            if (mark == null || index(marks, mark) >= 0)
                return false;
            push(marks, mark);
        }
        else
            return false;
    }
    return tables == 1 && chains == 1 && length(marks) == length(DPI_GUARD_PROVIDER_MARKS);
}

// "absent", "valid" or "invalid" (present but not the expected protection).
function nft_dpi_transition_guard_state(table) {
    let guard_table = as_string(table) + "DpiGuard";
    if (match(guard_table, /^[A-Za-z][A-Za-z0-9_]*$/) == null)
        return "invalid";
    if (!run_args_quiet([ "nft", "list", "table", "inet", guard_table ]))
        return "absent";
    let parsed = null;
    try {
        parsed = json(command_output_from_args([ "nft", "-j", "list", "table", "inet", guard_table ]));
    }
    catch (e) {
        return "invalid";
    }
    return dpi_guard_json_valid(parsed, guard_table) ? "valid" : "invalid";
}

// Idempotent install for callers that may run while their own guard is still
// active (config restore after needs_attention): reuse a verified guard, create
// a missing one, and fail closed on anything unexpected.
function nft_dpi_transition_guard_ensure(table) {
    let state = nft_dpi_transition_guard_state(table);
    if (state != "absent")
        return state == "valid";
    if (!nft_dpi_transition_guard(table, false))
        return false;
    if (nft_dpi_transition_guard_state(table) == "valid")
        return true;
    // A guard this call created but cannot verify would stay behind dropping
    // DPI traffic while the caller reports failure (UC-106): remove it.
    nft_dpi_transition_guard(table, true);
    return false;
}

function killswitch_section_enabled(section) {
    section = object_or_empty(section);
    return bool_option(section, "enabled", true) &&
        connections.is_connections_action(section_action(section)) &&
        bool_option(section, "kill_switch", false);
}

function killswitch_counter_name(section) {
    return "ks_" + as_string(section[".name"]);
}

// The elements of every set of a table, from one `nft list table` (audit
// optimization 23: one nft process instead of one per set and section).
// An empty set has no "elements" clause and yields "".
function nft_table_set_elements(output) {
    let sets = {};
    let current = null;
    let collecting = null;
    for (let line in split(as_string(output), "\n")) {
        if (collecting != null) {
            let end = index(line, "}");
            collecting += " " + (end >= 0 ? substr(line, 0, end) : line);
            if (end >= 0) {
                sets[current] = trim(replace(collecting, /[[:space:]]+/g, " "));
                collecting = null;
            }
            continue;
        }
        let set = match(line, /^[[:space:]]*set ([A-Za-z0-9_]+) \{[[:space:]]*$/);
        if (set != null) {
            current = set[1];
            sets[current] = "";
            continue;
        }
        let elements = current != null ? match(line, /^[[:space:]]*elements = \{(.*)$/) : null;
        if (elements == null)
            continue;
        let end = index(elements[1], "}");
        if (end >= 0)
            sets[current] = trim(replace(substr(elements[1], 0, end), /[[:space:]]+/g, " "));
        else
            collecting = elements[1];
    }
    return sets;
}

let live_table_sets = {};

function nft_set_elements_from_set(table, set_name) {
    let output = command_output_quiet_from_args([ "nft", "list", "set", "inet", table, set_name ]);
    if (output == "")
        return null;
    let found = match(output, /elements = \{([^}]*)\}/);
    return found == null ? "" : trim(replace(found[1], /[[:space:]]+/g, " "));
}

function nft_set_elements_from_table(table, set_name) {
    if (!exists(live_table_sets, table)) {
        let output = command_output_quiet_from_args([ "nft", "list", "table", "inet", table ]);
        live_table_sets[table] = output == "" ? null : nft_table_set_elements(output);
    }
    let sets = live_table_sets[table];
    if (sets != null && exists(sets, set_name))
        return sets[set_name];
    // Not in the table listing: asked on its own, so a listing this parser
    // does not read never loses a set. A missing set is an error (null).
    return nft_set_elements_from_set(table, set_name);
}

// The source interfaces as elements of the kill-switch's interface set, or
// null when one is not an interface name: the validator rejects it, and a
// name left out would leave its clients unprotected (NET-14).
function killswitch_interface_elements(settings) {
    let result = [];
    for (let name in whitespace_values(option(settings, "source_network_interfaces", "br-lan"))) {
        if (!connections.valid_source_interface_name(name))
            return null;
        push(result, sprintf("%J", name));
    }
    return result;
}

// Renders the persistent kill-switch table. The policy mirrors Prokop's own
// ordered priority chain, built by the same rule builders, on the forward
// hook: a packet reaching forward to a protected destination was by
// definition not TPROXY'd into sing-box, so it would leave directly. Sections
// before the last protected one keep their first-match verdict: bypass, DPI
// and unprotected connection sections return, protected ones reject. Set
// contents are copied from the live ProkopTable, which already holds the
// complete list generation.
function nft_killswitch_render_sections(sections, settings, live_table, ks_table, out_path, fakeip_range, fakeip6_range) {
    fakeip_range = default_arg(fakeip_range, "198.18.0.0/15");
    fakeip6_range = default_arg(fakeip6_range, "fc00::/18");
    ks_table = as_string(ks_table);

    let result = { ok: false, sections: [], rule_sections: [], set_elements: 0, error: "" };
    if (match(ks_table, /^[A-Za-z][A-Za-z0-9_]*$/) == null) {
        result.error = "invalid kill-switch table name";
        return result;
    }

    let last_index = -1;
    for (let i = 0; i < length(sections); i++) {
        if (killswitch_section_enabled(sections[i])) {
            push(result.sections, as_string(sections[i][".name"]));
            last_index = i;
        }
    }
    if (last_index < 0) {
        result.error = "no protected sections";
        return result;
    }

    let interfaces = killswitch_interface_elements(settings);
    if (interfaces == null) {
        result.error = "invalid source network interface";
        return result;
    }
    if (length(interfaces) == 0) {
        result.error = "no source network interfaces";
        return result;
    }

    let t = "inet " + ks_table;
    let lines = [
        "# Prokop VPN kill-switch. Generated; do not edit.",
        "add table " + t,
        "delete table " + t,
        "add table " + t,
        "add set " + t + " " + KILLSWITCH_INTERFACE_SET + " { type ifname; flags interval; auto-merge; }",
        "add element " + t + " " + KILLSWITCH_INTERFACE_SET + " { " + join(", ", interfaces) + " }",
        "add set " + t + " localv4 { type ipv4_addr; flags interval; auto-merge; }",
        "add element " + t + " localv4 { " + join(", ", LOCALV4_RANGES) + " }",
        "add set " + t + " localv6 { type ipv6_addr; flags interval; auto-merge; }",
        "add element " + t + " localv6 { " + join(", ", LOCALV6_RANGES) + " }",
        "add counter " + t + " " + KILLSWITCH_FAKEIP_COUNTER
    ];
    for (let i = 0; i <= last_index; i++)
        if (killswitch_section_enabled(sections[i]))
            push(lines, "add counter " + t + " " + killswitch_counter_name(sections[i]));
    push(lines,
        "add chain " + t + " " + KILLSWITCH_REJECT_CHAIN,
        "add rule " + t + " " + KILLSWITCH_REJECT_CHAIN + " meta l4proto tcp reject with tcp reset",
        "add rule " + t + " " + KILLSWITCH_REJECT_CHAIN + " reject with icmpx admin-prohibited",
        "add chain " + t + " " + KILLSWITCH_POLICY_CHAIN,
        // Empty unless sing-box died while dnsmasq still forwards to it; the
        // kill-switch watcher then redirects client DNS to its standby
        // resolver. It runs before Prokop's own DNS redirect (-101).
        "add chain " + t + " " + KILLSWITCH_DNS_CHAIN + " { type nat hook prerouting priority -102; policy accept; }",
        "add chain " + t + " " + KILLSWITCH_FORWARD_CHAIN + " { type filter hook forward priority -5; policy accept; }",
        "add rule " + t + " " + KILLSWITCH_FORWARD_CHAIN + " meta l4proto != { tcp, udp } return",
        ...(bool_option(settings, "exclude_ntp", false)
            ? [ "add rule " + t + " " + KILLSWITCH_FORWARD_CHAIN + " udp dport 123 return" ] : []),
        "add rule " + t + " " + KILLSWITCH_FORWARD_CHAIN + " ct direction reply return",
        "add rule " + t + " " + KILLSWITCH_FORWARD_CHAIN + " ct status dnat return",
        "add rule " + t + " " + KILLSWITCH_FORWARD_CHAIN + " iifname != @" + KILLSWITCH_INTERFACE_SET + " return",
        // FakeIP answers are only meaningful to sing-box. A client that still
        // holds one after Prokop stopped must fail fast, never leave via WAN.
        "add rule " + t + " " + KILLSWITCH_FORWARD_CHAIN + " ip daddr " + fakeip_range + " counter name " + KILLSWITCH_FAKEIP_COUNTER + " jump " + KILLSWITCH_REJECT_CHAIN,
        "add rule " + t + " " + KILLSWITCH_FORWARD_CHAIN + " ip6 daddr " + fakeip6_range + " counter name " + KILLSWITCH_FAKEIP_COUNTER + " jump " + KILLSWITCH_REJECT_CHAIN,
        "add rule " + t + " " + KILLSWITCH_FORWARD_CHAIN + " ip daddr @localv4 return",
        "add rule " + t + " " + KILLSWITCH_FORWARD_CHAIN + " ip6 daddr @localv6 return",
        "add rule " + t + " " + KILLSWITCH_FORWARD_CHAIN + " jump " + KILLSWITCH_POLICY_CHAIN
    );
    // NET-6: client DNS to foreign servers goes to the router's dnsmasq,
    // which answers with the block list while Prokop is stopped. After
    // Prokop's own redirect (-101): the first redirect of a connection wins.
    // Its sets are always there: the watcher's redirect of excluded devices
    // (killswitch/runtime.uc exempt_redirect_rules) uses them too.
    let intercept = client_dns_intercept_plan(settings, sections);
    push(lines, ...client_dns_intercept_set_lines(t, intercept));
    if (intercept != null) {
        push(lines, "add chain " + t + " ks_dns_intercept { type nat hook prerouting priority -100; policy accept; }");
        for (let rule in client_dns_intercept_rules(KILLSWITCH_INTERFACE_SET, "localv4", "localv6", intercept))
            push(lines, "add rule " + t + " ks_dns_intercept " + join(" ", rule));
    }

    let element_lines = [];
    let ok = true;
    for (let i = 0; i <= last_index && ok; i++) {
        let section = object_or_empty(sections[i]);
        if (!bool_option(section, "enabled", true) || !section_needs_priority_sets(section))
            continue;

        let protected = killswitch_section_enabled(section);
        nft_render_lines = [];
        nft_priority_verdict_override = protected
            ? [ "counter", "name", killswitch_counter_name(section), "jump", KILLSWITCH_REJECT_CHAIN ]
            : [ "return" ];
        let built = nft_add_section_priority_rules(ks_table, section, KILLSWITCH_INTERFACE_SET, "localv4", "localv6", "0", fakeip_range, fakeip6_range);
        let recorded = nft_render_lines;
        nft_render_lines = null;
        nft_priority_verdict_override = null;
        if (!built) {
            result.error = "could not build rules for section " + as_string(section[".name"]);
            ok = false;
            break;
        }

        // Router-originated traffic belongs to Prokop's own bootstrap and
        // list downloads; the kill-switch protects forwarded client traffic.
        let output_prefix = "add rule inet " + ks_table + " priority_output_rules ";
        for (let line in recorded)
            if (substr(line, 0, length(output_prefix)) != output_prefix)
                push(lines, line);
        if (protected)
            push(result.rule_sections, as_string(section[".name"]));

        for (let set_name in values(section_priority_sets(section))) {
            let elements = nft_set_elements_from_table(live_table, set_name);
            if (elements == null) {
                result.error = "live set " + set_name + " is missing from table " + as_string(live_table);
                ok = false;
                break;
            }
            if (elements != "") {
                push(element_lines, "add element " + t + " " + set_name + " { " + elements + " }");
                result.set_elements++;
            }
        }
    }
    if (!ok)
        return result;

    for (let line in element_lines)
        push(lines, line);

    if (!write_text_file(out_path, join("\n", lines) + "\n")) {
        result.error = "could not write " + as_string(out_path);
        return result;
    }
    result.ok = true;
    return result;
}

function nft_rebuild_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat, zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    log_debug("Applying nftables runtime rules");

    // In a batch the table may be gone by the commit (fw4 flush, a stop
    // meanwhile): 'add' before 'delete' makes the delete always valid
    // (NET-10), as the kill-switch batch does.
    if (NFT_BATCH_FILE != "") {
        if (!run_args([ "nft", "add", "table", "inet", table ]) || !nft_delete_table(table))
            return false;
    }
    else if (nft_table_present(table) && !nft_delete_table(table))
        return false;

    return nft_create_full_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat, zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address);
}

function nft_runtime_signature_from_uci() {
    return print_nft_runtime_signature_from_settings_and_sections(
        uci_settings(),
        uci_sections("section")
    );
}

function fixture_section(path, section_name) {
    let data = object_or_empty(common_read_json_file(path));
    connections.set_item_sections_from_data(data);
    return section_by_name(fixture_section_list(data, "section"), section_name);
}

function fixture_settings(data) {
    return object_or_empty(object_or_empty(data).settings);
}

function nft_runtime_signature_from_fixture(path) {
    let data = object_or_empty(common_read_json_file(path));
    connections.set_item_sections_from_data(data);
    return print_nft_runtime_signature_from_settings_and_sections(fixture_settings(data), fixture_section_list(data, "section"));
}

function nft_add_section_source_matchers(section, table, chunk_size_text) {
    let source_values = section_source_ip_values(section);
    if (source_values == "")
        return true;

    let sets = section_priority_sets(section);
    return nft_add_csv_chunks_to_family_sets(source_values, table, sets.sources, sets.sources6, "ips", "", chunk_size_text);
}

function nft_add_section_excluded_source_matchers(section, table, chunk_size_text) {
    let source_values = section_excluded_source_ip_values(section);
    if (source_values == "")
        return true;

    let sets = section_priority_sets(section);
    return nft_add_csv_chunks_to_family_sets(source_values, table, sets.excluded_sources, sets.excluded_sources6, "ips", "", chunk_size_text);
}

function nft_add_section_fully_routed_sources(section, table, chunk_size_text) {
    let seen = {};
    let values = [];
    for (let source_ip in list_option(section, "fully_routed_ips")) {
        source_ip = as_string(source_ip);
        if (source_ip == "" || seen[source_ip])
            continue;
        seen[source_ip] = true;
        push(values, source_ip);
    }

    if (length(values) == 0)
        return true;

    let sets = section_priority_sets(section);
    return nft_add_csv_chunks_to_family_sets(join(",", values), table, sets.fully_sources, sets.fully_sources6, "ips", "", chunk_size_text);
}

function source_aware_dns_values(sections, deferred_sections) {
    let seen = {};
    let values = [];

    for (let section in sections) {
        if (!bool_option(section, "enabled", true) ||
            deferred_sections[as_string(section[".name"])])
            continue;

        let action = section_action(section);

        if (connections.has_dns_matchers(section)) {
            for (let value in nft_csv_values(section_source_ip_values(section))) {
                if (!seen[value]) {
                    seen[value] = true;
                    push(values, value);
                }
            }
        }

        if (connections.has_dns_matchers(section) || section_has_fully_routed_ips(section)) {
            for (let value in nft_csv_values(section_excluded_source_ip_values(section))) {
                if (!seen[value]) {
                    seen[value] = true;
                    push(values, value);
                }
            }
        }

        if (action == "bypass" || action == "dns") {
            for (let value in list_option(section, "fully_routed_ips")) {
                value = trim(as_string(value));
                if (value != "" && !seen[value]) {
                    seen[value] = true;
                    push(values, value);
                }
            }
        }
    }

    return values;
}

function nft_add_source_aware_dns_sources(sections, deferred_sections, table) {
    let values = source_aware_dns_values(sections, deferred_sections);
    if (length(values) == 0)
        return true;

    return nft_add_csv_chunks_to_family_sets(
        join(",", values),
        table,
        DNS_SOURCE_SET,
        DNS_SOURCE6_SET,
        "ips",
        "",
        5000
    );
}

function nft_populate_runtime_set_for_section(section, deferred_sections, table, common_set, port_set, ip_port_set, common6_set, ip_port6_set) {
    if (!bool_option(section, "enabled", true))
        return true;
    if (section_action(section) == "dns")
        return true;

    let ports = section_rule_ports_csv(section);
    let ip_values = section_rule_condition_csv(section, "ip_cidr", "subnets");
    let sets = section_priority_sets(section);

    if (section_needs_priority_sets(section) && !nft_add_section_source_matchers(section, table, 5000))
        return false;
    if (section_needs_priority_sets(section) && !nft_add_section_excluded_source_matchers(section, table, 5000))
        return false;

    if (deferred_sections[as_string(section[".name"])])
        return true;

    if (section_needs_priority_sets(section)) {
        if (!nft_add_section_fully_routed_sources(section, table, 5000))
            return false;

        if (!nft_add_inline_ip_cidr_matchers(ip_values, ports, table, sets.subnets, sets.port_subnets, 5000, sets.subnets6, sets.port_subnets6))
            return false;

        if (ports != "" && !section_has_destination_matchers(section) &&
            !nft_add_set_elements(table, sets.ports, ports))
            return false;
    }

    return true;
}

function nft_add_subnet_file_for_section(section, filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    let ports = section_rule_ports_csv(section);
    let sets = section_priority_sets(section);

    if (!section_needs_priority_sets(section))
        return true;

    if (ports != "")
        return nft_add_values_to_port_subnets(nft_trimmed_lines(filepath), table, sets.port_subnets, sets.port_subnets6, chunk_size_text);

    return nft_add_file_chunks_to_family_sets(filepath, table, sets.subnets, sets.subnets6, "ips", "", chunk_size_text);
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && int(stat.size) > 0;
}

// The cache file name of a prepared import, or null when it cannot be
// named safely (no checksum, or an unusual port filter).
function nft_subnet_cache_key(json_path, ports, chunk_size_text, bypass) {
    let line = trim(command_output_from_args([ "md5sum", json_path ]));
    let sum = length(line) >= 32 ? substr(line, 0, 32) : "";
    let filter = replace(as_string(ports), /[^0-9,-]/g, "_");
    if (match(sum, /^[0-9a-f]{32}$/) == null || length(filter) > 64)
        return null;
    return "v" + SUBNET_CACHE_VERSION + "-" + (bypass ? "bypass" : "capture") + "-" + sum + "-" +
        nft_chunk_size(chunk_size_text) + "-" + (filter == "" ? "all" : filter);
}

function nft_prepared_family_valid(p) {
    return type(p) == "object" && type(p.v4) == "object" && type(p.v6) == "object" &&
        type(p.v4.chunks) == "array" && type(p.v4.invalid) == "array" &&
        type(p.v6.chunks) == "array" && type(p.v6.invalid) == "array";
}

// A hit is a use: the entry's time moves on, so the entries the reloads
// keep importing are not evicted before superseded ones (UC-222).
function nft_subnet_cache_read(key) {
    let path = SUBNET_CACHE_DIR + "/" + key + ".json";
    let data = null;
    try { data = json(fs.readfile(path) || ""); } catch (e) { data = null; }
    if (type(data) != "object" || !("unscoped" in data) || !("scoped" in data))
        return null;
    for (let part in [ data.unscoped, data.scoped ])
        if (part != null && !nft_prepared_family_valid(part))
            return null;
    run_args_quiet([ "touch", "-c", path ]);
    return data;
}

// Best effort: a failed write only means the next import prepares again.
// The least recently used entries go when the cache would grow beyond
// SUBNET_CACHE_MAX entries or SUBNET_CACHE_MAX_BYTES. Entries in use are
// kept and the new entry is not: when the rule sets every reload imports do
// not all fit, evicting the least recently used one evicts the next one the
// same reload imports, and no import would ever hit. An entry larger than
// the whole limit is not kept either.
function nft_subnet_cache_write(key, prepared) {
    let data = sprintf("%J", prepared);
    if (length(data) > SUBNET_CACHE_MAX_BYTES)
        return;
    if (!fs.stat(SUBNET_CACHE_DIR) && !run_args_quiet([ "mkdir", "-p", SUBNET_CACHE_DIR ]))
        return;
    let name = key + ".json";
    let path = SUBNET_CACHE_DIR + "/" + name;
    let now = time();
    let entries = [];
    let count = 1;
    let bytes = length(data);
    for (let other in fs.lsdir(SUBNET_CACHE_DIR) || []) {
        let st = other != name && match(other, /\.json$/) != null ? fs.stat(SUBNET_CACHE_DIR + "/" + other) : null;
        if (st != null) {
            push(entries, { name: other, mtime: st.mtime, size: st.size });
            count++;
            bytes += st.size;
        }
    }
    entries = sort(entries, (a, b) => a.mtime - b.mtime);
    let evict = [];
    for (let entry in entries) {
        if (count <= SUBNET_CACHE_MAX && bytes <= SUBNET_CACHE_MAX_BYTES)
            break;
        let age = now - entry.mtime;
        if (age >= 0 && age < SUBNET_CACHE_IN_USE_SECONDS)
            continue;
        push(evict, entry.name);
        count--;
        bytes -= entry.size;
    }
    if (count > SUBNET_CACHE_MAX || bytes > SUBNET_CACHE_MAX_BYTES)
        return;
    for (let other in evict)
        fs.unlink(SUBNET_CACHE_DIR + "/" + other);
    // On a full tmpfs writefile reports success and leaves the file short.
    let written = fs.writefile(path + ".tmp", data);
    let st = fs.stat(path + ".tmp");
    if (written == null || st == null || st.size != length(data) || !fs.rename(path + ".tmp", path))
        fs.unlink(path + ".tmp");
}

function nft_apply_prepared_ruleset_subnets(prepared, label, table, common_set, ip_port_set, common6_set, ip_port6_set) {
    if (prepared.unscoped != null &&
        !nft_apply_family_chunks(table, common_set, default_arg(common6_set, "prokop_subnets6"), prepared.unscoped))
        return false;
    if (prepared.scoped != null &&
        !nft_apply_family_chunks(table, ip_port_set, default_arg(ip_port6_set, "prokop_ip6_ports"), prepared.scoped))
        return false;
    if (prepared.unscoped == null && prepared.scoped == null)
        run_args([ "logger", "-t", "prokop", "[warn] " + as_string(label) + " has no ip_cidr entries for nftables" ]);
    return true;
}

function nft_add_json_ruleset_subnets_for_section(section, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set) {
    let ports = section_rule_ports_csv(section);
    let sets = section_priority_sets(section);

    if (!section_needs_priority_sets(section))
        return true;

    // A bypass section takes only the addresses nft may decide without
    // sing-box (UC-101); a capture section every address it may route.
    let bypass = section_priority_action(section) == "bypass";
    let key = nft_subnet_cache_key(json_path, ports, chunk_size_text, bypass);
    let prepared = key != null ? nft_subnet_cache_read(key) : null;
    if (prepared == null) {
        // An extraction lost on a full tmpfs is not a rule set without
        // subnets (UC-223).
        if (!routing_rulesets.extract_ip_cidr_nft_elements(
            json_path,
            unscoped_path,
            scoped_path,
            sprintf("%J", rule_port_values(ports)),
            sprintf("%J", rule_port_ranges(ports)),
            bypass
        )) {
            run_args([ "logger", "-t", "prokop", "[error] Could not extract the subnets of " + as_string(label) + " for nftables" ]);
            return false;
        }
        prepared = {
            unscoped: file_nonempty(unscoped_path) ? nft_prepare_family_chunks(nft_trimmed_lines(unscoped_path), "ips", "", chunk_size_text) : null,
            scoped: file_nonempty(scoped_path) ? nft_prepare_family_chunks(nft_trimmed_lines(scoped_path), "ip-ports", "", chunk_size_text) : null
        };
        if (key != null)
            nft_subnet_cache_write(key, prepared);
    }

    return nft_apply_prepared_ruleset_subnets(prepared, label, table, sets.subnets, sets.ip_ports, sets.subnets6, sets.ip6_ports);
}

function nft_community_subnet_lines(path, service, keep_shared_cloudflare) {
    let discord = as_string(service) == "discord";
    let result = [];
    // Tokenise exactly like the ordinary subnet path, so splitting the list
    // cannot change how any individual value is parsed.
    for (let value in nft_trimmed_lines(path)) {
        // Only the Discord list is split. Every other service keeps its ranges
        // intact, including the dedicated Cloudflare list itself.
        let shared = discord && core_ip.is_cloudflare_shared_cidr(value);
        if (shared == keep_shared_cloudflare)
            push(result, value);
    }
    return result;
}

function nft_add_values_to_family_sets(values, table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text) {
    return nft_add_values_to_family_sets_once(values, table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text);
}

function nft_add_community_subnet_file_for_section(section, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set) {
    if (as_string(service) != "discord")
        return nft_add_subnet_file_for_section(section, filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set);

    let sets = section_priority_sets(section);
    if (!section_needs_priority_sets(section))
        return true;

    // Discord's list mixes its own networks with shared Cloudflare Anycast
    // ranges that also serve unrelated sites and P2P. Route the shared ranges
    // for Discord's media ports only; dedicated Discord networks keep the
    // ordinary treatment, including any section port filter.
    let shared = nft_community_subnet_lines(filepath, service, true);
    let dedicated = nft_community_subnet_lines(filepath, service, false);
    let ports = section_rule_ports_csv(section);

    let ok = true;
    if (length(shared) > 0 &&
        !nft_add_values_to_port_subnets(shared, table, sets.udp_port_subnets, sets.udp_port_subnets6, chunk_size_text))
        ok = false;

    if (length(dedicated) > 0) {
        if (ports != "") {
            if (!nft_add_values_to_port_subnets(dedicated, table, sets.port_subnets, sets.port_subnets6, chunk_size_text))
                ok = false;
        }
        else if (!nft_add_values_to_family_sets(dedicated, table, sets.subnets, sets.subnets6,
            "ips", "", chunk_size_text))
            ok = false;
    }

    return ok;
}

function nft_add_subnet_file_for_uci_section(section_name, filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_subnet_file_for_section(uci_section(section_name), filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_json_ruleset_subnets_for_uci_section(section_name, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_json_ruleset_subnets_for_section(uci_section(section_name), json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_community_subnet_file_for_uci_section(section_name, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set) {
    return nft_add_community_subnet_file_for_section(uci_section(section_name), service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set);
}

function nft_add_subnet_file_for_fixture_section(fixture_path, section_name, filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_subnet_file_for_section(fixture_section(fixture_path, section_name), filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_json_ruleset_subnets_for_fixture_section(fixture_path, section_name, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_json_ruleset_subnets_for_section(fixture_section(fixture_path, section_name), json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_community_subnet_file_for_fixture_section(fixture_path, section_name, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set) {
    return nft_add_community_subnet_file_for_section(fixture_section(fixture_path, section_name), service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set);
}

function nft_populate_runtime_sets_from_sections(sections, populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set) {
    if (!arg_bool(populate_enabled))
        return true;

    // sing-box rejects a deferred section that the kill-switch protects
    // (singbox/generator.uc), so its traffic keeps reaching sing-box
    // instead of leaving directly (UC-192).
    let deferred_sections = word_set(deferred_section_names);
    for (let section in sections)
        if (killswitch_section_enabled(section))
            delete deferred_sections[as_string(object_or_empty(section)[".name"])];

    if (!nft_add_source_aware_dns_sources(sections, deferred_sections, table))
        return false;

    for (let section in sections)
        if (!nft_populate_runtime_set_for_section(section, deferred_sections, table, common_set, port_set, ip_port_set, common6_set, ip_port6_set))
            return false;

    return true;
}

function nft_populate_runtime_sets_from_uci(populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set) {
    if (!arg_bool(populate_enabled))
        return true;

    return nft_populate_runtime_sets_from_sections(uci_sections("section"), populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set);
}

function nft_populate_runtime_sets_fixture(path, populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set) {
    let data = object_or_empty(common_read_json_file(path));
    connections.set_item_sections_from_data(data);
    return nft_populate_runtime_sets_from_sections(fixture_section_list(data, "section"), populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set);
}

function nft_killswitch_render_from_uci(live_table, ks_table, out_path, fakeip_range, fakeip6_range) {
    let result = nft_killswitch_render_sections(uci_sections("section"), uci_settings(), live_table, ks_table, out_path, fakeip_range, fakeip6_range);
    print(sprintf("%J", result), "\n");
    return result.ok;
}

function nft_killswitch_render_fixture(path, live_table, ks_table, out_path, fakeip_range, fakeip6_range) {
    let data = object_or_empty(common_read_json_file(path));
    connections.set_item_sections_from_data(data);
    let result = nft_killswitch_render_sections(fixture_section_list(data, "section"), fixture_settings(data), live_table, ks_table, out_path, fakeip_range, fakeip6_range);
    print(sprintf("%J", result), "\n");
    return result.ok;
}

let mode = ARGV[0] || "";

if (mode == "text-list-to-csv")
    text_list_to_csv(ARGV[1], ARGV[2]);
else if (mode == "csv-to-json-array")
    csv_to_json_array(ARGV[1]);
else if (mode == "cache-path")
    cache_path(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
else if (mode == "list-value-to-csv")
    list_value_csv(ARGV[1]);
else if (mode == "csv-list-contains")
    exit(csv_list_contains(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "domain-subnet-text-csv")
    domain_subnet_text_csv(ARGV[1], ARGV[2]);
else if (mode == "combined-domain-text-csv")
    combined_domain_text_csv(ARGV[1], ARGV[2]);
else if (mode == "combined-domain-csv")
    combined_domain_csv(ARGV[1], ARGV[2]);
else if (mode == "rule-condition-csv")
    rule_condition_csv(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]);
else if (mode == "legacy-condition-csv")
    legacy_condition_csv(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "domain-subnet-file-csv")
    domain_subnet_file_csv(ARGV[1], ARGV[2]);
else if (mode == "split-domain-subnet-file")
    split_domain_subnet_file(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "normalize-port-condition-for-nft")
    normalize_port_condition_for_nft(ARGV[1]);
else if (mode == "rule-ports-csv")
    rule_ports_csv(ARGV[1], ARGV[2]);
else if (mode == "csv-to-lines-file")
    csv_to_lines_file(ARGV[1], ARGV[2]);
else if (mode == "nft-create-runtime-base")
    exit(nft_create_runtime_base(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15], ARGV[16], ARGV[17]) ? 0 : 1);
else if (mode == "nft-create-runtime-base-from-uci")
    exit(nft_create_runtime_base_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15]) ? 0 : 1);
else if (mode == "nft-create-runtime-output-rules")
    exit(nft_create_runtime_output_rules(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11]) ? 0 : 1);
else if (mode == "nft-create-provider-output-rules-from-uci")
    exit(nft_create_provider_output_rules_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]) ? 0 : 1);
else if (mode == "nft-create-provider-output-rules-fixture")
    exit(nft_create_provider_output_rules_from_sections(fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "section"), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]) ? 0 : 1);
else if (mode == "nft-add-section-priority-rules-fixture")
    exit(nft_add_section_priority_rules_from_sections(fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "section"), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]) ? 0 : 1);
else if (mode == "nft-create-full-runtime-from-uci")
    exit(nft_create_full_runtime_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15], ARGV[16], ARGV[17], ARGV[18], ARGV[19], ARGV[20], ARGV[21], ARGV[22], ARGV[23], ARGV[24], ARGV[25], ARGV[26]) ? 0 : 1);
else if (mode == "nft-rebuild-runtime-from-uci")
    exit(nft_rebuild_runtime_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15], ARGV[16], ARGV[17], ARGV[18], ARGV[19], ARGV[20], ARGV[21], ARGV[22], ARGV[23], ARGV[24], ARGV[25], ARGV[26]) ? 0 : 1);
else if (mode == "nft-apply-candidate-batch")
    exit(nft_apply_candidate_batch(ARGV[1]) ? 0 : 1);
else if (mode == "nft-prepare-chunks")
    nft_prepare_chunks(ARGV[1], ARGV[2], ARGV[3] || "", ARGV[4], ARGV[5], ARGV[6]);
else if (mode == "nft-add-file-chunks-to-set")
    exit(nft_add_file_chunks_to_set(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5] || "", ARGV[6]) ? 0 : 1);
else if (mode == "nft-add-subnet-file-for-uci-section")
    exit(nft_add_subnet_file_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]) ? 0 : 1);
else if (mode == "nft-add-json-ruleset-subnets-for-uci-section")
    exit(nft_add_json_ruleset_subnets_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11]) ? 0 : 1);
else if (mode == "nft-add-community-subnet-file-for-uci-section")
    exit(nft_add_community_subnet_file_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13]) ? 0 : 1);
else if (mode == "nft-add-subnet-file-for-section-fixture")
    exit(nft_add_subnet_file_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9]) ? 0 : 1);
else if (mode == "nft-add-json-ruleset-subnets-for-section-fixture")
    exit(nft_add_json_ruleset_subnets_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12]) ? 0 : 1);
else if (mode == "nft-add-community-subnet-file-for-section-fixture")
    exit(nft_add_community_subnet_file_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14]) ? 0 : 1);
else if (mode == "nft-populate-runtime-sets-from-uci")
    exit(nft_populate_runtime_sets_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12]) ? 0 : 1);
else if (mode == "nft-populate-runtime-sets-fixture")
    exit(nft_populate_runtime_sets_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13]) ? 0 : 1);
else if (mode == "nft-runtime-signature")
    exit(nft_runtime_signature_from_uci() ? 0 : 1);
else if (mode == "nft-runtime-signature-fixture")
    exit(nft_runtime_signature_from_fixture(ARGV[1]) ? 0 : 1);
else if (mode == "nft-table-present-fixture")
    exit(nft_table_present(ARGV[1]) ? 0 : 1);
else if (mode == "ensure-tproxy-route-rule")
    exit(ensure_tproxy_route_rule(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "remove-tproxy-route-rule")
    exit(remove_tproxy_route_rule(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "tproxy-route-present")
    exit(tproxy_route_present(ARGV[1]) ? 0 : 1);
else if (mode == "tproxy-route4-present")
    exit(tproxy_route4_present(ARGV[1]) ? 0 : 1);
else if (mode == "tproxy-route6-present")
    exit(tproxy_route6_present(ARGV[1]) ? 0 : 1);
else if (mode == "tproxy-marking-rule-present")
    exit(tproxy_marking_rule_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "tproxy-marking-rule4-present")
    exit(tproxy_marking_rule4_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "tproxy-marking-rule6-present")
    exit(tproxy_marking_rule6_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "tproxy-route-rule-present")
    exit(tproxy_route_rule_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "nft-validate-candidate-batch")
    exit(nft_validate_candidate_batch(ARGV[1]) ? 0 : 1);
else if (mode == "nft-commit-candidate-batch")
    exit(nft_commit_candidate_batch(ARGV[1]) ? 0 : 1);
else if (mode == "install-transition-guard")
    exit(nft_install_transition_guard(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "remove-transition-guard")
    exit(nft_remove_transition_guard(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "install-dpi-transition-guard")
    exit(nft_dpi_transition_guard(ARGV[1], false) ? 0 : 1);
else if (mode == "remove-dpi-transition-guard")
    exit(nft_dpi_transition_guard(ARGV[1], true) ? 0 : 1);
else if (mode == "ensure-dpi-transition-guard")
    exit(nft_dpi_transition_guard_ensure(ARGV[1]) ? 0 : 1);
else if (mode == "dpi-transition-guard-state") {
    print(nft_dpi_transition_guard_state(ARGV[1]), "\n");
    exit(0);
}
else if (mode == "killswitch-render")
    exit(nft_killswitch_render_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]) ? 0 : 1);
else if (mode == "killswitch-render-fixture")
    exit(nft_killswitch_render_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]) ? 0 : 1);
else if (mode == "ensure-bridge-netfilter-disabled")
    exit(ensure_bridge_netfilter_disabled() ? 0 : 1);
else if (mode == "restore-bridge-netfilter")
    exit(restore_bridge_netfilter() ? 0 : 1);
else {
    warn("Usage: nft/apply.uc <operation> ...\n");
    exit(1);
}
