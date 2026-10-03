// Test-only stand-in for the OpenWrt uci CLI (UC-009), run through the
// wrapper tests/helpers/uci_cli/uci. Never shipped.
//
// tests/helpers/uci_cli/select.sh hands it to the code under test (through
// PROKOP_AUTOTUNE_UCI) only when no real uci is on PATH, or when
// PROKOP_TEST_UCI_CLI=shim asks for it. It implements the part of the CLI
// Prokop shells out to, with the semantics of libuci and cli.c:
//
//   uci [-q] [-s] -c CONFDIR -t SAVEDIR get|show|set|delete|add_list|del_list|commit ARG
//
// Changes are kept as deltas in SAVEDIR/<package> (uci's delta format) and
// commit merges them into CONFDIR/<package>, rewrites it in uci's canonical
// export form and empties the delta file. Anything outside this subset
// (other commands and options, @type[n] and anonymous cfgXXXXXX references,
// ';' statement separators, line continuations, changes staged in the host
// save directory, which the real CLI merges even with -t) is refused loudly
// on stderr and in $PROKOP_TEST_UCI_SHIM_LOG, never approximated.
// tests/uci_cli_shim.sh pins the behaviour against the real CLI.

let fs = require("fs");

const SHIM_LOG = getenv("PROKOP_TEST_UCI_SHIM_LOG") || "";
const HOST_SAVEDIR = getenv("PROKOP_TEST_UCI_SHIM_HOST_SAVEDIR") || "/tmp/.uci";

let quiet = false;

function unsupported(what) {
    let message = "uci (Prokop test shim): unsupported " + what +
        "; install the OpenWrt uci CLI or extend tests/helpers/uci_cli/uci.uc\n";
    warn(message);
    if (SHIM_LOG != "") {
        let log = fs.open(SHIM_LOG, "a");
        if (log) { log.write(message); log.close(); }
    }
    exit(2);
}

const MESSAGES = { NOTFOUND: "Entry not found", INVAL: "Invalid argument", PARSE: "Parse error" };
function uci_error(code, detail, line) {
    if (!quiet)
        warn("uci: " + MESSAGES[code] + (detail ? " (" + detail + ")" : "") + (line ? " at line " + line : "") + "\n");
    exit(1);
}

// ---- names and values (libuci uci_validate_*) ------------------------------

function valid_name(s) { return type(s) == "string" && match(s, /^[A-Za-z0-9_]+$/) != null; }
function valid_package(s) { return type(s) == "string" && match(s, /^[A-Za-z0-9_-]+$/) != null; }
function valid_type(s) { return type(s) == "string" && match(s, /^[!-~]+$/) != null; }
function valid_text(s) {
    for (let i = 0; i < length(s); i++) {
        let c = ord(s, i);
        if (c < 32 && c != 9 && c != 10 && c != 13) return false;
    }
    return true;
}

// ---- the config file syntax (file.c) ---------------------------------------

