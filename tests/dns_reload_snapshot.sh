#!/usr/bin/env bash
set -euo pipefail

# The dnsmasq step of a reload and its rollback (UC-071): the snapshot
# records whether dnsmasq forwarded to sing-box before the step, a rollback
# runs the dns/apply.uc operation that brings that back (restore or
# configure, forced), a rollback that failed is kept for a retry and a
# completed reload discards it. Nothing copies /etc/config/dhcp: the probe
# defines no command runner, so a copy would fail it.
# tests/dnsmasq_reload_rollback.sh runs the whole reload.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

python3 - "$ROOT_DIR" "$WORK_DIR/probe.uc" <<'PY'
import pathlib
import re
import sys

source = (pathlib.Path(sys.argv[1]) / 'prokop/files/usr/lib/service/lifecycle.uc').read_text()
names = ('snapshot_dnsmasq_reload_config', 'restore_dnsmasq_reload_config',
         'discard_dnsmasq_reload_config')
functions = []
for name in names:
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    functions.append(match.group())

prefix = r'''
let dns_reload_rollback = "";
let forwarding = false;
let apply_ok = true;
let calls = [];
function check(ok, message) { if (!ok) { warn("FAIL: " + message + "\n"); exit(1); } }
function dns_apply_success(args) {
    push(calls, join(" ", args));
    return args[0] == "has-prokop-dns" ? forwarding : true;
}
function dns_apply_status(args) {
    push(calls, join(" ", args));
    return apply_ok ? 0 : 1;
}
'''
suffix = r'''
// dnsmasq did not forward to sing-box: the rollback takes the forwarding
// back. A second snapshot of the same reload keeps the first answer.
check(snapshot_dnsmasq_reload_config(), "snapshot failed");
forwarding = true;
check(snapshot_dnsmasq_reload_config(), "second snapshot failed");
check(restore_dnsmasq_reload_config(), "rollback failed");
check(join(",", calls) == "has-prokop-dns,restore force" && dns_reload_rollback == "",
    "the rollback did not restore dnsmasq: " + join(",", calls));

// dnsmasq forwarded to sing-box: the rollback sets the forwarding again. A
// rollback that failed is kept and retried.
calls = [];
check(snapshot_dnsmasq_reload_config(), "snapshot failed");
apply_ok = false;
check(!restore_dnsmasq_reload_config() && dns_reload_rollback == "configure",
    "a failed rollback was discarded");
apply_ok = true;
check(restore_dnsmasq_reload_config() && dns_reload_rollback == "", "the retry failed");
check(join(",", calls) == "has-prokop-dns,configure force,configure force",
    "the rollback did not configure dnsmasq again: " + join(",", calls));

// A completed reload discards it: no rollback.
check(snapshot_dnsmasq_reload_config(), "third snapshot failed");
discard_dnsmasq_reload_config();
calls = [];
check(restore_dnsmasq_reload_config() && length(calls) == 0, "a completed reload was rolled back");
print("dnsmasq reload snapshot checks passed\n");
'''
pathlib.Path(sys.argv[2]).write_text(prefix + '\n\n'.join(functions) + suffix)
PY

ucode "$WORK_DIR/probe.uc"
