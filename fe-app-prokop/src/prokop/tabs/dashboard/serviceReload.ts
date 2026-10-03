import { failureFromError, failureReason } from '../../helpers/actionReason';
import { Prokop } from '../../types';

// What a finished UI reload job did (service/ui.uc, UC-061): it ran, init.d
// only queued it behind another operation (a list or subscription update, a
// start), it skipped it because Prokop is stopped, or it failed. A reload
// refused because another service action runs is "busy"; one not confirmed
// in time is "unconfirmed", not failed (UC-116, UC-120).
export type ServiceReloadOutcome =
  | 'reloaded'
  | 'queued'
  | 'stopped'
  | 'failed'
  | 'busy'
  | 'unconfirmed';

export function serviceReloadOutcome(
  state: Prokop.ServiceActionState,
): ServiceReloadOutcome {
  if (state.outcome === 'queued') return 'queued';
  if (state.outcome === 'stopped') return 'stopped';
  if (state.success !== false) return 'reloaded';
  return state.reason === 'timeout' ? 'unconfirmed' : 'failed';
}

// A reload job that was refused, or not followed to its end.
export function serviceReloadRefusalOutcome(
  error: unknown,
): ServiceReloadOutcome {
  const reason = failureReason(failureFromError(error));
  if (reason === 'busy' || reason === 'startup_in_progress') return 'busy';
  if (reason === 'timeout') return 'unconfirmed';
  return 'failed';
}

// The URLTest settings are saved (or reset) before the reload: only the
// reload's outcome decides whether they are already in effect.
export function urlTestChangeToast(
  outcome: ServiceReloadOutcome,
  reset: boolean,
): { text: string; type: 'success' | 'warning' | 'error'; duration: number } {
  const done = reset
    ? _('URLTest settings reset')
    : _('URLTest settings saved');
  switch (outcome) {
    case 'queued':
      return {
        text: `${done}. ${_('Prokop is busy with another operation: the change applies when it finishes.')}`,
        type: 'warning',
        duration: 8000,
      };
    case 'stopped':
      return {
        text: `${done}. ${_('Prokop is stopped: the change applies when it is started.')}`,
        type: 'warning',
        duration: 8000,
      };
    case 'busy':
      return {
        text: `${done}. ${_('Prokop is busy with another service action, so the change is not applied yet; apply it again when that action finishes.')}`,
        type: 'warning',
        duration: 10000,
      };
    case 'unconfirmed':
      return {
        text: `${done}. ${_('Applying the change was not confirmed in time; check the service status.')}`,
        type: 'warning',
        duration: 10000,
      };
    case 'failed':
      return {
        text: `${done}. ${_('Prokop could not apply the change; see the Prokop log.')}`,
        type: 'error',
        duration: 10000,
      };
    default:
      return { text: done, type: 'success', duration: 3000 };
  }
}

export interface UrlTestChangeSteps {
  // Saves or resets the settings; throws when they were not saved.
  change: () => Promise<void>;
  // The reload job (shared/serviceControl runServiceActionJob).
  reload: () => Promise<Prokop.ServiceActionState>;
  refresh: () => Promise<void>;
}

// Saves the change, applies it with a reload and says what took effect. The
// editor stays open when the change is not in effect and applying it again
// can help: the reload failed or was refused (UC-116).
export async function runUrlTestChange(
  steps: UrlTestChangeSteps,
  reset: boolean,
) {
  await steps.change();

  let outcome: ServiceReloadOutcome;
  let finished = false;
  try {
    outcome = serviceReloadOutcome(await steps.reload());
    finished = true;
  } catch (error) {
    outcome = serviceReloadRefusalOutcome(error);
  }

  if (finished) {
    await steps.refresh().catch(() => undefined);
  }

  return {
    close: outcome !== 'failed' && outcome !== 'busy',
    toast: urlTestChangeToast(outcome, reset),
  };
}
