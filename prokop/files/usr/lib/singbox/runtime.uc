#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let durable = require("core.durable");
let runtime_dns = require("singbox.dns");
let managed_service = require("singbox.managed_service");
let legacy_forkop = require("core.legacy_forkop");
let listen_address = require("singbox.listen_address");
let identity = require("core.process_identity");
let ipv6 = require("core.ipv6");

const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || "prokop";
// Test-only config preparation failure injection. Empty in production.
const SINGBOX_CONFIG_FAIL_PHASE = getenv("PROKOP_SINGBOX_CONFIG_FAIL_PHASE") || "";
const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || "/tmp/sing-box";
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || TMP_SING_BOX_FOLDER + "/rulesets";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || TMP_SING_BOX_FOLDER + "/subscriptions";
const RUNTIME_STATE_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const SUBSCRIPTION_UPDATE_STATE_DIR = getenv("PROKOP_SUBSCRIPTION_UPDATE_STATE_DIR") || RUNTIME_STATE_DIR + "/subscription-update";
const SUBSCRIPTION_LINKS_DIR = getenv("PROKOP_SUBSCRIPTION_LINKS_DIR") || RUNTIME_STATE_DIR + "/subscription-links";
const SUBSCRIPTION_METADATA_DIR = getenv("PROKOP_SUBSCRIPTION_METADATA_DIR") || RUNTIME_STATE_DIR + "/subscription-metadata";
const OUTBOUND_METADATA_DIR = getenv("PROKOP_OUTBOUND_METADATA_DIR") || RUNTIME_STATE_DIR + "/outbound-metadata";
const SECTION_CACHE_DIR = getenv("PROKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const RUNTIME_CACHE_FORMAT_FILE = getenv("PROKOP_RUNTIME_CACHE_FORMAT_FILE") || RUNTIME_STATE_DIR + "/cache-format";
const RUNTIME_CACHE_FORMAT = getenv("PROKOP_RUNTIME_CACHE_FORMAT") || "11";
const PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/prokop/subscription-cache";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const RULESET_CACHE_UC = LIB_DIR + "/singbox/ruleset_cache.uc";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "10";
const PENDING_RELOAD_FILE = getenv("PROKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const SERVICE_INIT = getenv("PROKOP_SERVICE_INIT") || "/etc/init.d/prokop";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || "ProkopTable";
const NFT_COMMON_SET_NAME = getenv("NFT_COMMON_SET_NAME") || "prokop_subnets";
const NFT_COMMON6_SET_NAME = getenv("NFT_COMMON6_SET_NAME") || "prokop_subnets6";
const NFT_PORT_SET_NAME = getenv("NFT_PORT_SET_NAME") || "prokop_ports";
const NFT_IP_PORT_SET_NAME = getenv("NFT_IP_PORT_SET_NAME") || "prokop_ip_ports";
const NFT_IP_PORT6_SET_NAME = getenv("NFT_IP_PORT6_SET_NAME") || "prokop_ip6_ports";
const NFT_INTERFACE_SET_NAME = getenv("NFT_INTERFACE_SET_NAME") || "prokop_interfaces";
const NFT_LOCALV4_SET_NAME = getenv("NFT_LOCALV4_SET_NAME") || "localv4";
const NFT_LOCALV6_SET_NAME = getenv("NFT_LOCALV6_SET_NAME") || "localv6";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || "0x04000000";
const SB_SERVICE_MIXED_INBOUND_ADDRESS = getenv("SB_SERVICE_MIXED_INBOUND_ADDRESS") || "127.0.0.1";
const SB_SERVICE_MIXED_INBOUND_PORT = getenv("SB_SERVICE_MIXED_INBOUND_PORT") || "4534";
const LIST_BOOTSTRAP_DIR = getenv("PROKOP_LIST_BOOTSTRAP_DIR") || RUNTIME_STATE_DIR + "/list-bootstrap";
// Tenths of a second the temporary sing-box gets to start listening.
const LIST_BOOTSTRAP_START_WAIT = int(getenv("PROKOP_LIST_BOOTSTRAP_START_WAIT") || "300");
const SB_VARIANT_STATE_FILE = getenv("SB_VARIANT_STATE_FILE") || "/etc/prokop/sing-box-variant";
const SB_VERSION_STATE_FILE = getenv("SB_VERSION_STATE_FILE") || "/etc/prokop/sing-box-version";
const SB_MANAGED_SERVICE_MARKER = getenv("SB_MANAGED_SERVICE_MARKER") || "Prokop managed sing-box service for binary variants";
// The marker Forkop wrote into the same service: such a service is Prokop's
// once Forkop's package is gone (components/action.uc, service/package.uc).
const SB_LEGACY_MANAGED_SERVICE_MARKER = legacy_forkop.SING_BOX_MANAGED_MARKER;

function as_string(value) {
    return value == null ? "" : "" + value;
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

function command_env(assignments) {
    let parts = [];
    for (let name, value in assignments)
        push(parts, name + "=" + shell_quote(value));
    return join(" ", parts);
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", name ]);
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function remove_files(paths) {
    for (let path in paths)
        if (as_string(path) != "")
            remove_file(path);
}

function file_first_line(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return "";
    let newline = index(data, "\n");
    return trim(newline >= 0 ? substr(data, 0, newline) : data);
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
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

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "true" || value == "1" || value == "yes" || value == "on";
}

function bool_option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    return value == null ? !!fallback : arg_bool(value);
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, 0, slash) : "";
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function ensure_parent_dir(path) {
    let dir = parent_dir(path);
    return dir == "" || dir == "." || ensure_dir(dir);
}

function temp_path() {
    return trim(command_output_from_args([ "mktemp" ]));
}

function md5_file(path) {
    let line = trim(command_output_from_args([ "md5sum", as_string(path) ]));
    return length(line) >= 32 ? substr(line, 0, 32) : "";
}

function first_line_last_field(value) {
    value = as_string(value);
    let newline = index(value, "\n");
    let line = trim(newline >= 0 ? substr(value, 0, newline) : value);
    let fields = split(line, /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[length(fields) - 1]) : "";
}

function sing_box_version_output() {
    return command_exists("sing-box") ? command_output_from_args([ "sing-box", "version" ]) : "";
}

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_success(args) {
    return command_status(module_command(args)) == 0;
}

// The compressed variant is installed with every sing-box package removed
// (components/action.uc). A package installed since, by hand or from LuCI
// Software, replaced its binary: the marker then describes a binary that is
// gone, with its version and its features (A11).
let sing_box_package_present_cache = null;

function sing_box_package_present() {
    if (sing_box_package_present_cache == null) {
        sing_box_package_present_cache = false;
        for (let name in [ "sing-box-extended", "sing-box-tiny", "sing-box" ])
            if (module_success([ LIB_DIR + "/core/packages.uc", "installed", name ])) {
                sing_box_package_present_cache = true;
                break;
            }
    }
    return sing_box_package_present_cache;
}

function sing_box_marker_is(value) {
    let marker = file_first_line(SB_VARIANT_STATE_FILE);
    if (marker != as_string(value))
        return false;
    return marker != "extended-compressed" || !sing_box_package_present();
}

function sing_box_version_state() {
    return file_first_line(SB_VERSION_STATE_FILE);
}

// The variant marker and the version of a binary variant are written on a
// component install and read on every start: replaced whole, read back and
// flushed before and after the rename (core/durable.uc), never truncated
// and rewritten in place, where a power cut left them empty.
function write_state_marker(path, text) {
    return ensure_parent_dir(path) && durable.durable_replace(path + ".tmp." + as_string(fs.readlink("/proc/self")), path, text);
}

function sing_box_write_version_state(version) {
    version = as_string(version);
    return version != "" && write_state_marker(SB_VERSION_STATE_FILE, version + "\n");
}

function sing_box_clear_version_state() {
    remove_file(SB_VERSION_STATE_FILE);
    return true;
}

function sing_box_restore_version_state(version) {
    version = as_string(version);
    return version != "" ? sing_box_write_version_state(version) : sing_box_clear_version_state();
}

function sing_box_variant_marker() {
    return file_first_line(SB_VARIANT_STATE_FILE);
}

function sing_box_write_variant_marker(variant) {
    variant = as_string(variant);
    return variant != "" && write_state_marker(SB_VARIANT_STATE_FILE, variant + "\n");
}

function sing_box_clear_variant_marker() {
    remove_file(SB_VARIANT_STATE_FILE);
    return true;
}

function sing_box_restore_variant_marker(variant) {
    variant = as_string(variant);
    return variant != "" ? sing_box_write_variant_marker(variant) : sing_box_clear_variant_marker();
}

function sing_box_version() {
    if (!command_exists("sing-box"))
        return "";
    if (sing_box_marker_is("extended-compressed"))
        return sing_box_version_state();
    return first_line_last_field(sing_box_version_output());
}

function sing_box_version_is_extended(value) {
    return index(as_string(value), "extended") >= 0;
}

function sing_box_is_extended(value) {
    value = as_string(value);
    if (value == "" && command_exists("sing-box") && (sing_box_marker_is("extended-compressed") || sing_box_marker_is("extended")))
        return true;

    return sing_box_version_is_extended(value != "" ? value : sing_box_version());
}

function output_has_build_tag(output, tag) {
    tag = as_string(tag);
    if (tag == "")
        return false;

    for (let item in split(trim(replace(as_string(output), /[,: \t\r\n]+/g, " ")), " "))
        if (as_string(item) == tag)
            return true;
    return false;
}

function sing_box_supports_tailscale(version, version_output) {
    version = as_string(version);
    version_output = as_string(version_output);

    if (command_exists("sing-box") && sing_box_marker_is("extended-compressed"))
        return true;
    if (sing_box_is_extended(version))
        return true;
    if (version_output != "")
        return output_has_build_tag(version_output, "with_tailscale");
    return output_has_build_tag(sing_box_version_output(), "with_tailscale");
}

function sing_box_package_installed(name) {
    return module_success([ LIB_DIR + "/core/packages.uc", "installed", as_string(name) ]);
}

function sing_box_is_tiny(version, version_output) {
    version = as_string(version);
    version_output = as_string(version_output);

    if (command_exists("sing-box") && sing_box_marker_is("extended-compressed"))
        return false;
    if (sing_box_is_extended(version != "" ? version : sing_box_version()))
        return false;
    if (sing_box_package_installed("sing-box-tiny"))
        return true;
    if (!sing_box_marker_is("tiny"))
        return false;
    return !sing_box_supports_tailscale(version, version_output);
}

function sing_box_variant() {
    let version = "";

    if (!command_exists("sing-box"))
        return "not-installed";
    if (sing_box_marker_is("extended-compressed"))
        return "extended-compressed";

    version = sing_box_version();
    if (sing_box_is_extended(version))
        return sing_box_marker_is("extended-compressed") ? "extended-compressed" : "extended";
    if (sing_box_is_tiny(version, ""))
        return "tiny";
    return "stable";
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "prokop", "[" + level + "] " + as_string(message) ]);
}

function module_env_capture(env, args) {
    let output_path = temp_path();
    if (output_path == "")
        return { status: 1, output: "" };

    let status = command_status(command_env(env) + " " + module_command(args) + " >" + shell_quote(output_path) + " 2>&1");
    let output = as_string(fs.readfile(output_path) || "");
    remove_file(output_path);
    return { status, output };
}

function uci_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function uci_path(config, section, key) {
    return as_string(config) + "." + as_string(section) + "." + as_string(key);
}

function uci_get_option(config, section, key) {
    return trim(uci_core.get(uci_path(config, section, key)));
}

function ensure_sing_box_main_section() {
    if (uci_core.exists("sing-box.main"))
        return true;
    return uci_core.set_section("sing-box.main", "sing-box");
}

function uci_set_option(config, section, key, value) {
    if (!uci_core.exists(as_string(config) + "." + as_string(section)))
        return false;
    return uci_core.set(uci_path(config, section, key), value);
}

function uci_commit(config) {
    return uci_core.commit(config);
}

function managed_service_installed() {
    let data = fs.readfile("/etc/init.d/sing-box");
    return data != null && (index(as_string(data), SB_MANAGED_SERVICE_MARKER) >= 0 ||
        (index(as_string(data), SB_LEGACY_MANAGED_SERVICE_MARKER) >= 0 && !legacy_forkop.installed()));
}

function sing_box_compressed_marker_set() {
    return trim(as_string(fs.readfile(SB_VARIANT_STATE_FILE) || "")) == "extended-compressed";
}

// Every start installs the script (singbox/managed_service.uc): written
// only when it differs, stale copies of it removed.
function install_managed_service_script() {
    return managed_service.install();
}

function remove_managed_service_script() {
    if (!managed_service_installed())
        return;

    command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
    command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    remove_file("/etc/init.d/sing-box");
}

function disable_service_config() {
    if (!ensure_sing_box_main_section())
        return;
    uci_set_option("sing-box", "main", "enabled", "0");
    uci_commit("sing-box");
}

function prepare_service_disabled() {
    disable_service_config();
    if (file_exists("/etc/init.d/sing-box")) {
        command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
        command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    }
}

function configure_service() {
    let settings = uci_settings();

    if (sing_box_compressed_marker_set() && !install_managed_service_script()) {
        log_message("Failed to install managed sing-box service for compressed binary. Aborted.", "fatal");
        exit(1);
    }

    if (!ensure_sing_box_main_section())
        exit(1);

    let changed = false;
    if (uci_get_option("sing-box", "main", "enabled") != "1") {
        if (!uci_set_option("sing-box", "main", "enabled", "1"))
            exit(1);
        changed = true;
        log_message("sing-box service has been enabled", "info");
    }

    if (uci_get_option("sing-box", "main", "user") != "root") {
        if (!uci_set_option("sing-box", "main", "user", "root"))
            exit(1);
        changed = true;
        log_message("sing-box service user has been changed to root", "info");
    }

    let config_path = option(settings, "config_path", "");
    let conffile = uci_get_option("sing-box", "main", "conffile");
    if (conffile != config_path) {
        if (!uci_set_option("sing-box", "main", "conffile", config_path))
            exit(1);
        changed = true;
        log_message("sing-box service config path set to " + config_path, "info");
    }

    if (changed && !uci_commit("sing-box"))
        exit(1);

    if (file_exists("/etc/rc.d/S99sing-box")) {
        log_message("Disabling standalone sing-box autostart", "info");
        command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    }
}

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "components")
        return "download_components_via_proxy";
    return "";
}

