#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
NFT_APPLY_UC="$PROKOP_LIB/nft/apply.uc"
IP_UC="$PROKOP_LIB/core/ip.uc"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The Discord community subnet list also carries shared Cloudflare Anycast
# ranges. Routed as ordinary destination subnets they capture large amounts of
# unrelated traffic, torrents included. They must reach nftables only through
# Discord's own UDP media ports, while Discord's dedicated networks keep the
# ordinary treatment.

ucode -L "$PROKOP_LIB" -e '
let ip = require("core.ip");

// Shared Cloudflare ranges are recognised, Discord-owned ones are not.
for (let value in [ "104.16.0.0/12", "162.159.0.0/16", "2606:4700::/32" ])
    if (!ip.is_cloudflare_shared_cidr(value)) {
        warn("shared Cloudflare range not recognised: " + value + "\n");
        exit(1);
    }
for (let value in [ "66.22.192.0/18", "35.214.0.0/16", "1.2.3.4/32", "" ])
    if (ip.is_cloudflare_shared_cidr(value)) {
        warn("non-Cloudflare range wrongly classified: " + value + "\n");
        exit(1);
    }
// Matching must not depend on letter case in the IPv6 forms.
if (!ip.is_cloudflare_shared_cidr("2606:4700::/32") || !ip.is_cloudflare_shared_cidr("2606:4700::/32"))
    exit(1);
// Discord media ports cover voice, video and the STUN port.
for (let part in [ "3478", "50000-65535", "5000-5020", "19294-19344" ])
    if (index(ip.DISCORD_VOICE_PORTS_NFT, part) < 0) {
        warn("missing Discord media port range: " + part + "\n");
        exit(1);
    }
' || fail "core/ip.uc must classify shared Cloudflare ranges and Discord media ports"

# The split itself is a source contract: the shared ranges must go to the
# UDP-scoped sets, never to the plain subnet sets.
awk '
  /^function nft_add_community_subnet_file_for_section\(/ { inside = 1 }
  inside && /nft_community_subnet_lines\(filepath, service, true\)/  { shared = NR }
  inside && /nft_community_subnet_lines\(filepath, service, false\)/ { dedicated = NR }
  inside && /sets\.udp_ip_ports, sets\.udp_ip6_ports/ { udp = NR }
  inside && /DISCORD_VOICE_PORTS_NFT/ { ports = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && shared && dedicated && udp && ports && udp > shared ? 0 : 1 }
' "$NFT_APPLY_UC" || fail "shared Cloudflare ranges must be added to the UDP port sets with the Discord media ports"

# Any other service keeps the untouched path, so the dedicated Cloudflare list
# is not silently narrowed along with Discord.
grep -Fq 'if (as_string(service) != "discord")' "$NFT_APPLY_UC" ||
  fail "only the Discord list may be split"

# The narrowed rules must exist only when the section really enables Discord.
awk '
  /^function section_priority_needs_udp_ip_port_rules\(/ { inside = 1 }
  inside && /"discord"/ { matched = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && matched ? 0 : 1 }
' "$NFT_APPLY_UC" || fail "the UDP-scoped rules must be gated on the Discord list"

grep -Fq 'udp_ip_ports: prefix + "_udp_ip_ports"' "$NFT_APPLY_UC" ||
  fail "each section needs its own UDP-scoped ip/port sets"
grep -Fq 'nft_create_ipv4_port_set(table, sets.udp_ip_ports)' "$NFT_APPLY_UC" ||
  fail "the UDP-scoped sets must be created with the other priority sets"

grep -Fq 'CLOUDFLARE_SHARED_CIDRS' "$IP_UC" ||
  fail "the shared Cloudflare ranges must stay in one place"

printf 'discord cloudflare split checks passed\n'
