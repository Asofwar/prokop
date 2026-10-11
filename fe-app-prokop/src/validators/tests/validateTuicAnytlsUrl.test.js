import { describe, it, expect } from 'vitest';
import { validateTuicAnytlsUrl } from '../validateTuicAnytlsUrl';
import { validateProxyUrl } from '../validateProxyUrl';

const HEX_PIN = Array(32).fill('AB').join(':');
const B64_PIN = Buffer.alloc(32, 7).toString('base64');

describe('validateTuicAnytlsUrl', () => {
  it.each([
    'tuic://11111111-2222-3333-4444-555555555555:p%40ss@tuic.example.com:8443?congestion_control=bbr&alpn=h3&sni=tuic.example.com#n',
    'tuic://11111111-2222-3333-4444-555555555555@[2001:db8::1]:443',
    `tuic://11111111-2222-3333-4444-555555555555:pw@t.example.com:443?pinSHA256=${HEX_PIN}`,
    'anytls://se%23cret@any.example.com:8443?sni=any.example.com&insecure=1#node',
    'anytls://pw@any.example.com:443/?sni=a.example.com',
    `anytls://pw@any.example.com:443?pcs=${encodeURIComponent(B64_PIN)}`,
  ])('accepts %s', (url) => {
    expect(validateTuicAnytlsUrl(url).valid).toBe(true);
    expect(validateProxyUrl(url).valid).toBe(true);
  });

  it.each([
    'tuic://:pw@tuic.example.com:443',
    'tuic://uuid@tuic.example.com',
    'tuic://uuid@tuic.example.com:70000',
    'anytls://any.example.com:443',
    'anytls://pw@any.example.com:443?security=none',
    'anytls://pw@any example.com:443',
    'tuic://uuid:pw@t.example.com:443?pinSHA256=abcd',
    'anytls://pw@a.example.com:443?pcs=not-a-hash',
  ])('refuses %s', (url) => {
    expect(validateTuicAnytlsUrl(url).valid).toBe(false);
    expect(validateProxyUrl(url).valid).toBe(false);
  });
});
