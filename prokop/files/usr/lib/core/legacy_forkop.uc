// Names a Forkop installation leaves on a router. Prokop is the renamed
// Forkop; these are recognised only to migrate, hand over and clean up what
// Forkop created, and must keep their old spelling. Every value was checked
// against Forkop 1.0.x as shipped by both flavours (the fork with the
// per-section kill-switch, and the upstream without it).

let fs = require("fs");

const PRODUCT = "Forkop";
const PACKAGES = [ "luci-i18n-forkop-ru", "luci-app-forkop", "forkop" ];

const CONFIG_NAME = "forkop";
const CONFIG_PATH = "/etc/config/forkop";
const CONFIG_LEFTOVER_SUFFIXES = [ "-opkg", ".opkg-new", ".opkg-old", ".opkg-dist", ".apk-new", ".apk-old" ];

const INIT = "/etc/init.d/forkop";
const KILLSWITCH_INIT = "/etc/init.d/forkop-killswitch";
const TORRSERVER_INIT = "/etc/init.d/forkop-torrserver-direct";
const SERVICES = [ "forkop", "forkop-killswitch", "forkop-torrserver-direct" ];
const KILLSWITCH_SERVICE = "forkop-killswitch";
// rc.d links of the three services. START/STOP are 99/-, 20/90 and 100/9, so
// a link name may carry three digits (S100forkop-torrserver-direct).
const RC_D_LINK_REGEX = /^[SK][0-9]+forkop(-killswitch|-torrserver-direct)?$/;

const BIN = "/usr/bin/forkop";
const LIB_DIR = "/usr/lib/forkop";
const SHARE_DIR = "/usr/share/forkop";
const LIBEXEC_RO = "/usr/libexec/forkop-ro";
const STATE_DIR = "/etc/forkop";
const BACKUP_DIR = "/etc/forkop-backups";
const RUN_DIR = "/var/run/forkop";
const TMP_PREFIX = "/tmp/forkop";
// The kill-switch runtime whose presence makes the old package prerm lift the
// kill-switch on removal (service/package.uc prerm_cleanup, action "remove").
const KILLSWITCH_UC = "/usr/lib/forkop/killswitch/runtime.uc";

const NFT_TABLES = [
    "ForkopTable", "ForkopTableDpiGuard", "ForkopConfigRestore", "ForkopConfigRestoreDpiGuard",
    "ForkopAutotuneProbe", "ForkopAutotuneVerify", "ForkopTorrServerDirect"
];
const RUNTIME_TABLE = "ForkopTable";
const KILLSWITCH_TABLE = "ForkopKillswitch";
const KILLSWITCH_DNS_CHAIN = "ks_dns";
const KILLSWITCH_INCLUDE = "/usr/share/nftables.d/ruleset-post/90-forkop-killswitch.nft";
const KILLSWITCH_KEEP = "/lib/upgrade/keep.d/forkop-killswitch";
const KILLSWITCH_STATE_DIR = "/etc/forkop/killswitch";
const KILLSWITCH_SERVERSFILE = "/etc/forkop/killswitch/dnsmasq.servers";
const KILLSWITCH_DNS_BLOCKED_FILE = "/etc/forkop/killswitch/dns-blocked.servers";
// Standby resolver configuration and rule-set matcher cache.
const KILLSWITCH_CACHE_DIR = "/tmp/forkop-killswitch";

const RT_TABLE_ID = "105";
const RT_TABLE_NAME = "forkop";
const RT_TABLE_LINE = "105 forkop";
const CRON_MARKER_PREFIX = "# forkop-";

const DHCP_SECTION = "forkop";
const DHCP_OPTION_PREFIX = "forkop_";

const SING_BOX_MANAGED_MARKER = "Forkop managed sing-box service for binary variants";
const ZAPRET_MANAGER_MARKER = "# Forkop X Zapret-Manager launcher";
const SUBSCRIPTION_KEY_PREFIX = "__forkop_";
const SNAPSHOT_VERSION_KEY = "forkop_version";

