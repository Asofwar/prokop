import { getComponentActionKey } from '../helpers/getComponentActionKey';
import { observeRouterTime } from '../helpers/routerClock';
import {
  componentActionFailureMessage,
  componentActionSuccessText,
} from '../tabs/updates/componentActionToast';
import { normalizeProgress } from '../tabs/updates/componentProgressState';
import { normalizeSingBoxVariantFields } from '../helpers/singBoxVariant';
import type { Prokop } from '../types';
import { getLocalActionOverlay } from './localActionOverlay.service';
import { store } from './store.service';
import type { StoreType } from './store.service';

type UiActionMap = Partial<Prokop.UiState['actions']>;

function isRunningAction(state: { running?: boolean }) {
  return state.running === true;
}

function getEmptyUpdatesActions(): StoreType['updatesActions'] {
  return {
    prokopCheck: { loading: false },
    prokopInstall: { loading: false },
    singBoxCheck: { loading: false },
    singBoxInstall: { loading: false },
    singBoxInstallExtended: { loading: false },
    singBoxInstallExtendedCompressed: { loading: false },
    singBoxInstallTiny: { loading: false },
    singBoxInstallStable: { loading: false },
    zapretCheck: { loading: false },
    zapretInstall: { loading: false },
    zapretRemove: { loading: false },
    zapret2Check: { loading: false },
    zapret2Install: { loading: false },
    zapret2Remove: { loading: false },
    byedpiCheck: { loading: false },
    byedpiInstall: { loading: false },
    byedpiRemove: { loading: false },
    zapretManagerInstall: { loading: false },
    zapretManagerRemove: { loading: false },
    packetSteeringEnable: { loading: false },
    packetSteeringRestore: { loading: false },
    directProxyEnable: { loading: false },
    directProxyDisable: { loading: false },
    torrserverCheck: { loading: false },
    torrserverInstall: { loading: false },
    torrserverRemove: { loading: false },
    torrserverStart: { loading: false },
    torrserverApplySettings: { loading: false },
    torrserverDirectEnable: { loading: false },
    torrserverDirectDisable: { loading: false },
  };
}

function getEmptyDiagnosticsActions(): StoreType['diagnosticsActions'] {
  return {
    ...store.get().diagnosticsActions,
    restart: { loading: false },
    start: { loading: false },
    stop: { loading: false },
  };
}

function normalizeLatencyProgress(
  progress?: Prokop.LatencyActionProgress,
): Prokop.LatencyActionProgress | undefined {
  const total = Math.trunc(Number(progress?.total ?? 0));

  if (!Number.isFinite(total) || total <= 0) {
    return undefined;
  }

  const completedValue = Number(progress?.completed ?? 0);
  const failedValue = Number(progress?.failed ?? 0);
  const completed = Number.isFinite(completedValue)
    ? Math.trunc(completedValue)
    : 0;
  const failed = Number.isFinite(failedValue) ? Math.trunc(failedValue) : 0;

  return {
    completed: Math.min(Math.max(0, completed), total),
    total,
    failed: Math.max(0, failed),
  };
}

function applyServiceState(uiState: Prokop.UiState) {
  const currentSystemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = {
    ...currentSystemInfo,
    providerInfoLoaded: true,
    zapret_installed: uiState.capabilities.zapret_installed,
    zapret2_installed: uiState.capabilities.zapret2_installed,
    byedpi_installed: uiState.capabilities.byedpi_installed,
  };

  nextSystemInfo.sing_box_extended = uiState.capabilities.sing_box_extended;
  nextSystemInfo.sing_box_tiny = uiState.capabilities.sing_box_tiny;
  nextSystemInfo.sing_box_compressed = uiState.capabilities.sing_box_compressed;
  nextSystemInfo.sing_box_tailscale = uiState.capabilities.sing_box_tailscale;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: false,
      data: {
        singbox: uiState.service.sing_box.running,
        prokopRunning: uiState.service.prokop.running,
        prokopEnabled: uiState.service.prokop.enabled,
        prokopStatus: uiState.service.prokop.status,
        prokopStoppedByUser: uiState.service.prokop.stopped_by_user ?? 0,
        prokopNotStarted: uiState.service.prokop.not_started ?? null,
        prokopRestartBlocked: uiState.service.prokop.restart_blocked ?? 0,
        prokopStopAvailable: uiState.service.prokop.stop_available ?? 0,
      },
    },
    diagnosticsSystemInfo: normalizeSingBoxVariantFields(nextSystemInfo),
  });
}

