import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { Prokop } from '../../types';
import { store } from '../store.service';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  runtimeUiStatePollDelay,
  subscribeRuntimeUiState,
} from '../runtimeUiState.service';
import { setProkopAutostart } from '../../tabs/shared/serviceControl';

function createUiState(
  status = 'running & enabled',
  running = 1,
): Prokop.UiState {
  return {
    service: {
      prokop: {
        running,
        enabled: 1,
        status,
        dns_configured: running,
      },
      sing_box: {
        running,
        enabled: 0,
        status: running ? 'running but disabled' : 'stopped & disabled',
      },
    },
    capabilities: {
      sing_box_extended: 1,
      sing_box_tiny: 0,
      sing_box_compressed: 0,
      sing_box_tailscale: 1,
      zapret_installed: 1,
      zapret2_installed: 1,
      byedpi_installed: 0,
    },
    actions: {
      service: [],
      latency: [],
      component: [],
      subscription: [],
    },
  };
}

describe('refreshRuntimeUiState', () => {
  beforeEach(() => {
    store.reset();
    mocks.executeShellCommand.mockReset();
  });

  it('applies current UI state to the shared store', async () => {
    const uiState = createUiState('stopped but enabled', 0);

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await expect(refreshRuntimeUiState({ force: true })).resolves.toEqual(
      uiState,
    );

    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/prokop',
      args: ['get_ui_state'],
      timeout: 3000,
      shared: true,
    });
    expect(store.get().servicesInfoWidget.data).toMatchObject({
      prokopRunning: 0,
      prokopEnabled: 1,
      prokopStatus: 'stopped but enabled',
    });
  });

  it('coalesces concurrent refreshes into one RPC call', async () => {
    const uiState = createUiState();
    let resolveRpc: (value: {
      stdout: string;
      stderr: string;
      code: number;
    }) => void = () => undefined;

    mocks.executeShellCommand.mockReturnValue(
      new Promise((resolve) => {
        resolveRpc = resolve;
      }),
    );

    const firstRefresh = refreshRuntimeUiState({ force: true });
    const secondRefresh = refreshRuntimeUiState();

    expect(mocks.executeShellCommand).toHaveBeenCalledTimes(1);

    resolveRpc({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await expect(Promise.all([firstRefresh, secondRefresh])).resolves.toEqual([
      uiState,
      uiState,
    ]);
  });

  it('runs one follow-up refresh for forced callers that join an in-flight poll', async () => {
    const oldState = createUiState('running but disabled', 1);
    oldState.service.prokop.enabled = 0;
    const newState = createUiState('running & enabled', 1);
    const rpcResolvers: Array<
      (value: { stdout: string; stderr: string; code: number }) => void
    > = [];

    mocks.executeShellCommand.mockImplementation(
      () =>
        new Promise((resolve) => {
          rpcResolvers.push(resolve);
        }),
    );

    const poll = refreshRuntimeUiState({ force: true });
    const firstForced = refreshRuntimeUiState({ force: true });
    const secondForced = refreshRuntimeUiState({ force: true });

    expect(mocks.executeShellCommand).toHaveBeenCalledTimes(1);

    rpcResolvers[0]({ stdout: JSON.stringify(oldState), stderr: '', code: 0 });
    await expect(poll).resolves.toEqual(oldState);
    await vi.waitFor(() =>
      expect(mocks.executeShellCommand).toHaveBeenCalledTimes(2),
    );

    rpcResolvers[1]({ stdout: JSON.stringify(newState), stderr: '', code: 0 });

    await expect(Promise.all([firstForced, secondForced])).resolves.toEqual([
      newState,
      newState,
    ]);
    expect(store.get().servicesInfoWidget.data.prokopEnabled).toBe(1);
  });

  it('reads back autostart after a poll that started before the change', async () => {
    const before = createUiState('running but disabled', 1);
    before.service.prokop.enabled = 0;
    const after = createUiState('running & enabled', 1);
    let routerEnabled = 0;
    let resolvePoll: () => void = () => undefined;

    mocks.executeShellCommand.mockImplementation(
      ({ args }: { args: string[] }) => {
        if (args[0] === 'enable') {
          routerEnabled = 1;
          return Promise.resolve({ stdout: '', stderr: '', code: 0 });
        }

        const snapshot = routerEnabled ? after : before;
        if (args[0] === 'get_ui_state' && !routerEnabled) {
          return new Promise((resolve) => {
            resolvePoll = () =>
              resolve({
                stdout: JSON.stringify(snapshot),
                stderr: '',
                code: 0,
              });
          });
        }

        return Promise.resolve({
          stdout: JSON.stringify(snapshot),
          stderr: '',
          code: 0,
        });
      },
    );

    const poll = refreshRuntimeUiState();
    const toggled = setProkopAutostart(true);

    await vi.waitFor(() => expect(routerEnabled).toBe(1));
    resolvePoll();
    await poll;

    await expect(toggled).resolves.toBe(true);
  });

  it('marks the service state unavailable after repeated failed refreshes', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(createUiState()),
      stderr: '',
      code: 0,
    });
    await refreshRuntimeUiState({ force: true });
    expect(store.get().servicesInfoWidget.failed).toBe(false);

    mocks.executeShellCommand.mockRejectedValue(new Error('rpc timeout'));

    await refreshRuntimeUiState({ force: true });
    await refreshRuntimeUiState({ force: true });
    expect(store.get().servicesInfoWidget.failed).toBe(false);

    await refreshRuntimeUiState({ force: true });
    expect(store.get().servicesInfoWidget).toMatchObject({
      failed: true,
      data: { prokopRunning: 1 },
    });

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(createUiState()),
      stderr: '',
      code: 0,
    });
    await refreshRuntimeUiState({ force: true });
    expect(store.get().servicesInfoWidget.failed).toBe(false);
  });

  it('notifies subscribers after applying fresh state', async () => {
    const uiState = createUiState('stopped but enabled', 0);
    const listener = vi.fn();
    const unsubscribe = subscribeRuntimeUiState(listener);
    listener.mockClear();

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await refreshRuntimeUiState({ force: true });

    expect(listener).toHaveBeenCalledWith(uiState);

    unsubscribe();
    listener.mockClear();

    await refreshRuntimeUiState({ force: true });

    expect(listener).not.toHaveBeenCalled();
  });

  it('replays cached state to a new subscriber without another RPC', async () => {
    const uiState = createUiState('starting', 0);

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await refreshRuntimeUiState({ force: true });

    const listener = vi.fn();
    const unsubscribe = subscribeRuntimeUiState(listener);

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener).toHaveBeenCalledWith(uiState);
    expect(mocks.executeShellCommand).toHaveBeenCalledTimes(1);

    unsubscribe();
  });

  it('exposes the cached state without another RPC', async () => {
    const uiState = createUiState('running & enabled', 1);

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await refreshRuntimeUiState({ force: true });
    mocks.executeShellCommand.mockClear();

    expect(getCachedRuntimeUiState()).toEqual(uiState);
    expect(mocks.executeShellCommand).not.toHaveBeenCalled();
  });
});

// FE-8: a router that answers slowly or not at all is asked less often.
describe('runtimeUiStatePollDelay', () => {
  it('polls at the usual pace while answers come', () => {
    expect(runtimeUiStatePollDelay(false, 0)).toBe(1000);
    expect(runtimeUiStatePollDelay(true, 0)).toBe(500);
  });
  it('backs off after failed polls, up to ten seconds', () => {
    expect(runtimeUiStatePollDelay(false, 1)).toBe(2000);
    expect(runtimeUiStatePollDelay(true, 2)).toBe(4000);
    expect(runtimeUiStatePollDelay(false, 10)).toBe(10000);
  });
});
