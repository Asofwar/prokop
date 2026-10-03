#!/usr/bin/env ucode

// VPN kill-switch for Prokop connection sections.
//
// When a protected section's traffic cannot go through Prokop (sing-box or
// Prokop stopped, crashed or not started yet), it must fail instead of
// leaving through WAN. The protection is deliberately independent of the
// Prokop runtime:
//
//  * nftables: a separate table rendered from the live ProkopTable, installed
//    live and saved under STATE_DIR. fw4 loads the saved policy on every
//    firewall start/reload through the loader the prokop package installs
//    in ruleset-post, so it survives a Prokop stop, a firewall
//    reload/restart and a reboot, but never the package: without the loader
//    (package removal, a downgrade to a release without the kill-switch, a
//    sysupgrade to an image without Prokop) the saved policy is inert
//    (UC-191). It rejects forwarded client traffic that matches a protected
//    section in Prokop's own first-match order, plus any FakeIP destination.
//  * DNS: protected domains are answered locally (NXDOMAIN) by dnsmasq
//    whenever dnsmasq does not forward to sing-box; dns/apply.uc switches the
//    servers file on every configure/restore. A section may exempt its
//    excluded devices (D-23): while Prokop is stopped they resolve through
//    resolvers of their own, every other client keeps the block list.
//
// Only a successful Prokop start/reload refreshes the policy. A failed one,
// a stop or a missing runtime keep the last applied protection. Removing it
// takes an explicit "disable" or unchecking the option on every section.
//
// A router migrated from the product before the rename (core/legacy_forkop.uc)
// keeps that product's kill-switch until this one takes over: its nft table
// and fw4 include, and dnsmasq's servers file under its state directory. The
// first successful sync after the old package is gone (armed, or definitively
// nothing to protect) removes them, switches the servers file in the same
// dhcp commit and dnsmasq restart, and only then deletes the old state
// directory. "disable" lifts them too.

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");
let singbox_constants = require("singbox.constants");
let constants = require("core.constants");
let runtime_lock = require("core.runtime_lock");
let durable = require("core.durable");
let legacy = require("core.legacy_forkop");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let option = common.option;
let bool_option = common.bool_option;

function constant_value(name, fallback) {
    let value = constants[name];
    return value == null ? as_string(fallback) : as_string(value);
}

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || constant_value("PROKOP_CONFIG_NAME", "prokop");
const RUNTIME_STATE_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const LIVE_TABLE = constant_value("NFT_TABLE_NAME", "ProkopTable");
const KS_TABLE = constant_value("KILLSWITCH_NFT_TABLE", "ProkopKillswitch");
const STATE_DIR = constant_value("KILLSWITCH_STATE_DIR", "/etc/prokop/killswitch");
const NFT_POLICY = constant_value("KILLSWITCH_NFT_POLICY", STATE_DIR + "/policy.nft");
const NFT_LOADER = constant_value("KILLSWITCH_NFT_LOADER", "/usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft");
// The first kill-switch build saved the policy as an unguarded fw4 include
// that outlived the package; it is only ever removed (or adopted once).
const LEGACY_NFT_INCLUDE = constant_value("KILLSWITCH_NFT_INCLUDE", "/usr/share/nftables.d/ruleset-post/90-prokop-killswitch.nft");
const CACHE_DIR = constant_value("KILLSWITCH_CACHE_DIR", "/tmp/prokop-killswitch");
const FAKEIP_RANGE = constant_value("SB_FAKEIP_INET4_RANGE", "198.18.0.0/15");
const FAKEIP6_RANGE = constant_value("SB_FAKEIP_INET6_RANGE", "fc00::/18");
const DNS_BLOCKED_FILE = STATE_DIR + "/dns-blocked.servers";
// The standby resolver's: the names of every VPN section (UC-211). It can
// hold every name of large lists and changes with them; every refresh
// regenerates it, so it is kept in RAM, not on flash. Until the first
// refresh after a boot the standby blocks the protected names.
const STANDBY_BLOCKED_FILE = CACHE_DIR + "/standby-blocked.servers";
// dnsmasq reads it (dns/apply.uc keeps it empty while it forwards to sing-box).
const DNS_SERVERS_FILE = STATE_DIR + "/dnsmasq.servers";
// D-23: a section with this option lets its excluded devices resolve its
// names while Prokop is stopped. The block list dnsmasq reads is shared by
// all clients, so they get resolvers of their own: groups of excluded
// addresses with the block list that applies to them, kept as a difference
// to the shared one (on flash, like it), one standby dnsmasq per group, and
// a redirect of exactly those addresses' DNS to it.
const EXEMPT_OPTION = "kill_switch_dns_exempt";
const EXEMPT_FILE = STATE_DIR + "/dns-exempt.json";
const EXEMPT_FORMAT = 1;
const EXEMPT_PORT_BASE = int(constant_value("KILLSWITCH_EXEMPT_PORT", "18055"));
// Groups beyond it stay with the shared block list (fail closed).
const EXEMPT_MAX_GROUPS = 4;
// Answered by the resolver of a group with the configuration it was
// generated for and by no other (RFC 6761: never a real name).
const EXEMPT_PROBE_ZONE = "exempt.prokop.invalid";
// The input chain that lets only redirected DNS reach those resolvers.
const EXEMPT_GUARD_CHAIN = "ks_exempt_guard";
// A resolver that answered is probed again only every this many watcher
// passes; tests set it to 1.
const EXEMPT_PROBE_PASSES = int(getenv("PROKOP_KILLSWITCH_EXEMPT_PROBE_PASSES") || "5");
const DNSMASQ_INIT = getenv("DNSMASQ_INIT") || "/etc/init.d/dnsmasq";
// The dhcp configuration and the uci CLI an edit of it goes through, as in
// dns/apply.uc (core/uci.uc session).
const DNSMASQ_CONFIG_FILE = getenv("PROKOP_DNSMASQ_CONFIG_FILE") || "/etc/config/dhcp";
const UCI_CLI = getenv("PROKOP_UCI_CLI") || "uci";
const DNSMASQ_SERVERSFILE_OPTION = "dhcp.@dnsmasq[0].serversfile";
// The package file this process runs from.
const OWNER_FILE = sourcepath() || LIB_DIR + "/killswitch/runtime.uc";
const STATE_FILE = STATE_DIR + "/state.json";
// The time and reason of the last sync and the time of the last error
// change on every sync; they live in RAM so that state.json on flash
// changes only with the protection (UC-212).
const STATE_TIMES_FILE = RUNTIME_STATE_DIR + "/killswitch-state.json";
const STATE_TIMES = [ "updated_at", "reason", "last_error_at" ];
const LOCK_DIR = RUNTIME_STATE_DIR + "/killswitch.lock";
const NFT_UC = LIB_DIR + "/nft/apply.uc";
const DNS_UC = LIB_DIR + "/dns/apply.uc";
const SING_BOX_BIN = getenv("PROKOP_SING_BOX_BIN") || "sing-box";
const KILLSWITCH_INIT = getenv("PROKOP_KILLSWITCH_INIT") || "/etc/init.d/prokop-killswitch";
const STANDBY_PORT = constant_value("KILLSWITCH_STANDBY_PORT", "18054");
const SB_DNS_ADDRESS = constant_value("SB_DNS_INBOUND_ADDRESS", "127.0.0.42");
const SB_PROBE_DOMAIN = constant_value("FAKEIP_TEST_DOMAIN", "fakeip.podkop.fyi");
const DNS_CHAIN = "ks_dns";
const RELOAD_LOCK_DIR = getenv("PROKOP_RELOAD_LOCK_DIR") || "/var/run/prokop.reload.lock";
const PENDING_RELOAD_FILE = getenv("PROKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const SERVICE_INIT = getenv("PROKOP_SERVICE_INIT") || "/etc/init.d/prokop";
const STATE_UC = LIB_DIR + "/service/state.uc";
// What the last successful start or reload applied (service/state.uc), and
// the mark of a live table that lacks the list generation of the current
// configuration until the list-content reload (service/lifecycle.uc).
const RELOAD_STATE_FILE = getenv("PROKOP_RELOAD_STATE_FILE") || RUNTIME_STATE_DIR + "/reload-state";
const RUNTIME_LISTS_PENDING_FILE = getenv("PROKOP_RUNTIME_LISTS_PENDING_FILE") || RUNTIME_STATE_DIR + "/runtime-lists.pending";
// The reload state fields the live ProkopTable is built from.
const RUNTIME_SIGNATURES = [ "nft_signature", "list_signature" ];
// Attempts, 500 ms apart, to take a held lock; tests bound it.
const LOCK_ATTEMPTS = int(getenv("PROKOP_KILLSWITCH_LOCK_ATTEMPTS") || "120");
const INTERFACE_SET = "ks_interfaces";
// 2: the policy is saved at NFT_POLICY and loaded through the package's
// loader. The first kill-switch build wrote 1 and kept only the unguarded
// include.
const STATE_FORMAT = 2;
// The pre-rename kill-switch (core/legacy_forkop.uc).
const LEGACY_TABLE = legacy.KILLSWITCH_TABLE;
const LEGACY_DNS_CHAIN = legacy.KILLSWITCH_DNS_CHAIN;
const LEGACY_INCLUDE = legacy.path(legacy.KILLSWITCH_INCLUDE);
const LEGACY_KEEP = legacy.path(legacy.KILLSWITCH_KEEP);
const LEGACY_STATE_DIR = legacy.path(legacy.KILLSWITCH_STATE_DIR);
const LEGACY_PRODUCT_STATE_DIR = legacy.path(legacy.STATE_DIR);
const LEGACY_SERVERSFILE = legacy.path(legacy.KILLSWITCH_SERVERSFILE);
const LEGACY_CACHE_DIR = legacy.path(legacy.KILLSWITCH_CACHE_DIR);
const LEGACY_SERVICE_INIT = legacy.path(legacy.KILLSWITCH_INIT);
// An automatic hand-over, and a removal of Prokop itself, never lift the old
// protection while the old package is still installed: a rollback of an
// unfinished migration leaves it to the old product. An explicit disable
// lifts it whenever the old product is not active.
const STRICT_LEGACY_REASONS = { "package removal": true, "uninstall": true };
// Test-only bounds for the watcher loop; production runs it forever.
const WATCH_ITERATIONS = int(getenv("PROKOP_KILLSWITCH_WATCH_ITERATIONS") || "0");
const WATCH_INTERVAL_MS = int(getenv("PROKOP_KILLSWITCH_WATCH_INTERVAL_MS") || "2000");

// Route-rule keys that do not narrow a rule below "every client, every port".
// Only such rules may carve an exception out of a protected domain.
const UNRESTRICTED_RULE_KEYS = {
    action: true, outbound: true, inbound: true, domain: true, domain_suffix: true,
    domain_keyword: true, domain_regex: true, rule_set: true, ip_cidr: true
};

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function run_quiet(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function capture(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return { status: 1, output: "" };
    let data = pipe.read("all");
    let status = pipe.close();
    return { status: status == null ? 1 : status, output: as_string(data) };
}

function log_message(message, level) {
    run_quiet([ "logger", "-t", "prokop", "[" + as_string(level || "info") + "] " + as_string(message) ]);
}

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in args)
        push(result, as_string(arg));
    return result;
}

function ensure_dir(path) {
    return run_quiet([ "mkdir", "-p", path ]);
}

function dirname(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash > 0 ? substr(path, 0, slash) : "/";
}

let cached_self_pid = null;

function self_pid() {
    // popen's own shell is a direct child of this ucode process.
    if (cached_self_pid == null) {
        let pipe = fs.popen("echo $PPID", "r");
        let pid = pipe ? trim(as_string(pipe.read("all"))) : "";
        if (pipe)
            pipe.close();
        cached_self_pid = match(pid, /^[0-9]+$/) != null ? pid : "0";
    }
    return cached_self_pid;
}

