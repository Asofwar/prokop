#!/usr/bin/env ucode
// R2 pin_guard: a server chosen by hand in a rule's selector that stops
// answering gives way to the rule's URLTest group.
//
// Opt-in per rule (option pin_guard, off by default); the generator writes
// { section, selector, fallback, url } into the rule's section cache only
// when the rule has a URLTest group (singbox/generator.uc). The idea comes
// from cergo666/netshift 28560be6 (pinguard.sh); this is a rewrite.
//
// Health data. Every CHECK_INTERVAL the worker reads the Clash API proxies
// once. A latency entry of the chosen server that is new since the last
// check and has a delay is a passed check and costs nothing more: sing-box
// writes one after every successful test, its URLTest group's and the
// dashboard's alike. Otherwise one delay test of the chosen server runs
// through the Clash API, the same test the Priority worker uses. It cannot
// be left out: a URLTest group that carries no traffic, which is the case
// while the selector points at a server of its own, stops testing after its
// idle_timeout, so without the test a dead server would never be noticed.
// A check that cannot reach the Clash API counts neither way.
//
// Switch. After FAILURES_TO_SWITCH failed checks in a row (one check that
// passes starts the count again, as the Priority worker counts its
// failures) the selector goes to the fallback group with the "auto" mark,
// so the choice saved for a reboot (C4, core/selector_choices.uc) still
// names the server the user chose. The switch is recorded in EVENTS_FILE;
// the stop capture leaves a selector alone while it is where the guard put
// it (service/lifecycle.uc capture_selector_state), and the dashboard shows
// the record.
//
// No way back on its own: the guard does not test the server it left and
// does not switch back. Coming back would need tests of a server that
// carries no traffic and could flap between a half-dead server and the
// group; the URLTest group already takes the server again by itself when
// it is the fastest. The user chooses the server again on the dashboard,
// which clears the record. After a reboot the saved choice comes back and
// the guard checks it again from the start.

