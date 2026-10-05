#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let runtime_constants = require("singbox.constants");
let runtime_country = require("singbox.country");
let runtime_dns = require("singbox.dns");
let runtime_route = require("singbox.route");
let runtime_rulesets = require("singbox.rulesets");
let runtime_subscription = require("singbox.subscription");
let runtime_url = require("core.url");
let ipv6 = require("core.ipv6");
let runtime_urltest = require("singbox.urltest");
let source_rulesets = require("routing.rulesets");
let rule_config = require("config.rule");
let rule_conditions = require("routing.rule_conditions");
let connections = require("config.connections");
let urltest_override = require("config.urltest_override");
let subscription_share_link = require("subscription.share_link");
let legacy_forkop = require("core.legacy_forkop");
let core_ip = require("core.ip");
let uci = null;
let fixture_uci_data = null;
let runtime_settings_cache = null;
let runtime_ruleset_folder = runtime_constants.TMP_RULESET_FOLDER;
let runtime_supports_xhttp = true;
// X.Y.Z of sing-box-extended from "1.14.1-extended-2.7.2"; null when the
// version is not known.
let runtime_extended_version = null;
// C15: the payload probes of the priority groups that check payload: a
// selector with the group's nodes, reached through a mixed inbound on the
// loopback address, which the priority worker points at the node under
// test. Live traffic never goes through it.
const PRIORITY_PROBE_PORT_FIRST = 4580;
const PRIORITY_PROBE_MAX = 16;
let priority_probes = [];
let runtime_supports_dns_response_matching = false;
let provider_urltest_start_seed = "";

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let read_stdin = common.read_stdin;
let read_stdin_json = common.read_stdin_json;
let write_json = common.write_json;
let csv_to_json_array = common.csv_to_json_array;
let write_json_file = common.write_json_file;
let strip_internal_fields = common.strip_internal_fields;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let url_scheme = runtime_url.scheme;
let url_fragment = runtime_url.fragment;
let url_host = runtime_url.host;

const CONFIG_NAME = "prokop";

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash <= 0 ? "" : substr(path, 0, slash);
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "" || path == "/")
        return true;
    if (fs.stat(path) != null)
        return true;

    let parent = parent_dir(path);
    if (parent != "" && !ensure_dir(parent))
        return false;

    return fs.mkdir(path, 0755) || fs.stat(path) != null;
}

function ensure_parent_dir(path) {
    return ensure_dir(parent_dir(path));
}

// One seed per boot, kept on tmpfs: every provider group on this router
// rotates together, and a reload that changes nothing else produces the same
// config, so sing-box is not restarted for nothing. A reboot picks a new one.
// The environment override exists so tests can pin it.
let urltest_seed_file = getenv("PROKOP_URLTEST_SEED_FILE") ||
    (getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop") + "/urltest-seed";

function valid_urltest_seed(seed) {
    return match(seed, /^[A-Za-z0-9-]{8,64}$/) != null;
}

function urltest_start_seed() {
    if (provider_urltest_start_seed != "")
        return provider_urltest_start_seed;

    let seed = trim(as_string(getenv("PROKOP_URLTEST_START_SEED") || ""));
    if (seed == "") {
        seed = urltest_seed_file != "" ? trim(as_string(fs.readfile(urltest_seed_file) || "")) : "";
        if (!valid_urltest_seed(seed)) {
            seed = trim(as_string(fs.readfile("/proc/sys/kernel/random/uuid") || ""));
            let tmp_path = urltest_seed_file + ".tmp";
            // A seed that cannot be saved still works for this generation.
            if (urltest_seed_file != "" && valid_urltest_seed(seed) && ensure_parent_dir(urltest_seed_file) &&
                fs.writefile(tmp_path, seed + "\n") != null && !fs.rename(tmp_path, urltest_seed_file))
                fs.unlink(tmp_path);
        }
    }
    provider_urltest_start_seed = seed;
    return provider_urltest_start_seed;
}

function atomic_write_json_file(path, value) {
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!ensure_parent_dir(path))
        return false;
    // A write that failed half-way leaves no partial copy (UC-159). A full
    // filesystem can take the write and keep none of it: read back first.
    let data = sprintf("%J\n", value);
    if (fs.writefile(tmp_path, data) == null || !fs.chmod(tmp_path, 0600) ||
        fs.readfile(tmp_path) !== data || !fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }
    return true;
}

function fixture_section_list(type_name) {
    let value = object_or_empty(fixture_uci_data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(fixture_uci_data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function fixture_get_section(section_name) {
    let fixture = object_or_empty(fixture_uci_data);
    if (section_name == "settings" && type(fixture.settings) == "object")
        return fixture.settings;

    for (let type_name in [ "settings", "server", "section", "subscription_url", "section_interface", "urltest", "priority_group", "priority_level" ]) {
        for (let section in fixture_section_list(type_name)) {
            if (as_string(section[".name"]) == section_name)
                return section;
        }
    }

    return {};
}

function fixture_cursor(path) {
    fixture_uci_data = object_or_empty(read_json_file(path));
    connections.set_item_sections_from_data(fixture_uci_data);
    return {
        load: function(_config_name) {
            return true;
        },
        get_all: function(_config_name, section_name) {
            return fixture_get_section(section_name);
        },
        foreach: function(_config_name, type_name, callback) {
            for (let section in fixture_section_list(type_name))
                callback(section);
        }
    };
}

function use_fixture_cursor(path) {
    uci = fixture_cursor(path);
    runtime_settings_cache = null;
}

function runtime_uci_cursor() {
    return {
        load: function(package_name) {
            return uci_core.load(package_name);
        },
        get_all: function(package_name, section_name) {
            return uci_core.get_all(package_name, section_name);
        },
        foreach: function(package_name, type_name, callback) {
            for (let section in uci_core.section_objects(package_name, type_name))
                callback(section);
        }
    };
}

function uci_cursor() {
    if (uci == null)
        uci = runtime_uci_cursor();
    return uci;
}

function runtime_generate_unsupported(reason) {
    warn(reason, "\n");
    exit(2);
}

function valid_section_name(name) {
    return match(name, /^[A-Za-z0-9_]+$/);
}

function section_enabled(section) {
    return common.section_enabled(section);
}

function runtime_settings() {
    if (runtime_settings_cache == null)
        runtime_settings_cache = object_or_empty(uci_cursor().get_all(CONFIG_NAME, "settings"));
    return runtime_settings_cache;
}

function settings_update_interval() {
    let settings = runtime_settings();
    if (!bool_option(settings, "list_update_enabled", true))
        return "";

    let update_interval = option(settings, "update_interval", "1d");
    return update_interval != "" ? update_interval : "1d";
}

// sing-box refetches remote rule sets at most once an hour, like the list
// update (D-18 (a)).
function remote_ruleset_update_interval() {
    let update_interval = settings_update_interval();
    return update_interval != "" ? common.automatic_update_interval(update_interval) : runtime_constants.DISABLED_UPDATE_INTERVAL;
}

function internal_flag(value) {
    return value === true || value == 1 || value == "1" || value == "true" || value == "yes";
}

function subscription_group_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    return (t == "selector" || t == "urltest") && internal_flag(outbound.__prokop_allow_group);
}

function subscription_urltest_group_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    return as_string(outbound.type || "") == "urltest" && internal_flag(outbound.__prokop_allow_group);
}

function flintnet_subscription_source(source_entry) {
    return lc(url_host(as_string(source_entry))) == "sub.flintnet.pro";
}

function subscription_outbound_tag(outbound) {
    return type(outbound) == "object" ? as_string(outbound.tag || "") : "";
}

function subscription_urltest_group_member(outbound, refs) {
    let tag_name = subscription_outbound_tag(outbound);
    return tag_name != "" && object_or_empty(object_or_empty(refs).urltest)[tag_name] === true;
}

function subscription_visibility_refs(outbounds) {
    let refs = {
        urltest: {},
        detour: {}
    };

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        if (as_string(outbound.type) == "urltest") {
            for (let tag_name in array_or_empty(outbound.outbounds)) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    refs.urltest[tag_name] = true;
            }
        }

        let detour = as_string(outbound.detour || "");
        if (detour != "")
            refs.detour[detour] = true;
    }

    return refs;
}

function subscription_hidden_outbound(outbound, refs, hide_urltest_group_outbounds, hide_detour_outbounds) {
    if (type(outbound) != "object")
        return false;

    let tag_name = subscription_outbound_tag(outbound);
    let urltest_refs = object_or_empty(object_or_empty(refs).urltest);
    let detour_refs = object_or_empty(object_or_empty(refs).detour);
    let hidden_by_urltest = tag_name != "" && urltest_refs[tag_name];
    let hidden_by_detour = tag_name != "" && detour_refs[tag_name];

    if (hidden_by_urltest && hide_urltest_group_outbounds !== false)
        return true;
    if (hidden_by_detour && hide_detour_outbounds !== false)
        return true;
    return internal_flag(outbound.__prokop_hidden) && !hidden_by_urltest && !hidden_by_detour;
}

function tag(base, postfix) {
    return runtime_constants.tag(base, postfix);
}

function outbound_tag(section_name) {
    return runtime_constants.outbound_tag(section_name);
}

function download_via_proxy_section_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy_section";
    if (purpose == "components")
        return "download_components_via_proxy_section";
    return "";
}

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "components")
        return "download_components_via_proxy";
    return "";
}

function download_via_proxy_section(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    if (enabled_option == "" || !bool_option(settings, enabled_option, false))
        return "";

    let section_option = download_via_proxy_section_option_for_purpose(purpose);
    let configured = section_option != "" ? option(settings, section_option, "") : "";
    if (configured != "")
        return configured;

    return option(settings, "download_lists_via_proxy_section", "");
}

function download_via_proxy_enabled(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    return enabled_option != "" && bool_option(settings, enabled_option, false);
}

function download_via_proxy_any_enabled(settings, sections) {
    return download_via_proxy_enabled(settings, "lists") ||
        download_via_proxy_enabled(settings, "components") ||
        length(connections.subscription_download_targets(sections || [])) > 0;
}

function download_detour_tag(settings, purpose) {
    let section_name = download_via_proxy_section(settings, purpose);
    return section_name == "" ? "" : outbound_tag(section_name);
}

function ruleset_tag(section_name, name, kind) {
    kind = as_string(kind);
    return kind == ""
        ? section_name + "-" + name + "-ruleset"
        : section_name + "-" + name + "-" + kind + "-ruleset";
}

function ruleset_registered(config, tag_name) {
    for (let rule_set in array_or_empty(config.route && config.route.rule_set)) {
        if (type(rule_set) == "object" && rule_set.tag == tag_name)
            return true;
    }
    return false;
}

function ensure_custom_ruleset(config, reference) {
    let tag_name;
    let kind = runtime_rulesets.kind_from_reference_hint(reference);

    if (runtime_rulesets.is_community(reference)) {
        tag_name = "builtin-" + reference + "-ruleset";
        kind = runtime_rulesets.community_kind(reference);
        if (!ruleset_registered(config, tag_name)) {
            let rule_set = {
                type: "remote",
                tag: tag_name,
                format: "binary",
                url: runtime_rulesets.community_url(reference)
            };
            let detour = download_detour_tag(runtime_settings());
            if (detour != "")
                rule_set.download_detour = detour;
            rule_set.update_interval = remote_ruleset_update_interval();
            push(config.route.rule_set, rule_set);
        }
        return { tag: tag_name, kind };
    }

    tag_name = "inline-custom-" + runtime_rulesets.hash12(reference) + "-ruleset";
    if (kind == "unknown")
        kind = "domains";
    if (ruleset_registered(config, tag_name))
        return { tag: tag_name, kind };

    let extension = runtime_rulesets.file_extension(reference);
    if (substr(reference, 0, 1) == "/") {
        if (extension != "srs" && extension != "json")
            runtime_generate_unsupported("local rule_set extension is not supported by sing-box config generation");
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: extension == "json" ? "source" : "binary",
            path: reference
        });
    }
    else if (substr(reference, 0, 7) == "http://" || substr(reference, 0, 8) == "https://") {
        let rule_set = {
            type: "remote",
            tag: tag_name,
            format: runtime_rulesets.remote_format(reference),
            url: reference
        };
        let detour = download_detour_tag(runtime_settings());
        if (detour != "")
            rule_set.download_detour = detour;
        rule_set.update_interval = remote_ruleset_update_interval();
        push(config.route.rule_set, rule_set);
    }
    else {
        runtime_generate_unsupported("rule_set reference is not supported by sing-box config generation");
    }

    return { tag: tag_name, kind };
}

function clash_api_config(settings, service_address) {
    let controller = as_string(service_address || "");
    if (bool_option(settings, "enable_yacd", false) && bool_option(settings, "enable_yacd_wan_access", false))
        controller = "0.0.0.0";
    else if (controller == "")
        controller = "127.0.0.1";

    let result = {
        external_controller: controller + ":9090"
    };
    if (bool_option(settings, "enable_yacd", false))
        result.external_ui = "ui";
    // The secret protects the controller wherever it listens (UC-035): the
    // backend sends it under the same predicate.
    let secret = common.clash_api_secret(settings);
    if (secret != "")
        result.secret = secret;
    return result;
}

function cli_bool(value) {
    return value === true || value == "1" || value == "true" || value == "yes" || value == "on";
}

function tproxy_inbound_matcher() {
    return [ runtime_constants.TPROXY_INBOUND_TAG, runtime_constants.TPROXY_INBOUND6_TAG ];
}

function source_dns_inbound_matcher() {
    return [ runtime_constants.SOURCE_DNS_INBOUND_TAG ];
}

