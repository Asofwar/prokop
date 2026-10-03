#!/usr/bin/env ucode

// Durable replacement of a file on flash (UC-025).
//
// A rename alone does not make a new file durable on UBIFS, the NAND overlay
// of many routers: the rename reaches the flash within seconds, the data of
// the new file only with the write-back (about 30 s), so a power cut in
// between leaves the file empty. ucode has no fsync: sync(1) flushes the new
// file before the rename makes it the file, and the rename right after it,
// as libuci does for its commits. sync flushes every filesystem and may take
// long with much dirty data (USB storage): only rare, critical writes use
// it, never a file rewritten on every poll.
//
// fs.writefile reports a small file as written when the filesystem is full
// (stdio writes it on close, and that error is lost): the temporary file is
// read back before it replaces anything (UC-241), by every writer here,
// flushed or not.
//
// A symlink stays one: as a libuci commit does, the file it points to is
// replaced, through a temporary file next to that file. A symlink that
// points to nothing is not replaced by a regular file: the write fails.

let fs = require("fs");

function flush() {
    return system("sync >/dev/null 2>&1") == 0;
}

// The file a write of path replaces: path, or the file a symlink on the way
// points to; null for a symlink that points to nothing.
function target_of(path) {
    path = "" + path;
    let real = fs.realpath(path);
    if (real != null)
        return real;
    let link = fs.lstat(path);
    return link != null && link.type == "link" ? null : path;
}

// path is a symlink that points to nothing, which no writer here replaces:
// for the caller's message.
function dangling(path) {
    return target_of(path) == null;
}

// The temporary file a writer of path uses: hidden next to it and named
// after the writing process, so writers never share one.
function temp_path(path) {
    return fs.dirname(path) + "/." + fs.basename(path) + ".prokop-" + fs.readlink("/proc/self");
}

function replace(tmp, path, data, mode, swap, durable) {
    data = data == null ? "" : "" + data;
    let target = target_of(path);
    if (target == null)
        return false;
    // Next to the file that is replaced, so that the rename stays within
    // its directory.
    if (target != path)
        tmp = fs.dirname(target) + "/" + fs.basename(tmp);
    fs.unlink(tmp);
    // Private until it has its mode: it may hold a secret.
    let out = fs.open(tmp, "w", mode != null ? 0600 : 0666);
    let written = out != null && out.write(data) != null;
    if (out != null)
        out.close();
    if (!written || (mode != null && !fs.chmod(tmp, mode)) || fs.readfile(tmp) !== data ||
        (durable && !flush()) || !(swap != null ? swap(tmp, target) : fs.rename(tmp, target))) {
        fs.unlink(tmp);
        return false;
    }
    // Renamed: path holds data, whatever this flush reports.
    if (durable)
        flush();
    return true;
}

// Makes data the content of path, flushed before and after the rename.
// tmp: the caller's temporary file next to path, unique per writer; mode:
// its permissions (null: as created); swap(tmp, target), when given, renames
// tmp over target (the file path names) in place of a plain rename, and
// returns false to leave target as it is (e.g. a compare-and-swap under a
// lock): it runs between the two flushes. True when path holds data;
// otherwise tmp is gone and path is unchanged.
function durable_replace(tmp, path, data, mode, swap) {
    return replace(tmp, path, data, mode, swap, true);
}

// durable_replace through temp_path(), keeping the mode of the file it
// replaces; new_mode is the mode of a new file.
function durable_rewrite(path, data, new_mode, swap) {
    let target = target_of(path);
    if (target == null)
        return false;
    let stat = fs.stat(target);
    return durable_replace(temp_path(target), target, data, stat != null ? stat.mode : new_mode, swap);
}

// durable_replace without the flushes, for a file that is derived from
// other state and rebuilt from it when lost, or that is not on flash: the
// content is still read back before the rename.
function checked_replace(tmp, path, data, mode) {
    return replace(tmp, path, data, mode, null, false);
}

return { durable_replace, durable_rewrite, checked_replace, temp_path, dangling };
