import { asText } from '../../../helpers/asText';
import { ProkopShellMethods } from '../../methods';
import type { Prokop } from '../../types';
import type { StatusTone } from './statusLabels';
import {
  CONNECTIVITY_TARGETS_KEY,
  readStorageItem,
  writeStorageItem,
  type ReadableStorage,
} from '../../helpers/legacyStorage';

export type ConnectivityType = 'DNS' | 'TCP' | 'HTTP' | 'HTTPS';
export interface Target {
  host: string;
  type: ConnectivityType;
  port: string;
}
export type RowResult =
  | { state: 'idle' }
  | { state: 'running' }
  | { state: 'done'; result: Prokop.ConnectivityResult }
  | { state: 'invalid'; message: string }
  // The probe did not run or gave no answer (rpcd error, timeout): nothing
  // was observed, so it is neither a typing mistake nor an unreachable host.
  | { state: 'failed'; message: string };

const TYPES: ConnectivityType[] = ['DNS', 'TCP', 'HTTP', 'HTTPS'];
export const DEFAULT_PORTS: Record<ConnectivityType, string> = {
  DNS: '',
  TCP: '',
  HTTP: '80',
  HTTPS: '443',
};
const DEFAULTS: Target[] = [
  { host: 'cloudflare.com', type: 'HTTPS', port: '443' },
  { host: 'telegram.org', type: 'HTTPS', port: '443' },
];
const MAX_TARGETS = 10;

export function loadTargets(storage: ReadableStorage): Target[] {
  try {
    const value = JSON.parse(
      readStorageItem(storage, CONNECTIVITY_TARGETS_KEY) || 'null',
    );
    if (Array.isArray(value))
      return value
        .slice(0, MAX_TARGETS)
        .map((item) =>
          item && item.type === 'TLS' ? { ...item, type: 'HTTPS' } : item,
        )
        .filter(
          (item) =>
            item &&
            typeof item.host === 'string' &&
            item.host.length <= 253 &&
            TYPES.includes(item.type) &&
            typeof item.port === 'string' &&
            item.port.length <= 5,
        );
  } catch (_error) {
    /* use defaults */
  }
  return DEFAULTS.map((target) => ({ ...target }));
}

// A port the user typed is kept; a port that was only a type default follows
// the new type.
export function changeType(target: Target, type: ConnectivityType): Target {
  if (type === 'DNS') return { ...target, type, port: '' };
  if (type === 'TCP') return { ...target, type, port: target.port };
  const wasDefault =
    target.port === '' || Object.values(DEFAULT_PORTS).includes(target.port);
  return {
    ...target,
    type,
    port: wasDefault ? DEFAULT_PORTS[type] : target.port,
  };
}

const IPV4 = /^(\d{1,3}\.){3}\d{1,3}$/;

export function validateTarget(target: Target): string | null {
  const host = target.host.trim();
  if (!host) return _('Enter an address');
  if (target.type === 'DNS')
    return IPV4.test(host) || host.includes(':')
      ? _('DNS check needs a domain name')
      : null;
  if (!target.port) return _('Enter a port');
  const port = Number(target.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535)
    return _('Port must be between 1 and 65535');
  return null;
}

const ERROR_TEXT: Record<string, () => string> = {
  timeout: () => _('Timed out'),
  nxdomain: () => _('Domain does not exist'),
  no_answer: () => _('No DNS records for this name'),
  dns_failed: () => _('DNS name did not resolve'),
  connect_failed: () => _('Connection refused or host unreachable'),
  tls_failed: () => _('TLS or certificate error'),
  no_response: () => _('Server closed the connection without a response'),
  tool_missing: () => _('Probe tool is missing on the router'),
  failed: () => _('Check failed'),
};

export function resultView(result: RowResult): {
  text: string;
  tone: StatusTone;
} {
  if (result.state === 'idle')
    return { text: _('Not checked'), tone: 'neutral' };
  if (result.state === 'running')
    return { text: _('Checking…'), tone: 'loading' };
  if (result.state === 'invalid')
    return { text: result.message, tone: 'error' };
  if (result.state === 'failed')
    return { text: result.message, tone: 'warning' };
  const data = result.result;
  if (data.status === 'ok') {
    const parts = [`✓ ${_('Reachable')}`, `${data.latency_ms} ${_('ms')}`];
    if (data.address) parts.push(data.address);
    if (data.http_code) parts.push(`HTTP ${data.http_code}`);
    return { text: parts.join(' · '), tone: 'success' };
  }
  const reason = (ERROR_TEXT[data.error || ''] || ERROR_TEXT.failed)();
  return {
    text: `✕ ${reason}`,
    tone: data.status === 'timeout' ? 'warning' : 'error',
  };
}

export async function probe(target: Target): Promise<RowResult> {
  const invalid = validateTarget(target);
  if (invalid) return { state: 'invalid', message: invalid };
  const response = await ProkopShellMethods.connectivityTest(
    target.host.trim(),
    target.type,
    target.type === 'DNS' ? '' : target.port,
  );
  // connectivity_test answers {error:"invalid_input"} for a target it
  // rejects; any other answer without a status is a check that did not run.
  if (
    response.success &&
    (response.data as { error?: unknown } | undefined)?.error ===
      'invalid_input'
  )
    return { state: 'invalid', message: _('The router rejected this check') };
  if (!response.success || !response.data?.status)
    return { state: 'failed', message: _('The check could not run') };
  // A late answer for an edited row must not be shown as its result.
  if (
    response.data.type !== target.type ||
    (target.type !== 'DNS' && String(response.data.port) !== target.port)
  )
    return { state: 'idle' };
  return { state: 'done', result: response.data };
}

