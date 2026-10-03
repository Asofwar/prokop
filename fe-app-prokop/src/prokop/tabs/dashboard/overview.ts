import { Prokop } from '../../types';
import { prettyBytesRate } from '../../../helpers/prettyBytes';
import {
  eventKindLabel,
  eventOutcomeView,
  toEventOutcome,
  type SemanticStatus,
  type StatusTone,
} from '../../ui/status';
import { formatRelativeTime } from '../../ui/time';

// View model of the overview page: short answers, each with a link to the
// page that has the details. Pure, so every state is covered by tests.

export type OverviewPage =
  | 'monitoring'
  | 'diagnostics'
  | 'history'
  | 'rules'
  | 'settings';

export interface OverviewInput {
  health: Prokop.HealthStatus | null;
  // The last health report is kept when a later poll fails, so a guard it
  // showed stays visible; it no longer proves the system healthy (UC-021).
  healthStale?: boolean;
  availability: 'loading' | 'running' | 'stopped' | 'unavailable';
  prokopEnabled: boolean;
  // Stopped by the user, as opposed to down after a failed start or a
  // crash (D-15).
  prokopStoppedByUser: boolean;
  // Not started since boot, as opposed to down after an explicit start
  // (D-15); null when the backend does not report it.
  prokopNotStarted: boolean | null;
  // The service status of the UI state: a start, restart or reload in
  // progress is reported here before the runtime is up.
  prokopStatus: string;
  singBoxRunning: boolean;
  groups: Prokop.OutboundGroup[];
  ruleCount: number | null;
  traffic: { up: number; down: number } | null;
  connections: number | null;
  snapshotCount: number | null;
  lastDiagnosticRun: number | null;
  nowMs: number;
}

export interface OverviewWarning {
  title: string;
  text: string;
  link?: { page: OverviewPage; label: string };
}

export interface OverviewLine {
  text: string;
  tone?: StatusTone;
}

export interface OverviewState {
  status: SemanticStatus;
  title: string;
  lines: OverviewLine[];
  stopped: boolean;
}

export interface OverviewGroup {
  name: string;
  node: string;
  latency: string;
  tone: StatusTone;
}

export interface OverviewRouting {
  summary: string;
  live: string;
  groups: OverviewGroup[];
  more: number;
}

export interface OverviewRecovery {
  status: SemanticStatus;
  title: string;
  lines: OverviewLine[];
  // The step that ends a DPI guard that is left (UC-019): the card offers
  // the restart itself, the restore is on the History page.
  step?: 'restart' | 'restore';
}

export interface OverviewEvent {
  title: string;
  outcome: { label: string; tone: StatusTone };
  time: string;
}

function lastEvent(health: Prokop.HealthStatus | null) {
  const events = health?.recent_activity || [];
  return events.length ? events[events.length - 1] : null;
}

// The last configuration change: a failed scheduled jobs update
// (cron_refresh) is no failed change, also when it is the last event because
// its start or reload gave way to a stop; a configuration migration by a
// package upgrade (config_migration) changes nothing in the runtime
// (diagnostics/health.uc).
function lastChangeEvent(health: Prokop.HealthStatus | null) {
  const events = (health?.recent_activity || []).filter(
    (event) =>
      event.kind !== 'cron_refresh' && event.kind !== 'config_migration',
  );
  return events.length ? events[events.length - 1] : null;
}

// What the DPI guard that is left means, by what ends it
// (diagnostics/health.uc recovery.action): it does not go on its own unless
// a change still holds it (UC-019, UC-066).
function guardWarningText(action: Prokop.HealthStatus['recovery']['action']) {
  switch (action) {
    case 'restart':
      return _(
        'A failed change left the DPI guard in place. Traffic that needs DPI bypass stays blocked until you restart Prokop.',
      );
    case 'restore':
      return _(
        'A configuration restore did not finish. Traffic that needs DPI bypass stays blocked until you restore the last known good snapshot.',
      );
    case 'wait':
      return _(
        'A configuration change is being applied. Traffic that needs DPI bypass may be blocked until it finishes.',
      );
    default:
      return _(
        'A configuration change was not confirmed. Traffic that needs DPI bypass may be blocked; see the recovery details for the next step.',
      );
  }
}

