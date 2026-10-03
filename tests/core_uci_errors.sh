#!/usr/bin/env bash
set -euo pipefail

# libuci reports a failed set, delete, rename, load or commit with null, not
# with false and not with an exception (ucode lib/uci.c err_return), and a
# commit fails when the overlay is full or read-only. core/uci.uc reported
# every such failure as success (`commit() != false`, `c.set(...); return
# true`), so the checks of its callers never fired (UC-024). Here each
# wrapper reports the failure, a delete of what is already absent stays a
# success, and the callers that save a configuration fail with it: the
# runtime migration of a package upgrade and a rule's URLTest settings.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

unset PROKOP_UCI_STATE_FILE PROKOP_UCI_LOG_FILE

# A stand-in for the libuci ucode module with the binding's return values:
# true on success, null on an error. The packages come from STUB_STATE
# (JSON); STUB_FAIL names the calls that fail ("set commit ..."); every call
# is recorded in STUB_LOG.
mkdir -p "$WORK/modules"
cat >"$WORK/modules/uci.uc" <<'UC'
let fs = require("fs");
let state = json(fs.readfile(getenv("STUB_STATE")) || "{}");
let failing = {};
for (let name in split(getenv("STUB_FAIL") || "", " "))
    if (name != "") failing[name] = true;
function record(line) {
    let f = fs.open(getenv("STUB_LOG"), "a");
    f.write(line + "\n");
    f.close();
}
function section(p, s) {
    let sections = state[p];
    return sections == null ? null : sections[s];
}
function cursor() {
    return {
        load: function(p) {
            record("load " + p);
            return failing.load || state[p] == null ? null : true;
        },
        get: function(p, s, o) {
            let sec = section(p, s);
            if (sec == null) return null;
            return o == null ? sec[".type"] : sec[o];
        },
        get_all: function(p, s) { return section(p, s); },
        foreach: function(p, t, cb) {
            for (let name in keys(state[p] || {}))
                if (t == null || state[p][name][".type"] == t)
                    cb(state[p][name]);
            return true;
        },
        set: function(p, s, o, v) {
            record("set " + p + "." + s + "." + o + "=" + v);
            if (failing.set || state[p] == null) return null;
            // The binding takes no empty list (uval_to_uci: UCI_ERR_INVAL).
            if (type(v) == "array" && length(v) == 0) return null;
            if (v == null) {
                state[p][s] = state[p][s] || { ".name": s };
                state[p][s][".type"] = o;
                return true;
            }
            if (state[p][s] == null) return null;
            state[p][s][o] = v;
            return true;
        },
        delete: function(p, s, o) {
            record("delete " + p + "." + s + (o == null ? "" : "." + o));
            let sec = section(p, s);
            if (failing.delete || sec == null || (o != null && sec[o] == null)) return null;
            if (o == null) delete state[p][s];
            else delete sec[o];
            return true;
        },
        add: function(p, t) {
            record("add " + p + " " + t);
            if (failing.add || state[p] == null) return null;
            let name = sprintf("cfg%06x", length(keys(state[p])) + 1);
            state[p][name] = { ".name": name, ".type": t, ".anonymous": true };
            return name;
        },
        rename: function(p, s, n) {
            record("rename " + p + "." + s + "=" + n);
            if (failing.rename || section(p, s) == null) return null;
            state[p][n] = state[p][s];
            state[p][n][".name"] = n;
            delete state[p][s];
            return true;
        },
        commit: function(p) {
            record("commit " + p);
            return failing.commit ? null : true;
        }
    };
}
return { cursor };
UC

cat >"$WORK/probe.uc" <<'UC'
let uci = require("core.uci");
let op = ARGV[0];
let result;
if (op == "get") result = uci.get(ARGV[1]);
else if (op == "exists") result = uci.exists(ARGV[1]);
else if (op == "set") result = uci.set(ARGV[1], ARGV[2]);
else if (op == "set_empty_list") result = [ uci.set(ARGV[1], []), uci.exists(ARGV[1]) ];
else if (op == "set_section") result = uci.set_section(ARGV[1], ARGV[2]);
else if (op == "add_list") result = uci.add_list(ARGV[1], ARGV[2]);
else if (op == "del_list") result = uci.del_list(ARGV[1], ARGV[2]);
else if (op == "delete") result = uci.delete(ARGV[1]);
else if (op == "rename") result = uci.rename(ARGV[1], ARGV[2]);
else if (op == "add") result = uci.add(ARGV[1], ARGV[2]);
else if (op == "commit") result = uci.commit(ARGV[1]);
print(sprintf("%J\n", result));
UC

cat >"$WORK/base.json" <<'JSON'
{ "prokop": {
    "settings": { ".name": "settings", ".type": "settings", "marker": "1", "server": [ "a", "b" ] },
    "main": { ".name": "main", ".type": "section", "enabled": "1" }
} }
JSON

