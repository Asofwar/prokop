import { describe, expect, it, vi } from 'vitest';

import { ActionFailureError } from '../../../helpers/actionReason';
import { runUrlTestChange } from '../serviceReload';
import type { Prokop } from '../../../types';

const job = (
  patch: Partial<Prokop.ServiceActionState> = {},
): Prokop.ServiceActionState => ({
  kind: 'service',
  action: 'reload',
  running: false,
  success: true,
  message: 'Service reload completed',
  ...patch,
});

function steps(reload: () => Promise<Prokop.ServiceActionState>) {
  return {
    change: vi.fn(async () => undefined),
    reload: vi.fn(reload),
    refresh: vi.fn(async () => undefined),
  };
}

// UC-116: the URLTest settings are committed before the reload; a reload
// that failed, was refused or was not confirmed is not reported as applied,
// and the editor stays open when the change did not take effect.
describe('URLTest settings change', () => {
  it('closes the editor after a reload that applied the change', async () => {
    const flow = steps(async () => job());

    const result = await runUrlTestChange(flow, false);

    expect(result).toEqual({
      close: true,
      toast: {
        text: 'URLTest settings saved',
        type: 'success',
        duration: 3000,
      },
    });
    expect(flow.refresh).toHaveBeenCalled();
  });

  it('keeps the editor open and reports an error when the reload failed', async () => {
    const flow = steps(async () =>
      job({
        success: false,
        message: 'Service reload failed',
        reason: 'failure',
      }),
    );

    const result = await runUrlTestChange(flow, false);

    expect(result.close).toBe(false);
    expect(result.toast.type).toBe('error');
    expect(result.toast.text).toContain('URLTest settings saved');
    expect(result.toast.text).toContain('could not apply the change');
  });

  it('keeps the editor open when Prokop did not come back after the reload', async () => {
    const flow = steps(async () =>
      job({
        success: false,
        message: 'Service reload did not reach expected state',
        reason: 'failure',
      }),
    );

    const result = await runUrlTestChange(flow, false);

    expect(result.close).toBe(false);
    expect(result.toast.type).toBe('error');
    expect(result.toast.text).toContain('could not apply the change');
  });

  it('keeps the editor open when the reload was refused because Prokop is busy', async () => {
    const flow = steps(async () => {
      throw new ActionFailureError(
        'Another service action is already running',
        'busy',
      );
    });

    const result = await runUrlTestChange(flow, true);

    expect(result.close).toBe(false);
    expect(result.toast.type).toBe('warning');
    expect(result.toast.text).toContain('URLTest settings reset');
    expect(result.toast.text).toContain('not applied yet');
    expect(flow.refresh).not.toHaveBeenCalled();
  });

  it('says a reload not confirmed in time is not confirmed, not failed', async () => {
    const flow = steps(async () => {
      throw new ActionFailureError('Operation timed out', 'timeout');
    });

    const result = await runUrlTestChange(flow, false);

    expect(result.close).toBe(true);
    expect(result.toast.type).toBe('warning');
    expect(result.toast.text).toContain('URLTest settings saved');
    expect(result.toast.text).toContain('not confirmed');
  });

  it('starts no reload when the settings were not saved', async () => {
    const flow = steps(async () => job());
    flow.change.mockRejectedValueOnce(new Error('save failed'));

    await expect(runUrlTestChange(flow, false)).rejects.toThrow('save failed');
    expect(flow.reload).not.toHaveBeenCalled();
  });
});
