import { describe, expect, it } from 'vitest';

import { sampleFromConnections, trafficSpeed } from '../clashTraffic';

describe('connections snapshot sampling', () => {
  it('reads totals, connection count and memory', () => {
    expect(
      sampleFromConnections(
        {
          downloadTotal: 2000,
          uploadTotal: 500,
          connections: [{}, {}, {}],
          memory: 4096,
        },
        10,
      ),
    ).toEqual({
      downloadTotal: 2000,
      uploadTotal: 500,
      connections: 3,
      memory: 4096,
      at: 10,
    });
  });

  it('tolerates a partial or broken payload', () => {
    expect(sampleFromConnections(null, 0)).toBeNull();
    expect(sampleFromConnections({ downloadTotal: 'x' }, 0)).toEqual({
      downloadTotal: 0,
      uploadTotal: 0,
      connections: 0,
      memory: 0,
      at: 0,
    });
  });
});

describe('traffic speed', () => {
  const sample = (down: number, up: number, at: number) => ({
    downloadTotal: down,
    uploadTotal: up,
    connections: 0,
    memory: 0,
    at,
  });

  it('needs a previous sample', () => {
    expect(trafficSpeed(null, sample(100, 10, 1000))).toBeNull();
  });

  it('divides the byte difference by the elapsed seconds', () => {
    expect(trafficSpeed(sample(1000, 100, 0), sample(5000, 300, 2000))).toEqual(
      { down: 2000, up: 100 },
    );
  });

  it('starts over after a counter reset or a clock that did not advance', () => {
    expect(trafficSpeed(sample(5000, 300, 0), sample(10, 5, 2000))).toBeNull();
    expect(
      trafficSpeed(sample(1000, 100, 2000), sample(2000, 200, 2000)),
    ).toBeNull();
  });
});
