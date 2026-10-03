import {
  ActionFailureError,
  actionReasonIsWarning,
  actionReasonText,
  failureFromError,
  failureReason,
} from './actionReason';
import { Prokop } from '../types';

export interface ServiceActionNotice {
  text: string;
  type: 'warning' | 'error';
}

// One presentation of a service action that did not succeed (UC-120,
// UC-119): busy, a start in progress and an action not confirmed in time
// are translated warnings; a failure is an error with the backend's text.
export function serviceActionNotice(error: unknown): ServiceActionNotice {
  const failure = failureFromError(error);
  const reason = failureReason(failure);
  const reasonText = actionReasonText(reason);

  if (reasonText && actionReasonIsWarning(reason)) {
    return { text: reasonText, type: 'warning' };
  }

  const detail = reasonText || (failure.error || '').trim();
  return {
    text: detail
      ? `${_('Service action failed')}: ${detail}`
      : _('Service action failed'),
    type: 'error',
  };
}

// The notice for a finished job: none when it succeeded or when a reload
// was skipped for a stopped Prokop.
export function finishedServiceActionNotice(
  state: Prokop.ServiceActionState,
): ServiceActionNotice | null {
  if (state.running !== false || state.success !== false) {
    return null;
  }

  const reason = state.outcome === 'queued' ? 'queued' : state.reason;
  return serviceActionNotice(
    new ActionFailureError(state.message || '', reason),
  );
}
