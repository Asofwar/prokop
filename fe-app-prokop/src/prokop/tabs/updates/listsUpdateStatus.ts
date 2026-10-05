import { Prokop } from '../../types';

// Text of the lists update card (C6), apart from the card so it can be
// tested without the page services.
export type ListUpdateTone = 'neutral' | 'loading' | 'success' | 'error';

export interface ListUpdateSummary {
  text: string;
  tone: ListUpdateTone;
  failedSources: string[];
}

// Who the source is, after its kind (components/updates.uc
// safe_remote_source_identity): a host and path stay as they are.
function sourceIdentity(identity: string) {
  if (identity === 'configured remote source') {
    return _('configured source');
  }
  const ruleOnly = identity.match(/^rule '(.*)' remote source$/);
  if (ruleOnly) {
    return _('rule “%s”').replace('%s', ruleOnly[1]);
  }
  const rule = identity.match(/^rule '(.*)': (\S+)$/);
  if (rule) {
    return _('rule “%s”: %s').replace('%s', rule[1]).replace('%s', rule[2]);
  }
  return /^\S+$/.test(identity) ? identity : null;
}

const SOURCE_KINDS: Array<[RegExp, () => string]> = [
  [/^list source /, () => _('List source')],
  [/^remote domain\/IP list /, () => _('Domain and IP list')],
  [/^remote rule set /, () => _('Rule set')],
  [/^remote domain list /, () => _('Domain list')],
  [/^remote JSON subnet list /, () => _('Subnet list (JSON)')],
  [/^remote SRS subnet list /, () => _('Subnet list (SRS)')],
  [/^remote plain subnet list /, () => _('Subnet list (text)')],
];

// A source the router could not download, as it names it in English
// (components/updates.uc), in the UI's language (FE-15).
export function failedSourceText(source: string) {
  const builtIn = source.match(/^built-in (\S+) subnet list$/);
  if (builtIn) {
    return _('Built-in subnet list: %s').replace('%s', builtIn[1]);
  }
  for (const [pattern, kind] of SOURCE_KINDS) {
    const match = source.match(pattern);
    if (match) {
      const identity = sourceIdentity(source.slice(match[0].length));
      if (identity !== null) {
        return `${kind()}: ${identity}`;
      }
    }
  }
  return _('A list source; the details are in the system log');
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
    failedSources: (last.failed_sources || []).map(failedSourceText),
  };
}