function base_config(settings, service_address, runtime_context) {
    let log_level = option(settings, "log_level", "warn");
    let rewrite_ttl = int_option(settings, "dns_rewrite_ttl", "60");
    let cache_path = option(settings, "cache_path", "/tmp/sing-box/cache.db");
    let dns_config = runtime_dns.config(settings);
    if (dns_config.unsupported)
        runtime_generate_unsupported(dns_config.unsupported);

    let dns_rules = [];
    for (let rule in dns_config.rules)
        push(dns_rules, rule);
    for (let rule in [
        { action: "reject", query_type: "HTTPS" },
        { action: "reject", domain_suffix: "use-application-dns.net" },
        {
            action: "route",
            server: runtime_constants.FAKEIP_DNS_SERVER_TAG,
            rewrite_ttl,
            domain: [ runtime_constants.FAKEIP_TEST_DOMAIN, runtime_constants.CHECK_PROXY_IP_DOMAIN ]
        }
    ])
        push(dns_rules, rule);

    let dns_servers = [];
    for (let server in dns_config.servers)
        push(dns_servers, server);
    push(dns_servers, {
        type: "fakeip",
        tag: runtime_constants.FAKEIP_DNS_SERVER_TAG,
        inet4_range: runtime_constants.FAKEIP_INET4_RANGE,
        inet6_range: runtime_constants.FAKEIP_INET6_RANGE
    });

    runtime_context = object_or_empty(runtime_context);
    // B9, opt-in: on a router with little memory and an unstable upstream,
    // half-open client connections and idle UDP sessions piled up in sing-box
    // (one report: 1300+ of them, 120 MB RSS on a 256 MB router). Keep-alive finds
    // the dead ones, UDP sessions end after a minute instead of five. Every
    // sing-box from 1.12.0 (SB_REQUIRED_VERSION) knows these listen fields.
    let low_memory = option(settings, "tproxy_low_memory", "0") == "1";
    function tproxy_inbound(tag, listen) {
        let inbound = { type: "tproxy", tag, listen, listen_port: runtime_constants.TPROXY_INBOUND_PORT, tcp_fast_open: !low_memory, udp_fragment: true };
        if (low_memory) {
            inbound.tcp_keep_alive = "30s";
            inbound.tcp_keep_alive_interval = "15s";
            inbound.udp_timeout = "60s";
        }
        return inbound;
    }
    // Without IPv6 on the router there is no ::1 to listen on, and no IPv6
    // traffic to take (core/ipv6.uc, A1).
    let inbounds = [ tproxy_inbound(runtime_constants.TPROXY_INBOUND_TAG, runtime_constants.TPROXY_INBOUND_ADDRESS) ];
    if (ipv6.available())
        push(inbounds, tproxy_inbound(runtime_constants.TPROXY_INBOUND6_TAG, runtime_constants.TPROXY_INBOUND6_ADDRESS));
    push(inbounds, { type: "direct", tag: runtime_constants.DNS_INBOUND_TAG, listen: runtime_constants.DNS_INBOUND_ADDRESS, listen_port: runtime_constants.DNS_INBOUND_PORT });
    if (runtime_context.source_aware_dns)
        push(inbounds, { type: "direct", tag: runtime_constants.SOURCE_DNS_INBOUND_TAG, listen: runtime_constants.SOURCE_DNS_INBOUND_ADDRESS, listen_port: runtime_constants.SOURCE_DNS_INBOUND_PORT });
    for (let inbound in dns_config.inbounds)
        push(inbounds, inbound);

    runtime_context.dns_health_inbounds = dns_config.sniff_inbounds;
    runtime_context.default_domain_resolver = runtime_dns.default_domain_resolver(settings);

    return {
        log: {
            disabled: false,
            level: log_level,
            timestamp: false
        },
        dns: {
            servers: dns_servers,
            rules: dns_rules,
            final: runtime_constants.DNS_SERVER_TAG,
            strategy: option(settings, "dns_strategy", "prefer_ipv4"),
            independent_cache: true,
            // C9: EDNS Client Subnet, so geo-CDNs answer with a node near
            // the user when DNS leaves through a proxy or a public resolver.
            // Off unless set (config/validator.uc checks the value).
            ...(trim(option(settings, "dns_client_subnet", "")) != "" ?
                { client_subnet: trim(option(settings, "dns_client_subnet", "")) } : {})
        },
        ntp: {},
        certificate: {},
        endpoints: [],
        inbounds,
        outbounds: [
            { type: "direct", tag: runtime_constants.DIRECT_OUTBOUND_TAG },
            { type: "direct", tag: runtime_constants.BYPASS_OUTBOUND_TAG }
        ],
        route: runtime_route.config(settings, runtime_context),
        services: [],
        experimental: {
            cache_file: {
                enabled: true,
                path: cache_path,
                store_fakeip: true
            },
            clash_api: clash_api_config(settings, service_address)
        }
    };
}

function supported_subscription_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    if (subscription_group_outbound(outbound))
        return true;
    if (t == "direct" || t == "selector" || t == "urltest" || t == "dns" || t == "block")
        return false;
    return t == "vless" || t == "vmess" || t == "trojan" || t == "shadowsocks" ||
        t == "socks" || t == "hysteria2";
}

function outbound_uses_xhttp(outbound) {
    return type(outbound) == "object" && type(outbound.transport) == "object" &&
        lc(as_string(outbound.transport.type || "")) == "xhttp";
}

function outbound_uses_vless_encryption(outbound) {
    if (type(outbound) != "object" || lc(as_string(outbound.type || "")) != "vless")
        return false;
    let encryption = as_string(outbound.encryption || "");
    return encryption != "" && encryption != "none";
}

// sing-box-extended is at least major.minor.patch. An extended core of
// unknown version (unknown_ok) passes.
function extended_at_least(major, minor, patch, unknown_ok) {
    if (!runtime_supports_xhttp)
        return false;
    let v = runtime_extended_version;
    if (v == null)
        return unknown_ok;
    if (v[0] != major)
        return v[0] > major;
    if (v[1] != minor)
        return v[1] > minor;
    return v[2] >= patch;
}

// C3: VLESS Encryption (ML-KEM) came with sing-box-extended 2.0.0; on an
// older core it is an unknown field that fails the whole configuration.
const VLESS_ENCRYPTION_MIN_EXTENDED = [ 2, 0, 0 ];
// tls.reality.support_x25519mlkem768 came with sing-box-extended 2.7.2.
const REALITY_MLKEM_MIN_EXTENDED = [ 2, 7, 2 ];

// SB-10: the xHTTP settings beyond the base set (subscription/parser.uc
// XHTTP_EXTENDED_SETTINGS), by the sing-box-extended release whose
// option/v2ray_transport.go first reads them: [ release, an extended core
// of unknown version reads them, keys ]. sing-box decodes its options with
// unknown fields refused, so one key an older core does not know fails the
// whole configuration. The xHTTP transport itself came with 1.1.0.
const XHTTP_EXTENDED_FIELDS = [
    [ [ 1, 1, 0 ], true, [ "sc_max_buffered_posts", "no_sse_header" ] ],
    [ [ 1, 6, 0 ], false, [
        "uplink_http_method", "session_placement", "session_key", "seq_placement", "seq_key",
        "uplink_data_placement", "uplink_data_key", "uplink_chunk_size", "x_padding_obfs_mode",
        "x_padding_key", "x_padding_header", "x_padding_placement", "x_padding_method"
    ] ],
    [ [ 2, 5, 0 ], false, [ "session_id_table", "session_id_length" ] ]
];

// Range settings: a core before sing-box-extended 1.6.0 reads a range as
// "from-to" or {from, to} and refuses a plain number, which the parser
// writes for a fixed value; "N-N" means the same to every core.
const XHTTP_RANGE_FIELDS = [ "x_padding_bytes", "sc_max_each_post_bytes", "sc_min_posts_interval_ms",
    "sc_stream_up_server_secs" ];
const XMUX_RANGE_FIELDS = [ "max_concurrency", "max_connections", "c_max_reuse_times", "h_max_request_times",
    "h_max_reusable_secs" ];

function xhttp_ranges_as_text(options, keys) {
    if (type(options) != "object")
        return;
    for (let key in keys) {
        let value = options[key];
        if (type(value) == "int" || (type(value) == "double" && value == int(value)))
            options[key] = sprintf("%d-%d", value, value);
    }
}

function drop_unknown_xhttp_fields(options, dropped) {
    if (type(options) != "object")
        return;
    if (!extended_at_least(1, 6, 0, false)) {
        xhttp_ranges_as_text(options, XHTTP_RANGE_FIELDS);
        xhttp_ranges_as_text(options.xmux, XMUX_RANGE_FIELDS);
    }
    for (let group in XHTTP_EXTENDED_FIELDS) {
        let v = group[0];
        if (extended_at_least(v[0], v[1], v[2], group[1]))
            continue;
        for (let key in group[2]) {
            if (exists(options, key)) {
                delete options[key];
                push(dropped, key);
            }
        }
    }
}

// The settings this core does not read are left out of every xHTTP
// outbound, also its download options, with a warning: the node may then
// not reach its server, but the configuration stays valid. Its ranges are
// written the way this core reads them.
function drop_unsupported_xhttp_settings(config) {
    for (let outbound in array_or_empty(config.outbounds)) {
        if (!outbound_uses_xhttp(outbound))
            continue;
        let dropped = [];
        drop_unknown_xhttp_fields(outbound.transport, dropped);
        drop_unknown_xhttp_fields(outbound.transport.download, dropped);
        if (length(dropped) > 0)
            warn("xHTTP settings of outbound '", as_string(outbound.tag), "' need a newer sing-box-extended and were left out: ",
                join(", ", uniq(dropped)), "\n");
    }
}

function vless_encryption_supported() {
    let v = VLESS_ENCRYPTION_MIN_EXTENDED;
    return extended_at_least(v[0], v[1], v[2], true);
}

// The bytes a base64 (raw URL alphabet, no padding) segment decodes to, or
// null when it is not one, as Go's base64.RawURLEncoding reads it.
function raw_url_base64_length(value) {
    if (match(value, /^[A-Za-z0-9_-]*$/) == null)
        return null;
    let rest = length(value) % 4;
    if (rest == 1)
        return null;
    return int(length(value) / 4) * 3 + (rest == 2 ? 1 : rest == 3 ? 2 : 0);
}

// Why sing-box-extended refuses a VLESS encryption value, as its
// parseClientEncryption does: "mlkem768x25519plus.<mode>.<rtt>", padding
// segments, then keys of 32 (X25519) or 1184 (ML-KEM-768) bytes. "" for a
// value it takes. A truncated key fails here instead of the whole
// configuration in "sing-box check".
function vless_encryption_error(value) {
    let parts = split(trim(as_string(value)), ".");
    if (length(parts) < 4)
        return "missing components";
    if (parts[0] != "mlkem768x25519plus")
        return "unsupported prefix";
    if (index([ "native", "xorpub", "random" ], parts[1]) < 0)
        return "unknown mode";
    if (index([ "0rtt", "1rtt" ], parts[2]) < 0)
        return "unsupported RTT value";
    let keys = 0;
    for (let i = 3; i < length(parts); i++) {
        let segment = trim(parts[i]);
        if (segment == "")
            return "empty segment";
        let bytes = raw_url_base64_length(segment);
        if (bytes != null) {
            if (bytes != 32 && bytes != 1184)
                return "invalid key length";
            keys++;
            continue;
        }
        if (keys > 0)
            return "invalid key";
    }
    return keys > 0 ? "" : "no keys";
}

// Why this outbound's VLESS encryption cannot run on this core, or "".
function vless_encryption_unsupported(outbound) {
    if (!outbound_uses_vless_encryption(outbound))
        return "";
    if (!runtime_supports_xhttp)
        return "VLESS encryption requires sing-box-extended";
    if (!vless_encryption_supported())
        return "VLESS encryption requires sing-box-extended " + join(".", VLESS_ENCRYPTION_MIN_EXTENDED) + " or newer";
    let error = vless_encryption_error(outbound.encryption);
    return error != "" ? "invalid VLESS encryption value (" + error + ")" : "";
}

function ensure_explicit_outbound_supported(outbound, source, name) {
    if (!runtime_supports_xhttp && outbound_uses_xhttp(outbound))
        runtime_generate_unsupported(as_string(source) + " '" + as_string(name) + "' uses XHTTP transport, but sing-box-extended is not installed");
    if (!runtime_supports_xhttp && outbound_uses_vless_encryption(outbound))
        runtime_generate_unsupported(as_string(source) + " '" + as_string(name) + "' uses VLESS encryption, but sing-box-extended is not installed");
    let encryption = vless_encryption_unsupported(outbound);
    if (encryption != "")
        runtime_generate_unsupported(as_string(source) + " '" + as_string(name) + "': " + encryption);
}

function subscription_outbound_display_name(outbound) {
    return type(outbound) == "object"
        ? as_string(outbound.remark || outbound.tag || "unknown")
        : "unknown";
}

function add_subscription_reference(refs, value) {
    value = as_string(value);
    if (value != "")
        refs[value] = true;
}

function subscription_reference_set(outbounds) {
    let refs = {};
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;
        add_subscription_reference(refs, outbound.tag);
        add_subscription_reference(refs, outbound.remark);
    }
    return refs;
}

function subscription_reference_available(reference, source_refs, retained_refs) {
    reference = as_string(reference);
    return reference == "" || !source_refs[reference] || retained_refs[reference];
}

function subscription_group_has_retained_member(outbound, retained_refs) {
    for (let reference in array_or_empty(outbound.outbounds))
        if (retained_refs[as_string(reference)])
            return true;
    return false;
}

function warn_skipped_subscription_outbound(section_name, outbound, reason) {
    warn("skipped incompatible subscription outbound for rule '", section_name, "': ",
        subscription_outbound_display_name(outbound), " (", reason, ")\n");
}

function compatible_subscription_outbounds(outbounds, section_name) {
    let source_refs = subscription_reference_set(outbounds);
    let retained = [];
    for (let outbound in array_or_empty(outbounds)) {
        if (!supported_subscription_outbound(outbound))
            continue;
        if (!runtime_supports_xhttp && outbound_uses_xhttp(outbound)) {
            warn_skipped_subscription_outbound(section_name, outbound, "XHTTP requires sing-box-extended");
            continue;
        }
        let encryption = vless_encryption_unsupported(outbound);
        if (encryption != "") {
            warn_skipped_subscription_outbound(section_name, outbound, encryption);
            continue;
        }
        push(retained, outbound);
    }

    while (true) {
        let retained_refs = subscription_reference_set(retained);
        let next = [];
        let changed = false;
        for (let outbound in retained) {
            let detour = as_string(outbound.detour || "");
            if (!subscription_reference_available(detour, source_refs, retained_refs)) {
                warn_skipped_subscription_outbound(section_name, outbound,
                    "detour depends on unavailable outbound '" + detour + "'");
                changed = true;
                continue;
            }
            if (subscription_group_outbound(outbound) &&
                !subscription_group_has_retained_member(outbound, retained_refs)) {
                warn_skipped_subscription_outbound(section_name, outbound, "group has no compatible outbounds");
                changed = true;
                continue;
            }
            push(next, outbound);
        }
        retained = next;
        if (!changed)
            return retained;
    }
}

// Internal keys of a subscription cache Forkop wrote. Such a cache is
// discarded by its format (subscription/cache.uc); should one still reach the
// generator, its keys must not reach sing-box, which refuses unknown fields.
const LEGACY_SUBSCRIPTION_KEY_PREFIX = legacy_forkop.SUBSCRIPTION_KEY_PREFIX;

function copy_subscription_outbound(outbound, new_tag) {
    let copy = {};
    for (let key, value in outbound) {
        if (key != "tag" && key != "remark" && key != "share_link" &&
            key != "__prokop_hidden" && key != "__prokop_allow_group" &&
            key != "__prokop_description" && key != "__prokop_filter_names" &&
            index(key, LEGACY_SUBSCRIPTION_KEY_PREFIX) != 0)
            copy[key] = value;
    }
    if (as_string(copy.type || "") == "hysteria2" &&
        type(copy.tls) == "object" &&
        copy.tls.utls != null) {
        let tls = {};
        for (let key, value in copy.tls) {
            if (key != "utls")
                tls[key] = value;
        }
        copy.tls = tls;
    }
    copy.tag = new_tag;
    return copy;
}

function string_array_contains(values, needle) {
    for (let value in array_or_empty(values))
        if (as_string(value) == as_string(needle))
            return true;
    return false;
}

