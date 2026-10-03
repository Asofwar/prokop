import { describe, expect, it } from 'vitest';

import {
  createSnapshotToast,
  diffRows,
  diffTruncatedText,
  historyItems,
  recoveryRows,
  restoreConfirmMessage,
  restoreMigrationNote,
  restorePreview,
  restoreResultToast,
  snapshotBusyText,
  snapshotDiff,
  snapshotReasonLabel,
  snapshotRows,
  unsavedChangesBlockRestore,
} from '../model';
import type { Prokop } from '../../../types';

const health = (
  overrides: Partial<Prokop.HealthStatus> = {},
): Prokop.HealthStatus => ({
  overall: 'ok',
  service: { prokop: 'ok', sing_box: 'ok' },
  dns: { status: 'unknown' },
  dpi: { status: 'unknown' },
  lists: { status: 'unknown' },
  guard: { active: false },
  recovery: {
    pending: false,
    last_event: { kind: 'start', status: 'success', timestamp: 1 },
  },
  package_recovery: { pending: false },
  last_reload: { status: 'success', timestamp: 2 },
  recent_activity: [
    { kind: 'start', status: 'success', timestamp: 1 },
    { kind: 'reload', status: 'success', timestamp: 2 },
  ],
  ...overrides,
});

const snapshot = (
  id: string,
  createdAt: number,
  reason: string,
  isLkg = false,
): Prokop.SnapshotMetadata => ({
  id,
  created_at: createdAt,
  kind: reason === 'manual' ? 'manual' : 'automatic',
  reason,
  prokop_version: '1.0.0',
  is_lkg: isLkg,
});

describe('recovery state', () => {
  it('shows recovery facts, localized, with the last known good snapshot', () => {
    const rows = recoveryRows(health(), [
      snapshot('2_b', 20, 'last-known-working', true),
    ]);

    expect(rows.map((row) => row.label)).toEqual([
      'DPI guard',
      'Last recovery',
      'Package recovery',
      'Last reload',
      'Last known good configuration',
    ]);
    expect(rows[0].value).toBe('Inactive');
    expect(rows[1].value).toBe('Not needed');
    expect(rows[3].value).toMatch(/^Succeeded · /);
    expect(rows[4].tone).toBe('success');
    for (const row of rows)
      expect(row.value).not.toMatch(/^(ok|success|unknown|failure)$/);
  });

  it('says when no last known good snapshot exists or snapshots are unknown', () => {
    expect(recoveryRows(health(), [])[4].value).toBe('Not recorded yet');
    expect(recoveryRows(health(), null)[4].value).toBe('Unknown');
  });

  it('never presents an ordinary reload as the last recovery', () => {
    const reloadOnly = health({
      recovery: {
        pending: false,
        last_event: { kind: 'reload', status: 'success', timestamp: 9 },
      },
      recent_activity: [{ kind: 'reload', status: 'success', timestamp: 9 }],
    });
    expect(recoveryRows(reloadOnly, [])[1].value).toBe('Not needed');

    const rolledBack = health({
      recent_activity: [{ kind: 'reload', status: 'recovered', timestamp: 7 }],
    });
    expect(recoveryRows(rolledBack, [])[1].value).toMatch(
      /^Configuration reload: Recovered · /,
    );

    // An autotune rollback restored a snapshot: it is a recovery.
    const autotuneRollback = health({
      recent_activity: [
        { kind: 'autotune_rollback', status: 'success', timestamp: 8 },
      ],
    });
    expect(recoveryRows(autotuneRollback, [])[1].value).toMatch(
      /^Autotune rollback: Succeeded · /,
    );

    // The backend never records a 'recovery' kind: such an event counts only
    // by its outcome and is named as another event.
    const unknownKind = health({
      recent_activity: [{ kind: 'recovery', status: 'success', timestamp: 8 }],
    });
    expect(recoveryRows(unknownKind, [])[1].value).toBe('Not needed');
    const unknownKindRecovered = health({
      recent_activity: [
        { kind: 'recovery', status: 'recovered', timestamp: 8 },
      ],
    });
    expect(recoveryRows(unknownKindRecovered, [])[1].value).toMatch(
      /^Other event: Recovered · /,
    );
  });

  it('maps an active guard and pending package recovery', () => {
    const rows = recoveryRows(
      health({
        guard: { active: true },
        package_recovery: { pending: true },
        last_reload: null,
      }),
      [],
    );

    expect(rows[0]).toMatchObject({
      value: 'Active: DPI switch not confirmed',
      tone: 'error',
    });
    expect(rows[2].value).toBe('Waiting to finish');
    expect(rows[3].value).toBe('No reload recorded yet');
  });
});

