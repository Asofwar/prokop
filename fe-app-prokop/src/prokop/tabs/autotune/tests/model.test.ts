import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  applyConfirmation,
  applyRunning,
  applyPhaseLabel,
  applyOutcomeView,
  applyResultView,
  candidateRows,
  currentStrategyLabel,
  decisionText,
  durationChoices,
  groupCards,
  mutationErrorText,
  outsideReasonText,
  recordedApplyView,
  rollbackConfirmation,
  rollbackResultView,
  strategyLabel,
  targetIdFor,
  targetReasonText,
  targetRows,
  ruleListName,
  ruleListLabel,
  listErrorText,
  runProgressView,
  stateNotSavedText,
  workerView,
} from '../model';
import type { Prokop } from '../../../types';

const NOW = 1_800_000_000;

const policy = (
  overrides: Partial<Prokop.AutotunePolicy> = {},
): Prokop.AutotunePolicy => ({
  mode: 'recommend',
  interval: '6h',
  confirmations: 3,
  min_confidence: 'high',
  max_applies_per_day: 1,
  cooldown: '24h',
  probes: 5,
  ...overrides,
});

const summary = (
  overrides: Partial<Prokop.AutotuneTargetSummary> = {},
): Prokop.AutotuneTargetSummary => ({
  at: NOW - 60,
  status: 'selected',
  reason: 'direct_unstable_candidate_stable',
  selected: 'multisplit',
  confidence: 'high',
  candidates: [
    {
      id: 'direct',
      stability: 'unstable',
      success: 2,
      attempted: 5,
      success_ratio: 0.4,
      median_tls_ms: 160,
    },
    {
      id: 'fake',
      stability: 'stable',
      success: 5,
      attempted: 5,
      success_ratio: 1,
      median_tls_ms: 139,
    },
    {
      id: 'multisplit',
      stability: 'stable',
      success: 5,
      attempted: 5,
      success_ratio: 1,
      median_tls_ms: 142.4,
    },
    {
      id: 'udp_fake',
      stability: 'unsupported',
      success: 0,
      attempted: 0,
      success_ratio: null,
      median_tls_ms: null,
    },
  ],
  ...overrides,
});

const status = (
  overrides: Partial<Prokop.AutotuneStatus> = {},
): Prokop.AutotuneStatus => ({
  status: 'ok',
  policy: policy(),
  errors: [],
  targets: [
    {
      id: 't_youtube',
      host: 'youtube.com',
      enabled: true,
      resolver: null,
      last: summary(),
    },
    {
      id: 't_video',
      host: 'googlevideo.com',
      enabled: true,
      resolver: null,
      last: null,
    },
  ],
  groups: {},
  next_run_at: null,
  worker: null,
  recovered_at: null,
  state_recovered: null,
  ...overrides,
});

const recommendation: Prokop.AutotuneGroupResult = {
  status: 'recommendation',
  candidate: 'multisplit',
  confidence: 'high',
  representative: 't_youtube',
  reason: 'direct_unstable_candidate_stable',
  conflict: [],
};

const groupState = (
  overrides: Partial<Prokop.AutotuneGroupState> = {},
): Prokop.AutotuneGroupState => ({
  pending: { candidate: 'multisplit', count: 1 },
  last: {
    status: 'recommendation',
    candidate: 'multisplit',
    confidence: 'high',
    reason: null,
    at: NOW - 60,
  },
  cooldowns: {},
  last_apply: null,
  label: 'YouTube',
  targets: ['t_youtube'],
  current: 'fake',
  ready: false,
  required: 3,
  result: recommendation,
  decision: { reason: 'mode_not_auto', at: NOW - 60 },
  ...overrides,
});

const live = (
  overrides: Partial<Prokop.AutotuneLiveGroup> = {},
): Prokop.AutotuneGroups => ({
  status: 'ok',
  groups: {
    youtube: {
      label: 'YouTube',
      targets: ['t_youtube', 't_video'],
      current: 'fake',
      custom: false,
      result: recommendation,
      ...overrides,
    },
  },
  outside: [],
});

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(NOW * 1000);
});

afterEach(() => {
  vi.useRealTimers();
});

describe('autotune strategy labels', () => {
  it('names the control and the default, keeps catalog ids', () => {
    expect(strategyLabel('direct')).toBe('No bypass (direct)');
    expect(strategyLabel('default')).toBe('Default strategy');
    expect(strategyLabel('multisplit')).toBe('multisplit');
    expect(strategyLabel(null)).toBe('—');
  });

  it('never shows a raw custom strategy', () => {
    expect(currentStrategyLabel('', true)).toBe('Custom strategy');
    expect(currentStrategyLabel(null, null)).toBe('Not determined');
  });
});

