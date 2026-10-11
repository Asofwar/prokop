// Mirror of subscription/parser.uc certificate_pins: a link's certificate
// pins (pinSHA256, pcs) are SHA-256 hashes of the whole certificate, as hex
// (colons allowed) or base64, separated by commas. The backend refuses a
// node whose pin it cannot read, so the form refuses it first.
const PIN_KEYS = ['pinSHA256', 'pinsha256', 'pcs'];

function validPin(value: string): boolean {
  const hex = value.replace(/:/g, '');
  if (/^[0-9A-Fa-f]{64}$/.test(hex)) {
    return true;
  }

  return /^[A-Za-z0-9+/_-]{43}=?$/.test(value);
}

export function certificatePinsError(
  params: Record<string, string>,
): string | undefined {
  const key = PIN_KEYS.find((name) => (params[name] || '') !== '');
  if (!key) {
    return undefined;
  }

  const items = params[key]
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
  if (!items.length || !items.every(validPin)) {
    return _(
      'The certificate pin must be the SHA-256 of the certificate as 64 hex digits or base64',
    );
  }

  return undefined;
}