// UC-066, UC-019: a guard that is left or a failed last change is never
// shown as "In progress", and the step that ends a guard is named.
describe('recovery state that needs an action', () => {
  const guarded = (
    action: 'restart' | 'restore' | 'wait',
    kinds: { runtime?: boolean; restore?: boolean },
  ) =>
    health({
      overall: 'error',
      guard: { active: true, runtime: false, restore: false, ...kinds },
      recovery: { pending: true, last_event: null, action },
    });
  const row = (rows: ReturnType<typeof recoveryRows>, label: string) =>
    rows.find((item) => item.label === label);

  it('asks for a restart while a failed transition keeps its guard', () => {
    const rows = recoveryRows(guarded('restart', { runtime: true }), []);
    expect(row(rows, 'DPI guard')).toMatchObject({
      value: 'Active: kept by a failed change',
      tone: 'error',
    });
    expect(row(rows, 'Last recovery')).toMatchObject({
      value: 'Needs attention',
      tone: 'error',
    });
    expect(row(rows, 'Next step')?.value).toContain('Restart Prokop');
  });

  it('asks for a snapshot restore while an unfinished restore keeps its guard', () => {
    const rows = recoveryRows(guarded('restore', { restore: true }), []);
    expect(row(rows, 'DPI guard')).toMatchObject({
      value: 'Active: restore not finished',
      tone: 'error',
    });
    expect(row(rows, 'Last recovery')?.value).toBe('Needs attention');
    expect(row(rows, 'Next step')?.value).toContain(
      'Restore the last known good snapshot',
    );
  });

  it('shows a guard that a running change holds as in progress', () => {
    const rows = recoveryRows(guarded('wait', { restore: true }), []);
    expect(row(rows, 'DPI guard')?.tone).toBe('loading');
    expect(row(rows, 'Last recovery')).toMatchObject({
      value: 'In progress',
      tone: 'loading',
    });
    expect(row(rows, 'Next step')).toBeUndefined();
  });

  it('names the failed last change instead of "In progress"', () => {
    const failed = { kind: 'reload', status: 'failure', timestamp: 9 };
    const rows = recoveryRows(
      health({
        overall: 'error',
        recovery: { pending: true, last_event: failed, action: null },
        recent_activity: [failed],
      }),
      [],
    );
    const last = row(rows, 'Last recovery');
    expect(last?.value).toMatch(/^Configuration reload: Failed · /);
    expect(last?.tone).toBe('error');
    expect(row(rows, 'Next step')).toBeUndefined();
  });
});

