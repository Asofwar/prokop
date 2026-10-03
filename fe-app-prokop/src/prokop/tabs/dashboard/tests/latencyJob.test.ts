import { describe, expect, it } from 'vitest';

import {
  failureFromError,
  failureText,
  failureToastType,
} from '../../../helpers/actionReason';
import { latencyJobFailure } from '../latencyJob';
import type { Prokop } from '../../../types';

const job = (
  patch: Partial<Prokop.LatencyActionState> = {},
): Prokop.LatencyActionState => ({
  kind: 'latency',
  latency_type: 'proxy',
  section: 'main',
  tag: 'proxy-a',
  running: false,
  success: false,
  message: 'Latency test failed',
  ...patch,
});

function toast(state: Prokop.LatencyActionState) {
  const failure = failureFromError(latencyJobFailure(state));
  return {
    text: failureText(failure, 'Latency test failed'),
    type: failureToastType(failure),
  };
}

// UC-119: a failed latency job is shown by its reason; an older backend
// without reasons still names a busy worker in its text.
describe('latency job failure', () => {
  it('shows the reason of the backend', () => {
    expect(toast(job({ reason: 'clash_api_unreachable' }))).toEqual({
      text: 'The Clash API of sing-box is not reachable.',
      type: 'error',
    });
  });

  it('says that no tested proxy answered', () => {
    const shown = toast(
      job({
        latency_type: 'proxy_list',
        tag: '["proxy-a","proxy-b"]',
        reason: 'latency_failed',
      }),
    );
    expect(shown.type).toBe('error');
    expect(shown.text).toBe(
      'The latency test measured no delay: no tested proxy answered.',
    );
  });

  it('maps the busy worker of an older backend to a warning', () => {
    expect(
      toast(job({ message: 'Another latency test is already running' })),
    ).toEqual({
      text: 'Another action of this kind is already running. Try again when it finishes.',
      type: 'warning',
    });
  });

  it('falls back to the translated generic text', () => {
    expect(toast(job({ reason: 'failure' }))).toEqual({
      text: 'Latency test failed',
      type: 'error',
    });
    expect(toast(job())).toEqual({
      text: 'Latency test failed',
      type: 'error',
    });
  });
});
