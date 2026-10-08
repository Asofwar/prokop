import { beforeEach, describe, expect, it, vi } from 'vitest';
import { attachDnsProfiles } from '../dnsProfiles';

function formFixture() {
  const values = new Map<string, unknown>([
    ['dns_type', 'udp'],
    ['dns_server', ['192.0.2.53']],
  ]);
  const options = new Map();
  const option = (name: string) => {
    const result = {
      option: name,
      value: vi.fn(),
      depends: vi.fn(),
      cfgvalue: () => values.get(name),
      formvalue: () => values.get(name),
      getUIElement: () => ({
        setValue: (value: unknown) => values.set(name, value),
      }),
      map: { checkDepends: vi.fn() },
      onchange: undefined as
        | ((event: Event, id: string, value: string) => void)
        | undefined,
    };
    options.set(name, result);
    return result;
  };
  const protocol = option('dns_type');
  const server = option('dns_server');
  attachDnsProfiles(
    {
      option: (_kind, name) => option(name),
      taboption: (_tab, _kind, name) => option(name),
    },
    protocol,
    server,
    { ListValue: {} },
  );
  return {
    values,
    choose: (name: string) =>
      options.get('_dns_profile').onchange(null, 'settings', name),
    profileValue: () => options.get('_dns_profile').cfgvalue('settings'),
    changeProtocol: (name: string) =>
      protocol.onchange?.(null as unknown as Event, 'settings', name),
  };
}

beforeEach(() => vi.stubGlobal('_', (text: string) => text));

describe('DNS profile custom memory', () => {
  it('recognizes a persisted singleton DNS list as its preset', () => {
    const f = formFixture();
    f.values.set('dns_server', ['1.1.1.1']);
    expect(f.profileValue()).toBe('cloudflare_udp');
    f.values.set('dns_server', ['1.1.1.1', '192.0.2.53']);
    expect(f.profileValue()).toBe('custom');
  });
  it('keeps a custom address after multiple presets of the same protocol', () => {
    const f = formFixture();
    f.choose('cloudflare_udp');
    f.choose('yandex_udp');
    f.choose('custom');
    expect(f.values.get('dns_server')).toEqual(['192.0.2.53']);
  });
});