function download_via_proxy_section_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy_section";
    if (purpose == "components")
        return "download_components_via_proxy_section";
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

function service_proxy_port_for_purpose(purpose) {
    return int(SB_SERVICE_MIXED_INBOUND_PORT) + (as_string(purpose || "lists") == "components" ? 1 : 0);
}

function service_proxy_address(settings, purpose) {
    return download_via_proxy_section(settings, purpose) != "" ?
        SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + service_proxy_port_for_purpose(purpose) : "";
}

// quiet: a read-only query (the service-listen-address mode, which Clash API
// requests and the support report ask) leaves syslog alone; the
// configuration generation tells about the address (UC-149).
function service_listen_address_value(settings, quiet) {
    return listen_address.service_listen_address(settings, quiet ? null : log_message);
}

function subscription_cache_env() {
    return {
        PROKOP_CONFIG_NAME: CONFIG_NAME,
        PROKOP_LIB: LIB_DIR,
        TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER,
        PROKOP_RUNTIME_STATE_DIR: RUNTIME_STATE_DIR,
        PROKOP_SUBSCRIPTION_UPDATE_STATE_DIR: SUBSCRIPTION_UPDATE_STATE_DIR,
        PROKOP_SUBSCRIPTION_LINKS_DIR: SUBSCRIPTION_LINKS_DIR,
        PROKOP_SUBSCRIPTION_METADATA_DIR: SUBSCRIPTION_METADATA_DIR,
        PROKOP_OUTBOUND_METADATA_DIR: OUTBOUND_METADATA_DIR,
        PROKOP_SECTION_CACHE_DIR: SECTION_CACHE_DIR,
        PROKOP_RUNTIME_CACHE_FORMAT_FILE: RUNTIME_CACHE_FORMAT_FILE,
        PROKOP_RUNTIME_CACHE_FORMAT: RUNTIME_CACHE_FORMAT,
        PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR: PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT,
        PROKOP_PENDING_RELOAD_FILE: PENDING_RELOAD_FILE,
        PROKOP_SERVICE_INIT: SERVICE_INIT
    };
}