function rewrite_subscription_outbound_references(outbounds, tag_map, source_refs) {
    for (let outbound in outbounds) {
        if (type(outbound) != "object")
            continue;

        let detour = as_string(outbound.detour || "");
        if (detour != "" && tag_map[detour])
            outbound.detour = tag_map[detour];
        else if (detour != "" && source_refs[detour])
            delete outbound.detour;

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_map[tag_name])
                    push(rewritten, tag_map[tag_name]);
            }
            outbound.outbounds = rewritten;

            if (as_string(outbound.type || "") == "urltest") {
                delete outbound.default;
            }
            else {
                let default_tag = as_string(outbound.default || "");
                if (default_tag != "" && tag_map[default_tag])
                    default_tag = tag_map[default_tag];
                if (default_tag == "" || !string_array_contains(rewritten, default_tag))
                    default_tag = length(rewritten) > 0 ? rewritten[0] : "";
                if (default_tag != "")
                    outbound.default = default_tag;
                else
                    delete outbound.default;
            }
        }
    }
}

function subscription_skip_summary(skipped) {
    let parts = [];
    for (let t in sort(keys(skipped)))
        push(parts, skipped[t] + "x " + t);
    return join("; ", parts);
}

function reportable_skipped_subscription_type(t) {
    return t != "direct" && t != "selector" && t != "urltest" && t != "dns" && t != "block";
}

function urltest_leaf_candidate_outbound(outbound) {
    if (type(outbound) != "object")
        return false;

    let t = lc(as_string(outbound.type || ""));
    return t != "selector" && t != "urltest" && t != "dns" && t != "block";
}

// Where the suffix search of each base stopped last time, for one taken map
// (a generation uses one): every suffix below it was taken then and still is
// (tags are never released), so the result is the smallest free one, as
// before, without scanning the same suffixes again (5 000 equal names:
// quadratic to linear).
let unique_tag_memo = { taken: null, next: {} };

function unique_tag(base, taken) {
    base = as_string(base);
    if (base == "")
        base = "server";
    if (!taken[base])
        return base;
    if (unique_tag_memo.taken !== taken)
        unique_tag_memo = { taken, next: {} };
    for (let i = int(unique_tag_memo.next[base] || 1); i < 100000; i++) {
        let candidate = base + "-" + i;
        if (!taken[candidate]) {
            unique_tag_memo.next[base] = i + 1;
            return candidate;
        }
    }
    return base + "-overflow";
}

function reserved_runtime_tag_set(outbounds) {
    let result = {};
    for (let tag_name in keys(object_or_empty(runtime_constants.RESERVED_TAGS)))
        result[tag_name] = true;

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        let tag_name = as_string(outbound.tag || "");
        if (tag_name != "")
            result[tag_name] = true;
    }
    return result;
}

function assert_unique_outbound_tags(config) {
    let seen = {};
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            runtime_generate_unsupported("generated sing-box outbound is not an object");

        let tag_name = as_string(outbound.tag || "");
        if (tag_name == "")
            runtime_generate_unsupported("generated sing-box outbound has an empty tag");
        if (seen[tag_name])
            runtime_generate_unsupported("generated sing-box config has duplicate outbound tag '" + tag_name + "'");
        seen[tag_name] = true;
    }
}

function add_subscription_source_with_state(config, section, source_index, source_entry, taken, selector_tags, urltest_candidate_tags, state, show_metadata, include_urltest_groups, hide_urltest_group_outbounds, hide_detour_outbounds, node_prefix) {
    let section_name = section[".name"];
    let source_section = runtime_subscription.source_id(section_name, source_index);
    if (!runtime_subscription.source_cache_is_current(
        source_section,
        source_entry,
        connections.subscription_user_agent(section, source_entry),
        connections.subscription_hwid(section, source_entry)
    ))
        return 0;

    let source_outbounds = runtime_subscription.read_source_outbounds(source_section);
    if (length(source_outbounds) == 0)
        return 0;

    let skipped = {};
    for (let outbound in source_outbounds) {
        if (supported_subscription_outbound(outbound))
            continue;
        let t = type(outbound) == "object" ? as_string(outbound.type || "missing-type") : "non-object";
        if (reportable_skipped_subscription_type(t))
            skipped[t] = (skipped[t] || 0) + 1;
    }
    let outbounds = compatible_subscription_outbounds(source_outbounds, section_name);

    if (show_metadata !== false)
        runtime_subscription.merge_source_metadata(state, section_name, source_section, source_index, source_entry);
    let visibility_refs = subscription_visibility_refs(outbounds);
    if (include_urltest_groups === false)
        hide_urltest_group_outbounds = false;
    let exclude_flintnet_urltest_members =
        include_urltest_groups === false && flintnet_subscription_source(source_entry);
    node_prefix = trim(as_string(node_prefix));
    let prepared = [];
    let display_names = [];
    let source_links = [];
    let group_flags = [];
    let hidden_flags = [];
    let outbound_descriptions = [];
    let outbound_filter_names = [];
    let tag_map = {};
    for (let i = 0; i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (include_urltest_groups === false && subscription_urltest_group_outbound(outbound))
            continue;
        if (exclude_flintnet_urltest_members && subscription_urltest_group_member(outbound, visibility_refs))
            continue;
        let display_name = as_string(outbound.remark || outbound.tag || ("server-" + (i + 1)));
        let base = as_string(outbound.tag || outbound.remark || ("server-" + (i + 1)));
        if (node_prefix != "") {
            display_name = node_prefix + " " + display_name;
            base = display_name;
        }
        let new_tag = unique_tag(base, taken);
        taken[new_tag] = true;
        tag_map[base] = new_tag;
        if (as_string(outbound.tag || "") != "")
            tag_map[as_string(outbound.tag)] = new_tag;
        if (as_string(outbound.remark || "") != "")
            tag_map[as_string(outbound.remark)] = new_tag;
        push(prepared, copy_subscription_outbound(outbound, new_tag));
        push(display_names, display_name);
        let source_link = as_string(outbound.share_link || "");
        if (!subscription_share_link.is_copyable_link(source_link))
            source_link = subscription_share_link.serialize_outbound_link(outbound);
        push(source_links, source_link);
        push(group_flags, subscription_group_outbound(outbound));
        push(hidden_flags, subscription_hidden_outbound(outbound, visibility_refs, hide_urltest_group_outbounds, hide_detour_outbounds));
        push(outbound_descriptions, as_string(outbound.__prokop_description || ""));
        push(outbound_filter_names, map(array_or_empty(outbound.__prokop_filter_names),
            name => node_prefix != "" ? node_prefix + " " + name : name));
    }

    if (length(keys(skipped)) > 0)
        warn("skipped unsupported subscription outbounds for rule '", section_name, "': ", subscription_skip_summary(skipped), "\n");

    rewrite_subscription_outbound_references(prepared, tag_map, subscription_reference_set(source_outbounds));
    for (let outbound in prepared)
        if (as_string(outbound.type || "") == "urltest")
            urltest_override.apply(outbound, section_name, as_string(outbound.tag || ""));
    // Only provider groups are rotated. A URLTest the user assembled has an
    // order they chose, and it stays exactly as written.
    for (let i = 0; i < length(prepared); i++) {
        let group = prepared[i];
        if (group_flags[i] === true && as_string(group.type || "") == "urltest")
            group.outbounds = runtime_urltest.rotate_start(group.outbounds, urltest_start_seed(), group.tag);
    }
    let added = 0;
    for (let i = 0; i < length(prepared); i++) {
        let outbound = prepared[i];
        let is_group = group_flags[i] === true;
        if (is_group && length(array_or_empty(outbound.outbounds)) == 0) {
            warn("skipped empty subscription group for rule '", section_name, "': ", as_string(display_names[i] || outbound.tag || "unknown"), "\n");
            continue;
        }

        push(config.outbounds, outbound);
        added++;
        if (!is_group)
            push(urltest_candidate_tags, outbound.tag);
        runtime_subscription.remember_source_outbound(
            state,
            outbound.tag,
            display_names[i],
            outbound,
            source_links[i],
            outbound_descriptions[i]
        );
        state.outboundMetadata.filterNames[outbound.tag] = outbound_filter_names[i];
        if (hidden_flags[i] !== true) {
            push(selector_tags, outbound.tag);
            runtime_subscription.remember_urltest_group(state, outbound.tag, display_names[i], outbound);
        }
    }
    return added;
}

// Seconds of a sing-box duration ("90s", "1h30m", a bare number of
// seconds), null when unreadable.
function duration_to_seconds(value) {
    value = as_string(value);
    if (value == "")
        return null;
    if (match(value, /^[0-9]+$/) != null)
        return int(value, 10);

    let multipliers = { ns: 0.000000001, us: 0.000001, ms: 0.001, s: 1, m: 60, h: 3600, d: 86400 };
    let total = 0.0;
    let rest = value;
    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return null;
        total += matched[1] * multipliers[matched[3]];
        rest = substr(rest, length(matched[0]));
    }
    return total;
}

function urltest_check_interval(section, urltest_id) {
    let interval = connections.urltest_check_interval(section, urltest_id);
    return interval != "" ? interval : "3m";
}

// sing-box refuses a URLTest group whose interval is longer than its
// idle_timeout (30m unless set). A group with a longer interval and no
// idle_timeout of its own gets the interval as idle_timeout, whatever its
// id (A2); one with a shorter idle_timeout of its own is refused by the
// validator.
function urltest_idle_timeout(section, urltest_id) {
    let configured = connections.urltest_idle_timeout(section, urltest_id);
    if (configured != "")
        return configured;
    let interval = urltest_check_interval(section, urltest_id);
    let interval_seconds = duration_to_seconds(interval);
    let default_idle_seconds = duration_to_seconds(runtime_constants.URLTEST_DEFAULT_IDLE_TIMEOUT);
    return interval_seconds != null && default_idle_seconds != null && interval_seconds > default_idle_seconds ? interval : "";
}

function supported_urltest_filter_mode(mode) {
    return mode == "include" || mode == "exclude" || mode == "mixed";
}

function filter_mode_uses_include(mode) {
    return mode == "include" || mode == "mixed";
}

function filter_mode_uses_exclude(mode) {
    return mode == "exclude" || mode == "mixed";
}

function configured_country_filter(mode, include_countries, exclude_countries) {
    return (filter_mode_uses_include(mode) && length(array_or_empty(include_countries)) > 0) ||
        (filter_mode_uses_exclude(mode) && length(array_or_empty(exclude_countries)) > 0);
}

function section_needs_country_is(section) {
    for (let urltest_id in connections.urltests(section)) {
        let mode = connections.urltest_filter_mode(section, urltest_id);
        if (connections.urltest_detect_server_country(section, urltest_id) == "country_is" &&
            configured_country_filter(
                mode,
                connections.urltest_include_countries(section, urltest_id),
                connections.urltest_exclude_countries(section, urltest_id)
            ))
            return true;
    }

    for (let group_id in connections.priority_groups(section)) {
        for (let level_id in connections.priority_levels(group_id)) {
            if (connections.priority_level_direct(group_id, level_id))
                continue;
            let mode = connections.priority_level_filter_mode(group_id, level_id);
            if (connections.priority_level_detect_server_country(group_id, level_id) == "country_is" &&
                configured_country_filter(
                    mode,
                    connections.priority_level_include_countries(group_id, level_id),
                    connections.priority_level_exclude_countries(group_id, level_id)
                ))
                return true;
        }
    }
    return false;
}

function section_has_direct_priority_level(section) {
    for (let group_id in connections.priority_groups(section))
        for (let level_id in connections.priority_levels(group_id))
            if (connections.priority_level_direct(group_id, level_id))
                return true;
    return false;
}

function urltest_country_metadata(section, urltest_id, state) {
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let detect_method = connections.urltest_detect_server_country(section, urltest_id);
    if (detect_method == "flag_emoji")
        return runtime_urltest.countries_from_flag_names(object_or_empty(object_or_empty(state.outboundMetadata).names));
    return metadata;
}

function array_contains(values, needle) {
    for (let value in array_or_empty(values)) {
        if (value == needle)
            return true;
    }
    return false;
}

function unique_string_array(values) {
    let result = [];
    let seen = {};
    for (let value in array_or_empty(values)) {
        value = as_string(value);
        if (value == "" || seen[value])
            continue;
        seen[value] = true;
        push(result, value);
    }
    return result;
}

function object_keys_set(values) {
    let result = {};
    for (let value in array_or_empty(values))
        result[value] = true;
    return result;
}

function tag_display_name(tag, names) {
    let name = as_string(object_or_empty(names)[tag] || "");
    return name != "" ? name : tag;
}

function regex_match_set(tags, names, regexes) {
    return object_keys_set(runtime_urltest.regex_matching_tag_array(tags, names, regexes));
}

function tag_name_filter_matches(tag, names, name_filter, regex_set, metadata) {
    let name = tag_display_name(tag, names);
    if (array_contains(name_filter, name) || regex_set[tag])
        return true;
    for (let previous_name in array_or_empty(object_or_empty(object_or_empty(metadata).filterNames)[tag]))
        if (array_contains(name_filter, previous_name))
            return true;
    return false;
}

function tag_country_filter_matches(tag, countries, country_filter) {
    let country = uc(as_string(object_or_empty(countries)[tag] || ""));
    return country != "" && array_contains(country_filter, country);
}

function tag_attribute_filter_matches(tag, metadata, selected_values) {
    selected_values = array_or_empty(selected_values);
    if (length(selected_values) == 0)
        return true;

    let value = lc(as_string(object_or_empty(metadata)[tag] || ""));
    if (value == "")
        return false;
    for (let selected in selected_values)
        if (lc(as_string(selected)) == value)
            return true;
    return false;
}

function proxy_parameter_filter_matches_all(tag, metadata, protocols, transports, securities) {
    metadata = object_or_empty(metadata);
    return tag_attribute_filter_matches(tag, metadata.protocols, protocols) &&
        tag_attribute_filter_matches(tag, metadata.transports, transports) &&
        tag_attribute_filter_matches(tag, metadata.securities, securities);
}

function proxy_parameter_filter_matches_any(tag, metadata, protocols, transports, securities) {
    metadata = object_or_empty(metadata);
    return (length(array_or_empty(protocols)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.protocols, protocols)) ||
        (length(array_or_empty(transports)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.transports, transports)) ||
        (length(array_or_empty(securities)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.securities, securities));
}

function name_or_country_filter_configured(name_filter, regexes, country_filter) {
    return length(array_or_empty(name_filter)) > 0 ||
        length(array_or_empty(regexes)) > 0 ||
        length(array_or_empty(country_filter)) > 0;
}

function urltest_all_candidate_outbounds(urltest_candidate_tags) {
    return unique_string_array(urltest_candidate_tags);
}

function deduplicate_alias_outbounds(outbounds, metadata) {
    let aliases = object_or_empty(object_or_empty(metadata).aliases);
    let seen = {};
    let result = [];
    for (let tag in array_or_empty(outbounds)) {
        let identity = as_string(aliases[tag] || tag);
        if (seen[identity])
            continue;
        seen[identity] = true;
        push(result, tag);
    }
    return result;
}

