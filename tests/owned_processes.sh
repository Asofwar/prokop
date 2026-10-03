#!/usr/bin/env bash
set -euo pipefail

# Tests signal only their own processes (UC-233).
#
# A test stores the PID of a process it starts and signals that PID later:
# when it cleans up, between its cases, or after the code under test may
# already have ended the process. By then the number can name another
# process: PIDs are reused once a process has exited and been reaped, and
# under tests/run.sh that is often a process of another test. A cleanup that
# ran `kill -KILL -- "-$pid" || kill -KILL "$pid"`, `pkill -P "$pid"` or
# `kill "$pid" 2>/dev/null || true` killed that process, or its whole process
# group; deferred_start_retry killed a process of worker_pid_reuse so.
#
# tests/helpers/owned_processes.sh signals a PID, its process group or its
# children only while they carry the mark of the test or are children of the
# shell that signals, checked right before the signal. Part 1 holds the
# helper against processes under PIDs the test stored that are not its own
# (what a stored PID names once the number was reused): a host process, a
# process and a process group of another test. Part 2 checks that no test
# signals a stored PID the old way, and that the helper is loaded wherever a
# test or a stand-in it writes calls it.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

WORK_DIR="$(mktemp -d)"
OWN_MARK="$PROKOP_TEST_OWNER"
# The processes of "another test" carry a mark of their own.
OTHER_MARK="other-$OWN_MARK"
OTHERS=()
OWN=()
cleanup() {
  PROKOP_TEST_OWNER="$OTHER_MARK" owned_kill KILL "${OTHERS[@]}" || true
  PROKOP_TEST_OWNER="$OWN_MARK" owned_kill KILL "${OWN[@]}" || true
  # The host processes end with the work directory.
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck disable=SC2016 # expanded by the sh that runs it
GATE_LOOP='while [ -d "$1" ]; do sleep 0.1; done'
# PAIR_LOOP: a gate loop with a child that runs as long as it does (the
# loop's own sleeps come and go): sh -c "$PAIR_LOOP" NAME "$GATE_LOOP" DIR.
# shellcheck disable=SC2016
PAIR_LOOP='sh -c "$1" "$0-child" "$2" & while [ -d "$2" ]; do sleep 0.1; done'
# A group whose leader exits at once and leaves a member behind.
# shellcheck disable=SC2016
ORPHANING='(while [ -d "$1" ]; do sleep 0.1; done) & exit 0'
# sh -c "$ORPHAN" orphan COMMAND...: starts COMMAND through a shell that
# exits at once, so that it is no child of the test's shell, in the
# environment of that shell, and prints its PID.
# shellcheck disable=SC2016
ORPHAN='"$@" </dev/null >/dev/null 2>&1 & echo "$!"'
SH_EXE="$(basename "$(readlink -f /bin/sh)")"
running() { process_running "$1"; }
carries_mark() {
  local environ
  environ="$(tr '\0' '\n' <"/proc/$1/environ")" || return 1
  case "$environ" in *"PROKOP_TEST_OWNER=$2"*) return 0 ;; esac
  return 1
}
group_members() { pgrep -g "$1" 2>/dev/null | while read -r pid; do process_running "$pid" && echo "$pid"; done; }
group_size() { group_members "$1" | wc -l; }
# wait_until runs a command again on every attempt; the value of a $(...)
# among its arguments is taken once, before the first.
group_has() { [ "$(group_size "$1")" -ge "$2" ]; }
group_empty() { [ "$(group_size "$1")" -eq 0 ]; }
# pair_child PID: PAIR_CHILD is the child of a PAIR_LOOP, told by its argv: a
# fork of PID not yet exec'd shows the argv of PID.
pair_child() {
  local child
  for child in $(pgrep -P "$1"); do
    case "$(tr '\0' '\n' <"/proc/$child/cmdline" 2>/dev/null | sed -n 4p)" in
      *-child)
        PAIR_CHILD=$child
        return 0
        ;;
    esac
  done
  return 1
}

# --- Part 1: the helper ------------------------------------------------------

