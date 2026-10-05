#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let constants = require("core.constants");
let durable = require("core.durable");
let legacy = require("core.legacy_forkop");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = env("PROKOP_CONFIG_NAME", "prokop");
const CONFIG_PATH = env("PROKOP_CONFIG_PATH", "/etc/config/prokop");
const DEFAULT_CONFIG_PATH = env("PROKOP_DEFAULT_CONFIG_PATH", "/usr/share/prokop/defaults/prokop");
const RT_TABLES_PATH = env("PROKOP_RT_TABLES", "/etc/iproute2/rt_tables");
const BIN_PATH = env("PROKOP_BIN", "/usr/bin/prokop");
const INIT_PATH = env("PROKOP_INIT", "/etc/init.d/prokop");
const LIB_DIR = env("PROKOP_LIB", "/usr/lib/prokop");
const DNS_APPLY_UC = env("PROKOP_DNS_APPLY_UC", "/usr/lib/prokop/dns/apply.uc");
const KILLSWITCH_UC = env("PROKOP_KILLSWITCH_UC", "/usr/lib/prokop/killswitch/runtime.uc");
const SING_BOX_INIT = env("PROKOP_SING_BOX_INIT", "/etc/init.d/sing-box");
const SING_BOX_BIN = env("PROKOP_SING_BOX_BIN", "/usr/bin/sing-box");
const SING_BOX_CRONET = env("PROKOP_SING_BOX_CRONET", "/usr/lib/libcronet.so");
const SING_BOX_MANAGED_MARKER = env("SB_MANAGED_SERVICE_MARKER", "Prokop managed sing-box service for binary variants");
const TORRSERVER_DIRECT_INIT = env("PROKOP_TORRSERVER_DIRECT_INIT", "/etc/init.d/prokop-torrserver-direct");
const TORRSERVER_INIT = env("PROKOP_TORRSERVER_INIT", "/etc/init.d/prokop-torrserver");
const DNS_FAILSAFE_INIT = env("PROKOP_DNS_FAILSAFE_INIT", "/etc/init.d/prokop-dns-failsafe");
const FW_WATCH_INIT = env("PROKOP_FW_WATCH_INIT", "/etc/init.d/prokop-fw-watch");
const RC_D_DIR = env("PROKOP_RC_D_DIR", "/etc/rc.d");
// The rc.d links of releases whose prokop-torrserver-direct had START=100
// and STOP=9: rc.common's disable (S??, K??) never removes them, and its
// enabled looks for the links of the current values (UC-161).
const TORRSERVER_DIRECT_LEGACY_LINKS = [ "S100prokop-torrserver-direct", "K9prokop-torrserver-direct" ];
const CRONTAB_FILE = env("PROKOP_CRONTAB_FILE", "/etc/crontabs/root");
// The markers of Prokop's lines in the crontab (service/lifecycle.uc,
// autotune/manager.uc).
const CRON_MARKERS = /# prokop-(list-update|subscription-update|component-update-check|autotune)/;
const PACKAGE_UPGRADE_STATE = env("PROKOP_PACKAGE_UPGRADE_STATE", "/tmp/prokop-package-was-running");
const UPGRADE_SING_BOX_WAIT_SECONDS = int(env("PROKOP_UPGRADE_SING_BOX_WAIT_SECONDS", "15"));
// The start after an upgrade runs while the package manager holds its lock;
// a slow cold start must not hold the package operation up for the start's
// full timeout. The start carries on after this bound, logs its outcome and
// schedules its own retry.
const POSTINST_START_WAIT_SECONDS = env("PROKOP_POSTINST_START_WAIT_SECONDS", "60");
const POSTINST_USER_STOPPED = "Prokop was not started after the package upgrade: it was stopped by the user during the upgrade; start it to run it again";
const PROC_DIR = env("PROKOP_PROC_DIR", "/proc");
const COMPONENT_UPDATE_CHECK_CACHE_DIR = env("PROKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR", "/var/run/prokop/component-update-checks");
const COMPONENT_UPDATE_CHECK_STATE_FILE = env("PROKOP_COMPONENT_UPDATE_CHECK_STATE_FILE", "/var/run/prokop/component-update-check.timestamp");
const PACKAGE_TEST_MODE = env("PROKOP_PACKAGE_TEST_MODE", "") != "";
// Root prefix for the retired VPN fail-closed guard's paths (tests only).
const LEGACY_GUARD_ROOT = env("PROKOP_LEGACY_GUARD_ROOT", "");
const LEGACY_GUARD_TABLE = "ForkopVpnGuard";
const LEGACY_GUARD_SERVICE = "forkop-guard";
const LEGACY_GUARD_FIREWALL_INCLUDE = "firewall.forkop_vpn_guard";
const LEGACY_GUARD_OFFLOAD_KEYS = [ "flow_offloading", "flow_offloading_hw" ];

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