function urltest_matching_candidate_outbounds(urltest_candidate_tags, names, countries, name_filter, regexes, country_filter,
    metadata, proxy_parameters_enabled, proxy_parameters_operator, protocols, transports, securities, additional_matches) {
    names = object_or_empty(names);
    countries = object_or_empty(countries);
    country_filter = runtime_urltest.normalized_country_list(country_filter);

    let regex_set = regex_match_set(urltest_candidate_tags, names, regexes);
    let base_filter_configured = name_or_country_filter_configured(name_filter, regexes, country_filter);
    let additional_set = object_keys_set(additional_matches);
    let result = [];

    for (let tag in array_or_empty(urltest_candidate_tags)) {
        let base_matches = tag_name_filter_matches(tag, names, name_filter, regex_set, metadata) ||
            tag_country_filter_matches(tag, countries, country_filter);
        let matches = additional_set[tag] || base_matches;
        if (proxy_parameters_enabled && proxy_parameters_operator == "or") {
            matches = additional_set[tag] || base_matches || proxy_parameter_filter_matches_any(
                tag, metadata, protocols, transports, securities
            );
        }
        else if (proxy_parameters_enabled) {
            if (!base_filter_configured)
                base_matches = true;
            matches = additional_set[tag] ||
                (base_matches && proxy_parameter_filter_matches_all(
                    tag, metadata, protocols, transports, securities
                ));
        }

        if (matches)
            push(result, tag);
    }

    return unique_string_array(result);
}

function urltest_exclude_outbounds(all_outbounds, excluded_outbounds) {
    let excluded = object_keys_set(excluded_outbounds);
    let result = [];
    for (let tag in array_or_empty(all_outbounds)) {
        if (!excluded[tag])
            push(result, tag);
    }
    return result;
}

function filter_candidate_outbounds(filter_mode, urltest_candidate_tags, names, countries, metadata,
    include_names, include_regex, include_countries,
    include_proxy_parameters, include_protocols, include_transports, include_securities,
    exclude_names, exclude_regex, exclude_countries,
    exclude_proxy_parameters, exclude_protocols, exclude_transports, exclude_securities,
    include_additional_matches, exclude_additional_matches) {
    let all_outbounds = urltest_all_candidate_outbounds(urltest_candidate_tags);
    if (filter_mode == "" || filter_mode == "disabled")
        return deduplicate_alias_outbounds(all_outbounds, metadata);
    if (!supported_urltest_filter_mode(filter_mode))
        return deduplicate_alias_outbounds(all_outbounds, metadata);

    let include_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        include_names,
        include_regex,
        include_countries,
        metadata,
        include_proxy_parameters,
        "and",
        include_protocols,
        include_transports,
        include_securities,
        include_additional_matches
    );
    let exclude_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        exclude_names,
        exclude_regex,
        exclude_countries,
        metadata,
        exclude_proxy_parameters,
        "or",
        exclude_protocols,
        exclude_transports,
        exclude_securities,
        exclude_additional_matches
    );

    if (filter_mode == "include")
        return deduplicate_alias_outbounds(include_outbounds, metadata);
    if (filter_mode == "exclude")
        return deduplicate_alias_outbounds(urltest_exclude_outbounds(all_outbounds, exclude_outbounds), metadata);
    if (filter_mode == "mixed")
        return deduplicate_alias_outbounds(urltest_exclude_outbounds(include_outbounds, exclude_outbounds), metadata);
    return deduplicate_alias_outbounds(all_outbounds, metadata);
}

function urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, state) {
    return filter_candidate_outbounds(
        connections.urltest_filter_mode(section, urltest_id),
        urltest_candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        urltest_country_metadata(section, urltest_id, state),
        object_or_empty(state.outboundMetadata),
        connections.urltest_include_outbounds(section, urltest_id),
        connections.urltest_include_regex(section, urltest_id),
        connections.urltest_include_countries(section, urltest_id),
        connections.urltest_include_proxy_parameters(section, urltest_id),
        connections.urltest_include_protocols(section, urltest_id),
        connections.urltest_include_transports(section, urltest_id),
        connections.urltest_include_securities(section, urltest_id),
        connections.urltest_exclude_outbounds(section, urltest_id),
        connections.urltest_exclude_regex(section, urltest_id),
        connections.urltest_exclude_countries(section, urltest_id),
        connections.urltest_exclude_proxy_parameters(section, urltest_id),
        connections.urltest_exclude_protocols(section, urltest_id),
        connections.urltest_exclude_transports(section, urltest_id),
        connections.urltest_exclude_securities(section, urltest_id)
    );
}

function priority_level_country_metadata(group_id, level_id, state) {
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let detect_method = connections.priority_level_detect_server_country(group_id, level_id);
    if (detect_method == "flag_emoji")
        return runtime_urltest.countries_from_flag_names(object_or_empty(object_or_empty(state.outboundMetadata).names));
    return metadata;
}

function priority_level_filtered_outbounds(group_id, level_id, urltest_candidate_tags, state) {
    if (connections.priority_level_direct(group_id, level_id))
        return [ runtime_constants.DIRECT_OUTBOUND_TAG ];

    return filter_candidate_outbounds(
        connections.priority_level_filter_mode(group_id, level_id),
        urltest_candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        priority_level_country_metadata(group_id, level_id, state),
        object_or_empty(state.outboundMetadata),
        connections.priority_level_include_outbounds(group_id, level_id),
        connections.priority_level_include_regex(group_id, level_id),
        connections.priority_level_include_countries(group_id, level_id),
        connections.priority_level_include_proxy_parameters(group_id, level_id),
        connections.priority_level_include_protocols(group_id, level_id),
        connections.priority_level_include_transports(group_id, level_id),
        connections.priority_level_include_securities(group_id, level_id),
        connections.priority_level_exclude_outbounds(group_id, level_id),
        connections.priority_level_exclude_regex(group_id, level_id),
        connections.priority_level_exclude_countries(group_id, level_id),
        connections.priority_level_exclude_proxy_parameters(group_id, level_id),
        connections.priority_level_exclude_protocols(group_id, level_id),
        connections.priority_level_exclude_transports(group_id, level_id),
        connections.priority_level_exclude_securities(group_id, level_id)
    );
}

function remember_group_outbounds(group_outbounds, group_name, outbounds) {
    let combined = array_or_empty(group_outbounds[group_name]);
    for (let tag_name in array_or_empty(outbounds))
        push(combined, tag_name);
    group_outbounds[group_name] = unique_string_array(combined);
}

function grouped_selector_outbounds(section, selector_tags, group_outbounds, state) {
    let configured_groups = [
        ...connections.urltests(section),
        ...connections.priority_groups(section)
    ];
    if (length(configured_groups) == 0)
        return selector_tags;

    let selected = [];
    for (let group_name in keys(object_or_empty(group_outbounds))) {
        for (let tag_name in array_or_empty(group_outbounds[group_name])) {
            push(selected, tag_name);
        }
    }

    // An empty group (e.g. a renamed/missing filtered node) must not make
    // an otherwise usable subscription prevent the whole service from starting.
    // Retain the existing server selector fallback; never inject a direct route.
    return length(selected) > 0 ? unique_string_array(selected) : selector_tags;
}

function priority_levels_with_outbounds(group_id, urltest_candidate_tags, state) {
    let result = [];
    let assigned = {};

    for (let level_id in connections.priority_levels(group_id)) {
        let outbounds = [];
        for (let tag_name in priority_level_filtered_outbounds(group_id, level_id, urltest_candidate_tags, state)) {
            if (!assigned[tag_name]) {
                assigned[tag_name] = true;
                push(outbounds, tag_name);
            }
        }

        push(result, {
            id: level_id,
            displayName: connections.priority_level_display_name(group_id, level_id),
            order: int(connections.priority_level_order(group_id, level_id), 10),
            direct: connections.priority_level_direct(group_id, level_id),
            filter_mode: connections.priority_level_filter_mode(group_id, level_id),
            detect_server_country: connections.priority_level_detect_server_country(group_id, level_id),
            outbounds
        });
    }

    return result;
}

function priority_group_outbounds(levels) {
    let result = [];
    let seen = {};
    for (let level in array_or_empty(levels)) {
        for (let tag_name in array_or_empty(level.outbounds)) {
            tag_name = as_string(tag_name);
            if (tag_name != "" && !seen[tag_name]) {
                seen[tag_name] = true;
                push(result, tag_name);
            }
        }
    }
    return result;
}

function urltest_outbound_tag(section_name, urltest_id) {
    urltest_id = as_string(urltest_id);
    return urltest_id == "urltest"
        ? outbound_tag(section_name + "-urltest")
        : outbound_tag(section_name + "-urltest-" + urltest_id);
}

function priority_outbound_tag(section_name, group_id) {
    return outbound_tag(section_name + "-priority-" + as_string(group_id));
}

function add_urltest_outbound(config, section, urltest_id, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let urltest_outbounds = urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, state);
    let urltest_tag = urltest_outbound_tag(section_name, urltest_id);
    let display_name = connections.urltest_display_name(section, urltest_id);
    let urltest_outbound = {
        type: "urltest",
        tag: urltest_tag,
        outbounds: urltest_outbounds,
        url: connections.urltest_testing_url(section, urltest_id),
        interval: urltest_check_interval(section, urltest_id),
        tolerance: int(connections.urltest_tolerance(section, urltest_id), 10),
        interrupt_exist_connections: connections.urltest_interrupt_exist_connections(section, urltest_id)
    };
    let idle_timeout = urltest_idle_timeout(section, urltest_id);
    if (idle_timeout != "")
        urltest_outbound.idle_timeout = idle_timeout;
    urltest_override.apply(urltest_outbound, section_name, urltest_tag);

    runtime_subscription.remember_outbound_metadata(state, urltest_tag, display_name, urltest_outbound);
    runtime_subscription.remember_urltest_group_config(state, urltest_tag, {
        displayName: display_name,
        outbounds: urltest_outbounds,
        url: urltest_outbound.url,
        interval: urltest_outbound.interval,
        tolerance: urltest_outbound.tolerance,
        idle_timeout: urltest_outbound.idle_timeout,
        interrupt_exist_connections: urltest_outbound.interrupt_exist_connections
    });

    if (length(urltest_outbounds) == 0)
        runtime_generate_unsupported("URLTest group '" + display_name + "' in rule '" + section_name + "' has no usable proxy outbounds after filtering");

    push(config.outbounds, urltest_outbound);
    return {
        tag: urltest_tag,
        outbounds: urltest_outbounds
    };
}

function add_priority_group_outbound(config, section, group_id, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let levels = priority_levels_with_outbounds(group_id, urltest_candidate_tags, state);
    let outbounds = priority_group_outbounds(levels);
    let priority_tag = priority_outbound_tag(section_name, group_id);
    let display_name = connections.priority_group_display_name(section, group_id);
    let outbound = {
        type: "selector",
        tag: priority_tag,
        outbounds,
        default: outbounds[0],
        interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id)
    };

    let probe = null;
    if (connections.priority_group_payload_check(section, group_id) && length(outbounds) > 0) {
        if (length(priority_probes) >= PRIORITY_PROBE_MAX)
            runtime_generate_unsupported("at most " + PRIORITY_PROBE_MAX + " priority groups can check payload");
        probe = {
            tag: priority_tag + "-probe",
            inbound: runtime_constants.inbound_tag("probe-" + section_name + "-" + as_string(group_id)),
            port: PRIORITY_PROBE_PORT_FIRST + length(priority_probes)
        };
        push(priority_probes, probe);
        push(config.outbounds, {
            type: "selector",
            tag: probe.tag,
            outbounds,
            default: outbounds[0],
            interrupt_exist_connections: true
        });
    }

    runtime_subscription.remember_outbound_metadata(state, priority_tag, display_name, outbound);
    runtime_subscription.remember_priority_group(state, priority_tag, {
        id: group_id,
        tag: priority_tag,
        section: section_name,
        displayName: display_name,
        health_url: connections.priority_group_health_url(section, group_id),
        active_check_interval: connections.priority_group_active_check_interval(section, group_id),
        check_timeout: connections.priority_group_check_timeout(section, group_id),
        recovery_check_interval: connections.priority_group_recovery_check_interval(section, group_id),
        pick_fastest: connections.priority_group_pick_fastest(section, group_id),
        switch_to_faster_same_priority: connections.priority_group_switch_to_faster_same_priority(section, group_id),
        fastest_check_interval: connections.priority_group_fastest_check_interval(section, group_id),
        interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id),
        pin_dashboard: connections.priority_group_pin_dashboard(section, group_id),
        payload_check: probe != null,
        probe_tag: probe != null ? probe.tag : "",
        probe_port: probe != null ? probe.port : 0,
        outbounds,
        levels
    });

    if (length(outbounds) == 0)
        runtime_generate_unsupported("Priority group '" + display_name + "' in rule '" + section_name + "' has no usable proxy outbounds after filtering");

    push(config.outbounds, outbound);
    return {
        tag: priority_tag,
        outbounds
    };
}

function add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let selector_tag = outbound_tag(section_name);
    let selector_outbounds = selector_tags;
    let selector_default = selector_tags[0];
    let urltest_tags = [];
    let priority_tags = [];
    let group_outbounds = {};

    for (let urltest_id in connections.urltests(section)) {
        let urltest = add_urltest_outbound(config, section, urltest_id, urltest_candidate_tags, state);
        remember_group_outbounds(
            group_outbounds,
            connections.urltest_display_name(section, urltest_id),
            urltest.outbounds
        );
        if (urltest.tag == "")
            continue;

        push(urltest_tags, urltest.tag);
    }

    for (let group_id in connections.priority_groups(section)) {
        let priority = add_priority_group_outbound(config, section, group_id, urltest_candidate_tags, state);
        remember_group_outbounds(
            group_outbounds,
            connections.priority_group_display_name(section, group_id),
            priority.outbounds
        );
        if (priority.tag == "")
            continue;

        push(priority_tags, priority.tag);
    }

    selector_outbounds = grouped_selector_outbounds(section, selector_tags, group_outbounds, state);
    selector_default = selector_outbounds[0];
    if (length(urltest_tags) > 0 || length(priority_tags) > 0) {
        for (let tag in urltest_tags)
            push(selector_outbounds, tag);
        for (let tag in priority_tags)
            push(selector_outbounds, tag);
        selector_default = length(urltest_tags) > 0 ? urltest_tags[0] : priority_tags[0];
    }

    if (length(selector_outbounds) == 0)
        runtime_generate_unsupported("configured URLTest and Priority groups produced no usable outbounds");

    push(config.outbounds, {
        type: "selector",
        tag: selector_tag,
        outbounds: selector_outbounds,
        default: selector_default,
        interrupt_exist_connections: true
    });
}

function outbound_detour_tag_for_section(section) {
    if (!bool_option(section, "outbound_detour_enabled", false))
        return "";

    let detour_section = option(section, "outbound_detour_section", "");
    return detour_section == "" ? "" : outbound_tag(detour_section);
}

function apply_section_detour_to_connection_outbounds(config, start_index, detour_tag) {
    if (detour_tag == "")
        return;

    let outbounds = array_or_empty(config.outbounds);
    for (let i = int(start_index || 0); i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (type(outbound) != "object")
            continue;

        let outbound_type = lc(as_string(outbound.type || ""));
        if (outbound_type == "" ||
            outbound_type == "selector" ||
            outbound_type == "urltest" || outbound_type == "dns" ||
            outbound_type == "block")
            continue;

        // Preserve subscription chains: only their terminal dial outbound receives the section detour.
        if (as_string(outbound.detour || "") == "")
            outbound.detour = detour_tag;
    }
}

function mixed_proxy_enabled_action(action) {
    return action == "connection" || action == "proxy" || action == "outbound" || action == "vpn" ||
        action == "byedpi" || action == "zapret" || action == "zapret2";
}

