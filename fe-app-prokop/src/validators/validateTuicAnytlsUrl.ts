import { ValidationResult } from './types';
import { isValidPort, parseHostPort } from './hostPort';
import { parseQueryString } from '../helpers/parseQueryString';
import { certificatePinsError } from './validateCertificatePins';

// R4: tuic://uuid:password@host:port?... and anytls://password@host:port?...
// (subscription/parser.uc process_tuic, process_anytls).
export function validateTuicAnytlsUrl(url: string): ValidationResult {
  const isTuic = url.startsWith('tuic://');
  const isAnyTls = url.startsWith('anytls://');
  const name = isTuic ? 'TUIC' : 'AnyTLS';

  try {
    if (!isTuic && !isAnyTls) {
      return {
        valid: false,
        message: _('URL must start with tuic:// or anytls://'),
      };
    }

    if (/\s/.test(url)) {
      return {
        valid: false,
        message: _('Invalid %s URL: must not contain spaces').replace(
          '%s',
          name,
        ),
      };
    }

    const body = url.slice(isTuic ? 'tuic://'.length : 'anytls://'.length);
    const [mainPart] = body.split('#');
    const queryIndex = mainPart.indexOf('?');
    const authority = (
      queryIndex >= 0 ? mainPart.slice(0, queryIndex) : mainPart
    ).replace(/\/$/, '');
    const queryString = queryIndex >= 0 ? mainPart.slice(queryIndex + 1) : '';
    const at = authority.lastIndexOf('@');
    const userPart = at >= 0 ? authority.slice(0, at) : '';
    const hostPortPart = at >= 0 ? authority.slice(at + 1) : authority;

    if (!userPart || (isTuic && !userPart.split(':')[0])) {
      return {
        valid: false,
        message: isTuic
          ? _('Invalid TUIC URL: missing UUID')
          : _('Invalid AnyTLS URL: missing password'),
      };
    }

    const parsedHostPort = parseHostPort(hostPortPart);
    if (!parsedHostPort || !parsedHostPort.host) {
      return {
        valid: false,
        message: _('Invalid %s URL: invalid host and port').replace('%s', name),
      };
    }

    if (!isValidPort(parsedHostPort.port)) {
      return {
        valid: false,
        message: _('Invalid %s URL: invalid port number').replace('%s', name),
      };
    }

    const params = queryString ? parseQueryString(queryString) : {};
    if (
      isAnyTls &&
      params.security !== undefined &&
      !['', 'tls', 'reality'].includes(params.security)
    ) {
      return {
        valid: false,
        message: _('Invalid AnyTLS URL: AnyTLS always uses TLS'),
      };
    }

    const pinError = certificatePinsError(params);
    if (pinError) {
      return { valid: false, message: pinError };
    }
  } catch (_e) {
    return {
      valid: false,
      message: _('Invalid %s URL: parsing failed').replace('%s', name),
    };
  }

  return { valid: true, message: _('Valid') };
}
