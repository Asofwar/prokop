import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  checkNftRules: vi.fn(),
  updateCheckStore: vi.fn(),
}));

vi.mock('../../../../methods', () => ({
  ProkopShellMethods: { checkNftRules: mocks.checkNftRules },
  RemoteFakeIPMethods: {
    getFakeIpCheck: vi.fn().mockResolvedValue({}),
    getIpCheck: vi.fn().mockResolvedValue({}),
  },
}));

vi.mock('../updateCheckStore', () => ({
  updateCheckStore: mocks.updateCheckStore,
}));

import { runNftCheck } from '../runNftCheck';

const healthy = {
  table_exist: 1,
  rules_mangle_exist: 1,
  rules_mangle_counters: 1,
  rules_mangle_output_exist: 1,
  rules_mangle_output_counters: 1,
  rules_proxy_exist: 1,
  rules_proxy_counters: 1,
  rules_other_mark_exist: 0,
};

function item(key: string) {
  const calls = mocks.updateCheckStore.mock.calls;
  const last = calls[calls.length - 1][0];
  return last.items.find((i: { key: string }) => i.key === key);
}

describe('runNftCheck', () => {
  beforeEach(() => {
    mocks.checkNftRules.mockReset();
    mocks.updateCheckStore.mockReset();
  });

  it('shows idle router-originated capture counters as a warning, not an error', async () => {
    mocks.checkNftRules.mockResolvedValue({
      success: true,
      data: { ...healthy, rules_mangle_output_counters: 0 },
    });
    await runNftCheck();
    expect(item('Rules mangle output counters').state).toBe('warning');
    expect(item('Rules mangle output exist').state).toBe('success');
  });

  it('reports foreign marking rules as a warning', async () => {
    mocks.checkNftRules.mockResolvedValue({
      success: true,
      data: { ...healthy, rules_other_mark_exist: 1 },
    });
    await runNftCheck();
    expect(item('Additional marking rules found').state).toBe('warning');
  });
});
