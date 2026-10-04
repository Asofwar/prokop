#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let durable = require("core.durable");

let as_string = common.as_string;

// Test fixture hooks: a flat state file instead of libuci, and a log of
// commits. Only these Prokop-namespaced names count; the read-only CLI
// (/usr/libexec/prokop-ro) runs with a clean environment.
const UCI_STATE_FILE = getenv("PROKOP_UCI_STATE_FILE") || "";
const UCI_LOG_FILE = getenv("PROKOP_UCI_LOG_FILE") || "";

let runtime_cursor = false;
let loaded_packages = {};

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function path_parts(path) {
    path = as_string(path);
    let first = index(path, ".");
    if (first < 0)
        return null;

    let package_name = substr(path, 0, first);
    let rest = substr(path, first + 1);
    let second = index(rest, ".");
    if (second < 0)
        return { package: package_name, section: rest, option: "" };

    return {
        package: package_name,
        section: substr(rest, 0, second),
        option: substr(rest, second + 1)
    };
}

function anonymous_section_selector(section) {
    let matched = match(as_string(section), /^@([A-Za-z0-9_-]+)\[([0-9]+)\]$/);
    if (!matched)
        return null;

    return {
        type: as_string(matched[1]),
        index: int(matched[2])
    };
}

function resolve_section_name(c, package_name, raw_section_name) {
    raw_section_name = as_string(raw_section_name);

    let selector = anonymous_section_selector(raw_section_name);
    if (selector == null)
        return raw_section_name;

    let found = "";
    let current = 0;
    try {
        c.foreach(as_string(package_name), selector.type, function(section) {
            if (found != "")
                return;
            if (current == selector.index && type(section) == "object")
                found = as_string(section[".name"] || "");
            current++;
        });
    }
    catch (e) {
        return "";
    }

    return found;
}

function resolve_parts(c, parts) {
    if (parts == null)
        return null;

    let section = resolve_section_name(c, parts.package, parts.section);
    if (section == "")
        return null;

    return {
        package: parts.package,
        section,
        option: parts.option
    };
}

function state_lines() {
    let data = fs.readfile(UCI_STATE_FILE);
    if (data == null || data == "")
        return [];
    return split(replace(data, /\r/g, ""), "\n");
}

function state_write_lines(lines) {
    return fs.writefile(UCI_STATE_FILE, join("\n", lines) + "\n") != null;
}

function state_get(path) {
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == path)
            return equals >= 0 ? substr(line, equals + 1) : "";
    }
    return "";
}

function state_exists(path) {
    let prefix = as_string(path) + ".";
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == path || substr(key, 0, length(prefix)) == prefix)
            return true;
    }
    return false;
}

function state_delete(path) {
    let prefix = as_string(path) + ".";
    let changed = false;
    let lines = [];
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == path || substr(key, 0, length(prefix)) == prefix) {
            changed = true;
            continue;
        }
        push(lines, line);
    }
    return !changed || state_write_lines(lines);
}

function state_set(path, value) {
    let lines = [];
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key != path)
            push(lines, line);
    }
    push(lines, as_string(path) + "=" + as_string(value));
    return state_write_lines(lines);
}

function state_add_list(path, value) {
    let current = state_get(path);
    return state_set(path, current == "" ? value : current + " " + as_string(value));
}

function state_del_list(path, value) {
    let current = state_get(path);
    if (current == "")
        return false;

    let values = [];
    let removed = false;
    for (let item in words(current)) {
        if (item == value) {
            removed = true;
            continue;
        }
        push(values, item);
    }

    if (!removed)
        return false;
    if (length(values) == 0)
        return state_delete(path);
    return state_set(path, join(" ", values));
}

