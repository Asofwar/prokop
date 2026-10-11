import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { ProkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { provenanceLabel } from '../../../ui/status';
import type { IDiagnosticsChecksItem } from '../../../services';
import type { Prokop } from '../../../types';

type Row = Prokop.EnvironmentRow;

// Every value names where it comes from: the firewall configuration
// (flow offloading) or what the router reports now (IPv6, clock).
function withProvenance(text: string, row: Row | undefined) {
  const provenance = row?.provenance;
  return provenance ? `${text} (${provenanceLabel(provenance)})` : text;
}

function neutral(key: string, row: Row | undefined): IDiagnosticsChecksItem {
  return {
    state: 'neutral',
    key,
    value:
      row?.state === 'not_checked'
        ? _('Not checked')
        : _('Not available for checking'),
  };
}

export function flowOffloadingItem(
  row: Prokop.EnvironmentCheckResult['flow_offloading'],
): IDiagnosticsChecksItem {
  const key = _('Flow offloading');
  if (!row || (row.state !== 'ok' && row.state !== 'warning'))
    return neutral(key, row);
  if (row.state === 'ok')
    return { state: 'success', key, value: withProvenance(_('Off'), row) };
  return {
    state: 'warning',
    key,
    value: withProvenance(
      row.hardware
        ? _(
            'Hardware offloading is on: established connections are forwarded past the router processor and every nftables rule. Prokop, the kill-switch and zapret see only the start of a connection; a connection opened before Prokop started or before a list update can keep going directly, and device traffic counters are too low. If rules or the kill-switch apply unreliably, turn offloading off in Network → Firewall.',
          )
        : _(
            'Software offloading is on: established connections bypass the nftables rules. Prokop, the kill-switch and zapret see only the start of a connection; a connection opened before Prokop started or before a list update can keep going directly, and device traffic counters are too low. If rules or the kill-switch apply unreliably, turn offloading off in Network → Firewall.',
          ),
      row,
    ),
  };
}

export function ipv6Item(
  row: Prokop.EnvironmentCheckResult['ipv6'],
): IDiagnosticsChecksItem {
  const key = _('IPv6');
  if (!row || (row.state !== 'ok' && row.state !== 'warning'))
    return neutral(key, row);
  const interfaces = (row.global_interfaces || []).join(', ');
  if (row.state === 'warning')
    return {
      state: 'warning',
      key,
      value: withProvenance(
        _(
          'A global IPv6 address is on %s, but Prokop runs IPv4 only (IPv6 is disabled for the kernel or the loopback interface): IPv6 connections of devices pass Prokop and the kill-switch. Enable IPv6 on the router or turn IPv6 off for the devices.',
        ).replace('%s', interfaces),
        row,
      ),
    };
  return {
    state: 'success',
    key,
    value: withProvenance(
      interfaces
        ? _('Global IPv6 on %s; Prokop handles IPv6').replace('%s', interfaces)
        : _('No global IPv6 address'),
      row,
    ),
  };
}

export function clockItem(
  row: Prokop.EnvironmentCheckResult['clock'],
): IDiagnosticsChecksItem {
  const key = _('Router clock');
  if (!row || (row.state !== 'ok' && row.state !== 'warning'))
    return neutral(key, row);
  if (row.state === 'warning')
    return {
      state: 'warning',
      key,
      value: withProvenance(
        _(
          'Not synchronized: TLS and Reality connections and subscription downloads may fail while the time is wrong. Check NTP in System → System.',
        ),
        row,
      ),
    };
  return {
    state: 'success',
    key,
    value: withProvenance(
      typeof row.stratum === 'number'
        ? _('Synchronized, stratum %d').replace('%d', String(row.stratum))
        : _('Synchronized'),
      row,
    ),
  };
}

export function environmentCheckState(items: IDiagnosticsChecksItem[]) {
  if (items.some((item) => item.state === 'warning'))
    return { state: 'warning' as const, description: _('Issues detected') };
  if (items.every((item) => item.state === 'neutral'))
    return {
      state: 'unsupported' as const,
      description: _('Not available for checking'),
    };
  return { state: 'success' as const, description: _('Checks passed') };
}

export async function runEnvironmentCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.ENVIRONMENT;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const result = await ProkopShellMethods.checkEnvironment();
  if (
    !result.success ||
    typeof result.data !== 'object' ||
    result.data === null
  ) {
    // An older backend has no such command; nothing is proven either way.
    updateCheckStore({
      order,
      code,
      title,
      description: _('Not available for checking'),
      state: 'unsupported',
      items: [],
    });
    return;
  }

  const data = result.data;
  const items = [
    flowOffloadingItem(data.flow_offloading),
    ipv6Item(data.ipv6),
    clockItem(data.clock),
  ];
  const { state, description } = environmentCheckState(items);
  updateCheckStore({ order, code, title, description, state, items });
}
