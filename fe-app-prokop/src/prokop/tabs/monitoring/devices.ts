import type { Prokop } from '../../types';
import type { PathKind } from './connectionView';

// Monitoring > Devices. Two observed sources, kept apart because they count
// different things over different windows:
// - totals and speed: nft counters per LAN address on the router
//   (diagnostics/traffic.uc), all of a device's traffic since `since`;
// - the split by rule: sing-box's own connection counters, only for
//   connections that went through sing-box and were seen while this page
//   was open.

export interface DeviceHost {
  name: string;
  mac: string;
}

export type DeviceHosts = Record<string, DeviceHost>;

export interface RouteUse {
  key: string;
  label: string;
  kind: PathKind;
  bytes: number;
}

export interface TrackedConnection {
  id: string;
  ip: string;
  key: string;
  label: string;
  kind: PathKind;
  upload: number;
  download: number;
}

interface RouteTotals {
  label: string;
  kind: PathKind;
  bytes: number;
}

function addUse(
  target: Map<string, RouteTotals>,
  key: string,
  label: string,
  kind: PathKind,
  bytes: number,
) {
  const previous = target.get(key);
  target.set(key, {
    label: label || previous?.label || key,
    kind,
    bytes: (previous?.bytes || 0) + bytes,
  });
}

function connectionBytes(connection: TrackedConnection) {
  return (
    Math.max(0, Number(connection.upload) || 0) +
    Math.max(0, Number(connection.download) || 0)
  );
}

// sing-box reports each connection's bytes since it started; a connection
// that disappears from the list has ended and keeps its last count.
export class RouteUsageTracker {
  private live = new Map<string, TrackedConnection>();
  private finished = new Map<string, Map<string, RouteTotals>>();

  observe(connections: TrackedConnection[]) {
    const seen = new Set<string>();
    connections.forEach((connection) => {
      if (!connection.id || !connection.ip) return;
      seen.add(connection.id);
      this.live.set(connection.id, connection);
    });
    this.live.forEach((connection, id) => {
      if (seen.has(id)) return;
      this.live.delete(id);
      let routes = this.finished.get(connection.ip);
      if (!routes) {
        routes = new Map();
        this.finished.set(connection.ip, routes);
      }
      addUse(
        routes,
        connection.key,
        connection.label,
        connection.kind,
        connectionBytes(connection),
      );
    });
  }

  // Routes of the given addresses, most traffic first.
  usage(addresses: string[]): RouteUse[] {
    const wanted = new Set(addresses);
    const totals = new Map<string, RouteTotals>();
    this.finished.forEach((routes, ip) => {
      if (!wanted.has(ip)) return;
      routes.forEach((use, key) =>
        addUse(totals, key, use.label, use.kind, use.bytes),
      );
    });
    this.live.forEach((connection) => {
      if (!wanted.has(connection.ip)) return;
      addUse(
        totals,
        connection.key,
        connection.label,
        connection.kind,
        connectionBytes(connection),
      );
    });
    return Array.from(totals.entries())
      .map(([key, use]) => ({ key, ...use }))
      .filter((use) => use.bytes > 0)
      .sort((a, b) => b.bytes - a.bytes || a.label.localeCompare(b.label));
  }

  // Addresses with a connection open now.
  activeAddresses(): Set<string> {
    return new Set(Array.from(this.live.values(), (c) => c.ip));
  }

  reset() {
    this.live.clear();
    this.finished.clear();
  }
}

export interface CounterSample {
  at: number;
  since: number | null;
  bytes: Record<string, { tx: number; rx: number }>;
}

export function counterSample(
  traffic: Prokop.DeviceTraffic,
  at: number,
): CounterSample {
  const bytes: CounterSample['bytes'] = {};
  traffic.devices.forEach((device) => {
    bytes[device.address] = {
      tx: Number(device.tx_bytes) || 0,
      rx: Number(device.rx_bytes) || 0,
    };
  });
  return { at, since: traffic.since, bytes };
}

export interface AddressRate {
  tx: number;
  rx: number;
}

// The router dates a start from its uptime once the clock has moved
// (TRF-5): two readings of the same start may then differ by a second. A
// rebuild of the counters starts them anew, seconds or more apart.
function sameStart(a: number | null, b: number | null) {
  if (a == null || b == null) return a === b;
  return Math.abs(a - b) <= 2;
}

