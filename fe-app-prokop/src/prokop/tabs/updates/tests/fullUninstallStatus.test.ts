import { describe, expect, it } from 'vitest';

import {
  describeFailedRemoval,
  describeLeftItems,
  followRemoval,
  REMOVAL_WAIT_MS,
  startRemovalWait,
  TRANSACTIONS_WAIT_MS,
} from '../fullUninstallStatus';

describe('failed full removal', () => {
  it('says what Prokop left in place when its stop refused the removal', () => {
    const message = describeFailedRemoval({
      state: 'failed',
      phase: 'stop',
      left: 'table:ProkopTable,rule:4',
    });
    expect(message).toContain('nothing was removed');
    expect(message).toContain(
      'Still in place: nft table ProkopTable, IPv4 routing rule at priority 105.',
    );
    expect(message).not.toContain('%s');
  });

  it('says what is still in place after the packages were removed', () => {
    const message = describeFailedRemoval({
      state: 'failed',
      phase: 'files',
      left: 'table:ProkopKillswitch,cron',
    });
    expect(message).toContain('was removed, but this is still in place');
    expect(message).toContain(
      'nft table ProkopKillswitch, the lines marked "# prokop-" in /etc/crontabs/root',
    );
  });

  it('says that a configuration change kept the removal from starting', () => {
    const message = describeFailedRemoval({
      state: 'failed',
      phase: 'transactions',
    });
    expect(message).toContain('still changing its configuration');
    expect(message).toContain('nothing was removed');
  });

  it('keeps the left list as text', () => {
    expect(
      describeFailedRemoval({
        state: 'failed',
        phase: 'stop',
        left: "table:$& $' x",
      }),
    ).toContain("Still in place: nft table $& $' x.");
  });

  it('keeps the messages of failures that name nothing left', () => {
    expect(describeFailedRemoval({ state: 'failed', phase: 'preflight' })).toBe(
      'Original repositories could not be restored. Removal was cancelled before deleting packages.',
    );
    expect(describeFailedRemoval({ state: 'failed', phase: 'stop' })).toBe(
      'Removal did not finish. See the removal log in /tmp/prokop-uninstall.*/output.log.',
    );
    expect(describeFailedRemoval({ state: 'failed', phase: 'packages' })).toBe(
      'Removal did not finish. See the removal log in /tmp/prokop-uninstall.*/output.log.',
    );
  });
});

describe('what a removal left', () => {
  it('names each item the backend reports in the language of the UI', () => {
    expect(
      describeLeftItems(
        'table:ProkopTable,rule:4,rule:6,cron,table:ProkopTableDpiGuard,loader',
      ),
    ).toBe(
      'nft table ProkopTable, IPv4 routing rule at priority 105, ' +
        'IPv6 routing rule at priority 105, ' +
        'the lines marked "# prokop-" in /etc/crontabs/root, ' +
        'nft table ProkopTableDpiGuard, ' +
        'the kill-switch loader in /usr/share/nftables.d/ruleset-post',
    );
  });

  it('names the configuration backup a link kept in place', () => {
    expect(describeLeftItems('backup')).toBe(
      'the configuration backup in /etc/prokop-backups',
    );
  });

  it('shows an item it does not know as the backend sent it', () => {
    expect(describeLeftItems(' something new ,, cron')).toBe(
      'something new, the lines marked "# prokop-" in /etc/crontabs/root',
    );
    expect(describeLeftItems('')).toBe('');
  });
});

describe('how long the dialog follows a removal', () => {
  it('follows the removal for its own time when nothing held it up', () => {
    const wait = startRemovalWait(1000);
    expect(wait.deadline).toBe(1000 + REMOVAL_WAIT_MS);
    expect(
      followRemoval(wait, { state: 'running', phase: 'packages' }, 60000),
    ).toEqual(wait);
  });

  it('does not count the wait for a configuration change against the removal', () => {
    let wait = startRemovalWait(0);
    wait = followRemoval(
      wait,
      { state: 'running', phase: 'transactions' },
      1500,
    );
    expect(wait.waitingForChanges).toBe(true);
    expect(wait.deadline).toBe(1500 + TRANSACTIONS_WAIT_MS);
    // Still waiting a minute later: the deadline of the wait stays.
    const later = followRemoval(
      wait,
      { state: 'running', phase: 'transactions' },
      61500,
    );
    expect(later).toEqual(wait);
    // The change ended: the removal proper gets its whole time from now.
    wait = followRemoval(later, { state: 'running', phase: 'stop' }, 63000);
    expect(wait.waitingForChanges).toBe(false);
    expect(wait.deadline).toBe(63000 + REMOVAL_WAIT_MS);
    expect(wait.deadline).toBeGreaterThan(REMOVAL_WAIT_MS);
  });

  it('gives up on a removal that never leaves the wait', () => {
    let wait = startRemovalWait(0);
    wait = followRemoval(
      wait,
      { state: 'running', phase: 'transactions' },
      1500,
    );
    wait = followRemoval(
      wait,
      { state: 'running', phase: 'transactions' },
      1500 + TRANSACTIONS_WAIT_MS,
    );
    expect(wait.deadline).toBe(1500 + TRANSACTIONS_WAIT_MS);
  });
});