function applyActionState(actions: UiActionMap = {}) {
  const current = store.get();
  const localOverlay = getLocalActionOverlay();
  const currentLatencyProgressSections =
    current.sectionsWidget.latencyProgressSections;
  const subscriptionUpdatingSections: Record<string, boolean> = {};
  const latencyFetchingSections: Record<string, boolean> = {};
  const latencyProgressSections: Record<string, Prokop.LatencyActionProgress> =
    {};
  const updatesActions = getEmptyUpdatesActions();
  const diagnosticsActions = getEmptyDiagnosticsActions();

  for (const state of actions.subscription || []) {
    if (isRunningAction(state) && state.section) {
      subscriptionUpdatingSections[state.section] = true;
    }
  }

  for (const state of actions.latency || []) {
    if (isRunningAction(state) && state.section) {
      latencyFetchingSections[state.section] = true;
      const progress = normalizeLatencyProgress(state.progress);
      if (progress) {
        latencyProgressSections[state.section] = progress;
      } else if (currentLatencyProgressSections[state.section]) {
        latencyProgressSections[state.section] =
          currentLatencyProgressSections[state.section];
      }
    }
  }

  for (const state of actions.component || []) {
    if (!isRunningAction(state)) {
      continue;
    }

    const key = getComponentActionKey(state.component, state.action);
    if (key) {
      updatesActions[key] = { loading: true };
    }
  }

  for (const state of actions.service || []) {
    if (!isRunningAction(state)) {
      continue;
    }

    if (state.action === 'start') {
      diagnosticsActions.start = { loading: true };
    } else if (state.action === 'stop') {
      diagnosticsActions.stop = { loading: true };
    } else if (state.action === 'restart' || state.action === 'reload') {
      diagnosticsActions.restart = { loading: true };
    }
  }

  for (const section of localOverlay.subscriptionSections) {
    subscriptionUpdatingSections[section] = true;
  }

  for (const section of localOverlay.latencySections) {
    latencyFetchingSections[section] = true;
    if (
      !latencyProgressSections[section] &&
      currentLatencyProgressSections[section]
    ) {
      latencyProgressSections[section] =
        currentLatencyProgressSections[section];
    }
  }

  for (const key of localOverlay.componentActions) {
    updatesActions[key] = { loading: true };
  }

  for (const action of localOverlay.serviceActions) {
    diagnosticsActions[action] = { loading: true };
  }

  store.set({
    sectionsWidget: {
      ...current.sectionsWidget,
      subscriptionUpdatingSections,
      latencyFetchingSections,
      latencyProgressSections,
    },
    updatesActions,
    diagnosticsActions,
  });
}

// A running component action shows its progress on its card. A finished
// one keeps its view, which the job's completion fills in; a running view
// whose job the router no longer lists at all is gone. An answer read
// before the job ended may arrive after its completion: a finished view is
// never made running again by its own job, and a running view whose job the
// router lists as finished ends with the job's result (PRG-1).
function applyComponentProgress(states: Prokop.ComponentActionResult[] = []) {
  const current = store.get().updatesProgress;
  const next: StoreType['updatesProgress'] = {};
  const listed = new Set(states.map((state) => state.job_id).filter(Boolean));

  for (const [component, view] of Object.entries(current)) {
    if (view && (!view.running || listed.has(view.jobId))) {
      next[component as Prokop.ComponentName] = view;
    }
  }

  for (const state of states) {
    if (!state.job_id || state.action === 'check_update') {
      continue;
    }

    const known = next[state.component];
    const progress = normalizeProgress(state.progress);
    observeRouterTime(progress?.updated_at);

    if (!isRunningAction(state)) {
      if (known?.jobId === state.job_id && known.running) {
        const success = state.success !== false;
        next[state.component] = {
          ...known,
          running: false,
          finishedAt:
            (typeof state.updated_at === 'number' && state.updated_at) || 0,
          progress: progress ?? known.progress,
          success,
          message: success
            ? componentActionSuccessText(state)
            : componentActionFailureMessage(state, state),
          version: state.current_version || undefined,
        };
      }
      continue;
    }

    if (known?.jobId === state.job_id && !known.running) {
      continue;
    }

    next[state.component] = {
      component: state.component,
      action: state.action,
      jobId: state.job_id,
      running: true,
      startedAt: typeof state.started_at === 'number' ? state.started_at : 0,
      finishedAt: 0,
      progress,
    };
  }

  store.set({ updatesProgress: next });
}

export function applyUiStateToStore(uiState: Prokop.UiState) {
  observeRouterTime(uiState.now);
  applyServiceState(uiState);
  applyActionState(uiState.actions);
  applyComponentProgress(uiState.actions?.component);
}
