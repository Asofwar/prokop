import { describe, expect, it } from 'vitest';

import { deleteSnapshotToast, snapshotBusyText } from '../model';

// UC-119: a refused delete says why instead of a bare "Could not delete".
describe('snapshot delete toast', () => {
  it('confirms a deleted snapshot and warns while busy', () => {
    expect(deleteSnapshotToast({ status: 'deleted' })).toMatchObject({
      text: 'Snapshot deleted',
      type: 'success',
    });
    expect(
      deleteSnapshotToast({
        status: 'busy',
        reason: 'service_action_in_progress',
      }),
    ).toMatchObject({
      text: snapshotBusyText('service_action_in_progress'),
      type: 'warning',
    });
  });

  it('names why a delete was refused', () => {
    const lkg = deleteSnapshotToast({
      status: 'failed',
      reason: 'lkg_protected',
    });
    expect(lkg.type).toBe('warning');
    expect(lkg.text).toContain('last known good');

    const missing = deleteSnapshotToast({
      status: 'failed',
      reason: 'invalid_snapshot',
    });
    expect(missing.type).toBe('error');
    expect(missing.text).toContain('not found');

    expect(
      deleteSnapshotToast({ status: 'failed', reason: 'delete_failed' }).text,
    ).toBe('Could not delete snapshot');
    expect(deleteSnapshotToast(undefined).text).toBe(
      'Could not delete snapshot',
    );
  });
});
