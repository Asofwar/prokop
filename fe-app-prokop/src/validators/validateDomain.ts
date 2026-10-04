import { ValidationResult } from './types';

// What the router accepts in a domain (config/domain.uc, FE-4): letters,
// digits and hyphens of any script, and dots. Nothing the browser would drop
// or decode before checking: an invisible character (zero-width space, soft
// hyphen) the router keeps and then never matches, or `?`, `#`, `%` that
// the router refuses.
function hasInvisible(value: string): boolean {
  for (const ch of value) {
    const cp = ch.codePointAt(0) ?? 0;
    if (
      cp === 0xad ||
      cp === 0x34f ||
      (cp >= 0x180b && cp <= 0x180f) ||
      (cp >= 0x200b && cp <= 0x200f) ||
      (cp >= 0x202a && cp <= 0x202e) ||
      (cp >= 0x2060 && cp <= 0x2064) ||
      (cp >= 0xfe00 && cp <= 0xfe0f) ||
      cp === 0xfeff
    )
      return true;
  }
  return false;
}
const HOSTNAME_CHARACTERS = /^[\p{L}\p{M}\p{N}.-]+$/u;

function asciiHostname(hostname: string): string | null {
  if (
    !hostname ||
    hasInvisible(hostname) ||
    !HOSTNAME_CHARACTERS.test(hostname) ||
    hostname.startsWith('.') ||
    hostname.endsWith('.')
  ) {
    return null;
  }

  try {
    return new URL(`http://${hostname}`).hostname;
  } catch {
    return null;
  }
}

function validAsciiDomain(hostname: string, requireDot = true): boolean {
  if (!hostname || hostname.length > 253) {
    return false;
  }

  const parts = hostname.split('.');

  if (parts.some((part) => !part || part.length > 63)) {
    return false;
  }

  if (parts.some((part) => !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(part))) {
    return false;
  }

  if (!requireDot) {
    return true;
  }

  if (parts.length < 2) {
    return false;
  }

  const tld = parts[parts.length - 1];
  // Digits are allowed with a letter (.i2p); an all-digit one would be an
  // address.
  return (
    /^(?:[a-z0-9]{2,63}|xn--[a-z0-9-]{2,59})$/.test(tld) && /[a-z]/.test(tld)
  );
}

export function validateDomain(
  domain: string,
  allowDotTLD = false,
): ValidationResult {
  // Before trim(): it drops U+FEFF, which the router keeps.
  if (hasInvisible(`${domain || ''}`)) {
    return { valid: false, message: _('Invalid domain address') };
  }
  const normalized = `${domain || ''}`.trim();

  if (allowDotTLD) {
    const dotTld = normalized.startsWith('.') ? normalized.slice(1) : '';
    const ascii = asciiHostname(dotTld);
    if (ascii && !ascii.includes('.') && validAsciiDomain(ascii, false)) {
      return { valid: true, message: _('Valid') };
    }
  }

  const slashIndex = normalized.indexOf('/');
  const hostname =
    slashIndex >= 0 ? normalized.slice(0, slashIndex) : normalized;
  const path = slashIndex >= 0 ? normalized.slice(slashIndex) : '';

  if (path && /\s/.test(path)) {
    return { valid: false, message: _('Invalid domain address') };
  }

  const ascii = asciiHostname(hostname);

  if (!ascii || !validAsciiDomain(ascii)) {
    return { valid: false, message: _('Invalid domain address') };
  }

  return { valid: true, message: _('Valid') };
}
