#!/usr/bin/env bash
# Parallel runner for the backend tests (tests/*.sh): a fast local loop.
# CI still runs every test on its own (.github/workflows/backend-ci.yml).
#
# Usage: tests/run.sh [OPTION...] [TEST...]
#
# TEST is a test name (acl_boundary), a path (tests/acl_boundary.sh) or a
# quoted glob over the names ('autotune_*'). Without TEST and without
# --affected every tests/*.sh runs.
#
#   -j N              run N tests at once (default: twice the CPU count,
#                     the tests mostly wait)
#   -t SECONDS        stop a test after SECONDS and count it failed (default 900)
#   --affected BASE   run the tests that the changes since BASE can affect:
#                     the files of `git diff BASE...HEAD` (or of the range
#                     BASE when it holds '..') and the staged, unstaged and
#                     untracked files. A test is selected when it changed or
#                     its text names a changed file by repository path, by
#                     basename (.uc .js .ts .sh .json under prokop/,
#                     luci-app-prokop/, fe-app-prokop/src/, tests/helpers/), by
#                     ucode module name (core.uci) or by its fixture
#                     directory. A module or helper that requires or sources a
#                     changed one counts as changed. A safety set always runs.
#   -v, --verbose     print why each test was selected
#   -l, --list        print the selected tests in run order and exit
#   --no-rerun        do not re-run failed tests
#   --durations FILE  durations cache for longest-first scheduling (default
#                     ${XDG_CACHE_HOME:-$HOME/.cache}/prokop-tests/durations.tsv)
#   --all             run every test; without TEST under GitHub Actions the
#                     runner otherwise exits at once, since the CI loop over
#                     tests/*.sh runs each test itself
#   -h, --help        print this help
#
# Tests start longest first by the durations cache (tests without a recorded
# duration first) and the cache is updated after the run. Each test runs
# from the repository root with stdin from /dev/null; its output goes to a
# log file in a temporary directory. After the parallel pass each failed test
# is run once more, alone: one that passes then is reported as FLAKY and does
# not fail the run. While several tests run at once, a test that runs groups
# of its cases in parallel (tests/helpers/case_groups.sh) runs at most
# PROKOP_TEST_GROUP_JOBS of them at a time (default: 2 x CPUs / jobs, at
# least 2; a value set in the environment is kept). A test run alone runs all
# its groups at once.
#
# A test keeps its files in its own temporary directory. The run also fails
# when it changed the host where a test that misses an override of a Prokop
# default path, or writes under an empty variable, writes instead: an entry
# at /, Prokop's paths under /etc, /usr, /run and /tmp, the default UCI
# savedir (HOST_PATHS). PROKOP_TEST_HOST_ROOT moves that check to another
# root (the runner's self-test).
#
# Exit status: 0 when no test failed and the host is unchanged, 1 when a
# test failed or the host changed, 2 on a usage error, 130 when interrupted.

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SELF")/.." && pwd)"
TESTS_DIR="$ROOT_DIR/tests"

SAFETY_SET=(acl_boundary readonly_hostile_env readonly_secret_masking
  luci_readonly_command_guard luci_readonly_view cli_entrypoint
  source_assertions shell_inventory)

KILL_GRACE=10
LOG_TAIL=20
SLOWEST=10

die() {
  printf 'run.sh: %s\n' "$1" >&2
  exit "${2:-2}"
}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SELF"
}

if ((BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1))); then
  die "bash 5.1 or newer is required (wait -n -p), this is $BASH_VERSION"
fi
command -v timeout >/dev/null 2>&1 || die "timeout (coreutils) is required"

# ---------------------------------------------------------------------------
# Options

jobs_n=""
timeout_s=900
affected=""
verbose=0
list_only=0
rerun=1
run_all=0
durations="${XDG_CACHE_HOME:-$HOME/.cache}/prokop-tests/durations.tsv"
args=()

