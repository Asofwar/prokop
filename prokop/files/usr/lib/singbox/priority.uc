#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let process_identity = require("core.process_identity");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json = common.write_json;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const RUNTIME_STATE_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const SECTION_CACHE_DIR = getenv("PROKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const PRIORITY_PID_FILE = getenv("PROKOP_PRIORITY_PID_FILE") || RUNTIME_STATE_DIR + "/priority.pid";
const PRIORITY_UC = getenv("PROKOP_PRIORITY_UC") || LIB_DIR + "/singbox/priority.uc";
const DIAGNOSTICS_UC = getenv("PROKOP_DIAGNOSTICS_UC") || LIB_DIR + "/diagnostics/runtime.uc";
const SERVICE_ADDRESS = getenv("SB_SERVICE_MIXED_INBOUND_ADDRESS") || "127.0.0.1";

// C15: the payload check of a group downloads PAYLOAD_BYTES over HTTPS
// through the node under test (its probe selector and inbound, see
// singbox/generator.uc), so "the handshake works but no data flows" is a
// failure too. A node whose download failed is left alone for
// PAYLOAD_QUARANTINE_SECONDS; the active node is checked again every
// PAYLOAD_RECHECK_SECONDS, the quick delay check runs as before meanwhile.
const PAYLOAD_URL = getenv("PROKOP_PRIORITY_PAYLOAD_URL") || "https://speed.cloudflare.com/__down?bytes=32768";
const PAYLOAD_BYTES = int(getenv("PROKOP_PRIORITY_PAYLOAD_BYTES") || "32768");
const PAYLOAD_MAX_TIME = int(getenv("PROKOP_PRIORITY_PAYLOAD_MAX_TIME") || "15");
const HEALTH_FILE = RUNTIME_STATE_DIR + "/priority-health.json";
const PAYLOAD_QUARANTINE_SECONDS = 60;
const PAYLOAD_RECHECK_SECONDS = 180;

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "prokop", "[" + level + "] priority: " + as_string(message) ]);
}

// The monotonic clock: these are only check deadlines, and the wall clock
// steps when NTP sets it at boot (B5).
function now_seconds() {
    return int(clock(true)[0]);
}

function duration_to_milliseconds(value, fallback_ms) {
    let rest = as_string(value);
    if (rest == "")
        return fallback_ms;

    let total = 0.0;
    let multipliers = {
        ns: 0.000001,
        us: 0.001,
        ms: 1,
        s: 1000,
        m: 60000,
        h: 3600000,
        d: 86400000
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return fallback_ms;

        let token = as_string(matched[0]);
        total += (matched[1] * 1) * multipliers[matched[3]];
        rest = substr(rest, length(token));
    }

    return total <= 0 ? fallback_ms : int(total + 0.5);
}

function duration_to_seconds(value, fallback_seconds) {
    let ms = duration_to_milliseconds(value, fallback_seconds * 1000);
    let seconds = int((ms + 999) / 1000);
    return seconds > 0 ? seconds : fallback_seconds;
}

