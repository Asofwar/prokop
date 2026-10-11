#!/usr/bin/env bash
set -euo pipefail

# The FakeIP ranges must stay outside what dnsmasq's DNS rebind protection
# (rebind_protection=1 on OpenWrt, --stop-dns-rebind) treats as private:
# dnsmasq drops such answers from its upstream, which for Prokop is sing-box.
# dnsmasq 2.80..2.91 src/rfc1035.c private_net() / private_net6():
#   IPv4: 0/8, 127/8 (with rebind-localhost-ok off), 10/8, 100.64/10,
#         172.16/12, 192.168/16, 169.254/16, 192.0.2/24, 198.51.100/24,
#         203.0.113/24, 255.255.255.255
#   IPv6: ::, ::1, fe80::/10, fec0::/10, fd00::/8, 2001:db8::/32 and
#         IPv4-mapped private addresses
# Notably fc00::/8 is not in the list, so fc00::/18 passes.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"

ranges="$(ucode -L "$LIB" -e '
let sb = require("singbox.constants");
print(sb.FAKEIP_INET4_RANGE, " ", sb.FAKEIP_INET6_RANGE, "\n");
') $(ucode -L "$LIB" "$LIB/core/constants.uc" get SB_FAKEIP_INET4_RANGE) $(ucode -L "$LIB" "$LIB/core/constants.uc" get SB_FAKEIP_INET6_RANGE)"
# shellcheck disable=SC2086
set -- $ranges
[ "$1" = "$3" ] || { echo "FAIL: FakeIP IPv4 range differs: $1 vs $3" >&2; exit 1; }
[ "$2" = "$4" ] || { echo "FAIL: FakeIP IPv6 range differs: $2 vs $4" >&2; exit 1; }

node - "$1" "$2" <<'JS'
const [v4, v6] = process.argv.slice(2);
function v4num(a) { return a.split('.').reduce((n, o) => n * 256 + Number(o), 0); }
function v6big(a) {
  let [h, t] = a.split('::');
  const head = h ? h.split(':') : [];
  const tail = t !== undefined && t ? t.split(':') : [];
  const parts = [...head, ...Array(8 - head.length - tail.length).fill('0'), ...tail];
  return parts.reduce((n, p) => (n << 16n) + BigInt(parseInt(p || '0', 16)), 0n);
}
function overlaps(cidr, block, family) {
  const [a, l] = cidr.split('/'); const [b, m] = block.split('/');
  const bits = family === 4 ? 32 : 128;
  const p = BigInt(Math.min(Number(l), Number(m)));
  const conv = family === 4 ? (x) => BigInt(v4num(x)) : v6big;
  const shift = BigInt(bits) - p;
  return (conv(a) >> shift) === (conv(b) >> shift);
}
const private4 = ['0.0.0.0/8', '127.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '172.16.0.0/12',
  '192.168.0.0/16', '169.254.0.0/16', '192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24',
  '255.255.255.255/32'];
const private6 = ['::/128', '::1/128', 'fe80::/10', 'fec0::/10', 'fd00::/8', '2001:db8::/32',
  '::ffff:0:0/96'];
for (const block of private4)
  if (overlaps(v4, block, 4)) throw Error(`FakeIP ${v4} overlaps dnsmasq private ${block}`);
for (const block of private6)
  if (overlaps(v6, block, 6)) throw Error(`FakeIP ${v6} overlaps dnsmasq private ${block}`);
// Self-check of the overlap test: the range NetShift moved away from would fail.
if (!overlaps('fd00::/18', 'fd00::/8', 6) || overlaps('fc00::/18', 'fd00::/8', 6))
  throw Error('overlap self-check failed');
JS
echo "PASS: FakeIP ranges are outside dnsmasq rebind-protected ranges"
