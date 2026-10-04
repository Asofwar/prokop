import { afterEach, describe, expect, it, vi } from 'vitest';

import { executeShellCommand } from '../executeShellCommand';

// FE-8: a shared read that timed out for its caller is still running on the
// router; the next poll waits for that run instead of starting another.
describe('executeShellCommand shared runs', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('starts one run for a shared read until it finishes, even after a timeout', async () => {
    vi.useFakeTimers();
    let finish: (value: unknown) => void = () => undefined;
    const exec = vi.fn(() => new Promise((resolve) => (finish = resolve)));
    vi.stubGlobal('fs', { exec });

    const first = executeShellCommand({
      command: '/usr/bin/prokop',
      args: ['get_ui_state'],
      timeout: 3000,
      shared: true,
    });
    vi.advanceTimersByTime(3000);
    await expect(first).resolves.toMatchObject({ code: 1 });

    const second = executeShellCommand({
      command: '/usr/bin/prokop',
      args: ['get_ui_state'],
      timeout: 3000,
      shared: true,
    });
    expect(exec).toHaveBeenCalledTimes(1);
    finish({ stdout: '{}', stderr: '', code: 0 });
    await expect(second).resolves.toMatchObject({ stdout: '{}', code: 0 });

    // Finished: the next poll runs again.
    const third = executeShellCommand({
      command: '/usr/bin/prokop',
      args: ['get_ui_state'],
      timeout: 3000,
      shared: true,
    });
    expect(exec).toHaveBeenCalledTimes(2);
    finish({ stdout: '{}', stderr: '', code: 0 });
    await third;
  });

  it('runs every unshared command', async () => {
    const exec = vi.fn(async () => ({ stdout: '', stderr: '', code: 0 }));
    vi.stubGlobal('fs', { exec });
    await Promise.all([
      executeShellCommand({ command: '/bin/x', args: [] }),
      executeShellCommand({ command: '/bin/x', args: [] }),
    ]);
    expect(exec).toHaveBeenCalledTimes(2);
  });
});
