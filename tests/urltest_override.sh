#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
OVERRIDE_UC="$PROKOP_LIB/config/urltest_override.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

: >"$WORK_DIR/config.state"
PROKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$PROKOP_LIB" "$OVERRIDE_UC" save main group \
    https://example.com/generate_204 70s 175 30m 1

grep -Fq 'prokop.cfg000001=urltest_override' "$WORK_DIR/config.state" ||
  fail "save must create a URLTest override section"
grep -Fq 'prokop.cfg000001.testing_url=https://example.com/generate_204' "$WORK_DIR/config.state" ||
  fail "save must persist the testing URL"

cat >"$WORK_DIR/apply.uc" <<'EOF'
let override = require("config.urltest_override");
let outbound = { type: "urltest", url: "source", interval: "3m", tolerance: 50, idle_timeout: "30m", interrupt_exist_connections: false };
override.apply(outbound, "main", "group");
print(outbound.url, "|", outbound.interval, "|", outbound.tolerance, "|", outbound.idle_timeout, "|", outbound.interrupt_exist_connections, "\n");
EOF
applied="$(PROKOP_UCI_STATE_FILE="$WORK_DIR/config.state" ucode -L "$PROKOP_LIB" "$WORK_DIR/apply.uc")"
[ "$applied" = 'https://example.com/generate_204|70s|175|30m|true' ] ||
  fail "apply must overlay all URLTest runtime fields"

if PROKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$PROKOP_LIB" "$OVERRIDE_UC" save main group bad-url 0s '' nope 2; then
  fail "save must reject invalid values"
fi

PROKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$PROKOP_LIB" "$OVERRIDE_UC" reset main group
if grep -Fq 'urltest_override' "$WORK_DIR/config.state"; then
  fail "reset must remove the URLTest override section"
fi

printf 'URLTest override checks passed\n'

cat >"$WORK_DIR/source.state" <<'EOF'
prokop.ut_main=urltest
prokop.ut_main.section=main
prokop.ut_main.name=Fastest
prokop.old=urltest_override
prokop.old.rule=main
prokop.old.tag=main-urltest-ut_main-out
EOF
PROKOP_UCI_STATE_FILE="$WORK_DIR/source.state" \
  ucode -L "$PROKOP_LIB" "$OVERRIDE_UC" save main main-urltest-ut_main-out \
  https://example.com/check 90s 80 15m 0
grep -Fxq 'prokop.ut_main.testing_url=https://example.com/check' "$WORK_DIR/source.state" ||
  fail "configured URLTest settings must be updated at their source"
grep -Fxq 'prokop.ut_main.interrupt_exist_connections=0' "$WORK_DIR/source.state" ||
  fail "configured URLTest settings must preserve the interrupt option"
if grep -Fq 'urltest_override' "$WORK_DIR/source.state"; then
  fail "saving a configured group must remove its obsolete runtime override"
fi

# The dashboard saves a new value only as the validator takes it at start
# without a warning: a URL with a host, and a tolerance of 0..65535 for an
# override, as sing-box and the dashboard always took, or of 0..10000 for the
# URLTest group section of a rule the save writes to, as the validator and
# the rule editor take there.
: >"$WORK_DIR/range.state"
for args in 'http:///generate_204 70s 175' 'https://example.com/generate_204 70s 65536'; do
  # shellcheck disable=SC2086 # the URL, interval and tolerance are words
  if PROKOP_UCI_STATE_FILE="$WORK_DIR/range.state" \
    ucode -L "$PROKOP_LIB" "$OVERRIDE_UC" save main group $args 30m 1; then
    fail "save must reject what the validator refuses or warns about: $args"
  fi
done
[ ! -s "$WORK_DIR/range.state" ] || fail "a refused save must not write UCI"
PROKOP_UCI_STATE_FILE="$WORK_DIR/range.state" \
  ucode -L "$PROKOP_LIB" "$OVERRIDE_UC" save main group https://example.com:8443/generate_204 70s 65535 30m 1 ||
  fail "save must accept a tolerance of 65535 for an override"
grep -Fxq 'prokop.cfg000001.tolerance=65535' "$WORK_DIR/range.state" ||
  fail "save must persist a tolerance of 65535 for an override"
cp "$WORK_DIR/source.state" "$WORK_DIR/source-range.state"
if PROKOP_UCI_STATE_FILE="$WORK_DIR/source-range.state" \
  ucode -L "$PROKOP_LIB" "$OVERRIDE_UC" save main main-urltest-ut_main-out \
  https://example.com/check 90s 10001 15m 0; then
  fail "save must not write a tolerance the URLTest group check refuses"
fi
cmp -s "$WORK_DIR/source.state" "$WORK_DIR/source-range.state" ||
  fail "a refused save must leave the URLTest group section unchanged"
PROKOP_UCI_STATE_FILE="$WORK_DIR/source-range.state" \
  ucode -L "$PROKOP_LIB" "$OVERRIDE_UC" save main main-urltest-ut_main-out \
  https://example.com/check 90s 10000 15m 0 ||
  fail "save must accept a tolerance of 10000 for the URLTest group section"
grep -Fxq 'prokop.ut_main.tolerance=10000' "$WORK_DIR/source-range.state" ||
  fail "save must write a tolerance of 10000 to the URLTest group section"
