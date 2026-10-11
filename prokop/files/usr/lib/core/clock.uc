#!/usr/bin/env ucode

// Is the router's clock trustworthy? Read-only.
//
// status() -> { state, source, stratum, observed_at, reason }
//   state        "synced" | "unsynced" | "unknown"
//   source       where the answer comes from:
//                  "ntp_hotplug"  the marker an NTP event wrote this boot
//                  "release_date" the clock is earlier than this release
//                  "ntpd"         busybox ntpd runs with its event hook and
//                                 has not reported a synchronized stratum yet
//                  "none"         nothing can tell (no NTP client observed)
//   stratum      the NTP stratum of the marker (0..15), else null
//   observed_at  when the marker was written (epoch seconds), else null
//   reason       a stable code; the pages translate it:
//                  ntp_synced              synced by NTP this boot
//                  clock_before_release    the clock is earlier than the
//                                          release date of this package
//                  ntp_not_confirmed       ntpd runs, no sync reported yet
//                  ntp_disabled            the NTP client is disabled in
//                                          the system settings
//                  ntp_not_running         no NTP client runs
//                  ntp_client_unobserved   an NTP client runs that reports
//                                          nothing Prokop can read
//
// The marker: /etc/hotplug.d/ntp/60-prokop-time (installed with the
// package) writes /var/run/prokop/time-synced when busybox ntpd (OpenWrt
// sysntpd, ntpd -S /usr/sbin/ntpd-hotplug) reports a stratum below 16 on
// a "stratum", "periodic" or "step" event. /var/run is tmpfs: the marker is
// gone after a reboot, when a router without an RTC starts from an old
// time. An "unsync" event keeps it: the clock was right this boot and
// drifts by seconds, not by the days a missing synchronization costs.
//
// Callers: autotune (no decision while "unsynced", certificate time
// errors are a clock problem, never DPI evidence) and the diagnostics.
let fs = require("fs");

const MARKER = getenv("PROKOP_CLOCK_MARKER") || "/var/run/prokop/time-synced";
const PROC = getenv("PROKOP_CLOCK_PROC") || "/proc";
const SYSTEM_CONFIG = getenv("PROKOP_CLOCK_SYSTEM_CONFIG") || "/etc/config/system";
// 2026-10-01 00:00:00 UTC: no correct clock can read earlier than the
// release date of this package (raise it with each release).
const RELEASE_FLOOR = 1790812800;

function as_string(v) { return v == null ? "" : "" + v; }

function now() {
    let fake = getenv("PROKOP_CLOCK_NOW");
    return fake != null && match(fake, /^[0-9]+$/) != null ? int(fake) : time();
}

// The marker: "stratum=N\nat=EPOCH\naction=NAME\n". null when missing or
// malformed (a stratum of 16 is unsynchronized and never written).
function read_marker() {
    let text = fs.readfile(MARKER);
    if (text == null) return null;
    let values = {};
    for (let line in split(as_string(text), "\n")) {
        let m = match(trim(line), /^([a-z_]+)=([A-Za-z0-9_-]*)$/);
        if (m != null) values[m[1]] = m[2];
    }
    if (match(as_string(values.stratum), /^[0-9]{1,2}$/) == null || int(values.stratum) > 15) return null;
    if (match(as_string(values.at), /^[0-9]{1,12}$/) == null) return null;
    return { stratum: int(values.stratum), at: int(values.at) };
}

function basename(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash < 0 ? path : substr(path, slash + 1);
}

// NTP clients that run: [{ name, hooked }]. hooked: busybox ntpd with an
// event script (-S), which is what writes the marker.
function ntp_clients() {
    let result = [];
    for (let pid in fs.lsdir(PROC) || []) {
        if (match(pid, /^[1-9][0-9]*$/) == null) continue;
        let argv = split(as_string(fs.readfile(PROC + "/" + pid + "/cmdline")), "\0");
        let name = basename(argv[0]);
        if (index([ "ntpd", "chronyd", "openntpd", "ntpclient", "sntpd" ], name) < 0) continue;
        let hooked = false;
        for (let i = 1; i < length(argv); i++)
            if (argv[i] == "-S" && as_string(argv[i + 1]) != "") hooked = true;
        push(result, { name, hooked: name == "ntpd" && hooked });
    }
    return result;
}

// OpenWrt's "config timeserver 'ntp'" with "option enabled '0'".
function ntp_disabled() {
    let text = fs.readfile(SYSTEM_CONFIG);
    if (text == null) return false;
    let inside = false;
    for (let line in split(as_string(text), "\n")) {
        line = trim(line);
        if (match(line, /^config[ \t]/) != null) inside = match(line, /^config[ \t]+timeserver[ \t]+'?ntp'?$/) != null;
        else if (inside && match(line, /^option[ \t]+enabled[ \t]+'?0'?$/) != null) return true;
    }
    return false;
}

function status() {
    let marker = read_marker();
    if (marker != null)
        return { state: "synced", source: "ntp_hotplug", stratum: marker.stratum, observed_at: marker.at, reason: "ntp_synced" };
    if (now() < RELEASE_FLOOR)
        return { state: "unsynced", source: "release_date", stratum: null, observed_at: null, reason: "clock_before_release" };
    let clients = ntp_clients();
    if (length(filter(clients, (c) => c.hooked)) > 0)
        return { state: "unsynced", source: "ntpd", stratum: null, observed_at: null, reason: "ntp_not_confirmed" };
    if (length(clients) > 0)
        return { state: "unknown", source: "none", stratum: null, observed_at: null, reason: "ntp_client_unobserved" };
    return { state: "unknown", source: "none", stratum: null, observed_at: null,
        reason: ntp_disabled() ? "ntp_disabled" : "ntp_not_running" };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return { status, RELEASE_FLOOR };

print(sprintf("%J\n", status()));