function subscription_cache_capture(args) {
    let command_args = [ LIB_DIR + "/subscription/cache.uc" ];
    for (let arg in args)
        push(command_args, arg);
    return module_env_capture(subscription_cache_env(), command_args);
}

function log_lines(text, level, prefix) {
    for (let line in split(as_string(text), "\n"))
        if (trim(as_string(line)) != "")
            log_message(as_string(prefix) + as_string(line), level);
}

function last_nonblank_line(path) {
    let result = "";
    let data = as_string(fs.readfile(path) || "");
    for (let line in split(data, "\n"))
        if (trim(as_string(line)) != "")
            result = as_string(line);
    return result;
}

function generator_failure_reason(path, status) {
    let reason = last_nonblank_line(path);
    return reason != "" ? reason : "exit status " + status;
}

function log_file_lines(path, level, prefix) {
    log_lines(fs.readfile(path), level, prefix);
}

function sing_box_check(config_path, output_path) {
    let status = command_status(
        command_from_args(common.sing_box_check_args(config_path)) +
        " >" + shell_quote(output_path) + " 2>&1"
    );
    let reason = status == 0 ? "" : trim(as_string(fs.readfile(output_path) || ""));
    if (status != 0 && reason == "")
        reason = "exit status " + status;
    return { status, reason };
}

function prepare_subscription_caches(prepared, no_refresh) {
    let result = subscription_cache_capture([ "prepare-caches", "runtime", prepared ? "1" : "0", no_refresh ? "1" : "0" ]);
    if (result.status != 0) {
        log_message("Subscription caches are not ready for sing-box config generation. Aborted.", "fatal");
        log_lines(result.output, "debug", "subscription cache: ");
        return null;
    }
    return trim(result.output);
}

// The content of source_path becomes config_path, and source_path is
// consumed. It is written to a private file next to config_path, read back
// and renamed over it: config.json is the previous file or the new one,
// whole. The sources are in /tmp, config.json is on the overlay, and mv
// between them is no rename: it removes or truncates config.json and then
// copies, so a crash or a full overlay left it missing or cut short
// (UC-070). A publish that cannot complete leaves the previous file, no copy
// and the source, and logs why. What config_path already holds is not
// written again.
//
// Not flushed (core/durable.uc checked_replace): config.json is derived
// from the UCI configuration, and every start generates and publishes it
// before it starts sing-box (the standalone sing-box autostart is
// disabled), so a file that a power cut emptied is rebuilt by the next
// start. A sync would flush every filesystem (USB storage included) on
// each reload, subscription update and DNS-failover switch, and the switch
// would wait for it while DNS fails.
function publish_config_file(source_path, config_path) {
    let data = fs.readfile(source_path);
    if (data == null) {
        log_message("Cannot read " + as_string(source_path) + " to publish it as " + config_path + "; " + config_path + " was left unchanged", "error");
        return false;
    }
    if (!ensure_parent_dir(config_path)) {
        log_message("Cannot create the directory of " + config_path + "; the sing-box configuration was not published", "error");
        return false;
    }
    if (fs.readfile(config_path) !== data) {
        let staged = config_path + ".prokop-new." + as_string(fs.readlink("/proc/self"));
        // A full filesystem can take the write and keep none of it.
        if (!durable.checked_replace(staged, config_path, data, 0600)) {
            log_message(durable.dangling(config_path) ?
                config_path + " is a symlink that points to nothing (" + as_string(fs.readlink(config_path)) +
                    "); it was left as it is and the sing-box configuration was not published" :
                "Cannot write, read back or rename " + staged + " (is the overlay full?); " + config_path + " was left unchanged",
                "error");
            return false;
        }
    }
    remove_file(source_path);
    return true;
}

function save_config_file(temp_file_path, config_path) {
    // The staged file is private (mktemp, write_private_json_file), and so is
    // the published copy. A config left by an older release is narrowed too,
    // also when it is unchanged (UC-037).
    if (file_exists(config_path))
        fs.chmod(config_path, 0600);
    let current_hash = md5_file(config_path);
    let temp_hash = md5_file(temp_file_path);

    if (current_hash != temp_hash) {
        log_message("sing-box configuration changed; updating " + config_path, "info");
        return publish_config_file(temp_file_path, config_path);
    }

    log_message("sing-box configuration is unchanged", "info");
    remove_file(temp_file_path);
    return true;
}