describe('groupCards', () => {
  it('shows a recommendation that is still being confirmed', () => {
    const [card] = groupCards(
      status({ groups: { youtube: groupState() } }),
      live(),
    );
    expect(card.id).toBe('youtube');
    expect(card.title).toBe('YouTube');
    expect(card.badge).toEqual({ label: 'Confirming', tone: 'loading' });
    expect(card.current).toBe('fake');
    expect(card.recommended).toBe('multisplit');
    expect(card.progress).toEqual({ count: 1, required: 3 });
    expect(card.targets).toEqual(['youtube.com', 'googlevideo.com']);
    expect(card.explanation.join(' ')).toContain('3 checks in a row');
    expect(card.manualHint).toBe(false);
    expect(card.applyCandidate).toBeNull();
  });

  it('offers a manual apply only for a confirmed recommendation in recommend mode', () => {
    const ready = groupState({
      pending: { candidate: 'multisplit', count: 3 },
      ready: true,
    });
    const [card] = groupCards(status({ groups: { youtube: ready } }), live());
    expect(card.badge.label).toBe('Recommendation confirmed');
    expect(card.applyCandidate).toBe('multisplit');
    expect(card.manualHint).toBe(false);

    const [off] = groupCards(
      status({ policy: policy({ mode: 'off' }), groups: { youtube: ready } }),
      live(),
    );
    expect(off.applyCandidate).toBeNull();
    expect(off.manualHint).toBe(true);

    const [cooling] = groupCards(
      status({
        groups: { youtube: { ...ready, cooldowns: { multisplit: NOW + 60 } } },
      }),
      live(),
    );
    expect(cooling.applyCandidate).toBeNull();

    const [custom] = groupCards(
      status({ groups: { youtube: ready } }),
      live({ custom: true }),
    );
    expect(custom.applyCandidate).toBeNull();

    const [direct] = groupCards(
      status({
        groups: {
          youtube: {
            ...ready,
            pending: { candidate: 'direct', count: 3 },
            result: { ...recommendation, candidate: 'direct' },
          },
        },
      }),
      live(),
    );
    expect(direct.applyCandidate).toBeNull();

    const [auto] = groupCards(
      status({
        policy: policy({ mode: 'auto' }),
        groups: {
          youtube: {
            ...ready,
            decision: { reason: 'daily_limit_reached', at: NOW },
          },
        },
      }),
      live(),
    );
    expect(auto.manualHint).toBe(false);
    expect(auto.applyCandidate).toBeNull();
    expect(auto.explanation).toContain(decisionText('daily_limit_reached'));
  });

  it('explains a conflict with the target names, not ids', () => {
    const conflict: Prokop.AutotuneGroupResult = {
      status: 'conflict',
      candidate: null,
      confidence: null,
      reason: 'targets_need_different_strategies',
      conflict: [
        { target: 't_youtube', selected: 'multisplit' },
        { target: 't_video', selected: 'fake' },
      ],
    };
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({ pending: null, result: conflict }),
        },
      }),
      live(),
    );
    expect(card.badge).toEqual({ label: 'Conflict', tone: 'warning' });
    expect(card.recommended).toBeNull();
    expect(card.progress).toBeNull();
    const text = card.explanation.join(' ');
    expect(text).toContain('youtube.com: multisplit');
    expect(text).toContain('googlevideo.com: fake');
    expect(text).not.toContain('t_video');
  });

  it('never suggests turning DPI off when direct works', () => {
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({
            pending: null,
            result: {
              status: 'direct_stable',
              candidate: null,
              confidence: null,
              reason: 'direct_not_applicable',
            },
          }),
        },
      }),
      live(),
    );
    expect(card.badge.label).toBe('Bypass not needed');
    expect(card.recommended).toBeNull();
    expect(card.explanation.join(' ')).toContain(
      'never turns DPI bypass off by itself',
    );
  });

  it('marks a group never measured as not checked', () => {
    const [card] = groupCards(status(), live());
    expect(card.badge).toEqual({ label: 'Not checked', tone: 'neutral' });
    expect(card.checkedAt).toBeNull();
  });

  it('follows the current routing and falls back to the recorded groups', () => {
    const recorded = status({ groups: { old_rule: groupState() } });
    expect(groupCards(recorded, live()).map((c) => c.id)).toEqual(['youtube']);
    expect(groupCards(recorded, null).map((c) => c.id)).toEqual(['old_rule']);
  });

  it('reports the last apply and active cooldowns only', () => {
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({
            last_apply: {
              at: NOW - 100,
              group: 'youtube',
              candidate: 'multisplit',
              status: 'rolled_back',
              reason: 'verification_failed',
            },
            cooldowns: { multisplit: NOW + 3600, fake: NOW - 10 },
          }),
        },
      }),
      live(),
    );
    expect(card.lastApply?.outcome.label).toBe(
      'Check failed, rolled back automatically',
    );
    expect(card.cooldowns).toEqual([
      { candidate: 'multisplit', until: NOW + 3600 },
    ]);
  });

  it('hides a not-applied record', () => {
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({
            last_apply: {
              at: NOW,
              group: 'youtube',
              candidate: 'multisplit',
              status: 'not_applied',
              reason: 'dpi_guard_present',
            },
          }),
        },
      }),
      live(),
    );
    expect(card.lastApply).toBeNull();
  });

  it('says a custom rule strategy is kept', () => {
    const [card] = groupCards(
      status({ groups: { youtube: groupState() } }),
      live({ custom: true, current: '' }),
    );
    expect(card.current).toBe('Custom strategy');
    expect(card.explanation.join(' ')).toContain('custom strategy');
  });
});

describe('candidateRows', () => {
  it('orders stable first and shows latency only for successes', () => {
    const rows = candidateRows(summary());
    expect(rows.map((r) => r.name)).toEqual([
      'fake',
      'multisplit',
      'No bypass (direct)',
      'udp_fake',
    ]);
    expect(rows[1]).toMatchObject({
      result: '5 / 5',
      latency: '142 ms',
      selected: true,
    });
    expect(rows[3]).toMatchObject({ result: '—', latency: '—' });
    expect(rows[3].stability.label).toBe('Not supported');
  });
});

describe('targetRows', () => {
  it('describes each target in words', () => {
    const rows = targetRows([
      ...status().targets,
      {
        id: 't_off',
        host: 'example.org',
        enabled: false,
        resolver: null,
        last: null,
      },
      {
        id: 't_bad',
        host: 'bad.example',
        enabled: true,
        resolver: '192.0.2.53',
        last: summary({
          status: 'inconclusive',
          selected: null,
          reason: 'all_failed',
        }),
      },
    ]);
    expect(rows[0]).toMatchObject({ tone: 'success' });
    expect(rows[0].result).toContain('multisplit');
    expect(rows[1]).toMatchObject({ result: 'Not checked', tone: 'neutral' });
    expect(rows[2]).toMatchObject({ result: 'Disabled', tone: 'muted' });
    expect(rows[3].tone).toBe('warning');
    expect(rows[3].result).toContain('unreachable');
  });
});