# 1. A stored PID that names a host process: neither the process, nor its
#    children, nor a group of that number is signalled.
HOST="$(env -u PROKOP_TEST_OWNER sh -c "$ORPHAN" orphan sh -c "$PAIR_LOOP" host "$GATE_LOOP" "$WORK_DIR")"
wait_until 10 process_exec_is "$HOST" "$SH_EXE" || fail "a host process did not start"
wait_until 10 pair_child "$HOST" || fail "the host process did not start its child"
HOST_CHILD=$PAIR_CHILD
owned_process "$HOST" && fail "a host process counts as the test's"
owned_process "$HOST_CHILD" && fail "the child of a host process counts as the test's"
if owned_kill KILL "$HOST"; then fail "owned_kill reported a host process as signalled"; fi
owned_kill_children KILL "$HOST"
sleep 0.2
running "$HOST" || fail "owned_kill signalled a host process"
running "$HOST_CHILD" || fail "owned_kill_children signalled the child of a host process"

# 2. A stored PID that names a process of another test, and a stored number
#    that is the process group of another test (started under setsid, like
#    the actors of the lifecycle tests), with its leader alive or gone.
OTHER="$(PROKOP_TEST_OWNER="$OTHER_MARK" sh -c "$ORPHAN" orphan sh -c "$GATE_LOOP" other "$WORK_DIR")"
OTHER_GROUP="$(PROKOP_TEST_OWNER="$OTHER_MARK" sh -c "$ORPHAN" orphan \
  setsid sh -c "$PAIR_LOOP" other-group "$GATE_LOOP" "$WORK_DIR")"
ORPHANED_GROUP="$(PROKOP_TEST_OWNER="$OTHER_MARK" sh -c "$ORPHAN" orphan setsid sh -c "$ORPHANING" orphaned "$WORK_DIR")"
OTHERS+=("$OTHER" "$OTHER_GROUP" "$ORPHANED_GROUP")
wait_until 10 process_gone "$ORPHANED_GROUP" || fail "the leader of another test's group did not exit"
wait_until 10 pair_child "$OTHER_GROUP" || fail "another test's process group did not start"
OTHER_MEMBER=$PAIR_CHILD
wait_until 10 group_has "$ORPHANED_GROUP" 1 || fail "another test's leaderless group did not start"
for pid in "$OTHER" "$OTHER_GROUP" "$ORPHANED_GROUP"; do
  if owned_kill KILL "$pid"; then fail "owned_kill reported a process or group of another test ($pid) as signalled"; fi
  owned_kill_children KILL "$pid"
done
sleep 0.2
running "$OTHER" || fail "owned_kill signalled another test's process"
running "$OTHER_GROUP" || fail "owned_kill signalled another test's process group"
running "$OTHER_MEMBER" || fail "owned_kill signalled a member of another test's process group"
[ "$(group_size "$ORPHANED_GROUP")" -ge 1 ] || fail "owned_kill signalled another test's group whose leader had exited"
# Its own mark reaches all of them, a group whose leader has exited too: the
# helper keeps what `kill -- -$pid` did for a test's own group.
PROKOP_TEST_OWNER="$OTHER_MARK" owned_kill KILL "$OTHER" "$OTHER_GROUP" "$ORPHANED_GROUP" ||
  fail "owned_kill did not signal processes under their own mark"
wait_until 10 process_gone "$OTHER" || fail "a process was not killed under its own mark"
wait_until 10 group_empty "$OTHER_GROUP" || fail "a process group was not killed under its own mark"
wait_until 10 group_empty "$ORPHANED_GROUP" || fail "a group whose leader had exited was not killed under its own mark"

# 3. The test's own processes, which are no children of its shell: a
#    process, a group whose leader has exited, and the children of a
#    process, the host's child among them left alone.
MINE="$(sh -c "$ORPHAN" orphan sleep 300)"
OWN+=("$MINE")
wait_until 10 process_exec_is "$MINE" sleep || fail "the test's process did not start"
owned_process "$MINE" || fail "the test's own process does not count as its own"
owned_kill TERM "$MINE" || fail "owned_kill did not signal the test's process"
wait_until 10 process_gone "$MINE" || fail "the test's process was not signalled"
# Its PID, once the process has exited, names nothing of the test's.
if owned_kill TERM "$MINE"; then fail "owned_kill reported a process that has exited as signalled"; fi

OWN_GROUP="$(sh -c "$ORPHAN" orphan setsid sh -c "$ORPHANING" own-orphaned "$WORK_DIR")"
OWN+=("$OWN_GROUP")
wait_until 10 process_gone "$OWN_GROUP" || fail "the leader of the test's group did not exit"
wait_until 10 group_has "$OWN_GROUP" 1 || fail "the test's leaderless group did not start"
owned_kill KILL "$OWN_GROUP" || fail "owned_kill did not signal the test's group whose leader had exited"
wait_until 10 group_empty "$OWN_GROUP" || fail "the test's group whose leader had exited survived"