let fs = require("fs");
let common = require("core.common");
let process_identity = require("core.process_identity");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const RUNTIME_STATE_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const SECTION_CACHE_DIR = getenv("PROKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const PID_FILE = getenv("PROKOP_PIN_GUARD_PID_FILE") || RUNTIME_STATE_DIR + "/pin-guard.pid";
const EVENTS_FILE = getenv("PROKOP_PIN_GUARD_EVENTS_FILE") || RUNTIME_STATE_DIR + "/pin-guard.json";
const PIN_GUARD_UC = getenv("PROKOP_PIN_GUARD_UC") || LIB_DIR + "/singbox/pin_guard.uc";
const DIAGNOSTICS_UC = getenv("PROKOP_DIAGNOSTICS_UC") || LIB_DIR + "/diagnostics/runtime.uc";

const FAILURES_TO_SWITCH = 3;
const CHECK_INTERVAL_MS = int(getenv("PROKOP_PIN_GUARD_INTERVAL_MS") || "20000");
const CHECK_TIMEOUT_MS = "5000";
// Tests only: the worker stops after this many checks.
const CYCLES = int(getenv("PROKOP_PIN_GUARD_CYCLES") || "0");

// Whether a delay test ran in this check (see cycle()).
let tested = false;

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_success_from_args(args) {
    let status = int(system(command_from_args(args) + " >/dev/null 2>&1"));
    return status == 0;
}

function log_message(message, level) {
    command_success_from_args([ "logger", "-t", "prokop", "[" + as_string(level || "info") + "] pin guard: " + as_string(message) ]);
}

function clash(args) {
    let command = command_from_args([ "ucode", "-L", LIB_DIR, DIAGNOSTICS_UC, "clash-api" ]);
    for (let arg in args)
        command += " " + shell_quote(arg);
    let pipe = fs.popen(command + " 2>/dev/null", "r");
    if (pipe == null)
        return { ok: false, value: null };
    let output = as_string(pipe.read("all") || "");
    let status = pipe.close();
    let value = null;
    try {
        value = json(output);
    }
    catch (e) {
        value = null;
    }
    return { ok: status == 0, value };
}

// The rules that asked for the guard, as the running generation's section
// caches name them.
function guards_from_cache() {
    let result = [];
    for (let path in (fs.glob(SECTION_CACHE_DIR + "/*.json") || [])) {
        let guard = object_or_empty(object_or_empty(read_json_file(path)).pinGuard);
        let selector = as_string(guard.selector);
        let fallback = as_string(guard.fallback);
        if (selector != "" && fallback != "" && selector != fallback)
            push(result, { section: as_string(guard.section), selector, fallback, url: as_string(guard.url) });
    }
    return result;
}

function read_events() {
    let result = {};
    for (let selector, event in object_or_empty(read_json_file(EVENTS_FILE))) {
        event = object_or_empty(event);
        if (as_string(event.to) != "")
            result[selector] = event;
    }
    return result;
}

function write_events(events) {
    if (length(keys(events)) == 0) {
        if (fs.stat(EVENTS_FILE) != null)
            fs.unlink(EVENTS_FILE);
        return true;
    }
    let stamp = clock();
    let temporary = EVENTS_FILE + ".tmp." + stamp[0] + "." + stamp[1];
    if (!fs.writefile(temporary, sprintf("%J\n", events))) {
        fs.unlink(temporary);
        return false;
    }
    if (!fs.rename(temporary, EVENTS_FILE)) {
        fs.unlink(temporary);
        return false;
    }
    return true;
}

// A selector the guard can judge: a server, not a group (a URLTest or a
// Priority group looks after itself) and not Direct or Block.
function guarded_node(proxies, now) {
    if (now == "")
        return false;
    let kind = lc(as_string(object_or_empty(proxies[now]).type));
    return index([ "", "selector", "urltest", "fallback", "loadbalance", "direct", "block", "reject", "dns" ], kind) < 0;
}

function last_history(proxy) {
    let history = array_or_empty(object_or_empty(proxy).history);
    return length(history) > 0 ? object_or_empty(history[length(history) - 1]) : {};
}

// One check of one guarded rule. state: { node, failures, seen }.
function check_guard(guard, state, proxies, events) {
    let selector = object_or_empty(proxies[guard.selector]);
    if (lc(as_string(selector.type)) != "selector") {
        state.node = "";
        return false;
    }
    let now = as_string(selector.now);
    let changed = false;

    // The user chose again since the switch: the record is done with.
    let event = events[guard.selector];
    if (event != null && as_string(event.to) != now) {
        delete events[guard.selector];
        changed = true;
    }

    if (!guarded_node(proxies, now) || now == guard.fallback) {
        state.node = "";
        return changed;
    }
    if (state.node != now) {
        state.node = now;
        state.failures = 0;
        state.seen = null;
    }

    let last = last_history(proxies[now]);
    let stamp = as_string(last.time);
    let passed = false;
    if (stamp != "" && state.seen != null && stamp != state.seen && int(last.delay || 0) > 0)
        passed = true;
    else {
        let probe = clash([ "get_proxy_latency", now, CHECK_TIMEOUT_MS, guard.url ]);
        tested = true;
        passed = probe.ok && type(probe.value) == "object" && int(probe.value.delay || 0) > 0;
    }
    // The next check judges only an entry newer than this one; its own test,
    // whichever way it went, wrote one that is not news then.
    state.seen = null;

    if (passed) {
        state.failures = 0;
        return changed;
    }

    state.failures++;
    if (state.failures < FAILURES_TO_SWITCH) {
        log_message("server '" + now + "' of rule '" + guard.section + "' did not answer (" + state.failures + "/" + FAILURES_TO_SWITCH + ")", "info");
        return changed;
    }

    state.failures = 0;
    let switched = clash([ "set_group_proxy", guard.selector, guard.fallback, "auto" ]);
    if (!switched.ok) {
        log_message("could not switch rule '" + guard.section + "' to its URLTest group '" + guard.fallback + "'", "warn");
        return changed;
    }
    events[guard.selector] = { section: guard.section, from: now, to: guard.fallback, time: time() };
    state.node = "";
    log_message("server '" + now + "' chosen in rule '" + guard.section + "' did not answer " + FAILURES_TO_SWITCH +
        " checks in a row; switched the rule to its URLTest group '" + guard.fallback + "'. Choose the server again when it works.", "warn");
    return true;
}

// The history stamps this check saw, for the next one.
function remember_stamps(guards, states, proxies) {
    for (let guard in guards) {
        let state = states[guard.selector];
        if (state.node != "")
            state.seen = as_string(last_history(proxies[state.node]).time);
    }
}

function cycle(guards, states) {
    let answer = clash([ "get_proxies" ]);
    let proxies = answer.ok ? object_or_empty(object_or_empty(answer.value).proxies) : null;
    if (proxies == null || length(keys(proxies)) == 0)
        return;

    let events = read_events();
    let changed = false;
    tested = false;
    for (let guard in guards)
        if (check_guard(guard, states[guard.selector], proxies, events))
            changed = true;
    if (changed)
        write_events(events);

    // A test of this check wrote an entry the next check must not count as
    // news: read the proxies again then.
    if (tested) {
        answer = clash([ "get_proxies" ]);
        proxies = answer.ok ? object_or_empty(object_or_empty(answer.value).proxies) : {};
    }
    remember_stamps(guards, states, proxies);
}

function worker() {
    let guards = guards_from_cache();
    if (length(guards) == 0)
        return 0;
    let states = {};
    for (let guard in guards)
        states[guard.selector] = { node: "", failures: 0, seen: null };

    for (let n = 1; ; n++) {
        cycle(guards, states);
        if (CYCLES > 0 && n >= CYCLES)
            return 0;
        sleep(CHECK_INTERVAL_MS);
    }
}

function stop_runtime() {
    process_identity.signal(PID_FILE, "ucode", [ "ucode", "-L", LIB_DIR, PIN_GUARD_UC, "worker" ], true, "TERM");
    if (fs.stat(PID_FILE) != null)
        fs.unlink(PID_FILE);
    return 0;
}

// Records of rules that no longer ask for the guard go; the others stay
// across a reload, so that a stop after it still leaves the saved choice
// alone.
function prune_events(guards) {
    let wanted = {};
    for (let guard in guards)
        wanted[guard.selector] = guard.fallback;
    let events = read_events();
    let changed = false;
    for (let selector, event in events)
        if (wanted[selector] != as_string(event.to)) {
            delete events[selector];
            changed = true;
        }
    if (changed)
        write_events(events);
}

function start_runtime() {
    stop_runtime();
    let guards = guards_from_cache();
    prune_events(guards);
    if (length(guards) == 0)
        return 0;

    // procd's lock (fd 1000) stays with procd (R5); a shell without it
    // would take "1000" for an argument of the worker.
    let close_procd_lock = fs.stat("/proc/self/fd/1000") != null ? " 1000>&-" : "";
    let command = command_from_args([ "ucode", "-L", LIB_DIR, PIN_GUARD_UC, "worker" ]) +
        " >/dev/null 2>&1" + close_procd_lock + " & echo $!";
    let pipe = fs.popen(command_from_args([ "sh", "-c", command ]), "r");
    let pid = pipe != null ? trim(as_string(pipe.read("all") || "")) : "";
    if (pipe != null)
        pipe.close();
    return process_identity.record(PID_FILE, pid) ? 0 : 1;
}

let mode = ARGV[0] || "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
else {
    warn("Usage: singbox/pin_guard.uc <start-runtime|stop-runtime|worker>\n");
    exit(1);
}
