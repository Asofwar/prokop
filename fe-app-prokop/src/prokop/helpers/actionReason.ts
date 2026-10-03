import { READONLY_REFUSED } from '../services/readonlyCommandGuard';

// A refused or failed action as the shell methods hand it over: the stable
// reason of the backend (UC-119) and its English text.
export interface ActionFailure {
  reason?: string;
  error?: string;
  message?: string;
}

// A failure the page reports later: it keeps the reason next to the text.
export class ActionFailureError extends Error {
  readonly reason?: string;

  constructor(message: string, reason?: string) {
    super(message);
    this.name = 'ActionFailureError';
    this.reason = reason;
  }
}

// The refusals of a backend without reasons, by their English text.
const LEGACY_REFUSALS: Array<[string, string]> = [
  ['Another service action is already running', 'busy'],
  ['Another latency test is already running', 'busy'],
  ['Another component action is already running', 'busy'],
  ['Prokop startup is still in progress', 'startup_in_progress'],
];

// Not a failure of the action: it did not start because something else
// runs, or it was not confirmed in time and may still finish.
const WARNING_REASONS = ['busy', 'startup_in_progress', 'timeout', 'queued'];

export function actionReasonText(reason?: string | null): string | null {
  switch (reason) {
    case 'busy':
      return _(
        'Another action of this kind is already running. Try again when it finishes.',
      );
    case 'startup_in_progress':
      return _(
        'Prokop is still starting. Try again when the start finishes.',
      );
    case 'invalid_input':
      return _('The request was refused: invalid input.');
    case 'not_found':
      return _('The action was not found; it may have finished already.');
    case 'forbidden':
      return _('Not available in read-only mode.');
    case 'timeout':
      return _(
        'The action was not confirmed in time and may still be running; check the service status.',
      );
    case 'queued':
      return _(
        'Prokop is busy with another operation: the change applies when it finishes.',
      );
    case 'stale':
      return _(
        'The action stopped unexpectedly and its outcome is unknown; check the status before trying again.',
      );
    case 'latency_failed':
      return _('The latency test measured no delay: no tested proxy answered.');
    case 'clash_api_timeout':
      return _('The Clash API of sing-box did not answer in time.');
    case 'clash_api_unreachable':
      return _('The Clash API of sing-box is not reachable.');
    case 'clash_api_unavailable':
      return _('The Clash API of sing-box did not list its proxies.');
    case 'clash_api_auth_unavailable':
      return _('The Clash API credentials could not be prepared.');
    case 'clash_api_invalid_response':
    case 'clash_api_error':
      return _('The Clash API of sing-box answered with an error.');
    default:
      return null;
  }
}

export function actionReasonIsWarning(reason?: string | null) {
  return Boolean(reason && WARNING_REASONS.includes(reason));
}

// The reason of a failure: the backend's, the read-only guard's, or the one
// an older backend's English refusal stands for.
export function failureReason(failure: ActionFailure): string | undefined {
  if (failure.reason) {
    return failure.reason;
  }

  const texts = [failure.error, failure.message].filter(
    (text): text is string => typeof text === 'string' && text !== '',
  );

  if (texts.some((text) => text.includes(READONLY_REFUSED))) {
    return 'forbidden';
  }

  for (const [text, reason] of LEGACY_REFUSALS) {
    if (texts.some((item) => item.includes(text))) {
      return reason;
    }
  }

  return undefined;
}

export function failureFromError(error: unknown): ActionFailure {
  if (error instanceof ActionFailureError) {
    return { reason: error.reason, error: error.message };
  }

  return { error: error instanceof Error ? error.message : '' };
}

// The translated reason, else the backend's text, else the fallback.
export function failureText(failure: ActionFailure, fallback: string) {
  return (
    actionReasonText(failureReason(failure)) ||
    (failure.error || failure.message || '').trim() ||
    fallback
  );
}

export function failureToastType(failure: ActionFailure) {
  return actionReasonIsWarning(failureReason(failure)) ? 'warning' : 'error';
}
