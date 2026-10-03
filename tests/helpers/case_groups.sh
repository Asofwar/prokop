# shellcheck shell=sh
# Groups of cases of one slow test file that run at the same time. A test
# whose cases mostly wait (the one-second steps of the production code, the
# stand-ins' delays) runs independent groups of them at once instead of one
# after another. Every group must be hermetic: it runs in a subshell of its
# own and builds its own fixture (temporary directory, stand-ins, state), so
# nothing one group does is seen by another. POSIX sh and bash compatible.
#
# run_case_groups DIR FUNCTION GROUP...
# Runs `FUNCTION GROUP` for every GROUP (a plain word), each in a background
# subshell under set -e with its output in DIR/GROUP.log, waits for all of
# them and then prints the logs in the order of the groups. Returns 1,
# naming the group, when one of them failed. PROKOP_TEST_GROUP_JOBS, when
# set to a positive number, bounds how many groups run at once (tests/run.sh
# sets it while it runs several tests in parallel); by default all do.
#
# Call it as a plain command under set -e, never as a condition (after if,
# while or "!", or in a || or && list): the shell ignores set -e in
# everything such a condition runs, and a group would then go on after a
# failed check. It refuses to run there.
run_case_groups() {
    run_case_groups_dir=$1
    run_case_groups_fn=$2
    shift 2
    ( false; true ) &
    if wait "$!"; then
        printf 'FAIL: run_case_groups runs in a condition or without set -e: a failed check would not stop its group\n' >&2
        return 1
    fi
    run_case_groups_max=${PROKOP_TEST_GROUP_JOBS:-0}
    case $run_case_groups_max in '' | *[!0-9]*) run_case_groups_max=0 ;; esac
    mkdir -p "$run_case_groups_dir"
    run_case_groups_running=""
    run_case_groups_count=0
    for run_case_groups_group in "$@"; do
        # The oldest group first: the groups of a test take about as long.
        while [ "$run_case_groups_max" -gt 0 ] && [ "$run_case_groups_count" -ge "$run_case_groups_max" ]; do
            run_case_groups_pid=${run_case_groups_running%% *}
            run_case_groups_running=${run_case_groups_running#"$run_case_groups_pid"}
            run_case_groups_running=${run_case_groups_running# }
            wait "$run_case_groups_pid" || true
            run_case_groups_count=$((run_case_groups_count - 1))
        done
        rm -f "$run_case_groups_dir/$run_case_groups_group.status"
        (
            set +e
            ( set -e; "$run_case_groups_fn" "$run_case_groups_group" ) </dev/null \
                >"$run_case_groups_dir/$run_case_groups_group.log" 2>&1
            echo "$?" >"$run_case_groups_dir/$run_case_groups_group.status"
        ) &
        run_case_groups_running="${run_case_groups_running:+$run_case_groups_running }$!"
        run_case_groups_count=$((run_case_groups_count + 1))
    done
    for run_case_groups_pid in $run_case_groups_running; do
        wait "$run_case_groups_pid" || true
    done
    run_case_groups_result=0
    for run_case_groups_group in "$@"; do
        cat "$run_case_groups_dir/$run_case_groups_group.log"
        run_case_groups_status=1
        read -r run_case_groups_status <"$run_case_groups_dir/$run_case_groups_group.status" 2>/dev/null || true
        if [ "$run_case_groups_status" != 0 ]; then
            printf 'FAIL: the group of cases %s failed\n' "$run_case_groups_group" >&2
            run_case_groups_result=1
        fi
    done
    return "$run_case_groups_result"
}
