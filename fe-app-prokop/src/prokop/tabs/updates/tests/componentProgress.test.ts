import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  downloadText,
  formatBytes,
  formatDuration,
  normalizeProgress,
  stageRows,
  viewDuration,
} from '../componentProgress';
import {
  observeRouterTime,
  resetRouterClock,
  routerNowSeconds,
} from '../../../helpers/routerClock';
import type { Prokop } from '../../../types';

const g = globalThis as unknown as { _: (key: string) => string };
const ru: Record<string, string> = {
  '%s s': '%s с',
  '%s min %s s': '%s мин %s с',
  '%s h %s min': '%s ч %s мин',
  '%s B': '%s Б',
  '%s KB': '%s КБ',
  '%s MB': '%s МБ',
  'file %s of %s': 'файл %s из %s',
  '%s of %s (%s%)': '%s из %s (%s%)',
  '%s received': 'получено %s',
};

function view(
  overrides: Partial<Prokop.ComponentProgressView> = {},
): Prokop.ComponentProgressView {
  return {
    component: 'prokop',
    action: 'install',
    jobId: '1-1',
    running: true,
    startedAt: 1000,
    finishedAt: 0,
    progress: normalizeProgress({
      stage: 'download',
      stages: [
        { id: 'resolve', started_at: 1000, finished_at: 1002 },
        { id: 'download', started_at: 1002, finished_at: null },
      ],
      download: null,
      outcome: '',
      started_at: 1000,
      updated_at: 1005,
    }),
    ...overrides,
  };
}

describe('component action progress', () => {
  const original = g._;

  beforeEach(() => {
    g._ = (key: string) => ru[key] ?? key;
    resetRouterClock();
  });

  afterEach(() => {
    g._ = original;
    resetRouterClock();
  });

  it('formats times and sizes in Russian', () => {
    expect(formatDuration(42)).toBe('42 с');
    expect(formatDuration(65)).toBe('1 мин 05 с');
    expect(formatDuration(3720)).toBe('1 ч 02 мин');
    expect(formatDuration(-3)).toBe('0 с');
    expect(formatBytes(512)).toBe('512 Б');
    expect(formatBytes(1536)).toBe('1.5 КБ');
    expect(formatBytes(3 * 1024 * 1024)).toBe('3.0 МБ');
  });

  it('shows a percentage only against a published size', () => {
    expect(
      downloadText({
        file: 'prokop_2.21.0.apk',
        bytes: 1024 * 1024,
        total: 4 * 1024 * 1024,
        index: 1,
        count: 3,
      }),
    ).toBe('prokop_2.21.0.apk, файл 1 из 3: 1.0 МБ из 4.0 МБ (25%)');
    expect(
      downloadText({
        file: 'x.apk',
        bytes: 2048,
        total: 0,
        index: 0,
        count: 0,
      }),
    ).toBe('x.apk: получено 2.0 КБ');
  });

  it('passes only known fields of the right type', () => {
    expect(normalizeProgress(null)).toBeNull();
    expect(normalizeProgress('x')).toBeNull();
    const progress = normalizeProgress({
      stage: 'rm -rf',
      stages: [
        { id: 'download', started_at: 5, finished_at: null },
        { id: 'unknown', started_at: 6 },
        { id: 'install', started_at: 'soon' },
        'junk',
      ],
      download: { file: 7, bytes: -1, total: 10.7 },
      outcome: 'maybe',
    });
    expect(progress?.stage).toBe('');
    expect(progress?.stages).toEqual([
      { id: 'download', started_at: 5, finished_at: null },
    ]);
    expect(progress?.download).toEqual({
      file: '',
      bytes: 0,
      total: 10,
      index: 0,
      count: 0,
    });
    expect(progress?.outcome).toBe('');
  });

  it('lists done, current and upcoming stages while running', () => {
    const rows = stageRows(view());
    expect(rows.map((row) => `${row.id}:${row.state}`)).toEqual([
      'resolve:done',
      'download:current',
      'verify:pending',
      'prepare:pending',
      'stop:pending',
      'install:pending',
      'restart:pending',
      'check:pending',
    ]);
  });

  it('lists only the stages a finished action went through', () => {
    const failed = view({
      running: false,
      success: false,
      progress: normalizeProgress({
        stage: 'verify',
        stages: [
          { id: 'resolve', started_at: 1000, finished_at: 1002 },
          { id: 'download', started_at: 1002, finished_at: 1030 },
          { id: 'verify', started_at: 1030, finished_at: 1031 },
        ],
        outcome: 'failed',
        started_at: 1000,
      }),
    });
    expect(stageRows(failed).map((row) => `${row.id}:${row.state}`)).toEqual([
      'resolve:done',
      'download:done',
      'verify:failed',
    ]);
    expect(viewDuration(failed)).toBe(31);
  });

  it('a fresh TorrServer install has nothing to stop', () => {
    const rows = stageRows(
      view({
        component: 'torrserver',
        progress: normalizeProgress({
          stage: 'resolve',
          stages: [{ id: 'resolve', started_at: 1, finished_at: null }],
        }),
      }),
      false,
    );
    expect(rows.map((row) => row.id)).toEqual([
      'resolve',
      'download',
      'verify',
      'install',
      'start',
    ]);
  });

  it('measures the elapsed time on the router clock', () => {
    // The router is 100 s behind the browser.
    observeRouterTime(1900, 2_000_000);
    expect(routerNowSeconds(2_010_000)).toBe(1910);
    // A later, tighter observation wins; an older timestamp does not.
    observeRouterTime(1960, 2_059_000);
    observeRouterTime(1000, 2_060_000);
    expect(routerNowSeconds(2_061_000)).toBe(1962);
    expect(viewDuration(view({ startedAt: 1900, progress: null }))).toBeCloseTo(
      routerNowSeconds() - 1900,
      0,
    );
  });
});
