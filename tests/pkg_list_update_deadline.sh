#!/usr/bin/env bash
set -euo pipefail

# The package list update of a component action (A4): opkg waited forever
# for a lock another opkg held, or for a feed that never answered, and the
# component action hung with it. It now has a deadline, and a held package
# database lock is retried.
#
# pkg_list_update_command is components/action.uc's own, extracted; opkg and
# apk are stand-ins.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

python3 - "$LIB/components/action.uc" "$WORK_DIR/probe.uc" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding='utf-8').read()
parts = []
for name in ('PKG_LIST_UPDATE_TIMEOUT', 'PKG_LOCK_RETRIES'):
    match = re.search(r'^const ' + name + r' = [^\n]*;$', source, re.M)
    if match is None:
        raise SystemExit('missing production constant: ' + name)
    parts.append(match.group())
for name in ('as_string', 'shell_quote', 'command_from_args', 'pkg_list_update_command'):
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    parts.append(match.group())
prefix = 'function is_apk() { return getenv("APK") == "1"; }\n'
open(sys.argv[2], 'w', encoding='utf-8').write(prefix + '\n\n'.join(parts) + '\nprint(pkg_list_update_command());\n')
PY

mkdir -p "$WORK_DIR/bin"
# Fails with a lock error $LOCKED times, then succeeds; or never returns.
for tool in opkg apk; do
  cat >"$WORK_DIR/bin/$tool" <<'SH'
#!/bin/sh
[ "$1" = update ] || exit 2
n=$(cat "$COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$COUNT"
[ -z "${HANG:-}" ] || exec sleep 600
if [ "$n" -le "${LOCKED:-0}" ]; then
  echo "${LOCK_MESSAGE:?}" >&2
  exit 255
fi
echo "Updated list of available packages"
SH
done
chmod +x "$WORK_DIR/bin/"*

run_update() { # run_update <apk 0|1>, environment as given
  local command
  command="$(APK="$1" PROKOP_PKG_LIST_UPDATE_TIMEOUT="${TIMEOUT:-180}" PROKOP_PKG_LOCK_RETRIES="${RETRIES:-15}" \
    ucode "$WORK_DIR/probe.uc")"
  PATH="$WORK_DIR/bin:$PATH" COUNT="$WORK_DIR/count" sh -c "$command" >"$WORK_DIR/out" 2>&1
}

# A held opkg lock is waited out.
rm -f "$WORK_DIR/count"
LOCKED=2 LOCK_MESSAGE='opkg_conf_load: Could not lock /var/lock/opkg.lock: Resource temporarily unavailable.' \
  run_update 0 || fail "the update must succeed once the lock is free: $(cat "$WORK_DIR/out")"
[ "$(cat "$WORK_DIR/count")" = 3 ] || fail "opkg update must be tried until the lock is free, ran $(cat "$WORK_DIR/count") times"
grep -Fq 'retrying (2/15)' "$WORK_DIR/out" || fail "the lock retries must be logged"

# So is apk's.
rm -f "$WORK_DIR/count"
LOCKED=1 LOCK_MESSAGE='ERROR: Unable to lock database: Resource temporarily unavailable' \
  run_update 1 || fail "apk update must succeed once the lock is free"
[ "$(cat "$WORK_DIR/count")" = 2 ] || fail "apk update must be retried after a lock error"

# A lock that is never freed fails after the retries.
rm -f "$WORK_DIR/count"
if RETRIES=2 LOCKED=99 LOCK_MESSAGE='Could not lock /var/lock/opkg.lock' run_update 0; then
  fail "a lock held for good must fail the update"
fi
[ "$(cat "$WORK_DIR/count")" = 3 ] || fail "a held lock must be tried 1 + 2 times, ran $(cat "$WORK_DIR/count")"

# Any other failure is not retried.
rm -f "$WORK_DIR/count"
if LOCKED=1 LOCK_MESSAGE='wget returned 4' run_update 0; then
  fail "a feed error must fail the update"
fi
[ "$(cat "$WORK_DIR/count")" = 1 ] || fail "a feed error must not be retried"

# A feed that never answers is cut at the deadline.
rm -f "$WORK_DIR/count"
started=$SECONDS
if HANG=1 TIMEOUT=2 run_update 0; then
  fail "a hung update must fail"
fi
[ $((SECONDS - started)) -le 8 ] || fail "a hung update must stop at its deadline"
grep -Fq 'did not finish in 2 s' "$WORK_DIR/out" || fail "a hung update must say why it failed"

printf 'package list update deadline checks passed\n'
