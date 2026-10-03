#!/usr/bin/env bash
# shellcheck disable=SC1003,SC2016 # literal $, \ and $(...) are test data
set -euo pipefail

# UC-001: rpcd file.exec applies the caller's "env" table to the child, so a
# read-only LuCI session could point PROKOP_*/UCI_*/TMP_*/PATH overrides of
# the backend at arbitrary binaries and files. The read ACL group may only run
# /usr/libexec/prokop-ro, which must start the CLI with a clean environment
# and pass argv through verbatim.
#
# The wrapper's target is a constant; the test rewrites it in a temporary copy
# so the check runs without root and without an installed package.
# PROKOP_RO_WRAPPER_UNDER_TEST lets the harness point at another wrapper copy
# (for example a pass-through one) to confirm the test catches a regression.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${PROKOP_RO_WRAPPER_UNDER_TEST:-$ROOT_DIR/prokop/files/usr/libexec/prokop-ro}"
PROKOP_BIN="$ROOT_DIR/prokop/files/usr/bin/prokop"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
TARGET='/usr/bin/prokop'
FIXED_PATH='/usr/sbin:/usr/bin:/sbin:/bin'
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

UCODE_BIN="$(command -v ucode)" || fail "ucode is required"
UCODE_DIR="$(dirname "$UCODE_BIN")"
TIMEOUT_BIN="$(command -v timeout)" || fail "timeout is required"

[ -r "$WRAPPER" ] || fail "read-only wrapper is missing: $WRAPPER"

# Temporary copy whose only difference is the target binary.
wrapper_for() {
  local target="$1"
  local copy="$2"
  sed "s|$TARGET \"\\\$@\"|$target \"\$@\"|" "$WRAPPER" >"$copy"
  chmod 0755 "$copy"
  grep -Fq "$target \"\$@\"" "$copy" || fail "could not retarget the wrapper copy"
}

# Hostile environment: every override points at a marker.
EVIL="$WORK_DIR/evil"
MARKS="$WORK_DIR/marks"
mkdir -p "$EVIL/bin" "$EVIL/lib/diagnostics" "$EVIL/lib/service" "$EVIL/sing-box" "$MARKS"
for name in env prokop ucode uci sing-box nft ip ping nslookup logread ubus pgrep pidof sh ash \
  nfqws nfqws2 ciadpi dnsmasq wget curl opkg apk; do
  cat >"$EVIL/bin/$name" <<EOF
#!/bin/sh
printf '%s %s\n' "$name" "\$*" >>"$MARKS/executed"
exit 0
EOF
  chmod 0755 "$EVIL/bin/$name"
done
for module in diagnostics/runtime.uc service/ui.uc; do
  printf 'import { writefile } from "fs";\nwritefile("%s/lib-loaded", "%s\\n");\n' \
    "$MARKS" "$module" >"$EVIL/lib/$module"
done
printf 'root:$6$SHADOWMARKER$hash:19000:0:99999:7:::\n' >"$EVIL/shadow"
printf 'prokop.main=section\nprokop.settings=settings\nprokop.settings.config_path=%s\n' \
  "$EVIL/shadow" >"$EVIL/uci-state"
for victim in version-cache system-info uci-log; do
  printf 'VICTIM-UNCHANGED\n' >"$EVIL/$victim"
done