function state_rename(path, name) {
    let parts = path_parts(path);
    name = as_string(name);
    if (parts == null || parts.option != "" || name == "")
        return false;

    let from = parts.package + "." + parts.section;
    let to = parts.package + "." + name;
    if (state_get(from) == "" || state_exists(to))
        return false;

    let lines = [];
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == from || substr(key, 0, length(from) + 1) == from + ".")
            line = to + substr(line, length(from));
        push(lines, line);
    }
    return state_write_lines(lines);
}

function state_commit(package_name) {
    if (UCI_LOG_FILE == "")
        return true;
    let existing = fs.readfile(UCI_LOG_FILE);
    existing = existing == null ? "" : as_string(existing);
    return fs.writefile(UCI_LOG_FILE, existing + "commit " + as_string(package_name) + "\n") != null;
}

function state_add_section(package_name, type_name) {
    package_name = as_string(package_name);
    type_name = as_string(type_name);

    let index = 1;
    let section = "";
    while (true) {
        section = sprintf("cfg%06x", index);
        if (!state_exists(package_name + "." + section))
            break;
        index++;
    }

    return state_set(package_name + "." + section, type_name) ? section : "";
}

// type_name null: sections of every type.
function state_sections(package_name, type_name) {
    let result = [];
    let prefix = as_string(package_name) + ".";
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        if (equals < 0)
            continue;

        let key = substr(line, 0, equals);
        let value = substr(line, equals + 1);
        if ((type_name != null && value != type_name) || substr(key, 0, length(prefix)) != prefix)
            continue;

        let section = substr(key, length(prefix));
        if (index(section, ".") < 0)
            push(result, section);
    }
    return result;
}

function state_get_all(package_name, section_name) {
    package_name = as_string(package_name);
    section_name = as_string(section_name);

    let result = {};
    let section_type = state_get(package_name + "." + section_name);
    if (section_type != "") {
        result[".name"] = section_name;
        result[".type"] = section_type;
    }

    let prefix = package_name + "." + section_name + ".";
    for (let line in state_lines()) {
        if (line == "")
            continue;
        let equals = index(line, "=");
        if (equals < 0)
            continue;

        let key = substr(line, 0, equals);
        if (substr(key, 0, length(prefix)) != prefix)
            continue;

        let option = substr(key, length(prefix));
        if (option != "")
            result[option] = substr(line, equals + 1);
    }

    return length(keys(result)) > 0 ? result : null;
}

function fixture_enabled() {
    return UCI_STATE_FILE != "";
}

// The libuci binding reports a failed load, set, delete, rename or commit
// with null (ucode lib/uci.c err_return), never with false or an exception,
// and a commit fails on a full or read-only overlay: the wrappers below take
// only true for success (UC-024).
function cursor() {
    if (runtime_cursor !== false)
        return runtime_cursor;

    try {
        runtime_cursor = require("uci").cursor();
    }
    catch (e) {
        runtime_cursor = null;
    }
    return runtime_cursor;
}

function available() {
    return fixture_enabled() || cursor() != null;
}

function load(package_name) {
    package_name = as_string(package_name);
    if (fixture_enabled())
        return true;
    if (loaded_packages[package_name])
        return true;

    let c = cursor();
    if (c == null)
        return false;

    try {
        if (c.load(package_name) !== true)
            return false;
        loaded_packages[package_name] = true;
        return true;
    }
    catch (e) {
        return false;
    }
}

// Forgets what is loaded of a package: the next read loads it again from
// /etc/config. libuci keeps a loaded package in memory, and load() above
// loads it once per process; a long-running reader that must see the
// commits of other processes refreshes before it reads (UC-110).
function refresh(package_name) {
    package_name = as_string(package_name);
    if (fixture_enabled() || !loaded_packages[package_name])
        return;
    delete loaded_packages[package_name];
    if (runtime_cursor)
        try { runtime_cursor.unload(package_name); } catch (e) {}
}

