import { callBaseMethod } from './callBaseMethod';
import { ClashAPI, Prokop } from '../../types';
import { executeShellCommand } from '../../../helpers';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';
import { failureReason } from '../../helpers/actionReason';
import { observeRouterTime } from '../../helpers/routerClock';

const SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS = 15000;
const SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS = 1500;
const UI_ACTION_RPC_TIMEOUT_MS = 15000;
const UI_ACTION_TRANSIENT_RPC_GRACE_MS = 30000;
const SERVICE_ACTION_TIMEOUT_MS = 2 * 60 * 1000;
const SERVICE_ACTION_POLL_INTERVAL_MS = 1000;
const LATENCY_TEST_TIMEOUT_MS = 30 * 1000;
const LATENCY_TEST_POLL_INTERVAL_MS = 1000;
const COMPONENT_ACTION_RPC_TIMEOUT_MS = 15000;
const COMPONENT_ACTION_POLL_INTERVAL_MS = 1500;
const COMPONENT_ACTION_STATUS_REFRESH_INTERVAL_MS = 15000;
const COMPONENT_ACTION_SELF_UPDATE_SETTLE_MS = 30000;
const COMPONENT_ACTION_TRANSIENT_RPC_GRACE_MS = 30000;
const COMPONENT_ACTION_STATE_DIR = '/var/run/prokop/component-actions';
const GET_UI_STATE_RPC_TIMEOUT_MS = 3000;
const SUPPORT_REPORT_RPC_TIMEOUT_MS = 60000;
// Up to 16 targets, one DNS lookup (2 s timeout) each.
const AUTOTUNE_GROUPS_RPC_TIMEOUT_MS = 45000;

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function parseJsonObjectOutput<T>(output: string): T | null {
  if (!output) {
    return null;
  }

  try {
    return JSON.parse(output) as T;
  } catch (_error) {
    const jsonMatch = output.match(/(\{[\s\S]*\})\s*$/);

    if (!jsonMatch) {
      return null;
    }

    try {
      return JSON.parse(jsonMatch[1]) as T;
    } catch (_jsonError) {
      return null;
    }
  }
}

function parseComponentActionOutput(output: string) {
  return parseJsonObjectOutput<Prokop.ComponentActionResult>(output);
}

function parseComponentActionResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseComponentActionOutput(response.stdout);
}

function parseComponentActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  const parsedResponse = parseComponentActionResult(response);

  if (!parsedResponse) {
    return null;
  }

  return parsedResponse as unknown as Prokop.ComponentActionStartResult;
}

function parseSubscriptionUpdateStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Prokop.SubscriptionUpdateStartResult>(
    response.stdout,
  );
}

function parseSubscriptionUpdateJobState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Prokop.SubscriptionUpdateJobState>(
    response.stdout,
  );
}

function parseUiActionStartResult(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Prokop.UiActionStartResult>(response.stdout);
}

function parseServiceActionState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Prokop.ServiceActionState>(response.stdout);
}

function parseLatencyActionState(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
) {
  return parseJsonObjectOutput<Prokop.LatencyActionState>(response.stdout);
}

function isComponentActionJobId(jobId: string) {
  return /^[A-Za-z0-9._-]+$/.test(jobId) && jobId !== '.' && jobId !== '..';
}

async function readComponentActionState(jobId: string) {
  if (!isComponentActionJobId(jobId)) {
    return null;
  }

  try {
    return parseComponentActionOutput(
      await fs.read(`${COMPONENT_ACTION_STATE_DIR}/${jobId}.json`),
    );
  } catch (_error) {
    return null;
  }
}

async function readProkopVersion() {
  const response = await executeShellCommand({
    command: '/usr/bin/prokop',
    args: ['show_version'],
    timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
  });

  if ((response.code ?? 0) !== 0 || !response.stdout) {
    return '';
  }

  return response.stdout.trim();
}

async function isComponentActionStillRunning(
  jobId: string,
  component: Prokop.ComponentName,
  action: Prokop.ComponentAction,
) {
  const response = await callBaseMethod<Prokop.UiState>(
    Prokop.AvailableMethods.GET_UI_STATE,
    [],
    '/usr/bin/prokop',
    { timeout: GET_UI_STATE_RPC_TIMEOUT_MS },
  );

  return (
    response.success &&
    response.data.actions.component.some(
      (state) =>
        state.job_id === jobId &&
        state.component === component &&
        state.action === action &&
        state.running === true,
    )
  );
}

