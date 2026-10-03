#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_UC="$ROOT_DIR/prokop/files/usr/lib/components/action.uc"
UPDATES_TS="$ROOT_DIR/fe-app-prokop/src/prokop/tabs/updates/initController.ts"
DIAGNOSTICS_TS="$ROOT_DIR/fe-app-prokop/src/prokop/tabs/diagnostic/initController.ts"
CONSTANTS_UC="$ROOT_DIR/prokop/files/usr/lib/core/constants.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=tests/helpers/source_checks.sh
source "$ROOT_DIR/tests/helpers/source_checks.sh"

extended_resolver="$(source_function "$ACTION_UC" resolve_sing_box_extended_release)" || exit 1
printf '%s\n' "$extended_resolver" | grep -Fq '/forkop/sing-box-extended/latest.json' ||
  fail "a configured mirror must keep serving sing-box Extended metadata"
printf '%s\n' "$extended_resolver" | grep -Fq 'fetch_github_release_json("shtorm-7", "sing-box-extended")' ||
  fail "without a mirror sing-box Extended metadata must come from its GitHub releases"
grep -Fq 'asset_url: prokop_mirror_url(asset_url)' "$ACTION_UC" ||
  fail "sing-box Extended relative assets must stay on the dependency mirror"

# The fork's own release channel is the default; upstream's is never baked in.
grep -Fq 'env("PROKOP_RELEASE_REPO", "Asofwar/prokop")' "$CONSTANTS_UC" ||
  fail "Prokop releases must default to Asofwar/prokop"
grep -Fq 'env("PROKOP_RELEASE_BASE_URL", "https://asofwar.github.io/prokop")' "$CONSTANTS_UC" ||
  fail "Prokop releases must default to the fork's GitHub Pages release channel"
for source in "$ACTION_UC" "$ROOT_DIR/prokop/files/usr/lib/diagnostics/runtime.uc"; do
  grep -Fq 'getenv("PROKOP_RELEASE_REPO") || constants.PROKOP_RELEASE_REPO || ""' "$source" ||
    fail "$source must take the release repository from core.constants"
  source_refute "$source must not carry an upstream release default" \
    -E 'slayer326|fold8[.]ru' "$source"
done
grep -Fq 'getenv("PROKOP_RELEASE_BASE_URL") || constants.PROKOP_RELEASE_BASE_URL || ""' "$ACTION_UC" ||
  fail "the release channel URL must come from core.constants"
source_refute "the dependency mirror must be opt-in in the component actions" \
  -E 'infotechtg|51343' "$ACTION_UC"
grep -Fq 'release_base_url + "/updates/latest.json"' "$ACTION_UC" ||
  fail "Prokop updates must query the static release channel before GitHub"
grep -Fq 'return fetch_github_release_json(parts[0], parts[1]);' "$ACTION_UC" ||
  fail "Prokop updates must retain GitHub Releases as a fallback"
source_refute "LuCI must link to the fork, not upstream" \
  -F 'github.com/slayer326/forkop' "$ROOT_DIR/fe-app-prokop/src"
source_refute "runtime errors must send reports to the fork" \
  -F 'github.com/slayer326/forkop' "$ROOT_DIR/prokop/files/usr/lib/singbox/runtime.uc"

grep -Fq "text: _('Install Tiny build')" "$UPDATES_TS" || fail "Tiny switch is missing"
grep -Fq "text: _('Install Extended build')" "$UPDATES_TS" || fail "Extended switch is missing"
if grep -Fq "text: 'Stable'" "$UPDATES_TS"; then
  fail "Stable sing-box must not be offered in LuCI"
fi
if grep -Fq "text: 'Extended compressed'" "$UPDATES_TS"; then
  fail "Extended compressed must not be offered in LuCI"
fi

grep -Fq "title: 'Zapret-Manager-Stressozz'" "$UPDATES_TS" ||
  fail "Zapret-Manager-Stressozz branding is missing"
grep -Fq 'zapret_manager_installed' "$UPDATES_TS" ||
  fail "Zapret-Manager installed-state check is missing"
grep -Fq "key: 'zapretManagerRemove'" "$UPDATES_TS" ||
  fail "Zapret-Manager remove button is missing"
grep -Fq 'function remove_zapret_manager(action)' "$ACTION_UC" ||
  fail "Zapret-Manager safe removal action is missing"
grep -Fq 'function set_packet_steering(action)' "$ACTION_UC" ||
  fail "Packet Steering action is missing"
grep -Fq 'network.@globals[0].packet_steering' "$ACTION_UC" ||
  fail "Packet Steering must target the first network globals section"
grep -Fq "component: 'packet_steering'" "$UPDATES_TS" ||
  fail "Packet Steering card is missing"
grep -Fq "key: 'packetSteeringEnable'" "$UPDATES_TS" ||
  fail "Packet Steering enable button is missing"
grep -Fq "key: 'packetSteeringRestore'" "$UPDATES_TS" ||
  fail "Packet Steering restore button is missing"
grep -Fq 'clear_version_caches();' "$ACTION_UC" ||
  fail "component installation must invalidate system-info caches"
if grep -Fq 'github_probe(proxy_address)' "$ROOT_DIR/prokop/files/usr/lib/components/updates.uc"; then
  fail "list updates must not wait for an unrelated GitHub availability probe"
fi
grep -Fq 'grid-template-columns: repeat(3, minmax(0, 1fr))' \
  "$ROOT_DIR/fe-app-prokop/src/prokop/tabs/updates/styles.ts" ||
  fail "component columns must have equal fixed widths"
grep -Fq "key: 'Prokop'" "$DIAGNOSTICS_TS" ||
  fail "Prokop diagnostics branding is missing"

printf 'Prokop component checks passed\n'
