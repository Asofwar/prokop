import { ProkopShellMethods } from '../../methods';
import { confirmAction } from '../../ui/confirmAction';
import { refreshRuntimeUiState } from '../../services/runtimeUiState.service';
import { store } from '../../services/store.service';

export type ProkopServiceAction = 'start' | 'restart' | 'stop';

// Runs a service action through the same job as Diagnostics; pages follow
// the resulting state through the runtime UI state poller.
export async function runProkopServiceAction(action: ProkopServiceAction) {
  const start = await ProkopShellMethods.serviceActionStart(action);
  if (!start.success) {
    throw new Error(start.error);
  }

  const jobId = start.data.job_id;
  try {
    const result = await ProkopShellMethods.waitServiceActionJob(jobId);
    if (!result.success) {
      throw new Error(result.error);
    }
    if (result.data.success === false) {
      throw new Error(result.data.message || '');
    }
  } finally {
    void ProkopShellMethods.uiActionAck('service', jobId);
  }
}

export function confirmStopProkop() {
  return confirmAction({
    title: _('Stop Prokop?'),
    message: _('Prokop stops handling traffic until it is started again.'),
    consequences: [
      _('Routing, DNS and DPI bypass rules stop applying'),
      _('Devices keep using the router without Prokop'),
    ],
    confirmLabel: _('Stop'),
    danger: true,
  });
}

// init.d enable/disable print nothing, so the result is judged by the
// autostart state read back afterwards. Resolves to that state.
export async function setProkopAutostart(enabled: boolean) {
  try {
    await (enabled
      ? ProkopShellMethods.enable()
      : ProkopShellMethods.disable());
  } finally {
    await refreshRuntimeUiState({ force: true });
  }

  return Boolean(store.get().servicesInfoWidget.data.prokopEnabled);
}
