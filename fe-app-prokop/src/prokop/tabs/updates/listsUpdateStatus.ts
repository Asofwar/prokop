import { Prokop } from '../../types';

// Text of the lists update card (C6), apart from the card so it can be
// tested without the page services.
export type ListUpdateTone = 'neutral' | 'loading' | 'success' | 'error';

export interface ListUpdateSummary {
  text: string;
  tone: ListUpdateTone;
  failedSources: string[];
}

function formatTime(seconds: number) {
  return new Date(seconds * 1000).toLocaleString();
}

export function describeListUpdateStatus(
  status: Prokop.ListUpdateStatus | null,
  starting: boolean,
): ListUpdateSummary {
  if (starting || status?.running) {
    return { text: _('Updating lists…'), tone: 'loading', failedSources: [] };
  }
  if (!status) {
    return {
      text: _('Status unavailable'),
      tone: 'neutral',
      failedSources: [],
    };
  }
  const last = status.last_result;
  if (!last) {
    return {
      text: status.last_success_at
        ? _('Last successful update: %s').replace(
            '%s',
            formatTime(status.last_success_at),
          )
        : _('Lists have not been updated since the router started'),
      tone: 'neutral',
      failedSources: [],
    };
  }
  if (last.success) {
    return {
      text: _('Lists updated: %s').replace('%s', formatTime(last.finished_at)),
      tone: 'success',
      failedSources: [],
    };
  }
  const previous = status.last_success_at
    ? ' ' +
      _('The lists of the last successful update (%s) stay in use.').replace(
        '%s',
        formatTime(status.last_success_at),
      )
    : '';
  return {
    text:
      _('Lists update failed: %s.').replace(
        '%s',
        formatTime(last.finished_at),
      ) + previous,
    tone: 'error',
    failedSources: last.failed_sources,
  };
}