function add_mixed_proxy_for_section(config, section, service_address) {
    if (!bool_option(section, "mixed_proxy_enabled", false))
        return;

    let action = option(section, "action", "");
    if (!mixed_proxy_enabled_action(action))
        runtime_generate_unsupported("mixed proxy inbound is not supported for action " + action);

    let listen_port_value = option(section, "mixed_proxy_port", "");
    if (match(listen_port_value, /^[0-9]+$/) == null)
        runtime_generate_unsupported("mixed proxy port is invalid");
    let listen_port = int(listen_port_value, 10);
    if (listen_port < 1 || listen_port > 65535)
        runtime_generate_unsupported("mixed proxy port is invalid");

    let listen = as_string(service_address || "");
    if (listen == "")
        runtime_generate_unsupported("mixed proxy listen address is not set");

    let inbound = {
        type: "mixed",
        tag: runtime_constants.inbound_tag(section[".name"] + "-mixed"),
        listen,
        listen_port
    };

    if (bool_option(section, "mixed_proxy_auth_enabled", false)) {
        let username = option(section, "mixed_proxy_username", "");
        let password = option(section, "mixed_proxy_password", "");
        if (username == "" || password == "")
            runtime_generate_unsupported("mixed proxy authentication is enabled but username or password is empty");
        inbound.users = [{ username, password }];
    }
    push(config.inbounds, inbound);
    push(config.route.rules, {
        action: "route",
        inbound: inbound.tag,
        outbound: runtime_constants.outbound_tag(section[".name"])
    });
}

function add_service_mixed_proxy_inbound(config, tag_name, listen_port, outbound) {
    push(config.inbounds, {
        type: "mixed",
        tag: tag_name,
        listen: runtime_constants.SERVICE_MIXED_INBOUND_ADDRESS,
        listen_port
    });
    push(config.route.rules, {
        action: "route",
        inbound: tag_name,
        outbound
    });
}

function add_priority_probe_inbounds(config) {
    for (let probe in priority_probes)
        add_service_mixed_proxy_inbound(config, probe.inbound, probe.port, probe.tag);
}

function service_mixed_proxy_inbound_tag_for_purpose(purpose) {
    return as_string(purpose || "lists") == "components"
        ? runtime_constants.inbound_tag("service-components")
        : runtime_constants.SERVICE_MIXED_INBOUND_TAG;
}

function service_mixed_proxy_port_for_purpose(purpose) {
    return runtime_constants.SERVICE_MIXED_INBOUND_PORT +
        (as_string(purpose || "lists") == "components" ? 1 : 0);
}

function add_global_download_service_mixed_proxy(config, settings, purpose) {
    let outbound = download_detour_tag(settings, purpose);
    if (outbound == "")
        return;

    add_service_mixed_proxy_inbound(
        config,
        service_mixed_proxy_inbound_tag_for_purpose(purpose),
        service_mixed_proxy_port_for_purpose(purpose),
        outbound
    );
}

function add_subscription_download_service_mixed_proxies(config, sections) {
    for (let target in connections.subscription_download_targets(sections)) {
        let port = connections.subscription_download_target_port(sections, target, runtime_constants.SERVICE_MIXED_INBOUND_PORT);
        if (port <= 0)
            runtime_generate_unsupported("subscription download proxy port could not be resolved");

        add_service_mixed_proxy_inbound(
            config,
            runtime_constants.inbound_tag("service-subscription-" + target),
            port,
            outbound_tag(target)
        );
    }
}

function add_service_mixed_proxy(config, settings, sections) {
    if (!download_via_proxy_any_enabled(settings, sections))
        return;

    add_global_download_service_mixed_proxy(config, settings, "lists");
    add_global_download_service_mixed_proxy(config, settings, "components");
    add_subscription_download_service_mixed_proxies(config, sections);

    if (download_via_proxy_enabled(settings, "lists") && download_detour_tag(settings, "lists") == "")
        runtime_generate_unsupported("download lists via proxy section is not set");
    if (download_via_proxy_enabled(settings, "components") && download_detour_tag(settings, "components") == "")
        runtime_generate_unsupported("download components via proxy section is not set");
}

// Notifications sent through a rule's connection (notify/manager.uc): one
// more service inbound, below the download ones, routed only by its tag.
// A notification setting never fails the runtime: without that rule's
// outbound (the rule is gone, disabled, or not ready at a cold start) there
// is no inbound, and the sender goes directly.
function notify_proxy_section(settings) {
    if (!bool_option(settings, "notify_enabled", false) || !bool_option(settings, "notify_via_proxy", false))
        return "";
    return option(settings, "notify_via_proxy_section", "");
}

function add_notify_service_mixed_proxy(config, settings) {
    let section_name = notify_proxy_section(settings);
    if (section_name == "")
        return;
    let outbound = outbound_tag(section_name);
    let found = false;
    for (let item in array_or_empty(config.outbounds))
        if (type(item) == "object" && item.tag == outbound)
            found = true;
    if (!found)
        return;
    add_service_mixed_proxy_inbound(
        config,
        runtime_constants.inbound_tag("service-notify"),
        runtime_constants.SERVICE_MIXED_INBOUND_PORT - 1,
        outbound
    );
}

/*
 * This proxy is intentionally routed only by its inbound tag. Destination
 * domains, IP ranges and rule sets must never be able to move its traffic to a
 * VPN outbound. Keep the compact 1.14-compatible route rule shape used by the
 * other service inbounds.
 */
function add_direct_proxy(config, settings, service_address) {
    if (!bool_option(settings, "direct_proxy_enabled", false))
        return;

    let listen = as_string(service_address || "");
    if (listen == "")
        runtime_generate_unsupported("direct proxy listen address is not set");

    let port_value = option(settings, "direct_proxy_port", as_string(runtime_constants.DIRECT_PROXY_DEFAULT_PORT));
    if (match(port_value, /^[0-9]+$/) == null)
        runtime_generate_unsupported("direct proxy port is invalid");
    let listen_port = int(port_value, 10);
    if (listen_port < 1 || listen_port > 65535)
        runtime_generate_unsupported("direct proxy port is invalid");

    push(config.inbounds, {
        type: "mixed",
        tag: runtime_constants.DIRECT_PROXY_INBOUND_TAG,
        listen,
        listen_port
    });
    push(config.outbounds, {
        type: "direct",
        tag: runtime_constants.DIRECT_PROXY_OUTBOUND_TAG,
        routing_mark: runtime_constants.OUTBOUND_MARK
    });
    push(config.route.rules, {
        action: "route",
        inbound: runtime_constants.DIRECT_PROXY_INBOUND_TAG,
        outbound: runtime_constants.DIRECT_PROXY_OUTBOUND_TAG
    });
}

// A manual link is read by the subscription parser, as a subscription's
// links are: the generator's own second parser decoded the whole link before
// reading it and lost '#', '&' and '+' in credentials and paths, and refused
// Hysteria2 port ranges the UI accepts (SB-2, SB-3).
let share_link_parser = null;

// null for a link the parser cannot build an outbound from (an unknown
// scheme, or a transport sing-box has none of, as kcp or quic): that node
// is skipped with a warning, as a subscription's is, and the rule's other
// nodes still run (SB-11). A rule left without any fails as before.
function manual_link_outbound(link, tag_name, section_name) {
    if (share_link_parser == null)
        share_link_parser = require("subscription.parser");
    let outbound = share_link_parser.parse_share_link(trim(as_string(link)));
    if (type(outbound) != "object") {
        let scheme = url_scheme(link);
        let name = url_fragment(link);
        warn("skipped manual proxy link ", name != "" ? "'" + name + "' " : "", "of rule '", as_string(section_name), "': ",
            index([ "vmess", "ss", "vless", "trojan", "hysteria2", "hy2", "socks4", "socks4a", "socks5", "socks5h" ], scheme) < 0
                ? "its scheme is not supported"
                : "the " + scheme + " link is invalid or uses a transport sing-box does not have", "\n");
        return null;
    }
    delete outbound.share_link;
    delete outbound.remark;
    outbound.tag = tag_name;
    return outbound;
}

function add_manual_proxy_link(config, state, section_name, manual_index, link, taken, selector_tags, urltest_candidate_tags) {
    let tag_name = outbound_tag(section_name + "-" + manual_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let outbound = manual_link_outbound(link, tag_name, section_name);
    if (outbound == null)
        return null;
    let display_name = url_fragment(link);
    if (display_name == "")
        display_name = tag_name;
    ensure_explicit_outbound_supported(outbound, "manual outbound", display_name);
    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);

    state.links[tag_name] = as_string(link);
    runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
    return tag_name;
}

function connection_item_tag(section_name, kind, item_index) {
    return outbound_tag(section_name + "-" + as_string(kind) + "-" + item_index);
}

function add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let manual_links = connections.connection_urls(section);
    for (let i = 0; i < length(manual_links); i++) {
        let link = manual_links[i];
        add_manual_proxy_link(
            config,
            state,
            section_name,
            i + 1,
            link,
            taken,
            selector_tags,
            urltest_candidate_tags
        );
    }
}

function add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let subscription_urls = connections.subscription_urls(section);

    for (let i = 0; i < length(subscription_urls); i++)
        add_subscription_source_with_state(
            config,
            section,
            i + 1,
            subscription_urls[i],
            taken,
            selector_tags,
            urltest_candidate_tags,
            state,
            connections.subscription_dashboard_metadata_enabled(section, subscription_urls[i]),
            connections.subscription_include_urltest_groups(section, subscription_urls[i]),
            connections.subscription_hide_urltest_group_outbounds(section, subscription_urls[i]),
            connections.subscription_hide_detour_outbounds(section, subscription_urls[i]),
            connections.subscription_node_prefix(section, subscription_urls[i])
        );
}

function add_interface_connection_outbound(config, state, section, interface_index, interface_name, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let tag_name = connection_item_tag(section_name, "interface", interface_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let domain_resolver = "";
    if (connections.interface_domain_resolver_enabled(section, interface_name)) {
        domain_resolver = runtime_constants.domain_resolver_tag(section_name + "-interface-" + interface_index);
        let dns_server = runtime_dns.server_from_options(
            domain_resolver,
            connections.interface_domain_resolver_dns_type(section, interface_name),
            connections.interface_domain_resolver_dns_server(section, interface_name),
            tag_name
        );
        if (dns_server.unsupported)
            runtime_generate_unsupported(dns_server.unsupported);
        push(config.dns.servers, dns_server);
    }

    let outbound = {
        type: "direct",
        tag: tag_name,
        bind_interface: interface_name,
        domain_resolver,
        routing_mark: runtime_constants.OUTBOUND_MARK
    };
    if (domain_resolver == "")
        delete outbound.domain_resolver;

    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);
    runtime_subscription.remember_outbound_metadata(state, tag_name, interface_name, outbound);
}

function add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let items = connections.interfaces(section);
    for (let i = 0; i < length(items); i++)
        add_interface_connection_outbound(config, state, section, i + 1, items[i], taken, selector_tags, urltest_candidate_tags);
}

function parse_outbound_json(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return null;
    }

    return type(value) == "object" ? value : null;
}

function rewrite_json_outbound_references(outbounds, tag_map) {
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        for (let key in [ "detour", "default" ]) {
            let reference = as_string(outbound[key] || "");
            if (reference != "" && tag_map[reference])
                outbound[key] = tag_map[reference];
        }

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    push(rewritten, as_string(tag_map[tag_name] || tag_name));
            }
            outbound.outbounds = rewritten;
        }
    }
}

function prepare_json_connection_outbounds(section, taken) {
    let items = connections.outbound_jsons(section);
    let prepared = [];
    let outbounds = [];
    let tag_map = {};
    let legacy_tags = [];

    for (let i = 0; i < length(items); i++) {
        let outbound = parse_outbound_json(items[i]);
        if (outbound == null)
            runtime_generate_unsupported("JSON outbound is invalid");

        let display_name = trim(as_string(outbound.tag || ""));
        let legacy_tag = connection_item_tag(section[".name"], "json", i + 1);
        let base = display_name != "" ? display_name : legacy_tag;
        let tag_name = unique_tag(base, taken);
        ensure_explicit_outbound_supported(outbound, "JSON outbound", display_name != "" ? display_name : legacy_tag);
        taken[tag_name] = true;
        if (display_name != "" && !tag_map[display_name])
            tag_map[display_name] = tag_name;
        push(legacy_tags, [ legacy_tag, tag_name ]);

        outbound.tag = tag_name;
        push(outbounds, outbound);
        push(prepared, {
            outbound,
            displayName: display_name != "" ? display_name : "JSON outbound " + (i + 1)
        });
    }

    for (let entry in legacy_tags)
        if (!tag_map[entry[0]])
            tag_map[entry[0]] = entry[1];

    rewrite_json_outbound_references(outbounds, tag_map);
    return prepared;
}

function add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    for (let item in prepare_json_connection_outbounds(section, taken)) {
        let outbound = item.outbound;
        let tag_name = outbound.tag;
        push(config.outbounds, outbound);
        push(selector_tags, tag_name);
        if (urltest_leaf_candidate_outbound(outbound))
            push(urltest_candidate_tags, tag_name);
        runtime_subscription.remember_outbound_metadata(state, tag_name, item.displayName, outbound);
        runtime_subscription.remember_urltest_group(state, tag_name, item.displayName, outbound);
    }
}

function add_connections_outbound(config, section, taken) {
    let section_name = section[".name"];
    let selector_tags = [];
    let urltest_candidate_tags = [];
    let state = runtime_subscription.new_section_state(section_name);
    let cascade_start = length(array_or_empty(config.outbounds));

    add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags);
    // Apply before interface and JSON items are added: those source kinds are intentionally excluded.
    apply_section_detour_to_connection_outbounds(
        config,
        cascade_start,
        outbound_detour_tag_for_section(section)
    );
    add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags);

    if (length(selector_tags) == 0)
        runtime_generate_unsupported("connection section has no usable outbounds");

    if (section_needs_country_is(section)) {
        let previous_state = read_json_file(runtime_subscription.section_cache_path(section_name));
        state.outboundMetadata.countries = runtime_country.detect(
            state.servers,
            previous_state,
            option(runtime_settings(), "bootstrap_dns_server", "77.88.8.8")
        );
    }
    if (section_has_direct_priority_level(section))
        state.outboundMetadata.names[runtime_constants.DIRECT_OUTBOUND_TAG] = "Direct";

    state.urltestCandidateTags = unique_string_array(urltest_candidate_tags);
    runtime_subscription.resolve_urltest_profile_aliases(state);
    add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state);
    if (!atomic_write_json_file(runtime_subscription.section_cache_path(section_name), state))
        runtime_generate_unsupported("failed to write section cache for " + section_name);
}

function enabled_action_index(sections, target_section, action_name) {
    let index = 0;
    for (let section in sections) {
        if (option(section, "action", "") != action_name)
            continue;
        index++;
        if (section[".name"] == target_section[".name"])
            return index;
    }
    return 0;
}

function add_zapret_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "zapret");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve Zapret index for " + section[".name"]);
    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        routing_mark: runtime_constants.ZAPRET_ROUTE_MARK_BASE + index
    });
}

function add_zapret2_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "zapret2");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve Zapret2 index for " + section[".name"]);
    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        routing_mark: runtime_constants.ZAPRET2_ROUTE_MARK_BASE + index
    });
}

