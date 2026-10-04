#!/usr/bin/env bash
set -euo pipefail

# One text of the managed sing-box init script (UC-085).
#
# A binary sing-box variant (the compressed sing-box-extended) comes without
# the package's init script, and Prokop installs its own: at a start
# (singbox/runtime.uc configure-service), at a component install, update or
# rollback (components/action.uc) and in the requirements check when there is
# none (config/validator.uc). Each writer carried its own copy of the text,
# and two of them still had `procd_set_param file`, which release 1.0.14 took
# out of the start's copy: after a component install, `/etc/init.d/sing-box
# start|reload` with a changed config.json made procd restart sing-box
# outside Prokop's controlled transitions, until the next start of Prokop
# rewrote the script. Now every writer writes one text, byte for byte,
# without `procd_set_param file`: a start after a component install has
# nothing to rewrite. A copy of the script that a crash left behind, named
# after a writer that is gone, is removed by a component install as by a
# start (UC-159); the copy of a writer still at work is kept.
#
# The writers run in a mount namespace with an /etc/init.d of their own
# (unshare -rm); without user and mount namespaces only the source checks
# run.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

# shellcheck source=tests/helpers/source_checks.sh
source "$ROOT_DIR/tests/helpers/source_checks.sh"

# ---- 1. one copy of the text in the source ---------------------------------------

source_refute "the managed sing-box init script must not have procd restart sing-box when config.json changes" \
  -F 'procd_set_param file' "$LIB"
instance_owners="$(grep -R -l -F 'procd_open_instance' "$LIB" | sed "s|^$LIB/||" | LC_ALL=C sort)"
[ -n "$instance_owners" ] || fail "no module writes the managed sing-box init script"
[ "$(printf '%s\n' "$instance_owners" | wc -l)" -eq 1 ] ||
  fail "the managed sing-box init script text has more than one copy: $(printf '%s\n' "$instance_owners" | tr '\n' ' ')"
ok "the managed sing-box init script text has one copy, without procd_set_param file"

# B10: sing-box gets 10 s after SIGTERM to write its FakeIP cache, inside the
# 15 s a controlled transition waits for it to end.
term_timeout="$(ucode -L "$LIB" -e 'print(require("singbox.managed_service").text())' |
  sed -n 's/^ *procd_set_param term_timeout \([0-9]*\)$/\1/p')"
[ -n "$term_timeout" ] || fail "the managed sing-box init script sets no term_timeout"
{ [ "$term_timeout" -gt 5 ] && [ "$term_timeout" -lt 15 ]; } ||
  fail "term_timeout $term_timeout is not between procd's 5 s and the 15 s transition wait"
ok "the managed sing-box init script gives sing-box $term_timeout s to stop"

# ---- 2. every writer writes the same script ---------------------------------------

if ! unshare -rm true 2>/dev/null; then
  printf 'NOTE: no user and mount namespaces; the init script writers are not run\n'
  printf 'singbox_managed_service_text: PASS\n'
  exit 0
fi

mkdir -p "$WORK/bin" "$WORK/run"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
printf '#!/bin/sh\necho "sing-box version 1.12.0"\n' >"$WORK/bin/sing-box"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/nft"
chmod 0755 "$WORK/bin/"*
printf 'extended-compressed\n' >"$WORK/variant"
printf '1.12.0\n' >"$WORK/version"
cat >"$WORK/uci.state" <<EOF
prokop.settings=settings
prokop.settings.config_path=$WORK/config.json
sing-box.main=sing-box
sing-box.main.enabled=1
sing-box.main.user=root
sing-box.main.conffile=$WORK/config.json
EOF
: >"$WORK/validator-uci.state"
# The requirements check keeps its temporary file in TMPDIR.
export PATH="$WORK/bin:$PATH" LIB WORK TMPDIR="$WORK"
export PROKOP_RUNTIME_STATE_DIR="$WORK/run" PROKOP_UCI_LOG_FILE="$WORK/uci.log"
export SB_VARIANT_STATE_FILE="$WORK/variant" SB_VERSION_STATE_FILE="$WORK/version"

