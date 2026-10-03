# shellcheck shell=sh
# Signals that reach only the processes of this test (UC-233). POSIX sh and
# bash compatible; sourced by a test before it starts any process.
#
# A PID names a process only while that process exists. Once it has exited
# and been reaped, the kernel gives the number to a later process (PIDs wrap
# at pid_max, often 32768), and while tests run side by side (tests/run.sh)
# that is often a process of another test. A cleanup that signals a PID it
# stored when it started a process (kill -KILL "$pid"), the process group of
# that number (kill -KILL -- "-$pid") or the children of that number
# (pkill -P "$pid") then kills another test's process, or its whole group.
#
# Here a process counts as this test's only while that is proven, right
# before each signal, by one of:
# - the test's mark: sourcing this file exports PROKOP_TEST_OWNER, a random
#   token of this test run, and every program the test runs from then on,
#   and every program those run, carries it in /proc/<pid>/environ, which
#   shows the environment a program was exec'd with. A process of another
#   test or of the host does not carry it;
# - being a child of the shell that sends the signal: a job it started that
#   is a subshell (`( ... ) &`, `function &`) was forked, not exec'd, and
#   shows the environment of the test's shell, from before the mark was set.
#   No other process can become its child.
# The test's own shell and its subshells carry no mark, and a shell is not
# its own child: a test never signals itself. A process that has exited (a
# zombie included) proves nothing, so its reused PID is left alone.
#
# owned_processes_init
#   Sets a new mark. Sourcing this file does; a group of cases
#   (tests/helpers/case_groups.sh) that cleans up after itself calls it at
#   its start, so that its cleanup leaves the other groups' processes alone.
#   A stand-in that a test runs and that signals the test's processes (a
#   script the test writes) keeps the test's mark instead: it sources this
#   file with OWNED_PROCESSES_KEEP_MARK=1.
# owned_process PID
#   True while PID runs (not a zombie) and is this test's.
# owned_kill SIGNAL PID...
#   Sends SIGNAL (a name for kill -s: KILL, TERM, ...) to each PID that is
#   this test's. When a process of this test belongs to the process group of
#   that number (a process started under setsid leads one, and the group
#   outlives its leader while members remain), the whole group gets SIGNAL:
#   the ID of a group that has members is not given to another process, and
#   only descendants of the group's leader can join it. Returns 1 when some
#   PID named neither a process nor a process group of this test; a cleanup
#   ignores that.
# owned_kill_children SIGNAL PID...
#   Sends SIGNAL to every process of this test whose parent is PID.

owned_processes_init() {
    # The kernel's random UUID needs no od, which a stock OpenWrt BusyBox
    # lacks (tests/router/ runs there).
    owned_processes_random=""
    IFS= read -r owned_processes_random 2>/dev/null </proc/sys/kernel/random/uuid ||
        owned_processes_random="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    PROKOP_TEST_OWNER="$$-$(date +%s)-${owned_processes_random:?no random bytes for the test owner mark}"
    export PROKOP_TEST_OWNER
}

# owned_processes_stat PID: the state and the parent of PID in
# owned_processes_state and owned_processes_ppid. PID self is the shell that
# reads (a redirection of a builtin is opened by the shell itself).
owned_processes_stat() {
    IFS= read -r owned_processes_line 2>/dev/null <"/proc/$1/stat" || return 1
    owned_processes_pid=${owned_processes_line%% *}
    # The command name in parentheses may hold spaces and ')'.
    owned_processes_line=${owned_processes_line##*) }
    owned_processes_state=${owned_processes_line%% *}
    owned_processes_line=${owned_processes_line#* }
    owned_processes_ppid=${owned_processes_line%% *}
}

owned_processes_marked() {
    [ -n "${PROKOP_TEST_OWNER:-}" ] || return 1
    owned_processes_environ="$(tr '\0' '\n' 2>/dev/null <"/proc/$1/environ")" || return 1
    case "
$owned_processes_environ
" in
        *"
PROKOP_TEST_OWNER=$PROKOP_TEST_OWNER
"*) return 0 ;;
    esac
    return 1
}

owned_process() {
    case $1 in '' | *[!0-9]*) return 1 ;; esac
    owned_processes_stat self || return 1
    owned_processes_self=$owned_processes_pid
    owned_processes_stat "$1" || return 1
    case $owned_processes_state in Z | X) return 1 ;; esac
    [ "$owned_processes_ppid" = "$owned_processes_self" ] || owned_processes_marked "$1"
}

# owned_processes_select FIELD ID...
# Prints "ID PID" for every process whose parent (FIELD 2) or process group
# (FIELD 3, counted after the command name) is one of the IDs.
owned_processes_select() {
    owned_processes_field=$1
    shift
    # cat goes on past the stat files of processes that exit meanwhile.
    # shellcheck disable=SC2002
    cat /proc/[0-9]*/stat 2>/dev/null |
        awk -v field="$owned_processes_field" -v ids=" $* " '
            { pid = $1; sub(/^.*\) /, "") }
            index(ids, " " $field " ") { print $field, pid }
        ' || :
}

owned_kill() {
    owned_kill_signal=$1
    shift
    owned_kill_status=0
    owned_kill_members="$(owned_processes_select 3 "$@")"
    for owned_kill_pid in "$@"; do
        case $owned_kill_pid in
            '' | *[!0-9]*)
                owned_kill_status=1
                continue
                ;;
        esac
        owned_kill_group=""
        while read -r owned_kill_id owned_kill_member; do
            [ "$owned_kill_id" = "$owned_kill_pid" ] || continue
            if owned_process "$owned_kill_member"; then
                owned_kill_group=$owned_kill_pid
                break
            fi
        done <<OWNED_PROCESSES
$owned_kill_members
OWNED_PROCESSES
        if [ -n "$owned_kill_group" ] && kill -s "$owned_kill_signal" -- "-$owned_kill_group" 2>/dev/null; then
            continue
        fi
        if owned_process "$owned_kill_pid" && kill -s "$owned_kill_signal" "$owned_kill_pid" 2>/dev/null; then
            continue
        fi
        owned_kill_status=1
    done
    return "$owned_kill_status"
}

owned_kill_children() {
    owned_kill_signal=$1
    shift
    owned_kill_members="$(owned_processes_select 2 "$@")"
    while read -r owned_kill_id owned_kill_member; do
        [ -n "$owned_kill_member" ] || continue
        if owned_process "$owned_kill_member"; then
            kill -s "$owned_kill_signal" "$owned_kill_member" 2>/dev/null || :
        fi
    done <<OWNED_PROCESSES
$owned_kill_members
OWNED_PROCESSES
    return 0
}

if [ -z "${OWNED_PROCESSES_KEEP_MARK:-}" ] || [ -z "${PROKOP_TEST_OWNER:-}" ]; then
    owned_processes_init
fi
