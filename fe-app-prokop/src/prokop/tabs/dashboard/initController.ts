import { asText } from '../../../helpers/asText';
import { isPageHidden } from '../../../helpers/isPageHidden';
import {
  canUseDirectClashApi,
  getClashWsStreamUrl,
  onMount,
  preserveScrollForPage,
} from '../../../helpers';
import { showToast } from '../../../helpers/showToast';
import { CustomProkopMethods, ProkopShellMethods } from '../../methods';
import {
  logger,
  markUiActionOwned,
  setLocalLatencyAction,
  setLocalSubscriptionAction,
  shouldNotifyOwnedUiAction,
  socket,
  store,
  StoreType,
} from '../../services';
import {
  getLatencyTestLabel,
  renderFlagEmojis,
  renderSections,
} from './partials';
import { fetchServicesInfo } from '../../fetchers/fetchServicesInfo';
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
import { getClashControllerHosts } from '../../methods/custom/getClashControllerHosts';
import { Prokop } from '../../types';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../../services/runtimeUiState.service';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';
import { shouldShowLoadingForRestoredAction } from '../../helpers/restoredActionLoading';
import { getServiceAvailability } from '../../helpers/serviceAvailability';
import { createPriorityMembersState } from './priorityMembersState';
import {
  renderSectionsStaleNotice,
  sectionsAfterFailedRefresh,
  sectionsAfterRefresh,
} from './sectionsRefresh';
import {
  overviewLastEvent,
  overviewAutotune,
  overviewRecovery,
  overviewRouting,
  overviewState,
  overviewWarning,
  type OverviewInput,
} from './overview';
import { renderOverview } from './overviewCards';
import { runOverviewServiceAction } from './serviceActionFlow';
import { runUrlTestChange } from './serviceReload';
import { renderUrlTestEditorRow } from './urlTestEditorRow';
import { replaceChildrenKeepingFocus } from '../../../helpers/replaceChildrenKeepingFocus';
import { latencyJobFailure } from './latencyJob';
import {
  subscriptionUpdateErrorMessage,
  subscriptionUpdateFailureNotice,
} from './subscriptionJob';
import {
  ActionFailureError,
  failureFromError,
  failureReason,
  failureText,
  failureToastType,
} from '../../helpers/actionReason';
import { readLastRun } from '../diagnostic/partials/renderRunAction';
import { serviceActionNotice } from '../../helpers/serviceActionNotice';
import {
  confirmStopProkop,
  runProkopServiceAction,
  runServiceActionJob,
  setProkopAutostart,
  type ProkopServiceAction,
} from '../shared/serviceControl';
import { renderStartServiceAction } from '../shared/startService';
import {
  ConnectionsSample,
  sampleFromConnections,
  trafficSpeed,
} from './clashTraffic';
import { isReadonlyMode } from '../../services/accessMode.service';
import { isSectionEnabled } from '../../helpers/sectionEnabled';

const SECTIONS_REFRESH_INTERVAL_MS = 10000;
const CLASH_RPC_POLL_INTERVAL_MS = 2000;
const LATENCY_TEST_BUTTON_CLASS = 'dashboard-sections-grid-item-test-latency';
const LATENCY_TEST_BUTTON_LABEL_CLASS =
  'dashboard-sections-grid-item-test-latency__label';
let sectionsRefreshTimer: ReturnType<typeof setInterval> | null = null;
let healthRefreshTimer: ReturnType<typeof setInterval> | null = null;

let overviewHealth: Prokop.HealthStatus | null = null;
let overviewHealthStale = false;
let overviewRuleCount: number | null = null;
let overviewSnapshotCount: number | null = null;
let overviewAutotuneStatus: Prokop.AutotuneStatus | null = null;
let overviewAutotuneFailed = false;
let overviewServiceBusy = false;
// The controller runs on two pages: Overview (summary cards, live traffic)
// and Monitoring → Nodes (node selection only). Summary data, the health
// poll and the Clash traffic stream are loaded only where they are shown.
let overviewHost = false;
let clashUpdatesStarted = false;

async function refreshHealth(mountId: number) {
  const response = await ProkopShellMethods.getHealthStatus();
  if (!dashboardMounted || mountId !== dashboardMountId) return;
  // A failed poll keeps the last known health, so a DPI guard it showed
  // stays visible, and marks it stale: it proves nothing healthy (UC-021).
  if (response.success && response.data) {
    overviewHealth = response.data;
    overviewHealthStale = false;
  } else {
    overviewHealthStale = true;
  }
  renderOverviewCards();
}

// The autotune card: the same status call as the Autotune page, which a
// read-only session may make too. It changes on the scale of checks, so it
// is read with the health poll at a slower pace.
const AUTOTUNE_REFRESH_INTERVAL_MS = 30000;
let autotuneLoadedAt = 0;

async function refreshAutotune(mountId: number) {
  autotuneLoadedAt = Date.now();
  let next: Prokop.AutotuneStatus | null = null;
  try {
    const response = await ProkopShellMethods.autotuneStatus();
    const data = response.success ? response.data : null;
    next = data && data.status === 'ok' && data.policy ? data : null;
  } catch (error) {
    logger.error('[DASHBOARD]', 'autotune status failed', error);
  }
  if (!dashboardMounted || mountId !== dashboardMountId) return;
  // A failed poll keeps the last known state, like the health card.
  if (next) overviewAutotuneStatus = next;
  overviewAutotuneFailed = !next && !overviewAutotuneStatus;
  renderOverviewCards();
}

// Rule and snapshot counts change rarely; read them once per visit.
async function loadOverviewCounts(mountId: number) {
  const [sections, snapshots] = await Promise.allSettled([
    CustomProkopMethods.getConfigSections(),
    ProkopShellMethods.snapshotList(),
  ]);
  if (!dashboardMounted || mountId !== dashboardMountId) return;

  overviewRuleCount =
    sections.status === 'fulfilled'
      ? sections.value.filter(
          (section) =>
            section['.type'] === 'section' && isSectionEnabled(section.enabled),
        ).length
      : null;
  overviewSnapshotCount =
    snapshots.status === 'fulfilled' &&
    snapshots.value.success &&
    Array.isArray(snapshots.value.data)
      ? snapshots.value.data.length
      : null;
  renderOverviewCards();
}

function overviewInput(): OverviewInput {
  const state = store.get();
  const services = state.servicesInfoWidget;
  const bandwidth = state.bandwidthWidget;
  const systemInfo = state.systemInfoWidget;

  return {
    health: overviewHealth,
    healthStale: overviewHealthStale,
    availability: getDashboardServiceAvailability(),
    prokopEnabled: Boolean(services.data.prokopEnabled),
    prokopStoppedByUser: Boolean(services.data.prokopStoppedByUser),
    prokopNotStarted:
      services.data.prokopNotStarted === null
        ? null
        : Boolean(services.data.prokopNotStarted),
    prokopStatus: services.data.prokopStatus || '',
    singBoxRunning: Boolean(services.data.singbox),
    groups: state.sectionsWidget.data,
    ruleCount: overviewRuleCount,
    traffic:
      !bandwidth.loading && !bandwidth.failed
        ? { up: bandwidth.data.up, down: bandwidth.data.down }
        : null,
    connections:
      !systemInfo.loading && !systemInfo.failed
        ? systemInfo.data.connections
        : null,
    snapshotCount: overviewSnapshotCount,
    lastDiagnosticRun: readLastRun(localStorage),
    nowMs: Date.now(),
    autotune: overviewAutotuneStatus,
    autotuneFailed: overviewAutotuneFailed,
  };
}

