export interface FullUninstallStatus {
  state?: string;
  phase?: string;
  // What of Prokop is still in place when that failed the removal, as
  // comma-separated item codes (full-uninstall.sh find_left_behind; UC-028).
  left?: string;
}

function describeLeftItem(item: string): string {
  if (item.startsWith('table:')) {
    const table = item.slice('table:'.length);
    return _('nft table %s').replace('%s', () => table);
  }
  switch (item) {
    case 'rule:4':
      return _('IPv4 routing rule at priority 105');
    case 'rule:6':
      return _('IPv6 routing rule at priority 105');
    case 'cron':
      return _('the lines marked "# prokop-" in /etc/crontabs/root');
    case 'loader':
      return _('the kill-switch loader in /usr/share/nftables.d/ruleset-post');
    case 'backup':
      return _('the configuration backup in /etc/prokop-backups');
    default:
      return item;
  }
}

// The item codes of the removal status in the language of the UI; a code
// this release does not know is shown as it came.
export function describeLeftItems(left: string): string {
  return left
    .split(',')
    .map((item) => item.trim())
    .filter((item) => item !== '')
    .map(describeLeftItem)
    .join(', ');
}

// How long the dialog follows the removal before it says it could not
// confirm the end: the removal proper, and before it the wait for a
// configuration change that began earlier (phase "transactions": up to 60
// checks of a second and a look at the processes each; full-uninstall.sh,
// UC-084). That wait has a time of its own and does not count against the
// removal, which gets its whole time once the wait is over.
export const REMOVAL_WAIT_MS = 180000;
export const TRANSACTIONS_WAIT_MS = 120000;

export interface RemovalWait {
  deadline: number;
  waitingForChanges: boolean;
}

export function startRemovalWait(now: number): RemovalWait {
  return { deadline: now + REMOVAL_WAIT_MS, waitingForChanges: false };
}

// The wait after the status the removal reported at now.
export function followRemoval(
  wait: RemovalWait,
  status: FullUninstallStatus,
  now: number,
): RemovalWait {
  const waitingForChanges =
    status.state === 'running' && status.phase === 'transactions';
  if (waitingForChanges === wait.waitingForChanges) return wait;
  return {
    deadline:
      now + (waitingForChanges ? TRANSACTIONS_WAIT_MS : REMOVAL_WAIT_MS),
    waitingForChanges,
  };
}

// What the user reads about a removal that failed.
export function describeFailedRemoval(status: FullUninstallStatus): string {
  const left =
    typeof status.left === 'string' ? describeLeftItems(status.left) : '';
  if (status.phase === 'preflight') {
    return _(
      'Original repositories could not be restored. Removal was cancelled before deleting packages.',
    );
  }
  // A configuration change that began before the removal (a snapshot
  // restore, an autotune run) did not end in time: nothing was stopped or
  // removed (full-uninstall.sh; UC-084).
  if (status.phase === 'transactions') {
    return _(
      'Prokop is still changing its configuration (a snapshot restore, an autotune run or another change), so nothing was removed. Try again once it has finished.',
    );
  }
  // The stop left Prokop's interception in place: nothing was disabled,
  // stopped or removed after it.
  if (status.phase === 'stop' && left) {
    return _(
      'Prokop is still active after its stop, so nothing was removed. Still in place: %s. Stop Prokop or restart the router, then try again.',
    ).replace('%s', () => left);
  }
  if (left) {
    return _(
      'Prokop was removed, but this is still in place: %s. See the removal log in /tmp/prokop-uninstall.*/output.log.',
    ).replace('%s', () => left);
  }
  return _(
    'Removal did not finish. See the removal log in /tmp/prokop-uninstall.*/output.log.',
  );
}
