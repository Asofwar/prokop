import { asText } from '../../../helpers/asText';
import { prettyBytes, prettyBytesRate } from '../../../helpers/prettyBytes';
import { renderSearchIcon24 } from '../../../icons/renderSearchIcon24';
import { formatDateTime } from '../../ui/time';
import { renderProvenance } from '../../ui/status';
import type { Prokop } from '../../types';
import { deviceLabel, type DeviceRow, type RouteUse } from './devices';

export type DevicesStatus =
  | 'loading'
  | 'failed'
  | 'stopped'
  | Prokop.DeviceTraffic['state'];

export interface DevicesViewRow extends DeviceRow {
  routes: RouteUse[];
  // The address to open in Connections; null when sing-box has seen no
  // connection of the device while the page was open.
  connectionsAddress: string | null;
}

export interface DevicesViewModel {
  status: DevicesStatus;
  since: number | null;
  offload: Prokop.DeviceTraffic['offload'];
  // Counter sets that count no new address (TRF-1).
  full: boolean;
  // All counted addresses, when the router sent only the busiest (TRF-2).
  totalDevices: number | null;
  shownDevices: number;
  rows: DevicesViewRow[];
  showConnections: (address: string) => void;
  startServiceActions: () => HTMLElement[];
}

const ROUTES_SHOWN = 3;

function bytes(value: number) {
  return prettyBytes(Math.max(0, value));
}

function rate(value: number | null) {
  return value == null ? '—' : prettyBytesRate(Math.round(Math.max(0, value)));
}

function cell(label: string, children: (Node | string)[]) {
  const node = E('td', {}, [
    E('div', { class: 'fkp_monitoring-page__cell' }, children),
  ]);
  node.setAttribute('data-label', label);
  return node;
}

function secondary(text: string) {
  return E('span', { class: 'fkp_monitoring-page__secondary' }, asText(text));
}

function value(text: string, className = '') {
  return E(
    'span',
    { class: ['fkp_monitoring-page__value', className].join(' ').trim() },
    asText(text),
  );
}

function otherAddresses(row: DeviceRow) {
  const more = row.addresses.length - 1;
  if (more <= 0) return '';
  return more === 1
    ? row.addresses[1]
    : _('and %d more addresses').replace('%d', String(more));
}

function renderRoutes(routes: RouteUse[]) {
  if (!routes.length)
    return [secondary(_('No connections through sing-box seen yet'))];
  const shown = routes.slice(0, ROUTES_SHOWN);
  const rest = routes.slice(ROUTES_SHOWN);
  const restBytes = rest.reduce((sum, use) => sum + use.bytes, 0);
  return [
    E('ul', { class: 'fkp_monitoring-devices__routes' }, [
      ...shown.map((use) =>
        E('li', { class: 'fkp_monitoring-devices__route' }, [
          E(
            'span',
            {
              class: `fkp_monitoring-page__path-kind fkp_monitoring-page__path-kind--${use.kind}`,
            },
            asText(use.label),
          ),
          E(
            'span',
            { class: 'fkp_monitoring-devices__route-bytes' },
            asText(bytes(use.bytes)),
          ),
        ]),
      ),
      ...(rest.length
        ? [
            E(
              'li',
              {
                class:
                  'fkp_monitoring-devices__route fkp_monitoring-devices__route--rest',
              },
              asText(
                _('other %d: %s')
                  .replace('%d', String(rest.length))
                  .replace('%s', bytes(restBytes)),
              ),
            ),
          ]
        : []),
    ]),
  ];
}

function renderRow(row: DevicesViewRow, model: DevicesViewModel) {
  const label = deviceLabel(row);
  const others = otherAddresses(row);
  const address = row.connectionsAddress;
  const actionTitle = address
    ? _('Show connections of this device')
    : _('No connections of this device through sing-box seen yet');
  const action = E(
    'button',
    {
      type: 'button',
      class:
        'btn cbi-button fkp_monitoring-page__icon-action fkp_monitoring-devices__connections',
      title: actionTitle,
      'aria-label': actionTitle,
      ...(address
        ? { click: () => model.showConnections(address) }
        : { disabled: true }),
    },
    [renderSearchIcon24()],
  );

  return E('tr', {}, [
    cell(_('Device'), [
      value(label, 'fkp_monitoring-devices__name'),
      ...(others ? [secondary(others)] : []),
    ]),
    cell(_('Sent'), [value(bytes(row.txBytes))]),
    cell(_('Received'), [value(bytes(row.rxBytes))]),
    cell(_('Speed'), [
      value(`↑ ${rate(row.txRate)}`),
      secondary(`↓ ${rate(row.rxRate)}`),
    ]),
    cell(_('Through rules'), renderRoutes(row.routes)),
    cell(_('Actions'), [action]),
  ]);
}