describe('rule-list targets', () => {
  const lists = [
    {
      tag: 'Zapret-youtube-community-ruleset',
      rule: 'Zapret',
      label: 'Zapret',
    },
  ];
  const listTarget = (
    list: Partial<Prokop.AutotuneListView> | null,
    enabled = true,
  ): Prokop.AutotuneTarget => ({
    id: 'l_yt',
    host: null,
    enabled,
    resolver: null,
    last: null,
    rule_set: 'Zapret-youtube-community-ruleset',
    sample: 3,
    pins: [],
    list: list && {
      tag: 'Zapret-youtube-community-ruleset',
      total: 42,
      skipped: 2,
      pinned: false,
      members: ['m.youtube.com', 'youtu.be'],
      missing: [],
      error: null,
      ...list,
    },
  });
  const member = (id: string, host: string): Prokop.AutotuneTarget => ({
    id,
    host,
    enabled: true,
    resolver: null,
    parent: 'l_yt',
    last: id.endsWith('1') ? summary({}) : null,
  });

  it('names lists by their rule', () => {
    expect(ruleListName('Zapret-youtube-community-ruleset', 'Zapret')).toBe(
      'youtube',
    );
    expect(ruleListName('inline-custom-0284e7486d2f-ruleset', 'main')).toBe(
      'custom list',
    );
    expect(ruleListLabel('Zapret-youtube-community-ruleset', lists)).toBe(
      'Zapret: youtube',
    );
  });

  it('shows the measured domains under the list, not as own targets', () => {
    const rows = targetRows(
      [
        listTarget({}),
        member('l_yt__1', 'm.youtube.com'),
        member('l_yt__2', 'youtu.be'),
      ],
      lists,
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].host).toBe('List Zapret: youtube');
    expect(rows[0].result).toBe('Domains: 2');
    expect(rows[0].list?.note).toBe(
      'Checked 2 of 42 domains; 2 entries without a domain name are skipped',
    );
    expect(rows[0].list?.members.map((m) => [m.host, m.tone])).toEqual([
      ['m.youtube.com', 'success'],
      ['youtu.be', 'neutral'],
    ]);
  });

  it('explains pins and a list that gives nothing to check', () => {
    const pinned = targetRows(
      [
        listTarget({
          pinned: true,
          members: ['m.youtube.com'],
          missing: ['x.org'],
          skipped: 0,
        }),
      ],
      lists,
    )[0];
    expect(pinned.list?.note).toBe('Pinned domains: 1; not in the list: x.org');
    const broken = targetRows(
      [listTarget({ members: [], error: 'list_file_missing' })],
      lists,
    )[0];
    expect(broken).toMatchObject({
      result: 'Nothing to check',
      tone: 'warning',
    });
    expect(broken.list?.note).toContain('not downloaded');
    expect(targetRows([listTarget(null, false)], lists)[0]).toMatchObject({
      result: 'Disabled',
      tone: 'muted',
    });
    for (const reason of [
      'list_not_local',
      'list_file_missing',
      'list_unreadable',
      'list_has_no_domains',
      'list_domains_unresolved',
    ]) {
      expect(outsideReasonText(reason)).toBe(listErrorText(reason));
      expect(listErrorText(reason)).not.toMatch(/_/);
    }
    for (const reason of ['invalid_rule_set', 'invalid_sample', 'invalid_pin'])
      expect(mutationErrorText(reason)).not.toBe('The change was not saved.');
  });

  it('builds list target ids', () => {
    expect(targetIdFor('Zapret-youtube-community', [], 'l_')).toBe(
      'l_zapret_youtube_community',
    );
  });
});

describe('workerView', () => {
  it('distinguishes running, interrupted and postponed checks', () => {
    expect(workerView(null)).toBeNull();
    expect(workerView({ state: 'running', phase: 'measuring' })?.tone).toBe(
      'loading',
    );
    expect(workerView({ state: 'crashed' })?.tone).toBe('warning');
    expect(
      workerView({
        state: 'finished',
        result: 'skipped',
        reason: 'dpi_guard_present',
      })?.label,
    ).toContain('DPI protection is active');
    expect(
      workerView({
        state: 'finished',
        result: 'skipped',
        reason: 'runtime_guard_active',
      })?.label,
    ).toBe(
      'Last check postponed: a failed change left the DPI guard in place; restart Prokop',
    );
    expect(workerView({ state: 'finished', result: 'completed' })?.tone).toBe(
      'success',
    );
  });

  // UC-074: a run that could not write the autotune state says so.
  it('names a check that failed to save the state', () => {
    const view = workerView({
      state: 'finished',
      result: 'failed',
      reason: 'state_write_failed',
    });
    expect(view).toEqual({
      label: `The last check failed. ${stateNotSavedText()}`,
      tone: 'error',
    });
    expect(stateNotSavedText()).toContain('free space on the router');
    expect(
      workerView({
        state: 'finished',
        result: 'failed',
        reason: 'unknown_group',
      })?.label,
    ).toBe('The last check failed');
  });
});

