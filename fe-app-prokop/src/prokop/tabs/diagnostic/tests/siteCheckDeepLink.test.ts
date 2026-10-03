import { afterEach, describe, expect, it, vi } from 'vitest';

const routeTrace = vi.fn();
const connectivityTest = vi.fn();
vi.mock('../../../methods', () => ({
  ProkopShellMethods: {
    routeTrace: (...args: unknown[]) => routeTrace(...args),
    connectivityTest: (...args: unknown[]) => connectivityTest(...args),
  },
}));

import { initSiteCheck } from '../siteCheck';

describe('site check deep link', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('pre-fills the address from #host= but waits for a click', () => {
    const elements: Record<string, Record<string, unknown>> = {
      'site-check-run': { onclick: null, click: vi.fn() },
      'site-check-target': { value: '' },
      'site-check-result': { replaceChildren: vi.fn() },
    };
    vi.stubGlobal('document', {
      getElementById: (id: string) => elements[id] || null,
    });
    vi.stubGlobal('window', {
      location: { hash: '#host=tracker.example' },
    });

    initSiteCheck();

    expect(elements['site-check-target'].value).toBe('tracker.example');
    expect(elements['site-check-run'].click).not.toHaveBeenCalled();
    expect(routeTrace).not.toHaveBeenCalled();
    expect(connectivityTest).not.toHaveBeenCalled();
  });
});