// What the kill-switch keeps on flash (the saved policy, the block list,
// state.json) is flushed before the rename makes it the file and again
// after it, so a power cut leaves the old or the new file, never an empty
// one (UC-212, core/durable.uc). Callers write only what changed.
function write_durable(path, content) {
    if (!ensure_dir(dirname(path)))
        return false;
    return durable.durable_replace(path + ".tmp." + self_pid(), path, as_string(content));
}

function write_atomic(path, content) {
    if (!ensure_dir(dirname(path)))
        return false;
    // Unique per writer: a second writer must never rename a file this one
    // is still writing.
    let tmp = path + ".tmp." + self_pid();
    if (fs.writefile(tmp, as_string(content)) == null)
        return false;
    if (!fs.rename(tmp, path)) {
        fs.unlink(tmp);
        return false;
    }
    return true;
}

function now() {
    return time();
}

// ---------------------------------------------------------------- config

function config_sections() {
    return uci_core.section_objects(CONFIG_NAME, "section");
}

function config_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

// core/uci reads a configuration libuci cannot load (a parse error after a
// hand edit, no cursor) as one without sections. Only one that was read can
// show that no section is protected any more; migration always keeps the
// settings section.
function config_readable() {
    return uci_core.load(CONFIG_NAME) && uci_core.exists(CONFIG_NAME + ".settings");
}

function section_protected(section) {
    section = object_or_empty(section);
    return bool_option(section, "enabled", true) &&
        connections.is_connections_action(option(section, "action", "")) &&
        bool_option(section, "kill_switch", false);
}

function protected_section_names(sections) {
    let result = [];
    for (let section in sections)
        if (section_protected(section))
            push(result, as_string(section[".name"]));
    return result;
}

// Every enabled VPN (connection) section, protected or not.
function vpn_section_names(sections) {
    let result = [];
    for (let section in sections)
        if (bool_option(section, "enabled", true) && connections.is_connections_action(option(section, "action", "")))
            push(result, as_string(section[".name"]));
    return result;
}

// Protected sections that exempt their excluded devices from the DNS block
// while Prokop is stopped (D-23).
function section_exempts_devices(section) {
    return section_protected(section) && bool_option(section, EXEMPT_OPTION, false);
}

function any_section_exempts_devices(sections) {
    for (let section in sections)
        if (section_exempts_devices(section))
            return true;
    return false;
}

// What of the configuration decides who is exempt: a change of it after the
// last refresh ends the exemption until the next one (fail closed).
function exempt_fingerprint(sections) {
    let result = [];
    for (let section in sections) {
        if (!section_exempts_devices(section))
            continue;
        let item = { name: as_string(section[".name"]) };
        for (let key in sort(keys(section)))
            if (index(key, "excluded_source_ip_cidr") == 0 || key == "conditions_text_mode")
                item[key] = section[key];
        push(result, item);
    }
    return sprintf("%J", result);
}

// ------------------------------------------------------------------- lock
//
// killswitch.lock and reload.lock follow core/runtime_lock.uc: the owner is
// this process, named by its pid and start time, so a dead owner or a reused
// pid never holds them (UC-210). Global order (service/state.uc): reload.lock
// before killswitch.lock.

let lock_attempts = LOCK_ATTEMPTS;

function acquire_dir_lock(lock_dir) {
    ensure_dir(dirname(lock_dir));
    for (let attempt = 0; attempt < lock_attempts; attempt++) {
        if (runtime_lock.acquire(lock_dir, self_pid()))
            return true;
        if (attempt + 1 < lock_attempts)
            sleep(500);
    }
    return false;
}

// init.d queues every reload that found reload.lock held; its last holder
// applies them once it lets the lock go (service/lifecycle.uc, UC-061).
function release_reload_lock(apply_pending) {
    runtime_lock.release(RELOAD_LOCK_DIR, self_pid());
    if (apply_pending && fs.stat(PENDING_RELOAD_FILE) != null)
        run_quiet(module_args(STATE_UC, [ "run-pending-reload-if-requested", PENDING_RELOAD_FILE, SERVICE_INIT ]));
}

// ------------------------------------------------------------------ state

function read_state() {
    let state = object_or_empty(common.read_json_file(STATE_FILE));
    let times = object_or_empty(common.read_json_file(STATE_TIMES_FILE));
    for (let key in STATE_TIMES)
        if (times[key] != null)
            state[key] = times[key];
    return state;
}

// Key order does not matter; the times are not compared.
function state_content(value, top) {
    if (type(value) == "array")
        return "[" + join(",", map(value, (item) => state_content(item, false))) + "]";
    if (type(value) != "object")
        return sprintf("%J", value);
    let parts = [];
    for (let key in sort(keys(value)))
        if (!top || index(STATE_TIMES, key) < 0)
            push(parts, sprintf("%J", key) + ":" + state_content(value[key], false));
    return "{" + join(",", parts) + "}";
}

function write_state(state) {
    state.format = STATE_FORMAT;
    let times = {};
    for (let key in STATE_TIMES)
        times[key] = state[key];
    write_atomic(STATE_TIMES_FILE, sprintf("%J", times) + "\n");
    let saved = common.read_json_file(STATE_FILE);
    if (type(saved) == "object" && state_content(saved, true) == state_content(state, true))
        return true;
    return write_durable(STATE_FILE, sprintf("%.2J", state) + "\n");
}

function record_error(message) {
    let state = read_state();
    state.last_error = as_string(message);
    state.last_error_at = now();
    write_state(state);
    log_message("Kill-switch: " + as_string(message), "error");
}

// -------------------------------------------------------------------- nft

function live_table_present() {
    return run_quiet([ "nft", "list", "table", "inet", LIVE_TABLE ]);
}

function ks_table_present() {
    return run_quiet([ "nft", "list", "table", "inet", KS_TABLE ]);
}

function remove_legacy_include() {
    return fs.stat(LEGACY_NFT_INCLUDE) == null || fs.unlink(LEGACY_NFT_INCLUDE);
}

// Saved and loaded at boot (fw4 through the package's loader).
function policy_saved() {
    let stat = fs.stat(NFT_POLICY);
    return stat != null && stat.size > 0;
}

// D-23: the resolvers of excluded devices listen on the router's own
// addresses. Only DNS the watcher redirected there (dnat) may reach them, so
// that no other client resolves the exempted names by asking them directly.
// Replies to their own upstream queries are not new connections.
function exempt_guard_lines() {
    let t = "inet " + KS_TABLE;
    return [
        "add chain " + t + " " + EXEMPT_GUARD_CHAIN + " { type filter hook input priority -1; policy accept; }",
        "add rule " + t + " " + EXEMPT_GUARD_CHAIN + " iifname != \"lo\" meta l4proto { tcp, udp } th dport " +
            EXEMPT_PORT_BASE + "-" + (EXEMPT_PORT_BASE + EXEMPT_MAX_GROUPS - 1) +
            " ct direction original ct status & dnat == 0 drop"
    ];
}

// exempt_guard: some protected section exempts its excluded devices.
function apply_nft_policy(exempt_guard) {
    let tmp = trim(capture([ "mktemp" ]).output);
    if (tmp == "")
        return { ok: false, error: "mktemp failed" };

    let rendered = capture(module_args(NFT_UC, [ "killswitch-render", LIVE_TABLE, KS_TABLE, tmp, FAKEIP_RANGE, FAKEIP6_RANGE ]));
    let summary = null;
    try {
        summary = json(trim(rendered.output));
    }
    catch (e) {
        summary = null;
    }
    summary = object_or_empty(summary);
    if (rendered.status != 0 || summary.ok !== true) {
        fs.unlink(tmp);
        return { ok: false, error: "nft render failed: " + (as_string(summary.error) || "unknown error") };
    }
    if (exempt_guard) {
        let policy = fs.readfile(tmp);
        if (policy == null || fs.writefile(tmp, policy + join("\n", exempt_guard_lines()) + "\n") == null) {
            fs.unlink(tmp);
            return { ok: false, error: "could not add the guard of the resolvers of excluded devices" };
        }
    }

    // A broken saved policy would take the whole firewall down on the next
    // fw4 reload, so the exact bytes that get saved are checked and applied
    // live first.
    if (!run_quiet([ "nft", "-c", "-f", tmp ])) {
        fs.unlink(tmp);
        return { ok: false, error: "rendered kill-switch policy failed nft validation" };
    }
    if (!run_quiet([ "nft", "-f", tmp ])) {
        fs.unlink(tmp);
        return { ok: false, error: "kill-switch policy could not be applied" };
    }

    let content = fs.readfile(tmp);
    fs.unlink(tmp);
    if (content == null || (fs.readfile(NFT_POLICY) != content && !write_durable(NFT_POLICY, content)))
        return { ok: false, error: "could not save " + NFT_POLICY + "; the live policy is active until the next firewall reload" };
    remove_legacy_include();

    summary.ok = true;
    return summary;
}

// The retired global guard (ForkopVpnGuard) is left in place by the package
// upgrade until this kill-switch protects the same traffic.
const LEGACY_GUARD_TABLE = "ForkopVpnGuard";

function remove_legacy_guard_table() {
    if (run_quiet([ "nft", "list", "table", "inet", LEGACY_GUARD_TABLE ]))
        run_quiet([ "nft", "delete", "table", "inet", LEGACY_GUARD_TABLE ]);
}

function remove_nft_policy() {
    let ok = true;
    if (fs.stat(NFT_POLICY) != null && !fs.unlink(NFT_POLICY))
        ok = false;
    if (!remove_legacy_include())
        ok = false;
    if (ks_table_present() && !run_quiet([ "nft", "delete", "table", "inet", KS_TABLE ]))
        ok = false;
    return ok;
}

function nft_counters() {
    let result = {};
    let listed = capture([ "nft", "-j", "list", "counters", "table", "inet", KS_TABLE ]);
    if (listed.status != 0)
        return result;
    let data = null;
    try {
        data = json(listed.output);
    }
    catch (e) {
        return result;
    }
    for (let item in array_or_empty(object_or_empty(data).nftables)) {
        let counter = object_or_empty(object_or_empty(item).counter);
        let name = as_string(counter.name);
        if (name == "" || substr(name, 0, 3) != "ks_")
            continue;
        result[substr(name, 3)] = { packets: int(counter.packets), bytes: int(counter.bytes) };
    }
    return result;
}

// -------------------------------------------------------------------- DNS

function array_of(value) {
    if (type(value) == "array")
        return value;
    return value == null ? [] : [ value ];
}

function normalize_domain(value) {
    value = lc(trim(as_string(value)));
    while (substr(value, 0, 1) == ".")
        value = substr(value, 1);
    while (length(value) > 0 && substr(value, -1) == ".")
        value = substr(value, 0, length(value) - 1);
    if (value == "" || length(value) > 253 ||
        match(value, /^[a-z0-9_-]+(\.[a-z0-9_-]+)*$/) == null)
        return null;
    return value;
}

function parent_domain(value) {
    let dot = index(value, ".");
    return dot < 0 ? null : substr(value, dot + 1);
}

function new_matchers() {
    return { suffix: [], exact: [], keyword: 0, regex: 0, inverted: 0, error: "" };
}

function merge_matchers(target, source) {
    for (let value in source.suffix)
        push(target.suffix, value);
    for (let value in source.exact)
        push(target.exact, value);
    target.keyword += source.keyword;
    target.regex += source.regex;
    target.inverted += source.inverted;
    if (source.error != "" && target.error == "")
        target.error = source.error;
}

function collect_rule_matchers(rule, acc) {
    rule = object_or_empty(rule);
    if (as_string(rule.type) == "logical") {
        for (let child in array_or_empty(rule.rules))
            collect_rule_matchers(child, acc);
        return;
    }
    let has_domains = rule.domain != null || rule.domain_suffix != null ||
        rule.domain_keyword != null || rule.domain_regex != null;
    if (rule.invert === true) {
        if (has_domains)
            acc.inverted++;
        return;
    }
    for (let value in array_of(rule.domain_suffix))
        push(acc.suffix, value);
    for (let value in array_of(rule.domain))
        push(acc.exact, value);
    acc.keyword += length(array_of(rule.domain_keyword));
    acc.regex += length(array_of(rule.domain_regex));
}