function add_byedpi_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "byedpi");
    if (index <= 0)
        runtime_generate_unsupported("unable to resolve ByeDPI index for " + section[".name"]);
    push(config.outbounds, {
        type: "socks",
        tag: outbound_tag(section[".name"]),
        server: runtime_constants.BYEDPI_LISTEN_ADDRESS,
        server_port: runtime_constants.BYEDPI_PORT_BASE + index - 1,
        version: "5"
    });
}

function ensure_community_ruleset(config, section_name, community) {
    if (!runtime_rulesets.is_community(community))
        runtime_generate_unsupported("unknown community list " + community);

    let tag_name = ruleset_tag(section_name, community, "community");
    if (!ruleset_registered(config, tag_name)) {
        let rule_set = {
            type: "remote",
            tag: tag_name,
            format: "binary",
            url: runtime_rulesets.community_url(community),
            update_interval: remote_ruleset_update_interval()
        };
        let detour = download_detour_tag(runtime_settings(), "lists");
        if (detour != "")
            rule_set.download_detour = detour;
        push(config.route.rule_set, rule_set);
    }
    return {
        tag: tag_name,
        kind: runtime_rulesets.community_kind(community)
    };
}

function domain_ip_list_ruleset_tag(section_name) {
    return ruleset_tag(section_name, "lists", "");
}

function domain_ip_list_ruleset_path(section_name) {
    return runtime_ruleset_folder + "/" + domain_ip_list_ruleset_tag(section_name) + ".json";
}

function remote_list_ruleset_tag(section_name, kind) {
    return ruleset_tag(section_name, "remote", kind);
}

function remote_list_ruleset_path(section_name, kind) {
    return runtime_ruleset_folder + "/" + remote_list_ruleset_tag(section_name, kind) + ".json";
}

function remote_list_is_singbox_managed(reference) {
    let extension = runtime_rulesets.file_extension(reference);
    return extension == "json" || extension == "srs";
}

function ensure_materialized_remote_list_ruleset(config, section_name, kind) {
    let tag_name = remote_list_ruleset_tag(section_name, kind);
    let path = remote_list_ruleset_path(section_name, kind);
    let ruleset = read_json_file(path);

    // Plain remote lists are downloaded and converted into this source rule-set
    // by the transactional list generation.  Never publish an nft interception
    // without the corresponding sing-box matcher: a missing or malformed
    // materialized file is a generation/configuration failure, not an empty
    // matcher that could fall through to final/direct.
    if (type(ruleset) != "object" || type(ruleset.rules) != "array")
        runtime_generate_unsupported("remote " + kind + " ruleset for '" + section_name + "' is missing or invalid");

    if (!ruleset_registered(config, tag_name)) {
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: "source",
            path
        });
    }
    return tag_name;
}

function add_remote_list_rulesets(config, section, option_name, kind, route_tags, dns_tags) {
    let section_name = as_string(section[".name"]);
    let has_materialized_source = false;

    for (let reference in list_option(section, option_name)) {
        reference = as_string(reference);
        if (reference == "")
            continue;

        if (!remote_list_is_singbox_managed(reference)) {
            has_materialized_source = true;
            continue;
        }

        let ensured = ensure_custom_ruleset(config, reference);
        push(route_tags, ensured.tag);
        if (kind == "domains" && dns_tags != null)
            push(dns_tags, ensured.tag);
    }

    if (!has_materialized_source)
        return;

    let tag_name = ensure_materialized_remote_list_ruleset(config, section_name, kind);
    push(route_tags, tag_name);
    if (kind == "domains" && dns_tags != null)
        push(dns_tags, tag_name);
}

function reference_is_local(reference) {
    return substr(as_string(reference), 0, 1) == "/";
}

function source_file_exists(path) {
    return fs.readfile(path) != null;
}

// The local files of a section's domain_ip_lists, into its ruleset. Remote
// lists are downloaded by the list updater (components/updates.uc), which
// writes local and remote entries into the same ruleset: a section with both
// keeps that set as it is, or the rebuild dropped the downloaded entries
// until the next update (A8). A local file that is gone or unreadable keeps
// the previous set instead of a smaller one, and the new set replaces the
// old one in one rename.
function rebuild_local_domain_ip_list_ruleset(section_name, references, domains_only) {
    let ruleset_path = domain_ip_list_ruleset_path(section_name);
    let has_local = false, has_remote = false;

    for (let reference in references) {
        if (reference_is_local(reference))
            has_local = true;
        else if (as_string(reference) != "")
            has_remote = true;
    }

    if (!has_local)
        return;
    let previous = source_rulesets.has_rules(ruleset_path);
    if (has_remote && previous)
        return;

    let missing = [];
    for (let reference in references)
        if (reference_is_local(reference) && !source_file_exists(as_string(reference)))
            push(missing, as_string(reference));
    for (let reference in missing)
        warn("local domain/IP list not found: ", reference, "\n");
    if (length(missing) > 0 && previous) {
        warn("keeping the previous domain/IP list set of rule ", section_name, "\n");
        return;
    }

    let staging = ruleset_path + ".new";
    fs.unlink(staging);
    source_rulesets.create_source(staging);
    for (let reference in references) {
        reference = as_string(reference);
        if (!reference_is_local(reference) || index(missing, reference) >= 0)
            continue;

        source_rulesets.import_plain_list(reference, staging, "domain_suffix", "domains", "5000");
        if (!domains_only)
            source_rulesets.import_plain_list(reference, staging, "ip_cidr", "subnets", "5000");
    }
    if (!fs.rename(staging, ruleset_path)) {
        fs.unlink(staging);
        warn("could not replace the domain/IP list set of rule ", section_name, "\n");
    }
}

function add_domain_ip_list_ruleset(config, section_name, rule_set_tags, dns_query_tags, dns_response_tags, references, domains_only) {
    if (length(references) == 0)
        return;

    rebuild_local_domain_ip_list_ruleset(section_name, references, domains_only);

    let ruleset_path = domain_ip_list_ruleset_path(section_name);
    if (!source_rulesets.has_rules(ruleset_path))
        return;

    let tag_name = domain_ip_list_ruleset_tag(section_name);
    if (!ruleset_registered(config, tag_name)) {
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: "source",
            path: ruleset_path
        });
    }

    if (!domains_only)
        push(rule_set_tags, tag_name);
    let has_domains = source_rulesets.has_domain_matchers(ruleset_path);
    let has_addresses = source_rulesets.has_ip_matchers(ruleset_path);
    if (runtime_supports_dns_response_matching && has_addresses)
        push(dns_response_tags, tag_name);
    else if (has_domains)
        // Below 1.14 an address-only list cannot match a query, and it was
        // never placed in the DNS rules. Keep it out.
        push(dns_query_tags, tag_name);
}

// Legacy and combined rule conditions are read through one layer
// (routing/rule_conditions.uc), shared with autotune.
let legacy_condition_values = rule_conditions.legacy_condition_values;
let domain_conditions = rule_conditions.domain_conditions;

function add_domain_array(rule, key, values) {
    if (length(values) > 0)
        rule[key] = values;
}

function push_dns_matcher_rule(config, rule) {
    push(config.dns.rules, rule);
}

function section_dns_server(section) {
    // Domain-only bypass still needs to enter sing-box so its direct route is
    // visible in the connection monitor. Source-aware bypass is handled by
    // add_source_aware_bypass_dns_rules() and fully-routed devices keep their
    // real-address DNS path in add_fully_routed_ips_rules().
    return runtime_constants.FAKEIP_DNS_SERVER_TAG;
}

function single_or_array(values) {
    return length(values) == 1 ? values[0] : values;
}

function copy_dns_matchers(matchers) {
    let copy = {};
    for (let key, value in matchers)
        copy[key] = value;
    return copy;
}

function excluded_source_ip_cidr(section) {
    return legacy_condition_values(section, "excluded_source_ip_cidr");
}

function exclude_sources_from_matchers(matchers, section) {
    let excluded = excluded_source_ip_cidr(section);
    if (length(excluded) == 0)
        return matchers;

    // Actions belong to the outer rule, never to a nested match condition.
    let conditions = {};
    let result = {};
    for (let key, value in matchers) {
        if (key == "action" || key == "outbound" || key == "server" ||
            key == "rewrite_ttl" || key == "strategy")
            result[key] = value;
        else
            conditions[key] = value;
    }
    let wrapped = {
        type: "logical",
        mode: "and",
        rules: [
            conditions,
            {
                source_ip_cidr: single_or_array(excluded),
                invert: true
            }
        ]
    };
    for (let key, value in wrapped)
        result[key] = value;
    return result;
}

function exclude_sources_from_route_rule(rule, section) {
    return exclude_sources_from_matchers(rule, section);
}

function add_source_dns_matchers(rule, source_ip_cidr) {
    if (length(source_ip_cidr) == 0)
        return;

    rule.inbound = source_dns_inbound_matcher();
    rule.source_ip_cidr = single_or_array(source_ip_cidr);
}

function add_source_aware_bypass_dns_rules(config, matchers, rewrite_ttl) {
    if (runtime_supports_dns_response_matching) {
        // sing-box 1.14 response matching must inspect the response from the
        // same path that will be returned. Evaluate dnsmasq first, then
        // respond with that accepted non-FakeIP answer below.
        let evaluate = copy_dns_matchers(matchers);
        evaluate.action = "evaluate";
        evaluate.server = runtime_constants.DNSMASQ_DNS_SERVER_TAG;
        push_dns_matcher_rule(config, evaluate);
    }

    let fakeip_matcher = {
        ip_cidr: [ runtime_constants.FAKEIP_INET4_RANGE, runtime_constants.FAKEIP_INET6_RANGE ],
        invert: true
    };
    if (runtime_supports_dns_response_matching)
        fakeip_matcher.match_response = true;

    let filtered_dnsmasq = {
        type: "logical",
        mode: "and",
        rules: [
            copy_dns_matchers(matchers),
            fakeip_matcher
        ]
    };
    if (runtime_supports_dns_response_matching) {
        filtered_dnsmasq.action = "respond";
    }
    else {
        filtered_dnsmasq.action = "route";
        filtered_dnsmasq.server = runtime_constants.DNSMASQ_DNS_SERVER_TAG;
        filtered_dnsmasq.rewrite_ttl = rewrite_ttl;
    }
    push_dns_matcher_rule(config, filtered_dnsmasq);

    let fallback = copy_dns_matchers(matchers);
    fallback.action = "route";
    fallback.server = runtime_constants.DNS_SERVER_TAG;
    if (fallback.type == "logical")
        fallback.rules = [ ...fallback.rules, { query_type: [ "A", "AAAA" ] } ];
    else
        fallback.query_type = [ "A", "AAAA" ];
    fallback.rewrite_ttl = rewrite_ttl;
    push_dns_matcher_rule(config, fallback);
}

function add_section_dns_matcher_rule(config, section, matchers, rewrite_ttl) {
    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    add_source_dns_matchers(matchers, source_ip_cidr);
    matchers = exclude_sources_from_matchers(matchers, section);

    if (option(section, "action", "") == "bypass" && length(source_ip_cidr) > 0) {
        add_source_aware_bypass_dns_rules(config, matchers, rewrite_ttl);
        return;
    }

    matchers.action = "route";
    matchers.server = section_dns_server(section);
    matchers.rewrite_ttl = rewrite_ttl;
    push_dns_matcher_rule(config, matchers);
}

// Which DNS tag list a rule-set belongs to.
//
// Below 1.14 there is no response matching, so the pre-1.14 behaviour has to be
// reproduced exactly, and it differed by source: a community list always joined
// the DNS rule, while a custom rule-set joined it only when it carried domains.
// Returning null means "keep it out of the DNS rules", as before.
function dns_tags_for_ruleset_kind(kind, query_tags, response_tags, legacy_always) {
    if (as_string(kind) == "domains")
        return query_tags;
    if (runtime_supports_dns_response_matching)
        return response_tags;
    return legacy_always ? query_tags : null;
}

function append_unique_tags(values, additions) {
    let seen = {};
    for (let value in values)
        seen[value] = true;
    for (let value in additions) {
        if (!seen[value]) {
            seen[value] = true;
            push(values, value);
        }
    }
}

// sing-box 1.14 refuses to use an address rule-set as a DNS query filter: the
// addresses only exist once the answer is known. Ask it to resolve first, then
// route the answer when the rule-set matches the response.
function add_response_ruleset_dns_rule(config, section, tags, rewrite_ttl, server_tag) {
    if (length(tags) == 0)
        return;

    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");

    let evaluate = {};
    add_source_dns_matchers(evaluate, source_ip_cidr);
    evaluate = exclude_sources_from_matchers(evaluate, section);
    evaluate.action = "evaluate";
    evaluate.server = runtime_constants.DNS_SERVER_TAG;
    push_dns_matcher_rule(config, evaluate);

    let response = {
        rule_set: single_or_array(tags),
        match_response: true
    };
    add_source_dns_matchers(response, source_ip_cidr);
    response = exclude_sources_from_matchers(response, section);
    response.action = "route";
    response.server = server_tag;
    response.rewrite_ttl = rewrite_ttl;
    push_dns_matcher_rule(config, response);
}

function add_ruleset_dns_query_rule(config, section, tags, rewrite_ttl, server_tag) {
    if (length(tags) == 0)
        return;

    if (server_tag == section_dns_server(section)) {
        add_section_dns_matcher_rule(config, section, { rule_set: single_or_array(tags) }, rewrite_ttl);
        return;
    }

    let query = { rule_set: single_or_array(tags), action: "route", server: server_tag, rewrite_ttl };
    add_source_dns_matchers(query, legacy_condition_values(section, "source_ip_cidr"));
    push_dns_matcher_rule(config, exclude_sources_from_matchers(query, section));
}

function add_section_ruleset_dns_rules(config, section, query_tags, response_tags, rewrite_ttl, server_tag) {
    // Below 1.14 there is no response matching, so both kinds collapse back
    // into the single query rule this fork has always emitted.
    if (!runtime_supports_dns_response_matching) {
        append_unique_tags(query_tags, response_tags);
        add_ruleset_dns_query_rule(config, section, query_tags, rewrite_ttl, server_tag);
        return;
    }

    add_ruleset_dns_query_rule(config, section, query_tags, rewrite_ttl, server_tag);
    add_response_ruleset_dns_rule(config, section, response_tags, rewrite_ttl, server_tag);
}

function source_aware_dns_sources(sections) {
    let seen = {};
    let values = [];

    for (let section in sections) {
        let action = option(section, "action", "");
        let candidates = [];
        if (connections.has_dns_matchers(section))
            for (let value in legacy_condition_values(section, "source_ip_cidr"))
                push(candidates, value);
        if (connections.has_dns_matchers(section) || length(list_option(section, "fully_routed_ips")) > 0)
            for (let value in excluded_source_ip_cidr(section))
                push(candidates, value);
        if (action == "bypass" || action == "dns")
            for (let value in list_option(section, "fully_routed_ips"))
                push(candidates, value);

        for (let value in candidates) {
            value = trim(as_string(value));
            if (value != "" && !seen[value]) {
                seen[value] = true;
                push(values, value);
            }
        }
    }

    return values;
}