// A refusal or failure keeps the backend's stable reason (UC-119) next to
// its English text; a backend without reasons gets one from that text.
function actionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse: { message?: string; reason?: string } | null | undefined,
  fallback: string,
) {
  const error = parsedResponse?.message || response.stderr || fallback;
  const reason = failureReason({
    reason: parsedResponse?.reason,
    error: parsedResponse?.message || response.stderr,
  });

  return {
    success: false,
    error,
    ...(reason ? { reason } : {}),
  } as Prokop.MethodFailureResponse;
}

function componentActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: Pick<
    Prokop.ComponentActionResult,
    'message' | 'reason'
  > | null,
) {
  return actionFailure(response, parsedResponse, _('Failed to execute'));
}

function uiActionFailure(
  response: Awaited<ReturnType<typeof executeShellCommand>>,
  parsedResponse?: { message?: string; reason?: string } | null,
  fallback: string = _('Failed to execute'),
) {
  return actionFailure(response, parsedResponse, fallback);
}

function createTransientRpcGraceTracker(graceMs: number) {
  let failureStartedAt = 0;

  return {
    reset() {
      failureStartedAt = 0;
    },
    shouldContinue(error?: string) {
      if (!isTransientRpcError(error)) {
        failureStartedAt = 0;
        return false;
      }

      if (!failureStartedAt) {
        failureStartedAt = Date.now();
      }

      return Date.now() - failureStartedAt < graceMs;
    },
  };
}

