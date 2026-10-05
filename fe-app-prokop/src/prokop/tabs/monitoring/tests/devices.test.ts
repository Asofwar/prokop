import { describe, expect, it } from 'vitest';

import {
  DEVICE_TRAFFIC_POLL_INTERVAL_MS,
  RouteUsageTracker,
  counterRates,
  counterSample,
  deviceLabel,
  deviceRows,
  type TrackedConnection,
} from '../devices';
import type { Prokop } from '../../../types';

function traffic(
  devices: Array<[string, number, number]>,
  since: number | null = 1000,
): Prokop.DeviceTraffic {
  return {
    state: 'ok',
    since,
    now: 2000,
    offload: 'none',
    interfaces: ['br-lan'],
    devices: devices.map(([address, tx, rx]) => ({
      address,
      family: address.includes(':') ? 6 : 4,
      tx_bytes: tx,
      tx_packets: 1,
      rx_bytes: rx,
      rx_packets: 1,
    })),
  };
}

function connection(
  id: string,
  ip: string,
  key: string,
  upload: number,
  download: number,
): TrackedConnection {
  return {
    id,
    ip,
    key,
    label: key.replace(/^rule:/, ''),
    kind: 'connection',
    upload,
    download,
  };
}

describe('device rows', () => {
  it('adds up the addresses of one device (same MAC) and sorts by traffic', () => {
    const rows = deviceRows(
      traffic([
        ['192.168.1.20', 10, 20],
        ['fd00::5', 300, 4000],
        ['192.168.1.5', 100, 1000],
        ['192.168.1.30', 1, 1],
      ]),
      {
        '192.168.1.5': { name: 'Phone', mac: 'aa' },
        'fd00::5': { name: '', mac: 'aa' },
        '192.168.1.20': { name: 'TV', mac: 'bb' },
      },
      {},
    );
    expect(rows.map((row) => row.addresses)).toEqual([
      ['192.168.1.5', 'fd00::5'],
      ['192.168.1.20'],
      ['192.168.1.30'],
    ]);
    expect(rows[0]).toMatchObject({
      name: 'Phone',
      txBytes: 400,
      rxBytes: 5000,
      txRate: null,
    });
    expect(deviceLabel(rows[0])).toBe('Phone (192.168.1.5)');
    expect(deviceLabel(rows[2])).toBe('192.168.1.30');
  });

  it('never merges addresses without a known MAC', () => {
    const rows = deviceRows(
      traffic([
        ['192.168.1.5', 1, 1],
        ['192.168.1.6', 1, 1],
      ]),
      {
        '192.168.1.5': { name: 'Same', mac: '' },
        '192.168.1.6': { name: 'Same', mac: '' },
      },
      {},
    );
    expect(rows).toHaveLength(2);
  });
});

describe('device rows from observed MACs', () => {
  it('puts addresses with the MAC of the neighbour table together and names them by MAC (TRF-3)', () => {
    const data = traffic([
      ['192.168.1.5', 100, 1000],
      ['2001:db8::abcd', 10, 10],
      ['fe80::5', 1, 1],
    ]);
    data.devices.forEach((device) => {
      device.mac = 'AA:BB:CC:00:00:05';
    });
    const rows = deviceRows(
      data,
      { '192.168.9.9': { name: 'Phone', mac: 'aa:bb:cc:00:00:05' } },
      {},
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].addresses).toEqual([
      '192.168.1.5',
      '2001:db8::abcd',
      'fe80::5',
    ]);
    expect(rows[0].name).toBe('Phone');
  });

  it('keeps the addresses behind one MAC with several IPv4 addresses apart (TRF-4)', () => {
    const data = traffic([
      ['192.168.1.5', 100, 1000],
      ['192.168.1.6', 10, 10],
    ]);
    data.devices.forEach((device) => {
      device.mac = 'aa:bb:cc:00:00:01';
    });
    const rows = deviceRows(
      data,
      {
        '192.168.1.5': { name: 'Laptop', mac: 'aa:bb:cc:00:00:01' },
        '192.168.1.6': { name: '', mac: 'aa:bb:cc:00:00:01' },
      },
      {},
    );
    expect(rows.map((row) => [row.name, row.addresses])).toEqual([
      ['Laptop', ['192.168.1.5']],
      ['', ['192.168.1.6']],
    ]);
  });
});