describe('history list', () => {
  const events: Prokop.HistoryEvent[] = [
    { kind: 'start', status: 'success', timestamp: 100 },
    { kind: 'reload', status: 'failure', timestamp: 200 },
    { kind: 'autotune_apply', status: 'recovered', timestamp: 300 },
    { kind: 'snapshot_delete', status: 'success', timestamp: 400 },
  ];

  it('lists the newest event first with its own words', () => {
    expect(historyItems(events, 'all').map((item) => item.title)).toEqual([
      'Snapshot deleted',
      'Autotune apply',
      'Configuration reload',
      'Service start',
    ]);
    expect(historyItems(events, 'all')[1].outcome).toEqual({
      label: 'Recovered',
      tone: 'warning',
    });
  });

  it('names what a configuration migration changed (D-13)', () => {
    const [item] = historyItems(
      [
        {
          kind: 'config_migration',
          status: 'success',
          timestamp: 5,
          notices: [
            {
              code: 'retired_rule_sets',
              section: 'games',
              values: ['cloudflare', 'amazon'],
              replacements: ['cloudflare'],
            },
            {
              code: 'retired_rule_sets',
              section: 'cdn',
              values: ['fastly'],
              replacements: [],
            },
          ],
        },
      ],
      'config',
    );
    expect(item.title).toBe('Configuration migrated by the update');
    expect(item.details).toHaveLength(2);
    expect(item.details[0]).toContain('“games”');
    expect(item.details[0]).toContain('cloudflare, amazon');
    expect(item.details[0]).toContain(
      'Built-in rule sets of the same services: cloudflare. They were not added',
    );
    expect(item.details[1]).toContain('fastly');
    expect(item.details[1]).toContain('No built-in rule set replaces them.');
    expect(historyItems(events, 'all').every((i) => !i.details.length)).toBe(
      true,
    );
  });

  it('names removed subscription settings (D-17)', () => {
    const [item] = historyItems(
      [
        {
          kind: 'config_migration',
          status: 'success',
          timestamp: 7,
          notices: [
            {
              code: 'subscription_options_removed',
              section: 'vpn',
              values: ['hwid', 'hide_detour_outbounds'],
              replacements: [],
            },
          ],
        },
      ],
      'all',
    );
    expect(item.details).toEqual([
      'Rule “vpn”: the subscription settings hwid, hide_detour_outbounds were removed. This version always generates the HWID from the router and hides nodes of imported URLTest groups and cascades.',
    ]);
  });

  it('says a stored subscription User-Agent is now sent (D-17)', () => {
    const [item] = historyItems(
      [
        {
          kind: 'config_migration',
          status: 'success',
          timestamp: 7,
          notices: [
            {
              code: 'subscription_user_agent_in_effect',
              section: 'vpn',
              values: ['user_agent'],
              replacements: [],
            },
          ],
        },
      ],
      'all',
    );
    expect(item.details).toEqual([
      'Rule “vpn”: a subscription source now sends the User-Agent set in its settings. Earlier versions ignored it and chose one automatically; clear the field to go back to automatic selection.',
    ]);
  });

  it('names a raised update interval (D-18)', () => {
    const [item] = historyItems(
      [
        {
          kind: 'config_migration',
          status: 'success',
          timestamp: 6,
          notices: [
            {
              code: 'update_interval_raised',
              section: 'settings',
              values: ['update_interval'],
              replacements: [],
              from: '5m',
              to: '1h',
            },
            {
              code: 'update_interval_raised',
              section: 'settings',
              values: ['component_update_check_interval'],
              replacements: [],
              from: '30m',
              to: '1h',
            },
          ],
        },
      ],
      'all',
    );
    expect(item.details).toEqual([
      'List update frequency was 5m, shorter than the 1 h minimum of automatic updates: set to 1h.',
      'Component update check interval was 30m, shorter than the 1 h minimum of automatic updates: set to 1h.',
    ]);
  });

  it('names manual and automatic autotune applies', () => {
    const titles = historyItems(
      [
        {
          kind: 'autotune_apply',
          status: 'success',
          timestamp: 4,
          trigger: 'manual',
          candidate: 'multisplit',
        },
        {
          kind: 'autotune_apply',
          status: 'recovered',
          timestamp: 3,
          trigger: 'automatic',
          candidate: 'fake',
        },
        { kind: 'autotune_apply', status: 'success', timestamp: 2 },
      ],
      'autotune',
    ).map((item) => item.title);
    expect(titles).toEqual([
      'Autotune: multisplit applied manually',
      'Autotune: automatic apply of fake',
      'Autotune apply',
    ]);
  });

  // UC-060, design H.6: a rollback is an autotune event of its own, never a
  // snapshot restore.
  it('names automatic and manual autotune rollbacks', () => {
    const items = historyItems(
      [
        {
          kind: 'autotune_rollback',
          status: 'success',
          timestamp: 4,
          trigger: 'automatic',
          candidate: 'fake',
        },
        {
          kind: 'autotune_rollback',
          status: 'failure',
          timestamp: 3,
          trigger: 'manual',
          candidate: 'multisplit',
        },
        {
          kind: 'autotune_rollback',
          status: 'success',
          timestamp: 2,
          trigger: 'manual',
        },
        { kind: 'autotune_rollback', status: 'success', timestamp: 1 },
      ],
      'autotune',
    );
    expect(items.map((item) => item.title)).toEqual([
      'Autotune: automatic rollback of fake',
      'Autotune: manual rollback of multisplit',
      'Autotune: manual rollback',
      'Autotune rollback',
    ]);
    expect(items[1].outcome.label).toBe('Failed');
    expect(
      historyItems(
        [{ kind: 'autotune_rollback', status: 'success', timestamp: 1 }],
        'config',
      ),
    ).toHaveLength(0);
  });

  // The journal is in the order of recording; seconds are its only clock.
  // The automatic rollback is recorded before the apply that it ended: the
  // pair keeps that order within a second as across one.
  it('lists events of the same second in the order they were recorded', () => {
    const rollback: Omit<Prokop.HistoryEvent, 'timestamp'> = {
      kind: 'autotune_rollback',
      status: 'success',
      trigger: 'automatic',
      candidate: 'fake',
    };
    const apply: Omit<Prokop.HistoryEvent, 'timestamp'> = {
      kind: 'autotune_apply',
      status: 'recovered',
      trigger: 'automatic',
      candidate: 'fake',
    };
    for (const [first, second] of [
      [7, 7],
      [7, 8],
    ])
      expect(
        historyItems(
          [
            { kind: 'start', status: 'success', timestamp: 5 },
            { ...rollback, timestamp: first },
            { ...apply, timestamp: second },
          ],
          'all',
        ).map((item) => item.title),
      ).toEqual([
        'Autotune: automatic apply of fake',
        'Autotune: automatic rollback of fake',
        'Service start',
      ]);
  });

  it('filters by category', () => {
    expect(historyItems(events, 'config').map((item) => item.title)).toEqual([
      'Snapshot deleted',
      'Configuration reload',
    ]);
    expect(historyItems(events, 'autotune')).toHaveLength(1);
    expect(
      historyItems(
        [{ kind: 'autotune_mode', status: 'success', timestamp: 1 }],
        'autotune',
      ).map((item) => item.title),
    ).toEqual(['Autotune mode changed']);
    expect(
      historyItems(
        [
          { kind: 'autotune_run', status: 'failure', timestamp: 2 },
          { kind: 'autotune_recommendation', status: 'success', timestamp: 1 },
        ],
        'autotune',
      ).map((item) => item.title),
    ).toEqual(['Autotune run', 'Autotune recommendation confirmed']);
    expect(historyItems(events, 'service').map((item) => item.title)).toEqual([
      'Service start',
    ]);
  });

  // A start or reload that could not update the scheduled jobs goes on
  // without them; the failure stays visible in the history.
  it('names a failed update of the scheduled jobs as a service event', () => {
    const items = historyItems(
      [
        { kind: 'start', status: 'success', timestamp: 2 },
        { kind: 'cron_refresh', status: 'failure', timestamp: 1 },
      ],
      'service',
    );
    expect(items.map((item) => item.title)).toEqual([
      'Service start',
      'Scheduled jobs update',
    ]);
    expect(items[1].outcome.label).toBe('Failed');
  });
});