const ACL_GROUPS = [ "luci-app-forkop", "luci-app-forkop-admin" ];
const LUCI_VIEW_DIR = "/www/luci-static/resources/view/forkop";
const LUCI_MENU = "/usr/share/luci/menu.d/luci-app-forkop.json";
const LUCI_ACL = "/usr/share/rpcd/acl.d/luci-app-forkop.json";
const LUCI_UCI_DEFAULTS = "/etc/uci-defaults/50_luci-forkop";
const LUCI_I18N_PREFIX = "/usr/lib/lua/luci/i18n/forkop.";

// A filesystem root for the legacy paths below, set only by the isolated
// regression tests. The constants above never carry it.
const ROOT = getenv("PROKOP_LEGACY_FORKOP_ROOT") || "";

function path(value) {
    return ROOT + value;
}

// The Forkop package is installed: its main init script is a package file,
// removed only with the package.
function installed() {
    return fs.stat(path(INIT)) != null;
}

// The nft tables that exist now, as "family name" keys. `nft list tables`
// lists names only, never set contents (which can be large).
function nft_tables() {
    let result = {};
    let pipe = fs.popen("nft list tables 2>/dev/null", "r");
    if (!pipe)
        return result;
    let output = pipe.read("all");
    pipe.close();
    for (let line in split(output == null ? "" : "" + output, "\n")) {
        let found = match(trim(line), /^table ([a-z0-9]+) ([A-Za-z0-9_.-]+)/);
        if (found != null)
            result[found[1] + " " + found[2]] = true;
    }
    return result;
}

function nft_table_present(name) {
    return nft_tables()["inet " + name] === true;
}

// Forkop left something that marks a runtime: its package (init script,
// libraries) or, until the next reboot, the runtime state of one that ran.
// Without any of these no Forkop runtime can exist, and nothing is queried.
function traces() {
    return installed() || fs.stat(path(LIB_DIR)) != null || fs.stat(path(RUN_DIR)) != null;
}

// Why Forkop counts as active, or null: its runtime table exists (a running,
// starting or crashed runtime), or its init script reports it running.
// Installed but stopped or disabled Forkop files alone are not active.
function active_reason() {
    if (!traces())
        return null;
    if (nft_table_present(RUNTIME_TABLE))
        return "nft table " + RUNTIME_TABLE + " is present";
    let init = path(INIT);
    if (fs.stat(init) != null &&
        system("'" + replace(init, /'/g, "'\\''") + "' status >/dev/null 2>&1 </dev/null") == 0)
        return INIT + " reports it running";
    return null;
}

function active() {
    return active_reason() != null;
}

return {
    PRODUCT, PACKAGES, CONFIG_NAME, CONFIG_PATH, CONFIG_LEFTOVER_SUFFIXES,
    INIT, KILLSWITCH_INIT, TORRSERVER_INIT, SERVICES, KILLSWITCH_SERVICE, RC_D_LINK_REGEX,
    BIN, LIB_DIR, SHARE_DIR, LIBEXEC_RO, STATE_DIR, BACKUP_DIR, RUN_DIR, TMP_PREFIX, KILLSWITCH_UC,
    NFT_TABLES, RUNTIME_TABLE, KILLSWITCH_TABLE, KILLSWITCH_DNS_CHAIN, KILLSWITCH_INCLUDE, KILLSWITCH_KEEP,
    KILLSWITCH_STATE_DIR, KILLSWITCH_SERVERSFILE, KILLSWITCH_DNS_BLOCKED_FILE, KILLSWITCH_CACHE_DIR,
    RT_TABLE_ID, RT_TABLE_NAME, RT_TABLE_LINE, CRON_MARKER_PREFIX,
    DHCP_SECTION, DHCP_OPTION_PREFIX,
    SING_BOX_MANAGED_MARKER, ZAPRET_MANAGER_MARKER, SUBSCRIPTION_KEY_PREFIX, SNAPSHOT_VERSION_KEY,
    ACL_GROUPS, LUCI_VIEW_DIR, LUCI_MENU, LUCI_ACL, LUCI_UCI_DEFAULTS, LUCI_I18N_PREFIX,
    ROOT, path, installed, traces, nft_tables, nft_table_present, active_reason, active
};