function value_to_string(value) {
    if (value == null)
        return "";
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function value_to_list(value) {
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    return words(value);
}

function get(path) {
    path = as_string(path);
    if (fixture_enabled())
        return state_get(path);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return "";
    if (!load(parts.package))
        return "";
    parts = resolve_parts(c, parts);
    if (parts == null)
        return "";

    return value_to_string(c.get(parts.package, parts.section, parts.option));
}

function get_all(package_name, section_name) {
    if (fixture_enabled())
        return state_get_all(package_name, section_name);

    let c = cursor();
    if (c == null)
        return null;

    try {
        load(package_name);
        section_name = resolve_section_name(c, package_name, section_name);
        if (section_name == "")
            return null;
        return c.get_all(as_string(package_name), as_string(section_name));
    }
    catch (e) {
        return null;
    }
}

function exists(path) {
    path = as_string(path);
    if (fixture_enabled())
        return state_exists(path);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null)
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    if (parts.option == "")
        return c.get_all(parts.package, parts.section) != null;
    return c.get(parts.package, parts.section, parts.option) != null;
}

function delete_path(path) {
    path = as_string(path);
    if (fixture_enabled())
        return state_delete(path);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null)
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    try {
        // libuci refuses to delete what is absent (null); it is gone either way.
        if (parts.option == "")
            return c.get(parts.package, parts.section) == null || c.delete(parts.package, parts.section) === true;
        return c.get(parts.package, parts.section, parts.option) == null ||
            c.delete(parts.package, parts.section, parts.option) === true;
    }
    catch (e) {
        return false;
    }
}

function set_section(path, type_name) {
    path = as_string(path);
    if (fixture_enabled())
        return state_set(path, type_name);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option != "")
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    try {
        return c.set(parts.package, parts.section, as_string(type_name)) === true;
    }
    catch (e) {
        return false;
    }
}

// Gives the section <package>.<section> the name <name>; an anonymous section
// becomes a named one in place.
function rename(path, name) {
    path = as_string(path);
    name = as_string(name);
    if (fixture_enabled())
        return state_rename(path, name);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option != "" || name == "")
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null || c.get(parts.package, parts.section) == null || c.get(parts.package, name) != null)
        return false;

    try {
        return c.rename(parts.package, parts.section, name) === true;
    }
    catch (e) {
        return false;
    }
}

function add(package_name, type_name) {
    if (fixture_enabled())
        return state_add_section(package_name, type_name);

    let c = cursor();
    if (c == null)
        return "";

    try {
        load(package_name);
        let section = c.add(as_string(package_name), as_string(type_name));
        return as_string(section);
    }
    catch (e) {
        return "";
    }
}

function set(path, value) {
    path = as_string(path);
    if (fixture_enabled())
        return state_set(path, value_to_string(value));

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    try {
        // libuci keeps no empty list, and the binding refuses to set one
        // (null): an empty list is no option at all.
        if (type(value) == "array" && length(value) == 0)
            return c.get(parts.package, parts.section, parts.option) == null ||
                c.delete(parts.package, parts.section, parts.option) === true;
        return c.set(parts.package, parts.section, parts.option, type(value) == "array" ? value : as_string(value)) === true;
    }
    catch (e) {
        return false;
    }
}

function add_list(path, value) {
    path = as_string(path);
    if (fixture_enabled())
        return state_add_list(path, value);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    try {
        let values = value_to_list(c.get(parts.package, parts.section, parts.option));
        push(values, as_string(value));
        return c.set(parts.package, parts.section, parts.option, values) === true;
    }
    catch (e) {
        return false;
    }
}

function del_list(path, value) {
    path = as_string(path);
    if (fixture_enabled())
        return state_del_list(path, value);

    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    let values = [];
    let removed = false;
    for (let item in value_to_list(c.get(parts.package, parts.section, parts.option))) {
        if (item == value) {
            removed = true;
            continue;
        }
        push(values, item);
    }

    if (!removed)
        return false;

    try {
        if (length(values) == 0)
            return c.delete(parts.package, parts.section, parts.option) === true;
        return c.set(parts.package, parts.section, parts.option, values) === true;
    }
    catch (e) {
        return false;
    }
}

