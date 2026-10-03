#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# Run only against this fresh fake root, never against the host filesystem.
FAKE_ROOT="$WORK_DIR/root"
mkdir -p "$FAKE_ROOT/etc/opkg" "$FAKE_ROOT/etc/config" "$FAKE_ROOT/www" \
  "$FAKE_ROOT/tmp/forkop-full-uninstall.lock" "$FAKE_ROOT/var/run/forkop/component-action.lock" \
  "$WORK_DIR/job" "$WORK_DIR/bin"
printf '%s\n' 'src/gz openwrt https://mirror.51343.ru/openwrt/releases/test' > "$FAKE_ROOT/etc/opkg/distfeeds.conf"
printf '%s\n' 'keep my subscriptions' > "$FAKE_ROOT/etc/config/forkop"
# Prevent the asynchronous status cleanup from delaying the isolated test.
printf '#!/bin/sh\nexit 1\n' > "$WORK_DIR/bin/sleep"
chmod +x "$WORK_DIR/bin/sleep"
if PATH="$WORK_DIR/bin:$PATH" FORKOP_UNINSTALL_ROOT="$FAKE_ROOT" \
  FORKOP_MIRROR_BASE_URL=https://mirror.51343.ru \
  sh "$ROOT_DIR/forkop/files/usr/lib/full-uninstall.sh" worker \
  "$WORK_DIR/job" "$FAKE_ROOT/www/state.json" > "$WORK_DIR/log" 2>&1; then
  echo 'FAIL: removal must refuse to proceed without original repositories' >&2
  exit 1
fi
grep -Fq 'Cannot restore original repositories' "$WORK_DIR/log"
grep -Fq '"state":"failed","phase":"preflight"' "$FAKE_ROOT/www/state.json"
grep -Fxq 'keep my subscriptions' "$FAKE_ROOT/etc/config/forkop"
test ! -d "$FAKE_ROOT/tmp/forkop-full-uninstall.lock"
test ! -d "$FAKE_ROOT/var/run/forkop/component-action.lock"

# fresh_root FEED: a fake root whose only feed is FEED, without saved originals.
fresh_root() {
  rm -rf "$FAKE_ROOT" "$WORK_DIR/job"
  mkdir -p "$FAKE_ROOT/etc/opkg" "$FAKE_ROOT/etc/config" "$FAKE_ROOT/www" \
    "$FAKE_ROOT/tmp/forkop-full-uninstall.lock" "$FAKE_ROOT/var/run/forkop/component-action.lock" \
    "$WORK_DIR/job"
  printf '%s\n' "$1" > "$FAKE_ROOT/etc/opkg/distfeeds.conf"
  printf '%s\n' 'keep my subscriptions' > "$FAKE_ROOT/etc/config/forkop"
}
# Package managers and UCI are stubs: nothing outside the fake root is touched.
for tool in apk opkg; do printf '#!/bin/sh\nexit 1\n' > "$WORK_DIR/bin/$tool"; done
printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/bin/uci"
chmod +x "$WORK_DIR/bin/"*

# The mirror is opt-in: with none configured (UCI empty, variable unset) a feed
# on the former upstream mirror is still recognised and must be restorable.
fresh_root 'src/gz openwrt https://mirror.infotechtg.ru/openwrt/releases/test'
if env -u FORKOP_MIRROR_BASE_URL PATH="$WORK_DIR/bin:$PATH" FORKOP_UNINSTALL_ROOT="$FAKE_ROOT" \
  sh "$ROOT_DIR/forkop/files/usr/lib/full-uninstall.sh" worker \
  "$WORK_DIR/job" "$FAKE_ROOT/www/state.json" > "$WORK_DIR/log" 2>&1; then
  echo 'FAIL: removal must recognise the former upstream mirror without a configured one' >&2
  exit 1
fi
grep -Fq 'Cannot restore original repositories' "$WORK_DIR/log"

# An empty mirror setting must not mark every feed as mirrored.
fresh_root 'src/gz vendor https://packages.vendor.example/24.10/base'
FORKOP_MIRROR_BASE_URL='' PATH="$WORK_DIR/bin:$PATH" FORKOP_UNINSTALL_ROOT="$FAKE_ROOT" \
  sh "$ROOT_DIR/forkop/files/usr/lib/full-uninstall.sh" worker \
  "$WORK_DIR/job" "$FAKE_ROOT/www/state.json" > "$WORK_DIR/log" 2>&1 || {
  echo 'FAIL: removal without a mirror refused a feed on another host' >&2
  cat "$WORK_DIR/log" >&2
  exit 1
}
grep -Fq '"state":"complete"' "$FAKE_ROOT/www/state.json"
grep -Fxq 'src/gz vendor https://packages.vendor.example/24.10/base' "$FAKE_ROOT/etc/opkg/distfeeds.conf"
printf 'full uninstall preflight checks passed\n'
