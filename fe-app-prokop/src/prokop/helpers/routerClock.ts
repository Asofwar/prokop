// The router's clock as seen from the browser. The two can differ by any
// amount (a router without NTP yet, a laptop set wrong), so the times the
// router reports are never compared with Date.now() directly.
//
// Every router time the UI receives was read at or before the moment it
// arrives, so browser time minus router time is never smaller than the real
// offset; the smallest difference seen is the closest estimate.

let offsetMs: number | null = null;

export function observeRouterTime(
  routerSeconds: unknown,
  browserNowMs: number = Date.now(),
) {
  if (
    typeof routerSeconds !== 'number' ||
    !Number.isFinite(routerSeconds) ||
    routerSeconds <= 0
  ) {
    return;
  }

  const candidate = browserNowMs - routerSeconds * 1000;

  if (offsetMs === null || candidate < offsetMs) {
    offsetMs = candidate;
  }
}

// The router's time now, in seconds; the browser's while no router time
// has been seen.
export function routerNowSeconds(browserNowMs: number = Date.now()) {
  return (browserNowMs - (offsetMs ?? 0)) / 1000;
}

export function resetRouterClock() {
  offsetMs = null;
}
