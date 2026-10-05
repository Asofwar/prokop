import { describe, expect, it } from 'vitest';

import {
  applyOutcomeView,
  decisionText,
  durationLabel,
  groupCards,
  observationView,
} from '../model';
import { eventTitle } from '../../history/model';
import type { Prokop } from '../../../types';

const running = (
  overrides: Partial<Prokop.AutotuneObservation> = {},
): Prokop.AutotuneObservation => ({
  status: 'observing',
  group: 'youtube',
  candidate: 'multisplit',
  started_at: 1,
  checks_required: 4,
  passed: 1,
  failures_in_row: 0,
  checks: [{ at: 2, result: 'ok', reason: null, successes: 3, attempted: 3 }],
  ...overrides,
});

const status = (
  overrides: Partial<Prokop.AutotuneStatus> = {},
): Prokop.AutotuneStatus => ({
  status: 'ok',
  policy: {
    mode: 'auto',
    interval: '6h',
    confirmations: 3,
    min_confidence: 'high',
    max_applies_per_day: 1,
    cooldown: '24h',
    probes: 5,
    observation: '1h',
  },
  errors: [],
  targets: [],
  groups: {
    youtube: {
      pending: null,
      label: 'YouTube',
      targets: [],
      current: 'multisplit',
      last_apply: {
        at: 1,
        group: 'youtube',
        candidate: 'multisplit',
        status: 'applied',
        reason: null,
        trigger: 'automatic',
      },
    },
  },
  next_run_at: null,
  worker: null,
  recovered_at: null,
  state_recovered: null,
  ...overrides,
});

describe('observation after an automatic apply', () => {
  it('shows the running observation and its progress', () => {
    const view = observationView(running(), null);
    expect(view?.label).toBe('Under observation: 1 of 4 checks passed');
    expect(view?.tone).toBe('loading');
    expect(view?.detail).toBeNull();
  });

  it('warns that one more failure rolls back', () => {
    const view = observationView(running({ failures_in_row: 1 }), null);
    expect(view?.detail).toBe(
      'The last check failed; one more failure in a row rolls the change back.',
    );
  });

  it('explains an inconclusive check without blaming the strategy', () => {
    const view = observationView(
      running({
        checks: [
          { at: 2, result: 'inconclusive', reason: 'network_unavailable' },
        ],
      }),
      null,
    );
    expect(view?.detail).toBe('The last check could not reach the network.');
  });

  it('reports how the last observation ended', () => {
    expect(
      observationView(null, {
        status: 'passed',
        reason: null,
        passed: 4,
        checks_required: 4,
      }),
    ).toEqual({
      label: 'Observation passed',
      tone: 'success',
      detail: '4 of 4 checks passed',
    });
    expect(
      observationView(null, { status: 'rolled_back', reason: 'x' })?.tone,
    ).toBe('warning');
    expect(
      observationView(null, { status: 'needs_attention', reason: null })?.tone,
    ).toBe('error');
    expect(
      observationView(null, { status: 'ended', reason: 'config_changed' })
        ?.label,
    ).toBe('Observation stopped: the configuration was edited');
    // The operator's rollback is the last change of the card itself.
    expect(
      observationView(null, { status: 'ended', reason: 'operator_rollback' }),
    ).toBeNull();
    expect(observationView(null, null)).toBeNull();
  });

  it('puts the observation on the card of its group only', () => {
    const [card] = groupCards(status({ observation: running() }), null);
    expect(card.observation?.label).toBe(
      'Under observation: 1 of 4 checks passed',
    );
    const [other] = groupCards(
      status({ observation: running({ group: 'discord' }) }),
      null,
    );
    expect(other.observation).toBeNull();
  });

  it('names an observation rollback and a waiting apply', () => {
    expect(applyOutcomeView('rolled_back', 'observation_failed').label).toBe(
      'Stopped working under observation, rolled back',
    );
    expect(decisionText('observation_in_progress')).toBe(
      'The previous automatic change is still under observation; the next one waits for it.',
    );
    expect(durationLabel('30m')).toBe('30 min');
    expect(
      eventTitle({
        kind: 'autotune_observation',
        status: 'success',
        timestamp: 1,
        trigger: 'automatic',
        candidate: 'multisplit',
      }),
    ).toBe('Autotune: multisplit passed the observation');
  });
});
