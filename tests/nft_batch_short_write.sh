#!/usr/bin/env bash
# The nft candidate batch and the guard batches live in tmpfs. When it is
# full, ucode's write() and close() still report success while the data is
# lost (stdio writes on close and that error is dropped). A candidate cut at
# a line boundary passes `nft -c` and would replace the live table without
# the lost rules or set elements, and an empty guard batch "installs" no
# guard. Every append is checked, and a short one fails the preparation
# before the batch reaches nft (UC-223). The files the batch is built from
# are checked the same way: the subnets of a rule set or of a domain/IP
# list extracted into an empty file are no subnets, and the module appended
# nothing and reported success; the kill-switch DNS chain batch written
# empty "switched" the chain without changing it. A full tmpfs in a mount
# namespace; a batch on /dev/full (writes lost the same way) where no mount
# namespace can be made.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin"
cat >"$WORK/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$NFT_LOG"
if [ "$1 $2" = "list chain" ] && [ -n "${NFT_KS_CHAIN:-}" ]; then
  printf 'table inet ProkopKillswitch {\n\tchain ks_dns {\n\t}\n}\n'
  exit 0
fi
[ "$1" = list ] && exit 1
exit 0
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod +x "$WORK/bin/"*
printf '149.154.160.0/20\n91.108.4.0/22\n2001:db8::/32\n' >"$WORK/subnets.txt"
printf 'example.org\n198.51.100.0/24\n' >"$WORK/mixed.txt"
cat >"$WORK/fixture.json" <<'JSON'
{ "section": [ { ".name": "all", ".type": "section", "enabled": "1", "action": "proxy", "ip_cidr": [ "192.0.2.9" ] } ] }
JSON
printf '{"version":3,"rules":[{"ip_cidr":["198.51.100.0/24","203.0.113.0/24"]}]}\n' >"$WORK/rules.json"

cat >"$WORK/full.sh" <<'SH'
set -euo pipefail
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
FULL="$WORK/full"
mkdir -p "$FULL"
mount -t tmpfs -o size=16k tmpfs "$FULL"
trap 'umount "$FULL" 2>/dev/null || true' EXIT
export PATH="$WORK/bin:$PATH" NFT_LOG="$WORK/nft.log"
nft_uc() { ucode -L "$LIB" "$LIB/nft/apply.uc" "$@"; }
# fill: take every free block of the tmpfs.
fill() { head -c 65536 /dev/zero >"$FULL/fill.$1" 2>/dev/null || true; }

# A page-aligned candidate on a full tmpfs: the appended set elements are
# lost, yet the batch still ends at a line boundary.
batch="$FULL/candidate.nft"
{ printf '# Prokop nft candidate\n'; head -c 4072 /dev/zero | tr '\0' '#'; printf '\n'; } >"$batch"
[ "$(stat -c %s "$batch")" -eq 4096 ] || fail "the fixture batch is not page-aligned"
fill 1
: >"$NFT_LOG"
if PROKOP_NFT_BATCH_FILE="$batch" nft_uc nft-add-file-chunks-to-set "$WORK/subnets.txt" ProkopTable prokop_subnets ips '' 5000; then
  fail "an append lost on a full tmpfs was reported as prepared ($(stat -c %s "$batch") bytes)"
fi
[ ! -s "$NFT_LOG" ] || fail "candidate preparation reached nft: $(cat "$NFT_LOG")"

# Several appends: the first fit in the batch's last page, a later one does
# not. The preparation fails at the short one.
rm -f "$FULL"/fill.* "$batch"
{ printf '# Prokop nft candidate\n'; head -c 3970 /dev/zero | tr '\0' '#'; printf '\n'; } >"$batch"
fill 2
before="$(stat -c %s "$batch")"
if PROKOP_NFT_BATCH_FILE="$batch" nft_uc nft-add-file-chunks-to-set "$WORK/subnets.txt" ProkopTable prokop_subnets ips '' 1; then
  fail "a candidate whose later appends were lost was reported as prepared ($before -> $(stat -c %s "$batch") bytes)"
fi
[ "$(stat -c %s "$batch")" -gt "$before" ] || fail "the fixture did not let the first append through"

# The same preparation with room is complete.
rm -f "$FULL"/fill.* "$batch"
printf '# Prokop nft candidate\n' >"$batch"
PROKOP_NFT_BATCH_FILE="$batch" nft_uc nft-add-file-chunks-to-set "$WORK/subnets.txt" ProkopTable prokop_subnets ips '' 1 ||
  fail "a candidate with room was not prepared"
