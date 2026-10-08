#!/usr/bin/env bash
set -euo pipefail

# components/catalog.uc is the one list of component actions (UC-119): the
# UI's background start (components/updates.uc component_action_async)
# refuses any other before it starts a job, and components/action.uc runs
# only what it lists. This test ties the three together:
#   - every pair the dispatch of action.uc component_action handles is in the
#     catalog, and every catalog pair has a branch there;
#   - the UI start accepts every catalog pair (it gets as far as the lock)
#     and refuses a pair outside it as invalid input, without a job.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
ACTION_UC="$LIB/components/action.uc"
WORK="$(mktemp -d)"
LIVE=""
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
cleanup() {
  if [ -n "$LIVE" ]; then
    owned_kill KILL "$LIVE" || true
    wait "$LIVE" 2>/dev/null || true
  fi
  [ -n "${KEEP_WORK:-}" ] || rm -rf "${WORK:?}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v ucode >/dev/null || fail "ucode is required"
command -v node >/dev/null || fail "node is required"

ucode -L "$LIB" -e 'print(sprintf("%J", require("components.catalog").ACTIONS))' >"${WORK:?}/catalog.json" ||
  fail "components/catalog.uc does not load"

# --- The dispatch of action.uc and the catalog name the same pairs ------------
node - "$ACTION_UC" "${WORK:?}/catalog.json" <<'NODE'
const fs = require("fs");
const [actionUc, catalogFile] = process.argv.slice(2);
const source = fs.readFileSync(actionUc, "utf8");
const start = source.indexOf("\nfunction component_action(component, action, version) {");
if (start < 0) { console.error("FAIL: component_action is missing from action.uc"); process.exit(1); }
const end = source.indexOf("\n}\n", start);
const body = source.slice(start, end);
const dispatched = new Set();
// Each branch condition: component == "x" && (action == "a" || ...).
const condition = /(?:^|\n)\s*(?:else\s+)?if\s*\(component == "([a-z0-9_]+)" && \(?((?:[^\n]|\n(?!\s*(?:else|if|\/\/)))*?)\)?\)\s*\n/g;
for (let m; (m = condition.exec(body)); ) {
  for (const a of m[2].matchAll(/action == "([a-z0-9_]+)"/g)) dispatched.add(`${m[1]}/${a[1]}`);
}
if (dispatched.size < 10) {
  console.error(`FAIL: read only ${dispatched.size} dispatched pairs from component_action; the parser no longer matches it`);
  process.exit(1);
}
const catalog = JSON.parse(fs.readFileSync(catalogFile, "utf8"));
const listed = new Set();
for (const [component, actions] of Object.entries(catalog))
  for (const action of actions) listed.add(`${component}/${action}`);
const missing = [...dispatched].filter((pair) => !listed.has(pair));
const orphan = [...listed].filter((pair) => !dispatched.has(pair));
if (missing.length) { console.error(`FAIL: dispatched but not in components/catalog.uc: ${missing.join(", ")}`); process.exit(1); }
if (orphan.length) { console.error(`FAIL: in components/catalog.uc without a branch in action.uc: ${orphan.join(", ")}`); process.exit(1); }
NODE
pairs="$(node -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); for (const [k, v] of Object.entries(c)) for (const a of v) console.log(k + " " + a);' "${WORK:?}/catalog.json")"

# --- The UI start accepts every catalog pair and nothing else -------------------
export PROKOP_LIB="$LIB"
export UPDATES_JOB_DIR="${WORK:?}/jobs"
export PROKOP_UI_COMPONENT_ACTION_DIR="${WORK:?}/jobs"
export UPDATES_LOCK_DIR="${WORK:?}/component-action.lock"
export PROKOP_RUNTIME_STATE_DIR="${WORK:?}/run"
mkdir -p "$UPDATES_JOB_DIR" "$PROKOP_RUNTIME_STATE_DIR"
sleep 600 &
LIVE=$!
ucode -L "$LIB" "$LIB/service/state.uc" acquire-runtime-dir-lock "$UPDATES_LOCK_DIR" "$LIVE" ||
  fail "fixture: could not take the component lock"

start() {
  set +e
  ucode -L "$LIB" "$LIB/components/updates.uc" component-action-async "$1" "$2" "${3:-}" >"${WORK:?}/out" 2>/dev/null </dev/null
  set -e
  node -e 'const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(v.reason ?? ""));' \
    "${WORK:?}/out"
}

while read -r component action; do
  # With the lock held, a supported action gets as far as the busy refusal.
  [ "$(start "$component" "$action" "$([ "$action" = install_version ] && printf v1.14.1-extended-2.7.2 || true)")" = busy ] ||
    fail "the UI start refused the catalog action $component $action: $(cat "${WORK:?}/out")"
done <<<"$pairs"
[ "$(start sing-box check_update)" = busy ] || fail "the UI start must accept the sing-box spelling: $(cat "${WORK:?}/out")"
for pair in "prokop remove" "zapret_manager check_update" "bogus install"; do
  # shellcheck disable=SC2086
  [ "$(start $pair)" = invalid_input ] || fail "the UI start must refuse $pair as invalid input: $(cat "${WORK:?}/out")"
done
[ -z "$(ls -A "$UPDATES_JOB_DIR")" ] || fail "a refused component action started a job"

printf 'component catalog checks passed\n'