describe('texts', () => {
  it('explains every outside reason without raw codes', () => {
    for (const reason of [
      'target_disabled',
      'target_unresolved',
      'target_not_fakeip_routed',
      'rule_owner_undecidable',
      'dpi_identity_unproven',
      'provider_not_supported',
      'routed_through_connection',
      'no_dpi_rule',
      'bypassed',
      'blocked',
      'not_a_dpi_rule',
      'outbound_without_rule',
      'something_new',
    ]) {
      const text = outsideReasonText(reason);
      expect(text).not.toMatch(/_/);
      expect(text.length).toBeGreaterThan(5);
    }
  });

  it('names the unsaved changes refusal', () => {
    expect(mutationErrorText('uncommitted_uci_changes')).toContain(
      'unsaved configuration changes',
    );
    expect(mutationErrorText(undefined)).toBe('The change was not saved.');
    // The target is saved; its old measurements could not be forgotten.
    expect(mutationErrorText('state_write_failed')).toBe(stateNotSavedText());
  });
});

describe('targetIdFor', () => {
  it('builds a valid unique UCI id', () => {
    expect(targetIdFor('YouTube.com', [])).toBe('t_youtube_com');
    expect(targetIdFor('youtube.com', ['t_youtube_com'])).toBe(
      't_youtube_com_2',
    );
    const long = targetIdFor('a'.repeat(80) + '.example', []);
    expect(long).toMatch(/^[A-Za-z0-9_]{1,32}$/);
    expect(targetIdFor('x.io', ['t_x_io', 't_x_io_2'])).toBe('t_x_io_3');
  });
});

describe('durationChoices', () => {
  it('keeps a custom configured value selectable', () => {
    expect(durationChoices(['1h', '6h'], '6h')).toEqual(['1h', '6h']);
    expect(durationChoices(['1h', '6h'], '90m')).toEqual(['1h', '6h', '90m']);
  });
});