// Status and standard output (stderr discarded).
function command_capture_from_args(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return { status: 1, output: "" };
    let output = as_string(pipe.read("all"));
    return { status: normalize_status(pipe.close()), output };
}

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function path_basename(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, slash + 1) : path;
}

// A package replacement renames the executable link of an already running
// sing-box to "sing-box (deleted)". That process still holds the runtime, so
// the upgrade must keep counting it instead of concluding it has exited.
function sing_box_exe_path(path) {
    let basename = path_basename(path);
    return basename == "sing-box" || basename == "sing-box (deleted)";
}

function sing_box_process_count() {
    let count = 0;
    for (let exe_path in fs.glob(PROC_DIR + "/[0-9]*/exe"))
        if (sing_box_exe_path(as_string(fs.readlink(exe_path))))
            count++;
    return count;
}

function wait_for_upgrade_sing_box_exit() {
    let timeout = UPGRADE_SING_BOX_WAIT_SECONDS;

    // prerm stops the old service, but its sing-box child exits asynchronously.
    // postinst would otherwise reach the guarded start while that process is
    // still present, and the start refuses an ambiguous runtime by design -
    // leaving Prokop stopped after an ordinary package upgrade. Wait for the
    // process to leave on its own; never kill anything by name.
    while (sing_box_process_count() > 0) {
        if (timeout <= 0)
            return false;
        command_success_from_args([ "sleep", "1" ]);
        timeout--;
    }

    return true;
}

function unlink_if_exists(path) {
    if (path_exists(path))
        fs.unlink(as_string(path));
}

function clear_component_update_check_cache() {
    for (let path in fs.glob(COMPONENT_UPDATE_CHECK_CACHE_DIR + "/*"))
        unlink_if_exists(path);
    unlink_if_exists(COMPONENT_UPDATE_CHECK_STATE_FILE);
}

// rt_tables names the tables of other packages too. It is written to a copy
// next to it, read back, flushed and renamed over it, never truncated and
// rewritten in place, where a crash or a full overlay lost every entry
// (UC-076): core/durable.uc, as the start does (nft/apply.uc). The mode
// stays; a symlink stays one and the file it points to is replaced.
function replace_rt_tables(data) {
    return durable.durable_rewrite(RT_TABLES_PATH, data, 0644);
}

// The entry of the product before the rename (core/legacy_forkop.uc), which
// a migration or its old package removal may have left. It names the same
// table id, so `ip rule` would show Prokop's rule under the old name. It is
// the old product's own while that package is installed.
function legacy_rt_tables_line(line) {
    let fields = split(trim(as_string(line)), /[ \t]+/);
    return length(fields) >= 2 && fields[0] == legacy.RT_TABLE_ID && fields[1] == legacy.RT_TABLE_NAME;
}

