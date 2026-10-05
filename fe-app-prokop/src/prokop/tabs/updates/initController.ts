import { asText } from '../../../helpers/asText';
import { onMount, preserveScrollForPage } from '../../../helpers';
import { PROKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT } from '../../../constants';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { showToast } from '../../../helpers/showToast';
import {
  actionReasonText,
  failureReason,
  failureText,
  failureToastType,
} from '../../helpers/actionReason';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import {
  renderDownloadIcon24,
  renderCopyIcon24,
  renderRotateCcwIcon24,
  renderSearchIcon24,
  renderXIcon24,
} from '../../../icons';
import { renderButton } from '../../../partials';
import { getComponentActionKey } from '../../helpers/getComponentActionKey';
import type { UpdatesActionKey } from '../../helpers/getComponentActionKey';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { shouldShowLoadingForRestoredAction } from '../../helpers/restoredActionLoading';
import {
  formatSingBoxVersion,
  normalizeSingBoxVariantFields,
} from '../../helpers/singBoxVariant';
import {
  hasLocalMutatingServiceActionLoading,
  isServiceTransitionStatus,
} from '../diagnostic/serviceTransition';
import { shouldApplyCompletedComponentActionResult } from './componentActionCompletion';
import {
  componentActionFailureText,
  componentActionSuccessText,
} from './componentActionToast';
import {
  normalizeProgress,
  renderComponentProgress,
} from './componentProgress';
import { showReleaseSelector } from './releaseSelector';
import {
  shouldPreserveCompletedCheckResultOnNextMount,
  shouldExposeCheckResults,
  shouldRefreshComponentStateBeforeRender,
  shouldResetCheckResultsOnMount,
} from './checkResultLifecycle';
import { ProkopShellMethods } from '../../methods';
import {
  logger,
  markUiActionOwned,
  setLocalComponentAction,
  shouldNotifyOwnedUiAction,
  store,
  StoreType,
} from '../../services';
import { ensureSystemInfo } from '../../services/systemInfo.service';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../../services/runtimeUiState.service';
import { Prokop } from '../../types';
import { renderFullUninstall } from './fullUninstall';
import {
  refreshListsUpdateStatus,
  renderListsUpdate,
  stopListsUpdatePolling,
} from './listsUpdate';
import { render } from './render';
import { renderOnAttach } from './renderOnAttach';
import { confirmAction } from '../../ui/confirmAction';

type UpdateStatus = StoreType['updatesChecks'][Prokop.ComponentName]['status'];

interface ComponentActionButton {
  key: UpdatesActionKey;
  text: string;
  icon: () => SVGSVGElement;
  component: Prokop.ComponentName;
  action: Prokop.ComponentAction;
  disabled?: boolean;
  version?: string;
}

interface ComponentCard {
  component: Prokop.ComponentName;
  column: 0 | 1 | 2;
  title: string;
  version: string;
  latestVersion?: string;
  releaseUrl?: string;
  actions: ComponentActionButton[];
  copyValue?: string;
  // A line under the header: why an action is unavailable, or where the
  // component's own page is.
  note?: string;
  link?: { href: string; text: string };
  // Status lines under the header, and a second row of actions
  // with its own explanation (TorrServer's direct routing).
  details?: string[];
  directNote?: string;
  extraActions?: ComponentActionButton[];
}

let updatesLifecycleRegistered = false;
let updatesControllerInitialized = false;
let updatesMounted = false;
let updatesMountId = 0;
let pageUnloading = false;
let preserveCheckResultsOnNextMount = false;
let componentUpdateCheckCacheResolved = false;
let componentUpdateCheckCacheSnapshot: Prokop.ComponentUpdateCheckCache | null =
  null;
let componentUpdateCheckCachePromise: Promise<Prokop.ComponentUpdateCheckCache> | null =
  null;
let componentActionStateUnsubscribe: (() => void) | null = null;
let componentActionStateRefreshPromise: Promise<void> | null = null;
const followedComponentJobs = new Set<string>();
const handledComponentJobs = new Set<string>();

if (typeof window !== 'undefined') {
  window.addEventListener('pagehide', () => {
    pageUnloading = true;
  });
  window.addEventListener('pageshow', () => {
    pageUnloading = false;
  });
}

function shouldShowInstallAfterCheck(component: Prokop.ComponentName) {
  const status = getVisibleCheckResult(component)?.status;

  return status === 'outdated' || status === 'dev';
}

function getVisibleCheckResult(component: Prokop.ComponentName) {
  if (
    !shouldExposeCheckResults({
      mounted: updatesMounted,
      cacheResolved: componentUpdateCheckCacheResolved,
    })
  ) {
    return null;
  }

  return store.get().updatesChecks[component];
}

function getLatestVersion(component: Prokop.ComponentName) {
  const checkResult = getVisibleCheckResult(component);

  if (!checkResult || !shouldShowInstallAfterCheck(component)) {
    return undefined;
  }

  return checkResult.latest_version || undefined;
}

function getGitHubReleaseUrl(component: Prokop.ComponentName) {
  const checkResult = getVisibleCheckResult(component);

  if (
    !checkResult ||
    !shouldShowInstallAfterCheck(component) ||
    !checkResult.release_url
  ) {
    return undefined;
  }

  return checkResult.release_url;
}

function isAnyActionLoading() {
  return Object.values(store.get().updatesActions).some((item) => item.loading);
}

function isServiceRuntimeActionLoading() {
  const state = store.get();

  return (
    hasLocalMutatingServiceActionLoading(state.diagnosticsActions) ||
    isServiceTransitionStatus(state.servicesInfoWidget.data.prokopStatus)
  );
}

function isSystemInfoLoading() {
  const systemInfo = store.get().diagnosticsSystemInfo;

  return systemInfo.loading || !systemInfo.loaded;
}

function setActionLoading(
  action: UpdatesActionKey,
  loading: boolean,
  local = false,
) {
  if (local || !loading) {
    setLocalComponentAction(action, loading && local);
  }

  const updatesActions = store.get().updatesActions;

  store.set({
    updatesActions: {
      ...updatesActions,
      [action]: { loading },
    },
  });
}

function beginComponentAction(button: ComponentActionButton) {
  if (isAnyActionLoading()) {
    return false;
  }

  // The last action's result gives way to the new one.
  dismissComponentProgress(button.component);
  setActionLoading(button.key, true, true);
  return true;
}

function dismissComponentProgress(component: Prokop.ComponentName) {
  const current = store.get().updatesProgress;
  const view = current[component];

  if (!view || view.running) {
    return;
  }

  const next = { ...current };
  delete next[component];
  store.set({ updatesProgress: next });
}

