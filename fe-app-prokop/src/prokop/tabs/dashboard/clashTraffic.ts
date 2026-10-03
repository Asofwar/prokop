// Widget data from successive `clash_api get_connections` snapshots, for
// pages that cannot reach the controller websocket (HTTPS LuCI, a dropped
// socket). The speed is the change of the byte totals between snapshots.

export interface ConnectionsSample {
  downloadTotal: number;
  uploadTotal: number;
  connections: number;
  memory: number;
  // Milliseconds timestamp of the sample.
  at: number;
}

function counter(value: unknown) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : 0;
}

export function sampleFromConnections(
  payload: unknown,
  at: number,
): ConnectionsSample | null {
  if (!payload || typeof payload !== 'object') {
    return null;
  }

  const data = payload as Record<string, unknown>;
  return {
    downloadTotal: counter(data.downloadTotal),
    uploadTotal: counter(data.uploadTotal),
    connections: Array.isArray(data.connections) ? data.connections.length : 0,
    memory: counter(data.memory),
    at,
  };
}

// Bytes per second, or null until a comparable previous sample exists.
// A counter that went down means sing-box restarted: start over.
export function trafficSpeed(
  previous: ConnectionsSample | null,
  next: ConnectionsSample,
): { up: number; down: number } | null {
  if (!previous) {
    return null;
  }

  const seconds = (next.at - previous.at) / 1000;
  const down = next.downloadTotal - previous.downloadTotal;
  const up = next.uploadTotal - previous.uploadTotal;
  if (seconds <= 0 || down < 0 || up < 0) {
    return null;
  }

  return { up: Math.round(up / seconds), down: Math.round(down / seconds) };
}
