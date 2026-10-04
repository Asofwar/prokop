import { ValidationResult } from './types';

export function isIPv4(ip: string): boolean {
  const ipRegex =
    /^(?:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$/;

  return ipRegex.test(ip);
}

// The hextets themselves, as the router parses them (core/ip.uc), not the
// browser's URL parser, which takes 'fd00::1]?' or '::1]#junk' (FE-6).
function ipv6PartsCount(parts: string[]): number {
  let count = 0;
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part.includes('.')) {
      if (i !== parts.length - 1 || !isIPv4(part)) return -1;
      count += 2;
    } else if (/^[0-9A-Fa-f]{1,4}$/.test(part)) {
      count++;
    } else {
      return -1;
    }
  }
  return count;
}

export function isIPv6(ip: string): boolean {
  if (!ip.includes(':')) {
    return false;
  }

  const marker = ip.indexOf('::');
  if (marker < 0) {
    return ipv6PartsCount(ip.split(':')) === 8;
  }
  const left = ip.slice(0, marker);
  const right = ip.slice(marker + 2);
  if (right.includes('::')) {
    return false;
  }
  const leftCount = left === '' ? 0 : ipv6PartsCount(left.split(':'));
  const rightCount = right === '' ? 0 : ipv6PartsCount(right.split(':'));
  return leftCount >= 0 && rightCount >= 0 && leftCount + rightCount < 8;
}

export function validateIP(ip: string): ValidationResult {
  if (isIPv4(ip) || isIPv6(ip)) {
    return { valid: true, message: _('Valid') };
  }

  return { valid: false, message: _('Invalid IP address') };
}