// The finished action stays on its card with how it ended. The job's final
// state carries the stages it went through; a result the UI put together
// itself (the self-update below) keeps the stages last seen.
function setFinishedComponentProgress(
  jobId: string,
  result: Partial<Prokop.ComponentActionResult> | undefined,
  success: boolean,
  message: string,
) {
  const current = store.get().updatesProgress;
  const previous = Object.values(current).find((view) => view?.jobId === jobId);
  const component = result?.component || previous?.component;
  const action = result?.action || previous?.action;

  if (!component || !action || action === 'check_update') {
    return;
  }

  const progress =
    normalizeProgress(result?.progress) ??
    (previous?.jobId === jobId ? previous.progress : null);

  store.set({
    updatesProgress: {
      ...current,
      [component]: {
        component,
        action,
        jobId,
        running: false,
        startedAt:
          (typeof result?.started_at === 'number' && result.started_at) ||
          previous?.startedAt ||
          0,
        finishedAt:
          (typeof result?.updated_at === 'number' && result.updated_at) || 0,
        progress,
        success,
        message,
        version: result?.current_version || undefined,
      },
    },
  });
}

// The page reloads after Prokop updated itself: its result is shown once
// more after the reload.
const LAST_SELF_UPDATE_KEY = 'prokop.updates.lastSelfUpdate';

function keepSelfUpdateResultForReload() {
  const view = store.get().updatesProgress.prokop;

  if (!view || view.running) {
    return;
  }

  try {
    window.sessionStorage.setItem(
      LAST_SELF_UPDATE_KEY,
      JSON.stringify({ savedAt: Date.now(), view }),
    );
  } catch (_error) {
    // Without storage the result is only in the toast.
  }
}

function restoreSelfUpdateResult() {
  let saved: { savedAt?: number; view?: Prokop.ComponentProgressView } | null =
    null;

  try {
    const text = window.sessionStorage.getItem(LAST_SELF_UPDATE_KEY);
    window.sessionStorage.removeItem(LAST_SELF_UPDATE_KEY);
    saved = text ? JSON.parse(text) : null;
  } catch (_error) {
    return;
  }

  const view = saved?.view;
  if (
    !view ||
    view.component !== 'prokop' ||
    view.running ||
    typeof saved?.savedAt !== 'number' ||
    Date.now() - saved.savedAt > 10 * 60 * 1000 ||
    store.get().updatesProgress.prokop
  ) {
    return;
  }

  store.set({
    updatesProgress: {
      ...store.get().updatesProgress,
      prokop: { ...view, progress: normalizeProgress(view.progress) },
    },
  });
}

function setCheckResult(
  component: Prokop.ComponentName,
  status: UpdateStatus,
  latestVersion: string,
  releaseUrl: string = '',
) {
  const updatesChecks = store.get().updatesChecks;

  store.set({
    updatesChecks: {
      ...updatesChecks,
      [component]: {
        status,
        latest_version: latestVersion,
        release_url: releaseUrl,
      },
    },
  });
}

function resetCheckResult(component: Prokop.ComponentName) {
  setCheckResult(component, null, '');
}

function applyCachedCheckResults(results: Prokop.ComponentActionResult[]) {
  results.forEach((result) => {
    const status = result.status || null;

    if (status === 'latest' || status === 'outdated' || status === 'dev') {
      setCheckResult(
        result.component,
        status,
        result.latest_version || '',
        result.release_url || '',
      );
    }
  });
}

function loadComponentUpdateCheckCache({ force = false } = {}) {
  if (!force && componentUpdateCheckCacheSnapshot) {
    return Promise.resolve(componentUpdateCheckCacheSnapshot);
  }

  if (componentUpdateCheckCachePromise) {
    return componentUpdateCheckCachePromise;
  }

  const promise = ProkopShellMethods.componentUpdateCheckCache()
    .then((response) =>
      response.success
        ? response.data
        : ({
            enabled: false,
            results: [],
          } satisfies Prokop.ComponentUpdateCheckCache),
    )
    .then((cache) => {
      componentUpdateCheckCacheSnapshot = cache;
      return cache;
    })
    .finally(() => {
      if (componentUpdateCheckCachePromise === promise) {
        componentUpdateCheckCachePromise = null;
      }
    });

  componentUpdateCheckCachePromise = promise;
  return promise;
}

function getErrorMessage(error: unknown, fallback: string) {
  return error instanceof Error && error.message ? error.message : fallback;
}

async function ackComponentActionJob(jobId: string) {
  try {
    const response = await ProkopShellMethods.uiActionAck('component', jobId);

    if (!response.success) {
      logger.debug('[UPDATES]', 'component action ack failed', response.error);
    }
  } catch (error) {
    logger.debug('[UPDATES]', 'component action ack failed', error);
  }
}

function getExpectedLatestVersionForAction(button: ComponentActionButton) {
  if (button.component !== 'prokop' || button.action !== 'install') {
    return undefined;
  }

  return (
    store.get().updatesChecks[button.component].latest_version || undefined
  );
}

function getCheckToastMessage(status: UpdateStatus) {
  if (status === 'outdated') {
    return _('Update is available');
  }

  if (status === 'dev') {
    return _('Installed version is newer than release');
  }

  return _('Latest version is installed');
}

async function refreshSystemInfoAfterMutation() {
  await ensureSystemInfo({ force: true, silent: true });
}

function notifyActionProvidersAvailabilityChanged(
  systemInfo: StoreType['diagnosticsSystemInfo'],
) {
  if (typeof window === 'undefined' || typeof CustomEvent === 'undefined') {
    return;
  }

  window.dispatchEvent(
    new CustomEvent(PROKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT, {
      detail: {
        zapretInstalled: Boolean(systemInfo.zapret_installed),
        zapret2Installed: Boolean(systemInfo.zapret2_installed),
        byedpiInstalled: Boolean(systemInfo.byedpi_installed),
      },
    }),
  );
}

function reloadPageAfterProkopUpdate() {
  window.setTimeout(() => {
    window.location.reload();
  }, 1200);
}

