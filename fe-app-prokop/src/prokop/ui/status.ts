import { asText } from '../../helpers/asText';
// Shared status words and tones: a page maps the raw values of its backend
// module to this small semantic set and takes the label and tone from one
// place, so the same state never reads differently on two pages.

export type SemanticStatus =
  | 'healthy'
  | 'warning'
  | 'error'
  | 'needs_attention'
  | 'busy'
  | 'not_checked'
  | 'unsupported'
  | 'off'
  | 'unknown';

export type StatusTone =
  | 'success'
  | 'warning'
  | 'error'
  | 'loading'
  | 'neutral'
  | 'muted';

export function statusLabel(status: SemanticStatus): string {
  switch (status) {
    case 'healthy':
      return _('Healthy');
    case 'warning':
      return _('Warning');
    case 'error':
      return _('Error');
    case 'needs_attention':
      return _('Needs attention');
    case 'busy':
      return _('In progress');
    case 'not_checked':
      return _('Not checked');
    case 'unsupported':
      return _('Not supported');
    case 'off':
      return _('Disabled');
    default:
      return _('Unknown');
  }
}

export function statusTone(status: SemanticStatus): StatusTone {
  switch (status) {
    case 'healthy':
      return 'success';
    case 'warning':
      return 'warning';
    case 'error':
    case 'needs_attention':
      return 'error';
    case 'busy':
      return 'loading';
    case 'unsupported':
    case 'off':
      return 'muted';
    default:
      return 'neutral';
  }
}

// Outcomes of recorded events (history, recent activity) are not states:
// "recovered" and "rolled back" are results, so they get their own words.
export type EventOutcome =
  | 'succeeded'
  | 'recovered'
  | 'rolled_back'
  | 'failed'
  | 'needs_attention'
  | 'cancelled'
  | 'not_started'
  | 'unknown';

const EVENT_OUTCOMES: Record<string, EventOutcome> = {
  success: 'succeeded',
  succeeded: 'succeeded',
  applied: 'succeeded',
  recovered: 'recovered',
  rolled_back: 'rolled_back',
  failure: 'failed',
  failed: 'failed',
  needs_attention: 'needs_attention',
  stale: 'cancelled',
  refused: 'cancelled',
  cancelled: 'cancelled',
  // A restore while Prokop was stopped by the user (diagnostics/health.uc).
  not_started: 'not_started',
};

export function toEventOutcome(raw: unknown): EventOutcome {
  return EVENT_OUTCOMES[raw == null ? '' : String(raw)] ?? 'unknown';
}

export function eventOutcomeView(outcome: EventOutcome): {
  label: string;
  tone: StatusTone;
} {
  switch (outcome) {
    case 'succeeded':
      return { label: _('Succeeded'), tone: 'success' };
    case 'recovered':
      return { label: _('Recovered'), tone: 'warning' };
    case 'rolled_back':
      return { label: _('Rolled back'), tone: 'warning' };
    case 'failed':
      return { label: _('Failed'), tone: 'error' };
    case 'needs_attention':
      return { label: _('Needs attention'), tone: 'error' };
    case 'cancelled':
      return { label: _('Cancelled'), tone: 'neutral' };
    case 'not_started':
      return { label: _('Saved, service stopped'), tone: 'warning' };
    default:
      return { label: _('Unknown'), tone: 'neutral' };
  }
}

// What a recorded event was about (diagnostics/health.uc event kinds).
export function eventKindLabel(kind: string): string {
  switch (kind) {
    case 'start':
      return _('Service start');
    case 'reload':
      return _('Configuration reload');
    case 'restore':
      return _('Snapshot restore');
    case 'autotune_apply':
      return _('Autotune apply');
    case 'autotune_rollback':
      return _('Autotune rollback');
    case 'autotune_observation':
      return _('Autotune observation passed');
    case 'autotune_mode':
      return _('Autotune mode changed');
    case 'autotune_recommendation':
      return _('Autotune recommendation confirmed');
    case 'autotune_run':
      return _('Autotune run');
    case 'snapshot_create':
      return _('Snapshot created');
    case 'snapshot_delete':
      return _('Snapshot deleted');
    case 'snapshot_clear':
      return _('Automatic snapshots cleared');
    case 'history_clear':
      return _('History cleared');
    case 'cron_refresh':
      return _('Scheduled jobs update');
    case 'config_migration':
      return _('Configuration migrated by the update');
    default:
      return _('Other event');
  }
}

// Where a route or strategy fact comes from. Always shown next to the fact.
export type Provenance = 'observed' | 'configured' | 'simulated' | 'unknown';

export function provenanceLabel(provenance: Provenance): string {
  switch (provenance) {
    case 'observed':
      return _('Observed');
    case 'configured':
      return _('From configuration');
    case 'simulated':
      return _('Calculated');
    default:
      return _('Not determined');
  }
}

export function provenanceDescription(provenance: Provenance): string {
  switch (provenance) {
    case 'observed':
      return _('Seen in an active connection');
    case 'configured':
      return _('Derived from configuration');
    case 'simulated':
      return _('Calculated result');
    default:
      return _('Not determined');
  }
}

export function renderStatus(view: { label: string; tone: StatusTone }) {
  return E(
    'span',
    { class: `fkp-status fkp-status--${view.tone}` },
    asText(view.label),
  );
}

export function renderProvenance(provenance: Provenance) {
  return E(
    'span',
    {
      class: `fkp-provenance fkp-provenance--${provenance}`,
      title: provenanceDescription(provenance),
    },
    asText(provenanceLabel(provenance)),
  );
}
