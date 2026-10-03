#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");

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
        c.load(package_name);
        loaded_packages[package_name] = true;
        return true;
    }
    catch (e) {
        return false;
    }
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
        if (parts.option == "")
            c.delete(parts.package, parts.section);
        else
            c.delete(parts.package, parts.section, parts.option);
        return true;
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
        c.set(parts.package, parts.section, as_string(type_name));
        return true;
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
        return c.rename(parts.package, parts.section, name) != false;
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
        c.set(parts.package, parts.section, parts.option, type(value) == "array" ? value : as_string(value));
        return true;
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
        c.set(parts.package, parts.section, parts.option, values);
        return true;
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
            c.delete(parts.package, parts.section, parts.option);
        else
            c.set(parts.package, parts.section, parts.option, values);
        return true;
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
        return c.commit(package_name) != false;
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
    let handle = fs.open(as_string(config_file), "r");
    let locked = handle != null && handle.lock("x");
    // The lock must be on the file that is replaced, not on one that another
    // commit renamed away since it was opened.
    let current = locked ? fs.stat(config_file) : null;
    let held = locked ? fs.stat("/proc/self/fd/" + handle.fileno()) : null;
    let before = current != null && held != null && current.inode == held.inode ? fs.readfile(config_file) : null;
    if (before != null && fs.mkdir(dir + "/save", 0700) && fs.writefile(copy, before) != null) {
        if (keep_existing && trim(command_text([ ...base, "get", own ])) != "")
            result = "kept";
        // uci skips a staged option whose section does not exist, and the
        // commit still succeeds: only a copy that now holds the value counts.
        else if (fs.writefile(dir + "/save/" + OWN_OPTION_PACKAGE, own + "=" + shell_arg(value) + "\n") != null &&
                 command_ok([ ...base, "commit", OWN_OPTION_PACKAGE ]) &&
                 replace(command_text([ ...base, "get", own ]), /\n$/, "") == as_string(value)) {
            let after = fs.readfile(copy);
            let tmp = fs.dirname(config_file) + "/." + fs.basename(config_file) + ".prokop-" + as_string(fs.readlink("/proc/self"));
            let out = after != null ? fs.open(tmp, "w", 0600) : null;
            let written = out != null && out.write(after) != null;
            if (out != null)
                out.close();
            if (written && fs.chmod(tmp, current.mode) && fs.rename(tmp, config_file))
                result = "written";
            else
                fs.unlink(tmp);
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

return {
    available,
    load,
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
    sections,
    all_sections,
    section_objects
};
