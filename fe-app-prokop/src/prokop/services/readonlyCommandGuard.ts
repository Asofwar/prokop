import { isReadonlyMode } from './accessMode.service';
import { logger } from './logger.service';

export const PROKOP_CLI = '/usr/bin/prokop';

// rpcd hands the caller's environment to file.exec children, so the read
// role may run the CLI only through this wrapper, which clears it (UC-001).
export const PROKOP_READONLY_CLI = '/usr/libexec/prokop-ro';

// Mirror of the "read" exec grants of the luci-app-prokop ACL group
// (luci-app-prokop/root/usr/share/rpcd/acl.d/luci-app-prokop.json); a test
// keeps both lists identical. A read-only session only ever issues these
// commands, so rendering a page cannot start a mutation or trip the ACL.
export const READONLY_EXEC_PATTERNS = [
  '/usr/libexec/prokop-ro get_status',
  '/usr/libexec/prokop-ro killswitch_status',
  '/usr/libexec/prokop-ro get_sing_box_status',
  '/usr/libexec/prokop-ro get_zapret_status',
  '/usr/libexec/prokop-ro get_zapret2_status',
  '/usr/libexec/prokop-ro get_byedpi_status',
  '/usr/libexec/prokop-ro get_system_info',
  '/usr/libexec/prokop-ro get_ui_capabilities',
  '/usr/libexec/prokop-ro get_ui_state',
  '/usr/libexec/prokop-ro get_health_status',
  '/usr/libexec/prokop-ro get_history',
  '/usr/libexec/prokop-ro autotune_status',
  '/usr/libexec/prokop-ro autotune_groups',
  '/usr/libexec/prokop-ro autotune_run_status *',
  '/usr/libexec/prokop-ro route_trace *',
  '/usr/libexec/prokop-ro config_snapshot_list',
  '/usr/libexec/prokop-ro config_snapshot_diff *',
  '/usr/libexec/prokop-ro connectivity_test *',
  '/usr/libexec/prokop-ro get_readonly_config_sections',
  '/usr/libexec/prokop-ro get_dashboard_runtime_metadata',
  '/usr/libexec/prokop-ro show_version',
  '/usr/libexec/prokop-ro check_nft_rules',
  '/usr/libexec/prokop-ro check_sing_box',
  '/usr/libexec/prokop-ro check_logs',
  '/usr/libexec/prokop-ro check_fakeip',
  '/usr/libexec/prokop-ro check_zapret_runtime',
  '/usr/libexec/prokop-ro check_zapret2_runtime',
  '/usr/libexec/prokop-ro check_byedpi_runtime',
  '/usr/libexec/prokop-ro check_dns_available',
  '/usr/libexec/prokop-ro clash_api get_proxies',
  '/usr/libexec/prokop-ro clash_api get_connections',
  '/usr/libexec/prokop-ro service_action_status *',
  '/usr/libexec/prokop-ro latency_test_status *',
  '/usr/libexec/prokop-ro component_action_status *',
  '/usr/libexec/prokop-ro subscription_update_status *',
  '/usr/libexec/prokop-ro component_update_check_cache',
  '/usr/libexec/prokop-ro get_list_update_status',
  '/usr/libexec/prokop-ro global_check masked',
  '/usr/libexec/prokop-ro show_sing_box_config masked',
];

// stderr of a command refused locally in a read-only session.
export const READONLY_REFUSED = 'prokop: not available in read-only mode';

const compiled = READONLY_EXEC_PATTERNS.map(
  (pattern) =>
    new RegExp(
      `^${pattern
        .split('*')
        .map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&'))
        .join('.*')}$`,
    ),
);

// rpcd matches "command arg1 arg2 ..." against the ACL globs.
export function isReadonlyCommandAllowed(command: string, args: string[]) {
  const invocation = [command, ...args].join(' ');
  return compiled.some((pattern) => pattern.test(invocation));
}

// A read-only session reaches the CLI through the wrapper; administrators
// keep calling it directly.
export function resolveReadonlyCommand(command: string) {
  return isReadonlyMode() && command === PROKOP_CLI
    ? PROKOP_READONLY_CLI
    : command;
}

const reported = new Set<string>();

export function shouldRefuseCommand(command: string, args: string[]) {
  if (!isReadonlyMode() || isReadonlyCommandAllowed(command, args)) {
    return false;
  }

  const key = [command, args[0] ?? ''].join(' ');
  if (!reported.has(key)) {
    reported.add(key);
    logger.warn('[READONLY]', `refused ${key}`);
  }
  return true;
}
