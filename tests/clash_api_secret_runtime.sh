#!/usr/bin/env bash
set -euo pipefail

# D-1 (b), UC-007: the Clash API secret is mandatory and the validator refuses
# to start without one. The package postinst migration generates it, but a
# configuration that never went through the postinst (Prokop built into a
# firmware image, a keep-settings sysupgrade or a restored backup of an older
# config) must not fail closed: start and reload fill in an absent or blank
# secret before validation and never replace an existing one.
#
# The secret is the only change they commit. A libuci commit of the package
# would also commit whatever someone staged with `uci set` in /tmp/.uci/prokop
# (libuci merges that directory even through a cursor with its own save
# directory), so the secret is written through a private copy under its own
# package name, staged there in uci's delta format (never on a command line)
# and committed by the uci CLI; the result replaces the configuration file
# (core/uci.uc commit_option).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
LIFECYCLE="$PROKOP_LIB/service/lifecycle.uc"
WORK="$(mktemp -d)"
# A call the uci test shim refused fails the test, even one it tolerated.
cleanup() {
  local rc=$?
  uci_cli_report || [ "$rc" != 0 ] || rc=1
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# The secret is committed through the uci CLI.
# shellcheck source=tests/helpers/uci_cli/select.sh
source "$ROOT_DIR/tests/helpers/uci_cli/select.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

UCODE_BIN="$(command -v ucode)" || fail "ucode is required"
# The save directory `uci set` stages into on the router (/tmp/.uci); with the
# test shim it is also the directory the shim treats as the host's.
STAGED_DIR="$WORK/uci-save"
export PROKOP_TEST_UCI_SHIM_HOST_SAVEDIR="$STAGED_DIR"
mkdir -p "$STAGED_DIR" "$WORK/etc" "$WORK/bin"
# Every uci call is logged with its arguments.
cat >"$WORK/bin/uci" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK/uci.argv"
exec "$UCI_CLI" "\$@"
SH
chmod +x "$WORK/bin/uci"

extract() {
  awk -v name="$1" '
    $0 ~ "^function " name "\\(" { copy=1 }
    copy { print }
    copy && /^}/ { exit }
  ' "$LIFECYCLE"
}

{
  cat <<'UCODE'
let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
const CONFIG_NAME = "prokop";
let guard_marks = 0;
function log_message(message, level) { print(level, ": ", message, "\n"); }
function mark_internal_config_guard() { guard_marks++; }
// The lifecycle's libuci cursor (staged changes included): what it reads for
// the secret.
function config_get(path, fallback) { return getenv("CURSOR_SECRET") || fallback; }
UCODE
  for constant in CONFIG_FILE UCI_CLI; do
    grep -E "^const $constant = " "$LIFECYCLE" || fail "lifecycle.uc has no $constant"
  done
  for fn in as_string ensure_clash_api_secret; do
    extract "$fn" | grep -q . || fail "lifecycle.uc has no $fn()"
    extract "$fn"
  done
  cat <<'UCODE'
let ok = ensure_clash_api_secret();
print("result=", ok ? "ok" : "failed", " guard=", guard_marks, "\n");
UCODE
} >"$WORK/ensure.uc"

# run_ensure <name>: the configuration file is $WORK/etc/<name>, written
# through the uci CLI (core/uci.uc commit_option).
run_ensure() {
  local name="$1"
  : >"$WORK/uci.argv"
  PROKOP_CONFIG_FILE="$WORK/etc/$name" PROKOP_UCI_CLI="$WORK/bin/uci" \
    "$UCODE_BIN" -L "$PROKOP_LIB" "$WORK/ensure.uc" >"$WORK/$name.out" 2>&1 ||
    fail "ensure_clash_api_secret crashed for $name: $(cat "$WORK/$name.out")"
}

# config <name> [settings option line...]: the committed configuration.
config() {
  local name="$1"
  shift
  {
    printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption enable_yacd '0'\n"
    printf '%s\n' "$@"
    printf "\nconfig section 'main'\n\toption action 'connection'\n\tlist community_lists 'russia_inside'\n"
  } >"$WORK/etc/$name"
  chmod 0640 "$WORK/etc/$name"
}

secret_of() {
  local dir="$WORK/read-$1"
  rm -rf "$dir"
  mkdir -p "$dir/save"
  cp "$WORK/etc/$1" "$dir/prokop_read"
  "$UCI_CLI" -q -c "$dir" -t "$dir/save" get prokop_read.settings.yacd_secret_key || true
}

changed_options() {
  "$UCODE_BIN" -L "$PROKOP_LIB" "$PROKOP_LIB/config/snapshots.uc" fixture-diff "$1" "$2" |
    node -e 'let s="";process.stdin.on("data",(d)=>s+=d).on("end",()=>console.log(JSON.parse(s).map((c)=>c.section+"."+c.option).sort().join(" ")))'
}

