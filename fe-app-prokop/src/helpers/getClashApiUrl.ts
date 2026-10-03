function getWindowLocation(): Location | undefined {
  return typeof window !== 'undefined' ? window.location : undefined;
}

// Clash API authentication (UC-035): mirrors clash_api_secret() in the
// backend (core/common.uc). A secret is in effect exactly when this value is
// not empty, whatever the YACD and WAN access settings say.
export function getClashApiSecretFromSettings(settings?: {
  yacd_secret_key?: string;
}): string {
  return `${settings?.yacd_secret_key ?? ''}`.trim();
}

function normalizeHost(host: string) {
  return host
    .trim()
    .replace(/^\[(.*)\]$/, '$1')
    .toLowerCase();
}

// Direct controller access from the browser (HTTP and WebSocket) is an admin
// feature: it needs the Clash API secret, which read-only sessions never
// receive. Without it the pages poll through rpcd, where the backend holds
// the secret.
// The page host must also be one of the router addresses the backend reports
// for the controller (get_dashboard_runtime_metadata clashControllerHosts):
// LuCI opened through a tunnel or a proxy (e.g. http://127.0.0.1:8080) would
// otherwise read, and send the secret to, a controller on another machine
// (UC-125).
export function canUseDirectClashApi(
  secret: string,
  routerHosts: readonly string[],
): boolean {
  const location = getWindowLocation();

  if (
    secret.trim() === '' ||
    typeof location?.hostname !== 'string' ||
    location.hostname === '' ||
    location.protocol === 'https:'
  ) {
    return false;
  }

  const hostname = normalizeHost(location.hostname);

  return routerHosts.some((host) => normalizeHost(host) === hostname);
}

export function getClashWsUrl(): string {
  const { hostname } = window.location;

  return `ws://${hostname}:9090`;
}

// Browsers cannot set headers on a WebSocket, so the controller takes the
// secret as the token query parameter.
export function getClashWsStreamUrl(path: string, secret: string): string {
  return `${getClashWsUrl()}${path}?token=${encodeURIComponent(secret)}`;
}

export function getClashHttpUrl(): string {
  const { hostname } = window.location;

  return `http://${hostname}:9090`;
}

export function getClashUIUrl(): string {
  const { hostname } = window.location;

  return `http://${hostname}:9090/ui`;
}