export const ProkopShellMethods = {
  checkDNSAvailable: async () =>
    callBaseMethod<Prokop.DnsCheckResult>(
      Prokop.AvailableMethods.CHECK_DNS_AVAILABLE,
    ),
  checkFakeIP: async () =>
    callBaseMethod<Prokop.FakeIPCheckResult>(
      Prokop.AvailableMethods.CHECK_FAKEIP,
    ),
  checkNftRules: async () =>
    callBaseMethod<Prokop.NftRulesCheckResult>(
      Prokop.AvailableMethods.CHECK_NFT_RULES,
    ),
  checkZapretRuntime: async () =>
    callBaseMethod<Prokop.ZapretCheckResult>(
      Prokop.AvailableMethods.CHECK_ZAPRET_RUNTIME,
    ),
  checkZapret2Runtime: async () =>
    callBaseMethod<Prokop.Zapret2CheckResult>(
      Prokop.AvailableMethods.CHECK_ZAPRET2_RUNTIME,
    ),
  checkByedpiRuntime: async () =>
    callBaseMethod<Prokop.ByedpiCheckResult>(
      Prokop.AvailableMethods.CHECK_BYEDPI_RUNTIME,
    ),
  getStatus: async () =>
    callBaseMethod<Prokop.GetStatus>(Prokop.AvailableMethods.GET_STATUS),
  getReadonlyConfigSections: async () =>
    callBaseMethod<Prokop.ConfigSection[]>(
      Prokop.AvailableMethods.GET_READONLY_CONFIG_SECTIONS,
    ),
  getDashboardRuntimeMetadata: async () =>
    callBaseMethod<{
      urltestGroups: Record<string, unknown>;
      clashControllerHosts?: unknown;
    }>(Prokop.AvailableMethods.GET_DASHBOARD_RUNTIME_METADATA),
  checkSingBox: async () =>
    callBaseMethod<Prokop.SingBoxCheckResult>(
      Prokop.AvailableMethods.CHECK_SING_BOX,
    ),
  getSingBoxStatus: async () =>
    callBaseMethod<Prokop.GetSingBoxStatus>(
      Prokop.AvailableMethods.GET_SING_BOX_STATUS,
    ),
  getZapretStatus: async () =>
    callBaseMethod<Prokop.GetZapretStatus>(
      Prokop.AvailableMethods.GET_ZAPRET_STATUS,
    ),
  getZapret2Status: async () =>
    callBaseMethod<Prokop.GetZapret2Status>(
      Prokop.AvailableMethods.GET_ZAPRET2_STATUS,
    ),
  getByedpiStatus: async () =>
    callBaseMethod<Prokop.GetByedpiStatus>(
      Prokop.AvailableMethods.GET_BYEDPI_STATUS,
    ),
  getClashApiProxies: async () =>
    callBaseMethod<ClashAPI.Proxies>(Prokop.AvailableMethods.CLASH_API, [
      Prokop.AvailableClashAPIMethods.GET_PROXIES,
    ]),
  getClashApiConnections: async () =>
    callBaseMethod<unknown>(Prokop.AvailableMethods.CLASH_API, [
      Prokop.AvailableClashAPIMethods.GET_CONNECTIONS,
    ]),
  getClashApiProxyLatency: async (tag: string, timeout = '5000') =>
    callBaseMethod<Prokop.GetClashApiProxyLatency>(
      Prokop.AvailableMethods.CLASH_API,
      [Prokop.AvailableClashAPIMethods.GET_PROXY_LATENCY, tag, timeout],
    ),
  getClashApiGroupLatency: async (tag: string) =>
    callBaseMethod<Prokop.GetClashApiGroupLatency>(
      Prokop.AvailableMethods.CLASH_API,
      [Prokop.AvailableClashAPIMethods.GET_GROUP_LATENCY, tag, '10000'],
    ),
  setClashApiGroupProxy: async (group: string, proxy: string) =>
    callBaseMethod<unknown>(Prokop.AvailableMethods.CLASH_API, [
      Prokop.AvailableClashAPIMethods.SET_GROUP_PROXY,
      group,
      proxy,
    ]),
  closeClashApiConnection: async (connectionId: string) =>
    callBaseMethod<unknown>(Prokop.AvailableMethods.CLASH_API, [
      Prokop.AvailableClashAPIMethods.CLOSE_CONNECTION,
      connectionId,
    ]),
  closeAllClashApiConnections: async () =>
    callBaseMethod<unknown>(Prokop.AvailableMethods.CLASH_API, [
      Prokop.AvailableClashAPIMethods.CLOSE_ALL_CONNECTIONS,
    ]),
  enable: async () =>
    callBaseMethod<unknown>(
      Prokop.AvailableMethods.ENABLE,
      [],
      '/etc/init.d/prokop',
    ),
  disable: async () =>
    callBaseMethod<unknown>(
      Prokop.AvailableMethods.DISABLE,
      [],
      '/etc/init.d/prokop',
    ),
  globalCheck: async (masked = true) =>
    callBaseMethod<unknown>(Prokop.AvailableMethods.GLOBAL_CHECK, [
      masked ? 'masked' : 'raw',
    ]),
  supportReport: async () =>
    callBaseMethod<unknown>(
      Prokop.AvailableMethods.SUPPORT_REPORT,
      [],
      '/usr/bin/prokop',
      { timeout: SUPPORT_REPORT_RPC_TIMEOUT_MS },
    ),
  showSingBoxConfig: async (masked = true) =>
    callBaseMethod<unknown>(Prokop.AvailableMethods.SHOW_SING_BOX_CONFIG, [
      masked ? 'masked' : 'raw',
    ]),
  checkLogs: async () =>
    callBaseMethod<unknown>(Prokop.AvailableMethods.CHECK_LOGS),
  getSystemInfo: async () =>
    callBaseMethod<Prokop.GetSystemInfo>(
      Prokop.AvailableMethods.GET_SYSTEM_INFO,
    ),
  getUiCapabilities: async () =>
    callBaseMethod<Prokop.GetUiCapabilities>(
      Prokop.AvailableMethods.GET_UI_CAPABILITIES,
    ),
  getUiState: async () =>
    callBaseMethod<Prokop.UiState>(
      Prokop.AvailableMethods.GET_UI_STATE,
      [],
      '/usr/bin/prokop',
      { timeout: GET_UI_STATE_RPC_TIMEOUT_MS, shared: true },
    ),
  getHealthStatus: async () =>
    callBaseMethod<Prokop.HealthStatus>(
      Prokop.AvailableMethods.GET_HEALTH_STATUS,
    ),
  getHistory: async () =>
    callBaseMethod<Prokop.HistoryResult>(Prokop.AvailableMethods.GET_HISTORY),
  // Autotune commands exit non-zero with a structured result (failed,
  // refused, busy); keep it instead of a bare failure.
  autotuneStatus: async () =>
    callBaseMethod<Prokop.AutotuneStatus>(
      Prokop.AvailableMethods.AUTOTUNE_STATUS,
      [],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  // Resolves every target through the router DNS.
  autotuneGroups: async () =>
    callBaseMethod<Prokop.AutotuneGroups>(
      Prokop.AvailableMethods.AUTOTUNE_GROUPS,
      [],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true, timeout: AUTOTUNE_GROUPS_RPC_TIMEOUT_MS },
    ),
  autotunePolicySet: async (option: string, value: string) =>
    callBaseMethod<Prokop.AutotuneMutationResult>(
      Prokop.AvailableMethods.AUTOTUNE_POLICY_SET,
      [option, value],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  // A host target, or with an empty host a rule-list target: the sing-box
  // rule set tag, how many domains are measured, pinned domains.
  autotuneTargetSet: async (
    id: string,
    host: string,
    enabled: boolean,
    resolver: string,
    list?: { ruleSet: string; sample: string; pins: string[] },
  ) =>
    callBaseMethod<Prokop.AutotuneMutationResult>(
      Prokop.AvailableMethods.AUTOTUNE_TARGET_SET,
      [
        id,
        host,
        enabled ? '1' : '0',
        resolver,
        ...(list ? [list.ruleSet, list.sample, list.pins.join(',')] : []),
      ],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  autotuneListDomains: async (ruleSet: string) =>
    callBaseMethod<Prokop.AutotuneListDomains>(
      Prokop.AvailableMethods.AUTOTUNE_LIST_DOMAINS,
      [ruleSet],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  autotuneTargetRemove: async (id: string) =>
    callBaseMethod<Prokop.AutotuneMutationResult>(
      Prokop.AvailableMethods.AUTOTUNE_TARGET_REMOVE,
      [id],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  autotuneRunAsync: async (scope: string) =>
    callBaseMethod<Prokop.AutotuneMutationResult>(
      Prokop.AvailableMethods.AUTOTUNE_RUN_ASYNC,
      [scope],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  // Only the group is sent: the backend derives the candidate itself.
  autotuneApplyAsync: async (group: string) =>
    callBaseMethod<Prokop.AutotuneMutationResult>(
      Prokop.AvailableMethods.AUTOTUNE_APPLY_ASYNC,
      [group],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  // Restores the snapshot taken before the apply and reloads the service,
  // like a snapshot restore.
  autotuneRollback: async () =>
    callBaseMethod<Prokop.AutotuneRollbackResult>(
      Prokop.AvailableMethods.AUTOTUNE_ROLLBACK,
      [],
      '/usr/bin/prokop',
      { timeout: 120000, allowNonZeroWithStdout: true },
    ),
  autotuneRunStatus: async (job: string) =>
    callBaseMethod<Prokop.AutotuneJobStatus>(
      Prokop.AvailableMethods.AUTOTUNE_RUN_STATUS,
      [job],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  getDeviceTraffic: async () =>
    callBaseMethod<Prokop.DeviceTraffic>(
      Prokop.AvailableMethods.DEVICE_TRAFFIC,
    ),
  routeTrace: async (
    target: string,
    source: string,
    protocol: string,
    port: string,
  ) =>
    // An invalid target exits non-zero with {"error":"invalid_input"}.
    callBaseMethod<Prokop.RouteTrace>(
      Prokop.AvailableMethods.ROUTE_TRACE,
      [target, source, protocol, port],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  // Snapshot mutations print a structured result (busy, failed, ...) even
  // when they exit non-zero; keep it instead of a bare failure.
  // before-apply: Save & Apply's snapshot of the configuration before the
  // change (UC-067).
  snapshotCreate: async (
    kind: 'manual' | 'automatic' | 'before-apply' = 'manual',
  ) =>
    callBaseMethod<Prokop.SnapshotResult>(
      Prokop.AvailableMethods.CONFIG_SNAPSHOT_CREATE,
      [kind],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  snapshotList: async () =>
    callBaseMethod<Prokop.SnapshotMetadata[]>(
      Prokop.AvailableMethods.CONFIG_SNAPSHOT_LIST,
    ),
  snapshotDiff: async (id: string) =>
    callBaseMethod<Prokop.SnapshotDiffEntry[]>(
      Prokop.AvailableMethods.CONFIG_SNAPSHOT_DIFF,
      [id],
    ),
  snapshotRestore: async (id: string) =>
    callBaseMethod<Prokop.SnapshotResult>(
      Prokop.AvailableMethods.CONFIG_SNAPSHOT_RESTORE,
      [id],
      '/usr/bin/prokop',
      { timeout: 120000, allowNonZeroWithStdout: true },
    ),
  snapshotDelete: async (id: string) =>
    callBaseMethod<Prokop.SnapshotResult>(
      Prokop.AvailableMethods.CONFIG_SNAPSHOT_DELETE,
      [id],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true },
    ),
  connectivityTest: async (host: string, type: string, port: string) =>
    callBaseMethod<Prokop.ConnectivityResult>(
      Prokop.AvailableMethods.CONNECTIVITY_TEST,
      [host, type, port],
      '/usr/bin/prokop',
      { allowNonZeroWithStdout: true, timeout: 10000 },
    ),
  validateDpiStrategy: async (
    provider: 'zapret' | 'zapret2' | 'byedpi',
    strategy: string,
  ) =>
    callBaseMethod<unknown>(
      provider === 'zapret'
        ? Prokop.AvailableMethods.VALIDATE_NFQWS_STRATEGY_JSON
        : provider === 'zapret2'
          ? Prokop.AvailableMethods.VALIDATE_NFQWS2_STRATEGY_JSON
          : Prokop.AvailableMethods.VALIDATE_BYEDPI_STRATEGY_JSON,
      [strategy],
    ),
  serviceActionStart: async (action: Prokop.ServiceAction) => {
    const response = await executeShellCommand({
      command: '/usr/bin/prokop',
      args: [Prokop.AvailableMethods.SERVICE_ACTION_ASYNC, action],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Service action failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Prokop.MethodSuccessResponse<Prokop.UiActionStartResult>;
  },
  saveUrlTestOverride: async (
    section: string,
    tag: string,
    url: string,
    interval: string,
    tolerance: string,
    idleTimeout: string,
    interrupt: boolean,
  ) =>
    executeShellCommand({
      command: '/usr/bin/prokop',
      args: [
        'urltest_override_save',
        section,
        tag,
        url,
        interval,
        tolerance,
        idleTimeout,
        interrupt ? '1' : '0',
      ],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    }),
  resetUrlTestOverride: async (section: string, tag: string) =>
    executeShellCommand({
      command: '/usr/bin/prokop',
      args: ['urltest_override_reset', section, tag],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    }),
  serviceActionStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/prokop',
      args: [Prokop.AvailableMethods.SERVICE_ACTION_STATUS, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseServiceActionState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Service action failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Prokop.MethodSuccessResponse<Prokop.ServiceActionState>;
  },
  // A lost RPC reply while the job runs is no failure, and a job still
  // running at the bound is not confirmed rather than failed (UC-120).
  waitServiceActionJob: async (jobId: string, startedAt = Date.now()) => {
    const transientRpc = createTransientRpcGraceTracker(
      UI_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (Date.now() - startedAt < SERVICE_ACTION_TIMEOUT_MS) {
      await sleep(SERVICE_ACTION_POLL_INTERVAL_MS);

      const response = await ProkopShellMethods.serviceActionStatus(jobId);

      if (!response.success) {
        if (transientRpc.shouldContinue(response.error)) {
          continue;
        }

        return response;
      }

      transientRpc.reset();
      if (response.data.running) {
        continue;
      }

      return response;
    }

    return {
      success: false,
      error: _('Operation timed out'),
      reason: 'timeout',
    } as Prokop.MethodFailureResponse;
  },
  latencyTestStart: async (
    latencyType: Prokop.LatencyActionState['latency_type'],
    section: string,
    tag: string,
    timeout?: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/prokop',
      args: [
        Prokop.AvailableMethods.LATENCY_TEST_ASYNC,
        latencyType,
        section,
        tag,
        ...(timeout ? [timeout] : []),
      ],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Latency test failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Prokop.MethodSuccessResponse<Prokop.UiActionStartResult>;
  },
  latencyTestStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/prokop',
      args: [Prokop.AvailableMethods.LATENCY_TEST_STATUS, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseLatencyActionState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Latency test failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Prokop.MethodSuccessResponse<Prokop.LatencyActionState>;
  },
  waitLatencyTestJob: async (jobId: string, startedAt = Date.now()) => {
    const transientRpc = createTransientRpcGraceTracker(
      UI_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (Date.now() - startedAt < LATENCY_TEST_TIMEOUT_MS) {
      await sleep(LATENCY_TEST_POLL_INTERVAL_MS);

      const response = await ProkopShellMethods.latencyTestStatus(jobId);

      if (!response.success) {
        if (transientRpc.shouldContinue(response.error)) {
          continue;
        }

        return response;
      }

      transientRpc.reset();
      if (response.data.running) {
        continue;
      }

      return response;
    }

    // Still running at the bound: not confirmed in time, not failed (UC-119).
    return {
      success: false,
      error: _('Operation timed out'),
      reason: 'timeout',
    } as Prokop.MethodFailureResponse;
  },
  uiActionAck: async (
    kind: 'service' | 'latency' | 'component' | 'subscription',
    jobId: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/prokop',
      args: [Prokop.AvailableMethods.UI_ACTION_ACK, kind, jobId],
      timeout: UI_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseUiActionStartResult(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse?.success) {
      return uiActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Prokop.MethodSuccessResponse<Prokop.UiActionStartResult>;
  },
  componentActionStart: async (
    component: Prokop.ComponentName,
    action: Prokop.ComponentAction,
    version?: string,
  ) => {
    const response = await executeShellCommand({
      command: '/usr/bin/prokop',
      args: [
        Prokop.AvailableMethods.COMPONENT_ACTION_ASYNC,
        component,
        action,
        ...(version ? [version] : []),
      ],
      timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseComponentActionStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return componentActionFailure(response, parsedResponse);
    }

    return {
      success: true,
      data: parsedResponse,
    } as Prokop.MethodSuccessResponse<Prokop.ComponentActionStartResult>;
  },
  getListUpdateStatus: async () =>
    callBaseMethod<Prokop.ListUpdateStatus>(
      Prokop.AvailableMethods.GET_LIST_UPDATE_STATUS,
    ),
  listUpdateStart: async () =>
    callBaseMethod<Prokop.ListUpdateStartResult>(
      Prokop.AvailableMethods.LIST_UPDATE_ASYNC,
    ),
  componentUpdateCheckCache: async () =>
    callBaseMethod<Prokop.ComponentUpdateCheckCache>(
      Prokop.AvailableMethods.COMPONENT_UPDATE_CHECK_CACHE,
    ),
  waitComponentActionJob: async (
    jobId: string,
    component: Prokop.ComponentName,
    action: Prokop.ComponentAction,
    expectedLatestVersion?: string,
  ) => {
    let selfUpdateVersionMatchedAt = 0;
    let lastStatusRefreshAt = 0;
    const transientRpc = createTransientRpcGraceTracker(
      COMPONENT_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (true) {
      await sleep(COMPONENT_ACTION_POLL_INTERVAL_MS);

      const stateResponse = await readComponentActionState(jobId);

      if (stateResponse) {
        if (!stateResponse.running) {
          transientRpc.reset();
          return {
            success: true,
            data: stateResponse,
          } as Prokop.MethodSuccessResponse<Prokop.ComponentActionResult>;
        }

        if (
          Date.now() - lastStatusRefreshAt <
          COMPONENT_ACTION_STATUS_REFRESH_INTERVAL_MS
        ) {
          continue;
        }
      }

      lastStatusRefreshAt = Date.now();
      const statusResponse = await executeShellCommand({
        command: '/usr/bin/prokop',
        args: [Prokop.AvailableMethods.COMPONENT_ACTION_STATUS, jobId],
        timeout: COMPONENT_ACTION_RPC_TIMEOUT_MS,
      });
      const parsedResponse = parseComponentActionResult(statusResponse);
      // The router's clock, for the elapsed time on the component's card.
      observeRouterTime(parsedResponse?.now);

      if ((statusResponse.code ?? 0) !== 0 || !parsedResponse) {
        if (stateResponse?.running) {
          transientRpc.reset();
          continue;
        }

        if (await isComponentActionStillRunning(jobId, component, action)) {
          transientRpc.reset();
          continue;
        }

        const failure = componentActionFailure(statusResponse, parsedResponse);

        if (transientRpc.shouldContinue(failure.error)) {
          continue;
        }

        if (component === 'prokop' && action === 'install') {
          const installedVersion = expectedLatestVersion
            ? await readProkopVersion()
            : '';

          if (
            expectedLatestVersion &&
            installedVersion === expectedLatestVersion
          ) {
            if (!selfUpdateVersionMatchedAt) {
              selfUpdateVersionMatchedAt = Date.now();
            }

            if (
              Date.now() - selfUpdateVersionMatchedAt >=
              COMPONENT_ACTION_SELF_UPDATE_SETTLE_MS
            ) {
              return {
                success: true,
                data: {
                  success: true,
                  component,
                  action,
                  message: _('Prokop has been installed'),
                  current_version: installedVersion,
                  latest_version: expectedLatestVersion,
                  changed: true,
                  status: 'latest',
                },
              } as Prokop.MethodSuccessResponse<Prokop.ComponentActionResult>;
            }
          }

          continue;
        }

        return failure;
      }

      transientRpc.reset();
      if (parsedResponse.running) {
        continue;
      }

      return {
        success: true,
        data: parsedResponse,
      } as Prokop.MethodSuccessResponse<Prokop.ComponentActionResult>;
    }
  },
  subscriptionUpdateStart: async (section?: string, sourceIndex?: number) => {
    const startArgs = [
      Prokop.AvailableMethods.SUBSCRIPTION_UPDATE_ASYNC,
      ...(section ? [section] : []),
      ...(section && sourceIndex !== undefined ? [String(sourceIndex)] : []),
    ];
    const response = await executeShellCommand({
      command: '/usr/bin/prokop',
      args: startArgs,
      timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseSubscriptionUpdateStartResult(response);

    if (
      (response.code ?? 0) !== 0 ||
      !parsedResponse?.success ||
      !parsedResponse.job_id
    ) {
      return uiActionFailure(
        response,
        parsedResponse,
        _('Subscription update failed'),
      );
    }

    return {
      success: true,
      data: parsedResponse,
    } as Prokop.MethodSuccessResponse<Prokop.SubscriptionUpdateStartResult>;
  },
  subscriptionUpdateStatus: async (jobId: string) => {
    const response = await executeShellCommand({
      command: '/usr/bin/prokop',
      args: [Prokop.AvailableMethods.SUBSCRIPTION_UPDATE_STATUS, jobId],
      timeout: SUBSCRIPTION_UPDATE_RPC_TIMEOUT_MS,
    });
    const parsedResponse = parseSubscriptionUpdateJobState(response);

    if ((response.code ?? 0) !== 0 || !parsedResponse) {
      return {
        success: false,
        error: response.stderr || _('Subscription update failed'),
      } as Prokop.MethodFailureResponse;
    }

    return {
      success: true,
      data: parsedResponse,
    } as Prokop.MethodSuccessResponse<Prokop.SubscriptionUpdateJobState>;
  },
  waitSubscriptionUpdateJob: async (jobId: string) => {
    const transientRpc = createTransientRpcGraceTracker(
      UI_ACTION_TRANSIENT_RPC_GRACE_MS,
    );

    while (true) {
      await sleep(SUBSCRIPTION_UPDATE_POLL_INTERVAL_MS);

      const response = await ProkopShellMethods.subscriptionUpdateStatus(jobId);

      if (!response.success) {
        if (transientRpc.shouldContinue(response.error)) {
          continue;
        }

        return response;
      }

      transientRpc.reset();
      if (response.data.running) {
        continue;
      }

      return response;
    }
  },
};