# writer.sh DIR WRITER...: runs each WRITER with DIR as /etc/init.d.
cat >"$WORK/writer.sh" <<'SH'
set -e
mount --bind "$1" /etc/init.d
shift
for writer in "$@"; do
  case "$writer" in
    start)
      PROKOP_UCI_STATE_FILE="$WORK/uci.state" ucode -L "$LIB" "$LIB/singbox/runtime.uc" configure-service
      ;;
    component)
      ucode -L "$LIB" "$LIB/components/action.uc" install-managed-sing-box-service-fixture
      ;;
    requirements)
      # Fails later on the missing coreutils-base64; the script is
      # installed before that.
      PROKOP_UCI_STATE_FILE="$WORK/validator-uci.state" ucode -L "$LIB" "$LIB/config/validator.uc" check-requirements || true
      ;;
    stamp)
      stat -c '%i %y %s' /etc/init.d/sing-box >>"$WORK/stamps"
      ;;
  esac
done
SH
run_writers() {
  local dir="$1"
  shift
  unshare -rm sh "$WORK/writer.sh" "$dir" "$@" >"$WORK/writer.out" 2>&1 ||
    fail "the init script writers $* failed: $(cat "$WORK/writer.out")"
}

for writer in start component requirements; do
  mkdir -p "$WORK/initd-$writer"
  run_writers "$WORK/initd-$writer" "$writer"
  script="$WORK/initd-$writer/sing-box"
  [ -f "$script" ] || fail "the $writer writer did not install the managed init script: $(cat "$WORK/writer.out")"
  grep -q 'Prokop managed sing-box service for binary variants' "$script" ||
    fail "the script the $writer writer installs is not marked as Prokop's"
  [ "$(stat -c %a "$script")" = 755 ] || fail "the script the $writer writer installs is not executable"
  if grep -n -F 'procd_set_param file' "$script" >&2; then
    fail "the script the $writer writer installs has procd restart sing-box when config.json changes"
  fi
  # shellcheck disable=SC2016 # the script's own variables
  grep -q 'procd_set_param command "$PROG" run -c "$config_file"' "$script" ||
    fail "the script the $writer writer installs does not run sing-box"
  sh -n "$script" || fail "the script the $writer writer installs is not valid shell"
  [ -z "$(find "$WORK/initd-$writer" -name 'sing-box.*' -printf '%f ')" ] ||
    fail "the $writer writer left a copy of the init script"
done
cmp "$WORK/initd-start/sing-box" "$WORK/initd-component/sing-box" >&2 ||
  fail "a component install and a start write different init scripts"
cmp "$WORK/initd-start/sing-box" "$WORK/initd-requirements/sing-box" >&2 ||
  fail "the requirements check and a start write different init scripts"
ok "a start, a component install and the requirements check write the same init script"

# ---- 3. a start after a component install has nothing to rewrite ------------------

# The copies a crash left between write and rename: one of a writer that is
# gone, one of a writer still at work (this shell). The script in place is
# an older managed one, which the component install replaces.
mkdir -p "$WORK/initd-seq"
sh -c 'exit 0' &
dead=$!
wait "$dead" || true
printf 'stale\n' >"$WORK/initd-seq/sing-box.prokop.$dead"
printf 'in progress\n' >"$WORK/initd-seq/sing-box.prokop.$$"
printf '#!/bin/sh /etc/rc.common\n# Prokop managed sing-box service for binary variants\n# an older managed script\n' \
  >"$WORK/initd-seq/sing-box"
: >"$WORK/stamps"
run_writers "$WORK/initd-seq" component stamp start stamp requirements stamp
cmp -s "$WORK/initd-seq/sing-box" "$WORK/initd-start/sing-box" ||
  fail "a component install did not replace an older managed init script"
[ ! -e "$WORK/initd-seq/sing-box.prokop.$dead" ] ||
  fail "a component install left a copy of the init script whose writer is gone"
[ -e "$WORK/initd-seq/sing-box.prokop.$$" ] || fail "a component install removed the copy of a writer still at work"
[ "$(LC_ALL=C sort -u "$WORK/stamps" | wc -l)" -eq 1 ] ||
  fail "a start or the requirements check rewrote the init script a component install wrote: $(tr '\n' ';' <"$WORK/stamps")"
ok "a start after a component install keeps the script; stale copies go, a live writer's copy stays"

printf 'singbox_managed_service_text: PASS\n'