describe('snapshots', () => {
  it('labels every reason and marks the last known good one', () => {
    expect(snapshotReasonLabel('before-autotune')).toBe('Before autotune');
    // UC-067: the reload snapshot holds the configuration the reload
    // applies; Save & Apply's holds the one before the change.
    expect(snapshotReasonLabel('before-reload')).toBe('Applied by reload');
    expect(snapshotReasonLabel('before-apply')).toBe('Before applying changes');
    expect(snapshotReasonLabel('concurrent-change')).toBe('Concurrent edit');
    expect(snapshotReasonLabel('unexpected')).toBe('Other');

    const rows = snapshotRows([
      snapshot('1_a', 10, 'manual'),
      snapshot('2_b', 20, 'last-known-working', true),
    ]);

    expect(rows.map((row) => [row.id, row.lkg, row.canDelete])).toEqual([
      ['2_b', true, false],
      ['1_a', false, true],
    ]);
    expect(rows[1].reason).toBe('Manual');
    expect(rows[0].reason).toBe('');
  });

  it('shows list changes readably', () => {
    expect(
      diffRows([
        {
          section: 'settings',
          option: 'dns_server',
          kind: 'list',
          before: ['1.1.1.1', '8.8.8.8'],
          after: [],
        },
        { section: 'youtube', option: 'nfqws_opt', before: 'a', after: '' },
      ]),
    ).toEqual([
      {
        where: 'settings · dns_server',
        snapshot: '1.1.1.1, 8.8.8.8',
        current: '—',
      },
      { where: 'youtube · nfqws_opt', snapshot: 'a', current: '—' },
    ]);
  });

  // D-2(a), UC-063: null is an option absent on that side; '***' is a
  // value that exists and is hidden.
  it('shows an absent side as not set and keeps hidden values masked', () => {
    expect(
      diffRows([
        { section: 'settings', option: 'password', before: null, after: '***' },
        {
          section: '@section_interface[0]',
          option: 'dns_type',
          before: 'udp',
          after: null,
        },
        {
          section: 'settings',
          option: 'subscription_urls',
          kind: 'list',
          before: null,
          after: ['***'],
        },
      ]),
    ).toEqual([
      { where: 'settings · password', snapshot: 'not set', current: '***' },
      {
        where: '@section_interface[0] · dns_type',
        snapshot: 'udp',
        current: 'not set',
      },
      {
        where: 'settings · subscription_urls',
        snapshot: 'not set',
        current: '***',
      },
    ]);
  });

  // UC-062: the backend lists at most 100 changes; a longer diff ends with
  // { truncated, total } in place of the rest.
  const changes = (count: number): Prokop.SnapshotChange[] =>
    Array.from({ length: count }, (_, i) => ({
      section: 'settings',
      option: `opt${i}`,
      before: 'a',
      after: 'b',
    }));

  it('counts every change of a cut diff, not only the listed ones', () => {
    const cut = snapshotDiff([
      ...changes(100),
      { truncated: true, total: 250 },
    ]);
    expect(cut.changes).toHaveLength(100);
    expect(cut.changes.some((change) => 'truncated' in change)).toBe(false);
    expect(cut.total).toBe(250);
    expect(diffTruncatedText(cut)).toBe(
      'Only the first 100 changes are listed; 250 changes in total.',
    );

    const whole = snapshotDiff(changes(3));
    expect(whole).toEqual({ changes: changes(3), total: 3 });
    expect(snapshotDiff([])).toEqual({ changes: [], total: 0 });
  });

  it('does not understate the scope of a restore', () => {
    const preview = restorePreview(
      snapshotDiff([...changes(100), { truncated: true, total: 250 }]),
      8,
    );
    expect(preview).toHaveLength(9);
    expect(preview[0]).toBe('settings · opt0: b → a');
    expect(preview[8]).toBe('and 242 more');

    expect(restorePreview(snapshotDiff(changes(10)), 8)[8]).toBe('and 2 more');
    expect(restorePreview(snapshotDiff(changes(8)), 8)).toHaveLength(8);
    expect(restorePreview(snapshotDiff(changes(3)), 8)).toEqual([
      'settings · opt0: b → a',
      'settings · opt1: b → a',
      'settings · opt2: b → a',
    ]);
  });
});