[ "$(grep -c '^add element inet ProkopTable prokop_subnets ' "$batch")" -eq 3 ] || fail "the candidate with room lost elements: $(cat "$batch")"

# The guard batches are written whole into a temporary file: an empty one
# passes `nft -c` and `nft -f` and installs nothing.
rm -f "$batch"
mkdir -p "$FULL/tmp"
fill 3
: >"$NFT_LOG"
if TMPDIR="$FULL/tmp" nft_uc install-transition-guard ProkopTable 0x04000000; then
  fail "a transition guard lost on a full tmpfs was reported as installed"
fi
! grep -q -- '-f ' "$NFT_LOG" || fail "an empty transition guard batch reached nft: $(cat "$NFT_LOG")"
: >"$NFT_LOG"
if TMPDIR="$FULL/tmp" nft_uc install-dpi-transition-guard ProkopTable; then
  fail "a DPI guard lost on a full tmpfs was reported as installed"
fi
! grep -q -- '-f ' "$NFT_LOG" || fail "an empty DPI guard batch reached nft: $(cat "$NFT_LOG")"

# The subnets of a JSON rule set are extracted into files in tmpfs, then
# appended. The batch has room left in its last page, the extraction files
# have none: an empty extraction is not a rule set without subnets.
rm -rf "$FULL"/fill.* "$FULL/tmp"
{ printf '# Prokop nft candidate\n'; head -c 2000 /dev/zero | tr '\0' '#'; printf '\n'; } >"$batch"
fill 4
if PROKOP_NFT_SUBNET_CACHE_DIR="$FULL/cache" PROKOP_NFT_BATCH_FILE="$batch" nft_uc nft-add-json-ruleset-subnets-for-section-fixture \
  "$WORK/fixture.json" all "$WORK/rules.json" "Rule set test" ProkopTable s4 p4 "$FULL/u" "$FULL/s" 5000 s6 p6; then
  fail "a rule set whose extracted subnets were lost was reported as prepared: $(grep -c 'add element' "$batch") elements"
fi
if ucode -L "$LIB" "$LIB/routing/rulesets.uc" extract-ip-cidr-nft "$WORK/rules.json" "$FULL/u" "$FULL/s"; then
  fail "an extraction lost on a full tmpfs was reported as written ($(stat -c %s "$FULL/u") bytes)"
fi
# A domain/IP list is split into its domains and subnets the same way.
if nft_uc split-domain-subnet-file "$WORK/mixed.txt" "$FULL/d" "$FULL/n"; then
  fail "a domain/IP list split lost on a full tmpfs was reported as written ($(stat -c %s "$FULL/n") bytes)"
fi

# The kill-switch DNS chain is switched by a batch in a temporary file: an
# empty one passes `nft -f` and changes nothing.
mkdir -p "$FULL/tmp"
: >"$NFT_LOG"
if TMPDIR="$FULL/tmp" NFT_KS_CHAIN=1 PROKOP_RUNTIME_STATE_DIR="$WORK/run" KILLSWITCH_STATE_DIR="$WORK/ks" \
  ucode -L "$LIB" "$LIB/killswitch/runtime.uc" dns-redirect on; then
  fail "a kill-switch DNS batch lost on a full tmpfs was reported as applied"
fi
! grep -q -- '^-f ' "$NFT_LOG" || fail "an empty kill-switch DNS batch reached nft: $(cat "$NFT_LOG")"
SH

# Everywhere: a batch on /dev/full takes every write and keeps nothing, as a
# full tmpfs does, and write() and close() report success the same way.
: >"$WORK/nft.log"
if PATH="$WORK/bin:$PATH" NFT_LOG="$WORK/nft.log" PROKOP_NFT_BATCH_FILE=/dev/full \
  ucode -L "$LIB" "$LIB/nft/apply.uc" nft-add-file-chunks-to-set "$WORK/subnets.txt" ProkopTable prokop_subnets ips '' 5000; then
  fail "appends lost on /dev/full were reported as prepared"
fi

export WORK LIB
if unshare --mount true 2>/dev/null; then
  unshare --mount bash "$WORK/full.sh" || fail "full tmpfs"
elif unshare --user --map-root-user --mount true 2>/dev/null; then
  unshare --user --map-root-user --mount bash "$WORK/full.sh" || fail "full tmpfs"
else
  # Nothing above ran on a full tmpfs: say so instead of PASS.
  printf 'SKIP: nft_batch_short_write: no mount namespace for a full tmpfs; only the /dev/full case ran\n'
  exit 0
fi

printf 'nft_batch_short_write: PASS\n'
