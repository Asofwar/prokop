# shellcheck shell=bash
# The uci CLI for tests of code that shells out to it: the autotune manager
# writes policy and targets with `uci -c DIR -t SAVEDIR set/delete/commit`
# (UC-009). Sourced with ROOT_DIR and WORK set; exports PROKOP_AUTOTUNE_UCI.
#
# PROKOP_TEST_UCI_CLI chooses the CLI:
#   auto (default)  the OpenWrt uci on PATH, else the test shim
#   real            the OpenWrt uci on PATH; a missing one is a failure
#   shim            tests/helpers/uci_cli/uci (see tests/uci_cli_shim.sh)
# The chosen CLI must pass a set/commit/get round trip before the test
# starts, so a missing or broken tool fails here with its name, not as an
# empty failure deep inside the test. Calls the shim refuses during the test
# are collected in PROKOP_TEST_UCI_SHIM_LOG; uci_cli_report (EXIT trap)
# prints them and returns 1, and the trap must then fail the test even where
# the test tolerated the failing call (tests/uci_cli_shim.sh checks every
# test that sources this file).

UCI_CLI_SHIM="$ROOT_DIR/tests/helpers/uci_cli/uci"
export PROKOP_TEST_UCI_SHIM_LOG="$WORK/uci-shim.log"

uci_cli_report() {
  if [ -s "$PROKOP_TEST_UCI_SHIM_LOG" ]; then
    printf 'FAIL: the uci test shim refused a call:\n' >&2
    cat "$PROKOP_TEST_UCI_SHIM_LOG" >&2
    return 1
  fi
}

uci_cli_fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

case "${PROKOP_TEST_UCI_CLI:-auto}" in
  auto)
    UCI_CLI="$(command -v uci 2>/dev/null || true)"
    if [ -z "$UCI_CLI" ]; then
      UCI_CLI="$UCI_CLI_SHIM"
      printf 'NOTE: no OpenWrt uci CLI on PATH, using the test shim tests/helpers/uci_cli/uci\n' >&2
    fi
    ;;
  real)
    UCI_CLI="$(command -v uci 2>/dev/null)" ||
      uci_cli_fail "PROKOP_TEST_UCI_CLI=real: the OpenWrt uci CLI (uci -c/-t) is not on PATH"
    ;;
  shim) UCI_CLI="$UCI_CLI_SHIM" ;;
  *) uci_cli_fail "PROKOP_TEST_UCI_CLI must be auto, real or shim, not '${PROKOP_TEST_UCI_CLI}'" ;;
esac
if [ "$UCI_CLI" = "$UCI_CLI_SHIM" ] && ! command -v ucode >/dev/null 2>&1; then
  uci_cli_fail "the uci test shim needs ucode on PATH"
fi
export PROKOP_AUTOTUNE_UCI="$UCI_CLI"

uci_cli_check() {
  local dir="$WORK/uci-cli-check" out=""
  mkdir -p "$dir/config"
  printf "config probe 'probe'\n" >"$dir/config/probe"
  if ! out="$("$UCI_CLI" -c "$dir/config" -t "$dir/save" set probe.probe.value=ok 2>&1 &&
    "$UCI_CLI" -c "$dir/config" -t "$dir/save" commit probe 2>&1 &&
    "$UCI_CLI" -c "$dir/config" -t "$dir/save" get probe.probe.value 2>&1)" ||
    [ "$out" != ok ] || ! grep -Fxq "	option value 'ok'" "$dir/config/probe"; then
    uci_cli_fail "no working uci CLI ($UCI_CLI): ${out:-no output}"
  fi
  rm -rf "$dir"
}
uci_cli_check
