import { beforeEach, describe, expect, it, vi } from 'vitest';

const checkFakeIP = vi.fn();
const getFakeIpCheck = vi.fn();
const getIpCheck = vi.fn();
vi.mock('../../../methods', () => ({
  ProkopShellMethods: { checkFakeIP: () => checkFakeIP() },
  RemoteFakeIPMethods: {
    getFakeIpCheck: () => getFakeIpCheck(),
    getIpCheck: () => getIpCheck(),
  },
}));
vi.mock('../../../services', () => ({}));
vi.mock('../../../services/tab.service', () => ({ setProkopPage: vi.fn() }));
const updateCheckStore = vi.fn();
vi.mock('../checks/updateCheckStore', () => ({
  updateCheckStore: (check: unknown) => updateCheckStore(check),
}));

import { runFakeIPCheck } from '../checks/runFakeIPCheck';

interface StoredCheck {
  state: string;
  description: string;
  items: { state: string; key: string }[];
}
const lastCheck = () => updateCheckStore.mock.lastCall?.[0] as StoredCheck;

describe('FakeIP check', () => {
  beforeEach(() => {
    updateCheckStore.mockReset();
    getFakeIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '203.0.113.1' },
    });
    getIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: false, IP: '203.0.113.2' },
    });
  });

  it('shows a failed router call as not checked, not as broken FakeIP DNS', async () => {
    checkFakeIP.mockResolvedValue({ success: false, error: 'timed out' });
    await runFakeIPCheck();
    const check = lastCheck();
    expect(check.state).toBe('warning');
    expect(check.description).toBe(
      'Router FakeIP check could not be completed',
    );
    expect(check.items[0]).toMatchObject({
      state: 'warning',
      key: 'Router FakeIP check could not be completed',
    });
    expect(JSON.stringify(check)).not.toContain('does not work');
  });

  it('still reports an observed FakeIP DNS failure as an error', async () => {
    checkFakeIP.mockResolvedValue({
      success: true,
      data: { fakeip: false, IP: '93.184.216.34' },
    });
    getFakeIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: false, IP: '203.0.113.1' },
    });
    await runFakeIPCheck();
    const check = lastCheck();
    expect(check.state).toBe('error');
    expect(check.items[0]).toMatchObject({
      state: 'error',
      key: 'Sing-box FakeIP DNS does not work',
    });
  });
});
