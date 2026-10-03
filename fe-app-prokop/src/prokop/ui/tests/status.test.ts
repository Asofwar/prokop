import { describe, expect, it } from 'vitest';

import {
  eventKindLabel,
  eventOutcomeView,
  provenanceLabel,
  statusLabel,
  statusTone,
  toEventOutcome,
  type EventOutcome,
  type SemanticStatus,
} from '../status';

describe('labels and tones', () => {
  const all: SemanticStatus[] = [
    'healthy',
    'warning',
    'error',
    'needs_attention',
    'busy',
    'not_checked',
    'unsupported',
    'off',
    'unknown',
  ];

  // A status that loses its case falls back to the Unknown label, so every
  // known status must read differently from Unknown and from each other.
  it('gives every semantic status its own label', () => {
    const known = all.filter((status) => status !== 'unknown');
    const labels = known.map(statusLabel);

    for (const label of labels) expect(label).not.toBe(statusLabel('unknown'));
    expect(new Set(labels).size).toBe(known.length);
  });

  it('gives every semantic status its tone', () => {
    expect(all.map(statusTone)).toEqual([
      'success',
      'warning',
      'error',
      'error',
      'loading',
      'neutral',
      'muted',
      'muted',
      'neutral',
    ]);
  });
});

describe('event outcomes', () => {
  it('maps recorded event statuses to outcomes', () => {
    expect(toEventOutcome('success')).toBe('succeeded');
    expect(toEventOutcome('recovered')).toBe('recovered');
    expect(toEventOutcome('failure')).toBe('failed');
    expect(toEventOutcome('needs_attention')).toBe('needs_attention');
    expect(toEventOutcome('rolled_back')).toBe('rolled_back');
    expect(toEventOutcome('stale')).toBe('cancelled');
    expect(toEventOutcome('not_started')).toBe('not_started');
    expect(toEventOutcome('???')).toBe('unknown');
  });

  it('never shows an unknown outcome as a success', () => {
    expect(eventOutcomeView('unknown').tone).toBe('neutral');
    // A restore while Prokop was stopped by the user was not verified.
    expect(eventOutcomeView('not_started')).toEqual({
      label: 'Saved, service stopped',
      tone: 'warning',
    });
    expect(eventOutcomeView('needs_attention').tone).toBe('error');
    expect(eventOutcomeView('rolled_back').tone).toBe('warning');
  });
});

describe('event labels', () => {
  it('gives every event outcome its own label', () => {
    const outcomes: EventOutcome[] = [
      'succeeded',
      'recovered',
      'rolled_back',
      'failed',
      'needs_attention',
      'cancelled',
      'not_started',
    ];
    const labels = outcomes.map((outcome) => eventOutcomeView(outcome).label);

    for (const label of labels)
      expect(label).not.toBe(eventOutcomeView('unknown').label);
    expect(new Set(labels).size).toBe(outcomes.length);
  });

  it('names every recorded event kind', () => {
    const kinds = [
      'start',
      'reload',
      'restore',
      'autotune_apply',
      'autotune_rollback',
      'autotune_mode',
      'autotune_recommendation',
      'autotune_run',
      'snapshot_create',
      'snapshot_delete',
      'cron_refresh',
      'config_migration',
    ];
    const labels = kinds.map(eventKindLabel);

    for (const label of labels) expect(label).not.toBe(eventKindLabel('?'));
    expect(new Set(labels).size).toBe(kinds.length);
  });
});

describe('provenance', () => {
  it('labels every provenance', () => {
    expect(provenanceLabel('observed')).toBe('Observed');
    expect(provenanceLabel('configured')).toBe('From configuration');
    expect(provenanceLabel('simulated')).toBe('Calculated');
    expect(provenanceLabel('unknown')).toBe('Not determined');
  });
});