function patchSystemInfoAfterMutation(result: Prokop.ComponentActionResult) {
  const systemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = { ...systemInfo, loading: false, loaded: true };
  const version =
    result.current_version || result.latest_version || _('unknown');

  if (result.component === 'prokop' && result.action === 'install') {
    nextSystemInfo.prokop_version = version;
  }

  if (result.component === 'sing_box') {
    nextSystemInfo.sing_box_version = version;

    if (result.action === 'install_extended') {
      nextSystemInfo.sing_box_extended = 1;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_tailscale = 1;
    }

    if (result.action === 'install_extended_compressed') {
      nextSystemInfo.sing_box_extended = 1;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 1;
      nextSystemInfo.sing_box_tailscale = 1;
    }

    if (result.action === 'install_stable') {
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_tailscale = 1;
    }

    if (result.action === 'install_tiny') {
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 1;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_tailscale = 0;
    }
  }

  if (result.component === 'zapret') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.zapret_installed = 0;
      nextSystemInfo.zapret_version = 'not installed';
    } else {
      nextSystemInfo.zapret_installed = 1;
      nextSystemInfo.zapret_version = version;
    }
  }

  if (result.component === 'zapret2') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.zapret2_installed = 0;
      nextSystemInfo.zapret2_version = 'not installed';
    } else {
      nextSystemInfo.zapret2_installed = 1;
      nextSystemInfo.zapret2_version = version;
    }
  }

  if (result.component === 'byedpi') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.byedpi_installed = 0;
      nextSystemInfo.byedpi_version = 'not installed';
    } else {
      nextSystemInfo.byedpi_installed = 1;
      nextSystemInfo.byedpi_version = version;
    }
  }

  if (result.component === 'zapret_manager') {
    nextSystemInfo.zapret_manager_installed =
      result.action === 'remove' ? 0 : 1;
  }

  if (result.component === 'direct_proxy') {
    nextSystemInfo.direct_proxy_enabled = result.action === 'enable' ? 1 : 0;
  }
  if (result.component === 'torrserver_direct') {
    nextSystemInfo.torrserver_direct_enabled =
      result.action === 'enable' ? 1 : 0;
    nextSystemInfo.torrserver_direct_active =
      result.action === 'enable' ? 1 : 0;
  }

  const normalizedSystemInfo = normalizeSingBoxVariantFields(nextSystemInfo);

  store.set({
    diagnosticsSystemInfo: normalizedSystemInfo,
  });

  if (
    result.component === 'zapret' ||
    result.component === 'zapret2' ||
    result.component === 'byedpi'
  ) {
    notifyActionProvidersAvailabilityChanged(normalizedSystemInfo);
  }
}

async function applyCompletedComponentAction({
  key,
  result,
  notify,
}: {
  key: UpdatesActionKey;
  result: Prokop.ComponentActionResult;
  notify: boolean;
}) {
  if (result.action === 'check_update') {
    setActionLoading(key, false);

    if (!shouldApplyCompletedComponentActionResult(result, notify)) {
      return;
    }

    if (
      shouldPreserveCompletedCheckResultOnNextMount({
        action: result.action,
        mounted: updatesMounted,
      })
    ) {
      preserveCheckResultsOnNextMount = true;
    }

    const status = result.status === 'recovered' ? null : result.status || null;

    if (status === 'latest' || status === 'outdated' || status === 'dev') {
      setCheckResult(
        result.component,
        status,
        result.latest_version || '',
        result.release_url || '',
      );
    }

    if (notify) {
      showToast(getCheckToastMessage(status), 'success');
    }
    return;
  }

  if (
    result.component === 'prokop' &&
    result.action === 'install' &&
    result.status === 'recovered'
  ) {
    resetCheckResult(result.component);
    setActionLoading(key, false);
    if (notify) {
      showToast(componentActionSuccessText(result), 'success', 5000);
      window.setTimeout(() => window.location.reload(), 5000);
    }
    return;
  }

  if (result.action === 'install' || result.action.startsWith('install_')) {
    setCheckResult(result.component, 'latest', result.latest_version || '');
  } else {
    resetCheckResult(result.component);
  }

  patchSystemInfoAfterMutation(result);
  setActionLoading(key, false);

  if (result.component === 'prokop' && result.action === 'install') {
    if (notify) {
      showToast(componentActionSuccessText(result), 'success', 1200);
    }

    if (notify) {
      keepSelfUpdateResultForReload();
      reloadPageAfterProkopUpdate();
    }
    return;
  }

  if (notify) {
    showToast(componentActionSuccessText(result), 'success');
  }

  void refreshSystemInfoAfterMutation();
}

async function completeComponentActionJob(
  key: UpdatesActionKey,
  jobId: string,
  response: Prokop.MethodResponse<Prokop.ComponentActionResult>,
) {
  if (pageUnloading) {
    setActionLoading(key, false);
    return;
  }

  const alreadyHandled = handledComponentJobs.has(jobId);

  if (alreadyHandled) {
    setActionLoading(key, false);
    return;
  }

  const shouldNotify = shouldNotifyOwnedUiAction('component', jobId);

  if (!response.success || response.data.success === false) {
    const failure = response.success
      ? { reason: response.data.reason, error: response.data.message }
      : response;
    const message = failure.error || _('Failed to execute');

    if (isTransientRpcError(message)) {
      setActionLoading(key, false);
      void refreshComponentActionState();
      return;
    }

    handledComponentJobs.add(jobId);
    setActionLoading(key, false);
    setFinishedComponentProgress(
      jobId,
      response.success ? response.data : undefined,
      false,
      componentActionFailureText(failureText(failure, _('Failed to execute'))),
    );
    if (shouldNotify) {
      // Busy is a translated warning, not a failure (UC-119).
      showToast(
        componentActionFailureText(
          failureText(failure, _('Failed to execute')),
        ),
        failureToastType(failure),
      );
    }
    await ackComponentActionJob(jobId);
    return;
  }

  handledComponentJobs.add(jobId);
  setFinishedComponentProgress(
    jobId,
    response.data,
    true,
    componentActionSuccessText(response.data),
  );
  await ackComponentActionJob(jobId);
  await applyCompletedComponentAction({
    key,
    result: response.data,
    notify: shouldNotify,
  });
}

async function followComponentActionState(state: Prokop.ComponentActionResult) {
  const jobId = state.job_id;
  const key = getComponentActionKey(state.component, state.action);

  if (!jobId || !key || followedComponentJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledComponentJobs.has(jobId)) {
    return;
  }

  followedComponentJobs.add(jobId);
  if (shouldShowLoadingForRestoredAction(state)) {
    setActionLoading(key, true);
  }

  try {
    const response = state.running
      ? await ProkopShellMethods.waitComponentActionJob(
          jobId,
          state.component,
          state.action,
          state.latest_version || undefined,
        )
      : ({
          success: true,
          data: state,
        } as Prokop.MethodSuccessResponse<Prokop.ComponentActionResult>);

    await completeComponentActionJob(key, jobId, response);
  } catch (error) {
    logger.error('[UPDATES]', 'followComponentActionState failed', error);
    if (!pageUnloading) {
      const message = getErrorMessage(error, _('Failed to execute'));

      setActionLoading(key, false);
      if (!isTransientRpcError(message)) {
        showToast(message, 'error');
      }
    }
  } finally {
    followedComponentJobs.delete(jobId);
  }
}