function stateRow(text: string, className = '', actions: HTMLElement[] = []) {
  return E('tr', { class: 'fkp_monitoring-page__state-row' }, [
    E('td', { class: 'fkp_monitoring-page__state-cell', colSpan: 6 }, [
      E(
        'div',
        {
          class: ['fkp_monitoring-page__state', className]
            .filter(Boolean)
            .join(' '),
        },
        asText(
          actions.length ? [E('span', {}, asText(text)), ...actions] : text,
        ),
      ),
    ]),
  ]);
}

function stateFor(model: DevicesViewModel): HTMLElement | null {
  switch (model.status) {
    case 'loading':
      return stateRow(
        _('Loading device traffic'),
        'fkp_monitoring-page__state--loading',
      );
    case 'failed':
      return stateRow(
        _('Device traffic is unavailable'),
        'fkp_monitoring-page__state--error',
      );
    case 'stopped':
      return stateRow(
        _(
          'Prokop service is stopped. Start the service to count traffic per device.',
        ),
        '',
        model.startServiceActions(),
      );
    case 'disabled':
      return stateRow(
        _(
          'Counting traffic per device is off: Settings, Network, Count traffic per device.',
        ),
      );
    case 'unavailable':
      return stateRow(
        _(
          'The router could not set up the traffic counters; the system log says why.',
        ),
        'fkp_monitoring-page__state--error',
      );
    default:
      return model.rows.length
        ? null
        : stateRow(_('No traffic from devices counted yet'));
  }
}

function renderNotes(model: DevicesViewModel) {
  if (model.status !== 'ok') return [];
  const counted = model.since
    ? _('Sent, received and speed: router counters since %s.').replace(
        '%s',
        formatDateTime(model.since),
      )
    : _('Sent, received and speed: router counters since Prokop started.');
  // TRF-5, TRF-6, TRF-4: what the counters hold and what they do not.
  const scope = _(
    'They count what a device sends through the router and receives from it, DNS and this page included, also packets the firewall drops afterwards; traffic between devices of the LAN is not seen. An address idle for 7 days starts again from zero, and names are those of the current leases.',
  );
  const notes: Node[] = [
    E('p', { class: 'fkp_monitoring-devices__note' }, [
      renderProvenance('observed'),
      E(
        'span',
        { class: 'fkp_monitoring-devices__note-text' },
        asText(
          `${counted} ${scope} ${_('Through rules: what sing-box counted for connections seen while this page is open; traffic that no rule sends to sing-box is not split.')}`,
        ),
      ),
    ]),
  ];
  const warning = (text: string) =>
    E(
      'p',
      {
        class:
          'fkp_monitoring-devices__note fkp_monitoring-devices__note--warning',
        role: 'note',
      },
      asText(text),
    );
  if (model.full)
    notes.push(
      warning(
        _(
          'The router counts no new addresses: its list of addresses is full. New devices are missing until addresses idle for 7 days leave it.',
        ),
      ),
    );
  if (model.totalDevices != null && model.totalDevices > model.shownDevices)
    notes.push(
      warning(
        _('Shown: the %d addresses with the most traffic of %d.')
          .replace('%d', String(model.shownDevices))
          .replace('%d', String(model.totalDevices)),
      ),
    );
  if (model.offload === 'software' || model.offload === 'hardware')
    notes.push(
      E(
        'p',
        {
          class:
            'fkp_monitoring-devices__note fkp_monitoring-devices__note--warning',
          role: 'note',
        },
        asText(
          _(
            'Flow offloading is on in the firewall: accelerated connections bypass the counters, so the totals are lower than the real traffic.',
          ),
        ),
      ),
    );
  return notes;
}

export function renderDevicesPanel(model: DevicesViewModel) {
  const state = stateFor(model);
  const rows = state ? [state] : model.rows.map((row) => renderRow(row, model));
  return [
    ...renderNotes(model),
    E('div', { class: 'fkp_monitoring-page__table-wrap' }, [
      E(
        'table',
        {
          class:
            'table cbi-section-table fkp_monitoring-page__table fkp_monitoring-devices__table',
        },
        [
          E('thead', {}, [
            E('tr', {}, [
              E('th', {}, _('Device')),
              E('th', {}, _('Sent')),
              E('th', {}, _('Received')),
              E('th', {}, _('Speed')),
              E('th', {}, _('Through rules')),
              E('th', { class: 'fkp_monitoring-page__actions-head' }, [
                E('span', { class: 'fkp-visually-hidden' }, _('Actions')),
              ]),
            ]),
          ]),
          E('tbody', {}, rows),
        ],
      ),
    ]),
  ];
}
