import { describe, expect, it } from 'vitest';

import {
  describeListUpdateStatus,
  failedSourceText,
} from '../listsUpdateStatus';

const at = (seconds: number) => new Date(seconds * 1000).toLocaleString();

describe('lists update summary', () => {
  it('reports an update in progress, also right after the start', () => {
    expect(
      describeListUpdateStatus(
        { running: true, last_success_at: 0, last_result: null },
        false,
      ).tone,
    ).toBe('loading');
    expect(describeListUpdateStatus(null, true).tone).toBe('loading');
  });

  it('shows the time of a successful update', () => {
    const summary = describeListUpdateStatus(
      {
        running: false,
        last_success_at: 1700000000,
        last_result: {
          started_at: 1699999990,
          finished_at: 1700000000,
          success: true,
          failed_sources: [],
        },
      },
      false,
    );
    expect(summary.tone).toBe('success');
    expect(summary.text).toContain(at(1700000000));
    expect(summary.failedSources).toEqual([]);
  });

  it('lists the failed sources and the lists that stay in use', () => {
    const summary = describeListUpdateStatus(
      {
        running: false,
        last_success_at: 1690000000,
        last_result: {
          started_at: 1700000000,
          finished_at: 1700000010,
          success: false,
          failed_sources: ['list source bad.test/list.txt'],
        },
      },
      false,
    );
    expect(summary.tone).toBe('error');
    expect(summary.text).toContain(at(1700000010));
    expect(summary.text).toContain(at(1690000000));
    expect(summary.failedSources).toEqual(['List source: bad.test/list.txt']);
  });

  it('names the failed sources in the UI language (FE-15)', () => {
    expect(
      [
        "remote rule set rule 'Video': cdn.test/video.srs",
        "remote domain list rule 'Ads' remote source",
        'remote plain subnet list configured remote source',
        'built-in telegram subnet list',
        'something the page does not know',
      ].map(failedSourceText),
    ).toEqual([
      'Rule set: rule “Video”: cdn.test/video.srs',
      'Domain list: rule “Ads”',
      'Subnet list (text): configured source',
      'Built-in subnet list: telegram',
      'A list source; the details are in the system log',
    ]);
  });

  it('falls back to the last success when no result was recorded', () => {
    expect(
      describeListUpdateStatus(
        { running: false, last_success_at: 1690000000, last_result: null },
        false,
      ).text,
    ).toContain(at(1690000000));
    expect(
      describeListUpdateStatus(
        { running: false, last_success_at: 0, last_result: null },
        false,
      ).tone,
    ).toBe('neutral');
    expect(describeListUpdateStatus(null, false).tone).toBe('neutral');
  });
});
