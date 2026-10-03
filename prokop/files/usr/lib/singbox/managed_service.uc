#!/usr/bin/env ucode

// The init script of the sing-box service that Prokop installs for a binary
// sing-box variant, which comes without the package's script. One text for
// every writer (UC-085): a start (singbox/runtime.uc), a component install,
// update or rollback (components/action.uc) and the requirements check
// (config/validator.uc).
//
// procd does not watch config.json: with a `file` parameter on the instance,
// `/etc/init.d/sing-box start|reload` after a change of config.json has
// procd restart sing-box outside Prokop's controlled transitions (taken out
// in release 1.0.14).

let fs = require("fs");
let durable = require("core.durable");

const INIT_SCRIPT = "/etc/init.d/sing-box";
const MARKER = getenv("SB_MANAGED_SERVICE_MARKER") || "Prokop managed sing-box service for binary variants";

function text() {
    return "#!/bin/sh /etc/rc.common\n" +
        "# " + MARKER + "\n\n" +
        "USE_PROCD=1\n" +
        "START=99\n" +
        "PROG=\"/usr/bin/sing-box\"\n\n" +
        "start_service() {\n" +
        "    config_load \"sing-box\"\n" +
        "    local enabled config_file working_directory\n" +
        "    local log_stderr\n\n" +
        "    config_get_bool enabled \"main\" \"enabled\" \"0\"\n" +
        "    [ \"$enabled\" -eq \"1\" ] || return 0\n\n" +
        "    config_get config_file \"main\" \"conffile\" \"/etc/sing-box/config.json\"\n" +
        "    config_get working_directory \"main\" \"workdir\" \"/usr/share/sing-box\"\n" +
        "    config_get_bool log_stderr \"main\" \"log_stderr\" \"1\"\n\n" +
        "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" run -c \"$config_file\" -D \"$working_directory\"\n" +
        "    procd_set_param stderr \"$log_stderr\"\n" +
        "    procd_set_param limits core=\"unlimited\"\n" +
        "    procd_set_param limits nofile=\"1000000 1000000\"\n" +
        "    procd_set_param respawn\n" +
        "    procd_close_instance\n" +
        "}\n\n" +
        "service_triggers() {\n" +
        "    procd_add_reload_trigger \"sing-box\"\n" +
        "}\n";
}

// Written only when it differs, and copies that a crash left between their
// write and their rename (named by the pid of a writer that is gone) are
// removed (UC-159).
function install() {
    // Also when the script is current: another writer may have installed it
    // since the crash.
    for (let path in fs.glob(INIT_SCRIPT + ".prokop.*") || []) {
        let writer = match(path, /\/sing-box\.prokop\.([0-9]+)$/);
        if (writer != null && fs.stat("/proc/" + writer[1]) == null)
            fs.unlink(path);
    }

    let data = text();
    let current = fs.stat(INIT_SCRIPT);
    if (current != null && current.type == "file" && (current.mode & 0111) == 0111 &&
        fs.readfile(INIT_SCRIPT) === data)
        return true;

    // Named after this process, which lives until the rename: the cleanup
    // above in another writer keeps the copy while its writer is at work
    // (a pid of a short-lived shell would be gone at once). Read back and
    // flushed before and after the rename (core/durable.uc): a full overlay
    // took the write and left an empty init script in place. Written only
    // when it differs, so the flushes are rare.
    let tmp = INIT_SCRIPT + ".prokop." + fs.readlink("/proc/self");
    return durable.durable_replace(tmp, INIT_SCRIPT, data, 0755);
}

return { text, install };
