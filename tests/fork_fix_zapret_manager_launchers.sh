#!/usr/bin/env bash
# Zapret-Manager launchers that older releases wrote for the former upstream
# mirror (or that Prokop wrote for another mirror) keep downloading and running
# the script from that host. Every package postinst rewrites Prokop's own
# launchers for the current mirror setting; a launcher that is missing, not a
# regular file or not written by Prokop is never touched, an up-to-date one is
# not rewritten, and a failed rewrite never fails the package.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
ACTION_UC="$PROKOP_LIB/components/action.uc"
PACKAGE_UC="$PROKOP_LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"
trap 'chmod -R u+w "$WORK_DIR" 2>/dev/null || true; rm -rf "$WORK_DIR"' EXIT
BIN="$WORK_DIR/bin"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$BIN" "$WORK_DIR/run" "$WORK_DIR/root" "$WORK_DIR/expected"

# What upstream builds wrote: the former upstream mirror, no Prokop marker.
cat >"$WORK_DIR/expected/legacy" <<'EOF'
#!/bin/sh
export ZAPRET_MANAGER_MIRROR='https://mirror.infotechtg.ru'
exec sh <(wget -q -O - 'https://mirror.infotechtg.ru/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') "$@"
EOF
# What this release writes for another (no longer configured) mirror.
cat >"$WORK_DIR/expected/other-mirror" <<'EOF'
#!/bin/sh
# Prokop Zapret-Manager launcher
export ZAPRET_MANAGER_MIRROR='https://old-mirror.test'
exec sh <(wget -q -O - 'https://old-mirror.test/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') "$@"
EOF
cat >"$WORK_DIR/expected/direct" <<'EOF'
#!/bin/sh
# Prokop Zapret-Manager launcher
exec sh <(wget -q -O - 'https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') "$@"
EOF
cat >"$WORK_DIR/expected/mirrored" <<'EOF'
#!/bin/sh
# Prokop Zapret-Manager launcher
export ZAPRET_MANAGER_MIRROR='https://own-mirror.test'
exec sh <(wget -q -O - 'https://own-mirror.test/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') "$@"
EOF
cat >"$WORK_DIR/expected/foreign" <<'EOF'
#!/bin/sh
exec /opt/zapret-manager "$@"
EOF

# install NAME FIXTURE [MODE]
install_launcher() {
  rm -f "$BIN/$1"
  cp "$WORK_DIR/expected/$2" "$BIN/$1"
  chmod "${3:-0755}" "$BIN/$1"
}

assert_launcher() {
  cmp -s "$WORK_DIR/expected/$2" "$BIN/$1" ||
    fail "$3: $1 is not the $2 launcher: $(cat "$BIN/$1" 2>/dev/null || printf 'missing')"
}

# reconcile MIRROR: the step components/action.uc runs for package postinst.
reconcile() {
  PROKOP_MIRROR_BASE_URL="$1" PROKOP_ZAPRET_MANAGER_BIN_DIR="$BIN" PROKOP_LIB="$PROKOP_LIB" \
    ucode -L "$PROKOP_LIB" "$ACTION_UC" reconcile-zapret-manager-launchers
}

# postinst MIRROR: the whole package postinst, isolated from the host.
printf '%s\n' "config settings 'settings'" >"$WORK_DIR/config-prokop"
cp "$WORK_DIR/config-prokop" "$WORK_DIR/default-prokop"
printf '%s\n' 'prokop.settings=settings' >"$WORK_DIR/config.state"
postinst() {
  PROKOP_PACKAGE_TEST_MODE=1 \
  PROKOP_LIB="$PROKOP_LIB" \
  PROKOP_MIRROR_BASE_URL="$1" \
  PROKOP_ZAPRET_MANAGER_BIN_DIR="$BIN" \
  PROKOP_CONFIG_PATH="$WORK_DIR/config-prokop" \
  PROKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-prokop" \
  PROKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  PROKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running" \
  PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
  PROKOP_EXPLICIT_START_FILE="$WORK_DIR/run/start.explicit" \
  PROKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK_DIR/component-update-checks" \
  PROKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK_DIR/component-update-check.timestamp" \
  PROKOP_LEGACY_GUARD_ROOT="$WORK_DIR/root" \
    ucode -L "$PROKOP_LIB" "$PACKAGE_UC" postinst
}