async function handleServiceAction(action: ProkopServiceAction) {
  if (overviewServiceBusy) return;
  if (action === 'stop' && !(await confirmStopProkop())) return;

  const mountId = dashboardMountId;
  await runOverviewServiceAction({
    run: () => runProkopServiceAction(action),
    onError: (error) => {
      const notice = serviceActionNotice(error);
      showToast(notice.text, notice.type, 6000);
    },
    refreshRuntime: () => refreshRuntimeUiState({ force: true }),
    refreshHealth: () => refreshHealth(mountId),
    setBusy: (busy) => {
      overviewServiceBusy = busy;
      renderOverviewCards();
    },
  });
}

async function handleToggleAutostart() {
  if (overviewServiceBusy) return;
  const wanted = !store.get().servicesInfoWidget.data.prokopEnabled;

  overviewServiceBusy = true;
  renderOverviewCards();
  try {
    if ((await setProkopAutostart(wanted)) !== wanted) {
      showToast(_('Could not change autostart'), 'error', 6000);
    }
  } catch (_error) {
    showToast(_('Could not change autostart'), 'error', 6000);
  } finally {
    overviewServiceBusy = false;
    renderOverviewCards();
  }
}

function renderOverviewCards() {
  const container = document.getElementById('dashboard-overview');
  if (!container || !dashboardMounted) return;

  const input = overviewInput();
  const view = renderOverview(
    {
      warning: overviewWarning(input.health),
      state: overviewState(input),
      routing: overviewRouting(input),
      autotune: overviewAutotune(input),
      recovery: overviewRecovery(input),
      event: overviewLastEvent(input),
    },
    {
      readonly: isReadonlyMode(),
      serviceBusy: overviewServiceBusy,
      autostart: input.prokopEnabled,
      restartBlocked: Boolean(
        store.get().servicesInfoWidget.data.prokopRestartBlocked,
      ),
      stopAvailable: Boolean(
        store.get().servicesInfoWidget.data.prokopStopAvailable,
      ),
      onStart: () => void handleServiceAction('start'),
      onRestart: () => void handleServiceAction('restart'),
      onStop: () => void handleServiceAction('stop'),
      onToggleAutostart: () => void handleToggleAutostart(),
    },
  );

  // Keep an open service menu open across data refreshes.
  if (container.querySelector('.fkp-menu[open]')) return;
  preserveScrollForPage(() => replaceChildrenKeepingFocus(container, view));
}
let sectionsRefreshPromise: Promise<boolean> | null = null;
let sectionsStoppedRendered = false;
let sectionsRefreshQueued = false;
let actionStateUnsubscribe: (() => void) | null = null;
let dashboardMounted = false;
let dashboardMountId = 0;
let dashboardDataUpdatesStarted = false;
let dashboardDataUpdatesId = 0;
let pageUnloading = false;
let clashRpcPollTimer: ReturnType<typeof setInterval> | null = null;
let clashRpcPolling = false;
let lastConnectionsSample: ConnectionsSample | null = null;
const followedSubscriptionJobs = new Set<string>();
const followedLatencyJobs = new Set<string>();
const handledSubscriptionJobs = new Set<string>();
const handledLatencyJobs = new Set<string>();
// Cards are replaced on each refresh; keep disclosure state outside their DOM.
const priorityMembersState = createPriorityMembersState();

if (typeof window !== 'undefined') {
  window.addEventListener('pagehide', () => {
    pageUnloading = true;
  });
  window.addEventListener('pageshow', () => {
    pageUnloading = false;
  });
}

// Fetchers

async function fetchDashboardSectionsOnce(mountId: number) {
  if (getDashboardServiceAvailability() === 'stopped') {
    return false;
  }

  const prev = store.get().sectionsWidget;
  const hasRenderedData = prev.data.length > 0;

  store.set({
    sectionsWidget: {
      ...prev,
      failed: false,
      loading: prev.loading && !hasRenderedData,
    },
  });

  try {
    const { data, success } = await CustomProkopMethods.getDashboardSections();

    if (
      !dashboardMounted ||
      mountId !== dashboardMountId ||
      getDashboardServiceAvailability() === 'stopped'
    ) {
      return false;
    }

    if (!success) {
      throw new Error('failed to fetch dashboard sections');
    }

    store.set({
      sectionsWidget: sectionsAfterRefresh(store.get().sectionsWidget, data),
    });

    return true;
  } catch (error) {
    logger.error('[DASHBOARD]', 'fetchDashboardSections: failed', error);

    if (
      !dashboardMounted ||
      mountId !== dashboardMountId ||
      getDashboardServiceAvailability() === 'stopped'
    ) {
      return false;
    }

    store.set({
      sectionsWidget: sectionsAfterFailedRefresh(store.get().sectionsWidget),
    });

    return false;
  }
}

async function fetchDashboardSections(options: { force?: boolean } = {}) {
  if (sectionsRefreshPromise) {
    if (options.force) {
      sectionsRefreshQueued = true;
    }

    return sectionsRefreshPromise;
  }

  const mountId = dashboardMountId;
  const promise = (async () => {
    let success = false;

    do {
      sectionsRefreshQueued = false;
      success = await fetchDashboardSectionsOnce(mountId);
    } while (
      sectionsRefreshQueued &&
      dashboardMounted &&
      mountId === dashboardMountId
    );

    return success;
  })();

  sectionsRefreshPromise = promise;

  try {
    return await promise;
  } finally {
    if (sectionsRefreshPromise === promise) {
      sectionsRefreshPromise = null;
    }
  }
}

function setSubscriptionUpdating(
  sectionName: string,
  updating: boolean,
  local = false,
) {
  if (local || !updating) {
    setLocalSubscriptionAction(sectionName, updating && local);
  }

  const sectionsWidget = store.get().sectionsWidget;
  const subscriptionUpdatingSections = {
    ...sectionsWidget.subscriptionUpdatingSections,
  };

  if (updating) {
    subscriptionUpdatingSections[sectionName] = true;
  } else {
    delete subscriptionUpdatingSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      subscriptionUpdatingSections,
    },
  });
}

function setSelectorSwitching(sectionName: string, tag?: string) {
  const sectionsWidget = store.get().sectionsWidget;
  const selectorSwitchingSections = {
    ...sectionsWidget.selectorSwitchingSections,
  };

  if (tag) {
    selectorSwitchingSections[sectionName] = tag;
  } else {
    delete selectorSwitchingSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      selectorSwitchingSections,
    },
  });
}

