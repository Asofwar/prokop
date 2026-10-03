import { showToast } from '../../helpers/showToast';
import { finishedServiceActionNotice } from '../helpers/serviceActionNotice';
import { Prokop } from '../types';
import { subscribeRuntimeUiState } from './runtimeUiState.service';
import { shouldNotifyOwnedUiAction } from './uiActionNotification.service';

// Jobs a page of this browser tab is waiting for: that page reports their
// outcome itself.
const awaitedServiceActionJobs = new Set<string>();

export function beginAwaitedServiceAction(jobId: string) {
  awaitedServiceActionJobs.add(jobId);
}

export function endAwaitedServiceAction(jobId: string, reported: boolean) {
  awaitedServiceActionJobs.delete(jobId);
  if (reported) {
    // Consumed: the follower below says nothing more about it.
    shouldNotifyOwnedUiAction('service', jobId);
  }
}

// A job started in this browser tab whose page is gone (reloaded, or left
// before the job finished): its failure is still reported, once.
export function notifyFinishedServiceActions(uiState: Prokop.UiState) {
  for (const state of uiState.actions?.service || []) {
    const jobId = state.job_id;
    if (!jobId || awaitedServiceActionJobs.has(jobId)) {
      continue;
    }

    const notice = finishedServiceActionNotice(state);
    if (notice && shouldNotifyOwnedUiAction('service', jobId)) {
      showToast(notice.text, notice.type, 6000);
    }
  }
}

let unsubscribe: (() => void) | null = null;

export function startServiceActionOutcomeNotices() {
  if (!unsubscribe) {
    unsubscribe = subscribeRuntimeUiState(notifyFinishedServiceActions);
  }
}