function discard_config_stage(stage_path) {
    stage_path = as_string(stage_path);
    remove_files([ stage_path, stage_path + ".fingerprint" ]);
    command_success_from_args([ "rm", "-rf", stage_path + ".section-cache" ]);
    return true;
}

function restore_config_stage(backup_path) {
    let config_path = option(uci_settings(), "config_path", "");
    backup_path = as_string(backup_path);
    return config_path != "" && file_exists(backup_path) &&
        publish_config_file(backup_path, config_path);
}

function publish_section_cache(temp_config_path) {
    let source_dir = as_string(temp_config_path) + ".section-cache";
    let entries = fs.lsdir(source_dir);
    if (type(entries) != "array")
        return true;
    // Section caches hold full share links: keep them away from other users.
    if (!ensure_dir(SECTION_CACHE_DIR) || !fs.chmod(SECTION_CACHE_DIR, 0700))
        return false;

    for (let entry in entries) {
        entry = as_string(entry);
        if (match(entry, /^[A-Za-z0-9_-]+\.json$/) == null)
            continue;

        let source = source_dir + "/" + entry;
        let data = fs.readfile(source);
        if (data == null)
            return false;

        let target = SECTION_CACHE_DIR + "/" + entry;
        let temporary = target + ".tmp";
        if (fs.writefile(temporary, data) == null || !fs.chmod(temporary, 0600) ||
            !fs.rename(temporary, target)) {
            remove_file(temporary);
            return false;
        }
        remove_file(source);
    }

    command_success_from_args([ "rmdir", source_dir ]);
    return true;
}

function commit_config_stage(stage_path, backup_path) {
    let config_path = option(uci_settings(), "config_path", "");
    stage_path = as_string(stage_path);
    backup_path = as_string(backup_path);
    if (config_path == "" || !file_exists(stage_path) || backup_path == "")
        return false;

    // The reload lifecycle creates this backup before the first live config
    // change. It is consumed only after nft and sing-box reach the same state.
    // cp -p keeps the mode, so the live config is narrowed first (UC-037).
    fs.chmod(config_path, 0600);
    if (!command_success_from_args([ "cp", "-p", config_path, backup_path ]))
        return false;
    if (!save_config_file(stage_path, config_path))
        return false;
    if (!publish_section_cache(stage_path))
        return false;
    return true;
}

function replace_dns_server(config, replacement) {
    let servers = array_or_empty(object_or_empty(config.dns).servers);
    for (let i = 0; i < length(servers); i++) {
        if (as_string(object_or_empty(servers[i]).tag) == as_string(replacement.tag)) {
            servers[i] = replacement;
            return true;
        }
    }
    return false;
}

function patch_dns_config(state_path) {
    let settings = uci_settings();
    let candidate_state = common.read_json_file(state_path);
    let expected = runtime_dns.state_template(settings);
    if (!runtime_dns.state_matches(expected, candidate_state)) {
        log_message("DNS failover state does not match the current UCI configuration", "warn");
        exit(2);
    }

    let config_path = option(settings, "config_path", "");
    let config = common.read_json_file(config_path);
    if (config_path == "" || type(config) != "object") {
        log_message("Cannot read the current sing-box configuration for DNS failover", "error");
        exit(1);
    }

    let main = runtime_dns.server_config(settings, candidate_state);
    let bootstrap = runtime_dns.bootstrap_config(settings, candidate_state);
    if (main.unsupported || !replace_dns_server(config, main) || !replace_dns_server(config, bootstrap)) {
        log_message("Cannot locate or build canonical DNS servers for failover", "error");
        exit(1);
    }

    // The backup is what a failed switch publishes again: read back, since a
    // full /tmp can take the write and keep none of it.
    let current = fs.readfile(config_path);
    let backup_path = temp_path();
    let temp_config = temp_path();
    if (current == null || backup_path == "" || temp_config == "" ||
        fs.writefile(backup_path, current) == null || fs.readfile(backup_path) !== current ||
        !common.write_private_json_file(temp_config, config)) {
        remove_files([ backup_path, temp_config ]);
        exit(1);
    }

    let check_log = temp_path();
    let check_result = check_log == ""
        ? { status: 1, reason: "unable to create check output file" }
        : sing_box_check(temp_config, check_log);
    if (check_result.status != 0) {
        log_message("DNS failover produced an invalid sing-box configuration: " + check_result.reason, "error");
        remove_files([ backup_path, temp_config, check_log ]);
        exit(1);
    }
    remove_file(check_log);

    let changed = md5_file(config_path) != md5_file(temp_config);
    // The failover worker tries again on its next check: a candidate left in
    // /tmp on each failed try would stay in RAM.
    if (!save_config_file(temp_config, config_path)) {
        remove_files([ backup_path, temp_config ]);
        exit(1);
    }

    if (!changed) {
        remove_file(backup_path);
        print("0\n");
        return;
    }

    print("1\t", backup_path, "\n");
}

function restore_dns_config(backup_path) {
    let config_path = option(uci_settings(), "config_path", "");
    if (config_path == "" || !file_exists(backup_path))
        return false;
    return publish_config_file(backup_path, config_path);
}

// B6: a restart checks a staged configuration while the old runtime still
// serves, and its start used to generate, materialize and check the same
// configuration again. The start now publishes that checked stage instead,
// but only when everything a generation reads is what the precheck's
// generation read: the Prokop UCI package, the generator's arguments and
// environment, every file and cache it or the rule-set materializer reads,
// the files the configuration names, the sing-box binary and Prokop's own
// code. Both fingerprints come from generation_inputs_fingerprint; any
// difference, unreadable input or damaged stage generates again as before.
const STAGE_FINGERPRINT_FORMAT = "1";
const URLTEST_SEED_FILE = getenv("PROKOP_URLTEST_SEED_FILE") || RUNTIME_STATE_DIR + "/urltest-seed";
// As singbox/ruleset_cache.uc resolves them.
const RULESET_CACHE_DIR = getenv("PROKOP_RULESET_CACHE_DIR") || "/etc/prokop/ruleset-cache";
const RULESET_CACHE_MANIFEST = getenv("PROKOP_RULESET_CACHE_MANIFEST") || RULESET_CACHE_DIR + "/manifest.json";
const PERSISTENT_LIST_CACHE_DIR = getenv("PROKOP_PERSISTENT_LIST_CACHE_DIR") || "/etc/prokop/list-cache";
const RULESET_RUNTIME_CACHE_DIR = getenv("PROKOP_RULESET_RUNTIME_CACHE_DIR") || "/tmp/sing-box/ruleset-cache";
const RULESET_RUNTIME_MANIFEST = getenv("PROKOP_RULESET_RUNTIME_MANIFEST") || "/var/run/prokop/ruleset-cache-runtime.json";