async function followAlreadyRunningComponentAction(
  button: ComponentActionButton,
) {
  const uiState = await refreshRuntimeUiState({ force: true });

  if (!uiState) {
    return false;
  }

  const state = uiState.actions.component.find(
    (item) =>
      item.running &&
      item.component === button.component &&
      item.action === button.action,
  );

  if (!state) {
    return false;
  }

  if (state.job_id) {
    markUiActionOwned('component', state.job_id);
  }
  await followComponentActionState(state);
  return true;
}

// The backend refuses a start while another component action holds its
// lock (UC-119); an older backend said so only in English.
function isComponentActionAlreadyRunningError(
  failure: Prokop.MethodFailureResponse,
) {
  return failureReason(failure) === 'busy';
}

function handleComponentUiState(uiState: Prokop.UiState) {
  for (const state of uiState.actions.component || []) {
    void followComponentActionState(state);
  }
}

async function refreshComponentActionState() {
  if (componentActionStateRefreshPromise) {
    return componentActionStateRefreshPromise;
  }

  componentActionStateRefreshPromise = (async () => {
    if (!updatesMounted) {
      return;
    }

    const state = await refreshRuntimeUiState({ force: true });

    if (!state) {
      return;
    }

    handleComponentUiState(state);
  })().finally(() => {
    componentActionStateRefreshPromise = null;
  });

  return componentActionStateRefreshPromise;
}

function startComponentActionStateWatcher() {
  if (componentActionStateUnsubscribe) {
    return;
  }

  componentActionStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (updatesMounted) {
      handleComponentUiState(uiState);
    }
  });
}

function stopComponentActionStateWatcher() {
  if (!componentActionStateUnsubscribe) {
    return;
  }

  componentActionStateUnsubscribe();
  componentActionStateUnsubscribe = null;
}

const REMOVABLE_COMPONENT_TITLES: Partial<
  Record<Prokop.ComponentName, string>
> = {
  zapret: 'Zapret',
  zapret2: 'Zapret2',
  byedpi: 'ByeDPI',
  zapret_manager: 'Zapret-Manager-Stressozz',
  torrserver: 'TorrServer',
};

function confirmComponentRemoval(button: ComponentActionButton) {
  const title =
    REMOVABLE_COMPONENT_TITLES[button.component] || button.component;
  const isDpiProvider = ['zapret', 'zapret2', 'byedpi'].includes(
    button.component,
  );

  return confirmAction({
    title: _('Remove %s?').replace('%s', title),
    message:
      button.component === 'torrserver'
        ? _(
            'TorrServer is stopped and its program is removed. Its settings and torrent list stay on the router.',
          )
        : _('The package is removed from the router.'),
    consequences: isDpiProvider
      ? [_('Rules that use this provider stop bypassing DPI')]
      : undefined,
    confirmLabel: _('Remove'),
    danger: true,
  });
}

// The values match recommended_settings() in torrserver/manager.uc, which
// also sizes the cache for this router (torrserver_recommended_cache_mib).
function confirmTorrServerSettings() {
  const cacheMib = Number(
    store.get().diagnosticsSystemInfo.torrserver_recommended_cache_mib || 0,
  );
  return confirmAction({
    title: _('Apply the recommended TorrServer settings?'),
    message: _(
      'Prokop sets these TorrServer settings. The others, such as DLNA, the name and the trackers, stay as they are.',
    ),
    consequences: [
      cacheMib > 0
        ? _('Cache: %s MB, an eighth of the router memory').replace(
            '%s',
            String(cacheMib),
          )
        : _('Cache: an eighth of the router memory, 32 to 256 MB'),
      _('Read-ahead 95%, preload 50%'),
      _('25 connections per torrent, disconnect after 30 seconds'),
      _('Responsive mode on'),
      _('UPnP off: TorrServer does not open ports on the router'),
      _(
        'If a setting changes, TorrServer restarts its torrents: playback stops for a few seconds',
      ),
    ],
    confirmLabel: _('Apply'),
  });
}

async function handleComponentAction(button: ComponentActionButton) {
  if (button.action === 'remove' && !(await confirmComponentRemoval(button))) {
    return;
  }
  if (
    button.action === 'apply_settings' &&
    !(await confirmTorrServerSettings())
  ) {
    return;
  }

  if (!beginComponentAction(button)) {
    return;
  }

  let jobId = '';
  let ownsJobFollow = false;

  try {
    const startResponse = await ProkopShellMethods.componentActionStart(
      button.component,
      button.action,
      button.version,
    );

    if (!startResponse.success) {
      if (isComponentActionAlreadyRunningError(startResponse)) {
        setActionLoading(button.key, false);
        if (!(await followAlreadyRunningComponentAction(button))) {
          // Another component action runs: nothing was started.
          showToast(
            actionReasonText('busy') || startResponse.error,
            'warning',
            6000,
          );
          await refreshComponentActionState();
        }
        return;
      }

      if (isTransientRpcError(startResponse.error)) {
        if (!(await followAlreadyRunningComponentAction(button))) {
          setActionLoading(button.key, false);
          await refreshComponentActionState();
        }
        return;
      }

      throw new Error(startResponse.error);
    }

    jobId = startResponse.data.job_id;
    markUiActionOwned('component', jobId);
    if (followedComponentJobs.has(jobId)) {
      return;
    }

    followedComponentJobs.add(jobId);
    ownsJobFollow = true;

    const response = await ProkopShellMethods.waitComponentActionJob(
      jobId,
      button.component,
      button.action,
      button.version || getExpectedLatestVersionForAction(button),
    );

    await completeComponentActionJob(button.key, jobId, response);
  } catch (error) {
    logger.error('[UPDATES]', 'handleComponentAction failed', error);
    if (!pageUnloading) {
      const message = getErrorMessage(error, _('Failed to execute'));

      setActionLoading(button.key, false);
      if (!isTransientRpcError(message)) {
        showToast(message, 'error');
      }
      void refreshComponentActionState();
    }
  } finally {
    if (ownsJobFollow) {
      followedComponentJobs.delete(jobId);
    }
  }
}

function getCheckAction(
  component: Prokop.ComponentName,
  key: UpdatesActionKey,
): ComponentActionButton {
  return {
    key,
    text: _('Check update'),
    icon: renderSearchIcon24,
    component,
    action: 'check_update',
  };
}

