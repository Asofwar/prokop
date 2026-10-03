#!/usr/bin/env bash
# Self-test of the parallel test runner tests/run.sh. The runner is copied
# into a throwaway repository whose tests/ holds only fake tests (pass, fail,
# flaky, timeout, a barrier that passes only when run in parallel, files for
# --affected), so the real suite is never run.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

REPO="$WORK/repo"
STATE="$WORK/state"
mkdir -p "$REPO/tests" "$STATE" "$WORK/tmp" "$WORK/host/run/prokop" "$WORK/host/tmp"
cp "$ROOT_DIR/tests/run.sh" "$REPO/tests/run.sh"

fake_test() { # NAME BODY
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$REPO/tests/$1.sh"
}

# The runner as a developer calls it, but with its logs and durations cache
# inside $WORK, and its host check on $WORK/host instead of the host.
# GITHUB_ACTIONS is dropped: without TEST arguments the runner would otherwise
# leave the suite to the CI loop; so is PROKOP_TEST_GROUP_JOBS, which the
# runner running this test sets.
runner() {
  env -u GITHUB_ACTIONS -u PROKOP_TEST_GROUP_JOBS TMPDIR="$WORK/tmp" PROKOP_TEST_HOST_ROOT="$WORK/host" \
    bash "$REPO/tests/run.sh" --durations "$WORK/durations.tsv" "$@"
}

expect_line() { # FILE TEXT
  grep -Fq -- "$2" "$1" || {
    cat "$1" >&2
    fail "runner output lacks: $2"
  }
}

fake_test pass 'echo pass-output'
fake_test fail 'echo fail-marker-line; exit 3'
fake_test flaky "if [ -e '$STATE/flaky' ]; then exit 0; fi
: >'$STATE/flaky'
echo flaky-first-failure
exit 1"
fake_test timeout 'echo timeout-start; exec sleep 600'

# 1. Every test: one passes, one fails, one is flaky, one times out.
if runner -j 4 -t 2 >"$WORK/all.out" 2>&1; then
  cat "$WORK/all.out" >&2
  fail "the runner succeeded although a test failed"
fi
expect_line "$WORK/all.out" 'PASS 1  FLAKY 1  FAIL 2  of 4 tests'
expect_line "$WORK/all.out" 'Re-running 3 failed test(s) one at a time'
expect_line "$WORK/all.out" 'FAIL fail: FAIL (exit 3)'
expect_line "$WORK/all.out" '    fail-marker-line'
expect_line "$WORK/all.out" 'FAIL timeout: TIMEOUT after 2s'
expect_line "$WORK/all.out" '    timeout-start'
expect_line "$WORK/all.out" 'FLAKY flaky: first run FAIL (exit 1)'
expect_line "$WORK/all.out" '    flaky-first-failure'
expect_line "$WORK/all.out" '!!! 1 FLAKY test(s) above'
if grep -Fq 'pass-output' "$WORK/all.out"; then
  fail "the log of a passing test was printed"
fi
for name in fail flaky pass timeout; do
  grep -Eq "^$name"$'\t''[0-9]+\.[0-9]$' "$WORK/durations.tsv" ||
    fail "no duration recorded for $name: $(cat "$WORK/durations.tsv")"
done
grep -Fxq "timeout"$'\t'"2.0" "$WORK/durations.tsv" ||
  fail "a timed-out test is not recorded with the timeout"

# 2. Order: tests without a recorded duration first, then the longest first.
printf 'pass\t5.0\nfail\t1.0\nflaky\t9.0\n' >"$WORK/durations.tsv"
runner --list >"$WORK/order.out"
[ "$(cat "$WORK/order.out")" = "$(printf 'timeout\nflaky\npass\nfail')" ] ||
  fail "unexpected run order: $(cat "$WORK/order.out")"