describe('restore result', () => {
  it('reports restored only for a reload that ran', () => {
    expect(restoreResultToast({ status: 'success' })).toEqual({
      text: 'Configuration restored and reloaded',
      type: 'success',
      duration: 6000,
    });
    expect(
      restoreResultToast({
        status: 'recovered',
        reason: 'target_reload_failed',
      }).text,
    ).toBe('Restore failed; previous configuration and runtime recovered');
  });

  it('does not promise a reload before a restore while Prokop is stopped', () => {
    const running = restoreConfirmMessage(false);
    expect(running).toContain('reloads the configuration');

    const stopped = restoreConfirmMessage(true);
    expect(stopped).toContain('Prokop is stopped');
    expect(stopped).toContain('when you start Prokop');
    expect(stopped).not.toContain('reloads');
  });

  it('never reports a restore while Prokop is stopped as reloaded', () => {
    const kept = restoreResultToast({
      status: 'restored_not_started',
      reason: 'service_stopped',
    });
    expect(kept.type).toBe('warning');
    expect(kept.text).toContain('Prokop is stopped');
    expect(kept.text).toContain('when Prokop is started');
    expect(kept.text).not.toContain('reloaded');

    const invalid = restoreResultToast({
      status: 'failed',
      reason: 'target_invalid',
      runtime: 'stopped',
    });
    expect(invalid.type).toBe('warning');
    expect(invalid.text).toContain('did not pass validation');
    expect(invalid.text).toContain('previous configuration is kept');

    const overtaken = restoreResultToast({
      status: 'failed',
      reason: 'service_stopped',
      runtime: 'stopped',
    });
    expect(overtaken.text).toContain('stopped during the restore');
    // Without the stop, a failure still points to the recovery state.
    expect(restoreResultToast({ status: 'failed' }).type).toBe('error');
  });

  it('names a reload that was only queued', () => {
    const recovered = restoreResultToast({
      status: 'recovered',
      reason: 'target_reload_queued',
    });
    expect(recovered.type).toBe('warning');
    expect(recovered.text).toContain('only queued the reload');
    expect(recovered.text).toContain('previous configuration is kept');

    const unfinished = restoreResultToast({
      status: 'needs_attention',
      reason: 'rollback_reload_queued',
    });
    expect(unfinished.type).toBe('error');
    expect(unfinished.text).toContain('did not finish');
    expect(unfinished.text).toContain('DPI guard stays active');
    expect(unfinished.text).not.toContain('restored');

    expect(
      restoreResultToast({
        status: 'needs_attention',
        reason: 'runtime_rollback_failed',
      }),
    ).toEqual({
      text: 'Restore failed; check the recovery state before retrying',
      type: 'error',
      duration: 8000,
    });
    expect(restoreResultToast(undefined).type).toBe('error');
  });

  it('explains why a restore was refused unchanged', () => {
    expect(
      restoreResultToast({
        status: 'busy',
        reason: 'service_action_in_progress',
      }),
    ).toEqual({
      text: snapshotBusyText('service_action_in_progress'),
      type: 'warning',
      duration: 6000,
    });
    expect(snapshotBusyText('service_action_in_progress')).toContain(
      'The service is busy',
    );
    expect(snapshotBusyText('service_action_in_progress')).toContain(
      'Nothing was changed',
    );
    expect(snapshotBusyText('snapshot_operation_in_progress')).toBe(
      'Another snapshot operation is already in progress. Try again in a moment.',
    );
    // UC-068: uci changes staged on the router would ride along.
    const staged = restoreResultToast({
      status: 'failed',
      reason: 'uncommitted_uci_changes',
    });
    expect(staged.type).toBe('warning');
    expect(staged.text).toContain('was not started');
    expect(staged.text).toContain('Commit or revert');
  });

  // UC-019: a guard that a failed lifecycle transition kept refuses the
  // restore, or ends it needs_attention; the restart comes first.
  it('asks for a restart when a kept runtime guard stops the restore', () => {
    const refused = restoreResultToast({
      status: 'failed',
      reason: 'runtime_guard_active',
    });
    expect(refused.type).toBe('warning');
    expect(refused.text).toContain('was not started');
    expect(refused.text).toContain('Restart Prokop');
    const unfinished = restoreResultToast({
      status: 'needs_attention',
      reason: 'runtime_guard_active',
      guard: 'active',
    });
    expect(unfinished.type).toBe('error');
    expect(unfinished.text).toContain('did not finish');
    expect(unfinished.text).toContain('Restart Prokop');
  });

  it('keeps an edit made during the restore instead of calling it restored', () => {
    const edited = restoreResultToast({
      status: 'needs_attention',
      reason: 'config_changed_during_transaction',
      saved_snapshot: '1790000000_1',
    });
    expect(edited.type).toBe('error');
    expect(edited.text).toContain('did not finish');
    expect(edited.text).toContain('The change is kept');
    expect(edited.text).toContain('Concurrent edit');
    expect(edited.text).toContain('DPI guard stays active');
    // UC-023: the reload ran, but it may have read the change: no success,
    // and no guard is left.
    const reloaded = restoreResultToast({
      status: 'needs_attention',
      reason: 'config_changed_during_transaction',
      guard: 'inactive',
      saved_snapshot: '1790000000_1',
    });
    expect(reloaded.type).toBe('error');
    expect(reloaded.text).toContain('did not finish');
    expect(reloaded.text).toContain('not known whether with the snapshot');
    expect(reloaded.text).toContain('The change is kept');
    expect(reloaded.text).toContain('Concurrent edit');
    expect(reloaded.text).not.toContain('DPI guard');
    // Prokop stopped during the restore: nothing reloaded, no guard left.
    const stopped = restoreResultToast({
      status: 'needs_attention',
      reason: 'config_changed_during_transaction',
      runtime: 'stopped',
      saved_snapshot: '1790000000_1',
    });
    expect(stopped.text).toContain('was not applied');
    expect(stopped.text).toContain('The change is kept');
    expect(stopped.text).toContain('Concurrent edit');
    expect(stopped.text).not.toContain('DPI guard');
  });

  it('names a snapshot of the kept edit only when one was saved', () => {
    for (const extra of [
      {},
      { guard: 'inactive' as const },
      { runtime: 'stopped' as const },
    ]) {
      const unsaved = restoreResultToast({
        status: 'needs_attention',
        reason: 'config_changed_during_transaction',
        saved_snapshot: null,
        ...extra,
      });
      expect(unsaved.type).toBe('error');
      expect(unsaved.text).toContain('The change is kept in the configuration');
      expect(unsaved.text).toContain('no snapshot of it could be saved');
      expect(unsaved.text).not.toContain('Concurrent edit');
    }
  });

  it('asks for unsaved changes of this session to be applied first', () => {
    expect(
      unsavedChangesBlockRestore(
        { prokop: [['set', 'settings', 'dns_server', '9.9.9.9']] },
        'prokop',
      ),
    ).toBe(true);
    expect(unsavedChangesBlockRestore({ prokop: [] }, 'prokop')).toBe(false);
    expect(
      unsavedChangesBlockRestore({ network: [['set', 'lan']] }, 'prokop'),
    ).toBe(false);
    // Unknown (the call failed or LuCI lacks it): nothing is blocked.
    expect(unsavedChangesBlockRestore(null, 'prokop')).toBe(false);
    expect(unsavedChangesBlockRestore(undefined, 'prokop')).toBe(false);
  });
});