# The shipped config of a firmware image: no secret at all. Only the secret
# is added; the file keeps its mode; neither the secret nor the live package
# appears on a uci command line.
config absent
cp "$WORK/etc/absent" "$WORK/absent.before"
run_ensure absent
grep -Fq 'result=ok guard=1' "$WORK/absent.out" || fail "a missing secret must be generated: $(cat "$WORK/absent.out")"
secret="$(secret_of absent)"
printf '%s' "$secret" | grep -Eq '^[0-9a-f]{64}$' || fail "the generated secret must be 256-bit hex, got '$secret'"
[ "$(changed_options "$WORK/absent.before" "$WORK/etc/absent")" = settings.yacd_secret_key ] ||
  fail "more than the secret was committed: $(changed_options "$WORK/absent.before" "$WORK/etc/absent")"
[ "$(stat -c %a "$WORK/etc/absent")" = 640 ] || fail "the configuration file lost its mode: $(stat -c %a "$WORK/etc/absent")"
grep -Fq "$secret" "$WORK/absent.out" && fail "the log must not quote the generated secret"
grep -Fq "$secret" "$WORK/uci.argv" && fail "the secret must never be on a uci command line"
grep -Eq '(^| )prokop(\.| |$)' "$WORK/uci.argv" && fail "uci touched the live package: $(cat "$WORK/uci.argv")"
grep -Fq -- "-c $WORK/etc " "$WORK/uci.argv" && fail "uci ran on the live configuration directory"
[ -z "$(find "$WORK/etc" -name '.*')" ] || fail "a temporary file was left next to the configuration"

# A blank secret is no secret.
config blank "	option yacd_secret_key '   '"
run_ensure blank
secret_of blank | grep -Eq '^[0-9a-f]{64}$' || fail "a blank secret must be replaced"

# An existing user secret is never touched and nothing is written.
config user "	option yacd_secret_key 'my own secret'"
cp "$WORK/etc/user" "$WORK/user.before"
CURSOR_SECRET='my own secret' run_ensure user
grep -Fq 'result=ok guard=0' "$WORK/user.out" || fail "an existing secret needs no work: $(cat "$WORK/user.out")"
cmp -s "$WORK/etc/user" "$WORK/user.before" || fail "an existing secret must never be replaced"
! grep -q . "$WORK/uci.argv" || fail "uci ran although the secret exists"

# The committed file has a secret that the cursor does not see (a staged
# delete, a commit since): it is kept, never replaced.
config hidden "	option yacd_secret_key 'committed secret'"
cp "$WORK/etc/hidden" "$WORK/hidden.before"
run_ensure hidden
grep -Fq 'result=ok guard=0' "$WORK/hidden.out" || fail "a committed secret must be kept: $(cat "$WORK/hidden.out")"
cmp -s "$WORK/etc/hidden" "$WORK/hidden.before" || fail "a committed secret was replaced"
grep -Fq 'Generated' "$WORK/hidden.out" && fail "a kept secret must not be reported as generated"

# S1 leftover: changes staged with `uci set` (no commit) stay staged; only
# the secret is committed. Under the test shim a commit of the live package
# would have to merge them and is refused, failing this test.
config staged
cp "$WORK/etc/staged" "$WORK/staged.before"
printf "%s\n" "prokop.settings.dns_server='9.9.9.9'" "prokop.main.action='block'" >"$STAGED_DIR/prokop"
cp "$STAGED_DIR/prokop" "$WORK/staged.delta"
run_ensure staged
grep -Fq 'result=ok guard=1' "$WORK/staged.out" || fail "staged changes: the secret was not generated: $(cat "$WORK/staged.out")"
[ "$(changed_options "$WORK/staged.before" "$WORK/etc/staged")" = settings.yacd_secret_key ] ||
  fail "staged changes were committed with the secret: $(changed_options "$WORK/staged.before" "$WORK/etc/staged")"
cmp -s "$STAGED_DIR/prokop" "$WORK/staged.delta" || fail "the staged changes were touched"
rm -f "$STAGED_DIR/prokop"

# Without a random source nothing is written; the validator then reports the
# missing secret.
config norandom
cp "$WORK/etc/norandom" "$WORK/norandom.before"
PROKOP_SECRET_RANDOM_SOURCE="$WORK/missing-random" run_ensure norandom
grep -Fq 'result=failed' "$WORK/norandom.out" || fail "a failed generation must be reported"
cmp -s "$WORK/etc/norandom" "$WORK/norandom.before" || fail "nothing may be written without a random source"