need_value() {
  (($# >= 2)) || die "$1 needs a value"
}

while (($#)); do
  case $1 in
    -j) need_value "$@"; jobs_n=$2; shift 2 ;;
    -j*) jobs_n=${1#-j}; shift ;;
    -t) need_value "$@"; timeout_s=$2; shift 2 ;;
    --affected) need_value "$@"; affected=$2; shift 2 ;;
    --affected=*) affected=${1#*=}; shift ;;
    -v | --verbose) verbose=1; shift ;;
    -l | --list) list_only=1; shift ;;
    --no-rerun) rerun=0; shift ;;
    --durations) need_value "$@"; durations=$2; shift 2 ;;
    --durations=*) durations=${1#*=}; shift ;;
    --all) run_all=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; args+=("$@"); break ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) args+=("$1"); shift ;;
  esac
done

cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
if [[ -z $jobs_n ]]; then
  jobs_n=$((cpus * 2))
fi
[[ $jobs_n =~ ^[1-9][0-9]*$ ]] || die "-j needs a positive number, got '$jobs_n'"
[[ $timeout_s =~ ^[1-9][0-9]*$ ]] || die "-t needs a positive number of seconds, got '$timeout_s'"

if ((${#args[@]} == 0)) && [[ -z $affected ]] && ((run_all == 0)) &&
  [[ ${GITHUB_ACTIONS:-} == true ]]; then
  printf 'run.sh: the CI loop over tests/*.sh runs every test itself; pass --all to run them here too\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Selection

declare -A TEST_PATH=() REASON=() REASONS_N=()
selected=()

all_tests() {
  local file
  for file in "$TESTS_DIR"/*.sh; do
    [[ -f $file && ! $file -ef $SELF ]] && printf '%s\n' "$file"
  done
}

add_test() { # NAME PATH REASON
  if [[ -z ${TEST_PATH[$1]+set} ]]; then
    TEST_PATH[$1]=$2
    REASON[$1]=$3
    REASONS_N[$1]=1
    selected+=("$1")
  elif ((REASONS_N[$1] < 3)); then
    REASON[$1]+="; $3"
    REASONS_N[$1]=$((REASONS_N[$1] + 1))
  else
    REASONS_N[$1]=$((REASONS_N[$1] + 1))
  fi
}

select_arg() { # ARG: a path, a name or a glob over names
  local arg=$1 pattern file name matched=0
  if [[ -f $arg ]]; then
    file="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")"
    [[ $file -ef $SELF ]] && die "$arg is the runner, not a test"
    add_test "$(basename "$file" .sh)" "$file" "named on the command line"
    return
  fi
  pattern=${arg#tests/}
  pattern=${pattern%.sh}
  while IFS= read -r file; do
    name="$(basename "$file" .sh)"
    # shellcheck disable=SC2053 # the pattern is a glob on purpose
    if [[ $name == $pattern ]]; then
      add_test "$name" "$file" "named on the command line"
      matched=1
    fi
  done < <(all_tests)
  ((matched)) || die "no test matches '$arg'"
}

changed_files() { # BASE
  local range=$1
  [[ $range == *..* ]] || range="$range...HEAD"
  (
    cd "$ROOT_DIR" || exit 1
    git rev-parse --git-dir >/dev/null 2>&1 || { printf 'run.sh: %s is not a git checkout\n' "$ROOT_DIR" >&2; exit 1; }
    git diff --name-only "$range" -- || exit 1
    git diff --name-only HEAD -- 2>/dev/null
    git ls-files --others --exclude-standard
  ) | LC_ALL=C sort -u
}

# Dotted ucode module name of a library file: prokop/files/usr/lib/core/uci.uc
# is required as "core.uci".
module_name() {
  local path=$1
  [[ $path == prokop/files/usr/lib/*.uc ]] || return 1
  path=${path#prokop/files/usr/lib/}
  path=${path%.uc}
  printf '%s\n' "${path//\//.}"
}

# Text by which another module, script or helper uses FILE.
usage_tokens() {
  local file=$1 module
  if module="$(module_name "$file")"; then
    printf '%s\n' "\"$module\"" "'$module'" "/${file#prokop/files/usr/lib/}"
  fi
  case $file in
    tests/helpers/*) printf '%s\n' "${file#tests/}" ;;
  esac
}

# Repository files that use a changed file count as changed: a module that
# requires a changed module, a helper that sources a changed helper.
declare -A CHANGED=()
expand_changed() {
  local -a frontier=("$@") next tokens scope
  local file user dir
  for dir in prokop/files luci-app-prokop/root tests/helpers; do
    [[ -d $ROOT_DIR/$dir ]] && scope+=("$dir")
  done
  ((${#scope[@]})) || return 0
  while ((${#frontier[@]})); do
    next=()
    for file in "${frontier[@]}"; do
      mapfile -t tokens < <(usage_tokens "$file")
      ((${#tokens[@]})) || continue
      while IFS= read -r user; do
        [[ -n ${CHANGED[$user]+set} ]] && continue
        CHANGED[$user]="$file"
        next+=("$user")
      done < <(cd "$ROOT_DIR" && grep -rlF "${tokens[@]/#/-e}" -- "${scope[@]}" 2>/dev/null | LC_ALL=C sort)
    done
    frontier=("${next[@]}")
  done
}

# Text by which a test names FILE. Prints "w<TAB>token" for a token matched
# as a whole word and "s<TAB>token" for a plain substring.
test_tokens() {
  local file=$1 base module dir
  printf 's\t%s\n' "$file"
  base=${file##*/}
  case $file in
    prokop/* | luci-app-prokop/* | fe-app-prokop/src/* | tests/helpers/*)
      case $base in
        *.uc | *.js | *.ts | *.sh | *.json) printf 's\t%s\n' "$base" ;;
      esac
      ;;
    tests/fixtures/*) printf 's\t%s\n' "$base" ;;
  esac
  module="$(module_name "$file")" && printf 'w\t%s\n' "$module"
  case $file in
    tests/fixtures/*/* | tests/helpers/*/*)
      dir=${file%/*}
      while [[ $dir == tests/fixtures/* || $dir == tests/helpers/* ]]; do
        printf 's\t%s\n' "$dir"
        dir=${dir%/*}
      done
      ;;
  esac
}

select_affected() { # BASE
  local list file name kind token origin via test_file
  local -a direct test_files
  local -A token_files=() sub_tokens=() word_tokens=()
  list="$(changed_files "$1")" || die "cannot list the changes since '$1'" 2
  mapfile -t direct < <(printf '%s\n' "$list" | sed '/^$/d')
  if ((verbose)); then
    printf 'Changed files since %s: %d\n' "$1" "${#direct[@]}"
    ((${#direct[@]})) && printf '  %s\n' "${direct[@]}"
  fi
  for file in "${direct[@]}"; do
    CHANGED[$file]=""
  done
  ((${#direct[@]})) && expand_changed "${direct[@]}"

  mapfile -t test_files < <(all_tests)
  for file in "${!CHANGED[@]}"; do
    if [[ $file == tests/*.sh && $file != tests/*/* && -f $ROOT_DIR/$file && ! $ROOT_DIR/$file -ef $SELF ]]; then
      add_test "$(basename "$file" .sh)" "$ROOT_DIR/$file" "changed"
    fi
    while IFS=$'\t' read -r kind token; do
      token_files[$token]+="$file"$'\n'
      if [[ $kind == w ]]; then word_tokens[$token]=1; else sub_tokens[$token]=1; fi
    done < <(test_tokens "$file")
  done

  if ((${#test_files[@]})) && ((${#token_files[@]})); then
    while IFS= read -r line; do
      test_file=${line%%:*}
      token=${line#*:}
      name="$(basename "$test_file" .sh)"
      while IFS= read -r origin; do
        [[ -n $origin ]] || continue
        via=${CHANGED[$origin]}
        if [[ -n $via ]]; then
          add_test "$name" "$test_file" "names '$token' of $origin (uses changed $via)"
        else
          add_test "$name" "$test_file" "names '$token' of changed $origin"
        fi
      done <<<"${token_files[$token]}"
    done < <(
      {
        ((${#sub_tokens[@]})) && printf '%s\n' "${!sub_tokens[@]}" |
          grep -oHF -f - -- "${test_files[@]}"
        ((${#word_tokens[@]})) && printf '%s\n' "${!word_tokens[@]}" |
          grep -oHFw -f - -- "${test_files[@]}"
      } | LC_ALL=C sort -u
    )
  fi

  for name in "${SAFETY_SET[@]}"; do
    [[ -f $TESTS_DIR/$name.sh ]] && add_test "$name" "$TESTS_DIR/$name.sh" "safety set"
  done
}

if [[ -n $affected ]]; then
  select_affected "$affected"
fi
for arg in "${args[@]}"; do
  select_arg "$arg"
done
if ((${#args[@]} == 0)) && [[ -z $affected ]]; then
  while IFS= read -r file; do
    add_test "$(basename "$file" .sh)" "$file" "all tests"
  done < <(all_tests)
fi
((${#selected[@]})) || die "no test selected" 0

# ---------------------------------------------------------------------------
# Order: tests without a recorded duration first, then the longest first.

declare -A DURATION=()
if [[ -r $durations ]]; then
  while IFS=$'\t' read -r name seconds; do
    [[ -n $name && $seconds =~ ^[0-9]+(\.[0-9]+)?$ ]] && DURATION[$name]=$seconds
  done <"$durations"
fi

mapfile -t queue < <(
  for name in "${selected[@]}"; do
    printf '%s\t%s\n' "${DURATION[$name]:-inf}" "$name"
  done | LC_ALL=C sort -t $'\t' -k1,1gr -k2,2 | cut -f2
)

describe() { # NAME
  local more=$((REASONS_N[$1] - 3))
  printf '%s' "${REASON[$1]}"
  ((more > 0)) && printf '; and %d more' "$more"
  printf '\n'
}

if ((list_only)); then
  for name in "${queue[@]}"; do
    if ((verbose)); then
      printf '%-44s %s\n' "$name" "$(describe "$name")"
    else
      printf '%s\n' "$name"
    fi
  done
  exit 0
fi

if ((verbose)); then
  printf 'Selected %d tests:\n' "${#queue[@]}"
  for name in "${queue[@]}"; do
    printf '  %-44s %s\n' "$name" "$(describe "$name")"
  done
fi

# ---------------------------------------------------------------------------
# Running

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prokop-tests.XXXXXX")" || die "cannot create a log directory" 1

# The host paths a test must not change (see the header). A directory at /
# counts by name: what changes in it is the system's.
HOST_ROOT=${PROKOP_TEST_HOST_ROOT:-}
HOST_PATHS=(etc/prokop etc/prokop-backups etc/config etc/sing-box etc/crontabs
  etc/opkg etc/apk etc/rc.d etc/uci-defaults etc/hotplug.d
  etc/init.d/prokop etc/init.d/prokop-killswitch etc/init.d/prokop-torrserver-direct
  etc/init.d/sing-box usr/bin/prokop usr/lib/prokop usr/share/prokop
  usr/libexec/prokop-ro run/prokop var/run/prokop tmp/.uci)

host_state() {
  local path
  local -a paths=()
  for path in "${HOST_PATHS[@]}"; do
    [[ -e $HOST_ROOT/$path || -L $HOST_ROOT/$path ]] && paths+=("$HOST_ROOT/$path")
  done
  {
    find "${HOST_ROOT:-/}" -mindepth 1 -maxdepth 1 -type d -printf '%p %y\n'
    find "${HOST_ROOT:-/}" -mindepth 1 -maxdepth 1 ! -type d -printf '%p %y %s %T@\n'
    ((${#paths[@]})) && find "${paths[@]}" -printf '%p %y %s %T@\n'
    find "$HOST_ROOT/tmp" -mindepth 1 -maxdepth 1 -name 'prokop*' ! -name 'prokop-tests.*' \
      -printf '%p %y %s %T@\n'
  } 2>/dev/null | LC_ALL=C sort
}
host_before="$(host_state)"

now_us() {
  printf '%s\n' "${EPOCHREALTIME//[!0-9]/}"
}

seconds() { # MILLISECONDS -> 12.3
  printf '%d.%d' $(($1 / 1000)) $(($1 % 1000 / 100))
}

to_ms() { # 1m2.345s -> 62345
  [[ $1 =~ ^([0-9]+)m([0-9]+)[.,]([0-9]+)s$ ]] || { printf '0\n'; return; }
  local fraction="${BASH_REMATCH[3]}000"
  printf '%d\n' $((BASH_REMATCH[1] * 60000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${fraction:0:3}))
}

# Runs one test in a background subshell; writes "STATUS<TAB>EXIT<TAB>MS<TAB>CPU_MS"
# to RESULT. timeout puts the test in its own process group; on timeout or
# interrupt the whole group is signalled.
run_test() { # PATH LOG RESULT [GROUP_JOBS]
  local path=$1 log=$2 result=$3 group_jobs=${4:-} start end rc status _ user system
  local run_path=$path
  [[ $path == "$ROOT_DIR"/* ]] && run_path=${path#"$ROOT_DIR"/}
  start="$(now_us)"
  (
    cd "$ROOT_DIR" || exit 1
    if [[ -n $group_jobs ]]; then
      exec env PROKOP_TEST_GROUP_JOBS="$group_jobs" timeout -k "$KILL_GRACE" "$timeout_s" bash "$run_path"
    fi
    exec timeout -k "$KILL_GRACE" "$timeout_s" bash "$run_path"
  ) </dev/null >"$log" 2>&1 &
  printf '%s\n' "$!" >"$result.pid"
  wait "$!"
  rc=$?
  end="$(now_us)"
  rm -f "$result.pid"
  # times reports the CPU time of the waited-for children of this subshell:
  # the test and every process it waited for.
  times >"$result.times"
  { read -r _ _; read -r user system; } <"$result.times"
  case $rc in
    0) status=PASS ;;
    124 | 137) status=TIMEOUT ;;
    *) status=FAIL ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$status" "$rc" $(((end - start) / 1000)) \
    $(($(to_ms "$user") + $(to_ms "$system"))) >"$result.tmp"
  mv "$result.tmp" "$result"
}

stop_running() {
  local pidfile pid
  for pidfile in "$LOG_DIR"/*.pid; do
    [[ -e $pidfile ]] || continue
    read -r pid <"$pidfile" || continue
    kill -TERM -- "-$pid" 2>/dev/null
  done
}

on_interrupt() {
  trap - INT TERM
  printf '\nrun.sh: interrupted, stopping the running tests\n' >&2
  stop_running
  wait
  printf 'Logs: %s\n' "$LOG_DIR" >&2
  exit 130
}
trap on_interrupt INT TERM

declare -A STATUS=() EXIT_CODE=() ELAPSED=() CPU=() FIRST_STATUS=() FIRST_EXIT=()

read_result() { # NAME RESULT
  local status rc ms cpu
  IFS=$'\t' read -r status rc ms cpu <"$2" || { status=FAIL; rc=255; ms=0; cpu=0; }
  STATUS[$1]=$status
  EXIT_CODE[$1]=$rc
  ELAPSED[$1]=$ms
  CPU[$1]=$((${CPU[$1]:-0} + cpu))
}

label() { # STATUS EXIT_CODE
  case $1 in
    TIMEOUT) printf 'TIMEOUT after %ss' "$timeout_s" ;;
    FAIL) printf 'FAIL (exit %s)' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

total=${#queue[@]}
if ((jobs_n > total)); then jobs_n=$total; fi
# A test that runs groups of its cases at once (tests/helpers/case_groups.sh)
# runs only a few of them while other tests run beside it: the CPUs are
# shared already, and an overloaded host fails the tests that bound a wait.
# More groups for the longest test made the run no shorter on a loaded host,
# and the tests that bound a wait then failed.
group_jobs=${PROKOP_TEST_GROUP_JOBS:-}
if [[ -z $group_jobs ]] && ((jobs_n > 1)); then
  group_jobs=$(((cpus * 2 + jobs_n - 1) / jobs_n))
  ((group_jobs >= 2)) || group_jobs=2
fi
printf 'Running %d tests, %d at a time, timeout %ss; logs in %s\n' "$total" "$jobs_n" "$timeout_s" "$LOG_DIR"

wall_start="$(now_us)"
declare -A PID_NAME=()
running=0
started=0
finished=0
while ((started < total || running > 0)); do
  while ((started < total && running < jobs_n)); do
    name=${queue[started]}
    run_test "${TEST_PATH[$name]}" "$LOG_DIR/$name.log" "$LOG_DIR/$name.result" "$group_jobs" &
    started=$((started + 1))
    PID_NAME[$!]=$name
    running=$((running + 1))
  done
  done_pid=""
  wait -n -p done_pid
  wait_rc=$?
  if [[ -z $done_pid ]] && ((wait_rc == 127)); then
    die "lost track of the running tests" 1
  fi
  [[ -n $done_pid && -n ${PID_NAME[$done_pid]+set} ]] || continue
  name=${PID_NAME[$done_pid]}
  unset 'PID_NAME[$done_pid]'
  running=$((running - 1))
  finished=$((finished + 1))
  read_result "$name" "$LOG_DIR/$name.result"
  FIRST_STATUS[$name]=${STATUS[$name]}
  FIRST_EXIT[$name]=${EXIT_CODE[$name]}
  printf '[%*d/%d] %-7s %6ss  %s\n' "${#total}" "$finished" "$total" "${STATUS[$name]}" \
    "$(seconds "${ELAPSED[$name]}")" "$name"
done

failed=()
for name in "${queue[@]}"; do
  [[ ${STATUS[$name]} == PASS ]] || failed+=("$name")
done

# Durations of the parallel pass feed the next run's order, averaged with the
# cached ones: one run on a loaded host does not reorder the next. A test that
# timed out counts with the timeout.
update_durations() {
  local dir tmp name ms
  dir="$(dirname "$durations")"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "$durations.XXXXXX" 2>/dev/null)" || return 0
  {
    [[ -r $durations ]] && cat "$durations"
    for name in "${queue[@]}"; do
      ms=${ELAPSED[$name]}
      [[ ${STATUS[$name]} == TIMEOUT ]] && ms=$((timeout_s * 1000))
      printf '%s\t%s\n' "$name" "$(seconds "$ms")"
    done
  } | awk -F '\t' 'NF == 2 { if ($1 in d) d[$1] = sprintf("%.1f", (d[$1] + $2) / 2); else d[$1] = $2 }
      END { for (n in d) print n "\t" d[n] }' |
    LC_ALL=C sort >"$tmp"
  mv "$tmp" "$durations" 2>/dev/null || rm -f "$tmp"
}
update_durations

flaky=()
if ((rerun)) && ((${#failed[@]})); then
  printf '\nRe-running %d failed test(s) one at a time\n' "${#failed[@]}"
  for name in "${failed[@]}"; do
    run_test "${TEST_PATH[$name]}" "$LOG_DIR/$name.rerun.log" "$LOG_DIR/$name.rerun.result" "${PROKOP_TEST_GROUP_JOBS:-}" &
    wait "$!"
    read_result "$name" "$LOG_DIR/$name.rerun.result"
    printf 'rerun   %-7s %6ss  %s\n' "${STATUS[$name]}" "$(seconds "${ELAPSED[$name]}")" "$name"
  done
  still=()
  for name in "${failed[@]}"; do
    if [[ ${STATUS[$name]} == PASS ]]; then flaky+=("$name"); else still+=("$name"); fi
  done
  failed=("${still[@]}")
fi
wall_ms=$((($(now_us) - wall_start) / 1000))
host_changes="$(diff <(printf '%s\n' "$host_before") <(host_state) | grep '^[<>]')"

# ---------------------------------------------------------------------------
# Summary

tail_log() { # LOG
  printf '    --- %s (last %d lines) ---\n' "$1" "$LOG_TAIL"
  tail -n "$LOG_TAIL" "$1" | sed 's/^/    /'
}

test_ms=0
cpu_ms=0
for name in "${queue[@]}"; do
  test_ms=$((test_ms + ${ELAPSED[$name]}))
  cpu_ms=$((cpu_ms + ${CPU[$name]:-0}))
done

printf '\nSlowest tests (first run, wall / cpu):\n'
for name in "${queue[@]}"; do
  [[ ${FIRST_STATUS[$name]} == PASS ]] || continue
  printf '%s\t%s\n' "${ELAPSED[$name]}" "$name"
done | LC_ALL=C sort -t $'\t' -k1,1nr | head -n "$SLOWEST" |
  while IFS=$'\t' read -r ms name; do
    printf '  %7ss %7ss  %s\n' "$(seconds "$ms")" "$(seconds "${CPU[$name]:-0}")" "$name"
  done

if ((${#flaky[@]})); then
  printf '\n!!! FLAKY: %d test(s) failed in parallel and passed alone:\n' "${#flaky[@]}"
  for name in "${flaky[@]}"; do
    printf '  FLAKY %s: first run %s\n' "$name" "$(label "${FIRST_STATUS[$name]}" "${FIRST_EXIT[$name]}")"
    tail_log "$LOG_DIR/$name.log"
  done
fi

if ((${#failed[@]})); then
  printf '\nFAILED: %d test(s):\n' "${#failed[@]}"
  for name in "${failed[@]}"; do
    printf '  FAIL %s: %s\n' "$name" "$(label "${STATUS[$name]}" "${EXIT_CODE[$name]}")"
    if ((rerun)); then
      tail_log "$LOG_DIR/$name.rerun.log"
      printf '    (parallel-run log: %s)\n' "$LOG_DIR/$name.log"
    else
      tail_log "$LOG_DIR/$name.log"
    fi
  done
fi

passed=$((total - ${#failed[@]} - ${#flaky[@]}))
printf '\nPASS %d  FLAKY %d  FAIL %d  of %d tests | wall %ss | test time %ss | CPU %ss | jobs %d\n' \
  "$passed" "${#flaky[@]}" "${#failed[@]}" "$total" "$(seconds "$wall_ms")" \
  "$(seconds "$test_ms")" "$(seconds "$cpu_ms")" "$jobs_n"
printf 'Logs: %s\n' "$LOG_DIR"
((${#flaky[@]})) && printf '!!! %d FLAKY test(s) above: they pass alone but failed in parallel\n' "${#flaky[@]}"

# "<" is the host before the run, ">" after it.
if [[ -n $host_changes ]]; then
  printf '\nHOST CHANGED: the host paths below changed while the tests ran; a test\n'
  printf 'wrote outside its temporary directory (or another process wrote there):\n'
  printf '%s\n' "$host_changes" | sed 's/^/  /'
fi

((${#failed[@]} == 0)) && [[ -z $host_changes ]]