# 1. Package postinst without a mirror: the upstream launchers stop naming the
# former upstream mirror and run the project's own script.
install_launcher zms legacy
install_launcher zmsA legacy
postinst '' >"$WORK_DIR/postinst.out" 2>&1 || fail "package postinst failed: $(cat "$WORK_DIR/postinst.out")"
assert_launcher zms direct "postinst without a mirror"
assert_launcher zmsA direct "postinst without a mirror"
[ -x "$BIN/zms" ] && [ -x "$BIN/zmsA" ] || fail "a rewritten launcher is no longer executable"
if grep -Fq 'mirror.infotechtg.ru' "$BIN/zms" "$BIN/zmsA"; then
  fail "a launcher still downloads from the former upstream mirror"
fi
printf 'PASS: package postinst moves upstream launchers off the former mirror\n'

# 2. Up-to-date launchers are not rewritten.
out="$(reconcile '')" || fail "reconciling up-to-date launchers failed"
[ -z "$out" ] || fail "up-to-date launchers were rewritten: $out"
assert_launcher zms direct "repeated reconciliation"
printf 'PASS: up-to-date launchers stay as they are\n'

# 3. An opted-in mirror (trailing slash normalised) takes over direct
# launchers and launchers written for another mirror.
install_launcher zmsA other-mirror
reconcile 'https://own-mirror.test/' >/dev/null || fail "reconciling for an opted-in mirror failed"
assert_launcher zms mirrored "opted-in mirror"
assert_launcher zmsA mirrored "opted-in mirror"
postinst 'https://own-mirror.test' >"$WORK_DIR/postinst.out" 2>&1 ||
  fail "package postinst with the same mirror failed: $(cat "$WORK_DIR/postinst.out")"
assert_launcher zms mirrored "postinst with the same mirror"
printf 'PASS: launchers follow an opted-in mirror\n'

# 4. Launchers Prokop did not write, and links, are never touched; a missing
# launcher is never created.
install_launcher zms foreign
install_launcher zmsA legacy
reconcile '' >/dev/null || fail "reconciling next to a foreign launcher failed"
assert_launcher zms foreign "foreign launcher"
assert_launcher zmsA direct "Prokop launcher next to a foreign one"

rm -f "$BIN/zms" "$BIN/zmsA"
cp "$WORK_DIR/expected/legacy" "$WORK_DIR/legacy-target"
ln -s "$WORK_DIR/legacy-target" "$BIN/zmsA"
install_launcher zms legacy
reconcile '' >/dev/null || fail "reconciling next to a linked launcher failed"
assert_launcher zms direct "launcher next to a link"
[ -L "$BIN/zmsA" ] && cmp -s "$WORK_DIR/expected/legacy" "$WORK_DIR/legacy-target" ||
  fail "a linked launcher or its target was rewritten"
rm -f "$BIN/zmsA"
install_launcher zms legacy
reconcile '' >/dev/null || fail "reconciling a single launcher failed"
assert_launcher zms direct "single launcher"
[ ! -e "$BIN/zmsA" ] && [ ! -L "$BIN/zmsA" ] || fail "a missing launcher was created"
printf 'PASS: foreign, linked and missing launchers are left alone\n'

# 5. A launcher that cannot be rewritten only warns: the package still
# installs. (root ignores file permissions, so only an unprivileged run can
# check it.)
if [ "$(id -u)" -ne 0 ]; then
  install_launcher zms legacy 0555
  install_launcher zmsA legacy
  if reconcile '' >/dev/null 2>&1; then
    fail "a failed rewrite was reported as success"
  fi
  assert_launcher zmsA direct "launcher next to a read-only one"
  install_launcher zmsA legacy
  postinst '' >"$WORK_DIR/postinst.out" 2>&1 ||
    fail "a failed launcher rewrite failed the package postinst: $(cat "$WORK_DIR/postinst.out")"
  grep -Fq 'Unable to update the Zapret-Manager launchers' "$WORK_DIR/postinst.out" ||
    fail "a failed launcher rewrite was not reported"
  assert_launcher zmsA direct "postinst next to a read-only launcher"
  printf 'PASS: a failed launcher rewrite only warns\n'
fi

printf 'fork fix zapret-manager launchers: PASS\n'
