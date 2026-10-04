import { asText } from '../../../helpers/asText';
import { openProkopPage } from '../../helpers/navigation';
import { renderOverflowMenu } from '../../ui/overflowMenu';
import { renderStatus, statusTone } from '../../ui/status';
import type { SemanticStatus } from '../../ui/status';
import type {
  OverviewAutotune,
  OverviewEvent,
  OverviewLine,
  OverviewRecovery,
  OverviewRouting,
  OverviewState,
  OverviewWarning,
} from './overview';

export interface OverviewViewModel {
  warning: OverviewWarning | null;
  state: OverviewState;
  routing: OverviewRouting;
  autotune: OverviewAutotune;
  recovery: OverviewRecovery;
  event: OverviewEvent | null;
}

export interface OverviewActions {
  readonly: boolean;
  serviceBusy: boolean;
  autostart: boolean;
  // Several sing-box processes, or ownership unclear: a restart cannot prove
  // which one it would replace, so only Stop is offered.
  restartBlocked?: boolean;
  // Something may still intercept traffic although Prokop is not healthy:
  // Stop stays reachable and Start waits for it.
  stopAvailable?: boolean;
  onStart: () => void;
  onRestart: () => void;
  onStop: () => void;
  onToggleAutostart: () => void;
}

function statusView(status: SemanticStatus, label: string) {
  return { label, tone: statusTone(status) };
}

function linkButton(label: string, onClick: () => void) {
  return E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button fkp-overview__link',
      click: onClick,
    },
    asText(label),
  );
}

function renderLines(lines: OverviewLine[]) {
  return E(
    'ul',
    { class: 'fkp-overview__lines' },
    lines.map((line) =>
      E(
        'li',
        { class: line.tone ? `fkp-overview__line--${line.tone}` : '' },
        asText(line.text),
      ),
    ),
  );
}

function card(
  title: string,
  body: Node[],
  footer: Node[] = [],
  headerExtra: Node[] = [],
) {
  return E('section', { class: 'fkp-overview__card' }, [
    E('div', { class: 'fkp-overview__head' }, [
      E('h3', { class: 'fkp-overview__title' }, asText(title)),
      ...headerExtra,
    ]),
    ...body,
    ...(footer.length
      ? [E('div', { class: 'fkp-overview__footer fkp-actions' }, footer)]
      : []),
  ]);
}

function renderWarning(warning: OverviewWarning) {
  return E('section', { class: 'fkp-overview__warning', role: 'alert' }, [
    E('strong', {}, asText(warning.title)),
    E('p', {}, asText(warning.text)),
    ...(warning.link
      ? [
          linkButton(warning.link.label, () =>
            openProkopPage(warning.link!.page),
          ),
        ]
      : []),
  ]);
}

function renderStateCard(
  state: OverviewState,
  actions: OverviewActions,
  restartRequired: boolean,
) {
  const footer: Node[] = [];
  const menu: Node[] = [];

  if (!actions.readonly) {
    const stopOffered = !state.stopped || actions.stopAvailable === true;
    const restartOffered = actions.restartBlocked !== true;
    if (actions.restartBlocked)
      footer.push(
        E(
          'p',
          { class: 'fkp-overview__hint' },
          _(
            "Multiple sing-box processes were found or their ownership is unclear. Restart is unavailable; traffic routing was not changed. Stop Prokop ends Prokop's traffic interception and stops the sing-box processes that Prokop runs; then start Prokop again. A sing-box of another program is not stopped, and Prokop starts only after it has exited.",
          ),
        ),
      );
    // Down, but something still intercepts traffic: the way out is Stop.
    if (state.stopped && actions.stopAvailable) {
      footer.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-remove',
            disabled: actions.serviceBusy ? true : undefined,
            click: actions.onStop,
          },
          _('Stop Prokop…'),
        ),
      );
    }
    // A start is refused while a failed change keeps its DPI guard: only a
    // restart removes it (UC-019).
    else if (state.stopped && restartRequired && restartOffered) {
      footer.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-action',
            disabled: actions.serviceBusy ? true : undefined,
            click: actions.onRestart,
          },
          _('Restart Prokop'),
        ),
      );
    } else if (state.stopped) {
      footer.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-action',
            disabled: actions.serviceBusy ? true : undefined,
            click: actions.onStart,
          },
          asText(actions.serviceBusy ? _('Starting…') : _('Start Prokop')),
        ),
      );
    }
    menu.push(
      renderOverflowMenu(_('Service actions'), [
        ...(!state.stopped && restartOffered
          ? [
              {
                label: _('Restart Prokop'),
                onClick: actions.onRestart,
                disabled: actions.serviceBusy,
              },
            ]
          : []),
        ...(stopOffered
          ? [
              {
                label: _('Stop Prokop…'),
                onClick: actions.onStop,
                disabled: actions.serviceBusy,
                danger: true,
              },
            ]
          : []),
        {
          label: actions.autostart
            ? _('Disable autostart')
            : _('Enable autostart'),
          onClick: actions.onToggleAutostart,
          disabled: actions.serviceBusy,
        },
      ]),
    );
  }

  return card(
    _('State'),
    [
      E('div', { class: 'fkp-overview__status' }, [
        renderStatus(statusView(state.status, state.title)),
      ]),
      renderLines(state.lines),
    ],
    [
      ...footer,
      linkButton(_('Diagnostics'), () => openProkopPage('diagnostics')),
    ],
    menu,
  );
}