# probe "<failing calls>" <op> <args...>: the wrapper's result as JSON.
probe() {
  local failing="$1"
  shift
  : >"$WORK/calls"
  STUB_STATE="$WORK/base.json" STUB_FAIL="$failing" STUB_LOG="$WORK/calls" \
    ucode -L "$WORK/modules" -L "$LIB" "$WORK/probe.uc" "$@"
}
expect() {
  local want="$1" got
  shift
  got="$(probe "$@")" || fail "probe $* failed"
  [ "$got" = "$want" ] || fail "core.uci $*: expected $want, got $got"
}

# ---- 1. core/uci.uc reports the binding's failures ---------------------------
expect true "" commit prokop
expect false commit commit prokop
ok "a commit the binding refuses (read-only or full overlay) is a failure"

expect true "" set prokop.settings.marker 2
expect false set set prokop.settings.marker 2
expect false "" set prokop.missing.marker 2
expect false set set_section prokop.extra settings
expect false set add_list prokop.settings.server c
expect false set del_list prokop.settings.server a
expect false rename rename prokop.main renamed
ok "set, set_section, add_list, del_list and rename report a refused change"

expect true "" delete prokop.settings.marker
expect false delete delete prokop.settings.marker
expect true delete delete prokop.settings.absent
expect true delete delete prokop.absent
grep -q '^delete prokop.settings.absent' "$WORK/calls" &&
  fail "a delete of an absent option still went to the binding"
ok "a refused delete is a failure, a delete of what is already absent a success"

# libuci stores no empty list and the binding refuses one: an empty list is
# no option at all.
expect '[ true, false ]' "" set_empty_list prokop.settings.server
expect '[ true, false ]' "" set_empty_list prokop.settings.absent
expect '[ false, true ]' delete set_empty_list prokop.settings.server
ok "an empty list removes the option"

# A package libuci cannot load (missing or unparsable file).
expect false "" set network.lan.proto static
expect '""' "" get network.lan.proto
expect false "" exists network.lan
ok "a package that cannot be loaded is neither read nor written"

# ---- 2. the runtime migration of a package upgrade ---------------------------
export PROKOP_CONFIG_NAME=prokop
export PROKOP_RUNTIME_STATE_DIR="$WORK/run"
export TMP_SUBSCRIPTION_FOLDER="$WORK/subscriptions"
export PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/subscription-cache"
export PROKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK/internal-config-change"
cat >"$WORK/migrate.json" <<'JSON'
{ "prokop": {
    "settings": { ".name": "settings", ".type": "settings", "config_version": "1.0.1",
                  "component_update_check_enabled": "0" },
    "main": { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
              "proxy_config_type": "subscription", "subscription_url": "https://sub.example/list" }
} }
JSON
# migrate "<failing calls>" <migrate|migrate-podkop> [state]: the exit status in
# MIGRATE_STATUS. The configuration needs both: the version migrations of an
# upgrade, and the conversion of a Podkop subscription rule, which also drops
# the rule's subscription cache.
migrate() {
  mkdir -p "$TMP_SUBSCRIPTION_FOLDER"
  printf '{}\n' >"$TMP_SUBSCRIPTION_FOLDER/main.json"
  : >"$WORK/calls"
  MIGRATE_STATUS=0
  STUB_STATE="${3:-$WORK/migrate.json}" STUB_FAIL="$1" STUB_LOG="$WORK/calls" \
    ucode -L "$WORK/modules" -L "$LIB" "$LIB/config/migration.uc" "$2" >/dev/null 2>&1 || MIGRATE_STATUS=$?
}

# Controls; the first also brings the runtime cache format up to date, so
# that no later run clears the caches for that.
migrate "" migrate
[ "$MIGRATE_STATUS" = 0 ] || fail "the migration failed without a failing call: $(cat "$WORK/calls")"
grep -Fxq 'commit prokop' "$WORK/calls" || fail "the migration did not commit"
migrate "" migrate-podkop
[ "$MIGRATE_STATUS" = 0 ] || fail "the Podkop migration failed without a failing call: $(cat "$WORK/calls")"
[ ! -e "$TMP_SUBSCRIPTION_FOLDER/main.json" ] || fail "the Podkop migration kept the cache of the converted subscription"

migrate commit migrate
[ "$MIGRATE_STATUS" != 0 ] || fail "a migration whose commit failed reported success"
migrate commit migrate-podkop
[ "$MIGRATE_STATUS" != 0 ] || fail "a Podkop migration whose commit failed reported success"
[ -e "$TMP_SUBSCRIPTION_FOLDER/main.json" ] ||
  fail "a migration whose commit failed removed the caches of the configuration it did not save"
ok "a migration whose commit fails fails and keeps the caches"

migrate set migrate
[ "$MIGRATE_STATUS" != 0 ] || fail "a migration whose changes were refused reported success"
grep -q '^commit ' "$WORK/calls" && fail "a migration committed a configuration with refused changes"
ok "a migration with a refused change commits nothing and fails"