function file_md5(path) {
    let output = trim(capture([ "md5sum", path ]).output);
    let found = match(output, /^([0-9a-f]{32})/);
    return found == null ? "" : found[1];
}

function text_md5(text) {
    let tmp = trim(capture([ "mktemp" ]).output);
    if (tmp == "")
        return "";
    let md5 = fs.writefile(tmp, as_string(text)) != null ? file_md5(tmp) : "";
    fs.unlink(tmp);
    return md5;
}

function binary_ruleset(definition) {
    let format = as_string(definition.format);
    if (format != "")
        return format == "binary";
    return match(as_string(definition.path), /\.srs$/) != null;
}

let ruleset_cache_used = {};

function local_ruleset_matchers(definition) {
    let path = as_string(definition.path);
    let acc = new_matchers();
    if (path == "" || fs.stat(path) == null) {
        acc.error = "rule-set file " + path + " is missing";
        return acc;
    }
    // singbox/ruleset_cache.uc stands in an empty "empty-<hash>.json" for a
    // list that has not been downloaded yet; its real content is unknown.
    if (match(path, /(^|\/)empty-[0-9a-f]+\.json$/) != null) {
        acc.error = "rule-set " + as_string(definition.tag) + " is not downloaded yet";
        return acc;
    }

    if (!binary_ruleset(definition)) {
        let data = common.read_json_file(path);
        if (type(data) != "object") {
            acc.error = "rule-set file " + path + " is not valid JSON";
            return acc;
        }
        for (let rule in array_or_empty(data.rules))
            collect_rule_matchers(rule, acc);
        return acc;
    }

    // Decompiling a large binary list is the expensive step; cache the
    // extracted matchers by content.
    let md5 = file_md5(path);
    let cache_path = md5 != "" ? CACHE_DIR + "/" + md5 + ".json" : "";
    if (cache_path != "") {
        ruleset_cache_used[md5 + ".json"] = true;
        let cached = common.read_json_file(cache_path);
        if (type(cached) == "object" && type(cached.suffix) == "array" && type(cached.exact) == "array") {
            cached.error = "";
            return cached;
        }
    }

    ensure_dir(CACHE_DIR);
    let source = CACHE_DIR + "/decompile-" + self_pid() + ".json";
    if (!run_quiet([ SING_BOX_BIN, "rule-set", "decompile", path, "-o", source ])) {
        fs.unlink(source);
        acc.error = "could not decompile rule-set " + path;
        return acc;
    }
    let data = common.read_json_file(source);
    fs.unlink(source);
    if (type(data) != "object") {
        acc.error = "decompiled rule-set " + path + " is not valid JSON";
        return acc;
    }
    for (let rule in array_or_empty(data.rules))
        collect_rule_matchers(rule, acc);
    if (cache_path != "")
        write_atomic(cache_path, sprintf("%J", {
            suffix: acc.suffix, exact: acc.exact, keyword: acc.keyword,
            regex: acc.regex, inverted: acc.inverted
        }));
    return acc;
}

function ruleset_matchers(definitions, tag, memo) {
    if (memo[tag] != null)
        return memo[tag];
    let definition = definitions[tag];
    let acc = new_matchers();
    if (definition == null)
        acc.error = "rule-set " + tag + " is not defined";
    else if (as_string(definition.type) == "inline") {
        for (let rule in array_or_empty(definition.rules))
            collect_rule_matchers(rule, acc);
    }
    else if (as_string(definition.type) == "local")
        acc = local_ruleset_matchers(definition);
    else
        acc.error = "rule-set " + tag + " is not available locally";
    memo[tag] = acc;
    return acc;
}

// The rule-set tags a route rule matches by, its logical children included
// (generator.uc wraps every rule of a section with excluded devices as
// { type: logical, mode: and, rules: [ <conditions>, { source_ip_cidr, invert } ] }).
// The names of an inverted rule-set are the ones it does not match.
function collect_rule_set_tags(rule, tags, acc) {
    rule = object_or_empty(rule);
    if (rule.invert === true) {
        if (rule.rule_set != null)
            acc.inverted++;
        return;
    }
    if (as_string(rule.type) == "logical") {
        for (let child in array_or_empty(rule.rules))
            collect_rule_set_tags(child, tags, acc);
        return;
    }
    for (let tag in array_of(rule.rule_set))
        push(tags, as_string(tag));
}

function route_rule_matchers(rule, definitions, memo) {
    let acc = new_matchers();
    collect_rule_matchers(rule, acc);
    let tags = [];
    collect_rule_set_tags(rule, tags, acc);
    for (let tag in tags)
        merge_matchers(acc, ruleset_matchers(definitions, tag, memo));
    return acc;
}

const SOURCE_RULE_KEYS = [ "source_ip_cidr", "source_port", "source_port_range" ];

// The conditions a rule requires all of: the rule itself or, for a logical
// "and" rule, its children.
function and_conditions(rule, result) {
    rule = object_or_empty(rule);
    if (as_string(rule.type) == "logical" && as_string(rule.mode) == "and" && rule.invert !== true) {
        for (let child in array_or_empty(rule.rules))
            and_conditions(child, result);
    }
    else
        push(result, rule);
    return result;
}

// Which clients a route rule applies to: "all", "limited" to some (a source
// condition) or all but "excluded" ones (an inverted source condition).
function rule_clients(rule) {
    let result = "all";
    for (let condition in and_conditions(rule, [])) {
        let has_source = false;
        for (let key in SOURCE_RULE_KEYS)
            if (condition[key] != null)
                has_source = true;
        if (!has_source)
            continue;
        if (condition.invert !== true)
            return "limited";
        result = "excluded";
    }
    return result;
}

// The source addresses a route rule excludes in the form the generator
// gives every rule of a section with excluded devices (generator.uc
// exclude_sources_from_matchers: an inverted condition of source_ip_cidr
// alone), or null for a rule that excludes none or in any other form.
function rule_excluded_sources(rule) {
    let result = [];
    for (let condition in and_conditions(rule, [])) {
        if (condition.invert !== true)
            continue;
        let has_source = false;
        for (let key in SOURCE_RULE_KEYS)
            if (condition[key] != null)
                has_source = true;
        if (!has_source)
            continue;
        for (let key in keys(condition))
            if (key != "source_ip_cidr" && key != "invert")
                return null;
        for (let value in array_of(condition.source_ip_cidr))
            push(result, as_string(value));
    }
    return length(result) > 0 ? result : null;
}

// An address or a network as 16-bit words (2 for IPv4, 8 for IPv6) with
// the host bits cleared, and its text for nft; null for anything else
// (zones, embedded IPv4, leading zeros), which then stays blocked.
function cidr_word_mask(prefix, index) {
    let bits = prefix - 16 * index;
    if (bits <= 0)
        return 0;
    return bits >= 16 ? 0xffff : (0xffff << (16 - bits)) & 0xffff;
}

function ipv6_words(address) {
    let halves = split(address, "::");
    if (length(halves) > 2)
        return null;
    let head = halves[0] == "" ? [] : split(halves[0], ":");
    let tail = length(halves) == 2 && halves[1] != "" ? split(halves[1], ":") : [];
    let missing = 8 - length(head) - length(tail);
    if (length(halves) == 2 ? missing < 1 : missing != 0)
        return null;
    let words = [];
    for (let part in head)
        push(words, part);
    for (let i = 0; length(halves) == 2 && i < missing; i++)
        push(words, "0");
    for (let part in tail)
        push(words, part);
    for (let i = 0; i < 8; i++) {
        if (match(words[i], /^[0-9A-Fa-f]{1,4}$/) == null)
            return null;
        words[i] = hex(words[i]);
    }
    return words;
}

function parse_cidr(value) {
    value = trim(as_string(value));
    let slash = index(value, "/");
    let address = slash < 0 ? value : substr(value, 0, slash);
    let family = 6;
    let words = null;
    let v4 = match(address, /^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$/);
    if (v4 != null) {
        let octets = map(slice(v4, 1), (octet) => int(octet));
        for (let octet in octets)
            if (octet > 255)
                return null;
        family = 4;
        words = [ (octets[0] << 8) | octets[1], (octets[2] << 8) | octets[3] ];
    }
    else if (index(address, ":") >= 0)
        words = ipv6_words(address);
    if (words == null)
        return null;
    let bits = family == 4 ? 32 : 128;
    let prefix = bits;
    if (slash >= 0) {
        let text = substr(value, slash + 1);
        if (match(text, /^(0|[1-9][0-9]{0,2})$/) == null || int(text) > bits)
            return null;
        prefix = int(text);
    }
    for (let i = 0; i < length(words); i++)
        words[i] = words[i] & cidr_word_mask(prefix, i);
    let text = family == 4
        ? sprintf("%d.%d.%d.%d", words[0] >> 8, words[0] & 0xff, words[1] >> 8, words[1] & 0xff)
        : join(":", map(words, (word) => sprintf("%x", word)));
    return { family, words, prefix, text: text + "/" + prefix };
}

function cidr_contains(outer, inner) {
    if (outer.family != inner.family || outer.prefix > inner.prefix)
        return false;
    for (let i = 0; i < length(outer.words); i++) {
        let mask = cidr_word_mask(outer.prefix, i);
        if ((outer.words[i] & mask) != (inner.words[i] & mask))
            return false;
    }
    return true;
}

function rule_unrestricted(rule) {
    if (rule.invert === true)
        return false;
    for (let key in keys(rule))
        if (!UNRESTRICTED_RULE_KEYS[key])
            return false;
    return true;
}

