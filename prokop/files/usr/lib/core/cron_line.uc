// One Prokop line of the root crontab, found by its marker comment: written
// when it is wanted, removed when not, every other line kept as it is. The
// same checks as the autotune schedule line (autotune/manager.uc
// cron_rewrite): a crontab that cannot be read is never rewritten, and
// BusyBox crontab's silent partial writes on a full overlay are detected and
// undone.

let fs = require("fs");
let common = require("core.common");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function capture(args) {
    let pipe = fs.popen(common.shell_command(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";
    let output = pipe.read("all");
    pipe.close();
    return as_string(output);
}

function success(args) {
    return system(common.shell_command(args) + " >/dev/null 2>&1") == 0;
}

// opts: crontab_file, crontab (the command), tmp_dir. line: the line without
// its marker, or null to remove it.
function rewrite(opts, marker, line) {
    let crontab_file = opts.crontab_file, crontab = opts.crontab, tmp_dir = opts.tmp_dir;
    let enabled = line != null;
    let existing = fs.readfile(crontab_file);
    if (existing == null && fs.stat(crontab_file) != null)
        return { status: "failed", reason: "crontab_unreadable" };
    existing = as_string(existing);
    let lines = split(existing, "\n"), text = "";
    if (length(lines) > 0 && lines[length(lines) - 1] == "")
        pop(lines);
    for (let item in lines)
        if (index(item, marker) < 0)
            text += item + "\n";
    if (enabled)
        text += line + " " + marker + "\n";
    if (text == existing)
        return { status: "ok", enabled, changed: false };
    let tmp = trim(capture([ "mktemp", tmp_dir + "/prokop-cron.XXXXXX" ]));
    if (tmp == "")
        return { status: "failed", reason: "tempfile_unavailable" };
    if (fs.writefile(tmp, text) == null || fs.readfile(tmp) !== text) {
        fs.unlink(tmp);
        return { status: "failed", reason: "tempfile_unavailable" };
    }
    let ok = success([ crontab, tmp ]);
    let written = ok ? fs.readfile(crontab_file) : null;
    if (ok && written !== text) {
        if (as_string(written) === existing) {
            fs.unlink(tmp);
            return { status: "failed", reason: "crontab_not_written" };
        }
        if (written == null || length(written) >= length(text) || substr(text, 0, length(written)) !== written) {
            fs.unlink(tmp);
            return { status: "failed", reason: "crontab_changed" };
        }
        let restored = fs.writefile(tmp, existing) != null && fs.readfile(tmp) === existing &&
            success([ crontab, tmp ]) && fs.readfile(crontab_file) === existing;
        fs.unlink(tmp);
        return { status: "failed", reason: "crontab_incomplete", restored };
    }
    fs.unlink(tmp);
    return ok ? { status: "ok", enabled, changed: true } : { status: "failed", reason: "crontab_failed" };
}

return { rewrite };