// Statements of a config file: [{ line, words: [{ text, raw }] }]. A word is
// raw when it had no quotes or escapes (keywords must be raw).
function statements(text) {
    let result = [], words = [], word = null, line = 1, start = 1;
    let i = 0, n = length(text);
    let end_word = () => { if (word != null) push(words, word); word = null; };
    let end_statement = () => { end_word(); if (length(words)) push(result, { line: start, words }); words = []; };
    let begin_word = () => { if (word == null) { if (!length(words)) start = line; word = { text: "", raw: true }; } };
    while (i < n) {
        let c = substr(text, i, 1);
        if (c == "\n") { end_statement(); line++; i++; continue; }
        if (c == " " || c == "\t" || c == "\r" || c == "\f" || c == "\v") { end_word(); i++; continue; }
        if (c == "#") { end_word(); while (i < n && substr(text, i, 1) != "\n") i++; continue; }
        if (c == ";") unsupported("';' statement separator (line " + line + ")");
        begin_word();
        if (c == "'") {
            let rest = substr(text, i + 1), close = index(rest, "'");
            if (close < 0) return { error: "EOF with unterminated '", line };
            let piece = substr(rest, 0, close);
            word.text += piece; word.raw = false;
            line += length(split(piece, "\n")) - 1;
            i += close + 2;
            continue;
        }
        if (c == "\"") {
            word.raw = false;
            i++;
            while (true) {
                if (i >= n) return { error: "EOF with unterminated \"", line };
                let d = substr(text, i, 1);
                if (d == "\"") { i++; break; }
                if (d == "\\") {
                    i++;
                    if (i >= n || substr(text, i, 1) == "\n" || substr(text, i, 2) == "\r\n")
                        unsupported("backslash line continuation (line " + line + ")");
                    d = substr(text, i, 1);
                }
                if (d == "\n") line++;
                word.text += d;
                i++;
            }
            continue;
        }
        if (c == "\\") {
            word.raw = false;
            i++;
            if (i >= n || substr(text, i, 1) == "\n" || substr(text, i, 2) == "\r\n")
                unsupported("backslash line continuation (line " + line + ")");
        }
        word.text += substr(text, i, 1);
        i++;
    }
    end_statement();
    return { statements: result };
}

function find_section(pkg, name) {
    for (let s in pkg.sections) if (s.name === name) return s;
    return null;
}
function find_option(section, name) {
    for (let o in section.options) if (o.name === name) return o;
    return null;
}
function remove_item(list, item) {
    let kept = filter(list, (x) => x !== item);
    splice(list, 0, length(list), ...kept);
}

// ---- operations (list.c); each returns true when it changed something ------
// (a delta is recorded), false when not, or an error code.

function op_set(pkg, ptr) {
    let section = find_section(pkg, ptr.section);
    if (ptr.option == null) {
        if (ptr.value != "" && !valid_type(ptr.value)) return "INVAL";
        if (ptr.value == "") {
            if (!section) return false;
            remove_item(pkg.sections, section);
            return "DELETED";
        }
        if (!section) { push(pkg.sections, { name: ptr.section, type: ptr.value, options: [] }); return true; }
        if (section.type == ptr.value) return false;
        section.type = ptr.value;
        return true;
    }
    if (!section) return "INVAL";
    let option = find_option(section, ptr.option);
    if (ptr.value == "") {
        if (!option) return false;
        remove_item(section.options, option);
        return "DELETED";
    }
    if (!option) { push(section.options, { name: ptr.option, list: false, value: ptr.value }); return true; }
    if (!option.list && option.value == ptr.value) return false;
    option.list = false;
    option.value = ptr.value;
    return true;
}

function op_delete(pkg, ptr) {
    let section = find_section(pkg, ptr.section);
    if (!section) return "NOTFOUND";
    if (ptr.option == null) { remove_item(pkg.sections, section); return true; }
    let option = find_option(section, ptr.option);
    if (!option) return "NOTFOUND";
    remove_item(section.options, option);
    return true;
}

function op_add_list(pkg, ptr) {
    let section = find_section(pkg, ptr.section);
    if (!section || ptr.option == null) return "INVAL";
    let option = find_option(section, ptr.option);
    if (!option) push(section.options, { name: ptr.option, list: true, value: [ ptr.value ] });
    else if (!option.list) { option.list = true; option.value = [ option.value, ptr.value ]; }
    else push(option.value, ptr.value);
    return true;
}

function op_del_list(pkg, ptr) {
    let section = find_section(pkg, ptr.section);
    if (!section || ptr.option == null) return "INVAL";
    let option = find_option(section, ptr.option);
    if (!option || !option.list) return false;
    option.value = filter(option.value, (v) => v !== ptr.value);
    return true;
}

const OPS = { set: op_set, delete: op_delete, add_list: op_add_list, del_list: op_del_list };
const DELTA_PREFIX = { set: "", delete: "-", add_list: "|", del_list: "~" };

