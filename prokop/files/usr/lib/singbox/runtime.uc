#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let durable = require("core.durable");
let runtime_dns = require("singbox.dns");
let managed_service = require("singbox.managed_service");
let legacy_forkop = require("core.legacy_forkop");
let listen_address = require("singbox.listen_address");

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

function sing_box_marker_is(value) {
    return file_first_line(SB_VARIANT_STATE_FILE) == as_string(value);
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

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_success(args) {
    return command_status(module_command(args)) == 0;
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
        command_from_args([ "sing-box", "-c", config_path, "check" ]) +
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
    remove_file(stage_path);
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
    if (!ensure_dir(SECTION_CACHE_DIR))
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
        if (fs.writefile(temporary, data) == null || !fs.rename(temporary, target)) {
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

function init_config(populate_nft, caches_prepared, no_refresh, prepared_deferred_sections, stage_path) {
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

    let temp_config = temp_path();
    let runtime_log = temp_path();
    if (temp_config == "" || runtime_log == "") {
        remove_files([ temp_config, runtime_log ]);
        exit(1);
    }

    let generate_status = command_status(
        module_command([
            LIB_DIR + "/singbox/generator.uc",
            "generate-config",
            temp_config,
            service_listen_address_value(settings),
            mwan3_active ? "1" : "0",
            sing_box_is_extended(sing_box_version()) ? "1" : "0",
            deferred_sections,
            sing_box_version()
        ]) + " >" + shell_quote(runtime_log) + " 2>&1"
    );
    if (SINGBOX_CONFIG_FAIL_PHASE == "generate")
        generate_status = 1;
    if (generate_status != 0) {
        let reason = generator_failure_reason(runtime_log, generate_status);
        log_message("Failed to generate sing-box configuration: " + reason, "fatal");
        remove_files([ temp_config, runtime_log ]);
        exit(1);
    }
    log_file_lines(runtime_log, "warn", "sing-box config generator: ");

    // Configuration generation must be deterministic and network-free. Missing
    // remote rule sets are represented by an empty local placeholder and are
    // refreshed only by the serialized post-start/update worker.
    if (!module_success([ RULESET_CACHE_UC, "materialize-config", temp_config, "cache-only" ])) {
        log_message("Failed to materialize remote rule sets into the persistent local cache. Aborted.", "fatal");
        remove_files([ temp_config, runtime_log ]);
        exit(1);
    }

    let check_result = SINGBOX_CONFIG_FAIL_PHASE == "check"
        ? { status: 1, reason: "injected sing-box configuration check failure" }
        : sing_box_check(temp_config, runtime_log);
    if (check_result.status != 0) {
        log_message("Generated sing-box configuration is invalid: " + check_result.reason + ". Aborted.", "fatal");
        remove_files([ temp_config, runtime_log ]);
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
        remove_files([ temp_config, runtime_log ]);
        exit(1);
    }

    if (as_string(stage_path) != "") {
        if (!ensure_parent_dir(stage_path) || !command_success_from_args([ "mv", "-f", temp_config, stage_path ])) {
            remove_file(runtime_log);
            exit(1);
        }
        remove_file(runtime_log);
        print(deferred_sections, "\n");
        return;
    }

    if (!save_config_file(temp_config, config_path)) {
        remove_files([ temp_config, runtime_log ]);
        exit(1);
    }
    if (!publish_section_cache(temp_config)) {
        log_message("Failed to publish sing-box dashboard cache", "error");
        remove_file(runtime_log);
        exit(1);
    }
    remove_file(runtime_log);
    print(deferred_sections, "\n");
}

let mode = ARGV[0] || "";

if (mode == "configure-service")
    configure_service();
else if (mode == "init-config")
    init_config(arg_bool(ARGV[1] || "1"), arg_bool(ARGV[2] || "0"), arg_bool(ARGV[3] || "0"), ARGV[4] || "", "");
else if (mode == "prepare-config-stage")
    init_config(arg_bool(ARGV[1] || "0"), arg_bool(ARGV[2] || "0"), arg_bool(ARGV[3] || "0"), ARGV[4] || "", ARGV[5] || "");
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