function add_source_aware_dns_support(config, source_ip_cidr) {
    if (length(source_ip_cidr) == 0)
        return;

    push(config.dns.servers, {
        type: "udp",
        tag: runtime_constants.DNSMASQ_DNS_SERVER_TAG,
        server: "127.0.0.1",
        server_port: 53
    });
}

function add_source_aware_dns_fallback(config, source_ip_cidr) {
    if (length(source_ip_cidr) == 0)
        return;

    let rule = {
        action: "route",
        server: runtime_constants.DNSMASQ_DNS_SERVER_TAG,
        rewrite_ttl: int_option(runtime_settings(), "dns_rewrite_ttl", "60")
    };
    add_source_dns_matchers(rule, source_ip_cidr);
    push_dns_matcher_rule(config, rule);
}

function dns_action_server_tag(section_name) {
    return runtime_constants.tag(section_name, "dns-server");
}

function dns_action_detour_tag(section) {
    if (!bool_option(section, "dns_detour_enabled", false))
        return "";
    let target_section = option(section, "dns_detour_section", "");
    return target_section == "" ? "" : outbound_tag(target_section);
}

function add_dns_server_for_section(config, section) {
    let server = runtime_dns.server_from_options(
        dns_action_server_tag(section[".name"]),
        option(section, "dns_type", "udp"),
        option(section, "dns_server", ""),
        dns_action_detour_tag(section)
    );
    if (server.unsupported)
        runtime_generate_unsupported(server.unsupported);
    push(config.dns.servers, server);
}

function add_dns_action_rules_for_section(config, section) {
    let domains = domain_conditions(section);
    let domain = domains.domain;
    let domain_suffix = domains.domain_suffix;
    let domain_keyword = domains.domain_keyword;
    let domain_regex = domains.domain_regex;
    let dns_query_rule_set_tags = [];
    let dns_response_rule_set_tags = [];
    let section_name = section[".name"];
    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    let fully_routed_ips = list_option(section, "fully_routed_ips");

    for (let community in connections.community_lists(section)) {
        let ensured = ensure_community_ruleset(config, section_name, as_string(community));
        push(dns_tags_for_ruleset_kind(ensured.kind, dns_query_rule_set_tags, dns_response_rule_set_tags, true), ensured.tag);
    }
    for (let reference in connections.rule_sets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        let dns_tags = dns_tags_for_ruleset_kind(ensured.kind, dns_query_rule_set_tags, dns_response_rule_set_tags, false);
        if (dns_tags != null)
            push(dns_tags, ensured.tag);
    }
    add_remote_list_rulesets(
        config,
        section,
        "remote_domain_lists",
        "domains",
        dns_query_rule_set_tags,
        dns_query_rule_set_tags
    );
    add_domain_ip_list_ruleset(
        config,
        section_name,
        [],
        dns_query_rule_set_tags,
        dns_response_rule_set_tags,
        list_option(section, "domain_ip_lists"),
        true
    );

    let rewrite_ttl = int_option(runtime_settings(), "dns_rewrite_ttl", "60");
    let server_tag = dns_action_server_tag(section_name);
    let has_inline_domains = length(domain) > 0 || length(domain_suffix) > 0 ||
        length(domain_keyword) > 0 || length(domain_regex) > 0;

    if (length(fully_routed_ips) > 0) {
        let dns_rule = {
            action: "route",
            server: server_tag,
            rewrite_ttl
        };
        add_source_dns_matchers(dns_rule, fully_routed_ips);
        dns_rule = exclude_sources_from_matchers(dns_rule, section);
        push_dns_matcher_rule(config, dns_rule);
    }
    if (has_inline_domains) {
        let dns_rule = {
            action: "route",
            server: server_tag,
            rewrite_ttl
        };
        add_domain_array(dns_rule, "domain", domain);
        add_domain_array(dns_rule, "domain_suffix", domain_suffix);
        add_domain_array(dns_rule, "domain_keyword", domain_keyword);
        add_domain_array(dns_rule, "domain_regex", domain_regex);
        add_source_dns_matchers(dns_rule, source_ip_cidr);
        dns_rule = exclude_sources_from_matchers(dns_rule, section);
        push_dns_matcher_rule(config, dns_rule);
    }
    add_section_ruleset_dns_rules(
        config,
        section,
        dns_query_rule_set_tags,
        dns_response_rule_set_tags,
        rewrite_ttl,
        server_tag
    );
    if (!has_inline_domains && length(dns_query_rule_set_tags) == 0 &&
        length(dns_response_rule_set_tags) == 0 && length(fully_routed_ips) == 0)
        runtime_generate_unsupported("DNS action '" + section_name + "' has no domain matchers");
}

function add_port_matchers(rule, section) {
    let values = [];
    for (let value in list_option(section, "ports"))
        push(values, value);
    for (let value in rule_config.text_list_values(option(section, "ports_text", ""), "comma-space"))
        push(values, value);

    let ports = [];
    let port_ranges = [];
    let seen = {};
    for (let value in values) {
        value = trim(as_string(value));
        if (value == "" || seen[value])
            continue;
        seen[value] = true;

        // The port or range the way config/rule.uc reads it for nft and the
        // validator; a single-port range is the port: sing-box refuses a
        // range item without ':' (UC-098).
        let condition = rule_config.normalize_port_condition_value(value);
        if (condition == null)
            continue;
        if (index(condition, "-") < 0)
            push(ports, int(condition));
        else
            push(port_ranges, replace(condition, "-", ":"));
    }
    ports = uniq(ports);

    if (length(ports) > 0)
        rule.port = ports;
    if (length(port_ranges) > 0)
        rule.port_range = port_ranges;
}

function add_fully_routed_ips_rules(config, section) {
    let source_ip_cidr = list_option(section, "fully_routed_ips");
    if (length(source_ip_cidr) == 0)
        return;

    if (option(section, "action", "") == "bypass") {
        let dns_matchers = {};
        add_source_dns_matchers(dns_matchers, source_ip_cidr);
        dns_matchers = exclude_sources_from_matchers(dns_matchers, section);
        add_source_aware_bypass_dns_rules(
            config,
            dns_matchers,
            int_option(runtime_settings(), "dns_rewrite_ttl", "60")
        );
    }

    let target = runtime_route.target(section, outbound_tag(section[".name"]));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);

    let route_rule = {
        action: target.action,
        inbound: tproxy_inbound_matcher()
    };
    if (target.outbound)
        route_rule.outbound = target.outbound;
    route_rule.source_ip_cidr = single_or_array(source_ip_cidr);
    push(config.route.rules, exclude_sources_from_route_rule(route_rule, section));
}

function push_section_route_rule(config, section, route_rule) {
    let resolve = runtime_route.resolve_rule_for_section(section, route_rule);
    if (type(resolve) == "object" && resolve.warning)
        warn(resolve.warning, "\n");
    else if (type(resolve) == "object" && resolve.rule)
        push(config.route.rules, exclude_sources_from_route_rule(resolve.rule, section));
    push(config.route.rules, exclude_sources_from_route_rule(route_rule, section));
}

// nft captures the shared Cloudflare ranges of the Discord list for
// Discord's media ports over UDP only, whatever ports the rule filters
// (nft/apply.uc). sing-box takes that traffic to the rule's target by the
// same ranges and ports: matched by the rule-set and the rule's own port
// filter alone, it went out directly (C1).
function add_discord_shared_cloudflare_rule(config, section, target, source_ip_cidr) {
    let discord = false;
    for (let community in connections.community_lists(section))
        if (as_string(community) == "discord")
            discord = true;
    if (!discord)
        return;

    let ports = core_ip.discord_voice_port_matchers();
    let rule = {
        action: target.action,
        inbound: tproxy_inbound_matcher(),
        network: "udp",
        ip_cidr: [ ...core_ip.CLOUDFLARE_SHARED_CIDRS ],
        port: ports.port,
        port_range: ports.port_range
    };
    if (target.outbound)
        rule.outbound = target.outbound;
    if (length(source_ip_cidr) > 0)
        rule.source_ip_cidr = source_ip_cidr;
    push(config.route.rules, exclude_sources_from_route_rule(rule, section));
}

