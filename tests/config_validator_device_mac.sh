#!/usr/bin/env bash
set -euo pipefail

# Devices by MAC address in the device options (Device filter, Exclude
# devices, Forced device routing): a value written like a MAC must be a
# usable unicast one, and sing-box below 1.14 (no source_mac_address) is
# refused at start with a clear message. Address-only configurations pass
# as before.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/tmp"
cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
SH
chmod 0755 "$WORK/bin/logger"

fixture() {
  cat >"$WORK/$1.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn",
    "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret" },
  "section": [
    { ".name": "tv", ".type": "section", "enabled": "1", "action": "bypass",
      "ip_cidr": [ "10.0.0.0/8" ], "$2": [ "192.168.1.5", "$3" ] }
  ]
}
JSON
}

validate() {
  : >"$WORK/logger.log"
  PATH="$WORK/bin:$PATH" LOGGER_LOG="$WORK/logger.log" PROKOP_LIB="$LIB" \
    ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/$1.json" '{}' >"$WORK/$1.out" 2>&1
}

for key in source_ip_cidr excluded_source_ip_cidr fully_routed_ips; do
  fixture "ok_$key" "$key" "AA-BB-CC-00-00-01"
  validate "ok_$key" || fail "$key: a unicast MAC must be accepted ($(cat "$WORK/ok_$key.out" "$WORK/logger.log"))"
  for bad in 01:00:5e:00:00:01 00:00:00:00:00:00 aa:bb-cc:00:00:01; do
    fixture "bad_$key" "$key" "$bad"
    if validate "bad_$key"; then
      fail "$key: '$bad' must be refused"
    fi
    grep -Fq "Rule 'tv' has an invalid device MAC address '$bad' in $key" "$WORK/bad_$key.out" "$WORK/logger.log" ||
      fail "$key: '$bad' must be named: $(cat "$WORK/bad_$key.out" "$WORK/logger.log")"
  done
done
fixture "ip_only" source_ip_cidr "192.168.1.0/24"
validate ip_only || fail "address-only device filter must pass as before ($(cat "$WORK/ip_only.out"))"

# sing-box version gate (check-requirements).
cat >"$WORK/bin/sing-box" <<'STUB'
#!/bin/sh
[ "${1:-}" = version ] || exit 1
echo "sing-box version ${STUB_SING_BOX_VERSION:?}"
STUB
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/nft"
chmod 0755 "$WORK/bin/sing-box" "$WORK/bin/nft"
cat >"$WORK/mac.state" <<'EOF'
prokop.settings=settings
prokop.tv=section
prokop.tv.enabled=1
prokop.tv.action=bypass
prokop.tv.ip_cidr=10.0.0.0/8
prokop.tv.source_ip_cidr=aa:bb:cc:00:00:01
EOF
sed '/source_ip_cidr/s/=.*/=192.168.1.5/' "$WORK/mac.state" >"$WORK/ip.state"

requirements() {
  : >"$WORK/logger.log"
  PATH="$WORK/bin:$PATH" LOGGER_LOG="$WORK/logger.log" STUB_SING_BOX_VERSION="$2" \
    PROKOP_UCI_STATE_FILE="$WORK/$1.state" PROKOP_UCI_LOG_FILE="$WORK/uci.log" \
    PROKOP_RUNTIME_STATE_DIR="$WORK/run" TMPDIR="$WORK/tmp" \
    ucode -L "$LIB" "$LIB/config/validator.uc" check-requirements >/dev/null 2>&1 || true
}
MESSAGE="Rule 'tv' selects devices by MAC address, which needs sing-box 1.14 or later (installed: 1.13.5)"
requirements mac 1.13.5
grep -Fq "$MESSAGE" "$WORK/logger.log" || fail "sing-box 1.13 with a MAC rule must be refused: $(cat "$WORK/logger.log")"
requirements mac 1.14.2
if grep -Fq "selects devices by MAC address" "$WORK/logger.log"; then
  fail "sing-box 1.14 accepts a MAC rule"
fi
requirements ip 1.13.5
if grep -Fq "selects devices by MAC address" "$WORK/logger.log"; then
  fail "an address-only configuration must not need sing-box 1.14"
fi

printf 'PASS: config_validator_device_mac\n'
