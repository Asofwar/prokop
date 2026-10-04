import { ValidationResult } from './types';
import { isIPv4, isIPv6 } from './validateIp';

export function validateSubnet(value: string): ValidationResult {
  const [ip, cidr, extra] = value.split('/');

  if (!ip || extra !== undefined || (!isIPv4(ip) && !isIPv6(ip))) {
    return {
      valid: false,
      message: _('Invalid format. Use an IP address or CIDR subnet'),
    };
  }

  if ((ip === '0.0.0.0' || ip === '::') && cidr == null) {
    return {
      valid: false,
      message: _('Unspecified IP address is not allowed'),
    };
  }

  if (cidr !== undefined) {
    // No empty prefix ('1.2.3.4/') and no leading zero ('/08'), which
    // sing-box refuses (FE-6).
    if (!/^(?:0|[1-9]\d{0,2})$/.test(cidr)) {
      return {
        valid: false,
        message: _('Invalid CIDR prefix'),
      };
    }

    const cidrNum = parseInt(cidr, 10);
    const maxPrefix = isIPv6(ip) ? 128 : 32;

    if (cidrNum < 0 || cidrNum > maxPrefix) {
      return {
        valid: false,
        message: _(
          'CIDR must be between 0 and 32 for IPv4 or 0 and 128 for IPv6',
        ),
      };
    }
  }

  return { valid: true, message: _('Valid') };
}