function stage_fingerprint_path(stage_path) {
    return as_string(stage_path) + ".fingerprint";
}

// The generator marks a generation that asked nothing of the network (no
// server country lookup): only its result is a function of the files.
function generation_offline_marker(config_path) {
    return as_string(config_path) + ".offline";
}

// Kernel and device files are never read: only their kind is recorded.
function fingerprint_readable_path(path) {
    return match(path, /^\/(proc|sys|dev)(\/|$)/) == null;
}

// A file as stat sees it: a rewrite is a new inode or a new ctime.
function fingerprint_stat_signature(path, stat) {
    return join(":", [ "stat", path, stat.inode, stat.size, stat.mtime, stat.ctime ]);
}

// One entry per file under path, directories descended in name order:
// [ path, null ] for a regular file whose content is hashed (by_stat: whose
// stat signature is taken), [ path, kind ] for anything else. Returns false
// when a directory cannot be listed.
function fingerprint_collect(path, entries, recurse, depth, by_stat) {
    path = as_string(path);
    let stat = fs.stat(path);
    if (stat == null) {
        push(entries, [ path, "missing" ]);
        return true;
    }
    if (stat.type == "file" && fingerprint_readable_path(path)) {
        push(entries, [ path, by_stat ? fingerprint_stat_signature(path, stat) : null ]);
        return true;
    }
    if (stat.type != "directory" || !recurse || !fingerprint_readable_path(path)) {
        push(entries, [ path, stat.type ]);
        return true;
    }
    if (depth > 8)
        return false;
    let names = fs.lsdir(path);
    if (type(names) != "array")
        return false;
    push(entries, [ path, "directory" ]);
    for (let name in sort(names))
        if (!fingerprint_collect(path + "/" + name, entries, true, depth + 1, by_stat))
            return false;
    return true;
}

// The md5 of every [ path, null ] entry, filled in; false when md5sum fails
// on any of them.
function fingerprint_hash_entries(entries) {
    let pending = [];
    for (let i = 0; i < length(entries); i++)
        if (entries[i][1] == null)
            push(pending, i);
    for (let start = 0; start < length(pending); start += 64) {
        let batch = slice(pending, start, start + 64);
        let args = [ "md5sum", "--" ];
        for (let i in batch)
            push(args, entries[i][0]);
        let lines = filter(split(command_output_from_args(args), "\n"), (line) => line != "");
        if (length(lines) != length(batch))
            return false;
        for (let n = 0; n < length(batch); n++) {
            let line = lines[n];
            if (match(line, /^[0-9a-f]{32}  /) == null || substr(line, 34) != entries[batch[n]][0])
                return false;
            entries[batch[n]][1] = substr(line, 0, 32);
        }
    }
    return true;
}

// Absolute paths a UCI value names (a local list, a certificate, ...).
function fingerprint_uci_paths(value, paths) {
    if (type(value) == "array") {
        for (let item in value)
            fingerprint_uci_paths(item, paths);
        return;
    }
    for (let word in split(as_string(value), /[ \t\r\n,]+/))
        if (length(word) > 1 && substr(word, 0, 1) == "/" && index(paths, word) < 0)
            push(paths, word);
}

function generation_inputs_fingerprint(generator_args) {
    let inputs = {
        format: STAGE_FINGERPRINT_FORMAT,
        generator: generator_args,
        env: [],
        uci: [],
        ipv6: ipv6.available(),
        sing_box: "",
        files: []
    };

    let environment = getenv();
    for (let name in sort(keys(environment)))
        push(inputs.env, [ name, environment[name] ]);

    // Read again, as the generator process read it.
    uci_core.refresh(CONFIG_NAME);
    let uci_paths = [];
    for (let name in uci_core.all_sections(CONFIG_NAME)) {
        let section = uci_core.get_all(CONFIG_NAME, name);
        push(inputs.uci, section);
        for (let key, value in object_or_empty(section))
            if (substr(key, 0, 1) != ".")
                fingerprint_uci_paths(value, uci_paths);
    }
    if (length(inputs.uci) == 0)
        return "";

    // The sing-box binary (tens of megabytes) and Prokop's own code are
    // identified by their files rather than read: an upgrade or an edit is a
    // new inode or a new ctime.
    let binary = trim(command_output("command -v sing-box 2>/dev/null"));
    let binary_stat = binary != "" ? fs.stat(binary) : null;
    if (binary_stat != null)
        inputs.sing_box = fingerprint_stat_signature(binary, binary_stat);
    if (!fingerprint_collect(LIB_DIR, inputs.files, true, 0, true))
        return "";

    let config_path = option(uci_settings(), "config_path", "");
    let trees = [
        SECTION_CACHE_DIR,
        TMP_SUBSCRIPTION_FOLDER,
        TMP_RULESET_FOLDER,
        SUBSCRIPTION_LINKS_DIR,
        SUBSCRIPTION_METADATA_DIR,
        OUTBOUND_METADATA_DIR,
        PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        RULESET_CACHE_DIR,
        PERSISTENT_LIST_CACHE_DIR,
        RULESET_RUNTIME_CACHE_DIR
    ];
    let files = [
        config_path,
        RUNTIME_CACHE_FORMAT_FILE,
        PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        RULESET_CACHE_MANIFEST,
        RULESET_RUNTIME_MANIFEST,
        runtime_dns.DNS_FAILOVER_STATE_FILE,
        URLTEST_SEED_FILE,
        SB_VARIANT_STATE_FILE,
        SB_VERSION_STATE_FILE
    ];
    for (let path in trees)
        if (as_string(path) != "" && !fingerprint_collect(path, inputs.files, true, 0))
            return "";
    for (let path in [ ...files, ...uci_paths ])
        if (as_string(path) != "")
            fingerprint_collect(path, inputs.files, false, 0);
    if (!fingerprint_hash_entries(inputs.files))
        return "";

    // Kept as a digest: the inputs hold the UCI secrets.
    let path = temp_path();
    if (path == "")
        return "";
    let digest = fs.writefile(path, sprintf("%J", inputs)) != null ? md5_file(path) : "";
    remove_file(path);
    return digest;
}

// The files the configuration itself names (local rule sets, certificate
// and key files), outside the sing-box cache file it writes while it runs.
function config_named_paths(value, paths, key) {
    if (type(value) == "object") {
        for (let name, item in value)
            if (name != "experimental")
                config_named_paths(item, paths, name);
    }
    else if (type(value) == "array") {
        for (let item in value)
            config_named_paths(item, paths, key);
    }
    else if (type(value) == "string" && match(as_string(key), /path$/) != null &&
        substr(value, 0, 1) == "/" && index(paths, value) < 0)
        push(paths, value);
}