function getInstallAction(
  component: Prokop.ComponentName,
  key: UpdatesActionKey,
  installed: boolean,
): ComponentActionButton {
  return {
    key,
    text: installed ? _('Update') : _('Install'),
    icon: installed ? renderRotateCcwIcon24 : renderDownloadIcon24,
    component,
    action: 'install',
  };
}

function getInstalledUpdateActions(
  component: Prokop.ComponentName,
  checkKey: UpdatesActionKey,
  installKey: UpdatesActionKey,
  installed = true,
) {
  if (!installed) {
    return [];
  }

  const actions = [getCheckAction(component, checkKey)];
  if (shouldShowInstallAfterCheck(component)) {
    actions.push(getInstallAction(component, installKey, true));
  }
  return actions;
}

function getOptionalComponentActions({
  component,
  installed,
  checkKey,
  installKey,
  removeKey,
}: {
  component: 'zapret' | 'zapret2' | 'byedpi';
  installed: boolean;
  checkKey: UpdatesActionKey;
  installKey: UpdatesActionKey;
  removeKey: UpdatesActionKey;
}) {
  if (!installed) {
    return [getInstallAction(component, installKey, false)];
  }

  return [
    ...getInstalledUpdateActions(component, checkKey, installKey),
    {
      key: removeKey,
      text: _('Remove'),
      icon: renderXIcon24,
      component,
      action: 'remove' as const,
    },
  ];
}