# 3. A test that fails and then passes alone does not fail the run.
rm -f "$STATE/flaky"
runner pass flaky >"$WORK/flaky.out" 2>&1 || {
  cat "$WORK/flaky.out" >&2
  fail "a flaky test failed the run"
}
expect_line "$WORK/flaky.out" 'PASS 1  FLAKY 1  FAIL 0  of 2 tests'
# A new duration is averaged with the cached one (5.0 s for pass).
grep -Eq '^pass'$'\t''2\.[5-9]$' "$WORK/durations.tsv" ||
  fail "the duration of pass was not averaged with the cached 5.0 s: $(cat "$WORK/durations.tsv")"

# 4. --no-rerun reports the first failure.
rm -f "$STATE/flaky"
if runner --no-rerun 'fla*' >"$WORK/norerun.out" 2>&1; then
  fail "--no-rerun passed a failing test"
fi
expect_line "$WORK/norerun.out" 'PASS 0  FLAKY 0  FAIL 1  of 1 tests'
if grep -Fq 'Re-running' "$WORK/norerun.out"; then
  fail "--no-rerun re-ran a test"
fi

# 5. Tests run in parallel: each barrier test waits until all three have
# started, which a sequential run never reaches.
for name in barrier_a barrier_b barrier_c; do
  fake_test "$name" "touch '$STATE/$name'
for _ in \$(seq 200); do
  [ -e '$STATE/barrier_a' ] && [ -e '$STATE/barrier_b' ] && [ -e '$STATE/barrier_c' ] && exit 0
  sleep 0.1
done
exit 1"
done
runner -j 3 --no-rerun 'barrier_*' >"$WORK/parallel.out" 2>&1 || {
  cat "$WORK/parallel.out" >&2
  fail "tests did not run in parallel"
}
expect_line "$WORK/parallel.out" 'PASS 3  FLAKY 0  FAIL 0  of 3 tests'

# 5b. Groups of cases at once (tests/helpers/case_groups.sh): next to other
# tests 2 x CPUs / jobs of them (at least 2), a test run alone all of them; a
# value set by the caller applies to every test.
for name in gj_a gj_b gj_c; do
  fake_test "$name" "printf '%s\n' \"\${PROKOP_TEST_GROUP_JOBS:-unset}\" >'$STATE/$name.gj'"
done
printf 'gj_a\t9.0\ngj_b\t5.0\ngj_c\t1.0\n' >"$WORK/durations.tsv"
cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
[ "$cpus" -gt 2 ] || cpus=2
runner -j 2 'gj_*' >"$WORK/gj.out" 2>&1 || fail "the group-jobs tests failed: $(cat "$WORK/gj.out")"
[ "$(cat "$STATE/gj_a.gj" "$STATE/gj_b.gj" "$STATE/gj_c.gj" | tr '\n' ' ')" = "$cpus $cpus $cpus " ] ||
  fail "PROKOP_TEST_GROUP_JOBS of the tests: $(cat "$STATE"/gj_*.gj | tr '\n' ' ')"
runner gj_b >"$WORK/gj.out" 2>&1 || fail "a single group-jobs test failed: $(cat "$WORK/gj.out")"
[ "$(cat "$STATE/gj_b.gj")" = unset ] || fail "a test run alone was limited: $(cat "$STATE/gj_b.gj")"
env -u GITHUB_ACTIONS PROKOP_TEST_GROUP_JOBS=7 TMPDIR="$WORK/tmp" PROKOP_TEST_HOST_ROOT="$WORK/host" bash "$REPO/tests/run.sh" \
  --durations "$WORK/durations.tsv" -j 2 'gj_*' >"$WORK/gj.out" 2>&1 || fail "the group-jobs tests failed: $(cat "$WORK/gj.out")"
[ "$(cat "$STATE/gj_a.gj" "$STATE/gj_b.gj" "$STATE/gj_c.gj" | tr '\n' ' ')" = "7 7 7 " ] ||
  fail "a caller's PROKOP_TEST_GROUP_JOBS was not kept: $(cat "$STATE"/gj_*.gj | tr '\n' ' ')"