// What the checked stage is: its configuration, its section caches and the
// files its configuration names, each with its md5. null when any of it
// cannot be read.
function stage_contents(stage_path) {
    let config = common.read_json_file(stage_path);
    if (type(config) != "object")
        return null;
    let entries = [];
    if (!fingerprint_collect(stage_path, entries, false, 0) ||
        !fingerprint_collect(stage_path + ".section-cache", entries, true, 0))
        return null;
    let named = [];
    config_named_paths(config, named, "");
    for (let path in named)
        fingerprint_collect(path, entries, false, 0);
    if (entries[0][1] != null || !fingerprint_hash_entries(entries))
        return null;
    return entries;
}

// The generator writes a candidate's section caches next to it
// (generator.uc generate-config, LC-8): a candidate that is not published
// takes them along.
function remove_generation(temp_config, others) {
    remove_files([ temp_config, ...others ]);
    if (as_string(temp_config) != "") {
        remove_file(generation_offline_marker(temp_config));
        command_success_from_args([ "rm", "-rf", temp_config + ".section-cache" ]);
    }
}

// The record a reusable stage keeps next to it: the digest of the inputs it
// was generated from and what the stage is.
function write_stage_fingerprint(stage_path, inputs) {
    let contents = stage_contents(stage_path);
    if (inputs == "" || contents == null)
        return false;
    return common.write_private_json_file(stage_fingerprint_path(stage_path),
        { format: STAGE_FINGERPRINT_FORMAT, inputs, contents });
}

// The stage as checked, from the same inputs: a stage changed, cut short or
// without its record, or inputs that differ or cannot be read, are no match.
function checked_stage_matches(stage_path, inputs) {
    let record = common.read_json_file(stage_fingerprint_path(stage_path));
    if (inputs == "" || type(record) != "object" || record.format !== STAGE_FINGERPRINT_FORMAT ||
        record.inputs !== inputs || type(record.contents) != "array")
        return false;
    let contents = stage_contents(stage_path);
    return contents != null && sprintf("%J", contents) === sprintf("%J", record.contents);
}

// stage_reusable: a stage the restart may publish instead of generating
// again (a fingerprint is recorded next to it). checked_stage: such a stage,
// published when its fingerprint still matches; otherwise discarded.
function init_config(populate_nft, caches_prepared, no_refresh, prepared_deferred_sections, stage_path, stage_reusable, checked_stage) {
    let settings = uci_settings();
    let config_path = option(settings, "config_path", "");
    if (config_path == "") {
        log_message("sing-box config path is empty. Aborted.", "fatal");
        exit(1);
    }

    let mwan3_active = module_success([ LIB_DIR + "/config/validator.uc", "mwan3-is-active" ]);
    let output_interface = common.output_network_interface(settings);
    if (mwan3_active && output_interface != "")
        log_message("mwan3 is active and Output Network Interface is set to '" + output_interface + "'; sing-box egress is pinned to this interface", "warn");
    else if (mwan3_active)
        log_message("mwan3 is active; disabling sing-box auto_detect_interface so mwan3 can control egress routing", "warn");

    let deferred_sections = trim(as_string(prepared_deferred_sections));
    if (deferred_sections == "") {
        deferred_sections = prepare_subscription_caches(caches_prepared, no_refresh);
        if (deferred_sections == null)
            exit(1);
    }

    let version = sing_box_version();
    let generator_args = [
        service_listen_address_value(settings),
        mwan3_active ? "1" : "0",
        sing_box_is_extended(version) ? "1" : "0",
        deferred_sections,
        version
    ];
    checked_stage = as_string(checked_stage);
    stage_reusable = stage_reusable && as_string(stage_path) != "" && !populate_nft;
    let inputs = stage_reusable || (checked_stage != "" && !populate_nft)
        ? generation_inputs_fingerprint(generator_args) : "";

    if (checked_stage != "") {
        if (as_string(stage_path) == "" && !populate_nft && checked_stage_matches(checked_stage, inputs)) {
            log_message("Using the sing-box configuration checked before the restart: nothing it was generated from has changed", "info");
            if (!save_config_file(checked_stage, config_path)) {
                discard_config_stage(checked_stage);
                exit(1);
            }
            if (!publish_section_cache(checked_stage)) {
                log_message("Failed to publish sing-box dashboard cache", "error");
                discard_config_stage(checked_stage);
                exit(1);
            }
            discard_config_stage(checked_stage);
            print(deferred_sections, "\n");
            return;
        }
        log_message("Generating the sing-box configuration again: the one checked before the restart no longer matches what it is generated from", "info");
        discard_config_stage(checked_stage);
    }

    let temp_config = temp_path();
    let runtime_log = temp_path();
    if (temp_config == "" || runtime_log == "") {
        remove_generation(temp_config, [ runtime_log ]);
        exit(1);
    }

    let generate_status = command_status(
        module_command([
            LIB_DIR + "/singbox/generator.uc",
            "generate-config",
            temp_config,
            ...generator_args
        ]) + " >" + shell_quote(runtime_log) + " 2>&1"
    );
    if (SINGBOX_CONFIG_FAIL_PHASE == "generate")
        generate_status = 1;
    if (generate_status != 0) {
        let reason = generator_failure_reason(runtime_log, generate_status);
        log_message("Failed to generate sing-box configuration: " + reason, "fatal");
        remove_generation(temp_config, [ runtime_log ]);
        exit(1);
    }
    log_file_lines(runtime_log, "warn", "sing-box config generator: ");

    // Configuration generation must be deterministic and network-free. Missing
    // remote rule sets are represented by an empty local placeholder and are
    // refreshed only by the serialized post-start/update worker.
    if (!module_success([ RULESET_CACHE_UC, "materialize-config", temp_config, "cache-only", config_path ])) {
        log_message("Failed to materialize remote rule sets into the persistent local cache. Aborted.", "fatal");
        remove_generation(temp_config, [ runtime_log ]);
        exit(1);
    }

    let check_result = SINGBOX_CONFIG_FAIL_PHASE == "check"
        ? { status: 1, reason: "injected sing-box configuration check failure" }
        : sing_box_check(temp_config, runtime_log);
    if (check_result.status != 0) {
        log_message("Generated sing-box configuration is invalid: " + check_result.reason + ". Aborted.", "fatal");
        remove_generation(temp_config, [ runtime_log ]);
        exit(1);
    }

    if (populate_nft && !module_success([
        LIB_DIR + "/nft/apply.uc",
        "nft-populate-runtime-sets-from-uci",
        "1",
        deferred_sections,
        NFT_TABLE_NAME,
        NFT_COMMON_SET_NAME,
        NFT_PORT_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        NFT_INTERFACE_SET_NAME,
        NFT_LOCALV4_SET_NAME,
        NFT_FAKEIP_MARK,
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME,
        NFT_LOCALV6_SET_NAME
    ])) {
        log_message("Failed to update nftables runtime sets from the generated sing-box configuration. Aborted.", "fatal");
        remove_generation(temp_config, [ runtime_log ]);
        exit(1);
    }

    if (as_string(stage_path) != "") {
        // A generation that asked the network, or that changed what it read
        // (a first urltest seed, a rebuilt list set), is not the one a start
        // would make again from the same files.
        let reusable = stage_reusable && inputs != "" &&
            fs.stat(generation_offline_marker(temp_config)) != null &&
            generation_inputs_fingerprint(generator_args) == inputs;
        remove_file(generation_offline_marker(temp_config));
        // Its section caches go with it; commit_config_stage publishes
        // them, discard_config_stage removes them.
        remove_file(stage_fingerprint_path(stage_path));
        command_success_from_args([ "rm", "-rf", stage_path + ".section-cache" ]);
        if (!ensure_parent_dir(stage_path) || !command_success_from_args([ "mv", "-f", temp_config, stage_path ]) ||
            (fs.stat(temp_config + ".section-cache") != null &&
                !command_success_from_args([ "mv", "-f", temp_config + ".section-cache", stage_path + ".section-cache" ]))) {
            remove_generation(temp_config, [ runtime_log ]);
            exit(1);
        }
        if (reusable)
            write_stage_fingerprint(stage_path, inputs);
        remove_file(runtime_log);
        print(deferred_sections, "\n");
        return;
    }

    remove_file(generation_offline_marker(temp_config));

    if (!save_config_file(temp_config, config_path)) {
        remove_generation(temp_config, [ runtime_log ]);
        exit(1);
    }
    if (!publish_section_cache(temp_config)) {
        log_message("Failed to publish sing-box dashboard cache", "error");
        remove_generation(temp_config, [ runtime_log ]);
        exit(1);
    }
    remove_file(runtime_log);
    print(deferred_sections, "\n");
}