// Walks sing-box route rules in their first-match order. A protected rule
// blocks its domains (exact names are blocked with their subdomains: dnsmasq
// has no exact-only form, and over-blocking is the fail-closed side). An
// earlier unrestricted non-protected suffix keeps its own resolution: it
// shadows protected names under it and becomes a "#" exception when it sits
// below a protected name. Restricted earlier rules (by client, port, ...)
// never weaken the block.
//
// dnsmasq answers every client alike. A protected rule limited to some
// clients therefore blocks nothing through DNS; one that excludes some
// clients blocks its names for them as well (the fail-closed side for all
// the others), and both are reported (UC-193).
//
// An unreadable list fails the render, except in the rules of the sections
// named in optional_names: their readable names are blocked all the same,
// and the rest is counted (unreadable).
//
// options.skip names rules (by index) that do not apply to the clients the
// list is for: the block list of a group of excluded devices (D-23).
// options.attribute adds the section that blocks every blocked name
// (blocked_by), which tells whose names such a group resolves.
function render_dns_from_config(config, protected_names, memo, optional_names, options) {
    let result = {
        ok: false, error: "", content: "", domains: 0, exceptions: 0, shadowed: 0,
        invalid: 0, uncovered_keyword: 0, uncovered_regex: 0, uncovered_inverted: 0,
        client_limited: 0, excluded_devices: 0, unreadable: 0, unreadable_error: "", sections: {}
    };
    let optional = {};
    for (let name in array_or_empty(optional_names))
        optional[name] = true;
    options = object_or_empty(options);
    let skip = object_or_empty(options.skip);
    if (options.attribute)
        result.blocked_by = {};
    config = object_or_empty(config);
    let route = object_or_empty(config.route);
    let rules = route.rules;
    if (type(rules) != "array") {
        result.error = "sing-box config has no route rules";
        return result;
    }

    let protected_tags = {};
    for (let name in protected_names) {
        protected_tags[singbox_constants.outbound_tag(name)] = name;
        result.sections[name] = { domains: 0, uncovered: 0, client_limited: 0, excluded_devices: 0 };
    }

    let definitions = {};
    for (let definition in array_or_empty(route.rule_set))
        if (type(definition) == "object" && as_string(definition.tag) != "")
            definitions[as_string(definition.tag)] = definition;

    // Rules after the last protected one can neither block nor shadow a
    // protected name; skip them, together with their (often huge) lists.
    let last_protected = -1;
    for (let i = 0; i < length(rules); i++)
        if (!skip[i] && protected_tags[as_string(object_or_empty(rules[i]).outbound)] != null)
            last_protected = i;

    memo = memo || {};
    let relevant = [];
    for (let i = 0; i <= last_protected; i++) {
        if (skip[i])
            continue;
        let rule = object_or_empty(rules[i]);
        let action = as_string(rule.action);
        if (action != "route" && action != "reject" && !(action == "" && rule.outbound != null))
            continue;
        let section = protected_tags[as_string(rule.outbound)];
        // A restricted unprotected rule never yields an exception.
        if (section == null && !rule_unrestricted(rule))
            continue;
        push(relevant, { index: i, rule, section });
    }

    // Pass 1: every protected name and the first rule that protects it.
    let first = {};
    let order = [];
    for (let item in relevant) {
        if (item.section == null)
            continue;
        let rule = item.rule;
        let acc = route_rule_matchers(rule, definitions, memo);
        if (acc.error != "" && !optional[item.section]) {
            result.error = acc.error;
            return result;
        }
        if (acc.error != "") {
            result.unreadable++;
            if (result.unreadable_error == "")
                result.unreadable_error = acc.error;
        }
        // dnsmasq answers every client alike. A rule limited to some clients
        // must not take its names away from everybody else; those clients
        // stay protected by nftables (subnets) and FakeIP rejects only.
        let clients = rule_clients(rule);
        let names = length(acc.suffix) + length(acc.exact);
        if (clients == "limited") {
            result.client_limited += names;
            result.sections[item.section].client_limited += names;
            continue;
        }
        if (clients == "excluded") {
            result.excluded_devices += names;
            result.sections[item.section].excluded_devices += names;
        }
        result.uncovered_keyword += acc.keyword;
        result.uncovered_regex += acc.regex;
        result.uncovered_inverted += acc.inverted;
        result.sections[item.section].uncovered += acc.keyword + acc.regex + acc.inverted;
        for (let list in [ acc.suffix, acc.exact ]) {
            for (let value in list) {
                let domain = normalize_domain(value);
                if (domain == null) {
                    result.invalid++;
                    continue;
                }
                if (first[domain] == null) {
                    first[domain] = { index: item.index, section: item.section };
                    push(order, domain);
                }
            }
        }
    }

    // An unprotected suffix matters only when it equals or contains a
    // protected name (shadowing it) or lies below one (an exception).
    let covering = {};
    for (let domain in order)
        for (let candidate = domain; candidate != null; candidate = parent_domain(candidate))
            covering[candidate] = true;

    // Pass 2: the first unprotected rule of every relevant suffix. Unrelated
    // names, usually the bulk of large lists, are skipped by cheap lookups
    // before the full validation.
    let earlier = {};
    for (let item in relevant) {
        if (item.section != null)
            continue;
        let acc = route_rule_matchers(item.rule, definitions, memo);
        // An unreadable list in an unprotected rule only means fewer
        // exceptions, which is the fail-closed side.
        if (acc.error != "")
            continue;
        for (let value in acc.suffix) {
            let key = lc(as_string(value));
            if (substr(key, 0, 1) == ".")
                key = substr(key, 1);
            let related = covering[key] === true;
            for (let parent = parent_domain(key); !related && parent != null; parent = parent_domain(parent))
                related = first[parent] != null;
            if (!related)
                continue;
            let domain = normalize_domain(value);
            if (domain != null && (earlier[domain] == null || earlier[domain] > item.index))
                earlier[domain] = item.index;
        }
    }

    let blocked = {};
    let lines = [ "# Prokop VPN kill-switch: protected domains resolve only through Prokop." ];
    for (let domain in order) {
        let protected_at = first[domain].index;
        let shadowed = false;
        for (let candidate = domain; candidate != null && !shadowed; candidate = parent_domain(candidate))
            shadowed = earlier[candidate] != null && earlier[candidate] < protected_at;
        if (shadowed) {
            result.shadowed++;
            continue;
        }
        blocked[domain] = protected_at;
        if (result.blocked_by != null)
            result.blocked_by[domain] = first[domain].section;
        result.sections[first[domain].section].domains++;
        result.domains++;
        push(lines, "server=/" + domain + "/");
    }

    for (let domain in sort(keys(earlier))) {
        for (let parent = parent_domain(domain); parent != null; parent = parent_domain(parent)) {
            if (blocked[parent] != null && earlier[domain] < blocked[parent]) {
                push(lines, "server=/" + domain + "/#");
                result.exceptions++;
                break;
            }
        }
    }

    result.ok = true;
    result.content = join("\n", lines) + "\n";
    return result;
}

function sing_box_config_path(settings) {
    return option(settings, "config_path", "/etc/sing-box/config.json");
}

function prune_ruleset_cache() {
    for (let name in array_or_empty(fs.lsdir(CACHE_DIR)))
        if (match(name, /^[0-9a-f]{32}\.json$/) != null && !ruleset_cache_used[name])
            fs.unlink(CACHE_DIR + "/" + name);
}

// With release_legacy, dns/apply.uc also takes dnsmasq off the old product's
// servers file in the same commit (switched to this one when it is armed).
function dns_refresh(release_legacy) {
    return run_quiet(module_args(DNS_UC, release_legacy ? [ "killswitch-refresh", "release-legacy" ] : [ "killswitch-refresh" ]));
}

function dns_status() {
    let listed = capture(module_args(DNS_UC, [ "killswitch-status" ]));
    try {
        return object_or_empty(json(trim(listed.output)));
    }
    catch (e) {
        return {};
    }
}

// ------------------------------------------------------- standby resolver
//
// While Prokop runs, dnsmasq forwards everything to sing-box. If sing-box
// dies, that would take all DNS down, not only the protected names. The
// watcher then redirects client DNS to a standby dnsmasq that answers the
// names of every VPN section locally (the protected ones, and the others,
// which a dead sing-box fails without the kill-switch as well) and forwards
// the rest to the ordinary upstream, and hands DNS back as soon as sing-box
// answers again.

