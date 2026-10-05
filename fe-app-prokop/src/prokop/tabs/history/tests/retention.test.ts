import { describe, expect, it } from 'vitest';

import {
  clearHistoryToast,
  clearSnapshotsToast,
  deleteSnapshotToast,
  historyItems,
  parseRetentionInput,
  removableSnapshots,
  retentionConsequences,
  retentionToast,
  snapshotRows,
} from '../model';
import type { Prokop } from '../../../types';

const snapshot = (
  id: string,
  overrides: Partial<Prokop.SnapshotMetadata> = {},
): Prokop.SnapshotMetadata => ({
  id,
  created_at: Number(id),
  kind: 'automatic',
  reason: 'before-reload',
  prokop_version: '2.28.0',
  ...overrides,
});

const limits: Prokop.HistoryRetention = {
  history_limit: 50,
  snapshot_limit: 20,
  manual_snapshot_limit: 18,
};

// The Retention card checks its fields as config/retention.uc does.
describe('retention input', () => {
  it('accepts whole numbers within the bounds', () => {
    expect(parseRetentionInput(' 20 ', '6')).toEqual({
      ok: true,
      history: 20,
      snapshots: 6,
    });
    expect(parseRetentionInput('200', '50')).toEqual({
      ok: true,
      history: 200,
      snapshots: 50,
    });
  });

  it('names the field and its range when a value is refused', () => {
    for (const [history, snapshots, field] of [
      ['19', '20', 'History records'],
      ['201', '20', 'History records'],
      ['1e2', '20', 'History records'],
      ['', '20', 'History records'],
      ['50', '5', 'Snapshots'],
      ['50', '51', 'Snapshots'],
      ['50', '7.5', 'Snapshots'],
    ]) {
      const result = parseRetentionInput(history, snapshots);
      expect(result.ok).toBe(false);
      if (!result.ok) expect(result.message).toContain(field);
    }
  });
});

describe('retention consequences', () => {
  it('says nothing when no limit is lowered', () => {
    expect(
      retentionConsequences({ history: 80, snapshots: 30 }, limits, [], 50),
    ).toEqual([]);
  });

  it('counts only removable automatic snapshots beyond the new size', () => {
    const list = [
      snapshot('1', { kind: 'manual', reason: 'manual' }),
      snapshot('2', { is_lkg: true, reason: 'last-known-working' }),
      snapshot('3', { protected_reason: 'restore_guard_protected' }),
      ...['4', '5', '6', '7', '8', '9', '10'].map((id) => snapshot(id)),
    ];
    const lines = retentionConsequences(
      { history: 20, snapshots: 6 },
      limits,
      list,
      50,
    );
    expect(lines).toEqual([
      'Only the newest 20 history records are kept; older ones are deleted.',
      '4 oldest automatic snapshots are deleted.',
    ]);
    // Never more than the removable ones.
    expect(
      retentionConsequences(
        { history: 50, snapshots: 6 },
        limits,
        list.slice(0, 4),
        10,
      ),
    ).toEqual([]);
  });

  it('warns when manual snapshots no longer fit', () => {
    const manual = ['1', '2', '3', '4', '5'].map((id) =>
      snapshot(id, { kind: 'manual', reason: 'manual' }),
    );
    const lines = retentionConsequences(
      { history: 50, snapshots: 6 },
      limits,
      manual,
      0,
    );
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain('There are 5 manual snapshots');
    expect(lines[0]).toContain('the 4 that fit');
  });
});

describe('clear and retention toasts', () => {
  it('reports what a saved limit removed', () => {
    expect(retentionToast({ status: 'saved' }).text).toBe(
      'Retention limits saved',
    );
    const pruned = retentionToast({
      status: 'saved',
      removed_events: 3,
      removed_snapshots: 2,
    });
    expect(pruned.type).toBe('success');
    expect(pruned.text).toContain('history records deleted: 3');
    expect(pruned.text).toContain('snapshots deleted: 2');
    expect(retentionToast({ status: 'busy' }).type).toBe('warning');
    expect(
      retentionToast({ status: 'failed', reason: 'invalid_input' }).text,
    ).toContain('Nothing was changed');
    expect(retentionToast(undefined).type).toBe('error');
  });

  it('says what Clear kept', () => {
    const cleared = clearSnapshotsToast({
      status: 'cleared',
      removed: 3,
      kept: 1,
      manual: 2,
    });
    expect(cleared.type).toBe('success');
    expect(cleared.text).toContain('3');
    expect(cleared.text).toContain('Kept: 3');
    expect(
      clearSnapshotsToast({ status: 'cleared', removed: 0, kept: 2, manual: 1 })
        .type,
    ).toBe('warning');
    expect(clearSnapshotsToast({ status: 'busy' }).type).toBe('warning');
    expect(clearSnapshotsToast({ status: 'failed' }).type).toBe('error');
    expect(clearHistoryToast({ status: 'cleared', removed: 4 }).type).toBe(
      'success',
    );
    expect(clearHistoryToast({ status: 'busy' }).type).toBe('warning');
    expect(clearHistoryToast(undefined).type).toBe('error');
  });

  it('explains a snapshot kept for an unfinished restore', () => {
    const toast = deleteSnapshotToast({
      status: 'failed',
      reason: 'restore_guard_protected',
    });
    expect(toast.type).toBe('warning');
    expect(toast.text).toContain('unfinished restore');
    const [row] = snapshotRows([
      snapshot('1', {
        reason: 'pre-restore',
        protected_reason: 'restore_guard_protected',
      }),
    ]);
    expect(row.canDelete).toBe(false);
    expect(row.protectedText).toContain('unfinished restore');
  });
});

describe('removable snapshots and new history kinds', () => {
  it('leaves manual and protected snapshots out', () => {
    const list = [
      snapshot('1', { kind: 'manual', reason: 'manual' }),
      snapshot('2', { is_lkg: true }),
      snapshot('3', { protected_reason: 'apply_snapshot_protected' }),
      snapshot('4'),
    ];
    expect(removableSnapshots(list).map((s) => s.id)).toEqual(['4']);
  });

  it('names clear events and files them under Configuration', () => {
    const items = historyItems(
      [
        { kind: 'snapshot_clear', status: 'success', timestamp: 1 },
        { kind: 'history_clear', status: 'success', timestamp: 2 },
      ],
      'config',
      10000,
    );
    expect(items.map((item) => item.title)).toEqual([
      'History cleared',
      'Automatic snapshots cleared',
    ]);
  });
});
