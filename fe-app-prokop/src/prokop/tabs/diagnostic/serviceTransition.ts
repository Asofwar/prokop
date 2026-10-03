type LoadingActionState = {
  loading: boolean;
};

type DiagnosticServiceActions = {
  restart: LoadingActionState;
  start: LoadingActionState;
  stop: LoadingActionState;
  enable: LoadingActionState;
  disable: LoadingActionState;
};

type ComponentActions = Record<string, LoadingActionState>;

export function isServiceTransitionStatus(status: string) {
  return ['starting', 'stopping', 'restarting', 'reloading'].includes(status);
}

export function hasLocalMutatingServiceActionLoading(
  actions: DiagnosticServiceActions,
) {
  return (
    actions.restart.loading ||
    actions.start.loading ||
    actions.stop.loading ||
    actions.enable.loading ||
    actions.disable.loading
  );
}

export function shouldSkipServicesInfoAutoRefresh({
  force,
  localMutatingActionLoading,
}: {
  force: boolean;
  localMutatingActionLoading: boolean;
}) {
  return !force && localMutatingActionLoading;
}

export function shouldResetDiagnosticsChecks({
  resetChecks,
  diagnosticsRunLoading,
}: {
  resetChecks: boolean;
  diagnosticsRunLoading: boolean;
}) {
  return resetChecks && !diagnosticsRunLoading;
}

export function shouldDisableDiagnosticRunAction({
  providerInfoLoaded,
  servicesInfoLoading,
  prokopRunning,
  mutatingServiceActionLoading,
}: {
  providerInfoLoaded: boolean;
  servicesInfoLoading: boolean;
  prokopRunning: boolean;
  mutatingServiceActionLoading: boolean;
}) {
  return (
    !providerInfoLoaded ||
    servicesInfoLoading ||
    !prokopRunning ||
    mutatingServiceActionLoading
  );
}

export function hasComponentActionLoading(actions: ComponentActions) {
  return Object.values(actions).some((action) => action.loading);
}

export function getAvailableActionsDisabledState({
  servicesInfoLoading,
  mutatingServiceActionLoading,
  componentActionLoading,
}: {
  servicesInfoLoading: boolean;
  mutatingServiceActionLoading: boolean;
  componentActionLoading: boolean;
}) {
  return {
    serviceControlsDisabled:
      servicesInfoLoading ||
      mutatingServiceActionLoading ||
      componentActionLoading,
    utilityActionsDisabled:
      mutatingServiceActionLoading || componentActionLoading,
    viewLogsDisabled: false,
  };
}

export function shouldShowRestartAction({
  prokopRunning,
  restartBlocked = false,
  restartLoading,
  startLoading,
  stopLoading,
}: {
  prokopRunning: boolean;
  restartBlocked?: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopLoading: boolean;
}) {
  // A restart cannot prove which sing-box it would be replacing, so it is
  // withheld until the runtime has been stopped outright.
  return (
    restartLoading ||
    (prokopRunning && !restartBlocked && !startLoading && !stopLoading)
  );
}

export function shouldShowStartAction({
  prokopRunning,
  restartLoading,
  startLoading,
  stopAvailable = false,
  stopLoading,
}: {
  prokopRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopAvailable?: boolean;
  stopLoading: boolean;
}) {
  return (
    startLoading ||
    (!restartLoading && !prokopRunning && !stopAvailable && !stopLoading)
  );
}

export function shouldShowStopAction({
  prokopRunning,
  restartLoading,
  startLoading,
  stopAvailable = false,
  stopLoading,
}: {
  prokopRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopAvailable?: boolean;
  stopLoading: boolean;
}) {
  // Traffic may still be intercepted while Prokop reports unhealthy. Stop is
  // the way out of that state, so it stays reachable.
  return (
    stopLoading ||
    restartLoading ||
    ((prokopRunning || stopAvailable) && !startLoading)
  );
}