// Bytes per second between two readings of the same counters. None when the
// counters were rebuilt in between (a different start time, or a count that
// went down) or the readings are too close to tell.
// A gap longer than maxSeconds (a hidden page skipped its readings) would
// show an average over the gap as the current speed: none either.
export function counterRates(
  previous: CounterSample | null,
  next: CounterSample,
  maxSeconds = 15,
): Record<string, AddressRate> {
  const rates: Record<string, AddressRate> = {};
  if (!previous || !sameStart(previous.since, next.since)) return rates;
  const seconds = (next.at - previous.at) / 1000;
  if (!(seconds >= 0.5) || seconds > maxSeconds) return rates;
  Object.entries(next.bytes).forEach(([address, now]) => {
    const before = previous.bytes[address];
    if (!before || now.tx < before.tx || now.rx < before.rx) return;
    rates[address] = {
      tx: (now.tx - before.tx) / seconds,
      rx: (now.rx - before.rx) / seconds,
    };
  });
  return rates;
}

function isIpv4(address: string) {
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(address);
}

export function compareAddresses(a: string, b: string) {
  const a4 = isIpv4(a);
  const b4 = isIpv4(b);
  if (a4 !== b4) return a4 ? -1 : 1;
  if (a4) {
    const aParts = a.split('.').map(Number);
    const bParts = b.split('.').map(Number);
    for (let i = 0; i < 4; i += 1) {
      if (aParts[i] !== bParts[i]) return aParts[i] - bParts[i];
    }
    return 0;
  }
  return a.localeCompare(b);
}

export interface DeviceRow {
  key: string;
  name: string;
  // IPv4 first; the first one names the device next to its name.
  addresses: string[];
  txBytes: number;
  rxBytes: number;
  // null when there is no rate yet (first reading, counters rebuilt).
  txRate: number | null;
  rxRate: number | null;
}

function isIpv6LinkLocal(address: string) {
  return /^fe[89ab][0-9a-f]:/i.test(address);
}

// One row per device: addresses with the same MAC (IPv4 and the IPv6
// addresses of one device) are added up; an address the router knows no
// MAC for is a device of its own. The MAC is the one the router's
// neighbour table has now (observed, TRF-3), else the one of the host
// hints. A MAC with more than one IPv4 address is a repeater, relayd or a
// second router in front of several devices (TRF-4): its addresses stay
// rows of their own.
export function deviceRows(
  traffic: Prokop.DeviceTraffic,
  hosts: DeviceHosts,
  rates: Record<string, AddressRate>,
): DeviceRow[] {
  const observed = new Map(
    traffic.devices.map((device) => [device.address, device.mac || '']),
  );
  const macOf = (address: string) =>
    (observed.get(address) || hosts[address]?.mac || '').toLowerCase();
  const ipv4ByMac = new Map<string, number>();
  traffic.devices.forEach((device) => {
    const mac = macOf(device.address);
    if (mac && isIpv4(device.address))
      ipv4ByMac.set(mac, (ipv4ByMac.get(mac) || 0) + 1);
  });
  // The name a host hint gives the MAC, for addresses the hints do not
  // know yet (a new temporary IPv6 address).
  const nameByMac = new Map<string, string>();
  Object.values(hosts).forEach((host) => {
    const mac = (host.mac || '').toLowerCase();
    if (mac && host.name && !nameByMac.has(mac)) nameByMac.set(mac, host.name);
  });

  const rows = new Map<string, DeviceRow>();
  traffic.devices.forEach((device) => {
    const host = hosts[device.address];
    const mac = macOf(device.address);
    const shared = mac && (ipv4ByMac.get(mac) || 0) > 1;
    const key = mac && !shared ? `mac:${mac}` : `ip:${device.address}`;
    let row = rows.get(key);
    if (!row) {
      row = {
        key,
        name: '',
        addresses: [],
        txBytes: 0,
        rxBytes: 0,
        txRate: null,
        rxRate: null,
      };
      rows.set(key, row);
    }
    if (!row.name && host?.name) row.name = host.name;
    if (!row.name && mac && !shared) row.name = nameByMac.get(mac) || '';
    row.addresses.push(device.address);
    row.txBytes += Number(device.tx_bytes) || 0;
    row.rxBytes += Number(device.rx_bytes) || 0;
    const rate = rates[device.address];
    if (rate) {
      row.txRate = (row.txRate || 0) + rate.tx;
      row.rxRate = (row.rxRate || 0) + rate.rx;
    }
  });
  return Array.from(rows.values())
    .map((row) => ({
      ...row,
      // A link-local address never names the device.
      addresses: row.addresses.sort(
        (a, b) =>
          Number(isIpv6LinkLocal(a)) - Number(isIpv6LinkLocal(b)) ||
          compareAddresses(a, b),
      ),
    }))
    .sort(
      (a, b) =>
        b.txBytes + b.rxBytes - (a.txBytes + a.rxBytes) ||
        compareAddresses(a.addresses[0], b.addresses[0]),
    );
}

// "Name (IP)" as in the rule device pickers, or the address alone.
export function deviceLabel(row: DeviceRow) {
  const address = row.addresses[0] || '';
  return row.name ? `${row.name} (${address})` : address;
}