describe('manual apply', () => {
  const ready = groupState({
    pending: { candidate: 'multisplit', count: 3 },
    ready: true,
  });

  it('confirms with the rule, the targets and both strategy names only', () => {
    const [card] = groupCards(status({ groups: { youtube: ready } }), live());
    const confirm = applyConfirmation(card);
    expect(confirm.title).toBe('Apply multisplit?');
    expect(confirm.message).toContain('"YouTube"');
    expect(confirm.message).toContain('whole group');
    expect(confirm.consequences).toEqual(['youtube.com', 'googlevideo.com']);
    expect(confirm.notes[0]).toBe('Now: fake. Will be: multisplit.');
    expect(confirm.notes[1]).toContain('snapshot');
    expect(confirm.notes[1]).toContain('restored automatically');
    expect(JSON.stringify(confirm)).not.toMatch(/dpi-desync|nfqws|--/);
  });

  it('says how a device-limited rule is verified', () => {
    const scoped = groupState({
      pending: { candidate: 'multisplit', count: 3 },
      ready: true,
      source_scoped: true,
    });
    const [card] = groupCards(status({ groups: { youtube: scoped } }), live());
    expect(card.deviceLimited).toBe(true);
    expect(card.applyCandidate).toBe('multisplit');
    expect(card.explanation.join(' ')).toContain('limited to devices');
    const confirm = applyConfirmation(card);
    expect(confirm.notes[1]).toContain('through the queue of this rule');
    expect(confirm.notes[1]).toContain('restored automatically');
    const [plain] = groupCards(status({ groups: { youtube: ready } }), live());
    expect(plain.deviceLimited).toBe(false);
    expect(plain.explanation.join(' ')).not.toContain('limited to devices');
  });

  it('labels only the reported steps', () => {
    expect(applyPhaseLabel(null)).toBe('Checking the recommendation');
    expect(applyPhaseLabel({ phase: 'applying', apply_phase: null })).toBe(
      'Preparing the change',
    );
    expect(
      applyPhaseLabel({ phase: 'applying', apply_phase: 'verifying' }),
    ).toBe('Checking the real production path');
    expect(
      applyPhaseLabel({ phase: 'applying', apply_phase: 'rolling_back' }),
    ).toBe('Restoring the previous configuration');
  });

  it('explains every outcome', () => {
    const view = (result: string | undefined, reason: string | null = null) =>
      applyResultView({ status: 'failed', result, reason }, 'multisplit');
    expect(
      applyResultView({ status: 'ok', result: 'applied' }, 'multisplit'),
    ).toEqual({
      tone: 'success',
      text: 'Strategy multisplit applied and checked.',
      attention: false,
    });
    expect(view('rolled_back').tone).toBe('warning');
    expect(view('rolled_back').text).toContain('restored the previous');
    expect(view('stale', 'config_changed').text).toContain('outdated');
    expect(view('refused', 'rule_changed').text).toContain('outdated');
    expect(view('refused', 'owner_changed').text).toContain('outdated');
    expect(view('refused', 'not_confirmed').text).toBe(
      'The recommendation is not confirmed yet.',
    );
    expect(view('refused', 'dpi_guard_present').text).toContain(
      'DPI protection is active',
    );
    // The rule strategy cannot take the recommendation (only its TCP/443
    // profile is replaced): the reason is named, not a bare refusal.
    expect(
      view('refused', 'plan_not_applicable:tcp443_profile_shared').text,
    ).toContain('--filter-tcp=443');
    expect(
      view('refused', 'plan_not_applicable:no_tcp443_profile').text,
    ).toContain('no HTTPS (TCP/443) profile');
    // A guard a failed service change kept (UC-019): the configuration did
    // not change, and a restart, not a new check, is what is needed.
    for (const outcome of ['stale', 'refused'])
      expect(view(outcome, 'runtime_guard_active')).toEqual({
        tone: 'warning',
        text: 'The strategy was not applied: a failed change left the DPI guard in place; restart Prokop.',
        attention: false,
      });
    expect(view('failed', 'reload_failed_recovered')).toMatchObject({
      tone: 'warning',
      attention: false,
    });
    // A reload queued behind another service action never ran.
    expect(view('failed', 'reload_queued_recovered')).toEqual({
      tone: 'warning',
      text: 'The new strategy was not applied: the service was busy and only queued the reload. The previous configuration is kept.',
      attention: false,
    });
    expect(view('needs_attention', 'apply_rollback_reload_queued')).toEqual({
      tone: 'error',
      text: 'Automatic recovery did not finish.',
      attention: true,
    });
    for (const reason of ['service_action_in_progress', 'reload_pending'])
      expect(view('stale', reason)).toEqual({
        tone: 'warning',
        text: 'The strategy was not applied: the service is busy.',
        attention: false,
      });
    // Prokop stopped by the user: refused before anything changed, never
    // read as busy or outdated (D-15).
    for (const outcome of ['stale', 'refused'])
      expect(view(outcome, 'service_stopped')).toEqual({
        tone: 'warning',
        text: 'The strategy was not applied: Prokop is stopped; start it first.',
        attention: false,
      });
    expect(view('needs_attention', 'lkg_confirm_failed')).toEqual({
      tone: 'error',
      text: 'Automatic recovery did not finish.',
      attention: true,
    });
    // UC-017: the candidate failed, but the configuration was edited during
    // the check: kept, not rolled back; the rule may still use the candidate.
    const edited = view(
      'needs_attention',
      'verification_failed:config_changed_during_transaction',
    );
    expect(edited).toMatchObject({ tone: 'error', attention: true });
    expect(edited.text).toContain('did not roll back');
    expect(edited.text).toContain('Before autotune');
    expect(
      applyOutcomeView(
        'needs_attention',
        'verification_failed:config_changed_during_transaction',
      ),
    ).toEqual({
      label: 'Check failed, not rolled back: configuration edited',
      tone: 'error',
    });
    expect(
      applyOutcomeView('needs_attention', 'verification_failed:rollback_busy')
        .label,
    ).toBe('Rollback did not finish');
    // UC-023: the candidate reload failed and an edit landed meanwhile: the
    // edit was kept and saved, nothing was rolled back.
    const editedDuringApply = view(
      'needs_attention',
      'apply_config_changed_during_transaction',
    );
    expect(editedDuringApply).toMatchObject({ tone: 'error', attention: true });
    expect(editedDuringApply.text).toContain('did not finish');
    expect(editedDuringApply.text).toContain('kept that change');
    // Whether a snapshot of it could be saved is not known here.
    expect(editedDuringApply.text).not.toContain('Concurrent edit');
    // The edit landed while the rollback itself ran: the rollback started,
    // and the runtime may run either configuration.
    const editedDuringRollback = view(
      'needs_attention',
      'verification_failed:config_changed_during_rollback',
    );
    expect(editedDuringRollback).toMatchObject({
      tone: 'error',
      attention: true,
    });
    expect(editedDuringRollback.text).toContain('Before autotune');
    expect(editedDuringRollback.text).toContain('not known whether');
    expect(editedDuringRollback.text).not.toContain('did not roll back');
    expect(
      applyOutcomeView(
        'needs_attention',
        'verification_failed:config_changed_during_rollback',
      ),
    ).toEqual({
      label: 'Check failed, rollback did not finish: configuration edited',
      tone: 'error',
    });
    // The configuration is not last known working yet: re-running the
    // check alone does not help.
    const notConfirmed = view('stale', 'config_not_last_known_good');
    expect(notConfirmed).toMatchObject({ tone: 'warning', attention: false });
    expect(notConfirmed.text).toContain('last known working');
    expect(notConfirmed.text).not.toContain('Run the check again');
    expect(
      applyOutcomeView(
        'needs_attention',
        'apply_config_changed_during_transaction',
      ),
    ).toEqual({
      label: 'Apply did not finish: configuration edited',
      tone: 'error',
    });
    expect(view('failed', 'interrupted_after_apply').attention).toBe(true);
    expect(applyResultView(null, 'multisplit').attention).toBe(true);
    expect(
      applyResultView({ status: 'failed', reason: 'invalid_group' }, null)
        .attention,
    ).toBe(false);
    expect(
      applyResultView(
        {
          status: 'busy',
          result: 'refused',
          reason: 'autotune_worker_running',
        },
        null,
      ).text,
    ).toBe('Another autotune operation is running.');
  });

  it('marks a manual last apply', () => {
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({
            last_apply: {
              at: NOW - 10,
              group: 'youtube',
              candidate: 'multisplit',
              status: 'applied',
              reason: null,
              counted: false,
              trigger: 'manual',
            },
          }),
        },
      }),
      live(),
    );
    expect(card.lastApply?.candidate).toBe('multisplit (manually)');
  });
});

