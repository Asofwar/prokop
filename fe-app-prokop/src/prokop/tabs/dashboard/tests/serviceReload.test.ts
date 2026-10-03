import { describe, expect, it } from 'vitest';

import { serviceReloadOutcome, urlTestChangeToast } from '../serviceReload';
import type { Prokop } from '../../../types';

const job = (
  patch: Partial<Prokop.ServiceActionState>,
): Prokop.ServiceActionState => ({
  kind: 'service',
  action: 'reload',
  running: false,
  success: true,
  message: 'Service reload completed',
  ...patch,
});

describe('service reload outcome (UC-061)', () => {
  it('reports a reload only as applied when it ran', () => {
    expect(serviceReloadOutcome(job({}))).toBe('reloaded');
    expect(
      serviceReloadOutcome(
        job({
          success: false,
          outcome: 'queued',
          message:
            'Service reload queued: it runs after the operation in progress',
        }),
      ),
    ).toBe('queued');
    expect(
      serviceReloadOutcome(job({ success: true, outcome: 'stopped' })),
    ).toBe('stopped');
    expect(
      serviceReloadOutcome(
        job({ success: false, message: 'Service reload failed' }),
      ),
    ).toBe('failed');
  });

  it('says that saved URLTest settings wait for a queued or skipped reload', () => {
    expect(urlTestChangeToast('reloaded', false)).toMatchObject({
      text: 'URLTest settings saved',
      type: 'success',
    });
    const queued = urlTestChangeToast('queued', false);
    expect(queued.type).toBe('warning');
    expect(queued.text).toContain('URLTest settings saved');
    expect(queued.text).toContain('applies when it finishes');
    const stopped = urlTestChangeToast('stopped', true);
    expect(stopped.type).toBe('warning');
    expect(stopped.text).toContain('URLTest settings reset');
    expect(stopped.text).toContain('applies when it is started');
    expect(urlTestChangeToast('failed', false).type).toBe('error');
  });
});