function renderRoutingCard(routing: OverviewRouting, readonly: boolean) {
  return card(
    _('Routing'),
    [
      ...(routing.summary
        ? [E('p', { class: 'fkp-overview__summary' }, asText(routing.summary))]
        : []),
      ...(routing.live
        ? [E('p', { class: 'fkp-overview__hint' }, asText(routing.live))]
        : []),
      ...(routing.groups.length
        ? [
            E(
              'ul',
              { class: 'fkp-overview__groups' },
              routing.groups.map((group) =>
                E('li', {}, [
                  E(
                    'span',
                    { class: 'fkp-overview__group-name' },
                    asText(group.name),
                  ),
                  E('span', { class: 'fkp-overview__group-node' }, [
                    `${group.node} · `,
                    E(
                      'span',
                      { class: `fkp-status--${group.tone}` },
                      asText(group.latency),
                    ),
                  ]),
                ]),
              ),
            ),
          ]
        : []),
      ...(routing.more
        ? [
            E(
              'p',
              { class: 'fkp-overview__hint' },
              asText(_('%d more groups').replace('%d', String(routing.more))),
            ),
          ]
        : []),
    ],
    [
      linkButton(_('Nodes and groups'), () =>
        openProkopPage('monitoring', { view: 'nodes' }),
      ),
      linkButton(_('Connections'), () => openProkopPage('monitoring')),
      ...(readonly
        ? []
        : [linkButton(_('Rules'), () => openProkopPage('rules'))]),
    ],
  );
}

// Read-only in every session: mode changes and applies stay on the
// Autotune page.
function renderAutotuneCard(autotune: OverviewAutotune) {
  return card(
    _('DPI autotune'),
    [
      E('div', { class: 'fkp-overview__status' }, [
        renderStatus(statusView(autotune.status, autotune.title)),
      ]),
      renderLines(autotune.lines),
    ],
    [linkButton(_('Open autotune'), () => openProkopPage('autotune'))],
  );
}

function renderRecoveryCard(
  recovery: OverviewRecovery,
  actions: OverviewActions,
) {
  // The restart that removes a DPI guard a failed change kept (UC-019),
  // whether the runtime runs or not.
  const restart =
    !actions.readonly && recovery.step === 'restart'
      ? [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button cbi-button-action',
              disabled: actions.serviceBusy ? true : undefined,
              click: actions.onRestart,
            },
            _('Restart Prokop'),
          ),
        ]
      : [];
  return card(
    _('Recovery'),
    [
      E('div', { class: 'fkp-overview__status' }, [
        renderStatus(statusView(recovery.status, recovery.title)),
      ]),
      renderLines(recovery.lines),
    ],
    [
      ...restart,
      linkButton(_('Recovery details'), () => openProkopPage('history')),
    ],
  );
}

function renderEventCard(event: OverviewEvent | null) {
  return card(
    _('Last important event'),
    event
      ? [
          E('p', { class: 'fkp-overview__summary' }, [
            `${event.title}: `,
            E(
              'span',
              { class: `fkp-status--${event.outcome.tone}` },
              asText(event.outcome.label),
            ),
          ]),
          E('p', { class: 'fkp-overview__hint' }, asText(event.time)),
        ]
      : [E('p', { class: 'fkp-overview__hint' }, _('No events recorded yet'))],
    [linkButton(_('All events'), () => openProkopPage('history'))],
  );
}

export function renderOverview(
  vm: OverviewViewModel,
  actions: OverviewActions,
) {
  return E('div', { class: 'fkp-overview' }, [
    ...(vm.warning ? [renderWarning(vm.warning)] : []),
    E('div', { class: 'fkp-overview__grid' }, [
      renderStateCard(vm.state, actions, vm.recovery.step === 'restart'),
      renderRoutingCard(vm.routing, actions.readonly),
      renderAutotuneCard(vm.autotune),
      renderRecoveryCard(vm.recovery, actions),
      renderEventCard(vm.event),
    ]),
  ]);
}
