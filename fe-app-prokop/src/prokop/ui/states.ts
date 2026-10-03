import type { AsyncSnapshot } from './asyncState';

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
      action.label,
    ),
  ];
}

export function renderEmptyState(
  title: string,
  hint?: string,
  action?: StateAction,
) {
  return E('div', { class: 'fkp-state fkp-state--empty' }, [
    E('div', { class: 'fkp-state__title' }, title),
    ...(hint ? [E('div', { class: 'fkp-state__hint' }, hint)] : []),
    ...renderAction(action),
  ]);
}

export function renderLoadingState(label = _('Loading…')) {
  return E(
    'div',
    { class: 'fkp-state fkp-state--loading', role: 'status' },
    E('div', { class: 'fkp-state__title' }, label),
  );
}

export function renderErrorState(
  title: string,
  onRetry?: () => void,
  details?: string,
) {
  return E('div', { class: 'fkp-state fkp-state--error', role: 'alert' }, [
    E('div', { class: 'fkp-state__title' }, title),
    ...renderAction(
      onRetry ? { label: _('Retry'), onClick: onRetry } : undefined,
    ),
    ...(details ? [renderTechnicalDetails(details)] : []),
  ]);
}

// Missing data because of the role is not a failure: say so neutrally.
export function renderForbiddenState(
  label = _('Available to administrators only.'),
) {
  return E(
    'div',
    { class: 'fkp-state fkp-state--forbidden' },
    E('div', { class: 'fkp-state__hint' }, label),
  );
}

export function renderTechnicalDetails(text: string) {
  return E('details', { class: 'fkp-tech' }, [
    E('summary', {}, _('Technical details')),
    E('pre', { class: 'fkp-tech__content' }, text),
  ]);
}

export function timeoutMessage(timeoutMs: number) {
  return _('The router did not respond in %d s').replace(
    '%d',
    String(Math.round(timeoutMs / 1000)),
  );
}

interface AsyncStateView<T> {
  renderReady: (data: T) => Node;
  empty?: { title: string; hint?: string; action?: StateAction };
  errorTitle?: string;
  loadingLabel?: string;
  timeoutMs?: number;
  onRetry?: () => void;
}

// Refreshes keep showing the last good data instead of a spinner.
export function renderAsyncState<T>(
  snapshot: AsyncSnapshot<T>,
  view: AsyncStateView<T>,
): Node {
  switch (snapshot.phase) {
    case 'ready':
      return view.renderReady(snapshot.data as T);
    case 'empty':
      return renderEmptyState(
        view.empty?.title ?? _('No data'),
        view.empty?.hint,
        view.empty?.action,
      );
    case 'timeout':
      return renderErrorState(
        view.timeoutMs
          ? timeoutMessage(view.timeoutMs)
          : _('The router did not respond'),
        view.onRetry,
      );
    case 'error':
      return renderErrorState(
        view.errorTitle ?? _('Could not load data'),
        view.onRetry,
        snapshot.error,
      );
    case 'loading':
      return snapshot.data !== undefined
        ? view.renderReady(snapshot.data)
        : renderLoadingState(view.loadingLabel);
    default:
      return renderLoadingState(view.loadingLabel);
  }
}