function bool_value(value, fallback) {
    if (value == null || value == "")
        return !!fallback;
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function normalize_group(group, tag_name) {
    group = object_or_empty(group);
    let levels = [];
    for (let level in array_or_empty(group.levels)) {
        let outbounds = [];
        for (let outbound in array_or_empty(level.outbounds)) {
            outbound = as_string(outbound);
            if (outbound != "")
                push(outbounds, outbound);
        }
        if (length(outbounds) > 0) {
            push(levels, {
                id: as_string(level.id || ""),
                displayName: as_string(level.displayName || level.name || ""),
                order: int(level.order || 0),
                outbounds
            });
        }
    }

    return {
        id: as_string(group.id || ""),
        tag: as_string(group.tag || tag_name),
        section: as_string(group.section || ""),
        displayName: as_string(group.displayName || group.name || tag_name),
        health_url: as_string(group.health_url || "https://www.gstatic.com/generate_204"),
        active_check_interval: as_string(group.active_check_interval || "5s"),
        check_timeout: as_string(group.check_timeout || "2s"),
        recovery_check_interval: as_string(group.recovery_check_interval || "15s"),
        pick_fastest: bool_value(group.pick_fastest, false),
        switch_to_faster_same_priority: bool_value(group.switch_to_faster_same_priority, false),
        fastest_check_interval: as_string(group.fastest_check_interval || "3m"),
        payload_check: group.payload_check === true && as_string(group.probe_tag) != "" && int(group.probe_port || 0) > 0,
        probe_tag: as_string(group.probe_tag || ""),
        probe_port: int(group.probe_port || 0),
        levels
    };
}

function section_cache_files() {
    let result = [];
    for (let path in split(command_output_from_args([
        "find",
        SECTION_CACHE_DIR,
        "-mindepth",
        "1",
        "-maxdepth",
        "1",
        "-type",
        "f",
        "-name",
        "*.json"
    ]), "\n")) {
        path = as_string(path);
        if (path != "")
            push(result, path);
    }
    return result;
}

function priority_groups_from_cache() {
    let result = [];
    for (let path in section_cache_files()) {
        let cache = object_or_empty(read_json_file(path));
        for (let tag_name, group in object_or_empty(cache.priorityGroups)) {
            let normalized = normalize_group(group, tag_name);
            if (normalized.tag != "" && length(normalized.levels) > 0)
                push(result, normalized);
        }
    }
    return result;
}

// The answer and the exit status of a clash-api request, read through a
// pipe: no mktemp process and no temporary file on every probe, every 5 s
// per group (audit 2026-10-04, optimization 5).
function module_capture(args) {
    let command = command_from_args([ "ucode", "-L", LIB_DIR, DIAGNOSTICS_UC, "clash-api" ]);
    for (let arg in args)
        command += " " + shell_quote(arg);

    let pipe = fs.popen(command + " 2>&1", "r");
    if (pipe == null)
        return { status: 1, output: "" };
    let output = as_string(pipe.read("all") || "");
    let status = pipe.close();
    return { status: type(status) == "int" ? status : 1, output };
}

function parse_delay_output(output) {
    let value = null;
    try {
        value = json(output);
    }
    catch (e) {
        return null;
    }

    if (type(value) != "object")
        return null;

    let delay = value.delay;
    if (delay == null || as_string(delay) == "")
        return null;

    delay = int(delay, 10);
    return delay >= 0 ? delay : null;
}

function clash_probe(tag_name, group) {
    let timeout = as_string(duration_to_milliseconds(group.check_timeout, 2000));
    let result = module_capture([ "get_proxy_latency", tag_name, timeout, group.health_url ]);
    if (result.status != 0)
        return { alive: false, delay: 0 };

    let delay = parse_delay_output(result.output);
    if (delay == null)
        return { alive: false, delay: 0 };

    return { alive: true, delay };
}

// Points the group's probe selector at the node and downloads the payload
// through it; true when all of it arrived.
function payload_transfer(group, tag_name) {
    if (module_capture([ "set_group_proxy", group.probe_tag, tag_name, "auto" ]).status != 0)
        return false;
    let output = command_output_from_args([ "curl", "-sS", "-o", "/dev/null",
        "-w", "%{http_code} %{size_download}",
        "--max-time", as_string(PAYLOAD_MAX_TIME),
        "-x", "http://" + SERVICE_ADDRESS + ":" + as_string(group.probe_port),
        PAYLOAD_URL ]);
    let fields = split(trim(output), " ");
    return length(fields) == 2 && match(fields[0], /^2[0-9][0-9]$/) != null &&
        int(fields[1]) >= PAYLOAD_BYTES;
}

function new_payload_state() {
    return { quarantine: {}, verified: {}, observations: {} };
}

// The probe of a group that may check payload: the delay check first, then,
// for a group with payload_check, the download, unless the node passed it
// within PAYLOAD_RECHECK_SECONDS. A failed download quarantines the node.
function checked_probe(payload, group, tag_name, delay_probe, transfer, now) {
    payload.observations = payload.observations || {};
    if (group.payload_check && int(payload.quarantine[tag_name] || 0) > now)
        return { alive: false, delay: 0 };
    let result = delay_probe(tag_name, group);
    payload.observations[tag_name] = {
        delay: result.delay, handshake: result.alive, checked_uptime: now,
        payload: group.payload_check ? "pending" : "disabled", reason: result.alive ? "" : "handshake_failed"
    };
    if (!result.alive || !group.payload_check) return result;
    if (payload.verified[tag_name] != null && now - int(payload.verified[tag_name]) < PAYLOAD_RECHECK_SECONDS) {
        payload.observations[tag_name].payload = "passed";
        payload.observations[tag_name].payload_checked_uptime = payload.verified[tag_name];
        return result;
    }
    if (!transfer(group, tag_name)) {
        payload.observations[tag_name].payload = "failed";
        payload.observations[tag_name].reason = "payload_failed";
        delete payload.verified[tag_name];
        payload.quarantine[tag_name] = now + PAYLOAD_QUARANTINE_SECONDS;
        log_message("node " + tag_name + " of " + group.tag + " answers but did not pass the payload download; " +
            "skipping it for " + PAYLOAD_QUARANTINE_SECONDS + " s", "warn");
        return { alive: false, delay: 0 };
    }
    payload.verified[tag_name] = now;
    payload.observations[tag_name].payload = "passed";
    payload.observations[tag_name].payload_checked_uptime = now;
    return result;
}

function fixture_probe(latencies, tag_name) {
    let value = object_or_empty(latencies)[tag_name];
    if (value == null || as_string(value) == "" || int(value, 10) < 0)
        return { alive: false, delay: 0 };
    return { alive: true, delay: int(value, 10) };
}

function choose_from_level(group, level_index, probe, skip_tag) {
    let level = object_or_empty(array_or_empty(group.levels)[level_index]);
    let best = null;

    for (let tag_name in array_or_empty(level.outbounds)) {
        if (as_string(skip_tag) != "" && tag_name == skip_tag)
            continue;
        let result = probe(tag_name, group);
        if (!result.alive)
            continue;

        if (!group.pick_fastest)
            return {
                tag: tag_name,
                levelIndex: level_index,
                delay: result.delay
            };

        if (best == null || result.delay < best.delay)
            best = {
                tag: tag_name,
                levelIndex: level_index,
                delay: result.delay
            };
    }

    return best;
}

function choose_from_level_range(group, start_index, end_index, probe, skip_tag) {
    let levels = array_or_empty(group.levels);
    if (length(levels) == 0)
        return null;

    start_index = int(start_index || 0);
    end_index = int(end_index || 0);
    if (start_index < 0)
        start_index = 0;
    if (end_index >= length(levels))
        end_index = length(levels) - 1;
    if (start_index > end_index)
        return null;

    for (let i = start_index; i <= end_index; i++) {
        let selected = choose_from_level(group, i, probe, skip_tag);
        if (selected != null)
            return selected;
    }
    return null;
}

function choose_fastest_same_level(group, level_index, active_tag, probe) {
    let level = object_or_empty(array_or_empty(group.levels)[level_index]);
    let active = null;
    let best = null;

    for (let tag_name in array_or_empty(level.outbounds)) {
        let result = probe(tag_name, group);
        if (tag_name == active_tag)
            active = result;
        if (!result.alive)
            continue;
        if (best == null || result.delay < best.delay) {
            best = {
                tag: tag_name,
                levelIndex: level_index,
                delay: result.delay
            };
        }
    }

    if (best == null || best.tag == active_tag)
        return null;
    if (active != null && active.alive && best.delay < active.delay)
        return best;
    return null;
}

function set_group_proxy(group, tag_name) {
    let result = module_capture([ "set_group_proxy", group.tag, tag_name, "auto" ]);
    return result.status == 0;
}

function switch_group(state, group, selected) {
    if (selected == null || selected.tag == "")
        return false;

    if (state.active == selected.tag) {
        state.levelIndex = selected.levelIndex;
        state.activeDelay = selected.delay;
        return true;
    }

    if (!set_group_proxy(group, selected.tag)) {
        log_message("failed to switch " + group.tag + " to " + selected.tag, "warn");
        return false;
    }

    state.failures = 0;
    state.delay_samples = [];
    state.active = selected.tag;
    state.levelIndex = selected.levelIndex;
    state.activeDelay = selected.delay;
    return true;
}

function init_group_state(group) {
    return {
        failures: 0,
        delay_samples: [],
        payload: new_payload_state(),
        active: "",
        levelIndex: -1,
        activeDelay: 0,
        nextActiveCheck: now_seconds(),
        nextRecoveryCheck: now_seconds() + duration_to_seconds(group.recovery_check_interval, 15),
        nextFastestCheck: now_seconds() + duration_to_seconds(group.fastest_check_interval, 180)
    };
}

function tick_group(state, group) {
    let now = now_seconds();
    let probe = function(tag_name, probe_group) {
        return checked_probe(state.payload, probe_group, tag_name, clash_probe, payload_transfer, now);
    };

    if (state.active == "" && now >= state.nextActiveCheck) {
        let selected = choose_from_level_range(group, 0, length(group.levels) - 1, probe);
        switch_group(state, group, selected);
        state.nextActiveCheck = now + duration_to_seconds(group.active_check_interval, 5);
        return;
    }

    if (state.active != "" && now >= state.nextActiveCheck) {
        let active = probe(state.active, group);
        if (active.alive) {
            state.failures = 0;
            push(state.delay_samples, active.delay);
            if (length(state.delay_samples) > 3) shift(state.delay_samples);
            let ordered = sort([ ...state.delay_samples ], (a, b) => a - b);
            state.activeDelay = ordered[int(length(ordered) / 2)];
        }
        else if (++state.failures >= 2) {
            let selected = choose_from_level_range(
                group,
                state.levelIndex,
                length(group.levels) - 1,
                probe,
                state.active
            );
            if (switch_group(state, group, selected)) {
                state.nextRecoveryCheck = now + duration_to_seconds(group.recovery_check_interval, 15);
                state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
            }
            else {
                state.active = "";
                state.levelIndex = -1;
            }
        }
        state.nextActiveCheck = now + duration_to_seconds(group.active_check_interval, 5);
    }

    if (state.active != "" && state.levelIndex > 0 && now >= state.nextRecoveryCheck) {
        let selected = choose_from_level_range(group, 0, state.levelIndex - 1, probe);
        if (switch_group(state, group, selected))
            state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
        state.nextRecoveryCheck = now + duration_to_seconds(group.recovery_check_interval, 15);
    }

    if (state.active != "" && state.failures == 0 && group.switch_to_faster_same_priority && now >= state.nextFastestCheck) {
        let selected = choose_fastest_same_level(group, state.levelIndex, state.active, probe);
        if (selected != null && state.activeDelay - selected.delay >= 50 && selected.delay <= state.activeDelay * 0.8)
            switch_group(state, group, selected);
        state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
    }
}

function worker() {
    let groups = priority_groups_from_cache();
    if (length(groups) == 0)
        return 0;

    let states = {};
    for (let group in groups)
        states[group.tag] = init_group_state(group);

    while (true) {
        for (let group in groups)
            tick_group(states[group.tag], group);
        let report = {};
        for (let tag, state in states)
            report[tag] = { active: state.active, failures: state.failures, nodes: state.payload.observations };
        let temporary = HEALTH_FILE + ".tmp";
        if (fs.writefile(temporary, sprintf("%J", { uptime: now_seconds(), groups: report })) != null) {
            fs.chmod(temporary, 0600);
            fs.rename(temporary, HEALTH_FILE);
        }
        sleep(1000);
    }
}

function stop_runtime() {
    remove_file(HEALTH_FILE);
    process_identity.signal(PRIORITY_PID_FILE, "ucode", [ "ucode", "-L", LIB_DIR, PRIORITY_UC, "worker" ], true, "TERM");
    remove_file(PRIORITY_PID_FILE);
    return 0;
}

function start_runtime() {
    let groups = priority_groups_from_cache();
    stop_runtime();
    if (length(groups) == 0)
        return 0;

    if (!ensure_dir(RUNTIME_STATE_DIR))
        return 1;

    let command = command_from_args([ "ucode", "-L", LIB_DIR, PRIORITY_UC, "worker" ]) +
        " >/dev/null 2>&1 1000>&- & echo $!";
    let pid = trim(command_output_from_args([ "sh", "-c", command ]));
    return process_identity.record(PRIORITY_PID_FILE, pid) ? 0 : 1;
}

function select_fixture(group_path, latency_path, start_index, end_index, skip_tag) {
    let group = normalize_group(read_json_file(group_path), "fixture");
    let latencies = object_or_empty(read_json_file(latency_path));
    let selected = choose_from_level_range(group, start_index, end_index, function(tag_name, _group) {
        return fixture_probe(latencies, tag_name);
    }, skip_tag);
    write_json(selected == null ? {} : selected);
}

function select_faster_fixture(group_path, latency_path, level_index, active_tag) {
    let group = normalize_group(read_json_file(group_path), "fixture");
    let latencies = object_or_empty(read_json_file(latency_path));
    let selected = choose_fastest_same_level(group, int(level_index || 0), as_string(active_tag), function(tag_name, _group) {
        return fixture_probe(latencies, tag_name);
    });
    write_json(selected == null ? {} : selected);
}

// Runs the probes of a scenario ({ group, latencies, payload: { tag: bool },
// rounds: [ { now, level_start } ] }) and prints each round's selection with
// the downloads made and the quarantine.
function payload_fixture(path) {
    let scenario = object_or_empty(read_json_file(path));
    let group = normalize_group(scenario.group, "fixture");
    let latencies = object_or_empty(scenario.latencies);
    let outcomes = object_or_empty(scenario.payload);
    let payload = new_payload_state();
    let rounds = [];
    for (let round in array_or_empty(scenario.rounds)) {
        let downloads = [];
        let now = int(round.now || 0);
        let selected = choose_from_level_range(group, int(round.level_start || 0), length(group.levels) - 1,
            function(tag_name, probe_group) {
                return checked_probe(payload, probe_group, tag_name, function(tag) {
                    return fixture_probe(latencies, tag);
                }, function(_group, tag) {
                    push(downloads, tag);
                    return outcomes[tag] === true;
                }, now);
            }, as_string(round.skip || ""));
        push(rounds, { selected: selected == null ? "" : selected.tag, downloads,
            quarantined: sort(filter(keys(payload.quarantine), (tag) => payload.quarantine[tag] > now)) });
    }
    write_json(rounds);
}

let mode = ARGV[0] || "";

if (mode == "health-status") {
    let value = read_json_file(HEALTH_FILE);
    if (value == null || now_seconds() - int(value.uptime || 0) > 30)
        write_json({ available: false });
    else write_json({ available: true, uptime: now_seconds(), groups: value.groups });
}
else if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
else if (mode == "select-fixture")
    select_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "payload-fixture")
    payload_fixture(ARGV[1]);
else if (mode == "payload-transfer-fixture")
    exit(payload_transfer(normalize_group(read_json_file(ARGV[1]), "fixture"), ARGV[2]) ? 0 : 1);
else if (mode == "select-faster-fixture")
    select_faster_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else {
    warn("Usage: singbox/priority.uc <start-runtime|stop-runtime|worker|select-fixture|select-faster-fixture>\n");
    exit(1);
}