describe('recorded apply and its rollback', () => {
  const recorded = (
    overrides: Partial<Prokop.AutotuneRecordedApply> = {},
  ): Prokop.AutotuneRecordedApply => ({
    phase: 'applied',
    reason: null,
    group: 'youtube',
    candidate: 'multisplit',
    finished_at: NOW - 30,
    resolved: true,
    diagnosis: 'not_applied',
    in_progress: false,
    rollback: false,
    ...overrides,
  });

  it('says why nothing is confirmed while the rule runs an unverified strategy', () => {
    const view = recordedApplyView(
      recorded({
        phase: 'needs_attention',
        reason: 'verification_failed:config_changed_during_transaction',
        resolved: true,
        diagnosis: 'superseded',
        unverified_strategy: true,
      }),
      'YouTube',
    );
    expect(view).toMatchObject({ tone: 'warning', attention: true });
    expect(view?.text).toContain('multisplit in the rule "YouTube"');
    expect(view?.text).toContain('last known working');
    expect(view?.text).toContain('History and recovery');
    expect(
      recordedApplyView(
        recorded({ diagnosis: 'superseded', unverified_strategy: false }),
        'YouTube',
      ),
    ).toBeNull();
  });

  it('says nothing about a settled apply that cannot be rolled back', () => {
    expect(recordedApplyView(null, 'YouTube')).toBeNull();
    expect(recordedApplyView(recorded(), 'YouTube')).toBeNull();
    expect(
      recordedApplyView(
        recorded({ phase: 'verifying', in_progress: true, resolved: false }),
        'YouTube',
      ),
    ).toBeNull();
  });

  it('asks for a decision about an unverified candidate', () => {
    const view = recordedApplyView(
      recorded({
        phase: 'verifying',
        resolved: false,
        diagnosis: 'candidate_active',
        rollback: true,
      }),
      'YouTube',
    );
    expect(view?.attention).toBe(true);
    expect(view?.text).toContain('multisplit');
    expect(view?.text).toContain('"YouTube"');
    expect(view?.text).toContain('rolled back');
  });

  it('says what happened to a candidate that still waits for a decision', () => {
    const view = (reason: string | null, phase = 'needs_attention') =>
      recordedApplyView(
        recorded({
          phase,
          reason,
          resolved: false,
          diagnosis: 'candidate_active',
          rollback: true,
        }),
        'YouTube',
      )?.text ?? '';
    // Verified in production; only its record as last known working failed.
    expect(view('lkg_confirm_failed')).toContain('passed its check');
    expect(view('lkg_confirm_failed')).not.toContain('not checked');
    // The check ran and failed; the automatic rollback did not finish.
    for (const reason of [
      'verification_failed:rollback_recovered',
      'verification_failed:rollback_busy',
    ]) {
      expect(view(reason)).toContain('failed its check');
      expect(view(reason)).not.toContain('not checked');
    }
    expect(view('operator_rollback:rollback_needs_attention')).toContain(
      'rollback of the last change',
    );
    // A verification that never ended.
    expect(view(null, 'verifying')).toContain('not checked to the end');
    expect(view('interrupted_after_apply', 'failed')).toContain(
      'not checked to the end',
    );
    for (const reason of [
      'lkg_confirm_failed',
      'verification_failed:rollback_recovered',
      null,
    ])
      expect(view(reason)).toContain('wait until it is rolled back');
  });

  it('points to History when there is no snapshot to roll back to', () => {
    const missing = recordedApplyView(
      recorded({
        phase: 'verifying',
        resolved: false,
        diagnosis: 'candidate_active',
        rollback: false,
      }),
      'YouTube',
    );
    expect(missing?.attention).toBe(true);
    expect(missing?.text).toContain('History and recovery');
    expect(missing?.text).not.toContain('wait until it is rolled back');
    const damaged = recordedApplyView(
      recorded({
        phase: 'needs_attention',
        reason: 'apply_state_unreadable',
        group: null,
        candidate: null,
        resolved: false,
        diagnosis: 'state_unreadable',
        rollback: false,
      }),
      null,
    );
    expect(damaged?.attention).toBe(true);
    expect(damaged?.text).toContain('History and recovery');
    expect(damaged?.text).toContain('last known working');
  });

  it('names a damaged record and an unknown state', () => {
    const damaged = recordedApplyView(
      recorded({
        phase: 'needs_attention',
        reason: 'apply_state_unreadable',
        group: null,
        candidate: null,
        resolved: false,
        diagnosis: 'state_unreadable',
        rollback: true,
      }),
      null,
    );
    expect(damaged?.attention).toBe(true);
    expect(damaged?.text).toContain('damaged');
    expect(damaged?.text).toContain('last known working');
    const unknown = recordedApplyView(
      recorded({ phase: null, resolved: null, diagnosis: null }),
      null,
    );
    expect(unknown?.tone).toBe('warning');
    expect(unknown?.attention).toBe(false);
    const open = recordedApplyView(
      recorded({
        phase: 'applying',
        resolved: false,
        diagnosis: 'in_transaction',
      }),
      'YouTube',
    );
    expect(open?.attention).toBe(true);
    expect(open?.text).toContain('History and recovery');
  });

  it('offers the rollback of a verified apply without alarm', () => {
    const view = recordedApplyView(
      recorded({ diagnosis: 'candidate_active', rollback: true }),
      'YouTube',
    );
    expect(view).toMatchObject({ tone: 'neutral', attention: false });
    expect(view?.text).toContain('can be rolled back');
  });

  it('confirms with the rule and strategy names only', () => {
    const confirm = rollbackConfirmation(
      recorded({ diagnosis: 'candidate_active', rollback: true }),
      'YouTube',
    );
    expect(confirm.title).toBe('Roll back multisplit?');
    expect(confirm.message).toContain('"YouTube"');
    expect(confirm.consequences?.join(' ')).toContain('Before autotune');
    expect(confirm.confirmLabel).toBe('Roll back');
    const damaged = rollbackConfirmation(
      recorded({
        group: null,
        candidate: null,
        diagnosis: 'state_unreadable',
        rollback: true,
      }),
      null,
    );
    expect(damaged.consequences?.join(' ')).toContain('last known working');
    // Edits made since then are undone too, and where to find them.
    expect(damaged.consequences?.join(' ')).toContain('undone');
    expect(damaged.consequences?.join(' ')).toContain('Before restore');
    expect(JSON.stringify(damaged)).not.toContain('null');
  });

  // UC-074: done, but the autotune state does not show it.
  it('keeps what an unrecorded apply or rollback did', () => {
    const applied = applyResultView(
      {
        status: 'failed',
        result: 'applied',
        reason: 'state_write_failed',
        recorded: false,
      },
      'multisplit',
    );
    expect(applied.text).toBe(
      `${applyResultView({ status: 'ok', result: 'applied' }, 'multisplit').text} ${stateNotSavedText()}`,
    );
    expect(applied.tone).toBe('warning');
    const rolledBackByCheck = applyResultView(
      {
        status: 'failed',
        result: 'rolled_back',
        reason: 'verification_failed',
        recorded: false,
      },
      'multisplit',
    );
    expect(rolledBackByCheck.text).toContain(
      'restored the previous configuration',
    );
    expect(rolledBackByCheck.text).toContain(stateNotSavedText());
    expect(
      applyResultView(
        { status: 'refused', result: 'refused', reason: 'state_write_failed' },
        'multisplit',
      ).text,
    ).toBe(`The strategy was not applied. ${stateNotSavedText()}`);
    const rollback = rollbackResultView({
      status: 'failed',
      result: 'rolled_back',
      reason: 'state_write_failed',
      restored: true,
      recorded: false,
    });
    expect(rollback).toEqual({
      tone: 'warning',
      text: `The configuration before the change is restored. ${stateNotSavedText()}`,
      attention: false,
    });
    const unfinished = rollbackResultView({
      status: 'failed',
      result: 'needs_attention',
      reason: 'operator_rollback:config_changed_during_rollback',
      recorded: false,
    });
    expect(unfinished.tone).toBe('error');
    expect(unfinished.attention).toBe(true);
    expect(unfinished.text).toContain(stateNotSavedText());
  });

  it('explains every rollback outcome', () => {
    expect(
      rollbackResultView({ status: 'ok', result: 'rolled_back' }),
    ).toMatchObject({ tone: 'success', attention: false });
    expect(
      rollbackResultView({
        status: 'busy',
        result: 'refused',
        reason: 'autotune_worker_running',
      }).text,
    ).toBe('Another autotune operation is running.');
    expect(
      rollbackResultView({
        status: 'failed',
        result: 'failed',
        reason: 'rollback_needs_candidate_config',
      }).text,
    ).toContain('changed after the apply');
    // UC-017: an edit landed right before the restore; nothing changed.
    expect(
      rollbackResultView({
        status: 'failed',
        result: 'failed',
        reason: 'rollback_not_started:config_changed_during_transaction',
      }).text,
    ).toContain('changed after the apply');
    // UC-019: a guard a failed service change kept; nothing was changed.
    for (const reason of [
      'runtime_guard_active',
      'rollback_not_started:runtime_guard_active',
    ])
      expect(
        rollbackResultView({ status: 'failed', result: 'failed', reason }),
      ).toEqual({
        tone: 'warning',
        text: 'Nothing was rolled back: a failed change left the DPI guard in place; restart Prokop.',
        attention: false,
      });
    // UC-068: uci changes staged on the router.
    const staged = rollbackResultView({
      status: 'failed',
      result: 'failed',
      reason: 'rollback_not_started:uncommitted_uci_changes',
    });
    expect(staged).toMatchObject({ tone: 'warning', attention: false });
    expect(staged.text).toContain('Commit or revert');
    // The rollback of an unreadable record names it without the prefix.
    expect(
      rollbackResultView({
        status: 'failed',
        result: 'failed',
        reason: 'rollback_uncommitted_uci_changes',
      }),
    ).toEqual(staged);
    expect(
      rollbackResultView({
        status: 'failed',
        result: 'failed',
        reason: 'service_stopped',
      }).text,
    ).toContain('stopped');
    expect(
      rollbackResultView({
        status: 'failed',
        result: 'needs_attention',
        reason: 'operator_rollback:rollback_needs_attention',
      }),
    ).toMatchObject({ tone: 'error', attention: true });
    // An edit committed while the rollback's own reload ran: kept, and the
    // runtime may run either configuration.
    const editedDuringRollback = rollbackResultView({
      status: 'failed',
      result: 'needs_attention',
      reason: 'operator_rollback:config_changed_during_rollback',
    });
    expect(editedDuringRollback).toMatchObject({
      tone: 'error',
      attention: true,
    });
    expect(editedDuringRollback.text).toContain('kept that change');
    expect(editedDuringRollback.text).toContain('not known whether');
    // No answer (the request timed out): the rollback may still run.
    expect(rollbackResultView(null)).toMatchObject({
      tone: 'warning',
      attention: false,
    });
    expect(rollbackResultView(null).text).toContain('may still be running');
    expect(
      rollbackResultView({
        status: 'failed',
        result: 'failed',
        reason: 'last_known_working_missing',
      }).text,
    ).toContain('History and recovery');
  });

  it('tells whether a damaged record needed a restore', () => {
    const setAside = rollbackResultView({
      status: 'ok',
      result: 'rolled_back',
      reason: 'apply_state_unreadable',
      restored: false,
    });
    expect(setAside.tone).toBe('success');
    expect(setAside.text).toContain('set aside');
    expect(setAside.text).not.toContain('is restored');
    const restored = rollbackResultView({
      status: 'ok',
      result: 'rolled_back',
      reason: 'apply_state_unreadable',
      restored: true,
    });
    expect(restored.text).toContain(
      'last known working configuration is restored',
    );
    expect(
      rollbackResultView({
        status: 'ok',
        result: 'rolled_back',
        reason: 'operator_rollback',
        restored: true,
      }).text,
    ).toBe('The configuration before the change is restored.');
  });

  it('labels a rollback by the administrator as such on the group', () => {
    const [card] = groupCards(
      status({
        groups: {
          youtube: groupState({
            last_apply: {
              at: NOW - 10,
              group: 'youtube',
              candidate: 'multisplit',
              status: 'rolled_back',
              reason: 'operator_rollback',
              counted: false,
              trigger: 'manual',
            },
          }),
        },
      }),
      live(),
    );
    expect(card.lastApply?.outcome.label).toBe(
      'Rolled back by an administrator',
    );
  });
});

