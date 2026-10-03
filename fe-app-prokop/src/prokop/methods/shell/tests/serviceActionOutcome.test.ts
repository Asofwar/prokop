import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { ProkopShellMethods } from '../index';

const finished = {
  success: true,
  running: false,
  kind: 'service',
  action: 'restart',
  message: 'Service restart completed',
  exit_code: 0,
};

// UC-120: one handling of service action outcomes. A lost RPC reply while the
// job runs is no failure, an action that is not confirmed in time is not a
// failure either, and a refusal says why.
describe('service action outcomes', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    mocks.executeShellCommand.mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('keeps waiting through a transient RPC failure', async () => {
    mocks.executeShellCommand
      .mockResolvedValueOnce({
        stdout: '',
        stderr: 'No related RPC reply',
        code: 1,
      })
      .mockResolvedValue({
        stdout: JSON.stringify(finished),
        stderr: '',
        code: 0,
      });

    const waiting = ProkopShellMethods.waitServiceActionJob('job-1');
    await vi.advanceTimersByTimeAsync(2000);

    await expect(waiting).resolves.toEqual({ success: true, data: finished });
  });

  it('reports an action still running at its bound as not confirmed', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({ ...finished, running: true }),
      stderr: '',
      code: 0,
    });

    const waiting = ProkopShellMethods.waitServiceActionJob('job-1');
    await vi.advanceTimersByTimeAsync(3 * 60 * 1000);

    await expect(waiting).resolves.toMatchObject({
      success: false,
      reason: 'timeout',
    });
  });

  it('passes the reason of a refused start on', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({
        success: false,
        job_id: '',
        message: 'Another service action is already running',
        reason: 'busy',
      }),
      stderr: '',
      code: 1,
    });

    await expect(
      ProkopShellMethods.serviceActionStart('restart'),
    ).resolves.toEqual({
      success: false,
      error: 'Another service action is already running',
      reason: 'busy',
    });
  });

  it('passes the reason of a refused status on', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({
        success: false,
        job_id: '',
        message: 'Service action job was not found',
        reason: 'not_found',
      }),
      stderr: '',
      code: 1,
    });

    await expect(
      ProkopShellMethods.serviceActionStatus('job-1'),
    ).resolves.toMatchObject({ success: false, reason: 'not_found' });
  });
});