interface Row {
  target: Target;
  result: RowResult;
  element?: HTMLElement;
}

function field(label: string, control: HTMLElement, extraClass = '') {
  return E('label', { class: `fkp-conn__cell ${extraClass}`.trim() }, [
    E('span', { class: 'fkp-conn__cell-label' }, asText(label)),
    control,
  ]);
}

export function initConnectivityMatrix() {
  const root = document.getElementById('connectivity-rows');
  const add = document.getElementById(
    'connectivity-add',
  ) as HTMLButtonElement | null;
  const run = document.getElementById(
    'connectivity-run',
  ) as HTMLButtonElement | null;
  if (!root || !add || !run || add.onclick) return;
  const rows: Row[] = loadTargets(localStorage).map((target) => ({
    target,
    result: { state: 'idle' },
  }));
  let runningAll = false;
  const save = () =>
    writeStorageItem(
      localStorage,
      CONNECTIVITY_TARGETS_KEY,
      JSON.stringify(rows.map((row) => row.target)),
    );
  const busy = () => rows.some((row) => row.result.state === 'running');

  const updateButtons = () => {
    run.disabled = runningAll || busy() || rows.length === 0;
    add.disabled = rows.length >= MAX_TARGETS;
    for (const row of rows) {
      const retry =
        row.element?.querySelector<HTMLButtonElement>('.fkp-conn__retry');
      if (retry) retry.disabled = runningAll || row.result.state === 'running';
    }
  };
  const paintResult = (row: Row) => {
    const cell = row.element?.querySelector<HTMLElement>('.fkp-conn__result');
    if (!cell) return;
    const view = resultView(row.result);
    cell.className = `fkp-conn__result fkp-diag-text--${view.tone}`;
    cell.textContent = view.text;
    updateButtons();
  };
  const invalidate = (row: Row) => {
    row.result = { state: 'idle' };
    save();
    paintResult(row);
  };
  const check = async (row: Row) => {
    row.result = { state: 'running' };
    paintResult(row);
    const requested = { ...row.target };
    const result = await probe(requested);
    // Discard the answer if the row changed while the probe was running.
    if (JSON.stringify(requested) !== JSON.stringify(row.target)) return;
    row.result = result;
    paintResult(row);
  };

  const renderRow = (row: Row) => {
    const host = E('input', {
      class: 'cbi-input-text',
      value: row.target.host,
      placeholder: 'example.com',
      maxLength: 253,
    }) as HTMLInputElement;
    const type = E(
      'select',
      { class: 'cbi-input-select' },
      TYPES.map((kind) =>
        E(
          'option',
          { value: kind, selected: row.target.type === kind },
          asText(kind),
        ),
      ),
    ) as HTMLSelectElement;
    const port = E('input', {
      class: 'cbi-input-text',
      value: row.target.port,
      type: 'number',
      min: '1',
      max: '65535',
      placeholder: row.target.type === 'TCP' ? '443' : '',
    }) as HTMLInputElement;
    host.oninput = () => {
      row.target.host = host.value;
      invalidate(row);
    };
    port.oninput = () => {
      row.target.port = port.value.trim();
      invalidate(row);
    };
    type.onchange = () => {
      row.target = changeType(row.target, type.value as ConnectivityType);
      row.result = { state: 'idle' };
      save();
      row.element?.replaceWith(renderRow(row));
      updateButtons();
    };
    const portCell =
      row.target.type === 'DNS'
        ? E('div', { class: 'fkp-conn__cell fkp-conn__cell--muted' }, [
            E('span', { class: 'fkp-conn__cell-label' }, _('Port')),
            E('span', {}, _('not used')),
          ])
        : field(_('Port'), port);
    const view = resultView(row.result);
    row.element = E('div', { class: 'fkp-conn__row' }, [
      field(_('Address'), host),
      field(_('Type'), type),
      portCell,
      E('div', { class: 'fkp-conn__cell' }, [
        E('span', { class: 'fkp-conn__cell-label' }, _('Result')),
        E(
          'span',
          {
            class: `fkp-conn__result fkp-diag-text--${view.tone}`,
            role: 'status',
          },
          asText(view.text),
        ),
      ]),
      E('div', { class: 'fkp-conn__actions' }, [
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button fkp-conn__retry',
            click: () => void check(row),
          },
          _('Check'),
        ),
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button fkp-conn__remove',
            title: _('Remove'),
            'aria-label': _('Remove'),
            click: () => {
              rows.splice(rows.indexOf(row), 1);
              save();
              render();
            },
          },
          '✕',
        ),
      ]),
    ]);
    return row.element;
  };

  const render = () => {
    root.replaceChildren(
      E('div', { class: 'fkp-conn__head', role: 'presentation' }, [
        E('span', {}, _('Address')),
        E('span', {}, _('Type')),
        E('span', {}, _('Port')),
        E('span', {}, _('Result')),
        E('span', {}, ''),
      ]),
      ...rows.map(renderRow),
    );
    updateButtons();
  };

  add.onclick = () => {
    if (rows.length >= MAX_TARGETS) return;
    rows.push({
      target: { host: '', type: 'HTTPS', port: '443' },
      result: { state: 'idle' },
    });
    save();
    render();
    rows[rows.length - 1].element?.querySelector('input')?.focus();
  };
  run.onclick = async () => {
    if (runningAll || busy()) return;
    runningAll = true;
    updateButtons();
    try {
      for (const row of [...rows]) if (rows.includes(row)) await check(row);
    } finally {
      runningAll = false;
      updateButtons();
    }
  };
  render();
}
