import { describe, expect, it } from 'vitest';

import { applyOutcomeView, applyResultView } from '../model';

// Seeded property checks of the autotune status mapping (UC-156): every
// status autotune/apply.uc and autoapply.outcome() report, and any status a
// newer backend may add, maps to a view; only "applied" is shown as a
// success, and an unfinished or unknown outcome always asks for attention.

const SEED = 1560005;
const CASES = 600;

// mulberry32, as tests/helpers/property/scaffold.js.
function generator(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Status and phase strings of autotune/apply.uc plan/apply/verify/observe
// and of autoapply.outcome().
const APPLY_STATUSES = [
  'not_applicable',
  'direct_not_applicable',
  'ready',
  'busy',
  'verified',
  'observed',
  'stale',
  'no_change_required',
  'rolled_back',
  'needs_attention',
  'applied',
  'failed',
  'refused',
  'not_applied',
  'unknown',
];
const REASONS = [
  null,
  'config_changed',
  'rule_changed',
  'owner_changed',
  'not_confirmed',
  'dpi_guard_present',
  'runtime_guard_active',
  'reload_failed_recovered',
  'reload_queued_recovered',
  'interrupted_after_apply',
  'service_action_in_progress',
  'reload_pending',
  'service_stopped',
  'autotune_worker_running',
  'lkg_confirm_failed',
  'invalid_group',
];
const JOB_STATUSES = ['ok', 'failed', 'busy', 'refused', ''];

function cases() {
  const next = generator(SEED);
  const pick = <T>(items: T[]): T => items[Math.floor(next() * items.length)];
  const token = () =>
    Array.from({ length: 1 + Math.floor(next() * 12) }, () =>
      pick([...'abcdefghijklmnopqrstuvwxyz_']),
    ).join('');
  return Array.from({ length: CASES }, () => ({
    status: next() < 0.8 ? pick(JOB_STATUSES) : token(),
    result:
      next() < 0.1 ? undefined : next() < 0.8 ? pick(APPLY_STATUSES) : token(),
    reason: next() < 0.8 ? pick(REASONS) : token(),
    candidate: next() < 0.8 ? pick(['multisplit', 'fake', null]) : token(),
  }));
}

function check<T>(name: string, items: T[], property: (item: T) => void) {
  items.forEach((item, index) => {
    try {
      property(item);
    } catch (error) {
      throw new Error(
        `${name}: case ${index} (seed ${SEED}) ${JSON.stringify(item)}: ${String(error)}`,
      );
    }
  });
}

describe('autotune status mapping properties', () => {
  it('shows only an applied outcome as a success', () => {
    const statuses = [...APPLY_STATUSES, ...cases().map((c) => c.result ?? '')];
    check('applyOutcomeView', statuses, (status) => {
      const view = applyOutcomeView(status);
      expect(view.label).not.toBe('');
      expect(view.tone === 'success').toBe(status === 'applied');
      if (status === 'needs_attention' || status === 'unknown')
        expect(view.tone).toBe('error');
    });
  });

  it('never hides an unfinished or unknown apply result', () => {
    const known = new Set(APPLY_STATUSES);
    check('applyResultView', cases(), (c) => {
      const view = applyResultView(
        { status: c.status, result: c.result, reason: c.reason },
        c.candidate,
      );
      expect(view.text).not.toBe('');
      expect(view.text).not.toMatch(/undefined|null|%s/);
      expect(view.tone === 'success').toBe(c.result === 'applied');
      if (view.attention) expect(view.tone).toBe('error');
      if (c.result === 'needs_attention' || c.result === 'unknown')
        expect(view).toMatchObject({ tone: 'error', attention: true });
      if (c.result === 'failed' && c.reason === 'interrupted_after_apply')
        expect(view).toMatchObject({ tone: 'error', attention: true });
      // A result a newer backend reports is not a success or a no-op.
      if (c.result && !known.has(c.result) && c.status !== 'busy')
        expect(view).toMatchObject({ tone: 'error', attention: true });
    });
    const missing = applyResultView(null, 'multisplit');
    expect(missing).toMatchObject({ tone: 'error', attention: true });
  });
});