# A uci CLI that fails leaves the configuration as it was.
config broken
cp "$WORK/etc/broken" "$WORK/broken.before"
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/uci-broken"
chmod +x "$WORK/bin/uci-broken"
PROKOP_CONFIG_FILE="$WORK/etc/broken" PROKOP_UCI_CLI="$WORK/bin/uci-broken" \
  "$UCODE_BIN" -L "$PROKOP_LIB" "$WORK/ensure.uc" >"$WORK/broken.out" 2>&1 || fail "ensure crashed with a failing uci"
grep -Fq 'result=failed guard=0' "$WORK/broken.out" || fail "a failing uci must be reported: $(cat "$WORK/broken.out")"
cmp -s "$WORK/etc/broken" "$WORK/broken.before" || fail "a failing uci changed the configuration"
[ -z "$(find "$WORK/etc" -name '.*')" ] || fail "a failing uci left a temporary file next to the configuration"

# No settings section: uci skips the staged option and the commit succeeds
# without it. Nothing counts as written; the validator then reports the
# missing secret.
printf "config section 'main'\n\toption action 'connection'\n" >"$WORK/etc/nosettings"
chmod 0640 "$WORK/etc/nosettings"
cp "$WORK/etc/nosettings" "$WORK/nosettings.before"
run_ensure nosettings
grep -Fq 'result=failed guard=0' "$WORK/nosettings.out" || fail "a secret uci did not write was reported as written: $(cat "$WORK/nosettings.out")"
grep -Fq 'Generated' "$WORK/nosettings.out" && fail "a secret uci did not write must not be reported as generated"
cmp -s "$WORK/etc/nosettings" "$WORK/nosettings.before" || fail "the configuration changed although no secret was written"
[ -z "$(find "$WORK/etc" -name '.*')" ] || fail "a temporary file was left next to the configuration"

# The test fixture of core/uci.uc (the lifecycle tests' view of UCI) sets the
# option in its state and never logs a commit of the whole package.
printf '%s\n' 'prokop.settings=settings' 'prokop.settings.enable_yacd=0' >"$WORK/fixture.state"
: >"$WORK/fixture.log"
PROKOP_CONFIG_FILE="$WORK/etc/fixture-missing" PROKOP_UCI_STATE_FILE="$WORK/fixture.state" PROKOP_UCI_LOG_FILE="$WORK/fixture.log" \
  PROKOP_UCI_CLI="$WORK/bin/uci-broken" "$UCODE_BIN" -L "$PROKOP_LIB" "$WORK/ensure.uc" >"$WORK/fixture.out" 2>&1 ||
  fail "ensure crashed with the uci fixture"
grep -Fq 'result=ok guard=1' "$WORK/fixture.out" || fail "fixture: $(cat "$WORK/fixture.out")"
grep -Eq '^prokop\.settings\.yacd_secret_key=[0-9a-f]{64}$' "$WORK/fixture.state" || fail "fixture: no secret in the state"
[ "$(cat "$WORK/fixture.log")" = 'commit-option prokop.settings.yacd_secret_key' ] ||
  fail "fixture: a whole-package commit or none: $(cat "$WORK/fixture.log")"
[ ! -e "$WORK/etc/fixture-missing" ] || fail "fixture: a configuration file was written"

# Start and reload fill the secret in before validation; reload does it before
# it fingerprints the configuration, so the generated secret does not queue a
# second reload.
body_of() {
  awk -v name="$1" '
    $0 ~ "^function " name "\\(" { copy=1 }
    copy { print }
    copy && /^}/ { exit }
  ' "$LIFECYCLE"
}
line_in() {
  body_of "$1" | grep -n -F "$2" | head -n1 | cut -d: -f1
}
ensure_line="$(line_in start_main 'ensure_clash_api_secret();')"
validate_line="$(line_in start_main 'validate_start_config();')"
[ -n "$ensure_line" ] && [ -n "$validate_line" ] && [ "$ensure_line" -lt "$validate_line" ] ||
  fail "start must ensure the Clash API secret before validation"
ensure_line="$(line_in reload 'ensure_clash_api_secret();')"
fingerprint_line="$(line_in reload 'let reload_config_fingerprint = external_config_fingerprint();')"
validate_line="$(line_in reload 'validate_start_config();')"
[ -n "$ensure_line" ] && [ -n "$fingerprint_line" ] && [ "$ensure_line" -lt "$fingerprint_line" ] &&
  [ "$ensure_line" -lt "$validate_line" ] ||
  fail "reload must ensure the Clash API secret before it fingerprints and validates the config"

printf 'Start and reload fill in a missing Clash API secret, commit only it, and keep an existing one\n'