describe('runProgressView', () => {
  const item = (
    host: string,
    state: string,
    extra: Partial<Prokop.AutotuneRunItem> = {},
  ): Prokop.AutotuneRunItem => ({
    id: host,
    host,
    group: 'Zapret',
    state,
    expected_s: 100,
    ...extra,
  });
  const worker = (
    items: Prokop.AutotuneRunItem[],
    tune: Prokop.AutotuneTuneProgress | null = null,
  ): Prokop.AutotuneWorker => ({
    state: 'running',
    progress: { started_at: 1000, total: items.length, done: 0, items },
    tune,
  });

  it('shows the target measured now, its probes and the time left', () => {
    const view = runProgressView(
      worker(
        [
          item('youtube.com', 'done', {
            status: 'selected',
            selected: 'multisplit',
            confidence: 'high',
          }),
          item('youtu.be', 'running', { started_at: 1100 }),
          item('ytimg.com', 'pending'),
        ],
        { phase: 'measuring', done: 16, total: 32 },
      ),
      1140,
    )!;
    // 100 + 100 * (0.05 + 0.75 * 0.5) = 142.5 of 300.
    expect(view.percent).toBe(48);
    expect(view.title).toBe('Target 2 of 3: youtu.be');
    expect(view.phase).toBe('probes: 16 of 32');
    // 100 pending + 60 left of the running target.
    expect(view.remaining).toBe('about 3 min');
    expect(view.items.map((i) => i.tone)).toEqual([
      'success',
      'loading',
      'neutral',
    ]);
    expect(view.items[0].text).toContain('multisplit');
  });

  it('explains the wait for probe connections', () => {
    const view = runProgressView(
      worker([item('youtube.com', 'running', { started_at: 1000 })], {
        phase: 'holding',
        waited_s: 40,
        timeout_s: 300,
      }),
      1200,
    )!;
    expect(view.phase).toBe(
      'waiting for probe connections to close: 40 s (up to 300 s)',
    );
    expect(view.remaining).toBe('less than a minute');
  });

  it('has nothing to show without progress', () => {
    expect(runProgressView({ state: 'running' }, 0)).toBeNull();
    expect(runProgressView({ state: 'finished' }, 0)).toBeNull();
  });
});