export function overviewWarning(
  health: Prokop.HealthStatus | null,
): OverviewWarning | null {
  if (!health) return null;
  const details = {
    page: 'history' as const,
    label: _('Recovery details'),
  };

  if (health.guard?.active) {
    return {
      title: _('DPI protection is holding traffic'),
      text: guardWarningText(health.recovery?.action),
      link: details,
    };
  }
  if (health.package_recovery?.pending) {
    return {
      title: _('Package recovery has not finished'),
      text: _(
        'An interrupted package update is being recovered. Avoid changes until it completes.',
      ),
      link: details,
    };
  }
  if (lastChangeEvent(health)?.status === 'failure') {
    return {
      title: _('The last configuration change failed'),
      text: _('Prokop kept or restored the previous configuration.'),
      link: details,
    };
  }
  // A kernel-wide setting Prokop changes while it runs; stop puts back
  // what it changed (diagnostics/health.uc bridge_netfilter; D-19, UC-109).
  // disabled_by_prokop: a hook still holds the 0 that Prokop wrote.
  if (health.bridge_netfilter?.loaded) {
    return {
      title: _('br_netfilter is loaded'),
      text: health.bridge_netfilter.disabled_by_prokop
        ? _(
            'Prokop has turned off the iptables hooks of br_netfilter (net.bridge.bridge-nf-call-iptables and -ip6tables) for transparent proxying: iptables rules do not filter bridged traffic while it runs. Stopping Prokop restores the previous values unless another program has changed them since.',
          )
        : _(
            'While Prokop runs, it turns off the iptables hooks of br_netfilter (net.bridge.bridge-nf-call-iptables and -ip6tables) that are on, for transparent proxying, so iptables rules do not filter bridged traffic. Their current values were not set by Prokop, and stopping it does not change them.',
          ),
    };
  }

  return null;
}

// The VPN kill-switch keeps blocking while Prokop is down; a reload of a
// stopped Prokop never refreshes it (D-15, UC-208).
const KILL_SWITCH_STOPPED_LINE = () =>
  _(
    'If the VPN kill-switch is enabled, its sections stay blocked until Prokop is started.',
  );

export function overviewState(input: OverviewInput): OverviewState {
  const { health, availability } = input;
  const lines: OverviewLine[] = [];
  let status: SemanticStatus;
  let title: string;

  if (
    availability === 'stopped' &&
    ['starting', 'restarting', 'reloading'].includes(input.prokopStatus)
  ) {
    // Not up yet, and nothing failed so far: a start (boot, Start, the
    // start half of Restart, the WAN retry) or a reload repairing it.
    status = 'busy';
    title =
      input.prokopStatus === 'reloading'
        ? _('Applying changes…')
        : _('Starting…');
  } else if (availability === 'stopped' && input.prokopStoppedByUser) {
    status = 'off';
    title = _('Stopped by user');
    lines.push({
      text: _(
        'Prokop stays stopped until you start it: reloads, restores and updates do not start it.',
      ),
    });
    lines.push({
      text: _('Traffic goes through the router without Prokop.'),
    });
    lines.push({ text: KILL_SWITCH_STOPPED_LINE() });
  } else if (availability === 'stopped' && input.prokopNotStarted === true) {
    status = 'off';
    title = _('Not started');
    lines.push({
      text: _(
        'Prokop was not started since the router booted: reloads, restores and updates do not start it.',
      ),
    });
    lines.push({
      text: _('Traffic goes through the router without Prokop.'),
    });
    lines.push({ text: KILL_SWITCH_STOPPED_LINE() });
  } else if (availability === 'stopped') {
    // Nobody stopped it: a start failed or the runtime went down after an
    // explicit start. A backend that does not report whether Prokop was
    // started since boot says so only with autostart on.
    const failed = input.prokopNotStarted === false || input.prokopEnabled;
    status = failed ? 'error' : 'off';
    title = _('Not running');
    if (failed) {
      lines.push({
        text: _(
          'Prokop was not stopped by the user: its start failed or it stopped unexpectedly.',
        ),
        tone: 'error',
      });
    }
    lines.push({
      text: _('Traffic goes through the router without Prokop.'),
    });
    lines.push({ text: KILL_SWITCH_STOPPED_LINE() });
  } else if (availability === 'loading') {
    status = 'busy';
    title = _('Checking…');
  } else if (availability === 'unavailable') {
    status = 'unknown';
    title = _('State unavailable');
  } else if (health?.overall === 'transitioning') {
    status = 'busy';
    title = _('Applying changes…');
  } else if (health?.overall === 'error') {
    status = 'error';
    title = _('Prokop needs attention');
  } else {
    // Running, but only a health report proves it healthy: none yet, one
    // that failed to load, or an unknown one is not (UC-021).
    const known =
      !input.healthStale &&
      (health?.overall === 'ok' || health?.overall === 'recovered');
    status =
      health?.overall === 'recovered'
        ? 'warning'
        : known
          ? 'healthy'
          : 'unknown';
    title = _('Prokop is running');
    if (health?.overall === 'recovered') {
      lines.push({
        text: _('The last change was rolled back automatically.'),
        tone: 'warning',
      });
    }
    if (!known) lines.push({ text: _('Health state unavailable') });
  }

  if (availability === 'running') {
    lines.push(
      input.singBoxRunning
        ? { text: _('sing-box is running') }
        : { text: _('sing-box is not running'), tone: 'error' },
    );
    if (health?.dns?.status === 'warning') {
      lines.push({
        text: _('Router DNS is not pointed to Prokop'),
        tone: 'warning',
      });
    }
  }
  lines.push({
    text: input.prokopEnabled ? _('Autostart is on') : _('Autostart is off'),
  });
  lines.push({
    text: input.lastDiagnosticRun
      ? _('Last diagnostics: %s').replace(
          '%s',
          formatRelativeTime(input.lastDiagnosticRun / 1000, input.nowMs),
        )
      : _('Diagnostics has not been run yet'),
  });

  return { status, title, lines, stopped: availability === 'stopped' };
}

