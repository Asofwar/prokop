#!/usr/bin/env bash
set -euo pipefail

# Temporary names of autotune/apply.uc and the manager's stale cleanup
# (UC-157).
#
# A manager run removes every prokop-autotune-apply.* in its temporary
# directory: selection and plan directories a dead run left behind. apply.uc
# named the temporary files of its config hashes with the same prefix, so an
# apply.uc run outside the manager (the CLI) lost its hash file to a manager
# run that started meanwhile and failed with hash_unavailable. Here apply.uc
# is held while it hashes the configuration and a manager run cleans up.
# Stand-ins: tests/helpers/autotune_scheduler (the manager's tools); the
# apply.uc under test is the real one.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

# sha256sum records the file it hashes and waits for the test.
mkdir -p "$WORK/hash-bin"
REAL_SHA256SUM="$(command -v sha256sum)"
cat >"$WORK/hash-bin/sha256sum" <<SH
#!/bin/sh
printf '%s\n' "\$1" >>"$WORK/hashed"
while [ ! -e "$WORK/hash.gate" ] && [ -d "$WORK" ]; do sleep 0.05; done
exec "$REAL_SHA256SUM" "\$@"
SH
chmod +x "$WORK/hash-bin/sha256sum"

manager policy-set mode recommend >/dev/null
printf '{"status":"selected","selected":"fake","confidence":"high","reason":"direct_failed_candidate_stable","target":{"host":"www.youtube.com","ip":"198.18.0.9"},"candidates":[]}\n' \
  >"$WORK/selection.json"
# A selection directory of a dead run.
mkdir -p "$WORK/tmp/prokop-autotune-apply.leftover"

PATH="$WORK/hash-bin:$PATH" ucode -L "$REAL_LIB" "$REAL_LIB/autotune/apply.uc" plan "$WORK/selection.json" 192.0.2.53 \
  >"$WORK/plan.json" 2>&1 &
planner=$!
BG_PIDS+=("$planner")
wait_until 20 test -s "$WORK/hashed" || fail "apply.uc did not hash the configuration"
hash_file="$(head -n 1 "$WORK/hashed")"
[ "$(dirname "$hash_file")" = "$WORK/tmp" ] || fail "fixture: apply.uc hashes outside the autotune temporary directory: $hash_file"
[ -e "$hash_file" ] || fail "fixture: the file being hashed is missing"

manager run youtube >"$WORK/run.json" || fail "the manager run failed: $(cat "$WORK/run.json")"
[ ! -e "$WORK/tmp/prokop-autotune-apply.leftover" ] || fail "the manager run kept the directory of a dead run"
[ -e "$hash_file" ] || fail "the manager run removed the file a running apply.uc was hashing: ${hash_file##*/}"

: >"$WORK/hash.gate"
wait_until 30 process_gone "$planner" || fail "apply.uc did not finish"
wait "$planner" 2>/dev/null || true
if grep -q '"hash_unavailable"' "$WORK/plan.json"; then
  fail "apply.uc lost its configuration hash"
fi
[ ! -e "$hash_file" ] || fail "apply.uc left its hash file behind"

printf 'autotune temporary name checks passed\n'
