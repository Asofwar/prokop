import { readPageParams } from '../../helpers/navigation';
import { setProkopPage } from '../../services/tab.service';

// Monitoring has three views: live connections, traffic per device
// (monitoring#view=devices) and node selection (monitoring#view=nodes).
// Node selection is run by the dashboard controller, so switching to it
// switches the active controller; devices stay with the monitoring one.
export type MonitoringView = 'connections' | 'devices' | 'nodes';

const VIEWS: MonitoringView[] = ['connections', 'devices', 'nodes'];

export function readMonitoringView(hash?: string): MonitoringView {
  const view = readPageParams(hash).view as MonitoringView;
  return VIEWS.includes(view) ? view : 'connections';
}

let viewListener: ((view: MonitoringView) => void) | null = null;

// The monitoring controller follows switches between its own two views.
export function onMonitoringViewChange(
  listener: ((view: MonitoringView) => void) | null,
) {
  viewListener = listener;
}

export function controllerForView(view: MonitoringView) {
  return view === 'nodes' ? 'dashboard' : 'monitoring';
}

export function showMonitoringView(view: MonitoringView, updateUrl = true) {
  VIEWS.forEach((name) => {
    const panel = document.getElementById(`monitoring-view-${name}`);
    if (panel) panel.hidden = view !== name;
  });

  document
    .querySelectorAll<HTMLButtonElement>('.fkp_monitoring-page__view')
    .forEach((button) => {
      const selected = button.dataset.view === view;
      button.setAttribute('aria-pressed', selected ? 'true' : 'false');
      button.classList.toggle('fkp_monitoring-page__tab--active', selected);
    });

  if (updateUrl && typeof history !== 'undefined' && history.replaceState) {
    const url = `${window.location.pathname}${window.location.search}`;
    history.replaceState(
      null,
      '',
      view === 'connections' ? url : `${url}#view=${view}`,
    );
  }

  setProkopPage(controllerForView(view));
  viewListener?.(view);
}