# shellcheck disable=SC2016 # expanded by the parent sh
PARENT="$(sh -c "$ORPHAN" orphan sh -c 'sleep 300 & env -u PROKOP_TEST_OWNER sh -c "$1" host-child "$2" & wait' \
  parent "$GATE_LOOP" "$WORK_DIR")"
OWN+=("$PARENT")
# One child of the test's (sleep) and one of the host's (sh once env has
# exec'd it without the mark).
children_started() {
  local child marked=0 host=0
  for child in $(pgrep -P "$PARENT"); do
    if process_exec_is "$child" sleep && owned_process "$child"; then
      marked=$((marked + 1))
      MARKED_CHILD=$child
    elif process_exec_is "$child" "$SH_EXE" && ! owned_process "$child"; then
      host=$((host + 1))
      HOST_CHILD=$child
    fi
  done
  [ "$marked" = 1 ] && [ "$host" = 1 ]
}
wait_until 10 children_started || fail "the test's process did not start one child of its own and one of the host's"
owned_kill_children KILL "$PARENT"
wait_until 10 process_gone "$MARKED_CHILD" || fail "owned_kill_children did not signal the test's child"
sleep 0.2
running "$HOST_CHILD" || fail "owned_kill_children signalled a host process"
owned_kill KILL "$PARENT" || true

# 3b. A subshell job of the test's shell shows the environment of that shell,
#     from before the mark was set: it is the test's as a child of the shell
#     that signals it, and of no other shell.
(while [ -d "$WORK_DIR" ]; do sleep 0.1; done) &
JOB=$!
disown "$JOB"
OWN+=("$JOB")
carries_mark "$JOB" "$OWN_MARK" && fail "fixture: a subshell job carries the mark"
owned_process "$JOB" || fail "a subshell job of the test's shell does not count as the test's"
(owned_process "$JOB") && fail "a job of the test's shell counts as one of a subshell's"
owned_kill TERM "$JOB" || fail "owned_kill did not signal a subshell job of the test's shell"
wait_until 10 process_gone "$JOB" || fail "the subshell job was not signalled"

# 4. Never the test's own shell or a subshell of it, never a zombie, and a
#    variable that only holds the mark is no mark.
owned_process "$$" && fail "the test's own shell counts as one of its processes"
(owned_process "$BASHPID") && fail "a subshell of the test counts as one of its processes"
ZOMBIE_PARENT="$(sh -c "$ORPHAN" orphan sh -c 'sleep 0 & exec sleep 300' zombie-parent)"
OWN+=("$ZOMBIE_PARENT")
zombie_child() {
  local child state
  child="$(pgrep -P "$ZOMBIE_PARENT")" || return 1
  state="$(sed 's/.*) //' "/proc/$child/stat" | cut -d' ' -f1)"
  [ "$state" = Z ] && ZOMBIE="$child"
}
wait_until 10 zombie_child || fail "no zombie to check"
owned_process "$ZOMBIE" && fail "a zombie counts as a process of the test"
owned_kill KILL "$ZOMBIE_PARENT" || true
HOSTILE="$(env -u PROKOP_TEST_OWNER "X_PROKOP_TEST_OWNER=$OWN_MARK" "PROKOP_TEST_OWNER_COPY=$OWN_MARK" \
  sh -c "$ORPHAN" orphan sh -c "$GATE_LOOP" hostile "$WORK_DIR")"
LONGER="$(PROKOP_TEST_OWNER="${OWN_MARK}x" sh -c "$ORPHAN" orphan sh -c "$GATE_LOOP" longer "$WORK_DIR")"
wait_until 10 process_exec_is "$HOSTILE" "$SH_EXE" || fail "the process did not start"
wait_until 10 process_exec_is "$LONGER" "$SH_EXE" || fail "the process did not start"
owned_process "$HOSTILE" && fail "a process with the mark in another variable counts as the test's"
owned_process "$LONGER" && fail "a process with a longer mark counts as the test's"

