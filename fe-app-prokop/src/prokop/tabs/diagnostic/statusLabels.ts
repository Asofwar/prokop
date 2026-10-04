import { asText } from '../../../helpers/asText';
export { eventKindLabel } from '../../ui/status';
import type { IDiagnosticsChecksStoreItem } from '../../services';

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

export function renderStatusBadge(status: DisplayStatus) {
  return E(
    'span',
    { class: `fkp-diag-badge fkp-diag-badge--${status.tone}` },
    asText(status.text),
  );
}
