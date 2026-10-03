import { ProkopShellMethods } from '../methods';
import { Prokop } from '../types';
import { logger } from './logger.service';
import { store } from './store.service';
import { applyUiStateToStore } from './uiState.service';

const RUNTIME_UI_STATE_REFRESH_MIN_INTERVAL_MS = 500;
const RUNTIME_UI_STATE_IDLE_POLL_INTERVAL_MS = 1000;
const RUNTIME_UI_STATE_ACTIVE_POLL_INTERVAL_MS = 500;
// After this many failed refreshes in a row the last known service state is
// no longer shown as current (UC-122).
const RUNTIME_UI_STATE_MAX_FAILURES = 3;
type RuntimeUiStateListener = (uiState: Prokop.UiState) => void;

let runtimeUiStateRefreshPromise: Promise<Prokop.UiState | undefined> | null =
  null;
// A forced refresh asked for while another one is in flight runs once more
// after it, so it observes changes made after the in-flight request was sent
// (UC-121). Concurrent forced callers share this follow-up.
let runtimeUiStateFollowUpPromise: Promise<Prokop.UiState | undefined> | null =
  null;
let runtimeUiStateFailures = 0;
let lastRuntimeUiStateRefreshAt = 0;
let lastRuntimeUiState: Prokop.UiState | undefined;
let runtimeStateResumeRefreshRegistered = false;
let runtimeStatePollTimer: ReturnType<typeof setTimeout> | null = null;
let runtimeStatePollingStarted = false;
let runtimeStateHasRunningAction = false;
const runtimeUiStateListeners = new Set<RuntimeUiStateListener>();

function isDocumentVisible() {
  return (
    typeof document === 'undefined' ||
    !document.visibilityState ||
    document.visibilityState === 'visible'
  );
}

function hasRunningAction(uiState: Prokop.UiState) {
  return Object.values(uiState.actions).some((actions) =>
    actions.some((action) => action.running),
  );
}

function getNextPollDelay() {
  return runtimeStateHasRunningAction
    ? RUNTIME_UI_STATE_ACTIVE_POLL_INTERVAL_MS
    : RUNTIME_UI_STATE_IDLE_POLL_INTERVAL_MS;
}

function scheduleRuntimeUiStatePoll(delay = getNextPollDelay()) {
  if (
    !runtimeStatePollingStarted ||
    runtimeStatePollTimer ||
    typeof window === 'undefined'
  ) {
    return;
  }

  runtimeStatePollTimer = window.setTimeout(() => {
    runtimeStatePollTimer = null;
    void refreshRuntimeUiState()
      .catch(() => undefined)
      .finally(() => {
        scheduleRuntimeUiStatePoll();
      });
  }, delay);
}

function notifyRuntimeUiStateListeners(uiState: Prokop.UiState) {
  for (const listener of runtimeUiStateListeners) {
    try {
      listener(uiState);
    } catch (error) {
      logger.error('[RUNTIME_UI_STATE]', 'listener failed', error);
    }
  }
}

function markRuntimeUiStateFailure() {
  runtimeUiStateFailures += 1;

  if (runtimeUiStateFailures < RUNTIME_UI_STATE_MAX_FAILURES) {
    return;
  }

  const servicesInfoWidget = store.get().servicesInfoWidget;
  if (!servicesInfoWidget.failed && !servicesInfoWidget.loading) {
    store.set({ servicesInfoWidget: { ...servicesInfoWidget, failed: true } });
  }
}

function startRuntimeUiStateRefresh() {
  lastRuntimeUiStateRefreshAt = Date.now();

  const promise = ProkopShellMethods.getUiState()
    .then((response) => {
      if (!response.success) {
        markRuntimeUiStateFailure();
        return undefined;
      }

      runtimeUiStateFailures = 0;
      applyUiStateToStore(response.data);
      lastRuntimeUiState = response.data;
      runtimeStateHasRunningAction = hasRunningAction(response.data);
      notifyRuntimeUiStateListeners(response.data);
      return response.data;
    })
    .catch((error) => {
      logger.error('[RUNTIME_UI_STATE]', 'refresh failed', error);
      markRuntimeUiStateFailure();
      return undefined;
    })
    .finally(() => {
      if (runtimeUiStateRefreshPromise === promise) {
        runtimeUiStateRefreshPromise = null;
      }
    });

  runtimeUiStateRefreshPromise = promise;
  return promise;
}

export async function refreshRuntimeUiState({
  force = false,
}: { force?: boolean } = {}): Promise<Prokop.UiState | undefined> {
  if (!isDocumentVisible()) {
    return undefined;
  }

  if (runtimeUiStateRefreshPromise) {
    if (!force) {
      return runtimeUiStateRefreshPromise;
    }

    if (!runtimeUiStateFollowUpPromise) {
      const followUp = runtimeUiStateRefreshPromise
        .catch(() => undefined)
        .then(() => {
          runtimeUiStateFollowUpPromise = null;
          return runtimeUiStateRefreshPromise ?? startRuntimeUiStateRefresh();
        });
      runtimeUiStateFollowUpPromise = followUp;
    }

    return runtimeUiStateFollowUpPromise;
  }

  if (
    !force &&
    Date.now() - lastRuntimeUiStateRefreshAt <
      RUNTIME_UI_STATE_REFRESH_MIN_INTERVAL_MS
  ) {
    return undefined;
  }

  return startRuntimeUiStateRefresh();
}

export function subscribeRuntimeUiState(listener: RuntimeUiStateListener) {
  runtimeUiStateListeners.add(listener);

  if (lastRuntimeUiState) {
    try {
      listener(lastRuntimeUiState);
    } catch (error) {
      logger.error('[RUNTIME_UI_STATE]', 'listener failed', error);
    }
  }

  return () => {
    runtimeUiStateListeners.delete(listener);
  };
}

export function getCachedRuntimeUiState() {
  return lastRuntimeUiState;
}

export function registerRuntimeStateResumeRefresh() {
  if (runtimeStateResumeRefreshRegistered || typeof window === 'undefined') {
    return;
  }

  runtimeStateResumeRefreshRegistered = true;

  const refreshOnResume = () => {
    if (!isDocumentVisible()) {
      return;
    }

    void refreshRuntimeUiState({ force: true });
  };

  document.addEventListener('visibilitychange', refreshOnResume);
  window.addEventListener('pageshow', refreshOnResume);
  window.addEventListener('focus', refreshOnResume);
}

export function startRuntimeUiStatePolling() {
  if (runtimeStatePollingStarted || typeof window === 'undefined') {
    return;
  }

  runtimeStatePollingStarted = true;
  void refreshRuntimeUiState({ force: true }).finally(() => {
    scheduleRuntimeUiStatePoll();
  });
}
