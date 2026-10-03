import { beforeEach, describe, expect, it, vi } from 'vitest';

const shell = vi.hoisted(() => ({
  serviceActionStart: vi.fn(),
  waitServiceActionJob: vi.fn(),
  uiActionAck: vi.fn(),
}));
const toast = vi.hoisted(() => vi.fn());
vi.mock('../../../methods', () => ({ ProkopShellMethods: shell }));
vi.mock('../../../../helpers/showToast', () => ({ showToast: toast }));

interface FakeNode {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown[];
  disabled?: boolean;
  textContent?: string;
}
(globalThis as unknown as { E: unknown }).E = (
  tag: string,
  attrs: Record<string, unknown> = {},
  children: unknown = [],
): FakeNode => ({
  tag,
  attrs,
  children: Array.isArray(children) ? children : [children],
});

import { setReadonlyMode } from '../../../services/accessMode.service';
import { renderStartServiceAction } from '../startService';
import { runProkopServiceAction } from '../serviceControl';

beforeEach(() => {
  setReadonlyMode(false);
  Object.values(shell).forEach((mock) => mock.mockReset());
  toast.mockReset();
});

describe('starting Prokop from a stopped page', () => {
  it('runs the start job, waits for it and acknowledges it', async () => {
    shell.serviceActionStart.mockResolvedValue({
      success: true,
      data: { job_id: 'job-1' },
    });
    shell.waitServiceActionJob.mockResolvedValue({
      success: true,
      data: { success: true },
    });

    await runProkopServiceAction('start');

    expect(shell.serviceActionStart).toHaveBeenCalledWith('start');
    expect(shell.waitServiceActionJob).toHaveBeenCalledWith('job-1');
    expect(shell.uiActionAck).toHaveBeenCalledWith('service', 'job-1');
  });

  it('reports a failed job with the backend message', async () => {
    shell.serviceActionStart.mockResolvedValue({
      success: true,
      data: { job_id: 'job-2' },
    });
    shell.waitServiceActionJob.mockResolvedValue({
      success: true,
      data: { success: false, message: 'sing-box config invalid' },
    });
    const [button] = renderStartServiceAction() as unknown as FakeNode[];

    await (button.attrs.click as () => Promise<void>)();

    expect(toast).toHaveBeenCalledWith(
      'Service action failed: sing-box config invalid',
      'error',
      6000,
    );
    expect(shell.uiActionAck).toHaveBeenCalledWith('service', 'job-2');
    expect(button.disabled).toBe(false);
  });

  it('offers no button in a read-only session', () => {
    setReadonlyMode(true);

    expect(renderStartServiceAction()).toEqual([]);
  });
});
