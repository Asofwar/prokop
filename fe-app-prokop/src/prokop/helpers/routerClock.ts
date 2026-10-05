// The router's clock as seen from the browser. The two can differ by any
// amount (a router without NTP yet, a laptop set wrong), so the times the
// router reports are never compared with Date.now() directly.
//
// Every router time the UI receives was read at or before the moment it
// arrives, so browser time minus router time is never smaller than the real
// offset; the smallest difference seen is the closest estimate. The browser
// side is the page's monotonic clock, which a change of the computer's clock
// does not move, and the smallest difference is taken over the last minute
// only: a router whose clock steps back (NTP after boot) is followed within
// a minute instead of never (PRG-2).

const WINDOW_MS = 60_000;

let observations: { at: number; offset: number }[] = [];
let offsetMs: number | null = null;

// Epoch milliseconds that move with the page's monotonic clock.
export function browserNowMs() {
  if (
    typeof performance !== 'undefined' &&
    typeof performance.now === 'function' &&
    typeof performance.timeOrigin === 'number' &&
    performance.timeOrigin > 0
  ) {
    return performance.timeOrigin + performance.now();
  }
  return Date.now();
}

export function observeRouterTime(
  routerSeconds: unknown,
  nowMs: number = browserNowMs(),
) {
  if (
    typeof routerSeconds !== 'number' ||
    !Number.isFinite(routerSeconds) ||
    routerSeconds <= 0
  ) {
    return;
  }

  observations = observations.filter(
    (item) => item.at <= nowMs && nowMs - item.at < WINDOW_MS,
  );
  observations.push({ at: nowMs, offset: nowMs - routerSeconds * 1000 });
  offsetMs = Math.min(...observations.map((item) => item.offset));
}

// The router's time now, in seconds; the browser's while no router time
// has been seen.
export function routerNowSeconds(nowMs: number = browserNowMs()) {
  return (nowMs - (offsetMs ?? 0)) / 1000;
}

export function resetRouterClock() {
  observations = [];
  offsetMs = null;
}