function setLatencyFetching(
  sectionName: string,
  fetching: boolean,
  local = false,
  progress?: Prokop.LatencyActionProgress,
) {
  if (local || !fetching) {
    setLocalLatencyAction(sectionName, fetching && local);
  }

  const sectionsWidget = store.get().sectionsWidget;
  const latencyFetchingSections = {
    ...sectionsWidget.latencyFetchingSections,
  };
  const latencyProgressSections = {
    ...sectionsWidget.latencyProgressSections,
  };

  if (fetching) {
    latencyFetchingSections[sectionName] = true;
    if (progress) {
      latencyProgressSections[sectionName] = progress;
    }
  } else {
    delete latencyFetchingSections[sectionName];
    delete latencyProgressSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      latencyFetchingSections,
      latencyProgressSections,
    },
  });
}

async function completeSubscriptionUpdateJob(
  jobId: string,
  sectionName: string,
  response: Prokop.MethodResponse<Prokop.SubscriptionUpdateJobState>,
) {
  if (pageUnloading) {
    setSubscriptionUpdating(sectionName, false);
    return;
  }

  if (jobId && handledSubscriptionJobs.has(jobId)) {
    setSubscriptionUpdating(sectionName, false);
    return;
  }

  const shouldNotify = jobId
    ? shouldNotifyOwnedUiAction('subscription', jobId)
    : false;
  const failed = !response.success || response.data.success === false;
  const message = response.success
    ? response.data.message || _('Failed to update subscriptions')
    : response.error || _('Failed to update subscriptions');

  if (failed && isTransientRpcError(message)) {
    void refreshRuntimeUiState({ force: true });
    return;
  }

  if (jobId) {
    handledSubscriptionJobs.add(jobId);
  }

  setSubscriptionUpdating(sectionName, false);

  if (jobId && response.success) {
    void ProkopShellMethods.uiActionAck('subscription', jobId);
  }

  if (failed) {
    if (shouldNotify) {
      const notice = subscriptionUpdateFailureNotice(response);
      showToast(notice.text, notice.type);
    }
    return;
  }

  if (shouldNotify) {
    showToast(_('Subscriptions updated'), 'success');
  }
  void fetchDashboardSections({ force: true });
  void fetchServicesInfo();
}

async function followSubscriptionUpdateState(
  state: Prokop.SubscriptionUpdateJobState,
) {
  const jobId = state.job_id;
  const sectionName = state.section || '';

  if (!jobId || !sectionName || followedSubscriptionJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledSubscriptionJobs.has(jobId)) {
    return;
  }

  followedSubscriptionJobs.add(jobId);
  if (shouldShowLoadingForRestoredAction(state)) {
    setSubscriptionUpdating(sectionName, true);
  }

  try {
    const response = state.running
      ? await ProkopShellMethods.waitSubscriptionUpdateJob(jobId)
      : ({
          success: true,
          data: state,
        } as Prokop.MethodSuccessResponse<Prokop.SubscriptionUpdateJobState>);

    await completeSubscriptionUpdateJob(jobId, sectionName, response);
  } catch (error) {
    logger.error('[DASHBOARD]', 'followSubscriptionUpdateState failed', error);
    if (!pageUnloading) {
      const message =
        error instanceof Error
          ? error.message
          : _('Failed to update subscriptions');

      setSubscriptionUpdating(sectionName, false);
      if (!isTransientRpcError(message)) {
        showToast(subscriptionUpdateErrorMessage(message), 'error');
      }
    }
  } finally {
    followedSubscriptionJobs.delete(jobId);
  }
}

async function completeLatencyTestJob(jobId: string, sectionName: string) {
  setLatencyFetching(sectionName, false);

  if (pageUnloading) {
    return;
  }

  if (jobId && handledLatencyJobs.has(jobId)) {
    return;
  }

  if (jobId) {
    handledLatencyJobs.add(jobId);
  }

  if (jobId) {
    void ProkopShellMethods.uiActionAck('latency', jobId);
  }

  void fetchDashboardSections({ force: true });
}

async function followLatencyTestState(state: Prokop.LatencyActionState) {
  const jobId = state.job_id;
  const sectionName = state.section || '';

  if (!jobId || !sectionName || followedLatencyJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledLatencyJobs.has(jobId)) {
    return;
  }

  followedLatencyJobs.add(jobId);
  if (shouldShowLoadingForRestoredAction(state)) {
    setLatencyFetching(sectionName, true);
  }

  try {
    if (state.running) {
      await ProkopShellMethods.waitLatencyTestJob(jobId);
    }

    await completeLatencyTestJob(jobId, sectionName);
  } catch (error) {
    logger.error('[DASHBOARD]', 'followLatencyTestState failed', error);
    if (!pageUnloading) {
      setLatencyFetching(sectionName, false);
    }
  } finally {
    followedLatencyJobs.delete(jobId);
  }
}

function followDashboardActionsFromUiState(uiState: Prokop.UiState) {
  for (const state of uiState.actions.subscription || []) {
    if (state.running || (state.job_id && state.section)) {
      void followSubscriptionUpdateState(state);
    } else if (state.job_id && !handledSubscriptionJobs.has(state.job_id)) {
      handledSubscriptionJobs.add(state.job_id);
      void ProkopShellMethods.uiActionAck('subscription', state.job_id);
    }
  }

  for (const state of uiState.actions.latency || []) {
    if (state.running || (state.job_id && state.section)) {
      void followLatencyTestState(state);
    } else if (state.job_id && !handledLatencyJobs.has(state.job_id)) {
      handledLatencyJobs.add(state.job_id);
      void ProkopShellMethods.uiActionAck('latency', state.job_id);
    }
  }
}

function startActionStateWatcher() {
  if (actionStateUnsubscribe) {
    return;
  }

  actionStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (dashboardMounted) {
      followDashboardActionsFromUiState(uiState);
    }
  });
}

function stopActionStateWatcher() {
  if (!actionStateUnsubscribe) {
    return;
  }

  actionStateUnsubscribe();
  actionStateUnsubscribe = null;
}

async function connectToClashSockets(dataUpdatesId: number) {
  const mountId = dashboardMountId;
  const [clashApiSecret, clashControllerHosts] = await Promise.all([
    getClashApiSecret(),
    getClashControllerHosts(),
  ]);

  if (
    !dashboardMounted ||
    mountId !== dashboardMountId ||
    dataUpdatesId !== dashboardDataUpdatesId ||
    getDashboardServiceAvailability() === 'stopped'
  ) {
    return;
  }

  if (!canUseDirectClashApi(clashApiSecret, clashControllerHosts)) {
    startClashRpcPolling(dataUpdatesId);
    return;
  }

  socket.subscribe(
    getClashWsStreamUrl('/traffic', clashApiSecret),
    (msg) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

      const parsedMsg = JSON.parse(msg);

      store.set({
        bandwidthWidget: {
          loading: false,
          failed: false,
          data: { up: parsedMsg.up, down: parsedMsg.down },
        },
      });
    },
    (_err) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

      logger.warn(
        '[DASHBOARD]',
        'connectToClashSockets - traffic: socket unavailable, polling instead',
      );
      fallBackToClashRpcPolling(dataUpdatesId);
    },
  );

  socket.subscribe(
    getClashWsStreamUrl('/connections', clashApiSecret),
    (msg) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

      const parsedMsg = JSON.parse(msg);

      store.set({
        systemInfoWidget: {
          loading: false,
          failed: false,
          data: {
            connections: parsedMsg.connections?.length,
            memory: parsedMsg.memory,
          },
        },
      });
    },
    (_err) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

      logger.warn(
        '[DASHBOARD]',
        'connectToClashSockets - connections: socket unavailable, polling instead',
      );
      fallBackToClashRpcPolling(dataUpdatesId);
    },
  );
}

