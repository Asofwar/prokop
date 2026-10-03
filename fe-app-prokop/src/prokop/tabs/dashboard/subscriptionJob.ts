import {
  actionReasonIsWarning,
  actionReasonText,
  failureReason,
} from '../../helpers/actionReason';
import { Prokop } from '../../types';

export function subscriptionUpdateErrorMessage(message: string) {
  const detail = `${message || ''}`.trim();
  const fallback = _('Failed to update subscriptions');

  if (
    !detail ||
    detail === fallback ||
    detail === 'Subscription update failed'
  ) {
    return fallback;
  }

  return `${fallback}: ${detail}`;
}

// The notice of a subscription update job that did not succeed (UC-119): an
// update that a reload or another update kept from running was refused as
// busy, a translated warning; a failure is an error with the backend's text.
export function subscriptionUpdateFailureNotice(
  response: Prokop.MethodResponse<Prokop.SubscriptionUpdateJobState>,
): { text: string; type: 'warning' | 'error' } {
  const failure = response.success
    ? { reason: response.data.reason, message: response.data.message }
    : { reason: response.reason, error: response.error };
  const reason = failureReason(failure);
  const reasonText = actionReasonText(reason);

  if (reasonText && actionReasonIsWarning(reason)) {
    return { text: reasonText, type: 'warning' };
  }

  return {
    text: subscriptionUpdateErrorMessage(
      reasonText || failure.message || failure.error || '',
    ),
    type: 'error',
  };
}
