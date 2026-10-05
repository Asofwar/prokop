import { asText } from '../../../helpers/asText';
import { renderButton } from '../../../partials';
import { ProkopShellMethods } from '../../methods';
import { isReadonlyMode } from '../../services/accessMode.service';
import { Prokop } from '../../types';
import { describeListUpdateStatus } from './listsUpdateStatus';

// Manual lists update and the outcome of the last one (C6). The router runs
// the update in the background; the card polls its state while it runs.
const LIST_UPDATE_POLL_INTERVAL_MS = 3000;
// The worker records itself a moment after the start answered; until then
// a status without "running" does not mean the update already ended.
const LIST_UPDATE_START_GRACE_MS = 15000;

let status: Prokop.ListUpdateStatus | null = null;
let starting = false;
let startError = '';
let startedAt = 0;
let pollTimer: ReturnType<typeof setTimeout> | null = null;

// Started here, but the worker has neither shown up as running nor recorded
// a result newer than the start yet.
function awaitingWorker(now: number) {
  const finishedAt = (status?.last_result?.finished_at ?? 0) * 1000;
  return (
    !status?.running &&
    now - startedAt < LIST_UPDATE_START_GRACE_MS &&
    finishedAt < startedAt - 1000
  );
}

function shouldKeepPolling(now: number) {
  return Boolean(status?.running) || awaitingWorker(now);
}

export function stopListsUpdatePolling() {
  if (pollTimer) {
    clearTimeout(pollTimer);
    pollTimer = null;
  }
}

export async function refreshListsUpdateStatus(
  rerender: () => void,
  isMounted: () => boolean,
) {
  stopListsUpdatePolling();
  const response = await ProkopShellMethods.getListUpdateStatus();
  if (!isMounted()) {
    return;
  }
  status =
    response.success && typeof response.data === 'object'
      ? response.data
      : null;
  rerender();
  if (shouldKeepPolling(Date.now())) {
    pollTimer = setTimeout(
      () => void refreshListsUpdateStatus(rerender, isMounted),
      LIST_UPDATE_POLL_INTERVAL_MS,
    );
  }
}

async function startListsUpdate(
  rerender: () => void,
  isMounted: () => boolean,
) {
  if (starting || status?.running || awaitingWorker(Date.now())) {
    return;
  }
  starting = true;
  startError = '';
  rerender();
  const response = await ProkopShellMethods.listUpdateStart();
  starting = false;
  if (!response.success || !response.data?.success) {
    startError = _('Could not start the lists update');
    rerender();
    return;
  }
  startedAt = Date.now();
  await refreshListsUpdateStatus(rerender, isMounted);
}

export function renderListsUpdate(
  disabled: boolean,
  rerender: () => void,
  isMounted: () => boolean,
) {
  const busy = starting || awaitingWorker(Date.now());
  const summary = describeListUpdateStatus(status, busy);
  const children: Node[] = [
    E('div', { class: 'fkp_updates-page__component__header' }, [
      E(
        'b',
        { class: 'fkp_updates-page__component__title' },
        _('Domain and IP lists'),
      ),
    ]),
    E(
      'p',
      {
        class: `fkp-diag-text--${summary.tone}`,
        role: 'status',
      },
      asText(summary.text),
    ),
  ];
  if (summary.failedSources.length) {
    children.push(
      E('p', {}, _('Sources that could not be downloaded:')),
      E(
        'ul',
        {},
        summary.failedSources.map((source) => E('li', {}, asText(source))),
      ),
    );
  }
  if (startError) {
    children.push(
      E('p', { class: 'fkp-diag-text--error' }, asText(startError)),
    );
  }
  if (!isReadonlyMode()) {
    children.push(
      renderButton({
        text: _('Update lists'),
        disabled: disabled || busy || Boolean(status?.running),
        onClick: () => void startListsUpdate(rerender, isMounted),
      }),
    );
  }
  return E('div', { class: 'fkp_updates-page__component' }, children);
}