// ---- packages ---------------------------------------------------------------

function parse_package(text) {
    let parsed = statements(text);
    if (parsed.error) return parsed;
    let pkg = { sections: [] }, current = null;
    for (let st in parsed.statements) {
        let w = st.words, keyword = w[0].raw ? w[0].text : "";
        let fail = (reason) => ({ error: reason, line: st.line });
        if (keyword == "package" || keyword == "p") {
            if (length(w) < 2) return fail("package without name");
            if (length(w) > 2) return fail("too many arguments");
            if (!valid_package(w[1].text)) return fail("invalid character in name field");
        }
        else if (keyword == "config" || keyword == "c") {
            if (length(w) < 2 || w[1].text == "") return fail("insufficient arguments");
            if (length(w) > 3) return fail("too many arguments");
            let type_name = w[1].text, name = length(w) == 3 ? w[2].text : "";
            if (!valid_type(type_name)) return fail("invalid character in type field");
            if (name == "") {
                current = { name: null, type: type_name, options: [] };
                push(pkg.sections, current);
                continue;
            }
            if (!valid_name(name)) return fail("invalid character in name field");
            current = find_section(pkg, name);
            if (current && current.type != type_name)
                return fail("section of different type overwrites prior section with same name");
            if (!current) {
                current = { name, type: type_name, options: [] };
                push(pkg.sections, current);
            }
        }
        else if (keyword == "option" || keyword == "o" || keyword == "list" || keyword == "l") {
            if (!current) return fail("option/list command found before the first section");
            if (length(w) < 2 || w[1].text == "") return fail("insufficient arguments");
            if (length(w) > 3) return fail("too many arguments");
            if (!valid_name(w[1].text)) return fail("invalid character in name field");
            let value = length(w) == 3 ? w[2].text : "";
            let option = find_option(current, w[1].text);
            if (substr(keyword, 0, 1) == "o") {
                // Without a value it changes nothing: an earlier value stays
                // (libuci's uci_set of an empty value on load).
                if (value == "") continue;
                if (option) { option.list = false; option.value = value; }
                else push(current.options, { name: w[1].text, list: false, value });
            }
            else if (!option) push(current.options, { name: w[1].text, list: true, value: [ value ] });
            else if (!option.list) { option.list = true; option.value = [ option.value, value ]; }
            else push(option.value, value);
        }
        else return fail("invalid command");
    }
    return { package: pkg };
}