HOSTILE_ENV=(
  "PROKOP_UI_SING_BOX_BIN_PATH=$EVIL/bin/sing-box"
  "PROKOP_UI_SING_BOX_VERSION_CACHE_FILE=$EVIL/version-cache"
  "PROKOP_CONFIG=$EVIL/shadow"
  "PROKOP_SYSTEM_INFO_CACHE_FILE=$EVIL/system-info"
  "PROKOP_SYSTEM_INFO_CACHE_TTL=0"
  "PROKOP_LIB=$EVIL/lib"
  "PROKOP_BIN=$EVIL/bin/prokop"
  "UCI_STATE=$EVIL/uci-state"
  "UCI_LOG=$EVIL/uci-log"
  "PROKOP_UCI_STATE_FILE=$EVIL/uci-state"
  "PROKOP_UCI_LOG_FILE=$EVIL/uci-log"
  "ZAPRET_NFQWS_BIN=$EVIL/bin/nfqws"
  "ZAPRET_PROVIDER_NFQWS_BIN=$EVIL/bin/nfqws"
  "ZAPRET2_PROVIDER_NFQWS2_BIN=$EVIL/bin/nfqws2"
  "BYEDPI_BIN=$EVIL/bin/ciadpi"
  "DNSMASQ_INIT=$EVIL/bin/dnsmasq"
  "TMP_SING_BOX_FOLDER=$EVIL/sing-box"
  "PATH=$EVIL/bin"
  "ENV=$EVIL/bin/sh"
  "IFS=/"
)

# 1. Exact environment and argv the CLI receives.
RECORD="$WORK_DIR/record"
cat >"$WORK_DIR/recorder" <<EOF
#!/bin/sh
/usr/bin/env >"$RECORD.env"
: >"$RECORD.argv"
for arg in "\$@"; do printf '[%s]\n' "\$arg" >>"$RECORD.argv"; done
EOF
chmod 0755 "$WORK_DIR/recorder"
wrapper_for "$WORK_DIR/recorder" "$WORK_DIR/prokop-ro.record"

/usr/bin/env -i "${HOSTILE_ENV[@]}" "$WORK_DIR/prokop-ro.record" \
  route_trace 'example.org; touch x' '' '$(id)' '*' 'a b' >/dev/null 2>&1 ||
  fail "wrapper copy failed to run the recorder"

[ -r "$RECORD.env" ] || fail "recorder was not executed through the fixed PATH"
env_names="$(sed -n 's/=.*//p' "$RECORD.env" | grep -Ev '^(PWD|SHLVL|_|OLDPWD)$' | LC_ALL=C sort | tr '\n' ' ')"
[ "$env_names" = "PATH " ] ||
  fail "CLI inherited caller environment: $env_names"
grep -Fxq "PATH=$FIXED_PATH" "$RECORD.env" || fail "CLI PATH is not the fixed one"
expected_argv="$(printf '[%s]\n' route_trace 'example.org; touch x' '' '$(id)' '*' 'a b')"
[ "$(cat "$RECORD.argv")" = "$expected_argv" ] ||
  fail "wrapper changed argv: $(cat "$RECORD.argv")"

# 2. Real read-only commands of the CLI under the same hostile environment.
# The trampoline stands in for /usr/bin/prokop: it only adds the repository
# library and the ucode location when the wrapper did not provide them.
cat >"$WORK_DIR/trampoline" <<EOF
#!/bin/sh
export PROKOP_LIB="\${PROKOP_LIB:-$PROKOP_LIB}"
export PATH="$UCODE_DIR:\$PATH"
exec "$UCODE_BIN" "$PROKOP_BIN" "\$@"
EOF
chmod 0755 "$WORK_DIR/trampoline"
wrapper_for "$WORK_DIR/trampoline" "$WORK_DIR/prokop-ro.cli"