function commit(package_name) {
    if (fixture_enabled())
        return state_commit(package_name);

    let c = cursor();
    if (c == null)
        return false;

    try {
        return c.commit(package_name) === true;
    }
    catch (e) {
        return false;
    }
}

function section_name(section) {
    if (type(section) == "object")
        return as_string(section[".name"] || "");
    return as_string(section);
}

// Section names in file order; type_name null: sections of every type.
function section_names(package_name, type_name) {
    if (fixture_enabled())
        return state_sections(package_name, type_name);

    let c = cursor();
    if (c == null)
        return [];

    let result = [];
    try {
        load(package_name);
        c.foreach(package_name, type_name, function(section) {
            let name = section_name(section);
            if (name != "")
                push(result, name);
        });
    }
    catch (e) {
        return [];
    }
    return result;
}

function sections(package_name, type_name) {
    return section_names(package_name, as_string(type_name));
}

// The names of all sections of the package, whatever their type.
function all_sections(package_name) {
    return section_names(package_name, null);
}

function section_objects(package_name, type_name) {
    if (fixture_enabled()) {
        let result = [];
        for (let name in state_sections(package_name, as_string(type_name))) {
            let section = state_get_all(package_name, name);
            if (type(section) == "object")
                push(result, section);
        }
        return result;
    }

    let c = cursor();
    if (c == null)
        return [];

    let result = [];
    try {
        load(package_name);
        c.foreach(package_name, as_string(type_name), function(section) {
            if (type(section) == "object")
                push(result, section);
        });
    }
    catch (e) {
        return [];
    }
    return result;
}

// ---- one option, committed alone ---------------------------------------------

function shell_arg(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function shell_command(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_arg(arg));
    return join(" ", parts);
}

function command_ok(args) {
    return system(shell_command(args) + " >/dev/null 2>&1") == 0;
}