function fixture_uci() {
    return as_string(getenv("PROKOP_UCI_STATE_FILE") || "") != "";
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

// The watcher is long-lived and core.uci caches loaded packages, so live
// reads go through a fresh cursor every time.
function dnsmasq_option(name) {
    if (fixture_uci())
        return as_string(uci_core.get("dhcp.@dnsmasq[0]." + name));
    let value = null;
    try {
        let cursor = require("uci").cursor();
        cursor.foreach("dhcp", "dnsmasq", function(section) {
            value = section[name];
            return false;
        });
    }
    catch (e) {
        return "";
    }
    return type(value) == "array" ? join(" ", value) : as_string(value);
}

// sing-box's DNS inbound, also when written with a port.
function is_sing_box_dns(value) {
    value = as_string(value);
    return value == SB_DNS_ADDRESS || index(value, SB_DNS_ADDRESS + "#") == 0;
}

function dnsmasq_forwards_to_sing_box() {
    return length(filter(words(dnsmasq_option("server")), is_sing_box_dns)) > 0;
}

// The dnsmasq option backed up before dnsmasq was pointed at sing-box:
// Prokop's own backup, or one the product before the rename left behind.
function dnsmasq_backup_option(name) {
    let value = dnsmasq_option("prokop_" + name);
    return value != "" ? value : dnsmasq_option(legacy.DHCP_OPTION_PREFIX + name);
}

// A standby dnsmasq on port: the ordinary upstream, local names through the
// main dnsmasq. The standby resolver and the resolvers of excluded devices
// (D-23) differ in their port and their block list.
function resolver_config_lines(settings, title, port) {
    let lines = [
        "# Prokop VPN kill-switch " + title + ". Generated; do not edit.",
        "no-hosts",
        "bind-dynamic",
        "port=" + port,
        "cache-size=1000",
        // Answers given during an outage must not outlive it for long:
        // afterwards these names have to resolve through Prokop again.
        "max-ttl=30",
        "max-cache-ttl=30"
    ];
    for (let name in words(option(settings, "source_network_interfaces", "br-lan")))
        if (match(name, /^[A-Za-z0-9_.@-]+$/) != null)
            push(lines, "interface=" + name);

    // The original upstream: Prokop keeps it in prokop_* backups while
    // dnsmasq forwards to sing-box. sing-box itself is never an upstream.
    let forwarding = dnsmasq_forwards_to_sing_box();
    let servers = filter(words(dnsmasq_backup_option("server")), (value) => !is_sing_box_dns(value));
    if (length(servers) == 0)
        servers = filter(words(dnsmasq_option("server")), (value) => !is_sing_box_dns(value));
    let noresolv = dnsmasq_backup_option("noresolv");
    if (noresolv == "" && !forwarding)
        noresolv = dnsmasq_option("noresolv");
    if (noresolv == "1")
        push(lines, "no-resolv");
    else
        push(lines, "resolv-file=" + (dnsmasq_option("resolvfile") || "/tmp/resolv.conf.d/resolv.conf.auto"));
    for (let server in servers)
        if (match(server, /^[^[:space:]#]+(#[0-9]+)?$/) != null)
            push(lines, "server=" + server);

    // Local names stay with the main dnsmasq, which serves them itself.
    let domain = dnsmasq_option("domain") || "lan";
    if (match(domain, /^[A-Za-z0-9_.-]+$/) != null)
        push(lines, "server=/" + domain + "/127.0.0.1");
    return lines;
}

function standby_config_text(settings) {
    let lines = resolver_config_lines(settings, "standby resolver", STANDBY_PORT);
    let blocked = fs.readfile(STANDBY_BLOCKED_FILE) ?? fs.readfile(DNS_BLOCKED_FILE);
    return join("\n", lines) + "\n" + (blocked == null ? "" : blocked);
}

function write_standby_config(path) {
    let content = standby_config_text(config_settings());
    if (as_string(fs.readfile(path)) == content)
        return true;
    return write_atomic(path, content);
}

// ---------------------------------------- resolvers of excluded devices
//
// D-23: while Prokop is stopped, the excluded devices of a section that
// exempts them resolve its names through a standby dnsmasq of their group;
// every other client keeps the shared block list of the main dnsmasq. The
// firewall policy does not change: its rules of such a section never
// matched these devices.

let exempt_cache = { key: "", data: null };
let exempt_state_cache = { key: "", sig: "" };

function file_key(path) {
    let stat = fs.stat(path);
    return stat == null ? "" : sprintf("%d:%d:%d", stat.inode, stat.mtime, stat.size);
}

// The signature of the groups the last sync saved (state.dns.exempt_sig).
// Every sync rewrites the state, also one of a release that does not know
// the groups and leaves their file behind.
function exempt_state_sig() {
    let key = file_key(STATE_FILE);
    if (exempt_state_cache.key != key || key == "") {
        let dns = object_or_empty(object_or_empty(common.read_json_file(STATE_FILE)).dns);
        exempt_state_cache = { key, sig: as_string(dns.exempt_sig) };
    }
    return exempt_state_cache.sig;
}

// The groups of excluded devices the last sync saved, or null: also for
// groups another sync left behind.
function exempt_data() {
    let key = file_key(EXEMPT_FILE);
    if (key == "") {
        exempt_cache = { key: "", data: null };
        return null;
    }
    if (exempt_cache.key != key) {
        let data = common.read_json_file(EXEMPT_FILE);
        let valid = type(data) == "object" && data.format == EXEMPT_FORMAT &&
            type(data.groups) == "array" && length(data.groups) > 0 &&
            match(as_string(data.sig), /^[0-9a-f]{32}$/) != null;
        exempt_cache = { key, data: valid ? data : null };
    }
    let data = exempt_cache.data;
    return data != null && data.sig == exempt_state_sig() ? data : null;
}

function exempt_port(index) {
    return EXEMPT_PORT_BASE + index;
}

function exempt_probe_name(index, sig) {
    return "g" + index + "-" + sig + "." + EXEMPT_PROBE_ZONE;
}

// The block list of a group: the shared one without the lines that do not
// apply to its devices, with the ones that only apply to them.
function exempt_group_content(main, group) {
    let removed = {};
    for (let line in array_or_empty(group.removed))
        removed[as_string(line)] = true;
    let lines = filter(split(as_string(main), "\n"), (line) => line != "" && !removed[line]);
    // Only what render_dns_from_config writes goes into a configuration.
    for (let line in array_or_empty(group.added))
        if (match(as_string(line), /^server=\/[a-z0-9_.-]+\/#?$/) != null)
            push(lines, as_string(line));
    return join("\n", lines) + "\n";
}

function remove_exempt_configs(dir, keep) {
    keep = object_or_empty(keep);
    for (let name in array_or_empty(fs.lsdir(dir)))
        if (match(name, /^exempt-[0-9]+\.conf$/) != null && !keep[name])
            fs.unlink(dir + "/" + name);
}

// Writes the configuration of the resolver of every group to dir and prints
// its path; the init script runs a dnsmasq for each. Only groups saved for
// the block list and the configuration in place now get one: after a change
// (by a release that does not know them, or while Prokop was stopped) every
// excluded device keeps the shared block list until the next refresh.
function write_exempt_configs(dir) {
    let wanted = {};
    let settings = config_settings();
    let data = exempt_data();
    let main = fs.readfile(DNS_BLOCKED_FILE);
    if (data != null && main != null && !bool_option(settings, "dont_touch_dhcp", false) &&
        as_string(data.blocked_md5) == file_md5(DNS_BLOCKED_FILE) &&
        as_string(data.fingerprint) == exempt_fingerprint(config_sections())) {
        for (let i = 0; i < length(data.groups) && i < EXEMPT_MAX_GROUPS; i++) {
            let name = "exempt-" + i + ".conf";
            let path = dir + "/" + name;
            // It listens where the standby does: dnsmasq adds loopback,
            // where the watcher probes it, to any interface it is given.
            let lines = resolver_config_lines(settings, "resolver for excluded devices", exempt_port(i));
            push(lines, "address=/" + exempt_probe_name(i, data.sig) + "/127.0.0.1");
            let content = join("\n", lines) + "\n" + exempt_group_content(main, object_or_empty(data.groups[i]));
            if (as_string(fs.readfile(path)) != content && !write_atomic(path, content))
                continue;
            wanted[name] = true;
            print(path, "\n");
        }
    }
    remove_exempt_configs(dir, wanted);
    return true;
}

// A short stable hash of a text (FNV-1a, 32 bits).
function text_hash(text) {
    text = as_string(text);
    let hash = 0x811c9dc5;
    for (let i = 0; i < length(text); i++)
        hash = ((hash ^ ord(text, i)) * 0x01000193) & 0xffffffff;
    return sprintf("%08x", hash);
}

// Only a resolver that runs the configuration of its group answers the
// probe name of the group with 127.0.0.1.
function exempt_resolver_answers(index, sig) {
    let answer = capture([ "dig", "+short", "+time=1", "+tries=1", "-p", as_string(exempt_port(index)),
        "@127.0.0.1", exempt_probe_name(index, sig), "A" ]);
    return answer.status == 0 && trim(answer.output) == "127.0.0.1";
}

// The watcher's probes of those resolvers while Prokop is stopped, by group
// and configuration. One that answered is asked again only every
// EXEMPT_PROBE_PASSES passes and keeps its devices after one failed probe:
// a single slow answer must not flush the DNS chain (and the DNS
// conntrack entries of every client) twice. A second failure in a row, or a
// first one of a resolver that never answered, hands them back to the
// shared block list.
let exempt_probes = {};
let exempt_redirect_cache = { key: "", result: null };

function exempt_resolver_usable(index, sig) {
    let key = index + ":" + sig;
    let probe = exempt_probes[key];
    if (probe != null && probe.failures == 0 && ++probe.skipped < EXEMPT_PROBE_PASSES)
        return true;
    let failures = exempt_resolver_answers(index, sig) ? 0 : (probe == null ? 2 : probe.failures + 1);
    exempt_probes[key] = { failures, skipped: 0 };
    return failures < 2;
}

// The rules that redirect the DNS of the groups usable, narrowest source
// first (see exempt_redirect), or null without any.
function exempt_redirect_rules(data, usable) {
    let entries = [];
    for (let i in usable) {
        for (let source in array_or_empty(object_or_empty(data.groups[i]).sources)) {
            let cidr = parse_cidr(source);
            if (cidr != null)
                push(entries, { cidr, port: exempt_port(i) });
        }
    }
    if (length(entries) == 0)
        return null;
    sort(entries, (a, b) => a.cidr.family - b.cidr.family || b.cidr.prefix - a.cidr.prefix ||
        (a.cidr.text < b.cidr.text ? -1 : (a.cidr.text > b.cidr.text ? 1 : 0)));
    let rules = [];
    for (let entry in entries)
        for (let proto in [ "udp", "tcp" ])
            push(rules, "iifname @" + INTERFACE_SET + " " + (entry.cidr.family == 6 ? "ip6" : "ip") + " saddr " +
                entry.cidr.text + " fib daddr type local " + proto + " dport 53 counter redirect to :" + entry.port);
    return { rules, tag: "prokop-exempt-" + text_hash(join("\n", rules)) };
}

// The redirect of the excluded devices' DNS to the resolvers of their
// groups: only for the groups the last sync saved, only while dnsmasq
// answers with the shared block list itself (Prokop stopped), only to
// resolvers that answer with the configuration of their group
// (exempt_resolver_usable), and only DNS for the router itself, which is
// what the shared list answers. The narrowest source comes first: an
// address belongs to the group of the narrowest source that contains it,
// which is exempt from no rule a wider one does not exclude it from as well.
// null when none applies.
function exempt_redirect(forwarding) {
    let servers = forwarding || dnsmasq_option("serversfile") != DNS_SERVERS_FILE ? null : fs.stat(DNS_SERVERS_FILE);
    let data = servers != null && servers.size > 0 ? exempt_data() : null;
    if (data == null) {
        // The next stop starts with fresh probes.
        exempt_probes = {};
        return null;
    }
    let usable = [];
    for (let i = 0; i < length(data.groups) && i < EXEMPT_MAX_GROUPS; i++)
        if (exempt_resolver_usable(i, data.sig))
            push(usable, i);
    let key = data.sig + ":" + join(",", usable);
    if (exempt_redirect_cache.key != key)
        exempt_redirect_cache = { key, result: exempt_redirect_rules(data, usable) };
    return exempt_redirect_cache.result;
}

function sing_box_answers() {
    // Any reply counts, including NXDOMAIN: only a dead or hung resolver
    // fails. The FakeIP test name is answered by sing-box itself.
    return run_quiet([ "dig", "+time=1", "+tries=1", "@" + SB_DNS_ADDRESS, SB_PROBE_DOMAIN, "A" ]);
}

// The DNS chain of the live table, or null without one.
function dns_chain_listing() {
    let listed = capture([ "nft", "list", "chain", "inet", KS_TABLE, DNS_CHAIN ]);
    return listed.status != 0 ? null : listed.output;
}

function standby_redirected(listed) {
    return index(listed, "redirect to :" + STANDBY_PORT) >= 0;
}

// The tag the rules of the exemption redirect carry, "" without them.
function exempt_redirect_tag(listed) {
    let found = match(listed, /comment "(prokop-exempt-[0-9a-f]+)"/);
    return found == null ? "" : found[1];
}

function dns_redirect_state() {
    let listed = dns_chain_listing();
    return listed == null ? null : standby_redirected(listed);
}

// Client DNS goes to the standby resolver (a dead sing-box), the excluded
// devices' DNS to their resolvers (exempt, Prokop stopped) or nowhere else.
function set_dns_chain(standby, exempt) {
    let t = "inet " + KS_TABLE;
    let lines = [ "flush chain " + t + " " + DNS_CHAIN ];
    if (standby) {
        for (let proto in [ "udp", "tcp" ])
            push(lines, "add rule " + t + " " + DNS_CHAIN + " iifname @" + INTERFACE_SET + " " + proto +
                " dport 53 counter redirect to :" + STANDBY_PORT);
    }
    else if (exempt != null) {
        for (let rule in exempt.rules)
            push(lines, "add rule " + t + " " + DNS_CHAIN + " " + rule + " comment \"" + exempt.tag + "\"");
    }
    let tmp = trim(capture([ "mktemp" ]).output);
    if (tmp == "")
        return false;
    // On a full tmpfs writefile reports success and leaves the file empty,
    // and an empty batch passes `nft -f` while it changes nothing (UC-223).
    let data = join("\n", lines) + "\n";
    let ok = fs.writefile(tmp, data) != null && fs.readfile(tmp) === data && run_quiet([ "nft", "-f", tmp ]);
    fs.unlink(tmp);
    // Existing DNS flows keep their old NAT binding until they expire.
    if (ok) {
        run_quiet([ "conntrack", "-D", "-p", "udp", "--dport", "53" ]);
        run_quiet([ "conntrack", "-D", "-p", "tcp", "--dport", "53" ]);
    }
    return ok;
}

function dns_redirect(mode) {
    if (dns_redirect_state() == null)
        return 0;
    return set_dns_chain(mode == "on", null) ? 0 : 1;
}

// ---------------------------------------------------------------- orphaned
//
// The package this watcher runs from was removed, or replaced by a release
// without the kill-switch, and nothing lifted the protection: its scripts did
// not run (a package manager or a manual change that skips them). Nothing
// would ever lift it then, so the watcher does, with what this process has
// already loaded and the system's own tools (UC-191).

// Through the edit core/uci.uc gives every dhcp writer (dns/apply.uc): the
// uci CLI on a private copy (core/uci.uc and the CLI are what this process
// loaded and the system's own tool), and the file is replaced only while it
// holds what the edit read. A libuci commit would also commit what someone
// staged for dhcp with `uci set` (UC-236). A file that someone else changed
// meanwhile is read again. "detached", "absent" (dhcp does not name the
// block list), or null when the edit failed.
function detach_dns_servers_file() {
    for (let attempt = 1; attempt <= 5; attempt++) {
        let dhcp = uci_core.session("dhcp", DNSMASQ_CONFIG_FILE, UCI_CLI);
        if (dhcp == null)
            return null;
        if (dhcp.get(DNSMASQ_SERVERSFILE_OPTION) != DNS_SERVERS_FILE) {
            dhcp.close();
            return "absent";
        }
        if (dhcp.delete(DNSMASQ_SERVERSFILE_OPTION) && dhcp.commit())
            return "detached";
        let conflict = dhcp.conflict();
        dhcp.close();
        if (!conflict)
            return null;
    }
    return null;
}

function lift_orphaned() {
    log_message("Kill-switch: the Prokop package is gone and nothing lifted the kill-switch; removing its protection", "warn");
    if (ks_table_present())
        run_quiet([ "nft", "delete", "table", "inet", KS_TABLE ]);
    let detached = detach_dns_servers_file();
    for (let path in [ DNS_SERVERS_FILE, DNS_BLOCKED_FILE, STANDBY_BLOCKED_FILE, EXEMPT_FILE, NFT_POLICY, LEGACY_NFT_INCLUDE ])
        if (path != DNS_SERVERS_FILE || detached != null)
            fs.unlink(path);
    // dnsmasq does not start with a servers file that is gone: the block
    // list that dhcp still names is emptied instead, which lifts its blocks
    // all the same, and the option is left for the administrator.
    if (detached == null) {
        let emptied = fs.writefile(DNS_SERVERS_FILE, "") != null;
        log_message("Kill-switch: could not detach the block list " + DNS_SERVERS_FILE + " from dnsmasq" +
            (emptied ? "; it was emptied instead" : " or empty it") +
            ". Remove option serversfile from dhcp.@dnsmasq[0]", "error");
    }
    remove_exempt_configs(CACHE_DIR);
    if (detached != "absent")
        run_quiet([ DNSMASQ_INIT, "restart" ]);
    // procd would keep the standby dnsmasq; this ends the watcher as well.
    run_quiet([ "ubus", "call", "service", "delete", sprintf("%J", { name: "prokop-killswitch" }) ]);
}

function watch() {
    // A respawned watcher continues from the live state instead of handing
    // DNS back to a sing-box that may still be dead.
    let standby = dns_redirect_state() === true;
    let failures = 0;
    let successes = 0;
    let orphaned = 0;
    for (let iteration = 1; WATCH_ITERATIONS == 0 || iteration <= WATCH_ITERATIONS; iteration++) {
        // A package upgrade replaces the file in place; only a file missing
        // for several passes means that the package is gone.
        if (fs.stat(OWNER_FILE) == null) {
            if (++orphaned >= 5) {
                lift_orphaned();
                return 0;
            }
            sleep(WATCH_INTERVAL_MS);
            continue;
        }
        orphaned = 0;

        if (!policy_saved()) {
            standby = false;
            sleep(WATCH_INTERVAL_MS * 2);
            continue;
        }

        let forwarding = dnsmasq_forwards_to_sing_box();
        if (!forwarding || fs.stat(DNS_BLOCKED_FILE) == null) {
            // Prokop is stopped and dnsmasq answers with the block list
            // itself, or there is no block list a standby could enforce.
            standby = false;
            failures = 0;
            successes = 0;
        }
        else if (runtime_lock.busy(RELOAD_LOCK_DIR) && !standby) {
            // Prokop is restarting sing-box on purpose; its own transition
            // guard covers the gap. Do not fail over for a planned restart.
            failures = 0;
        }
        else if (sing_box_answers()) {
            successes++;
            failures = 0;
            if (standby && successes >= 2) {
                standby = false;
                log_message("Kill-switch: sing-box answers DNS again; client DNS goes through Prokop", "info");
            }
        }
        else {
            failures++;
            successes = 0;
            if (!standby && failures >= 3) {
                standby = true;
                log_message("Kill-switch: sing-box does not answer DNS; protected names are blocked and other names use the standby resolver", "warn");
            }
        }

        // Reconcile every pass: a firewall reload or a policy refresh
        // recreates the table with an empty DNS chain.
        let listed = dns_chain_listing();
        if (listed != null) {
            let exempt = standby ? null : exempt_redirect(forwarding);
            let tag = exempt == null ? "" : exempt.tag;
            let current = exempt_redirect_tag(listed);
            if (standby_redirected(listed) != standby || current != tag) {
                if (!set_dns_chain(standby, exempt))
                    log_message("Kill-switch: could not switch client DNS to the " +
                        (standby ? "standby resolver" : (tag != "" ? "resolvers of excluded devices" : "Prokop resolver")), "error");
                else if (current != tag)
                    log_message(tag != ""
                        ? "Kill-switch: excluded devices of sections that exempt them resolve their names through their own resolvers while Prokop is stopped"
                        : "Kill-switch: excluded devices resolve through the shared DNS block list", "info");
            }
        }

        sleep(WATCH_INTERVAL_MS);
    }
    return 0;
}

function service_control(actions) {
    if (fs.stat(KILLSWITCH_INIT) == null)
        return true;
    let ok = true;
    for (let action in actions)
        if (!run_quiet([ KILLSWITCH_INIT, action ]))
            ok = false;
    return ok;
}

function service_running() {
    let listed = capture([ "ubus", "call", "service", "list", sprintf("%J", { name: "prokop-killswitch" }) ]);
    if (listed.status != 0)
        return false;
    let data = null;
    try {
        data = json(listed.output);
    }
    catch (e) {
        return false;
    }
    let instances = object_or_empty(object_or_empty(object_or_empty(data)["prokop-killswitch"]).instances);
    for (let name in keys(instances))
        if (object_or_empty(instances[name]).running)
            return true;
    return false;
}

// Protected sections the running sing-box does not route. A section whose
// subscription could not be loaded is deferred until it can be downloaded
// (subscription/cache.uc): sing-box has no outbound for it and rejects its
// traffic (singbox/generator.uc). The live table still holds its
// destinations (nft/apply.uc), but its domains have no route rule to read:
// a block list rendered meanwhile would lack its names (UC-192).
function unrouted_sections(config, names) {
    config = object_or_empty(config);
    let routed = {};
    for (let outbound in array_or_empty(config.outbounds))
        routed[as_string(object_or_empty(outbound).tag)] = true;
    for (let rule in array_or_empty(object_or_empty(config.route).rules))
        routed[as_string(object_or_empty(rule).outbound)] = true;
    return filter(names, (name) => !routed[singbox_constants.outbound_tag(name)]);
}

// The excluded addresses of the sections that exempt them, grouped by the
// route rules that do not apply to them: an address is excluded from every
// rule of such a section that excludes a source containing it (D-23).
function exempt_groups(config, sections) {
    let tags = {};
    for (let section in sections)
        if (section_exempts_devices(section))
            tags[singbox_constants.outbound_tag(as_string(section[".name"]))] = as_string(section[".name"]);
    let rules = array_or_empty(object_or_empty(object_or_empty(config).route).rules);
    let excluding = [];
    let entries = {};
    let invalid = {};
    for (let i = 0; i < length(rules); i++) {
        let rule = object_or_empty(rules[i]);
        let section = tags[as_string(rule.outbound)];
        let sources = section != null && rule_clients(rule) == "excluded" ? rule_excluded_sources(rule) : null;
        if (sources == null)
            continue;
        let cidrs = [];
        for (let value in sources) {
            let cidr = parse_cidr(value);
            if (cidr == null) {
                invalid[value] = true;
                continue;
            }
            push(cidrs, cidr);
            entries[cidr.text] = cidr;
        }
        push(excluding, { index: i, section, cidrs });
    }
    let groups = {};
    for (let text in sort(keys(entries))) {
        let skip = {};
        let indices = [];
        let names = [];
        for (let rule in excluding) {
            for (let cidr in rule.cidrs) {
                if (!cidr_contains(cidr, entries[text]))
                    continue;
                skip[rule.index] = true;
                push(indices, rule.index);
                if (index(names, rule.section) < 0)
                    push(names, rule.section);
                break;
            }
        }
        let key = join(",", indices);
        if (groups[key] == null)
            groups[key] = { skip, sections: names, sources: [] };
        push(groups[key].sources, text);
    }
    return { groups: map(sort(keys(groups)), (key) => groups[key]), invalid: length(keys(invalid)) };
}

// Saves the groups of excluded devices for the block list main just
// rendered and saved (with blocked_by), as the lines their own lists lack or
// add, with what they were rendered for. Without a group that changes
// anything no file is kept. unblocked counts, by section, the blocked names
// of the section the excluded devices of a saved group resolve; sig is
// what the state records for the groups saved.
function sync_exempt(config, protected_names, sections, memo, main) {
    let result = { groups: 0, sig: "", unblocked: {}, warnings: [] };
    let built = exempt_groups(config, sections);
    let main_lines = {};
    for (let line in split(main.content, "\n"))
        if (line != "")
            main_lines[line] = true;
    let groups = [];
    // Only the groups that can get a resolver are rendered; the devices of
    // the others stay blocked.
    let beyond = 0;
    for (let group in built.groups) {
        if (length(groups) > EXEMPT_MAX_GROUPS) {
            beyond += length(group.sources);
            continue;
        }
        let rendered = render_dns_from_config(config, protected_names, memo, null, { skip: group.skip });
        if (!rendered.ok)
            continue;
        let lines = {};
        let added = [];
        for (let line in split(rendered.content, "\n")) {
            if (line == "" || lines[line])
                continue;
            lines[line] = true;
            if (!main_lines[line])
                push(added, line);
        }
        let removed = filter(keys(main_lines), (line) => !lines[line]);
        if (length(removed) > 0 || length(added) > 0)
            push(groups, { sections: group.sections, sources: group.sources, removed, added });
    }
    if (built.invalid > 0)
        push(result.warnings, sprintf("%d excluded device addresses of sections that exempt their excluded devices cannot be read; those devices stay blocked through DNS while Prokop is stopped",
            built.invalid));
    if (length(groups) > EXEMPT_MAX_GROUPS) {
        for (let group in slice(groups, EXEMPT_MAX_GROUPS))
            beyond += length(group.sources);
        push(result.warnings, sprintf("the excluded devices form more than %d groups with different blocked names, only %d get their own resolver; %d device addresses stay blocked through DNS while Prokop is stopped",
            EXEMPT_MAX_GROUPS, EXEMPT_MAX_GROUPS, beyond));
        groups = slice(groups, 0, EXEMPT_MAX_GROUPS);
    }
    let data = length(groups) > 0 ? {
        format: EXEMPT_FORMAT,
        fingerprint: exempt_fingerprint(sections),
        blocked_md5: file_md5(DNS_BLOCKED_FILE),
        groups
    } : null;
    if (data != null)
        data.sig = data.blocked_md5 != "" ? text_md5(sprintf("%J", data)) : "";
    let content = data != null && data.sig != "" ? sprintf("%J", data) + "\n" : null;
    if (content != null && (as_string(fs.readfile(EXEMPT_FILE)) == content || write_durable(EXEMPT_FILE, content))) {
        result.groups = length(groups);
        result.sig = data.sig;
        // A name leaves the list of a group only if every rule that blocks
        // it for the group's devices is one they are excluded from: its
        // first one belongs to a section the group is exempt from.
        let blocked_by = object_or_empty(main.blocked_by);
        let unblocked = {};
        for (let group in groups) {
            for (let line in group.removed) {
                let found = match(line, /^server=\/([^\/#]+)\/$/);
                let section = found == null ? null : blocked_by[found[1]];
                if (section == null || index(group.sections, section) < 0)
                    continue;
                if (unblocked[section] == null)
                    unblocked[section] = {};
                unblocked[section][found[1]] = true;
            }
        }
        for (let section in keys(unblocked))
            result.unblocked[section] = length(keys(unblocked[section]));
        return result;
    }
    // Groups that do not belong to the block list just saved are never
    // used: keep none.
    if (fs.stat(EXEMPT_FILE) != null && !fs.unlink(EXEMPT_FILE))
        push(result.warnings, "could not remove " + EXEMPT_FILE);
    if (data != null)
        push(result.warnings, "could not save the block lists of excluded devices; they stay blocked through DNS while Prokop is stopped");
    return result;
}

function sync_dns(settings, protected_names, config, vpn_names, unrouted, sections, release_legacy) {
    if (bool_option(settings, "dont_touch_dhcp", false)) {
        fs.unlink(DNS_BLOCKED_FILE);
        fs.unlink(STANDBY_BLOCKED_FILE);
        fs.unlink(EXEMPT_FILE);
        dns_refresh(release_legacy);
        return { ok: true, managed: false, warning: "dnsmasq is not managed by Prokop (dont_touch_dhcp); protected domains are guarded by nftables and FakeIP only" };
    }

    if (type(config) != "object")
        return { ok: false, error: "sing-box config " + sing_box_config_path(settings) + " is not readable" };
    if (length(unrouted) > 0)
        return { ok: false, error: "protected section(s) " + join(", ", unrouted) +
            " not routed by the running Prokop yet (subscription not loaded), so their domains are unknown" };

    ruleset_cache_used = {};
    let memo = {};
    let rendered = render_dns_from_config(config, protected_names, memo, null,
        any_section_exempts_devices(sections) ? { attribute: true } : null);
    if (!rendered.ok)
        return { ok: false, error: "DNS block list: " + rendered.error };
    // Without the kill-switch a dead sing-box fails every VPN section, not
    // only the protected ones: dnsmasq still forwards to it. The standby
    // resolver that keeps other names working meanwhile must not resolve
    // theirs either (UC-211). An unreadable list of an unprotected section
    // leaves out only its own names.
    let protected = {};
    for (let name in protected_names)
        protected[name] = true;
    let standby = render_dns_from_config(config, vpn_names, memo,
        filter(vpn_names, (name) => !protected[name]));
    if (!standby.ok)
        rendered.standby_error = standby.error;
    else if (standby.unreadable > 0)
        rendered.standby_unreadable = sprintf("%d rules of other VPN sections have lists that cannot be read (%s); their names are not blocked",
            standby.unreadable, standby.unreadable_error);
    // dnsmasq answers every client alike (render_dns_from_config).
    if (standby.ok && standby.client_limited > rendered.client_limited)
        rendered.standby_client_limited = standby.client_limited - rendered.client_limited;
    let standby_content = standby.ok ? standby.content : rendered.content;
    prune_ruleset_cache();

    if (as_string(fs.readfile(DNS_BLOCKED_FILE)) != rendered.content &&
        !write_durable(DNS_BLOCKED_FILE, rendered.content))
        return { ok: false, error: "could not write " + DNS_BLOCKED_FILE };
    if (as_string(fs.readfile(STANDBY_BLOCKED_FILE)) != standby_content &&
        !write_atomic(STANDBY_BLOCKED_FILE, standby_content))
        rendered.standby_error = "could not write " + STANDBY_BLOCKED_FILE;
    let exempt = sync_exempt(config, protected_names, sections, memo, rendered);
    delete rendered.blocked_by;
    if (exempt.groups > 0) {
        rendered.exempt_groups = exempt.groups;
        rendered.exempt_sig = exempt.sig;
    }
    // Names the excluded devices of a section resolve through their own
    // resolver are no longer blocked for them as well.
    for (let name in keys(exempt.unblocked)) {
        let section = rendered.sections[name];
        let count = exempt.unblocked[name];
        let moved = count < section.excluded_devices ? count : section.excluded_devices;
        section.excluded_exempt = count;
        section.excluded_devices -= moved;
        rendered.excluded_devices -= moved;
        rendered.excluded_exempt = int(rendered.excluded_exempt) + count;
    }
    if (length(exempt.warnings) > 0)
        rendered.exempt_warnings = exempt.warnings;
    if (!dns_refresh(release_legacy))
        return { ok: false, error: "dnsmasq could not be refreshed" };

    delete rendered.content;
    rendered.managed = true;
    return rendered;
}

// ------------------------------------------------- pre-rename kill-switch

function legacy_table_present() {
    return legacy.nft_table_present(LEGACY_TABLE);
}

function legacy_dns_attached() {
    return dnsmasq_option("serversfile") == LEGACY_SERVERSFILE;
}

function legacy_status() {
    return {
        installed: legacy.installed(),
        active: legacy_table_present(),
        persistent: fs.stat(LEGACY_INCLUDE) != null,
        keep: fs.stat(LEGACY_KEEP) != null,
        dns_attached: legacy_dns_attached(),
        state_dir: fs.stat(LEGACY_STATE_DIR) != null
    };
}

function legacy_present() {
    let st = legacy_status();
    return st.active || st.persistent || st.keep || st.dns_attached || st.state_dir;
}

// Whether the old kill-switch may be lifted now. Never while the old product
// is active; for an automatic hand-over and Prokop's own removal, not while
// its package is installed either (STRICT_LEGACY_REASONS).
function legacy_release_allowed(strict) {
    if (strict && legacy.installed())
        return false;
    return !legacy.active();
}

// The old nft policy. Its standby resolver goes first and client DNS is no
// longer redirected to it; the include goes before the table, or the next
// firewall reload would load the table again.
function legacy_nft_release() {
    let ok = true;
    if (fs.stat(LEGACY_SERVICE_INIT) != null) {
        run_quiet([ LEGACY_SERVICE_INIT, "stop" ]);
        run_quiet([ LEGACY_SERVICE_INIT, "disable" ]);
    }
    else
        run_quiet([ "ubus", "call", "service", "delete", sprintf("%J", { name: legacy.KILLSWITCH_SERVICE }) ]);

    let table = legacy_table_present();
    if (table) {
        run_quiet([ "nft", "flush", "chain", "inet", LEGACY_TABLE, LEGACY_DNS_CHAIN ]);
        // Existing DNS flows keep their redirect to the stopped standby.
        run_quiet([ "conntrack", "-D", "-p", "udp", "--dport", "53" ]);
        run_quiet([ "conntrack", "-D", "-p", "tcp", "--dport", "53" ]);
    }
    for (let path in [ LEGACY_INCLUDE, LEGACY_KEEP ])
        if (fs.stat(path) != null && !fs.unlink(path))
            ok = false;
    if (table && !run_quiet([ "nft", "delete", "table", "inet", LEGACY_TABLE ]))
        ok = false;
    if (ok)
        log_message("Kill-switch: the " + legacy.PRODUCT + " kill-switch policy " + LEGACY_TABLE + " was removed", "info");
    return ok;
}

// The old state directory goes only once dnsmasq no longer reads its servers
// file (dns_refresh with release_legacy switched it in one commit).
function legacy_dir_release() {
    if (legacy_dns_attached()) {
        log_message("Kill-switch: dnsmasq still uses " + LEGACY_SERVERSFILE + "; keeping " + LEGACY_STATE_DIR, "warn");
        return false;
    }
    if (fs.stat(LEGACY_STATE_DIR) != null && !run_quiet([ "rm", "-rf", LEGACY_STATE_DIR ]))
        return false;
    run_quiet([ "rm", "-rf", LEGACY_CACHE_DIR ]);
    // Empty once everything else was migrated and cleaned up.
    fs.rmdir(LEGACY_PRODUCT_STATE_DIR);
    return true;
}

// ------------------------------------------------------------- operations

function teardown(reason, release_legacy) {
    service_control([ "stop", "disable" ]);
    let ok = remove_nft_policy();
    remove_legacy_guard_table();
    if (release_legacy && !legacy_nft_release())
        ok = false;
    fs.unlink(DNS_BLOCKED_FILE);
    fs.unlink(STANDBY_BLOCKED_FILE);
    if (fs.stat(EXEMPT_FILE) != null && !fs.unlink(EXEMPT_FILE))
        ok = false;
    remove_exempt_configs(CACHE_DIR);
    if (!dns_refresh(release_legacy))
        ok = false;
    if (release_legacy && !legacy_dir_release())
        ok = false;
    write_state({
        active: false,
        reason: as_string(reason),
        updated_at: now(),
        last_error: ok ? "" : "protection could not be removed completely",
        last_error_at: ok ? 0 : now()
    });
    log_message("Kill-switch protection removed: " + as_string(reason), ok ? "info" : "error");
    return ok;
}

function reload_state_fields(text) {
    let result = {};
    for (let line in split(as_string(text), "\n")) {
        let equals = index(line, "=");
        if (equals > 0)
            result[substr(line, 0, equals)] = substr(line, equals + 1);
    }
    return result;
}

// The policy is rendered from the configuration in UCI (rules and their
// order) and the sets of the live table. Why they would not describe the
// same runtime, or "" (UC-209). Only a manual refresh can meet committed
// changes that wait for a reload; start and reload apply what they render.
function runtime_behind_config(manual) {
    if (fs.stat(RUNTIME_LISTS_PENDING_FILE) != null)
        return "Prokop has not applied the list generation of its configuration yet";
    let applied = fs.readfile(RELOAD_STATE_FILE);
    if (!manual || applied == null)
        return "";
    let tmp = trim(capture([ "mktemp" ]).output);
    if (tmp == "")
        return "";
    let current = run_quiet(module_args(STATE_UC, [ "capture-reload-state", tmp, "1" ])) ? fs.readfile(tmp) : null;
    fs.unlink(tmp);
    if (current == null)
        return "";
    applied = reload_state_fields(applied);
    current = reload_state_fields(current);
    for (let key in RUNTIME_SIGNATURES)
        if (as_string(applied[key]) != as_string(current[key]))
            return "the configuration changed since Prokop last applied it; reload Prokop first";
    return "";
}

function protection_present() {
    return fs.stat(NFT_POLICY) != null || fs.stat(LEGACY_NFT_INCLUDE) != null ||
        fs.stat(DNS_BLOCKED_FILE) != null || fs.stat(STANDBY_BLOCKED_FILE) != null || fs.stat(EXEMPT_FILE) != null ||
        read_state().active === true || ks_table_present() ||
        run_quiet([ "nft", "list", "table", "inet", LEGACY_GUARD_TABLE ]);
}

// Excluded devices resolve through the shared block list again (D-23): the
// fail-closed side, which needs no runtime.
function drop_exemption(reason) {
    if (fs.stat(EXEMPT_FILE) == null)
        return true;
    let ok = fs.unlink(EXEMPT_FILE) == true;
    let listed = dns_chain_listing();
    if (listed != null && exempt_redirect_tag(listed) != "" && !set_dns_chain(false, null))
        ok = false;
    // The service runs the resolvers the saved groups describe.
    if (service_running() && !service_control([ "start" ]))
        ok = false;
    log_message("Kill-switch: excluded devices resolve through the shared DNS block list again: " + as_string(reason), ok ? "info" : "error");
    return ok;
}

function sync_locked(reason, manual) {
    let settings = config_settings();
    let sections = config_sections();
    let names = protected_section_names(sections);
    if (length(names) == 0) {
        // Definitively nothing to protect: the old kill-switch goes as well.
        let release_legacy = legacy_present() && legacy_release_allowed(true);
        if (!release_legacy && !protection_present())
            return 0;
        if (!config_readable()) {
            drop_exemption("the Prokop configuration could not be read");
            record_error("the Prokop configuration could not be read; keeping the previous protection");
            return 1;
        }
        return teardown("no section has the kill-switch enabled", release_legacy) ? 0 : 1;
    }

    if (!live_table_present()) {
        record_error("Prokop runtime table " + LIVE_TABLE + " is not present; keeping the previous protection");
        return 1;
    }

    let behind = runtime_behind_config(manual);
    if (behind != "") {
        record_error(behind + "; keeping the previous protection");
        if (manual)
            warn("Kill-switch not refreshed: " + behind + "\n");
        return 1;
    }

    let config = common.read_json_file(sing_box_config_path(settings));
    let unrouted = type(config) == "object" ? unrouted_sections(config, names) : [];

    let nft_result = apply_nft_policy(any_section_exempts_devices(sections));
    if (!nft_result.ok) {
        record_error(nft_result.error + "; keeping the previous protection");
        return 1;
    }
    remove_legacy_guard_table();

    let warnings = [];
    // This policy is live: it replaces the old kill-switch, whose servers file
    // dnsmasq leaves in the commit that attaches this one.
    let release_legacy = legacy_present() && legacy_release_allowed(true);
    if (release_legacy && !legacy_nft_release())
        push(warnings, "the " + legacy.PRODUCT + " kill-switch policy " + LEGACY_TABLE + " could not be removed completely");
    let dns_result = sync_dns(settings, names, config, vpn_section_names(sections), unrouted, sections, release_legacy);
    if (release_legacy)
        legacy_dir_release();
    if (!dns_result.ok)
        push(warnings, as_string(dns_result.error) + "; the previous DNS block list stays in place");
    else if (dns_result.warning)
        push(warnings, as_string(dns_result.warning));
    if (dns_result.ok && dns_result.managed) {
        if (dns_result.uncovered_keyword > 0 || dns_result.uncovered_regex > 0 || dns_result.uncovered_inverted > 0)
            push(warnings, sprintf("%d keyword, %d regex and %d inverted domain matchers cannot be enforced through DNS while Prokop is stopped",
                dns_result.uncovered_keyword, dns_result.uncovered_regex, dns_result.uncovered_inverted));
        if (dns_result.client_limited > 0)
            push(warnings, sprintf("%d domains of client-limited rules are not blocked through DNS (it is shared by all clients); only their IP lists and FakeIP answers are blocked while Prokop is stopped",
                dns_result.client_limited));
        if (dns_result.standby_error)
            push(warnings, "the standby resolver for a dead sing-box blocks the protected names only, not those of the other VPN sections: " +
                as_string(dns_result.standby_error));
        if (dns_result.standby_unreadable)
            push(warnings, "the standby resolver for a dead sing-box: " + as_string(dns_result.standby_unreadable));
        if (dns_result.standby_client_limited > 0)
            push(warnings, sprintf("%d domains of device-limited rules of other VPN sections are not blocked by the standby resolver for a dead sing-box (DNS is shared by all clients)",
                dns_result.standby_client_limited));
        if (dns_result.excluded_devices > 0)
            push(warnings, sprintf("%d domains of rules with excluded devices are blocked through DNS for the excluded devices as well (it is shared by all clients) while Prokop is stopped",
                dns_result.excluded_devices));
        for (let warning in array_or_empty(dns_result.exempt_warnings))
            push(warnings, as_string(warning));
        let ds = dns_status();
        if (ds.conflict)
            push(warnings, "dnsmasq already uses servers file " + as_string(ds.serversfile) + "; DNS protection is not attached");
        else if (ds.legacy_attached)
            push(warnings, "dnsmasq still uses the " + legacy.PRODUCT + " kill-switch servers file " + as_string(ds.serversfile) +
                ", kept while " + legacy.PRODUCT + " is installed or active; DNS protection is not attached");
    }

    let state = {
        active: true,
        reason: as_string(reason),
        updated_at: now(),
        sections: names,
        rule_sections: array_or_empty(nft_result.rule_sections),
        set_elements: int(nft_result.set_elements),
        dns: dns_result.ok ? {
            managed: dns_result.managed === true,
            domains: int(dns_result.domains),
            exceptions: int(dns_result.exceptions),
            shadowed: int(dns_result.shadowed),
            invalid: int(dns_result.invalid),
            uncovered_keyword: int(dns_result.uncovered_keyword),
            uncovered_regex: int(dns_result.uncovered_regex),
            uncovered_inverted: int(dns_result.uncovered_inverted),
            client_limited: int(dns_result.client_limited),
            excluded_devices: int(dns_result.excluded_devices),
            sections: object_or_empty(dns_result.sections)
        } : object_or_empty(read_state().dns),
        warnings,
        last_error: "",
        last_error_at: 0
    };
    // Only with an exemption (D-23): the state of every other configuration
    // stays as it was.
    if (dns_result.ok && int(dns_result.excluded_exempt) > 0)
        state.dns.excluded_exempt = int(dns_result.excluded_exempt);
    if (dns_result.ok && int(dns_result.exempt_groups) > 0) {
        state.dns.exempt_groups = int(dns_result.exempt_groups);
        state.dns.exempt_sig = as_string(dns_result.exempt_sig);
    }
    // The service runs the resolvers of the groups the state names.
    write_state(state);
    if (!service_control([ "enable", "start" ])) {
        push(warnings, "the kill-switch service could not be started; DNS will not fail over to the standby resolver if sing-box dies");
        write_state(state);
    }
    log_message(sprintf("Kill-switch protection refreshed for %s (%s)", join(", ", names), as_string(reason)), "info");
    for (let warning in warnings)
        log_message("Kill-switch: " + warning, "warn");
    return 0;
}

// Start and reload refresh the policy while they hold reload.lock
// themselves (reload_lock_held). Every other caller takes it first, so a
// manual sync or removal never changes dnsmasq or the policy in the middle
// of a start, stop or reload, and gives up while one runs. A removal for the
// package (force) never stays behind a lock: once the bounded wait is over
// it removes the protection anyway, since nothing would be left to do it.
// A manual operation applies the reloads queued behind its reload.lock
// (apply_pending); a stopped or a package-changing Prokop has none to run.
function with_lock(callback, options) {
    let reload_lock_held = options.reload_lock_held === true;
    let force = options.force === true;
    let apply_pending = options.apply_pending === true;
    let reload_locked = false;
    if (!reload_lock_held) {
        reload_locked = acquire_dir_lock(RELOAD_LOCK_DIR);
        if (!reload_locked && !force) {
            warn("Prokop is starting, stopping or reloading; try the kill-switch operation again when it is done\n");
            log_message("Kill-switch: Prokop is starting, stopping or reloading; the kill-switch was not changed", "warn");
            return 1;
        }
    }
    let locked = acquire_dir_lock(LOCK_DIR);
    if (!locked && !force) {
        if (reload_locked)
            release_reload_lock(apply_pending);
        warn("Another kill-switch operation is still running\n");
        log_message("Kill-switch: another kill-switch operation is still running", "error");
        return 1;
    }
    if (!locked || (!reload_lock_held && !reload_locked))
        log_message("Kill-switch: a lock is still held; removing the protection anyway", "warn");

    let status = 1;
    try {
        status = callback();
    }
    catch (e) {
        record_error("unexpected failure: " + as_string(e));
        status = 1;
    }
    if (locked)
        runtime_lock.release(LOCK_DIR, self_pid());
    if (reload_locked)
        release_reload_lock(apply_pending);
    return status;
}

function sync(reason, reload_lock_held) {
    return with_lock(function() { return sync_locked(reason || "manual", !reload_lock_held); },
        { reload_lock_held, apply_pending: true });
}

// Prokop stopped by the user or not started since boot (D-15): reloads,
// restores and configuration changes never reach start or reload, which
// refresh the kill-switch. Lifting it needs no runtime, so a configuration
// that protects no section any more lifts it here (UC-208). One that still
// protects a section keeps the last applied protection, the blocking side,
// until the next start renders it again. A start or reload whose table lacks
// the list generation of the configuration (UC-209) follows it the same way.
// Who is exempt from the DNS block (D-23) follows a change at once, to the
// blocking side: a changed exemption ends until the next start renders it.
// So do groups another sync left behind (exempt_data).
function exempt_outdated(sections) {
    if (fs.stat(EXEMPT_FILE) == null)
        return false;
    let data = exempt_data();
    return data == null || as_string(data.fingerprint) != exempt_fingerprint(sections);
}

function follow_stopped_config(reason, reload_lock_held) {
    let sections = config_sections();
    let protecting = length(protected_section_names(sections)) > 0;
    let outdated = protecting && exempt_outdated(sections);
    if ((protecting && !outdated) || !protection_present())
        return 0;
    // A skipped reload is not held up for long behind a lifecycle action.
    if (lock_attempts > 10)
        lock_attempts = 10;
    if (outdated)
        return with_lock(function() {
            return drop_exemption("the exemption changed while Prokop is stopped") ? 0 : 1;
        }, { reload_lock_held });
    return with_lock(function() { return sync_locked(reason || "reload while Prokop is stopped"); },
        { reload_lock_held });
}

function disable(reason, force) {
    reason = as_string(reason) || "disabled on request";
    return with_lock(function() {
        let release_legacy = false;
        if (legacy_present()) {
            release_legacy = legacy_release_allowed(STRICT_LEGACY_REASONS[reason] === true);
            if (!release_legacy)
                log_message("Kill-switch: the " + legacy.PRODUCT + " kill-switch stays in place: " + legacy.PRODUCT +
                    " is still " + (legacy.active() ? "active" : "installed"), "warn");
        }
        return teardown(reason, release_legacy) ? 0 : 1;
    }, { force, apply_pending: !force });
}

// A package upgrade from the first kill-switch build: its unguarded fw4
// include becomes the saved policy that only the package's loader loads, so
// the protection stays across the upgrade, and a running watcher is
// restarted on the new code. Neither dnsmasq nor the live table change:
// killswitch.lock alone serializes it with a sync.
//
// That build may also have run after this one (a change of version that kept
// the saved policy, and back): it never reads the saved policy, and every
// sync or removal here deletes the unguarded include, so what it did last is
// the newer protection. Its include replaces the saved policy; without one,
// a removal it recorded (state.json of format 1 with active false) makes the
// saved policy stale. A failed sync of it keeps the previous protection.
function postinst() {
    return with_lock(function() {
        let first_include = fs.readfile(LEGACY_NFT_INCLUDE);
        let state = read_state();
        if (first_include != null && length(first_include) > 0) {
            if (fs.readfile(NFT_POLICY) != first_include && !write_durable(NFT_POLICY, first_include)) {
                record_error("could not adopt " + LEGACY_NFT_INCLUDE);
                return 1;
            }
        }
        else if (policy_saved() && int(state.format) < STATE_FORMAT && state.active === false) {
            if (!fs.unlink(NFT_POLICY)) {
                record_error("could not remove the saved policy the first kill-switch build had removed");
                return 1;
            }
            log_message("Kill-switch: the saved policy predates its removal by the first kill-switch build and is removed", "info");
        }
        if (first_include != null)
            remove_legacy_include();
        // A reinstall after a sysupgrade to an image without Prokop finds
        // the saved policy (lib/upgrade/keep.d) but no rc.d link of the
        // service: fw4 loads the policy again through this package's
        // loader, and only the service's boot() attaches the DNS block list
        // that goes with it.
        if (policy_saved())
            service_control([ "enable" ]);
        if (service_running())
            service_control([ "restart" ]);
        return 0;
    }, { reload_lock_held: true });
}

function status() {
    let sections = config_sections();
    let state = read_state();
    let configured = protected_section_names(sections);
    // Loaded again by fw4 only while the package's loader is installed.
    let persistent = policy_saved() && fs.stat(NFT_LOADER) != null;
    let table_present = ks_table_present();
    let prokop_running = live_table_present();
    let config = prokop_running ? common.read_json_file(sing_box_config_path(config_settings())) : null;
    print(sprintf("%J", {
        configured,
        active: table_present,
        persistent,
        prokop_running,
        // Not routed by the running Prokop yet; it rejects their traffic.
        unrouted: type(config) == "object" ? unrouted_sections(config, configured) : [],
        pending: length(configured) > 0 && !table_present,
        counters: table_present ? nft_counters() : {},
        dns: dns_status(),
        dns_standby: table_present && dns_redirect_state() === true,
        // The excluded devices of exempting sections use their resolvers now.
        dns_exempt: table_present && exempt_redirect_tag(as_string(dns_chain_listing())) != "",
        service_running: service_running(),
        // What the kill-switch of the product before the rename left; a
        // disable lifts it once that product is no longer active.
        legacy: legacy_status(),
        state
    }), "\n");
    return 0;
}

function render_dns_fixture(config_path, names_csv, out_path) {
    let names = filter(split(as_string(names_csv), ","), (value) => value != "");
    ruleset_cache_used = {};
    let rendered = render_dns_from_config(common.read_json_file(config_path), names);
    if (rendered.ok && as_string(out_path) != "")
        fs.writefile(out_path, rendered.content);
    delete rendered.content;
    print(sprintf("%J", rendered), "\n");
    return rendered.ok ? 0 : 1;
}

let mode = ARGV[0] || "";

if (mode == "sync")
    exit(sync(ARGV[1], ARGV[2] == "reload-lock-held"));
else if (mode == "disable")
    exit(disable(ARGV[1], false));
else if (mode == "release")
    exit(disable(ARGV[1] || "removed with the package", true));
else if (mode == "status")
    exit(status());
else if (mode == "render-dns-fixture")
    exit(render_dns_fixture(ARGV[1], ARGV[2], ARGV[3]));
else if (mode == "follow-stopped-config")
    exit(follow_stopped_config(ARGV[1], ARGV[2] == "reload-lock-held"));
else if (mode == "postinst")
    exit(postinst());
else if (mode == "armed")
    exit(policy_saved() ? 0 : 1);
else if (mode == "standby-config")
    exit(write_standby_config(ARGV[1]) ? 0 : 1);
else if (mode == "exempt-configs")
    exit(write_exempt_configs(ARGV[1] || CACHE_DIR) ? 0 : 1);
else if (mode == "dns-redirect")
    exit(dns_redirect(ARGV[1]));
else if (mode == "watch")
    exit(watch());

warn("Usage: killswitch/runtime.uc <sync [reason [reload-lock-held]]|disable [reason]|release [reason]|follow-stopped-config [reason [reload-lock-held]]|postinst|status|armed|standby-config <path>|exempt-configs <dir>|dns-redirect <on|off>|watch>\n");
exit(1);
