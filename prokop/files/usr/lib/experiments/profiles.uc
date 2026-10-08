// Named profiles point to manual snapshots and use their guarded restore.
let fs = require("fs");
let c = require("experiments.common");
const LIB = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const DIR = getenv("PROKOP_PROFILES_DIR") || "/etc/prokop/profiles";
const FILE = DIR + "/index.json";
function snapshots(mode, id) {
    let r = c.capture([ "ucode", "-L", LIB, LIB + "/config/snapshots.uc", mode, id || "" ]);
    try { return json(r.output); } catch (e) { return c.fail("snapshot_operation_failed"); }
}
function run(mode, name) {
    if (!c.directory(DIR)) return c.fail("profile_storage_unavailable");
    if (!c.locks.acquire(DIR + "/lock", c.self())) return c.fail("profile_operation_busy");
    let result;
    function work() {
        let profiles = c.read(FILE, {});
        if (type(profiles) != "object") return c.fail("invalid_profile_index");
        if (mode == "list") return { success: true, profiles: map(keys(profiles), (key) => ({ name: key, snapshot: profiles[key] })) };
        if (length(name) < 1 || length(name) > 64 || match(name, /[[:cntrl:]]/) != null) return c.fail("invalid_profile_name");
        if (mode == "save") {
            if (profiles[name] != null) return c.fail("profile_name_exists");
            let saved = snapshots("create", "manual");
            if (saved.status != "created" || saved.snapshot?.id == null) return saved;
            profiles[name] = saved.snapshot.id;
            if (!c.write(FILE, profiles, true)) return c.fail("profile_index_write_failed_snapshot_preserved");
            return { success: true, name, snapshot: saved.snapshot.id };
        }
        let id = profiles[name];
        if (type(id) != "string") return c.fail("profile_not_found");
        if (mode == "activate") return snapshots("restore", id);
        if (mode == "diff") {
            let changes = snapshots("diff", id);
            return type(changes) == "array" ? { success: true, changes } : changes;
        }
        if (mode == "remove") {
            // Only unlink the name: the manual snapshot remains in History.
            delete profiles[name];
            return c.write(FILE, profiles, true) ? { success: true } : c.fail("profile_index_write_failed");
        }
        return c.fail("invalid_action");
    }
    try { result = work(); } catch (e) { result = c.fail("profile_operation_failed"); }
    c.locks.release(DIR + "/lock", c.self());
    return result;
}
let answer = run(c.value(ARGV[0]), c.value(ARGV[1]));
if (answer.status != null && index([ "created", "success", "restored_not_started" ], answer.status) < 0) answer.success = false;
c.reply(answer);
