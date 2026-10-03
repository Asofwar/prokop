#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
SCRIPT="$LIB/diagnostics/connectivity.uc"
if ucode -L "$LIB" "$SCRIPT" fixture 'bad;touch /tmp/prokop-injected' TCP 443 0 >/dev/null; then exit 1; fi
node - "$LIB" "$SCRIPT" <<'JS'
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const [lib, script] = process.argv.slice(2);
const run = (mode, host, type, port, status = '0', output = '') =>
  JSON.parse(execFileSync('ucode', ['-L', lib, script, mode, host, type, port, status, output]));
const args = (host, type, port) => run('fixture-args', host, type, port);
const probe = (host, type, port, status, output) => run('fixture', host, type, port, status, output);
const invalid = (host, type, port) => assert.throws(() => run('fixture', host, type, port));

// No probe depends on an external `timeout` binary (absent on OpenWrt busybox).
for (const [host, type, port] of [['example.org', 'DNS', ''], ['192.0.2.1', 'TCP', '443'],
  ['example.org', 'HTTP', ''], ['example.org', 'HTTPS', ''], ['example.org', 'TLS', '']]) {
  const argv = args(host, type, port);
  assert.notEqual(argv[0], 'timeout');
  assert.equal(argv.includes('timeout'), false);
}
assert.deepEqual(args('example.org', 'DNS', '').slice(0, 3), ['dig', '+timeout=3', '+tries=1']);
const tcp = args('192.0.2.1', 'TCP', '443');
assert.equal(tcp[0], 'curl');
assert.ok(tcp.includes('--connect-timeout') && tcp.includes('--max-time'));

// URLs, default and custom ports, IPv6 brackets.
assert.equal(args('192.0.2.1', 'TCP', '443').at(-1), 'http://192.0.2.1:443/');
assert.equal(args('example.org', 'HTTP', '').at(-1), 'http://example.org:80/');
assert.equal(args('example.org', 'HTTPS', '').at(-1), 'https://example.org:443/');
assert.equal(args('example.org', 'HTTPS', '8443').at(-1), 'https://example.org:8443/');
assert.equal(args('192.0.2.1', 'TLS', '443').at(-1), 'https://192.0.2.1:443/');
assert.equal(args('2001:db8::1', 'TCP', '443').at(-1), 'http://[2001:db8::1]:443/');
assert.equal(args('2001:db8::1', 'HTTPS', '443').at(-1), 'https://[2001:db8::1]:443/');
assert.equal(args('2001:db8::1', 'HTTP', '80').at(-1), 'http://[2001:db8::1]:80/');
assert.equal(args('::ffff:192.0.2.1', 'HTTPS', '443').at(-1), 'https://[::ffff:192.0.2.1]:443/');
for (const host of ['[2001:db8::1]', '[[2001:db8::1]]', 'fe80::1%eth0', 'bad;id', ''])
  invalid(host, 'HTTP', '80');
invalid('example.org', 'TCP', '');
invalid('example.org', 'TCP', '65536');
invalid('example.org', 'SMTP', '25');
invalid('192.0.2.1', 'DNS', '');

// DNS verdicts.
let r = probe('example.org', 'DNS', '', '0',
  ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\nexample.org.\t300\tIN\tA\t93.184.216.34\n');
assert.deepEqual([r.status, r.error, r.type, r.port, r.origin, r.address], ['ok', null, 'DNS', null, 'router', '93.184.216.34']);
r = probe('nonexistent.invalid', 'DNS', '', '0', ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 2\n');
assert.deepEqual([r.status, r.error], ['error', 'nxdomain']);
r = probe('example.org', 'DNS', '', '0', ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 3\n');
assert.deepEqual([r.status, r.error], ['error', 'no_answer']);
r = probe('example.org', 'DNS', '', '9', ';; communications error to 127.0.0.1#53: timed out\n');
assert.deepEqual([r.status, r.error], ['timeout', 'timeout']);
r = probe('example.org', 'DNS', '', '0', ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 4\n');
assert.deepEqual([r.status, r.error], ['error', 'dns_failed']);

// TCP verdicts: the handshake is what counts, not the application answer.
r = probe('192.0.2.1', 'TCP', '443', '0', '0.007201 0.014373 400');
assert.deepEqual([r.status, r.error, r.type, r.port, r.latency_ms], ['ok', null, 'TCP', 443, 7]);
r = probe('192.0.2.1', 'TCP', '853', '56', '0.007295 0.014298 000');
assert.equal(r.status, 'ok');
r = probe('127.0.0.1', 'TCP', '1', '7', '0.000000 0.000377 000');
assert.deepEqual([r.status, r.error], ['error', 'connect_failed']);
r = probe('192.0.2.1', 'TCP', '443', '28', '0.000000 3.000816 000');
assert.deepEqual([r.status, r.error, r.latency_ms], ['timeout', 'timeout', 3000]);
r = probe('nonexistent.invalid', 'TCP', '80', '6', '0.000000 0.000688 000');
assert.deepEqual([r.status, r.error], ['error', 'dns_failed']);

// HTTP/HTTPS verdicts; the result type always matches the request.
r = probe('example.org', 'HTTP', '', '0', '0.203080 0.375152 200');
assert.deepEqual([r.status, r.type, r.port, r.http_code, r.latency_ms], ['ok', 'HTTP', 80, 200, 375]);
r = probe('cloudflare.com', 'HTTPS', '', '0', '0.012834 0.187748 301');
assert.deepEqual([r.status, r.type, r.port, r.http_code], ['ok', 'HTTPS', 443, 301]);
r = probe('cloudflare.com', 'TLS', '443', '0', '0.012834 0.187748 301');
assert.equal(r.type, 'HTTPS');
r = probe('expired.badssl.com', 'HTTPS', '', '60', '0.051068 0.373359 000');
assert.deepEqual([r.status, r.error], ['error', 'tls_failed']);
r = probe('example.org', 'HTTP', '', '52', '0.100000 0.200000 000');
assert.deepEqual([r.status, r.error], ['error', 'no_response']);
r = probe('example.org', 'HTTPS', '', '127', '');
assert.deepEqual([r.status, r.error], ['error', 'tool_missing']);
JS
printf 'connectivity: PASS\n'
