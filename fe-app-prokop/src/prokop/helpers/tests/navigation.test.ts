import { afterEach, describe, expect, it } from 'vitest';

import { prokopPageUrl, readPageParams } from '../navigation';
import { isActiveLuciTab } from '../isActiveLuciTab';
import { setStandalonePage } from '../../services/prokopPage';

const g = globalThis as unknown as { L?: unknown };

afterEach(() => {
  delete g.L;
  setStandalonePage(null);
});

describe('Prokop page links', () => {
  it('builds the page URL through LuCI', () => {
    g.L = { url: (...parts: string[]) => `/cgi-bin/luci/${parts.join('/')}` };

    expect(prokopPageUrl('diagnostics')).toBe(
      '/cgi-bin/luci/admin/services/prokop/diagnostics',
    );
  });

  it('carries page parameters in the hash', () => {
    expect(prokopPageUrl('monitoring', { search: 'youtube.com' })).toBe(
      '/cgi-bin/luci/admin/services/prokop/monitoring#search=youtube.com',
    );
    expect(readPageParams('#search=youtube.com&device=192.168.1.2')).toEqual({
      search: 'youtube.com',
      device: '192.168.1.2',
    });
    expect(readPageParams('')).toEqual({});
  });
});

describe('active page without LuCI tabs', () => {
  it('treats the registered page as the active tab', () => {
    expect(isActiveLuciTab('monitoring')).toBe(false);

    setStandalonePage('monitoring');

    expect(isActiveLuciTab('monitoring')).toBe(true);
    expect(isActiveLuciTab('dashboard')).toBe(false);
  });
});
