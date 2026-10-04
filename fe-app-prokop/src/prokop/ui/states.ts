import { asText } from '../../helpers/asText';
interface StateAction {
  label: string;
  onClick: () => void;
}

function renderAction(action?: StateAction) {
  if (!action) return [];

  return [
    E(
      'button',
      {
        type: 'button',
        class: 'btn cbi-button',
        click: () => action.onClick(),
      },
      asText(action.label),
    ),
  ];
}

export function renderEmptyState(
  title: string,
  hint?: string,
  action?: StateAction,
) {
  return E('div', { class: 'fkp-state fkp-state--empty' }, [
    E('div', { class: 'fkp-state__title' }, asText(title)),
    ...(hint ? [E('div', { class: 'fkp-state__hint' }, asText(hint))] : []),
    ...renderAction(action),
  ]);
}

export function renderLoadingState(label = _('Loading…')) {
  return E(
    'div',
    { class: 'fkp-state fkp-state--loading', role: 'status' },
    E('div', { class: 'fkp-state__title' }, asText(label)),
  );
}

export function renderErrorState(
  title: string,
  onRetry?: () => void,
  details?: string,
) {
  return E('div', { class: 'fkp-state fkp-state--error', role: 'alert' }, [
    E('div', { class: 'fkp-state__title' }, asText(title)),
    ...renderAction(
      onRetry ? { label: _('Retry'), onClick: onRetry } : undefined,
    ),
    ...(details ? [renderTechnicalDetails(details)] : []),
  ]);
}

export function renderTechnicalDetails(text: string) {
  return E('details', { class: 'fkp-tech' }, [
    E('summary', {}, _('Technical details')),
    E('pre', { class: 'fkp-tech__content' }, asText(text)),
  ]);
}