# A Podkop configuration with empty DNS server options: the migration turns
# them into lists, and an empty list is no option (the binding refuses to
# set one).
sed 's/"component_update_check_enabled": "0"/"component_update_check_enabled": "0", "dns_server": "", "bootstrap_dns_server": ""/' \
  "$WORK/migrate.json" >"$WORK/migrate-empty-dns.json"
grep -q '"dns_server": ""' "$WORK/migrate-empty-dns.json" || fail "the empty DNS server fixture was not written"
migrate "" migrate-podkop "$WORK/migrate-empty-dns.json"
[ "$MIGRATE_STATUS" = 0 ] || fail "a migration of empty DNS server options failed: $(cat "$WORK/calls")"
grep -Fxq 'delete prokop.settings.dns_server' "$WORK/calls" || fail "the empty DNS server option was not removed: $(cat "$WORK/calls")"
grep -Fxq 'commit prokop' "$WORK/calls" || fail "the migration of empty DNS server options was not committed"
ok "a migration that empties a list removes the option"

# ---- 3. a rule's URLTest settings ---------------------------------------------
cat >"$WORK/urltest.json" <<'JSON'
{ "prokop": { "settings": { ".name": "settings", ".type": "settings" },
              "main": { ".name": "main", ".type": "section", "enabled": "1" } } }
JSON
urltest_save() {
  : >"$WORK/calls"
  STUB_STATE="$WORK/urltest.json" STUB_FAIL="$1" STUB_LOG="$WORK/calls" \
    ucode -L "$WORK/modules" -L "$LIB" "$LIB/config/urltest_override.uc" save main main-urltest \
    https://check.example/generate_204 3m 50 30m 1 >/dev/null 2>&1
}
urltest_save "" || fail "saving the URLTest settings failed without a failing call: $(cat "$WORK/calls")"
grep -Fxq 'commit prokop' "$WORK/calls" || fail "the URLTest settings were not committed"
urltest_save commit && fail "URLTest settings whose commit failed were reported as saved"
ok "URLTest settings whose commit fails are reported as not saved"

# ---- 4. a user setting saved by a component action ---------------------------
# TorrServer Direct off, through the real components/action.uc: its saved
# setting must be committed before the service is stopped, and a refused
# commit fails the action with the service left as it was.
mkdir -p "$WORK/bin" "$WORK/action-run"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
cat >"$WORK/bin/torrserver-direct" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK/torrserver.calls"
SH
chmod +x "$WORK/bin/logger" "$WORK/bin/torrserver-direct"
cat >"$WORK/torrserver.json" <<'JSON'
{ "prokop": { "settings": { ".name": "settings", ".type": "settings", "torrserver_direct_enabled": "1" } } }
JSON
torrserver_direct_off() {
  : >"$WORK/calls"
  : >"$WORK/torrserver.calls"
  PATH="$WORK/bin:$PATH" STUB_STATE="$WORK/torrserver.json" STUB_FAIL="$1" STUB_LOG="$WORK/calls" \
    PROKOP_LIB="$LIB" PROKOP_RUNTIME_STATE_DIR="$WORK/action-run" UPDATES_LOCK_DIR="$WORK/action-run/component-action.lock" \
    PROKOP_BIN="$WORK/no-prokop" PROKOP_SERVICE_INIT="$WORK/no-init" PROKOP_OPKG_RECOVERY_DIR="$WORK/recovery" \
    PROKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK/managed-upgrade" PROKOP_TORRSERVER_DIRECT_INIT="$WORK/bin/torrserver-direct" \
    ucode -L "$WORK/modules" -L "$LIB" "$LIB/components/action.uc" component-action torrserver_direct disable \
    >"$WORK/action.out" 2>/dev/null || true
}
torrserver_direct_off ""
grep -q '"success": *true' "$WORK/action.out" || fail "TorrServer Direct could not be turned off: $(cat "$WORK/action.out")"
grep -Fxq 'commit prokop' "$WORK/calls" || fail "the TorrServer Direct setting was not committed"
grep -Fxq 'stop' "$WORK/torrserver.calls" || fail "TorrServer Direct was not stopped"
for failing in set commit; do
  torrserver_direct_off "$failing"
  grep -q '"success": *false' "$WORK/action.out" ||
    fail "TorrServer Direct off was reported as done although its setting was not saved ($failing): $(cat "$WORK/action.out")"
  grep -q 'Failed to save TorrServer Direct settings' "$WORK/action.out" ||
    fail "the refused TorrServer Direct setting ($failing) was not reported: $(cat "$WORK/action.out")"
  [ ! -s "$WORK/torrserver.calls" ] || fail "TorrServer Direct was stopped although its setting was not saved ($failing)"
done
ok "a user setting that cannot be saved fails its action"

printf 'core UCI error checks passed\n'