# 5. A group of cases sets a mark of its own: the processes of the test
#    before it are not the group's, and the group's are not the test's.
BEFORE="$(sh -c "$ORPHAN" orphan sleep 300)"
OWN+=("$BEFORE")
wait_until 10 process_exec_is "$BEFORE" sleep || fail "the test's process did not start"
(
  owned_processes_init
  [ "$PROKOP_TEST_OWNER" != "$OWN_MARK" ] || fail "a group of cases kept the test's mark"
  owned_process "$BEFORE" && fail "a process of the test counts as the group's"
  group_process="$(sh -c "$ORPHAN" orphan sleep 300)"
  printf '%s\n' "$group_process" >"$WORK_DIR/group.pid"
  wait_until 10 process_exec_is "$group_process" sleep || fail "the group's process did not start"
  owned_process "$group_process" || fail "the group's process does not count as the group's"
)
GROUP_PROCESS="$(cat "$WORK_DIR/group.pid")"
owned_process "$GROUP_PROCESS" && fail "a process of a group of cases counts as the test's"
[ "$PROKOP_TEST_OWNER" = "$OWN_MARK" ] || fail "a group of cases changed the test's mark"
PROKOP_TEST_OWNER="$(tr '\0' '\n' <"/proc/$GROUP_PROCESS/environ" | sed -n 's/^PROKOP_TEST_OWNER=//p')" \
  owned_kill KILL "$GROUP_PROCESS" || fail "the group's process was not killed under its mark"
owned_kill KILL "$BEFORE" || fail "the test's process was not killed"

# 6. The helper loads, and sets a new mark each time, with only what a stock
#    OpenWrt BusyBox has: no od, no hexdump. tests/router/ runs on a router.
mkdir "$WORK_DIR/busybox-bin"
for tool in awk cat date tr; do ln -s "$(command -v "$tool")" "$WORK_DIR/busybox-bin/$tool"; done
# shellcheck disable=SC2016 # expanded by the sh that loads the helper
marks="$(env -u PROKOP_TEST_OWNER PATH="$WORK_DIR/busybox-bin" /bin/sh -c '
  . "$1" || exit 1
  first=$PROKOP_TEST_OWNER
  owned_processes_init || exit 1
  printf "%s %s\n" "$first" "$PROKOP_TEST_OWNER"
' sh "$ROOT_DIR/tests/helpers/owned_processes.sh" 2>&1)" || fail "the helper does not load without od and hexdump: $marks"
case "$marks" in
  *-?*" "*-?*) [ "${marks% *}" != "${marks#* }" ] || fail "the helper set the same mark twice: $marks" ;;
  *) fail "the helper set no mark without od and hexdump: $marks" ;;
esac

# --- Part 2: no test signals a stored PID the old way ------------------------