# 6. --affected selects by path, basename, module name, users of a changed
# module or helper, changed tests and the safety set.
mkdir -p "$REPO/prokop/files/usr/lib/core" "$REPO/prokop/files/usr/lib/feature" "$REPO/tests/helpers"
printf 'return { x: 1 };\n' >"$REPO/prokop/files/usr/lib/core/base.uc"
printf 'let base = require("core.base");\n' >"$REPO/prokop/files/usr/lib/feature/user.uc"
printf 'helper() { :; }\n' >"$REPO/tests/helpers/common.sh"
fake_test uses_base "ucode -e 'require(\"core.base\")'"
# shellcheck disable=SC2016 # $ROOT_DIR is the fake test's own variable
fake_test uses_user 'ucode "$ROOT_DIR/prokop/files/usr/lib/feature/user.uc"'
# shellcheck disable=SC2016
fake_test uses_helper '. "$ROOT_DIR/tests/helpers/common.sh"'
fake_test unrelated 'true'
fake_test acl_boundary 'true'

git_repo() {
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$REPO" \
    -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false "$@"
}
command -v git >/dev/null 2>&1 || fail "git is required for the --affected check"
git_repo init -q
git_repo add -A
git_repo commit -q -m base

affected() { # BASE EXPECTED-NAMES...
  local base=$1
  shift
  runner --affected "$base" --list >"$WORK/affected.out" 2>&1 || {
    cat "$WORK/affected.out" >&2
    fail "--affected $base failed"
  }
  [ "$(LC_ALL=C sort "$WORK/affected.out")" = "$(printf '%s\n' "$@" | LC_ALL=C sort)" ] ||
    fail "--affected $base selected: $(tr '\n' ' ' <"$WORK/affected.out"), expected: $*"
}

affected HEAD acl_boundary
printf 'return { x: 2 };\n' >"$REPO/prokop/files/usr/lib/core/base.uc"
affected HEAD acl_boundary uses_base uses_user
git_repo commit -q -am 'change base'
affected HEAD~1 acl_boundary uses_base uses_user
affected HEAD~1..HEAD acl_boundary uses_base uses_user
printf 'helper() { true; }\n' >"$REPO/tests/helpers/common.sh"
fake_test new_test 'true'
affected HEAD acl_boundary uses_helper new_test
runner --affected HEAD --list --verbose >"$WORK/why.out" 2>&1
expect_line "$WORK/why.out" 'tests/helpers/common.sh'
grep -Eq '^uses_helper +names .*tests/helpers/common\.sh' "$WORK/why.out" ||
  fail "--verbose does not say why uses_helper was selected: $(cat "$WORK/why.out")"
grep -Eq '^acl_boundary +safety set' "$WORK/why.out" ||
  fail "--verbose does not name the safety set"

# 7. Under GitHub Actions a bare call leaves the suite to the CI loop.
GITHUB_ACTIONS=true TMPDIR="$WORK/tmp" PROKOP_TEST_HOST_ROOT="$WORK/host" bash "$REPO/tests/run.sh" \
  --durations "$WORK/durations.tsv" >"$WORK/ci.out" 2>&1 ||
  fail "a bare call under GitHub Actions failed"
expect_line "$WORK/ci.out" 'pass --all'
if grep -Fq 'Running' "$WORK/ci.out"; then
  fail "a bare call under GitHub Actions ran tests"
fi

# 8. A test that writes to the host instead of its temporary directory
# fails the run, also when it passes itself: here an entry at / (a path under
# an empty variable) and a file in Prokop's runtime directory. The runner
# names what changed; a later run that leaves the host as it was passes.
fake_test host_leak "printf x >'$WORK/host/stray'; : >'$WORK/host/run/prokop/state.json'"
if runner host_leak >"$WORK/host.out" 2>&1; then
  cat "$WORK/host.out" >&2
  fail "a test that wrote to the host passed the run"
fi
expect_line "$WORK/host.out" 'PASS 1  FLAKY 0  FAIL 0  of 1 tests'
expect_line "$WORK/host.out" 'HOST CHANGED'
expect_line "$WORK/host.out" "> $WORK/host/stray f 1 "
expect_line "$WORK/host.out" "> $WORK/host/run/prokop/state.json f 0 "
runner pass >"$WORK/host.out" 2>&1 || {
  cat "$WORK/host.out" >&2
  fail "a run that left the host as it was failed"
}

printf 'Test runner self-test passed\n'
