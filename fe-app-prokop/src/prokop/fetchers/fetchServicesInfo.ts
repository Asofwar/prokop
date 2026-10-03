import { ProkopShellMethods } from '../methods';
import { logger } from '../services/logger.service';
import { store } from '../services/store.service';
import { refreshRuntimeUiState } from '../services/runtimeUiState.service';
import { Prokop } from '../types';

let latestServicesInfoRequestId = 0;

function getSettledMethodResponse<T>(
  scope: string,
  result: PromiseSettledResult<Prokop.MethodResponse<T>>,
): Prokop.MethodResponse<T> {
  if (result.status === 'fulfilled') {
    return result.value;
  }

  logger.error('[SERVICES_INFO]', `${scope} failed`, result.reason);

  return {
    success: false,
    error: result.reason instanceof Error ? result.reason.message : '',
  };
}

export async function fetchServicesInfo() {
  const requestId = ++latestServicesInfoRequestId;
  const uiState = await refreshRuntimeUiState({ force: true });

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  if (uiState) {
    return uiState;
  }

  const [prokopResult, singboxResult] = await Promise.allSettled([
    ProkopShellMethods.getStatus(),
    ProkopShellMethods.getSingBoxStatus(),
  ]);

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  const prokop = getSettledMethodResponse('getStatus', prokopResult);
  const singbox = getSettledMethodResponse('getSingBoxStatus', singboxResult);
  const previousData = store.get().servicesInfoWidget.data;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: !prokop.success || !singbox.success,
      data: {
        singbox: singbox.success ? singbox.data.running : previousData.singbox,
        prokopRunning: prokop.success
          ? prokop.data.running
          : previousData.prokopRunning,
        prokopEnabled: prokop.success
          ? prokop.data.enabled
          : previousData.prokopEnabled,
        prokopStatus: prokop.success
          ? prokop.data.status
          : previousData.prokopStatus,
        prokopStoppedByUser: prokop.success
          ? (prokop.data.stopped_by_user ?? 0)
          : previousData.prokopStoppedByUser,
        prokopNotStarted: prokop.success
          ? (prokop.data.not_started ?? null)
          : previousData.prokopNotStarted,
        prokopRestartBlocked: prokop.success
          ? (prokop.data.restart_blocked ?? 0)
          : previousData.prokopRestartBlocked,
        prokopStopAvailable: prokop.success
          ? (prokop.data.stop_available ?? 0)
          : previousData.prokopStopAvailable,
      },
    },
  });

  return undefined;
}