# The wrapper hands the CLI production default paths, so the real commands
# would write caches under /var/run/prokop and /tmp/sing-box and global_check
# would reach the network. Run them in a private mount and network namespace
# with an empty /run and /tmp where available (as root, or through an
# unprivileged user namespace). Paths the test itself needs are bound back
# into the private /tmp when they live there.
ISOLATE=()
isolate_probe='mount -t tmpfs tmpfs /run && mkdir /run/host-tmp && mount --rbind /tmp /run/host-tmp &&
mount -t tmpfs tmpfs /tmp'
for needed in "$ROOT_DIR" "$UCODE_DIR" "$WORK_DIR"; do
  case "$needed" in
    /tmp/*)
      isolate_probe="$isolate_probe && mkdir -p $(printf '%q' "$needed") &&
mount --rbind $(printf '%q' "/run/host-tmp/${needed#/tmp/}") $(printf '%q' "$needed")"
      ;;
  esac
done
if unshare --mount --net --propagation private sh -c "$isolate_probe" 2>/dev/null; then
  ISOLATE=(unshare --mount --net --propagation private)
elif unshare --user --map-root-user --mount --net --propagation private \
  sh -c "$isolate_probe" 2>/dev/null; then
  ISOLATE=(unshare --user --map-root-user --mount --net --propagation private)
fi
if [ "${#ISOLATE[@]}" -gt 0 ]; then
  ISOLATE+=(sh -c "$isolate_probe && exec \"\$@\"" sh)
fi
run_state() {
  find /var/run/prokop -printf '%p %s %T@\n' 2>/dev/null | LC_ALL=C sort || true
}
run_state_before="$(run_state)"

for command in "get_ui_capabilities" "get_system_info" "global_check masked" \
  "show_sing_box_config masked" "check_zapret_runtime" "get_status"; do
  # shellcheck disable=SC2086
  "${ISOLATE[@]}" /usr/bin/env -i "${HOSTILE_ENV[@]}" "$TIMEOUT_BIN" 60 "$WORK_DIR/prokop-ro.cli" $command \
    >"$WORK_DIR/out" 2>&1 || true
  if grep -Fq 'SHADOWMARKER' "$WORK_DIR/out"; then
    fail "$command printed a file chosen by the caller environment"
  fi
  if [ "$command" = get_ui_capabilities ]; then
    # Guard against a vacuous pass: the real CLI must have run.
    grep -Fq '"sing_box_package"' "$WORK_DIR/out" ||
      fail "the real CLI did not run under the wrapper: $(head -c 300 "$WORK_DIR/out")"
  fi
done

[ "$(run_state)" = "$run_state_before" ] ||
  fail "read commands under test changed the host /var/run/prokop"

if [ -e "$MARKS/executed" ]; then
  fail "a binary chosen by the caller environment was executed: $(cat "$MARKS/executed")"
fi
[ ! -e "$MARKS/lib-loaded" ] || fail "modules were loaded from the caller's PROKOP_LIB"
for victim in version-cache system-info uci-log; do
  [ "$(cat "$EVIL/$victim")" = 'VICTIM-UNCHANGED' ] ||
    fail "file chosen by the caller environment was overwritten: $victim"
done
[ -z "$(ls -A "$EVIL/sing-box")" ] || fail "TMP_SING_BOX_FOLDER from the caller was used"

# Production contract (checked last so a regressed copy fails on behaviour): fixed target and PATH, no expansion besides "$@".
grep -Fxq "exec /usr/bin/env -i PATH=$FIXED_PATH $TARGET \"\$@\"" "$WRAPPER" ||
  fail "wrapper must exec the CLI through env -i with a fixed PATH"
if grep -v '^#' "$WRAPPER" | sed 's/"\$@"//' | grep -q '\$'; then
  fail "wrapper must not expand anything but \"\$@\""
fi
if grep -v '^#' "$WRAPPER" | grep -Eq '(^|[^[:alnum:]_])(eval|source)([^[:alnum:]_]|$)|(^|[[:space:]])\.[[:space:]]'; then
  fail "wrapper must not evaluate its input"
fi

# Both package builds install the wrapper as an executable.
grep -Fq 'install -m 0755 "$ROOT_DIR/prokop/files/usr/libexec/prokop-ro" "$output_root/usr/libexec/prokop-ro"' \
  "$ROOT_DIR/build.sh" || fail "build.sh does not install the read-only wrapper"
grep -Fq '"$output_root/usr/libexec/prokop-ro" \' "$ROOT_DIR/build.sh" ||
  fail "build.sh does not keep the read-only wrapper executable"
grep -Fq '$(INSTALL_BIN) ./files/usr/libexec/prokop-ro $(1)/usr/libexec/prokop-ro' \
  "$ROOT_DIR/prokop/Makefile" || fail "prokop/Makefile does not install the read-only wrapper"

printf 'read-only wrapper ignores the caller environment\n'