function quote(value) { return "'" + replace(value, /'/g, "'\\''") + "'"; }
function escape(value) { return replace(value, /'/g, "'\\''"); }

function export_package(pkg) {
    let out = "";
    for (let s in pkg.sections) {
        out += "\nconfig " + escape(s.type) + (s.name == null ? "" : " " + quote(s.name)) + "\n";
        for (let o in s.options) {
            if (o.list) for (let v in o.value) out += "\tlist " + escape(o.name) + " " + quote(v) + "\n";
            else out += "\toption " + escape(o.name) + " " + quote(o.value) + "\n";
        }
    }
    return out + "\n";
}

// uci_parse_ptr: package[.section[.option]][=value], split at the first '='.
function parse_ptr(arg) {
    let value = null, eq = index(arg, "=");
    if (eq >= 0) { value = substr(arg, eq + 1); arg = substr(arg, 0, eq); }
    let parts = split(arg, ".");
    if (length(parts) > 3 || !valid_package(parts[0])) return null;
    let ptr = { package: parts[0], section: parts[1], option: parts[2], value };
    if (ptr.option != null && !valid_name(ptr.option)) return null;
    if (value != null && !valid_text(value)) return null;
    return ptr;
}

let confdir = null, savedir = null;

function delta_path(name) { return savedir + "/" + name; }

// Loads CONFDIR/<name> with the deltas of SAVEDIR/<name> applied, as
// uci_load does. Returns { pkg, changes } (changes: delta entries applied).
function load(name) {
    let host = fs.stat(HOST_SAVEDIR + "/" + name);
    if (host != null && host.size > 0)
        unsupported("changes staged in " + HOST_SAVEDIR + "/" + name + " (the real uci merges them even with -t)");
    let text = fs.readfile(confdir + "/" + name);
    if (text == null) uci_error("NOTFOUND");
    let parsed = parse_package(text);
    if (parsed.error) uci_error("PARSE", parsed.error, parsed.line);
    let pkg = parsed.package, changes = 0;
    // One delta entry per line, a quoted value may span lines.
    let delta = statements(fs.readfile(delta_path(name)) ?? "");
    if (delta.error) unsupported("delta file " + delta_path(name) + " (" + delta.error + ")");
    for (let st in delta.statements) {
        // Like uci_parse_delta: an entry that does not parse or apply is skipped.
        if (length(st.words) != 1) continue;
        let entry = st.words[0].text, cmd = "set", prefix = substr(entry, 0, 1);
        if (index("+@^", prefix) >= 0) unsupported("delta entry '" + entry + "' in " + delta_path(name));
        if (prefix == "-") cmd = "delete";
        else if (prefix == "|") cmd = "add_list";
        else if (prefix == "~") cmd = "del_list";
        if (cmd != "set") entry = substr(entry, 1);
        let ptr = parse_ptr(entry);
        if (ptr == null || ptr.package != name || ptr.section == null) continue;
        if (!valid_name(ptr.section)) unsupported("section reference '" + ptr.section + "' in " + delta_path(name));
        if (cmd == "delete" && ptr.value != null) unsupported("delta entry '" + entry + "' in " + delta_path(name));
        if (cmd != "delete" && ptr.value == null) continue;
        let result = OPS[cmd](pkg, ptr);
        if (type(result) != "string" || result == "DELETED") changes++;
    }
    return { pkg, changes };
}

function append_delta(name, cmd, ptr) {
    let st = fs.stat(savedir);
    if (st == null && !fs.mkdir(savedir, 0700)) uci_error("INVAL", "cannot create " + savedir);
    let line = DELTA_PREFIX[cmd] + ptr.package + "." + ptr.section + (ptr.option == null ? "" : "." + ptr.option);
    if (ptr.value != null && cmd != "delete") line += "=" + quote(ptr.value);
    let handle = fs.open(delta_path(name), "a");
    if (!handle) uci_error("INVAL", "cannot write " + delta_path(name));
    handle.lock("x");
    handle.write(line + "\n");
    handle.close();
}

// A section the package holds only as an anonymous one has a generated
// cfgXXXXXX name in libuci the shim cannot reproduce.
function check_reference(pkg, ptr) {
    if (ptr.section == null) return;
    if (substr(ptr.section, 0, 1) == "@") unsupported("section reference '" + ptr.section + "'");
    // libuci takes any other invalid name for a failed extended lookup.
    if (!valid_name(ptr.section)) uci_error("INVAL");
    if (find_section(pkg, ptr.section) == null && match(ptr.section, /^cfg[0-9a-f]{6}$/) &&
        length(filter(pkg.sections, (s) => s.name == null)))
        unsupported("anonymous section reference '" + ptr.section + "'");
}

function show_value(option, quoted) {
    if (!option.list) return (quoted ? quote(option.value) : option.value) + "\n";
    return join(" ", map(option.value, (v) => (quoted || match(v, /[ \t\r\n]/)) ? quote(v) : v)) + "\n";
}

function show_section(name, section, ref) {
    let out = name + "." + ref + "=" + section.type + "\n";
    for (let o in section.options) out += name + "." + ref + "." + o.name + "=" + show_value(o, true);
    return out;
}

// ---- command line -----------------------------------------------------------

let args = [ ...ARGV ];
while (length(args) && substr(args[0], 0, 1) == "-") {
    let flag = shift(args);
    if (flag == "-q") quiet = true;
    else if (flag == "-s") ;
    else if (flag == "-c" || flag == "-t") {
        if (!length(args)) unsupported("option " + flag + " without a directory");
        let dir = replace(shift(args), /\/+$/, "");
        if (flag == "-c") confdir = dir; else savedir = dir;
    }
    else unsupported("option " + flag);
}
if (confdir == null || savedir == null || confdir == "" || savedir == "")
    unsupported("call without -c CONFDIR and -t SAVEDIR (the shim never uses /etc/config or /tmp/.uci)");
let same_dir = (a, b) => a == b || (fs.realpath(a) != null && fs.realpath(a) == fs.realpath(b));
if (same_dir(confdir, "/etc/config")) unsupported("live directory " + confdir);
if (same_dir(savedir, HOST_SAVEDIR)) unsupported("save directory " + savedir + " (the host's " + HOST_SAVEDIR + ")");

let command = shift(args);
if (command == null) unsupported("call without a command");
if (index([ "get", "show", "set", "delete", "add_list", "del_list", "commit" ], command) < 0)
    unsupported("command '" + command + "'");
if (length(args) != 1) unsupported("'" + command + "' with " + length(args) + " arguments");

let ptr = parse_ptr(args[0]);
if (ptr == null) uci_error("PARSE");

if (command == "commit") {
    if (ptr.section != null || ptr.value != null) unsupported("commit argument '" + args[0] + "'");
    let config = confdir + "/" + ptr.package;
    let handle = fs.open(config, "r");
    if (!handle) uci_error("NOTFOUND");
    handle.lock("x");
    let loaded = load(ptr.package);
    // uci_file_commit: without a delta that applies, the file stays as it is.
    if (loaded.changes > 0) {
        let st = fs.stat(config);
        let tmp = confdir + "/." + ptr.package + ".uci-shim-" + fs.readlink("/proc/self");
        if (fs.writefile(tmp, export_package(loaded.pkg)) == null || !fs.chmod(tmp, st.mode) || !fs.rename(tmp, config)) {
            fs.unlink(tmp);
            uci_error("INVAL", "cannot write " + config);
        }
        fs.writefile(delta_path(ptr.package), "");
    }
    handle.close();
    exit(0);
}

let loaded = load(ptr.package), pkg = loaded.pkg;
check_reference(pkg, ptr);

if (command == "get" || command == "show") {
    if (ptr.value != null) exit(1);
    if (ptr.section == null) {
        if (command == "get") exit(0);
        let seen = {}, out = "";
        for (let s in pkg.sections) {
            let index_of_type = seen[s.type] || 0;
            seen[s.type] = index_of_type + 1;
            out += show_section(ptr.package, s, s.name ?? sprintf("@%s[%d]", s.type, index_of_type));
        }
        print(out);
        exit(0);
    }
    let section = find_section(pkg, ptr.section);
    let option = section && ptr.option != null ? find_option(section, ptr.option) : null;
    if (!section || (ptr.option != null && !option)) uci_error("NOTFOUND");
    if (command == "get") print(option ? show_value(option, false) : section.type + "\n");
    else if (option) print(ptr.package + "." + ptr.section + "." + option.name + "=" + show_value(option, true));
    else print(show_section(ptr.package, section, ptr.section));
    exit(0);
}

if (ptr.section == null) unsupported("'" + command + "' of a whole package");
if (command == "delete" && ptr.value != null) unsupported("delete by list index or value");
if (command != "delete" && ptr.value == null) uci_error("INVAL");

let result = OPS[command](pkg, ptr);
if (result === "DELETED") append_delta(ptr.package, "delete", { ...ptr, value: null });
else if (type(result) == "string") uci_error(result);
else if (result) append_delta(ptr.package, command, ptr);
exit(0);