function command_text(args) {
    let pipe = fs.popen(shell_command(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    return pipe.close() == 0 && data != null ? as_string(data) : "";
}

// The package name of the private copy commit_option() writes through;
// nothing is ever staged under it.
const OWN_OPTION_PACKAGE = "prokop_own_option";

// Sets one option of a package and commits exactly that change. commit()
// would also commit every change someone staged with `uci set` in
// /tmp/.uci/<package>, and a cursor with a save directory of its own does not
// help: libuci merges that directory anyway (and then leaves the changes
// staged a second time). So the option is set on a private copy of
// config_file under a package name of its own, staged there in uci's delta
// format (the value never appears on a command line) and committed by the
// uci CLI (cli); the copy then replaces config_file while the file is locked
// (uci commit takes the same lock) and unchanged. Changes staged in /tmp/.uci
// or in a LuCI session stay staged. keep_existing: a value the committed file
// already has stays. "written" (the committed copy holds the value), "kept",
// or "" when nothing was written (e.g. the section does not exist). The
// fixture sets its state and logs "commit-option <path>", never a commit of
// the package.
function commit_option(config_file, path, value, keep_existing, cli) {
    path = as_string(path);
    let parts = path_parts(path);
    if (parts == null || match(parts.section, /^[A-Za-z0-9_]+$/) == null || match(parts.option, /^[A-Za-z0-9_]+$/) == null)
        return "";
    if (fixture_enabled()) {
        if (keep_existing && trim(state_get(path)) != "")
            return "kept";
        if (!state_set(path, value))
            return "";
        if (UCI_LOG_FILE != "")
            fs.writefile(UCI_LOG_FILE, as_string(fs.readfile(UCI_LOG_FILE)) + "commit-option " + path + "\n");
        return "written";
    }

    let dir = trim(command_text([ "mktemp", "-d" ]));
    if (dir == "" || fs.stat(dir) == null)
        return "";
    let copy = dir + "/" + OWN_OPTION_PACKAGE;
    let own = OWN_OPTION_PACKAGE + "." + parts.section + "." + parts.option;
    let base = [ as_string(cli) || "uci", "-q", "-c", dir, "-t", dir + "/save" ];
    let result = "";
    // A symlink stays one: the file it points to is replaced, as a libuci
    // commit does.
    let file = fs.realpath(as_string(config_file));
    let handle = file != null ? fs.open(file, "r") : null;
    let locked = handle != null && handle.lock("x");
    // The lock must be on the file that is replaced, not on one that another
    // commit renamed away since it was opened.
    let current = locked ? fs.stat(file) : null;
    let held = locked ? fs.stat("/proc/self/fd/" + handle.fileno()) : null;
    let before = current != null && held != null && current.inode == held.inode ? fs.readfile(file) : null;
    if (before != null && fs.mkdir(dir + "/save", 0700) && fs.writefile(copy, before) != null && fs.readfile(copy) === before) {
        if (keep_existing && trim(command_text([ ...base, "get", own ])) != "")
            result = "kept";
        // uci skips a staged option whose section does not exist, and the
        // commit still succeeds: only a copy that now holds the value counts.
        else if (fs.writefile(dir + "/save/" + OWN_OPTION_PACKAGE, own + "=" + shell_arg(value) + "\n") != null &&
                 command_ok([ ...base, "commit", OWN_OPTION_PACKAGE ]) &&
                 replace(command_text([ ...base, "get", own ]), /\n$/, "") == as_string(value)) {
            // Read back and flushed before and after the rename, as a
            // session commit does (core/durable.uc): a full overlay takes a
            // small write and keeps none of it, and the empty copy would
            // replace the whole configuration.
            let after = fs.readfile(copy);
            if (after != null && durable.durable_rewrite(file, after))
                result = "written";
        }
    }
    if (locked)
        handle.lock("u");
    if (handle != null)
        handle.close();
    command_ok([ "rm", "-rf", dir ]);
    // Later reads of this process see the file as it is now.
    if (result == "written" && runtime_cursor) {
        try { runtime_cursor.unload(parts.package); } catch (e) {}
        delete loaded_packages[parts.package];
    }
    return result;
}

// ---- an edit of one package, saved as a whole ---------------------------------

// The package name of the private copy session() edits.
const SESSION_PACKAGE = "prokop_session";
// How long a session commit waits for a file that other commits keep
// replacing before it gives up (conflict).
const SESSION_LOCK_SECONDS = 5;

function list_equal(left, right) {
    if (length(left) != length(right))
        return false;
    for (let i = 0; i < length(left); i++)
        if (as_string(left[i]) != as_string(right[i]))
            return false;
    return true;
}

// The private copy of config_file a session edits through the uci CLI: null
// when the file cannot be read. A symlink stays one: the file it points to is
// read and replaced, as a libuci commit does.
function session_copy(package_name, config_file, cli) {
    let file = fs.realpath(config_file);
    let before = null;
    let reader = file != null ? fs.open(file, "r") : null;
    if (reader != null) {
        // The lock a libuci read takes: no writer is half-way through.
        if (reader.lock("s"))
            before = reader.read("all");
        reader.close();
    }
    if (before == null)
        return null;
    let dir = trim(command_text([ "mktemp", "-d" ]));
    if (dir == "" || fs.stat(dir) == null)
        return null;
    let copy = dir + "/" + SESSION_PACKAGE;
    let base = [ as_string(cli) || "uci", "-q", "-c", dir, "-t", dir + "/save" ];
    let conflict = false;
    let release = function() {
        command_ok([ "rm", "-rf", dir ]);
    };
    // Read back: a full /tmp can take the write and keep none of it, and an
    // empty copy reads as a package without a section.
    if (!fs.mkdir(dir + "/save", 0700) || fs.writefile(copy, before) == null || fs.readfile(copy) !== before) {
        release();
        return null;
    }

    let own = function(path) {
        let parts = path_parts(path);
        if (parts == null || parts.package != package_name || parts.section == "")
            return null;
        return SESSION_PACKAGE + "." + parts.section + (parts.option != "" ? "." + parts.option : "");
    };
    let write = function(command, path, value) {
        let target = own(path);
        if (target == null)
            return false;
        return command_ok([ ...base, command, value == null ? target : target + "=" + as_string(value) ]);
    };
    // The lock libuci takes for a commit, on the file at that path now, not
    // on one that another commit renamed away since it was opened: null when
    // it cannot be had, or (conflict) when other commits kept replacing the
    // file for SESSION_LOCK_SECONDS.
    let lock_file = function() {
        let deadline = time() + SESSION_LOCK_SECONDS;
        for (;;) {
            let lock = fs.open(file, "r");
            if (lock == null || !lock.lock("x")) {
                if (lock != null)
                    lock.close();
                return null;
            }
            let now = fs.stat(file);
            let held = fs.stat("/proc/self/fd/" + lock.fileno());
            if (now != null && held != null && now.inode == held.inode)
                return lock;
            lock.close();
            if (time() > deadline) {
                conflict = true;
                return null;
            }
        }
    };
    // file becomes the committed copy, written next to it, read back and
    // flushed first (core/durable.uc). The lock is held only to check that
    // file still holds what the session read and to rename the copy over it,
    // so readers and other commits of the package wait no longer than for a
    // libuci commit. A file someone else changed meanwhile is left as it is
    // (conflict).
    let replace_config = function() {
        let after = fs.readfile(copy);
        if (after == null || fs.stat(file) == null)
            return false;
        if (after == before)
            return true;
        return durable.durable_rewrite(file, after, null, function(tmp, target) {
            let lock = lock_file();
            let current = lock != null ? lock.read("all") : null;
            let renamed = false;
            if (current != null && current != before)
                conflict = true;
            else if (current != null)
                renamed = fs.rename(tmp, target);
            if (lock != null)
                lock.close();
            return renamed;
        });
    };

    return {
        read: function(path) {
            let target = own(path);
            let value = target == null ? "" : replace(command_text([ ...base, "get", target ]), /\n$/, "");
            return { exists: value != "", value };
        },
        set: function(path, value) { return write("set", path, value); },
        delete: function(path) { return write("delete", path, null); },
        add_list: function(path, value) { return write("add_list", path, value); },
        del_list: function(path, value) { return write("del_list", path, value); },
        commit: function() {
            if (!command_ok([ ...base, "commit", SESSION_PACKAGE ]) || !replace_config())
                return false;
            // Later reads of this process see the file as it is now.
            if (runtime_cursor) {
                try { runtime_cursor.unload(package_name); } catch (e) {}
                delete loaded_packages[package_name];
            }
            return true;
        },
        conflict: function() { return conflict; },
        release
    };
}

// The fixture edits its state at once; what a session did not commit is
// taken back at its end, as the private copy is.
function session_fixture(package_name) {
    let prefix = package_name + ".";
    let saved = state_lines();
    let wrote = false, committed = false;
    let write = function(ok) {
        wrote = true;
        return ok;
    };
    return {
        read: function(path) {
            return { exists: state_exists(path), value: state_get(path) };
        },
        set: function(path, value) { return write(state_set(path, value)); },
        delete: function(path) { return write(state_delete(path)); },
        add_list: function(path, value) { return write(state_add_list(path, value)); },
        del_list: function(path, value) { return write(state_del_list(path, value)); },
        commit: function() {
            committed = state_commit(package_name);
            return committed;
        },
        release: function() {
            if (!wrote || committed)
                return;
            let lines = [];
            for (let line in state_lines())
                if (line != "" && substr(line, 0, length(prefix)) != prefix)
                    push(lines, line);
            for (let line in saved)
                if (line != "" && substr(line, 0, length(prefix)) == prefix)
                    push(lines, line);
            state_write_lines(lines);
        }
    };
}

// An edit of package_name (the file config_file) that commit() saves as a
// whole or not at all, and only when it changes something: after a change
// that was refused, commit() writes nothing and fails. set() of the value an
// option has, delete() of what is absent and del_list() of a value the list
// does not hold change nothing; set() of a list is a list ([] removes it).
// Paths are <package>.<section>[.<option>], @type[n] included.
//
// A libuci commit of the package would also commit what someone staged with
// `uci set` in /tmp/.uci/<package> (see commit_option), and libuci reads
// would see those staged values. So the session reads and edits a private
// copy of config_file under a package name of its own through the uci CLI
// (cli), and commit() replaces config_file with the committed copy. Changes
// staged in /tmp/.uci or in a LuCI session stay staged, and what the session
// reads is what config_file holds. No lock is held while the session edits:
// commit() takes the lock libuci takes for a commit only to replace the file,
// and only while the file still holds what the session read. When someone
// else changed it meanwhile, commit() writes nothing and fails, and
// conflict() is true: the caller starts its edit over. null when config_file
// cannot be read. The fixture edits its state and logs "commit <package>"
// for a commit that changes something.
function session(package_name, config_file, cli) {
    package_name = as_string(package_name);
    let backend = fixture_enabled() ? session_fixture(package_name) : session_copy(package_name, as_string(config_file), cli);
    if (backend == null)
        return null;

    let cache = {}, dirty = false, failed = false, open = true;
    let read = function(path) {
        path = as_string(path);
        if (cache[path] == null)
            cache[path] = backend.read(path);
        return cache[path];
    };
    let changed = function(ok) {
        cache = {};
        if (ok)
            dirty = true;
        else
            failed = true;
        return ok;
    };
    let remove = function(path) {
        if (!open)
            return false;
        return !read(path).exists || changed(backend.delete(path));
    };
    let close = function() {
        if (open)
            backend.release();
        open = false;
    };

    return {
        get: function(path) { return read(path).value; },
        exists: function(path) { return read(path).exists; },
        set: function(path, value) {
            if (!open)
                return false;
            let current = read(path);
            if (type(value) == "array") {
                let values = [];
                for (let item in value)
                    push(values, as_string(item));
                if (current.exists ? list_equal(words(current.value), values) : length(values) == 0)
                    return true;
                if (current.exists && !changed(backend.delete(path)))
                    return false;
                for (let item in values)
                    if (!changed(backend.add_list(path, item)))
                        return false;
                return true;
            }
            value = as_string(value);
            if (value == "")
                return remove(path);
            return (current.exists && current.value == value) || changed(backend.set(path, value));
        },
        delete: remove,
        add_list: function(path, value) {
            return open && changed(backend.add_list(path, as_string(value)));
        },
        del_list: function(path, value) {
            if (!open || index(words(read(path).value), as_string(value)) < 0)
                return false;
            return changed(backend.del_list(path, as_string(value)));
        },
        // True when the package holds the edit (also when it changed
        // nothing); the session is closed afterwards.
        commit: function() {
            let ok = open && !failed && (!dirty || backend.commit());
            close();
            return ok;
        },
        // The commit failed because someone else changed the file.
        conflict: function() { return backend.conflict != null && backend.conflict(); },
        // Something was edited (also when the edits ended where it began).
        changed: function() { return dirty; },
        close
    };
}

return {
    available,
    load,
    refresh,
    get,
    get_all,
    exists,
    delete: delete_path,
    set_section,
    rename,
    add,
    set,
    add_list,
    del_list,
    commit,
    commit_option,
    session,
    sections,
    all_sections,
    section_objects
};
