import { describe, expect, it } from 'vitest';

import {
  actionReasonIsWarning,
  actionReasonText,
  failureReason,
  failureText,
} from '../actionReason';
import { READONLY_REFUSED } from '../../services/readonlyCommandGuard';

// UC-119: the backend refuses and fails with stable reasons; the page shows
// them translated and keeps the English message only as a last resort.
describe('action reasons', () => {
  it('translates the stable reasons of the backend', () => {
    for (const reason of [
      'busy',
      'startup_in_progress',
      'invalid_input',
      'not_found',
      'forbidden',
      'timeout',
      'queued',
      'stale',
      'latency_failed',
      'clash_api_unreachable',
      'clash_api_timeout',
    ]) {
      expect(actionReasonText(reason)).toEqual(expect.any(String));
    }
    expect(actionReasonText('failure')).toBeNull();
    expect(actionReasonText(undefined)).toBeNull();
  });

  it('presents busy, a start in progress and an unconfirmed action as warnings', () => {
    expect(actionReasonIsWarning('busy')).toBe(true);
    expect(actionReasonIsWarning('startup_in_progress')).toBe(true);
    expect(actionReasonIsWarning('timeout')).toBe(true);
    expect(actionReasonIsWarning('failure')).toBe(false);
    // A worker that is gone leaves the outcome unknown: not a warning that
    // the action may still finish.
    expect(actionReasonIsWarning('stale')).toBe(false);
    expect(actionReasonIsWarning('invalid_input')).toBe(false);
    expect(actionReasonIsWarning(undefined)).toBe(false);
  });

  it('reads the reason of the backend, of the read-only guard and of an older backend', () => {
    expect(failureReason({ reason: 'not_found', error: 'x' })).toBe(
      'not_found',
    );
    expect(failureReason({ error: READONLY_REFUSED })).toBe('forbidden');
    // A backend without reasons: its English refusals are known.
    expect(
      failureReason({ error: 'Another service action is already running' }),
    ).toBe('busy');
    expect(
      failureReason({ message: 'Prokop startup is still in progress' }),
    ).toBe('startup_in_progress');
    expect(
      failureReason({ message: 'Another component action is already running' }),
    ).toBe('busy');
    expect(failureReason({ error: 'Service restart failed' })).toBeUndefined();
  });

  it('shows the translated reason, else the message, else the fallback', () => {
    expect(failureText({ reason: 'busy', error: 'English' }, 'fallback')).toBe(
      actionReasonText('busy'),
    );
    expect(failureText({ error: 'Service restart failed' }, 'fallback')).toBe(
      'Service restart failed',
    );
    expect(failureText({ reason: 'failure', error: '' }, 'fallback')).toBe(
      'fallback',
    );
  });
});