describe('counter rates', () => {
  it('reports bytes per second between two readings of the same counters', () => {
    const first = counterSample(traffic([['192.168.1.5', 1000, 5000]]), 0);
    const next = counterSample(traffic([['192.168.1.5', 4000, 11000]]), 3000);
    expect(counterRates(first, next)).toEqual({
      '192.168.1.5': { tx: 1000, rx: 2000 },
    });
    const rows = deviceRows(
      traffic([['192.168.1.5', 4000, 11000]]),
      {},
      counterRates(first, next),
    );
    expect(rows[0]).toMatchObject({ txRate: 1000, rxRate: 2000 });
  });

  it('reports no speed across rebuilt counters or a long gap', () => {
    const first = counterSample(traffic([['192.168.1.5', 1000, 5000]]), 0);
    expect(
      counterRates(
        first,
        counterSample(traffic([['192.168.1.5', 2000, 6000]], 1500), 3000),
      ),
    ).toEqual({});
    expect(
      counterRates(
        first,
        counterSample(traffic([['192.168.1.5', 10, 10]]), 3000),
      ),
    ).toEqual({});
    expect(
      counterRates(
        first,
        counterSample(traffic([['192.168.1.5', 2000, 6000]]), 60000),
      ),
    ).toEqual({});
    expect(counterRates(null, first)).toEqual({});
    // A start dated from the uptime moves by a second between readings.
    expect(
      counterRates(
        first,
        counterSample(traffic([['192.168.1.5', 4000, 11000]], 1001), 3000),
      ),
    ).toEqual({ '192.168.1.5': { tx: 1000, rx: 2000 } });
  });
});

describe('route usage', () => {
  it('keeps the last count of a finished connection and adds the live ones', () => {
    const tracker = new RouteUsageTracker();
    tracker.observe([
      connection('1', '192.168.1.5', 'rule:YouTube', 100, 900),
      connection('2', '192.168.1.5', 'rule:Telegram', 10, 20),
      connection('3', '192.168.1.9', 'rule:YouTube', 5, 5),
    ]);
    tracker.observe([
      connection('2', '192.168.1.5', 'rule:Telegram', 50, 50),
      connection('4', '192.168.1.5', 'rule:YouTube', 0, 1000),
    ]);
    expect(tracker.usage(['192.168.1.5'])).toEqual([
      {
        key: 'rule:YouTube',
        label: 'YouTube',
        kind: 'connection',
        bytes: 2000,
      },
      {
        key: 'rule:Telegram',
        label: 'Telegram',
        kind: 'connection',
        bytes: 100,
      },
    ]);
    expect(tracker.usage(['192.168.1.9'])).toEqual([
      { key: 'rule:YouTube', label: 'YouTube', kind: 'connection', bytes: 10 },
    ]);
    expect(Array.from(tracker.activeAddresses())).toEqual(['192.168.1.5']);
    tracker.reset();
    expect(tracker.usage(['192.168.1.5'])).toEqual([]);
  });

  it('leaves out connections without an id or a source address', () => {
    const tracker = new RouteUsageTracker();
    tracker.observe([
      connection('', '192.168.1.5', 'rule:A', 1, 1),
      connection('1', '', 'rule:A', 1, 1),
    ]);
    expect(tracker.usage(['192.168.1.5', ''])).toEqual([]);
  });
});

describe('device traffic polling', () => {
  // Each read runs ucode and nft on the router: not more often than every
  // 5 s while the Devices page is open.
  it('reads the counters every 5 s', () => {
    expect(DEVICE_TRAFFIC_POLL_INTERVAL_MS).toBe(5000);
  });
});
