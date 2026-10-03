import { beforeEach, describe, expect, it, vi } from 'vitest';

const shell = vi.hoisted(() => ({
  serviceActionStart: vi.fn(),
  waitServiceActionJob: vi.fn(),
  uiActionAck: vi.fn(),
}));
const toast = vi.hoisted(() => vi.fn());
vi.mock('../../../methods', () => ({ ProkopShellMethods: shell }));
vi.mock('../../../../helpers/showToast', () => ({ showToast: toast }));

import { actionReasonText } from '../../../helpers/actionReason';
import { serviceActionNotice } from '../../../helpers/serviceActionNotice';
import { notifyFinishedServiceActions } from '../../../services/serviceActionOutcome.service';
import { markUiActionOwned } from '../../../services/uiActionNotification.service';
import { Prokop } from '../../../types';
import { runProkopServiceAction } from '../serviceControl';

let nextJob = 0;
const newJobId = () => `job-${++nextJob}`;

function uiState(...service: Prokop.ServiceActionState[]) {
  return {
    actions: { service, latency: [], component: [], subscription: [] },
  } as unknown as Prokop.UiState;
}

function finished(
  jobId: string,
  extra: Partial<Prokop.ServiceActionState> = {},
): Prokop.ServiceActionState {
  return {
    success: false,
    running: false,
    kind: 'service',
    action: 'restart',
    job_id: jobId,
    message: 'Service restart failed',
    reason: 'failure',
    ...extra,
  };
}

async function failure(run: Promise<unknown>) {
  try {
    await run;
  } catch (error) {
    return error;
  }
  throw new Error('the action did not fail');
}

beforeEach(() => {
  Object.values(shell).forEach((mock) => mock.mockReset());
  toast.mockReset();
});

// UC-120/UC-119: busy is a warning, an action not confirmed in time is not a
// failure, a failure is an error, and the failure of a job this browser
// started is reported even when the page that started it is gone.
describe('service action outcomes', () => {
  it('presents a refusal because another action runs as a translated warning', async () => {
    shell.serviceActionStart.mockResolvedValue({
      success: false,
      error: 'Another service action is already running',
      reason: 'busy',
    });

    const error = await failure(runProkopServiceAction('restart'));

    expect(serviceActionNotice(error)).toEqual({
      text: actionReasonText('busy'),
      type: 'warning',
    });
  });

  it('presents an action not confirmed in time as a warning', async () => {
    const jobId = newJobId();
    shell.serviceActionStart.mockResolvedValue({
      success: true,
      data: { success: true, job_id: jobId, message: '' },
    });
    shell.waitServiceActionJob.mockResolvedValue({
      success: false,
      error: 'Operation timed out',
      reason: 'timeout',
    });

    const error = await failure(runProkopServiceAction('restart'));

    expect(serviceActionNotice(error)).toEqual({
      text: actionReasonText('timeout'),
      type: 'warning',
    });
  });

  it('presents a failed job as an error with its message', async () => {
    const jobId = newJobId();
    shell.serviceActionStart.mockResolvedValue({
      success: true,
      data: { success: true, job_id: jobId, message: '' },
    });
    shell.waitServiceActionJob.mockResolvedValue({
      success: true,
      data: finished(jobId),
    });

    const error = await failure(runProkopServiceAction('restart'));

    expect(serviceActionNotice(error)).toEqual({
      text: 'Service action failed: Service restart failed',
      type: 'error',
    });
  });

  it('presents a runtime that did not reach the expected state as an error', async () => {
    // The command returned, then Prokop stayed down for the whole wait:
    // that failed; it is no unconfirmed action that may still finish.
    const jobId = newJobId();
    shell.serviceActionStart.mockResolvedValue({
      success: true,
      data: { success: true, job_id: jobId, message: '' },
    });
    shell.waitServiceActionJob.mockResolvedValue({
      success: true,
      data: finished(jobId, {
        message: 'Service restart did not reach expected state',
      }),
    });

    const error = await failure(runProkopServiceAction('restart'));

    expect(serviceActionNotice(error)).toEqual({
      text: 'Service action failed: Service restart did not reach expected state',
      type: 'error',
    });
  });

  it('reports the failure of a job this browser started once', () => {
    const jobId = newJobId();
    markUiActionOwned('service', jobId);

    notifyFinishedServiceActions(uiState(finished(jobId)));
    notifyFinishedServiceActions(uiState(finished(jobId)));

    expect(toast).toHaveBeenCalledTimes(1);
    expect(toast).toHaveBeenCalledWith(
      'Service action failed: Service restart failed',
      'error',
      6000,
    );
  });

  it('says nothing about a job another browser started', () => {
    notifyFinishedServiceActions(uiState(finished(newJobId())));

    expect(toast).not.toHaveBeenCalled();
  });

  it('says nothing about a job that succeeded or a reload skipped while stopped', () => {
    const done = newJobId();
    const skipped = newJobId();
    markUiActionOwned('service', done);
    markUiActionOwned('service', skipped);

    notifyFinishedServiceActions(
      uiState(
        finished(done, { success: true, reason: undefined }),
        finished(skipped, {
          action: 'reload',
          success: true,
          outcome: 'stopped',
          reason: undefined,
        }),
      ),
    );

    expect(toast).not.toHaveBeenCalled();
  });

  it('leaves the outcome of a job this page waits for to that page', async () => {
    const jobId = newJobId();
    let finishWait: (value: unknown) => void = () => undefined;
    shell.serviceActionStart.mockResolvedValue({
      success: true,
      data: { success: true, job_id: jobId, message: '' },
    });
    shell.waitServiceActionJob.mockReturnValue(
      new Promise((resolve) => {
        finishWait = resolve;
      }),
    );

    const run = runProkopServiceAction('restart');
    await vi.waitFor(() => expect(shell.waitServiceActionJob).toBeCalled());
    // The poller sees the finished job before the page's own wait does.
    notifyFinishedServiceActions(uiState(finished(jobId)));
    finishWait({ success: true, data: finished(jobId) });
    await failure(run);
    notifyFinishedServiceActions(uiState(finished(jobId)));

    expect(toast).not.toHaveBeenCalled();
  });

  it('reports a job that finished after the page stopped waiting', async () => {
    const jobId = newJobId();
    shell.serviceActionStart.mockResolvedValue({
      success: true,
      data: { success: true, job_id: jobId, message: '' },
    });
    shell.waitServiceActionJob.mockResolvedValue({
      success: false,
      error: 'Operation timed out',
      reason: 'timeout',
    });

    await failure(runProkopServiceAction('restart'));
    notifyFinishedServiceActions(uiState(finished(jobId)));

    expect(toast).toHaveBeenCalledTimes(1);
  });
});
