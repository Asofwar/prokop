export { eventKindLabel } from '../../ui/status';
import type { IDiagnosticsChecksStoreItem } from '../../services';
import type { Prokop } from '../../types';

export type StatusTone =
  | 'success'
  | 'warning'
  | 'error'
  | 'neutral'
  | 'loading';

export interface DisplayStatus {
  text: string;
  tone: StatusTone;
}

export function checkStatus(
  state: IDiagnosticsChecksStoreItem['state'],
): DisplayStatus {
  switch (state) {
    case 'success':
      return { text: _('Healthy'), tone: 'success' };
    case 'warning':
      return { text: _('Needs attention'), tone: 'warning' };
    case 'error':
      return { text: _('Error'), tone: 'error' };
    case 'loading':
      return { text: _('Checking…'), tone: 'loading' };
    case 'unsupported':
      return { text: _('Not available for checking'), tone: 'neutral' };
    default:
      return { text: _('Not checked'), tone: 'neutral' };
  }
}

export function eventStatus(status: string): DisplayStatus {
  switch (status) {
    case 'success':
      return { text: _('Succeeded'), tone: 'success' };
    case 'recovered':
      return { text: _('Recovered'), tone: 'warning' };
    case 'failure':
      return { text: _('Failed'), tone: 'error' };
    case 'needs_attention':
      return { text: _('Needs attention'), tone: 'error' };
    default:
      return { text: _('Not available for checking'), tone: 'neutral' };
  }
}

export function healthStatus(level: Prokop.HealthLevel): DisplayStatus {
  switch (level) {
    case 'ok':
      return { text: _('Healthy'), tone: 'success' };
    case 'warning':
      return { text: _('Needs attention'), tone: 'warning' };
    case 'error':
      return { text: _('Error'), tone: 'error' };
    case 'transitioning':
      return { text: _('Switching'), tone: 'loading' };
    default:
      return { text: _('Not available for checking'), tone: 'neutral' };
  }
}

export function formatTime(timestamp: number) {
  return new Date(timestamp * 1000).toLocaleString();
}

export function renderStatusBadge(status: DisplayStatus) {
  return E(
    'span',
    { class: `fkp-diag-badge fkp-diag-badge--${status.tone}` },
    status.text,
  );
}
