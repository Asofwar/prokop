#!/bin/sh
set -eu

# The requirements check (config/validator.uc check-requirements, run by
# every start) reads `sing-box version` through a temporary file, with a
# bound on how long sing-box may take. The file was a fixed name in /tmp,
# /tmp/prokop-validator-version.<pid>: a name others can guess, and outside
# the directory a test gives a run in TMPDIR, so the host check of
# tests/run.sh saw it appear and go when runs overlapped. The file is now
# made by mktemp in TMPDIR (/tmp when it is unset, as on OpenWrt), and is
# removed after the probe.
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT HUP INT TERM
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/tmp"
# The probed sing-box notes where its stdout goes and answers a version
# below the minimum, which the check can only report when it read the
# answer back from the file.
cat > "$WORK/bin/sing-box" <<'STUB'
#!/bin/sh
[ "${1:-}" = version ] || exit 1
stdout="$(readlink "/proc/$$/fd/1")"
printf '%s\n' "$stdout" > "$PROBE_TARGET"
echo "sing-box version 1.0.0"
STUB
cat > "$WORK/bin/logger" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LOGGER_LOG"
STUB
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/nft"
chmod 0755 "$WORK/bin/sing-box" "$WORK/bin/logger" "$WORK/bin/nft"
: > "$WORK/uci.state"

check_requirements() {
  rm -f "$WORK/probe-target" "$WORK/logger.log"
  PATH="$WORK/bin:$PATH" PROBE_TARGET="$WORK/probe-target" LOGGER_LOG="$WORK/logger.log" \
    PROKOP_UCI_STATE_FILE="$WORK/uci.state" PROKOP_UCI_LOG_FILE="$WORK/uci.log" \
    PROKOP_RUNTIME_STATE_DIR="$WORK/run" TMPDIR="$1" \
    ucode -L "$LIB" "$LIB/config/validator.uc" check-requirements > /dev/null 2>&1 || true
}

check_requirements "$WORK/tmp"
[ -s "$WORK/probe-target" ] || fail "sing-box version was not probed"
target="$(cat "$WORK/probe-target")"
case "$target" in
  "$WORK/tmp/"*) ;;
  *) fail "the sing-box version probe wrote outside TMPDIR: $target" ;;
esac
[ ! -e "$target" ] || fail "the sing-box version probe left its file behind: $target"
[ -z "$(ls -A "$WORK/tmp")" ] || fail "the sing-box version probe left files in TMPDIR: $(ls -A "$WORK/tmp")"
grep -Fq "Package 'sing-box' version (1.0.0) is lower than the required minimum" "$WORK/logger.log" ||
  fail "the probed version was not read back: $(cat "$WORK/logger.log" 2>/dev/null)"
ok "the sing-box version is read through a file that mktemp makes in TMPDIR and is removed"

# When mktemp cannot make the file (TMPDIR names a missing directory), the
# probe gives nothing and the check goes on quietly: mktemp's own complaint
# must not reach the output of check-requirements.
rm -f "$WORK/probe-target" "$WORK/logger.log"
PATH="$WORK/bin:$PATH" PROBE_TARGET="$WORK/probe-target" LOGGER_LOG="$WORK/logger.log" \
  PROKOP_UCI_STATE_FILE="$WORK/uci.state" PROKOP_UCI_LOG_FILE="$WORK/uci.log" \
  PROKOP_RUNTIME_STATE_DIR="$WORK/run" TMPDIR="$WORK/missing" \
  ucode -L "$LIB" "$LIB/config/validator.uc" check-requirements > "$WORK/missing.out" 2> "$WORK/missing.err" || true
[ ! -e "$WORK/probe-target" ] || fail "sing-box was probed although mktemp could not make the file"
! grep -q mktemp "$WORK/missing.out" "$WORK/missing.err" ||
  fail "mktemp's error leaked into check-requirements output: $(cat "$WORK/missing.out" "$WORK/missing.err")"
ok "a failed mktemp leaves the probe empty without noise"

printf 'validator_version_probe_tmpdir: PASS\n'