function getComponentCards(): ComponentCard[] {
  const systemInfo = normalizeSingBoxVariantFields(
    store.get().diagnosticsSystemInfo,
  );
  const systemInfoLoading = isSystemInfoLoading();
  const zapretInstalled = Boolean(systemInfo.zapret_installed);
  const zapret2Installed = Boolean(systemInfo.zapret2_installed);
  const byedpiInstalled = Boolean(systemInfo.byedpi_installed);
  const zapretManagerInstalled = Boolean(systemInfo.zapret_manager_installed);
  const packetSteeringEnabled = systemInfo.packet_steering_mode === '2';
  const directProxyEnabled = Boolean(systemInfo.direct_proxy_enabled);
  const directProxyEndpoint = systemInfo.direct_proxy_address
    ? `${systemInfo.direct_proxy_address}:${systemInfo.direct_proxy_port || '2080'}`
    : '';
  const torrserverRunning = Boolean(systemInfo.torrserver_running);
  const torrserverInstalled = Boolean(systemInfo.torrserver_installed);
  const torrserverServiceRunning = Boolean(
    systemInfo.torrserver_service_running,
  );
  const torrserverForeign = Boolean(systemInfo.torrserver_foreign);
  const torrserverDirectAvailable = Boolean(
    systemInfo.torrserver_direct_available,
  );
  const torrserverDirectEnabled = Boolean(systemInfo.torrserver_direct_enabled);
  const torrserverDirectActive = Boolean(systemInfo.torrserver_direct_active);
  const singBoxExtended =
    Boolean(systemInfo.sing_box_extended) && !systemInfo.sing_box_compressed;
  const singBoxTiny = Boolean(systemInfo.sing_box_tiny);

  const prokopActions = getInstalledUpdateActions(
    'prokop',
    'prokopCheck',
    'prokopInstall',
  );
  const singBoxActions = getInstalledUpdateActions(
    'sing_box',
    'singBoxCheck',
    'singBoxInstall',
    singBoxTiny || singBoxExtended,
  );

  // Prokop exposes only the Tiny and Extended sing-box variants.
  if (!singBoxTiny) {
    singBoxActions.push({
      key: 'singBoxInstallTiny',
      text: _('Install Tiny build'),
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_tiny',
    });
  }
  if (!singBoxExtended) {
    singBoxActions.push({
      key: 'singBoxInstallExtended',
      text: _('Install Extended build'),
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_extended',
    });
  }

  const zapretActions = getOptionalComponentActions({
    component: 'zapret',
    installed: zapretInstalled,
    checkKey: 'zapretCheck',
    installKey: 'zapretInstall',
    removeKey: 'zapretRemove',
  });
  const zapret2Actions = getOptionalComponentActions({
    component: 'zapret2',
    installed: zapret2Installed,
    checkKey: 'zapret2Check',
    installKey: 'zapret2Install',
    removeKey: 'zapret2Remove',
  });
  const byedpiActions = getOptionalComponentActions({
    component: 'byedpi',
    installed: byedpiInstalled,
    checkKey: 'byedpiCheck',
    installKey: 'byedpiInstall',
    removeKey: 'byedpiRemove',
  });
  const zapretManagerActions: ComponentActionButton[] = zapretManagerInstalled
    ? [
        {
          key: 'zapretManagerRemove',
          text: _('Remove'),
          icon: renderXIcon24,
          component: 'zapret_manager',
          action: 'remove',
        },
      ]
    : [
        {
          key: 'zapretManagerInstall',
          text: _('Install'),
          icon: renderDownloadIcon24,
          component: 'zapret_manager',
          action: 'install',
        },
      ];

  const torrserverActions: ComponentActionButton[] = torrserverInstalled
    ? [
        ...(torrserverServiceRunning
          ? []
          : [
              {
                key: 'torrserverStart' as const,
                text: _('Start'),
                icon: renderRotateCcwIcon24,
                component: 'torrserver' as const,
                action: 'start' as const,
              },
            ]),
        ...getInstalledUpdateActions(
          'torrserver',
          'torrserverCheck',
          'torrserverInstall',
        ),
        {
          key: 'torrserverRemove',
          text: _('Remove'),
          icon: renderXIcon24,
          component: 'torrserver',
          action: 'remove',
        },
        ...(torrserverServiceRunning
          ? [
              {
                key: 'torrserverApplySettings' as const,
                text: _('Apply recommended settings'),
                icon: renderRotateCcwIcon24,
                component: 'torrserver' as const,
                action: 'apply_settings' as const,
              },
            ]
          : []),
      ]
    : [
        {
          ...getInstallAction('torrserver', 'torrserverInstall', false),
          disabled: torrserverForeign,
        },
      ];
  // TorrServer Direct (its traffic bypasses Prokop's routing) belongs to the
  // same card. Enable is offered only once a TorrServer runs: before that
  // there is nothing to mark. Disable stays reachable whatever TorrServer
  // does, so a setting that is on can always be turned off.
  // Nothing about it is shown while there is no TorrServer at all and the
  // setting is off.
  const torrserverDirectShown =
    torrserverDirectEnabled || torrserverInstalled || torrserverRunning;
  const torrserverDirectState = torrserverDirectEnabled
    ? torrserverDirectActive
      ? _('Direct routing is on')
      : _('Direct routing is on and waits for TorrServer')
    : _('Direct routing is off');
  const torrserverDirectActions: ComponentActionButton[] =
    torrserverDirectEnabled
      ? [
          {
            key: 'torrserverDirectDisable',
            text: _('Disable direct routing'),
            icon: renderXIcon24,
            component: 'torrserver_direct',
            action: 'disable',
          },
        ]
      : torrserverRunning
        ? [
            {
              key: 'torrserverDirectEnable',
              text: _('Enable direct routing'),
              icon: renderRotateCcwIcon24,
              component: 'torrserver_direct',
              action: 'enable',
              disabled: !torrserverDirectAvailable,
            },
          ]
        : [];
  const torrserverDirectNote =
    systemInfoLoading || torrserverDirectEnabled
      ? undefined
      : !torrserverRunning
        ? undefined
        : !torrserverDirectAvailable
          ? _(
              'TorrServer does not run in its own service group. Install TorrServer from Prokop to use direct routing for it.',
            )
          : undefined;
  const torrserverWebUrl =
    torrserverInstalled && torrserverServiceRunning
      ? `http://${window.location.hostname}:${systemInfo.torrserver_port || '8090'}`
      : '';

  return [
    {
      component: 'prokop',
      column: 0,
      title: 'Prokop',
      version: systemInfoLoading
        ? _('Loading...')
        : normalizeCompiledVersion(systemInfo.prokop_version),
      latestVersion: getLatestVersion('prokop'),
      releaseUrl: getGitHubReleaseUrl('prokop'),
      actions: prokopActions,
    },
    {
      component: 'sing_box',
      column: 0,
      title: 'Sing-box',
      version: systemInfoLoading
        ? _('Loading...')
        : formatSingBoxVersion(systemInfo),
      latestVersion: getLatestVersion('sing_box'),
      releaseUrl: getGitHubReleaseUrl('sing_box'),
      actions: singBoxActions,
    },
    {
      component: 'zapret',
      column: 1,
      title: 'Zapret',
      version: systemInfoLoading
        ? _('Loading...')
        : zapretInstalled
          ? systemInfo.zapret_version
          : _('Not installed'),
      latestVersion: getLatestVersion('zapret'),
      releaseUrl: getGitHubReleaseUrl('zapret'),
      actions: zapretActions,
    },
    {
      component: 'zapret2',
      column: 1,
      title: 'Zapret2',
      version: systemInfoLoading
        ? _('Loading...')
        : zapret2Installed
          ? systemInfo.zapret2_version
          : _('Not installed'),
      latestVersion: getLatestVersion('zapret2'),
      releaseUrl: getGitHubReleaseUrl('zapret2'),
      actions: zapret2Actions,
    },
    {
      component: 'byedpi',
      column: 1,
      title: 'ByeDPI',
      version: systemInfoLoading
        ? _('Loading...')
        : byedpiInstalled
          ? systemInfo.byedpi_version
          : _('Not installed'),
      latestVersion: getLatestVersion('byedpi'),
      releaseUrl: getGitHubReleaseUrl('byedpi'),
      actions: byedpiActions,
    },
    {
      component: 'zapret_manager',
      column: 1,
      title: 'Zapret-Manager-Stressozz',
      version: zapretManagerInstalled
        ? _('Installed (Mirror edition)')
        : _('Not installed'),
      latestVersion: '',
      releaseUrl: 'https://github.com/Screamshow/Zapret-Manager',
      actions: zapretManagerActions,
    },
    {
      component: 'packet_steering',
      column: 2,
      title: 'Packet Steering',
      version: packetSteeringEnabled ? _('Mode 2 enabled') : _('Normal mode'),
      actions: [
        packetSteeringEnabled
          ? {
              key: 'packetSteeringRestore',
              text: _('Restore normal mode'),
              icon: renderRotateCcwIcon24,
              component: 'packet_steering',
              action: 'restore',
            }
          : {
              key: 'packetSteeringEnable',
              text: _('Enable mode 2'),
              icon: renderRotateCcwIcon24,
              component: 'packet_steering',
              action: 'enable',
            },
      ],
    },
    {
      component: 'direct_proxy',
      column: 2,
      title: _('Direct Proxy'),
      version: directProxyEnabled
        ? `HTTP/SOCKS5 · ${directProxyEndpoint || _('Enabled')}`
        : _('Disabled'),
      copyValue: directProxyEnabled ? directProxyEndpoint : undefined,
      actions: [
        directProxyEnabled
          ? {
              key: 'directProxyDisable',
              text: _('Disable'),
              icon: renderXIcon24,
              component: 'direct_proxy',
              action: 'disable',
            }
          : {
              key: 'directProxyEnable',
              text: _('Enable'),
              icon: renderRotateCcwIcon24,
              component: 'direct_proxy',
              action: 'enable',
            },
      ],
    },
    {
      component: 'torrserver',
      column: 2,
      title: 'TorrServer',
      version: systemInfoLoading
        ? _('Loading...')
        : torrserverInstalled
          ? `${systemInfo.torrserver_version} · ${
              torrserverServiceRunning ? _('Running') : _('Stopped')
            }`
          : torrserverForeign
            ? _('Installed outside Prokop')
            : _('Not installed'),
      latestVersion: getLatestVersion('torrserver'),
      releaseUrl: 'https://github.com/YouROK/TorrServer/releases',
      actions: torrserverActions,
      note:
        !systemInfoLoading && !torrserverInstalled && torrserverForeign
          ? _(
              'Another TorrServer is installed or running on this router. Prokop does not replace it; remove it first to install TorrServer from Prokop.',
            )
          : undefined,
      link: torrserverWebUrl
        ? { href: torrserverWebUrl, text: _('Open TorrServer') }
        : undefined,
      details:
        systemInfoLoading || !torrserverDirectShown
          ? undefined
          : [torrserverDirectState],
      directNote: torrserverDirectNote,
      extraActions: torrserverDirectActions,
    },
  ];
}