function setClashWidgetsFailed() {
  store.set({
    bandwidthWidget: { loading: false, failed: true, data: { up: 0, down: 0 } },
    systemInfoWidget: {
      loading: false,
      failed: true,
      data: { connections: 0, memory: 0 },
    },
  });
}

async function pollClashConnections(dataUpdatesId: number) {
  if (
    clashRpcPolling ||
    dataUpdatesId !== dashboardDataUpdatesId ||
    getDashboardServiceAvailability() === 'stopped'
  ) {
    return;
  }

  clashRpcPolling = true;

  try {
    const response = await ProkopShellMethods.getClashApiConnections();
    if (dataUpdatesId !== dashboardDataUpdatesId) {
      return;
    }

    const sample = response.success
      ? sampleFromConnections(response.data, Date.now())
      : null;
    if (!sample) {
      lastConnectionsSample = null;
      setClashWidgetsFailed();
      return;
    }

    const speed = trafficSpeed(lastConnectionsSample, sample);
    lastConnectionsSample = sample;
    store.set({
      ...(speed
        ? { bandwidthWidget: { loading: false, failed: false, data: speed } }
        : {}),
      systemInfoWidget: {
        loading: false,
        failed: false,
        data: { connections: sample.connections, memory: sample.memory },
      },
    });
  } catch (error) {
    logger.error('[DASHBOARD]', 'pollClashConnections: failed', error);
    lastConnectionsSample = null;
    setClashWidgetsFailed();
  } finally {
    clashRpcPolling = false;
  }
}

// HTTPS pages cannot open the ws:// controller socket, and a socket can
// drop; the widgets then keep working through rpcd.
function startClashRpcPolling(dataUpdatesId: number) {
  if (clashRpcPollTimer) {
    return;
  }

  lastConnectionsSample = null;
  void pollClashConnections(dataUpdatesId);
  clashRpcPollTimer = setInterval(() => {
    if (isPageHidden()) return;
    void pollClashConnections(dataUpdatesId);
  }, CLASH_RPC_POLL_INTERVAL_MS);
}

function stopClashRpcPolling() {
  if (clashRpcPollTimer) {
    clearInterval(clashRpcPollTimer);
    clashRpcPollTimer = null;
  }
  lastConnectionsSample = null;
}

function fallBackToClashRpcPolling(dataUpdatesId: number) {
  if (dataUpdatesId !== dashboardDataUpdatesId) {
    return;
  }

  socket.resetAll();
  startClashRpcPolling(dataUpdatesId);
}

function getDashboardServiceAvailability() {
  const service = store.get().servicesInfoWidget;

  return getServiceAvailability({
    loading: service.loading,
    failed: service.failed,
    running: service.data.prokopRunning,
  });
}

function stopDashboardDataUpdates() {
  dashboardDataUpdatesStarted = false;
  dashboardDataUpdatesId += 1;

  if (sectionsRefreshTimer) {
    clearInterval(sectionsRefreshTimer);
    sectionsRefreshTimer = null;
  }

  sectionsRefreshQueued = false;
  stopClashRpcPolling();
  // Never close sockets this controller did not open (Monitoring owns its
  // connections stream when it hosts the Nodes view).
  if (clashUpdatesStarted) socket.resetAll();
  clashUpdatesStarted = false;
}

function startDashboardDataUpdates() {
  if (
    dashboardDataUpdatesStarted ||
    !dashboardMounted ||
    getDashboardServiceAvailability() === 'stopped'
  ) {
    return;
  }

  dashboardDataUpdatesStarted = true;
  const dataUpdatesId = ++dashboardDataUpdatesId;
  void fetchDashboardSections({ force: true });
  if (overviewHost) {
    clashUpdatesStarted = true;
    // Direct sockets need the secret; without it (read-only, HTTPS) the
    // widgets poll through rpcd.
    void connectToClashSockets(dataUpdatesId);
  }
  sectionsRefreshTimer = setInterval(() => {
    if (isPageHidden()) return;
    void fetchDashboardSections();
  }, SECTIONS_REFRESH_INTERVAL_MS);
}

function syncDashboardServiceAvailability() {
  const availability = getDashboardServiceAvailability();
  const stopped = availability === 'stopped';

  // The nodes grid shows its own stopped state; re-render it only when that
  // flips so service polls do not replace the cards.
  if (stopped !== sectionsStoppedRendered) {
    void renderSectionsWidget();
  }

  if (stopped || availability === 'loading') {
    stopDashboardDataUpdates();
    return;
  }

  startDashboardDataUpdates();
}

// Handlers

async function handleChooseOutbound(
  sectionName: string,
  selector: string,
  tag: string,
) {
  const sectionsWidget = store.get().sectionsWidget;
  const section = sectionsWidget.data.find(
    (item) => item.sectionName === sectionName,
  );

  if (
    !section?.withTagSelect ||
    sectionsWidget.selectorSwitchingSections[sectionName] ||
    section.outbounds.some(
      (outbound) => outbound.code === tag && outbound.selected,
    )
  ) {
    return;
  }

  setSelectorSwitching(sectionName, tag);

  try {
    const response = await ProkopShellMethods.setClashApiGroupProxy(
      selector,
      tag,
    );
    if (!response.success) {
      showToast(_('Failed to switch the node'), 'error');
    }
    await fetchDashboardSections({ force: true });
  } catch (error) {
    logger.error('[DASHBOARD]', 'handleChooseOutbound: failed', error);
    showToast(_('Failed to switch the node'), 'error');
  } finally {
    setSelectorSwitching(sectionName);
  }
}

function getInitialLatencyProgress(
  latencyType: Prokop.LatencyActionState['latency_type'],
  tag: string,
): Prokop.LatencyActionProgress | undefined {
  if (latencyType !== 'proxy_list') {
    return undefined;
  }

  try {
    const tags = JSON.parse(tag);
    if (!Array.isArray(tags)) {
      return undefined;
    }

    const total = tags.filter(
      (item) => typeof item === 'string' && item.length > 0,
    ).length;

    return total > 0 ? { completed: 0, total, failed: 0 } : undefined;
  } catch {
    return undefined;
  }
}