function remove_rt_tables_entry() {
    let data = fs.readfile(RT_TABLES_PATH);
    if (data == null)
        return true;

    let strip_legacy = !legacy.installed();
    let changed = false;
    let lines = [];
    for (let line in split(data, "\n")) {
        if (index(line, "105 prokop") >= 0 || (strip_legacy && legacy_rt_tables_line(line))) {
            changed = true;
            continue;
        }
        push(lines, line);
    }

    return !changed || replace_rt_tables(join("\n", lines));
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function truthy(value) {
    value = ascii_lower(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function dont_touch_dhcp_enabled() {
    return truthy(uci_core.get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

function restore_dnsmasq_if_needed() {
    if (dont_touch_dhcp_enabled())
        return;

    command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);
    // dns/apply.uc loads Prokop's modules: without the library path it
    // could never run (UC-078).
    if (path_exists(DNS_APPLY_UC))
        command_success_from_args([ "ucode", "-L", LIB_DIR, DNS_APPLY_UC, "failsafe-restore" ]);
}

// A managed service script the product before the rename wrote is Prokop's
// once that package is gone (a migration that did not rewrite its marker).
function managed_sing_box_script(data) {
    if (data == null)
        return false;
    if (index(data, SING_BOX_MANAGED_MARKER) >= 0)
        return true;
    return !legacy.installed() && index(data, legacy.SING_BOX_MANAGED_MARKER) >= 0;
}

// keep_running: the sing-box still serves an interception that a removal
// could not take down. Its files go with the package and its autostart
// with them; the process serves on until a reboot clears both.
function remove_managed_sing_box(keep_running) {
    let data = fs.readfile(SING_BOX_INIT);
    if (!managed_sing_box_script(data))
        return;

    if (!keep_running)
        command_success_from_args([ SING_BOX_INIT, "stop" ]);
    command_success_from_args([ SING_BOX_INIT, "disable" ]);
    unlink_if_exists(SING_BOX_INIT);
    unlink_if_exists(SING_BOX_BIN);
    unlink_if_exists(SING_BOX_CRONET);
}

// Removes the rc.d links an older release made for TorrServer Direct;
// true when there were any.
function remove_torrserver_direct_legacy_links() {
    let found = false;
    for (let name in TORRSERVER_DIRECT_LEGACY_LINKS) {
        let path = RC_D_DIR + "/" + name;
        if (fs.lstat(path) != null) {
            fs.unlink(path);
            found = true;
        }
    }
    return found;
}

function torrserver_direct_switched_on() {
    return trim(as_string(uci_core.get(CONFIG_NAME + ".settings.torrserver_direct_enabled"))) == "1";
}

// A removal leaves nothing running of the package's second service: its
// worker would go on from the loaded script and its stop removes its nft
// table (UC-083). The rc.d links of both services stay, as they did: opkg's
// install --force-reinstall (the in-app rollback of a failed upgrade, the
// usual manual repair) runs this "prerm remove" before the package goes back
// on, and the postinst of no release enables Prokop again. Full uninstall
// removes them; after a plain removal they point to scripts that are gone,
// which the boot cannot run and passes over.
function stop_torrserver_direct() {
    if (path_exists(TORRSERVER_DIRECT_INIT))
        command_success_from_args([ TORRSERVER_DIRECT_INIT, "stop" ]);
}

// The TorrServer Direct worker keeps running across an upgrade on the code it
// was started with, and a reinstall stopped it: restart it on the new code
// when it is switched on and enabled (UC-083). The links of an older release
// become the current ones, or just go when it is switched off (UC-161).
function torrserver_direct_postinst() {
    if (!path_exists(TORRSERVER_DIRECT_INIT))
        return;
    let on = torrserver_direct_switched_on();
    if (remove_torrserver_direct_legacy_links() && on)
        command_success_from_args([ TORRSERVER_DIRECT_INIT, "enable" ]);
    if (on && command_success_from_args([ TORRSERVER_DIRECT_INIT, "enabled" ]))
        command_success_from_args([ TORRSERVER_DIRECT_INIT, "restart" ]);
}

// TorrServer installed by Prokop runs from the package's init script: a
// removal stops it with the script that goes. An upgrade leaves it running
// (procd keeps the instance; streams go on), and a reinstall, whose "prerm
// remove" stopped it, starts it again when its autostart is on.
function stop_torrserver() {
    if (path_exists(TORRSERVER_INIT))
        command_success_from_args([ TORRSERVER_INIT, "stop" ]);
}

function torrserver_postinst() {
    if (path_exists(TORRSERVER_INIT) && command_success_from_args([ TORRSERVER_INIT, "enabled" ]))
        command_success_from_args([ TORRSERVER_INIT, "start" ]);
}

// The boot hook that hands DNS back to dnsmasq when Prokop will not start
// (LC-1) must run whatever autostart is: always enabled. OpenWrt's default
// postinst enables it on a first install only, build.sh's packages never.
function dns_failsafe_postinst() {
    if (path_exists(DNS_FAILSAFE_INIT) &&
        !command_success_from_args([ DNS_FAILSAFE_INIT, "enabled" ]))
        command_success_from_args([ DNS_FAILSAFE_INIT, "enable" ]);
}

// The firewall watcher (NET-4) reloads Prokop when fw4 took ProkopTable
// away; it does nothing while Prokop is stopped, so it is always enabled,
// and it is restarted on the new code. It stops before the package change
// stops Prokop: a reload must not meet a half-replaced package.
function fw_watch_postinst() {
    if (!path_exists(FW_WATCH_INIT))
        return;
    if (!command_success_from_args([ FW_WATCH_INIT, "enabled" ]))
        command_success_from_args([ FW_WATCH_INIT, "enable" ]);
    command_success_from_args([ FW_WATCH_INIT, "restart" ]);
}

function stop_fw_watch() {
    if (path_exists(FW_WATCH_INIT))
        command_success_from_args([ FW_WATCH_INIT, "stop" ]);
}

function remember_upgrade_state(action) {
    // An explicit removal is unambiguous: nothing should be restored later.
    if (as_string(action) == "remove") {
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
        return;
    }

    // opkg runs prerm as "upgrade <new version>" or "remove" and sets
    // PKG_UPGRADE for it (opkg-lede: libopkg opkg_install.c
    // prerm_upgrade_old_pkg, opkg_remove.c, pkg.c pkg_run_script). The
    // package scripts pass an empty action on only under PKG_UPGRADE=1
    // (build.sh, prokop/Makefile), which no known opkg sends without an
    // action, and `prokop package_prerm` run by hand passes none. Such a
    // prerm is not taken for a removal: that would erase the only hand-off
    // telling postinst to restart a service that prerm has just stopped, and
    // the router would come back with Prokop down. Service state decides:
    // record a restart only when Prokop was actually running immediately
    // before prerm, or a start deferred for reload.lock was still to run: the
    // stop below cancels it, as Prokop's own stop also when the user's stop
    // came before that start (service/initd.uc stop_request_source). A
    // Prokop that runs while the user's stop is recorded is on its way down:
    // the stop below is then recorded as the user's, and postinst leaves
    // Prokop down (D-15(a)).
    if (command_success_from_args([ INIT_PATH, "status" ]) ||
        command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/initd.uc", "deferred-start-pending" ]))
        fs.writefile(PACKAGE_UPGRADE_STATE, "1\n");
    else
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
}

// The newest release without the VPN kill-switch. Older code neither knows
// its persistent policy nor can lift it.
const LAST_RELEASE_WITHOUT_KILLSWITCH = [ 1, 0, 31 ];

// true or false for an x.y.z[-...] release version, null when unknown.
// 0.0.0 is no release: every SDK build without a release version carries it
// (prokop/Makefile PKG_VERSION), also one that predates the kill-switch and
// can never lift its DNS block list. It counts as a release without the
// kill-switch; a build that has it protects again from its next start.
function release_has_killswitch(version) {
    let parts = match(as_string(version), /^([0-9]+)\.([0-9]+)\.([0-9]+)/);
    if (parts == null)
        return null;
    for (let i = 0; i < 3; i++) {
        let value = int(parts[i + 1]);
        if (value != LAST_RELEASE_WITHOUT_KILLSWITCH[i])
            return value > LAST_RELEASE_WITHOUT_KILLSWITCH[i];
    }
    return false;
}

// The kill-switch must never outlive the code that can lift it (UC-191): a
// removal lifts it, and so does a change to a release without it. opkg runs
// this package's prerm with the new version; apk runs the incoming
// package's pre-upgrade, which passes its version from this release on and
// none in every release up to 1.0.31. Any other change keeps the protection
// across the stop the package change needs.
function killswitch_outlives_package(action, version) {
    action = as_string(action);
    if (action == "remove")
        return true;
    if (action != "upgrade")
        return false;
    let supported = release_has_killswitch(version);
    if (supported != null)
        return !supported;
    return command_success_from_args([ "sh", "-c", "command -v apk" ]);
}

function nft_table_present(name) {
    return command_success_from_args([ "nft", "-t", "list", "table", "inet", name ]);
}

// Prokop's interception that is in place, one entry each: its nft table, or
// its fwmark rule at priority 105 that routes marked traffic to the table of
// its sing-box listener (by the table's name, or by number once rt_tables
// lost it, or under another name of table 105 with Prokop's fwmark: iproute2
// shows the last rt_tables name of an id, Podkop's for one, NET-3).
function interception_left() {
    let left = [];
    let table = constants.NFT_TABLE_NAME || "ProkopTable";
    if (nft_table_present(table))
        push(left, "nft table inet " + table);
    let lookup = constants.RT_TABLE_NAME || "prokop";
    let mark = hex(constants.NFT_FAKEIP_MARK || "0x04000000");
    for (let family in [ "4", "6" ])
        for (let line in split(command_capture_from_args([ "ip", "-" + family, "rule", "show" ]).output, "\n")) {
            let rule = match(line, /^105:.*[ \t]lookup[ \t]+([^ \t]+)/);
            let fwmark = match(line, /[ \t]fwmark[ \t]+(0x[0-9a-fA-F]+)\/(0x[0-9a-fA-F]+)/);
            if (rule != null && (rule[1] == lookup || rule[1] == "105" ||
                (fwmark != null && hex(fwmark[1]) == mark && hex(fwmark[2]) == mark))) {
                push(left, "IPv" + family + " rule 105");
                break;
            }
        }
    return left;
}

function prokop_interception_present() {
    return length(interception_left()) > 0;
}

// What Prokop's stop is to take down and did not: its interception and its
// lines in the crontab, which would call a removed /usr/bin/prokop.
function runtime_left() {
    let left = interception_left();
    if (match(as_string(fs.readfile(CRONTAB_FILE)), CRON_MARKERS) != null)
        push(left, "scheduled jobs in " + CRONTAB_FILE);
    return left;
}

// What a removal left of Prokop (UC-028): besides the runtime, the
// kill-switch it could not lift (its table, and the saved policy its fw4
// loader would load again on a reinstall), the TorrServer Direct table and
// the fail-closed DPI guards. Prokop's stop leaves the guard of a restore or
// an autotune apply that ended needs_attention, which only a restore
// releases: it stays across a reinstall, and after a removal until a
// reboot or Full uninstall.
function removal_left() {
    let left = runtime_left();
    let killswitch_table = constants.KILLSWITCH_NFT_TABLE || "ProkopKillswitch";
    let table_name = constants.NFT_TABLE_NAME || "ProkopTable";
    for (let table in [ killswitch_table, "ProkopTorrServerDirect", "ProkopTraffic", table_name + "DpiGuard", "ProkopConfigRestoreDpiGuard" ])
        if (nft_table_present(table))
            push(left, "nft table inet " + table);
    let policy = constants.KILLSWITCH_NFT_POLICY || "/etc/prokop/killswitch/policy.nft";
    if (path_exists(policy))
        push(left, "saved kill-switch policy " + policy);
    return left;
}

// The package managers discard prerm's output (build.sh, prokop/Makefile):
// what goes wrong here must reach the system log.
function log_warning(message) {
    warn(message + "\n");
    command_success_from_args([ "logger", "-t", "prokop", "[warn] " + message ]);
}

function log_error(message) {
    warn(message + "\n");
    command_success_from_args([ "logger", "-t", "prokop", "[error] " + message ]);
}

function log_info(message) {
    warn(message + "\n");
    command_success_from_args([ "logger", "-t", "prokop", "[info] " + message ]);
}

// Only apk passes a failed prerm on, from the incoming package's
// pre-upgrade (in every release), and keeps the installed Prokop. opkg's
// prerm and every pre-deinstall go on with the change whatever prerm
// returns.
function package_change_stops_on_failure(action) {
    return as_string(action) == "upgrade" && command_success_from_args([ "sh", "-c", "command -v apk" ]);
}

function prerm_cleanup(action, version) {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    remember_upgrade_state(action);
    if (!PACKAGE_TEST_MODE) {
        stop_fw_watch();
        // Prokop's own stop for the package change, not the user's
        // (service/initd.uc stop_request_source).
        let removal = as_string(action) == "remove";
        let stopped = command_success_from_args([ "env", "PROKOP_STOP_SOURCE=package", INIT_PATH, "stop" ]);
        // A removal leaves nobody to own what a failed or refused stop kept
        // (UC-028): the explicit stop, as the user's (PROKOP_STOP_SOURCE=user),
        // removes Prokop's own interception without a proof of ownership and
        // stops only the sing-box Prokop owns (UC-213). It names its source:
        // the plain stop of OpenWrt's default prerm, which an SDK package runs
        // around this one, stops nothing (/etc/init.d/prokop stop_service).
        // What the stop left decides, not its exit status: rc.common drops
        // the status of stop_service unless a hook passes it on, and a stop
        // that cannot delete the table or the rule goes on.
        let left = removal ? runtime_left() : [];
        if (length(left) > 0) {
            log_warning("Prokop's stop for its removal left " + join(", ", left) + "; taking it down with an explicit stop");
            command_success_from_args([ "env", "PROKOP_STOP_SOURCE=user", INIT_PATH, "stop" ]);
        }
        // No start follows a removal: the explicit start ends with it, and
        // a reinstall that does not start Prokop shows it not started, not
        // as a start that failed (service/initd.uc EXPLICIT_START_FILE;
        // D-15(a)).
        if (removal) {
            command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/initd.uc", "clear-explicit-start" ]);
            stop_torrserver_direct();
            stop_torrserver();
        }
        // A stop that failed or was refused (another sing-box makes
        // ownership ambiguous) may have left Prokop's nft table and ip rule
        // in place. An upgrade then keeps their listener, the managed
        // sing-box, its DNS and the routing table name: without them the
        // interception would black-hole traffic with nobody left to own it
        // (UC-197). After an upgrade whose stop succeeded, the start in
        // postinst brings the runtime back over whatever the stop left.
        let intercepting = (removal || !stopped) && prokop_interception_present();
        // An upgrade keeps the kill-switch: protected traffic must stay
        // blocked while the old runtime is down. A removal or a release
        // without the kill-switch lifts it, since nothing would be left to
        // manage the persistent policy; unless the change does not happen:
        // apk keeps the installed Prokop when this prerm fails.
        if (killswitch_outlives_package(action, version) && path_exists(KILLSWITCH_UC) &&
            !(intercepting && package_change_stops_on_failure(action)))
            command_success_from_args([ "ucode", "-L", LIB_DIR, KILLSWITCH_UC, "release",
                removal ? "package removal" :
                "change to a release without the kill-switch (" + (as_string(version) || "unknown version") + ")" ]);
        if (intercepting && !removal) {
            log_warning("Prokop did not stop and still intercepts traffic; its sing-box, DNS and routing were left in place");
            return false;
        }
        // The DNS configuration outlives the package. Whatever a removal
        // could not take down is gone after a reboot.
        restore_dnsmasq_if_needed();
        // The managed sing-box (a binary variant Prokop installed itself,
        // not a package) goes with a removal only: no package brings it
        // back, so an upgrade that took it left the new release without a
        // core (A7).
        if (removal)
            remove_managed_sing_box(intercepting);
        if (intercepting)
            log_warning("Prokop could not be stopped for its removal and still intercepts traffic until a reboot; its DNS was restored");
        if (removal) {
            let removed = remove_rt_tables_entry();
            // The package managers go on with a removal whatever prerm
            // returns: it never reports success with something of Prokop
            // in place, and the system log says what (UC-028).
            left = removal_left();
            if (length(left) > 0) {
                log_warning("Prokop's removal left in place: " + join(", ", left));
                return false;
            }
            return removed;
        }
    }
    return remove_rt_tables_entry();
}

function read_json_or_null(path) {
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

// The per-section kill-switch replaced the global VPN fail-closed guard
// (ForkopVpnGuard, /etc/init.d/forkop-guard). An upgrade removes the guard's
// files, but not what it left running or changed: its procd service with the
// standby dnsmasq instances and watcher, the DNS redirect in its nft table
// (after the old prerm's stop all client DNS goes to those instances), the
// firewall include and the disabled flow offload. Undo all of it here, before
// Prokop is started again. config/migration.uc carries its protection over to
// the sections.
function legacy_vpn_guard_cleanup() {
    let root = LEGACY_GUARD_ROOT;
    let state_dir = root + "/etc/forkop/vpn-guard";
    let runtime_dir = root + "/tmp/forkop-vpn-guard";
    let init_script = root + "/etc/init.d/" + LEGACY_GUARD_SERVICE;
    let has_table = command_success_from_args([ "sh", "-c", "nft list table inet " + LEGACY_GUARD_TABLE + " >/dev/null 2>&1" ]);
    let has_include = uci_core.exists(LEGACY_GUARD_FIREWALL_INCLUDE);
    if (!has_table && !has_include && !path_exists(state_dir) && !path_exists(runtime_dir) && !path_exists(init_script))
        return true;

    // Saved offload values live only in the guard's policy snapshot; old
    // versions kept them in the firewall include section.
    let saved = {};
    let policy = read_json_or_null(state_dir + "/policy.json");
    if (type(policy) == "object" && type(policy.saved_offload) == "object")
        saved = policy.saved_offload;
    for (let key in LEGACY_GUARD_OFFLOAD_KEYS)
        if (saved[key] == null && has_include)
            saved[key] = uci_core.get(LEGACY_GUARD_FIREWALL_INCLUDE + ".saved_" + key);

    command_success_from_args([ "ubus", "call", "service", "delete", sprintf("%J", { name: LEGACY_GUARD_SERVICE }) ]);
    let rc_dir = root + "/etc/rc.d";
    for (let name in (fs.lsdir(rc_dir) || []))
        if (match(name, /^[SK][0-9]+forkop-guard$/) != null)
            fs.unlink(rc_dir + "/" + name);

    // The guard's forward rejects stay until the first successful kill-switch
    // sync replaces them (killswitch/runtime.uc), so an upgrade never leaves
    // a window without protection. Only its client DNS redirect goes now:
    // the standby resolvers it pointed to were just stopped.
    if (has_table)
        command_success_from_args([ "sh", "-c", "nft flush chain inet " + LEGACY_GUARD_TABLE + " dns >/dev/null 2>&1; true" ]);
    // DNS flows already redirected to the stopped standby keep their NAT.
    command_success_from_args([ "sh", "-c", "conntrack -D -p udp --dport 53 >/dev/null 2>&1; conntrack -D -p tcp --dport 53 >/dev/null 2>&1; true" ]);

    let firewall_changed = false, firewall_saved = true;
    for (let key in LEGACY_GUARD_OFFLOAD_KEYS) {
        if (as_string(saved[key]) == "1" && as_string(uci_core.get("firewall.@defaults[0]." + key)) != "1") {
            firewall_saved = uci_core.set("firewall.@defaults[0]." + key, "1") && firewall_saved;
            firewall_changed = true;
        }
    }
    if (has_include) {
        firewall_saved = uci_core.delete(LEGACY_GUARD_FIREWALL_INCLUDE) && firewall_saved;
        firewall_changed = true;
    }
    // A firewall the overlay does not save (full, read-only) keeps the
    // guard's state directory: the saved offload values live there, and the
    // next postinst tries again (UC-024).
    if (firewall_changed) {
        firewall_saved = firewall_saved && uci_core.commit("firewall");
        if (firewall_saved)
            command_success_from_args([ "sh", "-c", "[ ! -x /etc/init.d/firewall ] || /etc/init.d/firewall reload >/dev/null 2>&1" ]);
        else
            log_warning("Could not save the firewall settings the retired VPN guard changed (flow offload, its include); the next package install tries again");
    }

    command_success_from_args([ "rm", "-rf", ...(firewall_saved ? [ state_dir ] : []), runtime_dir ]);
    for (let path in [ init_script, root + "/etc/hotplug.d/iface/95-forkop-guard",
        root + "/lib/upgrade/keep.d/forkop-guard", root + "/usr/share/forkop/vpn-guard-firewall.sh" ])
        unlink_if_exists(path);
    return firewall_saved;
}

// The configuration holds secrets (the Clash API secret, D-1; subscription
// URLs, WAN credentials): only root reads it, 0600 as the packages install
// it. Releases before installed it 0644, and a configuration kept across the
// upgrade keeps its mode: it is narrowed here, on the first package change
// that finds it wider. libuci and Prokop's own writers keep the mode
// (core/durable.uc durable_rewrite). A configuration that cannot be changed
// (a read-only overlay) is still read as it is: the package change goes on.
function protect_config_mode() {
    let info = fs.stat(CONFIG_PATH);
    if (info != null && (info.mode & 0077) != 0 && !fs.chmod(CONFIG_PATH, 0600))
        warn("Unable to make the Prokop configuration readable by root only.\n");
}

// A missing or empty configuration comes back from the packaged defaults.
// The package scripts restore it before the migrations, which fail without
// it (build.sh write_backend_postinst, mode restore-config; UC-077), and
// postinst checks again.
function restore_missing_config() {
    let config = fs.readfile(CONFIG_PATH);
    if (config != null && trim(as_string(config)) != "") {
        protect_config_mode();
        return true;
    }

    let defaults = fs.readfile(DEFAULT_CONFIG_PATH);
    if (defaults == null || trim(as_string(defaults)) == "") {
        warn("Unable to restore missing Prokop configuration: packaged defaults are unavailable.\n");
        return false;
    }
    if (fs.writefile(CONFIG_PATH, defaults) == null ||
        !command_success_from_args([ "chmod", "0600", CONFIG_PATH ])) {
        warn("Unable to restore missing Prokop configuration.\n");
        return false;
    }
    return true;
}

// Whether the migrations of this release have nothing left to do on the
// configuration (config/migration.uc migrated). The package scripts run
// them before postinst; when they could not save their changes (a full or
// read-only overlay), this release would run on a configuration it does not
// understand.
function configuration_migrated() {
    return command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/config/migration.uc", "migrated" ]);
}

// Zapret-Manager launchers that Prokop wrote for another mirror, a former
// upstream one among them, would keep running the script from that host:
// they follow the current mirror setting again (components/action.uc).
function reconcile_zapret_manager_launchers() {
    let module = LIB_DIR + "/components/action.uc";
    if (path_exists(module) &&
        !command_success_from_args([ "ucode", "-L", LIB_DIR, module, "reconcile-zapret-manager-launchers" ]))
        warn("Unable to update the Zapret-Manager launchers for the current mirror setting.\n");
}

// What the product before the rename left once its package is gone: the
// retired VPN guard and the policy routing table entry. Nothing while that
// package is installed: Prokop's package is installed next to it during a
// migration, which must be able to roll back to it untouched. The installer
// runs this again after it has removed the old package.
function legacy_cleanup() {
    if (legacy.installed())
        return true;
    let ok = legacy_vpn_guard_cleanup();
    let data = fs.readfile(RT_TABLES_PATH);
    if (data != null) {
        let lines = filter(split(data, "\n"), (line) => !legacy_rt_tables_line(line));
        if (length(lines) != length(split(data, "\n")) && !replace_rt_tables(join("\n", lines)))
            ok = false;
    }
    return ok;
}

function postinst_restore() {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    clear_component_update_check_cache();
    legacy_cleanup();
    // The first kill-switch build saved an unguarded fw4 include; it becomes
    // the policy only this package's loader loads (UC-191).
    if (path_exists(KILLSWITCH_UC))
        command_success_from_args([ "ucode", "-L", LIB_DIR, KILLSWITCH_UC, "postinst" ]);
    reconcile_zapret_manager_launchers();

    if (!restore_missing_config())
        return false;

    if (!uci_core.load(CONFIG_NAME) || !uci_core.exists(CONFIG_NAME + ".settings")) {
        warn("Prokop configuration is invalid or unavailable to UCI.\n");
        return false;
    }
    torrserver_direct_postinst();
    torrserver_postinst();
    dns_failsafe_postinst();
    fw_watch_postinst();

    // Only an explicit start since boot lets a reload start a runtime that
    // is down (service/initd.uc EXPLICIT_START_FILE; D-15(a)), and a previous
    // version kept no record of its start. A runtime that runs across the
    // upgrade (no prerm stopped it) was started explicitly; so was Prokop
    // that ran before the upgrade, whose restart below is an explicit start
    // also when it does not come or fails.
    let initd_module = LIB_DIR + "/service/initd.uc";
    if (!path_exists(PACKAGE_UPGRADE_STATE)) {
        command_success_from_args([ "ucode", "-L", LIB_DIR, initd_module, "mark-explicit-start", "if-running" ]);
        return true;
    }

    // The user's stop holds Prokop down until the user starts it again
    // (D-15(a)), also one made after prerm's stop for the upgrade (the
    // package manager may take minutes before this postinst) or while it
    // ran: prerm's stop recorded after the user's is the user's as well
    // (service/initd.uc stop_request_source). Its record stays, and the
    // hand-off is consumed. The start below follows prerm's
    // own stop (PROKOP_START_AFTER_STOP): a stop requested after that one
    // wins over it also when it comes after this check (service/initd.uc
    // start_service).
    let own_stop = command_capture_from_args([ "ucode", "-L", LIB_DIR, initd_module, "own-stop-request" ]);
    if (own_stop.status == 3) {
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
        log_info(POSTINST_USER_STOPPED);
        return true;
    }
    let after_stop = own_stop.status == 0 ? trim(own_stop.output) : "";

    // Fail closed: Prokop that ran before the upgrade starts again only on
    // a configuration this release has migrated. The package scripts run
    // postinst also when the migration failed (UC-026); then it refuses the
    // start here. The stop of the upgrade keeps holding the runtime down (no
    // reload starts it, D-15), the start counts as failed in the health
    // history, the log says why, and the package operation fails. The
    // hand-off is consumed: a later run of these scripts must not start a
    // Prokop that was stopped since.
    if (!configuration_migrated()) {
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
        command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "start", "failure", "automatic" ]);
        log_error("Prokop was not started after the package upgrade: its configuration is not migrated to this release (the migration could not be saved); start it once the configuration can be saved, or install the package again");
        return false;
    }
    command_success_from_args([ "ucode", "-L", LIB_DIR, initd_module, "mark-explicit-start" ]);

    if (!wait_for_upgrade_sing_box_exit()) {
        warn("Timed out waiting for the previous Prokop sing-box runtime to exit; startup was not attempted.
");
        return false;
    }

    // The hand-off is consumed before the start, whatever its outcome: opkg
    // configures a package whose postinst failed again on every later
    // install, and such a re-run must neither wait for the runtime that came
    // up meanwhile nor start a Prokop that was stopped since.
    unlink_if_exists(PACKAGE_UPGRADE_STATE);

    // init.d exits 0 under procd before the detached start has run: wait for
    // the start's own result (service/initd.uc start-and-wait, UC-013) to
    // report a failure. It does not fail the package operation, as with
    // OpenWrt's default postinst: a failed start schedules its own retry,
    // and the in-app upgrade checks the runtime itself.
    let started = command_capture_from_args([ "env", "PROKOP_SERVICE_INIT=" + INIT_PATH,
        "PROKOP_START_AFTER_STOP=" + after_stop,
        "ucode", "-L", LIB_DIR, LIB_DIR + "/service/initd.uc", "start-and-wait", "start", "",
        POSTINST_START_WAIT_SECONDS ]);
    if (started.status != 0 &&
        command_capture_from_args([ "ucode", "-L", LIB_DIR, initd_module, "own-stop-request" ]).status == 3)
        log_info(POSTINST_USER_STOPPED);
    else if (started.status != 0 && match(started.output, /(^|\n)pending\n/) != null)
        warn("Prokop is still starting after the package upgrade; see the Prokop log for its outcome.\n");
    else if (started.status != 0)
        warn("Prokop did not start after the package upgrade; see the Prokop log.\n");
    return true;
}

function luci_cache_globs() {
    let configured = env("PROKOP_LUCI_CACHE_GLOBS", "");
    if (configured != "")
        return split(configured, /[ \t\r\n]+/);

    return [ "/var/luci-indexcache*", "/tmp/luci-indexcache*" ];
}

function remove_luci_index_cache() {
    for (let pattern in luci_cache_globs()) {
        pattern = as_string(pattern);
        if (pattern == "")
            continue;

        for (let path in fs.glob(pattern))
            unlink_if_exists(path);
    }
}

function luci_postinst() {
    remove_luci_index_cache();
    if (!PACKAGE_TEST_MODE) {
        if (path_exists("/etc/init.d/rpcd"))
            command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);
        command_success_from_args([ "logger", "-t", "prokop", "[info] Package defaults applied" ]);
    }
    return true;
}

let mode = ARGV[0] || "";

if (mode == "prerm")
    exit(prerm_cleanup(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "postinst")
    exit(postinst_restore() ? 0 : 1);
else if (mode == "restore-config")
    exit(env("IPKG_INSTROOT", "") != "" || restore_missing_config() ? 0 : 1);
else if (mode == "remove-rt-tables-entry")
    exit(remove_rt_tables_entry() ? 0 : 1);
else if (mode == "luci-postinst")
    exit(luci_postinst() ? 0 : 1);
else if (mode == "legacy-vpn-guard-cleanup")
    exit(legacy_vpn_guard_cleanup() ? 0 : 1);
else if (mode == "legacy-cleanup")
    exit(legacy_cleanup() ? 0 : 1);
else if (mode == "sing-box-exe-path-fixture")
    exit(sing_box_exe_path(ARGV[1]) ? 0 : 1);
else {
    warn("Usage: service/package.uc <prerm|postinst|remove-rt-tables-entry|luci-postinst|legacy-cleanup>\n");
    exit(1);
}
