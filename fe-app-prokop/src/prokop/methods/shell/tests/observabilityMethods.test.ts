import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ executeShellCommand: vi.fn() }));
vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { ProkopShellMethods } from '../index';

describe('observability CLI contracts', () => {
  beforeEach(() => mocks.executeShellCommand.mockReset());

  it('passes trace parameters as separate arguments', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      code: 0,
      stdout: '{}',
      stderr: '',
    });
    await ProkopShellMethods.routeTrace(
      'example.org',
      '192.168.1.2',
      'TCP',
      '443',
    );
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        command: '/usr/bin/prokop',
        args: ['route_trace', 'example.org', '192.168.1.2', 'TCP', '443'],
      }),
    );
  });

  it('keeps snapshot creation explicit before apply', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      code: 0,
      stdout: '{"status":"created"}',
      stderr: '',
    });
    await ProkopShellMethods.snapshotCreate('before-apply');
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['config_snapshot_create', 'before-apply'],
      }),
    );
  });

  it('uses each existing provider validator without runtime mutation', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      code: 0,
      stdout: '{"valid":true}',
      stderr: '',
    });
    for (const provider of ['zapret', 'zapret2', 'byedpi'] as const)
      await ProkopShellMethods.validateDpiStrategy(provider, '--test');
    expect(
      mocks.executeShellCommand.mock.calls.map(([value]) => value.args[0]),
    ).toEqual([
      'validate_nfqws_strategy_json',
      'validate_nfqws2_strategy_json',
      'validate_byedpi_strategy_json',
    ]);
  });

  it('keeps the structured busy result of snapshot mutations that exit non-zero', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      code: 1,
      stdout: '{"status":"busy","reason":"snapshot_operation_in_progress"}',
      stderr: '',
    });
    for (const call of [
      () => ProkopShellMethods.snapshotCreate('manual'),
      () => ProkopShellMethods.snapshotRestore('1_2'),
      () => ProkopShellMethods.snapshotDelete('1_2'),
    ]) {
      const response = await call();
      if (!response.success) throw new Error('structured result was dropped');
      expect(response.data).toEqual({
        status: 'busy',
        reason: 'snapshot_operation_in_progress',
      });
    }
  });

  it('keeps the invalid_input answer of a rejected route trace target', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      code: 1,
      stdout: '{"error":"invalid_input"}',
      stderr: '',
    });
    const response = await ProkopShellMethods.routeTrace(
      'bad host',
      '',
      'TCP',
      '',
    );
    if (!response.success) throw new Error('structured result was dropped');
    expect(response.data).toEqual({ error: 'invalid_input' });
  });
});