async function handleTestLatency(
  latencyType: Prokop.LatencyActionState['latency_type'],
  sectionName: string,
  tag: string,
  timeout?: string,
) {
  if (store.get().sectionsWidget.latencyFetchingSections[sectionName]) {
    return;
  }

  setLatencyFetching(
    sectionName,
    true,
    true,
    getInitialLatencyProgress(latencyType, tag),
  );
  let jobId = '';
  let ownsJobFollow = false;
  let completed = false;

  try {
    const startResponse = await ProkopShellMethods.latencyTestStart(
      latencyType,
      sectionName,
      tag,
      timeout,
    );

    if (!startResponse.success) {
      throw new ActionFailureError(
        startResponse.error,
        failureReason(startResponse),
      );
    }

    jobId = startResponse.data.job_id;
    if (followedLatencyJobs.has(jobId)) {
      completed = true;
      return;
    }

    followedLatencyJobs.add(jobId);
    ownsJobFollow = true;
    const completion = await ProkopShellMethods.waitLatencyTestJob(jobId);
    if (!completion.success) {
      throw new ActionFailureError(completion.error, failureReason(completion));
    }
    if (!completion.data.success) {
      throw latencyJobFailure(completion.data);
    }
    await completeLatencyTestJob(jobId, sectionName);
    completed = true;
  } catch (error) {
    logger.error('[DASHBOARD]', 'handleTestLatency: failed', error);
    if (!pageUnloading) {
      // Another test running is a warning; why a test failed is translated
      // (UC-119).
      const failure = failureFromError(error);
      showToast(
        failureText(failure, _('Latency test failed')),
        failureToastType(failure),
      );
    }
  } finally {
    if (ownsJobFollow) {
      followedLatencyJobs.delete(jobId);
    }

    if (!completed) {
      setLatencyFetching(sectionName, false);
    }
  }
}

function formatUrlTestModalValue(value: unknown) {
  if (typeof value === 'boolean') {
    return value ? _('Yes') : _('No');
  }

  const text = `${value ?? ''}`.trim();
  return text || _('No');
}

function getUrlTestLatencyClass(latency: number) {
  if (!latency) {
    return 'fkp_dashboard-page__outbound-grid__item__latency--empty';
  }

  if (latency < 800) {
    return 'fkp_dashboard-page__outbound-grid__item__latency--green';
  }

  if (latency < 1500) {
    return 'fkp_dashboard-page__outbound-grid__item__latency--yellow';
  }

  return 'fkp_dashboard-page__outbound-grid__item__latency--red';
}

function formatUrlTestLatency(latency: number) {
  return latency ? _('%d ms').replace('%d', String(latency)) : '—';
}

function renderDetailsUrl(value: unknown) {
  const url = `${value ?? ''}`.trim();

  if (!/^https?:\/\//i.test(url)) {
    return E('span', {}, asText(formatUrlTestModalValue(value)));
  }

  return E(
    'a',
    {
      class: 'fkp_dashboard-page__urltest-details__url',
      href: url,
      target: '_blank',
      rel: 'noopener noreferrer',
    },
    asText(url),
  );
}

function getDetectedCountryFlag(country?: string) {
  const code = `${country || ''}`.trim().toUpperCase();

  if (!/^[A-Z]{2}$/.test(code)) {
    return '';
  }

  return String.fromCodePoint(
    ...code.split('').map((char) => 0x1f1e6 + char.charCodeAt(0) - 65),
  );
}

function renderDetailsMemberName(member: Prokop.UrlTestMember) {
  const countryFlag = getDetectedCountryFlag(member.country);
  if (!countryFlag) {
    return renderFlagEmojis(member.displayName);
  }

  return [
    E(
      'span',
      { class: 'fkp_dashboard-page__urltest-details__country-badge' },
      asText(countryFlag),
    ),
    ...renderFlagEmojis(member.displayName),
  ];
}

function renderUrlTestSelectedValue(info: Prokop.UrlTestInfo) {
  const selectedMember = info.outbounds.find((member) => member.selected);
  const selectedName =
    selectedMember?.displayName || info.selectedName || info.selectedCode || '';
  const name = formatUrlTestModalValue(selectedName);

  if (name === _('No')) {
    return E('span', {}, asText(name));
  }

  return E(
    'span',
    { class: 'fkp_dashboard-page__urltest-details__selected-value' },
    [
      E(
        'span',
        { class: 'fkp_dashboard-page__urltest-details__selected-name' },
        asText(selectedMember ? renderDetailsMemberName(selectedMember) : name),
      ),
      ...(selectedMember?.type
        ? [
            E(
              'span',
              { class: 'fkp_dashboard-page__urltest-details__selected-type' },
              asText(selectedMember.type),
            ),
          ]
        : []),
      ...(selectedMember
        ? [
            E(
              'span',
              { class: getUrlTestLatencyClass(selectedMember.latency) },
              asText(formatUrlTestLatency(selectedMember.latency)),
            ),
          ]
        : []),
    ],
  );
}