# stale_kills FILE...: the commands (with their continuation lines) that
# signal a stored PID, the process group of a stored number (with or without
# `--`), the children of a stored PID or the PIDs xargs reads, other than
# through the helper. A plain `kill "$pid"`, or one followed by `|| fail` or
# `|| exit`, fails the test if the process is gone: it is a signal under test
# sent to a process the test has just seen running, and stays. Any other
# `||` or a redirected stderr hides that the process was gone.
stale_kills() {
  awk '
    FNR == 1 { joined = "" }
    # A command with its continuation lines, reported at its first line.
    {
      if (joined == "")
        start = FNR
      if ($0 ~ /\\$/) {
        joined = joined substr($0, 1, length($0) - 1) " "
        next
      }
      line = joined $0
      joined = ""
    }
    line ~ /^[[:space:]]*#/ { next }
    {
      why = ""
      if (line ~ /(^|[^a-z_-])kill([[:space:]]+(-[A-Za-z][A-Za-z0-9+]*|-[1-9][0-9]*|-[sn][[:space:]]+[A-Za-z0-9+]+))*([[:space:]]+--)?[[:space:]]+"?-"?\$/)
        why = "signals the process group of a stored number"
      else if (line ~ /(^|[^a-z_-])pkill[[:space:]][^#;|&]*(-P|--parent)([[:space:]=]|$)/)
        why = "signals the children of a stored PID"
      else if (line ~ /(^|[^a-z_-])xargs([[:space:]]+-[^[:space:]]+)*[[:space:]]+kill([[:space:]]|$)/)
        why = "signals the PIDs it reads"
      else {
        # Each kill of a stored PID up to the end of its command, when the
        # command hides that the process was gone: then the signal went to
        # whatever held the number.
        rest = line
        while (why == "" && match(rest, /(^|[^a-z_-])kill([[:space:]]+(-[A-Za-z][A-Za-z0-9+]*|-[1-9][0-9]*|-[sn][[:space:]]+[A-Za-z0-9+]+))?([[:space:]]+--)?[[:space:]]+"?\$/)) {
          command = substr(rest, RSTART)
          rest = substr(rest, RSTART + RLENGTH)
          sub(/;.*/, "", command)
          if (command ~ /[2&]>/)
            why = "signals a stored PID whose process may be gone"
          else if (match(command, /\|\|[[:space:]]*/) && substr(command, RSTART + RLENGTH) !~ /^(fail|exit)([[:space:]]|$)/)
            why = "signals a stored PID whose process may be gone"
        }
      }
      if (why != "")
        printf "%s:%d: %s: %s\n", FILENAME, start, why, line
    }
  ' "$@"
}

# The check finds every old form, and nothing else.
cat >"$WORK_DIR/sample.sh" <<'SH'
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
trap 'kill "$holder" 2>/dev/null || true; rm -rf "$WORK"' EXIT
kill -HUP -- "-$runner" 2>/dev/null || true; wait "$runner" || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null
kill "$(cat "$STATE/holder")" 2>/dev/null || true
  for pid in "${FOREIGN_PIDS[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
kill -s TERM "$pid" || :
kill -9 "$runner"; kill -9 "$(cat "$STATE/guard.pid")" 2>/dev/null || true
  kill -KILL "-$pid" 2>/dev/null || true
kill -9 -$pgid || :
kill -KILL -- -"$pid"
kill "$pid" >/dev/null 2>&1 || echo gone
kill -s KILL "$pid" &>/dev/null; true
kill -TERM "$pid" || return 0
  kill -KILL "$pid" \
    2>/dev/null || true
echo "$pid" | xargs kill 2>/dev/null || true
pkill -KILL --parent "$pid" || true
pkill --signal KILL -P "$pid"
-- allowed --
  owned_kill KILL "${actors[@]}" || true
kill -0 "$pid" 2>/dev/null || fail "gone"
kill -0 -- "-$pgid" 2>/dev/null || break
kill -TERM "$runner"; wait "$runner" || true
kill -TERM "$pid" || fail "the worker is gone"
pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
# kill -KILL "$pid" 2>/dev/null || true
kill -TERM "$runner" \
  || fail "the runner is gone"
SH
found="$(stale_kills "$WORK_DIR/sample.sh" | cut -d: -f2 | tr '\n' ' ')"
[ "$found" = "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 19 20 21 " ] ||
  fail "the check of the old forms found lines '$found', not 1 to 17 and 19 to 21"

# unloaded_kills FILE...: the calls of owned_kill and owned_kill_children
# where the helper is not loaded. There the call fails with "not found", the
# `|| true` of a cleanup hides that, and the process is never signalled. A
# stand-in that a test writes (a here document) runs in a process of its
# own, or is sourced by one, and loads the helper itself; a test or helper
# loads it, or a helper of tests/helpers that does.
unloaded_kills() {
  awk '
    function loads(line) {
      return line ~ /^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(\.|source)[[:space:]]/ &&
        line ~ /owned_processes\.sh|[$][{]?OWNED_PROCESSES([^A-Za-z0-9_]|$)|helpers\/autotune_stubs\.sh|helpers\/autotune_scheduler\/setup\.sh/
    }
    function calls(line) {
      return line !~ /^[[:space:]]*#/ && line ~ /(^|[^A-Za-z0-9_])owned_kill(_children)?([^A-Za-z0-9_]|$)/
    }
    function finish_file() {
      if (file != "" && !file_loads)
        printf "%s", file_calls
      # A here document that never ends (or the text of one taken for it).
      if (tag != "" && !body_loads)
        printf "%s", body_calls
    }
    FNR == 1 { finish_file(); file = FILENAME; file_loads = 0; file_calls = ""; tag = "" }
    tag != "" {
      line = $0
      if (strip) sub(/^\t+/, "", line)
      if (line == tag) {
        if (!body_loads)
          printf "%s", body_calls
        tag = ""
      } else if (loads($0))
        body_loads = 1
      else if (calls($0))
        body_calls = body_calls sprintf("%s:%d: a stand-in calls the helper without loading it: %s\n", FILENAME, FNR, $0)
      next
    }
    {
      if (loads($0))
        file_loads = 1
      else if (calls($0))
        file_calls = file_calls sprintf("%s:%d: calls the helper without loading it: %s\n", FILENAME, FNR, $0)
      # A here document starts: <<TAG, <<-TAG, <<\047TAG\047, <<"TAG"; not a
      # here-string (<<<) and not the text of one inside a string.
      if (match($0, /(^|[^<])<<-?[[:space:]]*(\047[A-Za-z_][A-Za-z0-9_]*\047|"[A-Za-z_][A-Za-z0-9_]*"|\\?[A-Za-z_][A-Za-z0-9_]*)([[:space:];|&)>]|$)/)) {
        tag = substr($0, RSTART, RLENGTH)
        sub(/^[^<]?<<-?[[:space:]]*/, "", tag)
        strip = substr($0, RSTART, RLENGTH) ~ /<<-/
        sub(/[[:space:];|&)>]$/, "", tag)
        gsub(/[\047"\\]/, "", tag)
        body_loads = 0
        body_calls = ""
      }
    }
    END { finish_file() }
  ' "$@"
}

# The check finds a call without the helper, in a test and in a stand-in.
cat >"$WORK_DIR/unloaded.sh" <<'SH'
cleanup() { owned_kill KILL "$pid" || true; }
SH
cat >"$WORK_DIR/stand-ins.sh" <<'SH'
. "$ROOT/tests/helpers/owned_processes.sh"
cat >"$WORK/loaded" <<'STUB'
OWNED_PROCESSES_KEEP_MARK=1 . "$OWNED_PROCESSES"
owned_kill TERM "$holder" || true
STUB
cat >"$WORK/lock.sh" <<'STUB'
release_lock() { owned_kill TERM "$(cat "$STATE/holder")" || true; }
STUB
cat >"$WORK/unquoted" <<-STUB
	owned_kill_children KILL "\$pid"
	STUB
heredoc_script "$BUILD_SCRIPT" "  cat > \"\$control_dir/prerm\" <<'EOF'" "$WORK/prerm"
owned_kill KILL "$pid" || true
cat >"$WORK/notes" <<EOF
EOF
SH
# shellcheck disable=SC2016 # the text of a stand-in
printf '%s\n' "cat >\"\$WORK/stand-in\" <<'STUB'" 'owned_kill KILL "$pid" || true' >"$WORK_DIR/unterminated.sh"
found="$(unloaded_kills "$WORK_DIR/unloaded.sh" "$WORK_DIR/stand-ins.sh" "$WORK_DIR/unterminated.sh" |
  sed "s|^$WORK_DIR/||" | cut -d: -f1,2 | tr '\n' ' ')"
[ "$found" = "unloaded.sh:1 stand-ins.sh:7 stand-ins.sh:10 unterminated.sh:2 " ] ||
  fail "the check of calls without the helper found '$found', not unloaded.sh:1, stand-ins.sh:7 and 10, unterminated.sh:2"

TEST_FILES=()
while IFS= read -r file; do
  case "${file#"$ROOT_DIR"/}" in
    # The helper itself, this check, the runner, which signals the process
    # group of a test it started only while its pidfile says that the test
    # still runs, the local lane runner, which signals only jobs of its own
    # shell before it reaps them, and a regression run alone on a router
    # against the installed Prokop, without this repository.
    tests/helpers/owned_processes.sh | tests/owned_processes.sh | tests/run.sh | tests/runner/run.sh | \
      tests/router/singbox_single_process.sh) continue ;;
  esac
  TEST_FILES+=("$file")
done < <(find "$ROOT_DIR/tests" -name '*.sh' -type f | sort)
[ "${#TEST_FILES[@]}" -ge 100 ] || fail "only ${#TEST_FILES[@]} test files to check"
source_require "${TEST_FILES[@]}"
if old="$(stale_kills "${TEST_FILES[@]}")" && [ -n "$old" ]; then
  printf '%s\n' "$old" | sed "s|^$ROOT_DIR/||" >&2
  fail "tests signal stored PIDs other than through tests/helpers/owned_processes.sh (UC-233)"
fi
if unloaded="$(unloaded_kills "${TEST_FILES[@]}")" && [ -n "$unloaded" ]; then
  printf '%s\n' "$unloaded" | sed "s|^$ROOT_DIR/||" >&2
  fail "tests call owned_kill where tests/helpers/owned_processes.sh is not loaded"
fi

printf 'owned processes checks passed\n'
