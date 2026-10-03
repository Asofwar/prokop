#!/usr/bin/env bash
# Local parallel test runner for Forkop (Linux or WSL).
#
# Independent lanes run concurrently and are aggregated into one result:
#   backend   tests/*.sh in a job pool, longest test first
#   syntax    ucode -c and ucode -S -c for forkop/files/usr/lib/**/*.uc
#   shell     shellcheck --severity=error over the CI file set
#   frontend  prettier --check, eslint, vitest, tsc --noEmit (fe-app-forkop)
#
# The backend and static lanes run on a fresh copy of the working tree on the
# native Linux filesystem: /mnt/c (9p) is several times slower and serialises
# parallel file access. The copy is rebuilt on every run, so nothing from a
# previous run can mask a failure.
#
# Every backend test runs in its own user, mount, pid and network namespace
# with a private tmpfs /tmp and no capabilities. Fixed /tmp paths, leaked
# background processes and accidental real nft/ip/uci calls therefore cannot
# collide between tests or reach the host network or the router.
#
# CI keeps its own sequential loop (.github/workflows/backend-ci.yml).
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: tests/runner/run.sh [options] [test ...]

Modes:
  (default)          all lanes, maximum safe parallelism
  --serial           one backend test at a time, lanes one after another
  --lanes LIST       comma-separated subset of: backend,syntax,shell,frontend
                     (static = syntax,shell)
  test ...           backend tests only, by name (nft_apply, nft_apply.sh)
                     or glob (autotune_*)

Options:
  -j, --jobs N       backend workers (default: auto, FORKOP_TEST_JOBS)
  --repeat N         run every selected backend test N times (flake hunting)
  --timeout SEC      per-test timeout (default 600, FORKOP_TEST_TIMEOUT)
  --in-place         run from the working tree instead of a native-fs copy
  --no-isolate       no namespaces; each test still gets a private TMPDIR
  -v, --verbose      print every finished test, not only failures
  --list             print the backend tests in scheduling order and exit
  -h, --help         this help

Logs and timings: ${FORKOP_TEST_CACHE:-~/.cache/forkop-tests}/last
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_DIR="${FORKOP_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/forkop-tests}"
TIMINGS="$CACHE_DIR/timings.tsv"
NPROC="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

JOBS="${FORKOP_TEST_JOBS:-auto}"
TIMEOUT="${FORKOP_TEST_TIMEOUT:-600}"
REPEAT=1
LANES="backend,syntax,shell,frontend"
SERIAL=0
IN_PLACE=0
ISOLATE=1
VERBOSE=0
LIST_ONLY=0
SELECTED=()

while [ $# -gt 0 ]; do
  case "$1" in
    -j|--jobs) JOBS="${2:?}"; shift ;;
    -j*) JOBS="${1#-j}" ;;
    --jobs=*) JOBS="${1#*=}" ;;
    --serial) SERIAL=1 ;;
    --lanes) LANES="${2:?}"; shift ;;
    --lanes=*) LANES="${1#*=}" ;;
    --repeat) REPEAT="${2:?}"; shift ;;
    --timeout) TIMEOUT="${2:?}"; shift ;;
    --in-place) IN_PLACE=1 ;;
    --no-isolate) ISOLATE=0 ;;
    -v|--verbose) VERBOSE=1 ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) SELECTED+=("${1%.sh}") ;;
  esac
  shift
done

LANES="${LANES//static/syntax,shell}"
[ ${#SELECTED[@]} -gt 0 ] && LANES="backend"
lane_enabled() { case ",$LANES," in *",$1,"*) return 0 ;; esac; return 1; }

# The backend suite waits far more than it computes (~2% CPU sequentially):
# wall time is bounded by the longest test once the long tests start first.
# Measured on 16 CPUs, 4..64 workers all finish in the same time, so one
# worker per CPU leaves headroom without extra memory or scheduling churn.
if [ "$SERIAL" = 1 ]; then
  JOBS=1
elif [ "$JOBS" = auto ]; then
  JOBS="$NPROC"
fi
case "$JOBS" in ''|*[!0-9]*|0) printf 'invalid job count: %s\n' "$JOBS" >&2; exit 2 ;; esac

# --- backend test selection and order -------------------------------------

