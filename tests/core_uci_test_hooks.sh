#!/usr/bin/env bash
set -euo pipefail

# UC-155: core/uci.uc can switch every get/set/commit to a flat fixture file
# for tests. Only the Prokop-namespaced PROKOP_UCI_STATE_FILE and
# PROKOP_UCI_LOG_FILE may do that; a generic UCI_STATE/UCI_LOG inherited from
# a shell, procd or another tool must leave production UCI access alone. The
# remaining hooks cannot reach the read-only CLI: /usr/libexec/prokop-ro runs
# it with env -i (readonly_hostile_env.sh sets them as hostile input).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

# A stand-in for the libuci ucode module: the production path, recorded.
mkdir -p "$WORK/modules"
cat >"$WORK/modules/uci.uc" <<'UC'
let record = (line) => {
    let f = require("fs").open(getenv("STUB_CURSOR_LOG"), "a");
    f.write(line + "\n");
    f.close();
};
function cursor() {
    return {
        load: (p) => true,
        get: (p, s, o) => (p == "prokop" && s == "settings" && o == "marker") ? "from-cursor" : null,
        set: (p, s, o, v) => { record("set " + p + "." + s + "." + o + "=" + v); return true; },
        commit: (p) => { record("commit " + p); return true; }
    };
}
return { cursor };
UC
cat >"$WORK/probe.uc" <<'UC'
let uci = require("core.uci");
print(sprintf("%J\n", {
    available: uci.available(),
    marker: uci.get("prokop.settings.marker"),
    set: uci.set("prokop.settings.written", "1"),
    commit: uci.commit("prokop")
}));
UC

# probe <VAR=value...>: core.uci in an environment with only these hooks.
probe() {
  printf 'prokop.settings=settings\nprokop.settings.marker=from-fixture\n' >"$WORK/state"
  : >"$WORK/log"
  : >"$WORK/cursor.log"
  env -u PROKOP_UCI_STATE_FILE -u PROKOP_UCI_LOG_FILE -u UCI_STATE -u UCI_LOG \
    STUB_CURSOR_LOG="$WORK/cursor.log" "$@" \
    ucode -L "$WORK/modules" -L "$LIB" "$WORK/probe.uc" >"$WORK/out.json" ||
    fail "core.uci probe failed: $*"
}
field() { node -e 'console.log(JSON.stringify(require(process.argv[1])[process.argv[2]]))' "$WORK/out.json" "$1"; }

# ---- generic names are no hooks ------------------------------------------------
probe UCI_STATE="$WORK/state" UCI_LOG="$WORK/log"
[ "$(field marker)" = '"from-cursor"' ] || fail "UCI_STATE switched core.uci to a fixture file: $(cat "$WORK/out.json")"
if grep -q written "$WORK/state"; then fail "UCI_STATE file was written: $(cat "$WORK/state")"; fi
[ ! -s "$WORK/log" ] || fail "UCI_LOG file was written: $(cat "$WORK/log")"
[ "$(cat "$WORK/cursor.log")" = "$(printf 'set prokop.settings.written=1\ncommit prokop')" ] ||
  fail "writes must go through the UCI cursor: $(cat "$WORK/cursor.log")"
ok "a generic UCI_STATE/UCI_LOG leaves production UCI access alone"

# ---- the Prokop-namespaced hooks still work --------------------------------------
probe PROKOP_UCI_STATE_FILE="$WORK/state" PROKOP_UCI_LOG_FILE="$WORK/log"
[ "$(field marker)" = '"from-fixture"' ] || fail "PROKOP_UCI_STATE_FILE fixture not read: $(cat "$WORK/out.json")"
[ "$(field available)" = true ] || fail "the fixture must count as available"
grep -Fxq 'prokop.settings.written=1' "$WORK/state" || fail "fixture write missing: $(cat "$WORK/state")"
[ "$(cat "$WORK/log")" = 'commit prokop' ] || fail "PROKOP_UCI_LOG_FILE commit log: $(cat "$WORK/log")"
[ ! -s "$WORK/cursor.log" ] || fail "the fixture must not reach the UCI cursor: $(cat "$WORK/cursor.log")"
ok "PROKOP_UCI_STATE_FILE and PROKOP_UCI_LOG_FILE keep the fixture mode"

# ---- no production code reads a generic UCI_* variable ---------------------------
# Production: the router tree and the LuCI app's root (rpcd ACLs, uci-defaults).
PROD=("$ROOT_DIR/prokop/files" "$ROOT_DIR/luci-app-prokop/root")
# getenv() with a literal name, in either quote style.
names="$(grep -rIhoE "getenv\\([\"'][^\"']*[\"']\\)" "${PROD[@]}" |
  sed -E "s/getenv\\([\"']([^\"']*)[\"']\\)/\\1/" | LC_ALL=C sort -u)"
[ -n "$names" ] || fail "no getenv() calls found: the guard lost its anchor"
generic="$(printf '%s\n' "$names" | grep -E '^UCI_' || true)"
[ -z "$generic" ] || fail "production code reads generic UCI_* variables: $generic"
# The generic names in any other form: a helper's argument (env("UCI_STATE")),
# shell $UCI_STATE or ${UCI_LOG}, a name kept in a variable. Whole words only,
# so PROKOP_UCI_STATE_FILE and the UCI_STATE_FILE constant do not count.
hits="$(grep -rInwE 'UCI_(STATE|LOG)' "${PROD[@]}" || true)"
[ -z "$hits" ] || fail "production code names the generic UCI_STATE/UCI_LOG: $hits"
# Every getenv() in core/uci.uc names one of its two hooks literally.
hooks="$(grep -oE 'getenv\([^)]*\)' "$LIB/core/uci.uc" | tr "'" '"' | LC_ALL=C sort -u | tr '\n' ' ')"
[ "$hooks" = 'getenv("PROKOP_UCI_LOG_FILE") getenv("PROKOP_UCI_STATE_FILE") ' ] ||
  fail "core/uci.uc reads other variables: $hooks"
ok "core/uci.uc reads only PROKOP_UCI_* hooks, and no production code names UCI_STATE/UCI_LOG"
