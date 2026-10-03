import { afterEach, describe, expect, it, vi } from 'vitest';

import { prettyBytes, prettyBytesRate } from '../prettyBytes';

const RU: Record<string, string> = {
  B: 'Б',
  KB: 'КБ',
  MB: 'МБ',
  '%s/s': '%s/с',
};

describe('prettyBytes', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('keeps the English units by default', () => {
    expect(prettyBytes(12)).toBe('12 B');
    expect(prettyBytes(4200000)).toBe('4.2 MB');
    expect(prettyBytesRate(1000)).toBe('1 KB/s');
  });

  it('localizes byte and rate units through the catalog', () => {
    vi.spyOn(
      globalThis as unknown as { _: (key: string) => string },
      '_',
    ).mockImplementation((key: string) => RU[key] ?? key);

    expect(prettyBytes(12)).toBe('12 Б');
    expect(prettyBytes(310000)).toBe('310 КБ');
    expect(prettyBytesRate(4200000)).toBe('4.2 МБ/с');
  });
});