function renderComponentCard(card: ComponentCard) {
  const updatesActions = store.get().updatesActions;
  const anyActionLoading = isAnyActionLoading();
  const serviceRuntimeActionLoading = isServiceRuntimeActionLoading();
  const systemInfoLoading = isSystemInfoLoading();

  // 1. Header (displays Title, Current Version, no badges)
  const headerChildren: Node[] = [
    E('b', { class: 'fkp_updates-page__component__title' }, asText(card.title)),
    E(
      'span',
      { class: 'fkp_updates-page__component__header-version' },
      asText(card.version),
    ),
  ];
  const header = E(
    'div',
    { class: 'fkp_updates-page__component__header' },
    headerChildren,
  );

  // 2. Details (renders status messages for check results)
  const detailsChildren: Node[] = [];
  const checkResult = getVisibleCheckResult(card.component);

  if (checkResult && checkResult.status) {
    let labelText = '';
    const latestValueNodes: Node[] = [];

    if (checkResult.status === 'outdated') {
      labelText = _('Update is available:');
      const versionToShow =
        checkResult.latest_version || card.latestVersion || card.version;

      if (checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'fkp_updates-page__component__release-version-link',
              href: checkResult.release_url,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            asText(versionToShow || _('Open')),
          ),
        );
      } else if (versionToShow) {
        latestValueNodes.push(document.createTextNode(versionToShow));
      }
    } else if (checkResult.status === 'latest') {
      labelText = _('Latest version is installed');
    } else if (checkResult.status === 'dev') {
      labelText = `${_('Installed version is newer than release')}. ${_('Latest version:')}`;
      const versionToShow = checkResult.latest_version || card.latestVersion;

      if (checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'fkp_updates-page__component__release-version-link',
              href: checkResult.release_url,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            asText(versionToShow || _('Open')),
          ),
        );
      } else if (versionToShow) {
        latestValueNodes.push(document.createTextNode(versionToShow));
      }
    }

    if (labelText) {
      const rowChildren: Node[] = [
        E(
          'span',
          { class: 'fkp_updates-page__component__info-label' },
          asText(labelText),
        ),
      ];
      if (latestValueNodes.length > 0) {
        rowChildren.push(
          E(
            'span',
            {
              class:
                'fkp_updates-page__component__info-value fkp_updates-page__component__info-value--latest',
            },
            latestValueNodes,
          ),
        );
      }

      detailsChildren.push(
        E(
          'div',
          { class: 'fkp_updates-page__component__info-row' },
          rowChildren,
        ),
      );
    }
  }

  if (card.note) {
    detailsChildren.push(
      E(
        'div',
        { class: 'fkp_updates-page__component__info-row' },
        E(
          'span',
          { class: 'fkp_updates-page__component__info-label' },
          asText(card.note),
        ),
      ),
    );
  }

  for (const row of card.details || []) {
    detailsChildren.push(
      E(
        'div',
        { class: 'fkp_updates-page__component__info-row' },
        E(
          'span',
          { class: 'fkp_updates-page__component__info-value' },
          asText(row),
        ),
      ),
    );
  }

  if (card.directNote) {
    detailsChildren.push(
      E(
        'div',
        { class: 'fkp_updates-page__component__info-row' },
        E(
          'span',
          { class: 'fkp_updates-page__component__info-label' },
          asText(card.directNote),
        ),
      ),
    );
  }

  if (card.link) {
    detailsChildren.push(
      E('div', { class: 'fkp_updates-page__component__info-row' }, [
        E(
          'a',
          {
            class: 'fkp_updates-page__component__release-version-link',
            href: card.link.href,
            target: '_blank',
            rel: 'noopener noreferrer',
          },
          asText(card.link.text),
        ),
      ]),
    );
  }

  const detailsContainer =
    detailsChildren.length > 0
      ? E(
          'div',
          { class: 'fkp_updates-page__component__details' },
          detailsChildren,
        )
      : null;

  // 3. The running or last action: its stages, download and time.
  // A card can carry another component's actions (TorrServer's direct
  // routing): their progress shows on it too.
  const updatesProgress = store.get().updatesProgress;
  const progressView =
    updatesProgress[card.component] ||
    card.actions
      .map((action) => updatesProgress[action.component])
      .find(Boolean);
  const progressPanel = progressView
    ? renderComponentProgress(progressView, {
        installed:
          progressView.component !== 'torrserver' ||
          Boolean(store.get().diagnosticsSystemInfo.torrserver_installed),
        onDismiss: () => dismissComponentProgress(progressView.component),
      })
    : null;

  // 4. Actions classification
  const primaryActions: ComponentActionButton[] = [];
  const dangerActions: ComponentActionButton[] = [];
  const variantActions: ComponentActionButton[] = [];

  card.actions.forEach((action) => {
    if (action.action === 'remove') {
      dangerActions.push(action);
    } else if (action.action.startsWith('install_')) {
      variantActions.push(action);
    } else {
      primaryActions.push(action);
    }
  });

  const actionElements: Node[] = [];

  // Render primary and danger buttons in a main row
  const primaryButtons = primaryActions.map((action) => {
    const loading = updatesActions[action.key].loading;
    const isUpdateOrInstall = action.action === 'install';

    return renderButton({
      classNames: isUpdateOrInstall ? ['cbi-button-save'] : [],
      text: action.text,
      icon: action.icon,
      loading,
      disabled:
        action.disabled ||
        systemInfoLoading ||
        serviceRuntimeActionLoading ||
        (anyActionLoading && !loading),
      onClick: () => void handleComponentAction(action),
    });
  });

  // Installing a specific release is a separate, deliberate action: the regular
  // install button always takes the newest one.
  if (card.component === 'prokop') {
    primaryButtons.push(
      renderButton({
        text: _('Choose version'),
        disabled:
          systemInfoLoading || serviceRuntimeActionLoading || anyActionLoading,
        onClick: () =>
          void showReleaseSelector(card.version, (version) => {
            void handleComponentAction({
              key: 'prokopInstall',
              text: _('Install'),
              icon: renderDownloadIcon24,
              component: 'prokop',
              action: 'install',
              version,
            });
          }),
      }),
    );
  }

  const dangerButtons = dangerActions.map((action) => {
    const loading = updatesActions[action.key].loading;

    return renderButton({
      classNames: ['cbi-button-remove'],
      text: action.text,
      icon: action.icon,
      loading,
      disabled:
        systemInfoLoading ||
        serviceRuntimeActionLoading ||
        (anyActionLoading && !loading),
      onClick: () => void handleComponentAction(action),
    });
  });

  if (primaryButtons.length > 0 || dangerButtons.length > 0) {
    actionElements.push(
      E('div', { class: 'fkp_updates-page__component__actions-main' }, [
        ...primaryButtons,
        ...dangerButtons,
      ]),
    );
  }

  if (card.extraActions && card.extraActions.length > 0) {
    actionElements.push(
      E(
        'div',
        { class: 'fkp_updates-page__component__actions-main' },
        card.extraActions.map((action) => {
          const loading = updatesActions[action.key].loading;
          return renderButton({
            text: action.text,
            icon: action.icon,
            loading,
            disabled:
              action.disabled ||
              systemInfoLoading ||
              serviceRuntimeActionLoading ||
              (anyActionLoading && !loading),
            onClick: () => void handleComponentAction(action),
          });
        }),
      ),
    );
  }

  if (card.copyValue) {
    actionElements.push(
      E('div', { class: 'fkp_updates-page__component__actions-main' }, [
        renderButton({
          text: _('Copy address'),
          icon: renderCopyIcon24,
          disabled: anyActionLoading || serviceRuntimeActionLoading,
          onClick: () => copyToClipboard(card.copyValue || ''),
        }),
      ]),
    );
  }

  // Render variant buttons if any
  if (variantActions.length > 0) {
    const variantButtons = variantActions.map((action) => {
      const loading = updatesActions[action.key].loading;
      return renderButton({
        text: action.text,
        icon: action.icon,
        loading,
        disabled:
          systemInfoLoading ||
          serviceRuntimeActionLoading ||
          (anyActionLoading && !loading),
        onClick: () => void handleComponentAction(action),
      });
    });

    actionElements.push(
      E('div', { class: 'fkp_updates-page__component__variants' }, [
        E(
          'div',
          { class: 'fkp_updates-page__component__variants-title' },
          _('Install another build:'),
        ),
        E(
          'div',
          { class: 'fkp_updates-page__component__variants-buttons' },
          variantButtons,
        ),
      ]),
    );
  }

  const actionsContainer = E(
    'div',
    {
      class: [
        'fkp_updates-page__component__actions',
        detailsContainer
          ? 'fkp_updates-page__component__actions--with-details'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    actionElements,
  );

  const cardChildren: Node[] = [header];
  if (detailsContainer) {
    cardChildren.push(detailsContainer);
  }
  cardChildren.push(actionsContainer);
  if (progressPanel) {
    cardChildren.push(progressPanel);
  }

  return E('div', { class: 'fkp_updates-page__component' }, cardChildren);
}

function renderUpdatesComponents() {
  const container = document.getElementById('fkp_updates-components');

  if (!container) {
    return;
  }

  const columns = [[], [], []] as Node[][];
  getComponentCards().forEach((card) => {
    columns[card.column].push(renderComponentCard(card));
  });
  columns[2].push(
    renderListsUpdate(
      isAnyActionLoading() || isServiceRuntimeActionLoading(),
      renderUpdatesComponents,
      () => updatesMounted,
    ),
  );
  columns[2].push(
    renderFullUninstall(
      isAnyActionLoading() || isServiceRuntimeActionLoading(),
    ),
  );

  return preserveScrollForPage(() => {
    container.replaceChildren(
      E('div', { class: 'fkp_updates-page__components-column' }, columns[0]),
      E('div', { class: 'fkp_updates-page__components-column' }, columns[1]),
      E('div', { class: 'fkp_updates-page__components-column' }, columns[2]),
    );
  });
}

function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (
    diff.diagnosticsSystemInfo ||
    diff.updatesActions ||
    diff.updatesChecks ||
    diff.updatesProgress ||
    diff.diagnosticsActions ||
    diff.servicesInfoWidget
  ) {
    renderUpdatesComponents();
  }
}

