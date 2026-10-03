import { describe, expect, it } from 'vitest';

import { subscriptionUpdateFailureNotice } from '../subscriptionJob';
import type { Prokop } from '../../../types';

const finished = (
  patch: Partial<Prokop.SubscriptionUpdateJobState> = {},
): Prokop.MethodResponse<Prokop.SubscriptionUpdateJobState> => ({
  success: true,
  data: {
    kind: 'subscription',
    success: false,
    running: false,
    section: 'main',
    message: 'Subscription update failed',
    reason: 'failure',
    ...patch,
  },
});

// UC-119: a subscription update that a reload or another update kept from
// running was refused as busy, which is a translated warning; a failure
// stays an error with the backend's text.
describe('subscription update job notice', () => {
  it('presents an update refused as busy as a translated warning', () => {
    expect(
      subscriptionUpdateFailureNotice(
        finished({
          message:
            'Prokop reload is already running; skipping subscription update',
          reason: 'busy',
          exit_code: 2,
        }),
      ),
    ).toEqual({
      text: 'Another action of this kind is already running. Try again when it finishes.',
      type: 'warning',
    });
  });

  it('keeps the backend text of a failed update', () => {
    expect(
      subscriptionUpdateFailureNotice(
        finished({ message: 'Failed to download source 1' }),
      ),
    ).toEqual({
      text: 'Failed to update subscriptions: Failed to download source 1',
      type: 'error',
    });
    expect(subscriptionUpdateFailureNotice(finished())).toEqual({
      text: 'Failed to update subscriptions',
      type: 'error',
    });
  });

  it('presents a job whose worker is gone as an error', () => {
    expect(
      subscriptionUpdateFailureNotice(
        finished({
          message: 'Subscription update worker exited unexpectedly',
          reason: 'stale',
        }),
      ).type,
    ).toBe('error');
  });

  it('keeps the text of a status request that failed', () => {
    expect(
      subscriptionUpdateFailureNotice({
        success: false,
        error: 'Subscription update job was not found',
        reason: 'not_found',
      }),
    ).toEqual({
      text: 'Failed to update subscriptions: The action was not found; it may have finished already.',
      type: 'error',
    });
  });
});