all_tests() {
  local f
  for f in "$ROOT"/tests/*.sh; do
    [ -f "$f" ] && basename "$f" .sh
  done
}

select_tests() {
  local name pattern matched
  if [ ${#SELECTED[@]} -eq 0 ]; then
    all_tests
    return
  fi
  for pattern in "${SELECTED[@]}"; do
    matched=0
    while IFS= read -r name; do
      # shellcheck disable=SC2053 # the pattern is a glob on purpose
      if [[ "$name" == $pattern ]]; then
        printf '%s\n' "$name"
        matched=1
      fi
    done < <(all_tests)
    [ "$matched" = 1 ] || { printf 'no backend test matches: %s\n' "$pattern" >&2; return 1; }
  done
}

# Longest known duration first so the long poles start immediately; tests
# without history (new ones) go first as well. Timings only affect order.
order_tests() {
  awk -F'\t' -v timings="$TIMINGS" '
    BEGIN { while ((getline line < timings) > 0) { split(line, f, "\t"); ms[f[1]] = f[2] } }
    NF && !seen[$0]++ { printf "%d\t%s\n", ($0 in ms) ? ms[$0] : 999999999, $0 }
  ' | sort -t "$(printf '\t')" -k1,1nr -k2,2 | cut -f2
}

SELECTION="$(select_tests)" || exit 2
mapfile -t TESTS < <(printf '%s\n' "$SELECTION" | order_tests)
if [ "$SERIAL" = 1 ]; then
  mapfile -t TESTS < <(printf '%s\n' "${TESTS[@]}" | sort)
fi

if [ "$LIST_ONLY" = 1 ]; then
  printf '%s\n' "${TESTS[@]}"
  exit 0
fi

# --- run directory, tree copy ----------------------------------------------

mkdir -p "$CACHE_DIR"
RUN_DIR="$(mktemp -d "$CACHE_DIR/run.XXXXXX")"
OUT="$RUN_DIR/out"
mkdir -p "$OUT/logs" "$OUT/status" "$OUT/lanes" "$OUT/tmp"

# Killing unshare makes it SIGKILL the namespace, so no test outlives the run.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$1" 2>/dev/null
}

cleanup() {
  local rc=$? pid
  trap - EXIT INT TERM
  for pid in $(jobs -p); do
    kill_tree "$pid"
  done
  wait 2>/dev/null
  rm -rf "$CACHE_DIR/last"
  mv "$OUT" "$CACHE_DIR/last" 2>/dev/null
  rm -rf "$RUN_DIR"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

now_ms() { local t; t="$(date +%s%N)"; printf '%s\n' "$((t / 1000000))"; }
fmt_ms() { awk -v ms="$1" 'BEGIN { printf "%.1fs", ms / 1000 }'; }

T_START="$(now_ms)"

if [ "$IN_PLACE" = 0 ] && ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'warning: not a git checkout, running in place\n' >&2
  IN_PLACE=1
fi

if [ "$IN_PLACE" = 1 ]; then
  TREE="$ROOT"
else
  TREE="$RUN_DIR/tree"
  mkdir -p "$TREE"
  # Tracked and untracked-but-not-ignored files: exactly what a commit of the
  # current working tree would test. Deleted tracked files are skipped.
  (cd "$ROOT" && git ls-files -z -c -o --exclude-standard |
    tar --null -T - --ignore-failed-read -cf - 2>"$OUT/tree-copy.log") |
    tar -xf - -C "$TREE" || { printf 'failed to copy the working tree\n' >&2; exit 1; }
  # Tests that read history (git archive of the stable tag) use the real repo.
  printf 'gitdir: %s\n' "$(git -C "$ROOT" rev-parse --absolute-git-dir)" >"$TREE/.git"
fi

# --- isolation ---------------------------------------------------------------

# PID 1 of the namespace: private /tmp, loopback only, then the test without
# any capability. When PID 1 exits the kernel kills everything the test left.
NS_INIT='
mount -t tmpfs -o mode=1777 forkop-test-tmp /tmp || exit 125
mkdir -p /tmp/home
ip link set lo up 2>/dev/null
HOME=/tmp/home setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-all -- bash "$1" &
wait "$!"
'
NS_CMD=(unshare --user --map-current-user --mount --pid --fork --mount-proc --net --kill-child --keep-caps)

if [ "$ISOLATE" = 1 ] && ! "${NS_CMD[@]}" bash -c "$NS_INIT" forkop-ns /dev/null >/dev/null 2>&1; then
  printf 'warning: user namespaces unavailable, falling back to --no-isolate\n' >&2
  ISOLATE=0
fi

run_test() {
  local name="$1" tmp="$OUT/tmp/$2"
  if [ "$ISOLATE" = 1 ]; then
    timeout -k 10 "$TIMEOUT" "${NS_CMD[@]}" bash -c "$NS_INIT" forkop-ns "$TREE/tests/$name.sh"
  else
    mkdir -p "$tmp"
    TMPDIR="$tmp" timeout -k 10 "$TIMEOUT" bash "$TREE/tests/$name.sh"
    local rc=$?
    rm -rf "$tmp"
    return "$rc"
  fi
}

# --- lanes -------------------------------------------------------------------

lane_result() { printf '%s\t%s\t%s\n' "$2" "$3" "${4:-}" >"$OUT/lanes/$1"; }

run_one() {
  local name="$1" id="$2" start rc dur label=""
  start="$(now_ms)"
  run_test "$name" "$id" >"$OUT/logs/$id.log" 2>&1
  rc=$?
  dur=$(($(now_ms) - start))
  printf '%s\t%s\t%s\n' "$name" "$rc" "$dur" >"$OUT/status/$id"
  [ "$rc" = 124 ] && label=" (timeout ${TIMEOUT}s)"
  if [ "$rc" != 0 ]; then
    printf 'FAIL  %7s  %s%s\n' "$(fmt_ms "$dur")" "$id" "$label"
  elif [ "$VERBOSE" = 1 ]; then
    printf 'ok    %7s  %s\n' "$(fmt_ms "$dur")" "$id"
  fi
}

# Tests that inspect host-wide state (e.g. count every sing-box in /proc).
# A pid namespace makes them safe to run alongside the rest; without one
# they run alone after the pool.
HOST_STATE_TESTS=" singbox_stale_procd_pid "

lane_backend() {
  local start running=0 name r id failed exclusive=()
  start="$(now_ms)"
  for ((r = 1; r <= REPEAT; r++)); do
    for name in "${TESTS[@]}"; do
      id="$name"
      [ "$REPEAT" -gt 1 ] && id="$name.$r"
      if [ "$ISOLATE" = 0 ] && [[ "$HOST_STATE_TESTS" == *" $name "* ]]; then
        exclusive+=("$name" "$id")
        continue
      fi
      while [ "$running" -ge "$JOBS" ]; do
        wait -n
        running=$((running - 1))
      done
      run_one "$name" "$id" &
      running=$((running + 1))
    done
  done
  wait
  for ((r = 0; r < ${#exclusive[@]}; r += 2)); do
    run_one "${exclusive[r]}" "${exclusive[r + 1]}"
  done
  failed="$(cat "$OUT"/status/* 2>/dev/null | awk -F'\t' '$1 !~ /^frontend-/ && $2 != 0' | wc -l)"
  lane_result backend "$([ "$failed" = 0 ] && echo PASS || echo FAIL)" "$(($(now_ms) - start))" \
    "$((${#TESTS[@]} * REPEAT)) runs, $failed failed, $JOBS workers"
}

uc_files() { find "$TREE/forkop/files/usr/lib" -name '*.uc' -print0; }

lane_syntax() {
  local start rc=0
  start="$(now_ms)"
  if ! command -v ucode >/dev/null 2>&1; then
    lane_result syntax SKIP 0 "ucode not installed"
    return
  fi
  {
    uc_files | xargs -0 -n1 -P "$NPROC" ucode -c -o /dev/null || rc=1
    uc_files | xargs -0 -n1 -P "$NPROC" ucode -S -c -o /dev/null || rc=1
  } >"$OUT/logs/lane-syntax.log" 2>&1
  lane_result syntax "$([ "$rc" = 0 ] && echo PASS || echo FAIL)" "$(($(now_ms) - start))" \
    "$(uc_files | tr -cd '\0' | wc -c) files x2"
}

lane_shell() {
  local start rc=0 scripts
  start="$(now_ms)"
  if ! command -v shellcheck >/dev/null 2>&1; then
    lane_result shell SKIP 0 "shellcheck not installed"
    return
  fi
  # Same selection as .github/workflows/shellcheck.yml.
  mapfile -d '' scripts < <(cd "$TREE" && find . -type f \
    \( -name '*.sh' -o -path './build.sh' -o -path './install.sh' \
       -o -path './forkop/files/etc/init.d/*' \
       -o -path './luci-app-forkop/root/etc/uci-defaults/*' \) -print0)
  (cd "$TREE" && printf '%s\0' "${scripts[@]}" |
    xargs -0 -n4 -P "$NPROC" shellcheck --severity=error) >"$OUT/logs/lane-shell.log" 2>&1 || rc=1
  lane_result shell "$([ "$rc" = 0 ] && echo PASS || echo FAIL)" "$(($(now_ms) - start))" \
    "${#scripts[@]} files"
}

find_frontend_node() {
  local fe="$1"
  if [ -d "$fe/node_modules/@esbuild/linux-x64" ] && command -v node >/dev/null 2>&1; then
    command -v node
  elif grep -qi microsoft /proc/version 2>/dev/null && [ -d "$fe/node_modules/@esbuild/win32-x64" ]; then
    # node_modules were installed by Windows node; call it through WSL interop.
    command -v node.exe 2>/dev/null ||
      { [ -x "/mnt/c/Program Files/nodejs/node.exe" ] && echo "/mnt/c/Program Files/nodejs/node.exe"; }
  fi
}

frontend_check() {
  local name="$1" start rc
  shift
  start="$(now_ms)"
  (cd "$ROOT/fe-app-forkop" && "$@") >"$OUT/logs/frontend-$name.log" 2>&1
  rc=$?
  printf '%s\t%s\t%s\n' "frontend-$name" "$rc" "$(($(now_ms) - start))" >"$OUT/status/frontend-$name"
  [ "$rc" = 0 ] || printf 'FAIL  %7s  frontend-%s\n' "$(fmt_ms "$(($(now_ms) - start))")" "$name"
}

lane_frontend() {
  local start fe="$ROOT/fe-app-forkop" node failed
  start="$(now_ms)"
  if [ ! -d "$fe/node_modules" ]; then
    lane_result frontend SKIP 0 "fe-app-forkop/node_modules missing (yarn install)"
    return
  fi
  node="$(find_frontend_node "$fe")"
  if [ -z "$node" ]; then
    lane_result frontend SKIP 0 "no node matching the installed node_modules platform"
    return
  fi
  # Read-only equivalents of the CI steps; the build step is not run because
  # it rewrites the committed LuCI bundle.
  frontend_check prettier "$node" node_modules/prettier/bin/prettier.cjs --check src &
  frontend_check eslint "$node" node_modules/eslint/bin/eslint.js src --ext .ts,.tsx --max-warnings=0 --concurrency=auto &
  frontend_check vitest "$node" node_modules/vitest/vitest.mjs run &
  frontend_check tsc "$node" node_modules/typescript/bin/tsc --noEmit &
  wait
  failed="$(cat "$OUT"/status/frontend-* | awk -F'\t' '$2 != 0' | wc -l)"
  lane_result frontend "$([ "$failed" = 0 ] && echo PASS || echo FAIL)" "$(($(now_ms) - start))" \
    "prettier, eslint, vitest, tsc"
}

# --- resource sampling ---------------------------------------------------------

cpu_sample() { awk '/^cpu /{ print $2+$3+$4+$7+$8, $5+$6 } /^ctxt /{ print $2 }' /proc/stat | paste -sd' '; }
mem_used_mb() { awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ print int((t-a)/1024) }' /proc/meminfo; }

sample_memory() {
  local peak=0 cur
  while :; do
    cur="$(mem_used_mb)"
    [ "$cur" -gt "$peak" ] && { peak="$cur"; echo "$peak" >"$OUT/mem-peak"; }
    sleep 0.5
  done
}

# --- main ----------------------------------------------------------------------

read -r BUSY0 IDLE0 CTXT0 < <(cpu_sample)
MEM0="$(mem_used_mb)"
sample_memory &
SAMPLER=$!

printf 'forkop tests: %d backend x%d, %d workers, %d CPUs, lanes %s%s%s\n' \
  "${#TESTS[@]}" "$REPEAT" "$JOBS" "$NPROC" "$LANES" \
  "$([ "$ISOLATE" = 1 ] && echo ', isolated' || echo ', not isolated')" \
  "$([ "$IN_PLACE" = 1 ] && echo ', in place' || echo ', native-fs copy')"

LANE_PIDS=()
for lane in backend syntax shell frontend; do
  lane_enabled "$lane" || continue
  # A lane is a subshell so its own `wait` never waits for the sampler.
  "lane_$lane" &
  if [ "$SERIAL" = 1 ]; then
    wait "$!"
  else
    LANE_PIDS+=("$!")
  fi
done
[ ${#LANE_PIDS[@]} -gt 0 ] && wait "${LANE_PIDS[@]}"

kill "$SAMPLER" 2>/dev/null
wait "$SAMPLER" 2>/dev/null
read -r BUSY1 IDLE1 CTXT1 < <(cpu_sample)
WALL=$(($(now_ms) - T_START))

# Remember durations for the next run's ordering (single runs only).
if [ "$REPEAT" = 1 ] && compgen -G "$OUT/status/*" >/dev/null; then
  {
    cat "$OUT"/status/* | awk -F'\t' '$1 !~ /^frontend-/ { print $1 "\t" $3 }'
    [ -f "$TIMINGS" ] && cat "$TIMINGS"
  } | awk -F'\t' '!seen[$1]++' >"$TIMINGS.new" && mv "$TIMINGS.new" "$TIMINGS"
fi

# --- report --------------------------------------------------------------------

STATUS=0
printf '\n%-9s %-5s %8s  %s\n' LANE RESULT TIME DETAIL
for lane in backend syntax shell frontend; do
  lane_enabled "$lane" || continue
  if [ ! -f "$OUT/lanes/$lane" ]; then
    printf '%-9s %-5s %8s  %s\n' "$lane" FAIL - "lane did not finish"
    STATUS=1
    continue
  fi
  IFS=$'\t' read -r result ms detail <"$OUT/lanes/$lane"
  printf '%-9s %-5s %8s  %s\n' "$lane" "$result" "$(fmt_ms "$ms")" "$detail"
  [ "$result" = FAIL ] && STATUS=1
done

for lane in syntax shell; do
  if [ -f "$OUT/lanes/$lane" ] && grep -q '^FAIL' "$OUT/lanes/$lane"; then
    printf '\n--- %s ---\n' "$lane"
    tail -n 40 "$OUT/logs/lane-$lane.log"
  fi
done

if compgen -G "$OUT/status/*" >/dev/null; then
  while IFS=$'\t' read -r id rc; do
    printf '\n--- %s (exit %s) ---\n' "$id" "$rc"
    tail -n 30 "$OUT/logs/$id.log"
  done < <(for f in "$OUT"/status/*; do
             awk -F'\t' -v id="${f##*/}" '$2 != 0 { print id "\t" $2 }' "$f"
           done)
  if [ "$REPEAT" -gt 1 ]; then
    printf '\nflaky / failing tests over %d repeats:\n' "$REPEAT"
    cat "$OUT"/status/* | awk -F'\t' '$1 !~ /^frontend-/ { n[$1]++; if ($2 != 0) f[$1]++ }
      END { for (t in f) printf "  %s: %d/%d failed\n", t, f[t], n[t]; if (length(f) == 0) print "  none" }'
  fi
  printf '\nslowest:'
  cat "$OUT"/status/* | sort -t "$(printf '\t')" -k3,3nr | head -n 5 |
    awk -F'\t' '{ printf "  %s %.1fs", $1, $3 / 1000 }'
  printf '\n'
fi

BUSY=$((BUSY1 - BUSY0))
IDLE=$((IDLE1 - IDLE0))
awk -v w="$WALL" -v b="$BUSY" -v i="$IDLE" -v c=$((CTXT1 - CTXT0)) -v n="$NPROC" \
    -v m0="$MEM0" -v mp="$(cat "$OUT/mem-peak" 2>/dev/null || echo "$MEM0")" 'BEGIN {
  util = (b + i) > 0 ? 100 * b / (b + i) : 0
  printf "\nwall %.1fs | cpu %.0f%% of %d CPUs (%.1f cores avg) | ctx switches %.0f/s | mem peak %d MiB (+%d)\n",
    w / 1000, util, n, util * n / 100, c / (w / 1000), mp, mp - m0
}'
printf 'logs: %s\n' "$CACHE_DIR/last"
printf '%s\n' "$([ "$STATUS" = 0 ] && echo 'RESULT: PASS' || echo 'RESULT: FAIL')"
exit "$STATUS"
