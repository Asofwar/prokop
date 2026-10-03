#!/usr/bin/env bash
# While a full removal runs, the CLI refuses every command that changes
# Prokop (UC-084).
#
# Before: /usr/bin/prokop refused a hand-kept list of commands while
# /tmp/prokop-full-uninstall.lock existed (start, reload, the updates, the
# component actions, autotune runs and applies). Commands added later were
# missing from it: a snapshot restore, create or delete, an URLTest
# override, the autotune policy and targets (which also write the crontab),
# DNS failover, a kill-switch sync, a UI service action, a postinst, and the
# Clash API actions that change the running proxy all ran during the
# removal and could write /etc/config/prokop, the snapshots, the crontab or
# an nft table again after the removal had taken them away.
#
# Now the CLI names what may run during a removal, the commands that only
# read and the steps the removal runs itself, and refuses everything else,
# a command added later too. The test runs every command of command_spec
# against stub modules, with and without the removal's lock; the lock lives
# in a private /tmp of a user and mount namespace, never in the host's /tmp.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT_DIR/prokop/files/usr/bin/prokop"
NAMESPACE=(unshare --user --map-root-user --mount --propagation private)

namespaces() { printf '%s %s' "$(readlink /proc/self/ns/user)" "$(readlink /proc/self/ns/mnt)"; }

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: full_uninstall_command_gate: %s\n' "$1"
    exit 0
  }
  command -v unshare >/dev/null 2>&1 || skip 'unshare is not installed'
  probe_status=0
  probe="$("${NAMESPACE[@]}" sh -c 'mount -t tmpfs tmpfs /tmp' 2>&1)" || probe_status=$?
  [ "$probe_status" = 0 ] || skip "a private user+mount namespace with its own /tmp is unavailable: $probe"
  PROKOP_GATE_HOST_NAMESPACES="$(namespaces)" exec "${NAMESPACE[@]}" bash "$0" --in-namespace
fi

# ---- inside the namespace ---------------------------------------------------

refuse() {
  printf 'FAIL: --in-namespace is only for the private namespace this test creates (%s)\n' "$1" >&2
  exit 1
}
# Never mount over the caller's /tmp: only a new user namespace that maps
# nothing but root, with a new mount namespace, is accepted.
mapfile -t uid_map </proc/self/uid_map
read -r map_inside _ map_count <<<"${uid_map[0]:-}"
if [ "${#uid_map[@]}" != 1 ] || [ "$map_inside" != 0 ] || [ "$map_count" != 1 ]; then
  refuse "not a user namespace mapping only root: ${uid_map[*]:-}"
fi
read -r host_user host_mnt <<<"${PROKOP_GATE_HOST_NAMESPACES:-}"
read -r own_user own_mnt <<<"$(namespaces)"
if [ -z "${host_user:-}" ] || [ "$own_user" = "$host_user" ] || [ "$own_mnt" = "${host_mnt:-}" ]; then
  refuse "the user or mount namespace is not new"
fi
# The checkout may itself be under /tmp, which the private /tmp hides: the
# CLI is read before and copied into it.
exec 3<"$CLI"
mount -t tmpfs -o mode=1777 tmpfs /tmp || refuse "cannot mount a private /tmp"

export TMPDIR=/tmp
WORK="$(mktemp -d)"
CLI="$WORK/prokop"
cat <&3 >"$CLI"
exec 3<&-
LOCK=/tmp/prokop-full-uninstall.lock
LIB="$WORK/lib"
export GATE_RAN="$WORK/ran"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# What may run during a removal: the commands that only read, and the
# removal's own steps (init.d stop, the kill-switch removal, the dnsmasq
# restore, the package's prerm; a second full_uninstall, or its alias
# uninstall, answers itself).
ALLOWED="
stop disable killswitch_disable dnsmasq_restore restore_dnsmasq package_prerm full_uninstall uninstall
killswitch_status show_config show_version show_sing_box_config show_sing_box_version
check_proxy check_nft check_nft_rules check_sing_box check_logs check_sing_box_logs check_fakeip
check_zapret_runtime check_zapret2_runtime check_byedpi_runtime check_dns_available
get_status get_outbound_metadata get_subscription_metadata get_sing_box_status get_zapret_status
get_zapret2_status get_byedpi_status get_system_info get_ui_capabilities get_ui_state
get_health_status get_history get_readonly_config_sections get_dashboard_runtime_metadata
route_trace connectivity_test global_check support_report config_snapshot_list config_snapshot_diff
service_action_status latency_test_status component_action_status subscription_update_status
component_update_check_cache prokop_releases autotune_status autotune_target autotune_groups
autotune_list_domains autotune_run_status validate_nfqws_strategy_json
validate_nfqws2_strategy_json validate_byedpi_strategy_json
"
# Everything that changes Prokop's configuration, snapshots, scheduled jobs,
# packages or runtime.
REFUSED="
start main restart reload enable dns_failover_apply
list_update list_update_if_due subscription_update subscription_update_async subscription_update_if_due
service_action_async latency_test_async ui_action_ack neutralize_zapret_defaults
component_action component_action_async component_updates_if_due package_postinst luci_postinst
config_snapshot_create config_snapshot_restore config_snapshot_delete
urltest_override_save urltest_override_reset
autotune_policy_set autotune_target_set autotune_target_remove autotune_run autotune_run_async
autotune_apply autotune_apply_async autotune_rollback autotune_if_due killswitch_sync
"
listed() { case " $(printf '%s' "$2" | tr '\n' ' ') " in *" $1 "*) return 0 ;; esac; return 1; }

