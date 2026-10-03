import { afterEach, describe, expect, it, vi } from 'vitest';

import { formatDate, formatDateTime, uiLocale } from '../time';

// 2026-09-28 14:10:00 UTC
const TS = Date.UTC(2026, 8, 28, 14, 10, 0) / 1000;

function stubLang(lang: string) {
  vi.stubGlobal('document', { documentElement: { lang } });
}

describe('UI date formatting', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('follows the LuCI UI language, not the browser locale', () => {
    stubLang('ru');
    expect(formatDateTime(TS)).toBe(new Date(TS * 1000).toLocaleString('ru'));
    expect(formatDate(TS)).toMatch(/^\d{2}\.\d{2}\.2026$/);

    stubLang('en');
    expect(formatDateTime(TS)).toBe(new Date(TS * 1000).toLocaleString('en'));
    expect(formatDateTime(TS)).not.toBe(
      new Date(TS * 1000).toLocaleString('ru'),
    );
  });

  it('accepts LuCI codes with an underscore and ignores unknown or empty ones', () => {
    stubLang('zh_Hans');
    expect(uiLocale()).toBe('zh-Hans');

    stubLang('');
    expect(uiLocale()).toBeUndefined();

    stubLang('not a locale!');
    expect(uiLocale()).toBeUndefined();
    expect(() => formatDateTime(TS)).not.toThrow();
  });

  it('works without a document', () => {
    expect(uiLocale()).toBeUndefined();
    expect(formatDateTime(TS)).toBe(new Date(TS * 1000).toLocaleString());
  });
});
