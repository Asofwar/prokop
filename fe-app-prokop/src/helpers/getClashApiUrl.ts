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

// Direct controller access from the browser (HTTP and WebSocket) is an admin
// feature: it needs the Clash API secret, which read-only sessions never
// receive. Without it the pages poll through rpcd, where the backend holds
// the secret.
export function canUseDirectClashApi(secret: string): boolean {
  const location = getWindowLocation();

  return (
    secret.trim() !== '' &&
    typeof location?.hostname === 'string' &&
    location.hostname !== '' &&
    location.protocol !== 'https:'
  );
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