// UC-022, D-14: manual snapshots stop at RETENTION-2 so the automatic ones
// keep their places; every refusal says why, and that nothing changed.
describe('snapshot refusals', () => {
  it('says why a manual snapshot was not saved and what to do', () => {
    const limit = createSnapshotToast({
      status: 'failed',
      reason: 'manual_limit_reached',
      limit: 8,
    });
    expect(limit.type).toBe('warning');
    expect(limit.text).toContain('at most 8 manual snapshots');
    expect(limit.text).toContain('Delete a manual snapshot');
    expect(limit.text).toContain('before a restore, Save & Apply or autotune');
    // At the limit one deletion makes room.
    const atLimit = createSnapshotToast({
      status: 'failed',
      reason: 'manual_limit_reached',
      limit: 8,
      manual: 8,
    });
    expect(atLimit.text).toBe(limit.text);
    // Manual snapshots kept from before the limit: the toast says how many
    // must go, not one.
    const over = createSnapshotToast({
      status: 'failed',
      reason: 'manual_limit_reached',
      limit: 8,
      manual: 10,
    });
    expect(over.type).toBe('warning');
    expect(over.text).toContain('at most 8 manual snapshots');
    expect(over.text).toContain('There are 10 manual snapshots now');
    expect(over.text).toContain('delete 3 you no longer need');
    expect(over.text).not.toContain('Delete a manual snapshot');

    expect(createSnapshotToast({ status: 'created' })).toEqual({
      text: 'Snapshot saved',
      type: 'success',
      duration: 3000,
    });
    expect(
      createSnapshotToast({
        status: 'busy',
        reason: 'snapshot_operation_in_progress',
      }),
    ).toEqual({
      text: snapshotBusyText('snapshot_operation_in_progress'),
      type: 'warning',
      duration: 6000,
    });
    for (const [reason, words] of [
      ['config_unavailable', 'could not be read'],
      ['write_failed', 'free space'],
      ['hash_unavailable', 'free space'],
      ['lock_unavailable', 'could not be locked'],
    ]) {
      const refused = createSnapshotToast({ status: 'failed', reason });
      expect(refused.text).toContain('Snapshot not saved');
      expect(refused.text).toContain(words);
    }
    expect(createSnapshotToast({ status: 'failed' }).text).toBe(
      'Could not create snapshot',
    );
    expect(createSnapshotToast(undefined).type).toBe('error');
  });

  it('names why a restore was refused before it changed anything', () => {
    for (const [reason, words] of [
      ['pre_restore_snapshot_failed', 'could not be saved as a snapshot'],
      ['invalid_snapshot', 'missing or damaged'],
      ['config_unavailable', 'could not be read'],
      ['concurrent_change', 'changed while the restore was starting'],
      ['guard_unavailable', 'DPI guard'],
      ['lock_unavailable', 'could not be locked'],
    ]) {
      const refused = restoreResultToast({ status: 'failed', reason });
      expect(refused.type).toBe('warning');
      expect(refused.text).toContain('Restore was not started');
      expect(refused.text).toContain(words);
      expect(refused.text).toContain('Nothing was changed');
      expect(refused.text).not.toContain('check the recovery state');
    }
  });

  it('keeps the previous configuration when it cannot be replaced', () => {
    const own = restoreResultToast({
      status: 'failed',
      reason: 'replace_failed',
    });
    expect(own.type).toBe('warning');
    expect(own.text).toContain('could not be written');
    expect(own.text).toContain('previous configuration is kept');
    expect(own.text).not.toContain('DPI guard');
    // A guard an earlier restore left stays active.
    const inherited = restoreResultToast({
      status: 'failed',
      reason: 'replace_failed',
      guard: 'active',
    });
    expect(inherited.text).toContain('previous configuration is kept');
    expect(inherited.text).toContain(
      'DPI guard of an earlier restore stays active',
    );
  });

  it('says that the guard of an earlier restore stays after a refusal', () => {
    const edited = restoreResultToast({
      status: 'failed',
      reason: 'concurrent_change',
      guard: 'active',
    });
    expect(edited.type).toBe('warning');
    expect(edited.text).toContain('changed while the restore was starting');
    expect(edited.text).toContain(
      'DPI guard of an earlier restore stays active',
    );
    expect(
      restoreResultToast({ status: 'failed', reason: 'concurrent_change' })
        .text,
    ).not.toContain('DPI guard');
  });
});

