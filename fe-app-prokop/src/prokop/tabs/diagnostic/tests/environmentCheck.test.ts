import { beforeEach, describe, expect, it, vi } from 'vitest';

const checkEnvironment = vi.fn();
vi.mock('../../../methods', () => ({
  ProkopShellMethods: { checkEnvironment: () => checkEnvironment() },
}));
vi.mock('../../../services', () => ({}));
vi.mock('../../../services/tab.service', () => ({ setProkopPage: vi.fn() }));
const updateCheckStore = vi.fn();
vi.mock('../checks/updateCheckStore', () => ({
  updateCheckStore: (check: unknown) => updateCheckStore(check),
}));

import { runEnvironmentCheck } from '../checks/runEnvironmentCheck';

interface StoredCheck {
  state: string;
  description: string;
  items: { state: string; key: string; value: string }[];
}
const lastCheck = () => updateCheckStore.mock.lastCall?.[0] as StoredCheck;

describe('Environment check', () => {
  beforeEach(() => updateCheckStore.mockReset());

  it('is not available for checking on a backend without the command', async () => {
    checkEnvironment.mockResolvedValue({ success: false, error: 'usage' });
    await runEnvironmentCheck();
    expect(lastCheck()).toMatchObject({
      state: 'unsupported',
      description: 'Not available for checking',
      items: [],
    });
  });

  it('passes with offloading off, IPv6 handled and the clock synchronized', async () => {
    checkEnvironment.mockResolvedValue({
      success: true,
      data: {
        flow_offloading: { state: 'ok', provenance: 'configured' },
        ipv6: {
          state: 'ok',
          provenance: 'observed',
          prokop_ipv6: true,
          global_interfaces: ['br-lan'],
        },
        clock: { state: 'ok', provenance: 'observed', stratum: 2 },
      },
    });
    await runEnvironmentCheck();
    const check = lastCheck();
    expect(check.state).toBe('success');
    expect(check.items.map((item) => item.state)).toEqual([
      'success',
      'success',
      'success',
    ]);
    expect(check.items[0].value).toBe('Off (From configuration)');
    expect(check.items[1].value).toBe(
      'Global IPv6 on br-lan; Prokop handles IPv6 (Observed)',
    );
    expect(check.items[2].value).toBe('Synchronized, stratum 2 (Observed)');
  });

  it('warns about offloading and unhandled IPv6, clock module missing', async () => {
    checkEnvironment.mockResolvedValue({
      success: true,
      data: {
        flow_offloading: {
          state: 'warning',
          provenance: 'configured',
          software: true,
          hardware: true,
        },
        ipv6: {
          state: 'warning',
          provenance: 'observed',
          prokop_ipv6: false,
          global_interfaces: ['br-lan', 'pppoe-wan'],
        },
        clock: {
          state: 'unavailable',
          provenance: 'observed',
          reason: 'clock_module_missing',
        },
      },
    });
    await runEnvironmentCheck();
    const check = lastCheck();
    expect(check.state).toBe('warning');
    expect(check.items[0].state).toBe('warning');
    expect(check.items[0].value).toContain('Hardware offloading is on');
    expect(check.items[1].value).toContain('br-lan, pppoe-wan');
    expect(check.items[1].value).toContain('Prokop runs IPv4 only');
    expect(check.items[2]).toMatchObject({
      state: 'neutral',
      key: 'Router clock',
      value: 'Not available for checking',
    });
    // No raw backend enum reaches the page.
    expect(JSON.stringify(check)).not.toContain('clock_module_missing');
  });

  it('shows an unknown clock as not checked and only neutral rows as unsupported', async () => {
    checkEnvironment.mockResolvedValue({
      success: true,
      data: {
        flow_offloading: { state: 'unavailable' },
        ipv6: { state: 'unavailable' },
        clock: { state: 'not_checked', provenance: 'observed' },
      },
    });
    await runEnvironmentCheck();
    const check = lastCheck();
    expect(check.state).toBe('unsupported');
    expect(check.items[2].value).toBe('Not checked');
  });
});