// A9: the temporary sing-box a start runs while it downloads the first list
// generation through a rule's proxy (singbox/generator.uc
// generate_list_bootstrap_config). It listens only on the lists service
// proxy and is stopped before the real sing-box starts.
function list_bootstrap_config_path() {
    return LIST_BOOTSTRAP_DIR + "/config.json";
}

function list_bootstrap_argv() {
    return [ "sing-box", "run", "-c", list_bootstrap_config_path(), "-D", LIST_BOOTSTRAP_DIR ];
}

// In process: the waits below poll up to some hundred times, a forked
// sleep each was a process per poll.
function list_bootstrap_pause() {
    sleep(100);
}

// Stops the temporary sing-box this or an earlier start left, only when the
// recorded process still is that sing-box, and removes its files.
function list_bootstrap_stop() {
    let pid_file = LIST_BOOTSTRAP_DIR + "/sing-box.pid";
    let saved = identity.read_record(pid_file);
    let argv = list_bootstrap_argv();
    if (saved != null && identity.matches_record(saved, "sing-box", argv, true, true) != "") {
        identity.signal_record(saved, "sing-box", argv, true, "TERM");
        for (let i = 0; i < 50 && identity.matches_record(saved, "sing-box", argv, true, true) != ""; i++)
            list_bootstrap_pause();
        if (identity.matches_record(saved, "sing-box", argv, true, true) != "") {
            identity.signal_record(saved, "sing-box", argv, true, "KILL");
            for (let i = 0; i < 20 && identity.matches_record(saved, "sing-box", argv, true, true) != ""; i++)
                list_bootstrap_pause();
        }
        if (identity.matches_record(saved, "sing-box", argv, true, true) != "") {
            log_message("The temporary sing-box for the list download (pid " + saved.pid + ") did not stop", "error");
            return false;
        }
    }
    command_success_from_args([ "rm", "-rf", LIST_BOOTSTRAP_DIR ]);
    return true;
}

function list_bootstrap_fail(message, log_path) {
    log_message(message, "error");
    if (log_path != null)
        log_file_lines(log_path, "error", "temporary sing-box: ");
    list_bootstrap_stop();
    return false;
}

// Generates the temporary config of stage ("" for the lists proxy,
// "subscriptions" for the subscription download proxies), starts the
// temporary sing-box from it and waits until it listens.
function list_bootstrap_run(settings, deferred_sections, stage, label) {
    if (!ensure_dir(LIST_BOOTSTRAP_DIR) || !fs.chmod(LIST_BOOTSTRAP_DIR, 0700))
        return list_bootstrap_fail("Cannot create " + LIST_BOOTSTRAP_DIR + " for the temporary sing-box");

    let log_path = LIST_BOOTSTRAP_DIR + "/sing-box.log";
    let mwan3_active = module_success([ LIB_DIR + "/config/validator.uc", "mwan3-is-active" ]);
    let status = command_status(
        module_command([
            LIB_DIR + "/singbox/generator.uc",
            "generate-list-bootstrap-config",
            list_bootstrap_config_path(),
            service_listen_address_value(settings, true),
            mwan3_active ? "1" : "0",
            sing_box_is_extended(sing_box_version()) ? "1" : "0",
            trim(as_string(deferred_sections)),
            sing_box_version(),
            LIST_BOOTSTRAP_DIR + "/generation",
            stage
        ]) + " >" + shell_quote(log_path) + " 2>&1"
    );
    if (status != 0)
        return list_bootstrap_fail("Cannot generate the temporary sing-box configuration: " + generator_failure_reason(log_path, status));
    let check = sing_box_check(list_bootstrap_config_path(), log_path);
    if (check.status != 0)
        return list_bootstrap_fail("The temporary sing-box configuration is invalid: " + check.reason);

    let pipe = fs.popen(command_from_args(list_bootstrap_argv()) + " >" + shell_quote(log_path) +
        " 2>&1 </dev/null & echo $!", "r");
    let pid = pipe ? trim(as_string(pipe.read("all"))) : "";
    if (pipe)
        pipe.close();
    if (match(pid, /^[1-9][0-9]*$/) == null)
        return list_bootstrap_fail("Cannot start the temporary sing-box", log_path);
    if (!identity.record(LIST_BOOTSTRAP_DIR + "/sing-box.pid", pid)) {
        command_success_from_args([ "kill", "-9", pid ]);
        return list_bootstrap_fail("Cannot record the temporary sing-box process", log_path);
    }

    let argv = list_bootstrap_argv();
    for (let i = 0; i < LIST_BOOTSTRAP_START_WAIT; i++) {
        if (index(as_string(fs.readfile(log_path) || ""), "sing-box started") >= 0) {
            log_message("Started a temporary sing-box " + label, "info");
            return true;
        }
        if (identity.matches(LIST_BOOTSTRAP_DIR + "/sing-box.pid", "sing-box", argv, true, true) == "")
            break;
        list_bootstrap_pause();
    }
    return list_bootstrap_fail("The temporary sing-box " + label + " did not start", log_path);
}

function word_list_contains(value, word) {
    return index(split(trim(as_string(value)), /[ \t\r\n]+/), as_string(word)) >= 0;
}