function renderUrlTestInfoModal(outbound: Prokop.Outbound) {
  const info = outbound.urlTestInfo;

  if (!info) {
    return E('div', {}, _('URLTest details are unavailable'));
  }

  const fields: Array<{
    label: string;
    value?: unknown;
    children?: Array<HTMLElement | string>;
  }> = [
    {
      label: _('Selected'),
      children: [renderUrlTestSelectedValue(info)],
    },
    { label: _('Testing URL'), children: [renderDetailsUrl(info.url)] },
    { label: _('Interval'), value: info.interval },
    { label: _('Tolerance'), value: info.tolerance },
    { label: _('Idle timeout'), value: info.idleTimeout },
    {
      label: _('Interrupt connections'),
      value: info.interruptExistConnections,
    },
  ];

  return E('div', { class: 'fkp_dashboard-page__urltest-details' }, [
    E(
      'dl',
      { class: 'fkp_dashboard-page__urltest-details__params' },
      fields.map(({ label, value, children }) =>
        E('div', { class: 'fkp_dashboard-page__urltest-details__param' }, [
          E('dt', {}, asText(label)),
          E(
            'dd',
            {},
            children || [E('span', {}, asText(formatUrlTestModalValue(value)))],
          ),
        ]),
      ),
    ),
    E('div', { class: 'fkp_dashboard-page__urltest-details__outbounds' }, [
      E(
        'div',
        { class: 'fkp_dashboard-page__urltest-details__outbounds-title' },
        _('Nodes'),
      ),
      E(
        'div',
        { class: 'fkp_dashboard-page__urltest-details__table' },
        info.outbounds.length
          ? info.outbounds.map((member) =>
              E(
                'div',
                {
                  class: [
                    'fkp_dashboard-page__urltest-details__row',
                    member.selected
                      ? 'fkp_dashboard-page__urltest-details__row--active'
                      : '',
                  ]
                    .filter(Boolean)
                    .join(' '),
                },
                [
                  E(
                    'div',
                    {
                      class: 'fkp_dashboard-page__urltest-details__row-name',
                    },
                    [
                      E('b', {}, renderDetailsMemberName(member)),
                      ...(member.type
                        ? [
                            E(
                              'span',
                              {
                                class:
                                  'fkp_dashboard-page__urltest-details__row-type',
                              },
                              asText(member.type),
                            ),
                          ]
                        : []),
                    ],
                  ),
                  E(
                    'div',
                    {
                      class: 'fkp_dashboard-page__urltest-details__row-meta',
                    },
                    [
                      E(
                        'span',
                        { class: getUrlTestLatencyClass(member.latency) },
                        asText(formatUrlTestLatency(member.latency)),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : [
              E(
                'div',
                { class: 'fkp_dashboard-page__urltest-details__empty' },
                _('Node list is empty'),
              ),
            ],
      ),
    ]),
    // Close first in '.right': LuCI's Escape clicks the first
    // '.right > button' of the modal (UC-134).
    E('div', { class: 'right fkp_dashboard-page__urltest-details__footer' }, [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button cbi-button-neutral',
          click: () => {
            ui.hideModal();
          },
        },
        _('Close'),
      ),
      ...(isReadonlyMode()
        ? []
        : [
            E(
              'button',
              {
                type: 'button',
                class: 'btn cbi-button cbi-button-action',
                click: () => renderUrlTestEditorModal(outbound),
              },
              _('Edit'),
            ),
          ]),
    ]),
  ]);
}

function renderUrlTestEditorModal(outbound: Prokop.Outbound) {
  const info = outbound.urlTestInfo;
  if (!info) return;

  const input = (value: unknown, type = 'text') =>
    E('input', { type, value: `${value ?? ''}`, class: 'cbi-input-text' });
  const url = input(info.url);
  const interval = input(info.interval);
  const tolerance = input(info.tolerance, 'number');
  const idleTimeout = input(info.idleTimeout);
  const interrupt = E('input', { type: 'checkbox' });
  interrupt.checked = Boolean(info.interruptExistConnections);
  const controls = [url, interval, tolerance, idleTimeout, interrupt];
  const progress = E('div', {
    class: 'alert-message notice',
    style: 'display:none; margin-top:1em',
  });
  const actionButtons: HTMLButtonElement[] = [];
  let activeButton: HTMLButtonElement | null = null;
  let activeButtonLabel = '';
  const setBusy = (busy: boolean, message = '') => {
    controls.forEach((control) => {
      control.disabled = busy;
    });
    actionButtons.forEach((button) => {
      button.disabled = busy;
    });
    progress.style.display = message ? '' : 'none';
    progress.textContent = message;
    if (activeButton) {
      activeButton.textContent = busy ? _('Applying…') : activeButtonLabel;
    }
  };
  const row = renderUrlTestEditorRow;

  // A reload that init.d only queued, or skipped for a stopped Prokop, is
  // not reported as applied (UC-061); one that failed or was refused keeps
  // the editor open (UC-116).
  const apply = async (change: () => Promise<void>, isReset: boolean) => {
    const result = await runUrlTestChange(
      {
        change,
        reload: async () => {
          setBusy(true, _('Applying Prokop configuration…'));
          return runServiceActionJob('reload');
        },
        refresh: async () => {
          setBusy(true, _('Refreshing Dashboard…'));
          await fetchDashboardSections({ force: true });
        },
      },
      isReset,
    );
    if (result.close) {
      ui.hideModal();
    } else {
      setBusy(false);
    }
    showToast(result.toast.text, result.toast.type, result.toast.duration);
  };
  const save = () =>
    apply(async () => {
      setBusy(true, _('Saving URLTest settings…'));
      const response = await ProkopShellMethods.saveUrlTestOverride(
        info.sectionName || '',
        info.code,
        url.value.trim(),
        interval.value.trim(),
        tolerance.value.trim(),
        idleTimeout.value.trim(),
        interrupt.checked,
      );
      if ((response.code ?? 0) !== 0)
        throw new Error(response.stderr || 'save failed');
    }, false);
  const reset = () =>
    apply(async () => {
      setBusy(true, _('Removing user settings…'));
      const response = await ProkopShellMethods.resetUrlTestOverride(
        info.sectionName || '',
        info.code,
      );
      if ((response.code ?? 0) !== 0)
        throw new Error(response.stderr || 'reset failed');
    }, true);
  const action = (fn: () => Promise<void>) => async (event: MouseEvent) => {
    activeButton = event.currentTarget as HTMLButtonElement;
    activeButtonLabel = activeButton.textContent || '';
    try {
      await fn();
    } catch (error) {
      logger.error('[DASHBOARD]', 'URLTest override failed', error);
      setBusy(false);
      showToast(_('Failed to save URLTest settings'), 'error');
    }
  };

  const resetButton = E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button cbi-button-negative',
      click: action(reset),
    },
    _('Use source values'),
  );
  const saveButton = E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button cbi-button-positive',
      click: action(save),
    },
    _('Save'),
  );
  const cancelButton = E(
    'button',
    { type: 'button', class: 'btn', click: () => ui.hideModal() },
    _('Cancel'),
  );
  actionButtons.push(resetButton, saveButton, cancelButton);

  ui.showModal(
    asText(`${_('Edit URLTest')}: ${info.displayName}`),
    E('div', {}, [
      E('div', { class: 'fkp_dashboard-page__urltest-details__params' }, [
        row(_('Testing URL'), url),
        row(_('Interval'), interval),
        row(_('Tolerance'), tolerance),
        row(_('Idle timeout'), idleTimeout),
        row(_('Interrupt connections'), interrupt),
      ]),
      progress,
      // Cancel first in '.right': LuCI's Escape clicks it (UC-134).
      E('div', { class: 'right fkp_dashboard-page__urltest-details__footer' }, [
        cancelButton,
        resetButton,
        saveButton,
      ]),
    ]),
  );
}

function handleShowUrlTestInfo(outbound: Prokop.Outbound) {
  if (!outbound.urlTestInfo) {
    return;
  }

  ui.showModal(
    asText(
      `${_('URLTest details')}: ${
        outbound.urlTestInfo.displayName || outbound.displayName
      }`,
    ),
    renderUrlTestInfoModal(outbound),
  );
}

function renderPrioritySelectedValue(info: Prokop.PriorityInfo) {
  const selectedMember = info.outbounds.find((member) => member.selected);
  const selectedName =
    selectedMember?.displayName || info.selectedName || info.selectedCode || '';
  const name = formatUrlTestModalValue(selectedName);

  if (name === _('No')) {
    return E('span', {}, asText(name));
  }

  return E(
    'span',
    { class: 'fkp_dashboard-page__urltest-details__selected-value' },
    [
      E(
        'span',
        {
          class: [
            'fkp_dashboard-page__urltest-details__selected-name',
            selectedMember
              ? 'fkp_dashboard-page__urltest-details__priority-name'
              : '',
          ]
            .filter(Boolean)
            .join(' '),
        },
        asText(
          selectedMember ? renderPriorityMemberName(selectedMember) : name,
        ),
      ),
      ...(selectedMember?.type
        ? [
            E(
              'span',
              { class: 'fkp_dashboard-page__urltest-details__selected-type' },
              asText(selectedMember.type),
            ),
          ]
        : []),
      ...(selectedMember
        ? [
            E(
              'span',
              { class: getUrlTestLatencyClass(selectedMember.latency) },
              asText(formatUrlTestLatency(selectedMember.latency)),
            ),
          ]
        : []),
    ],
  );
}

function renderPriorityMemberName(member: Prokop.PriorityMember) {
  const levelName = member.levelName || _('Level');

  return [
    E(
      'span',
      { class: 'fkp_dashboard-page__urltest-details__priority-number' },
      asText(`#${member.levelIndex + 1}`),
    ),
    E(
      'span',
      { class: 'fkp_dashboard-page__urltest-details__priority-level' },
      asText(levelName),
    ),
    E(
      'span',
      { class: 'fkp_dashboard-page__urltest-details__priority-node' },
      renderDetailsMemberName(member),
    ),
  ];
}

