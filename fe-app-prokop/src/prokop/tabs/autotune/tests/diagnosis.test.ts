import { describe, expect, it } from 'vitest';

import {
  applyOutcomeView,
  blockerText,
  blockTypeText,
  clockWarning,
  groupCards,
  mutationErrorText,
  outsideReasonText,
  runProgressView,
  targetReasonText,
  targetRows,
} from '../model';
import type { Prokop } from '../../../types';

const status = (
  overrides: Partial<Prokop.AutotuneStatus> = {},
): Prokop.AutotuneStatus => ({
  status: 'ok',
  policy: {
    mode: 'recommend',
    interval: '6h',
    confirmations: 3,
    min_confidence: 'high',
    max_applies_per_day: 1,
    cooldown: '24h',
    probes: 5,
  },
  errors: [],
  targets: [],
  groups: {},
  next_run_at: null,
  worker: null,
  recovered_at: null,
  state_recovered: null,
  ...overrides,
});

describe('autotune diagnosis texts', () => {
  it('names every block type and stays silent for none and unclear', () => {
    for (const type of [
      'ip_block',
      'sni_block',
      'tls_block',
      'tls12_only',
      'tls13_only',
      'transfer_cut',
      'cert_mismatch',
      'clock_problem',
      'dns_spoof',
    ])
      expect(blockTypeText(type)).not.toBe('');
    expect(blockTypeText('none')).toBe('');
    expect(blockTypeText('unclear')).toBe('');
    expect(blockTypeText(undefined)).toBe('');
  });

  it('recommends a connection rule for an address block, changing nothing', () => {
    const text = targetReasonText('ip_blocked');
    expect(text).toContain('connection (proxy or VPN) rule');
    expect(text).toContain('Prokop changes nothing');
  });

  it('explains clock, spoofed DNS and ByeDPI reasons without raw codes', () => {
    for (const reason of ['clock_problem', 'clock_unsynced', 'dns_spoofed'])
      expect(targetReasonText(reason)).not.toMatch(/_/);
    expect(outsideReasonText('byedpi_isolation_unavailable')).toContain(
      'ByeDPI',
    );
    expect(blockerText('clock_unsynced')).toContain('clock');
    expect(mutationErrorText('invalid_large_path')).toContain('/');
    expect(mutationErrorText('large_path_needs_host')).not.toBe(
      mutationErrorText(undefined),
    );
  });

  it('shows the diagnosis next to the result of a target', () => {
    const [row] = targetRows(
      status({
        targets: [
          {
            id: 't_x',
            host: 'x.example',
            enabled: true,
            resolver: null,
            last: {
              at: 1,
              status: 'inconclusive',
              reason: 'ip_blocked',
              selected: null,
              confidence: null,
              block: { type: 'ip_block' },
              candidates: [],
            },
          },
        ],
      }).targets,
    );
    expect(row.result).toContain('Blocked by address');
    expect(row.tone).toBe('warning');
  });

  it('warns about an unsynchronized clock only', () => {
    expect(
      clockWarning({
        state: 'unsynced',
        source: 'release_date',
        stratum: null,
        observed_at: null,
        reason: 'clock_before_release',
      }),
    ).toContain('behind');
    expect(
      clockWarning({
        state: 'unknown',
        source: 'none',
        stratum: null,
        observed_at: null,
        reason: 'ntp_not_running',
      }),
    ).toBeNull();
    expect(clockWarning(undefined)).toBeNull();
  });

  it('does not blame the strategy for a clock-caused rollback', () => {
    expect(
      applyOutcomeView('rolled_back', 'verification_clock_problem').label,
    ).toContain('clock');
  });

  it('shows a Zapret2 recommendation as not applicable with its reason', () => {
    const result: Prokop.AutotuneGroupResult = {
      status: 'not_applicable',
      candidate: 'z2_fake',
      confidence: 'high',
      reason: 'zapret2_apply_unsupported',
    };
    const [card] = groupCards(
      status({
        groups: {
          z2: {
            pending: null,
            last: {
              status: 'not_applicable',
              candidate: 'z2_fake',
              confidence: 'high',
              reason: 'zapret2_apply_unsupported',
              at: 1,
            },
            cooldowns: {},
            last_apply: null,
            label: 'Z2',
            targets: [],
            current: 'default',
            ready: false,
            required: 3,
            result,
          } as Prokop.AutotuneGroupState,
        },
      }),
      null,
    );
    expect(card.recommended).toBe('z2_fake');
    expect(card.applyCandidate).toBeNull();
    expect(card.explanation.join(' ')).toContain('Zapret2');
  });

  it('reports the diagnosing phase of a running check', () => {
    const view = runProgressView(
      {
        state: 'running',
        progress: {
          started_at: 1,
          total: 1,
          done: 0,
          items: [
            {
              id: 't_x',
              host: 'x.example',
              parent: null,
              group: 'g',
              state: 'running',
              expected_s: 150,
              started_at: 1,
            },
          ],
        },
        tune: { phase: 'diagnosing', done: 0, total: 9 },
      } as Prokop.AutotuneWorker,
      10,
    );
    expect(view?.phase).toContain('blocked');
  });
});