function word_list_without(value, word) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "" && item != word)
            push(result, item);
    return join(" ", result);
}

// The rule the lists download through has no nodes yet: its subscription
// did not download directly at this start and was deferred until the
// service proxy of the rule it downloads through runs (subscription/cache.uc
// prepare_subscription_caches). The temporary sing-box serves that proxy
// first, the subscription downloads through it (only through it, never
// directly), and the sing-box stops. Without nodes the lists cannot be
// downloaded through the rule, and the start stops (fail closed): they are
// not downloaded around it.
function list_bootstrap_fetch_subscription(settings, deferred_sections, section) {
    if (!list_bootstrap_run(settings, deferred_sections, "subscriptions",
        "to download the subscription of rule " + section + " the lists download through"))
        return false;
    let result = subscription_cache_capture([ "update-section-through-list-bootstrap", section ]);
    log_lines(result.output, "debug", "subscription cache: ");
    if (!list_bootstrap_stop())
        return false;
    if (result.status != 0 && result.status != 2) {
        log_message("The subscription of rule " + section + " did not download through the rule it downloads through; " +
            "the lists download through rule " + section + ", which has no nodes", "error");
        return false;
    }
    return true;
}

// Prints the subscription rules that stay deferred for the start (the ones
// it was given less the one this bootstrap downloaded). deferred_sections
// is null when the caller did not prepare the subscription caches.
function list_bootstrap_start(deferred_sections) {
    let settings = uci_settings();
    let section = download_via_proxy_section(settings, "lists");
    if (section == "") {
        print(trim(as_string(deferred_sections)), "\n");
        return true;
    }
    if (!list_bootstrap_stop())
        return false;

    if (deferred_sections == null)
        deferred_sections = prepare_subscription_caches(true, true);
    if (deferred_sections == null)
        return list_bootstrap_fail("Subscription caches are not ready for the temporary sing-box");
    deferred_sections = trim(as_string(deferred_sections));

    if (word_list_contains(deferred_sections, section)) {
        if (!list_bootstrap_fetch_subscription(settings, deferred_sections, section))
            return false;
        deferred_sections = word_list_without(deferred_sections, section);
    }

    if (!list_bootstrap_run(settings, deferred_sections, "", "to download the lists through rule " + section))
        return false;
    print(deferred_sections, "\n");
    return true;
}

let mode = ARGV[0] || "";

if (mode == "configure-service")
    configure_service();
else if (mode == "init-config")
    init_config(arg_bool(ARGV[1] || "1"), arg_bool(ARGV[2] || "0"), arg_bool(ARGV[3] || "0"), ARGV[4] || "", "", false, ARGV[5] || "");
else if (mode == "prepare-config-stage")
    init_config(arg_bool(ARGV[1] || "0"), arg_bool(ARGV[2] || "0"), arg_bool(ARGV[3] || "0"), ARGV[4] || "", ARGV[5] || "",
        (ARGV[6] || "") == "reusable", "");
else if (mode == "commit-config-stage")
    exit(commit_config_stage(ARGV[1] || "", ARGV[2] || "") ? 0 : 1);
else if (mode == "restore-config-stage")
    exit(restore_config_stage(ARGV[1] || "") ? 0 : 1);
else if (mode == "discard-config-stage")
    exit(discard_config_stage(ARGV[1] || "") ? 0 : 1);
else if (mode == "save-config-file-fixture")
    exit(save_config_file(ARGV[1] || "", ARGV[2] || "") ? 0 : 1);
else if (mode == "publish-section-cache-fixture")
    exit(publish_section_cache(ARGV[1] || "") ? 0 : 1);
else if (mode == "check-config-fixture") {
    let result = sing_box_check(ARGV[1] || "", ARGV[2] || "");
    if (result.reason != "")
        print(result.reason, "\n");
    exit(result.status);
}
else if (mode == "generator-failure-reason-fixture")
    print(generator_failure_reason(ARGV[1] || "", int(ARGV[2] || "1")), "\n");
else if (mode == "patch-dns-config")
    patch_dns_config(ARGV[1] || "");
else if (mode == "list-bootstrap-start")
    exit(list_bootstrap_start(length(ARGV) > 1 ? ARGV[1] : null) ? 0 : 1);
else if (mode == "list-bootstrap-stop")
    exit(list_bootstrap_stop() ? 0 : 1);
else if (mode == "restore-dns-config")
    exit(restore_dns_config(ARGV[1] || "") ? 0 : 1);
else if (mode == "managed-service-installed")
    exit(managed_service_installed() ? 0 : 1);
else if (mode == "remove-managed-service-script")
    remove_managed_service_script();
else if (mode == "prepare-service-disabled")
    prepare_service_disabled();
else if (mode == "service-proxy-address")
    print(service_proxy_address(uci_settings(), ARGV[1] || "lists"), "\n");
else if (mode == "service-listen-address") {
    let address = service_listen_address_value(uci_settings(), true);
    if (address == "")
        exit(1);
    print(address, "\n");
}
else if (mode == "device-ipv4-address") {
    let address = listen_address.device_ipv4_address(ARGV[1]);
    if (address == "")
        exit(1);
    print(address, "\n");
}
else if (mode == "ip-addr-first-inet4")
    print(listen_address.ip_addr_first_inet4(fs.readfile("/dev/stdin")), "\n");
else if (mode == "version")
    print(sing_box_version(), "\n");
else if (mode == "version-output")
    print(sing_box_version_output());
else if (mode == "version-from-output")
    print(first_line_last_field(fs.readfile("/dev/stdin")), "\n");
else if (mode == "read-version-state")
    print(sing_box_version_state(), "\n");
else if (mode == "write-version-state")
    exit(sing_box_write_version_state(ARGV[1]) ? 0 : 1);
else if (mode == "clear-version-state")
    exit(sing_box_clear_version_state() ? 0 : 1);
else if (mode == "restore-version-state")
    exit(sing_box_restore_version_state(ARGV[1]) ? 0 : 1);
else if (mode == "read-variant-marker")
    print(sing_box_variant_marker(), "\n");
else if (mode == "write-variant-marker")
    exit(sing_box_write_variant_marker(ARGV[1]) ? 0 : 1);
else if (mode == "clear-variant-marker")
    exit(sing_box_clear_variant_marker() ? 0 : 1);
else if (mode == "restore-variant-marker")
    exit(sing_box_restore_variant_marker(ARGV[1]) ? 0 : 1);
else if (mode == "marker-is")
    exit(sing_box_marker_is(ARGV[1]) ? 0 : 1);
else if (mode == "is-extended")
    exit(sing_box_is_extended(ARGV[1]) ? 0 : 1);
else if (mode == "is-tiny")
    exit(sing_box_is_tiny(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "supports-tailscale")
    exit(sing_box_supports_tailscale(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "variant")
    print(sing_box_variant(), "\n");
else {
    warn("Usage: singbox/runtime.uc <operation> ...\n");
    exit(1);
}