function renderPriorityInfoModal(outbound: Prokop.Outbound) {
  const info = outbound.priorityInfo;

  if (!info) {
    return E('div', {}, _('Priority details are unavailable'));
  }

  const fields: Array<{
    label: string;
    value?: unknown;
    children?: Array<HTMLElement | string>;
  }> = [
    {
      label: _('Selected'),
      children: [renderPrioritySelectedValue(info)],
    },
    { label: _('Check URL'), children: [renderDetailsUrl(info.healthUrl)] },
    {
      label: _('Check interval'),
      value: info.activeCheckInterval,
    },
    { label: _('Unavailability timeout'), value: info.checkTimeout },
    {
      label: _('Higher-level check interval'),
      value: info.recoveryCheckInterval,
    },
    {
      label: _('Select the fastest node'),
      value: info.pickFastest,
    },
    {
      label: _('Automatically select the fastest node in the current level'),
      value: info.switchToFasterSamePriority,
    },
    ...(info.switchToFasterSamePriority
      ? [
          {
            label: _('Faster server search interval'),
            value: info.fastestCheckInterval,
          },
        ]
      : []),
    {
      label: _('Interrupt connections'),
      value: info.interruptExistConnections,
    },
  ];

  return E('div', { class: 'fkp_dashboard-page__urltest-details' }, [
    E(
      'dl',
      { class: 'fkp_dashboard-page__urltest-details__params' },
      fields.map(({ label, value, children }) =>
        E('div', { class: 'fkp_dashboard-page__urltest-details__param' }, [
          E('dt', {}, asText(label)),
          E(
            'dd',
            {},
            children || [E('span', {}, asText(formatUrlTestModalValue(value)))],
          ),
        ]),
      ),
    ),
    E('div', { class: 'fkp_dashboard-page__urltest-details__outbounds' }, [
      E(
        'div',
        { class: 'fkp_dashboard-page__urltest-details__outbounds-title' },
        _('Nodes'),
      ),
      E(
        'div',
        { class: 'fkp_dashboard-page__urltest-details__table' },
        info.outbounds.length
          ? info.outbounds.map((member) =>
              E(
                'div',
                {
                  class: [
                    'fkp_dashboard-page__urltest-details__row',
                    member.selected
                      ? 'fkp_dashboard-page__urltest-details__row--active'
                      : '',
                  ]
                    .filter(Boolean)
                    .join(' '),
                },
                [
                  E(
                    'div',
                    {
                      class: 'fkp_dashboard-page__urltest-details__row-name',
                    },
                    [
                      E(
                        'b',
                        {
                          class:
                            'fkp_dashboard-page__urltest-details__priority-name',
                        },
                        renderPriorityMemberName(member),
                      ),
                      ...(member.type
                        ? [
                            E(
                              'span',
                              {
                                class:
                                  'fkp_dashboard-page__urltest-details__row-type',
                              },
                              asText(member.type),
                            ),
                          ]
                        : []),
                    ],
                  ),
                  E(
                    'div',
                    {
                      class: 'fkp_dashboard-page__urltest-details__row-meta',
                    },
                    [
                      E(
                        'span',
                        { class: getUrlTestLatencyClass(member.latency) },
                        asText(formatUrlTestLatency(member.latency)),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : [
              E(
                'div',
                { class: 'fkp_dashboard-page__urltest-details__empty' },
                _('Node list is empty'),
              ),
            ],
      ),
    ]),
    E('div', { class: 'right fkp_dashboard-page__urltest-details__footer' }, [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button cbi-button-neutral',
          click: () => {
            ui.hideModal();
          },
        },
        _('Close'),
      ),
    ]),
  ]);
}

function handleShowPriorityInfo(outbound: Prokop.Outbound) {
  if (!outbound.priorityInfo) {
    return;
  }

  ui.showModal(
    asText(
      `${_('Priority details')}: ${
        outbound.priorityInfo.displayName || outbound.displayName
      }`,
    ),
    renderPriorityInfoModal(outbound),
  );
}

async function handleUpdateSubscription(section: Prokop.OutboundGroup) {
  if (
    store.get().sectionsWidget.subscriptionUpdatingSections[section.sectionName]
  ) {
    return;
  }

  setSubscriptionUpdating(section.sectionName, true, true);
  let jobId = '';
  let ownsJobFollow = false;

  try {
    const startResponse = await ProkopShellMethods.subscriptionUpdateStart(
      section.sectionName,
    );

    if (!startResponse.success) {
      throw new Error(startResponse.error);
    }

    jobId = startResponse.data.job_id;
    markUiActionOwned('subscription', jobId);
    if (followedSubscriptionJobs.has(jobId)) {
      return;
    }

    followedSubscriptionJobs.add(jobId);
    ownsJobFollow = true;
    const response = await ProkopShellMethods.waitSubscriptionUpdateJob(jobId);
    await completeSubscriptionUpdateJob(jobId, section.sectionName, response);
  } catch (error) {
    logger.error('[DASHBOARD]', 'handleUpdateSubscription: failed', error);
    if (!pageUnloading) {
      const message =
        error instanceof Error
          ? error.message
          : _('Failed to update subscriptions');

      setSubscriptionUpdating(section.sectionName, false);
      if (!isTransientRpcError(message)) {
        showToast(subscriptionUpdateErrorMessage(message), 'error');
      }
    }
  } finally {
    if (ownsJobFollow) {
      followedSubscriptionJobs.delete(jobId);
    }
  }
}

function shallowRecordEqual<T>(
  left: Record<string, T>,
  right: Record<string, T>,
) {
  const leftKeys = Object.keys(left);
  const rightKeys = Object.keys(right);

  if (leftKeys.length !== rightKeys.length) {
    return false;
  }

  return leftKeys.every((key) => left[key] === right[key]);
}

function canUpdateLatencyProgressInline(
  prev: StoreType['sectionsWidget'],
  next: StoreType['sectionsWidget'],
) {
  return (
    prev.loading === next.loading &&
    prev.failed === next.failed &&
    prev.stale === next.stale &&
    prev.data === next.data &&
    shallowRecordEqual(
      prev.latencyFetchingSections,
      next.latencyFetchingSections,
    ) &&
    shallowRecordEqual(
      prev.subscriptionUpdatingSections,
      next.subscriptionUpdatingSections,
    ) &&
    shallowRecordEqual(
      prev.selectorSwitchingSections,
      next.selectorSwitchingSections,
    )
  );
}

function findLatencyTestButton(container: HTMLElement, sectionName: string) {
  return Array.from(
    container.querySelectorAll<HTMLButtonElement>(
      `.${LATENCY_TEST_BUTTON_CLASS}`,
    ),
  ).find((button) => button.dataset.latencySection === sectionName);
}

function updateLatencyProgressInline(
  sectionsWidget: StoreType['sectionsWidget'],
) {
  const container = document.getElementById('dashboard-sections-grid');

  if (!container) {
    return false;
  }

  for (const section of sectionsWidget.data) {
    if (!sectionsWidget.latencyFetchingSections[section.sectionName]) {
      continue;
    }

    const button = findLatencyTestButton(container, section.sectionName);
    const label = button?.querySelector<HTMLElement>(
      `.${LATENCY_TEST_BUTTON_LABEL_CLASS}`,
    );

    if (!label) {
      return false;
    }

    const text = getLatencyTestLabel(
      sectionsWidget.latencyProgressSections[section.sectionName],
    );

    if (label.textContent !== text) {
      label.textContent = text;
    }
  }

  return true;
}

// Renderer

async function renderSectionsWidget() {
  logger.debug('[DASHBOARD]', 'renderSectionsWidget');
  const sectionsWidget = store.get().sectionsWidget;
  const container = document.getElementById('dashboard-sections-grid');

  if (!container) {
    return;
  }

  const stopped = getDashboardServiceAvailability() === 'stopped';
  sectionsStoppedRendered = stopped;

  if (stopped || sectionsWidget.loading || sectionsWidget.failed) {
    const renderedWidget = renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      stopped,
      stoppedActions: stopped ? renderStartServiceAction() : undefined,
      section: {
        code: '',
        sectionName: '',
        displayName: '',
        outbounds: [],
        withTagSelect: false,
      },
      onTestLatency: () => {},
      onChooseOutbound: () => {},
      onShowUrlTestInfo: () => {},
      onShowPriorityInfo: () => {},
      onUpdateSubscription: () => {},
      latencyFetching: false,
      latencyProgress: undefined,
      subscriptionUpdating: false,
      selectorSwitchingTag: undefined,
      isPriorityMembersExpanded: () => false,
      onPriorityMembersToggle: () => {},
    });

    return preserveScrollForPage(() => {
      container.replaceChildren(renderedWidget);
    });
  }

  const renderedWidgets = sectionsWidget.data.map((section) =>
    renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      section,
      latencyFetching: Boolean(
        sectionsWidget.latencyFetchingSections[section.sectionName],
      ),
      latencyProgress:
        sectionsWidget.latencyProgressSections[section.sectionName],
      subscriptionUpdating: Boolean(
        sectionsWidget.subscriptionUpdatingSections[section.sectionName],
      ),
      selectorSwitchingTag:
        sectionsWidget.selectorSwitchingSections[section.sectionName],
      readonly: isReadonlyMode(),
      isPriorityMembersExpanded: (outbound) =>
        priorityMembersState.isExpanded(section.sectionName, outbound.code),
      onPriorityMembersToggle: (outbound, open) => {
        priorityMembersState.setExpanded(
          section.sectionName,
          outbound.code,
          open,
        );
      },
      onTestLatency: (tag) => {
        if (section.withTagSelect) {
          if (Array.isArray(tag)) {
            return handleTestLatency(
              'proxy_list',
              section.sectionName,
              JSON.stringify(tag),
            );
          }

          return handleTestLatency('group', section.sectionName, tag);
        }

        return handleTestLatency(
          'proxy',
          section.sectionName,
          Array.isArray(tag) ? JSON.stringify(tag) : tag,
          section.latencyTestTimeout,
        );
      },
      onChooseOutbound: (sectionName, selector, tag) => {
        void handleChooseOutbound(sectionName, selector, tag);
      },
      onShowUrlTestInfo: (outbound) => {
        handleShowUrlTestInfo(outbound);
      },
      onShowPriorityInfo: (outbound) => {
        handleShowPriorityInfo(outbound);
      },
      onUpdateSubscription: (section) => {
        void handleUpdateSubscription(section);
      },
    }),
  );

  return preserveScrollForPage(() => {
    const staleNotice = renderSectionsStaleNotice(sectionsWidget);
    replaceChildrenKeepingFocus(
      container,
      ...(staleNotice ? [staleNotice] : []),
      ...renderedWidgets,
    );
  });
}

