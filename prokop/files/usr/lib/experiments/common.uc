// Shared helpers for optional fork experiments. No shell interpolation of input.
let fs = require("fs");
let durable = require("core.durable");
let locks = require("core.runtime_lock");
function value(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(value(v), /'/g, "'\\''") + "'"; }
function command(args) { return join(" ", map(args, quote)); }
function capture(args) {
    let pipe = fs.popen(command(args) + " 2>/dev/null", "r");
    if (!pipe) return { code: 127, output: "" };
    let output = pipe.read("all"), code = int(pipe.close());
    return { code: code > 255 ? int(code / 256) : code, output: value(output) };
}
function read(path, fallback) { try { return json(fs.readfile(path)); } catch (e) { return fallback; } }
function directory(path) {
    let stat = fs.lstat(path);
    if (stat != null && stat.type != "directory") return false;
    if (stat == null && !fs.mkdir(path, 0700)) return false;
    return fs.chmod(path, 0700);
}
function write(path, data, flash) {
    return flash ? durable.durable_rewrite(path, sprintf("%J\n", data), 0600) :
        durable.checked_replace(durable.temp_path(path), path, sprintf("%J\n", data), 0600);
}
function uptime() { return int(split(value(fs.readfile("/proc/uptime")), " ")[0]); }
function self() { return value(fs.readlink("/proc/self")); }
function reply(data) { print(sprintf("%J\n", data)); exit(data.success === false ? 1 : 0); }
function fail(reason) { return { success: false, reason }; }
return { value, quote, command, capture, read, directory, write, uptime, self, reply, fail, locks };