// D-16, UC-065: a snapshot of an older release is migrated on a copy before
// it is restored. The confirmation says so beforehand; a snapshot that
// cannot be migrated is refused with nothing changed; a finished restore
// names the migration.
describe('restore migration', () => {
  const migration = { from: '1.0.23', to: '1.0.33' };

  it('warns before the restore, from which version to which', () => {
    expect(restoreMigrationNote(null)).toBeNull();
    const note = restoreMigrationNote(migration) ?? '';
    expect(note).toContain('saved by Prokop 1.0.23');
    expect(note).toContain('migrated to the current version 1.0.33');
    expect(note).toContain('The snapshot itself is not changed');
    // A snapshot whose release was not recorded is still named older.
    const unknown =
      restoreMigrationNote({ from: 'unknown', to: '1.0.33' }) ?? '';
    expect(unknown).toContain('an older version of Prokop');
    expect(unknown).toContain('1.0.33');
    expect(unknown).not.toContain('unknown');
  });

  it('says that a snapshot that cannot be migrated was not restored', () => {
    const refused = restoreResultToast({
      status: 'failed',
      reason: 'snapshot_migration_failed',
      detail: 'incomplete',
      migration,
    });
    expect(refused.type).toBe('warning');
    expect(refused.text).toContain('Restore was not started');
    expect(refused.text).toContain('could not be migrated');
    expect(refused.text).toContain('Nothing was changed');
  });

  it('names the migration of a finished restore', () => {
    const done = restoreResultToast({
      status: 'success',
      migration: { ...migration, migrations: ['vpn_guard_kill_switch_v1'] },
    });
    expect(done.type).toBe('success');
    expect(done.text).toContain('Configuration restored and reloaded');
    expect(done.text).toContain('migrated from Prokop 1.0.23 to 1.0.33');
    const kept = restoreResultToast({
      status: 'restored_not_started',
      reason: 'service_stopped',
      migration,
    });
    expect(kept.type).toBe('warning');
    expect(kept.text).toContain('Prokop is stopped');
    expect(kept.text).toContain('migrated from Prokop 1.0.23 to 1.0.33');
    expect(
      restoreResultToast({
        status: 'success',
        migration: { from: 'unknown', to: '1.0.33' },
      }).text,
    ).toContain('migrated to Prokop 1.0.33');
    // Without a migration the texts stay as they were.
    expect(restoreResultToast({ status: 'success' }).text).toBe(
      'Configuration restored and reloaded',
    );
  });
});