function latencyTone(latency: number): StatusTone {
  if (!latency) return 'neutral';
  if (latency < 800) return 'success';
  return latency < 1500 ? 'warning' : 'error';
}

const MAX_GROUPS = 3;

export function overviewRouting(input: OverviewInput): OverviewRouting {
  const groups = input.groups.filter((group) => group.outbounds.length);
  // Node groups are only known while sing-box runs.
  const groupsKnown = input.availability === 'running' || groups.length > 0;
  let summary = '';
  if (input.ruleCount !== null && groupsKnown) {
    summary = _('%d rules · %d node groups')
      .replace('%d', String(input.ruleCount))
      .replace('%d', String(groups.length));
  } else if (input.ruleCount !== null) {
    summary = _('%d rules').replace('%d', String(input.ruleCount));
  } else if (groupsKnown) {
    summary = _('%d node groups').replace('%d', String(groups.length));
  }

  let live = '';
  if (input.availability === 'stopped') {
    live = _('Routing is paused while Prokop is stopped.');
  } else if (input.connections !== null) {
    live = _('%d connections now').replace('%d', String(input.connections));
    if (input.traffic) {
      live += ` · ↓ ${prettyBytesRate(input.traffic.down)} ↑ ${prettyBytesRate(input.traffic.up)}`;
    }
  }

  return {
    summary,
    live,
    groups: groups.slice(0, MAX_GROUPS).map((group) => {
      const selected =
        group.outbounds.find((outbound) => outbound.selected) ||
        group.outbounds[0];
      return {
        name: group.displayName,
        node: selected.displayName,
        latency: selected.latency
          ? _('%d ms').replace('%d', String(selected.latency))
          : _('no data'),
        tone: latencyTone(selected.latency),
      };
    }),
    more: Math.max(0, groups.length - MAX_GROUPS),
  };
}

export function overviewRecovery(input: OverviewInput): OverviewRecovery {
  const { health } = input;
  if (!health) {
    return { status: 'unknown', title: _('State unavailable'), lines: [] };
  }

  const lines: OverviewLine[] = [];
  const reload = health.last_reload;
  if (reload) {
    const outcome = eventOutcomeView(toEventOutcome(reload.status));
    lines.push({
      text: _('Last reload: %s').replace(
        '%s',
        `${outcome.label} · ${formatRelativeTime(reload.timestamp, input.nowMs)}`,
      ),
      tone: outcome.tone,
    });
  } else {
    lines.push({ text: _('No reload recorded yet') });
  }
  if (input.snapshotCount !== null) {
    lines.push({
      text: _('Snapshots: %d').replace('%d', String(input.snapshotCount)),
    });
  }

  const state = recoveryState(health);
  // A stale report may still show what is left, never that nothing is.
  if (input.healthStale && state.status === 'healthy')
    return { status: 'unknown', title: _('State unavailable'), lines };
  return { ...state, lines: [...state.lines, ...lines] };
}

// Whatever is left is never "No recovery needed" (UC-021): a DPI guard,
// named by what ends it (UC-019, UC-066), an unfinished package recovery,
// or a failed last change (health.uc recovery.pending without a guard: the
// previous configuration was kept, nothing is in progress).
function recoveryState(health: Prokop.HealthStatus): OverviewRecovery {
  if (health.guard?.active) {
    switch (health.recovery?.action) {
      case 'restart':
        return {
          status: 'needs_attention',
          title: _('Restart required'),
          step: 'restart',
          lines: [
            {
              text: _(
                'A failed change left the DPI guard in place: restart Prokop to remove it.',
              ),
              tone: 'error',
            },
          ],
        };
      case 'restore':
        return {
          status: 'needs_attention',
          title: _('Restore required'),
          step: 'restore',
          lines: [
            {
              text: _(
                'A configuration restore did not finish: restore the last known good snapshot to finish it.',
              ),
              tone: 'error',
            },
          ],
        };
      case 'wait':
        return { status: 'busy', title: _('Change in progress'), lines: [] };
      default:
        return {
          status: 'needs_attention',
          title: _('Protection is active'),
          lines: [],
        };
    }
  }
  if (health.package_recovery?.pending) {
    return {
      status: 'needs_attention',
      title: _('Package recovery has not finished'),
      lines: [],
    };
  }
  if (health.recovery?.pending) {
    return {
      status: 'error',
      title: _('The last configuration change failed'),
      lines: [
        {
          text: _('Prokop kept or restored the previous configuration.'),
          tone: 'error',
        },
      ],
    };
  }
  return { status: 'healthy', title: _('No recovery needed'), lines: [] };
}

export function overviewLastEvent(input: OverviewInput): OverviewEvent | null {
  const event = lastEvent(input.health);
  if (!event) return null;

  return {
    title: eventKindLabel(event.kind),
    outcome: eventOutcomeView(toEventOutcome(event.status)),
    time: formatRelativeTime(event.timestamp, input.nowMs),
  };
}