function add_combined_route_for_section(config, section) {
    let domains = domain_conditions(section);
    let domain = domains.domain;
    let domain_suffix = domains.domain_suffix;
    let domain_keyword = domains.domain_keyword;
    let domain_regex = domains.domain_regex;
    let ip_cidr = legacy_condition_values(section, "ip_cidr");
    let source_ip_cidr = legacy_condition_values(section, "source_ip_cidr");
    let rule_set_tags = [];
    let dns_query_rule_set_tags = [];
    let dns_response_rule_set_tags = [];
    let section_name = section[".name"];

    add_fully_routed_ips_rules(config, section);

    for (let community in connections.community_lists(section)) {
        let ensured = ensure_community_ruleset(config, section_name, as_string(community));
        push(rule_set_tags, ensured.tag);
        push(dns_tags_for_ruleset_kind(ensured.kind, dns_query_rule_set_tags, dns_response_rule_set_tags, true), ensured.tag);
    }
    for (let reference in connections.rule_sets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        push(rule_set_tags, ensured.tag);
        let dns_tags = dns_tags_for_ruleset_kind(ensured.kind, dns_query_rule_set_tags, dns_response_rule_set_tags, false);
        if (dns_tags != null)
            push(dns_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets_with_subnets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        push(rule_set_tags, ensured.tag);
        let dns_tags = dns_tags_for_ruleset_kind(ensured.kind, dns_query_rule_set_tags, dns_response_rule_set_tags, false);
        if (dns_tags != null)
            push(dns_tags, ensured.tag);
    }
    add_remote_list_rulesets(
        config,
        section,
        "remote_domain_lists",
        "domains",
        rule_set_tags,
        dns_query_rule_set_tags
    );
    add_remote_list_rulesets(
        config,
        section,
        "remote_subnet_lists",
        "subnets",
        rule_set_tags,
        null
    );
    add_domain_ip_list_ruleset(
        config,
        section_name,
        rule_set_tags,
        dns_query_rule_set_tags,
        dns_response_rule_set_tags,
        list_option(section, "domain_ip_lists"),
        false
    );

    let target = runtime_route.target(section, outbound_tag(section_name));
    if (target.unsupported)
        runtime_generate_unsupported(target.unsupported);
    let route_rule = {
        action: target.action,
        inbound: tproxy_inbound_matcher()
    };
    if (target.outbound)
        route_rule.outbound = target.outbound;
    add_domain_array(route_rule, "domain", domain);
    add_domain_array(route_rule, "domain_suffix", domain_suffix);
    add_domain_array(route_rule, "domain_keyword", domain_keyword);
    add_domain_array(route_rule, "domain_regex", domain_regex);
    if (length(ip_cidr) > 0)
        route_rule.ip_cidr = ip_cidr;
    if (length(source_ip_cidr) > 0)
        route_rule.source_ip_cidr = source_ip_cidr;
    add_port_matchers(route_rule, section);
    let has_route_matchers = route_rule.domain != null || route_rule.domain_suffix != null ||
        route_rule.domain_keyword != null || route_rule.domain_regex != null ||
        route_rule.ip_cidr != null || (length(rule_set_tags) == 0 &&
        (route_rule.port != null || route_rule.port_range != null));
    if (has_route_matchers)
        push_section_route_rule(config, section, route_rule);

    if (length(rule_set_tags) > 0) {
        // Since sing-box 1.14 a rule-set containing more than one rule is an
        // independent matcher.  Combining it with inline domain fields makes
        // the two matchers an AND expression, while Prokop sections define
        // inline domains and lists as alternatives.  Keep shared device and
        // port filters, but emit the rule-set alternative as its own rule.
        let rule_set_rule = {
            action: target.action,
            inbound: tproxy_inbound_matcher(),
            rule_set: single_or_array(rule_set_tags)
        };
        if (target.outbound)
            rule_set_rule.outbound = target.outbound;
        if (length(source_ip_cidr) > 0)
            rule_set_rule.source_ip_cidr = source_ip_cidr;
        add_port_matchers(rule_set_rule, section);
        push_section_route_rule(config, section, rule_set_rule);
    }
    add_discord_shared_cloudflare_rule(config, section, target, source_ip_cidr);

    let rewrite_ttl = int_option(runtime_settings(), "dns_rewrite_ttl", "60");
    if (length(domain) > 0 || length(domain_suffix) > 0 || length(domain_keyword) > 0 || length(domain_regex) > 0) {
        let dns_rule = {};
        add_domain_array(dns_rule, "domain", domain);
        add_domain_array(dns_rule, "domain_suffix", domain_suffix);
        add_domain_array(dns_rule, "domain_keyword", domain_keyword);
        add_domain_array(dns_rule, "domain_regex", domain_regex);
        add_section_dns_matcher_rule(config, section, dns_rule, rewrite_ttl);
    }
    add_section_ruleset_dns_rules(
        config,
        section,
        dns_query_rule_set_tags,
        dns_response_rule_set_tags,
        rewrite_ttl,
        section_dns_server(section)
    );
}

function unsupported_matcher_key(section) {
    let unsupported_options = [
        "subnet", "subnet_text",
        "local_domain_lists", "local_subnet_lists"
    ];
    for (let key in unsupported_options) {
        if (length(list_option(section, key)) > 0 || option(section, key, "") != "")
            return key;
    }
    return "";
}

// C3, opt-in per rule: REALITY servers on Xray-core 26.9.8 and newer that
// want X25519MLKEM768 in the ClientHello answer without it with their mask
// site. The key share goes with uTLS "chrome" only. sing-box-extended
// 2.7.2 or newer reads it; on any other core the option does nothing, which
// the setting says, and the configuration stays valid.
function apply_reality_mlkem(config, section, first) {
    if (!bool_option(section, "reality_mlkem", false))
        return;
    let v = REALITY_MLKEM_MIN_EXTENDED;
    if (!extended_at_least(v[0], v[1], v[2], false)) {
        warn("rule '", section[".name"], "': post-quantum REALITY key share needs sing-box-extended ",
            join(".", v), " or newer; not applied\n");
        return;
    }
    for (let i = first; i < length(config.outbounds); i++) {
        let tls = object_or_empty(config.outbounds[i]).tls;
        if (type(tls) != "object" || type(tls.reality) != "object" || tls.reality.enabled === false)
            continue;
        if (type(tls.utls) != "object" || lc(as_string(tls.utls.fingerprint)) != "chrome")
            continue;
        tls.reality.support_x25519mlkem768 = true;
    }
}

function add_outbound_for_section(config, section, taken, sections) {
    let action = option(section, "action", "");
    let section_name = section[".name"];
    if (!valid_section_name(section_name))
        runtime_generate_unsupported("section name is not safe for sing-box config generation");
    let unsupported_matcher = unsupported_matcher_key(section);
    if (unsupported_matcher != "")
        runtime_generate_unsupported("section has unsupported matcher " + unsupported_matcher);

    if (connections.is_connections_action(action)) {
        let first = length(config.outbounds);
        add_connections_outbound(config, section, taken);
        apply_reality_mlkem(config, section, first);
    }
    else if (action == "zapret")
        add_zapret_outbound(config, section, sections);
    else if (action == "zapret2")
        add_zapret2_outbound(config, section, sections);
    else if (action == "byedpi")
        add_byedpi_outbound(config, section, sections);
    else if (action == "bypass") {
        /* route-only action */
    }
    else if (action == "block") {
        /* route-only action */
    }
    else if (action == "dns") {
        add_dns_server_for_section(config, section);
    }
    else {
        runtime_generate_unsupported("unsupported action " + action);
    }
}

function reserve_section_outbound_tags(sections, taken) {
    for (let section in sections) {
        let action = option(section, "action", "");
        if (connections.is_connections_action(action) ||
            action == "byedpi" || action == "zapret" || action == "zapret2")
            taken[outbound_tag(section[".name"])] = true;

        if (!connections.is_connections_action(action))
            continue;

        for (let urltest_id in connections.urltests(section))
            taken[urltest_outbound_tag(section[".name"], urltest_id)] = true;
        for (let group_id in connections.priority_groups(section))
            taken[priority_outbound_tag(section[".name"], group_id)] = true;
    }
}

function add_route_for_section(config, section) {
    if (option(section, "action", "") == "dns")
        add_dns_action_rules_for_section(config, section);
    else
        add_combined_route_for_section(config, section);
}

function add_service_route_rules(config, sections) {
    let first = null;
    for (let section in sections) {
        let action = option(section, "action", "");
        if (connections.is_connections_action(action) ||
            action == "byedpi" || action == "zapret" || action == "zapret2") {
            first = section;
            break;
        }
    }
    if (first != null) {
        push(config.route.rules, {
            action: "route",
            inbound: tproxy_inbound_matcher(),
            outbound: outbound_tag(first[".name"]),
            domain: runtime_constants.CHECK_PROXY_IP_DOMAIN
        });
    }
    push(config.route.rules, {
        action: "route-options",
        domain: runtime_constants.FAKEIP_TEST_DOMAIN,
        override_port: 8443
    });
}

function deferred_section_set(value) {
    let result = {};
    for (let name in split(trim(as_string(value)), /[ \t\r\n]+/)) {
        name = as_string(name);
        if (name != "")
            result[name] = true;
    }
    return result;
}

// A deferred subscription section has no outbound until its subscription is
// loaded, so its traffic would meanwhile take the final (direct) outbound.
// One the VPN kill-switch protects is rejected instead, as a block section
// with its own matchers; nft/apply.uc keeps capturing its destinations
// (UC-192).
function deferred_section_rejected(section) {
    if (!connections.is_connections_action(option(section, "action", "")) ||
        !bool_option(section, "kill_switch", false))
        return null;
    let rejected = {};
    for (let key, value in section)
        rejected[key] = value;
    rejected.action = "block";
    delete rejected.mixed_proxy_enabled;
    return rejected;
}

function enabled_sections(deferred_sections) {
    let deferred = deferred_section_set(deferred_sections);
    let result = [];
    uci_cursor().foreach(CONFIG_NAME, "section", function(section) {
        let rejected = deferred[as_string(section[".name"])] ? deferred_section_rejected(section) : null;
        if (section_enabled(section) && !deferred[as_string(section[".name"])])
            push(result, section);
        else if (section_enabled(section) && rejected != null)
            push(result, rejected);
    });
    return result;
}

function apply_sing_box_version(config, sing_box_version) {
    let version_parts = match(as_string(sing_box_version), /^v?([0-9]+)\.([0-9]+)\./);
    let extended_parts = match(as_string(sing_box_version), /-extended-([0-9]+)\.([0-9]+)\.([0-9]+)/);
    runtime_extended_version = extended_parts != null
        ? [ int(extended_parts[1]), int(extended_parts[2]), int(extended_parts[3]) ]
        : null;
    runtime_supports_dns_response_matching = version_parts != null &&
        (int(version_parts[1]) > 1 || (int(version_parts[1]) == 1 && int(version_parts[2]) >= 14));
    if (version_parts != null && (int(version_parts[1]) > 1 ||
        (int(version_parts[1]) == 1 && int(version_parts[2]) >= 14)))
        delete config.dns.independent_cache;
}

function generate_config(output_path, service_address, mwan3_active, supports_xhttp, deferred_sections, sing_box_version) {
    priority_probes = [];
    runtime_supports_xhttp = supports_xhttp == null || as_string(supports_xhttp) == ""
        ? true
        : cli_bool(supports_xhttp);
    let cursor = uci_cursor();
    cursor.load(CONFIG_NAME);
    runtime_settings_cache = object_or_empty(cursor.get_all(CONFIG_NAME, "settings"));
    let settings = runtime_settings_cache;

    let sections = enabled_sections(deferred_sections);
    if (length(sections) == 0 && trim(as_string(deferred_sections)) == "")
        runtime_generate_unsupported("no enabled sections");

    let source_aware_dns = source_aware_dns_sources(sections);
    let config = base_config(settings, service_address, {
        mwan3_active: cli_bool(mwan3_active),
        source_aware_dns: length(source_aware_dns) > 0
    });
    apply_sing_box_version(config, sing_box_version);
    add_source_aware_dns_support(config, source_aware_dns);
    let taken = reserved_runtime_tag_set(config.outbounds);
    reserve_section_outbound_tags(sections, taken);
    for (let section in sections)
        add_outbound_for_section(config, section, taken, sections);
    add_direct_proxy(config, settings, service_address);
    add_service_route_rules(config, sections);
    for (let section in sections)
        add_route_for_section(config, section);
    add_source_aware_dns_fallback(config, source_aware_dns);
    add_service_mixed_proxy(config, settings, sections);
    add_notify_service_mixed_proxy(config, settings);
    add_priority_probe_inbounds(config);
    for (let section in sections)
        add_mixed_proxy_for_section(config, section, service_address);

    drop_unsupported_xhttp_settings(config);
    assert_unique_outbound_tags(config);
    strip_internal_fields(config);
    if (!common.write_private_json_file(output_path, config)) {
        warn("failed to write ", output_path, "\n");
        exit(1);
    }
}

// A9: the first start without a list cache, with lists downloaded through a
// rule's proxy. The list generation must exist before routing starts, and
// the service proxy it downloads through is part of the sing-box that
// starts after it. This config is a temporary sing-box for that download
// only: the outbounds of the enabled rules, DNS, and the lists service
// proxy inbound routed to the configured rule. No transparent proxy, DNS or
// other inbounds, no route or DNS rules (their rule sets are the lists that
// do not exist yet), no Clash API and no cache file. Generation side files
// (rule sets, section caches) go to scratch_dir, not to the runtime
// directories the real start fills afterwards.
//
// Stage "subscriptions" comes first when the rule the lists download
// through has no nodes yet: its subscription did not download directly at
// this start and waits for the service proxy of the rule it downloads
// through. The config then serves the subscription download proxies of
// the rules that have an outbound instead of the lists proxy.
function generate_list_bootstrap_config(output_path, service_address, mwan3_active, supports_xhttp, deferred_sections, sing_box_version, scratch_dir, stage) {
    if (as_string(scratch_dir) == "")
        runtime_generate_unsupported("list bootstrap scratch directory is not set");
    let subscriptions_stage = as_string(stage) == "subscriptions";
    if (!subscriptions_stage && as_string(stage) != "")
        runtime_generate_unsupported("unknown list bootstrap stage");
    runtime_subscription.set_section_cache_dir(scratch_dir + "/section-cache");
    runtime_ruleset_folder = scratch_dir + "/rulesets";
    runtime_supports_xhttp = supports_xhttp == null || as_string(supports_xhttp) == ""
        ? true
        : cli_bool(supports_xhttp);
    let cursor = uci_cursor();
    cursor.load(CONFIG_NAME);
    runtime_settings_cache = object_or_empty(cursor.get_all(CONFIG_NAME, "settings"));
    let settings = runtime_settings_cache;
    let detour = download_detour_tag(settings, "lists");
    if (detour == "")
        runtime_generate_unsupported("lists are not downloaded through a proxy");

    let sections = enabled_sections(deferred_sections);
    let config = base_config(settings, service_address, { mwan3_active: cli_bool(mwan3_active) });
    apply_sing_box_version(config, sing_box_version);
    let taken = reserved_runtime_tag_set(config.outbounds);
    reserve_section_outbound_tags(sections, taken);
    for (let section in sections)
        add_outbound_for_section(config, section, taken, sections);
    let present = {};
    for (let outbound in config.outbounds)
        present[as_string(outbound.tag)] = true;
    for (let endpoint in config.endpoints)
        present[as_string(endpoint.tag)] = true;
    let deferred = deferred_section_set(deferred_sections);

    config.inbounds = [];
    config.route.rules = [];
    config.route.rule_set = [];
    config.dns.rules = [];
    config.services = [];
    config.experimental = {};
    // "sing-box started" is an info line: the start waits for it.
    config.log = { disabled: false, level: "info", timestamp: false };

    if (subscriptions_stage) {
        // The ports subscription/cache.uc downloads through
        // (subscription_service_proxy_port): numbered over all rules.
        let all_sections = [];
        cursor.foreach(CONFIG_NAME, "section", function(section) {
            push(all_sections, section);
        });
        let base_port = int(getenv("SB_SERVICE_MIXED_INBOUND_PORT") || runtime_constants.SERVICE_MIXED_INBOUND_PORT);
        for (let target in connections.subscription_download_targets(all_sections)) {
            if (deferred[target] || !present[outbound_tag(target)])
                continue;
            let port = connections.subscription_download_target_port(all_sections, target, base_port);
            if (port <= 0)
                runtime_generate_unsupported("subscription download proxy port could not be resolved");
            add_service_mixed_proxy_inbound(config, runtime_constants.inbound_tag("service-subscription-" + target),
                port, outbound_tag(target));
        }
        if (length(config.inbounds) == 0)
            runtime_generate_unsupported("no rule a subscription downloads through has an outbound");
    }
    else {
        if (!present[detour])
            runtime_generate_unsupported("the rule lists are downloaded through has no outbound");
        // The port the list download reaches it on (components/updates.uc).
        add_service_mixed_proxy_inbound(config, runtime_constants.SERVICE_MIXED_INBOUND_TAG,
            int(getenv("SB_SERVICE_MIXED_INBOUND_PORT") || runtime_constants.SERVICE_MIXED_INBOUND_PORT), detour);
    }

    drop_unsupported_xhttp_settings(config);
    assert_unique_outbound_tags(config);
    strip_internal_fields(config);
    if (!common.write_private_json_file(output_path, config)) {
        warn("failed to write ", output_path, "\n");
        exit(1);
    }
}

function generate_config_fixture(fixture_path, output_path, service_address, mwan3_active, supports_xhttp, deferred_sections, sing_box_version) {
    use_fixture_cursor(fixture_path);
    // A fixture run keeps out of the router's runtime state unless pointed at one.
    if (!getenv("PROKOP_URLTEST_SEED_FILE") && !getenv("PROKOP_RUNTIME_STATE_DIR"))
        urltest_seed_file = "";
    runtime_subscription.set_section_cache_dir(output_path + ".section-cache");
    runtime_ruleset_folder = output_path + ".rulesets";
    generate_config(output_path, service_address, mwan3_active, supports_xhttp, deferred_sections, sing_box_version);
}

function stdin_length() {
    let value = read_stdin_json();
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function stdin_contains(needle) {
    return index(read_stdin(), as_string(needle)) >= 0;
}

function stdin_regex_matches(pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return false;

    try {
        return match(read_stdin(), regexp(pattern)) != null;
    }
    catch (e) {
        return false;
    }
}

function ip_addr_first_inet4() {
    for (let line in split(read_stdin(), "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (length(fields) < 2 || fields[0] != "inet")
            continue;

        let slash = index(fields[1], "/");
        print(slash >= 0 ? substr(fields[1], 0, slash) : fields[1], "\n");
        return;
    }
}

function stdin_first_dns_a_address() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) != null) {
            print(line, "\n");
            return;
        }
    }
}

function stdin_first_dns_aaaa_address() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^[0-9A-Fa-f:]+$/) != null) {
            print(line, "\n");
            return;
        }
    }
}

function stdin_first_nslookup_address() {
    for (let line in split(read_stdin(), "\n")) {
        line = as_string(line);
        if (match(line, /^Address[ \t]*[0-9]*:[ \t]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) == null &&
            match(line, /^Address[ \t]*[0-9]*:[ \t]*[0-9A-Fa-f:]+$/) == null)
            continue;

        let fields = split(trim(line), /[ \t]+/);
        if (length(fields) > 0)
            print(fields[length(fields) - 1], "\n");
        return;
    }
}

function stdin_first_field() {
    let data = read_stdin();
    let newline = index(data, "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);

    if (length(fields) > 0 && fields[0] != "")
        print(fields[0], "\n");
}

function array_append_string(value) {
    let result = array_or_empty(read_stdin_json());
    push(result, as_string(value));
    write_json(result);
}

function normalized_country_list() {
    write_json(runtime_urltest.normalized_country_list(read_stdin_json()));
}

function urltest_filter(mode, tags_path, names_path, countries_path, names_filter_path, regex_tags_path, countries_filter_path) {
    write_json(runtime_urltest.filter_array(
        mode,
        read_json_file(tags_path),
        read_json_file(names_path),
        read_json_file(countries_path),
        read_json_file(names_filter_path),
        read_json_file(regex_tags_path),
        read_json_file(countries_filter_path)
    ));
}

function object_nonempty_stdin() {
    let value = read_stdin_json();
    return (type(value) == "array" || type(value) == "object") && length(value) > 0;
}

let mode = ARGV[0] || "";

if (mode == "generate-config")
    generate_config(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5] || "", ARGV[6] || "");
else if (mode == "generate-config-fixture")
    generate_config_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6] || "", ARGV[7] || "");
else if (mode == "generate-list-bootstrap-config")
    generate_list_bootstrap_config(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5] || "", ARGV[6] || "", ARGV[7] || "", ARGV[8] || "");
else if (mode == "generate-list-bootstrap-config-fixture") {
    use_fixture_cursor(ARGV[1]);
    urltest_seed_file = "";
    generate_list_bootstrap_config(ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6] || "", ARGV[7] || "", ARGV[8] || "", ARGV[9] || "");
}
else if (mode == "stdin-length")
    stdin_length();
else if (mode == "stdin-contains")
    exit(stdin_contains(ARGV[1]) ? 0 : 1);
else if (mode == "stdin-regex-matches")
    exit(stdin_regex_matches(ARGV[1]) ? 0 : 1);
else if (mode == "csv-to-json-array")
    csv_to_json_array(ARGV[1]);
else if (mode == "ip-addr-first-inet4")
    ip_addr_first_inet4();
else if (mode == "stdin-first-dns-a-address")
    stdin_first_dns_a_address();
else if (mode == "stdin-first-dns-aaaa-address")
    stdin_first_dns_aaaa_address();
else if (mode == "stdin-first-nslookup-address")
    stdin_first_nslookup_address();
else if (mode == "stdin-first-field")
    stdin_first_field();
else if (mode == "array-append-string")
    array_append_string(ARGV[1]);
else if (mode == "normalized-country-list")
    normalized_country_list();
else if (mode == "urltest-filter")
    urltest_filter(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
else if (mode == "object-nonempty")
    exit(object_nonempty_stdin() ? 0 : 1);
else if (mode == "vless-encryption-error")
    print(vless_encryption_error(ARGV[1]), "\n");
else {
    warn("Usage: singbox/generator.uc <operation> ...\n");
    exit(1);
}
