import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  canUseDirectClashApi,
  getClashApiSecretFromSettings,
  getClashWsStreamUrl,
} from '../getClashApiUrl';

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('canUseDirectClashApi', () => {
  it('allows direct Clash API access from HTTP LuCI with the secret', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'http:' },
    });

    expect(canUseDirectClashApi('secret')).toBe(true);
  });

  it('blocks direct Clash API access without the secret (read-only sessions)', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'http:' },
    });

    expect(canUseDirectClashApi('')).toBe(false);
    expect(canUseDirectClashApi('   ')).toBe(false);
  });

  it('blocks direct Clash API access from HTTPS LuCI', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'https:' },
    });

    expect(canUseDirectClashApi('secret')).toBe(false);
  });

  it('blocks direct Clash API access outside a browser location', () => {
    vi.stubGlobal('window', undefined);

    expect(canUseDirectClashApi('secret')).toBe(false);
  });
});

describe('getClashApiSecretFromSettings', () => {
  // Same predicate as clash_api_secret() in core/common.uc: the secret
  // applies whenever it is set, whatever YACD and WAN access say.
  it('returns the trimmed secret regardless of YACD and WAN access', () => {
    expect(
      getClashApiSecretFromSettings({
        yacd_secret_key: '  secret  ',
        enable_yacd: '0',
        enable_yacd_wan_access: '0',
      }),
    ).toBe('secret');
  });

  it('returns an empty secret when none is configured', () => {
    expect(getClashApiSecretFromSettings(undefined)).toBe('');
    expect(getClashApiSecretFromSettings({})).toBe('');
    expect(getClashApiSecretFromSettings({ yacd_secret_key: ' ' })).toBe('');
  });
});

describe('getClashWsStreamUrl', () => {
  it('URL-encodes the secret in the token parameter', () => {
    vi.stubGlobal('window', { location: { hostname: 'router.example' } });

    expect(getClashWsStreamUrl('/traffic', 'a&b=c d')).toBe(
      'ws://router.example:9090/traffic?token=a%26b%3Dc%20d',
    );
  });
});
