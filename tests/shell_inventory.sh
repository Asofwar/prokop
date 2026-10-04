#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_FILES="$ROOT_DIR/prokop/files"
PROKOP_BIN="$PROKOP_FILES/usr/bin/prokop"
PROKOP_LIB="$PROKOP_FILES/usr/lib"
PROKOP_INIT="$PROKOP_FILES/etc/init.d/prokop"
LUCI_ROOT="$ROOT_DIR/luci-app-prokop/root"
LUCI_UCI_DEFAULTS="$LUCI_ROOT/etc/uci-defaults/50_luci-prokop"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -d "$PROKOP_LIB" ] || fail "runtime library directory is missing"
[ -r "$PROKOP_BIN" ] || fail "prokop ucode entrypoint is missing"
[ -r "$PROKOP_INIT" ] || fail "prokop init.d entrypoint is missing"
[ -r "$LUCI_UCI_DEFAULTS" ] || fail "LuCI uci-defaults entrypoint is missing"

runtime_shell_files="$(find "$PROKOP_LIB" -type f -name '*.sh' -print)"
expected_runtime_shell_files="$PROKOP_LIB/full-uninstall.sh"
[ "$runtime_shell_files" = "$expected_runtime_shell_files" ] ||
  fail "runtime library may contain only the controlled full-uninstall helper: $runtime_shell_files"

legacy_shell_owners='runtime_state\.sh|rules_nft_runtime\.sh|config_validation\.sh|sing_box_runtime\.sh|updates_runtime\.sh|updater\.sh|status_diagnostics\.sh|helpers\.sh|constants\.sh|subscription_runtime\.sh|byedpi\.sh|zapret\.sh|zapret2\.sh'
if find "$PROKOP_FILES" -type f -print | grep -E "$legacy_shell_owners" >/dev/null 2>&1; then
  fail "legacy runtime shell owner file returned under prokop/files"
fi

shell_scripts="$(
  find "$PROKOP_FILES" "$LUCI_ROOT" -type f -print |
    while IFS= read -r file; do
      first_line="$(sed -n '1p' "$file")"
      case "$first_line" in
        '#!'*'/bin/sh'*|'#!'*'/bin/ash'*|'#!'*'rc.common'*|'#!'*' bash'*|'#!'*'/bash'*)
          printf '%s\n' "${file#$ROOT_DIR/}"
          ;;
      esac
    done |
    LC_ALL=C sort
)"

expected_shell_scripts="$(
  printf '%s\n' \
    'luci-app-prokop/root/etc/uci-defaults/50_luci-prokop' \
    'prokop/files/etc/init.d/prokop' \
    'prokop/files/etc/init.d/prokop-dns-failsafe' \
    'prokop/files/etc/init.d/prokop-killswitch' \
    'prokop/files/etc/init.d/prokop-torrserver-direct' \
    'prokop/files/usr/lib/full-uninstall.sh' \
    'prokop/files/usr/libexec/prokop-ro' \
    'prokop/files/usr/share/prokop/mirror-migration.sh' |
    LC_ALL=C sort
)"

[ "$shell_scripts" = "$expected_shell_scripts" ] ||
  fail "unexpected packaged shell inventory:
expected:
$expected_shell_scripts
actual:
$shell_scripts"

grep -Fq '#!/usr/bin/ucode' "$PROKOP_BIN" ||
  fail "/usr/bin/prokop must remain a direct ucode executable"
grep -Fq 'function command_spec(command)' "$PROKOP_BIN" ||
  fail "/usr/bin/prokop must own command routing in ucode"
if grep -n -E '#!/bin/(ba)?sh|exec[[:space:]]+ucode|run_module\(|PROKOP_COMMAND' "$PROKOP_BIN" >/dev/null 2>&1; then
  fail "/usr/bin/prokop must not regress to a shell loader or shell router"
fi

grep -Fq 'PROKOP_INITD_UC="$PROKOP_LIB/service/initd.uc"' "$PROKOP_INIT" ||
  fail "init.d must delegate service orchestration to service/initd.uc"
grep -Fq 'initd_ucode start-service' "$PROKOP_INIT" ||
  fail "init.d start path must delegate to ucode"
grep -Fq 'initd_ucode stop-service' "$PROKOP_INIT" ||
  fail "init.d stop path must delegate to ucode"
grep -Fq 'initd_ucode reload-service' "$PROKOP_INIT" ||
  fail "init.d reload path must delegate to ucode"
grep -Fq 'initd_ucode trigger-plan' "$PROKOP_INIT" ||
  fail "init.d trigger decisions must be produced by ucode"

if awk '!/^[[:space:]]*#/' "$PROKOP_INIT" | grep -n -E '(^|[^[:alnum:]_])(uci|config_load|config_get|config_foreach|jsonfilter|nft|iptables|ip6?tables|sing-box|dnsmasq|curl|wget|opkg|apk)([[:space:]]|$)' >/dev/null 2>&1; then
  fail "init.d must not own UCI, routing, download, package, dnsmasq, nft, or sing-box decisions"
fi
if grep -n -E 'PROKOP_RELOAD_LOCK|PROKOP_URLTEST_SELECTOR_SWITCHES|capture_reload_state|populate_nft_runtime_sets|rebuild_nft_runtime|apply_pending_urltest_selector_switches' "$PROKOP_INIT" >/dev/null 2>&1; then
  fail "init.d must not own runtime state or reload decisions"
fi

grep -Fq '/usr/bin/prokop luci_postinst' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must delegate postinstall work to ucode"
if grep -n -E '(^|[^[:alnum:]_])(uci|rm|logger|rpcd|killall|jsonfilter|config_load|config_get)([[:space:]]|$)' "$LUCI_UCI_DEFAULTS" >/dev/null 2>&1; then
  fail "LuCI uci-defaults must not own cache, rpcd, logging, or UCI logic"
fi

printf 'shell inventory checks passed\n'