async function onStoreUpdate(
  next: StoreType,
  prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.sectionsWidget) {
    const inlineUpdated =
      canUpdateLatencyProgressInline(
        prev.sectionsWidget,
        next.sectionsWidget,
      ) && updateLatencyProgressInline(next.sectionsWidget);

    if (!inlineUpdated) {
      renderSectionsWidget();
    }
  }

  if (diff.servicesInfoWidget) {
    syncDashboardServiceAvailability();
  }

  if (
    diff.bandwidthWidget ||
    diff.systemInfoWidget ||
    diff.servicesInfoWidget ||
    diff.sectionsWidget
  ) {
    renderOverviewCards();
  }
}

async function onPageMount() {
  // Cleanup before mount
  onPageUnmount();

  dashboardMounted = true;
  dashboardMountId += 1;
  const mountId = dashboardMountId;
  overviewHost = Boolean(document.getElementById('dashboard-overview'));
  if (overviewHost) {
    void refreshHealth(mountId);
    void refreshAutotune(mountId);
    healthRefreshTimer = setInterval(() => {
      if (isPageHidden()) return;
      void refreshHealth(mountId);
      if (Date.now() - autotuneLoadedAt >= AUTOTUNE_REFRESH_INTERVAL_MS)
        void refreshAutotune(mountId);
    }, 10000);
  }
  const hasRuntimeSnapshot = Boolean(getCachedRuntimeUiState());

  if (!hasRuntimeSnapshot) {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (!dashboardMounted || mountId !== dashboardMountId) {
      return;
    }

    if (!uiState) {
      void fetchServicesInfo();
    }
  }

  // Add new listener
  store.subscribe(onStoreUpdate);
  startActionStateWatcher();
  void renderSectionsWidget();
  if (overviewHost) void loadOverviewCounts(mountId);
  syncDashboardServiceAvailability();
  renderOverviewCards();

  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }
}

function onPageUnmount() {
  dashboardMounted = false;
  dashboardMountId += 1;
  if (healthRefreshTimer) clearInterval(healthRefreshTimer);
  healthRefreshTimer = null;

  stopDashboardDataUpdates();
  stopActionStateWatcher();
  sectionsRefreshQueued = false;
  sectionsRefreshPromise = null;
  // Remove old listener
  store.unsubscribe(onStoreUpdate);
  // Clear store
  store.reset(['bandwidthWidget', 'systemInfoWidget']);
}

let dashboardLifecycleRegistered = false;
let dashboardControllerInitialized = false;

function registerLifecycleListeners() {
  if (dashboardLifecycleRegistered) {
    return;
  }

  dashboardLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      logger.debug(
        '[DASHBOARD]',
        'active tab diff event, active tab:',
        diff.tabService.current,
      );
      const isDashboardVisible = next.tabService.current === 'dashboard';

      if (isDashboardVisible) {
        logger.debug(
          '[DASHBOARD]',
          'registerLifecycleListeners',
          'onPageMount',
        );
        return onPageMount();
      }

      if (!isDashboardVisible) {
        logger.debug(
          '[DASHBOARD]',
          'registerLifecycleListeners',
          'onPageUnmount',
        );
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (dashboardControllerInitialized) {
    return;
  }

  dashboardControllerInitialized = true;

  onMount('dashboard-status').then(() => {
    logger.debug('[DASHBOARD]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (
      store.get().tabService.current === 'dashboard' ||
      isActiveLuciTab('dashboard')
    ) {
      onPageMount();
    }
  });
}
