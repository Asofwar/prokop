#!/usr/bin/env bash
set -euo pipefail

# Start and stop of the DPI providers poll for their processes instead of
# sleeping whole seconds (opt. 11, 12), the bounded `sing-box version` probe
# polls every 0.1 s (opt. 13), and the compressed sing-box is not unpacked to
# answer it (opt. 14). The whole-second sleeps are counted through a `sleep`
# stand-in, not timed, so a loaded machine cannot make the test flaky.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
RUNTIME="$LIB/providers/byedpi/runtime.uc"
WORK_DIR="$(mktemp -d)"

# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

groups=()
cleanup() {
  if [ "${#groups[@]}" -gt 0 ]; then
    owned_kill KILL "${groups[@]}" || :
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

real_sleep="$(command -v sleep)"
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/sleep" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK_DIR/sleeps"
exec "$real_sleep" "\$@"
SH
cat >"$WORK_DIR/bin/logger" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK_DIR/log"
SH
chmod +x "$WORK_DIR/bin/sleep" "$WORK_DIR/bin/logger"

# A ciadpi that keeps running, and one that exits at once.
cat >"$WORK_DIR/ciadpi" <<SH
#!/bin/sh
exec "$real_sleep" 30
SH
cat >"$WORK_DIR/ciadpi-dies" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$WORK_DIR/ciadpi" "$WORK_DIR/ciadpi-dies"

{
  printf 'prokop.settings=settings\n'
  for rule in r1 r2 r3 r4; do
    printf 'prokop.%s=section\nprokop.%s.action=byedpi\n' "$rule" "$rule"
  done
} >"$WORK_DIR/state"
printf 'prokop.settings=settings\n' >"$WORK_DIR/empty-state"

# run_runtime STATE BIN MODE: the runtime in its own process group, so that
# everything it starts is cleaned up with it.
run_runtime() {
  local rc=0
  : >"$WORK_DIR/sleeps"
  PATH="$WORK_DIR/bin:$PATH" PROKOP_UCI_STATE_FILE="$1" BYEDPI_BIN="$2" \
    BYEDPI_STATE_DIR="$WORK_DIR/byedpi" BYEDPI_SERVICE_INIT="$WORK_DIR/none" \
    PROKOP_LIB="$LIB" POSIXLY_CORRECT=1 \
    setsid ucode -L "$LIB" "$RUNTIME" "$3" >"$WORK_DIR/out" 2>&1 &
  local pid=$!
  groups+=("$pid")
  wait "$pid" || rc=$?
  return "$rc"
}

whole_second_sleeps() {
  grep -c -x '1' "$WORK_DIR/sleeps" || :
}

# A start used to sleep a whole second per rule. The supervisor's pidfile
# record may still sleep once when it reads /proc too early; that is not
# per rule.
per_rule_sleeps() {
  [ "$(whole_second_sleeps)" -ge "$1" ]
}

# Opt. 11: a stop without rules waits for nothing.
run_runtime "$WORK_DIR/empty-state" "$WORK_DIR/ciadpi" stop-runtime || fail "an empty stop failed"
[ ! -s "$WORK_DIR/sleeps" ] || fail "a stop without rules still sleeps: $(tr '\n' ' ' <"$WORK_DIR/sleeps")"

# Opt. 12: four rules start together, with no whole-second sleep per rule.
run_runtime "$WORK_DIR/state" "$WORK_DIR/ciadpi" start-runtime || {
  cat "$WORK_DIR/out" >&2
  fail "four ByeDPI rules did not start"
}
if per_rule_sleeps 4; then
  fail "the start still sleeps a whole second per rule: $(tr '\n' ' ' <"$WORK_DIR/sleeps")"
fi
for rule in r1 r2 r3 r4; do
  pid="$(head -n 1 "$WORK_DIR/byedpi/child-pid/$rule.pid" 2>/dev/null || :)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    fail "ciadpi of rule $rule is not running after the start"
  fi
done
run_runtime "$WORK_DIR/empty-state" "$WORK_DIR/ciadpi" stop-runtime || fail "the stop failed"
[ "$(whole_second_sleeps)" = 0 ] || fail "the stop still sleeps whole seconds: $(tr '\n' ' ' <"$WORK_DIR/sleeps")"

# A ciadpi that exits at once still fails the start (fail closed).
if run_runtime "$WORK_DIR/state" "$WORK_DIR/ciadpi-dies" start-runtime; then
  fail "a start whose ciadpi exits at once succeeded"
fi
grep -q "but ciadpi is not running" "$WORK_DIR/log" || {
  cat "$WORK_DIR/out" "$WORK_DIR/log" >&2
  fail "a ciadpi that exits at once was not named"
}
run_runtime "$WORK_DIR/empty-state" "$WORK_DIR/ciadpi" stop-runtime || :

# The same for zapret, through the shared NFQUEUE runtime.
{
  printf 'prokop.settings=settings\n'
  for rule in z1 z2 z3; do
    printf 'prokop.%s=section\nprokop.%s.action=zapret\n' "$rule" "$rule"
  done
} >"$WORK_DIR/zapret-state"
run_zapret() {
  local rc=0
  : >"$WORK_DIR/sleeps"
  PATH="$WORK_DIR/bin:$PATH" PROKOP_UCI_STATE_FILE="$1" ZAPRET_NFQWS_BIN="$WORK_DIR/ciadpi" \
    ZAPRET_PROVIDER_NFQWS_BIN="$WORK_DIR/ciadpi" ZAPRET_STATE_DIR="$WORK_DIR/zapret" \
    ZAPRET_PID_DIR="$WORK_DIR/zapret/pid" ZAPRET_CHILD_PID_DIR="$WORK_DIR/zapret/child-pid" \
    ZAPRET_LOG_DIR="$WORK_DIR/zapret/log" PROKOP_LIB="$LIB" POSIXLY_CORRECT=1 \
    setsid ucode -L "$LIB" "$LIB/providers/zapret/runtime.uc" "$2" >"$WORK_DIR/out" 2>&1 &
  local pid=$!
  groups+=("$pid")
  wait "$pid" || rc=$?
  return "$rc"
}
run_zapret "$WORK_DIR/empty-state" stop-runtime || fail "an empty zapret stop failed"
[ ! -s "$WORK_DIR/sleeps" ] || fail "a zapret stop without rules still sleeps: $(tr '\n' ' ' <"$WORK_DIR/sleeps")"
run_zapret "$WORK_DIR/zapret-state" start-runtime || {
  cat "$WORK_DIR/out" "$WORK_DIR/log" >&2
  fail "three zapret rules did not start"
}
if per_rule_sleeps 3; then
  fail "the zapret start still sleeps a whole second per rule: $(tr '\n' ' ' <"$WORK_DIR/sleeps")"
fi
[ "$(find "$WORK_DIR/zapret/child-pid" -name '*.pid' | wc -l)" = 3 ] || fail "not every zapret rule started"
run_zapret "$WORK_DIR/empty-state" stop-runtime || fail "the zapret stop failed"

# Opt. 13: the bounded probe answers as soon as the command does, and still
# cuts a command that hangs.
python3 - "$LIB/config/validator.uc" "$WORK_DIR/probe.uc" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding='utf-8').read()
parts = ['let fs = require("fs");']
for name in ('as_string', 'shell_quote', 'command_from_args', 'command_output', 'command_output_from_args',
             'bounded_command_output_from_args'):
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    parts.append(match.group())
parts.append('print(bounded_command_output_from_args(split(ARGV[0], " "), int(ARGV[1])));')
open(sys.argv[2], 'w', encoding='utf-8').write('\n\n'.join(parts) + '\n')
PY
probe() {
  : >"$WORK_DIR/sleeps"
  PATH="$WORK_DIR/bin:$PATH" ucode "$WORK_DIR/probe.uc" "$1" "$2"
}
[ "$(probe "echo instant" 5)" = "instant" ] || fail "the bounded probe lost the output"
[ "$(whole_second_sleeps)" = 0 ] || fail "the bounded probe waits a whole second for an instant command"
start="$(date +%s)"
[ -z "$(probe "$real_sleep 20" 1 2>/dev/null)" ] || fail "a command past its bound gave output"
[ $(($(date +%s) - start)) -le 5 ] || fail "a command past its 1 s bound was not cut"

# Opt. 14: the compressed sing-box is not run for its version.
grep -Fq 'if (!sing_box_compressed && command_exists("sing-box"))' "$LIB/config/validator.uc" ||
  fail "the compressed sing-box must not be run for its version"

printf 'DPI start/stop timing checks passed\n'