function applyComponentUpdateCheckCache(
  componentUpdateCheckCache: Prokop.ComponentUpdateCheckCache,
) {
  componentUpdateCheckCacheResolved = true;

  if (componentUpdateCheckCache.enabled) {
    store.reset(['updatesChecks']);
    applyCachedCheckResults(componentUpdateCheckCache.results);
  }

  if (
    shouldResetCheckResultsOnMount({
      anyActionLoading: isAnyActionLoading(),
      preserveCheckResultsOnNextMount,
      persistentCacheEnabled: componentUpdateCheckCache.enabled,
    })
  ) {
    store.reset(['updatesChecks']);
  }
}

async function onPageMount() {
  onPageUnmount();

  updatesMounted = true;
  updatesMountId += 1;
  const mountId = updatesMountId;
  const cachedRuntimeState = getCachedRuntimeUiState();
  const hasRuntimeSnapshot = Boolean(cachedRuntimeState);
  const needsFreshStateBeforeRender =
    shouldRefreshComponentStateBeforeRender(cachedRuntimeState);
  const runtimeStateRefreshPromise =
    !hasRuntimeSnapshot || needsFreshStateBeforeRender
      ? refreshRuntimeUiState({ force: true })
      : null;
  const prefetchedComponentUpdateCheckCache = componentUpdateCheckCacheSnapshot;

  if (prefetchedComponentUpdateCheckCache) {
    applyComponentUpdateCheckCache(prefetchedComponentUpdateCheckCache);
  }

  restoreSelfUpdateResult();
  renderUpdatesComponents();

  const componentUpdateCheckCache = await loadComponentUpdateCheckCache({
    force: Boolean(prefetchedComponentUpdateCheckCache),
  });

  if (!updatesMounted || mountId !== updatesMountId) {
    return;
  }

  applyComponentUpdateCheckCache(componentUpdateCheckCache);
  preserveCheckResultsOnNextMount = false;
  renderUpdatesComponents();

  if (runtimeStateRefreshPromise) {
    await runtimeStateRefreshPromise;

    if (!updatesMounted || mountId !== updatesMountId) {
      return;
    }
  }

  store.subscribe(onStoreUpdate);
  startComponentActionStateWatcher();
  renderUpdatesComponents();
  void ensureSystemInfo();
  void refreshListsUpdateStatus(renderUpdatesComponents, () => updatesMounted);
  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }
}

function onPageUnmount() {
  updatesMounted = false;
  updatesMountId += 1;
  stopComponentActionStateWatcher();
  stopListsUpdatePolling();
  store.unsubscribe(onStoreUpdate);
}

function registerLifecycleListeners() {
  if (updatesLifecycleRegistered) {
    return;
  }

  updatesLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      const isUpdatesVisible = next.tabService.current === 'updates';

      if (isUpdatesVisible) {
        return onPageMount();
      }

      if (updatesMounted) {
        return onPageUnmount();
      }
    }
  });
}

export function renderView(): HTMLElement {
  const root = render();
  renderOnAttach(root, {
    isMounted: () => updatesMounted,
    waitForAttach: onMount,
    renderComponents: renderUpdatesComponents,
  });
  return root;
}

export async function initController(): Promise<void> {
  if (updatesControllerInitialized) {
    return;
  }

  updatesControllerInitialized = true;
  void loadComponentUpdateCheckCache();

  onMount('updates-status').then(() => {
    logger.debug('[UPDATES]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (
      store.get().tabService.current === 'updates' ||
      isActiveLuciTab('updates')
    ) {
      onPageMount();
    }
  });
}