# Every command of command_spec, with its module.
mapfile -t specs < <(sed -n 's/^ *\([a-z0-9_]*\): \[ "\([^"]*\)", "[^"]*", [0-9]* \],\{0,1\}$/\1 \2/p' "$CLI")
[ "${#specs[@]}" -gt 80 ] || fail "command_spec was not read from $CLI: ${#specs[@]} commands"
for spec in "${specs[@]}"; do
  read -r command module <<<"$spec"
  [ "$command" = clash_api ] && continue
  if listed "$command" "$ALLOWED" && listed "$command" "$REFUSED"; then
    fail "$command is listed as allowed and as refused"
  fi
  listed "$command" "$ALLOWED" || listed "$command" "$REFUSED" ||
    fail "the new command $command must be classified here: may it run while Prokop is being removed?"
  if [ ! -e "$LIB/$module" ]; then
    mkdir -p "$(dirname "$LIB/$module")"
    cat >"$LIB/$module" <<'UCODE'
let fs = require("fs");
let out = fs.open(getenv("GATE_RAN"), "a");
out.write(join(" ", ARGV) + "\n");
out.close();
UCODE
  fi
done

# run COMMAND [ARG...]: rc, whether its module ran, and what it said.
run() {
  : >"$GATE_RAN"
  rc=0
  PROKOP_LIB="$LIB" ucode "$CLI" "$@" >"$WORK/out" 2>"$WORK/err" </dev/null || rc=$?
  ran="$(cat "$GATE_RAN")"
}
expect_ran() {
  run "$@"
  if [ "$rc" != 0 ] || [ -z "$ran" ]; then
    fail "$CASE: $1 ${2:-} did not run (rc $rc): $(cat "$WORK/err")"
  fi
}
expect_refused() {
  run "$@"
  [ "$rc" != 0 ] || fail "$CASE: $1 ${2:-} succeeded"
  [ -z "$ran" ] || fail "$CASE: $1 ${2:-} ran its module: $ran"
  grep -Fq 'Prokop full removal is in progress' "$WORK/err" ||
    fail "$CASE: $1 ${2:-} did not say why it was refused: $(cat "$WORK/err")"
}

# 1. Without a removal every command reaches its module.
CASE="no removal"
for spec in "${specs[@]}"; do
  read -r command _ <<<"$spec"
  expect_ran "$command" a1 a2 a3 a4 a5 a6 a7
done

# 2. During a removal only the allowed ones do.
CASE="removal running"
mkdir "$LOCK"
for spec in "${specs[@]}"; do
  read -r command _ <<<"$spec"
  [ "$command" = clash_api ] && continue
  if listed "$command" "$ALLOWED"; then
    expect_ran "$command" a1 a2 a3 a4 a5 a6 a7
  else
    expect_refused "$command" a1 a2
  fi
done
# The Clash API reads with get_*; its other actions change the runtime.
for action in get_proxies get_connections get_proxy_latency get_proxy_latencies get_group_latency; do
  expect_ran clash_api "$action" x
done
for action in set_group_proxy close_connection close_all_connections ""; do
  expect_refused clash_api "$action" x
done
# An unknown command still gets the usage.
run no_such_command
if [ "$rc" = 0 ] || ! grep -Fq 'Available commands' "$WORK/out"; then
  fail "$CASE: an unknown command did not get the usage"
fi

printf 'full_uninstall_command_gate: ok\n'