describe('S9 autotune texts', () => {
  it('shows a recommendation the rule strategy cannot take as not applicable (UC-032)', () => {
    const notApplicable = groupState({
      pending: null,
      ready: false,
      result: {
        ...recommendation,
        status: 'not_applicable',
        reason: 'tcp443_profile_shared',
      },
    });
    const [card] = groupCards(
      status({ groups: { youtube: notApplicable } }),
      live(),
    );
    expect(card.badge).toEqual({ label: 'Cannot be applied', tone: 'neutral' });
    expect(card.applyCandidate).toBeNull();
    expect(card.progress).toBeNull();
    expect(card.explanation.join(' ')).toContain('--filter-tcp=443');
  });

  it('explains an invalid measurement and the probe budget (UC-111, UC-031)', () => {
    expect(targetReasonText('candidate_bypassed')).toContain(
      'The check was invalid',
    );
    expect(targetReasonText('too_many_probes')).toContain('lower the number');
  });

  it('labels failed and unconfirmed applies by what happened (UC-112)', () => {
    expect(
      applyOutcomeView('failed', 'apply_failed:snapshot_retention_full'),
    ).toEqual({
      label: 'Not applied, the previous configuration is kept',
      tone: 'warning',
    });
    expect(applyOutcomeView('failed', 'reload_failed_recovered').label).toBe(
      'Service reload failed, previous configuration restored',
    );
    for (const reason of [
      'lkg_confirm_failed',
      'config_changed_during_verification',
    ])
      expect(applyOutcomeView('needs_attention', reason).label).toBe(
        'Applied and checked, but not confirmed as the working configuration',
      );
    expect(applyOutcomeView('needs_attention', 'rollback_failed').label).toBe(
      'Rollback did not finish',
    );
  });

  it('locks the page while any apply runs, also a scheduled one (UC-113)', () => {
    const base = status();
    expect(applyRunning(null)).toBe(false);
    expect(
      applyRunning({
        ...base,
        worker: { state: 'running', trigger: 'schedule', phase: 'applying' },
      }),
    ).toBe(true);
    expect(
      applyRunning({
        ...base,
        worker: { state: 'running', trigger: 'schedule', phase: 'measuring' },
      }),
    ).toBe(false);
    expect(mutationErrorText('apply_in_progress')).toContain('being applied');
  });

  it('counts only scheduled confirmations in automatic mode (D-11a)', () => {
    const manualOnly = groupState({
      pending: { candidate: 'multisplit', count: 3, scheduled: 1 },
      ready: true,
      ready_auto: false,
    });
    const [auto] = groupCards(
      status({
        policy: policy({ mode: 'auto' }),
        groups: { youtube: manualOnly },
      }),
      live(),
    );
    expect(auto.badge.label).toBe('Confirming');
    expect(auto.progress).toEqual({ count: 1, required: 3 });
    expect(auto.explanation.join(' ')).toContain('only scheduled checks count');
    const [recommend] = groupCards(
      status({ groups: { youtube: manualOnly } }),
      live(),
    );
    expect(recommend.badge.label).toBe('Recommendation confirmed');
    expect(recommend.applyCandidate).toBe('multisplit');
  });
});
