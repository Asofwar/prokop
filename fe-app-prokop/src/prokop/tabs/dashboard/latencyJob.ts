import { ActionFailureError, failureReason } from '../../helpers/actionReason';
import { Prokop } from '../../types';

// Why a finished latency job failed. Its own text is always "Latency test
// failed" and the reason says why (UC-119); an older backend gives no
// reason, but its text still names a busy worker.
export function latencyJobFailure(state: Prokop.LatencyActionState) {
  return new ActionFailureError(
    _('Latency test failed'),
    failureReason({ reason: state.reason, message: state.message }),
  );
}
